module moveposition_simple::strategy {
    use std::option;
    use std::option::Option;
    use std::signer;
    use std::string::utf8;
    use aptos_std::math64;
    use aptos_framework::coin::Self;
    use aptos_framework::event::emit;
    use aptos_framework::object::{Self, Object};
    use aptos_framework::primary_fungible_store::balance as primary_store_balance;

    use coin_to_fa::coins::{
        MBTC,
        TruAPT,
        USDC,
        USDt,
        WETH,
        WBTC,
        EZBTC,
        EZETH,
        MOVE,
        SOLVBTC,
        STBTC,
        RSETH
    };
    use hocket::hocket;
    use moveposition_block::moveposition_block::{Self, virtual_coin_type_metadata};
    use satay::base_strategy::{Self, AuthRef, BaseStrategy, HarvestRequest};
    use satay::hot_asset::{Self, HotAsset};
    use satay::hot_coin::{Self, HotCoin};
    use satay::protocol;
    use satay::vault::{Self, Vault, WithdrawalRequest};

    use moveposition_simple::ticket;

    #[test_only]
    use std::vector;
    #[test_only]
    use aptos_framework::event;

    #[test_only]
    friend moveposition_simple::strategy_tests;

    /// Not authorized to perform the operation.
    const ENOT_AUTHORIZED: u64 = 0;
    /// Invalid amount specified.
    const EINVALID_AMOUNT: u64 = 1;
    /// Insufficient balance to perform the operation.
    const EINSUFFICIENT_BALANCE: u64 = 2;
    /// Invalid asset metadata.
    const EINVALID_ASSET_METADATA: u64 = 3;
    /// Unsupported asset type.
    const EUNSUPPORTED_ASSET_TYPE: u64 = 4;
    /// Invalid asset type.
    const EINVALID_ASSET_TYPE: u64 = 5;
    /// Invalid vault specified.
    const EVAULT_MISMATCH: u64 = 6;
    /// Invalid withdrawal account specified.
    const EWITHDRAWAL_ACCOUNT_MISMATCH: u64 = 7;
    /// Cannot exceed the strategy debt.
    const ECANNOT_EXCEED_DEBT: u64 = 8;
    /// The allowed margin exceeded.
    const EALLOWED_MARGIN_EXCEEDED: u64 = 9;

    const MAX_BPS: u64 = 10000;
    const MAX_AMOUNT_LEEWAY_BPS: u64 = 1500;
    const DEFAULT_AMOUNT_LEEWAY_BPS: u64 = 100;

    struct MovePositionStrategy has key {
        vault: Object<Vault>,
        auth_ref: AuthRef,

        /// The maximum percentage (in basis points) by which the off-chain computed withdrawal (moveposition collateral) amount (amount encoded in the packet payload)
        /// can exceed the actual on-chain calculated amount to withdraw.
        ///
        /// This ensures that if an off-chain request overstates the required withdrawal, the withdrawal is aborted.
        /// Without this check, withdrawing more than needed would cause the excess amount to remain idle in the base strategy,
        /// instead of earning yield for the strategy.
        amount_leeway_bps: u64
    }

    struct Witness has drop {}

    #[event]
    struct StrategyCreated has drop, store {
        vault: Object<Vault>,
        strategy: Object<BaseStrategy>
    }

    /// Creates a new instance of the strategy.
    ///
    /// @param account The account that is creating the strategy.
    /// @param vault The vault to be used by the strategy.
    /// @param debt_limit The maximum amount of debt that can be borrowed by the strategy.
    public entry fun create(
        account: &signer, vault: Object<Vault>, debt_limit: u64
    ) {
        let auth_ref =
            base_strategy::create(account, vault::base_metadata(vault), Witness {});
        let base_strategy = base_strategy::auth_ref_strategy(&auth_ref);

        // This will only work if the `account` is the governance account.
        // Otherwise, the transaction will fail.
        vault::add_strategy(account, vault, base_strategy, debt_limit);

        let amount_leeway_bps = DEFAULT_AMOUNT_LEEWAY_BPS;
        let strategy_signer = base_strategy::get_signer(&auth_ref);

        moveposition_block::ensure_portfolio_exists(&strategy_signer);

        move_to(
            &strategy_signer,
            MovePositionStrategy { vault, auth_ref, amount_leeway_bps }
        );
        emit(StrategyCreated { vault, strategy: base_strategy });
    }

    public entry fun update_amount_leeway_bps(
        account: &signer, strategy: Object<BaseStrategy>, amount_leeway_bps: u64
    ) acquires MovePositionStrategy {
        let account_address = signer::address_of(account);
        assert!(
            protocol::is_governance(account_address)
                || base_strategy::manager(strategy) == account_address,
            ENOT_AUTHORIZED
        );

        assert!(amount_leeway_bps <= MAX_AMOUNT_LEEWAY_BPS, EINVALID_AMOUNT);

        let strategy_ref =
            borrow_global_mut<MovePositionStrategy>(object::object_address(&strategy));
        strategy_ref.amount_leeway_bps = amount_leeway_bps;
    }

    /// Deposits coins into the strategy.
    /// The CoinType's `paired_metadata` has to match the strategy's base metadata.
    ///
    /// @param account The account that is depositing the funds.
    /// @param strategy The strategy to deposit into.
    /// @param data The encoded moveposition packet data.
    /// @param amount The amount of funds to deposit.
    ///
    /// @reverts EINVALID_AMOUNT if the amount is zero.
    /// @reverts EINSUFFICIENT_BALANCE if the account does not have enough balance to deposit.
    public entry fun deposit_coin<CoinType>(
        account: &signer,
        strategy: Object<BaseStrategy>,
        data: vector<u8>,
        amount: u64
    ) acquires MovePositionStrategy {
        assert!(amount > 0, EINVALID_AMOUNT);

        let account_address = signer::address_of(account);
        assert!(
            coin::balance<CoinType>(account_address) >= amount, EINSUFFICIENT_BALANCE
        );

        let strategy_ref = borrow_strategy(strategy);
        let hot_coin = hot_coin::new_from_account<CoinType>(account, amount);
        let shares = deposit_internal(strategy_ref, data, hot_coin);
        hot_asset::dispatch(shares)
    }

    public entry fun deposit_fa(
        account: &signer,
        strategy: Object<BaseStrategy>,
        data: vector<u8>,
        amount: u64
    ) acquires MovePositionStrategy {
        assert!(amount > 0, EINVALID_AMOUNT);

        let account_address = signer::address_of(account);
        let base_metadata = base_strategy::base_metadata(strategy);
        assert!(
            primary_store_balance(account_address, base_metadata) >= amount,
            EINSUFFICIENT_BALANCE
        );

        let strategy_ref = borrow_strategy(strategy);
        let hot_asset = hot_asset::new_from_account(account, base_metadata, amount);
        let shares = deposit_internal_fa(strategy_ref, data, hot_asset);
        hot_asset::dispatch(shares)
    }

    /// Deposits funds from the vault associated with the strategy into the strategy.
    ///
    /// @param account The account that is depositing the funds.
    /// @param strategy The strategy to deposit into.
    /// @param packet The encoded moveposition packet.
    /// @param amount The amount of funds to deposit.
    ///
    /// @reverts EINVALID_AMOUNT if the amount is zero.
    /// @reverts EINSUFFICIENT_BALANCE if the account does not have enough balance to deposit.
    public entry fun vault_deposit_coin<CoinType>(
        account: &signer,
        strategy: Object<BaseStrategy>,
        packet: vector<u8>,
        amount: u64
    ) acquires MovePositionStrategy {
        let strategy_ref = borrow_strategy(strategy);
        let vault = strategy_ref.vault;
        let auth_ref = &strategy_ref.auth_ref;

        // This function creates a debt of the specified amount in the vault and associates it with the strategy.
        // The asset is returned.
        // Also, this function can only be called by the vault manager or governance, otherwise transaction fails.
        let deposit_coin =
            vault::create_debt_coin<CoinType>(account, vault, auth_ref, amount);
        let shares = deposit_internal(strategy_ref, packet, deposit_coin);
        vault::deposit_strategy_shares(vault, strategy, shares);
    }

    public entry fun vault_deposit_fa(
        account: &signer,
        strategy: Object<BaseStrategy>,
        packet: vector<u8>,
        amount: u64
    ) acquires MovePositionStrategy {
        let strategy_ref = borrow_strategy(strategy);
        let vault = strategy_ref.vault;
        let auth_ref = &strategy_ref.auth_ref;

        // This function creates a debt of the specified amount in the vault and associates it with the strategy.
        // The asset is returned.
        // Also, this function can only be called by the vault manager or governance, otherwise transaction fails.
        let deposit_asset = vault::create_debt_fa(account, vault, auth_ref, amount);
        let shares = deposit_internal_fa(strategy_ref, packet, deposit_asset);
        vault::deposit_strategy_shares(vault, strategy, shares);
    }

    /// Withdraws funds from the strategy.
    /// This withdraws the specified amount of strategy shares and redeems them for the strategy's base asset and then converts it to CoinType.
    ///
    /// @param account The account that is withdrawing the funds.
    /// @param strategy The strategy to withdraw from.
    /// @param amount The amount of funds to withdraw.
    /// @param max_loss The maximum amount of loss to take.
    ///
    /// @reverts EINVALID_AMOUNT if the amount is zero.
    /// @reverts EINSUFFICIENT_BALANCE if the account does not have enough balance to withdraw.
    public entry fun withdraw_coin<CoinType>(
        account: &signer,
        strategy: Object<BaseStrategy>,
        data: vector<u8>,
        amount: u64,
        max_loss: Option<u64>
    ) acquires MovePositionStrategy {
        let withdrawn =
            withdraw_coin_internal<CoinType>(account, strategy, data, amount, max_loss);
        hot_coin::dispatch(withdrawn)
    }

    public entry fun withdraw_fa(
        account: &signer,
        strategy: Object<BaseStrategy>,
        data: vector<u8>,
        amount: u64,
        max_loss: Option<u64>
    ) acquires MovePositionStrategy {
        let withdrawn = withdraw_fa_internal(account, strategy, data, amount, max_loss);
        hot_asset::dispatch(withdrawn)
    }

    public fun vault_withdraw_coin<CoinType>(
        account: &signer,
        request: &mut WithdrawalRequest,
        strategy: Object<BaseStrategy>,
        data: vector<u8>,
        amount: u64,
        max_loss: Option<u64>
    ): HotCoin<CoinType> acquires MovePositionStrategy {
        assert!(amount > 0, EINVALID_AMOUNT);
        let strategy_ref = borrow_strategy(strategy);

        assert!(strategy_ref.vault == vault::withdrawal_vault(request), EVAULT_MISMATCH);
        assert!(
            signer::address_of(account) == vault::withdrawal_account(request),
            EWITHDRAWAL_ACCOUNT_MISMATCH
        );

        let vault = strategy_ref.vault;
        let strategy = strategy;

        // Disallow withdrawing more than the remaining amount
        assert!(amount <= vault::withdrawal_remaining(request), EINVALID_AMOUNT);

        // Disallow withdrawing more than the strategy debt against the vault
        assert!(amount <= vault::strategy_debt(vault, strategy), ECANNOT_EXCEED_DEBT);

        // Convert the amount to strategy shares and withdraw it
        let shares_amount = base_strategy::amount_to_shares(strategy, amount);
        let shares_asset =
            vault::withdraw_strategy_shares(vault, &strategy_ref.auth_ref, shares_amount);
        strategy_withdraw_internal<CoinType>(strategy_ref, data, shares_asset, max_loss)
    }

    public fun vault_withdraw_fa(
        account: &signer,
        request: &mut WithdrawalRequest,
        strategy: Object<BaseStrategy>,
        data: vector<u8>,
        amount: u64,
        max_loss: Option<u64>
    ): HotAsset acquires MovePositionStrategy {
        assert!(amount > 0, EINVALID_AMOUNT);
        let strategy_ref = borrow_strategy(strategy);

        assert!(strategy_ref.vault == vault::withdrawal_vault(request), EVAULT_MISMATCH);
        assert!(
            signer::address_of(account) == vault::withdrawal_account(request),
            EWITHDRAWAL_ACCOUNT_MISMATCH
        );

        let vault = strategy_ref.vault;
        let strategy = strategy;

        // Disallow withdrawing more than the remaining amount
        assert!(amount <= vault::withdrawal_remaining(request), EINVALID_AMOUNT);

        // Disallow withdrawing more than the strategy debt against the vault
        assert!(amount <= vault::strategy_debt(vault, strategy), ECANNOT_EXCEED_DEBT);

        // Convert the amount to strategy shares and withdraw it
        let shares_amount = base_strategy::amount_to_shares(strategy, amount);
        let shares_asset =
            vault::withdraw_strategy_shares(vault, &strategy_ref.auth_ref, shares_amount);
        strategy_withdraw_fa_internal(strategy_ref, data, shares_asset, max_loss)
    }

    public entry fun tend_coin<CoinType>(
        account: &signer, strategy: Object<BaseStrategy>, data: vector<u8>
    ) acquires MovePositionStrategy {
        let strategy_ref = borrow_strategy(strategy);
        let tend_coin =
            base_strategy::tend_coin<CoinType>(account, &strategy_ref.auth_ref);
        market_deposit_internal(strategy_ref, data, tend_coin);
    }

    public entry fun tend_fa(
        account: &signer, strategy: Object<BaseStrategy>, data: vector<u8>
    ) acquires MovePositionStrategy {
        let strategy_ref = borrow_strategy(strategy);
        let tend_asset = base_strategy::tend_fa(account, &strategy_ref.auth_ref);
        let metadata = option::some(base_strategy::base_metadata(strategy));

        if (metadata == virtual_coin_type_metadata<TruAPT>()) {
            market_deposit_fa_internal<TruAPT>(strategy_ref, data, tend_asset);
        } else if (metadata == virtual_coin_type_metadata<USDt>()) {
            market_deposit_fa_internal<USDt>(strategy_ref, data, tend_asset);
        } else if (metadata == virtual_coin_type_metadata<USDC>()) {
            market_deposit_fa_internal<USDC>(strategy_ref, data, tend_asset);
        } else if (metadata == virtual_coin_type_metadata<MBTC>()) {
            market_deposit_fa_internal<MBTC>(strategy_ref, data, tend_asset);
        } else if (metadata == virtual_coin_type_metadata<WETH>()) {
            market_deposit_fa_internal<WETH>(strategy_ref, data, tend_asset);
        } else if (metadata == virtual_coin_type_metadata<WBTC>()) {
            market_deposit_fa_internal<WBTC>(strategy_ref, data, tend_asset);
        } else if (metadata == virtual_coin_type_metadata<EZBTC>()) {
            market_deposit_fa_internal<EZBTC>(strategy_ref, data, tend_asset);
        } else if (metadata == virtual_coin_type_metadata<EZETH>()) {
            market_deposit_fa_internal<EZETH>(strategy_ref, data, tend_asset);
        } else if (metadata == virtual_coin_type_metadata<MOVE>()) {
            market_deposit_fa_internal<MOVE>(strategy_ref, data, tend_asset);
        } else if (metadata == virtual_coin_type_metadata<SOLVBTC>()) {
            market_deposit_fa_internal<SOLVBTC>(strategy_ref, data, tend_asset);
        } else if (metadata == virtual_coin_type_metadata<STBTC>()) {
            market_deposit_fa_internal<STBTC>(strategy_ref, data, tend_asset);
        } else if (metadata == virtual_coin_type_metadata<RSETH>()) {
            market_deposit_fa_internal<RSETH>(strategy_ref, data, tend_asset);
        } else {
            abort EINVALID_ASSET_TYPE
        };
    }

    public entry fun vault_report(
        account: &signer, strategy: Object<BaseStrategy>
    ) acquires MovePositionStrategy {
        let strategy_ref = borrow_strategy(strategy);

        let vault = strategy_ref.vault;
        vault::report(account, vault, strategy);
    }

    public entry fun harvest<CoinType>(
        account: &signer, strategy: Object<BaseStrategy>
    ) acquires MovePositionStrategy {
        let strategy_ref = borrow_strategy(strategy);

        let request = base_strategy::request_harvest(account, &strategy_ref.auth_ref);
        handle_harvest_pnl<CoinType>(&mut request, &strategy_ref.auth_ref);
        base_strategy::complete_harvest(request);
    }

    public entry fun harvest_fa(
        account: &signer, strategy: Object<BaseStrategy>
    ) acquires MovePositionStrategy {
        let strategy_ref = borrow_strategy(strategy);
        let request = base_strategy::request_harvest(account, &strategy_ref.auth_ref);
        let metadata = option::some(base_strategy::base_metadata(strategy));

        if (metadata == virtual_coin_type_metadata<TruAPT>()) {
            handle_harvest_pnl<TruAPT>(&mut request, &strategy_ref.auth_ref);
        } else if (metadata == virtual_coin_type_metadata<USDt>()) {
            handle_harvest_pnl<USDt>(&mut request, &strategy_ref.auth_ref);
        } else if (metadata == virtual_coin_type_metadata<USDC>()) {
            handle_harvest_pnl<USDC>(&mut request, &strategy_ref.auth_ref);
        } else if (metadata == virtual_coin_type_metadata<MBTC>()) {
            handle_harvest_pnl<MBTC>(&mut request, &strategy_ref.auth_ref);
        } else if (metadata == virtual_coin_type_metadata<WETH>()) {
            handle_harvest_pnl<WETH>(&mut request, &strategy_ref.auth_ref);
        } else if (metadata == virtual_coin_type_metadata<WBTC>()) {
            handle_harvest_pnl<WBTC>(&mut request, &strategy_ref.auth_ref);
        } else if (metadata == virtual_coin_type_metadata<EZBTC>()) {
            handle_harvest_pnl<EZBTC>(&mut request, &strategy_ref.auth_ref);
        } else if (metadata == virtual_coin_type_metadata<EZETH>()) {
            handle_harvest_pnl<EZETH>(&mut request, &strategy_ref.auth_ref);
        } else if (metadata == virtual_coin_type_metadata<MOVE>()) {
            handle_harvest_pnl<MOVE>(&mut request, &strategy_ref.auth_ref);
        } else if (metadata == virtual_coin_type_metadata<SOLVBTC>()) {
            handle_harvest_pnl<SOLVBTC>(&mut request, &strategy_ref.auth_ref);
        } else if (metadata == virtual_coin_type_metadata<STBTC>()) {
            handle_harvest_pnl<STBTC>(&mut request, &strategy_ref.auth_ref);
        } else if (metadata == virtual_coin_type_metadata<RSETH>()) {
            handle_harvest_pnl<RSETH>(&mut request, &strategy_ref.auth_ref);
        } else {
            abort EINVALID_ASSET_TYPE
        };

        base_strategy::complete_harvest(request);
    }

    inline fun borrow_strategy(strategy: Object<BaseStrategy>): &MovePositionStrategy {
        borrow_global<MovePositionStrategy>(object::object_address(&strategy))
    }

    fun deposit_internal_fa(
        strategy: &MovePositionStrategy, data: vector<u8>, hot_asset: HotAsset
    ): HotAsset {
        let shares = base_strategy::mint_debt_shares_fa(&hot_asset, &strategy.auth_ref);
        let metadata = option::some(hot_asset::asset_metadata(&hot_asset));

        if (metadata == virtual_coin_type_metadata<TruAPT>()) {
            market_deposit_fa_internal<TruAPT>(strategy, data, hot_asset);
        } else if (metadata == virtual_coin_type_metadata<USDt>()) {
            market_deposit_fa_internal<USDt>(strategy, data, hot_asset);
        } else if (metadata == virtual_coin_type_metadata<USDC>()) {
            market_deposit_fa_internal<USDC>(strategy, data, hot_asset);
        } else if (metadata == virtual_coin_type_metadata<MBTC>()) {
            market_deposit_fa_internal<MBTC>(strategy, data, hot_asset);
        } else if (metadata == virtual_coin_type_metadata<WETH>()) {
            market_deposit_fa_internal<WETH>(strategy, data, hot_asset);
        } else if (metadata == virtual_coin_type_metadata<WBTC>()) {
            market_deposit_fa_internal<WBTC>(strategy, data, hot_asset);
        } else if (metadata == virtual_coin_type_metadata<EZBTC>()) {
            market_deposit_fa_internal<EZBTC>(strategy, data, hot_asset);
        } else if (metadata == virtual_coin_type_metadata<EZETH>()) {
            market_deposit_fa_internal<EZETH>(strategy, data, hot_asset);
        } else if (metadata == virtual_coin_type_metadata<MOVE>()) {
            market_deposit_fa_internal<MOVE>(strategy, data, hot_asset);
        } else if (metadata == virtual_coin_type_metadata<SOLVBTC>()) {
            market_deposit_fa_internal<SOLVBTC>(strategy, data, hot_asset);
        } else if (metadata == virtual_coin_type_metadata<STBTC>()) {
            market_deposit_fa_internal<STBTC>(strategy, data, hot_asset);
        } else if (metadata == virtual_coin_type_metadata<RSETH>()) {
            market_deposit_fa_internal<RSETH>(strategy, data, hot_asset);
        } else {
            abort EINVALID_ASSET_TYPE
        };

        shares
    }

    fun deposit_internal<CoinType>(
        strategy: &MovePositionStrategy, data: vector<u8>, coin: HotCoin<CoinType>
    ): HotAsset {
        let shares = base_strategy::mint_debt_shares_coin(&coin, &strategy.auth_ref);
        market_deposit_internal(strategy, data, coin);
        shares
    }

    fun market_withdraw_internal<CoinType>(
        strategy_ref: &MovePositionStrategy, data: vector<u8>, amount: u64
    ): HotCoin<CoinType> {
        validate_withdrawal_data<CoinType>(data, amount, strategy_ref.amount_leeway_bps);

        let strategy_signer = base_strategy::get_signer(&strategy_ref.auth_ref);
        moveposition_block::redeem<CoinType>(&strategy_signer, data)
    }

    fun market_withdraw_fa_internal<VirtualCoinType>(
        strategy_ref: &MovePositionStrategy, data: vector<u8>, amount: u64
    ): HotAsset {
        validate_withdrawal_data<VirtualCoinType>(
            data, amount, strategy_ref.amount_leeway_bps
        );

        let strategy_signer = base_strategy::get_signer(&strategy_ref.auth_ref);
        moveposition_block::redeem_fa<VirtualCoinType>(&strategy_signer, data)
    }

    fun market_deposit_internal<CoinType>(
        strategy: &MovePositionStrategy, data: vector<u8>, hot_coin: HotCoin<CoinType>
    ) {
        validate_deposit_data<CoinType>(data, hot_coin::value(&hot_coin));

        let strategy_signer = base_strategy::get_signer(&strategy.auth_ref);
        moveposition_block::lend<CoinType>(&strategy_signer, data, hot_coin);
    }

    fun market_deposit_fa_internal<VirtualCoinType>(
        strategy: &MovePositionStrategy, data: vector<u8>, hot_asset: HotAsset
    ) {
        validate_deposit_data<VirtualCoinType>(data, hot_asset::amount(&hot_asset));

        let strategy_signer = base_strategy::get_signer(&strategy.auth_ref);
        moveposition_block::lend_fa<VirtualCoinType>(&strategy_signer, data, hot_asset);
    }

    fun strategy_withdraw_internal<CoinType>(
        strategy_ref: &MovePositionStrategy,
        data: vector<u8>,
        shares_asset: HotAsset,
        max_loss: Option<u64>
    ): HotCoin<CoinType> {
        let request =
            base_strategy::request_withdrawal(shares_asset, &strategy_ref.auth_ref);
        base_strategy::withdraw(&mut request);

        // We are not able to complete the withdrawal with the idle assets,
        // so we need to withdraw from our deposits in the the yield source
        if (base_strategy::withdrawal_remaining(&request) > 0) {
            let amount_needed = base_strategy::withdrawal_remaining(&request);
            let base_strategy = base_strategy::withdrawal_strategy(&request);
            let remaining_amount_shares =
                base_strategy::amount_to_shares(base_strategy, amount_needed);
            let collateral_for_shares =
                get_collateral_for_shares<CoinType>(
                    strategy_ref, remaining_amount_shares
                );

            // moveposition collateral is not in terms of the base asset,
            // it's based on an internal coin type used in move position called "deposit notes"
            let coin_withdrawn =
                market_withdraw_internal<CoinType>(
                    strategy_ref, data, collateral_for_shares
                );
            base_strategy::apply_coin_withdrawal(&mut request, coin_withdrawn);
        };

        base_strategy::complete_withdrawal_coin<CoinType>(request, max_loss)
    }

    fun strategy_withdraw_fa_internal(
        strategy_ref: &MovePositionStrategy,
        data: vector<u8>,
        shares_asset: HotAsset,
        max_loss: Option<u64>
    ): HotAsset {
        let request =
            base_strategy::request_withdrawal(shares_asset, &strategy_ref.auth_ref);
        base_strategy::withdraw(&mut request);

        // We are not able to complete the withdrawal with the idle assets,
        // so we need to withdraw from our deposits in the the yield source
        if (base_strategy::withdrawal_remaining(&request) > 0) {
            let amount_needed = base_strategy::withdrawal_remaining(&request);
            let base_strategy = base_strategy::withdrawal_strategy(&request);
            let remaining_amount_shares =
                base_strategy::amount_to_shares(base_strategy, amount_needed);

            let metadata = option::some(base_strategy::base_metadata(base_strategy));
            let asset_withdrawn =
                if (metadata == virtual_coin_type_metadata<TruAPT>()) {
                    let collateral_for_shares =
                        get_collateral_for_shares<TruAPT>(
                            strategy_ref, remaining_amount_shares
                        );
                    market_withdraw_fa_internal<TruAPT>(
                        strategy_ref, data, collateral_for_shares
                    )
                } else if (metadata == virtual_coin_type_metadata<USDt>()) {
                    let collateral_for_shares =
                        get_collateral_for_shares<USDt>(
                            strategy_ref, remaining_amount_shares
                        );
                    market_withdraw_fa_internal<USDt>(
                        strategy_ref, data, collateral_for_shares
                    )
                } else if (metadata == virtual_coin_type_metadata<USDC>()) {
                    let collateral_for_shares =
                        get_collateral_for_shares<USDC>(
                            strategy_ref, remaining_amount_shares
                        );
                    market_withdraw_fa_internal<USDC>(
                        strategy_ref, data, collateral_for_shares
                    )
                } else if (metadata == virtual_coin_type_metadata<MBTC>()) {
                    let collateral_for_shares =
                        get_collateral_for_shares<MBTC>(
                            strategy_ref, remaining_amount_shares
                        );
                    market_withdraw_fa_internal<MBTC>(
                        strategy_ref, data, collateral_for_shares
                    )
                } else if (metadata == virtual_coin_type_metadata<WETH>()) {
                    let collateral_for_shares =
                        get_collateral_for_shares<WETH>(
                            strategy_ref, remaining_amount_shares
                        );
                    market_withdraw_fa_internal<WETH>(
                        strategy_ref, data, collateral_for_shares
                    )
                } else if (metadata == virtual_coin_type_metadata<WBTC>()) {
                    let collateral_for_shares =
                        get_collateral_for_shares<WBTC>(
                            strategy_ref, remaining_amount_shares
                        );
                    market_withdraw_fa_internal<WBTC>(
                        strategy_ref, data, collateral_for_shares
                    )
                } else if (metadata == virtual_coin_type_metadata<EZBTC>()) {
                    let collateral_for_shares =
                        get_collateral_for_shares<EZBTC>(
                            strategy_ref, remaining_amount_shares
                        );
                    market_withdraw_fa_internal<EZBTC>(
                        strategy_ref, data, collateral_for_shares
                    )
                } else if (metadata == virtual_coin_type_metadata<EZETH>()) {
                    let collateral_for_shares =
                        get_collateral_for_shares<EZETH>(
                            strategy_ref, remaining_amount_shares
                        );
                    market_withdraw_fa_internal<EZETH>(
                        strategy_ref, data, collateral_for_shares
                    )
                } else if (metadata == virtual_coin_type_metadata<MOVE>()) {
                    let collateral_for_shares =
                        get_collateral_for_shares<MOVE>(
                            strategy_ref, remaining_amount_shares
                        );
                    market_withdraw_fa_internal<MOVE>(
                        strategy_ref, data, collateral_for_shares
                    )
                } else if (metadata == virtual_coin_type_metadata<SOLVBTC>()) {
                    let collateral_for_shares =
                        get_collateral_for_shares<SOLVBTC>(
                            strategy_ref, remaining_amount_shares
                        );
                    market_withdraw_fa_internal<SOLVBTC>(
                        strategy_ref, data, collateral_for_shares
                    )
                } else if (metadata == virtual_coin_type_metadata<STBTC>()) {
                    let collateral_for_shares =
                        get_collateral_for_shares<STBTC>(
                            strategy_ref, remaining_amount_shares
                        );
                    market_withdraw_fa_internal<STBTC>(
                        strategy_ref, data, collateral_for_shares
                    )
                } else if (metadata == virtual_coin_type_metadata<RSETH>()) {
                    let collateral_for_shares =
                        get_collateral_for_shares<RSETH>(
                            strategy_ref, remaining_amount_shares
                        );
                    market_withdraw_fa_internal<RSETH>(
                        strategy_ref, data, collateral_for_shares
                    )
                } else {
                    abort EINVALID_ASSET_TYPE
                };

            // moveposition collateral is not in terms of the base asset,
            // it's based on an internal coin type used in move position called "deposit notes"
            base_strategy::apply_fa_withdrawal(&mut request, asset_withdrawn);
        };

        base_strategy::complete_withdrawal(request, max_loss)
    }

    fun withdraw_coin_internal<CoinType>(
        account: &signer,
        strategy: Object<BaseStrategy>,
        data: vector<u8>,
        amount: u64,
        max_loss: Option<u64>
    ): HotCoin<CoinType> acquires MovePositionStrategy {
        assert!(amount > 0, EINVALID_AMOUNT);
        let account_address = signer::address_of(account);
        let shares_metadata = base_strategy::shares_metadata(strategy);
        assert!(
            primary_store_balance(account_address, shares_metadata) >= amount,
            EINSUFFICIENT_BALANCE
        );

        let strategy_ref = borrow_strategy(strategy);
        let shares_hot_asset =
            hot_asset::new_from_account(account, shares_metadata, amount);
        strategy_withdraw_internal<CoinType>(
            strategy_ref, data, shares_hot_asset, max_loss
        )
    }

    fun withdraw_fa_internal(
        account: &signer,
        strategy: Object<BaseStrategy>,
        data: vector<u8>,
        amount: u64,
        max_loss: Option<u64>
    ): HotAsset acquires MovePositionStrategy {
        assert!(amount > 0, EINVALID_AMOUNT);
        let account_address = signer::address_of(account);
        let shares_metadata = base_strategy::shares_metadata(strategy);
        assert!(
            primary_store_balance(account_address, shares_metadata) >= amount,
            EINSUFFICIENT_BALANCE
        );

        let strategy_ref = borrow_strategy(strategy);
        let shares_hot_asset =
            hot_asset::new_from_account(account, shares_metadata, amount);
        strategy_withdraw_fa_internal(strategy_ref, data, shares_hot_asset, max_loss)
    }

    fun get_collateral_for_shares<CoinType>(
        strategy_ref: &MovePositionStrategy, amount: u64
    ): u64 {
        let base_strategy = base_strategy::auth_ref_strategy(&strategy_ref.auth_ref);
        let strategy_address = object::object_address(&base_strategy);

        let collateral_balance =
            moveposition_block::get_collateral_balance<CoinType>(strategy_address);
        let total_shares = base_strategy::total_shares(base_strategy);
        math64::mul_div(amount, collateral_balance, total_shares)
    }

    fun handle_harvest_pnl<CoinType>(
        request: &mut HarvestRequest, auth_ref: &AuthRef
    ) {
        let strategy = base_strategy::harvest_strategy(request);

        let total_debt = base_strategy::total_debt(strategy);
        let strategy_address = object::object_address(&strategy);

        // collateral is in `notes` not raw coins (base asset), so we need to convert it
        let collateral_balance =
            moveposition_block::get_collateral_balance<CoinType>(strategy_address);
        let account_coins =
            moveposition_block::calc_coins_from_dnotes<CoinType>(collateral_balance);

        if (account_coins > total_debt) {
            let profit = account_coins - total_debt;
            base_strategy::report_harvest_profit(request, auth_ref, profit);
        } else if (account_coins < total_debt) {
            let loss = total_debt - account_coins;
            base_strategy::report_harvest_loss(request, auth_ref, loss);
        }
    }

    fun validate_deposit_data<CoinType>(data: vector<u8>, amount: u64) {
        let packet = hocket::parse_and_verify(data);
        let ticket = ticket::deserialize(hocket::get_payload(&packet));

        ticket::validate_amount(&ticket, amount);
        ticket::validate_coin_type<CoinType>(&ticket);
        ticket::validate_operation(&ticket, utf8(b"lend_v2"));
    }

    fun validate_withdrawal_data<CoinType>(
        data: vector<u8>, amount: u64, leeway_bps: u64
    ) {
        let packet = hocket::parse_and_verify(data);
        let ticket = ticket::deserialize(hocket::get_payload(&packet));

        // calculate the allowed margin based on the amount and leeway_bps
        let allowed_margin = math64::mul_div(amount, leeway_bps, MAX_BPS);
        assert!(
            ticket::amount(&ticket) <= amount + allowed_margin,
            EALLOWED_MARGIN_EXCEEDED
        );

        ticket::validate_coin_type<CoinType>(&ticket);
        ticket::validate_operation(&ticket, utf8(b"redeem_v2"));
    }

    #[view]
    public fun withdrawal_amount_view<CoinType>(
        strategy: Object<BaseStrategy>, amount: u64
    ): u64 acquires MovePositionStrategy {
        let withdrawable = math64::min(amount, base_strategy::total_idle(strategy));
        let remaining = amount - withdrawable;
        if (remaining == 0) return 0;

        let strategy_ref = borrow_strategy(strategy);
        let remaining_amount_shares = base_strategy::amount_to_shares(
            strategy, remaining
        );
        return get_collateral_for_shares<CoinType>(
            strategy_ref, remaining_amount_shares
        )
    }

    #[view]
    public fun withdrawal_amount_view_fa(
        strategy: Object<BaseStrategy>, amount: u64
    ): u64 acquires MovePositionStrategy {
        let metadata = option::some(base_strategy::base_metadata(strategy));
        if (metadata == virtual_coin_type_metadata<TruAPT>()) {
            withdrawal_amount_view<TruAPT>(strategy, amount)
        } else if (metadata == virtual_coin_type_metadata<USDt>()) {
            withdrawal_amount_view<USDt>(strategy, amount)
        } else if (metadata == virtual_coin_type_metadata<USDC>()) {
            withdrawal_amount_view<USDC>(strategy, amount)
        } else if (metadata == virtual_coin_type_metadata<MBTC>()) {
            withdrawal_amount_view<MBTC>(strategy, amount)
        } else if (metadata == virtual_coin_type_metadata<WETH>()) {
            withdrawal_amount_view<WETH>(strategy, amount)
        } else if (metadata == virtual_coin_type_metadata<WBTC>()) {
            withdrawal_amount_view<WBTC>(strategy, amount)
        } else if (metadata == virtual_coin_type_metadata<EZBTC>()) {
            withdrawal_amount_view<EZBTC>(strategy, amount)
        } else if (metadata == virtual_coin_type_metadata<EZETH>()) {
            withdrawal_amount_view<EZETH>(strategy, amount)
        } else if (metadata == virtual_coin_type_metadata<MOVE>()) {
            withdrawal_amount_view<MOVE>(strategy, amount)
        } else if (metadata == virtual_coin_type_metadata<SOLVBTC>()) {
            withdrawal_amount_view<SOLVBTC>(strategy, amount)
        } else if (metadata == virtual_coin_type_metadata<STBTC>()) {
            withdrawal_amount_view<STBTC>(strategy, amount)
        } else if (metadata == virtual_coin_type_metadata<RSETH>()) {
            withdrawal_amount_view<RSETH>(strategy, amount)
        } else {
            abort EINVALID_ASSET_TYPE
        }
    }

    #[test_only]
    public fun create_for_test(
        account: &signer, vault: Object<Vault>, debt_limit: u64
    ): Object<BaseStrategy> {
        create(account, vault, debt_limit);

        let events = event::emitted_events<StrategyCreated>();
        vector::pop_back(&mut events).strategy
    }
}

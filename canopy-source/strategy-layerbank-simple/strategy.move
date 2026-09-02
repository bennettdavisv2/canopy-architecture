module layerbank_simple::strategy {
    use std::option::{Self, Option};
    use std::signer;
    use std::vector;

    use aptos_framework::coin;
    use aptos_framework::timestamp;
    use aptos_framework::event::emit;
    use aptos_framework::aptos_coin::AptosCoin;
    use aptos_framework::fungible_asset::Metadata;
    use aptos_framework::object::{Self, Object};
    use aptos_framework::primary_fungible_store::{balance as primary_store_balance, deposit as primary_store_deposit};

    use satay::protocol;
    use satay::base_strategy::{Self, AuthRef, BaseStrategy, HarvestRequest};
    use satay::hot_asset::{Self, HotAsset};
    use satay::vault::{Self, Vault, WithdrawalRequest};

    use canopy_staking::multi_rewards::{Self, StakingPool};

    use layerbank_block::layerbank_block;

    #[test_only]
    use aptos_framework::event;

    #[test_only]
    friend layerbank_simple::deposit_fa_test_entry_functions;
    #[test_only]
    friend layerbank_simple::withdraw_fa_test_entry_functions;

    // - - - - CONSTANTS - - - -

    /// Not authorized to perform the operation.
    const ENOT_AUTHORIZED: u64 = 0;
    /// Invalid amount specified.
    const EINVALID_AMOUNT: u64 = 1;
    /// Insufficient balance to perform the operation.
    const EINSUFFICIENT_BALANCE: u64 = 2;
    /// Invalid vault specified.
    const EVAULT_MISMATCH: u64 = 6;
    /// Invalid withdrawal account specified.
    const EWITHDRAWAL_ACCOUNT_MISMATCH: u64 = 7;
    /// Cannot exceed the strategy debt.
    const ECANNOT_EXCEED_DEBT: u64 = 8;
    /// Invalid fee recipient
    const EINVALID_FEE_RECIPIENT: u64 = 9;
    /// No rewards pool address set.
    const ENO_REWARDS_POOL_ADDRESS: u64 = 10;
    /// Upkeep not ready.
    const EUPKEEP_NOT_READY: u64 = 11;
    /// Invalid rewards pool address.
    const EINVALID_REWARDS_POOL_ADDRESS: u64 = 12;
    /// Invalid upkeep interval.
    const EINVALID_UPKEEP_INTERVAL: u64 = 13;

    const DEFAULT_UPKEEP_INTERVAL: u64 = 60 * 60 * 24; // 1 day
    const MIN_UPKEEP_INTERVAL: u64 = 60 * 60; // 1 hour
    const MAX_UPKEEP_INTERVAL: u64 = 60 * 60 * 24 * 7; // 7 days

    // - - - - STRUCTS - - - -

    struct Witness has drop {}

    struct LayerBankStrategy has key {
        auth_ref: AuthRef,
        vault: Object<Vault>,
        rewards_controller_address: Option<address>
    }

    struct RewardsPoolDetails has key {
        rewards_pool_address: Option<address>,
        last_upkeep_timestamp: u64,
        upkeep_interval: u64
    }

    // - - - - INSTANTIATOR - - - -

    /// Creates a new instance of the strategy.
    public entry fun create(
        account: &signer,
        vault: Object<Vault>,
        debt_limit: u64,
        rewards_controller_address: Option<address>
    ) {
        // Ensure a reserve exists for the base asset before creating a strategy
        layerbank_block::ensure_reserve_exists(object::object_address(&vault::base_metadata(vault)));

        let auth_ref = base_strategy::create(account, vault::base_metadata(vault), Witness {});
        let base_strategy = base_strategy::auth_ref_strategy(&auth_ref);

        // NOTE: account must be the protocol governance signer in order to add a strategy to the vault
        vault::add_strategy(account, vault, base_strategy, debt_limit);

        let strategy_signer = base_strategy::get_signer(&auth_ref);
        let strategy = LayerBankStrategy { auth_ref, vault, rewards_controller_address };

        initialize_reward_pool_details(&strategy, option::none());
        move_to(&strategy_signer, strategy);

        emit(StrategyCreated { vault, strategy: base_strategy, rewards_controller_address });
    }

    fun initialize_reward_pool_details(
        strategy_ref: &LayerBankStrategy, rewards_pool_address: Option<address>
    ) {
        let strategy_signer = base_strategy::get_signer(&strategy_ref.auth_ref);

        validate_rewards_pool_address(rewards_pool_address);

        move_to(
            &strategy_signer,
            RewardsPoolDetails {
                rewards_pool_address,
                last_upkeep_timestamp: 0,
                upkeep_interval: DEFAULT_UPKEEP_INTERVAL
            }
        );
    }

    fun validate_rewards_pool_address(rewards_pool_address: Option<address>) {
        if (option::is_some(&rewards_pool_address)) {
            assert!(
                object::object_exists<StakingPool>(*option::borrow(&rewards_pool_address)),
                EINVALID_REWARDS_POOL_ADDRESS
            );
        };
    }

    // - - - - DIRECT STRATEGY USER FUNCTIONS - - - -

    /// Deposits fungible assets into the strategy.
    /// The asset metadata has to match the strategy's base metadata and must also match the metadata \
    /// corresponding `paired_metadata` of the specified `CoinType`.
    ///
    /// @param account The account that is depositing the funds and also will be awarded the newly minted strategy shares.
    /// @param strategy The strategy to deposit into.
    /// @param amount The amount of funds to deposit.
    ///
    /// @reverts EINVALID_AMOUNT if the amount is zero.
    /// @reverts EINSUFFICIENT_BALANCE if the account does not have enough balance to deposit.
    public(friend) fun deposit_fa(account: &signer, strategy: Object<BaseStrategy>, amount: u64) acquires LayerBankStrategy {
        assert!(amount > 0, EINVALID_AMOUNT);

        let account_address = signer::address_of(account);
        let base_metadata = base_strategy::base_metadata(strategy);
        assert!(
            primary_store_balance(account_address, base_metadata) >= amount,
            EINSUFFICIENT_BALANCE
        );

        let hot_asset = hot_asset::new_from_account(account, base_metadata, amount);

        let strategy_ref = borrow_strategy(strategy);
        let strategy_shares = deposit_fa_internal(strategy_ref, hot_asset);
        hot_asset::dispatch(strategy_shares);
    }

    /// Withdraws funds from the strategy.
    /// This withdraws the specified amount of strategy shares and redeems them for the strategy's base asset.
    ///
    /// @param account The account that is withdrawing the funds i.e. that has the strategy shares that will be burned.
    /// @param strategy The strategy to withdraw from.
    /// @param amount The amount of strategy shares to burn and redeem for the base asset.
    /// @param max_loss The maximum amount of loss to take in BPS.
    ///
    /// @reverts EINVALID_AMOUNT if the amount is zero.
    /// @reverts EINSUFFICIENT_BALANCE if the account does not have enough balance to withdraw.
    public entry fun withdraw_fa(
        account: &signer,
        strategy: Object<BaseStrategy>,
        amount: u64,
        max_loss: Option<u64>
    ) acquires LayerBankStrategy {
        ensure_fee_recipient(account, strategy);

        assert!(amount > 0, EINVALID_AMOUNT);
        let account_address = signer::address_of(account);
        let shares_metadata = base_strategy::shares_metadata(strategy);
        assert!(
            primary_store_balance(account_address, shares_metadata) >= amount,
            EINSUFFICIENT_BALANCE
        );

        let strategy_ref = borrow_strategy(strategy);
        let shares_asset = hot_asset::new_from_account(account, shares_metadata, amount);
        hot_asset::dispatch(withdraw_fa_internal(strategy_ref, shares_asset, max_loss));
    }

    // - - - - ROUTER FUNCTIONS - - - -

    /// This function is meant to be called by the router::deposit function.
    /// When a user deposits via the router::deposit function the deposit goes to the vault increasing the vault's idle and vault shares are minted and awarded to the user
    /// The router then calls all the concrete_strategy::vault_deposit functions for all the concrete strategies connected with the vault
    /// Each concrete_strategy::vault_deposit function then calls the vault::create_debt_fa to get the portion of the newly added idle vault deposits allocated to the strategy
    /// which decreases the vault's idle holdings and increases the vault's debt by the same amount
    /// This amount is then deposited to the underlying protocol(in this case LayerBank) and the strategy shares that were minted are deposited to the satay vault
    ///
    /// @dev This function is only callable from the vault module.
    ///
    /// @param vault_signer The signer of the satay vault; required to call vault::create_debt_fa
    /// @param strategy The strategy to deposit into.
    /// @param amount The amount of base asset funds to deposit.
    public entry fun vault_deposit_fa(
        vault_signer: &signer, strategy: Object<BaseStrategy>, amount: u64
    ) acquires LayerBankStrategy {
        let strategy_ref = borrow_strategy(strategy);
        let vault = strategy_ref.vault;
        let auth_ref = &strategy_ref.auth_ref;

        // This function creates a debt of the specified amount in the vault and associates it with the strategy.
        // The asset is returned.
        // Also, this function can only be called by the vault manager or governance, otherwise transaction fails.
        let hot_asset = vault::create_debt_fa(vault_signer, vault, auth_ref, amount);
        let shares = deposit_fa_internal(strategy_ref, hot_asset);
        vault::deposit_strategy_shares(vault, strategy, shares);
    }

    /// This function is meant to be called by the router::withdraw function.
    /// When a user withdraws(a specified number of vault shares) via the router::withdraw function a vault::WithdrawalRequest is created
    /// The router attempts to satisfy as much of the request using the vault's idle assets, if there is still a remaining amount
    /// it then attempts to satisfy it with the vault's other holdings(i.e. debt) by withdrawing from the connected strategies
    /// The router calls a concrete_strategy::vault_withdraw function in a computed sequence in an attempt to satisfy the request
    /// Each concrete_strategy::vault_withdraw function then computes the amount of strategy shares that the specified amount is equal to
    /// It then attempts to withdraw those strategy shares from the satay vault and redeems those strategy shares for the base asset
    /// in accordance with the strategy's holdings(i.e. idle + debt assets) and the strategy shares are burned
    ///
    /// @param account The signer of the WithdrawalRequest.withdrawal_account
    /// @param request The WithdrawalRequest
    /// @param strategy The strategy instance that is being withdrawn from.
    /// @param amount The amount of base asset funds to withdraw.
    /// @param max_loss The max loss in the actual withdrawn with the specified amount to withdraw in BPS
    public fun vault_withdraw_fa(
        account: &signer,
        request: &mut WithdrawalRequest,
        strategy: Object<BaseStrategy>,
        amount: u64,
        max_loss: Option<u64>
    ): HotAsset acquires LayerBankStrategy {
        assert!(amount > 0, EINVALID_AMOUNT);
        let strategy_ref = borrow_strategy(strategy);

        assert!(strategy_ref.vault == vault::withdrawal_vault(request), EVAULT_MISMATCH);
        assert!(
            signer::address_of(account) == vault::withdrawal_account(request),
            EWITHDRAWAL_ACCOUNT_MISMATCH
        );

        let vault = strategy_ref.vault;

        // Disallow withdrawing more than the remaining amount
        assert!(amount <= vault::withdrawal_remaining(request), EINVALID_AMOUNT);

        // Disallow withdrawing more than the strategy debt to the vault
        // NOTE: this is a quasi-invariant as the router should never call this function that violates this assertion
        assert!(amount <= vault::strategy_debt(vault, strategy), ECANNOT_EXCEED_DEBT);

        // Convert the amount to strategy shares and withdraw those shares from the vault
        let shares_amount = base_strategy::amount_to_shares(strategy, amount);
        let shares_asset = vault::withdraw_strategy_shares(vault, &strategy_ref.auth_ref, shares_amount);
        withdraw_fa_internal(strategy_ref, shares_asset, max_loss)
    }

    // - - - - ADMIN PROXY FUNCTIONS(Also called by the router) - - - -

    public entry fun tend_fa(strategy_manager: &signer, strategy: Object<BaseStrategy>) acquires LayerBankStrategy {
        let strategy_ref = borrow_strategy(strategy);

        // we get the idle assets in the strategy and deploy it to LayerBank
        let tend_fa = base_strategy::tend_fa(strategy_manager, &strategy_ref.auth_ref);
        market_deposit_fa_internal(strategy_ref, tend_fa);
    }

    /// This function is a simple proxy function and is potentially redundant?
    ///
    /// @param vault_reporter The signer of the vault or of the protocol or of the vault manager
    /// @param strategy The strategy that is being reported in the underlying satay vault
    public entry fun vault_report(vault_reporter: &signer, strategy: Object<BaseStrategy>) acquires LayerBankStrategy {
        let strategy_ref = borrow_strategy(strategy);

        let vault = strategy_ref.vault;
        vault::report(vault_reporter, vault, strategy);
    }

    /// This function harvests any profits/losses including rewards.
    /// Rewards in the base asset are considered profits
    /// Rewards not in the base asset are deposited to the strategy's PFS and can be swept
    ///
    /// @param account This should be an account that is allowed to base_strategy::request_harvest
    /// @param strategy The strategy instance that is being harvested.
    public entry fun harvest(account: &signer, strategy: Object<BaseStrategy>) acquires LayerBankStrategy {
        let strategy_ref = borrow_strategy(strategy);
        let auth_ref = &strategy_ref.auth_ref;
        let strategy_signer = base_strategy::get_signer(auth_ref);

        let request = base_strategy::request_harvest(account, auth_ref);

        let base_metadata = base_strategy::base_metadata(strategy);

        handle_harvest_pnl(&mut request, auth_ref, strategy, base_metadata);

        // At this point the HarvestRequest is updated with the appropriate profit or loss at least looking at only the supplied asset value
        // however we need to consider any rewards earned in the base asset as a profit, which we do below:

        if (option::is_some(&strategy_ref.rewards_controller_address)) {
            let rewards_controller_address = *option::borrow(&strategy_ref.rewards_controller_address);

            if (layerbank_block::has_base_asset_rewards(base_metadata, rewards_controller_address)) {
                let base_asset_reward_amount =
                    (
                        layerbank_block::claim_base_asset_rewards(
                            &strategy_signer, base_metadata, rewards_controller_address
                        ) as u64
                    );

                if (base_asset_reward_amount > 0) {
                    base_strategy::report_harvest_profit(&mut request, auth_ref, base_asset_reward_amount);
                    let hot_asset =
                        hot_asset::new_from_account(&strategy_signer, base_metadata, base_asset_reward_amount);
                    // rewards in the base asset are auto-compounded back in
                    market_deposit_fa_internal(strategy_ref, hot_asset);
                };

                layerbank_block::claim_all_non_base_asset_rewards(
                    &strategy_signer, base_metadata, rewards_controller_address
                );
            }
        };

        // finalize profits&losses as well as the performance fee(split between the protocol and manager)
        base_strategy::complete_harvest(request);
    }

    // - - - - ADMIN FUNCTIONS - - - -

    /// Updates the rewards controller address for the strategy
    /// This function can only be called by the base strategy manager
    public entry fun set_rewards_controller_address(
        account: &signer, strategy: Object<BaseStrategy>, new_rewards_controller_address: Option<address>
    ) acquires LayerBankStrategy {
        // Check that caller is the strategy manager
        assert!(
            signer::address_of(account) == base_strategy::manager(strategy),
            ENOT_AUTHORIZED
        );

        let strategy_ref = borrow_global_mut<LayerBankStrategy>(object::object_address(&strategy));
        strategy_ref.rewards_controller_address = new_rewards_controller_address;
    }

    // - - - - ADMIN MANAGEMENT - - - -

    /// Sets the rewards pool address for the strategy.
    /// This updates where rewards should be claimed from.
    ///
    /// @param account The account updating the address.
    /// @param strategy The strategy to update.
    /// @param rewards_pool_address The new rewards pool address.
    ///
    /// @reverts ENOT_AUTHORIZED if the account is not the strategy manager.
    public entry fun set_rewards_pool_address(
        account: &signer, strategy: Object<BaseStrategy>, rewards_pool_address: Option<address>
    ) acquires RewardsPoolDetails, LayerBankStrategy {
        assert!(
            signer::address_of(account) == base_strategy::manager(strategy),
            ENOT_AUTHORIZED
        );

        // Strategies created before the multirewards package was integrated will not have a rewards pool address set.
        // In this case, we initialize the rewards pool details.
        if (!exists<RewardsPoolDetails>(object::object_address(&strategy))) {
            let strategy_ref = borrow_global_mut<LayerBankStrategy>(object::object_address(&strategy));
            initialize_reward_pool_details(strategy_ref, rewards_pool_address);
        } else {
            validate_rewards_pool_address(rewards_pool_address);
            let rewards_pool_details_ref = borrow_mut_rewards_pool_details(strategy);
            rewards_pool_details_ref.rewards_pool_address = rewards_pool_address;
        };

    }

    /// Claims all non-base asset rewards from LayerBank
    /// This function can only be called by the base strategy manager
    public entry fun claim_all_non_base_asset_rewards(
        account: &signer, strategy: Object<BaseStrategy>
    ) acquires LayerBankStrategy, RewardsPoolDetails {
        // Check that caller is the strategy manager
        assert!(
            signer::address_of(account) == base_strategy::manager(strategy),
            ENOT_AUTHORIZED
        );

        claim_all_non_base_asset_rewards_internal(strategy);
    }

    /// Notify rewards for assets in the primary store of the strategy.
    ///
    /// @param account The account claiming the rewards.
    /// @param strategy The strategy that will notify the rewards.
    ///
    /// @reverts ENOT_AUTHORIZED if the account is not the strategy manager.
    public entry fun notify_rewards(
        account: &signer, strategy: Object<BaseStrategy>, metadata: Object<Metadata>
    ) acquires LayerBankStrategy, RewardsPoolDetails {
        assert!(
            signer::address_of(account) == base_strategy::manager(strategy),
            ENOT_AUTHORIZED
        );

        notify_rewards_internal(strategy, metadata);
    }

    /// Notify all rewards for the strategy that are part of the rewards pool.
    ///
    /// @param account The account claiming the rewards.
    /// @param strategy The strategy that will notify the rewards.
    ///
    /// @reverts ENOT_AUTHORIZED if the account is not the strategy manager.
    public entry fun notify_all_rewards(
        account: &signer, strategy: Object<BaseStrategy>
    ) acquires LayerBankStrategy, RewardsPoolDetails {
        assert!(
            signer::address_of(account) == base_strategy::manager(strategy),
            ENOT_AUTHORIZED
        );

        notify_all_rewards_internal(strategy);
    }

    public entry fun perform_upkeep(strategy: Object<BaseStrategy>) acquires LayerBankStrategy, RewardsPoolDetails {
        assert!(check_upkeep(strategy), EUPKEEP_NOT_READY);

        claim_all_non_base_asset_rewards_internal(strategy);
        notify_all_rewards_internal(strategy);

        let rewards_pool_details_ref = borrow_mut_rewards_pool_details(strategy);
        rewards_pool_details_ref.last_upkeep_timestamp = timestamp::now_seconds();
    }

    /// Sets the upkeep interval for the strategy.
    /// This updates how often the upkeep can be performed.
    ///
    /// @param account The account updating the interval.
    /// @param strategy The strategy to update.
    /// @param upkeep_interval The new upkeep interval.
    ///
    /// @reverts ENOT_AUTHORIZED if the account is not the strategy manager.
    public entry fun set_upkeep_interval(
        account: &signer, strategy: Object<BaseStrategy>, upkeep_interval: u64
    ) acquires RewardsPoolDetails {
        assert!(
            upkeep_interval >= MIN_UPKEEP_INTERVAL && upkeep_interval <= MAX_UPKEEP_INTERVAL,
            EINVALID_UPKEEP_INTERVAL
        );
        assert!(
            signer::address_of(account) == base_strategy::manager(strategy),
            ENOT_AUTHORIZED
        );

        let rewards_pool_details_ref = borrow_mut_rewards_pool_details(strategy);
        rewards_pool_details_ref.upkeep_interval = upkeep_interval;
    }

    // - - - - VIEW FUNCTIONS - - - -

    #[view]
    public fun get_base_asset(strategy: Object<BaseStrategy>): Object<Metadata> acquires LayerBankStrategy {
        let strategy_ref = borrow_strategy(strategy);
        vault::base_metadata(strategy_ref.vault)
    }

    #[view]
    public fun get_rewards_controller_address(strategy: Object<BaseStrategy>): Option<address> acquires LayerBankStrategy {
        let strategy_ref = borrow_strategy(strategy);
        strategy_ref.rewards_controller_address
    }

    #[view]
    /// Gets the rewards pool address for the strategy.
    ///
    /// @param strategy The strategy to get the address for.
    ///
    /// @return The optional rewards pool address.
    public fun rewards_pool_address(strategy: Object<BaseStrategy>): Option<address> acquires RewardsPoolDetails {
        let rewards_pool_details_ref = borrow_rewards_pool_details(strategy);
        rewards_pool_details_ref.rewards_pool_address
    }

    #[view]
    public fun get_last_upkeep_timestamp(strategy: Object<BaseStrategy>): u64 acquires RewardsPoolDetails {
        let rewards_pool_details_ref = borrow_rewards_pool_details(strategy);
        rewards_pool_details_ref.last_upkeep_timestamp
    }

    #[view]
    public fun check_upkeep(strategy: Object<BaseStrategy>): bool acquires RewardsPoolDetails {
        let rewards_pool_details_ref = borrow_rewards_pool_details(strategy);
        let current_timestamp = timestamp::now_seconds();
        current_timestamp - rewards_pool_details_ref.last_upkeep_timestamp > rewards_pool_details_ref.upkeep_interval
    }

    // - - - - INTERNAL FUNCTIONS - - - -

    /// Internal function to handle deposits
    fun deposit_fa_internal(strategy: &LayerBankStrategy, base_asset: HotAsset): HotAsset {
        let strategy_shares = base_strategy::mint_debt_shares_fa(&base_asset, &strategy.auth_ref);
        market_deposit_fa_internal(strategy, base_asset);
        strategy_shares
    }

    /// Internal function to handle market deposits
    fun market_deposit_fa_internal(strategy: &LayerBankStrategy, hot_asset: HotAsset) {
        let strategy_signer = &base_strategy::get_signer(&strategy.auth_ref);
        let strategy_address = object::object_address(&base_strategy::auth_ref_strategy(&strategy.auth_ref));

        layerbank_block::supply(
            strategy_signer,
            hot_asset,
            strategy_address, // Strategy receives the aTokens
            0 // referral_code is 0
        );
    }

    fun withdraw_fa_internal(
        strategy_ref: &LayerBankStrategy, strategy_shares_asset: HotAsset, max_loss: Option<u64>
    ): HotAsset {
        let request = base_strategy::request_withdrawal(strategy_shares_asset, &strategy_ref.auth_ref);
        // NOTE: we first attempt to withdraw as much as possible from the strategy's idle assets
        // in order to fulfill the WithdrawalRequest
        base_strategy::withdraw(&mut request);

        // If we still have remaining amount to withdraw after using idle assets,
        // then we withdraw the rest from LayerBank/Aave
        if (base_strategy::withdrawal_remaining(&request) > 0) {
            let base_amount_needed = base_strategy::withdrawal_remaining(&request);
            let base_fa_withdrawn = market_withdraw_fa_internal(strategy_ref, base_amount_needed);
            base_strategy::apply_fa_withdrawal(&mut request, base_fa_withdrawn);
        };

        // NOTE: complete_withdrawal returns the base_asset FungibleAsset that was accumulated to the WithdrawalRequest.withdrawn
        base_strategy::complete_withdrawal(request, max_loss)
    }

    fun market_withdraw_fa_internal(strategy_ref: &LayerBankStrategy, amount: u64): HotAsset {
        let strategy_signer = base_strategy::get_signer(&strategy_ref.auth_ref);

        // we withdraw the requested amount of the base asset from layerbank
        layerbank_block::withdraw(
            &strategy_signer, // since the supplied assets are registered under the strategy's address in LayerBank
            object::object_address(&vault::base_metadata(strategy_ref.vault)),
            amount
        )
    }

    fun claim_all_non_base_asset_rewards_internal(strategy: Object<BaseStrategy>) acquires LayerBankStrategy, RewardsPoolDetails {

        let strategy_ref = borrow_strategy(strategy);
        let pool_details_ref = borrow_rewards_pool_details(strategy);

        let strategy_signer = base_strategy::get_signer(&strategy_ref.auth_ref);
        let base_metadata = vault::base_metadata(strategy_ref.vault);

        // Only claim if we have a rewards controller set
        if (option::is_some(&strategy_ref.rewards_controller_address)) {
            let strategy_signer = base_strategy::get_signer(&strategy_ref.auth_ref);
            layerbank_block::claim_all_non_base_asset_rewards(
                &strategy_signer,
                base_metadata,
                *option::borrow(&strategy_ref.rewards_controller_address)
            );
            // NOTE: the non base asset rewards can then be fetched by calling base_strategy::sweep
        };
    }

    fun notify_rewards_internal(
        strategy: Object<BaseStrategy>, metadata: Object<Metadata>
    ) acquires LayerBankStrategy, RewardsPoolDetails {
        let strategy_ref = borrow_strategy(strategy);
        let strategy_signer = &base_strategy::get_signer(&strategy_ref.auth_ref);

        let base_metadata = base_strategy::base_metadata(strategy);
        if (metadata != base_metadata) {
            let reward_amount = primary_store_balance(object::object_address(&strategy), metadata);
            notify_reward_amount_internal(strategy_signer, strategy, metadata, reward_amount);
        };
    }

    fun notify_all_rewards_internal(strategy: Object<BaseStrategy>) acquires LayerBankStrategy, RewardsPoolDetails {
        let strategy_ref = borrow_strategy(strategy);
        let metadata =
            layerbank_block::get_rewards_by_asset(
                vault::base_metadata(strategy_ref.vault),
                *option::borrow(&strategy_ref.rewards_controller_address)
            );
        for (i in 0..vector::length(&metadata)) {
            let staking_pool = get_staking_pool(strategy);

            let (_staking_token, reward_tokens, _total_subscribed) = multi_rewards::get_pool_info(staking_pool);
            let metadata_address = object::address_to_object<Metadata>(*vector::borrow(&metadata, i));

            if (vector::contains(&reward_tokens, &metadata_address)) {
                notify_rewards_internal(
                    strategy,
                    metadata_address
                );
            };
        };
    }

    fun notify_reward_amount_internal(
        strategy_signer: &signer,
        strategy: Object<BaseStrategy>,
        reward_metadata: Object<Metadata>,
        reward_amount: u64
    ) acquires RewardsPoolDetails {
        let rewards_pool_address = rewards_pool_address(strategy);
        if (option::is_some(&rewards_pool_address)) {
            let staking_pool = get_staking_pool(strategy);
            multi_rewards::notify_reward_amount(strategy_signer, staking_pool, reward_metadata, reward_amount);
        }
    }

    fun get_staking_pool(strategy: Object<BaseStrategy>): Object<StakingPool> acquires RewardsPoolDetails {
        let rewards_pool_address = rewards_pool_address(strategy);
        assert!(option::is_some(&rewards_pool_address), ENO_REWARDS_POOL_ADDRESS);
        object::address_to_object<StakingPool>(option::destroy_some(rewards_pool_address))
    }

    inline fun borrow_rewards_pool_details(strategy: Object<BaseStrategy>): &RewardsPoolDetails {
        borrow_global<RewardsPoolDetails>(object::object_address(&strategy))
    }

    inline fun borrow_mut_rewards_pool_details(strategy: Object<BaseStrategy>): &mut RewardsPoolDetails {
        borrow_global_mut<RewardsPoolDetails>(object::object_address(&strategy))
    }

    fun handle_harvest_pnl(
        request: &mut HarvestRequest,
        auth_ref: &AuthRef,
        strategy: Object<BaseStrategy>,
        base_metadata: Object<Metadata>
    ) {
        // this is the last recorded value of the strategy's holdings
        let total_debt = base_strategy::total_debt(strategy);
        let strategy_address = object::object_address(&strategy);

        // this is the latest(i.e. now) base asset value of the strategy in the underlying Layerbank market
        let latest_supplied_amount =
            (
                layerbank_block::get_user_supply_with_interest(
                    strategy_address, object::object_address(&base_metadata)
                ) as u64
            );

        // we report a profit or loss accordingly based on the latest value vs the last recorded debt value(i.e. the last base asset amount deployed)
        if (latest_supplied_amount > total_debt) {
            let profit = latest_supplied_amount - total_debt;
            base_strategy::report_harvest_profit(request, auth_ref, profit);
        } else if (latest_supplied_amount < total_debt) {
            let loss = total_debt - latest_supplied_amount;
            base_strategy::report_harvest_loss(request, auth_ref, loss);
        }
    }

    fun ensure_fee_recipient(account: &signer, strategy: Object<BaseStrategy>) {
        let account_address = signer::address_of(account);

        let manager = base_strategy::manager(strategy);
        let protocol_fee_recipient = protocol::get_protocol_fee_recipient();
        assert!(
            account_address == manager || account_address == protocol_fee_recipient,
            EINVALID_FEE_RECIPIENT
        );
    }

    /// Internal helper to borrow strategy reference
    inline fun borrow_strategy(strategy: Object<BaseStrategy>): &LayerBankStrategy {
        borrow_global<LayerBankStrategy>(object::object_address(&strategy))
    }

    // - - - - EVENTS - - - -

    #[event]
    struct StrategyCreated has drop, store {
        vault: Object<Vault>,
        strategy: Object<BaseStrategy>,
        rewards_controller_address: Option<address>
    }

    // - - - - TEST_ONLY - - - -

    #[test_only]
    public fun create_for_test(
        account: &signer,
        vault: Object<Vault>,
        debt_limit: u64,
        rewards_controller_address: Option<address>
    ): Object<BaseStrategy> {
        create(account, vault, debt_limit, rewards_controller_address);

        let events = event::emitted_events<StrategyCreated>();
        vector::pop_back(&mut events).strategy
    }

    #[test_only]
    public fun get_most_recent_strategy(): (Option<Object<BaseStrategy>>, Option<address>) {
        let events = event::emitted_events<StrategyCreated>();
        if (vector::length(&events) == 0) {
            return (option::none(), option::none());
        };
        let last_event = vector::pop_back(&mut events);
        (option::some(last_event.strategy), last_event.rewards_controller_address)
    }
}

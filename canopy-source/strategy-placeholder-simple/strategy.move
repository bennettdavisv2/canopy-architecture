/// Placeholder Strategy
/// 
/// This is a temporary strategy designed to hold deposited funds used to manage users deposited assets 
/// while the main strategies are still being developed.
module placeholder_simple::strategy {
    use std::signer;
    use std::option::Option;

    use aptos_framework::event::emit;
    use aptos_framework::object::{Self, Object};
    use aptos_framework::primary_fungible_store::balance as primary_store_balance;

    use satay::base_strategy::{Self, AuthRef, BaseStrategy};
    use satay::hot_asset::{Self, HotAsset};
    use satay::hot_coin::{Self, HotCoin};
    use satay::protocol;
    use satay::vault::{Self, Vault, WithdrawalRequest};

    use placeholder_block::placeholder_block;

    #[test_only]
    friend placeholder_simple::strategy_tests;

    #[test_only]
    use std::vector;
    #[test_only]
    use aptos_framework::event;

    struct Witness has drop {}

    struct PlaceholderStrategy has key {
        auth_ref: AuthRef,
        vault: Object<Vault>
    }

    #[event]
    struct StrategyCreated has drop, store {
        vault: Object<Vault>,
        strategy: Object<BaseStrategy>
    }

    /// Not authorized to perform the operation.
    const ENOT_AUTHORIZED: u64 = 0;
    /// Invalid amount specified.
    const EINVALID_AMOUNT: u64 = 1;
    /// Insufficient balance to perform the operation.
    const EINSUFFICIENT_BALANCE: u64 = 2;
    /// Invalid vault specified.
    const EVAULT_MISMATCH: u64 = 3;
    /// Invalid withdrawal account specified.
    const EWITHDRAWAL_ACCOUNT_MISMATCH: u64 = 4;
    /// Cannot exceed the strategy debt.
    const ECANNOT_EXCEED_DEBT: u64 = 5;
    /// Invalid fee recipient
    const EINVALID_FEE_RECIPIENT: u64 = 6;
    /// Could not complete withdrawal
    const ECOULD_NOT_COMPLETE_WITHDRAWAL: u64 = 7;

    /// Creates a new instance of the strategy.
    ///
    /// @param account The account that is creating the strategy.
    /// @param vault The vault to be used by the strategy.
    public entry fun create(account: &signer, vault: Object<Vault>, debt_limit: u64) {
        let auth_ref = base_strategy::create(account, vault::base_metadata(vault), Witness {});
        let base_strategy = base_strategy::auth_ref_strategy(&auth_ref);

        // This will only work if the `account` is the governance account.
        // Otherwise, the transaction will fail.
        vault::add_strategy(account, vault, base_strategy, debt_limit);

        let strategy_signer = base_strategy::get_signer(&auth_ref);

        move_to(&strategy_signer, PlaceholderStrategy { vault, auth_ref });
        emit(StrategyCreated { vault, strategy: base_strategy });
    }

    /// Deposits fungible assets into the strategy.
    /// The asset metadata has to match the strategy's base metadata and must also match the metadata \
    /// corresponding `paired_metadata` of the specified `CoinType`.
    ///
    /// @param account The account that is depositing the funds.
    /// @param strategy The strategy to deposit into.
    /// @param amount The amount of funds to deposit.
    ///
    /// @reverts EINVALID_AMOUNT if the amount is zero.
    public(friend) fun deposit_fa(account: &signer, strategy: Object<BaseStrategy>, amount: u64) acquires PlaceholderStrategy {
        assert!(amount > 0, EINVALID_AMOUNT);

        let base_metadata = base_strategy::base_metadata(strategy);
        // create a hot asset for deposit, this sets the owner to the account of the user depositing
        let hot_asset = hot_asset::new_from_account(account, base_metadata, amount);

        let strategy_ref = borrow_strategy(strategy);
        // dispatch shares to the user, this ensures that the user always receive the shares
        hot_asset::dispatch(base_strategy::deposit(hot_asset, &strategy_ref.auth_ref));
    }

    /// Deposits coins into the strategy.
    /// The CoinType's `paired_metadata` has to match the strategy's base metadata.
    ///
    /// @param account The account that is depositing the funds.
    /// @param strategy The strategy to deposit into.
    /// @param amount The amount of base asset to deposit.
    ///
    /// @reverts EINVALID_AMOUNT if the amount is zero.
    public(friend) fun deposit_coin<CoinType>(
        account: &signer, strategy: Object<BaseStrategy>, amount: u64
    ) acquires PlaceholderStrategy {
        assert!(amount > 0, EINVALID_AMOUNT);

        let strategy_ref = borrow_strategy(strategy);
        let hot_coin = hot_coin::new_from_account<CoinType>(account, amount);
        hot_asset::dispatch(base_strategy::deposit(hot_coin::into_asset(hot_coin), &strategy_ref.auth_ref));
    }

    /// Deposits funds from the vault associated with the strategy into the strategy.
    ///
    /// @param account The account that is depositing the funds.
    /// @param strategy The strategy to deposit into.
    /// @param amount The amount of base asset to deposit.
    ///
    /// @reverts EINVALID_AMOUNT if the amount is zero.
    public entry fun vault_deposit_coin<CoinType>(
        account: &signer, strategy: Object<BaseStrategy>, amount: u64
    ) acquires PlaceholderStrategy {
        let strategy_ref = borrow_strategy(strategy);
        let vault = strategy_ref.vault;
        let auth_ref = &strategy_ref.auth_ref;

        // This function creates a debt of the specified amount in the vault and associates it with the strategy.
        // The asset is returned.
        // Also, this function can only be called by the vault manager or governance, otherwise transaction fails.
        let deposit_coin = vault::create_debt_coin<CoinType>(account, vault, auth_ref, amount);
        let shares = base_strategy::deposit(hot_coin::into_asset(deposit_coin), auth_ref);
        vault::deposit_strategy_shares(vault, strategy, shares);
    }

    /// Deposits funds from the vault associated with the strategy into the strategy.
    ///
    /// @param account The account that is depositing the funds.
    /// @param strategy The strategy to deposit into.
    /// @param amount The amount of base asset to deposit.
    ///
    /// @reverts EINVALID_AMOUNT if the amount is zero.
    public entry fun vault_deposit_fa(
        account: &signer, strategy: Object<BaseStrategy>, amount: u64
    ) acquires PlaceholderStrategy {
        let strategy_ref = borrow_strategy(strategy);
        let vault = strategy_ref.vault;
        let auth_ref = &strategy_ref.auth_ref;

        // This function creates a debt of the specified amount in the vault and associates it with the strategy.
        // The asset is returned.
        // Also, this function can only be called by the vault manager or governance, otherwise transaction fails.
        let hot_asset = vault::create_debt_fa(account, vault, auth_ref, amount);
        let shares = base_strategy::deposit(hot_asset, auth_ref);
        vault::deposit_strategy_shares(vault, strategy, shares);
    }

    /// Withdraws funds from the strategy.
    /// This withdraws the specified amount of strategy shares and redeems them for the strategy's base asset.
    ///
    /// @param account The account that is withdrawing the funds.
    /// @param strategy The strategy to withdraw from.
    /// @param amount The amount of strategy shares to withdraw.
    /// @param max_loss The maximum amount of loss to take.
    ///
    /// @reverts EINVALID_AMOUNT if the amount is zero.
    public entry fun withdraw_fa(
        account: &signer,
        strategy: Object<BaseStrategy>,
        amount: u64,
        max_loss: Option<u64>
    ) acquires PlaceholderStrategy {
        ensure_fee_recipient(account, strategy);

        assert!(amount > 0, EINVALID_AMOUNT);
        let shares_metadata = base_strategy::shares_metadata(strategy);

        let strategy_ref = borrow_strategy(strategy);
        let shares_asset = hot_asset::new_from_account(account, shares_metadata, amount);
        hot_asset::dispatch(withdraw_fa_internal(strategy_ref, shares_asset, max_loss));
    }

    /// Withdraws funds from the strategy.
    /// This withdraws the specified amount of strategy shares and redeems them for the strategy's base asset and then converts it to CoinType.
    ///
    /// @param account The account that is withdrawing the funds.
    /// @param strategy The strategy to withdraw from.
    /// @param amount The amount of strategy shares to withdraw.
    /// @param max_loss The maximum amount of loss to take.
    ///
    /// @reverts EINVALID_AMOUNT if the amount is zero.
    public entry fun withdraw_coin<CoinType>(
        account: &signer,
        strategy: Object<BaseStrategy>,
        amount: u64,
        max_loss: Option<u64>
    ) acquires PlaceholderStrategy {
        ensure_fee_recipient(account, strategy);

        assert!(amount > 0, EINVALID_AMOUNT);
        let shares_metadata = base_strategy::shares_metadata(strategy);

        let strategy_ref = borrow_strategy(strategy);
        let shares_asset = hot_asset::new_from_account(account, shares_metadata, amount);
        hot_coin::dispatch(withdraw_coin_internal<CoinType>(strategy_ref, shares_asset, max_loss));
    }

    /// Withdraws funds from the strategy.
    /// This withdraws the specified amount of base asset from the strategy.account
    ///
    /// @param account The account that is withdrawing the funds.
    /// @param request The withdrawal request.
    /// @param strategy The strategy to withdraw from.
    /// @param amount The amount of base asset to withdraw.
    /// @param max_loss The maximum amount of loss to take.
    ///
    /// @reverts EINVALID_AMOUNT if the amount is zero.
    /// @reverts EVAULT_MISMATCH if the vault does not match the withdrawal request.
    /// @reverts EWITHDRAWAL_ACCOUNT_MISMATCH if the account does not match the withdrawal request.
    public fun vault_withdraw_coin<CoinType>(
        account: &signer,
        request: &mut WithdrawalRequest,
        strategy: Object<BaseStrategy>,
        amount: u64,
        max_loss: Option<u64>
    ): HotCoin<CoinType> acquires PlaceholderStrategy {
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
        assert!(amount <= vault::strategy_debt(vault, strategy), ECANNOT_EXCEED_DEBT);

        // Convert the amount to strategy shares and withdraw it
        let shares_amount = base_strategy::amount_to_shares(strategy, amount);
        let shares_asset = vault::withdraw_strategy_shares(vault, &strategy_ref.auth_ref, shares_amount);
        withdraw_coin_internal<CoinType>(strategy_ref, shares_asset, max_loss)
    }

    /// Withdraws funds from the strategy.
    /// This withdraws the specified amount of base asset from the strategy and converts it to a hot asset.
    ///
    /// @param account The account that is withdrawing the funds.
    /// @param request The withdrawal request.
    /// @param strategy The strategy to withdraw from.
    /// @param amount The amount of base asset to withdraw.
    /// @param max_loss The maximum amount of loss to take.
    ///
    /// @reverts EINVALID_AMOUNT if the amount is zero.
    /// @reverts EVAULT_MISMATCH if the vault does not match the withdrawal request.
    /// @reverts EWITHDRAWAL_ACCOUNT_MISMATCH if the account does not match the withdrawal request.
    public fun vault_withdraw_fa(
        account: &signer,
        request: &mut WithdrawalRequest,
        strategy: Object<BaseStrategy>,
        amount: u64,
        max_loss: Option<u64>
    ): HotAsset acquires PlaceholderStrategy {
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

        // Disallow withdrawing more than the strategy debt to the vault
        assert!(amount <= vault::strategy_debt(vault, strategy), ECANNOT_EXCEED_DEBT);

        // Convert the amount to strategy shares and withdraw it
        let shares_amount = base_strategy::amount_to_shares(strategy, amount);
        let shares_asset = vault::withdraw_strategy_shares(vault, &strategy_ref.auth_ref, shares_amount);
        withdraw_fa_internal(strategy_ref, shares_asset, max_loss)
    }

    /// Recalls assets from the strategy.
    /// This withdraws all strategy shares from the associated vault and redeems them for the strategy's base asset and deposits them into the vault.
    ///
    /// @param account The account that is recalling the assets.
    /// @param strategy The strategy to recall assets from.
    /// @param max_loss The maximum amount of loss to take.
    ///
    /// @reverts ENOT_AUTHORIZED if the account is not the manager of the strategy.
    public entry fun unlink_from_vault(account: &signer, strategy: Object<BaseStrategy>, max_loss: Option<u64>) acquires PlaceholderStrategy {
        let account_address = signer::address_of(account);
        assert!(account_address == base_strategy::manager(strategy) || protocol::is_governance(account_address), ENOT_AUTHORIZED);

        let strategy_ref = borrow_strategy(strategy);
        let shares_metadata = base_strategy::shares_metadata(strategy);
        let shares_amount = primary_store_balance(object::object_address(&strategy_ref.vault), shares_metadata);

        let shares_asset = vault::withdraw_strategy_shares(strategy_ref.vault, &strategy_ref.auth_ref, shares_amount);
        let withdrawn_asset = withdraw_fa_internal(strategy_ref, shares_asset, max_loss);
        placeholder_block::deposit_to_vault(strategy_ref.vault, withdrawn_asset);

        vault::remove_strategy(account, strategy_ref.vault, strategy, true);
        vault::rebalance_idle(account, strategy_ref.vault);
    }

    /// Reports the strategy to the vault.
    ///
    /// @param account The account that is reporting the strategy.
    /// @param strategy The strategy to report.
    public entry fun vault_report<CoinType>(account: &signer, strategy: Object<BaseStrategy>) acquires PlaceholderStrategy {
        let strategy_ref = borrow_strategy(strategy);
        vault::report(account, strategy_ref.vault, strategy);
    }

    inline fun borrow_strategy(strategy: Object<BaseStrategy>): &PlaceholderStrategy {
        borrow_global<PlaceholderStrategy>(object::object_address(&strategy))
    }

    fun strategy_withdraw_coin_internal<CoinType>(strategy: &PlaceholderStrategy, amount: u64): HotCoin<CoinType> {
        let base_strategy = base_strategy::auth_ref_strategy(&strategy.auth_ref);
        assert!(base_strategy::total_idle(base_strategy) >= amount, EINSUFFICIENT_BALANCE);

        let strategy_signer = base_strategy::get_signer(&strategy.auth_ref);
        placeholder_block::withdraw<CoinType>(&strategy_signer, base_strategy, amount)
    }

    fun strategy_withdraw_fa_internal(strategy: &PlaceholderStrategy, amount: u64): HotAsset {
        let base_strategy = base_strategy::auth_ref_strategy(&strategy.auth_ref);
        assert!(base_strategy::total_idle(base_strategy) >= amount, EINSUFFICIENT_BALANCE);

        let strategy_signer = base_strategy::get_signer(&strategy.auth_ref);
        placeholder_block::withdraw_fa(&strategy_signer, base_strategy, amount)
    }

    fun withdraw_fa_internal(
        strategy_ref: &PlaceholderStrategy, shares_hot_asset: HotAsset, max_loss: Option<u64>
    ): HotAsset {
        let request = base_strategy::request_withdrawal(shares_hot_asset, &strategy_ref.auth_ref);
        base_strategy::withdraw(&mut request);

        assert!(base_strategy::withdrawal_remaining(&request) == 0, ECOULD_NOT_COMPLETE_WITHDRAWAL);
        base_strategy::complete_withdrawal(request, max_loss)
    }

    fun withdraw_coin_internal<CoinType>(
        strategy_ref: &PlaceholderStrategy, shares_hot_asset: HotAsset, max_loss: Option<u64>
    ): HotCoin<CoinType> {
        let request = base_strategy::request_withdrawal(shares_hot_asset, &strategy_ref.auth_ref);
        base_strategy::withdraw(&mut request);

        assert!(base_strategy::withdrawal_remaining(&request) == 0, ECOULD_NOT_COMPLETE_WITHDRAWAL);
        base_strategy::complete_withdrawal_coin<CoinType>(request, max_loss)
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

    #[test_only]
    public fun create_for_test(account: &signer, vault: Object<Vault>, debt_limit: u64): Object<BaseStrategy> {
        create(account, vault, debt_limit);

        let events = event::emitted_events<StrategyCreated>();
        vector::pop_back(&mut events).strategy
    }
}

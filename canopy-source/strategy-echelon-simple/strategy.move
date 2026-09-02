module echelon_simple::strategy {
    use std::option::{Self, Option};
    use std::signer;
    use std::string::String;
    use std::vector;
    use aptos_std::math64;
    use aptos_std::type_info;

    use aptos_framework::coin;
    use aptos_framework::event::emit;
    use aptos_framework::fungible_asset::Metadata;
    use aptos_framework::object::{Self, Object};
    use aptos_framework::primary_fungible_store::balance as primary_store_balance;
    use aptos_framework::timestamp;

    use echelon_block::echelon_block;
    use lending::lending::Market;
    use satay::base_strategy::{Self, AuthRef, BaseStrategy, HarvestRequest};
    use satay::hot_asset::{Self, HotAsset};
    use satay::hot_coin::{Self, HotCoin};
    use satay::protocol;
    use satay::vault::{Self, Vault, WithdrawalRequest};

    use canopy_staking::multi_rewards::{Self, StakingPool};
    use canopy_staking::router as multi_rewards_router;

    #[test_only]
    use aptos_framework::event;

    #[test_only]
    friend echelon_simple::strategy_tests;

    struct Witness has drop {}

    struct EchelonStrategy has key {
        auth_ref: AuthRef,
        vault: Object<Vault>,
        market: Object<Market>,
        reward_assets: RewardAssets
    }

    struct RewardAssets has store {
        coin_types: vector<String>,
        fa_metadatas: vector<Object<Metadata>>
    }

    struct RewardsPoolDetails has key {
        rewards_pool_address: Option<address>,
        last_upkeep_timestamp: u64,
        upkeep_interval: u64
    }

    #[event]
    struct StrategyCreated has drop, store {
        vault: Object<Vault>,
        market: Object<Market>,
        strategy: Object<BaseStrategy>
    }

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
    /// Reward already added
    const EREWARD_ALREADY_ADDED: u64 = 9;
    /// Too many rewards
    const ETOO_MANY_REWARDS: u64 = 10;
    /// Invalid fee recipient
    const EINVALID_FEE_RECIPIENT: u64 = 11;
    /// No rewards pool address set.
    const ENO_REWARDS_POOL_ADDRESS: u64 = 12;
    /// Upkeep not ready.
    const EUPKEEP_NOT_READY: u64 = 13;
    /// Invalid rewards pool address.
    const EINVALID_REWARDS_POOL_ADDRESS: u64 = 14;
    /// Invalid upkeep interval.
    const EINVALID_UPKEEP_INTERVAL: u64 = 15;

    const MAX_REWARDS_LENGTH: u64 = 10;
    const DEFAULT_UPKEEP_INTERVAL: u64 = 60 * 60 * 24; // 1 day
    const MIN_UPKEEP_INTERVAL: u64 = 60 * 60; // 1 hour
    const MAX_UPKEEP_INTERVAL: u64 = 60 * 60 * 24 * 7; // 7 days

    /// Creates a new instance of the strategy.
    ///
    /// @param account The account that is creating the strategy.
    /// @param vault The vault to be used by the strategy.
    /// @param market The market to be used by the strategy.
    /// @param debt_limit The maximum amount of debt that can be borrowed by the strategy.
    public entry fun create(
        account: &signer,
        vault: Object<Vault>,
        market: Object<Market>,
        debt_limit: u64
    ) {
        let auth_ref = base_strategy::create(account, vault::base_metadata(vault), Witness {});
        let base_strategy = base_strategy::auth_ref_strategy(&auth_ref);

        // This will only work if the `account` is the governance account.
        // Otherwise, the transaction will fail.
        vault::add_strategy(account, vault, base_strategy, debt_limit);

        let strategy_signer = base_strategy::get_signer(&auth_ref);
        let reward_assets = RewardAssets {
            coin_types: vector::empty(),
            fa_metadatas: vector::empty()
        };

        let strategy = EchelonStrategy { vault, market, auth_ref, reward_assets };
        initialize_reward_pool_details(&strategy, option::none());

        move_to(&strategy_signer, strategy);
        emit(StrategyCreated { vault, market, strategy: base_strategy });
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
    /// @reverts EINSUFFICIENT_BALANCE if the account does not have enough balance to deposit.
    public(friend) fun deposit_fa(account: &signer, strategy: Object<BaseStrategy>, amount: u64) acquires EchelonStrategy {
        assert!(amount > 0, EINVALID_AMOUNT);
        let account_address = signer::address_of(account);
        let base_metadata = base_strategy::base_metadata(strategy);
        assert!(
            primary_store_balance(account_address, base_metadata) >= amount,
            EINSUFFICIENT_BALANCE
        );

        // create a hot asset for deposit, this sets the owner to the account of the user depositing
        let hot_asset = hot_asset::new_from_account(account, base_metadata, amount);

        let strategy_ref = borrow_strategy(strategy);
        let shares = deposit_fa_internal(strategy_ref, hot_asset);

        // dispatch shares to the user, this ensures that the user always receive the shares
        hot_asset::dispatch(shares);
    }

    /// Deposits coins into the strategy.
    /// The CoinType's `paired_metadata` has to match the strategy's base metadata.
    ///
    /// @param account The account that is depositing the funds.
    /// @param strategy The strategy to deposit into.
    /// @param amount The amount of funds to deposit.
    ///
    /// @reverts EINVALID_AMOUNT if the amount is zero.
    /// @reverts EINSUFFICIENT_BALANCE if the account does not have enough balance to deposit.
    public(friend) fun deposit_coin<CoinType>(
        account: &signer, strategy: Object<BaseStrategy>, amount: u64
    ) acquires EchelonStrategy {
        assert!(amount > 0, EINVALID_AMOUNT);

        let account_address = signer::address_of(account);
        assert!(coin::balance<CoinType>(account_address) >= amount, EINSUFFICIENT_BALANCE);

        let strategy_ref = borrow_strategy(strategy);
        let hot_coin = hot_coin::new_from_account<CoinType>(account, amount);
        let shares = deposit_coin_internal(strategy_ref, hot_coin);
        hot_asset::dispatch(shares);
    }

    /// Deposits funds from the vault associated with the strategy into the strategy.
    ///
    /// @dev This function is only callable from the vault module.
    /// @param account The account that is depositing the funds.
    /// @param strategy The strategy to deposit into.
    /// @param amount The amount of funds to deposit.
    ///
    public entry fun vault_deposit_coin<CoinType>(
        account: &signer, strategy: Object<BaseStrategy>, amount: u64
    ) acquires EchelonStrategy {
        let strategy_ref = borrow_strategy(strategy);
        let vault = strategy_ref.vault;
        let auth_ref = &strategy_ref.auth_ref;

        // This function creates a debt of the specified amount in the vault and associates it with the strategy.
        // The asset is returned.
        // Also, this function can only be called by the vault manager or governance, otherwise transaction fails.
        let deposit_coin = vault::create_debt_coin<CoinType>(account, vault, auth_ref, amount);
        let shares = deposit_coin_internal(strategy_ref, deposit_coin);
        vault::deposit_strategy_shares(vault, strategy, shares);
    }

    public entry fun vault_deposit_fa(
        account: &signer, strategy: Object<BaseStrategy>, amount: u64
    ) acquires EchelonStrategy {
        let strategy_ref = borrow_strategy(strategy);
        let vault = strategy_ref.vault;
        let auth_ref = &strategy_ref.auth_ref;

        // This function creates a debt of the specified amount in the vault and associates it with the strategy.
        // The asset is returned.
        // Also, this function can only be called by the vault manager or governance, otherwise transaction fails.
        let hot_asset = vault::create_debt_fa(account, vault, auth_ref, amount);
        let shares = deposit_fa_internal(strategy_ref, hot_asset);
        vault::deposit_strategy_shares(vault, strategy, shares);
    }

    /// Withdraws funds from the strategy.
    /// This withdraws the specified amount of strategy shares and redeems them for the strategy's base asset.
    ///
    /// @param account The account that is withdrawing the funds.
    /// @param strategy The strategy to withdraw from.
    /// @param amount The amount of funds to withdraw.
    /// @param max_loss The maximum amount of loss to take.
    ///
    /// @reverts EINVALID_AMOUNT if the amount is zero.
    /// @reverts EINSUFFICIENT_BALANCE if the account does not have enough balance to withdraw.
    public entry fun withdraw_fa(
        account: &signer,
        strategy: Object<BaseStrategy>,
        amount: u64,
        max_loss: Option<u64>
    ) acquires EchelonStrategy {
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
        amount: u64,
        max_loss: Option<u64>
    ) acquires EchelonStrategy {
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
        hot_coin::dispatch(withdraw_coin_internal<CoinType>(strategy_ref, shares_asset, max_loss));
    }

    public fun vault_withdraw_coin<CoinType>(
        account: &signer,
        request: &mut WithdrawalRequest,
        strategy: Object<BaseStrategy>,
        amount: u64,
        max_loss: Option<u64>
    ): HotCoin<CoinType> acquires EchelonStrategy {
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

    public fun vault_withdraw_fa(
        account: &signer,
        request: &mut WithdrawalRequest,
        strategy: Object<BaseStrategy>,
        amount: u64,
        max_loss: Option<u64>
    ): HotAsset acquires EchelonStrategy {
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
        withdraw_fa_internal(strategy_ref, shares_asset, max_loss)
    }

    public entry fun tend_coin<CoinType>(account: &signer, strategy: Object<BaseStrategy>) acquires EchelonStrategy {
        let strategy_ref = borrow_strategy(strategy);
        let tend_coin = base_strategy::tend_coin<CoinType>(account, &strategy_ref.auth_ref);
        market_deposit_coin_internal(strategy_ref, tend_coin);
    }

    public entry fun tend_fa(account: &signer, strategy: Object<BaseStrategy>) acquires EchelonStrategy {
        let strategy_ref = borrow_strategy(strategy);
        let tend_fa = base_strategy::tend_fa(account, &strategy_ref.auth_ref);
        market_deposit_fa_internal(strategy_ref, tend_fa);
    }

    public entry fun harvest<CoinType>(account: &signer, strategy: Object<BaseStrategy>) acquires EchelonStrategy {
        let strategy_ref = borrow_strategy(strategy);
        let auth_ref = &strategy_ref.auth_ref;

        let request = base_strategy::request_harvest(account, &strategy_ref.auth_ref);
        handle_harvest_pnl(&mut request, auth_ref, strategy_ref.market);

        // Claims all rewards associated with the strategy if any; and returns the base asset rewards if any.
        let base_rewards_maybe = claim_coin_rewards_internal<CoinType>(strategy_ref, auth_ref);
        if (option::is_some(&base_rewards_maybe)) {
            let reward = option::destroy_some(base_rewards_maybe);
            let reward_amount = hot_coin::value(&reward);

            base_strategy::report_harvest_profit(&mut request, auth_ref, reward_amount);
            market_deposit_coin_internal(strategy_ref, reward);
        } else {
            option::destroy_none(base_rewards_maybe);
        };

        base_strategy::complete_harvest(request);
    }

    public entry fun harvest_fa(account: &signer, strategy: Object<BaseStrategy>) acquires EchelonStrategy {
        let strategy_ref = borrow_strategy(strategy);
        let auth_ref = &strategy_ref.auth_ref;

        let request = base_strategy::request_harvest(account, auth_ref);
        handle_harvest_pnl(&mut request, auth_ref, strategy_ref.market);

        // Claims all rewards associated with the strategy if any; and returns the base asset rewards if any.
        let base_rewards_maybe = claim_fa_rewards_internal(strategy_ref, auth_ref);
        if (option::is_some(&base_rewards_maybe)) {
            let reward = option::destroy_some(base_rewards_maybe);
            let reward_amount = hot_asset::amount(&reward);

            base_strategy::report_harvest_profit(&mut request, auth_ref, reward_amount);
            market_deposit_fa_internal(strategy_ref, reward);
        } else {
            option::destroy_none(base_rewards_maybe);
        };

        base_strategy::complete_harvest(request);
    }

    public entry fun vault_report<CoinType>(account: &signer, strategy: Object<BaseStrategy>) acquires EchelonStrategy {
        let strategy_ref = borrow_strategy(strategy);

        let vault = strategy_ref.vault;
        vault::report(account, vault, strategy);
    }

    public entry fun add_reward_coin_type<CoinType>(
        account: &signer, strategy: Object<BaseStrategy>
    ) acquires EchelonStrategy {
        let account_address = signer::address_of(account);
        assert!(
            protocol::is_governance(account_address) || base_strategy::manager(strategy) == account_address,
            ENOT_AUTHORIZED
        );

        assert!(coin::is_coin_initialized<CoinType>(), EINVALID_ASSET_TYPE);

        let coin_type = type_info::type_name<CoinType>();
        let strategy_ref = borrow_global_mut<EchelonStrategy>(object::object_address(&strategy));
        assert!(
            !vector::contains(&strategy_ref.reward_assets.coin_types, &coin_type),
            EREWARD_ALREADY_ADDED
        );
        assert!(
            vector::length(&strategy_ref.reward_assets.coin_types) < MAX_REWARDS_LENGTH,
            ETOO_MANY_REWARDS
        );
        vector::push_back(&mut strategy_ref.reward_assets.coin_types, coin_type);
    }

    public entry fun add_reward_metadata(
        account: &signer, strategy: Object<BaseStrategy>, metadata: Object<Metadata>
    ) acquires EchelonStrategy {
        let account_address = signer::address_of(account);
        assert!(
            protocol::is_governance(account_address) || base_strategy::manager(strategy) == account_address,
            ENOT_AUTHORIZED
        );

        let strategy_ref = borrow_global_mut<EchelonStrategy>(object::object_address(&strategy));
        assert!(
            !vector::contains(&strategy_ref.reward_assets.fa_metadatas, &metadata),
            EREWARD_ALREADY_ADDED
        );
        assert!(
            vector::length(&strategy_ref.reward_assets.fa_metadatas) < MAX_REWARDS_LENGTH,
            ETOO_MANY_REWARDS
        );
        vector::push_back(&mut strategy_ref.reward_assets.fa_metadatas, metadata);
    }

    public entry fun remove_reward_coin_type<CoinType>(
        account: &signer, strategy: Object<BaseStrategy>
    ) acquires EchelonStrategy {
        let account_address = signer::address_of(account);
        assert!(
            protocol::is_governance(account_address) || base_strategy::manager(strategy) == account_address,
            ENOT_AUTHORIZED
        );

        let strategy_ref = borrow_global_mut<EchelonStrategy>(object::object_address(&strategy));
        let (exists, index) = vector::index_of(
            &strategy_ref.reward_assets.coin_types,
            &type_info::type_name<CoinType>()
        );
        if (exists) {
            vector::remove(&mut strategy_ref.reward_assets.coin_types, index);
        };
    }

    public entry fun remove_reward_metadata(
        account: &signer, strategy: Object<BaseStrategy>, metadata: Object<Metadata>
    ) acquires EchelonStrategy {
        let account_address = signer::address_of(account);
        assert!(
            protocol::is_governance(account_address) || base_strategy::manager(strategy) == account_address,
            ENOT_AUTHORIZED
        );

        let strategy_ref = borrow_global_mut<EchelonStrategy>(object::object_address(&strategy));
        let (exists, index) = vector::index_of(&strategy_ref.reward_assets.fa_metadatas, &metadata);
        if (exists) {
            vector::remove(&mut strategy_ref.reward_assets.fa_metadatas, index);
        }
    }

    public entry fun claim_non_base_asset_fa_rewards(strategy: Object<BaseStrategy>) acquires EchelonStrategy {
        let strategy_ref = borrow_strategy(strategy);
        claim_non_base_fa_rewards_internal(strategy_ref, &strategy_ref.auth_ref);
    }

    public entry fun claim_non_base_asset_coin_rewards<CoinType>(strategy: Object<BaseStrategy>) acquires EchelonStrategy {
        let strategy_ref = borrow_strategy(strategy);
        claim_non_base_coin_rewards_internal<CoinType>(strategy_ref, &strategy_ref.auth_ref);
    }

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
    ) acquires RewardsPoolDetails, EchelonStrategy {
        assert!(
            signer::address_of(account) == base_strategy::manager(strategy),
            ENOT_AUTHORIZED
        );

        // Strategies created before the multirewards package was integrated will not have a rewards pool address set.
        // In this case, we initialize the rewards pool details.
        if (!exists<RewardsPoolDetails>(object::object_address(&strategy))) {
            let strategy_ref = borrow_global_mut<EchelonStrategy>(object::object_address(&strategy));
            initialize_reward_pool_details(strategy_ref, rewards_pool_address);
        } else {
            validate_rewards_pool_address(rewards_pool_address);

            let rewards_pool_details_ref = borrow_mut_rewards_pool_details(strategy);
            rewards_pool_details_ref.rewards_pool_address = rewards_pool_address;
        };

    }

    /// Notify rewards for assets in the primary store of the strategy.
    ///
    /// @param account The account claiming the rewards.
    /// @param strategy The strategy that will notify the rewards.
    ///
    /// @reverts ENOT_AUTHORIZED if the account is not the strategy manager.
    public entry fun notify_rewards_coin<CoinType>(
        account: &signer, strategy: Object<BaseStrategy>
    ) acquires EchelonStrategy, RewardsPoolDetails {
        assert!(
            signer::address_of(account) == base_strategy::manager(strategy),
            ENOT_AUTHORIZED
        );

        notify_rewards_coin_internal<CoinType>(strategy);
    }

    /// Notify all rewards for the strategy that are part of the rewards pool.
    ///
    /// @param account The account claiming the rewards.
    /// @param strategy The strategy that will notify the rewards.
    ///
    /// @reverts ENOT_AUTHORIZED if the account is not the strategy manager.
    public entry fun notify_all_rewards(
        account: &signer, strategy: Object<BaseStrategy>
    ) acquires EchelonStrategy, RewardsPoolDetails {
        assert!(
            signer::address_of(account) == base_strategy::manager(strategy),
            ENOT_AUTHORIZED
        );

        notify_all_rewards_internal(strategy);
    }

    public entry fun perform_upkeep_fa(strategy: Object<BaseStrategy>) acquires EchelonStrategy, RewardsPoolDetails {
        assert!(check_upkeep(strategy), EUPKEEP_NOT_READY);

        let strategy_ref = borrow_strategy(strategy);
        claim_non_base_fa_rewards_internal(strategy_ref, &strategy_ref.auth_ref);
        notify_all_rewards_internal(strategy);

        let rewards_pool_details_ref = borrow_mut_rewards_pool_details(strategy);
        rewards_pool_details_ref.last_upkeep_timestamp = timestamp::now_seconds();
    }

    public entry fun perform_upkeep_coin<CoinType>(strategy: Object<BaseStrategy>) acquires EchelonStrategy, RewardsPoolDetails {
        assert!(check_upkeep(strategy), EUPKEEP_NOT_READY);

        let strategy_ref = borrow_strategy(strategy);
        claim_non_base_coin_rewards_internal<CoinType>(strategy_ref, &strategy_ref.auth_ref);
        notify_rewards_coin_internal<CoinType>(strategy);

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
        assert!(upkeep_interval >= MIN_UPKEEP_INTERVAL && upkeep_interval <= MAX_UPKEEP_INTERVAL, EINVALID_UPKEEP_INTERVAL);
        assert!(
            signer::address_of(account) == base_strategy::manager(strategy),
            ENOT_AUTHORIZED
        );

        let rewards_pool_details_ref = borrow_mut_rewards_pool_details(strategy);
        rewards_pool_details_ref.upkeep_interval = upkeep_interval;
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

    public fun get_market(strategy: Object<BaseStrategy>): Object<Market> acquires EchelonStrategy {
        let strategy_ref = borrow_strategy(strategy);
        strategy_ref.market
    }

    inline fun borrow_strategy(strategy: Object<BaseStrategy>): &EchelonStrategy {
        borrow_global<EchelonStrategy>(object::object_address(&strategy))
    }

    fun claim_coin_rewards_internal<CoinType>(
        strategy_ref: &EchelonStrategy, auth_ref: &AuthRef
    ): Option<HotCoin<CoinType>> {
        let strategy = base_strategy::auth_ref_strategy(auth_ref);
        let base_metadata = base_strategy::base_metadata(strategy);
        let strategy_address = object::object_address(&strategy);

        let reward_assets = &strategy_ref.reward_assets;
        let strategy_signer = base_strategy::get_signer(auth_ref);
        let market_address = object::object_address(&strategy_ref.market);

        let type_string = type_info::type_name<CoinType>();
        if (!vector::contains(&reward_assets.coin_types, &type_string)) {
            return option::none()
        };

        let rewards = echelon_block::get_supply_reward<CoinType>(strategy_address, market_address);
        if (rewards > 0) {
            let reward = echelon_block::claim_supply_reward<CoinType>(&strategy_signer, market_address);
            if (option::some(base_metadata) == coin::paired_metadata<CoinType>()) {
                return option::some(reward)
            };

            if (!coin::is_account_registered<CoinType>(strategy_address)) {
                coin::register<CoinType>(&strategy_signer);
            };

            hot_coin::dispatch(reward);
        };
        option::none()
    }

    fun claim_fa_rewards_internal(strategy_ref: &EchelonStrategy, auth_ref: &AuthRef): Option<HotAsset> {
        let strategy = base_strategy::auth_ref_strategy(auth_ref);
        let base_metadata = base_strategy::base_metadata(strategy);
        let strategy_address = object::object_address(&strategy);

        let reward_assets = &strategy_ref.reward_assets;
        let strategy_signer = base_strategy::get_signer(auth_ref);
        let market_address = object::object_address(&strategy_ref.market);

        let base_rewards_maybe = option::none();
        for (i in 0..vector::length(&reward_assets.fa_metadatas)) {
            let reward_metadata = *vector::borrow(&reward_assets.fa_metadatas, i);
            let amount = echelon_block::get_supply_reward_fa(strategy_address, market_address, reward_metadata);

            if (amount > 0) {
                let reward = echelon_block::claim_supply_reward_fa(&strategy_signer, reward_metadata, market_address);

                if (reward_metadata == base_metadata) {
                    option::fill(&mut base_rewards_maybe, reward);
                } else {
                    // If the reward asset metadata is different from the base asset metadata,
                    // we transfer it to the strategy and admin can sweep it later.
                    hot_asset::dispatch(reward);
                };
            }
        };

        base_rewards_maybe
    }

    fun claim_non_base_coin_rewards_internal<CoinType>(
        strategy_ref: &EchelonStrategy, auth_ref: &AuthRef
    ) {
        let strategy = base_strategy::auth_ref_strategy(auth_ref);
        let base_metadata = base_strategy::base_metadata(strategy);
        let strategy_address = object::object_address(&strategy);

        let reward_assets = &strategy_ref.reward_assets;
        let strategy_signer = base_strategy::get_signer(auth_ref);
        let market_address = object::object_address(&strategy_ref.market);

        let type_string = type_info::type_name<CoinType>();
        if (option::some(base_metadata) != coin::paired_metadata<CoinType>()) {
            if (vector::contains(&reward_assets.coin_types, &type_string)) {
                let rewards = echelon_block::get_supply_reward<CoinType>(strategy_address, market_address);
                if (rewards > 0) {
                    let reward = echelon_block::claim_supply_reward<CoinType>(&strategy_signer, market_address);
                    if (!coin::is_account_registered<CoinType>(strategy_address)) {
                        coin::register<CoinType>(&strategy_signer);
                    };

                    hot_coin::dispatch(reward);
                };
            };
        };
    }

    fun claim_non_base_fa_rewards_internal(strategy_ref: &EchelonStrategy, auth_ref: &AuthRef) {
        let strategy = base_strategy::auth_ref_strategy(auth_ref);
        let base_metadata = base_strategy::base_metadata(strategy);
        let strategy_address = object::object_address(&strategy);

        let reward_assets = &strategy_ref.reward_assets;
        let strategy_signer = base_strategy::get_signer(auth_ref);
        let market_address = object::object_address(&strategy_ref.market);

        for (i in 0..vector::length(&reward_assets.fa_metadatas)) {
            let reward_metadata = *vector::borrow(&reward_assets.fa_metadatas, i);
            let amount = echelon_block::get_supply_reward_fa(strategy_address, market_address, reward_metadata);

            if (amount > 0) {
                if (reward_metadata != base_metadata) {
                    let reward = echelon_block::claim_supply_reward_fa(
                        &strategy_signer, reward_metadata, market_address
                    );
                    hot_asset::dispatch(reward);
                };
            };
        };
    }

    fun deposit_coin_internal<CoinType>(strategy: &EchelonStrategy, hot_coin: HotCoin<CoinType>): HotAsset {
        let shares = base_strategy::mint_debt_shares_coin(&hot_coin, &strategy.auth_ref);
        market_deposit_coin_internal(strategy, hot_coin);
        shares
    }

    fun deposit_fa_internal(strategy: &EchelonStrategy, hot_asset: HotAsset): HotAsset {
        let shares = base_strategy::mint_debt_shares_fa(&hot_asset, &strategy.auth_ref);
        market_deposit_fa_internal(strategy, hot_asset);
        shares
    }

    fun withdraw_fa_internal(
        strategy_ref: &EchelonStrategy, asset: HotAsset, max_loss: Option<u64>
    ): HotAsset {
        let request = base_strategy::request_withdrawal(asset, &strategy_ref.auth_ref);
        base_strategy::withdraw(&mut request);

        // We are not able to complete the withdrawal with the idle assets,
        // so we need to withdraw from our deposits in the the yield source
        if (base_strategy::withdrawal_remaining(&request) > 0) {
            let amount_needed = base_strategy::withdrawal_remaining(&request);
            let fa_withdrawn = market_withdraw_fa_internal(strategy_ref, amount_needed);
            base_strategy::apply_fa_withdrawal(&mut request, fa_withdrawn);
        };

        base_strategy::complete_withdrawal(request, max_loss)
    }

    fun withdraw_coin_internal<CoinType>(
        strategy_ref: &EchelonStrategy, asset: HotAsset, max_loss: Option<u64>
    ): HotCoin<CoinType> {
        let request = base_strategy::request_withdrawal(asset, &strategy_ref.auth_ref);
        base_strategy::withdraw(&mut request);

        // We are not able to complete the withdrawal with the idle assets,
        // so we need to withdraw from our deposits in the the yield source
        if (base_strategy::withdrawal_remaining(&request) > 0) {
            let amount_needed = base_strategy::withdrawal_remaining(&request);
            let coin_withdrawn = market_withdraw_coin_internal<CoinType>(strategy_ref, amount_needed);
            base_strategy::apply_coin_withdrawal(&mut request, coin_withdrawn);
        };

        base_strategy::complete_withdrawal_coin<CoinType>(request, max_loss)
    }

    fun market_withdraw_coin_internal<CoinType>(strategy_ref: &EchelonStrategy, amount: u64): HotCoin<CoinType> {
        let market = strategy_ref.market;
        let auth_ref = &strategy_ref.auth_ref;
        let strategy_address = object::object_address(&base_strategy::auth_ref_strategy(&strategy_ref.auth_ref));

        let account_coins = echelon_block::account_coins(strategy_address, market);
        let account_shares = echelon_block::account_shares(strategy_address, market);

        let shares_to_withdraw = math64::mul_div(amount, account_shares, account_coins);
        echelon_block::withdraw<CoinType>(&base_strategy::get_signer(auth_ref), market, shares_to_withdraw)
    }

    fun market_withdraw_fa_internal(strategy_ref: &EchelonStrategy, amount: u64): HotAsset {
        let auth_ref = &strategy_ref.auth_ref;
        let market = strategy_ref.market;

        let shares_to_withdraw = echelon_block::coins_to_shares(market, amount);
        echelon_block::withdraw_fa(&base_strategy::get_signer(auth_ref), market, shares_to_withdraw)
    }

    fun market_deposit_coin_internal<CoinType>(
        strategy: &EchelonStrategy, hot_coin: HotCoin<CoinType>
    ) {
        let strategy_signer = base_strategy::get_signer(&strategy.auth_ref);
        echelon_block::supply(&strategy_signer, strategy.market, hot_coin);
    }

    fun market_deposit_fa_internal(strategy: &EchelonStrategy, hot_asset: HotAsset) {
        let strategy_signer = base_strategy::get_signer(&strategy.auth_ref);
        echelon_block::supply_fa(&strategy_signer, strategy.market, hot_asset);
    }

    fun notify_rewards_coin_internal<CoinType>(strategy: Object<BaseStrategy>) acquires EchelonStrategy, RewardsPoolDetails {
        let strategy_ref = borrow_strategy(strategy);
        let strategy_signer = &base_strategy::get_signer(&strategy_ref.auth_ref);

        let reward_metadata = coin::paired_metadata<CoinType>();
        let base_metadata = base_strategy::base_metadata(strategy);

        if (option::is_some(&reward_metadata) && option::destroy_some(reward_metadata) != base_metadata) {
            let reward_amount = coin::balance<CoinType>(object::object_address(&strategy));
            notify_reward_amount_coin_internal<CoinType>(strategy_signer, strategy, reward_amount);
        };
    }

    fun notify_all_rewards_internal(strategy: Object<BaseStrategy>) acquires EchelonStrategy, RewardsPoolDetails {
        let strategy_ref = borrow_strategy(strategy);
        let strategy_signer = &base_strategy::get_signer(&strategy_ref.auth_ref);

        let staking_pool = get_staking_pool(strategy);
        let base_metadata = base_strategy::base_metadata(strategy);
        let reward_tokens = multi_rewards::get_pool_reward_tokens(staking_pool);

        let (i, len) = (0, vector::length(&reward_tokens));
        while (i < len) {
            let reward_metadata = *vector::borrow(&reward_tokens, i);
            if (reward_metadata != base_metadata) {
                let reward_amount = primary_store_balance(object::object_address(&strategy), reward_metadata);
                notify_reward_amount_fa_internal(strategy_signer, strategy, reward_metadata, reward_amount);
            };
            i = i + 1;
        }
    }

    fun notify_reward_amount_fa_internal(
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

    fun notify_reward_amount_coin_internal<CoinType>(
        strategy_signer: &signer, strategy: Object<BaseStrategy>, reward_amount: u64
    ) acquires RewardsPoolDetails {
        let rewards_pool_address = rewards_pool_address(strategy);
        if (option::is_some(&rewards_pool_address)) {
            let staking_pool = get_staking_pool(strategy);
            multi_rewards_router::notify_reward_amount<CoinType>(strategy_signer, staking_pool, reward_amount);
        }
    }

    fun initialize_reward_pool_details(
        strategy_ref: &EchelonStrategy, rewards_pool_address: Option<address>
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
        request: &mut HarvestRequest, auth_ref: &AuthRef, market: Object<Market>
    ) {
        let strategy = base_strategy::harvest_strategy(request);
        let total_debt = base_strategy::total_debt(strategy);
        let strategy_address = object::object_address(&strategy);
        let account_coins = echelon_block::account_coins(strategy_address, market);

        if (account_coins > total_debt) {
            let profit = account_coins - total_debt;
            base_strategy::report_harvest_profit(request, auth_ref, profit);
        } else if (account_coins < total_debt) {
            let loss = total_debt - account_coins;
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

    #[test_only]
    public fun create_for_test(
        account: &signer,
        vault: Object<Vault>,
        market: Object<Market>,
        debt_limit: u64
    ): Object<BaseStrategy> {
        create(account, vault, market, debt_limit);

        let events = event::emitted_events<StrategyCreated>();
        vector::pop_back(&mut events).strategy
    }
}

module meridian_rewards::strategy {
    use std::option::{Self, Option};
    use std::signer;
    use std::vector;
    use aptos_framework::account;
    use aptos_framework::event::emit;
    use aptos_framework::fungible_asset::Metadata;
    use aptos_framework::object::{Self, Object};
    use aptos_framework::primary_fungible_store::{balance as primary_store_balance};
    use aptos_framework::timestamp;

    use aptos_framework::coin;
    use satay::base_strategy::{Self, AuthRef, BaseStrategy, HarvestRequest};
    use satay::hot_asset::{Self, HotAsset};
    use satay::protocol;
    use satay::vault::{Self, Vault, WithdrawalRequest};

    use meridian_farming_block::meridian_farming_block;
    use meridian_coin::meridian_coin::M;
    use canopy_staking::multi_rewards::{Self, StakingPool};

    #[test_only]
    use aptos_framework::event;
    #[test_only]
    friend meridian_rewards::withdraw_fa_test_entry_functions;
    #[test_only]
    friend meridian_rewards::deposit_fa_test_entry_functions;

    // - - - - STRUCTS - - - -

    struct Witness has drop {}

    struct MeridianRewardsStrategy<phantom WrapperStakeCoin> has key {
        auth_ref: AuthRef,
        vault: Object<Vault>,
        pool_id: u64
    }

    struct RewardsPoolDetails has key {
        rewards_pool_address: Option<address>,
        last_upkeep_timestamp: u64,
        upkeep_interval: u64
    }

    // - - - - EVENTS - - - -

    #[event]
    struct StrategyCreated has drop, store {
        vault: Object<Vault>,
        strategy: Object<BaseStrategy>
    }

    // - - - - CONSTANTS - - - -

    const DEFAULT_UPKEEP_INTERVAL: u64 = 60 * 60 * 24; // 1 day
    const MIN_UPKEEP_INTERVAL: u64 = 60 * 60; // 1 hour
    const MAX_UPKEEP_INTERVAL: u64 = 60 * 60 * 24 * 7; // 7 days

    // - - - - ERRORS - - - -

    /// Not authorized to perform the operation.
    const ENOT_AUTHORIZED: u64 = 0;
    /// Invalid amount specified.
    const EINVALID_AMOUNT: u64 = 1;
    /// Insufficient balance to perform the operation.
    const EINSUFFICIENT_BALANCE: u64 = 2;
    /// Invalid asset metadata.
    const EINVALID_ASSET_METADATA: u64 = 3;
    /// Invalid vault specified.
    const EVAULT_MISMATCH: u64 = 6;
    /// Invalid withdrawal account specified.
    const EWITHDRAWAL_ACCOUNT_MISMATCH: u64 = 7;
    /// Cannot exceed the strategy debt.
    const ECANNOT_EXCEED_DEBT: u64 = 8;
    /// Pool not found in Meridian.
    const EPOOL_NOT_FOUND: u64 = 9;
    /// Invalid rewards pool address.
    const EINVALID_REWARDS_POOL_ADDRESS: u64 = 10;
    /// No rewards pool address set.
    const ENO_REWARDS_POOL_ADDRESS: u64 = 11;
    /// Invalid reward coin type.
    const EINVALID_REWARD_COIN_TYPE: u64 = 12;
    /// Upkeep not ready.
    const EUPKEEP_NOT_READY: u64 = 13;
    /// Invalid fee recipient.
    const EINVALID_FEE_RECIPIENT: u64 = 14;
    /// Invalid upkeep interval.
    const EINVALID_UPKEEP_INTERVAL: u64 = 15;


    // - - - - INSTANTIATOR - - - -

    /// This creates a new strategy instance and adds it to the vault.
    ///
    /// @param account The account that is creating the strategy.
    /// @param vault The vault to add the strategy to.
    /// @param debt_limit The maximum amount of debt the strategy can take.
    /// @param pool_id The ID of the Meridian pool to interact with.
    /// @param rewards_pool_address Optional address of the rewards pool.
    ///
    /// @reverts If the account is not the protocol governance signer.
    /// @reverts If the pool does not exist in Meridian.
    public entry fun create<WrapperStakeCoin>(
        account: &signer,
        vault: Object<Vault>,
        debt_limit: u64,
        pool_id: u64,
        rewards_pool_address: Option<address>
    ) {
        // Ensure this FA has a wrapped coin in Meridian.
        let metadata = vault::base_metadata(vault);
        meridian_farming_block::ensure_wrapped_coin_exists(metadata);

        validate_rewards_pool_address(rewards_pool_address);

        let auth_ref = base_strategy::create(account, metadata, Witness {});
        let base_strategy = base_strategy::auth_ref_strategy(&auth_ref);

        // NOTE: account must be the protocol governance signer in order to add a strategy to the vault
        vault::add_strategy(account, vault, base_strategy, debt_limit);

        let strategy_signer = base_strategy::get_signer(&auth_ref);
        register_coin_store<M>(&strategy_signer);
        meridian_farming_block::ensure_meridian_pool_exists(pool_id);

        move_to(
            &strategy_signer,
            MeridianRewardsStrategy<WrapperStakeCoin> { auth_ref, vault, pool_id }
        );

        move_to(
            &strategy_signer,
            RewardsPoolDetails {
                rewards_pool_address,
                last_upkeep_timestamp: 0,
                upkeep_interval: DEFAULT_UPKEEP_INTERVAL
            }
        );

        emit(StrategyCreated { vault, strategy: base_strategy });
    }

    /// Deposits fungible assets into the strategy directly.
    /// This deposits the specified amount of base asset and mints strategy shares in return.
    ///
    /// @typeparam WrapperStakeCoin The type of the Meridian wrapped staking coin that is linked to the strategy base asset
    ///
    /// @param account The account that is depositing the funds.
    /// @param strategy The strategy to deposit into.
    /// @param amount The amount of base asset to deposit.
    ///
    /// @reverts EINVALID_AMOUNT if the amount is zero.
    /// @reverts EINSUFFICIENT_BALANCE if the account does not have enough balance to deposit.
    /// @reverts if the strategy's base asset metadata does not match the wrapped coin.
    public(friend) entry fun deposit_fa<WrapperStakeCoin>(
        account: &signer, strategy: Object<BaseStrategy>, amount: u64
    ) acquires MeridianRewardsStrategy {
        assert!(amount > 0, EINVALID_AMOUNT);
        let base_metadata = base_strategy::base_metadata(strategy);
        assert!(
            primary_store_balance(signer::address_of(account), base_metadata) >= amount,
            EINSUFFICIENT_BALANCE
        );

        // create a hot asset for deposit, this sets the owner to the account of the user depositing
        let hot_asset = hot_asset::new_from_account(account, base_metadata, amount);

        let strategy_ref = borrow_strategy<WrapperStakeCoin>(strategy);
        let shares = deposit_fa_internal<WrapperStakeCoin>(strategy_ref, hot_asset);

        // dispatch shares to the user, this ensures that the user always receive the shares
        hot_asset::dispatch(shares);
    }

    /// Deposits fungible assets into the strategy from the vault.
    /// This creates vault debt and deposits the assets into the Meridian pool.
    ///
    /// @dev This function is only callable from the vault module.
    ///
    /// @typeparam WrapperStakeCoin The type of the Meridian wrapped staking coin that is linked to the strategy base asset
    ///
    /// @param account The account that is depositing the funds. (must be the vault signer)
    /// @param strategy The strategy to deposit into.
    /// @param amount The amount of base asset to deposit.
    ///
    /// @reverts If the account is not the vault signer or governance.
    /// @reverts if the strategy's base asset metadata does not match the wrapped coin.

    public entry fun vault_deposit_fa<WrapperStakeCoin>(
        account: &signer, strategy: Object<BaseStrategy>, amount: u64
    ) acquires MeridianRewardsStrategy {

        let strategy_ref = borrow_strategy<WrapperStakeCoin>(strategy);
        let vault = strategy_ref.vault;
        let auth_ref = &strategy_ref.auth_ref;

        // This function creates a debt of the specified amount in the vault and associates it with the strategy.
        // The asset is returned.
        // Also, this function can only be called by the vault manager or governance, otherwise transaction fails.
        let hot_asset = vault::create_debt_fa(account, vault, auth_ref, amount);
        let shares = deposit_fa_internal<WrapperStakeCoin>(strategy_ref, hot_asset);
        vault::deposit_strategy_shares(vault, strategy, shares);
    }

    /// Withdraws funds from the strategy.
    /// This withdraws the specified amount of strategy shares and redeems them for the strategy's base asset.
    ///
    /// @typeparam WrapperStakeCoin The type of the Meridian wrapped staking coin that is linked to the strategy base asset
    ///
    /// @param account The account that is withdrawing the funds.
    /// @param strategy The strategy to withdraw from.
    /// @param amount The amount of strategy shares to redeem for the base asset.
    /// @param max_loss The maximum amount of loss to take.
    ///
    /// @reverts EINVALID_AMOUNT if the amount is zero.
    /// @reverts EINSUFFICIENT_BALANCE if the account does not have enough balance to withdraw.
    public entry fun withdraw_fa<WrapperStakeCoin>(
        account: &signer,
        strategy: Object<BaseStrategy>,
        amount: u64,
        max_loss: Option<u64>
    ) acquires MeridianRewardsStrategy {
        ensure_fee_recipient(account, strategy);

        assert!(amount > 0, EINVALID_AMOUNT);
        let account_address = signer::address_of(account);
        let shares_metadata = base_strategy::shares_metadata(strategy);
        assert!(
            primary_store_balance(account_address, shares_metadata) >= amount,
            EINSUFFICIENT_BALANCE
        );

        let strategy_ref = borrow_strategy<WrapperStakeCoin>(strategy);
        let shares_asset = hot_asset::new_from_account(account, shares_metadata, amount);
        let asset = withdraw_fa_internal<WrapperStakeCoin>(strategy_ref, shares_asset, max_loss);

        // dispatch asset to the user, this ensures that the user always receive the shares
        hot_asset::dispatch(asset);
    }

    /// Withdraws funds from the strategy to the vault.
    /// This withdraws the specified amount from the Meridian pool and repays vault debt.
    ///
    /// @typeparam WrapperStakeCoin The type of the Meridian wrapped staking coin that is linked to the strategy base asset
    ///
    /// @param account The account that is withdrawing the funds.
    /// @param request The withdrawal request to process.
    /// @param strategy The strategy to withdraw from.
    /// @param amount The amount of funds to withdraw.
    /// @param max_loss The maximum amount of loss to take.
    ///
    /// @reverts EINVALID_AMOUNT if the amount is zero.
    /// @reverts EVAULT_MISMATCH if the vault does not match.
    /// @reverts EWITHDRAWAL_ACCOUNT_MISMATCH if the account does not match.
    /// @reverts ECANNOT_EXCEED_DEBT if amount exceeds strategy debt.
    public fun vault_withdraw_fa<WrapperStakeCoin>(
        account: &signer,
        request: &mut WithdrawalRequest,
        strategy: Object<BaseStrategy>,
        amount: u64,
        max_loss: Option<u64>
    ): HotAsset acquires MeridianRewardsStrategy {
        assert!(amount > 0, EINVALID_AMOUNT);
        let strategy_ref = borrow_strategy<WrapperStakeCoin>(strategy);

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
        withdraw_fa_internal<WrapperStakeCoin>(strategy_ref, shares_asset, max_loss)
    }

    /// This function harvests any profits/losses including rewards.
    /// Rewards in the base asset are considered profits
    /// Rewards not in the base asset are deposited to the strategy's PFS and can be swept
    ///
    /// @typeparam WrapperStakeCoin The type of the Meridian wrapped staking coin that is linked to the strategy base asset
    /// @typeparam WrappedExtraRewardCoin The type of the Meridian wrapped extra reward coin
    ///
    /// @param account The account initiating the harvest.
    /// @param strategy The strategy to harvest from.
    ///
    /// @reverts If the account is not authorized to harvest.
    public entry fun harvest<WrapperStakeCoin>(account: &signer, strategy: Object<BaseStrategy>) acquires MeridianRewardsStrategy {
        let strategy_ref = borrow_strategy<WrapperStakeCoin>(strategy);
        let auth_ref = &strategy_ref.auth_ref;
        let strategy_signer = base_strategy::get_signer(auth_ref);
        let strategy_address = object::object_address(&strategy);

        // Claim any base asset rewards to the strategy's idle, they can be tended to by the strategy after
        if (meridian_farming_block::reward_amount<WrapperStakeCoin>(strategy_address, strategy_ref.pool_id) > 0) {
            meridian_farming_block::claim_base_asset_reward<WrapperStakeCoin>(&strategy_signer, strategy_ref.pool_id);
            base_strategy::rebalance_idle(account, strategy);
        };

        let request = base_strategy::request_harvest(account, auth_ref);
        handle_harvest_pnl(&mut request, auth_ref, strategy_ref.pool_id);

        // finalize profits&losses as well as the performance fee(split between the protocol and manager)
        base_strategy::complete_harvest(request);
    }

    public entry fun perform_upkeep<WrapperStakeCoin, WrappedExtraRewardCoin1, WrappedExtraRewardCoin2, WrappedExtraRewardCoin3, WrappedExtraRewardCoin4>(
        strategy: Object<BaseStrategy>
    ) acquires MeridianRewardsStrategy, RewardsPoolDetails {
        assert!(check_upkeep(strategy), EUPKEEP_NOT_READY);

        claim_rewards_internal<WrapperStakeCoin, WrappedExtraRewardCoin1>(strategy);
        notify_rewards_internal<WrapperStakeCoin, WrappedExtraRewardCoin1>(strategy);

        claim_rewards_internal<WrapperStakeCoin, WrappedExtraRewardCoin2>(strategy);
        notify_rewards_internal<WrapperStakeCoin, WrappedExtraRewardCoin2>(strategy);

        claim_rewards_internal<WrapperStakeCoin, WrappedExtraRewardCoin3>(strategy);
        notify_rewards_internal<WrapperStakeCoin, WrappedExtraRewardCoin3>(strategy);

        claim_rewards_internal<WrapperStakeCoin, WrappedExtraRewardCoin4>(strategy);
        notify_rewards_internal<WrapperStakeCoin, WrappedExtraRewardCoin4>(strategy);

        // Update the last upkeep timestamp
        let rewards_pool_details_ref = borrow_mut_rewards_pool_details(strategy);
        rewards_pool_details_ref.last_upkeep_timestamp = timestamp::now_seconds();
    }

    fun handle_harvest_pnl(request: &mut HarvestRequest, auth_ref: &AuthRef, pool_id: u64) {
        let strategy = base_strategy::harvest_strategy(request);
        let total_debt = base_strategy::total_debt(strategy);
        let strategy_address = object::object_address(&strategy);

        let (stake_amount, _) = meridian_farming_block::stake_amount(strategy_address, pool_id);

        // There should not be profit or loss in the strategy, but for the sake of completeness we calculate it
        if (stake_amount > total_debt) {
            let profit = stake_amount - total_debt;
            base_strategy::report_harvest_profit(request, auth_ref, profit);
        } else if (stake_amount < total_debt) {
            let loss = total_debt - stake_amount;
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
    // - - - - ADMIN MANAGEMENT - - - -

    /// Claims non-base asset rewards from the strategy.
    /// This allows the strategy manager to claim rewards that are not in the base asset.
    ///
    /// @typeparam WrapperStakeCoin The type of the Meridian wrapped staking coin that is linked to the strategy base asset
    /// @typeparam WrappedExtraRewardCoin The type of the Meridian wrapped extra reward coin
    ///
    /// @param account The account claiming the rewards.
    /// @param strategy The strategy to claim rewards from.
    ///
    /// @reverts ENOT_AUTHORIZED if the account is not the strategy manager.
    public entry fun claim_non_base_asset_rewards<WrapperStakeCoin, WrappedExtraRewardCoin>(
        account: &signer, strategy: Object<BaseStrategy>
    ) acquires MeridianRewardsStrategy {
        assert!(
            signer::address_of(account) == base_strategy::manager(strategy),
            ENOT_AUTHORIZED
        );

        assert!(
            !meridian_farming_block::is_same_coin<WrapperStakeCoin, WrappedExtraRewardCoin>(),
            EINVALID_REWARD_COIN_TYPE
        );

        claim_rewards_internal<WrapperStakeCoin, WrappedExtraRewardCoin>(strategy);
    }

    /// Notify rewards for assets in the primary store of the strategy that are linked to the WrappedExtraRewardCoin.
    ///
    /// @typeparam WrapperStakeCoin The type of the Meridian wrapped staking coin that is linked to the strategy base asset
    /// @typeparam WrappedExtraRewardCoin The type of the Meridian wrapped extra reward coin
    ///
    /// @param account The account claiming the rewards.
    /// @param strategy The strategy that will notify the rewards.
    ///
    /// @reverts ENOT_AUTHORIZED if the account is not the strategy manager.
    public entry fun notify_rewards<WrapperStakeCoin, WrappedExtraRewardCoin>(
        account: &signer, strategy: Object<BaseStrategy>
    ) acquires MeridianRewardsStrategy, RewardsPoolDetails {
        assert!(
            signer::address_of(account) == base_strategy::manager(strategy),
            ENOT_AUTHORIZED
        );

        notify_rewards_internal<WrapperStakeCoin, WrappedExtraRewardCoin>(strategy);
    }

    /// Notify all rewards for the strategy that are part of the rewards pool.
    ///
    /// @typeparam WrapperStakeCoin The type of the Meridian wrapped staking coin that is linked to the strategy base asset
    /// @typeparam WrappedExtraRewardCoin The type of the Meridian wrapped extra reward coin
    ///
    /// @param account The account claiming the rewards.
    /// @param strategy The strategy that will notify the rewards.
    ///
    /// @reverts ENOT_AUTHORIZED if the account is not the strategy manager.
    public entry fun notify_all_rewards<WrapperStakeCoin>(
        account: &signer, strategy: Object<BaseStrategy>
    ) acquires MeridianRewardsStrategy, RewardsPoolDetails {
        assert!(
            signer::address_of(account) == base_strategy::manager(strategy),
            ENOT_AUTHORIZED
        );

        notify_all_rewards_internal<WrapperStakeCoin>(strategy);
    }

    // - - - - INTERNAL FUNCTIONS - - - -

    fun deposit_fa_internal<WrapperStakeCoin>(
        strategy: &MeridianRewardsStrategy<WrapperStakeCoin>, hot_asset: HotAsset
    ): HotAsset {
        let shares = base_strategy::mint_debt_shares_fa(&hot_asset, &strategy.auth_ref);
        market_deposit_fa_internal<WrapperStakeCoin>(strategy, hot_asset);
        shares
    }

    fun market_deposit_fa_internal<WrapperStakeCoin>(
        strategy: &MeridianRewardsStrategy<WrapperStakeCoin>, hot_asset: HotAsset
    ) {
        let strategy_signer = base_strategy::get_signer(&strategy.auth_ref);
        meridian_farming_block::stake_fa<WrapperStakeCoin>(&strategy_signer, strategy.pool_id, hot_asset)
    }

    fun withdraw_fa_internal<WrapperStakeCoin>(
        strategy_ref: &MeridianRewardsStrategy<WrapperStakeCoin>, shares_asset: HotAsset, max_loss: Option<u64>
    ): HotAsset {
        let request = base_strategy::request_withdrawal(shares_asset, &strategy_ref.auth_ref);
        base_strategy::withdraw(&mut request);

        // We are not able to complete the withdrawal with the idle assets,
        // so we need to withdraw from our deposits in the the yield source
        if (base_strategy::withdrawal_remaining(&request) > 0) {
            let amount_needed = base_strategy::withdrawal_remaining(&request);
            let fa_withdrawn = market_withdraw_fa_internal<WrapperStakeCoin>(strategy_ref, amount_needed);
            base_strategy::apply_fa_withdrawal(&mut request, fa_withdrawn);
        };

        base_strategy::complete_withdrawal(request, max_loss)
    }

    fun market_withdraw_fa_internal<WrapperStakeCoin>(
        strategy_ref: &MeridianRewardsStrategy<WrapperStakeCoin>, amount: u64
    ): HotAsset {
        let auth_ref = &strategy_ref.auth_ref;

        meridian_farming_block::unstake_fa<WrapperStakeCoin>(
            &base_strategy::get_signer(auth_ref),
            strategy_ref.pool_id,
            amount
        )
    }

    fun claim_rewards_internal<WrapperStakeCoin, WrappedExtraRewardCoin>(
        strategy: Object<BaseStrategy>
    ) acquires MeridianRewardsStrategy {
        let strategy_ref = borrow_strategy<WrapperStakeCoin>(strategy);
        let strategy_signer = base_strategy::get_signer(&strategy_ref.auth_ref);

        // Always claim M rewards
        meridian_farming_block::claim_meridian<WrapperStakeCoin>(&strategy_signer, strategy_ref.pool_id);
        // Claim any extra rewards
        if (!meridian_farming_block::is_null<WrappedExtraRewardCoin>()) {
            meridian_farming_block::claim_extra_reward<WrapperStakeCoin, WrappedExtraRewardCoin>(
                &strategy_signer, strategy_ref.pool_id
            );
        }
    }

    fun notify_rewards_internal<WrapperStakeCoin, WrappedExtraRewardCoin>(
        strategy: Object<BaseStrategy>
    ) acquires MeridianRewardsStrategy, RewardsPoolDetails {
        if (meridian_farming_block::is_null<WrappedExtraRewardCoin>()) { return };

        let strategy_ref = borrow_strategy<WrapperStakeCoin>(strategy);
        let strategy_signer = &base_strategy::get_signer(&strategy_ref.auth_ref);

        let base_metadata = meridian_farming_block::wrapped_coin_metadata<WrapperStakeCoin>();
        let reward_metadata = meridian_farming_block::wrapped_coin_metadata<WrappedExtraRewardCoin>();

        if (reward_metadata != base_metadata) {
            let reward_amount = primary_store_balance(object::object_address(&strategy), reward_metadata);
            notify_reward_amount_internal(strategy_signer, strategy, reward_metadata, reward_amount);
        }
    }

    fun notify_all_rewards_internal<WrapperStakeCoin>(
        strategy: Object<BaseStrategy>
    ) acquires MeridianRewardsStrategy, RewardsPoolDetails {
        let strategy_ref = borrow_strategy<WrapperStakeCoin>(strategy);
        let strategy_signer = &base_strategy::get_signer(&strategy_ref.auth_ref);

        let staking_pool = get_staking_pool(strategy);
        let reward_tokens = multi_rewards::get_pool_reward_tokens(staking_pool);

        let base_metadata = meridian_farming_block::wrapped_coin_metadata<WrapperStakeCoin>();

        let i = 0;
        let len = vector::length(&reward_tokens);
        while (i < len) {
            let reward_metadata = *vector::borrow(&reward_tokens, i);
            // Skip if reward token is the same as base asset
            if (reward_metadata != base_metadata) {
                let reward_amount = primary_store_balance(object::object_address(&strategy), reward_metadata);
                notify_reward_amount_internal(strategy_signer, strategy, reward_metadata, reward_amount);
            };
            i = i + 1;
        }
    }

    fun notify_reward_amount_internal(
        strategy_signer: &signer,
        strategy: Object<BaseStrategy>,
        reward_metadata: Object<Metadata>,
        reward_amount: u64
    ) acquires RewardsPoolDetails {
        // If a rewards pool address is set, notify the rewards module
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

    fun validate_rewards_pool_address(rewards_pool_address: Option<address>) {
        if (option::is_some(&rewards_pool_address)) {
            assert!(
                object::object_exists<StakingPool>(*option::borrow(&rewards_pool_address)),
                EINVALID_REWARDS_POOL_ADDRESS
            );
        };
    }

    inline fun borrow_strategy<WrapperStakeCoin>(strategy: Object<BaseStrategy>): &MeridianRewardsStrategy<WrapperStakeCoin> {
        borrow_global<MeridianRewardsStrategy<WrapperStakeCoin>>(object::object_address(&strategy))
    }

    inline fun borrow_mut_strategy<WrapperStakeCoin>(
        strategy: Object<BaseStrategy>
    ): &mut MeridianRewardsStrategy<WrapperStakeCoin> {
        borrow_global_mut<MeridianRewardsStrategy<WrapperStakeCoin>>(object::object_address(&strategy))
    }

    inline fun borrow_rewards_pool_details(strategy: Object<BaseStrategy>): &RewardsPoolDetails {
        borrow_global<RewardsPoolDetails>(object::object_address(&strategy))
    }

    inline fun borrow_mut_rewards_pool_details(strategy: Object<BaseStrategy>): &mut RewardsPoolDetails {
        borrow_global_mut<RewardsPoolDetails>(object::object_address(&strategy))
    }

    inline fun register_coin_store<CoinType>(account: &signer) {
        account::create_account_if_does_not_exist(signer::address_of(account));
        coin::register<CoinType>(account);
    }

    // - - - - ADMIN FUNCTIONS - - - -

    /// Tends to the strategy by deploying idle assets.
    /// This takes idle assets in the strategy and deploys them to Meridian.
    ///
    /// @typeparam WrapperStakeCoin The type of the Meridian wrapped staking coin that is linked to the strategy base asset
    ///
    /// @param strategy_manager The account managing the strategy.
    /// @param strategy The strategy to tend to.
    public entry fun tend_fa<WrapperStakeCoin>(
        strategy_manager: &signer, strategy: Object<BaseStrategy>
    ) acquires MeridianRewardsStrategy {
        let strategy_ref = borrow_strategy<WrapperStakeCoin>(strategy);

        // we get the idle assets in the strategy and deploy it to Meridian
        let tend_fa = base_strategy::tend_fa(strategy_manager, &strategy_ref.auth_ref);
        market_deposit_fa_internal<WrapperStakeCoin>(strategy_ref, tend_fa);
    }

    /// Reports strategy performance to the vault.
    /// This updates the vault with the strategy's current profits or losses.
    ///
    /// @param account The account initiating the report.
    /// @param strategy The strategy to report on.
    public entry fun vault_report<WrapperStakeCoin>(
        account: &signer, strategy: Object<BaseStrategy>
    ) acquires MeridianRewardsStrategy {
        let strategy_ref = borrow_strategy<WrapperStakeCoin>(strategy);

        let vault = strategy_ref.vault;
        vault::report(account, vault, strategy);
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
    ) acquires RewardsPoolDetails {
        assert!(
            signer::address_of(account) == base_strategy::manager(strategy),
            ENOT_AUTHORIZED
        );
        validate_rewards_pool_address(rewards_pool_address);

        let rewards_pool_details_ref = borrow_mut_rewards_pool_details(strategy);
        rewards_pool_details_ref.rewards_pool_address = rewards_pool_address;
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

    // - - - - VIEW FUNCTIONS - - - -

    #[view]
    /// Gets the base asset metadata for the strategy.
    ///
    /// @param strategy The strategy to get the base asset for.
    ///
    /// @return The metadata object for the base asset.
    public fun get_base_asset<WrapperStakeCoin>(strategy: Object<BaseStrategy>): Object<Metadata> acquires MeridianRewardsStrategy {
        let strategy_ref = borrow_strategy<WrapperStakeCoin>(strategy);
        vault::base_metadata(strategy_ref.vault)
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

    // - - - - TEST_ONLY - - - -

    #[test_only]
    public fun create_for_test<WrapperStakeCoin>(
        account: &signer,
        vault: Object<Vault>,
        debt_limit: u64,
        pool_id: u64,
        rewards_pool_address: Option<address>
    ): Object<BaseStrategy> {
        create<WrapperStakeCoin>(account, vault, debt_limit, pool_id, rewards_pool_address);

        let events = event::emitted_events<StrategyCreated>();
        vector::pop_back(&mut events).strategy
    }

    #[test_only]
    public fun get_most_recent_strategy(): Option<Object<BaseStrategy>> {
        let events = event::emitted_events<StrategyCreated>();
        if (vector::length(&events) == 0) {
            return option::none()
        };
        let last_event = vector::pop_back(&mut events);
        option::some(last_event.strategy)
    }
}

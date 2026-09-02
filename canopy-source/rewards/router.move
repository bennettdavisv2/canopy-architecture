module canopy_staking::router {
    use std::signer;
    use std::option;
    use std::string::{String};
    use std::vector;

    use aptos_token::token::{Self};

    use aptos_framework::coin;
    use aptos_framework::object::{Object};
    use aptos_framework::fungible_asset::{Metadata};
    use aptos_framework::primary_fungible_store;

    use canopy_staking::multi_rewards::{Self, StakingPool};

    use canopy_staking::token_fa_wrapper;

    /// Pool's staking token doesn't match the CoinType
    const INVALID_POOL_TOKEN: u64 = 1;

    // - - - - PUBLIC FUNCTIONS multi_rewards: Coin to FA - - - -

    public entry fun create_staking_pool<CoinType>(creator: &signer) {
        let staking_token = get_or_create_paired_metadata<CoinType>(creator);
        multi_rewards::entry_create_staking_pool(creator, staking_token);
    }

    public entry fun add_reward<CoinType>(
        admin: &signer,
        pool: Object<StakingPool>,
        rewards_distributor: address,
        rewards_duration: u64
    ) {
        let reward_token = get_or_create_paired_metadata<CoinType>(admin);
        multi_rewards::add_reward(admin, pool, reward_token, rewards_distributor, rewards_duration);
    }

    public entry fun notify_reward_amount<CoinType>(
        distributor: &signer, pool: Object<StakingPool>, reward_amount: u64
    ) {
        let reward_token = get_or_create_paired_metadata<CoinType>(distributor);
        convert_and_deposit<CoinType>(distributor, reward_amount);
        multi_rewards::notify_reward_amount(distributor, pool, reward_token, reward_amount);
    }

    public entry fun stake<CoinType>(account: &signer, amount: u64) {
        let staking_token = get_or_create_paired_metadata<CoinType>(account);
        convert_and_deposit<CoinType>(account, amount);
        multi_rewards::stake(account, staking_token, amount);
    }

    public entry fun withdraw<CoinType>(account: &signer, amount: u64) {
        let staking_token = get_or_create_paired_metadata<CoinType>(account);
        multi_rewards::withdraw(account, staking_token, amount);

        // NOTE: we do NOT need to convert the fungible asset back to coin
        // since coin relies on the primary_fungible_store as a fallback in case it does not have sufficient coin
    }

    // NOTE: for convenience we implement stake_token and withdraw_token to enable user's to wrap/unwrap before staking/withdrawing from multi_rewards

    public entry fun stake_token(
        account: &signer,
        amount: u64,
        creator: address,
        collection: String,
        name: String,
        property_version: u64
    ) {
        let token_id = token::create_token_id_raw(creator, collection, name, property_version);

        // Wrap token to FA
        let wrapped_fa = token_fa_wrapper::wrap(account, token_id, amount);

        // Get the FA metadata for the wrapped token
        let fa_metadata = token_fa_wrapper::get_fungible_asset_metadata(&token_id);

        // Deposit the wrapped FA to the user's primary store
        let account_addr = signer::address_of(account);
        primary_fungible_store::deposit(account_addr, wrapped_fa);

        // Stake the wrapped tokens
        multi_rewards::stake(account, fa_metadata, amount);
    }

    public entry fun withdraw_token(
        account: &signer,
        amount: u64,
        creator: address,
        collection: String,
        name: String,
        property_version: u64
    ) {
        let token_id = token::create_token_id_raw(creator, collection, name, property_version);

        // Get the FA metadata for the wrapped token
        let fa_metadata = token_fa_wrapper::get_fungible_asset_metadata(&token_id);

        // Withdraw from multi_rewards
        multi_rewards::withdraw(account, fa_metadata, amount);

        // Unwrap the FA back to a token
        token_fa_wrapper::unwrap(account, token_id, amount);
    }

    public entry fun set_rewards_duration<CoinType>(
        distributor: &signer, pool: Object<StakingPool>, new_duration: u64
    ) {
        let reward_token = get_or_create_paired_metadata<CoinType>(distributor);
        multi_rewards::set_rewards_duration(distributor, pool, reward_token, new_duration);
    }

    // - - - - PUBLIC FUNCTIONS multi_rewards: batch operations - - - -

    public entry fun stake_and_subscribe_fa(
        account: &signer,
        staking_token: Object<Metadata>,
        amount: u64,
        pools: vector<Object<StakingPool>>
    ) {
        multi_rewards::stake(account, staking_token, amount);
        verify_and_subscribe_to_pools(account, staking_token, &pools);
    }

    public entry fun unsubscribe_and_withdraw_fa(
        account: &signer,
        staking_token: Object<Metadata>,
        amount: u64,
        pools: vector<Object<StakingPool>>
    ) {
        verify_and_unsubscribe_from_pools(account, staking_token, &pools);
        multi_rewards::withdraw(account, staking_token, amount);
    }

    public entry fun stake_and_subscribe<CoinType>(
        account: &signer, pools: vector<Object<StakingPool>>, amount: u64
    ) {
        // First stake the amount - this internally handles coin conversion and deposit
        stake<CoinType>(account, amount);

        // Get the staking token to verify all pools
        let staking_token = get_or_create_paired_metadata<CoinType>(account);
        verify_and_subscribe_to_pools(account, staking_token, &pools);
    }

    public entry fun unsubscribe_and_withdraw<CoinType>(
        account: &signer, pools: vector<Object<StakingPool>>, amount: u64
    ) {
        // Get the staking token to verify all pools
        let staking_token = get_or_create_paired_metadata<CoinType>(account);
        verify_and_unsubscribe_from_pools(account, staking_token, &pools);

        // Finally withdraw the amount - no need to convert back to coin
        // since coin relies on the primary_fungible_store as a fallback
        withdraw<CoinType>(account, amount);
    }

    public entry fun stake_and_subscribe_token(
        account: &signer,
        pools: vector<Object<StakingPool>>,
        amount: u64,
        creator: address,
        collection: String,
        name: String,
        property_version: u64
    ) {
        // First stake the token amount - this internally handles token wrapping
        stake_token(account, amount, creator, collection, name, property_version);

        // Get token ID and FA metadata for verification
        let token_id = token::create_token_id_raw(creator, collection, name, property_version);
        let staking_token = token_fa_wrapper::get_fungible_asset_metadata(&token_id);
        verify_and_subscribe_to_pools(account, staking_token, &pools);
    }

    public entry fun unsubscribe_and_withdraw_token(
        account: &signer,
        pools: vector<Object<StakingPool>>,
        amount: u64,
        creator: address,
        collection: String,
        name: String,
        property_version: u64
    ) {
        // Get token ID and FA metadata for verification
        let token_id = token::create_token_id_raw(creator, collection, name, property_version);
        let staking_token = token_fa_wrapper::get_fungible_asset_metadata(&token_id);
        verify_and_unsubscribe_from_pools(account, staking_token, &pools);

        // Finally withdraw and unwrap the token
        withdraw_token(account, amount, creator, collection, name, property_version);
    }

    public entry fun claim_rewards(account: &signer, staking_tokens: vector<Object<Metadata>>) {
        let i = 0;
        let len = vector::length(&staking_tokens);
        while (i < len) {
            let staking_token = *vector::borrow(&staking_tokens, i);
            multi_rewards::claim_reward(account, staking_token);
            i = i + 1;
        };
    }

    // - - - - PUBLIC FUNCTIONS: once-off - - - -

    public entry fun create_fungible_asset_for_token(
        creator: address,
        collection: String,
        name: String,
        property_version: u64
    ) {
        let token_id = token::create_token_id_raw(creator, collection, name, property_version);
        token_fa_wrapper::create_fungible_asset(token_id);
    }

    // - - - - INTERNAL HELPER FUNCTIONS - - - -

    fun get_or_create_paired_metadata<CoinType>(account: &signer): Object<Metadata> {
        let metadata_opt = coin::paired_metadata<CoinType>();
        if (option::is_none(&metadata_opt)) {
            coin::migrate_to_fungible_store<CoinType>(account);
            // NOTE: at this point the paired metadata must exist
            metadata_opt = coin::paired_metadata<CoinType>();
        };
        option::extract(&mut metadata_opt)
    }

    fun convert_and_deposit<CoinType>(account: &signer, amount: u64) {
        let account_addr = signer::address_of(account);
        let coin = coin::withdraw<CoinType>(account, amount);
        let fa = coin::coin_to_fungible_asset(coin);
        primary_fungible_store::deposit(account_addr, fa);
    }

    /// Verifies and subscribes to all pools for a given staking token
    fun verify_and_subscribe_to_pools(
        account: &signer, staking_token: Object<Metadata>, pools: &vector<Object<StakingPool>>
    ) {
        let i = 0;
        let len = vector::length(pools);
        while (i < len) {
            let pool = vector::borrow(pools, i);

            // Verify the pool is for this token type
            let (pool_staking_token, _, _) = multi_rewards::get_pool_info(*pool);
            assert!(pool_staking_token == staking_token, INVALID_POOL_TOKEN);

            multi_rewards::subscribe(account, *pool);
            i = i + 1;
        };
    }

    /// Verifies and unsubscribes from all pools for a given staking token
    fun verify_and_unsubscribe_from_pools(
        account: &signer, staking_token: Object<Metadata>, pools: &vector<Object<StakingPool>>
    ) {
        let i = 0;
        let len = vector::length(pools);
        while (i < len) {
            let pool = vector::borrow(pools, i);

            // Verify the pool is for this token type
            let (pool_staking_token, _, _) = multi_rewards::get_pool_info(*pool);
            assert!(pool_staking_token == staking_token, INVALID_POOL_TOKEN);

            // Unsubscribe will automatically claim any pending rewards
            multi_rewards::unsubscribe(account, *pool);
            i = i + 1;
        };
    }

    // - - - - - - TEST ONLY - - - - - -

    // - - - - - - TEST ONLY: functions - - - - - -

    #[test_only]
    public fun get_paired_metadata<CoinType>(): Object<Metadata> {
        let metadata_opt = coin::paired_metadata<CoinType>();
        // NOTE: extract will fail if NOT some(i.e. optional is not defined)
        option::extract(&mut metadata_opt)
    }
}

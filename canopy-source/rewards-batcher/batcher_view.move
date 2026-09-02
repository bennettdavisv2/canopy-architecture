module multi_rewards_batcher::batcher_view {
    use std::vector;
    use std::option::{Self, Option};
    use aptos_framework::object::{Self, Object};
    use aptos_framework::fungible_asset::{Self, Metadata};
    use aptos_framework::timestamp;

    use canopy_staking::multi_rewards::{Self, StakingPool};

    // For get_pool_full_details
    struct PoolDetails has copy, drop {
        staking_token: Object<Metadata>,
        reward_tokens: vector<Object<Metadata>>,
        total_subscribed: u64,
        staking_token_supply: Option<u128>,
        owner: address,
        pool_address: address
    }

    // For get_pool_reward_details
    struct RewardTokenDetails has copy, drop {
        token: Object<Metadata>,
        distributor: address,
        duration: u64,
        period_finish: u64,
        last_update_time: u64,
        reward_rate: u128,
        reward_per_token: u128,
        remaining_rewards: u64,
        unallocated_rewards: u64
    }

    // For get_user_staking_overview
    struct UserStakingOverview has copy, drop {
        staking_token: Object<Metadata>,
        staked_balance: u64,
        subscribed_pools: vector<Object<StakingPool>>
    }

    // For get_user_rewards_by_pool
    struct UserReward has copy, drop {
        reward_token: Object<Metadata>,
        earned_amount: u64,
        reward_per_token_paid: u128
    }

    // User position in a specific pool
    struct UserPoolPosition has copy, drop {
        pool: Object<StakingPool>,
        is_subscribed: bool,
        pool_staking_token: Object<Metadata>,
        effective_staked_amount: u64, // Only counts if subscribed
        rewards: vector<UserReward>
    }

    // Complete system overview
    struct UserSystemOverview has copy, drop {
        staked_balances: vector<TokenBalance>, // Token balances for all staked tokens
        pool_positions: vector<UserPoolPosition> // Position in each pool
    }

    // Simple token balance struct
    struct TokenBalance has copy, drop {
        token: Object<Metadata>,
        amount: u64
    }

    // Active pool info
    struct ActivePoolInfo has copy, drop {
        pool: Object<StakingPool>,
        staking_token: Object<Metadata>,
        total_subscribed: u64,
        active_reward_tokens: vector<Object<Metadata>>,
        reward_end_times: vector<u64> // Corresponding reward period finish times
    }

    #[view]
    /// Returns comprehensive details about a staking pool
    public fun get_pool_full_details(pool: Object<StakingPool>): PoolDetails {
        let pool_address = object::object_address(&pool);
        let (staking_token, reward_tokens, total_subscribed) = multi_rewards::get_pool_info(pool);

        // Get the total supply of the staking token (this is optional as not all FAs track supply)
        let staking_token_supply = fungible_asset::supply(staking_token);

        // Note: This would require adding a view function to get the pool owner in the multi_rewards module
        // For now, I'm setting it to a placeholder address
        let owner = @0x0; // Ideally this would be fetched from the pool

        PoolDetails { staking_token, reward_tokens, total_subscribed, staking_token_supply, owner, pool_address }
    }

    #[view]
    /// Returns comprehensive details about multiple staking pools
    public fun get_pools_full_details(pools: vector<Object<StakingPool>>): vector<PoolDetails> {
        let pool_details = vector::empty<PoolDetails>();

        let i = 0;
        let len = vector::length(&pools);
        while (i < len) {
            let pool = *vector::borrow(&pools, i);
            let details = get_pool_full_details(pool);
            vector::push_back(&mut pool_details, details);
            i = i + 1;
        };

        pool_details
    }

    /// Combined pool and reward details structure
    struct PoolRewardDetails has copy, drop {
        pool_details: PoolDetails,
        reward_details: vector<RewardTokenDetails>
    }

    #[view]
    /// Returns both pool info and all reward details for multiple pools
    public fun get_pools_reward_tokens_details(pools: vector<Object<StakingPool>>): vector<PoolRewardDetails> {
        let combined_details = vector::empty<PoolRewardDetails>();

        let i = 0;
        let len = vector::length(&pools);
        while (i < len) {
            let pool = *vector::borrow(&pools, i);
            let pool_details = get_pool_full_details(pool);
            let reward_details = get_pool_all_rewards_details(pool);

            let combined = PoolRewardDetails { pool_details, reward_details };

            vector::push_back(&mut combined_details, combined);
            i = i + 1;
        };

        combined_details
    }

    #[view]
    /// Returns a user's positions in multiple specified pools
    public fun get_user_multiple_pools_positions(user: address, pools: vector<Object<StakingPool>>): vector<UserPoolPosition> {
        let positions = vector::empty<UserPoolPosition>();

        let i = 0;
        let len = vector::length(&pools);
        while (i < len) {
            let pool = *vector::borrow(&pools, i);
            let position = get_user_pool_position(user, pool);
            vector::push_back(&mut positions, position);
            i = i + 1;
        };

        positions
    }

    #[view]
    /// Returns complete details about a specific reward token in a pool
    public fun get_pool_reward_details(pool: Object<StakingPool>, reward_token: Object<Metadata>): RewardTokenDetails {
        let (distributor, duration, period_finish, last_update_time, reward_rate, reward_per_token_stored) =
            multi_rewards::get_reward_data(pool, reward_token);

        let reward_per_token = multi_rewards::get_reward_per_token(pool, reward_token);
        let remaining_rewards = multi_rewards::get_remaining_rewards(pool, reward_token);
        let unallocated_rewards = multi_rewards::get_unallocated_rewards(pool, reward_token);

        RewardTokenDetails {
            token: reward_token,
            distributor,
            duration,
            period_finish,
            last_update_time,
            reward_rate,
            reward_per_token,
            remaining_rewards,
            unallocated_rewards
        }
    }

    #[view]
    /// Returns detailed information about all reward tokens in a pool
    public fun get_pool_all_rewards_details(pool: Object<StakingPool>): vector<RewardTokenDetails> {
        let reward_tokens = multi_rewards::get_pool_reward_tokens(pool);
        let reward_details = vector::empty<RewardTokenDetails>();

        let i = 0;
        let len = vector::length(&reward_tokens);
        while (i < len) {
            let reward_token = *vector::borrow(&reward_tokens, i);
            let token_details = get_pool_reward_details(pool, reward_token);
            vector::push_back(&mut reward_details, token_details);
            i = i + 1;
        };

        reward_details
    }

    #[view]
    /// Returns a user's staking overview for a specific token
    public fun get_user_staking_overview(user: address, staking_token: Object<Metadata>): UserStakingOverview {
        let staked_balance = multi_rewards::get_user_staked_balance(user, staking_token);
        let subscribed_pools = multi_rewards::get_user_subscribed_pools(user, staking_token);

        UserStakingOverview { staking_token, staked_balance, subscribed_pools }
    }

    #[view]
    /// Returns all rewards a user has earned in a specific pool
    public fun get_user_rewards_by_pool(user: address, pool: Object<StakingPool>): vector<UserReward> {
        let reward_tokens = multi_rewards::get_pool_reward_tokens(pool);
        let user_rewards = vector::empty<UserReward>();

        let i = 0;
        let len = vector::length(&reward_tokens);
        while (i < len) {
            let reward_token = *vector::borrow(&reward_tokens, i);
            let earned_amount = multi_rewards::get_earned(user, pool, reward_token);
            let (reward_per_token_paid, _) = multi_rewards::get_user_reward_data(user, pool, reward_token);

            let user_reward = UserReward { reward_token, earned_amount, reward_per_token_paid };

            vector::push_back(&mut user_rewards, user_reward);
            i = i + 1;
        };

        user_rewards
    }

    #[view]
    /// Returns a user's complete position in a specific pool
    public fun get_user_pool_position(user: address, pool: Object<StakingPool>): UserPoolPosition {
        let (staking_token, _, _) = multi_rewards::get_pool_info(pool);
        let is_subscribed = multi_rewards::is_user_subscribed(user, pool);

        // Only count balance as staked in this pool if user is subscribed
        let effective_staked_amount = 0;
        if (is_subscribed) {
            effective_staked_amount = multi_rewards::get_user_staked_balance(user, staking_token);
        };

        let rewards = get_user_rewards_by_pool(user, pool);

        UserPoolPosition { pool, is_subscribed, pool_staking_token: staking_token, effective_staked_amount, rewards }
    }

    #[view]
    /// Returns a list of positions in all pools a user is subscribed to for a specific staking token
    public fun get_user_pools_positions_by_token(user: address, staking_token: Object<Metadata>): vector<UserPoolPosition> {
        let user_overview = get_user_staking_overview(user, staking_token);
        let subscribed_pools = user_overview.subscribed_pools;
        let pool_positions = vector::empty<UserPoolPosition>();

        let i = 0;
        let len = vector::length(&subscribed_pools);
        while (i < len) {
            let pool = *vector::borrow(&subscribed_pools, i);
            let position = get_user_pool_position(user, pool);
            vector::push_back(&mut pool_positions, position);
            i = i + 1;
        };

        pool_positions
    }

    #[view]
    /// Returns all pools that use a specific staking token
    /// Note: This requires maintaining a list of all pools in the multi_rewards module
    /// or scanning objects - this is a simplified version that accepts a list of pools to check
    public fun get_pools_by_staking_token(
        candidate_pools: vector<Object<StakingPool>>, staking_token: Object<Metadata>
    ): vector<Object<StakingPool>> {
        let matching_pools = vector::empty<Object<StakingPool>>();

        let i = 0;
        let len = vector::length(&candidate_pools);
        while (i < len) {
            let pool = *vector::borrow(&candidate_pools, i);
            let (pool_staking_token, _, _) = multi_rewards::get_pool_info(pool);

            if (object::object_address(&pool_staking_token) == object::object_address(&staking_token)) {
                vector::push_back(&mut matching_pools, pool);
            };

            i = i + 1;
        };

        matching_pools
    }

    #[view]
    /// Returns pools with active reward periods
    public fun get_active_rewards_pools(candidate_pools: vector<Object<StakingPool>>): vector<ActivePoolInfo> {
        let active_pools = vector::empty<ActivePoolInfo>();
        let current_time = timestamp::now_seconds();

        let i = 0;
        let len = vector::length(&candidate_pools);
        while (i < len) {
            let pool = *vector::borrow(&candidate_pools, i);
            let (staking_token, reward_tokens, total_subscribed) = multi_rewards::get_pool_info(pool);

            let active_reward_tokens = vector::empty<Object<Metadata>>();
            let reward_end_times = vector::empty<u64>();

            let j = 0;
            let rewards_len = vector::length(&reward_tokens);
            let has_active_rewards = false;

            while (j < rewards_len) {
                let reward_token = *vector::borrow(&reward_tokens, j);
                let (_, _, period_finish, _, _, _) = multi_rewards::get_reward_data(pool, reward_token);

                if (period_finish > current_time) {
                    has_active_rewards = true;
                    vector::push_back(&mut active_reward_tokens, reward_token);
                    vector::push_back(&mut reward_end_times, period_finish);
                };

                j = j + 1;
            };

            if (has_active_rewards) {
                let active_pool_info = ActivePoolInfo { pool, staking_token, total_subscribed, active_reward_tokens, reward_end_times };
                vector::push_back(&mut active_pools, active_pool_info);
            };

            i = i + 1;
        };

        active_pools
    }

    #[view]
    /// Returns a comprehensive overview of a user's position across the entire staking system
    /// Note: This requires knowing all staking tokens the user has interacted with
    public fun get_user_system_overview(user: address, staking_tokens: vector<Object<Metadata>>): UserSystemOverview {
        let staked_balances = vector::empty<TokenBalance>();
        let all_pool_positions = vector::empty<UserPoolPosition>();

        let i = 0;
        let len = vector::length(&staking_tokens);
        while (i < len) {
            let staking_token = *vector::borrow(&staking_tokens, i);
            let balance = multi_rewards::get_user_staked_balance(user, staking_token);

            if (balance > 0) {
                let token_balance = TokenBalance { token: staking_token, amount: balance };
                vector::push_back(&mut staked_balances, token_balance);

                // Get all pool positions for this token
                let pool_positions = get_user_pools_positions_by_token(user, staking_token);
                let j = 0;
                let pos_len = vector::length(&pool_positions);
                while (j < pos_len) {
                    vector::push_back(&mut all_pool_positions, *vector::borrow(&pool_positions, j));
                    j = j + 1;
                };
            };

            i = i + 1;
        };

        UserSystemOverview { staked_balances, pool_positions: all_pool_positions }
    }
}

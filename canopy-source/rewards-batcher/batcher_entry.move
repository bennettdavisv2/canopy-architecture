module multi_rewards_batcher::batcher_entry {
    use std::vector;
    use std::signer;

    use aptos_framework::object::{Object};
    use aptos_framework::fungible_asset::Metadata;

    use canopy_staking::multi_rewards::{Self, StakingPool};

    /// Batch create multiple staking pools at once
    ///
    /// @param creator - The signer of the account creating the pools
    /// @param staking_tokens - Vector of staking tokens to create pools for
    ///
    /// This function allows an admin to create multiple staking pools in a single transaction.
    /// One pool will be created for each staking token provided in the input vector.
    public entry fun batch_create_staking_pools(creator: &signer, staking_tokens: vector<Object<Metadata>>) {
        let i = 0;
        let len = vector::length(&staking_tokens);

        while (i < len) {
            let staking_token = *vector::borrow(&staking_tokens, i);
            multi_rewards::entry_create_staking_pool(creator, staking_token);
            i = i + 1;
        };
    }

    /// Add the same reward token to multiple staking pools
    ///
    /// @param admin - The signer of the account adding the reward
    /// @param pools - Vector of staking pools to add the reward token to
    /// @param reward_token - The token to be used as a reward
    /// @param rewards_distributor - The address authorized to distribute this reward
    /// @param rewards_duration - The duration of the reward period in seconds
    ///
    /// This function adds the same reward token to multiple pools in a single transaction.
    public entry fun batch_add_reward_to_multiple_pools(
        admin: &signer,
        pools: vector<Object<StakingPool>>,
        reward_token: Object<Metadata>,
        rewards_distributor: address,
        rewards_duration: u64
    ) {
        let i = 0;
        let len = vector::length(&pools);

        while (i < len) {
            let pool = *vector::borrow(&pools, i);
            multi_rewards::add_reward(admin, pool, reward_token, rewards_distributor, rewards_duration);
            i = i + 1;
        };
    }

    /// Add multiple reward tokens to a single staking pool
    ///
    /// @param admin - The signer of the account adding the rewards
    /// @param pool - The staking pool to add reward tokens to
    /// @param reward_tokens - Vector of tokens to be used as rewards
    /// @param rewards_distributors - Vector of addresses authorized to distribute each reward
    /// @param rewards_durations - Vector of durations for each reward period in seconds
    ///
    /// This function adds multiple reward tokens to a single pool in one transaction.
    /// The vectors must be of the same length and corresponding indices represent a complete reward configuration.
    public entry fun batch_add_multiple_rewards_to_pool(
        admin: &signer,
        pool: Object<StakingPool>,
        reward_tokens: vector<Object<Metadata>>,
        rewards_distributors: vector<address>,
        rewards_durations: vector<u64>
    ) {
        let len = vector::length(&reward_tokens);

        // Verify input vectors have the same length
        assert!(vector::length(&rewards_distributors) == len, 1);
        assert!(vector::length(&rewards_durations) == len, 1);

        let i = 0;
        while (i < len) {
            let reward_token = *vector::borrow(&reward_tokens, i);
            let rewards_distributor = *vector::borrow(&rewards_distributors, i);
            let rewards_duration = *vector::borrow(&rewards_durations, i);

            multi_rewards::add_reward(admin, pool, reward_token, rewards_distributor, rewards_duration);
            i = i + 1;
        };
    }

    /// Matrix operation: Add multiple reward tokens to multiple staking pools
    ///
    /// @param admin - The signer of the account adding the rewards
    /// @param pools - Vector of staking pools
    /// @param reward_tokens - Vector of tokens to be used as rewards
    /// @param rewards_distributors - Vector of addresses authorized to distribute rewards
    /// @param rewards_durations - Vector of durations for each reward period in seconds
    /// @param pool_reward_matrix - Matrix defining which rewards apply to which pools (1 = add, 0 = skip)
    ///                            First dimension maps to pools, second to rewards
    ///
    /// This function allows configuring multiple pools with multiple rewards with full flexibility.
    /// The pool_reward_matrix is a flattened 2D array where matrix[i * reward_count + j] = 1 means
    /// "add reward j to pool i".
    public entry fun batch_add_rewards_matrix(
        admin: &signer,
        pools: vector<Object<StakingPool>>,
        reward_tokens: vector<Object<Metadata>>,
        rewards_distributors: vector<address>,
        rewards_durations: vector<u64>,
        pool_reward_matrix: vector<u8>
    ) {
        let pool_count = vector::length(&pools);
        let reward_count = vector::length(&reward_tokens);

        // Verify input vectors have the correct lengths
        assert!(vector::length(&rewards_distributors) == reward_count, 1);
        assert!(vector::length(&rewards_durations) == reward_count, 1);
        assert!(vector::length(&pool_reward_matrix) == pool_count * reward_count, 1);

        let p = 0;
        while (p < pool_count) {
            let pool = *vector::borrow(&pools, p);

            let r = 0;
            while (r < reward_count) {
                let matrix_index = p * reward_count + r;
                let should_add = *vector::borrow(&pool_reward_matrix, matrix_index);

                if (should_add == 1) {
                    let reward_token = *vector::borrow(&reward_tokens, r);
                    let rewards_distributor = *vector::borrow(&rewards_distributors, r);
                    let rewards_duration = *vector::borrow(&rewards_durations, r);

                    multi_rewards::add_reward(admin, pool, reward_token, rewards_distributor, rewards_duration);
                };

                r = r + 1;
            };

            p = p + 1;
        };
    }

    /// Batch notify reward amounts for multiple token-pool pairs
    ///
    /// @param distributor - The signer of the account authorized to distribute rewards
    /// @param pools - Vector of staking pool objects
    /// @param reward_tokens - Vector of token being added as rewards
    /// @param reward_amounts - Vector of reward token amounts to add
    ///
    /// This function allows notifying reward amounts for multiple pools and tokens in one transaction.
    /// Each triplet (pools[i], reward_tokens[i], reward_amounts[i]) represents one notification.
    public entry fun batch_notify_reward_amounts(
        distributor: &signer,
        pools: vector<Object<StakingPool>>,
        reward_tokens: vector<Object<Metadata>>,
        reward_amounts: vector<u64>
    ) {
        let len = vector::length(&pools);

        // Verify input vectors have the same length
        assert!(vector::length(&reward_tokens) == len, 1);
        assert!(vector::length(&reward_amounts) == len, 1);

        let i = 0;
        while (i < len) {
            let pool = *vector::borrow(&pools, i);
            let reward_token = *vector::borrow(&reward_tokens, i);
            let reward_amount = *vector::borrow(&reward_amounts, i);

            multi_rewards::notify_reward_amount(distributor, pool, reward_token, reward_amount);
            i = i + 1;
        };
    }

    /// Batch update reward durations for multiple pools/tokens
    ///
    /// @param distributor - The signer of the account authorized to modify reward settings
    /// @param pools - Vector of staking pool objects
    /// @param reward_tokens - Vector of reward tokens whose duration is being updated
    /// @param new_durations - Vector of new durations for the reward periods, in seconds
    ///
    /// This function allows updating reward durations for multiple pools and tokens in one transaction.
    /// Each triplet (pools[i], reward_tokens[i], new_durations[i]) represents one duration update.
    public entry fun batch_set_rewards_durations(
        distributor: &signer,
        pools: vector<Object<StakingPool>>,
        reward_tokens: vector<Object<Metadata>>,
        new_durations: vector<u64>
    ) {
        let len = vector::length(&pools);

        // Verify input vectors have the same length
        assert!(vector::length(&reward_tokens) == len, 1);
        assert!(vector::length(&new_durations) == len, 1);

        let i = 0;
        while (i < len) {
            let pool = *vector::borrow(&pools, i);
            let reward_token = *vector::borrow(&reward_tokens, i);
            let new_duration = *vector::borrow(&new_durations, i);

            multi_rewards::set_rewards_duration(distributor, pool, reward_token, new_duration);
            i = i + 1;
        };
    }

    /// Complete pool setup: Create multiple pools with the same reward token
    ///
    /// @param creator - The signer of the account creating the pools
    /// @param staking_tokens - Vector of staking tokens to create pools for
    /// @param reward_token - The token to be used as a reward for all pools
    /// @param rewards_distributor - The address authorized to distribute the reward
    /// @param rewards_duration - The duration of the reward period in seconds
    ///
    /// This function creates multiple staking pools and adds the same reward token to all of them.
    /// It combines pool creation and reward token configuration in a single transaction.
    public entry fun create_pools_with_same_reward(
        creator: &signer,
        staking_tokens: vector<Object<Metadata>>,
        reward_token: Object<Metadata>,
        rewards_distributor: address,
        rewards_duration: u64
    ) {
        let pools = vector::empty<Object<StakingPool>>();

        // First create all pools
        let i = 0;
        let len = vector::length(&staking_tokens);

        while (i < len) {
            let staking_token = *vector::borrow(&staking_tokens, i);
            let pool = multi_rewards::create_staking_pool(creator, staking_token);
            vector::push_back(&mut pools, pool);
            i = i + 1;
        };

        // Then add the same reward token to all pools
        i = 0;
        while (i < len) {
            let pool = *vector::borrow(&pools, i);
            multi_rewards::add_reward(creator, pool, reward_token, rewards_distributor, rewards_duration);
            i = i + 1;
        };
    }

    /// Complete pool setup: Create multiple pools with their own reward tokens
    ///
    /// @param creator - The signer of the account creating the pools
    /// @param staking_tokens - Vector of staking tokens to create pools for
    /// @param reward_tokens - Vector of tokens to be used as rewards, one per pool
    /// @param rewards_distributors - Vector of addresses authorized to distribute rewards
    /// @param rewards_durations - Vector of durations for each reward period in seconds
    ///
    /// This function creates multiple staking pools and adds a specific reward token to each.
    /// Each pool gets exactly one reward token specified by the corresponding index in reward_tokens.
    public entry fun create_pools_with_rewards(
        creator: &signer,
        staking_tokens: vector<Object<Metadata>>,
        reward_tokens: vector<Object<Metadata>>,
        rewards_distributors: vector<address>,
        rewards_durations: vector<u64>
    ) {
        let len = vector::length(&staking_tokens);

        // Verify input vectors have the same length
        assert!(vector::length(&reward_tokens) == len, 1);
        assert!(vector::length(&rewards_distributors) == len, 1);
        assert!(vector::length(&rewards_durations) == len, 1);

        // Create each pool and add its corresponding reward token
        let i = 0;
        while (i < len) {
            let staking_token = *vector::borrow(&staking_tokens, i);
            let reward_token = *vector::borrow(&reward_tokens, i);
            let rewards_distributor = *vector::borrow(&rewards_distributors, i);
            let rewards_duration = *vector::borrow(&rewards_durations, i);

            // Create the pool
            let pool = multi_rewards::create_staking_pool(creator, staking_token);

            // Add the reward token
            multi_rewards::add_reward(creator, pool, reward_token, rewards_distributor, rewards_duration);

            i = i + 1;
        };
    }

    /// Complete pool setup: Create multiple pools with multiple reward tokens each
    ///
    /// @param creator - The signer of the account creating the pools
    /// @param staking_tokens - Vector of staking tokens to create pools for
    /// @param reward_tokens_nested - Nested vector of reward tokens for each pool
    /// @param rewards_distributors_nested - Nested vector of distributor addresses for each reward
    /// @param rewards_durations_nested - Nested vector of durations for each reward
    ///
    /// This function creates multiple pools, each with potentially multiple reward tokens.
    /// The nested vectors must be structured where the outer index corresponds to the pool,
    /// and the inner vectors must all have matching lengths for each pool.
    public entry fun create_pools_with_multiple_rewards(
        creator: &signer,
        staking_tokens: vector<Object<Metadata>>,
        reward_tokens_nested: vector<vector<Object<Metadata>>>,
        rewards_distributors_nested: vector<vector<address>>,
        rewards_durations_nested: vector<vector<u64>>
    ) {
        let pool_count = vector::length(&staking_tokens);

        // Verify input vectors have the same outer length
        assert!(vector::length(&reward_tokens_nested) == pool_count, 1);
        assert!(vector::length(&rewards_distributors_nested) == pool_count, 1);
        assert!(vector::length(&rewards_durations_nested) == pool_count, 1);

        let p = 0;
        while (p < pool_count) {
            let staking_token = *vector::borrow(&staking_tokens, p);

            // Create the pool
            let pool = multi_rewards::create_staking_pool(creator, staking_token);

            // Get the reward tokens, distributors, and durations for this pool
            let reward_tokens = vector::borrow(&reward_tokens_nested, p);
            let rewards_distributors = vector::borrow(&rewards_distributors_nested, p);
            let rewards_durations = vector::borrow(&rewards_durations_nested, p);

            let reward_count = vector::length(reward_tokens);

            // Verify inner vectors have matching lengths
            assert!(vector::length(rewards_distributors) == reward_count, 1);
            assert!(vector::length(rewards_durations) == reward_count, 1);

            // Add each reward token to the pool
            let r = 0;
            while (r < reward_count) {
                let reward_token = *vector::borrow(reward_tokens, r);
                let rewards_distributor = *vector::borrow(rewards_distributors, r);
                let rewards_duration = *vector::borrow(rewards_durations, r);

                multi_rewards::add_reward(creator, pool, reward_token, rewards_distributor, rewards_duration);

                r = r + 1;
            };

            p = p + 1;
        };
    }
}

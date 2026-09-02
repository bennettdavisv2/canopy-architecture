module canopy_views::rewards_view {
    use std::option::{Self, Option};
    use std::vector;
    use std::math64;
    use std::signer;

    use aptos_std::table::{Self, Table};

    use aptos_framework::code::PackageRegistry;
    use aptos_framework::event;
    use aptos_framework::fungible_asset::Metadata;
    use aptos_framework::object::{Self, Object};
    use aptos_framework::timestamp;

    use canopy_staking::multi_rewards::StakingPool;
    use multi_rewards_batcher::batcher_view::{
        Self,
        PoolDetails,
        UserPoolPosition,
        RewardTokenDetails
    };

    /// Error codes
    /// Not authorized to perform action
    const E_NOT_AUTHORIZED: u64 = 1;
    /// Already initialized
    const E_ALREADY_INITIALIZED: u64 = 2;
    /// Pool is already registered
    const E_POOL_ALREADY_REGISTERED: u64 = 3;
    /// Pool is not registered
    const E_POOL_NOT_REGISTERED: u64 = 4;

    const DEFAULT_POOL_LIMIT: u64 = 20;
    const MAX_POOL_LIMIT: u64 = 50;
    const DEFAULT_USER_LIMIT: u64 = 20;
    const MAX_USER_LIMIT: u64 = 50;
    const DEFAULT_REWARD_LIMIT: u64 = 20;
    const MAX_REWARD_LIMIT: u64 = 100;

    // - - - storage - - -

    /// Global configuration resource stored at @canopy_views
    struct RewardsRegistry has key {
        /// The owner of the registry
        owner: address,
        /// Vector of registered staking pools
        pool_list: vector<Object<StakingPool>>,
        /// Table mapping pool address to its index in the vector
        pool_indices: Table<Object<StakingPool>, u64>
    }

    // - - - events - - -

    #[event]
    struct AddPoolEvent has drop, store {
        pool: Object<StakingPool>
    }

    #[event]
    struct RemovePoolEvent has drop, store {
        pool: Object<StakingPool>
    }

    #[event]
    struct OwnershipTransferEvent has drop, store {
        previous_owner: address,
        new_owner: address
    }

    // - - - constructor - - -

    /// Since the package will be published under an object, the object_signer will be the package's object signer
    fun init_module(object_signer: &signer) {
        // Initialize the registry configuration
        let registry_config = RewardsRegistry {
            owner: get_deployer(),
            pool_list: vector::empty<Object<StakingPool>>(),
            pool_indices: table::new()
        };

        // Move the registry configuration to the resource account
        move_to(object_signer, registry_config);
    }

    // - - - stateful functions - - -

    /// Add a pool to the registry
    public entry fun add_pool(owner: &signer, pool: Object<StakingPool>) acquires RewardsRegistry {
        let owner_addr = signer::address_of(owner);
        let config = borrow_global_mut<RewardsRegistry>(@canopy_views);

        // Check authorization
        assert!(owner_addr == config.owner, E_NOT_AUTHORIZED);

        // Check if pool is already in the registry
        assert!(
            !table::contains(&config.pool_indices, pool),
            E_POOL_ALREADY_REGISTERED
        );

        // Add pool to the registry
        let index = vector::length(&config.pool_list);
        vector::push_back(&mut config.pool_list, pool);
        table::add(&mut config.pool_indices, pool, index);

        // Emit event
        event::emit(AddPoolEvent { pool });
    }

    /// Remove a pool from the registry
    public entry fun remove_pool(
        owner: &signer, pool: Object<StakingPool>
    ) acquires RewardsRegistry {
        let owner_addr = signer::address_of(owner);
        let config = borrow_global_mut<RewardsRegistry>(@canopy_views);

        // Check authorization
        assert!(owner_addr == config.owner, E_NOT_AUTHORIZED);

        // Check if pool is in the registry
        assert!(
            table::contains(&config.pool_indices, pool),
            E_POOL_NOT_REGISTERED
        );

        // Get the index of the pool to remove
        let index_to_remove = *table::borrow(&config.pool_indices, pool);

        // Remove from the indices table
        table::remove(&mut config.pool_indices, pool);

        // Remove from the vector by swapping with the last element for efficiency
        let last_index = vector::length(&config.pool_list) - 1;

        if (index_to_remove != last_index) {
            // Swap with the last element
            vector::swap(&mut config.pool_list, index_to_remove, last_index);

            // Update the index of the swapped element
            let swapped_pool = vector::borrow(&config.pool_list, index_to_remove);
            table::upsert(&mut config.pool_indices, *swapped_pool, index_to_remove);
        };

        // Remove the last element (which is either the target or the original last element)
        vector::pop_back(&mut config.pool_list);

        // Emit event
        event::emit(RemovePoolEvent { pool });
    }

    /// Transfer ownership of the registry
    public entry fun transfer_ownership(
        current_owner: &signer, new_owner: address
    ) acquires RewardsRegistry {
        let current_owner_addr = signer::address_of(current_owner);
        let config = borrow_global_mut<RewardsRegistry>(@canopy_views);

        // Check authorization
        assert!(
            current_owner_addr == config.owner,
            E_NOT_AUTHORIZED
        );

        // Transfer ownership
        let previous_owner = config.owner;
        config.owner = new_owner;

        // Emit event
        event::emit(OwnershipTransferEvent { previous_owner, new_owner });
    }

    #[view]
    public fun get_rewards_snapshot(
        offset: Option<u64>, limit: Option<u64>, user: Option<address>
    ): (vector<PoolDetails>, Option<vector<UserPoolPosition>>) acquires RewardsRegistry {
        let config = borrow_global<RewardsRegistry>(@canopy_views);

        // Paginate pools at the registry level first
        let paginated_pool_list =
            if (option::is_some(&offset) || option::is_some(&limit)) {
                let total_count = vector::length(&config.pool_list);
                let page_offset = clamp_offset(offset, total_count);
                let page_limit = clamp_limit(limit, DEFAULT_POOL_LIMIT, MAX_POOL_LIMIT);
                slice_vector(&config.pool_list, page_offset, page_limit)
            } else {
                config.pool_list
            };

        // Get details only for paginated pools
        let paginated_pools = batcher_view::get_pools_full_details(paginated_pool_list);

        // Get user positions if user provided (use paginated pool list)
        let user_positions =
            if (option::is_some(&user)) {
                let addr = option::extract(&mut user);
                let positions =
                    batcher_view::get_user_multiple_pools_positions(
                        addr, paginated_pool_list
                    );
                option::some(positions)
            } else {
                option::none()
            };

        (paginated_pools, user_positions)
    }

    #[view]
    public fun get_pool_details(pool: Object<StakingPool>): PoolDetails {
        batcher_view::get_pool_full_details(pool)
    }

    #[view]
    public fun get_reward_token_details(pool: Object<StakingPool>): vector<RewardTokenDetails> {
        batcher_view::get_pool_all_rewards_details(pool)
    }

    #[view]
    public fun get_user_pool_positions_by_token(
        user: address,
        staking_token: Object<Metadata>,
        offset: Option<u64>,
        limit: Option<u64>
    ): vector<UserPoolPosition> {
        let positions =
            batcher_view::get_user_pools_positions_by_token(user, staking_token);

        if (option::is_some(&offset) || option::is_some(&limit)) {
            let total_count = vector::length(&positions);
            let page_offset = clamp_offset(offset, total_count);
            let page_limit = clamp_limit(limit, DEFAULT_USER_LIMIT, MAX_USER_LIMIT);
            slice_vector(&positions, page_offset, page_limit)
        } else {
            positions
        }
    }

    #[view]
    public fun get_user_pool_positions_by_tokens(
        user: address,
        staking_tokens: vector<Object<Metadata>>,
        offset: Option<u64>,
        limit: Option<u64>
    ): vector<UserPoolPosition> {
        // Note: This function collects all positions from multiple tokens
        // We cannot optimize by paginating tokens first because each token
        // may have different numbers of positions, making offset/limit
        // semantics unclear at the token level vs position level
        let all_positions = vector::empty<UserPoolPosition>();
        let i = 0;
        let len = vector::length(&staking_tokens);
        while (i < len) {
            let token = *vector::borrow(&staking_tokens, i);
            let token_positions =
                batcher_view::get_user_pools_positions_by_token(user, token);
            let j = 0;
            let pos_len = vector::length(&token_positions);
            while (j < pos_len) {
                vector::push_back(
                    &mut all_positions, *vector::borrow(&token_positions, j)
                );
                j = j + 1;
            };
            i = i + 1;
        };

        if (option::is_some(&offset) || option::is_some(&limit)) {
            let total_count = vector::length(&all_positions);
            let page_offset = clamp_offset(offset, total_count);
            let page_limit = clamp_limit(limit, DEFAULT_USER_LIMIT, MAX_USER_LIMIT);
            slice_vector(&all_positions, page_offset, page_limit)
        } else {
            all_positions
        }
    }

    #[view]
    public fun get_user_pool_positions(
        user: address, offset: Option<u64>, limit: Option<u64>
    ): vector<UserPoolPosition> acquires RewardsRegistry {
        let config = borrow_global<RewardsRegistry>(@canopy_views);

        // Paginate pools at the registry level first
        let paginated_pool_list =
            if (option::is_some(&offset) || option::is_some(&limit)) {
                let total_count = vector::length(&config.pool_list);
                let page_offset = clamp_offset(offset, total_count);
                let page_limit = clamp_limit(limit, DEFAULT_USER_LIMIT, MAX_USER_LIMIT);
                slice_vector(&config.pool_list, page_offset, page_limit)
            } else {
                config.pool_list
            };

        // Get positions only for paginated pools
        batcher_view::get_user_multiple_pools_positions(user, paginated_pool_list)
    }

    #[view]
    public fun get_registry_overview(
        offset: Option<u64>, limit: Option<u64>, include_pools: bool
    ): (u64, bool, bool, bool, Option<vector<PoolDetails>>) acquires RewardsRegistry {
        let pools_view =
            if (!include_pools) {
                option::none<vector<PoolDetails>>()
            } else {
                let config = borrow_global<RewardsRegistry>(@canopy_views);

                // Paginate pools at the registry level first
                let paginated_pool_list =
                    if (option::is_some(&offset) || option::is_some(&limit)) {
                        let total_count = vector::length(&config.pool_list);
                        let page_offset = clamp_offset(offset, total_count);
                        let page_limit =
                            clamp_limit(limit, DEFAULT_POOL_LIMIT, MAX_POOL_LIMIT);
                        slice_vector(&config.pool_list, page_offset, page_limit)
                    } else {
                        config.pool_list
                    };

                // Get details only for paginated pools
                let pool_details =
                    batcher_view::get_pools_full_details(paginated_pool_list);
                option::some(pool_details)
            };

        (timestamp::now_seconds(), false, false, include_pools, pools_view)
    }

    fun slice_vector<T: copy>(items: &vector<T>, offset: u64, limit: u64): vector<T> {
        let len = vector::length(items);
        if (offset >= len) return vector[];

        let sliced = vector[];
        let max_count = len - offset;
        let (i, take) = (0, math64::min(max_count, limit));
        while (i < take) {
            let idx = offset + i;
            vector::push_back(&mut sliced, *vector::borrow(items, idx));
            i = i + 1;
        };

        sliced
    }

    fun clamp_limit(limit: Option<u64>, default: u64, max: u64): u64 {
        math64::min(option::get_with_default(&limit, default), max)
    }

    fun clamp_offset(offset: Option<u64>, total_count: u64): u64 {
        math64::min(option::get_with_default(&offset, 0), total_count)
    }

    // - - - registry view functions - - -

    #[view]
    /// Check if a pool is registered
    public fun is_pool_registered(pool: Object<StakingPool>): bool acquires RewardsRegistry {
        let config = borrow_global<RewardsRegistry>(@canopy_views);
        table::contains(&config.pool_indices, pool)
    }

    #[view]
    /// Get the current owner of the registry
    public fun get_owner(): address acquires RewardsRegistry {
        let config = borrow_global<RewardsRegistry>(@canopy_views);
        config.owner
    }

    #[view]
    /// Get all registered pools
    public fun get_all_pool_list(): vector<Object<StakingPool>> acquires RewardsRegistry {
        let config = borrow_global<RewardsRegistry>(@canopy_views);
        config.pool_list
    }

    #[view]
    /// Get a paginated list of registered pools
    /// @param offset - Starting index in the list
    /// @param limit - Maximum number of pools to return
    public fun get_paginated_pools(
        offset: u64, limit: u64
    ): vector<Object<StakingPool>> acquires RewardsRegistry {
        let config = borrow_global<RewardsRegistry>(@canopy_views);
        slice_vector(&config.pool_list, offset, limit)
    }

    #[view]
    /// Get pool info by address
    public fun get_pool_info(
        pool: Object<StakingPool>
    ): Option<Object<StakingPool>> acquires RewardsRegistry {
        let config = borrow_global<RewardsRegistry>(@canopy_views);

        if (!table::contains(&config.pool_indices, pool)) {
            return option::none()
        };

        let index = *table::borrow(&config.pool_indices, pool);
        option::some(*vector::borrow(&config.pool_list, index))
    }

    #[view]
    /// Get the number of registered pools
    public fun get_registered_pool_count(): u64 acquires RewardsRegistry {
        let config = borrow_global<RewardsRegistry>(@canopy_views);
        vector::length(&config.pool_list)
    }

    // - - - internal functions - - -

    fun get_deployer(): address {
        // if the package is deployed to an object,
        // the deployer is the owner of the `PackageRegistry` object.
        if (object::object_exists<PackageRegistry>(@canopy_views)) {
            let package_object =
                object::address_to_object<PackageRegistry>(@canopy_views);
            return object::owner(package_object)
        };

        @canopy_views
    }
}

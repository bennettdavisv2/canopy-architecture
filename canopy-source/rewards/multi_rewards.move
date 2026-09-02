module canopy_staking::multi_rewards {
    use std::signer;
    use std::vector;
    use std::option::{Self, Option};

    use aptos_std::table::{Self, Table};

    use aptos_framework::account::{Self, SignerCapability};
    use aptos_framework::event;
    use aptos_framework::fungible_asset::{Self, FungibleStore, Metadata};
    use aptos_framework::primary_fungible_store;
    use aptos_framework::object::{Self, ExtendRef, Object};
    use aptos_framework::timestamp;

    // Error codes

    /// Operation attempted by an unauthorized account.
    const E_NOT_AUTHORIZED: u64 = 1;
    /// Attempt to add an existing reward token to the pool.
    const E_REWARD_ALREADY_EXISTS: u64 = 2;
    /// Operation attempted with an unsupported token.
    const E_INVALID_TOKEN: u64 = 3;
    /// Withdrawal attempt exceeds user's staked balance.
    const E_INSUFFICIENT_BALANCE: u64 = 4;
    /// Attempt to update reward duration before current period end.
    const E_REWARD_PERIOD_NOT_FINISHED: u64 = 6;
    /// Invalid rewards duration specified.
    const E_INVALID_DURATION: u64 = 7;
    /// Staking attempt below minimum required amount.
    const E_STAKE_AMOUNT_TOO_LOW: u64 = 8;
    /// Attempt to withdraw zero tokens.
    const E_WITHDRAW_ZERO: u64 = 9;
    /// Attempt to exceed maximum allowed reward tokens per pool.
    const E_MAX_REWARDS_REACHED: u64 = 10;
    /// Specified reward duration exceeds maximum allowed.
    const E_EXCEEDS_MAX_DURATION: u64 = 11;
    /// Withdrawal attempt with no staked balance.
    const E_NO_BALANCE_TO_WITHDRAW: u64 = 12;
    /// Operation attempted for user with no existing data.
    const E_USER_DATA_NOT_FOUND: u64 = 13;
    /// User operation attempted on unsubscribed pool.
    const E_NOT_SUBSCRIBED: u64 = 14;
    /// Subscription attempt without staked balance.
    const E_NO_STAKED_BALANCE: u64 = 15;
    /// Subscription attempt to an already subscribed pool.
    const E_ALREADY_SUBSCRIBED: u64 = 16;
    /// User has reached maximum allowed pool subscriptions for a staking token
    const E_MAX_SUBSCRIPTIONS_REACHED: u64 = 17;
    /// No emergency withdrawal proposal exists for this pool
    const E_NO_EMERGENCY_WITHDRAW_PROPOSAL: u64 = 18;
    /// Emergency withdrawal timelock period has not elapsed yet
    const E_EMERGENCY_WITHDRAW_TIMELOCK_NOT_ELAPSED: u64 = 19;

    /// Precision factor for fixed-point calculations (1e12).
    /// Provides sufficient precision for Aptos Standard Fungible Assets,
    /// considering the max balance for a FungibleStore is u64.
    const U12_FP_PRECISION: u128 = 1_000_000_000_000;

    /// Minimum amount of tokens that can be staked. Can be reduced if need be.
    const MIN_STAKE_AMOUNT: u64 = 1_000;

    /// Maximum number of reward tokens allowed per staking pool.
    /// Limits complexity and gas costs for reward calculations and distributions.
    const MAX_REWARD_TOKENS: u64 = 20;

    /// Maximum number of staking pools for a giving staking asset that a user can subscribe to
    const MAX_SUBSCRIBED_POOLS: u64 = 50;

    /// Maximum duration for a reward period, set to 2 years (in seconds). Can be increased if need be.
    const MAX_DURATION: u64 = 86400 * 365 * 2; // 2 years

    /// Seed used for creating the resource account.
    const SEED: vector<u8> = b"MULTI_REWARDS_MODULE_SEED";

    /// This struct stores the configuration data for the multi_rewards module. It is used in an immutable (read-only)
    /// way after construction (i.e., init_module).
    struct InitConfiguration has key {
        /// Capability that allows the module to create and manage resources on behalf of itself,
        /// enabling operations like creating fungible stores for staking and rewards.
        resource_signer_cap: SignerCapability
    }

    /// This struct stores the global data for the multi_rewards module. It keeps track of all staking stores and
    /// user staked balances across all staking tokens.
    struct MultiRewardsModule has key {
        /// Maps staking tokens to their respective FungibleStore objects, allowing efficient
        /// management of staked tokens for each supported staking token.
        staking_stores: Table<Object<Metadata>, Object<FungibleStore>>,
        /// Provides a nested mapping of user addresses to their staked balances for each staking token,
        /// enabling quick lookup of a user's staked amount for any given token.
        user_staked_balances: Table<address, Table<Object<Metadata>, u64>>
    }
    #[resource_group_member(group = aptos_framework::object::ObjectGroup)]
    /// This struct represents a staking pool within the multi_rewards system. It contains all the necessary
    /// information about a specific pool, including the staking token, reward tokens and reward data
    struct StakingPool has key {
        /// The owner of the StakingPool
        owner: address,
        /// The token that users stake in this pool.
        staking_token: Object<Metadata>,
        /// A list of all reward tokens that this pool distributes to stakers.
        reward_tokens: vector<Object<Metadata>>,
        /// Maps reward tokens to their respective ManagedFungibleStore
        reward_stores: Table<Object<Metadata>, ManagedFungibleStore>,
        /// Stores the current reward data for each reward token in the pool.
        reward_data: Table<Object<Metadata>, RewardData>,
        /// The total amount of staking tokens currently staked in this pool.
        total_subscribed: u64,
        /// The extend ref for the staking pool
        pool_extend_ref: ExtendRef,
        /// Optional proposal for emergency withdrawal
        admin_withdraw_proposal: Option<AdminWithdrawProposal>
    }

    /// A wrapper structure for managing a fungible asset store with extended control capabilities.
    struct ManagedFungibleStore has store {
        /// The underlying fungible store object that holds the assets.
        store: Object<FungibleStore>,
        /// An ExtendRef that allows for authorized operations on the store, such as withdrawals.
        store_extend_ref: ExtendRef
    }

    /// This struct stores user-specific data related to their staking activities and rewards.
    struct UserData has key {
        /// Maps staking tokens to the pools a user has subscribed to, allowing quick lookup
        /// of a user's subscriptions for any given staking token.
        subscribed_pools: Table<Object<Metadata>, vector<Object<StakingPool>>>,
        /// Stores the user's reward data for each pool and reward token combination,
        /// enabling efficient tracking and updating of user rewards.
        pool_rewards: Table<Object<StakingPool>, Table<Object<Metadata>, UserRewardData>>
    }

    /// This struct stores reward-related data for a specific reward token in a pool.
    struct RewardData has store {
        /// The address authorized to distribute rewards for this token.
        rewards_distributor: address,
        /// The duration of the reward period in seconds.
        rewards_duration: u64,
        /// The timestamp when the current reward period ends.
        period_finish: u64,
        /// The timestamp of the last reward update.
        last_update_time: u64,
        /// The rate at which rewards are distributed per second. Format: U12-FP
        reward_rate: u128,
        /// The accumulated rewards per token, used for calculating individual user rewards. Format: U12-FP
        reward_per_token_stored: u128,
        /// The accumulated unallocated rewards during periods where 0 stake was subscribed to the pool
        unallocated_rewards: u64
    }

    /// This struct stores user-specific reward data for a particular reward token in a pool.
    struct UserRewardData has store, drop {
        /// The reward_per_token value when the user's rewards were last updated,
        /// used to calculate the user's share of rewards since their last update. Format: U12-FP
        reward_per_token_paid: u128,
        /// The current amount of unclaimed rewards for the user.
        rewards: u64
    }

    /// Struct to hold emergency withdrawal proposal details
    struct AdminWithdrawProposal has store, drop {
        /// Timestamp when the proposal was created
        proposed_at: u64
    }

    // - - - - - - CONSTRUCTOR FUNCTION - - - - - -

    /// Since the pkg will be published under an object the signer will be the pkg's object signer
    fun init_module(object_signer: &signer) {
        // NOTE: the object_signer address == @canopy_staking

        // Create a resource account
        let (resource_signer, resource_signer_cap) = account::create_resource_account(object_signer, SEED);

        // Store the signer capability for future use (if needed)
        move_to(object_signer, InitConfiguration { resource_signer_cap });

        // Create and move the MultiRewardsModule resource
        move_to(
            &resource_signer,
            MultiRewardsModule {
                staking_stores: table::new(),
                user_staked_balances: table::new()
            }
        );
    }

    // - - - - - - PUBLIC FUNCTIONS - - - - - -

    public entry fun entry_create_staking_pool(creator: &signer, staking_token: Object<Metadata>) acquires InitConfiguration, MultiRewardsModule {
        create_staking_pool(creator, staking_token);
    }

    /// Creates a new staking pool for a specific token.
    ///
    /// @param creator - The signer of the account creating the pool
    /// @param staking_token - The token that users will stake in this pool
    ///
    /// @return Object<StakingPool> - The newly created staking pool object
    public fun create_staking_pool(creator: &signer, staking_token: Object<Metadata>): Object<StakingPool> acquires InitConfiguration, MultiRewardsModule {

        let constructor_ref = object::create_sticky_object(@canopy_staking);
        let staking_pool_signer = object::generate_signer(&constructor_ref);
        let staking_pool_address = signer::address_of(&staking_pool_signer);

        // Ensure we have a staking store for this token
        get_or_create_staking_store(staking_token);

        let creator_addr = signer::address_of(creator);
        let pool_extend_ref = object::generate_extend_ref(&constructor_ref);

        let staking_pool = StakingPool {
            owner: creator_addr,
            staking_token,
            reward_tokens: vector::empty(),
            reward_stores: table::new(),
            reward_data: table::new(),
            total_subscribed: 0,
            pool_extend_ref,
            admin_withdraw_proposal: option::none() // Initialize as none
        };

        move_to(&staking_pool_signer, staking_pool);

        event::emit(StakingPoolCreatedEvent { pool_address: staking_pool_address, staking_token, creator: creator_addr });

        let staking_pool_obj = object::address_to_object<StakingPool>(staking_pool_address);
        staking_pool_obj
    }

    /// Adds a new reward token to an existing staking pool.
    ///
    /// @param admin - The signer of the account authorized to add rewards
    /// @param pool - The staking pool object to add the reward to
    /// @param reward_token - The token to be used as a reward
    /// @param rewards_distributor - The address authorized to distribute this reward
    /// @param rewards_duration - The duration of the reward period in seconds
    ///
    /// This function adds a new reward token to the specified staking pool.
    /// It initializes the reward data and creates a store for the reward tokens.
    /// The number of reward tokens per pool is limited to MAX_REWARD_TOKENS.
    /// Only the pool owner can add new reward tokens.
    ///
    /// Aborts if:
    /// - The caller is not the pool owner
    /// - The reward token already exists for this pool
    /// - The pool has reached the maximum number of reward tokens
    /// - The rewards duration is invalid (0 or exceeds MAX_DURATION)
    public entry fun add_reward(
        admin: &signer,
        pool: Object<StakingPool>,
        reward_token: Object<Metadata>,
        rewards_distributor: address,
        rewards_duration: u64
    ) acquires StakingPool {
        let pool_addr = object::object_address(&pool);
        let staking_pool = borrow_global_mut<StakingPool>(pool_addr);

        // Verify admin authority (this should be replaced with a proper access control system)
        assert!(signer::address_of(admin) == staking_pool.owner, E_NOT_AUTHORIZED);

        // Ensure the reward token hasn't been added before
        assert!(!table::contains(&staking_pool.reward_data, reward_token), E_REWARD_ALREADY_EXISTS);
        // the following check is redundant since if the reward_token exists then the reward_store also exists
        // assert!(!table::contains(&staking_pool.reward_stores, reward_token), E_REWARD_ALREADY_EXISTS);

        // Check if the number of reward tokens is less than the limit so we can add another
        assert!(vector::length(&staking_pool.reward_tokens) < MAX_REWARD_TOKENS, E_MAX_REWARDS_REACHED);

        assert!(rewards_duration != 0, E_INVALID_DURATION);
        assert!(rewards_duration <= MAX_DURATION, E_EXCEEDS_MAX_DURATION);

        // Add the reward token
        vector::push_back(&mut staking_pool.reward_tokens, reward_token);

        // Initialize RewardData for the new reward token
        let reward_data = RewardData {
            rewards_distributor,
            rewards_duration,
            period_finish: 0,
            last_update_time: 0,
            reward_rate: 0,
            reward_per_token_stored: 0,
            unallocated_rewards: 0
        };

        table::add(&mut staking_pool.reward_data, reward_token, reward_data);

        // Create a new object for the reward store
        let store_constructor_ref = object::create_object(object::object_address(&pool));
        // NOTE: we attempt to create_store for the reward_token for the staking_pool
        // however if a store already exists in the staking_pool.reward_stores then we abort with E_REWARD_ALREADY_EXISTS
        let reward_store = ManagedFungibleStore {
            store: fungible_asset::create_store(&store_constructor_ref, reward_token),
            store_extend_ref: object::generate_extend_ref(&store_constructor_ref)
        };

        table::add(&mut staking_pool.reward_stores, reward_token, reward_store);

        event::emit(
            RewardAddedEvent { pool_address: object::object_address(&pool), reward_token, rewards_distributor, rewards_duration }
        );
    }

    /// Stakes tokens into the system, adding them to all subscribed pools for the given staking_token
    ///
    /// @param account - The signer of the account staking tokens
    /// @param staking_token - The token being staked
    /// @param amount - The amount of tokens to stake
    ///
    /// This function allows users to stake tokens into the system. The staked amount
    /// is distributed across all pools the user is subscribed to for the given staking token.
    /// It updates the total subscribed amount for each affected pool and the user's staked balance.
    ///
    /// The function performs the following key operations:
    /// 1. Updates rewards for all subscribed pools
    /// 2. Increases the total subscribed amount for each pool
    /// 3. Transfers tokens from the user to the module's staking store
    /// 4. Updates the user's staked balance in the global state
    ///
    /// Aborts if:
    /// - The staking amount is less than MIN_STAKE_AMOUNT
    /// - The user has insufficient balance of the staking token
    public entry fun stake(
        account: &signer, staking_token: Object<Metadata>, amount: u64
    ) acquires InitConfiguration, MultiRewardsModule, UserData, StakingPool {
        assert!(amount >= MIN_STAKE_AMOUNT, E_STAKE_AMOUNT_TOO_LOW);

        let user_addr = signer::address_of(account);
        let rs_address = get_rs_address();

        // Ensure UserData exists
        if (!exists<UserData>(user_addr)) {
            move_to(
                account,
                UserData {
                    subscribed_pools: table::new(),
                    pool_rewards: table::new()
                }
            );
        };

        let pools = vector::empty<Object<StakingPool>>();
        {
            // Get all subscribed pools of the given staking token
            let user_data = borrow_global<UserData>(user_addr);
            if (table::contains(&user_data.subscribed_pools, staking_token)) {
                let subscribed_pools = table::borrow(&user_data.subscribed_pools, staking_token);
                let i = 0;
                let len = vector::length(subscribed_pools);
                while (i < len) {
                    let pool_obj = *vector::borrow(subscribed_pools, i);
                    vector::push_back(&mut pools, pool_obj);
                    i = i + 1;
                };
            };
        };

        // Update total_subscribed for all subscribed pools
        let i = 0;
        let len = vector::length(&pools);
        while (i < len) {
            let pool_obj = vector::borrow(&pools, i);
            update_reward(pool_obj, user_addr);
            let pool = borrow_global_mut<StakingPool>(object::object_address(pool_obj));
            pool.total_subscribed = pool.total_subscribed + amount;
            i = i + 1;
        };

        // Transfer tokens from user to the module's staking store
        let staking_store = get_or_create_staking_store(staking_token);
        let staked_tokens = primary_fungible_store::withdraw(account, staking_token, amount);
        fungible_asset::deposit(staking_store, staked_tokens);

        let mr_module = borrow_global_mut<MultiRewardsModule>(rs_address);

        // Update user's staked balance
        if (!table::contains(&mr_module.user_staked_balances, user_addr)) {
            let user_balances = table::new();
            table::add(&mut user_balances, staking_token, amount);
            table::add(&mut mr_module.user_staked_balances, user_addr, user_balances);
        } else {
            let user_balances = table::borrow_mut(&mut mr_module.user_staked_balances, user_addr);
            if (!table::contains(user_balances, staking_token)) {
                table::add(user_balances, staking_token, amount);
            } else {
                let balance = table::borrow_mut(user_balances, staking_token);
                *balance = *balance + amount;
            };
        };

        event::emit(StakeEvent { user: user_addr, staking_token, amount });
    }

    /// Withdraws staked tokens from the system.
    ///
    /// @param account - The signer of the account withdrawing tokens
    /// @param staking_token - The token being withdrawn
    /// @param amount - The amount of tokens to withdraw
    ///
    /// This function allows users to withdraw their staked tokens. It processes the withdrawal
    /// across all pools the user is subscribed to for the given staking token. The function
    /// updates rewards, adjusts pool totals, and transfers tokens back to the user.
    ///
    /// Key operations:
    /// 1. Updates rewards for all affected pools
    /// 2. Checks the user's staked balance
    /// 3. Reduces the user's staked balance and pool totals
    /// 4. Transfers tokens from the module's store to the user
    ///
    /// Aborts if:
    /// - The withdrawal amount is zero
    /// - The user has no staked balance
    /// - The withdrawal amount exceeds the user's staked balance
    /// - The user data doesn't exist
    public entry fun withdraw(
        account: &signer, staking_token: Object<Metadata>, amount: u64
    ) acquires InitConfiguration, MultiRewardsModule, UserData, StakingPool {
        assert!(amount != 0, E_WITHDRAW_ZERO);
        let user_addr = signer::address_of(account);
        let rs_address = get_rs_address();

        // Ensure UserData exists
        assert!(exists<UserData>(user_addr), E_USER_DATA_NOT_FOUND);

        let pools = vector::empty<Object<StakingPool>>();
        {
            // Update rewards for all subscribed pools of the given staking token
            let user_data = borrow_global<UserData>(user_addr);
            if (table::contains(&user_data.subscribed_pools, staking_token)) {
                let subscribed_pools = table::borrow(&user_data.subscribed_pools, staking_token);
                let i = 0;
                let len = vector::length(subscribed_pools);
                while (i < len) {
                    let pool_obj = *vector::borrow(subscribed_pools, i);
                    vector::push_back(&mut pools, pool_obj);
                    i = i + 1;
                };
            };
        };

        let i = 0;
        let len = vector::length(&pools);
        while (i < len) {
            let pool_obj = vector::borrow(&pools, i);
            update_reward(pool_obj, user_addr);
            i = i + 1;
        };

        // Check user's staked balance
        let mr_module = borrow_global_mut<MultiRewardsModule>(rs_address);
        let user_balances = table::borrow_mut(&mut mr_module.user_staked_balances, user_addr);
        let user_balance = table::borrow_mut(user_balances, staking_token);
        assert!(*user_balance >= amount, E_INSUFFICIENT_BALANCE);

        // Update user's staked balance
        *user_balance = *user_balance - amount;

        // Transfer tokens from module's staking store to user
        let staking_store = get_or_create_staking_store(staking_token);
        let withdrawn_tokens = fungible_asset::withdraw(&get_resource_signer(), staking_store, amount);
        primary_fungible_store::deposit(user_addr, withdrawn_tokens);

        event::emit(WithdrawEvent { user: user_addr, staking_token, amount });

        // Update total subscribed for each pool
        i = 0;
        while (i < len) {
            let pool_obj = vector::borrow(&pools, i);
            let pool = borrow_global_mut<StakingPool>(object::object_address(pool_obj));
            pool.total_subscribed = pool.total_subscribed - amount;
            i = i + 1;
        };
    }

    /// Claims accrued rewards for a user across all subscribed pools for a specific staking token.
    ///
    /// @param account - The signer of the account claiming rewards
    /// @param staking_token - The staking token associated with the pools to claim rewards from
    ///
    /// This function allows users to claim their accrued rewards from all pools they're subscribed to
    /// for a given staking token. It processes rewards for each subscribed pool and each reward token
    /// within those pools.
    ///
    /// Key operations:
    /// 1. Retrieves all pools the user is subscribed to for the given staking token
    /// 2. Updates rewards for each pool to ensure accurate reward calculation
    /// 3. For each pool and reward token, calculates and transfers accrued rewards
    /// 4. Resets the user's reward data after claiming
    ///
    /// Aborts if:
    /// - The user data doesn't exist
    /// - The user is not subscribed to any pools for the given staking token
    public entry fun claim_reward(account: &signer, staking_token: Object<Metadata>) acquires InitConfiguration, MultiRewardsModule, UserData, StakingPool {
        let user_addr = signer::address_of(account);

        // Ensure UserData exists
        assert!(exists<UserData>(user_addr), E_USER_DATA_NOT_FOUND);

        // Get subscribed pools
        let subscribed_pools = vector::empty<Object<StakingPool>>();
        {
            let user_data = borrow_global<UserData>(user_addr);
            assert!(table::contains(&user_data.subscribed_pools, staking_token), E_NOT_SUBSCRIBED);
            let pools = table::borrow(&user_data.subscribed_pools, staking_token);
            let i = 0;
            let len = vector::length(pools);
            while (i < len) {
                vector::push_back(&mut subscribed_pools, *vector::borrow(pools, i));
                i = i + 1;
            };
        };

        // Update rewards for all pools
        let i = 0;
        let pools_len = vector::length(&subscribed_pools);
        while (i < pools_len) {
            let pool_obj = vector::borrow(&subscribed_pools, i);
            update_reward(pool_obj, user_addr);
            i = i + 1;
        };

        // Claim rewards
        i = 0;
        while (i < pools_len) {
            let pool_obj = vector::borrow(&subscribed_pools, i);
            let pool_addr = object::object_address(pool_obj);
            let staking_pool = borrow_global<StakingPool>(pool_addr);

            let j = 0;
            let reward_tokens_len = vector::length(&staking_pool.reward_tokens);
            while (j < reward_tokens_len) {
                let reward_token = *vector::borrow(&staking_pool.reward_tokens, j);

                let reward_amount = {
                    let user_data = borrow_global_mut<UserData>(user_addr);
                    if (table::contains(&user_data.pool_rewards, *pool_obj)
                        && table::contains(table::borrow(&user_data.pool_rewards, *pool_obj), reward_token)) {
                        let pool_rewards = table::borrow_mut(&mut user_data.pool_rewards, *pool_obj);
                        let user_reward_data = table::borrow_mut(pool_rewards, reward_token);
                        let amount = user_reward_data.rewards;
                        user_reward_data.rewards = 0; // Reset reward to 0 after claiming
                        amount
                    } else { 0 }
                };

                if (reward_amount != 0) {
                    let reward_store = table::borrow(&staking_pool.reward_stores, reward_token);
                    let store_signer = &object::generate_signer_for_extending(&reward_store.store_extend_ref);
                    let withdrawn_tokens = fungible_asset::withdraw(store_signer, reward_store.store, reward_amount);
                    primary_fungible_store::deposit(user_addr, withdrawn_tokens);

                    event::emit(
                        RewardClaimedEvent { pool_address: pool_addr, user: user_addr, reward_token, reward_amount }
                    );
                };

                j = j + 1;
            };

            i = i + 1;
        };
    }

    /// Notifies the system of new rewards available for distribution in a specific pool.
    ///
    /// @param distributor - The signer of the account authorized to distribute rewards
    /// @param pool - The staking pool object to add rewards to
    /// @param reward_token - The token being added as a reward
    /// @param reward_amount - The amount of reward tokens to add
    ///
    /// This function allows an authorized distributor to add new rewards to a specific pool.
    /// It updates the reward data, transfers the reward tokens to the pool, and recalculates
    /// the reward rate for the current or new reward period.
    ///
    /// Key operations:
    /// 1. Verifies the distributor's authorization
    /// 2. Updates global reward state
    /// 3. Transfers reward tokens to the pool
    /// 4. Calculates and updates the new reward rate and period
    /// 5. Handles any unallocated rewards from previous periods
    ///
    /// The reward rate is calculated to distribute the new rewards evenly over the reward duration,
    /// taking into account any remaining rewards from the current period if it's ongoing.
    ///
    /// Aborts if:
    /// - The distributor is not authorized for the given reward token
    /// - The reward token is not supported by the pool
    public entry fun notify_reward_amount(
        distributor: &signer,
        pool: Object<StakingPool>,
        reward_token: Object<Metadata>,
        reward_amount: u64
    ) acquires InitConfiguration, MultiRewardsModule, StakingPool, UserData {
        let pool_address = object::object_address(&pool);

        // Verify the distributor is authorized
        {
            let staking_pool = borrow_global<StakingPool>(pool_address);
            let reward_data = table::borrow(&staking_pool.reward_data, reward_token);
            assert!(
                signer::address_of(distributor) == reward_data.rewards_distributor,
                E_NOT_AUTHORIZED
            );
        };

        // Update reward for address zero (global update)
        update_reward(&pool, @0x0);

        let current_time = timestamp::now_seconds();

        // Transfer reward tokens to the pool
        {
            let staking_pool = borrow_global<StakingPool>(pool_address);
            let reward_store = table::borrow(&staking_pool.reward_stores, reward_token);
            let reward_tokens = primary_fungible_store::withdraw(distributor, reward_token, reward_amount);
            fungible_asset::deposit(reward_store.store, reward_tokens);
        };

        // Update reward data
        {
            let staking_pool = borrow_global_mut<StakingPool>(pool_address);
            let reward_data = table::borrow_mut(&mut staking_pool.reward_data, reward_token);

            let unallocated = reward_data.unallocated_rewards;
            let reward_amount_with_unallocated = ((reward_amount + unallocated) as u128);
            reward_data.unallocated_rewards = 0;

            if (current_time >= reward_data.period_finish) {
                reward_data.reward_rate = (reward_amount_with_unallocated * U12_FP_PRECISION) / (reward_data.rewards_duration as u128);
            } else {
                let remaining = reward_data.period_finish - current_time;
                let leftover_u12 = (remaining as u128) * reward_data.reward_rate;
                reward_data.reward_rate = ((reward_amount_with_unallocated * U12_FP_PRECISION) + leftover_u12)
                    / (reward_data.rewards_duration as u128);
            };

            reward_data.last_update_time = current_time;
            reward_data.period_finish = current_time + reward_data.rewards_duration;
        };

        {
            let staking_pool = borrow_global<StakingPool>(pool_address);
            let reward_data = table::borrow(&staking_pool.reward_data, reward_token);
            event::emit(
                RewardNotifiedEvent {
                    pool_address,
                    reward_token,
                    reward_amount,
                    reward_rate: reward_data.reward_rate,
                    period_finish: reward_data.period_finish
                }
            );
        };
    }

    /// Updates the reward duration for a specific reward token in a staking pool.
    ///
    /// @param distributor - The signer of the account authorized to modify reward settings
    /// @param pool - The staking pool object to modify
    /// @param reward_token - The reward token whose duration is being updated
    /// @param new_duration - The new duration for the reward period, in seconds
    ///
    /// This function allows an authorized distributor to change the duration of the reward period
    /// for a specific reward token in a given pool. The new duration affects future reward distributions.
    ///
    /// Key operations:
    /// 1. Verifies the distributor's authorization
    /// 2. Checks that the current reward period has finished
    /// 3. Updates the rewards_duration for the specified reward token
    ///
    /// Aborts if:
    /// - The distributor is not authorized for the given reward token
    /// - The new duration is 0 or exceeds MAX_DURATION
    /// - The current reward period has not yet finished
    ///
    /// Note: This function can only be called after the current reward period has ended.
    /// It affects the distribution of future rewards and does not impact currently accruing rewards.
    public entry fun set_rewards_duration(
        distributor: &signer,
        pool: Object<StakingPool>,
        reward_token: Object<Metadata>,
        new_duration: u64
    ) acquires StakingPool {
        let pool_addr = object::object_address(&pool);

        {
            let staking_pool = borrow_global<StakingPool>(pool_addr);
            let reward_data = table::borrow(&staking_pool.reward_data, reward_token);
            assert!(
                signer::address_of(distributor) == reward_data.rewards_distributor,
                E_NOT_AUTHORIZED
            );
        };

        assert!(new_duration != 0, E_INVALID_DURATION);
        assert!(new_duration <= MAX_DURATION, E_EXCEEDS_MAX_DURATION);

        let staking_pool = borrow_global_mut<StakingPool>(pool_addr);
        let reward_data = table::borrow_mut(&mut staking_pool.reward_data, reward_token);

        assert!(timestamp::now_seconds() > reward_data.period_finish, E_REWARD_PERIOD_NOT_FINISHED);

        reward_data.rewards_duration = new_duration;

        event::emit(RewardsDurationUpdatedEvent { pool_address: pool_addr, reward_token, new_duration });
    }

    /// Performs an emergency withdrawal of all staked tokens for a user.
    ///
    /// @param account - The signer of the account performing the emergency withdrawal
    /// @param staking_token - The token to be withdrawn
    ///
    /// This function allows a user to withdraw all of their staked tokens of a specific type
    /// in an emergency situation, bypassing normal withdrawal restrictions and reward updates.
    ///
    /// Key operations:
    /// 1. Retrieves the user's total staked balance for the specified token
    /// 2. Sets the user's staked balance to 0
    /// 3. Transfers all staked tokens from the module's store back to the user
    /// 4. Updates the total subscribed amount for all affected pools
    ///
    /// Important notes:
    /// - This function does not update or distribute any accrued rewards
    /// - It's designed for use in emergency situations only
    /// - Affects all pools the user is subscribed to for the given staking token
    ///
    /// Aborts if:
    /// - The user has no staked balance for the specified token
    /// - The user data doesn't exist
    ///
    /// Warning: Using this function will result in the loss of any unclaimed rewards.
    public entry fun emergency_withdraw(
        account: &signer, staking_token: Object<Metadata>
    ) acquires InitConfiguration, MultiRewardsModule, UserData, StakingPool {
        let user_addr = signer::address_of(account);
        let rs_address = get_rs_address();

        // Ensure UserData exists
        assert!(exists<UserData>(user_addr), E_USER_DATA_NOT_FOUND);

        let mr_module = borrow_global_mut<MultiRewardsModule>(rs_address);

        // Get user balance
        let user_balances = table::borrow_mut(&mut mr_module.user_staked_balances, user_addr);
        assert!(table::contains(user_balances, staking_token), E_NO_BALANCE_TO_WITHDRAW);

        let user_balance = table::borrow_mut(user_balances, staking_token);
        let withdraw_amount = *user_balance;

        // Ensure user has a balance to withdraw
        assert!(withdraw_amount != 0, E_NO_BALANCE_TO_WITHDRAW);

        // Set user balance to 0 instead of deleting
        *user_balance = 0;

        // Transfer tokens from module's staking store to user
        let staking_store = get_or_create_staking_store(staking_token);
        let withdrawn_tokens = fungible_asset::withdraw(&get_resource_signer(), staking_store, withdraw_amount);
        primary_fungible_store::deposit(user_addr, withdrawn_tokens);

        event::emit(EmergencyWithdrawEvent { user: user_addr, staking_token, amount: withdraw_amount });

        // Update total subscribed for each affected pool
        let user_data = borrow_global<UserData>(user_addr);
        if (table::contains(&user_data.subscribed_pools, staking_token)) {
            let subscribed_pools = table::borrow(&user_data.subscribed_pools, staking_token);
            let i = 0;
            let len = vector::length(subscribed_pools);
            while (i < len) {
                let pool_obj = *vector::borrow(subscribed_pools, i);
                let pool = borrow_global_mut<StakingPool>(object::object_address(&pool_obj));
                pool.total_subscribed = pool.total_subscribed - withdraw_amount;
                i = i + 1;
            };
        };
    }

    /// Subscribes a user to a specific staking pool.
    ///
    /// @param user - The signer of the account subscribing to the pool
    /// @param pool - The staking pool object to subscribe to
    ///
    /// This function allows a user to subscribe to a staking pool, enabling them to earn rewards
    /// from that pool based on their staked amount of the pool's staking token.
    ///
    /// Key operations:
    /// 1. Verifies the user has a non-zero staked balance of the pool's staking token
    /// 2. Updates rewards for the pool to ensure accurate starting point for the new subscriber
    /// 3. Adds the pool to the user's list of subscribed pools for the staking token
    /// 4. Increases the pool's total subscribed amount by the user's current stake
    ///
    /// Important notes:
    /// - Users must have staked tokens before subscribing to a pool
    /// - Subscription is necessary to start accruing rewards from a specific pool
    /// - Users can be subscribed to multiple pools for the same staking token
    ///
    /// Aborts if:
    /// - The user has no staked balance for the pool's staking token
    /// - The user is already subscribed to the pool
    /// - The user data doesn't exist (i.e., user hasn't staked before)
    ///
    /// Note: Subscribing does not automatically stake tokens. Users must stake tokens separately.
    public entry fun subscribe(user: &signer, pool: Object<StakingPool>) acquires InitConfiguration, MultiRewardsModule, UserData, StakingPool {
        let user_addr = signer::address_of(user);
        let pool_addr = object::object_address(&pool);
        let rs_address = get_rs_address();

        // Get the staking token for this pool
        let staking_pool = borrow_global<StakingPool>(pool_addr);
        let staking_token = staking_pool.staking_token;

        // Verify user has a staked balance
        let mr_module = borrow_global<MultiRewardsModule>(rs_address);
        assert!(table::contains(&mr_module.user_staked_balances, user_addr), E_NO_STAKED_BALANCE);
        let user_balances = table::borrow(&mr_module.user_staked_balances, user_addr);
        assert!(table::contains(user_balances, staking_token), E_NO_STAKED_BALANCE);
        let staked_balance = *table::borrow(user_balances, staking_token);
        assert!(staked_balance != 0, E_NO_STAKED_BALANCE);

        // Ensure UserData exists
        if (!exists<UserData>(user_addr)) {
            move_to(
                user,
                UserData {
                    subscribed_pools: table::new(),
                    pool_rewards: table::new()
                }
            );
        };

        {
            let user_data = borrow_global_mut<UserData>(user_addr);

            // Check if user is already subscribed
            if (!table::contains(&user_data.subscribed_pools, staking_token)) {
                table::add(&mut user_data.subscribed_pools, staking_token, vector::empty());
            };
            let subscribed_pools = table::borrow_mut(&mut user_data.subscribed_pools, staking_token);
            assert!(!vector::contains(subscribed_pools, &pool), E_ALREADY_SUBSCRIBED);
            assert!(vector::length(subscribed_pools) < MAX_SUBSCRIBED_POOLS, E_MAX_SUBSCRIPTIONS_REACHED);

            // Initialize user's reward data for this pool
            if (!table::contains(&user_data.pool_rewards, pool)) {
                table::add(&mut user_data.pool_rewards, pool, table::new());
            };
        };

        update_reward(&pool, user_addr);

        let user_data = borrow_global_mut<UserData>(user_addr);
        let subscribed_pools = table::borrow_mut(&mut user_data.subscribed_pools, staking_token);

        // Add pool to user's subscribed pools
        vector::push_back(subscribed_pools, pool);

        // Update pool's total_subscribed amount
        let staking_pool = borrow_global_mut<StakingPool>(pool_addr);
        staking_pool.total_subscribed = staking_pool.total_subscribed + staked_balance;

        event::emit(SubscriptionEvent { user: user_addr, pool_address: pool_addr, staking_token });
    }

    /// Unsubscribes a user from a specific staking pool.
    ///
    /// @param user - The signer of the account unsubscribing from the pool
    /// @param pool - The staking pool object to unsubscribe from
    ///
    /// This function allows a user to unsubscribe from a staking pool, stopping the accrual of rewards
    /// from that pool for their staked tokens.
    ///
    /// Key operations:
    /// 1. Verifies the user is currently subscribed to the pool
    /// 2. Updates rewards to ensure all accrued rewards are accounted for before unsubscribing
    /// 3. Decreases the pool's total subscribed amount by the user's current stake
    /// 4. Removes the pool from the user's list of subscribed pools
    /// 5. Claims and transfers any outstanding rewards to the user
    /// 6. Cleans up the user's reward data for the pool
    ///
    /// Important notes:
    /// - Unsubscribing does not automatically unstake tokens
    /// - Any unclaimed rewards are automatically claimed during unsubscription
    /// - The user's staked balance remains unchanged, but stops earning rewards from this pool
    ///
    /// Aborts if:
    /// - The user is not subscribed to the pool
    /// - The user data doesn't exist
    ///
    /// Note: Users can unsubscribe from a pool while keeping their tokens staked in the system.
    public entry fun unsubscribe(user: &signer, pool: Object<StakingPool>) acquires InitConfiguration, MultiRewardsModule, UserData, StakingPool {
        let user_addr = signer::address_of(user);
        let pool_addr = object::object_address(&pool);

        // Get the staking token for this pool
        let staking_pool = borrow_global<StakingPool>(pool_addr);
        let staking_token = staking_pool.staking_token;

        let subscribed_pool_index: u64;

        {
            // Ensure UserData exists
            assert!(exists<UserData>(user_addr), E_USER_DATA_NOT_FOUND);
            let user_data = borrow_global_mut<UserData>(user_addr);

            // Verify that the user is subscribed to this pool
            assert!(table::contains(&user_data.subscribed_pools, staking_token), E_NOT_SUBSCRIBED);
            let subscribed_pools = table::borrow_mut(&mut user_data.subscribed_pools, staking_token);
            let (is_subscribed, index) = vector::index_of(subscribed_pools, &pool);
            subscribed_pool_index = index;
            assert!(is_subscribed, E_NOT_SUBSCRIBED);
        };

        // Update rewards before unsubscribing
        update_reward(&pool, user_addr);

        let user_data = borrow_global_mut<UserData>(user_addr);

        // Get user's staked balance
        let rs_address = get_rs_address();
        let mr_module = borrow_global<MultiRewardsModule>(rs_address);
        let user_balances = table::borrow(&mr_module.user_staked_balances, user_addr);
        let staked_balance = *table::borrow(user_balances, staking_token);

        // Update pool's total_subscribed amount
        let staking_pool = borrow_global_mut<StakingPool>(pool_addr);
        staking_pool.total_subscribed = staking_pool.total_subscribed - staked_balance;

        let subscribed_pools = table::borrow_mut(&mut user_data.subscribed_pools, staking_token);
        // Remove the pool from user's subscribed pools
        vector::remove(subscribed_pools, subscribed_pool_index);

        // Claim rewards for this staking pool then clean up user's reward data for this pool
        let pool_rewards = table::borrow_mut(&mut user_data.pool_rewards, pool);
        let reward_tokens = &staking_pool.reward_tokens;
        let i = 0;
        let len = vector::length(reward_tokens);
        while (i < len) {
            let reward_token = vector::borrow(reward_tokens, i);
            if (table::contains(pool_rewards, *reward_token)) {
                let user_reward_data = table::borrow_mut(pool_rewards, *reward_token);
                let reward_amount = user_reward_data.rewards;
                if (reward_amount != 0) {
                    user_reward_data.rewards = 0;
                    let reward_store = table::borrow(&staking_pool.reward_stores, *reward_token);
                    let store_signer = &object::generate_signer_for_extending(&reward_store.store_extend_ref);
                    let withdrawn_tokens = fungible_asset::withdraw(store_signer, reward_store.store, reward_amount);
                    primary_fungible_store::deposit(user_addr, withdrawn_tokens);

                    event::emit(
                        RewardClaimedEvent { pool_address: pool_addr, user: user_addr, reward_token: *reward_token, reward_amount }
                    );
                };
                table::remove(pool_rewards, *reward_token);
            };
            i = i + 1;
        };
        event::emit(UnsubscriptionEvent { user: user_addr, pool_address: pool_addr, staking_token });
    }

    /// Proposes an emergency withdrawal of reward tokens from a specific pool
    /// @param admin - The signer of the account proposing the emergency withdrawal (must be pool owner)
    /// @param pool - The staking pool to withdraw rewards from
    /// @param recipient - Address to receive the withdrawn funds
    ///
    /// This function can only be called by the pool owner and creates or overwrites an existing proposal.
    /// After proposal, a timelock period must pass before execution.
    public entry fun propose_admin_withdrawal(
        admin: &signer,
        pool: Object<StakingPool>
    ) acquires StakingPool {
        let pool_addr = object::object_address(&pool);
        let staking_pool = borrow_global_mut<StakingPool>(pool_addr);

        // Verify admin authority
        assert!(signer::address_of(admin) == staking_pool.owner, E_NOT_AUTHORIZED);

        // Create and store proposal
        let current_time = timestamp::now_seconds();
        let proposal = AdminWithdrawProposal {
            proposed_at: current_time
        };

        // Store the proposal in the StakingPool
        option::fill(&mut staking_pool.admin_withdraw_proposal, proposal);

        event::emit(AdminWithdrawalProposedEvent {
            pool_address: pool_addr,
            proposed_at: current_time
        });
    }

    /// Clears an emergency withdrawal proposal for a specific pool
    /// @param admin - The signer of the account clearing the proposal (must be pool owner)
    /// @param pool - The staking pool for which to clear the proposal
    ///
    /// This function can only be called by the pool owner and removes an existing proposal.
    public entry fun clear_admin_withdrawal_proposal(
        admin: &signer,
        pool: Object<StakingPool>
    ) acquires StakingPool {
        let pool_addr = object::object_address(&pool);
        let staking_pool = borrow_global_mut<StakingPool>(pool_addr);

        // Verify admin authority
        assert!(signer::address_of(admin) == staking_pool.owner, E_NOT_AUTHORIZED);

        // Verify proposal exists
        assert!(option::is_some(&staking_pool.admin_withdraw_proposal), E_NO_EMERGENCY_WITHDRAW_PROPOSAL);

        // Remove the proposal
        let AdminWithdrawProposal { proposed_at: _ } = option::extract(&mut staking_pool.admin_withdraw_proposal);

        event::emit(AdminWithdrawalClearedEvent {
            pool_address: pool_addr,
            cleared_by: signer::address_of(admin)
        });
    }

    /// Executes an emergency withdrawal if timelock has elapsed
    /// @param pool - The staking pool to withdraw rewards from
    ///
    /// This function:
    /// - Verifies proposal exists and timelock has elapsed
    /// - Withdraws all reward tokens to the specified recipient
    /// - Clears the proposal after execution
    public entry fun execute_admin_withdrawal(
        pool: Object<StakingPool>
    ) acquires StakingPool {
        let pool_addr = object::object_address(&pool);
        let staking_pool = borrow_global_mut<StakingPool>(pool_addr);

        // Verify proposal exists
        assert!(option::is_some(&staking_pool.admin_withdraw_proposal), E_NO_EMERGENCY_WITHDRAW_PROPOSAL);

        // Extract proposal
        let proposal = option::extract(&mut staking_pool.admin_withdraw_proposal);
        let AdminWithdrawProposal { proposed_at } = proposal;

        // Verify timelock elapsed (6 months = 15,552,000 seconds)
        let current_time = timestamp::now_seconds();
        assert!(current_time >= proposed_at + 15552000, E_EMERGENCY_WITHDRAW_TIMELOCK_NOT_ELAPSED);

        // Get the recipient (pool owner)
        let recipient = staking_pool.owner;

        // Withdraw all reward tokens
        let total_withdrawn_tokens = vector::empty<Object<Metadata>>();
        let total_withdrawn_amounts = vector::empty<u64>();

        let i = 0;
        let len = vector::length(&staking_pool.reward_tokens);

        while (i < len) {
            let reward_token = *vector::borrow(&staking_pool.reward_tokens, i);
            let reward_store = table::borrow(&staking_pool.reward_stores, reward_token);
            let store_signer = &object::generate_signer_for_extending(&reward_store.store_extend_ref);
            let balance = fungible_asset::balance(reward_store.store);

            if (balance > 0) {
                let withdrawn_tokens = fungible_asset::withdraw(store_signer, reward_store.store, balance);
                primary_fungible_store::deposit(recipient, withdrawn_tokens);

                vector::push_back(&mut total_withdrawn_tokens, reward_token);
                vector::push_back(&mut total_withdrawn_amounts, balance);
            };

            i = i + 1;
        };

        event::emit(AdminWithdrawalExecutedEvent {
            pool_address: pool_addr,
            recipient,
            tokens: total_withdrawn_tokens,
            amounts: total_withdrawn_amounts
        });
    }

    /// Sweeps a specific token that is not linked to a specific pool (as staking token or reward token)
    /// @param admin - The signer of the account that will receive the swept tokens
    /// @param pool - The specific staking pool to check against
    /// @param token - The token to sweep
    ///
    /// This function allows the pool owner to withdraw any tokens held in the pool's primary store.
    /// The withdrawn tokens are transferred to the pool owner's account and a TokenSweptEvent is emitted.
    public entry fun sweep_token(admin: &signer, pool: Object<StakingPool>, token: Object<Metadata>) acquires StakingPool {
        let admin_addr = signer::address_of(admin);
        let pool_addr = object::object_address(&pool);
        let staking_pool = borrow_global<StakingPool>(pool_addr);

        // Verify admin authority (only pool owner can sweep tokens)
        assert!(admin_addr == staking_pool.owner, E_NOT_AUTHORIZED);

        // Check if there's a balance to sweep
        let balance = primary_fungible_store::balance(pool_addr, token);
        if (balance > 0) {
            // Use object::generate_signer_for_extending to get a signer for the pool
            let pool_signer = object::generate_signer_for_extending(&staking_pool.pool_extend_ref);

            // Withdraw tokens using the pool signer
            let tokens = primary_fungible_store::withdraw(&pool_signer, token, balance);

            // Deposit tokens to admin
            let admin_addr = signer::address_of(admin);
            primary_fungible_store::deposit(admin_addr, tokens);

            // Emit event
            event::emit(TokenSweptEvent {
                pool_address: pool_addr,
                token,
                amount: balance
            });
        };
    }

    // - - - - - - INTERNAL FUNCTIONS - - - - - -

    /// Get or create a staking store for a token
    fun get_or_create_staking_store(staking_token: Object<Metadata>): Object<FungibleStore> acquires InitConfiguration, MultiRewardsModule {
        let rs_address = get_rs_address();
        let mr_module = borrow_global_mut<MultiRewardsModule>(rs_address);

        if (!table::contains(&mr_module.staking_stores, staking_token)) {
            let store_constructor_ref = object::create_object(rs_address);
            let new_store = fungible_asset::create_store(&store_constructor_ref, staking_token);
            table::add(&mut mr_module.staking_stores, staking_token, new_store);
        };
        *table::borrow(&mr_module.staking_stores, staking_token)
    }

    fun update_reward(pool_obj: &Object<StakingPool>, account: address) acquires InitConfiguration, MultiRewardsModule, StakingPool, UserData {
        let pool_addr = object::object_address(pool_obj);
        let reward_tokens = vector::empty<Object<Metadata>>();

        {
            let pool = borrow_global<StakingPool>(pool_addr);
            let i = 0;
            let len = vector::length(&pool.reward_tokens);
            while (i < len) {
                let reward_token = *vector::borrow(&pool.reward_tokens, i);
                vector::push_back(&mut reward_tokens, reward_token);
                i = i + 1;
            };
        };

        let i = 0;
        let len = vector::length(&reward_tokens);
        while (i < len) {
            let reward_token = vector::borrow(&reward_tokens, i);
            let new_reward_per_token: u128;

            // Update reward data
            {
                let pool = borrow_global_mut<StakingPool>(pool_addr);
                new_reward_per_token = reward_per_token(pool, *reward_token);
                let new_last_update_time = last_time_reward_applicable(table::borrow(&pool.reward_data, *reward_token).period_finish);
                let reward_data = table::borrow_mut(&mut pool.reward_data, *reward_token);

                let time_difference = ((new_last_update_time - reward_data.last_update_time) as u128);
                let total_subscribed = pool.total_subscribed;

                if (total_subscribed == 0 && time_difference != 0) {
                    reward_data.unallocated_rewards = reward_data.unallocated_rewards
                        + (((time_difference * reward_data.reward_rate) / U12_FP_PRECISION) as u64);
                };

                reward_data.reward_per_token_stored = new_reward_per_token;
                reward_data.last_update_time = new_last_update_time;
            };

            if (account != @0x0) {
                {
                    let user_data = borrow_global_mut<UserData>(account);

                    if (!table::contains(&user_data.pool_rewards, *pool_obj)) {
                        table::add(&mut user_data.pool_rewards, *pool_obj, table::new());
                    };
                };

                let earned_amount = total_earned(pool_obj, account, *reward_token);
                let user_data = borrow_global_mut<UserData>(account);
                let pool_rewards = table::borrow_mut(&mut user_data.pool_rewards, *pool_obj);
                let user_reward_data = table::borrow_mut(pool_rewards, *reward_token);
                user_reward_data.rewards = earned_amount;
                user_reward_data.reward_per_token_paid = new_reward_per_token;
            };

            i = i + 1;
        };
    }

    fun total_earned(
        pool_obj: &Object<StakingPool>, account: address, reward_token: Object<Metadata>
    ): u64 acquires InitConfiguration, MultiRewardsModule, StakingPool, UserData {
        let user_data = borrow_global_mut<UserData>(account);

        // Get user's staked balance for the staking token
        let rs_address = get_rs_address();
        let mr_module = borrow_global<MultiRewardsModule>(rs_address);

        let pool_addr = object::object_address(pool_obj);
        let pool = borrow_global<StakingPool>(pool_addr);
        let staking_token = pool.staking_token;

        let user_balances = table::borrow(&mr_module.user_staked_balances, account);
        let user_balance = *table::borrow(user_balances, staking_token);

        // Get user's reward data for the pool and reward token
        let pool_rewards = table::borrow_mut(&mut user_data.pool_rewards, *pool_obj);

        // Check if user has reward data for this pool and token
        if (!table::contains(pool_rewards, reward_token)) {
            table::add(
                pool_rewards,
                reward_token,
                UserRewardData { reward_per_token_paid: 0, rewards: 0 }
            );
        };

        let user_reward_data = table::borrow(pool_rewards, reward_token);

        let user_reward_per_token_paid = user_reward_data.reward_per_token_paid;
        let user_rewards = user_reward_data.rewards;

        let reward_per_token_current = reward_per_token(pool, reward_token);
        let is_subscribed = is_user_subscribed(account, *pool_obj);

        // if the user is not already subscribed to the pool then we assume they had 0 staked to the pool
        let subscribed_balance = if (is_subscribed) {
            (user_balance as u128)
        } else { 0u128 };

        let earned_amount = (((subscribed_balance * (reward_per_token_current - user_reward_per_token_paid)) / U12_FP_PRECISION) as u64);

        user_rewards + earned_amount
    }

    fun reward_per_token(pool: &StakingPool, reward_token: Object<Metadata>): u128 {
        let reward_data = table::borrow(&pool.reward_data, reward_token);
        if (pool.total_subscribed == 0) {
            return reward_data.reward_per_token_stored
        };

        let extra_reward_per_token =
            ((((last_time_reward_applicable(reward_data.period_finish) - reward_data.last_update_time) as u128)
                * (reward_data.reward_rate as u128)) / (pool.total_subscribed as u128));

        let extrapolated_reward_per_token = reward_data.reward_per_token_stored + extra_reward_per_token;
        extrapolated_reward_per_token
    }

    fun last_time_reward_applicable(period_finish: u64): u64 {
        min(timestamp::now_seconds(), period_finish)
    }

    fun min(a: u64, b: u64): u64 {
        if (a < b) a else b
    }

    fun get_resource_signer(): signer acquires InitConfiguration {
        let init_config = borrow_global<InitConfiguration>(@canopy_staking);
        account::create_signer_with_capability(&init_config.resource_signer_cap)
    }

    fun get_rs_address(): address acquires InitConfiguration {
        // it's simpler to get the resource account address as follows instead of precomputing the address
        // and referencing an address literal
        let rs = get_resource_signer();
        signer::address_of(&rs)
    }

    // - - - - - - VIEW FUNCTIONS - - - - - -

    #[view]
    /// Returns the staking token, list of reward tokens, and total subscribed amount for a given pool
    public fun get_pool_info(pool: Object<StakingPool>): (Object<Metadata>, vector<Object<Metadata>>, u64) acquires StakingPool {
        let pool_addr = object::object_address(&pool);
        let staking_pool = borrow_global<StakingPool>(pool_addr);

        (staking_pool.staking_token, staking_pool.reward_tokens, staking_pool.total_subscribed)
    }

    #[view]
    /// Returns the staked balance of a user for a specific staking token
    public fun get_user_staked_balance(user: address, staking_token: Object<Metadata>): u64 acquires InitConfiguration, MultiRewardsModule {
        let rs_address = get_rs_address();
        let mr_module = borrow_global<MultiRewardsModule>(rs_address);

        if (table::contains(&mr_module.user_staked_balances, user)) {
            let user_balances = table::borrow(&mr_module.user_staked_balances, user);
            if (table::contains(user_balances, staking_token)) {
                *table::borrow(user_balances, staking_token)
            } else { 0 }
        } else { 0 }
    }

    #[view]
    /// Returns the list of pools a user is subscribed to for a specific staking token
    public fun get_user_subscribed_pools(user: address, staking_token: Object<Metadata>): vector<Object<StakingPool>> acquires UserData {
        if (!exists<UserData>(user)) {
            return vector::empty()
        };

        let user_data = borrow_global<UserData>(user);
        if (!table::contains(&user_data.subscribed_pools, staking_token)) {
            return vector::empty()
        };

        *table::borrow(&user_data.subscribed_pools, staking_token)
    }

    #[view]
    /// Returns the reward data for a specific reward token in a pool
    /// (distributor, duration, period finish, last update time, reward rate, reward per token stored)
    public fun get_reward_data(pool: Object<StakingPool>, reward_token: Object<Metadata>): (address, u64, u64, u64, u128, u128) acquires StakingPool {
        let pool_addr = object::object_address(&pool);
        let staking_pool = borrow_global<StakingPool>(pool_addr);

        assert!(table::contains(&staking_pool.reward_data, reward_token), E_INVALID_TOKEN);

        let reward_data = table::borrow(&staking_pool.reward_data, reward_token);

        (
            reward_data.rewards_distributor,
            reward_data.rewards_duration,
            reward_data.period_finish,
            reward_data.last_update_time,
            reward_data.reward_rate,
            reward_data.reward_per_token_stored
        )
    }

    #[view]
    /// Returns the user's reward data for a specific pool and reward token
    /// (reward per token paid, rewards)
    public fun get_user_reward_data(user: address, pool: Object<StakingPool>, reward_token: Object<Metadata>): (u128, u64) acquires UserData {
        if (!exists<UserData>(user)) {
            return (0, 0)
        };

        let user_data = borrow_global<UserData>(user);

        if (!table::contains(&user_data.pool_rewards, pool)) {
            return (0, 0)
        };

        let pool_rewards = table::borrow(&user_data.pool_rewards, pool);

        if (!table::contains(pool_rewards, reward_token)) {
            return (0, 0)
        };

        let user_reward_data = table::borrow(pool_rewards, reward_token);

        (user_reward_data.reward_per_token_paid, user_reward_data.rewards)
    }

    #[view]
    /// Calculates and returns the amount of rewards earned by a user for a specific pool and reward token that can be claimed
    public fun get_earned(
        user: address, pool: Object<StakingPool>, reward_token: Object<Metadata>
    ): u64 acquires InitConfiguration, MultiRewardsModule, StakingPool, UserData {
        if (!exists<UserData>(user)) {
            return 0
        };

        let user_data = borrow_global<UserData>(user);

        if (!table::contains(&user_data.pool_rewards, pool)) {
            return 0
        };

        // NOTE: we do the following as we don't want to call total_earned and create state in this view function
        let pool_rewards = table::borrow(&user_data.pool_rewards, pool);
        if (!table::contains(pool_rewards, reward_token)) {
            // Calculate rewards for users subscribed before reward token was added

            // Only calculate if user is subscribed
            if (is_user_subscribed(user, pool)) {
                let rs_address = get_rs_address();
                let mr_module = borrow_global<MultiRewardsModule>(rs_address);

                let pool_addr = object::object_address(&pool);
                let staking_pool = borrow_global<StakingPool>(pool_addr);

                let user_balances = table::borrow(&mr_module.user_staked_balances, user);
                let user_balance = *table::borrow(user_balances, staking_pool.staking_token);

                // Calculate rewards using current reward_per_token and 0 for reward_per_token_paid
                let reward_per_token_current = reward_per_token(staking_pool, reward_token);
                return ((((user_balance as u128) * reward_per_token_current) / U12_FP_PRECISION) as u64)
            };
            return 0
        };

        total_earned(&pool, user, reward_token)
    }

    #[view]
    /// Returns the current reward per token for a specific reward token in a pool
    public fun get_reward_per_token(pool: Object<StakingPool>, reward_token: Object<Metadata>): u128 acquires StakingPool {
        let pool_addr = object::object_address(&pool);
        let staking_pool = borrow_global<StakingPool>(pool_addr);

        assert!(table::contains(&staking_pool.reward_data, reward_token), E_INVALID_TOKEN);

        reward_per_token(staking_pool, reward_token)
    }

    #[view]
    /// Returns the last applicable time for rewards in a specific pool and reward token
    public fun get_last_time_reward_applicable(pool: Object<StakingPool>, reward_token: Object<Metadata>): u64 acquires StakingPool {
        let pool_addr = object::object_address(&pool);
        let staking_pool = borrow_global<StakingPool>(pool_addr);

        assert!(table::contains(&staking_pool.reward_data, reward_token), E_INVALID_TOKEN);

        let reward_data = table::borrow(&staking_pool.reward_data, reward_token);
        last_time_reward_applicable(reward_data.period_finish)
    }

    #[view]
    /// Checks if a user is subscribed to a specific pool
    public fun is_user_subscribed(user: address, pool: Object<StakingPool>): bool acquires UserData, StakingPool {
        if (!exists<UserData>(user)) {
            return false
        };

        let user_data = borrow_global<UserData>(user);
        let pool_addr = object::object_address(&pool);
        let staking_pool = borrow_global<StakingPool>(pool_addr);
        let staking_token = staking_pool.staking_token;

        if (!table::contains(&user_data.subscribed_pools, staking_token)) {
            return false
        };

        let subscribed_pools = table::borrow(&user_data.subscribed_pools, staking_token);
        vector::contains(subscribed_pools, &pool)
    }

    #[view]
    /// Returns the list of reward tokens for a specific pool
    public fun get_pool_reward_tokens(pool: Object<StakingPool>): vector<Object<Metadata>> acquires StakingPool {
        let pool_addr = object::object_address(&pool);
        let staking_pool = borrow_global<StakingPool>(pool_addr);
        staking_pool.reward_tokens
    }

    #[view]
    /// Returns the remaining rewards to be distributed for a specific reward token in a pool
    public fun get_remaining_rewards(pool: Object<StakingPool>, reward_token: Object<Metadata>): u64 acquires StakingPool {
        let pool_addr = object::object_address(&pool);
        let staking_pool = borrow_global<StakingPool>(pool_addr);

        assert!(table::contains(&staking_pool.reward_data, reward_token), E_INVALID_TOKEN);

        let reward_data = table::borrow(&staking_pool.reward_data, reward_token);
        let current_time = timestamp::now_seconds();

        if (current_time >= reward_data.period_finish) {
            // If the reward period has ended, there are no remaining rewards
            0
        } else {
            let remaining_time = reward_data.period_finish - current_time;
            ((((remaining_time as u128) * reward_data.reward_rate) / U12_FP_PRECISION) as u64)
        }
    }

    #[view]
    /// Returns the unallocated rewards "distributed" during periods where 0 was subscribed for a pool
    public fun get_unallocated_rewards(pool: Object<StakingPool>, reward_token: Object<Metadata>): u64 acquires StakingPool {
        let pool_addr = object::object_address(&pool);
        let staking_pool = borrow_global<StakingPool>(pool_addr);

        assert!(table::contains(&staking_pool.reward_data, reward_token), E_INVALID_TOKEN);

        let reward_data = table::borrow(&staking_pool.reward_data, reward_token);
        reward_data.unallocated_rewards
    }

    // - - - - - - EVENTS - - - - - -

    #[event]
    struct StakingPoolCreatedEvent has drop, store {
        creator: address,
        staking_token: Object<Metadata>,
        pool_address: address
    }

    #[event]
    struct RewardAddedEvent has drop, store {
        pool_address: address,
        reward_token: Object<Metadata>,
        rewards_distributor: address,
        rewards_duration: u64
    }

    #[event]
    struct StakeEvent has drop, store {
        user: address,
        staking_token: Object<Metadata>,
        amount: u64
    }

    #[event]
    struct WithdrawEvent has drop, store {
        user: address,
        staking_token: Object<Metadata>,
        amount: u64
    }

    #[event]
    struct RewardClaimedEvent has drop, store {
        user: address,
        pool_address: address,
        reward_token: Object<Metadata>,
        reward_amount: u64
    }

    #[event]
    struct SubscriptionEvent has drop, store {
        user: address,
        pool_address: address,
        staking_token: Object<Metadata>
    }

    #[event]
    struct UnsubscriptionEvent has drop, store {
        user: address,
        pool_address: address,
        staking_token: Object<Metadata>
    }

    #[event]
    struct RewardNotifiedEvent has drop, store {
        pool_address: address,
        reward_token: Object<Metadata>,
        reward_amount: u64,
        reward_rate: u128,
        period_finish: u64
    }

    #[event]
    struct RewardsDurationUpdatedEvent has drop, store {
        pool_address: address,
        reward_token: Object<Metadata>,
        new_duration: u64
    }

    #[event]
    struct EmergencyWithdrawEvent has drop, store {
        user: address,
        staking_token: Object<Metadata>,
        amount: u64
    }

    #[event]
    struct TokenSweptEvent has drop, store {
        pool_address: address,
        token: Object<Metadata>,
        amount: u64
    }

    #[event]
    struct AdminWithdrawalProposedEvent has drop, store {
        pool_address: address,
        proposed_at: u64
    }

    #[event]
    struct AdminWithdrawalClearedEvent has drop, store {
        pool_address: address,
        cleared_by: address
    }

    #[event]
    struct AdminWithdrawalExecutedEvent has drop, store {
        pool_address: address,
        recipient: address,
        tokens: vector<Object<Metadata>>,
        amounts: vector<u64>
}


    // - - - - - - TEST ONLY - - - - - -

    // - - - - - - TEST ONLY: constants - - - - - -

    const E_EVENT_NOT_EMITTED: u64 = 501;

    // - - - - - - TEST ONLY: functions - - - - - -

    #[test_only]
    public fun init_module_for_test() {
        let canopy_staking = account::create_account_for_test(@canopy_staking);
        init_module(&canopy_staking);
    }

    #[test_only]
    public fun get_reward_store_balance(pool: Object<StakingPool>, reward_token: Object<Metadata>): u64 acquires StakingPool {
        let pool_addr = object::object_address(&pool);
        let staking_pool = borrow_global<StakingPool>(pool_addr);

        assert!(table::contains(&staking_pool.reward_stores, reward_token), 0); // Ensure the reward token exists

        let reward_store = table::borrow(&staking_pool.reward_stores, reward_token);
        fungible_asset::balance(reward_store.store)
    }

    // - - - - - - TEST ONLY: event emission - - - - - -

    #[test_only]
    public fun assert_StakingPoolCreatedEvent_emitted(
        pool_address: address, staking_token: Object<Metadata>, creator: address
    ) {
        assert!(
            event::was_event_emitted<StakingPoolCreatedEvent>(&StakingPoolCreatedEvent { pool_address, staking_token, creator }),
            E_EVENT_NOT_EMITTED
        );
    }

    #[test_only]
    public fun assert_RewardAddedEvent_emitted(
        pool_address: address,
        reward_token: Object<Metadata>,
        rewards_distributor: address,
        rewards_duration: u64
    ) {
        assert!(
            event::was_event_emitted<RewardAddedEvent>(
                &RewardAddedEvent { pool_address, reward_token, rewards_distributor, rewards_duration }
            ),
            E_EVENT_NOT_EMITTED
        );
    }

    #[test_only]
    public fun assert_StakeEvent_emitted(user: address, staking_token: Object<Metadata>, amount: u64) {
        assert!(
            event::was_event_emitted<StakeEvent>(&StakeEvent { user, staking_token, amount }),
            E_EVENT_NOT_EMITTED
        );
    }

    #[test_only]
    public fun assert_WithdrawEvent_emitted(user: address, staking_token: Object<Metadata>, amount: u64) {
        assert!(
            event::was_event_emitted<WithdrawEvent>(&WithdrawEvent { user, staking_token, amount }),
            E_EVENT_NOT_EMITTED
        );
    }

    #[test_only]
    public fun assert_EmergencyWithdrawEvent_emitted(
        user: address, staking_token: Object<Metadata>, amount: u64
    ) {
        assert!(
            event::was_event_emitted<EmergencyWithdrawEvent>(&EmergencyWithdrawEvent { user, staking_token, amount }),
            E_EVENT_NOT_EMITTED
        );
    }

    #[test_only]
    public fun assert_SubscriptionEvent_emitted(
        pool_address: address, user: address, staking_token: Object<Metadata>
    ) {
        assert!(
            event::was_event_emitted<SubscriptionEvent>(&SubscriptionEvent { user, pool_address, staking_token }),
            E_EVENT_NOT_EMITTED
        );
    }

    #[test_only]
    public fun assert_UnsubscriptionEvent_emitted(
        pool_address: address, user: address, staking_token: Object<Metadata>
    ) {
        assert!(
            event::was_event_emitted<UnsubscriptionEvent>(&UnsubscriptionEvent { user, pool_address, staking_token }),
            E_EVENT_NOT_EMITTED
        );
    }

    #[test_only]
    public fun assert_RewardNotifiedEvent_emitted(
        pool_address: address,
        reward_token: Object<Metadata>,
        reward_amount: u64,
        reward_rate: u128,
        period_finish: u64
    ) {
        assert!(
            event::was_event_emitted<RewardNotifiedEvent>(
                &RewardNotifiedEvent { pool_address, reward_token, reward_amount, reward_rate, period_finish }
            ),
            E_EVENT_NOT_EMITTED
        );
    }

    #[test_only]
    public fun assert_RewardsDurationUpdatedEvent_emitted(
        pool_address: address, reward_token: Object<Metadata>, new_duration: u64
    ) {
        assert!(
            event::was_event_emitted<RewardsDurationUpdatedEvent>(&RewardsDurationUpdatedEvent { pool_address, reward_token, new_duration }),
            E_EVENT_NOT_EMITTED
        );
    }

    #[test_only]
    public fun assert_RewardClaimedEvent_emitted(
        pool_address: address,
        user: address,
        reward_token: Object<Metadata>,
        reward_amount: u64
    ) {
        assert!(
            event::was_event_emitted<RewardClaimedEvent>(&RewardClaimedEvent { pool_address, user, reward_token, reward_amount }),
            E_EVENT_NOT_EMITTED
        );
    }

    #[test_only]
    public fun assert_TokenSweptEvent_emitted(
        pool_address: address,
        token: Object<Metadata>,
        amount: u64
    ) {
        assert!(
            event::was_event_emitted<TokenSweptEvent>(&TokenSweptEvent { pool_address, token, amount }),
            E_EVENT_NOT_EMITTED
        );
    }

    #[test_only]
public fun assert_AdminWithdrawalProposedEvent_emitted(
    pool_address: address,
    proposed_at: u64
) {
    assert!(
        event::was_event_emitted<AdminWithdrawalProposedEvent>(
            &AdminWithdrawalProposedEvent { pool_address, proposed_at }
        ),
        E_EVENT_NOT_EMITTED
    );
}

#[test_only]
public fun assert_AdminWithdrawalClearedEvent_emitted(
    pool_address: address,
    cleared_by: address
) {
    assert!(
        event::was_event_emitted<AdminWithdrawalClearedEvent>(
            &AdminWithdrawalClearedEvent { pool_address, cleared_by }
        ),
        E_EVENT_NOT_EMITTED
    );
}

#[test_only]
public fun assert_AdminWithdrawalExecutedEvent_emitted(
    pool_address: address,
    recipient: address,
    tokens: vector<Object<Metadata>>,
    amounts: vector<u64>
) {
    assert!(
        event::was_event_emitted<AdminWithdrawalExecutedEvent>(
            &AdminWithdrawalExecutedEvent { pool_address, recipient, tokens, amounts }
        ),
        E_EVENT_NOT_EMITTED
    );
}
}

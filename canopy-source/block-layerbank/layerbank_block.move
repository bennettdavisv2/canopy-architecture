module layerbank_block::layerbank_block {

    use std::signer;
    use std::vector;
    use aptos_framework::fungible_asset;
    use aptos_framework::fungible_asset::Metadata;
    use aptos_framework::object::{Self, ExtendRef, Object};
    use aptos_framework::primary_fungible_store;

    use satay::hot_asset::{Self, HotAsset};
    use satay::protocol::{Self, BlockRef};

    use layerbank_math::wad_ray_math;
    use layerbank_pool::a_token_factory;
    use layerbank_pool::pool;
    use layerbank_pool::rewards_distributor_v2;
    use layerbank_pool::rewards_controller_v2;
    use layerbank_pool::supply_logic;

    // LayerBank is an Aave fork
    // - - - - CONSTANTS - - - -

    const MAX_U64: u256 = 18446744073709551615u256;

    // - - - - INITIALIZE - - - -

    struct LayerBankBlock has key {
        block_ref: BlockRef,
        extend_ref: ExtendRef
    }

    const BLOCK_SEED: vector<u8> = b"00000001LayerBankBlock";

    // This entry function must be called by the governance account after the block package is deployed
    // to initialize the block within the system.
    //
    // - Without initialization, the block cannot be used to handle assets in the system.
    // - Only governance can initialize blocks, and only once.
    public entry fun initialize(account: &signer) {
        let (constructor_ref, block_ref) = protocol::new_block_ref(account, BLOCK_SEED);

        let block_signer = object::generate_signer(&constructor_ref);
        let extend_ref = object::generate_extend_ref(&constructor_ref);
        move_to(&block_signer, LayerBankBlock { block_ref, extend_ref })
    }

    // Get the address of the block object (not the package itself).
    public fun block_address(): address {
        object::create_object_address(&protocol::get_address(), BLOCK_SEED)
    }

    inline fun block_ref(): &BlockRef {
        &borrow_global<LayerBankBlock>(block_address()).block_ref
    }

    // - - - - LENDING INTERACTION - - - -

    /// Supplies an asset to the Aave lending pool
    /// @notice Supplies the specified amount of an asset to the Aave lending pool and mints aTokens to the recipient
    /// @dev This function wraps the Aave supply_logic::supply function. The account must have sufficient balance of the asset.
    /// @param account The signer that has the assets to supply (typically the base strategy signer)
    /// @param asset The address of the underlying asset to supply
    /// @param amount The amount of the asset to supply
    /// @param recipient The address that will receive the aTokens (typically the base strategy signer)
    /// @param referral_code A referral code for the supply action (0 if the action is executed directly by the user, without any middle-man)
    public fun supply(
        account: &signer,
        hot_asset: HotAsset,
        recipient: address,
        referral_code: u16
    ) acquires LayerBankBlock {
        // Destroy the hot asset and deposit the underlying asset into the primary fungible store
        let asset = hot_asset::destroy_with_block_ref(hot_asset, block_ref());

        let amount = (fungible_asset::amount(&asset) as u256);

        let asset_address = object::object_address(&fungible_asset::metadata_from_asset(&asset));
        primary_fungible_store::deposit(signer::address_of(account), asset);

        // Supply the asset to the Aave lending pool
        supply_logic::supply(account, asset_address, amount, recipient, referral_code);
    }

    /// Withdraws an asset from the Aave lending pool
    /// @notice Withdraws the specified amount of an underlying asset from the Aave pool
    ///
    /// @param account The signer that has the aTokens to burn (must have sufficient aToken balance)
    /// @param asset The address of the underlying asset to withdraw
    /// @param amount The amount of the underlying asset to withdraw
    /// @param recipient The address that will receive both the withdrawn asset
    public fun withdraw(account: &signer, asset_address: address, amount: u64): HotAsset {
        // NOTE: we do NOT claim any rewards in the base asset here, this should be done elsewhere
        // and can make use of the appropriate layerbank_block claim rewards function

        // Withdraw the asset from the Aave lending pool to account
        supply_logic::withdraw(
            account,
            asset_address,
            amount as u256,
            signer::address_of(account)
        );

        // Withdraw the asset from the primary fungible store and wrap
        let metadata = object::address_to_object<Metadata>(asset_address);
        let asset = primary_fungible_store::withdraw(account, metadata, amount);
        hot_asset::new(asset)
    }

    // - - - - REWARDS INTERACTION - - - -

    public fun claim_all_rewards(
        caller: &signer, base_asset: Object<Metadata>, rewards_controller_address: address
    ) {
        let a_token_address = get_a_token(base_asset);

        rewards_distributor_v2::claim_all_rewards_to_self(
            caller,
            vector::singleton(a_token_address),
            rewards_controller_address
        );
    }

    public fun claim_all_non_base_asset_rewards(
        caller: &signer, base_asset: Object<Metadata>, rewards_controller_address: address
    ) {
        let base_asset_address = object::object_address(&base_asset);
        let a_token_address = get_a_token(base_asset);

        // Get list of all reward assets
        let reward_assets = rewards_controller_v2::get_rewards_list(rewards_controller_address);

        // Iterate through rewards and claim all except base asset
        let i = 0;
        let len = vector::length(&reward_assets);
        while (i < len) {
            let reward_asset = *vector::borrow(&reward_assets, i);
            if (reward_asset != base_asset_address) {
                rewards_distributor_v2::claim_rewards_to_self(
                    caller,
                    vector::singleton(a_token_address),
                    MAX_U64, // Claim maximum amount
                    reward_asset,
                    rewards_controller_address
                );
            };
            i = i + 1;
        };
    }

    public fun claim_base_asset_rewards(
        caller: &signer, base_asset: Object<Metadata>, rewards_controller_address: address
    ): u256 {
        let base_asset_address = object::object_address(&base_asset);
        let a_token_address = get_a_token(base_asset);

        // Get list of all reward assets
        if (has_base_asset_rewards(base_asset, rewards_controller_address)) {
            return rewards_distributor_v2::claim_rewards_to_self(
                caller,
                vector::singleton(a_token_address),
                MAX_U64, // Claim maximum amount
                base_asset_address,
                rewards_controller_address
            )
        };
        // no base asset rewards earned
        0
    }

    // - - - - VIEW FUNCTIONS - - - -

    #[view]
    /// @notice Returns the total amount of underlying asset supplied by a user including accrued interest
    /// @dev Calculated by multiplying the user's scaled aToken balance by the normalized income (liquidity index)
    /// @param user The address of the user whose supply balance is being checked
    /// @param asset The address of the underlying asset that was supplied
    /// @return The total supply balance including accrued interest, expressed in the underlying asset's decimals
    public fun get_user_supply_with_interest(user: address, asset: address): u256 {
        let reserve_data = pool::get_reserve_data(asset);
        let a_token_address = pool::get_reserve_a_token_address(&reserve_data);
        let scaled_balance = a_token_factory::scaled_balance_of(user, a_token_address);
        let normalized_income = pool::get_reserve_normalized_income(asset);
        wad_ray_math::ray_mul(scaled_balance, normalized_income)
    }

    #[view]
    public fun get_rewards_by_asset(
        base_asset: Object<Metadata>, rewards_controller_address: address
    ): vector<address> {
        let a_token_address = get_a_token(base_asset);
        rewards_controller_v2::get_rewards_by_asset(a_token_address, rewards_controller_address)
    }

    #[view]
    public fun has_base_asset_rewards(
        base_asset: Object<Metadata>, rewards_controller_address: address
    ): bool {
        let base_metadata_address = object::object_address(&base_asset);
        let a_token_address = get_a_token(base_asset);
        let rewards = rewards_controller_v2::get_rewards_by_asset(a_token_address, rewards_controller_address);
        vector::contains(&rewards, &base_metadata_address)
    }

    public inline fun ensure_reserve_exists(asset: address) {
        pool::get_reserve_data(asset);
    }

    inline fun get_a_token(base_asset: Object<Metadata>): address {
        let base_asset_address = object::object_address(&base_asset);
        let reserve_data = pool::get_reserve_data(base_asset_address);
        pool::get_reserve_a_token_address(&reserve_data)
    }
}

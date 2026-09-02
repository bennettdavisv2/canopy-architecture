module meridian_farming_block::meridian_farming_block {
    use std::signer;
    use std::option;
    use aptos_std::type_info;
    use aptos_framework::fungible_asset::{Metadata, FungibleAsset};
    use aptos_framework::object::{Self, ExtendRef, Object};
    use aptos_framework::primary_fungible_store;
    use aptos_framework::coin::{Self, Coin};

    use satay::hot_asset::{Self, HotAsset};
    use satay::protocol::{Self, BlockRef};

    use meridian_farming::farming;
    use meridian_farming::scripts::{Null};
    use fa_coin_wrapper::fa_coin_wrapper;

    struct MeridianFarmingBlock has key {
        block_ref: BlockRef,
        extend_ref: ExtendRef
    }

    const BLOCK_SEED: vector<u8> = b"00000001MeridianFarmingBlock";

    // This entry function must be called by the governance account after the block package is deployed
    // to initialize the block within the system.
    //
    // - Without initialization, the block cannot be used to handle assets in the system.
    // - Only governance can initialize blocks, and only once.
    public entry fun initialize(account: &signer) {
        let (constructor_ref, block_ref) = protocol::new_block_ref(account, BLOCK_SEED);

        let block_signer = object::generate_signer(&constructor_ref);
        let extend_ref = object::generate_extend_ref(&constructor_ref);
        move_to(&block_signer, MeridianFarmingBlock { block_ref, extend_ref })
    }

    // Get the address of the block object (not the package itself).
    public fun block_address(): address {
        object::create_object_address(&protocol::get_address(), BLOCK_SEED)
    }

    inline fun block_ref(): &BlockRef acquires MeridianFarmingBlock {
        &borrow_global<MeridianFarmingBlock>(block_address()).block_ref
    }

    public fun stake_fa<WrapperStakeCoin>(account: &signer, pool_id: u64, hot_asset: HotAsset) acquires MeridianFarmingBlock {
        let asset = hot_asset::destroy_with_block_ref(hot_asset, block_ref());

        let coin = fa_coin_wrapper::fa_to_coin<WrapperStakeCoin>(asset);

        let meridian_reward_coin = farming::stake(account, pool_id, coin);
        coin::deposit(signer::address_of(account), meridian_reward_coin);
    }

    public fun unstake_fa<WrapperStakeCoin>(account: &signer, pool_id: u64, amount: u64): HotAsset {
        let (unstaked, meridian_reward_coin) = farming::unstake<WrapperStakeCoin>(account, pool_id, amount);
        coin::deposit(signer::address_of(account), meridian_reward_coin);
        hot_asset::new(fa_coin_wrapper::coin_to_fa<WrapperStakeCoin>(unstaked))
    }

    public fun claim_meridian<StakeCoin>(account: &signer, pool_id: u64) {
        let meridian_reward_coin = farming::claim_meridian<StakeCoin>(account, pool_id);
        coin::deposit(signer::address_of(account), meridian_reward_coin)
    }

    public fun claim_base_asset_reward<StakeCoin>(account: &signer, pool_id: u64): u64 acquires MeridianFarmingBlock {
        if (!is_null<StakeCoin>()) {
            let base_asset_reward = farming::claim_extra_reward<StakeCoin, StakeCoin>(account, pool_id);
            let amount = coin::value(&base_asset_reward);
            let hot_asset =
                hot_asset::new_with_recipient_and_block_ref(
                    coin_to_fa_internal<StakeCoin>(base_asset_reward),
                    signer::address_of(account),
                    block_ref()
                );
            hot_asset::dispatch(hot_asset);
            amount
        } else { 0 }
    }

    public fun claim_extra_reward<StakeCoin, ExtraRewardCoin>(
        account: &signer, pool_id: u64
    ): u64 {

        if (!is_null<ExtraRewardCoin>()) {
            let wrapped_extra_reward = farming::claim_extra_reward<StakeCoin, ExtraRewardCoin>(
                account, pool_id
            );
            let amount = coin::value(&wrapped_extra_reward);
            primary_fungible_store::deposit(
                signer::address_of(account),
                coin_to_fa_internal<ExtraRewardCoin>(wrapped_extra_reward)
            );
            amount
        } else { 0 }
    }

    // - - - - HELPER FUNCTIONS - - - -

    public fun ensure_wrapped_coin_exists(metadata: Object<Metadata>) {
        // It will abort if it does not exist
        fa_coin_wrapper::metadata_wrapped_coin(metadata);
    }

    #[view]
    public fun wrapped_coin_metadata<WCoin>(): Object<Metadata> {
        // If the coin is wrapped by Meridian, get metadata from Meridian wraper
        if (fa_coin_wrapper::is_fa_wrapped_coin<WCoin>()) {
            fa_coin_wrapper::wrapped_coin_metadata<WCoin>()
        // Otherwise, get metadata from coin module
        } else {
            option::destroy_some(coin::paired_metadata<WCoin>())
        }
    }

    #[view]
    public fun is_same_coin<CoinType1, CoinType2>(): bool {
        type_info::type_name<CoinType1>() == type_info::type_name<CoinType2>()
    }

    #[view]
    public fun is_null<CoinType>(): bool {
        type_info::type_name<CoinType>() == type_info::type_name<Null>()
    }

    #[view]
    /// Returns (stake amount, boosted stake amount) of a user in a pool
    public fun stake_amount(account_address: address, pool_id: u64): (u64, u64) {
        let (stake_amount, boosted_stake_amount, _) = farming::stake_amount(account_address, pool_id);
        (stake_amount, boosted_stake_amount)
    }

    #[view]
    public fun reward_amount<RewardCoin>(account_address: address, pool_id: u64): u64 {
        let (_, reward_amount) = farming::stake_and_reward_amount<RewardCoin>(account_address, pool_id);
        reward_amount
    }

    public fun ensure_meridian_pool_exists(pool_id: u64): u256 {
        // Errors in case pool does not exist
        farming::pool_acc_meridian_reward_per_share(pool_id)
    }

    public fun coin_to_fa_internal<CoinType>(coin: Coin<CoinType>): FungibleAsset {
        // If the coin is wrapped by Meridian, we unwrap using Meridian wraper
        if (fa_coin_wrapper::is_fa_wrapped_coin<CoinType>()) {
            fa_coin_wrapper::coin_to_fa<CoinType>(coin)
        // Otherwise, we convert the coin to a fungible asset using coin module
        } else {
            coin::coin_to_fungible_asset<CoinType>(coin)
        }
    }

    #[test_only]
    use meridian_farming::package as farming_package;

    #[test_only]
    public fun update_extra_reward<WrappedExtraRewardCoin>(
        account: &signer,
        pool_id: u64,
        start_sec: u64,
        end_sec: u64,
        reward_per_day: u64
    ) {
        let metadata = fa_coin_wrapper::wrapped_coin_metadata<WrappedExtraRewardCoin>();
        let balance_fa = primary_fungible_store::balance(signer::address_of(account), metadata);
        fa_coin_wrapper::fa_to_coin_entry<WrappedExtraRewardCoin>(account, balance_fa);

        farming::update_extra_reward<WrappedExtraRewardCoin>(account, pool_id, start_sec, end_sec, reward_per_day);

        // Return all unused wrapper coins to the account
        let balance_coin = coin::balance<WrappedExtraRewardCoin>(signer::address_of(account));
        fa_coin_wrapper::coin_to_fa_entry<WrappedExtraRewardCoin>(account, balance_coin);
    }

    #[test_only]
    public fun farming_resource_account_address(): address {
        farming_package::resource_account_address()
    }
}

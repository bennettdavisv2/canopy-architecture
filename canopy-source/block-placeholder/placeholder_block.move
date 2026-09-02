module placeholder_block::placeholder_block {
    use std::option;

    use aptos_framework::coin;
    use aptos_framework::aptos_account;
    use aptos_framework::primary_fungible_store;
    use aptos_framework::object::{Self, ExtendRef, Object};

    use satay::base_strategy::{Self, BaseStrategy};
    use satay::hot_asset::{Self, HotAsset};
    use satay::protocol::{Self, BlockRef};
    use satay::hot_coin::{Self, HotCoin};
    use satay::vault::Vault;

    struct PlaceholderBlock has key {
        block_ref: BlockRef,
        extend_ref: ExtendRef
    }

    const BLOCK_SEED: vector<u8> = b"00000000PlaceholderBlock";

    /// Invalid asset metadata.
    const EINVALID_ASSET_METADATA: u64 = 0;

    // This entry function must be called by the governance account after the block package is deployed
    // to initialize the block within the system.
    //
    // - Without initialization, the block cannot be used to handle assets in the system.
    // - Only governance can initialize blocks, and only once.
    public entry fun initialize(account: &signer) {
        let (constructor_ref, block_ref) = protocol::new_block_ref(account, BLOCK_SEED);

        let block_signer = object::generate_signer(&constructor_ref);
        let extend_ref = object::generate_extend_ref(&constructor_ref);
        move_to(&block_signer, PlaceholderBlock { block_ref, extend_ref })
    }

    // Get the address of the block object (not the package itself).
    public fun block_address(): address {
        object::create_object_address(&protocol::get_address(), BLOCK_SEED)
    }

    inline fun block_ref(): &BlockRef acquires PlaceholderBlock {
        &borrow_global<PlaceholderBlock>(block_address()).block_ref
    }

    public fun deposit<CoinType>(strategy: Object<BaseStrategy>, coin: HotCoin<CoinType>) acquires PlaceholderBlock {
        let coin = hot_coin::destroy_with_block_ref(coin, block_ref());
        aptos_account::deposit_coins(object::object_address(&strategy), coin)
    }

    public fun deposit_fa(strategy: Object<BaseStrategy>, asset: HotAsset) acquires PlaceholderBlock {
        let asset = hot_asset::destroy_with_block_ref(asset, block_ref());
        primary_fungible_store::deposit(object::object_address(&strategy), asset)
    }

    public fun deposit_to_vault(vault: Object<Vault>, asset: HotAsset) acquires PlaceholderBlock {
        let asset = hot_asset::destroy_with_block_ref(asset, block_ref());
        primary_fungible_store::deposit(object::object_address(&vault), asset)
    }

    public fun withdraw<CoinType>(strategy_signer: &signer, strategy: Object<BaseStrategy>, amount: u64): HotCoin<CoinType> {
        let metadata = base_strategy::base_metadata(strategy);
        assert!(coin::paired_metadata<CoinType>() == option::some(metadata), EINVALID_ASSET_METADATA);

        hot_coin::new(coin::withdraw<CoinType>(strategy_signer, amount))
    }

    public fun withdraw_fa(strategy_signer: &signer, strategy: Object<BaseStrategy>, amount: u64): HotAsset {
        let metadata = base_strategy::base_metadata(strategy);
        hot_asset::new(primary_fungible_store::withdraw(strategy_signer, metadata, amount))
    }
}
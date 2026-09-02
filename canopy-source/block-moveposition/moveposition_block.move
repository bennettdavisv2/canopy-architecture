module moveposition_block::moveposition_block {
    use std::option;
    use std::option::Option;
    use std::signer;
    use aptos_framework::aptos_account;
    use aptos_framework::coin;
    use aptos_framework::fungible_asset::Metadata;
    use aptos_framework::object::{Self, ExtendRef, Object};
    use aptos_framework::primary_fungible_store;

    use coin_to_fa::map;
    use satay::hot_asset;
    use satay::hot_asset::HotAsset;
    use satay::hot_coin;
    use satay::hot_coin::HotCoin;
    use satay::protocol::{Self, BlockRef};
    use superp::broker::{Self, DepositNote};
    use superp::entry_public;
    use superp::portfolio;

    struct MovepositionBlock has key {
        block_ref: BlockRef,
        extend_ref: ExtendRef
    }

    const BLOCK_SEED: vector<u8> = b"000MovepositionBlock";

    // This entry function must be called by the governance account after the block package is deployed
    // to initialize the block within the system.
    //
    // - Without initialization, the block cannot be used to handle assets in the system.
    // - Only governance can initialize blocks, and only once.
    public entry fun initialize(account: &signer) {
        let (constructor_ref, block_ref) = protocol::new_block_ref(account, BLOCK_SEED);

        let block_signer = object::generate_signer(&constructor_ref);
        let extend_ref = object::generate_extend_ref(&constructor_ref);
        move_to(&block_signer, MovepositionBlock { block_ref, extend_ref })
    }

    // Get the address of the block object (not the package itself).
    public fun block_address(): address {
        object::create_object_address(&protocol::get_address(), BLOCK_SEED)
    }

    inline fun block_ref(): &BlockRef acquires MovepositionBlock {
        &borrow_global<MovepositionBlock>(block_address()).block_ref
    }

    public fun lend<CoinType>(account: &signer, packet: vector<u8>, hot_coin: HotCoin<CoinType>) acquires MovepositionBlock {
        let coin = hot_coin::destroy_with_block_ref(hot_coin, block_ref());
        aptos_account::deposit_coins(signer::address_of(account), coin);

        entry_public::lend_v2<CoinType>(account, packet)
    }

    /// This function is equivalent to `lend`, but it is specifically for FA lending through virtual coin types.
    /// Unlike `lend`, where the `CoinType` represents a real coin, the `CoinType` here is a virtual coin type which is mapped to fungible asset metadata.
    ///
    /// If the `CoinType` is not mapped to fungible asset metadata, the lending will abort.
    public fun lend_fa<VirtualCoinType>(
        account: &signer, packet: vector<u8>, hot_asset: HotAsset
    ) acquires MovepositionBlock {
        let asset = hot_asset::destroy_with_block_ref(hot_asset, block_ref());
        primary_fungible_store::deposit(signer::address_of(account), asset);

        entry_public::lend_v2<VirtualCoinType>(account, packet)
    }

    public fun borrow<CoinType>(account: &signer, packet: vector<u8>): HotCoin<CoinType> {
        let account_address = signer::address_of(account);
        let initial_balance = coin::balance<CoinType>(account_address);

        entry_public::borrow_v2<CoinType>(account, packet);

        let final_balance = coin::balance<CoinType>(account_address);
        hot_coin::new(coin::withdraw<CoinType>(account, final_balance - initial_balance))
    }

    public fun redeem<CoinType>(account: &signer, packet: vector<u8>): HotCoin<CoinType> {
        let account_address = signer::address_of(account);
        let initial_balance = coin::balance<CoinType>(account_address);

        entry_public::redeem_v2<CoinType>(account, packet);

        let final_balance = coin::balance<CoinType>(account_address);
        hot_coin::new(coin::withdraw<CoinType>(account, final_balance - initial_balance))
    }

    /// This function is equivalent to `redeem`, but it is specifically for FA redeeming through virtual coin types.
    /// Unlike `redeem`, where the `CoinType` represents a real coin, the `CoinType` here is a virtual coin type which is mapped to fungible asset metadata.
    ///
    /// If the `CoinType` is not mapped to fungible asset metadata, the redeeming will abort.
    public fun redeem_fa<VirtualCoinType>(account: &signer, packet: vector<u8>): HotAsset {
        let account_address = signer::address_of(account);
        let metadata = map::get_metadata<VirtualCoinType>();
        let initial_balance = primary_fungible_store::balance(account_address, metadata);

        entry_public::redeem_v2<VirtualCoinType>(account, packet);

        let final_balance = primary_fungible_store::balance(account_address, metadata);
        hot_asset::new(primary_fungible_store::withdraw(account, metadata, final_balance - initial_balance))
    }

    public fun repay<CoinType>(
        account: &signer, packet: vector<u8>, hot_coin: HotCoin<CoinType>
    ) acquires MovepositionBlock {
        let coin = hot_coin::destroy_with_block_ref(hot_coin, block_ref());
        aptos_account::deposit_coins(signer::address_of(account), coin);

        entry_public::repay_v2<CoinType>(account, packet)
    }

    public fun get_collateral_balance<CoinType>(account: address): u64 {
        // we can't just pass `CoinType` because portfolios only hold notes and not raw coins
        portfolio::get_collat_balance<DepositNote<CoinType>>(account)
    }

    public fun calc_coins_from_dnotes<CoinType>(amount: u64): u64 {
        broker::calc_coins_from_dnotes<CoinType>(amount)
    }

    public fun ensure_portfolio_exists(account: &signer) {
        portfolio::ensure_exists(account)
    }

    public fun is_virtual_coin_type<CoinType>(): bool {
        coin_to_fa::map::mapping_exists<CoinType>()
    }

    public fun virtual_coin_type_metadata<CoinType>(): Option<Object<Metadata>> {
        if (is_virtual_coin_type<CoinType>()) {
            return option::some(coin_to_fa::map::get_metadata<CoinType>())
        };
        option::none()
    }
}

module echelon_block::echelon_block {
    use std::signer;
    use aptos_framework::fungible_asset::{Self, Metadata};
    use aptos_framework::object::{Self, ExtendRef, Object};
    use aptos_framework::coin;

    use lending::farming;
    use lending::lending::{Self, Market};
    use satay::hot_asset::{Self, HotAsset};
    use satay::hot_coin::{Self, HotCoin};
    use satay::protocol::{Self, BlockRef};

    const SUPPLY_MARKET_TYPE: u64 = 200;
    const BORROW_MARKET_TYPE: u64 = 201;

    struct EchelonBlock has key {
        block_ref: BlockRef,
        extend_ref: ExtendRef
    }

    const BLOCK_SEED: vector<u8> = b"00000001EchelonBlock";

    // This entry function must be called by the governance account after the block package is deployed
    // to initialize the block within the system.
    //
    // - Without initialization, the block cannot be used to handle assets in the system.
    // - Only governance can initialize blocks, and only once.
    public entry fun initialize(account: &signer) {
        let (constructor_ref, block_ref) = protocol::new_block_ref(account, BLOCK_SEED);

        let block_signer = object::generate_signer(&constructor_ref);
        let extend_ref = object::generate_extend_ref(&constructor_ref);
        move_to(&block_signer, EchelonBlock { block_ref, extend_ref })
    }

    // Get the address of the block object (not the package itself).
    public fun block_address(): address {
        object::create_object_address(&protocol::get_address(), BLOCK_SEED)
    }

    inline fun block_ref(): &BlockRef acquires EchelonBlock {
        &borrow_global<EchelonBlock>(block_address()).block_ref
    }

    public fun supply<CoinType>(
        account: &signer, market: Object<Market>, coin: HotCoin<CoinType>
    ) acquires EchelonBlock {
        let coin = hot_coin::destroy_with_block_ref(coin, block_ref());
        lending::supply(account, market, coin)
    }

    public fun supply_fa(account: &signer, market: Object<Market>, hot_asset: HotAsset) acquires EchelonBlock {
        let asset = hot_asset::destroy_with_block_ref(hot_asset, block_ref());
        lending::supply_fa(account, market, asset)
    }

    public fun borrow<CoinType>(account: &signer, market: Object<Market>, amount: u64): HotCoin<CoinType> {
        let coin = lending::borrow(account, market, amount);
        hot_coin::new(coin)
    }

    public fun withdraw<CoinType>(account: &signer, market: Object<Market>, shares: u64): HotCoin<CoinType> {
        let coin = lending::withdraw(account, market, shares);
        hot_coin::new(coin)
    }

    public fun withdraw_fa(account: &signer, market: Object<Market>, shares: u64): HotAsset {
        let asset = lending::withdraw_fa(account, market, shares);
        hot_asset::new(asset)
    }

    public fun account_coins(account: address, market: Object<Market>): u64 {
        lending::account_coins(account, market)
    }

    public fun account_shares(account: address, market: Object<Market>): u64 {
        lending::account_shares(account, market)
    }

    public fun amount_borrowable<CoinType>(account: address, market: Object<Market>): u64 {
        lending::account_borrowable_coins(account, market)
    }

    public fun amount_withdrawable<CoinType>(account: address, market: Object<Market>): u64 {
        lending::account_withdrawable_coins(account, market)
    }

    public fun coins_to_shares(market: Object<Market>, coins: u64): u64 {
        lending::coins_to_shares(market, coins)
    }

    public fun get_supply_reward<CoinType>(account: address, market: address): u64 {
        let farming_identifier = farming::farming_identifier(market, SUPPLY_MARKET_TYPE);
        let coin_type = coin::name<CoinType>();
        farming::claimable_reward_amount(account, coin_type, farming_identifier)
    }

    public fun get_supply_reward_fa(
        account: address, market: address, metadata: Object<Metadata>
    ): u64 {
        let farming_identifier = farming::farming_identifier(market, SUPPLY_MARKET_TYPE);
        farming::claimable_reward_amount(account, fungible_asset::name(metadata), farming_identifier)
    }

    public fun get_borrow_reward<CoinType>(account: address, market: address): u64 {
        let farming_identifier = farming::farming_identifier(market, BORROW_MARKET_TYPE);
        let coin_type = coin::name<CoinType>();
        farming::claimable_reward_amount(account, coin_type, farming_identifier)
    }

    public fun get_borrow_reward_fa(
        account: address, market: address, metadata: Object<Metadata>
    ): u64 {
        let farming_identifier = farming::farming_identifier(market, BORROW_MARKET_TYPE);
        farming::claimable_reward_amount(account, fungible_asset::name(metadata), farming_identifier)
    }

    public fun claim_supply_reward<CoinType>(account: &signer, market: address): HotCoin<CoinType> acquires EchelonBlock {
        let farming_identifier = farming::farming_identifier(market, SUPPLY_MARKET_TYPE);
        let coin = farming::claim_reward<CoinType>(account, farming_identifier);
        hot_coin::new_with_recipient_and_block_ref(coin, signer::address_of(account), block_ref())
    }

    public fun claim_supply_reward_fa(
        account: &signer, metadata: Object<Metadata>, market: address
    ): HotAsset acquires EchelonBlock {
        let farming_identifier = farming::farming_identifier(market, SUPPLY_MARKET_TYPE);
        let asset = farming::claim_reward_fa(account, metadata, farming_identifier);
        hot_asset::new_with_recipient_and_block_ref(asset, signer::address_of(account), block_ref())
    }
}

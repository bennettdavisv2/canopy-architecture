module satay::hot_coin {
    use std::option::{Self, Option};
    use std::signer;
    use aptos_framework::coin::{Self, Coin};

    use satay::hot_asset;
    use satay::hot_asset::HotAsset;
    use satay::protocol::{Self, BlockRef};

    friend satay::vault;
    friend satay::base_strategy;

    struct HotCoin<phantom CoinType> {
        coin: Coin<CoinType>,
        owner: Option<address>,
        recipient: Option<address>
    }

    /// Invalid block ref
    const EINVALID_BLOCK_REF: u64 = 100;
    /// Cannot destroy a hot coin with a recipient.
    const ERR_CANNOT_DESTROY_WITH_RECIPIENT: u64 = 101;

    public fun new<CoinType>(coin: Coin<CoinType>): HotCoin<CoinType> {
        HotCoin {
            coin,
            owner: option::none(),
            recipient: option::none()
        }
    }

    public fun new_from_account<CoinType>(account: &signer, amount: u64): HotCoin<CoinType> {
        let coin = coin::withdraw<CoinType>(account, amount);
        let account_address = signer::address_of(account);

        HotCoin {
            coin,
            recipient: option::none(),
            owner: option::some(account_address)
        }
    }

    public fun into_asset<CoinType>(hot_coin: HotCoin<CoinType>): HotAsset {
        let HotCoin { coin, recipient, owner } = hot_coin;
        let asset = coin::coin_to_fungible_asset(coin);

        hot_asset::new_with_recipient_and_owner(asset, recipient, owner)
    }

    public(friend) fun new_with_recipient<CoinType>(coin: Coin<CoinType>, recipient: address): HotCoin<CoinType> {
        HotCoin {
            coin,
            owner: option::none(),
            recipient: option::some(recipient)
        }
    }

    public fun new_with_recipient_and_block_ref<CoinType>(
        coin: Coin<CoinType>, recipient: address, block_ref: &BlockRef
    ): HotCoin<CoinType> {
        assert!(protocol::is_valid_block_ref(block_ref), EINVALID_BLOCK_REF);
        new_with_recipient(coin, recipient)
    }

    public(friend) fun destroy<CoinType>(hot_coin: HotCoin<CoinType>): Coin<CoinType> {
        let HotCoin { coin, recipient: _, owner: _ } = hot_coin;
        coin
    }

    public fun destroy_with_block_ref<CoinType>(
        hot_coin: HotCoin<CoinType>, block_ref: &BlockRef
    ): Coin<CoinType> {
        assert!(protocol::is_valid_block_ref(block_ref), EINVALID_BLOCK_REF);
        destroy(hot_coin)
    }

    public fun dispatch<CoinType>(hot_coin: HotCoin<CoinType>) {
        let HotCoin { coin, recipient, owner: _ } = hot_coin;
        coin::deposit(option::destroy_some(recipient), coin);
    }

    public fun owner<CoinType>(hot_coin: &HotCoin<CoinType>): Option<address> {
        hot_coin.owner
    }

    public fun recipient<CoinType>(hot_coin: &HotCoin<CoinType>): Option<address> {
        hot_coin.recipient
    }

    public fun coin<CoinType>(hot_coin: &HotCoin<CoinType>): &Coin<CoinType> {
        &hot_coin.coin
    }

    public fun value<CoinType>(hot_coin: &HotCoin<CoinType>): u64 {
        coin::value(&hot_coin.coin)
    }
}

module satay::hot_asset {
    /*
    This module implements a hot-potato wrapper around fungible assets for secure transfer of assets between packages within the Satay system.

    A "HotAsset":
      - Wraps a `FungibleAsset` with an optional recipient and owner.
      - Ensures that the asset is either transferred to the specified recipient or (if conditions require) released or destroyed (by authorized modules) for alternative usage.

    The name "hot asset" is a ref to the "hot potato" concept.
    */

    use std::option::{Self, Option};
    use std::signer;
    use aptos_framework::fungible_asset::{Self, FungibleAsset, Metadata};
    use aptos_framework::object::Object;
    use aptos_framework::primary_fungible_store::{deposit as primary_store_deposit, withdraw as primary_store_withdraw};

    use satay::protocol::{Self, BlockRef};

    friend satay::vault;
    friend satay::hot_coin;
    friend satay::base_strategy;

    /// A hot-potato wrapper around a `FungibleAsset`.
    ///
    /// * `asset`: The fungible asset being wrapped.
    /// * `recipient`: The optional recipient address of the wrapped asset.
    ///   - If `recipient` is `none`, there is no specified recipient yet.
    ///   - If `recipient` is `some(address)`, that address is meant to receive this asset.
    ///     In some cases, the recipient may end up not receiving the asset, as it might be intended
    ///     for other purposes, such as tracking the recipient of the asset's corresponding shares asset.
    struct HotAsset {
        /// The asset being wrapped.
        asset: FungibleAsset,
        /// If the hot asset is created, by withdrawing from an account, that account address is set here.
        /// This is especially useful to enforce transfer of corresponding shares asset if the hot asset represents a `base asset`.
        owner: Option<address>,
        /// The account that should receive the asset.
        recipient: Option<address>
    }

    /// Block reference is invalid.
    const EINVALID_BLOCK_REF: u64 = 100;
    /// Cannot destroy a hot asset with a recipient.
    const ERR_CANNOT_DESTROY_WITH_RECIPIENT: u64 = 101;

    /// Creates a new `HotAsset` with no specified recipient.
    ///
    /// # Parameters
    /// * `asset`: The fungible asset to wrap.
    ///
    /// # Returns
    /// A `HotAsset` wrapping the provided `FungibleAsset`, with `recipient` and `owner` set to `none`.
    public fun new(asset: FungibleAsset): HotAsset {
        HotAsset {
            asset,
            owner: option::none(),
            recipient: option::none()
        }
    }

    public(friend) fun new_with_recipient_and_owner(
        asset: FungibleAsset, recipient: Option<address>, owner: Option<address>
    ): HotAsset {
        HotAsset { asset, owner, recipient }
    }

    /// Creates a new `HotAsset` by withdrawing assets from the given account.
    ///
    /// # Parameters
    /// * `account`: The signer reference from which to withdraw the asset.
    /// * `metadata`: The `Metadata` object of the inner fungible asset.
    /// * `amount`: The amount of the fungible asset to withdraw and wrap.
    ///
    /// # Returns
    /// A new `HotAsset` that wraps the withdrawn `FungibleAsset`, with `owner` set to
    /// the address of the specified account.
    public fun new_from_account(account: &signer, metadata: Object<Metadata>, amount: u64): HotAsset {
        let asset = primary_store_withdraw(account, metadata, amount);
        let account_address = signer::address_of(account);

        HotAsset {
            asset,
            recipient: option::none(),
            owner: option::some(account_address)
        }
    }

    /// Creates a new `HotAsset` with a specified recipient.
    ///
    /// This function is friend-only accessible. It lets other modules within the satay package set a specific
    /// recipient address immediately when creating the `HotAsset`.
    ///
    /// # Parameters
    /// * `asset`: The `FungibleAsset` to wrap.
    /// * `recipient`: The address that should receive the inner `FungibleAsset`.
    ///
    /// # Returns
    /// A `HotAsset` wrapping `asset`, with `recipient` set to the specified address.
    public(friend) fun new_with_recipient(asset: FungibleAsset, recipient: address): HotAsset {
        HotAsset {
            asset,
            owner: option::none(),
            recipient: option::some(recipient)
        }
    }

    public fun new_with_recipient_and_block_ref(
        asset: FungibleAsset, recipient: address, block_ref: &BlockRef
    ): HotAsset {
        assert!(protocol::is_valid_block_ref(block_ref), EINVALID_BLOCK_REF);
        new_with_recipient(asset, recipient)
    }

    /// Destroys a `HotAsset` and returns the wrapped `FungibleAsset`.
    ///
    /// # Parameters
    /// * `hot_asset`: The `HotAsset` to destroy.
    ///
    /// # Returns
    /// The inner `FungibleAsset` that was wrapped by the `HotAsset`.
    public(friend) fun destroy(hot_asset: HotAsset): FungibleAsset {
        let HotAsset { asset, recipient: _, owner: _ } = hot_asset;
        asset
    }

    /// Destroys a `HotAsset` with an additional check for a valid `BlockRef` and returns the wrapped `FungibleAsset`.
    ///
    /// # Parameters
    /// * `hot_asset`: The `HotAsset` to destroy.
    /// * `block_ref`: The ref of a block owned by the protocol.
    ///
    /// # Returns
    /// The underlying `FungibleAsset` if `block_ref` is valid; otherwise, aborts with `EINVALID_BLOCK_REF`.
    public fun destroy_with_block_ref(hot_asset: HotAsset, block_ref: &BlockRef): FungibleAsset {
        assert!(protocol::is_valid_block_ref(block_ref), EINVALID_BLOCK_REF);
        destroy(hot_asset)
    }

    /// Dispatches the fungible asset by transferring it to the specified recipient.
    ///
    /// If `recipient` is `some(address)`, the asset is deposited into `primary_fungible_store`
    /// under that address. If `recipient` is `none`, this function will abort
    /// (because `option::destroy_some` will fail).
    ///
    /// # Parameters
    /// * `hot_asset`: The `HotAsset` to transfer.
    public fun dispatch(hot_asset: HotAsset) {
        let HotAsset { asset, recipient, owner: _ } = hot_asset;
        primary_store_deposit(option::destroy_some(recipient), asset);
    }

    /// Returns the optional owner of the hot asset.
    public fun owner(hot_asset: &HotAsset): Option<address> {
        hot_asset.owner
    }

    /// Returns the optional recipient of the hot asset.
    public fun recipient(hot_asset: &HotAsset): Option<address> {
        hot_asset.recipient
    }

    /// Returns the a reference to the inner fungible asset.
    public fun asset(hot_asset: &HotAsset): &FungibleAsset {
        &hot_asset.asset
    }

    /// Returns the amount of the inner fungible asset.
    public fun amount(hot_asset: &HotAsset): u64 {
        fungible_asset::amount(&hot_asset.asset)
    }

    /// Returns the metadata of the inner fungible asset.
    public fun asset_metadata(hot_asset: &HotAsset): Object<Metadata> {
        fungible_asset::asset_metadata(&hot_asset.asset)
    }

    #[test_only]
    public fun new_with_recipient_for_test(asset: FungibleAsset, recipient: address): HotAsset {
        new_with_recipient(asset, recipient)
    }

    #[test_only]
    public fun set_recipient_for_test(hot_asset: &mut HotAsset, recipient: address) {
        hot_asset.recipient = option::some(recipient);
    }

    #[test_only]
    public fun set_owner_for_test(hot_asset: &mut HotAsset, owner: address) {
        hot_asset.owner = option::some(owner);
    }

    #[test_only]
    public fun destroy_for_test(hot_asset: HotAsset): FungibleAsset {
        destroy(hot_asset)
    }
}

module satay::asset {
    use std::option;
    use std::signer;
    use std::string::String;
    use aptos_framework::fungible_asset::{Self, BurnRef, FungibleAsset, Metadata, MintRef, TransferRef};
    use aptos_framework::object::{Self, ConstructorRef, Object, ObjectGroup};
    use aptos_framework::primary_fungible_store;

    friend satay::vault;
    friend satay::base_strategy;

    #[resource_group_member(group = ObjectGroup)]
    struct AssetController has key {
        mint_ref: MintRef,
        burn_ref: BurnRef,
        transfer_ref: TransferRef
    }

    const ENOT_ASSET_OWNER: u64 = 0;
    const EASSET_CONTROLLER_NOT_FOUND: u64 = 1;
    const EASSET_META_NOT_FOUND: u64 = 2;

    public(friend) fun create(
        owner: &signer,
        name: String,
        symbol: String,
        decimals: u8,
        icon_uri: String,
        project_uri: String
    ): Object<Metadata> {
        let owner_address = signer::address_of(owner);
        let constructor_ref = object::create_sticky_object(owner_address);
        create_internal(&constructor_ref, name, symbol, decimals, icon_uri, project_uri)
    }

    public(friend) fun create_with_seed(
        owner: &signer,
        seed: vector<u8>,
        name: String,
        symbol: String,
        decimals: u8,
        icon_uri: String,
        project_uri: String
    ): Object<Metadata> {
        let constructor_ref = object::create_named_object(owner, seed);
        create_internal(&constructor_ref, name, symbol, decimals, icon_uri, project_uri)
    }

    fun create_internal(
        constructor_ref: &ConstructorRef,
        name: String,
        symbol: String,
        decimals: u8,
        icon_uri: String,
        project_uri: String
    ): Object<Metadata> {
        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            constructor_ref,
            option::none(),
            name,
            symbol,
            decimals,
            icon_uri,
            project_uri
        );

        let mint_ref = fungible_asset::generate_mint_ref(constructor_ref);
        let burn_ref = fungible_asset::generate_burn_ref(constructor_ref);
        let transfer_ref = fungible_asset::generate_transfer_ref(constructor_ref);

        let asset_signer = object::generate_signer(constructor_ref);
        let controller = AssetController { mint_ref, burn_ref, transfer_ref };
        move_to(&asset_signer, controller);

        object::object_from_constructor_ref(constructor_ref)
    }

    public fun safe_mint(signer: &signer, metadata: Object<Metadata>, amount: u64): FungibleAsset acquires AssetController {
        assert!(object::is_owner(metadata, signer::address_of(signer)), ENOT_ASSET_OWNER);
        mint(metadata, amount)
    }

    public(friend) fun mint(metadata: Object<Metadata>, amount: u64): FungibleAsset acquires AssetController {
        let asset_address = object::object_address(&metadata);
        let controller = borrow_global<AssetController>(asset_address);
        fungible_asset::mint(&controller.mint_ref, amount)
    }

    public fun safe_burn(signer: &signer, asset: FungibleAsset): u64 acquires AssetController {
        let metadata = fungible_asset::asset_metadata(&asset);
        assert!(object::is_owner(metadata, signer::address_of(signer)), ENOT_ASSET_OWNER);
        burn(asset)
    }

    public(friend) fun burn(asset: FungibleAsset): u64 acquires AssetController {
        let asset_address = object::object_address(&fungible_asset::asset_metadata(&asset));
        let controller = borrow_global<AssetController>(asset_address);

        let amount = fungible_asset::amount(&asset);
        fungible_asset::burn(&controller.burn_ref, asset);
        amount
    }

    #[test_only]
    public fun create_for_test(
        owner: &signer,
        name: String,
        symbol: String,
        decimals: u8,
        icon_uri: String,
        project_uri: String
    ): Object<Metadata> {
        create(owner, name, symbol, decimals, icon_uri, project_uri)
    }

    #[test_only]
    public fun create_with_seed_for_test(
        owner: &signer,
        seed: vector<u8>,
        name: String,
        symbol: String,
        decimals: u8,
        icon_uri: String,
        project_uri: String
    ): Object<Metadata> {
        create_with_seed(owner, seed, name, symbol, decimals, icon_uri, project_uri)
    }
}

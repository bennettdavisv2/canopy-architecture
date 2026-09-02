module canopy_staking::token_fa_wrapper {

    use aptos_framework::account::{Self, SignerCapability};
    use aptos_framework::fungible_asset::{Self, BurnRef, FungibleAsset, Metadata, MintRef};
    use aptos_framework::object::{Self, Object};
    use aptos_framework::primary_fungible_store;

    use aptos_token::token::{Self, TokenId};

    use aptos_std::smart_table::{Self, SmartTable};

    use std::option;
    use std::string::{Self, String};
    use std::signer;

    // - - - Error Codes - - -

    /// Invalid Aptos Token
    const E_INVALID_TOKEN_DATA: u64 = 1000;

    /// Seed used for creating the resource account.
    const SEED: vector<u8> = b"TOKEN_FA_WRAPPER_MODULE_SEED";

    /// Stores the refs for a specific fungible asset wrapper for wrapping and unwrapping.
    struct FungibleAssetData has store {
        // Used during unwrapping to burn the internal fungible assets.
        burn_ref: BurnRef,
        // Reference to the metadata object.
        metadata: Object<Metadata>,
        // Used during wrapping to mint the internal fungible assets.
        mint_ref: MintRef
    }

    /// The resource stored in the main resource account to track all the fungible asset wrappers.
    /// This main resource account will also be the one holding all the deposited tokens.
    struct WrapperAccount has key {
        // The signer cap used to withdraw deposited tokens from the main resource account during unwrapping so the
        // tokens can be returned to the end users.
        signer_cap: SignerCapability,
        // Map from an original token id (represented as TokenId) to the corresponding fungible asset wrapper.
        token_to_fungible_asset: SmartTable<TokenId, FungibleAssetData>,
        // Map from a fungible asset wrapper to the original token id.
        fungible_asset_to_token: SmartTable<Object<Metadata>, TokenId>
    }

    // - - - - - - CONSTRUCTOR FUNCTION - - - - - -

    /// Since the pkg will be published under an object the signer will be the pkg's object signer
    fun init_module(object_signer: &signer) {
        let (_, resource_signer_cap) = account::create_resource_account(object_signer, SEED);
        move_to(
            object_signer,
            WrapperAccount {
                signer_cap: resource_signer_cap,
                token_to_fungible_asset: smart_table::new(),
                fungible_asset_to_token: smart_table::new()
            }
        );
    }

    public fun wrap(user: &signer, token_id: TokenId, amount: u64): FungibleAsset acquires WrapperAccount {
        // Ensure the fungible asset wrapper exists for this token
        create_fungible_asset(token_id);

        // Withdraw the token from the user
        let token = token::withdraw_token(user, token_id, amount);

        // Get the wrapper account
        let wrapper_account = borrow_global_mut<WrapperAccount>(@canopy_staking);

        // Get the fungible asset data for this token
        let fa_data = smart_table::borrow(&wrapper_account.token_to_fungible_asset, token_id);

        // Deposit the token to the wrapper account
        let wrapper_signer = account::create_signer_with_capability(&wrapper_account.signer_cap);
        token::deposit_token(&wrapper_signer, token);

        // Mint the corresponding fungible asset
        let fa = fungible_asset::mint(&fa_data.mint_ref, amount);

        // Return the fungible asset to the user
        fa
    }

    public fun unwrap(user: &signer, token_id: TokenId, amount: u64) acquires WrapperAccount {
        // Get the wrapper account
        let wrapper_account = borrow_global_mut<WrapperAccount>(@canopy_staking);

        // Get the fungible asset data for this token
        let fa_data = smart_table::borrow(&wrapper_account.token_to_fungible_asset, token_id);

        // Withdraw the fungible asset from the user's primary store
        let fa = primary_fungible_store::withdraw(user, fa_data.metadata, amount);

        // Burn the fungible asset
        fungible_asset::burn(&fa_data.burn_ref, fa);

        // Withdraw the original token from the wrapper account
        let wrapper_signer = account::create_signer_with_capability(&wrapper_account.signer_cap);
        let token = token::withdraw_token(&wrapper_signer, token_id, amount);

        // Deposit the original token back to the user
        token::deposit_token(user, token);
    }

    // Helper function to create a fungible asset wrapper if it doesn't exist
    public fun create_fungible_asset(token_id: TokenId) acquires WrapperAccount {
        let wrapper_account = borrow_global_mut<WrapperAccount>(@canopy_staking);

        // Get token data ID information
        let token_data_id = token::get_tokendata_id(token_id);
        let (creator, collection, name) = token::get_token_data_id_fields(&token_data_id);

        // Assert that the token data exists
        assert!(
            token::check_tokendata_exists(creator, collection, name),
            E_INVALID_TOKEN_DATA
        );

        if (!smart_table::contains(&wrapper_account.token_to_fungible_asset, token_id)) {
            // Truncate collection name if it exceeds 32 characters and add a suffix to ensure uniqueness
            let fa_name =
                if (string::length(&collection) > 32) {
                    // Take first 28 chars and add "-FA" suffix to stay within 32 char limit
                    let truncated = string::sub_string(&collection, 0, 28);
                    string::append(&mut truncated, string::utf8(b"-FA"));
                    truncated
                } else {
                    collection
                };

            // Truncate token name if it exceeds 10 characters and add identifying suffix
            let fa_symbol =
                if (string::length(&name) > 10) {
                    // Take first 7 chars and add "FA" suffix to stay within 10 char limit
                    let truncated = string::sub_string(&name, 0, 7);
                    string::append(&mut truncated, string::utf8(b"FA"));
                    truncated
                } else { name };

            let resource_signer = account::create_signer_with_capability(&wrapper_account.signer_cap);
            let resource_account_addr = signer::address_of(&resource_signer);

            let metadata_constructor_ref = object::create_sticky_object(resource_account_addr);

            primary_fungible_store::create_primary_store_enabled_fungible_asset(
                &metadata_constructor_ref,
                option::none(), // maximum_supply
                fa_name, // truncated collection name if needed
                fa_symbol, // truncated name if needed
                0, // decimals; use 0
                string::utf8(b""), // URI can be empty or set as needed
                string::utf8(b"") // Project URL can be empty or set as needed
            );

            let mint_ref = fungible_asset::generate_mint_ref(&metadata_constructor_ref);
            let burn_ref = fungible_asset::generate_burn_ref(&metadata_constructor_ref);
            let metadata = object::object_from_constructor_ref<Metadata>(&metadata_constructor_ref);

            smart_table::add(
                &mut wrapper_account.token_to_fungible_asset,
                token_id,
                FungibleAssetData { burn_ref, metadata, mint_ref }
            );
            smart_table::add(&mut wrapper_account.fungible_asset_to_token, metadata, token_id);
        }
    }

    // - - - - - - VIEW FUNCTIONS - - - - - -

    // - - - - PSEUDO-VIEW FUNCTIONS - - - -

    /// Check if a fungible asset wrapper exists for a given token id
    public fun is_wrapper_exists(token_id: TokenId): bool acquires WrapperAccount {
        let wrapper_account = borrow_global<WrapperAccount>(@canopy_staking);
        smart_table::contains(&wrapper_account.token_to_fungible_asset, token_id)
    }

    /// Get the fungible asset metadata for a given token id
    public fun get_fungible_asset_metadata(token_id: &TokenId): Object<Metadata> acquires WrapperAccount {
        let wrapper_account = borrow_global<WrapperAccount>(@canopy_staking);
        let fa_data = smart_table::borrow(&wrapper_account.token_to_fungible_asset, *token_id);
        fa_data.metadata
    }

    /// Get the token id for a given fungible asset metadata
    public fun get_token_id(metadata: Object<Metadata>): TokenId acquires WrapperAccount {
        let wrapper_account = borrow_global<WrapperAccount>(@canopy_staking);
        *smart_table::borrow(&wrapper_account.fungible_asset_to_token, metadata)
    }

    /// Get the balance of wrapped tokens for a specific token id and address
    public fun get_wrapped_balance(addr: address, token_id: &TokenId): u64 acquires WrapperAccount {
        let fa_metadata = get_fungible_asset_metadata(token_id);
        primary_fungible_store::balance(addr, fa_metadata)
    }

    // - - - - ACTUAL VIEW FUNCTIONS - - - -

    #[view]
    /// Return the address of the resource account that stores all deposited coins.
    public fun wrapper_address(): address acquires WrapperAccount {
        // it's simpler to get the resource account address as follows instead of precomputing the address
        // and referencing an address literal
        let resource_signer = get_resource_signer();
        signer::address_of(&resource_signer)
    }

    #[view]
    public fun does_wrapper_exist(
        creator: address,
        collection: String,
        name: String,
        property_version: u64
    ): bool acquires WrapperAccount {
        let token_id = token::create_token_id_raw(creator, collection, name, property_version);
        is_wrapper_exists(token_id)
    }

    #[view]
    public fun get_fa_wrapper_metadata(
        creator: address,
        collection: String,
        name: String,
        property_version: u64
    ): Object<Metadata> acquires WrapperAccount {
        let token_id = token::create_token_id_raw(creator, collection, name, property_version);
        get_fungible_asset_metadata(&token_id)
    }

    #[view]
    public fun get_token_id_fields(metadata: Object<Metadata>): (address, String, String, u64) acquires WrapperAccount {
        let token_id = get_token_id(metadata);
        token::get_token_id_fields(&token_id)
    }

    #[view]
    public fun get_fa_wrapped_balance(
        addr_to_check: address,
        creator: address,
        collection: String,
        name: String,
        property_version: u64
    ): u64 acquires WrapperAccount {
        let token_id = token::create_token_id_raw(creator, collection, name, property_version);
        get_wrapped_balance(addr_to_check, &token_id)
    }

    #[view]
    public fun get_token_balance(
        addr_to_check: address,
        creator: address,
        collection: String,
        name: String,
        property_version: u64
    ): u64 {
        let token_id = token::create_token_id_raw(creator, collection, name, property_version);
        token::balance_of(addr_to_check, token_id)
    }

    // - - - - - - Internal Functions - - - - - -

    fun get_resource_signer(): signer acquires WrapperAccount {
        let wrapper_account = borrow_global<WrapperAccount>(@canopy_staking);
        account::create_signer_with_capability(&wrapper_account.signer_cap)
    }

    // - - - - - - TEST ONLY - - - - - -

    // - - - - - - TEST ONLY: functions - - - - - -

    #[test_only]
    public fun init_module_for_test() {
        let canopy_staking = account::create_account_for_test(@canopy_staking);
        init_module(&canopy_staking);
    }
}

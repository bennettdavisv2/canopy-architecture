module canopy_helpers::helpers {
    use std::vector;

    use aptos_framework::object::Object;
    use aptos_framework::fungible_asset::Metadata;

    use aptos_framework::primary_fungible_store;

    use satay::vault::{Self, Vault};

    // - - - VIEW FUNCTIONS - - - -

    #[view]
    public fun batch_get_fa_balance(
        metadatas: vector<Object<Metadata>>, user_address: address
    ): vector<u64> {
        let result = vector::empty();
        let i = 0;
        let len = vector::length(&metadatas);

        while (i < len) {
            let metadata = metadatas[i];
            let contribution = primary_fungible_store::balance(user_address, metadata);
            vector::push_back(&mut result, contribution);
            i += 1;
        };
        result
    }

    #[view]
    public fun batch_get_vault_balance(
        vaults: vector<Object<Vault>>, user_address: address
    ): vector<u64> {
        let (_, balances) = batch_get_vault_shares_metadata_and_balance(
            vaults,
            user_address
        );
        balances
    }

    #[view]
    public fun batch_get_vault_shares_metadata_and_balance(
        vaults: vector<Object<Vault>>, user_address: address
    ): (vector<Object<Metadata>>, vector<u64>) {
        let shares_metadatas = vector::empty();
        let shares_balances = vector::empty();
        let i = 0;
        let len = vector::length(&vaults);

        while (i < len) {
            let vault = vaults[i];
            let shares_metadata = vault::shares_metadata(vault);
            let shares_balance = primary_fungible_store::balance(user_address, shares_metadata);
            vector::push_back(&mut shares_metadatas, shares_metadata);
            vector::push_back(&mut shares_balances, shares_balance);
            i += 1;
        };
        (shares_metadatas, shares_balances)
    }

    #[view]
    public fun batch_get_vault_base_metadata_and_balance(
        vaults: vector<Object<Vault>>, user_address: address
    ): (vector<Object<Metadata>>, vector<u64>) {
        let base_metadatas = vector::empty();
        let base_balances = vector::empty();
        let i = 0;
        let len = vector::length(&vaults);

        while (i < len) {
            let vault = vaults[i];
            let base_metadata = vault::base_metadata(vault);
            let base_balance = primary_fungible_store::balance(user_address, base_metadata);
            vector::push_back(&mut base_metadatas, base_metadata);
            vector::push_back(&mut base_balances, base_balance);
            i += 1;
        };
        (base_metadatas, base_balances)
    }

    #[view]
    public fun batch_get_vault_all_metadata_and_balance(
        vaults: vector<Object<Vault>>, user_address: address
    ): (vector<Object<Metadata>>, vector<u64>, vector<Object<Metadata>>, vector<u64>) {
        let shares_metadatas = vector::empty();
        let shares_balances = vector::empty();
        let base_metadatas = vector::empty();
        let base_balances = vector::empty();
        let i = 0;
        let len = vector::length(&vaults);

        while (i < len) {
            let vault = vaults[i];
            let shares_metadata = vault::shares_metadata(vault);
            let base_metadata = vault::base_metadata(vault);
            let shares_balance = primary_fungible_store::balance(user_address, shares_metadata);
            let base_balance = primary_fungible_store::balance(user_address, base_metadata);

            vector::push_back(&mut shares_metadatas, shares_metadata);
            vector::push_back(&mut shares_balances, shares_balance);
            vector::push_back(&mut base_metadatas, base_metadata);
            vector::push_back(&mut base_balances, base_balance);
            i += 1;
        };
        (shares_metadatas, shares_balances, base_metadatas, base_balances)
    }

}

module satay_router::router {
    use std::option::{Self, Option};
    use std::vector;
    use std::signer;
    use aptos_std::simple_map;
    use aptos_framework::object::{Self, Object};
    use aptos_framework::primary_fungible_store;
    use aptos_framework::coin;

    use satay::base_strategy::BaseStrategy;
    use satay::hot_asset;
    use satay::hot_coin;
    use satay::protocol;
    use satay::vault::{Self, Vault};

    use satay_router::auth;
    use satay_router::deposit;
    use satay_router::harvest;
    use satay_router::withdraw;

    // Error codes

    /// The amount of shares out is not enough.
    const ENOT_ENOUGH_OUT_SHARES: u64 = 1;
    /// The amount of coins out is not enough.
    const ENOT_ENOUGH_OUT_AMOUNT: u64 = 2;

    public entry fun deposit_coin<CoinType, RewardCoinType>(
        account: &signer,
        vault: Object<Vault>,
        packets_keys: vector<Object<BaseStrategy>>,
        packets_values: vector<vector<u8>>,
        amount: u64,
        min_shares_out: Option<u64>
    ) {
        if (protocol::should_auto_harvest()) {
            vault_harvest_coin<RewardCoinType>(vault);
            vault_report(vault);
        } else if (protocol::should_auto_report()) {
            vault_report(vault)
        };

        let hot_asset = hot_coin::into_asset(hot_coin::new_from_account<CoinType>(account, amount));
        let vault_shares = vault::deposit(vault, hot_asset);
        if (option::is_some(&min_shares_out)) {
            assert!(
                hot_asset::amount(&vault_shares) >= option::destroy_some(min_shares_out),
                ENOT_ENOUGH_OUT_SHARES
            );
        };

        hot_asset::dispatch(vault_shares);
        let packets = create_packets_map(packets_keys, packets_values);
        deposit::deploy_coin_funds<CoinType>(vault, packets);
    }

    public entry fun deposit_fa(
        account: &signer,
        vault: Object<Vault>,
        packets_keys: vector<Object<BaseStrategy>>,
        packets_values: vector<vector<u8>>,
        amount: u64,
        min_shares_out: Option<u64>
    ) {
        if (protocol::should_auto_harvest()) {
            vault_harvest_fa(vault);
            vault_report(vault);
        } else if (protocol::should_auto_report()) {
            vault_report(vault)
        };

        // If user deposits native asset, migrate to fungible_store if needed.
        let base_metadata = vault::base_metadata(vault);
        if (object::object_address(&base_metadata) == @0xa
            && (
                !primary_fungible_store::primary_store_exists(signer::address_of(account), base_metadata)
                    || primary_fungible_store::balance(signer::address_of(account), base_metadata) <= amount
            )) {
            coin::migrate_to_fungible_store<0x1::aptos_coin::AptosCoin>(account);
        };

        let hot_asset = hot_asset::new_from_account(account, vault::base_metadata(vault), amount);
        let vault_shares = vault::deposit(vault, hot_asset);
        if (option::is_some(&min_shares_out)) {
            assert!(
                hot_asset::amount(&vault_shares) >= option::destroy_some(min_shares_out),
                ENOT_ENOUGH_OUT_SHARES
            );
        };

        hot_asset::dispatch(vault_shares);

        let packets = create_packets_map(packets_keys, packets_values);
        deposit::deploy_fa_funds(vault, packets);
    }

    public entry fun deposit_fa_with_coin_type<WrapperCoinType>(
        account: &signer,
        vault: Object<Vault>,
        packets_keys: vector<Object<BaseStrategy>>,
        packets_values: vector<vector<u8>>,
        amount: u64,
        min_shares_out: Option<u64>
    ) {
        if (protocol::should_auto_harvest()) {
            vault_harvest_fa(vault);
            vault_report(vault);
        } else if (protocol::should_auto_report()) {
            vault_report(vault)
        };

        // If user deposits native asset, migrate to fungible_store if needed.
        let base_metadata = vault::base_metadata(vault);
        if (object::object_address(&base_metadata) == @0xa
            && (
                !primary_fungible_store::primary_store_exists(signer::address_of(account), base_metadata)
                    || primary_fungible_store::balance(signer::address_of(account), base_metadata) <= amount
            )) {
            coin::migrate_to_fungible_store<0x1::aptos_coin::AptosCoin>(account);
        };

        let hot_asset = hot_asset::new_from_account(account, vault::base_metadata(vault), amount);
        let vault_shares = vault::deposit(vault, hot_asset);
        if (option::is_some(&min_shares_out)) {
            assert!(
                hot_asset::amount(&vault_shares) >= option::destroy_some(min_shares_out),
                ENOT_ENOUGH_OUT_SHARES
            );
        };

        hot_asset::dispatch(vault_shares);

        let packets = create_packets_map(packets_keys, packets_values);
        deposit::deploy_fa_funds_with_coin_type<WrapperCoinType>(vault, packets);
    }

    public entry fun withdraw_coin<CoinType, RewardCoinType>(
        account: &signer,
        vault: Object<Vault>,
        packets_keys: vector<Object<BaseStrategy>>,
        packets_values: vector<vector<u8>>,
        amount: u64,
        max_loss: Option<u64>,
        min_amount_out: Option<u64>
    ) {
        if (protocol::should_auto_harvest()) {
            vault_harvest_coin<RewardCoinType>(vault);
            vault_report(vault);
        } else if (protocol::should_auto_report()) {
            vault_report(vault)
        };

        let shares_asset = hot_asset::new_from_account(account, vault::shares_metadata(vault), amount);
        let request = vault::request_withdrawal(account, vault, shares_asset);
        vault::withdraw(account, &mut request);

        let packets = create_packets_map(packets_keys, packets_values);

        if (vault::withdrawal_remaining(&request) > 0) {
            let withdrawal_map = withdraw::get_withdrawal_map(vault, &request);
            let strategies = vault::vault_strategies(vault);

            vector::for_each(
                strategies,
                |strategy| {
                    let amount = *simple_map::borrow(&withdrawal_map, &strategy);
                    let packet =
                        if (simple_map::contains_key(&packets, &strategy)) {
                            option::some(*simple_map::borrow(&packets, &strategy))
                        } else {
                            option::none()
                        };

                    let hot_coin =
                        withdraw::withdraw_coin<CoinType>(account, &mut request, strategy, packet, amount, max_loss);

                    let hot_asset = hot_coin::into_asset(hot_coin);
                    vault::apply_strategy_withdrawal(&mut request, strategy, hot_asset, amount);
                }
            );
        };

        let coin = vault::complete_withdrawal_coin<CoinType>(account, request, max_loss);
        if (option::is_some(&min_amount_out)) {
            assert!(
                hot_coin::value(&coin) >= option::destroy_some(min_amount_out),
                ENOT_ENOUGH_OUT_AMOUNT
            );
        };

        hot_coin::dispatch(coin);
    }

    public entry fun withdraw_fa(
        account: &signer,
        vault: Object<Vault>,
        packets_keys: vector<Object<BaseStrategy>>,
        packets_values: vector<vector<u8>>,
        amount: u64,
        max_loss: Option<u64>,
        min_amount_out: Option<u64>
    ) {
        if (protocol::should_auto_harvest()) {
            vault_harvest_fa(vault);
            vault_report(vault);
        } else if (protocol::should_auto_report()) {
            vault_report(vault)
        };

        let shares_asset = hot_asset::new_from_account(account, vault::shares_metadata(vault), amount);
        let request = vault::request_withdrawal(account, vault, shares_asset);
        vault::withdraw(account, &mut request);

        let packets = create_packets_map(packets_keys, packets_values);

        if (vault::withdrawal_remaining(&request) > 0) {
            let withdrawal_map = withdraw::get_withdrawal_map(vault, &request);
            let strategies = vault::vault_strategies(vault);
            vector::for_each(
                strategies,
                |strategy| {
                    let amount = *simple_map::borrow(&withdrawal_map, &strategy);
                    let packet =
                        if (simple_map::contains_key(&packets, &strategy)) {
                            option::some(*simple_map::borrow(&packets, &strategy))
                        } else {
                            option::none()
                        };

                    let asset = withdraw::withdraw_fa(account, &mut request, strategy, packet, amount, max_loss);
                    vault::apply_strategy_withdrawal(&mut request, strategy, asset, amount);
                }
            );
        };

        let asset = vault::complete_withdrawal(account, request, max_loss);
        if (option::is_some(&min_amount_out)) {
            assert!(
                hot_asset::amount(&asset) >= option::destroy_some(min_amount_out),
                ENOT_ENOUGH_OUT_AMOUNT
            );
        };

        hot_asset::dispatch(asset);
    }

    // This function is used to withdraw FA from strategies that may use a Coin Wrapper.
    // The WrapperCoinType parameter is used by strategies that implement coin wrapping functionality
    // (like Meridian's wrapper coin type). For strategies that only use FA (without coin wrapping),
    // this type parameter is ignored (and this function behaves as withdraw_fa).
    public entry fun withdraw_fa_with_coin_type<WrapperCoinType>(
        account: &signer,
        vault: Object<Vault>,
        packets_keys: vector<Object<BaseStrategy>>,
        packets_values: vector<vector<u8>>,
        amount: u64,
        max_loss: Option<u64>,
        min_amount_out: Option<u64>
    ) {
        if (protocol::should_auto_harvest()) {
            vault_harvest_fa(vault);
            vault_report(vault);
        } else if (protocol::should_auto_report()) {
            vault_report(vault)
        };

        let shares_asset = hot_asset::new_from_account(account, vault::shares_metadata(vault), amount);
        let request = vault::request_withdrawal(account, vault, shares_asset);
        vault::withdraw(account, &mut request);

        let packets = create_packets_map(packets_keys, packets_values);

        if (vault::withdrawal_remaining(&request) > 0) {
            let withdrawal_map = withdraw::get_withdrawal_map(vault, &request);
            let strategies = vault::vault_strategies(vault);
            vector::for_each(
                strategies,
                |strategy| {
                    let amount = *simple_map::borrow(&withdrawal_map, &strategy);
                    let packet =
                        if (simple_map::contains_key(&packets, &strategy)) {
                            option::some(*simple_map::borrow(&packets, &strategy))
                        } else {
                            option::none()
                        };

                    let asset =
                        withdraw::withdraw_fa_with_coin_type<WrapperCoinType>(
                            account, &mut request, strategy, packet, amount, max_loss
                        );
                    vault::apply_strategy_withdrawal(&mut request, strategy, asset, amount);
                }
            );
        };

        let asset = vault::complete_withdrawal(account, request, max_loss);
        if (option::is_some(&min_amount_out)) {
            assert!(
                hot_asset::amount(&asset) >= option::destroy_some(min_amount_out),
                ENOT_ENOUGH_OUT_AMOUNT
            );
        };

        hot_asset::dispatch(asset);
    }

    fun vault_report(vault: Object<Vault>) {
        let borrowed_router_ref = auth::borrow_router_ref();
        let router_ref = auth::borrowed_ref(&borrowed_router_ref);

        let vault_signer = vault::get_signer_for_router(vault, router_ref);
        auth::return_router_ref(borrowed_router_ref);

        vector::for_each(
            vault::vault_strategies(vault),
            |strategy| {
                vault::report(&vault_signer, vault, strategy);
            }
        );
    }

    fun vault_harvest_coin<CoinType>(vault: Object<Vault>) {
        vector::for_each(
            vault::vault_strategies(vault),
            |strategy| {
                harvest::harvest_coin<CoinType>(strategy);
            }
        );
    }

    fun vault_harvest_fa(vault: Object<Vault>) {
        vector::for_each(
            vault::vault_strategies(vault),
            |strategy| {
                harvest::harvest_fa(strategy);
            }
        );
    }

    /// Creates a simple_map from keys and values vectors.
    /// If the keys vector is empty, returns an empty simple_map instead.
    fun create_packets_map<K: store + copy + drop, V: store + copy + drop>(
        keys: vector<K>, values: vector<V>
    ): simple_map::SimpleMap<K, V> {
        if (vector::length(&keys) > 0) {
            simple_map::new_from(keys, values)
        } else {
            simple_map::new()
        }
    }
}

module satay_router::deposit {
    use std::option::{Self, Option};
    use std::vector;
    use aptos_std::math64;
    use aptos_std::simple_map::{Self, SimpleMap};
    use aptos_framework::object::Object;

    use echelon_simple::strategy as echelon_simple;
    use layerbank_simple::strategy as layerbank_simple;
    use moveposition_simple::strategy as moveposition_simple;
    use meridian_rewards::strategy as meridian_rewards;
    use placeholder_simple::strategy as placeholder_simple;

    use satay::base_strategy::{Self, BaseStrategy};
    use satay::vault::{Self, Vault};

    use satay_router::auth;

    friend satay_router::router;

    /// Strategies and capacities vectors do not match
    const EVECTORS_LENGTH_MISMATCH: u64 = 0;

    public(friend) fun deposit_coin<CoinType>(
        vault: Object<Vault>,
        strategy: Object<BaseStrategy>,
        packet: Option<vector<u8>>,
        amount: u64
    ) {
        let borrowed_router_ref = auth::borrow_router_ref();
        let vault_signer = vault::get_signer_for_router(vault, auth::borrowed_ref(&borrowed_router_ref));
        auth::return_router_ref(borrowed_router_ref);

        let concrete_address = base_strategy::concrete_address(strategy);
        if (concrete_address == @echelon_simple) {
            echelon_simple::vault_deposit_coin<CoinType>(&vault_signer, strategy, amount);
        } else if (concrete_address == @moveposition_simple) {
            let packet = option::destroy_some(packet);
            moveposition_simple::vault_deposit_coin<CoinType>(&vault_signer, strategy, packet, amount);
        } else if (concrete_address == @meridian_rewards) {
            meridian_rewards::vault_deposit_fa<CoinType>(&vault_signer, strategy, amount);
        } else if (concrete_address == @placeholder_simple) {
            placeholder_simple::vault_deposit_coin<CoinType>(&vault_signer, strategy, amount);
        }
    }

    public(friend) fun deposit_fa(
        vault: Object<Vault>,
        strategy: Object<BaseStrategy>,
        packet: Option<vector<u8>>,
        amount: u64
    ) {
        let borrowed_router_ref = auth::borrow_router_ref();
        let vault_signer = vault::get_signer_for_router(vault, auth::borrowed_ref(&borrowed_router_ref));
        auth::return_router_ref(borrowed_router_ref);

        let concrete_address = base_strategy::concrete_address(strategy);
        if (concrete_address == @echelon_simple) {
            echelon_simple::vault_deposit_fa(&vault_signer, strategy, amount);
        } else if (concrete_address == @moveposition_simple) {
            let packet = option::destroy_some(packet);
            moveposition_simple::vault_deposit_fa(&vault_signer, strategy, packet, amount);
        } else if (concrete_address == @layerbank_simple) {
            layerbank_simple::vault_deposit_fa(&vault_signer, strategy, amount);
        } else if (concrete_address == @placeholder_simple) {
            placeholder_simple::vault_deposit_fa(&vault_signer, strategy, amount);
        };
    }

    public(friend) fun deposit_fa_with_coin_type<WrapperCoinType>(
        vault: Object<Vault>,
        strategy: Object<BaseStrategy>,
        packet: Option<vector<u8>>,
        amount: u64
    ) {
        let borrowed_router_ref = auth::borrow_router_ref();
        let vault_signer = vault::get_signer_for_router(vault, auth::borrowed_ref(&borrowed_router_ref));
        auth::return_router_ref(borrowed_router_ref);

        let concrete_address = base_strategy::concrete_address(strategy);
        if (concrete_address == @echelon_simple) {
            echelon_simple::vault_deposit_fa(&vault_signer, strategy, amount);
        } else if (concrete_address == @moveposition_simple) {
            let packet = option::destroy_some(packet);
            moveposition_simple::vault_deposit_fa(&vault_signer, strategy, packet, amount);
        } else if (concrete_address == @layerbank_simple) {
            layerbank_simple::vault_deposit_fa(&vault_signer, strategy, amount);
        } else if (concrete_address == @meridian_rewards) {
            meridian_rewards::vault_deposit_fa<WrapperCoinType>(&vault_signer, strategy, amount);
        } else if (concrete_address == @placeholder_simple) {
            placeholder_simple::vault_deposit_fa(&vault_signer, strategy, amount);
        };
    }

    public(friend) fun deploy_fa_funds(
        vault: Object<Vault>,
        packets: SimpleMap<Object<BaseStrategy>, vector<u8>>
    ) {
        let total_idle = vault::total_idle(vault);
        let strategies = vault::vault_strategies(vault);
        if (total_idle == 0 || vector::is_empty(&strategies))
            return;

        let (total_capacity, capacities) = get_capacities(vault);
        assert!(
            vector::length(&capacities) == vector::length(&strategies),
            EVECTORS_LENGTH_MISMATCH
        );

        for (i in 0..vector::length(&capacities)) {
            let capacity = *vector::borrow(&capacities, i);
            if (capacity != 0) {
                let strategy = *vector::borrow(&strategies, i);
                let amount = math64::mul_div(capacity, total_idle, total_capacity);
                let packet =
                    if (simple_map::contains_key(&packets, &strategy)) {
                        option::some(*simple_map::borrow(&packets, &strategy))
                    } else {
                        option::none()
                    };

                deposit_fa(vault, strategy, packet, amount);
            }
        }
    }


    public(friend) fun deploy_fa_funds_with_coin_type<WrapperCoinType>(
        vault: Object<Vault>,
        packets: SimpleMap<Object<BaseStrategy>, vector<u8>>
    ) {
        let total_idle = vault::total_idle(vault);
        let strategies = vault::vault_strategies(vault);
        if (total_idle == 0 || vector::is_empty(&strategies))
            return;

        let (total_capacity, capacities) = get_capacities(vault);
        assert!(
            vector::length(&capacities) == vector::length(&strategies),
            EVECTORS_LENGTH_MISMATCH
        );

        for (i in 0..vector::length(&capacities)) {
            let capacity = *vector::borrow(&capacities, i);
            if (capacity != 0) {
                let strategy = *vector::borrow(&strategies, i);
                let amount = math64::mul_div(capacity, total_idle, total_capacity);
                let packet =
                    if (simple_map::contains_key(&packets, &strategy)) {
                        option::some(*simple_map::borrow(&packets, &strategy))
                    } else {
                        option::none()
                    };

                deposit_fa_with_coin_type<WrapperCoinType>(vault, strategy, packet, amount);
            }
        }
    }

    public(friend) fun deploy_coin_funds<CoinType>(
        vault: Object<Vault>,
        packets: SimpleMap<Object<BaseStrategy>, vector<u8>>
    ) {
        let total_idle = vault::total_idle(vault);
        let strategies = vault::vault_strategies(vault);
        if (total_idle == 0 || vector::is_empty(&strategies))
            return;

        let (total_capacity, capacities) = get_capacities(vault);
        assert!(
            vector::length(&strategies) == vector::length(&capacities),
            EVECTORS_LENGTH_MISMATCH
        );

        for (i in 0..vector::length(&capacities)) {
            let capacity = *vector::borrow(&capacities, i);
            if (capacity != 0) {
                let strategy = *vector::borrow(&strategies, i);
                let amount = math64::mul_div(capacity, total_idle, total_capacity);
                let packet =
                    if (simple_map::contains_key(&packets, &strategy)) {
                        option::some(*simple_map::borrow(&packets, &strategy))
                    } else {
                        option::none()
                    };
                deposit_coin<CoinType>(vault, strategy, packet, amount);
            }
        }
    }

    fun get_capacities(vault: Object<Vault>): (u64, vector<u64>) {
        // Total amount that can be allocated to strategies.
        // This is the sum of the difference between the debt limit and the current debt for each strategy.
        let total_capacity = 0;
        // The amount that can be allocated to each strategy. It is the difference between the debt limit and the current debt.
        let capacities = vector::empty<u64>();

        vector::for_each(
            vault::vault_strategies(vault),
            |strategy| {
                let strategy_debt = vault::strategy_debt(vault, strategy);
                let strategy_debt_limit = vault::strategy_debt_limit(vault, strategy);

                if (strategy_debt_limit > strategy_debt) {
                    let capacity = strategy_debt_limit - strategy_debt;
                    vector::push_back(&mut capacities, capacity);
                    total_capacity = total_capacity + capacity;
                } else {
                    vector::push_back(&mut capacities, 0);
                }
            }
        );

        (total_capacity, capacities)
    }

    #[view]
    public fun get_allocations_view(vault: Object<Vault>, amount: u64): SimpleMap<Object<BaseStrategy>, u64> {
        let total_idle = vault::total_idle(vault) + amount;
        let allocations = simple_map::new();
        let strategies = vault::vault_strategies(vault);
        if (total_idle == 0 || vector::is_empty(&strategies)) {
            return allocations
        };

        let (total_capacity, capacities) = get_capacities(vault);
        assert!(
            vector::length(&strategies) == vector::length(&capacities),
            EVECTORS_LENGTH_MISMATCH
        );

        for (i in 0..vector::length(&capacities)) {
            let capacity = *vector::borrow(&capacities, i);
            if (capacity != 0) {
                let strategy = *vector::borrow(&strategies, i);
                let amount = math64::mul_div(capacity, total_idle, total_capacity);

                simple_map::add(&mut allocations, strategy, amount);
            }
        };

        return allocations
    }
}

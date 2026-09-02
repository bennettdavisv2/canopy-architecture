module satay_router::harvest {
    use aptos_framework::object::Object;

    use echelon_simple::strategy as echelon_simple;
    use moveposition_simple::strategy as moveposition_simple;
    use layerbank_simple::strategy as layerbank_simple;
    use satay::base_strategy::{Self, BaseStrategy};

    use satay_router::auth;

    friend satay_router::router;

    public(friend) fun harvest_coin<CoinType>(strategy: Object<BaseStrategy>) {
        let router_signer = auth::get_signer();
        let concrete_address = base_strategy::concrete_address(strategy);

        if (concrete_address == @echelon_simple) {
            echelon_simple::harvest<CoinType>(&router_signer, strategy);
        } else if (concrete_address == @moveposition_simple) {
            moveposition_simple::harvest<CoinType>(&router_signer, strategy);
        }
    }

    public(friend) fun harvest_fa(strategy: Object<BaseStrategy>) {
        let router_signer = auth::get_signer();
        let concrete_address = base_strategy::concrete_address(strategy);

        if (concrete_address == @echelon_simple) {
            echelon_simple::harvest_fa(&router_signer, strategy);
        } else if (concrete_address == @moveposition_simple) {
            moveposition_simple::harvest_fa(&router_signer, strategy);
        } else if (concrete_address == @layerbank_simple) {
            layerbank_simple::harvest(&router_signer, strategy);
        }
    }
}

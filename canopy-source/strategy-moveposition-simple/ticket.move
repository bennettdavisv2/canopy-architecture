// From https://github.com/concordia-fi/system/blob/master/move/superp/sources/basic_ticket_v2.move

module moveposition_simple::ticket {
    use std::simple_map;
    use std::string::String;
    use std::type_info;
    use std::vector;

    use concbox::binary_cursor;

    struct BasicTicket has drop {
        operation: String,
        user: address,
        coin_type: String,
        portfolio_snapshot: PortfolioSnapshot,
        amount: u64
    }

    struct PortfolioSnapshot has drop {
        liabilities: simple_map::SimpleMap<String, u64>,
        collaterals: simple_map::SimpleMap<String, u64>
    }

    const EINVALID_TICKET_OPERATION: u64 = 1;
    const EINVALID_TICKET_USER: u64 = 2;
    const EINVALID_TICKET_COIN_TYPE: u64 = 3;
    const EINVALID_TICKET_AMOUNT: u64 = 4;
    const EINVALID_TICKET_PORTFOLIO_COLLATERALS: u64 = 5;
    const EINVALID_TICKET_PORTFOLIO_LIABILITIES: u64 = 6;

    public fun deserialize(data: vector<u8>): BasicTicket {
        let c = binary_cursor::init(data);
        let operation = binary_cursor::read_string(&mut c);
        let user = binary_cursor::read_address(&mut c);
        let coin_type = binary_cursor::read_string(&mut c);
        let portfolio_snapshot = deserialize_portfolio(&mut c);
        let amount = binary_cursor::read_u64(&mut c);

        binary_cursor::destroy_empty(c);

        BasicTicket { operation, user, coin_type, portfolio_snapshot, amount }
    }

    // Deserialize PortfolioSnapshot from binary data.
    // The expected format is:
    // - u64: number of collaterals
    // - for each collateral:
    //   - string: coin type
    //   - u64: balance
    // - u64: number of liabilities
    // - for each liability:
    //   - string: coin type
    //   - u64: balance
    fun deserialize_portfolio(cursor: &mut binary_cursor::Cursor): PortfolioSnapshot {
        // Deserialize PortfolioSnapshot
        let collaterals = simple_map::new<String, u64>();
        let collateral_count = binary_cursor::read_u64(cursor);
        for (collateral in 0..collateral_count) {
            let coin_type = binary_cursor::read_string(cursor);
            let balance = binary_cursor::read_u64(cursor);
            simple_map::add(&mut collaterals, coin_type, balance);
        };

        let liabilities = simple_map::new<String, u64>();
        let liability_count = binary_cursor::read_u64(cursor);
        for (liability in 0..liability_count) {
            let coin_type = binary_cursor::read_string(cursor);
            let balance = binary_cursor::read_u64(cursor);
            simple_map::add(&mut liabilities, coin_type, balance);
        };

        PortfolioSnapshot { liabilities, collaterals }
    }

    public fun validate_operation(ticket: &BasicTicket, operation: String) {
        assert!(ticket.operation == operation, EINVALID_TICKET_OPERATION);
    }

    public fun validate_user(ticket: &BasicTicket, u_addr: address) {
        assert!(ticket.user == u_addr, EINVALID_TICKET_USER);
    }

    public fun validate_coin_type<TCoin>(ticket: &BasicTicket) {
        assert!(ticket.coin_type == type_info::type_name<TCoin>(), EINVALID_TICKET_COIN_TYPE);
    }

    public fun validate_amount(ticket: &BasicTicket, amount: u64) {
        assert!(ticket.amount == amount, EINVALID_TICKET_AMOUNT);
    }

    public fun amount(ticket: &BasicTicket): u64 {
        ticket.amount
    }

    // Compare two simple maps of u64 values.
    // Returns true if the maps are equal, false otherwise.
    //
    // Note: maps can be compared with ==, but that will only work if the maps are in the same order
    fun portfolio_maps_equal(
        map1: &simple_map::SimpleMap<String, u64>,
        map2: &simple_map::SimpleMap<String, u64>
    ): bool {
        if (simple_map::length(map1) != simple_map::length(map2)) {
            return false
        };

        // The move prover has trouble dealing with simple_map::keys()
        // so use to_vec_pair() to get the keys
        let (keys, _) = simple_map::to_vec_pair<String, u64>(*map1);
        while (!vector::is_empty(&keys)) {
            let key: String = vector::pop_back(&mut keys);
            if (simple_map::borrow(map1, &key) != simple_map::borrow(map2, &key)) {
                return false
            }
        };

        true
    }

    public fun validate_portfolio_collaterals(
        ticket: &BasicTicket, collaterals: &simple_map::SimpleMap<String, u64>
    ) {
        assert!(
            portfolio_maps_equal(&ticket.portfolio_snapshot.collaterals, collaterals),
            EINVALID_TICKET_PORTFOLIO_COLLATERALS
        );
    }

    public fun validate_portfolio_liabilities(
        ticket: &BasicTicket, liabilities: &simple_map::SimpleMap<String, u64>
    ) {
        assert!(
            portfolio_maps_equal(&ticket.portfolio_snapshot.liabilities, liabilities),
            EINVALID_TICKET_PORTFOLIO_LIABILITIES
        );
    }

    public fun get_amount(ticket: &BasicTicket): u64 {
        ticket.amount
    }

    #[test_only]
    public fun create(
        operation: String,
        user: address,
        coin_type: String,
        collaterals: simple_map::SimpleMap<String, u64>,
        liabilities: simple_map::SimpleMap<String, u64>,
        amount: u64
    ): BasicTicket {
        let portfolio_snapshot = PortfolioSnapshot { collaterals, liabilities };

        BasicTicket { operation, user, coin_type, amount, portfolio_snapshot }
    }
}

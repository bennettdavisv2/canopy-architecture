module satay::protocol {
    use std::option::{Self, Option};
    use std::signer;
    use aptos_framework::code::PackageRegistry;
    use aptos_framework::event;
    use aptos_framework::event::emit;
    use aptos_framework::fungible_asset::{FungibleStore, Metadata};
    use aptos_framework::object;
    use aptos_framework::object::{ConstructorRef, ExtendRef, Object, ObjectCore, ObjectGroup};
    use aptos_framework::primary_fungible_store;
    use aptos_framework::system_addresses;
    use aptos_framework::timestamp;

    use satay::constants;

    // ========== Friends =========

    friend satay::base_strategy;
    friend satay::vault;

    // ========== Structs ==========

    #[resource_group_member(group = ObjectGroup)]
    struct Protocol has key {
        /// The address of the current governance account.
        governance: address,
        /// An optional address that represents a pending governance account.
        /// This field is used when there's a proposed change in governance
        /// that hasn't taken effect yet.
        pending_governance: Option<PendingGovernance>,
        /// The address of the router package.
        router: Option<address>,
        /// The current pending router.
        pending_router: Option<PendingRouter>,
        /// Default fee configuration
        fee_config: FeeConfig,
        /// Feature configuration
        feature_config: FeatureConfig,
        /// Timelock configuration
        timelock_config: TimelockConfig
    }

    struct PendingRouter has store, drop {
        /// The time pending router was requested
        requested_at: u64,
        /// The pending router address.
        addr: address
    }

    struct PendingGovernance has store, drop {
        /// The time pending governance was requested
        requested_at: u64,
        /// The pending governance address.
        addr: address
    }

    struct FeeConfig has store, drop {
        /// Fee charged by the protocol, expressed in BPS.
        protocol_fee: u64,
        /// The address that receives the protocol fee.
        protocol_fee_recipient: address,
        /// Default performance fee, expressed in BPS.
        performance_fee: u64,
        /// Default management fee, expressed in BPS.
        management_fee: u64
    }

    struct FeatureConfig has store, drop {
        /// Whether to automatically harvest strategies.
        auto_harvest: bool,
        /// Whether to automatically report strategy to vault.
        auto_report: bool
    }

    struct TimelockConfig has store, drop {
        /// Router timelock
        router_delay: u64,
        /// Governance timelock
        governance_delay: u64
    }

    struct RouterRef has store, drop {
        router: address
    }

    #[resource_group_member(group = ObjectGroup)]
    struct ProtocolController has key {
        extend_ref: ExtendRef
    }

    struct BlockRef has store, drop {
        block: address
    }

    // ========== Events ==========

    #[event]
    struct GovernanceUpdated has store, drop {
        governance: address
    }

    #[event]
    struct ProtocolFeeUpdated has store, drop {
        fee: u64
    }

    #[event]
    struct PerformanceFeeUpdated has store, drop {
        fee: u64
    }

    #[event]
    struct ManagementFeeUpdated has store, drop {
        fee: u64
    }

    #[event]
    struct ProtocolFeeRecipientUpdated has store, drop {
        addr: address
    }

    #[event]
    struct RouterUpdated has store, drop {
        router: address
    }

    // The seed used to create the protocol resource.
    const PROTOCOL_SEED: vector<u8> = b"00000000Protocol";

    // ========== Errors ==========

    /// The protocol has not been initialized.
    const EPROTOCOL_NOT_INITIALIZED: u64 = 100;
    /// The account is not the governance account.
    const ENOT_GOVERNANCE: u64 = 101;
    /// The account is not the pending governance account.
    const ENOT_PENDING_GOVERNANCE: u64 = 102;
    /// The fee is invalid.
    const EINVALID_FEE: u64 = 103;
    /// The address is reserved.
    const ERESERVED_ADDRESS: u64 = 104;
    /// There is no pending router.
    const ENO_PENDING_ROUTER: u64 = 105;
    /// Pending router does not match expected
    const EINVALID_PENDING_ROUTER: u64 = 106;
    /// Timelock not elased
    const ETIMELOCK_NOT_ELAPSED: u64 = 107;
    /// Invalid timelock delay value
    const EINVALID_DELAY_VALUE: u64 = 108;

    /// Initializes the module by creating a new protocol object.
    fun init_module(signer: &signer) {
        let constructor_ref = object::create_named_object(signer, PROTOCOL_SEED);
        let protocol_signer = object::generate_signer(&constructor_ref);

        let deployer = get_deployer();
        let (protocol, controller) = create_internal(deployer, &constructor_ref);

        move_to(&protocol_signer, protocol);
        move_to(&protocol_signer, controller);
    }

    /// Sets the pending governance address in the config resource.
    /// This function can only be called by the current governance account.
    public entry fun set_governance(account: &signer, governance: address) acquires Protocol {
        assert!(is_governance(signer::address_of(account)), ENOT_GOVERNANCE);
        let protocol_mut = borrow_global_mut<Protocol>(get_address());

        let current_time = timestamp::now_seconds();
        // Disallow overwriting the current pending router until timelock delay elapses
        if (option::is_some(&protocol_mut.pending_governance)) {
            let pending_governance = option::borrow(&protocol_mut.pending_governance);
            assert!(
                current_time >= pending_governance.requested_at + protocol_mut.timelock_config.governance_delay,
                ETIMELOCK_NOT_ELAPSED
            )
        };

        option::swap_or_fill(
            &mut protocol_mut.pending_governance,
            PendingGovernance { requested_at: current_time, addr: governance }
        );
    }

    /// Accepts the pending governance address and sets it as the current governance address.
    /// This function can only be called by the pending governance account.
    public entry fun accept_governance(account: &signer) acquires Protocol {
        assert!(is_pending_governance(signer::address_of(account)), ENOT_PENDING_GOVERNANCE);
        let protocol_mut = borrow_global_mut<Protocol>(get_address());

        let pending_governance = option::extract(&mut protocol_mut.pending_governance);
        protocol_mut.governance = pending_governance.addr;
        event::emit(GovernanceUpdated { governance: protocol_mut.governance })
    }

    /// Sets the protocol fee.
    public entry fun set_protocol_fee(account: &signer, protocol_fee: u64) acquires Protocol {
        assert!(is_governance(signer::address_of(account)), ENOT_GOVERNANCE);
        assert!(protocol_fee <= constants::max_protocol_fee(), EINVALID_FEE);

        borrow_global_mut<Protocol>(get_address()).fee_config.protocol_fee = protocol_fee;
        emit(ProtocolFeeUpdated { fee: protocol_fee })
    }

    /// Sets the performance fee.
    public entry fun set_performance_fee(account: &signer, performance_fee: u64) acquires Protocol {
        assert!(is_governance(signer::address_of(account)), ENOT_GOVERNANCE);
        assert!(performance_fee <= constants::max_performance_fee(), EINVALID_FEE);

        borrow_global_mut<Protocol>(get_address()).fee_config.performance_fee = performance_fee;
        emit(PerformanceFeeUpdated { fee: performance_fee })
    }

    /// Sets the management fee.
    public entry fun set_management_fee(account: &signer, management_fee: u64) acquires Protocol {
        assert!(is_governance(signer::address_of(account)), ENOT_GOVERNANCE);
        assert!(management_fee <= constants::max_management_fee(), EINVALID_FEE);

        borrow_global_mut<Protocol>(get_address()).fee_config.management_fee = management_fee;
        emit(ManagementFeeUpdated { fee: management_fee })
    }

    /// Sets the protocol fee recipient.
    public entry fun set_protocol_fee_recipient(account: &signer, recipient: address) acquires Protocol {
        assert!(is_governance(signer::address_of(account)), ENOT_GOVERNANCE);
        assert!(!system_addresses::is_framework_reserved_address(recipient), ERESERVED_ADDRESS);

        borrow_global_mut<Protocol>(get_address()).fee_config.protocol_fee_recipient = recipient;
        emit(ProtocolFeeRecipientUpdated { addr: recipient })
    }

    public entry fun approve_pending_router(account: &signer, router: address) acquires Protocol {
        assert!(is_governance(signer::address_of(account)), ENOT_GOVERNANCE);

        let protocol_mut = borrow_global_mut<Protocol>(get_address());
        assert!(option::is_some(&protocol_mut.pending_router), ENO_PENDING_ROUTER);

        let pending_router = option::extract(&mut protocol_mut.pending_router);
        assert!(pending_router.addr == router, EINVALID_PENDING_ROUTER);

        option::swap_or_fill(&mut protocol_mut.router, pending_router.addr);
        emit(RouterUpdated { router: pending_router.addr })
    }

    public entry fun set_auto_harvest(account: &signer, auto_harvest: bool) acquires Protocol {
        assert!(is_governance(signer::address_of(account)), ENOT_GOVERNANCE);
        borrow_global_mut<Protocol>(get_address()).feature_config.auto_harvest = auto_harvest;
    }

    public entry fun set_auto_report(account: &signer, auto_report: bool) acquires Protocol {
        assert!(is_governance(signer::address_of(account)), ENOT_GOVERNANCE);
        borrow_global_mut<Protocol>(get_address()).feature_config.auto_report = auto_report;
    }

    public entry fun set_router_delay(account: &signer, delay: u64) acquires Protocol {
        assert!(is_governance(signer::address_of(account)), ENOT_GOVERNANCE);
        assert!(
            delay > 0 && delay <= constants::max_router_delay(),
            EINVALID_DELAY_VALUE
        );
        borrow_global_mut<Protocol>(get_address()).timelock_config.router_delay = delay;
    }

    public entry fun set_governance_delay(account: &signer, delay: u64) acquires Protocol {
        assert!(is_governance(signer::address_of(account)), ENOT_GOVERNANCE);
        assert!(
            delay > 0 && delay <= constants::max_governance_delay(),
            EINVALID_DELAY_VALUE
        );
        borrow_global_mut<Protocol>(get_address()).timelock_config.governance_delay = delay;
    }

    public fun request_router_ref(router_signer: &signer): RouterRef acquires Protocol {
        let router = signer::address_of(router_signer);
        let protocol_mut = borrow_global_mut<Protocol>(get_address());

        let current_time = timestamp::now_seconds();

        // Disallow overwriting the current pending router until timelock delay elapses
        if (option::is_some(&protocol_mut.pending_router)) {
            let pending_router = option::borrow(&protocol_mut.pending_router);
            assert!(
                current_time >= pending_router.requested_at + protocol_mut.timelock_config.router_delay,
                ETIMELOCK_NOT_ELAPSED
            )
        };

        option::swap_or_fill(
            &mut protocol_mut.pending_router,
            PendingRouter { addr: router, requested_at: current_time }
        );

        RouterRef { router }
    }

    public fun new_block_ref(account: &signer, seed: vector<u8>): (ConstructorRef, BlockRef) acquires Protocol, ProtocolController {
        assert!(is_governance(signer::address_of(account)), ENOT_GOVERNANCE);
        let constructor_ref = object::create_named_object(&get_signer(), seed);

        let block = object::address_from_constructor_ref(&constructor_ref);
        let transfer_ref = object::generate_transfer_ref(&constructor_ref);
        object::disable_ungated_transfer(&transfer_ref);

        (constructor_ref, BlockRef { block })
    }

    public fun is_valid_router_ref(router_ref: &RouterRef): bool acquires Protocol {
        return option::some(router_ref.router) == get_router()
    }

    public fun is_valid_block_ref(block_ref: &BlockRef): bool {
        object::is_owner(
            object::address_to_object<ObjectCore>(block_ref.block),
            get_address()
        )
    }

    // ========== Friend functions ==========

    public(friend) fun get_signer(): signer acquires ProtocolController {
        let address = get_address();
        assert!(exists<Protocol>(address), EPROTOCOL_NOT_INITIALIZED);
        let extend_ref = &borrow_global<ProtocolController>(address).extend_ref;
        object::generate_signer_for_extending(extend_ref)
    }

    // ========== View functions ==========

    #[view]
    public fun is_governance(account: address): bool acquires Protocol {
        borrow_global<Protocol>(get_address()).governance == account
    }

    #[view]
    public fun is_pending_governance(account: address): bool acquires Protocol {
        let protocol_mut = borrow_global<Protocol>(get_address());

        if (option::is_none(&protocol_mut.pending_governance)) return false;
        account == option::borrow(&protocol_mut.pending_governance).addr
    }

    #[view]
    public fun get_governance(): address acquires Protocol {
        let config = borrow_global<Protocol>(get_address());
        config.governance
    }

    #[view]
    public fun get_pending_governance(): Option<address> acquires Protocol {
        let config = borrow_global<Protocol>(get_address());
        if (option::is_some(&config.pending_governance)) {
            return option::some(option::borrow(&config.pending_governance).addr)
        };
        option::none()
    }

    #[view]
    public fun get_address(): address {
        let address = object::create_object_address(&@satay, PROTOCOL_SEED);
        assert!(object::object_exists<Protocol>(address), EPROTOCOL_NOT_INITIALIZED);
        address
    }

    #[view]
    public fun get_protocol_fee(): u64 acquires Protocol {
        borrow_global<Protocol>(get_address()).fee_config.protocol_fee
    }

    #[view]
    public fun get_protocol_fee_recipient(): address acquires Protocol {
        borrow_global<Protocol>(get_address()).fee_config.protocol_fee_recipient
    }

    #[view]
    public fun get_deployer(): address {
        // if the package is deployed to an object,
        // the deployer is the owner of the `PackageRegistry` object.
        if (object::object_exists<PackageRegistry>(@satay)) {
            let package_object = object::address_to_object<PackageRegistry>(@satay);
            return object::owner(package_object)
        };

        @satay
    }

    #[view]
    public fun get_performance_fee(): u64 acquires Protocol {
        borrow_global<Protocol>(get_address()).fee_config.performance_fee
    }

    #[view]
    public fun get_management_fee(): u64 acquires Protocol {
        borrow_global<Protocol>(get_address()).fee_config.management_fee
    }

    #[view]
    public fun get_protocol_fee_recipient_store(metadata: Object<Metadata>): Object<FungibleStore> acquires Protocol {
        primary_fungible_store::ensure_primary_store_exists(get_protocol_fee_recipient(), metadata)
    }

    #[view]
    public fun get_router(): Option<address> acquires Protocol {
        borrow_global<Protocol>(get_address()).router
    }

    #[view]
    public fun should_auto_harvest(): bool acquires Protocol {
        borrow_global<Protocol>(get_address()).feature_config.auto_harvest
    }

    #[view]
    public fun should_auto_report(): bool acquires Protocol {
        borrow_global<Protocol>(get_address()).feature_config.auto_report
    }

    // ========== Internal functions ==========

    /// Creates an instance of the `Protocol` and `ProtocolCapability`.
    fun create_internal(governance: address, constructor_ref: &ConstructorRef): (Protocol, ProtocolController) {
        let protocol = Protocol {
            governance,
            pending_governance: option::none(),
            router: option::none(),
            pending_router: option::none(),
            fee_config: FeeConfig {
                protocol_fee_recipient: governance,
                protocol_fee: constants::default_protocol_fee(),
                management_fee: constants::default_management_fee(),
                performance_fee: constants::default_performance_fee()
            },
            feature_config: FeatureConfig { auto_harvest: true, auto_report: true },
            timelock_config: TimelockConfig {
                router_delay: constants::default_router_delay(),
                governance_delay: constants::default_governance_delay()
            }
        };

        let controller = ProtocolController { extend_ref: object::generate_extend_ref(constructor_ref) };
        (protocol, controller)
    }

    #[test_only]
    public fun init_module_for_test(signer: &signer) {
        init_module(signer)
    }

    #[test_only]
    public fun get_signer_for_test(): signer acquires ProtocolController {
        get_signer()
    }

    #[test_only]
    public entry fun approve_pending_router_for_test(account: &signer) acquires Protocol {
        assert!(is_governance(signer::address_of(account)), ENOT_GOVERNANCE);

        let protocol_mut = borrow_global_mut<Protocol>(get_address());

        let pending_router = option::extract(&mut protocol_mut.pending_router);
        option::swap_or_fill(&mut protocol_mut.router, pending_router.addr);
    }
}

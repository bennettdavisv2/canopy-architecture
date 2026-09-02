module satay_router::auth {
    use std::option::{Self, Option};
    use aptos_framework::account::{Self, SignerCapability};

    use satay::protocol::{Self, RouterRef};

    friend satay_router::router;
    friend satay_router::harvest;
    friend satay_router::deposit;
    friend satay_router::withdraw;

    struct RouterAuth has key {
        router_ref: Option<RouterRef>,
        signer_cap: SignerCapability
    }

    struct BorrowedRouterRef {
        router_ref: RouterRef
    }

    const ACCOUNT_SEED: vector<u8> = b"RouterAuth";

    fun init_module(module_signer: &signer) {
        let (rsigner, signer_cap) = account::create_resource_account(module_signer, ACCOUNT_SEED);

        let router_ref = protocol::request_router_ref(&rsigner);
        move_to(module_signer, RouterAuth { router_ref: option::some(router_ref), signer_cap });
    }

    public(friend) fun get_signer(): signer acquires RouterAuth {
        let auth = borrow_global<RouterAuth>(@satay_router);
        account::create_signer_with_capability(&auth.signer_cap)
    }

    public(friend) fun borrow_router_ref(): BorrowedRouterRef acquires RouterAuth {
        let auth = borrow_global_mut<RouterAuth>(@satay_router);
        BorrowedRouterRef { router_ref: option::extract(&mut auth.router_ref) }
    }

    public(friend) fun return_router_ref(borrowed_router_ref: BorrowedRouterRef) acquires RouterAuth {
        let BorrowedRouterRef { router_ref } = borrowed_router_ref;

        let auth = borrow_global_mut<RouterAuth>(@satay_router);
        option::fill(&mut auth.router_ref, router_ref);
    }

    public(friend) fun borrowed_ref(borrowed_router_ref: &BorrowedRouterRef): &RouterRef {
        &borrowed_router_ref.router_ref
    }

    #[test_only]
    public fun init_module_for_test(module_signer: &signer) {
        init_module(module_signer)
    }

    #[test_only]
    public fun get_signer_for_test(): signer acquires RouterAuth {
        get_signer()
    }
}

module std_batcher::std_views {

    use aptos_framework::object::{Self, Object};
    use std::vector;

    // ===== Batch functions for owner =====

    #[view]
    /// Get owners for multiple objects
    public fun get_owners<T: key>(objects: vector<Object<T>>): vector<address> {
        let owners = vector::empty<address>();
        let i = 0;
        let len = vector::length(&objects);
        while (i < len) {
            let obj = *vector::borrow(&objects, i);
            vector::push_back(&mut owners, object::owner(obj));
            i = i + 1;
        };
        owners
    }

    // ===== Batch functions for is_owner =====

    #[view]
    /// Check if a single address is owner of multiple objects
    public fun is_owner_of_objects<T: key>(objects: vector<Object<T>>, owner: address): vector<bool> {
        let results = vector::empty<bool>();
        let i = 0;
        let len = vector::length(&objects);
        while (i < len) {
            let obj = *vector::borrow(&objects, i);
            vector::push_back(&mut results, object::is_owner(obj, owner));
            i = i + 1;
        };
        results
    }

    #[view]
    /// Check if multiple addresses are owners of a single object
    public fun are_owners_of_object<T: key>(object: Object<T>, owners: vector<address>): vector<bool> {
        let results = vector::empty<bool>();
        let i = 0;
        let len = vector::length(&owners);
        while (i < len) {
            let owner = *vector::borrow(&owners, i);
            vector::push_back(&mut results, object::is_owner(object, owner));
            i = i + 1;
        };
        results
    }

    #[view]
    /// Check if addresses are owners of corresponding objects (paired)
    public fun are_owners_paired<T: key>(objects: vector<Object<T>>, owners: vector<address>): vector<bool> {
        assert!(vector::length(&objects) == vector::length(&owners), 1); // Length mismatch

        let results = vector::empty<bool>();
        let i = 0;
        let len = vector::length(&objects);
        while (i < len) {
            let obj = *vector::borrow(&objects, i);
            let owner = *vector::borrow(&owners, i);
            vector::push_back(&mut results, object::is_owner(obj, owner));
            i = i + 1;
        };
        results
    }

    // ===== Batch functions for owns (direct or indirect ownership) =====

    #[view]
    /// Check if a single address owns multiple objects (directly or indirectly)
    public fun owns_objects<T: key>(objects: vector<Object<T>>, owner: address): vector<bool> {
        let results = vector::empty<bool>();
        let i = 0;
        let len = vector::length(&objects);
        while (i < len) {
            let obj = *vector::borrow(&objects, i);
            vector::push_back(&mut results, object::owns(obj, owner));
            i = i + 1;
        };
        results
    }

    #[view]
    /// Check if multiple addresses own a single object (directly or indirectly)
    public fun owners_own_object<T: key>(object: Object<T>, owners: vector<address>): vector<bool> {
        let results = vector::empty<bool>();
        let i = 0;
        let len = vector::length(&owners);
        while (i < len) {
            let owner = *vector::borrow(&owners, i);
            vector::push_back(&mut results, object::owns(object, owner));
            i = i + 1;
        };
        results
    }

    #[view]
    /// Check if addresses own corresponding objects (paired, directly or indirectly)
    public fun owns_paired<T: key>(objects: vector<Object<T>>, owners: vector<address>): vector<bool> {
        assert!(vector::length(&objects) == vector::length(&owners), 1); // Length mismatch

        let results = vector::empty<bool>();
        let i = 0;
        let len = vector::length(&objects);
        while (i < len) {
            let obj = *vector::borrow(&objects, i);
            let owner = *vector::borrow(&owners, i);
            vector::push_back(&mut results, object::owns(obj, owner));
            i = i + 1;
        };
        results
    }

    // ===== Batch functions for root_owner =====

    #[view]
    /// Get root owners for multiple objects
    public fun get_root_owners<T: key>(objects: vector<Object<T>>): vector<address> {
        let root_owners = vector::empty<address>();
        let i = 0;
        let len = vector::length(&objects);
        while (i < len) {
            let obj = *vector::borrow(&objects, i);
            vector::push_back(&mut root_owners, object::root_owner(obj));
            i = i + 1;
        };
        root_owners
    }

    // ===== Utility functions for common patterns =====

    #[view]
    /// Check if all objects have the same owner
    public fun have_same_owner<T: key>(objects: vector<Object<T>>): bool {
        let len = vector::length(&objects);
        if (len <= 1) return true;

        let first_owner = object::owner(*vector::borrow(&objects, 0));
        let i = 1;
        while (i < len) {
            if (object::owner(*vector::borrow(&objects, i)) != first_owner) {
                return false
            };
            i = i + 1;
        };
        true
    }

    #[view]
    /// Check if all objects have the same root owner
    public fun have_same_root_owner<T: key>(objects: vector<Object<T>>): bool {
        let len = vector::length(&objects);
        if (len <= 1) return true;

        let first_root = object::root_owner(*vector::borrow(&objects, 0));
        let i = 1;
        while (i < len) {
            if (object::root_owner(*vector::borrow(&objects, i)) != first_root) {
                return false
            };
            i = i + 1;
        };
        true
    }
}

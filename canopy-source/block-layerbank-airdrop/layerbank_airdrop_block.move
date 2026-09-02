module layerbank_airdrop_block::layerbank_airdrop_block {
    use std::option;
    use std::signer;

    use aptos_framework::object::{Self, ExtendRef, Object};
    use aptos_framework::aptos_coin::{AptosCoin};
    use aptos_framework::fungible_asset::{Metadata};
    use aptos_framework::coin;

    use satay::protocol::{Self, BlockRef};

    use layerbank_movedrop::simple_airdrop;

    struct LayerBankAirdropBlock has key {
        block_ref: BlockRef,
        extend_ref: ExtendRef
    }

    const BLOCK_SEED: vector<u8> = b"00000003LayerBankAirdropBlock";

    // This entry function must be called by the governance account after the block package is deployed
    // to initialize the block within the system.
    //
    // - Without initialization, the block cannot be used to handle assets in the system.
    // - Only governance can initialize blocks, and only once.
    public entry fun initialize(account: &signer) {
        let (constructor_ref, block_ref) = protocol::new_block_ref(account, BLOCK_SEED);

        let block_signer = object::generate_signer(&constructor_ref);
        let extend_ref = object::generate_extend_ref(&constructor_ref);
        move_to(&block_signer, LayerBankAirdropBlock { block_ref, extend_ref })
    }

    // Get the address of the block object (not the package itself).
    public fun block_address(): address {
        object::create_object_address(&protocol::get_address(), BLOCK_SEED)
    }

    inline fun block_ref(): &BlockRef acquires LayerBankAirdropBlock {
        &borrow_global<LayerBankAirdropBlock>(block_address()).block_ref
    }


    public fun claim(account: &signer): u64 {
        claim_behalf(account, signer::address_of(account))
    }

    public fun claim_behalf(account: &signer, on_behalf_of: address): u64 {
        let claimable_amount = claimable_amount(on_behalf_of);
        if (claimable_amount == 0) return 0;

        let pre_balance = coin::balance<AptosCoin>(on_behalf_of);
        simple_airdrop::claim_behalf(account, on_behalf_of);
        let post_balance = coin::balance<AptosCoin>(on_behalf_of);
        post_balance - pre_balance
    }

    #[view]
    public fun claimable_amount(account_address: address): u64 {
        simple_airdrop::get_claim_status(account_address)
    }

    #[view]
    public fun reward_metadata(): Object<Metadata> {
      option::destroy_some(coin::paired_metadata<AptosCoin>())
    }
}

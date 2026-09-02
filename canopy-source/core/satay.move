module satay::satay {
    use std::option::{Self, Option};
    use aptos_framework::coin;
    use aptos_framework::fungible_asset::{Self, Metadata};
    use aptos_framework::object::Object;

    use satay::base_strategy;
    use satay::base_strategy::BaseStrategy;
    use satay::vault::{Self, Vault};

    public entry fun create_vault(
        account: &signer,
        deposit_limit: Option<u64>,
        total_debt_limit: Option<u64>,
        base_metadata: Object<Metadata>
    ) {
        vault::create(account, deposit_limit, total_debt_limit, base_metadata);
    }

    public entry fun create_vault_with_coin<CoinType>(
        account: &signer, deposit_limit: Option<u64>, total_debt_limit: Option<u64>
    ) {
        let paired_metadata = coin::paired_metadata<CoinType>();
        let base_metadata =
            if (option::is_none(&paired_metadata)) {
                let zero = coin::coin_to_fungible_asset(coin::zero<CoinType>());
                let base_metadata = fungible_asset::asset_metadata(&zero);
                fungible_asset::destroy_zero(zero);
                base_metadata
            } else {
                option::destroy_some(paired_metadata)
            };

        create_vault(account, deposit_limit, total_debt_limit, base_metadata)
    }

    public entry fun pause_vault(account: &signer, vault: Object<Vault>) {
        vault::pause(account, vault)
    }

    public entry fun unpause_vault(account: &signer, vault: Object<Vault>) {
        vault::unpause(account, vault)
    }

    public entry fun add_strategy(
        account: &signer,
        vault: Object<Vault>,
        strategy: Object<BaseStrategy>,
        debt_limit: u64
    ) {
        vault::add_strategy(account, vault, strategy, debt_limit)
    }

    public entry fun remove_strategy(
        account: &signer,
        vault: Object<Vault>,
        strategy: Object<BaseStrategy>,
        force: bool
    ) {
        vault::remove_strategy(account, vault, strategy, force)
    }

    public entry fun set_vault_deposit_limit(
        account: &signer, vault: Object<Vault>, value: Option<u64>
    ) {
        vault::set_deposit_limit(account, vault, value)
    }

    public entry fun set_vault_performance_fee(
        account: &signer, vault: Object<Vault>, value: Option<u64>
    ) {
        vault::set_performance_fee(account, vault, value)
    }

    public entry fun set_vault_management_fee(
        account: &signer, vault: Object<Vault>, value: Option<u64>
    ) {
        vault::set_management_fee(account, vault, value)
    }

    public entry fun set_vault_lock_duration(account: &signer, vault: Object<Vault>, value: u64) {
        vault::set_lock_duration(account, vault, value)
    }

    public entry fun set_vault_manager(account: &signer, vault: Object<Vault>, manager: address) {
        vault::update_manager(account, vault, manager)
    }

    public entry fun rebalance_vault_idle(account: &signer, vault: Object<Vault>) {
        vault::rebalance_idle(account, vault)
    }

    public entry fun sweep_vault(
        account: &signer,
        vault: Object<Vault>,
        metadata: Object<Metadata>,
        amount: u64
    ) {
        vault::sweep(account, vault, metadata, amount)
    }

    // ========== Strategy Functions ==========

    public entry fun set_strategy_debt_limit(
        account: &signer,
        vault: Object<Vault>,
        strategy: Object<BaseStrategy>,
        value: u64
    ) {
        vault::update_strategy_debt_limit(account, vault, strategy, value)
    }

    public entry fun set_strategy_performance_fee(
        account: &signer, strategy: Object<BaseStrategy>, value: Option<u64>
    ) {
        base_strategy::set_performance_fee(account, strategy, value)
    }

    public entry fun set_strategy_lock_duration(
        account: &signer, strategy: Object<BaseStrategy>, value: u64
    ) {
        base_strategy::set_lock_duration(account, strategy, value)
    }

    public entry fun set_strategy_manager(
        account: &signer, strategy: Object<BaseStrategy>, manager: address
    ) {
        base_strategy::update_manager(account, strategy, manager)
    }

    public entry fun rebalance_strategy_idle(account: &signer, strategy: Object<BaseStrategy>) {
        base_strategy::rebalance_idle(account, strategy)
    }

    public entry fun sweep_strategy(
        account: &signer,
        strategy: Object<BaseStrategy>,
        metadata: Object<Metadata>,
        amount: u64
    ) {
        base_strategy::sweep(account, strategy, metadata, amount)
    }
}

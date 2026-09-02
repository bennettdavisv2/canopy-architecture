module satay::vault {
    use std::option::{Self, Option};
    use std::signer;
    use std::string::{Self, String, utf8};
    use std::vector;
    use aptos_std::math64;
    use aptos_std::simple_map::{Self, SimpleMap};
    use aptos_std::string_utils;
    use aptos_std::type_info;
    use aptos_std::type_info::TypeInfo;
    use aptos_framework::coin::Self;
    use aptos_framework::event::emit;
    use aptos_framework::fungible_asset::{Self, FungibleAsset, Metadata};
    use aptos_framework::object::{Self, ConstructorRef, ExtendRef, Object, ObjectGroup};
    use aptos_framework::primary_fungible_store::{
        balance as primary_store_balance,
        deposit as primary_store_deposit,
        ensure_primary_store_exists,
        is_balance_at_least as is_primary_store_balance_at_least,
        transfer as primary_store_transfer,
        withdraw as primary_store_withdraw
    };
    use aptos_framework::timestamp;

    use satay::asset;
    use satay::base_strategy::{Self, AuthRef, BaseStrategy, BaseStrategyState, VaultBaseStrategyView};
    use satay::constants;
    use satay::hot_asset;
    use satay::hot_asset::HotAsset;
    use satay::hot_coin;
    use satay::hot_coin::HotCoin;
    use satay::protocol;
    use satay::protocol::RouterRef;

    friend satay::satay;

    #[test_only]
    friend satay::vault_tests;

    #[resource_group_member(group = ObjectGroup)]
    struct Vault has key {
        /// The total amount of base asset the vault has deposited into strategies.
        total_debt: u64,
        /// This indicates if the vault is active or not.
        /// An inactive vault does not accept deposits but allows withdrawals.
        is_paused: bool,
        /// The total amount of idle assets in the vault.
        total_idle: u64,
        /// The maximum amount of the base asset that can be deposited into the vault.
        deposit_limit: Option<u64>,
        total_debt_limit: Option<u64>,
        /// The base asset (asset to be deposited) of the vault.
        base_metadata: Object<Metadata>,
        /// The shares asset (asset to be issued) of the vault.
        shares_metadata: Object<Metadata>,
        /// The last time the vault was reported.
        last_report: u64,
        /// The amount of profit that is locked in the vault.
        total_locked: u64,
        lock_duration: u64,
        manager: address,
        /// The addresses of the strategies that the vault uses.
        strategies: SimpleMap<Object<BaseStrategy>, BaseStrategyState>,
        management_fee: Option<u64>,
        performance_fee: Option<u64>
    }

    #[resource_group_member(group = ObjectGroup)]
    struct VaultController has key {
        extend_ref: ExtendRef
    }

    #[resource_group_member(group = ObjectGroup)]
    struct RegistryInfo has key {
        vaults: vector<Object<Vault>>,
        strategies: vector<Object<BaseStrategy>>
    }

    struct WithdrawalRequest {
        /// The remaining amount to be withdrawn.
        remaining: u64,
        /// The account that initiated the withdrawal.
        account: address,
        /// The total amount of assets to be withdrawn.
        to_withdraw: u64,
        /// The vault to be withdrawn from.
        vault: Object<Vault>,
        /// The assets that will be burned for the withdrawal.
        to_burn: FungibleAsset,
        /// The assets that have been withdrawn.
        withdrawn: FungibleAsset,
        /// The losses realized by the strategies during the withdrawal.
        losses: SimpleMap<Object<BaseStrategy>, u64>,
        /// The debt offsets made by the strategies during the withdrawal.
        debt_offsets: SimpleMap<Object<BaseStrategy>, u64>
    }

    struct VaultView has copy, drop {
        /// The number of decimal places used by the base asset and shares asset for the vault.
        decimals: u8,
        /// The total amount of debt associated with the vault.
        total_debt: u64,
        /// The total amount of unused (idle) base asset available in the vault.
        total_idle: u64,
        /// The total number of shares issued by the vault.
        total_shares: u64,
        /// The total value of all assets held by the vault (both idle and debt).
        total_asset: u64,
        /// The name of the vault's base asset (e.g., "USDC").
        asset_name: String,
        /// The name of the vault's shares asset (e.g., "svUSDC").
        shares_name: String,
        /// The address of the vault itself.
        vault_address: address,
        /// The address of the base asset used by the vault.
        asset_address: address,
        /// The address of the shares asset issued by the vault.
        shares_address: address,
        /// The string representation of the coin type that the base metadata is paired with.
        paired_coin_type: Option<String>,
        /// A list of strategies that that are associated with the vault.
        strategies: vector<VaultBaseStrategyView>
    }

    struct PaginatedVaultsView has copy, drop {
        limit: u64,
        offset: u64,
        total_count: u64,
        vaults: vector<VaultView>
    }

    // ========== Events =========

    #[event]
    struct VaultCreated has store, drop {
        vault: Object<Vault>,
        deposit_limit: Option<u64>,
        total_debt_limit: Option<u64>,
        base_metadata: Object<Metadata>,
        shares_metadata: Object<Metadata>
    }

    #[event]
    struct Deposit has store, drop {
        amount: u64,
        vault: Object<Vault>
    }

    #[event]
    struct Withdraw has store, drop {
        loss: u64,
        amount: u64,
        vault: Object<Vault>
    }

    #[event]
    struct RegistryInitialized has store, drop {
        protocol: address
    }

    #[event]
    struct VaultPaused has store, drop {
        vault: Object<Vault>,
        paused_by: address
    }

    #[event]
    struct VaultUnpaused has store, drop {
        vault: Object<Vault>,
        unpaused_by: address
    }

    #[event]
    struct SetDepositLimit has store, drop {
        vault: Object<Vault>,
        limit: Option<u64>
    }

    #[event]
    struct SetPerformanceFee has store, drop {
        vault: Object<Vault>,
        fee: Option<u64>
    }

    #[event]
    struct SetManagementFee has store, drop {
        vault: Object<Vault>,
        fee: Option<u64>
    }

    #[event]
    struct BaseStrategyAdded has store, drop {
        vault: Object<Vault>,
        strategy: Object<BaseStrategy>
    }

    #[event]
    struct BaseStrategyRemoved has store, drop {
        vault: Object<Vault>,
        strategy: Object<BaseStrategy>,
        force: bool
    }

    #[event]
    struct BaseStrategySharesDeposit has store, drop {
        amount: u64,
        vault: Object<Vault>,
        strategy: Object<BaseStrategy>
    }

    #[event]
    struct BaseStrategySharesWithdraw has store, drop {
        amount: u64,
        vault: Object<Vault>,
        strategy: Object<BaseStrategy>
    }

    #[event]
    struct SetLockDuration has store, drop {
        vault: Object<Vault>,
        duration: u64
    }

    // ========== Errors =========

    /// Unauthorized signer or capability
    const ENOT_AUTHORIZED: u64 = 100;
    /// Resource already initialized
    const EALREADY_INITIALIZED: u64 = 101;
    /// Invalid debt limit (too much or too low)
    const EINVALID_DEBT_LIMIT: u64 = 102;
    /// Invalid deposit limit (too much or too low)
    const EINVALID_DEPOSIT_LIMIT: u64 = 103;
    /// Invalid performance fee (too much or too low)
    const EINVALID_FEE: u64 = 104;
    /// Asset metadata does not match the vault base asset's
    const EVAULT_BASE_ASSET_MISMATCH: u64 = 105;
    /// Insufficient balance to perform action
    const EINSUFFICIENT_BALANCE: u64 = 106;
    /// Vault has not been paused
    const EVAULT_NOT_PAUSED: u64 = 107;
    /// Vault has already been paused
    const EVAULT_ALREADY_PAUSED: u64 = 108;
    /// BaseStrategy has already been added to vault
    const ESTRATEGY_ALREADY_ADDED: u64 = 109;
    /// Asset metadata does not match the vault shares asset's
    const EVAULT_SHARES_ASSET_MISMATCH: u64 = 110;
    /// BaseStrategy does not have sufficient debt
    const ESTRATEGY_INSUFFICIENT_DEBT: u64 = 111;
    /// BaseStrategy does not belong or match the vault it's being used with
    const EVAULT_STRATEGY_MISMATCH: u64 = 112;
    /// Deposit too much and exceeds the set limit
    const EINVALID_DEPOSIT_AMOUNT: u64 = 113;
    /// BaseStrategy still has unpaid debt
    const ESTRATEGY_HAS_DEBT: u64 = 114;
    /// Vault does not have sufficient debt
    const EVAULT_INSUFFICIENT_DEBT: u64 = 115;
    /// Invalid withdrawal amount
    const EINVALID_WITHDRAWAL_AMOUNT: u64 = 116;
    /// Vault is currently paused
    const EVAULT_PAUSED: u64 = 117;
    /// BaseStrategy shares metadata does not match asset metadata
    const ESTRATEGY_SHARES_METADATA_MISMATCH: u64 = 118;
    /// BaseStrategy witness does not match the provided witness
    const ESTRATEGY_WITNESS_MISMATCH: u64 = 119;
    /// Invalid shares conversion factors
    const EINVALID_SHARES_FACTORS: u64 = 120;
    /// Insufficient vault assets
    const EVAULT_INSUFFICIENT_ASSETS: u64 = 121;
    /// Invalid amount of debt to take
    const EINVALID_DEBT_AMOUNT: u64 = 122;
    /// Invalid report time
    const EINVALID_REPORT_TIME: u64 = 123;
    /// Withdrawal account mismatch
    const EWITHDRAWAL_ACCOUNT_MISMATCH: u64 = 124;
    /// Asset store already exists
    const EASSET_STORE_ALREADY_EXISTS: u64 = 125;
    /// Asset store does not exists
    const EASSET_STORE_DOES_NOT_EXISTS: u64 = 126;
    /// Invalid amount
    const EINVALID_AMOUNT: u64 = 127;
    /// Total withdrawn does not match the expected amount
    const EINVARIANT_VIOLATION: u64 = 128;
    /// Too much loss
    const ETOO_MUCH_LOSS: u64 = 129;
    /// Invalid lock duration
    const EINVALID_LOCK_DURATION: u64 = 130;
    /// Can not sweep base asset
    const ECANNOT_SWEEP_BASE_ASSET: u64 = 131;
    /// Can not sweep asset associated with vault
    const ECANNOT_SWEEP_ASSOCIATED_ASSET: u64 = 132;
    /// Invariant violation for strategy insufficient debt
    const E_INVARIANT_STRATEGY_INSUFFICIENT_DEBT: u64 = 133;
    /// Invalid hot asset owner
    const EINVALID_HOT_ASSET_OWNER: u64 = 134;

    // - - - Constants - - -

    // fungible_asset constants
    const MAX_NAME_LENGTH: u64 = 32;
    const MAX_SYMBOL_LENGTH: u64 = 10;

    public entry fun initialize(account: &signer) {
        assert!(protocol::is_governance(signer::address_of(account)), ENOT_AUTHORIZED);
        assert!(
            !exists<RegistryInfo>(protocol::get_address()),
            EALREADY_INITIALIZED
        );

        move_to(
            &protocol::get_signer(),
            RegistryInfo {
                vaults: vector::empty(),
                strategies: vector::empty()
            }
        );

        emit(RegistryInitialized { protocol: protocol::get_address() })
    }

    // ========== Public functions =========

    /// Creates a new vault managed by the account specified by the `account` parameter.
    ///
    /// @param account The account that is creating the vault.
    /// @param deposit_limit The maximum amount of assets that can be deposited into the vault.
    /// @param total_debt_limit The maximum total amount of debt all strategies associated can have to this vault.
    /// @param base_metadata The base asset of the vault.
    ///
    /// @return The vault object.
    ///
    /// @reverts ENOT_AUTHORIZED if the account is not the governance account.
    /// @reverts EINVALID_DEPOSIT_LIMIT if the deposit limit is less than or equal to 0.
    /// @reverts EVAULT_BASE_ASSET_MISMATCH if the base asset is not the base asset of the vault.
    public(friend) fun create(
        account: &signer,
        deposit_limit: Option<u64>,
        total_debt_limit: Option<u64>,
        base_metadata: Object<Metadata>
    ): Object<Vault> acquires RegistryInfo {
        // Right now, only governance can create vaults.
        let account_address = signer::address_of(account);
        assert!(protocol::is_governance(account_address), ENOT_AUTHORIZED);

        // If the deposit limit is set, it must be greater than 0 because setting it to 0 will
        // effectively make the vault useless.
        if (option::is_some(&deposit_limit)) {
            assert!(*option::borrow(&deposit_limit) > 0, EINVALID_DEPOSIT_LIMIT)
        };

        if (option::is_some(&total_debt_limit)) {
            assert!(*option::borrow(&total_debt_limit) > 0, EINVALID_DEBT_LIMIT)
        };

        let constructor_ref = object::create_sticky_object(protocol::get_address());
        let vault_signer = object::generate_signer(&constructor_ref);

        // Get the current vault index (0-based) from the registry
        let registry = borrow_global_mut<RegistryInfo>(protocol::get_address());
        let vault_index = vector::length(&registry.vaults);

        // Create the vault's shares asset
        let shares_metadata = create_shares_asset(&vault_signer, base_metadata, vault_index);

        let (vault, vault_controller) =
            create_internal(
                &constructor_ref,
                account_address,
                deposit_limit,
                total_debt_limit,
                base_metadata,
                shares_metadata
            );

        move_to(&vault_signer, vault);
        move_to(&vault_signer, vault_controller);

        let vault = object::object_from_constructor_ref<Vault>(&constructor_ref);

        emit(
            VaultCreated { vault, deposit_limit, total_debt_limit, base_metadata, shares_metadata }
        );

        ensure_primary_store_exists(object::object_address(&vault), base_metadata);

        // Add the vault to the registry
        vector::push_back(&mut registry.vaults, vault);

        vault
    }

    /// Pauses a vault specified by the `vault` parameter. Only the governance account or vault manager can pause a vault.
    /// Pausing a vault prevents the vault from accepting deposits.
    ///
    /// @param account The account that is pausing the vault.
    /// @param vault The vault to be paused.
    ///
    /// @reverts ENOT_AUTHORIZED if the account is not the governance or the manager account.
    /// @reverts EVAULT_ALREADY_PAUSED if the vault is already paused.
    public(friend) fun pause(account: &signer, vault: Object<Vault>) acquires Vault {
        let vault_mut = borrow_vault_mut(vault);
        let account_address = signer::address_of(account);

        assert!(!vault_mut.is_paused, EVAULT_ALREADY_PAUSED);
        assert!(
            protocol::is_governance(account_address) || vault_mut.manager == account_address,
            ENOT_AUTHORIZED
        );

        vault_mut.is_paused = true;
        emit(VaultPaused { vault, paused_by: signer::address_of(account) });
    }

    /// Unpauses a vault specified by the `vault` parameter. Only the governance account can unpause a vault.
    /// Unpausing a vault allows the vault to accept deposits again.
    ///
    /// @param account The account that is unpausing the vault.
    /// @param vault The vault to be unpaused.
    ///
    /// @reverts ENOT_AUTHORIZED if the account is not the governance account.
    /// @reverts EVAULT_NOT_PAUSED if the vault is not paused.
    public(friend) fun unpause(account: &signer, vault: Object<Vault>) acquires Vault {
        let vault_mut = borrow_vault_mut(vault);
        assert!(vault_mut.is_paused, EVAULT_NOT_PAUSED);
        assert!(protocol::is_governance(signer::address_of(account)), ENOT_AUTHORIZED);

        vault_mut.is_paused = false;
        emit(VaultUnpaused { vault, unpaused_by: signer::address_of(account) });
    }

    /// Sets the deposit limit of a vault specified by the `vault` parameter.
    /// The deposit limit is the maximum amount of assets that can be deposited into the vault.
    ///
    /// @param account The account that is setting the deposit limit.
    /// @param vault The vault to be set.
    /// @param deposit_limit The new deposit limit.
    ///
    /// @reverts ENOT_AUTHORIZED if the account is not the governance or the manager account.
    public(friend) fun set_deposit_limit(
        account: &signer, vault: Object<Vault>, deposit_limit: Option<u64>
    ) acquires Vault {
        let vault_mut = borrow_vault_mut(vault);
        let account_address = signer::address_of(account);
        assert!(
            protocol::is_governance(account_address) || vault_mut.manager == account_address,
            ENOT_AUTHORIZED
        );

        vault_mut.deposit_limit = deposit_limit;
        emit(SetDepositLimit { vault, limit: deposit_limit });
    }

    /// Sets the performance fee of a vault specified by the `vault` parameter.
    ///
    /// @param account The account that is setting the performance fee.
    /// @param vault The vault to be set.
    /// @param fee The new performance fee. Optional.
    ///
    /// @reverts ENOT_AUTHORIZED if the account is not the governance account.
    /// @reverts EINVALID_FEE if the performance fee is not less than or equal to the max performance fee.
    public(friend) fun set_performance_fee(
        account: &signer, vault: Object<Vault>, fee: Option<u64>
    ) acquires Vault {
        let vault_mut = borrow_vault_mut(vault);
        assert!(protocol::is_governance(signer::address_of(account)), ENOT_AUTHORIZED);

        if (option::is_some(&fee)) {
            assert!(*option::borrow(&fee) <= constants::max_performance_fee(), EINVALID_FEE);
        };

        vault_mut.performance_fee = fee;
        emit(SetPerformanceFee { vault, fee });
    }

    /// Sets the management fee of a vault specified by the `vault` parameter.
    ///
    /// @param account The account that is setting the management fee.
    /// @param vault The vault to be set.
    /// @param fee The new management fee. Optional.
    ///
    /// @reverts ENOT_AUTHORIZED if the account is not the governance account.
    /// @reverts EINVALID_FEE if the management fee is not less than or equal to the max management fee.
    public fun set_management_fee(account: &signer, vault: Object<Vault>, fee: Option<u64>) acquires Vault {
        let vault_mut = borrow_vault_mut(vault);
        assert!(protocol::is_governance(signer::address_of(account)), ENOT_AUTHORIZED);

        if (option::is_some(&fee)) {
            assert!(*option::borrow(&fee) <= constants::max_management_fee(), EINVALID_FEE);
        };

        vault_mut.management_fee = fee;
        emit(SetManagementFee { vault, fee });
    }

    /// Sets the profit lock duration of a vault specified by the `vault` parameter.
    ///
    /// @param account The account that is setting the duration.
    /// @param vault The vault to be set.
    /// @param duration The new duration.
    ///
    /// @reverts ENOT_AUTHORIZED if the account is not the governance or the manager account.
    public(friend) fun set_lock_duration(account: &signer, vault: Object<Vault>, duration: u64) acquires Vault {
        let vault_mut = borrow_vault_mut(vault);
        assert!(protocol::is_governance(signer::address_of(account)), ENOT_AUTHORIZED);

        assert!(
            duration >= constants::min_lock_duration() && duration <= constants::max_lock_duration(),
            EINVALID_LOCK_DURATION
        );

        vault_mut.lock_duration = duration;
        emit(SetLockDuration { vault, duration });
    }

    /// Deposits an asset into a vault specified by the `vault` parameter.
    /// The asset must be a fungible asset with the base asset of the vault as its metadata.
    ///
    /// @param vault The vault to be deposited into.
    /// @param hot_asset The asset (hot) to be deposited.
    ///
    /// @reverts ENOT_AUTHORIZED if the account is not the governance account.
    /// @reverts EVAULT_PAUSED if the vault is not active.
    /// @reverts EVAULT_BASE_ASSET_MISMATCH if the asset's metadata is not the base asset of the vault.
    /// @reverts EINSUFFICIENT_BALANCE if the asset's balance is less than the amount to be deposited.
    /// @reverts EINVALID_DEPOSIT_AMOUNT if the vault's deposit limit is set and the total assets exceeds it.
    public fun deposit(vault: Object<Vault>, hot_asset: HotAsset): HotAsset acquires Vault {
        let vault_ref = borrow_vault(vault);
        assert!(!vault_ref.is_paused, EVAULT_PAUSED);

        let deposit_amount = hot_asset::amount(&hot_asset);
        assert!(deposit_amount > 0, EINVALID_DEPOSIT_AMOUNT);
        assert!(deposit_amount <= max_deposit(vault_ref), EINVALID_DEPOSIT_AMOUNT);
        assert!(hot_asset::asset_metadata(&hot_asset) == vault_ref.base_metadata, EVAULT_BASE_ASSET_MISMATCH);

        deposit_internal(vault, hot_asset)
    }

    /// Initializes a withdrawal request for a vault specified by the `vault` parameter.
    /// The withdrawal request can be used to withdraw assets from the vault.
    ///
    /// @param vault The vault to be withdrawn from.
    /// @param hot_asset The shares asset (hot) to be withdrawn.
    ///
    /// @return The withdrawal request.
    ///
    /// @reverts EVAULT_SHARES_ASSET_MISMATCH if the shares asset is not the shares asset of the vault.
    /// @reverts EVAULT_INSUFFICIENT_DEBT if the vault has debt.
    public fun request_withdrawal(account: &signer, vault: Object<Vault>, hot_asset: HotAsset): WithdrawalRequest acquires Vault {
        let vault_ref = borrow_vault(vault);
        assert!(
            hot_asset::asset_metadata(&hot_asset) == vault_ref.shares_metadata,
            EVAULT_SHARES_ASSET_MISMATCH
        );

        let shares_amount = hot_asset::amount(&hot_asset);
        assert!(shares_amount > 0, EINVALID_WITHDRAWAL_AMOUNT);

        let base_metadata = vault_ref.base_metadata;
        let to_withdraw = convert_shares_to_amount(vault_ref, shares_amount);

        WithdrawalRequest {
            vault,
            to_withdraw,
            remaining: to_withdraw,
            losses: simple_map::new(),
            debt_offsets: simple_map::new(),
            account: signer::address_of(account),
            to_burn: hot_asset::destroy(hot_asset),
            withdrawn: fungible_asset::zero(base_metadata)
        }
    }

    /// Withdraws assets from a vault specified by the `request` parameter.
    ///
    /// @param request The withdrawal request to be withdrawn from.
    ///
    /// @reverts EVAULT_WITHDRAWAL_AMOUNT_NOT_ZERO if the withdrawal request is not complete.
    /// @reverts EVAULT_DOES_NOT_EXIST if the vault does not exist.
    public fun withdraw(account: &signer, request: &mut WithdrawalRequest) acquires Vault, VaultController {
        assert!(signer::address_of(account) == request.account, EWITHDRAWAL_ACCOUNT_MISMATCH);

        let vault_mut = borrow_vault_mut(request.vault);

        // Ensure that we have enough assets to cover the withdrawal
        assert!(get_free_funds(vault_mut) >= request.remaining, EVAULT_INSUFFICIENT_ASSETS);

        // Withdraw the minimum of `remaining` and `total_idle` to avoid underflow errors
        // and ensure that we don't withdraw more than we have.
        let total_idle = vault_mut.total_idle;
        let withdrawable = math64::min(request.remaining, total_idle);
        if (withdrawable > 0) {
            let vault_signer =
                &object::generate_signer_for_extending(&borrow_vault_controller(&request.vault).extend_ref);

            let asset = primary_store_withdraw(vault_signer, vault_mut.base_metadata, withdrawable);
            fungible_asset::merge(&mut request.withdrawn, asset);

            vault_mut.total_idle = total_idle - withdrawable;
            request.remaining = request.remaining - withdrawable;
        };

        // Since we have withdrawn the available assets,
        // we need to ensure that the vault has enough debt to cover the withdrawal from the strategies.
        assert!(vault_mut.total_debt >= request.remaining, EVAULT_INSUFFICIENT_DEBT);

        // Any value left in `remaining` will be withdrawn from the vault's strategies.
    }

    /// Completes a withdrawal request specified by the `request` parameter.
    ///
    /// @param request The withdrawal request to be completed.
    ///
    /// @return The withdrawn assets.
    ///
    /// @reverts EVAULT_WITHDRAWAL_AMOUNT_NOT_ZERO if the withdrawal amount is not zero.
    /// @reverts EVAULT_DOES_NOT_EXIST if the vault does not exist.
    fun complete_withdrawal_internal(
        account: &signer, request: WithdrawalRequest, max_loss: Option<u64>
    ): FungibleAsset acquires VaultController, Vault {
        let WithdrawalRequest {
            vault,
            to_withdraw,
            to_burn,
            withdrawn,
            losses,
            debt_offsets,
            account: account_address,
            remaining: remaining_amount
        } = request;

        assert!(signer::address_of(account) == account_address, EWITHDRAWAL_ACCOUNT_MISMATCH);

        // Block to handle debt offsets
        let total_debt_offset: u64 = 0;
        {
            let i = 0;
            let (strategies, offsets) = simple_map::to_vec_pair(debt_offsets);
            while (i < vector::length(&strategies)) {
                let amount = *vector::borrow(&offsets, i);
                let strategy = *vector::borrow(&strategies, i);
                let state_mut = strategy_state_mut(vault, &strategy);

                let current_debt = base_strategy::get_current_debt(state_mut);
                assert!(current_debt >= amount, ESTRATEGY_INSUFFICIENT_DEBT);

                // Apply the offset to the strategy's current debt and also increment the total offset
                base_strategy::set_current_debt(state_mut, current_debt - amount);
                total_debt_offset = total_debt_offset + amount;

                i = i + 1;
            };
        };

        // Block to handle loss
        let total_strategies_loss = 0;
        {
            let i = 0;
            let (strategies, losses) = simple_map::to_vec_pair(losses);
            while (i < vector::length(&strategies)) {
                let loss = *vector::borrow(&losses, i);
                let strategy = *vector::borrow(&strategies, i);
                handle_loss(vault, strategy, loss);
                total_strategies_loss = total_strategies_loss + loss;

                i = i + 1;
            };
        };

        assert!(
            remaining_amount + total_strategies_loss + fungible_asset::amount(&withdrawn) == to_withdraw,
            EINVARIANT_VIOLATION
        );

        let vault_mut = borrow_vault_mut(vault);

        // if we still have some to withdraw in `remaining`,
        // we need to subtract it from the total debt and regard it as a loss
        let debt_offset_with_loss = total_debt_offset + remaining_amount;

        assert!(vault_mut.total_debt >= debt_offset_with_loss, EVAULT_INSUFFICIENT_DEBT);
        vault_mut.total_debt = vault_mut.total_debt - debt_offset_with_loss;

        let total_loss = total_strategies_loss + remaining_amount;
        if (option::is_some(&max_loss)) {
            let max_loss = option::destroy_some(max_loss);
            let max_loss_value = math64::mul_div(to_withdraw, max_loss, constants::bps_max());
            assert!(total_loss <= max_loss_value, ETOO_MUCH_LOSS)
        };

        let vault_signer = &object::generate_signer_for_extending(&borrow_vault_controller(&vault).extend_ref);
        asset::safe_burn(vault_signer, to_burn);

        emit(Withdraw { vault, loss: total_loss, amount: fungible_asset::amount(&withdrawn) });

        withdrawn
    }

    public fun complete_withdrawal(
        account: &signer, request: WithdrawalRequest, max_loss: Option<u64>
    ): HotAsset acquires Vault, VaultController {
        let asset = complete_withdrawal_internal(account, request, max_loss);

        // Convert the shares asset to a hot asset,
        // and the recipient is set to the account that requested the withdrawal.
        hot_asset::new_with_recipient(asset, signer::address_of(account))
    }

    public fun complete_withdrawal_coin<C>(
        account: &signer, request: WithdrawalRequest, max_loss: Option<u64>
    ): HotCoin<C> acquires Vault, VaultController {
        let vault = request.vault;
        let asset = complete_withdrawal_internal(account, request, max_loss);
        let asset_metadata = fungible_asset::asset_metadata(&asset);
        assert!(
            option::destroy_some(coin::paired_metadata<C>()) == asset_metadata,
            EVAULT_BASE_ASSET_MISMATCH
        );

        // We cannot convert the asset to a coin directly here because aptos doesn't allow it.
        // So, we need to deposit the asset into the vault primary store and then withdraw the coin.

        let amount = fungible_asset::amount(&asset);
        let vault_address = object::object_address(&vault);
        let vault_signer = object::generate_signer_for_extending(&borrow_vault_controller(&vault).extend_ref);
        primary_store_deposit(vault_address, asset);

        let coin = coin::withdraw<C>(&vault_signer, amount);
        let account_address = signer::address_of(account);
        if (!coin::is_account_registered<C>(account_address)) {
            coin::register<C>(account)
        };

        // Create a hot coin with the recipient being the account that requested the withdrawal.
        hot_coin::new_with_recipient(coin, account_address)
    }

    public fun report(account: &signer, vault: Object<Vault>, strategy: Object<BaseStrategy>): (u64, u64) acquires Vault {
        let vault_ref = borrow_vault(vault);
        let account_address = signer::address_of(account);
        let vault_address = object::object_address(&vault);

        assert!(!vault_ref.is_paused, EVAULT_PAUSED);
        assert!(
            protocol::is_governance(account_address)
                || account_address == vault_ref.manager
                || account_address == vault_address,
            ENOT_AUTHORIZED
        );
        let (profit, loss) = get_strategy_returns(vault, strategy);
        if (loss > 0) {
            handle_loss(vault, strategy, loss)
        };

        let (management_fee, performance_fee) = assess_fee(vault, strategy, profit);
        let total_fee = management_fee + performance_fee;

        if (total_fee > 0) {
            let vault_ref = borrow_vault(vault);
            let fee_shares = convert_amount_to_shares(vault_ref, total_fee);
            let fee_shares_asset = asset::mint(vault_ref.shares_metadata, fee_shares);

            let protocol_fee_bps = protocol::get_protocol_fee();
            if (protocol_fee_bps > 0) {
                let protocol_fee = math64::mul_div(fee_shares, protocol_fee_bps, constants::bps_max());
                if (protocol_fee > 0) {
                    // Give the protocol or governance it's own share of the profit
                    let protocol_fee_shares = fungible_asset::extract(&mut fee_shares_asset, protocol_fee);
                    fungible_asset::deposit(
                        protocol::get_protocol_fee_recipient_store(vault_ref.shares_metadata),
                        protocol_fee_shares
                    );
                };
            };

            // fee_shares_asset now contains the remaining fees, so we \
            // give the remaining fee to the strategy manager/strategist
            primary_store_deposit(base_strategy::manager(strategy), fee_shares_asset);
        };

        if (profit > 0) {
            let vault_mut = borrow_vault_mut(vault);
            let locked_profit = get_locked_profit(vault_mut) + (profit - performance_fee);
            if (locked_profit > loss) {
                vault_mut.total_locked = locked_profit - loss;
            } else {
                vault_mut.total_locked = 0;
            };

            handle_profit(vault, strategy, profit)
        };

        borrow_vault_mut(vault).last_report = timestamp::now_seconds();
        base_strategy::set_last_report(strategy_state_mut(vault, &strategy));

        return (profit, loss)
    }

    /// Adds a strategy to a vault specified by the `vault` parameter.
    ///
    /// @param account The account that is adding the strategy.
    /// @param vault The vault to be added to.
    /// @param strategy The strategy to be added.
    /// @param debt_limit The maximum amount of debt the strategy is allowed to take on.
    ///
    /// @reverts EVAULT_PAUSED if the vault is not active.
    /// @reverts ENOT_AUTHORIZED if the account is not the governance account.
    /// @reverts ESTRATEGY_ALREADY_ADDED if the strategy is already added.
    /// @reverts EVAULT_BASE_ASSET_MISMATCH if the strategy's base metadata is not the base metadata of the vault.
    public fun add_strategy(
        account: &signer,
        vault: Object<Vault>,
        strategy: Object<BaseStrategy>,
        debt_limit: u64
    ) acquires Vault, RegistryInfo {
        let vault_mut = borrow_vault_mut(vault);

        assert!(!vault_mut.is_paused, EVAULT_PAUSED);
        assert!(protocol::is_governance(signer::address_of(account)), ENOT_AUTHORIZED);
        assert!(base_strategy::base_metadata(strategy) == vault_mut.base_metadata, EVAULT_BASE_ASSET_MISMATCH);

        assert!(!simple_map::contains_key(&vault_mut.strategies, &strategy), ESTRATEGY_ALREADY_ADDED);

        // Not allow debt limit to be 0 as it will effectively disable the strategy
        assert!(debt_limit > 0, EINVALID_DEBT_LIMIT);

        simple_map::add(&mut vault_mut.strategies, strategy, base_strategy::new_state(debt_limit));

        let registry = borrow_global_mut<RegistryInfo>(protocol::get_address());
        vector::push_back(&mut registry.strategies, strategy);

        emit(BaseStrategyAdded { strategy, vault });
    }

    /// Removes a strategy from a vault specified by the `vault` parameter.
    ///
    /// @param account The account that is removing the strategy.
    /// @param vault The vault to be removed from.
    /// @param strategy The strategy to be removed.
    /// @param force Whether to force the removal of the strategy.
    ///
    /// @reverts EVAULT_PAUSED if the vault is not active.
    /// @reverts EVAULT_STRATEGY_MISMATCH if the strategy is not found.
    /// @reverts ENOT_AUTHORIZED if the account is not the governance account.
    public fun remove_strategy(
        account: &signer,
        vault: Object<Vault>,
        strategy: Object<BaseStrategy>,
        force: bool
    ) acquires Vault, RegistryInfo {
        let vault_mut = borrow_vault_mut(vault);
        assert!(!vault_mut.is_paused, EVAULT_PAUSED);
        assert!(protocol::is_governance(signer::address_of(account)), ENOT_AUTHORIZED);
        assert!(simple_map::contains_key(&vault_mut.strategies, &strategy), EVAULT_STRATEGY_MISMATCH);

        let (_, strategy_state) = simple_map::remove(&mut vault_mut.strategies, &strategy);
        let strategy_debt = base_strategy::get_current_debt(&strategy_state);
        if (strategy_debt > 0) {
            assert!(force, ESTRATEGY_HAS_DEBT);

            assert!(vault_mut.total_debt >= strategy_debt, EVAULT_INSUFFICIENT_DEBT);
            vault_mut.total_debt = vault_mut.total_debt - strategy_debt;
        };

        let registry = borrow_global_mut<RegistryInfo>(protocol::get_address());
        vector::remove_value(&mut registry.strategies, &strategy);

        base_strategy::destroy_state(strategy_state);
        emit(BaseStrategyRemoved { strategy, vault, force });
    }

    /// Updates the debt limit of a strategy specified by the `strategy` parameter.
    ///
    /// @param account The account that is updating the debt limit.
    /// @param vault The vault to be updated.
    /// @param strategy The strategy to be updated.
    /// @param debt_limit The new debt limit.
    ///
    /// @reverts EVAULT_PAUSED if the vault is not active.
    /// @reverts ENOT_AUTHORIZED if the account is not the governance account.
    /// @reverts EVAULT_STRATEGY_MISMATCH if the strategy is not found.
    public fun update_strategy_debt_limit(
        account: &signer,
        vault: Object<Vault>,
        strategy: Object<BaseStrategy>,
        debt_limit: u64
    ) acquires Vault {
        let vault_ref = borrow_vault(vault);
        assert!(!vault_ref.is_paused, EVAULT_PAUSED);
        assert!(protocol::is_governance(signer::address_of(account)), ENOT_AUTHORIZED);
        assert!(simple_map::contains_key(&vault_ref.strategies, &strategy), EVAULT_STRATEGY_MISMATCH);

        let strategy_state = strategy_state_mut(vault, &strategy);
        base_strategy::set_debt_limit(strategy_state, debt_limit);
    }

    public fun create_debt_fa(
        account: &signer,
        vault: Object<Vault>,
        auth_ref: &AuthRef,
        amount: u64
    ): HotAsset acquires Vault, VaultController {
        create_debt_internal(account, vault, auth_ref, amount);

        let vault_signer = object::generate_signer_for_extending(&borrow_vault_controller(&vault).extend_ref);
        hot_asset::new_from_account(&vault_signer, borrow_vault(vault).base_metadata, amount)
    }

    public fun create_debt_coin<C>(
        account: &signer,
        vault: Object<Vault>,
        auth_ref: &AuthRef,
        amount: u64
    ): HotCoin<C> acquires Vault, VaultController {
        create_debt_internal(account, vault, auth_ref, amount);

        let vault_ref = borrow_vault(vault);
        let vault_signer = object::generate_signer_for_extending(&borrow_vault_controller(&vault).extend_ref);
        assert!(
            option::destroy_some(coin::paired_metadata<C>()) == vault_ref.base_metadata,
            EVAULT_BASE_ASSET_MISMATCH
        );

        hot_coin::new_from_account(&vault_signer, amount)
    }

    public fun sweep(
        account: &signer,
        vault: Object<Vault>,
        metadata: Object<Metadata>,
        amount: u64
    ) acquires Vault, VaultController {
        let account_address = signer::address_of(account);
        let vault_ref = borrow_vault(vault);

        assert!(
            protocol::is_governance(account_address) || vault_ref.manager == account_address,
            ENOT_AUTHORIZED
        );
        assert!(metadata != vault_ref.base_metadata, ECANNOT_SWEEP_BASE_ASSET);

        let stratgies = vault_strategies(vault);
        vector::for_each(
            stratgies,
            |strategy| {
                let shares_metadata = base_strategy::shares_metadata(strategy);
                assert!(shares_metadata != metadata, ECANNOT_SWEEP_ASSOCIATED_ASSET);
            }
        );

        let vault_address = object::object_address(&vault);
        assert!(
            is_primary_store_balance_at_least(vault_address, metadata, amount),
            EINVALID_AMOUNT
        );

        let vault_controller = borrow_vault_controller(&vault);
        let vault_signer = object::generate_signer_for_extending(&vault_controller.extend_ref);
        primary_store_transfer(&vault_signer, metadata, protocol::get_governance(), amount);
    }

    /// Rebalances the idle assets in a vault by comparing the current total idle balance with the available balance in the
    /// primary store. If the total idle assets in the vault are less than the available balance, it adjusts the
    /// total_idle balance accordingly.
    ///
    /// Only authorized users (governance or vault manager) can call this function.
    ///
    /// @param account The signer performing the rebalance operation. Must be either governance or the vault manager.
    /// @param vault The vault object to rebalance the idle assets for.
    ///
    /// @reverts ENOT_AUTHORIZED Thrown if the caller is not authorized to perform the operation (not governance or vault manager).
    public fun rebalance_idle(account: &signer, vault: Object<Vault>) acquires Vault {
        let vault_mut = borrow_vault_mut(vault);
        let account_address = signer::address_of(account);
        let vault_address = object::object_address(&vault);

        assert!(
            protocol::is_governance(account_address) || vault_mut.manager == account_address,
            ENOT_AUTHORIZED
        );
        vault_mut.total_idle = primary_store_balance(vault_address, vault_mut.base_metadata);
    }

    public(friend) fun update_manager(account: &signer, vault: Object<Vault>, manager: address) acquires Vault {
        let account_address = signer::address_of(account);
        assert!(protocol::is_governance(account_address), ENOT_AUTHORIZED);

        let vault_mut = borrow_vault_mut(vault);
        vault_mut.manager = manager;
    }

    /// Deposits shares of the specified strategy into the vault.
    ///
    /// @param vault The vault to be deposited into.
    /// @param strategy The strategy whose shares are to be deposited.
    /// @param asset The asset to be deposited.
    ///
    /// @reverts EVAULT_DOES_NOT_EXIST if the vault does not exist.
    /// @reverts EVAULT_STRATEGY_MISMATCH if the strategy is not found.
    public fun deposit_strategy_shares(
        vault: Object<Vault>, strategy: Object<BaseStrategy>, asset: HotAsset
    ) acquires Vault {
        let vault_ref = borrow_vault(vault);
        assert!(!vault_ref.is_paused, EVAULT_PAUSED);
        assert!(simple_map::contains_key(&vault_ref.strategies, &strategy), EVAULT_STRATEGY_MISMATCH);

        let asset_metadata = hot_asset::asset_metadata(&asset);
        assert!(asset_metadata == base_strategy::shares_metadata(strategy), ESTRATEGY_SHARES_METADATA_MISMATCH);

        let vault_address = object::object_address(&vault);
        assert!(hot_asset::recipient(&asset) == option::some(vault_address), EINVALID_HOT_ASSET_OWNER);

        emit(BaseStrategySharesDeposit { amount: hot_asset::amount(&asset), vault, strategy });
        hot_asset::dispatch(asset)
    }

    /// Withdraws shares from a strategy associated with the `auth_ref` parameter.
    ///
    /// @param vault The vault to be withdrawn from.
    /// @param auth_ref The authref of the strategy to withdraw from.
    /// @param amount The amount to be withdrawn.
    ///
    /// @return The withdrawn shares.
    ///
    /// @reverts EVAULT_DOES_NOT_EXIST if the vault does not exist.
    /// @reverts ESTORE_DOES_NOT_EXIST if the shares store does not exist.
    /// @reverts EVAULT_STRATEGY_MISMATCH if the strategy is not found.
    public fun withdraw_strategy_shares(
        vault: Object<Vault>, auth_ref: &AuthRef, amount: u64
    ): HotAsset acquires Vault, VaultController {
        let vault_mut = borrow_vault_mut(vault);
        let strategy = base_strategy::auth_ref_strategy(auth_ref);
        assert!(simple_map::contains_key(&vault_mut.strategies, &strategy), EVAULT_STRATEGY_MISMATCH);

        let shares_metadata = base_strategy::shares_metadata(strategy);

        emit(BaseStrategySharesWithdraw { amount, vault, strategy });

        let vault_signer = object::generate_signer_for_extending(&borrow_vault_controller(&vault).extend_ref);
        hot_asset::new(primary_store_withdraw(&vault_signer, shares_metadata, amount))
    }

    public fun get_strategy_shares_balance(vault: Object<Vault>, strategy: Object<BaseStrategy>): u64 {
        let metadata = base_strategy::shares_metadata(strategy);
        primary_store_balance(object::object_address(&vault), metadata)
    }

    public fun apply_strategy_withdrawal(
        request: &mut WithdrawalRequest,
        strategy: Object<BaseStrategy>,
        hot_asset: HotAsset,
        expected_amount: u64
    ) {
        let asset = hot_asset::destroy(hot_asset);
        let asset_amount = fungible_asset::amount(&asset);
        if (asset_amount < expected_amount) {
            apply_strategy_loss(request, strategy, expected_amount - asset_amount);
        };

        assert!(asset_amount <= request.remaining, EINVALID_WITHDRAWAL_AMOUNT);
        request.remaining = request.remaining - asset_amount;

        add_debt_offset(request, strategy, asset_amount);
        fungible_asset::merge(&mut request.withdrawn, asset);
    }

    fun apply_strategy_loss(
        request: &mut WithdrawalRequest, strategy: Object<BaseStrategy>, amount: u64
    ) {
        assert!(amount <= request.remaining, EINVALID_WITHDRAWAL_AMOUNT);
        request.remaining = request.remaining - amount;

        if (!simple_map::contains_key(&request.losses, &strategy)) {
            simple_map::add(&mut request.losses, strategy, amount);
            return
        };

        let loss = simple_map::borrow_mut(&mut request.losses, &strategy);
        *loss = *loss + amount;
    }

    public fun add_debt_offset(
        request: &mut WithdrawalRequest, strategy: Object<BaseStrategy>, amount: u64
    ) {
        if (!simple_map::contains_key(&request.debt_offsets, &strategy)) {
            simple_map::add(&mut request.debt_offsets, strategy, amount);
            return
        };

        let offset = simple_map::borrow_mut(&mut request.debt_offsets, &strategy);
        *offset = *offset + amount;
    }

    public fun withdrawn_amount(request: &WithdrawalRequest): u64 {
        fungible_asset::amount(&request.withdrawn)
    }

    public fun withdrawn_asset(request: &WithdrawalRequest): &FungibleAsset {
        &request.withdrawn
    }

    public fun get_total_assets(vault: &Vault): u64 {
        vault.total_idle + vault.total_debt
    }

    public fun convert_amount_to_shares(vault: &Vault, amount: u64): u64 {
        let free_funds = get_free_funds(vault);
        let total_shares = get_total_shares(vault);

        if (free_funds == 0 || total_shares == 0) {
            return amount
        };
        math64::mul_div(amount, (total_shares as u64), free_funds)
    }

    public fun convert_shares_to_amount(vault: &Vault, shares: u64): u64 {
        let free_funds = get_free_funds(vault);
        let total_shares = get_total_shares(vault);

        assert!(total_shares > 0 && free_funds > 0, EINVALID_SHARES_FACTORS);
        math64::mul_div(shares, free_funds, (total_shares as u64))
    }

    public fun get_total_shares(vault: &Vault): u128 {
        let supply = fungible_asset::supply(vault.shares_metadata);
        option::destroy_with_default(supply, 0)
    }

    public fun get_locked_profit(vault: &Vault): u64 {
        if (vault.is_paused) return 0;

        let elapsed_time = timestamp::now_seconds() - vault.last_report;
        if (elapsed_time >= vault.lock_duration || vault.total_locked == 0) {
            return 0
        };

        let time_remaining = vault.lock_duration - elapsed_time;
        math64::mul_div(vault.total_locked, time_remaining, vault.lock_duration)
    }

    public fun get_free_funds(vault: &Vault): u64 {
        let locked_profit = get_locked_profit(vault);
        let total_assets = get_total_assets(vault);

        if (locked_profit > total_assets) return 0;
        return total_assets - locked_profit
    }

    public fun max_deposit(vault: &Vault): u64 {
        let deposit_limit = vault.deposit_limit;
        let total_assets = get_total_assets(vault);

        if (option::is_some(&deposit_limit)) {
            let limit = option::destroy_some(deposit_limit);
            if (limit > total_assets) {
                return limit - total_assets
            };

            return 0
        };

        return constants::u64_max() - total_assets
    }

    public fun withdrawal_amount(request: &WithdrawalRequest): u64 {
        request.to_withdraw
    }

    public fun withdrawal_remaining(request: &WithdrawalRequest): u64 {
        request.remaining
    }

    public fun withdrawal_account(request: &WithdrawalRequest): address {
        request.account
    }

    public fun withdrawal_vault(request: &WithdrawalRequest): Object<Vault> {
        request.vault
    }

    public fun withdrawal_to_burn(request: &WithdrawalRequest): &FungibleAsset {
        &request.to_burn
    }

    public fun withdrawal_withdrawn(request: &WithdrawalRequest): &FungibleAsset {
        &request.withdrawn
    }

    public fun withdrawal_debt_offsets(request: &WithdrawalRequest): &SimpleMap<Object<BaseStrategy>, u64> {
        &request.debt_offsets
    }

    public fun withdrawal_losses(request: &WithdrawalRequest): &SimpleMap<Object<BaseStrategy>, u64> {
        &request.losses
    }

    public fun get_signer_for_router(vault: Object<Vault>, ref: &RouterRef): signer acquires VaultController {
        assert!(protocol::is_valid_router_ref(ref), ENOT_AUTHORIZED);
        object::generate_signer_for_extending(&borrow_vault_controller(&vault).extend_ref)
    }

    // ========== View functions =========

    #[view]
    public fun vaults(): vector<Object<Vault>> acquires RegistryInfo {
        let registry = borrow_global<RegistryInfo>(protocol::get_address());
        let vaults = vector::empty<Object<Vault>>();

        for (i in 0..vector::length(&registry.vaults)) {
            let vault = vector::borrow(&registry.vaults, i);
            vector::push_back(&mut vaults, *vault);
        };

        vaults
    }

    #[view]
    public fun paginated_vaults(offset: u64, limit: u64): vector<Object<Vault>> acquires RegistryInfo {
        let registry = borrow_global<RegistryInfo>(protocol::get_address());
        let vaults = vector::empty<Object<Vault>>();
        let total_vaults = vector::length(&registry.vaults);

        let start = math64::min(offset, total_vaults);
        let end = math64::min(start + limit, total_vaults);

        for (i in start..end) {
            let vault = vector::borrow(&registry.vaults, i);
            vector::push_back(&mut vaults, *vault);
        };

        vaults
    }

    #[view]
    public fun vault_strategies(vault: Object<Vault>): vector<Object<BaseStrategy>> acquires Vault {
        let strategies = &borrow_vault(vault).strategies;
        simple_map::keys(strategies)
    }

    #[view]
    public fun strategy_debt(vault: Object<Vault>, strategy: Object<BaseStrategy>): u64 acquires Vault {
        base_strategy::get_current_debt(strategy_state(vault, &strategy))
    }

    #[view]
    public fun strategy_total_loss(vault: Object<Vault>, strategy: Object<BaseStrategy>): u64 acquires Vault {
        base_strategy::get_total_loss(strategy_state(vault, &strategy))
    }

    #[view]
    public fun strategy_total_profit(vault: Object<Vault>, strategy: Object<BaseStrategy>): u64 acquires Vault {
        base_strategy::get_total_profit(strategy_state(vault, &strategy))
    }

    #[view]
    public fun strategy_last_report(vault: Object<Vault>, strategy: Object<BaseStrategy>): u64 acquires Vault {
        base_strategy::get_last_report(strategy_state(vault, &strategy))
    }

    #[view]
    public fun strategies(): vector<Object<BaseStrategy>> acquires RegistryInfo {
        borrow_global<RegistryInfo>(protocol::get_address()).strategies
    }

    #[view]
    public fun amount_to_shares(vault: Object<Vault>, amount: u64): u64 acquires Vault {
        convert_amount_to_shares(borrow_vault(vault), amount)
    }

    #[view]
    public fun shares_to_amount(vault: Object<Vault>, shares: u64): u64 acquires Vault {
        convert_shares_to_amount(borrow_vault(vault), shares)
    }

    #[view]
    public fun base_metadata(vault: Object<Vault>): Object<Metadata> acquires Vault {
        borrow_vault(vault).base_metadata
    }

    #[view]
    public fun shares_metadata(vault: Object<Vault>): Object<Metadata> acquires Vault {
        borrow_vault(vault).shares_metadata
    }

    #[view]
    public fun total_debt_limit(vault: Object<Vault>): Option<u64> acquires Vault {
        borrow_vault(vault).total_debt_limit
    }

    #[view]
    public fun total_idle(vault: Object<Vault>): u64 acquires Vault {
        borrow_vault(vault).total_idle
    }

    #[view]
    public fun total_debt(vault: Object<Vault>): u64 acquires Vault {
        borrow_vault(vault).total_debt
    }

    #[view]
    public fun total_assets(vault: Object<Vault>): u64 acquires Vault {
        get_total_assets(borrow_vault(vault))
    }

    #[view]
    public fun total_shares(vault: Object<Vault>): u128 acquires Vault {
        get_total_shares(borrow_vault(vault))
    }

    #[view]
    public fun is_paused(vault: Object<Vault>): bool acquires Vault {
        borrow_vault(vault).is_paused
    }

    #[view]
    public fun deposit_limit(vault: Object<Vault>): Option<u64> acquires Vault {
        borrow_vault(vault).deposit_limit
    }

    #[view]
    public fun manager(vault: Object<Vault>): address acquires Vault {
        borrow_vault(vault).manager
    }

    #[view]
    public fun lock_duration(vault: Object<Vault>): u64 acquires Vault {
        borrow_vault(vault).lock_duration
    }

    #[view]
    public fun total_locked(vault: Object<Vault>): u64 acquires Vault {
        borrow_vault(vault).total_locked
    }

    #[view]
    public fun performance_fee(vault: Object<Vault>): Option<u64> acquires Vault {
        borrow_vault(vault).performance_fee
    }

    #[view]
    public fun management_fee(vault: Object<Vault>): Option<u64> acquires Vault {
        borrow_vault(vault).management_fee
    }

    #[view]
    public fun strategy_debt_limit(vault: Object<Vault>, strategy: Object<BaseStrategy>): u64 acquires Vault {
        base_strategy::get_debt_limit(strategy_state(vault, &strategy))
    }

    #[view]
    public fun vaults_view(offset: u64, limit: u64): PaginatedVaultsView acquires Vault, RegistryInfo {
        let paginated_vaults = paginated_vaults(offset, limit);
        let total_count = vector::length(&paginated_vaults);
        let vaults = vector::empty<VaultView>();

        for (i in 0..total_count) {
            let vault = *vector::borrow(&paginated_vaults, i);
            vector::push_back(&mut vaults, vault_view(vault));
        };

        PaginatedVaultsView { limit, offset, vaults, total_count }
    }

    #[view]
    public fun vault_view(vault: Object<Vault>): VaultView acquires Vault {
        let vault_ref = borrow_vault(vault);

        let vault_address = object::object_address(&vault);

        let total_asset = get_total_assets(vault_ref);
        let total_shares = (get_total_shares(vault_ref) as u64);
        let decimals = fungible_asset::decimals(vault_ref.base_metadata);

        let asset_name = fungible_asset::name(vault_ref.base_metadata);
        let asset_address = object::object_address(&vault_ref.base_metadata);

        let shares_name = fungible_asset::name(vault_ref.shares_metadata);
        let shares_address = object::object_address(&vault_ref.shares_metadata);

        let paired_coin_maybe = coin::paired_coin(vault_ref.base_metadata);
        let paired_coin_type =
            if (option::is_some(&paired_coin_maybe)) {
                option::some(type_info_to_string(option::borrow(&paired_coin_maybe)))
            } else {
                option::none()
            };

        let strategy_views = vector::empty<VaultBaseStrategyView>();
        let strategies = simple_map::keys(&vault_ref.strategies);
        for (i in 0..vector::length(&strategies)) {
            let strategy = vector::borrow(&strategies, i);
            let state = simple_map::borrow(&vault_ref.strategies, strategy);
            let strategy_view = base_strategy::vault_base_strategy_view(*strategy, state, vault_address);
            vector::push_back(&mut strategy_views, strategy_view);
        };

        VaultView {
            decimals,
            asset_name,
            shares_name,
            total_asset,
            total_shares,
            vault_address,
            asset_address,
            shares_address,
            paired_coin_type,
            strategies: strategy_views,
            total_debt: vault_ref.total_debt,
            total_idle: vault_ref.total_idle
        }
    }

    // ========== Inline functions =========

    inline fun borrow_vault(vault: Object<Vault>): &Vault {
        borrow_global<Vault>(object::object_address(&vault))
    }

    inline fun borrow_vault_mut(vault: Object<Vault>): &mut Vault {
        borrow_global_mut<Vault>(object::object_address(&vault))
    }

    inline fun borrow_vault_controller(vault: &Object<Vault>): &VaultController {
        borrow_global<VaultController>(object::object_address(vault))
    }

    inline fun strategy_state(vault: Object<Vault>, strategy: &Object<BaseStrategy>): &BaseStrategyState acquires Vault {
        simple_map::borrow(&borrow_vault(vault).strategies, strategy)
    }

    inline fun strategy_state_mut(vault: Object<Vault>, strategy: &Object<BaseStrategy>): &mut BaseStrategyState acquires Vault {
        simple_map::borrow_mut(&mut borrow_vault_mut(vault).strategies, strategy)
    }

    // ========== Internal functions =========

    fun deposit_internal(vault: Object<Vault>, hot_asset: HotAsset): HotAsset acquires Vault {
        // hot assets being deposited must come from a known owner, this allows us to enforce the
        // recipient of the shares asset without share of it being held onto by the concrete strategy or malicious attacker.
        let owner_maybe = hot_asset::owner(&hot_asset);
        assert!(option::is_some(&owner_maybe), EINVALID_HOT_ASSET_OWNER);

        let vault_mut = borrow_vault_mut(vault);
        let asset = hot_asset::destroy(hot_asset);
        let base_amount = fungible_asset::amount(&asset);
        let shares_amount = convert_amount_to_shares(vault_mut, base_amount);

        vault_mut.total_idle = vault_mut.total_idle + base_amount;
        primary_store_deposit(object::object_address(&vault), asset);

        emit(Deposit { amount: base_amount, vault });

        // Create shares asset with the recipient being the owner of the deposited hot asset.
        let recipient = option::destroy_some(owner_maybe);
        hot_asset::new_with_recipient(asset::mint(vault_mut.shares_metadata, shares_amount), recipient)
    }

    fun create_shares_asset(
        vault_signer: &signer, base_metadata: Object<Metadata>, vault_index: u64
    ): Object<Metadata> {
        let base_symbol = fungible_asset::symbol(base_metadata);

        // Create name: "CV [BASE_SYMBOL]-[INDEX]"
        let name_prefix = string::utf8(b"CV ");
        let index_str = string_utils::to_string(&vault_index); // Convert index to string

        // Calculate available space for the symbol in the name (accounting for prefix, dash, and index)
        let symbol_max_len = MAX_NAME_LENGTH - string::length(&name_prefix) - string::length(&index_str) - 1; // -1 for dash

        // Truncate the symbol if needed
        let truncated_symbol =
            if (string::length(&base_symbol) > symbol_max_len) {
                string::sub_string(&base_symbol, 0, symbol_max_len)
            } else {
                base_symbol
            };

        // Construct the final name: "CV [BASE_SYMBOL]-[INDEX]"
        let final_name = name_prefix;
        string::append(&mut final_name, truncated_symbol);
        string::append(&mut final_name, string::utf8(b"-"));
        string::append(&mut final_name, index_str);

        // Handle symbol - prefixed with "cv" e.g. cvBTC, cvUSDT
        let symbol_max_base_len = MAX_SYMBOL_LENGTH - 2; // 2 is length of "cv"
        let truncated_symbol_for_prefix =
            if (string::length(&base_symbol) > symbol_max_base_len) {
                // Truncate base_symbol if needed
                string::sub_string(&base_symbol, 0, symbol_max_base_len)
            } else {
                base_symbol
            };

        let final_symbol = string::utf8(b"cv");
        string::append(&mut final_symbol, truncated_symbol_for_prefix);

        // Get decimals from the base metadata
        let decimals = fungible_asset::decimals(base_metadata);

        asset::create(
            vault_signer,
            final_name,
            final_symbol,
            decimals,
            utf8(
                b"https://raw.githubusercontent.com/Canopyxyz/canopy-assets/master/icons/canopy_vault.svg"
            ),
            utf8(b"https://www.canopyhub.xyz")
        )
    }

    fun get_strategy_returns(vault: Object<Vault>, strategy: Object<BaseStrategy>): (u64, u64) acquires Vault {
        let vault_ref = borrow_vault(vault);
        assert!(simple_map::contains_key(&vault_ref.strategies, &strategy), EVAULT_STRATEGY_MISMATCH);

        // Get the vault's strategy shares balance...
        // and convert the balance to the strategy's base asset.
        let strategy_shares = get_strategy_shares_balance(vault, strategy);
        if (strategy_shares == 0) return (0, 0);

        let strategy_assets = base_strategy::shares_to_amount(strategy, strategy_shares);
        let state = strategy_state(vault, &strategy);
        let strategy_debt = base_strategy::get_current_debt(state);

        let (profit, loss) = (0, 0);
        if (strategy_assets > strategy_debt) {
            profit = strategy_assets - strategy_debt;
        } else {
            loss = strategy_debt - strategy_assets;
        };

        (profit, loss)
    }

    fun assess_fee(vault: Object<Vault>, strategy: Object<BaseStrategy>, profit: u64): (u64, u64) acquires Vault {
        let state = strategy_state(vault, &strategy);
        let vault_ref = borrow_vault(vault);

        let (management_fee, performance_fee) = (0, 0);
        let last_report = base_strategy::get_last_report(state);
        assert!(timestamp::now_seconds() >= last_report, EINVALID_REPORT_TIME);

        let duration = timestamp::now_seconds() - last_report;
        let management_fee_bps = option::destroy_with_default(
            vault_ref.management_fee, protocol::get_management_fee()
        );
        if (duration > 0 && management_fee_bps > 0) {
            let current_debt = base_strategy::get_current_debt(state);

            management_fee = (((current_debt as u128) * (management_fee_bps as u128) * (duration as u128))
                / ((constants::bps_max() as u128) * (constants::seconds_per_year() as u128)) as u64);
        };

        // Take performance fee only if there is gain and performance fee is not zero.
        let performance_fee_bps =
            option::destroy_with_default(vault_ref.performance_fee, protocol::get_performance_fee());

        if (profit > 0 && performance_fee_bps > 0) {
            performance_fee = (profit * performance_fee_bps) / constants::bps_max();
        };

        return (management_fee, performance_fee)
    }

    fun handle_loss(vault: Object<Vault>, strategy: Object<BaseStrategy>, loss: u64) acquires Vault {
        let state = strategy_state_mut(vault, &strategy);
        let strategy_debt = base_strategy::get_current_debt(state);
        assert!(strategy_debt >= loss, ESTRATEGY_INSUFFICIENT_DEBT);

        let total_loss = base_strategy::get_total_loss(state) + loss;
        base_strategy::set_total_loss(state, total_loss);

        let new_debt = strategy_debt - loss;
        base_strategy::set_current_debt(state, new_debt);

        let vault_mut = borrow_vault_mut(vault);
        assert!(vault_mut.total_debt >= loss, E_INVARIANT_STRATEGY_INSUFFICIENT_DEBT);
        vault_mut.total_debt = vault_mut.total_debt - loss;
    }

    fun handle_profit(vault: Object<Vault>, strategy: Object<BaseStrategy>, profit: u64) acquires Vault {
        let state = strategy_state_mut(vault, &strategy);
        let total_profit = base_strategy::get_total_profit(state) + profit;
        base_strategy::set_total_profit(state, total_profit);

        let strategy_debt = base_strategy::get_current_debt(state);
        base_strategy::set_current_debt(state, strategy_debt + profit);

        let vault_mut = borrow_vault_mut(vault);
        vault_mut.total_debt = vault_mut.total_debt + profit;
    }

    fun create_debt_internal(
        account: &signer,
        vault: Object<Vault>,
        auth_ref: &AuthRef,
        amount: u64
    ) acquires Vault {
        assert!(is_signer_authorized(account, vault), ENOT_AUTHORIZED);
        let vault_mut = borrow_vault_mut(vault);
        let strategy = base_strategy::auth_ref_strategy(auth_ref);

        assert!(!vault_mut.is_paused, EVAULT_PAUSED);
        assert!(simple_map::contains_key(&vault_mut.strategies, &strategy), EVAULT_STRATEGY_MISMATCH);

        let vault_address = object::object_address(&vault);
        assert!(vault_mut.total_idle >= amount, EVAULT_INSUFFICIENT_ASSETS);
        assert!(
            primary_store_balance(vault_address, vault_mut.base_metadata) >= vault_mut.total_idle,
            EVAULT_INSUFFICIENT_ASSETS
        );

        let new_total_debt = vault_mut.total_debt + amount;
        if (option::is_some(&vault_mut.total_debt_limit)) {
            assert!(
                new_total_debt <= option::destroy_some(vault_mut.total_debt_limit),
                EINVALID_DEBT_AMOUNT
            );
        };

        vault_mut.total_debt = new_total_debt;
        vault_mut.total_idle = vault_mut.total_idle - amount;

        let strategy_state = strategy_state_mut(vault, &strategy);
        let new_strategy_debt = base_strategy::get_current_debt(strategy_state) + amount;

        let strategy_debt_limit = base_strategy::get_debt_limit(strategy_state);
        assert!(new_strategy_debt <= strategy_debt_limit, EINVALID_DEBT_AMOUNT);

        base_strategy::set_current_debt(strategy_state, new_strategy_debt);
    }

    fun create_internal(
        constructor_ref: &ConstructorRef,
        manager: address,
        deposit_limit: Option<u64>,
        total_debt_limit: Option<u64>,
        base_metadata: Object<Metadata>,
        shares_metadata: Object<Metadata>
    ): (Vault, VaultController) {
        let vault = Vault {
            manager,
            base_metadata,
            total_debt: 0,
            deposit_limit,
            total_idle: 0,
            total_debt_limit,
            total_locked: 0,
            shares_metadata,
            is_paused: false,
            strategies: simple_map::new(),
            management_fee: option::none(),
            performance_fee: option::none(),
            last_report: timestamp::now_seconds(),
            lock_duration: constants::default_lock_duration()
        };

        let extend_ref = object::generate_extend_ref(constructor_ref);
        let transfer_ref = object::generate_transfer_ref(constructor_ref);
        object::disable_ungated_transfer(&transfer_ref);

        (vault, VaultController { extend_ref })
    }

    fun is_signer_authorized(account: &signer, vault: Object<Vault>): bool acquires Vault {
        let vault_ref = borrow_vault(vault);
        let account_address = signer::address_of(account);

        let is_manager = vault_ref.manager == account_address;
        let is_protocol = protocol::is_governance(account_address);
        let is_self = account_address == object::object_address(&vault);

        is_manager || is_protocol || is_self
    }

    fun type_info_to_string(type_info: &TypeInfo): String {
        let delimeter = b"::";
        let pkg_addr = type_info::account_address(type_info);
        let type_str = string_utils::to_string_with_canonical_addresses(&pkg_addr);

        string::append(&mut type_str, utf8(delimeter));
        string::append(&mut type_str, utf8(type_info::module_name(type_info)));
        string::append(&mut type_str, utf8(delimeter));
        string::append(&mut type_str, utf8(type_info::struct_name(type_info)));

        type_str
    }

    #[test_only]
    public fun create_for_test(
        manager: &signer,
        deposit_limit: Option<u64>,
        total_debt_limit: Option<u64>,
        base_metadata: Object<Metadata>
    ): Object<Vault> acquires RegistryInfo {
        create(manager, deposit_limit, total_debt_limit, base_metadata)
    }

    #[test_only]
    public fun create_for_test_coin<CoinType>(
        manager: &signer, deposit_limit: Option<u64>, total_debt_limit: Option<u64>
    ): Object<Vault> acquires RegistryInfo {
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

        create(manager, deposit_limit, total_debt_limit, base_metadata)
    }

    #[test_only]
    public fun increment_to_withdraw_withdrawal_for_test(
        request: &mut WithdrawalRequest, amount: u64
    ) {
        request.to_withdraw = request.to_withdraw + amount;
    }

    #[test_only]
    public fun decrement_to_withdraw_withdrawal_for_test(
        request: &mut WithdrawalRequest, amount: u64
    ) {
        request.to_withdraw = request.to_withdraw - amount;
    }

    #[test_only]
    public fun increment_remaining_withdrawal_for_test(
        request: &mut WithdrawalRequest, amount: u64
    ) {
        request.remaining = request.remaining + amount;
    }

    #[test_only]
    public fun decrement_remaining_withdrawal_for_test(
        request: &mut WithdrawalRequest, amount: u64
    ) {
        request.remaining = request.remaining - amount;
    }

    #[test_only]
    public fun increment_total_idle_for_test(vault: Object<Vault>, amount: u64) acquires Vault {
        let vault_mut = borrow_vault_mut(vault);
        vault_mut.total_idle = vault_mut.total_idle + amount;
    }

    #[test_only]
    public fun decrement_total_idle_for_test(vault: Object<Vault>, amount: u64) acquires Vault {
        let vault_mut = borrow_vault_mut(vault);
        vault_mut.total_idle = vault_mut.total_idle - amount;
    }

    #[test_only]
    public fun increment_total_debt_for_test(vault: Object<Vault>, amount: u64) acquires Vault {
        let vault_mut = borrow_vault_mut(vault);
        vault_mut.total_debt = vault_mut.total_debt + amount;
    }

    #[test_only]
    public fun decrement_total_debt_for_test(vault: Object<Vault>, amount: u64) acquires Vault {
        let vault_mut = borrow_vault_mut(vault);
        vault_mut.total_debt = vault_mut.total_debt - amount;
    }

    #[test_only]
    public fun increment_strategy_debt_for_test(
        vault: Object<Vault>, strategy: Object<BaseStrategy>, amount: u64
    ) acquires Vault {
        let strategy_state = strategy_state_mut(vault, &strategy);
        let current_debt = base_strategy::get_current_debt(strategy_state);
        base_strategy::set_current_debt(strategy_state, current_debt + amount);
    }

    #[test_only]
    public fun decrement_strategy_debt_for_test(
        vault: Object<Vault>, strategy: Object<BaseStrategy>, amount: u64
    ) acquires Vault {
        let strategy_state = strategy_state_mut(vault, &strategy);
        let current_debt = base_strategy::get_current_debt(strategy_state);
        if (current_debt >= amount) {
            base_strategy::set_current_debt(strategy_state, current_debt - amount);
        } else {
            base_strategy::set_current_debt(strategy_state, 0);
        };
    }

    #[test_only]
    public fun destroy_withdrawal_for_test(request: WithdrawalRequest) {
        let WithdrawalRequest {
            remaining: _,
            to_withdraw: _,
            to_burn,
            withdrawn,
            debt_offsets: _,
            losses: _,
            account: _,
            vault: _
        } = request;

        primary_store_deposit(@0xDeAd, withdrawn);
        primary_store_deposit(@0xDeAd, to_burn);
    }

    #[test_only]
    public fun assess_fee_for_test(
        vault: Object<Vault>, strategy: Object<BaseStrategy>, profit: u64
    ): (u64, u64) acquires Vault {
        assess_fee(vault, strategy, profit)
    }

    #[test_only]
    public fun amount_to_shares_for_test(vault: Object<Vault>, amount: u64): u64 acquires Vault {
        convert_amount_to_shares(borrow_vault(vault), amount)
    }
}

module satay::base_strategy {
    use std::option::{Self, Option};
    use std::signer;
    use std::string::{Self, utf8};
    use aptos_std::math64;
    use aptos_std::type_info;
    use aptos_framework::coin;
    use aptos_framework::fungible_asset::{Self, FungibleAsset, Metadata};
    use aptos_framework::object::{Self, ConstructorRef, ExtendRef, Object, ObjectGroup};
    use aptos_framework::primary_fungible_store::{
        Self,
        balance as primary_store_balance,
        deposit as primary_store_deposit,
        ensure_primary_store_exists,
        withdraw as primary_store_withdraw
    };
    use aptos_framework::timestamp;

    use satay::asset;
    use satay::constants;
    use satay::hot_asset::{Self, HotAsset};
    use satay::hot_coin::{Self, HotCoin};
    use satay::protocol;

    friend satay::vault;
    friend satay::satay;

    #[resource_group_member(group = ObjectGroup)]
    struct BaseStrategy has key {
        /// Total idle assets not yet deployed
        total_idle: u64,
        /// Total debt deployed by the strategy
        total_debt: u64,
        /// Locked shares
        total_locked: u64,
        /// The duration of the locked profit
        lock_duration: u64,
        /// The address of the strategy implementation.
        concrete_address: address,
        /// Timestamp of the last profit collection.
        last_harvest: u64,
        /// The metadata of the base(deposit) asset.
        base_metadata: Object<Metadata>,
        /// The metadata of the shares asset.
        shares_metadata: Object<Metadata>,
        /// The address of the strategy manager.
        manager: address,
        performance_fee: Option<u64>
    }

    #[resource_group_member(group = ObjectGroup)]
    struct BaseStrategyController has key {
        /// The extend_ref of the strategy, used to generate signer for the strategy.
        extend_ref: ExtendRef
    }

    /// A reference used to authorize the strategy for certain action or operations.
    struct AuthRef has store, drop {
        strategy: Object<BaseStrategy>
    }

    struct BaseStrategyState has store {
        /// The debt limit of the strategy.
        debt_limit: u64,
        /// The current amount of debt of the strategy.
        current_debt: u64,
        /// The time when the strategy was last reported.
        last_report: u64,
        /// Total loss
        total_loss: u64,
        /// Total profit
        total_profit: u64
    }

    struct WithdrawalRequest {
        /// The account withdrawing the funds,
        /// this will be `none` if the funds are being withdrawn from the vault.
        account: Option<address>,
        /// THe remaining amount to be withdrawn.
        remaining: u64,
        /// The amount of assets to be withdrawn.
        to_withdraw: u64,
        /// The shares to be burnt.
        to_burn: FungibleAsset,
        /// The assets that have been withdrawn.
        withdrawn: FungibleAsset,
        /// The amount that needs to be offset from the debt.
        debt_offset: u64,
        /// The strategy that is being withdrawn from.
        strategy: Object<BaseStrategy>
    }

    struct HarvestRequest {
        loss: u64,
        profit: u64,
        strategy: Object<BaseStrategy>
    }

    /// The view of a base strategy as a standalone object.
    struct BaseStrategyView has copy, drop {
        /// The number of decimal places used by the strategy's base asset and shares asset.
        decimals: u8,
        /// The total amount of debt the strategy holds.
        total_debt: u64,
        /// The total amount of unused (idle) base assets held by the strategy.
        total_idle: u64,
        /// The total number of shares issued by the strategy.
        total_shares: u64,
        /// The total value of all assets managed by the strategy (including debt assets).
        total_asset: u64,
        /// The address of the strategy's base asset.
        asset_address: address,
        /// The address of the shares asset issued by the strategy.
        shares_address: address,
        /// The specific address where the strategy is implemented. This is the address of the deployed strategy code.
        concrete_address: address,
        /// The address of the base strategy object.
        strategy_address: address
    }

    /// The view of a base strategy as associated with a specific vault.
    struct VaultBaseStrategyView has copy, drop {
        /// The number of decimal places used by the strategy's base asset and shares asset.
        decimals: u8,
        /// The maximum amount of debt that the strategy is allowed to hold from the associated vault.
        debt_limit: u64,
        /// The total amount of loss incurred by the strategy in relation to the associated vault.
        total_loss: u64,
        /// The total amount of debt held by the strategy across all associated entities.
        total_debt: u64,
        /// The total amount of unused (idle) base assets held by the strategy.
        total_idle: u64,
        /// The last time the strategy reported its performance or status to the vault.
        last_report: u64,
        /// The current amount of debt the strategy holds specifically from the associated vault.
        current_vault_debt: u64,
        /// The total number of shares issued by the strategy.
        total_shares: u64,
        /// The total amount of profit generated by the strategy for the associated vault.
        total_profit: u64,
        /// The total value of all assets managed by the strategy (including debt assets).
        total_asset: u64,
        /// The address of the strategy's base asset.
        asset_address: address,
        /// The address of the shares asset issued by the strategy.
        shares_address: address,
        /// The specific address where the strategy is implemented. This is the address of the deployed strategy code.
        concrete_address: address,
        /// The address of the base strategy object.
        strategy_address: address,
        /// The address of the vault associated with this strategy.
        vault_address: address
    }

    /// Unauthorized signer or capability
    const ENOT_AUTHORIZED: u64 = 100;
    /// Invalid amount specified
    const EINVALID_AMOUNT: u64 = 101;
    /// Insufficient debt to perform action
    const EINSUFFICIENT_DEBT: u64 = 102;
    /// Too much loss
    const ETOO_MUCH_LOSS: u64 = 103;
    /// Asset metadata mismatch
    const EASSET_METADATA_MISMATCH: u64 = 104;
    /// Insufficient idle balance
    const EINSUFFICIENT_IDLE_BALANCE: u64 = 105;
    /// Invariant violation
    const EINVARIANT_VIOLATION: u64 = 106;
    /// Invalid remaining amount
    const EINVALID_REMAINING_AMOUNT: u64 = 107;
    /// Invalid fee
    const EINVALID_FEE: u64 = 108;
    /// Invalid lock duration
    const EINVALID_LOCK_DURATION: u64 = 109;
    /// Cannot sweep base asset
    const ECANNOT_SWEEP_BASE_ASSET: u64 = 110;
    /// Invalid strategy module name
    const EINVALID_STRATEGY_MODULE_NAME: u64 = 111;
    /// Invalid withdrawal account
    const ENOT_WITHDRAWAL_ACCOUNT: u64 = 112;
    /// Invalid hot asset recipient
    const EINVALID_HOT_RECIPIENT: u64 = 113;

    // ========== Public Functions ==========

    public fun create<T: drop>(account: &signer, base_metadata: Object<Metadata>, _witness: T): AuthRef {
        let constructor_ref = object::create_sticky_object(protocol::get_address());
        let strategy_signer = object::generate_signer(&constructor_ref);

        let witness = type_info::type_of<T>();
        let concrete_address = type_info::account_address(&witness);

        // Create the shares asset for the strategy
        let shares_metadata = create_shares_asset(&strategy_signer, base_metadata);
        let (base_strategy, strategy_controller) =
            create_internal(
                &constructor_ref,
                signer::address_of(account),
                base_metadata,
                shares_metadata,
                concrete_address
            );

        move_to(&strategy_signer, base_strategy);
        move_to(&strategy_signer, strategy_controller);

        let base_strategy_object = object::object_from_constructor_ref<BaseStrategy>(&constructor_ref);
        ensure_primary_store_exists(object::object_address(&base_strategy_object), base_metadata);

        AuthRef { strategy: base_strategy_object }
    }

    public fun deposit(hot_asset: HotAsset, auth_ref: &AuthRef): HotAsset acquires BaseStrategy, BaseStrategyController {
        // hot assets being deposited must come from a known owner, this allows us to enforce the
        // recipient of the shares asset without share of it being held onto by the concrete strategy or malicious attacker.
        let owner_maybe = hot_asset::owner(&hot_asset);
        assert!(option::is_some(&owner_maybe), EINVALID_HOT_RECIPIENT);

        let strategy = auth_ref.strategy;
        let strategy_mut = borrow_strategy_mut(&strategy);
        assert!(hot_asset::asset_metadata(&hot_asset) == strategy_mut.base_metadata, EASSET_METADATA_MISMATCH);

        let asset_amount = hot_asset::amount(&hot_asset);
        let strategy_controller = borrow_strategy_controller(&strategy);
        let shares_asset = mint_shares_for_amount(strategy_mut, strategy_controller, asset_amount);

        deposit_internal(strategy, hot_asset);

        // Create shares asset with the recipient being the owner of the deposited hot asset.
        hot_asset::new_with_recipient(shares_asset, option::destroy_some(owner_maybe))
    }

    public fun mint_debt_shares_fa(hot_asset: &HotAsset, auth_ref: &AuthRef): HotAsset acquires BaseStrategy, BaseStrategyController {
        let asset = hot_asset::asset(hot_asset);
        assert!(fungible_asset::asset_metadata(asset) == base_metadata(auth_ref.strategy), EASSET_METADATA_MISMATCH);
        let debt_shares = mint_debt_shares_internal(auth_ref.strategy, fungible_asset::amount(asset));

        // Convert the shares to a hot asset and set the recipient to the owner of the original hot asset
        let owner_maybe = hot_asset::owner(hot_asset);
        assert!(option::is_some(&owner_maybe), EINVALID_HOT_RECIPIENT);
        hot_asset::new_with_recipient(debt_shares, option::destroy_some(owner_maybe))
    }

    public fun mint_debt_shares_coin<CoinType>(
        hot_coin: &HotCoin<CoinType>, auth_ref: &AuthRef
    ): HotAsset acquires BaseStrategy, BaseStrategyController {
        assert!(
            option::destroy_some(coin::paired_metadata<CoinType>()) == base_metadata(auth_ref.strategy),
            EASSET_METADATA_MISMATCH
        );

        let debt_shares = mint_debt_shares_internal(auth_ref.strategy, hot_coin::value(hot_coin));

        // Convert the shares to a hot asset and set the recipient to the owner of the original hot coin
        let owner_maybe = hot_coin::owner(hot_coin);
        assert!(option::is_some(&owner_maybe), EINVALID_HOT_RECIPIENT);
        hot_asset::new_with_recipient(debt_shares, option::destroy_some(owner_maybe))
    }

    public fun set_lock_duration(
        account: &signer, strategy: Object<BaseStrategy>, duration: u64
    ) acquires BaseStrategy {
        let strategy_mut = borrow_strategy_mut(&strategy);
        assert!(protocol::is_governance(signer::address_of(account)), ENOT_AUTHORIZED);

        assert!(
            duration >= constants::min_lock_duration() && duration <= constants::max_lock_duration(),
            EINVALID_LOCK_DURATION
        );
        strategy_mut.lock_duration = duration;
    }

    public fun set_performance_fee(
        account: &signer, strategy: Object<BaseStrategy>, fee: Option<u64>
    ) acquires BaseStrategy {
        let strategy_mut = borrow_strategy_mut(&strategy);
        assert!(protocol::is_governance(signer::address_of(account)), ENOT_AUTHORIZED);

        if (option::is_some(&fee)) {
            assert!(*option::borrow(&fee) <= constants::max_performance_fee(), EINVALID_FEE);
        };

        strategy_mut.performance_fee = fee;
    }

    public fun request_withdrawal(hot_shares: HotAsset, auth_ref: &AuthRef): WithdrawalRequest acquires BaseStrategy {
        let strategy = auth_ref.strategy;
        let strategy_ref = borrow_strategy(&strategy);
        assert!(
            hot_asset::asset_metadata(&hot_shares) == strategy_ref.shares_metadata,
            EASSET_METADATA_MISMATCH
        );

        let amount = hot_asset::amount(&hot_shares);
        let to_withdraw = convert_shares_to_amount(strategy_ref, amount);

        // Withdrawal account should be set to the owner of the shares asset, if set.
        let withdrawer = hot_asset::owner(&hot_shares);

        WithdrawalRequest {
            strategy,
            to_withdraw,
            debt_offset: 0,
            account: withdrawer,
            remaining: to_withdraw,
            to_burn: hot_asset::destroy(hot_shares),
            withdrawn: fungible_asset::zero(strategy_ref.base_metadata)
        }
    }

    public fun withdraw(request: &mut WithdrawalRequest) acquires BaseStrategy, BaseStrategyController {
        let strategy_mut = borrow_strategy_mut(&request.strategy);
        let available = math64::min(request.remaining, strategy_mut.total_idle);
        if (available == 0) return;

        let strategy_address = object::object_address(&request.strategy);
        assert!(
            primary_store_balance(strategy_address, strategy_mut.base_metadata) >= available,
            EINSUFFICIENT_IDLE_BALANCE
        );

        let stategy_controller = borrow_strategy_controller(&request.strategy);
        let strategy_signer = object::generate_signer_for_extending(&stategy_controller.extend_ref);
        let withdrawn = primary_store_withdraw(&strategy_signer, strategy_mut.base_metadata, available);
        fungible_asset::merge(&mut request.withdrawn, withdrawn);

        strategy_mut.total_idle = strategy_mut.total_idle - available;
        request.remaining = request.remaining - available;
    }

    public fun apply_fa_withdrawal(request: &mut WithdrawalRequest, hot_asset: HotAsset) acquires BaseStrategy {
        let asset = hot_asset::destroy(hot_asset);
        let amount = fungible_asset::amount(&asset);

        // if the amount gotten is more than the needed amount, extract the excess and deposit it into the strategy
        if (amount > request.remaining) {
            let excess = amount - request.remaining;
            deposit_internal(request.strategy, hot_asset::new(fungible_asset::extract(&mut asset, excess)));
        };

        let amount = fungible_asset::amount(&asset);
        request.remaining = request.remaining - amount;
        request.debt_offset = request.debt_offset + amount;

        fungible_asset::merge(&mut request.withdrawn, asset);
    }

    public fun apply_coin_withdrawal<C>(request: &mut WithdrawalRequest, hot_coin: HotCoin<C>) acquires BaseStrategy {
        let asset = coin::coin_to_fungible_asset(hot_coin::destroy(hot_coin));
        apply_fa_withdrawal(request, hot_asset::new(asset));
    }

    fun complete_withdrawal_internal(
        request: WithdrawalRequest, max_loss: Option<u64>
    ): (FungibleAsset, Option<address>) acquires BaseStrategy, BaseStrategyController {
        let WithdrawalRequest { remaining, strategy, to_withdraw, to_burn, withdrawn, debt_offset, account } = request;
        let strategy_mut = borrow_strategy_mut(&strategy);

        // Anything left in `remaining` is regarded as loss.
        if (option::is_some(&max_loss)) {
            let max_loss = option::destroy_some(max_loss);
            let max_loss_value = math64::mul_div(max_loss, to_withdraw, constants::bps_max());
            assert!(remaining <= max_loss_value, ETOO_MUCH_LOSS);
        };

        let total_offset = remaining + debt_offset;
        assert!(strategy_mut.total_debt >= total_offset, EINSUFFICIENT_DEBT);
        strategy_mut.total_debt = strategy_mut.total_debt - total_offset;

        let strategy_controller = borrow_strategy_controller(&strategy);
        let strategy_signer = object::generate_signer_for_extending(&strategy_controller.extend_ref);

        // Ensure invariants are maintained
        assert!(
            remaining + fungible_asset::amount(&withdrawn) == to_withdraw,
            EINVARIANT_VIOLATION
        );

        asset::safe_burn(&strategy_signer, to_burn);
        (withdrawn, account)
    }

    public fun complete_withdrawal(
        request: WithdrawalRequest, max_loss: Option<u64>
    ): HotAsset acquires BaseStrategy, BaseStrategyController {
        let (withdrawn, account) = complete_withdrawal_internal(request, max_loss);
        if (option::is_some(&account)) {
            let account_address = option::destroy_some(account);
            hot_asset::new_with_recipient(withdrawn, account_address)
        } else {
            hot_asset::new(withdrawn)
        }
    }

    public fun complete_withdrawal_coin<C>(
        request: WithdrawalRequest, max_loss: Option<u64>
    ): HotCoin<C> acquires BaseStrategy, BaseStrategyController {
        let strategy = request.strategy;
        let (withdrawn, account) = complete_withdrawal_internal(request, max_loss);
        let asset_metadata = fungible_asset::asset_metadata(&withdrawn);
        assert!(
            option::destroy_some(coin::paired_metadata<C>()) == asset_metadata,
            EASSET_METADATA_MISMATCH
        );

        // We cannot convert the asset to a coin directly here because aptos doesn't allow it.
        // So, we need to deposit the asset into the strategy primary store and then withdraw the coin.

        let amount = fungible_asset::amount(&withdrawn);
        let strategy_address = object::object_address(&strategy);
        let strategy_signer = object::generate_signer_for_extending(
            &borrow_strategy_controller(&strategy).extend_ref
        );
        primary_store_deposit(strategy_address, withdrawn);

        let coin = coin::withdraw<C>(&strategy_signer, amount);
        if (option::is_some(&account)) {
            let account_address = option::destroy_some(account);
            hot_coin::new_with_recipient(coin, account_address)
        } else {
            hot_coin::new(coin)
        }
    }

    public fun request_harvest(account: &signer, auth_ref: &AuthRef): HarvestRequest acquires BaseStrategy {
        let strategy = auth_ref.strategy;
        let strategy_ref = borrow_strategy(&strategy);
        let account_address = signer::address_of(account);
        let router_address_maybe = protocol::get_router();

        if (option::is_some(&router_address_maybe)) {
            let router_address = option::destroy_some(router_address_maybe);
            assert!(
                account_address == strategy_ref.manager || account_address == router_address,
                ENOT_AUTHORIZED
            );
        } else {
            assert!(account_address == strategy_ref.manager, ENOT_AUTHORIZED);
        };

        HarvestRequest { strategy, profit: 0, loss: 0 }
    }

    public fun report_harvest_profit(
        request: &mut HarvestRequest, auth_ref: &AuthRef, amount: u64
    ) {
        assert!(auth_ref.strategy == request.strategy, ENOT_AUTHORIZED);
        request.profit = request.profit + amount;
    }

    public fun report_harvest_loss(
        request: &mut HarvestRequest, auth_ref: &AuthRef, amount: u64
    ) acquires BaseStrategy {
        assert!(auth_ref.strategy == request.strategy, ENOT_AUTHORIZED);

        let strategy_ref = borrow_strategy(&request.strategy);
        request.loss = request.loss + amount;
        assert!(strategy_ref.total_debt >= request.loss, EINSUFFICIENT_DEBT);
    }

    public fun complete_harvest(request: HarvestRequest) acquires BaseStrategy, BaseStrategyController {
        let HarvestRequest { strategy, profit, loss } = request;

        /*
        Since we handle claiming of rewards during harvest, it is possible to have both profit and loss.
        This can happen when:
          - Claiming rewards results in new assets (profit).
          - And at the same time, the underlying protocol or strategy adjustments reduce the total value of managed assets (loss).

        To handle this:
          1. If the profit is greater than the loss:
             - The net profit is calculated as `profit - loss`.
             - The loss is reset to 0 since it is fully offset by the profit.

          2. If the loss is greater than the profit:
             - The net loss is calculated as `loss - profit`.
             - The profit is reset to 0 since it is fully offset by the loss.
        */

        if (profit > loss) {
            profit = profit - loss;
            loss = 0;
        } else if (loss > profit) {
            loss = loss - profit;
            profit = 0;
        } else {
            // When profit == loss, both are effectively canceled out.
            profit = 0;
            loss = 0;
        };

        let strategy_mut = borrow_strategy_mut(&strategy);
        let strategy_controller_ref = borrow_strategy_controller(&strategy);
        let strategy_signer = object::generate_signer_for_extending(&strategy_controller_ref.extend_ref);

        let (net_profit, locked_profit) = (0, get_locked_profit(strategy_mut));

        if (loss > 0) {
            assert!(strategy_mut.total_debt >= loss, EINSUFFICIENT_DEBT);
            strategy_mut.total_debt = strategy_mut.total_debt - loss;
        } else if (profit > 0) {
            let (protocol_fee, manager_fee) = get_fee_amounts(strategy_mut, profit);
            let total_fee = protocol_fee + manager_fee;

            if (protocol_fee > 0) {
                let recipient = protocol::get_protocol_fee_recipient();
                let protocol_fee_shares = convert_amount_to_shares(strategy_mut, protocol_fee);

                let protocol_fee_asset =
                    asset::safe_mint(
                        &strategy_signer,
                        strategy_mut.shares_metadata,
                        protocol_fee_shares
                    );
                primary_fungible_store::deposit(recipient, protocol_fee_asset);
            };

            if (manager_fee > 0) {
                let manager_fee_shares = convert_amount_to_shares(strategy_mut, manager_fee);
                let manager_fee_asset =
                    asset::safe_mint(
                        &strategy_signer,
                        strategy_mut.shares_metadata,
                        manager_fee_shares
                    );
                primary_fungible_store::deposit(strategy_mut.manager, manager_fee_asset);
            };

            strategy_mut.total_debt = strategy_mut.total_debt + profit;
            net_profit = profit - total_fee;
        };

        let new_locked = locked_profit + net_profit;
        if (new_locked > loss) {
            strategy_mut.total_locked = new_locked - loss;
        } else {
            strategy_mut.total_locked = 0;
        };

        strategy_mut.last_harvest = timestamp::now_seconds();
    }

    public fun tend_fa(account: &signer, auth_ref: &AuthRef): HotAsset acquires BaseStrategyController, BaseStrategy {
        let strategy = auth_ref.strategy;
        let amount = tend_internal(account, strategy);

        let strategy_ref = borrow_strategy(&strategy);
        let strategy_controller_ref = borrow_strategy_controller(&strategy);
        let strategy_signer = object::generate_signer_for_extending(&strategy_controller_ref.extend_ref);

        hot_asset::new(primary_store_withdraw(&strategy_signer, strategy_ref.base_metadata, amount))
    }

    public fun tend_coin<C>(account: &signer, auth_ref: &AuthRef): HotCoin<C> acquires BaseStrategy, BaseStrategyController {
        let strategy = auth_ref.strategy;
        let amount = tend_internal(account, strategy);

        let strategy_ref = borrow_strategy(&strategy);
        let strategy_controller_ref = borrow_strategy_controller(&strategy);
        let strategy_signer = object::generate_signer_for_extending(&strategy_controller_ref.extend_ref);
        assert!(
            option::destroy_some(coin::paired_metadata<C>()) == strategy_ref.base_metadata,
            EASSET_METADATA_MISMATCH
        );

        hot_coin::new(coin::withdraw<C>(&strategy_signer, amount))
    }

    public fun sweep(
        account: &signer,
        strategy: Object<BaseStrategy>,
        metadata: Object<Metadata>,
        amount: u64
    ) acquires BaseStrategy, BaseStrategyController {
        let account_address = signer::address_of(account);
        let strategy_ref = borrow_strategy(&strategy);

        assert!(
            protocol::is_governance(account_address) || strategy_ref.manager == account_address,
            ENOT_AUTHORIZED
        );
        assert!(metadata != strategy_ref.base_metadata, ECANNOT_SWEEP_BASE_ASSET);

        let strategy_address = object::object_address(&strategy);
        assert!(
            primary_fungible_store::is_balance_at_least(strategy_address, metadata, amount),
            EINVALID_AMOUNT
        );

        let strategy_controller = borrow_strategy_controller(&strategy);
        let strategy_signer = object::generate_signer_for_extending(&strategy_controller.extend_ref);
        primary_fungible_store::transfer(
            &strategy_signer,
            metadata,
            protocol::get_governance(),
            amount
        );
    }

    /// Rebalances the idle assets in a strategy by comparing the current total idle balance with the available balance in the
    /// primary store. If the total idle assets in the strategy are less than the available balance, it adjusts the
    /// total_idle balance accordingly.
    ///
    /// Only authorized users (governance or strategy manager) can call this function.
    ///
    /// @param account The signer performing the rebalance operation. Must be either governance or the strategy manager.
    /// @param strategy The strategy object to rebalance the idle assets for.
    ///
    /// @reverts ENOT_AUTHORIZED Thrown if the caller is not authorized to perform the operation (not governance or strategy manager).
    public fun rebalance_idle(account: &signer, strategy: Object<BaseStrategy>) acquires BaseStrategy {
        let account_address = signer::address_of(account);
        let strategy_mut = borrow_strategy_mut(&strategy);
        let strategy_address = object::object_address(&strategy);

        assert!(
            protocol::is_governance(account_address) || strategy_mut.manager == account_address,
            ENOT_AUTHORIZED
        );
        strategy_mut.total_idle = primary_store_balance(strategy_address, strategy_mut.base_metadata);
    }

    public(friend) fun update_manager(
        account: &signer, strategy: Object<BaseStrategy>, manager: address
    ) acquires BaseStrategy {
        let account_address = signer::address_of(account);
        assert!(protocol::is_governance(account_address), ENOT_AUTHORIZED);

        let strategy_mut = borrow_strategy_mut(&strategy);
        strategy_mut.manager = manager;
    }

    public(friend) fun new_state(debt_limit: u64): BaseStrategyState {
        BaseStrategyState {
            debt_limit,
            total_loss: 0,
            total_profit: 0,
            current_debt: 0,
            last_report: timestamp::now_seconds()
        }
    }

    public(friend) fun destroy_state(state: BaseStrategyState) {
        let BaseStrategyState { debt_limit: _, current_debt: _, last_report: _, total_profit: _, total_loss: _ } =
            state;
    }

    public(friend) fun set_debt_limit(state: &mut BaseStrategyState, debt_limit: u64) {
        state.debt_limit = debt_limit;
    }

    public(friend) fun set_current_debt(state: &mut BaseStrategyState, current_debt: u64) {
        state.current_debt = current_debt;
    }

    public(friend) fun set_total_loss(state: &mut BaseStrategyState, total_loss: u64) {
        state.total_loss = total_loss;
    }

    public(friend) fun set_total_profit(state: &mut BaseStrategyState, total_profit: u64) {
        state.total_profit = total_profit;
    }

    public(friend) fun set_last_report(state: &mut BaseStrategyState) {
        state.last_report = timestamp::now_seconds();
    }

    // ========== Public Functions ==========

    public fun withdrawal_amount(request: &WithdrawalRequest): u64 {
        request.to_withdraw
    }

    public fun withdrawal_remaining(request: &WithdrawalRequest): u64 {
        request.remaining
    }

    public fun withdrawal_strategy(request: &WithdrawalRequest): Object<BaseStrategy> {
        request.strategy
    }

    public fun withdrawal_to_burn(request: &WithdrawalRequest): &FungibleAsset {
        &request.to_burn
    }

    public fun withdrawal_withdrawn(request: &WithdrawalRequest): &FungibleAsset {
        &request.withdrawn
    }

    public fun withdrawal_debt_offset(request: &WithdrawalRequest): u64 {
        request.debt_offset
    }

    public fun harvest_strategy(request: &HarvestRequest): Object<BaseStrategy> {
        request.strategy
    }

    public fun harvest_profit(request: &HarvestRequest): u64 {
        request.profit
    }

    public fun harvest_loss(request: &HarvestRequest): u64 {
        request.loss
    }

    public fun get_total_assets(strategy: &BaseStrategy): u64 {
        strategy.total_idle + strategy.total_debt
    }

    public fun get_free_funds(strategy: &BaseStrategy): u64 {
        let total_assets = get_total_assets(strategy);
        if (total_assets == 0) return 0;

        total_assets - get_locked_profit(strategy)
    }

    public fun get_total_shares(strategy: &BaseStrategy): u64 {
        let supply = fungible_asset::supply(strategy.shares_metadata);
        (option::destroy_with_default(supply, 0) as u64)
    }

    public fun get_signer(auth_ref: &AuthRef): signer acquires BaseStrategyController {
        let strategy = auth_ref_strategy(auth_ref);
        object::generate_signer_for_extending(&borrow_strategy_controller(&strategy).extend_ref)
    }

    fun convert_amount_to_shares(strategy: &BaseStrategy, amount: u64): u64 {
        let free_funds = get_free_funds(strategy);
        let total_shares = get_total_shares(strategy);

        if (free_funds == 0 || total_shares == 0 || amount == 0) { amount }
        else {
            math64::mul_div(amount, total_shares, free_funds)
        }
    }

    fun convert_shares_to_amount(strategy: &BaseStrategy, shares: u64): u64 {
        let free_funds = get_free_funds(strategy);
        let total_shares = get_total_shares(strategy);

        math64::mul_div(shares, free_funds, total_shares)
    }

    public fun get_locked_profit(strategy: &BaseStrategy): u64 {
        let elapsed_time = timestamp::now_seconds() - strategy.last_harvest;
        if (elapsed_time >= strategy.lock_duration || strategy.total_locked == 0) {
            return 0
        };

        let time_remaining = strategy.lock_duration - elapsed_time;
        (((strategy.total_locked as u128) * (time_remaining as u128) / (strategy.lock_duration as u128)) as u64)
    }

    /// Calculates the fee shares for the given profit.
    ///
    /// @param strategy The strategy to be updated.
    /// @param profit The profit to be used to calculate the fee shares.
    ///
    /// @return The tuple of (protocol fee shares, manager fee shares).
    public fun get_fee_amounts(strategy: &BaseStrategy, profit: u64): (u64, u64) {
        if (profit == 0) return (0, 0);

        let default_performance_fee_bps = protocol::get_performance_fee();
        let performance_fee_bps = option::destroy_with_default(strategy.performance_fee, default_performance_fee_bps);

        let bps_max = constants::bps_max();
        let fee_amount = math64::mul_div(profit, performance_fee_bps, bps_max);
        if (fee_amount == 0) return (0, 0);

        let protocol_fee_bps = protocol::get_protocol_fee();
        if (protocol_fee_bps > 0) {
            let protocol_fee = math64::mul_div(fee_amount, protocol_fee_bps, bps_max);
            return (protocol_fee, fee_amount - protocol_fee)
        };

        (0, fee_amount)
    }

    // ========== BaseStrategy State Functions =========

    public fun get_debt_limit(state: &BaseStrategyState): u64 {
        state.debt_limit
    }

    public fun get_current_debt(state: &BaseStrategyState): u64 {
        state.current_debt
    }

    public fun get_last_report(state: &BaseStrategyState): u64 {
        state.last_report
    }

    public fun get_total_loss(state: &BaseStrategyState): u64 {
        state.total_loss
    }

    public fun get_total_profit(state: &BaseStrategyState): u64 {
        state.total_profit
    }

    #[view]
    public fun base_strategy_view(strategy: Object<BaseStrategy>): BaseStrategyView acquires BaseStrategy {
        let strategy_ref = borrow_strategy(&strategy);

        let total_asset = get_total_assets(strategy_ref);
        let total_shares = get_total_shares(strategy_ref);
        let strategy_address = object::object_address(&strategy);
        let decimals = fungible_asset::decimals(strategy_ref.base_metadata);
        let asset_address = object::object_address(&strategy_ref.base_metadata);
        let shares_address = object::object_address(&strategy_ref.shares_metadata);

        BaseStrategyView {
            decimals,
            total_shares,
            total_asset,
            asset_address,
            shares_address,
            strategy_address,
            total_debt: strategy_ref.total_debt,
            total_idle: strategy_ref.total_idle,
            concrete_address: strategy_ref.concrete_address
        }
    }

    public(friend) fun vault_base_strategy_view(
        strategy: Object<BaseStrategy>, state: &BaseStrategyState, vault_address: address
    ): VaultBaseStrategyView acquires BaseStrategy {
        let strategy_ref = borrow_strategy(&strategy);
        let total_asset = get_total_assets(strategy_ref);
        let total_shares = get_total_shares(strategy_ref);
        let strategy_address = object::object_address(&strategy);
        let decimals = fungible_asset::decimals(strategy_ref.base_metadata);
        let asset_address = object::object_address(&strategy_ref.base_metadata);
        let shares_address = object::object_address(&strategy_ref.shares_metadata);

        VaultBaseStrategyView {
            decimals,
            total_shares,
            total_asset,
            asset_address,
            vault_address,
            shares_address,
            strategy_address,
            debt_limit: state.debt_limit,
            total_loss: state.total_loss,
            last_report: state.last_report,
            total_profit: state.total_profit,
            total_debt: strategy_ref.total_debt,
            total_idle: strategy_ref.total_idle,
            current_vault_debt: state.current_debt,
            concrete_address: strategy_ref.concrete_address
        }
    }

    // ========== Helper Functions ==========

    inline fun borrow_strategy(strategy: &Object<BaseStrategy>): &BaseStrategy acquires BaseStrategy {
        borrow_global<BaseStrategy>(object::object_address(strategy))
    }

    inline fun borrow_strategy_mut(strategy: &Object<BaseStrategy>): &mut BaseStrategy acquires BaseStrategy {
        borrow_global_mut<BaseStrategy>(object::object_address(strategy))
    }

    inline fun borrow_strategy_controller(
        strategy: &Object<BaseStrategy>
    ): &BaseStrategyController acquires BaseStrategyController {
        borrow_global<BaseStrategyController>(object::object_address(strategy))
    }

    inline fun borrow_strategy_controller_mut(
        strategy: &Object<BaseStrategy>
    ): &mut BaseStrategyController acquires BaseStrategyController {
        borrow_global_mut<BaseStrategyController>(object::object_address(strategy))
    }

    // ========== View Functions =========

    #[view]
    public fun base_metadata(strategy: Object<BaseStrategy>): Object<Metadata> acquires BaseStrategy {
        borrow_strategy(&strategy).base_metadata
    }

    #[view]
    public fun shares_metadata(strategy: Object<BaseStrategy>): Object<Metadata> acquires BaseStrategy {
        borrow_strategy(&strategy).shares_metadata
    }

    #[view]
    public fun shares_to_amount(strategy: Object<BaseStrategy>, shares: u64): u64 acquires BaseStrategy {
        convert_shares_to_amount(borrow_strategy(&strategy), shares)
    }

    #[view]
    public fun amount_to_shares(strategy: Object<BaseStrategy>, amount: u64): u64 acquires BaseStrategy {
        convert_amount_to_shares(borrow_strategy(&strategy), amount)
    }

    #[view]
    public fun manager(strategy: Object<BaseStrategy>): address acquires BaseStrategy {
        borrow_strategy(&strategy).manager
    }

    #[view]
    public fun total_debt(strategy: Object<BaseStrategy>): u64 acquires BaseStrategy {
        borrow_strategy(&strategy).total_debt
    }

    #[view]
    public fun total_idle(strategy: Object<BaseStrategy>): u64 acquires BaseStrategy {
        borrow_strategy(&strategy).total_idle
    }

    #[view]
    public fun total_locked(strategy: Object<BaseStrategy>): u64 acquires BaseStrategy {
        borrow_strategy(&strategy).total_locked
    }

    #[view]
    public fun total_assets(strategy: Object<BaseStrategy>): u64 acquires BaseStrategy {
        get_total_assets(borrow_strategy(&strategy))
    }

    #[view]
    public fun last_harvest(strategy: Object<BaseStrategy>): u64 acquires BaseStrategy {
        borrow_strategy(&strategy).last_harvest
    }

    #[view]
    public fun performance_fee(strategy: Object<BaseStrategy>): Option<u64> acquires BaseStrategy {
        borrow_strategy(&strategy).performance_fee
    }

    #[view]
    public fun lock_duration(strategy: Object<BaseStrategy>): u64 acquires BaseStrategy {
        borrow_strategy(&strategy).lock_duration
    }

    #[view]
    public fun fee_amounts(strategy: Object<BaseStrategy>, profit: u64): (u64, u64) acquires BaseStrategy {
        get_fee_amounts(borrow_strategy(&strategy), profit)
    }

    #[view]
    public fun concrete_address(strategy: Object<BaseStrategy>): address acquires BaseStrategy {
        borrow_strategy(&strategy).concrete_address
    }

    #[view]
    public fun total_shares(strategy: Object<BaseStrategy>): u64 acquires BaseStrategy {
        get_total_shares(borrow_strategy(&strategy))
    }

    public fun auth_ref_strategy(auth_ref: &AuthRef): Object<BaseStrategy> {
        auth_ref.strategy
    }

    // ========== Private functions =========

    fun create_internal(
        constructor_ref: &ConstructorRef,
        manager: address,
        base_metadata: Object<Metadata>,
        shares_metadata: Object<Metadata>,
        concrete_address: address
    ): (BaseStrategy, BaseStrategyController) {
        let strategy = BaseStrategy {
            manager,
            total_debt: 0,
            total_idle: 0,
            base_metadata,
            shares_metadata,
            total_locked: 0,
            performance_fee: option::none(),
            last_harvest: timestamp::now_seconds(),
            lock_duration: constants::default_lock_duration(),
            concrete_address: concrete_address
        };

        let extend_ref = object::generate_extend_ref(constructor_ref);
        let transfer_ref = object::generate_transfer_ref(constructor_ref);
        object::disable_ungated_transfer(&transfer_ref);
        (strategy, BaseStrategyController { extend_ref })
    }

    fun tend_internal(account: &signer, strategy: Object<BaseStrategy>): u64 acquires BaseStrategy {
        let strategy_mut = borrow_strategy_mut(&strategy);
        assert!(strategy_mut.manager == signer::address_of(account), ENOT_AUTHORIZED);

        let strategy_address = object::object_address(&strategy);
        assert!(
            primary_store_balance(strategy_address, strategy_mut.base_metadata) >= strategy_mut.total_idle,
            EINSUFFICIENT_IDLE_BALANCE
        );

        // we tend the entire idle balance
        let amount = strategy_mut.total_idle;
        strategy_mut.total_idle = 0;
        strategy_mut.total_debt = strategy_mut.total_debt + amount;

        amount
    }

    fun deposit_internal(strategy: Object<BaseStrategy>, hot_asset: HotAsset) acquires BaseStrategy {
        let asset = hot_asset::destroy(hot_asset);
        let deposit_amount = fungible_asset::amount(&asset);
        let strategy_mut = borrow_strategy_mut(&strategy);
        let strategy_address = object::object_address(&strategy);

        primary_store_deposit(strategy_address, asset);
        strategy_mut.total_idle = strategy_mut.total_idle + deposit_amount;
    }

    fun create_shares_asset(strategy_signer: &signer, base_metadata: Object<Metadata>): Object<Metadata> {
        let name = utf8(b"SS "); // e.g "SS Circle", "SS Bitcoin"
        string::append(&mut name, fungible_asset::name(base_metadata));

        // strategy shares symbols are prefixed with "ss" e.g ssBTC, ssETH
        let symbol = utf8(b"ss");
        string::append(&mut symbol, fungible_asset::symbol(base_metadata));

        let decimals = fungible_asset::decimals(base_metadata);

        asset::create(
            strategy_signer,
            name,
            symbol,
            decimals,
            utf8(
                b"https://raw.githubusercontent.com/Canopyxyz/canopy-assets/master/icons/canopy_vault.svg"
            ),
            utf8(b"https://www.canopyhub.xyz")
        )
    }

    fun mint_shares_for_amount(
        strategy: &mut BaseStrategy, controller: &BaseStrategyController, amount: u64
    ): FungibleAsset {
        let shares_amount = convert_amount_to_shares(strategy, amount);

        let strategy_signer = object::generate_signer_for_extending(&controller.extend_ref);
        asset::safe_mint(&strategy_signer, strategy.shares_metadata, shares_amount)
    }

    fun mint_debt_shares_internal(
        strategy: Object<BaseStrategy>, amount: u64
    ): FungibleAsset acquires BaseStrategyController, BaseStrategy {
        let strategy_mut = borrow_strategy_mut(&strategy);
        let strategy_controller = borrow_strategy_controller(&strategy);

        let shares = mint_shares_for_amount(strategy_mut, strategy_controller, amount);
        strategy_mut.total_debt = strategy_mut.total_debt + amount;
        shares
    }

    #[test_only]
    public fun auth_ref_for_test(strategy: Object<BaseStrategy>): AuthRef {
        AuthRef { strategy }
    }
}

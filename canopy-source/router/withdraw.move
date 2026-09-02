module satay_router::withdraw {
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
    use satay::hot_asset::HotAsset;
    use satay::hot_coin::HotCoin;
    use satay::vault::{Self, Vault, WithdrawalRequest};

    friend satay_router::router;

    const EUNKNOWN_STRATEGY: u64 = 0;

    public(friend) fun withdraw_coin<CoinType>(
        account: &signer,
        request: &mut WithdrawalRequest,
        strategy: Object<BaseStrategy>,
        packet: Option<vector<u8>>,
        amount: u64,
        max_loss: Option<u64>
    ): HotCoin<CoinType> {
        let concrete_address = base_strategy::concrete_address(strategy);
        if (concrete_address == @echelon_simple) {
            return echelon_simple::vault_withdraw_coin<CoinType>(account, request, strategy, amount, max_loss)
        } else if (concrete_address == @moveposition_simple) {
            let packet = option::destroy_some(packet);
            return moveposition_simple::vault_withdraw_coin<CoinType>(
                account, request, strategy, packet, amount, max_loss
            )
        } else if (concrete_address == @placeholder_simple) {
            return placeholder_simple::vault_withdraw_coin<CoinType>(account, request, strategy, amount, max_loss)
        };

        abort EUNKNOWN_STRATEGY
    }

    public(friend) fun withdraw_fa(
        account: &signer,
        request: &mut WithdrawalRequest,
        strategy: Object<BaseStrategy>,
        packet: Option<vector<u8>>,
        amount: u64,
        max_loss: Option<u64>
    ): HotAsset {
        let concrete_address = base_strategy::concrete_address(strategy);
        if (concrete_address == @echelon_simple) {
            return echelon_simple::vault_withdraw_fa(account, request, strategy, amount, max_loss)
        } else if (concrete_address == @moveposition_simple) {
            let packet = option::destroy_some(packet);
            return moveposition_simple::vault_withdraw_fa(account, request, strategy, packet, amount, max_loss)
        } else if (concrete_address == @layerbank_simple) {
            return layerbank_simple::vault_withdraw_fa(account, request, strategy, amount, max_loss)
        } else if (concrete_address == @placeholder_simple) {
            return placeholder_simple::vault_withdraw_fa(account, request, strategy, amount, max_loss)
        };

        abort EUNKNOWN_STRATEGY
    }

    public(friend) fun withdraw_fa_with_coin_type<CoinType>(
        account: &signer,
        request: &mut WithdrawalRequest,
        strategy: Object<BaseStrategy>,
        packet: Option<vector<u8>>,
        amount: u64,
        max_loss: Option<u64>
    ): HotAsset {
        let concrete_address = base_strategy::concrete_address(strategy);
        if (concrete_address == @echelon_simple) {
            return echelon_simple::vault_withdraw_fa(account, request, strategy, amount, max_loss)
        } else if (concrete_address == @moveposition_simple) {
            let packet = option::destroy_some(packet);
            return moveposition_simple::vault_withdraw_fa(account, request, strategy, packet, amount, max_loss)
        } else if (concrete_address == @layerbank_simple) {
            return layerbank_simple::vault_withdraw_fa(account, request, strategy, amount, max_loss)
        } else if (concrete_address == @meridian_rewards) {
            return meridian_rewards::vault_withdraw_fa<CoinType>(account, request, strategy, amount, max_loss)
        } else if (concrete_address == @placeholder_simple) {
            return placeholder_simple::vault_withdraw_fa(account, request, strategy, amount, max_loss)
        };

        abort EUNKNOWN_STRATEGY
    }

    public(friend) fun get_withdrawal_map(vault: Object<Vault>, request: &WithdrawalRequest):
        SimpleMap<Object<BaseStrategy>, u64> {
        let withdrawal_map = simple_map::new<Object<BaseStrategy>, u64>();
        let remaining = vault::withdrawal_remaining(request);
        if (remaining > 0) {
            let strategies = vault::vault_strategies(vault);

            // Withdraw from strategies that are over their limit
            let (remaining, total_strategies_debt) = over_cap_withdrawal(
                remaining, vault, strategies, &mut withdrawal_map
            );

            // If there's still some left, withdraw from the strategies proportionally to their debt
            if (remaining > 0 && total_strategies_debt > 0) {
                proportional_withdrawal(
                    remaining,
                    total_strategies_debt,
                    vault,
                    strategies,
                    &mut withdrawal_map
                )
            }
        };

        withdrawal_map
    }

    #[view]
    public fun get_withdrawal_map_view(vault: Object<Vault>, shares: u64): SimpleMap<Object<BaseStrategy>, u64> {
        let withdrawal_map = simple_map::new();
        let to_withdraw = vault::shares_to_amount(vault, shares);
        let withdrawable = math64::min(to_withdraw, vault::total_idle(vault));

        let remaining = to_withdraw - withdrawable;
        if (remaining == 0) return withdrawal_map;

        let strategies = vault::vault_strategies(vault);
        let (remaining, total_strategies_debt) = over_cap_withdrawal(remaining, vault, strategies, &mut withdrawal_map);
        if (remaining > 0 && total_strategies_debt > 0) {
            proportional_withdrawal(
                remaining,
                total_strategies_debt,
                vault,
                strategies,
                &mut withdrawal_map
            )
        };

        return withdrawal_map
    }

    fun over_cap_withdrawal(
        remaining: u64,
        vault: Object<Vault>,
        strategies: vector<Object<BaseStrategy>>,
        withdrawal_map: &mut SimpleMap<Object<BaseStrategy>, u64>
    ): (u64, u64) {
        if (remaining == 0) return (0, 0);

        let total_strategies_debt = 0;
        let remaining_amount = remaining;

        vector::for_each(
            strategies,
            |strategy| {
                let strategy_debt = vault::strategy_debt(vault, strategy);
                let strategy_debt_limit = vault::strategy_debt_limit(vault, strategy);

                if (strategy_debt > strategy_debt_limit) {
                    let amount = strategy_debt - strategy_debt_limit;
                    let to_withdraw = math64::min(amount, remaining_amount);

                    if (simple_map::contains_key(withdrawal_map, &strategy)) {
                        let withdrawal = simple_map::borrow_mut(withdrawal_map, &strategy);
                        *withdrawal = *withdrawal + to_withdraw;
                    } else {
                        simple_map::add(withdrawal_map, strategy, to_withdraw);
                    };

                    remaining_amount = remaining_amount - to_withdraw;
                    total_strategies_debt = total_strategies_debt + (strategy_debt - to_withdraw);
                } else {
                    total_strategies_debt = total_strategies_debt + strategy_debt;
                }
            }
        );

        return (remaining, total_strategies_debt)
    }

    fun proportional_withdrawal(
        remaining: u64,
        total_strategies_debt: u64,
        vault: Object<Vault>,
        strategies: vector<Object<BaseStrategy>>,
        withdrawal_map: &mut SimpleMap<Object<BaseStrategy>, u64>
    ) {
        vector::for_each(
            strategies,
            |strategy| {
                let strategy_debt =
                    if (simple_map::contains_key(withdrawal_map, &strategy)) {
                        let strategy_debt = vault::strategy_debt(vault, strategy);
                        strategy_debt - *simple_map::borrow(withdrawal_map, &strategy)
                    } else {
                        vault::strategy_debt(vault, strategy)
                    };

                let amount = math64::mul_div(remaining, strategy_debt, total_strategies_debt);

                if (simple_map::contains_key(withdrawal_map, &strategy)) {
                    let withdrawal = simple_map::borrow_mut(withdrawal_map, &strategy);
                    *withdrawal = *withdrawal + amount;
                } else {
                    simple_map::add(withdrawal_map, strategy, amount);
                };
            }
        );
    }
}

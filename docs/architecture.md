# Canopy — Architecture Notes

Canopy is a yield aggregator on Movement. Its Move contracts are in a private repository,
but every package was published on-chain **with source attached**, so the implementation is
readable and checkable by anyone. These notes are written against that source.

```bash
python3 tools/fetch-canopy-source.py     # writes ./canopy-source/ (gitignored)
```

Citations are `package/file.move:line`, against source fetched 2026-08-20 from Movement
mainnet (chainId 126). Line numbers shift when a package is upgraded; module and function
names are the stable reference. Addresses and per-module ABI counts are in
[`reference.md`](reference.md).

**Scope.** Core, router, blocks, strategies, rewards, helpers, views — the 18 packages the
fetch tool pulls. The Meridian ALM packages are listed in `reference.md` but not analyzed
here; two of them were published without source at all.

---

## 1. What keeps a strategy out of vault accounting

Strategies live in separate packages at separate addresses from the core vault. Move's
`friend` mechanism cannot reach across that boundary — every `friend` declaration in the
system names a module at the *same* address (`core/vault.move:35`,
`core/base_strategy.move:25-26`, `core/hot_asset.move:20-22`, `router/auth.move:7-10`). So
`friend` organizes module visibility inside a package and does nothing at the boundary that
matters. Three other mechanisms do the real work.

**Identity — a one-time witness.** Registration goes through:

```move
public fun create<T: drop>(account: &signer, base_metadata: Object<Metadata>, _witness: T): AuthRef
```

`core/base_strategy.move:186`. The witness value is thrown away; only its type is read:

```move
let witness = type_info::type_of<T>();
let concrete_address = type_info::account_address(&witness);
```

`core/base_strategy.move:190-191`. Since only the declaring module can construct a value of
its own struct, passing `T` proves the caller *is* that module — and the strategy's
`concrete_address` is derived from the type rather than passed as an argument, so it can't
be spoofed. Each strategy declares `struct Witness has drop {}` and passes `Witness {}`
(e.g. `strategy-echelon-simple/strategy.move:33,110`). Conventional Aptos-Move, used
conventionally.

**Authority — a non-copyable `AuthRef`.** `create` returns:

```move
struct AuthRef has store, drop {
    strategy: Object<BaseStrategy>
}
```

`core/base_strategy.move:58`. `store` and `drop`, but **not `copy`** — holdable, not
duplicable — and the field is private to `base_strategy`. Every privileged core function
takes `&AuthRef` and reads its target *out of the ref* rather than from a caller-supplied
argument: `deposit` (`:213`), `mint_debt_shares_fa` (`:233`), `request_withdrawal` (`:286`),
`request_harvest` (`:425`), `get_signer` (`:721`). The pattern throughout is
`let strategy = auth_ref.strategy;`. A strategy therefore cannot name another strategy's
object — it can only act on the one its ref is bound to. Where a request and a ref are both
in play the binding is rechecked: `assert!(auth_ref.strategy == request.strategy, ENOT_AUTHORIZED)`
(`core/base_strategy.move:447`, `:454`).

This is the load-bearing mechanism. It makes "a strategy can only affect its own accounting
object" a property of the type system rather than a runtime check that could be missed.

**Custody — hot potatoes.** Assets crossing a package boundary are wrapped in `HotAsset`
(`core/hot_asset.move:32`), which declares **no abilities at all**: it cannot be stored,
copied, or dropped, so the compiler rejects any transaction that fails to consume it. A
strategy physically cannot retain funds handed to it. `WithdrawalRequest` (`:75`) and
`HarvestRequest` (`:93`) in `core/base_strategy.move` are ability-less for the same reason —
a withdrawal that opens must be driven to completion.

**At the venue edge — `BlockRef`.** Unwrapping a hot potato requires one:
`destroy_with_block_ref` (`core/hot_asset.move:135`), validated by
`protocol::is_valid_block_ref` (`core/protocol.move:311`). The only constructor is
`protocol::new_block_ref` (`core/protocol.move:296`), and block initialization is
governance-only and one-shot (`block-echelon/echelon_block.move:28`).

---

## 2. The deposit path, and why an empty vault is safe

### The trace

A fungible-asset deposit into the Echelon simple-lend strategy, end to end:

| # | Step | Where |
|---|---|---|
| 1 | Router entry; may auto-harvest/report first | `satay_router::router::deposit_fa`, `router/router.move:57` |
| 2 | Withdraw from depositor, wrap as `HotAsset` recording `owner` | `hot_asset::new_from_account`, `router/router.move:82` |
| 3 | Price shares, credit `total_idle`, emit `Deposit`, mint shares as a new potato | `vault::deposit` → `deposit_internal`, `core/vault.move:526`, `:1436` |
| 4 | Optional slippage assert, then deliver shares | `ENOT_ENOUGH_OUT_SHARES`, `router/router.move:84-89` |
| 5 | Split idle funds pro-rata across strategies by capacity | `deposit::deploy_fa_funds`, `router/deposit.move:95`, `:114` |
| 6 | Dispatch to the strategy by hardcoded address | `deposit::deposit_fa`, `router/deposit.move:57-67` |
| 7 | Draw allocation as vault debt, mint debt shares, return strategy shares to vault | `echelon_simple::strategy::vault_deposit_fa`, `strategy-echelon-simple/strategy.move:204` |
| 8 | Unwrap under `BlockRef`, call Echelon | `echelon_block::supply_fa`, `block-echelon/echelon_block.move:52-55` |

Two details in step 3 are deliberate. `deposit_internal` asserts the hot asset carries an
owner (`EINVALID_HOT_ASSET_OWNER`, `core/vault.move:1440`) and mints shares addressed to
that owner (`:1453-1454`) — the inline comment says this exists so shares cannot be retained
by the concrete strategy or an attacker. The block in step 8 is a thin translation layer:
unwrap, forward to Echelon's own `lending` module, hold no accounting of its own.

### First-deposit share pricing

```move
public fun convert_amount_to_shares(vault: &Vault, amount: u64): u64 {
    let free_funds = get_free_funds(vault);
    let total_shares = get_total_shares(vault);

    if (free_funds == 0 || total_shares == 0) {
        return amount
    };
    math64::mul_div(amount, (total_shares as u64), free_funds)
}
```

`core/vault.move:1105`. **The first deposit mints 1:1**, with no virtual shares, no decimal
offset, and no burned dead-shares seed — every conventional ERC-4626 inflation mitigation is
absent.

What makes that safe is the denominator (`core/vault.move:1101`):

```move
public fun get_total_assets(vault: &Vault): u64 {
    vault.total_idle + vault.total_debt
}
```

Share price comes from **internal accounting, never the live token balance**. The classic
donation attack — mint 1 share, transfer a large amount straight to the vault address, watch
the next depositor's `mul_div` round to zero — needs the donation to land in the denominator.
Here it doesn't. A direct transfer sits in the vault's primary store invisible to
`total_idle`, which moves only through explicit accounting writes.

The one function that resyncs to the real balance is `rebalance_idle`
(`core/vault.move:971`), gated to governance or the vault manager:

```move
assert!(
    protocol::is_governance(account_address) || vault_mut.manager == account_address,
    ENOT_AUTHORIZED
);
vault_mut.total_idle = primary_store_balance(vault_address, vault_mut.base_metadata);
```

So an attacker cannot trigger absorption of their own donation. The attack is structurally
unavailable rather than priced out by a magic constant — cleaner than the virtual-offset
convention, at the cost of requiring every inflow to have an accounting path.

Worth stating plainly alongside it:

- Rounding truncates toward zero (`math64::mul_div`), so a depositor gets at most their exact
  share. Standard.
- The user-side guard, `min_shares_out`, is an opt-in `Option<u64>`; passing `none` waives
  slippage protection.
- A drained vault aborts on valuation rather than pricing at zero —
  `assert!(total_shares > 0 && free_funds > 0, EINVALID_SHARES_FACTORS)`, `core/vault.move:1119`.
- Profit releases linearly, not instantly: `get_locked_profit` (`core/vault.move:1128`)
  amortizes over `lock_duration` and `get_free_funds` (`core/vault.move:1140`) subtracts it,
  so a depositor arriving just after a harvest can't capture the whole step. This is the
  Yearn locked-profit degradation pattern. Note it returns `0` when the vault is paused
  (`:1129`), releasing locked profit immediately on pause.

### The tradeoff: static dispatch

Move has no dynamic dispatch, so the router resolves strategies by literal address comparison:

```move
if (concrete_address == @echelon_simple) {
    echelon_simple::vault_deposit_fa(&vault_signer, strategy, amount);
} else if (concrete_address == @moveposition_simple) { ...
```

`router/deposit.move:57-67`, same shape in `router/withdraw.move`. The consequence, stated
without dressing it up: **adding a strategy requires upgrading the router.** The router is
not generic over strategies; it enumerates them. That is why `SatayRouter` carries
`upgrade_number = 5`, joint-highest in the system. It is the price of an immutable core —
the extension point had to live somewhere upgradeable, and the router keeps it out of the
code that custodies funds.

One asymmetry in the deployed chain: `deposit_fa` matches four strategy addresses, while
`deposit_fa_with_coin_type` (`router/deposit.move:80-92`) matches those plus
`@meridian_rewards`, so the Meridian strategy is reachable only through the coin-type
variant. Halborn's SCA #2 reported a related issue (finding 8.2, marked addressed). Since
`meridian_rewards::strategy::vault_deposit_fa` is generic over `WrapperCoinType`, routing it
through the parameterized path is consistent with intent. I could not determine from source
alone whether the asymmetry is deliberate.

### Audit cross-check

Halborn reviewed this path twice — *Core Strategies* (Nov–Dec 2024: 14 findings, 0
critical/high, 4 medium) and the re-audit (Feb 2025: 11 findings, none medium or above).
Both PDFs are in [`../audits/`](../audits/).

Finding 7.2 is checkable against deployed source, and the result is more interesting than
"fixed". Halborn recommended replacing per-account ratio math with
`echelon_block::coins_to_shares`, which reads market-wide supply. The **FA path took the
fix** (`strategy-echelon-simple/strategy.move:809`). The **coin path retains the original
form** — `math64::mul_div(amount, account_shares, account_coins)` at `:801`. Both are in the
currently deployed `EchelonSimple`.

I record this as an observation, not a live defect: the coin path may be intentionally
vestigial, since the router migrates native coin balances to fungible stores
(`router/router.move:73-80`) and drives the FA path. Confirming that needs the private repo
— Halborn's remediation hash points at `Canopyxyz/satay-movement`, which is not public.

---

## 3. Which documented strategy is which package

`docs.canopyhub.xyz` describes strategies at product level; the SDK lists package addresses;
neither connects them. Built from module declarations, the router's dispatch chain, and the
docs pages.

| Documented strategy | Package | Move module | Block | Upgrades |
|---|---|---|---|---|
| Echelon Simple Lend | `EchelonSimple` | `echelon_simple::strategy` | `echelon_block` | 3 |
| Layerbank Lend | `LayerBankSimple` | `layerbank_simple::strategy` | `layerbank_block` | 5 |
| MovePosition Lend | `MovepositionSimple` | `moveposition_simple::strategy`, `::ticket` | `moveposition_block` | 2 |
| *(not user-facing)* | `MeridianRewards` | `meridian_rewards::strategy` | `meridian_farming_block` | 0 |
| *(vault placeholder)* | `PlaceholderSimple` | `placeholder_simple::strategy` | `placeholder_block` | 0 |

The three "Simple Lending" doc pages map cleanly onto the three lending packages — the
Echelon page documents `echelon_simple::strategy` by name and shows the same
`struct Witness has drop {}` as `strategy-echelon-simple/strategy.move:33`.

**Documented but not in the fetched packages:** Leveraged Liquid Staking and Borrow
Optimization have no counterpart among them. Single Sided Liquidity and Ascend most likely
live in the `alm.meridian.*` / Ichi vault packages — the docs describe single-token deposits
into concentrated liquidity, and Ascend's median-observation rebalancing is suggestive of
`medianStableV2` — but that package was **published without source**, so the mapping is not
verifiable on-chain and I am not asserting it. `LayerBankAirdropBlock` is a block with no
strategy pointing at it.

---

## 4. Withdrawal and harvest

Withdrawal inverts the deposit path but is request-driven. `request_withdrawal`
(`core/base_strategy.move:286`) returns an ability-less `WithdrawalRequest` the strategy
fills in stages (`strategy-echelon-simple/strategy.move:762`): idle assets are consumed
first, the venue is touched only for the shortfall via `withdrawal_remaining` /
`apply_fa_withdrawal`, then `complete_withdrawal` closes it with an optional `max_loss`.
Because the request has no abilities, a partial withdrawal cannot be abandoned mid-flight.

Harvest has the same shape — `request_harvest` (`:425`) returns a `HarvestRequest`, and
profit/loss are applied through functions that reassert the auth binding (`:445-455`).

Not analyzed in depth: fee assessment in `core/protocol.move`, the rewards system
(`rewards/multi_rewards.move`, 1774 lines), and the batchers.

---

## 5. The immutability boundary — and how often it moved

Policy values as the fetch tool reports them (`0` arbitrary, `1` compatible, `2` immutable):

| Package | Policy | Upgrades |
|---|---|---|
| `Satay` (core) | **immutable** | 0 |
| `MultiRewardsAptos` (rewards) | **immutable** | 2 |
| `SatayRouter` | compatible | **5** |
| `LayerBankSimple` | compatible | **5** |
| `EchelonSimple` | compatible | 3 |
| `MovepositionSimple` | compatible | 2 |
| `MeridianFarmingBlock` | compatible | 1 |
| `MultiRewardsBatcher`, `StdBatcher`, `CanopyHelpers` | compatible | 1 each |
| 5 remaining blocks, `PlaceholderSimple`, `MeridianRewards`, `CanopyViews` | compatible | 0 |

**Exactly two packages are immutable.** `Satay` — `asset`, `constants`, `protocol`,
`hot_asset`, `hot_coin`, `base_strategy`, `vault`, `satay` — and `MultiRewardsAptos`
(`multi_rewards`, `token_fa_wrapper`, `router`), frozen after two upgrades.

The per-venue **blocks are not immutable**. All six are `compatible`, and
`MeridianFarmingBlock` has already been upgraded once. The line that actually holds is around
vault share accounting, not around "core plus blocks". Earlier drafts of this repo claimed
otherwise and were wrong; the claim is corrected here against fetched data.

"Upgradeable" also means `compatible`, not `arbitrary` — no Canopy package uses policy `0`.
A compatible upgrade cannot change existing struct layouts or public function signatures, so
even the mutable half cannot silently redefine `BaseStrategy` or change what `deposit`
accepts.

### What would have required a migration

With `Satay` frozen, any change to the *shape* of core state is out of reach of an upgrade
and would mean deploying a new core package and migrating every vault and strategy object:

- Any field of `BaseStrategy` (`core/base_strategy.move:29`) or `Vault` — widening
  `total_idle` / `total_debt` from `u64`, or adding a field for a new accounting concept.
- Any public core signature, including `base_strategy::create` — the witness registration
  handshake is fixed permanently.
- Adding an ability to `HotAsset` or `AuthRef`.
- The share-pricing rule itself. The first-deposit 1:1 rule is frozen: if the
  internal-accounting property above were ever found insufficient, no upgrade could add a
  virtual offset to the deployed core.

### What the upgrade counts show

More interesting than the fact that flexibility existed is where it got used. Fourteen
upgrades across the fetched packages, landing exactly where the design predicted:

- **Router: 5.** A direct consequence of static dispatch — every strategy addition forces a
  router upgrade. Not churn in routing logic.
- **Strategies: 5 / 3 / 2.** Venue integrations absorbed the most change, which is the stated
  reason for leaving them upgradeable.
- **Blocks: 1 upgrade across six packages.** The adapter layer turned out nearly as stable as
  core. That makes the old "blocks are immutable" claim an understandable error — they barely
  moved — but they were never frozen, and freezing them would have cost almost nothing.
- **Core: 0.** The immutable core never needed to change, which is the bet the split was
  making.

`MultiRewardsAptos` is the sharpest case: two upgrades, *then* frozen. The rewards logic was
iterated until it settled and only then locked — freezing as a decision made after the fact,
not a constraint imposed up front.

---

## Verifying any of this

```bash
# upgrade policy and count for any package
curl -s https://mainnet.movementnetwork.xyz/v1/accounts/<address>/resource/0x1::code::PackageRegistry \
  | jq '.data.packages[] | {name, upgrade_policy, upgrade_number}'

# module ABI: exposed functions, entry/view flags, structs
curl -s https://mainnet.movementnetwork.xyz/v1/accounts/<address>/modules
```

Addresses are in [`reference.md`](reference.md). Source renders on the explorer at
`explorer.movementnetwork.xyz/object/{address}/modules/code/{module}`.

**Known gaps**, stated rather than papered over: the Meridian ALM packages are not fetched or
analyzed. `alm.meridian.registry` and `alm.meridian.strategies.medianStableV2` were published
with **no source** — ABIs only — which bounds §3. Test modules named in `friend` declarations
are stripped at publication. Halborn's remediation commits point at a private repository, so
findings can be checked against deployed source but not against diffs.

---

Sources: verified Move source from `0x1::code::PackageRegistry` on Movement mainnet; the
public `Canopyxyz/canopy-sdk` deployment registry; `docs.canopyhub.xyz`; published audits by
Halborn, MoveBit, and OtterSec. No private or post-acquisition material. Canopy's source
carries no license — publicly readable is not openly licensed, so it is quoted here in short
excerpts as commentary and `canopy-source/` is gitignored, never redistributed.

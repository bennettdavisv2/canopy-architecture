# Reference — addresses, modules, repositories

Companion tables for [`architecture.md`](architecture.md). Everything here is drawn from
public sources: the deployment registry in the open `canopy-sdk` repo, generated ABI
bindings in that same repo, and verified module source on the Movement and Aptos explorers.
Nothing is from internal or post-acquisition material.

Compiled 2026-08-18, policy data re-verified 2026-08-20.

---

## Public repositories

| Repo | Type | Language | Commits | Active | Contributors | README | License |
|---|---|---|---|---|---|---|---|
| [canopy-sdk](https://github.com/Canopyxyz/canopy-sdk) | Source | TypeScript | 85 | 2025-09-16 → 2026-08-17 | 5 | Yes | **None** |
| [sentio-processors](https://github.com/Canopyxyz/sentio-processors) | Source | TypeScript | 46 | 2025-01-09 → 2026-05-18 | 3 | Yes | **None** |
| [canopy-points-processor](https://github.com/Canopyxyz/canopy-points-processor) | Source | TypeScript | 8 | 2025-05-27 → 2025-06-03 | 1 | Yes | **None** |
| [canopy-assets](https://github.com/Canopyxyz/canopy-assets) | Source | SVG | 2 | 2025-02-18 → 2025-02-24 | 1 | No | **None** |
| [fixed_point64](https://github.com/Canopyxyz/fixed_point64) | Fork (ThalaLabs) | Move | — | → 2025-07-09 | — | — | upstream |
| [manager-interface](https://github.com/Canopyxyz/manager-interface) | Fork (ThalaLabs) | Move | — | → 2025-03-31 | — | — | upstream |
| [movement-tokens](https://github.com/Canopyxyz/movement-tokens) | Fork (movement-network) | — | → 2025-05-28 | — | — | upstream |
| [DefiLlama-Adapters](https://github.com/Canopyxyz/DefiLlama-Adapters) | Fork (DefiLlama) | JS | — | → 2025-04-07 | — | — | upstream |

### canopy-sdk
pnpm monorepo publishing four npm packages under the `@canopyhub` scope:
`canopy-sdk`, `canopy-sdk-core`, `canopy-sdk-deployments`, `canopy-sdk-bindings` (v2.1.0).
Covers vault reads and transaction builders, curator vault deposits/redemptions/previews,
rewards staking and claim helpers, Meridian ALM vault support, deployment + ABI registries,
contract lookup helpers, and batch reads backed by an on-chain helper module.
`@aptos-labs/ts-sdk` is a peer dependency (type-only imports) so consumers keep a single
copy of the `Aptos` type at the API boundary. ~142 TypeScript source files, a React example
app, Jest tests, and a documented release process (`RELEASING.md`).

### sentio-processors / canopy-points-processor
Sentio indexing processors for Canopy modules, with GraphQL schemas for ICHI vaults,
Meridian ICHI vaults, and rewards. The points processor indexes Canopy vaults and vault
shares for points calculation.

### canopy-assets
Brand icons and logos (SVG).

---

## Package addresses

## Movement Mainnet (chainId 126)

Fullnode: `https://mainnet.movementnetwork.xyz/v1`

| Component | Address |
|---|---|
| `canopy.core` | [`0xb10bd32b3979c9d04272c769d9ef52afbc6edc4bf03982a9e326b96ac25e7f2d`](https://explorer.movementnetwork.xyz/account/0xb10bd32b3979c9d04272c769d9ef52afbc6edc4bf03982a9e326b96ac25e7f2d) |
| `canopy.router` | [`0x717b417949cd5bfa6dc02822eacb727d820de2741f6ea90bf16be6c0ed46ff4b`](https://explorer.movementnetwork.xyz/account/0x717b417949cd5bfa6dc02822eacb727d820de2741f6ea90bf16be6c0ed46ff4b) |
| `canopy.blocks.echelon` | [`0x2859e4b5922d5c6746e51387eea923cd8630ecba132e3eafdf6924269b0dc319`](https://explorer.movementnetwork.xyz/account/0x2859e4b5922d5c6746e51387eea923cd8630ecba132e3eafdf6924269b0dc319) |
| `canopy.blocks.moveposition` | [`0xf35c3fb25b800e4e25b71e255bd3194812d08a0044b45373c53798280db58dca`](https://explorer.movementnetwork.xyz/account/0xf35c3fb25b800e4e25b71e255bd3194812d08a0044b45373c53798280db58dca) |
| `canopy.blocks.layerbank` | [`0x61a67557042baa9fd928e874b84ed53b5de73a0f5474fd278e4d73393125d32e`](https://explorer.movementnetwork.xyz/account/0x61a67557042baa9fd928e874b84ed53b5de73a0f5474fd278e4d73393125d32e) |
| `canopy.blocks.placeholder` | [`0xf23a6e822ee3605642d7ce720f2dc0f8269c199da94d93136f56089bb005f309`](https://explorer.movementnetwork.xyz/account/0xf23a6e822ee3605642d7ce720f2dc0f8269c199da94d93136f56089bb005f309) |
| `canopy.blocks.meridianFarming` | [`0x04d59ca485d294ce6645e456a7ec4ddf1363c844365e4a568ff9211c7e21c8b3`](https://explorer.movementnetwork.xyz/account/0x04d59ca485d294ce6645e456a7ec4ddf1363c844365e4a568ff9211c7e21c8b3) |
| `canopy.blocks.layerbankAirdrop` | [`0xac80083d55f39c8a62eea93d3877b2f5fd40ef469ae54910ff27ff49dd42c8a6`](https://explorer.movementnetwork.xyz/account/0xac80083d55f39c8a62eea93d3877b2f5fd40ef469ae54910ff27ff49dd42c8a6) |
| `canopy.strategies.movepositionSimple` | [`0xd7c7b27e361434e18d2410fd02f7140a8c10d174c9be0efd5324578d243953bd`](https://explorer.movementnetwork.xyz/account/0xd7c7b27e361434e18d2410fd02f7140a8c10d174c9be0efd5324578d243953bd) |
| `canopy.strategies.layerbankSimple` | [`0xad1b34939f164ec6f6c0157da3a30bf9e5d408250978691872a79aa584852b85`](https://explorer.movementnetwork.xyz/account/0xad1b34939f164ec6f6c0157da3a30bf9e5d408250978691872a79aa584852b85) |
| `canopy.strategies.echelonSimple` | [`0x5d2b6a8b6478d86f62c9d3378e2a1fa265e85e69046946632d1fecae1940e851`](https://explorer.movementnetwork.xyz/account/0x5d2b6a8b6478d86f62c9d3378e2a1fa265e85e69046946632d1fecae1940e851) |
| `canopy.strategies.placeholderSimple` | [`0xa9cebc4e3a52f186c831666a6e2f0475d32ebd23244b207ffde0ce06d9813414`](https://explorer.movementnetwork.xyz/account/0xa9cebc4e3a52f186c831666a6e2f0475d32ebd23244b207ffde0ce06d9813414) |
| `canopy.strategies.meridianRewards` | [`0x133b23036f4ac78279fd4cc75b798ccfe2d3c002585049d7483230653b924b7d`](https://explorer.movementnetwork.xyz/account/0x133b23036f4ac78279fd4cc75b798ccfe2d3c002585049d7483230653b924b7d) |
| `canopy.helpers` | [`0x93c6d4852a37be13ec1487a60d32433e396b048ce634b4e8b9f60ff0dac365d2`](https://explorer.movementnetwork.xyz/account/0x93c6d4852a37be13ec1487a60d32433e396b048ce634b4e8b9f60ff0dac365d2) |
| `canopy.views` | [`0x707462571715301b063d79c2cdb57c3bd1cfe2189889793b00077ceed86e0219`](https://explorer.movementnetwork.xyz/account/0x707462571715301b063d79c2cdb57c3bd1cfe2189889793b00077ceed86e0219) |
| `rewards.module` | [`0x113a1769acc5ce21b5ece6f9533eef6dd34c758911fa5235124c87ff1298633b`](https://explorer.movementnetwork.xyz/account/0x113a1769acc5ce21b5ece6f9533eef6dd34c758911fa5235124c87ff1298633b) |
| `rewards.router` | [`0x113a1769acc5ce21b5ece6f9533eef6dd34c758911fa5235124c87ff1298633b`](https://explorer.movementnetwork.xyz/account/0x113a1769acc5ce21b5ece6f9533eef6dd34c758911fa5235124c87ff1298633b) |
| `rewards.batcher` | [`0x265d62018bb6ec05859cdf5520cfc1efa8e84a4f9a853c66f139a2184d367be4`](https://explorer.movementnetwork.xyz/account/0x265d62018bb6ec05859cdf5520cfc1efa8e84a4f9a853c66f139a2184d367be4) |
| `rewards.stdBatcher` | [`0x2a6b1dd5556386991fc6f4fa140ae65a6fc90414acec00e7f0254e98929ec140`](https://explorer.movementnetwork.xyz/account/0x2a6b1dd5556386991fc6f4fa140ae65a6fc90414acec00e7f0254e98929ec140) |
| `alm.meridian.vaults` | [`0x96cfeae5e78eeb1b6215bb83ed9023106e0df49e6d4380783e0e40aa8e771f83`](https://explorer.movementnetwork.xyz/account/0x96cfeae5e78eeb1b6215bb83ed9023106e0df49e6d4380783e0e40aa8e771f83) |
| `alm.meridian.standard` | [`0xec1daab2836431755e13aadec864bccf552dfe7c846b5684b60238394dc91326`](https://explorer.movementnetwork.xyz/account/0xec1daab2836431755e13aadec864bccf552dfe7c846b5684b60238394dc91326) |
| `alm.meridian.registry` | [`0x3b0710d1a0a14a38e2059fc9562f875a1a275a580b7c43c019e68be5a8ae1741`](https://explorer.movementnetwork.xyz/account/0x3b0710d1a0a14a38e2059fc9562f875a1a275a580b7c43c019e68be5a8ae1741) |
| `alm.meridian.batchViews` | [`0xc5f874798691b514476ed1c3c6dd2a4931066f86ba70bd56820da586a84a8b0a`](https://explorer.movementnetwork.xyz/account/0xc5f874798691b514476ed1c3c6dd2a4931066f86ba70bd56820da586a84a8b0a) |
| `alm.meridian.strategies.regularV4` | [`0x6360db298cb2068064ab89b4c27c1df3e26971994d40f2d7ccf6f8f8e6808607`](https://explorer.movementnetwork.xyz/account/0x6360db298cb2068064ab89b4c27c1df3e26971994d40f2d7ccf6f8f8e6808607) |
| `alm.meridian.strategies.medianStableV2` | [`0xce4cb4a684e38346910686cf63fcbb9f3678c2b2fdd9d297bd375e617cee5cee`](https://explorer.movementnetwork.xyz/account/0xce4cb4a684e38346910686cf63fcbb9f3678c2b2fdd9d297bd375e617cee5cee) |
| `sharedPackages.largePackages` | [`0x1f33887fba324884468f326ab741e937fb2b9563faa467dca15e4eb198817531`](https://explorer.movementnetwork.xyz/account/0x1f33887fba324884468f326ab741e937fb2b9563faa467dca15e4eb198817531) |

## Movement Testnet (chainId 250)

Fullnode: `https://testnet.movementnetwork.xyz/v1`

| Component | Address |
|---|---|
| `curator.vault` | [`0x8ff93d763976b0b71ee99e3601ada04800dd372806d6d7248086266613167bd2`](https://explorer.movementnetwork.xyz/account/0x8ff93d763976b0b71ee99e3601ada04800dd372806d6d7248086266613167bd2) |
| `curator.router` | [`0x97b28d98b0e76f529a12d4d37671be3954aaf619afe600c0bee58349a8ce02d0`](https://explorer.movementnetwork.xyz/account/0x97b28d98b0e76f529a12d4d37671be3954aaf619afe600c0bee58349a8ce02d0) |
| `curator.genericAdapter` | [`0x362f2f52db6906f1c38ee6c2058633987a400eba1cac6c29de48979faabc5078`](https://explorer.movementnetwork.xyz/account/0x362f2f52db6906f1c38ee6c2058633987a400eba1cac6c29de48979faabc5078) |

## Aptos Mainnet (chainId 1)

Fullnode: `https://api.mainnet.aptoslabs.com/v1`

| Component | Address |
|---|---|
| `alm.meridian.vaults` | `0xeb57695cd494c59ea7b1356580f1e7d5666fd84827322369e21d712e22397b54` |
| `alm.meridian.standard` | `0x781a660f7f6e1f3b6318c365ccb3fe01804ac318224784fd5c955c0f53ed77c7` |
| `alm.meridian.registry` | `0xae645c9ef6a7d68d64e2beb1c6896f73f189ab609e650ace8bdeeac390b0dd38` |
| `alm.meridian.strategies.regularV4` | `0xad879f655500986d56972c95817575b5ddc1a65c5181be15cbf1f5f6ad685d04` |

## Aptos Testnet (chainId 2)

Fullnode: `https://api.testnet.aptoslabs.com/v1`

| Component | Address |
|---|---|
| `canopy.core` | `0xe5ec58845afb1cb164d1c260f2a284b2f1311318973e13355b9e4dc2908eed5a` |
| `canopy.router` | `0x6db956973bb73aff8b6c3712a7b4fff18bfefd850cce81c558d20a7ab1fc37d9` |
| `canopy.blocks.echelon` | `0xa5d6e6dde6622d8532a67ebfe45a36617660c0b9107772c9c9d4e5f27ce08078` |
| `canopy.blocks.moveposition` | `0x26edc07d3e9b3f89af3ecc2a3488391286ab06ae65eefc1c598816328e11a47e` |
| `canopy.blocks.layerbank` | `0x9d4b014c145e1c926a570a4e1293397ec3999913f70a3e97146bbd8f50bc063f` |
| `canopy.blocks.placeholder` | `0xae643384070b7e5772e29628a99098a8f7dd86ebb747eea70c6e210a66c7ef37` |
| `canopy.strategies.echelonSimple` | `0x1b4ec80d5161b9669974b051a3e2db1503304c69073afdbfc1e8d2cfb947a55b` |
| `canopy.strategies.movepositionSimple` | `0x0374b4443dbd6cd1ce289b47b7cc8cdc468571871161b6d672157fac41f5c6ab` |
| `canopy.strategies.layerbankSimple` | `0xbc95c89d0117335acb2e05401a8ff5978549fde3f7b789e88de7c685275f5b3c` |
| `rewards.module` | `0xd56da69b420f88aa56d713e0453f4dba2ccc6ebd1d1810c821c80b4874ae81d3` |
| `rewards.router` | `0xd56da69b420f88aa56d713e0453f4dba2ccc6ebd1d1810c821c80b4874ae81d3` |
| `rewards.batcher` | `0x266c450e37b89350e8f22c7d994fe5fbc489801221679d39a915d42e2f239e55` |

## Published in official documentation but not in the SDK registry

| Component | Address |
|---|---|
| `canopy.liquidswapVaults` | [`0x5cd341a0cd4c2fb8d9e342814c00d7b388ad7579365d657ebb5b18e35c3c761b`](https://explorer.movementnetwork.xyz/account/0x5cd341a0cd4c2fb8d9e342814c00d7b388ad7579365d657ebb5b18e35c3c761b) |

Source: `docs.canopyhub.xyz/operations/canopy-smart-contracts`.

---

## Module registry — Movement mainnet

Entry / view / struct counts per module, from the published ABIs.

| Module file | On-chain module | Address | Entry fns | View fns | Structs |
|---|---|---|---|---|---|
| `canopy_base_strategy` | `base_strategy` | [`0xb10bd32b…7f2d`](https://explorer.movementnetwork.xyz/object/0xb10bd32b3979c9d04272c769d9ef52afbc6edc4bf03982a9e326b96ac25e7f2d/modules/code/base_strategy) | 0 | 16 | 8 |
| `canopy_helpers` | `helpers` | [`0x93c6d485…65d2`](https://explorer.movementnetwork.xyz/object/0x93c6d4852a37be13ec1487a60d32433e396b048ce634b4e8b9f60ff0dac365d2/modules/code/helpers) | 0 | 5 | 0 |
| `canopy_protocol` | `protocol` | [`0xb10bd32b…7f2d`](https://explorer.movementnetwork.xyz/object/0xb10bd32b3979c9d04272c769d9ef52afbc6edc4bf03982a9e326b96ac25e7f2d/modules/code/protocol) | 11 | 14 | 15 |
| `canopy_rewards_view` | `rewards_view` | [`0x70746257…0219`](https://explorer.movementnetwork.xyz/object/0x707462571715301b063d79c2cdb57c3bd1cfe2189889793b00077ceed86e0219/modules/code/rewards_view) | 3 | 13 | 4 |
| `canopy_router` | `router` | [`0x717b4179…ff4b`](https://explorer.movementnetwork.xyz/object/0x717b417949cd5bfa6dc02822eacb727d820de2741f6ea90bf16be6c0ed46ff4b/modules/code/router) | 6 | 0 | 0 |
| `canopy_router_deposit` | `deposit` | [`0x717b4179…ff4b`](https://explorer.movementnetwork.xyz/object/0x717b417949cd5bfa6dc02822eacb727d820de2741f6ea90bf16be6c0ed46ff4b/modules/code/deposit) | 0 | 1 | 0 |
| `canopy_router_withdraw` | `withdraw` | [`0x717b4179…ff4b`](https://explorer.movementnetwork.xyz/object/0x717b417949cd5bfa6dc02822eacb727d820de2741f6ea90bf16be6c0ed46ff4b/modules/code/withdraw) | 0 | 1 | 0 |
| `canopy_satay` | `satay` | [`0xb10bd32b…7f2d`](https://explorer.movementnetwork.xyz/object/0xb10bd32b3979c9d04272c769d9ef52afbc6edc4bf03982a9e326b96ac25e7f2d/modules/code/satay) | 19 | 0 | 0 |
| `canopy_strategy_echelon_simple` | `strategy` | [`0x5d2b6a8b…e851`](https://explorer.movementnetwork.xyz/object/0x5d2b6a8b6478d86f62c9d3378e2a1fa265e85e69046946632d1fecae1940e851/modules/code/strategy) | 22 | 3 | 5 |
| `canopy_strategy_layerbank_simple` | `strategy` | [`0xad1b3493…2b85`](https://explorer.movementnetwork.xyz/object/0xad1b34939f164ec6f6c0157da3a30bf9e5d408250978691872a79aa584852b85/modules/code/strategy) | 13 | 5 | 4 |
| `canopy_strategy_meridian_rewards` | `strategy` | [`0x133b2303…4b7d`](https://explorer.movementnetwork.xyz/object/0x133b23036f4ac78279fd4cc75b798ccfe2d3c002585049d7483230653b924b7d/modules/code/strategy) | 13 | 4 | 4 |
| `canopy_strategy_moveposition_simple` | `strategy` | [`0xd7c7b27e…53bd`](https://explorer.movementnetwork.xyz/object/0xd7c7b27e361434e18d2410fd02f7140a8c10d174c9be0efd5324578d243953bd/modules/code/strategy) | 13 | 2 | 3 |
| `canopy_strategy_moveposition_ticket` | `ticket` | [`0xd7c7b27e…53bd`](https://explorer.movementnetwork.xyz/object/0xd7c7b27e361434e18d2410fd02f7140a8c10d174c9be0efd5324578d243953bd/modules/code/ticket) | 0 | 0 | 2 |
| `canopy_strategy_placeholder_simple` | `strategy` | [`0xa9cebc4e…3414`](https://explorer.movementnetwork.xyz/object/0xa9cebc4e3a52f186c831666a6e2f0475d32ebd23244b207ffde0ce06d9813414/modules/code/strategy) | 7 | 0 | 3 |
| `canopy_vault` | `vault` | [`0xb10bd32b…7f2d`](https://explorer.movementnetwork.xyz/object/0xb10bd32b3979c9d04272c769d9ef52afbc6edc4bf03982a9e326b96ac25e7f2d/modules/code/vault) | 1 | 27 | 20 |
| `multi_rewards` | `multi_rewards` | [`0x113a1769…633b`](https://explorer.movementnetwork.xyz/object/0x113a1769acc5ce21b5ece6f9533eef6dd34c758911fa5235124c87ff1298633b/modules/code/multi_rewards) | 14 | 12 | 22 |
| `multi_rewards_batcher_entry` | `batcher_entry` | [`0x265d6201…7be4`](https://explorer.movementnetwork.xyz/object/0x265d62018bb6ec05859cdf5520cfc1efa8e84a4f9a853c66f139a2184d367be4/modules/code/batcher_entry) | 9 | 0 | 0 |
| `multi_rewards_batcher_view` | `batcher_view` | [`0x265d6201…7be4`](https://explorer.movementnetwork.xyz/object/0x265d62018bb6ec05859cdf5520cfc1efa8e84a4f9a853c66f139a2184d367be4/modules/code/batcher_view) | 0 | 13 | 9 |
| `multi_rewards_router` | `router` | [`0x113a1769…633b`](https://explorer.movementnetwork.xyz/object/0x113a1769acc5ce21b5ece6f9533eef6dd34c758911fa5235124c87ff1298633b/modules/code/router) | 16 | 0 | 0 |
| `multi_rewards_std_views` | `std_views` | [`0x2a6b1dd5…c140`](https://explorer.movementnetwork.xyz/object/0x2a6b1dd5556386991fc6f4fa140ae65a6fc90414acec00e7f0254e98929ec140/modules/code/std_views) | 0 | 10 | 0 |

<details>
<summary>Function surface (movement-mainnet)</summary>

**`base_strategy`** — 0xb10bd32b3979c9d04272c769d9ef52afbc6edc4bf03982a9e326b96ac25e7f2d

_View:_ `amount_to_shares`, `base_metadata`, `base_strategy_view`, `concrete_address`, `fee_amounts`, `last_harvest`, `lock_duration`, `manager`, `performance_fee`, `shares_metadata`, `shares_to_amount`, `total_assets`, `total_debt`, `total_idle`, `total_locked`, `total_shares`

**`helpers`** — 0x93c6d4852a37be13ec1487a60d32433e396b048ce634b4e8b9f60ff0dac365d2

_View:_ `batch_get_fa_balance`, `batch_get_vault_all_metadata_and_balance`, `batch_get_vault_balance`, `batch_get_vault_base_metadata_and_balance`, `batch_get_vault_shares_metadata_and_balance`

**`protocol`** — 0xb10bd32b3979c9d04272c769d9ef52afbc6edc4bf03982a9e326b96ac25e7f2d

_Entry:_ `accept_governance`, `approve_pending_router`, `set_auto_harvest`, `set_auto_report`, `set_governance`, `set_governance_delay`, `set_management_fee`, `set_performance_fee`, `set_protocol_fee`, `set_protocol_fee_recipient`, `set_router_delay`

_View:_ `get_address`, `get_deployer`, `get_governance`, `get_management_fee`, `get_pending_governance`, `get_performance_fee`, `get_protocol_fee`, `get_protocol_fee_recipient`, `get_protocol_fee_recipient_store`, `get_router`, `is_governance`, `is_pending_governance`, `should_auto_harvest`, `should_auto_report`

**`rewards_view`** — 0x707462571715301b063d79c2cdb57c3bd1cfe2189889793b00077ceed86e0219

_Entry:_ `add_pool`, `remove_pool`, `transfer_ownership`

_View:_ `get_all_pool_list`, `get_owner`, `get_paginated_pools`, `get_pool_details`, `get_pool_info`, `get_registered_pool_count`, `get_registry_overview`, `get_reward_token_details`, `get_rewards_snapshot`, `get_user_pool_positions`, `get_user_pool_positions_by_token`, `get_user_pool_positions_by_tokens`, `is_pool_registered`

**`router`** — 0x717b417949cd5bfa6dc02822eacb727d820de2741f6ea90bf16be6c0ed46ff4b

_Entry:_ `deposit_coin`, `deposit_fa`, `deposit_fa_with_coin_type`, `withdraw_coin`, `withdraw_fa`, `withdraw_fa_with_coin_type`

**`deposit`** — 0x717b417949cd5bfa6dc02822eacb727d820de2741f6ea90bf16be6c0ed46ff4b

_View:_ `get_allocations_view`

**`withdraw`** — 0x717b417949cd5bfa6dc02822eacb727d820de2741f6ea90bf16be6c0ed46ff4b

_View:_ `get_withdrawal_map_view`

**`satay`** — 0xb10bd32b3979c9d04272c769d9ef52afbc6edc4bf03982a9e326b96ac25e7f2d

_Entry:_ `add_strategy`, `create_vault`, `create_vault_with_coin`, `pause_vault`, `rebalance_strategy_idle`, `rebalance_vault_idle`, `remove_strategy`, `set_strategy_debt_limit`, `set_strategy_lock_duration`, `set_strategy_manager`, `set_strategy_performance_fee`, `set_vault_deposit_limit`, `set_vault_lock_duration`, `set_vault_management_fee`, `set_vault_manager`, `set_vault_performance_fee`, `sweep_strategy`, `sweep_vault`, `unpause_vault`

**`strategy`** — 0x5d2b6a8b6478d86f62c9d3378e2a1fa265e85e69046946632d1fecae1940e851

_Entry:_ `add_reward_coin_type`, `add_reward_metadata`, `claim_non_base_asset_coin_rewards`, `claim_non_base_asset_fa_rewards`, `create`, `harvest`, `harvest_fa`, `notify_all_rewards`, `notify_rewards_coin`, `perform_upkeep_coin`, `perform_upkeep_fa`, `remove_reward_coin_type`, `remove_reward_metadata`, `set_rewards_pool_address`, `set_upkeep_interval`, `tend_coin`, `tend_fa`, `vault_deposit_coin`, `vault_deposit_fa`, `vault_report`, `withdraw_coin`, `withdraw_fa`

_View:_ `check_upkeep`, `get_last_upkeep_timestamp`, `rewards_pool_address`

**`strategy`** — 0xad1b34939f164ec6f6c0157da3a30bf9e5d408250978691872a79aa584852b85

_Entry:_ `claim_all_non_base_asset_rewards`, `create`, `harvest`, `notify_all_rewards`, `notify_rewards`, `perform_upkeep`, `set_rewards_controller_address`, `set_rewards_pool_address`, `set_upkeep_interval`, `tend_fa`, `vault_deposit_fa`, `vault_report`, `withdraw_fa`

_View:_ `check_upkeep`, `get_base_asset`, `get_last_upkeep_timestamp`, `get_rewards_controller_address`, `rewards_pool_address`

**`strategy`** — 0x133b23036f4ac78279fd4cc75b798ccfe2d3c002585049d7483230653b924b7d

_Entry:_ `claim_non_base_asset_rewards`, `create`, `deposit_fa`, `harvest`, `notify_all_rewards`, `notify_rewards`, `perform_upkeep`, `set_rewards_pool_address`, `set_upkeep_interval`, `tend_fa`, `vault_deposit_fa`, `vault_report`, `withdraw_fa`

_View:_ `check_upkeep`, `get_base_asset`, `get_last_upkeep_timestamp`, `rewards_pool_address`

**`strategy`** — 0xd7c7b27e361434e18d2410fd02f7140a8c10d174c9be0efd5324578d243953bd

_Entry:_ `create`, `deposit_coin`, `deposit_fa`, `harvest`, `harvest_fa`, `tend_coin`, `tend_fa`, `update_amount_leeway_bps`, `vault_deposit_coin`, `vault_deposit_fa`, `vault_report`, `withdraw_coin`, `withdraw_fa`

_View:_ `withdrawal_amount_view`, `withdrawal_amount_view_fa`

**`strategy`** — 0xa9cebc4e3a52f186c831666a6e2f0475d32ebd23244b207ffde0ce06d9813414

_Entry:_ `create`, `unlink_from_vault`, `vault_deposit_coin`, `vault_deposit_fa`, `vault_report`, `withdraw_coin`, `withdraw_fa`

**`vault`** — 0xb10bd32b3979c9d04272c769d9ef52afbc6edc4bf03982a9e326b96ac25e7f2d

_Entry:_ `initialize`

_View:_ `amount_to_shares`, `base_metadata`, `deposit_limit`, `is_paused`, `lock_duration`, `management_fee`, `manager`, `paginated_vaults`, `performance_fee`, `shares_metadata`, `shares_to_amount`, `strategies`, `strategy_debt`, `strategy_debt_limit`, `strategy_last_report`, `strategy_total_loss`, `strategy_total_profit`, `total_assets`, `total_debt`, `total_debt_limit`, `total_idle`, `total_locked`, `total_shares`, `vault_strategies`, `vault_view`, `vaults`, `vaults_view`

**`multi_rewards`** — 0x113a1769acc5ce21b5ece6f9533eef6dd34c758911fa5235124c87ff1298633b

_Entry:_ `add_reward`, `claim_reward`, `clear_admin_withdrawal_proposal`, `emergency_withdraw`, `entry_create_staking_pool`, `execute_admin_withdrawal`, `notify_reward_amount`, `propose_admin_withdrawal`, `set_rewards_duration`, `stake`, `subscribe`, `sweep_token`, `unsubscribe`, `withdraw`

_View:_ `get_earned`, `get_last_time_reward_applicable`, `get_pool_info`, `get_pool_reward_tokens`, `get_remaining_rewards`, `get_reward_data`, `get_reward_per_token`, `get_unallocated_rewards`, `get_user_reward_data`, `get_user_staked_balance`, `get_user_subscribed_pools`, `is_user_subscribed`

**`batcher_entry`** — 0x265d62018bb6ec05859cdf5520cfc1efa8e84a4f9a853c66f139a2184d367be4

_Entry:_ `batch_add_multiple_rewards_to_pool`, `batch_add_reward_to_multiple_pools`, `batch_add_rewards_matrix`, `batch_create_staking_pools`, `batch_notify_reward_amounts`, `batch_set_rewards_durations`, `create_pools_with_multiple_rewards`, `create_pools_with_rewards`, `create_pools_with_same_reward`

**`batcher_view`** — 0x265d62018bb6ec05859cdf5520cfc1efa8e84a4f9a853c66f139a2184d367be4

_View:_ `get_active_rewards_pools`, `get_pool_all_rewards_details`, `get_pool_full_details`, `get_pool_reward_details`, `get_pools_by_staking_token`, `get_pools_full_details`, `get_pools_reward_tokens_details`, `get_user_multiple_pools_positions`, `get_user_pool_position`, `get_user_pools_positions_by_token`, `get_user_rewards_by_pool`, `get_user_staking_overview`, `get_user_system_overview`

**`router`** — 0x113a1769acc5ce21b5ece6f9533eef6dd34c758911fa5235124c87ff1298633b

_Entry:_ `add_reward`, `claim_rewards`, `create_fungible_asset_for_token`, `create_staking_pool`, `notify_reward_amount`, `set_rewards_duration`, `stake`, `stake_and_subscribe`, `stake_and_subscribe_fa`, `stake_and_subscribe_token`, `stake_token`, `unsubscribe_and_withdraw`, `unsubscribe_and_withdraw_fa`, `unsubscribe_and_withdraw_token`, `withdraw`, `withdraw_token`

**`std_views`** — 0x2a6b1dd5556386991fc6f4fa140ae65a6fc90414acec00e7f0254e98929ec140

_View:_ `are_owners_of_object`, `are_owners_paired`, `get_owners`, `get_root_owners`, `have_same_owner`, `have_same_root_owner`, `is_owner_of_objects`, `owners_own_object`, `owns_objects`, `owns_paired`

</details>

---

## Verifying any of this

Every claim above is independently checkable without repository access:

- **Module interfaces** — `GET {fullnode}/v1/accounts/{address}/modules` returns each
  published module's ABI: exposed functions, visibility, entry/view flags, and struct
  definitions. This is the same data the SDK's generated bindings encode.
- **Upgrade policy** — the `0x1::code::PackageRegistry` resource on a package account
  records each published package's policy (`0` arbitrary, `1` compatible, `2` immutable):

  ```bash
  curl -s https://mainnet.movementnetwork.xyz/v1/accounts/<address>/resource/0x1::code::PackageRegistry \
    | jq '.data.packages[] | {name, upgrade_policy, upgrade_number}'
  ```

  Run against `canopy.core` and any strategy package, this confirms the immutable/upgradeable
  split described above.
- **Verified source** — Canopy published its packages with source attached, so the Move
  implementation is readable on the explorer at
  `explorer.movementnetwork.xyz/object/{address}/modules/code/{module}`. The same source is
  available programmatically: `PackageRegistry.packages[].modules[].source` holds it
  gzip-compressed and hex-encoded. See `fetch-canopy-source.py`.

---

## Caveats

- **No LICENSE file exists in any of the four source repositories.** Publicly readable is
  not the same as open source; without a license these are all-rights-reserved by default.
  Post-acquisition this is Movement Labs' call to make, not something to assert unilaterally.
- Core Move contracts are in a private repository, but the packages were published to
  Movement mainnet **with source included**, so the implementations are readable on-chain
  and rendered by the explorer. Publicly readable is still not the same as licensed: the
  source can be linked, read, cited, and documented, but not relicensed or redistributed.
- Ownership of the GitHub organization and npm scope transferred with the acquisition.
- **Authorship:** commit history for all four public repos is attributable to engineering
  contributors, not to the founder. This document is an inventory of what the team shipped,
  not a claim of authorship.

---

## Deliberately not included

Individual vault-object addresses, historical deployment generations, and operational
tracking data are omitted. Some of that is discoverable on-chain by anyone willing to index
events, but it is not published by Canopy, and this document holds only what is.

# Canopy

A yield-aggregation protocol on the Movement network. I founded it at Vanderbilt, served as
CEO, and the company was acquired at graduation.

**I did not write Canopy's Move contracts.** I set scope, ran the audit cycle across six
engagements and three firms, and made the architectural calls — most consequentially where
to draw the line between code that could be upgraded and code that was frozen at deploy.
This repository documents a system I was responsible for, not one I implemented. The
engineering credit belongs to the engineers who wrote it.

Everything here is written against the deployed on-chain source, so a reader with no access
to the private repository can check any claim in it.

https://github.com/user-attachments/assets/e2c453c7-72d8-41a9-bbcd-b1eb7faa42c1

<p align="center">
  Presenting Canopy at <b>Korea Blockchain Week 2025</b> &nbsp;·&nbsp; 1 min
  &nbsp;&nbsp;|&nbsp;&nbsp;
  <b><a href="https://bennettdavisv2.github.io/canopy-architecture/">Interactive architecture map →</a></b>
</p>

---

## Contents

| | |
|---|---|
| [`docs/architecture.md`](docs/architecture.md) | The technical deep-dive: layer enforcement, a traced deposit path, share-pricing and inflation analysis, the immutability boundary. |
| [`docs/reference.md`](docs/reference.md) | Addresses, per-module ABI counts, public repositories, verification commands. |
| [`audits/`](audits/) | Six third-party audit reports — Halborn ×3, MoveBit ×2, OtterSec ×1, spanning Jun 2024 → Jul 2025. |
| [`tools/`](tools/) | `fetch-canopy-source.py` pulls verified Move source for all 18 mainnet packages from the public fullnode; `gen-package-index.py` regenerates the package index from that data. Stdlib only, no credentials. |
| [`site/`](site/) | Source for the interactive architecture map, plus the build script that emits the deployed page. |

---

## The system

Three layers plus a router. A **core** package holds vault and strategy accounting. One
**block** adapter wraps each integrated venue (Echelon, MovePosition, LayerBank, Meridian).
**Strategy** packages compose a block into a yield strategy. The router is the entry point
for deposits and withdrawals.

The decision I owned was where to put the immutability line: vault share accounting frozen at
deploy and not patchable by anyone including governance, while the router, strategies, and
blocks stayed upgradeable so logic tracking venue incentives could be revised without
touching the code that custodies funds.

## Three things the source shows

**The layer boundary is enforced by the type system, not by convention.** Strategies live in
separate packages, so Move's `friend` mechanism can't reach them. Instead a strategy proves
its identity with a one-time witness type, holds a non-copyable `AuthRef` that binds it to
exactly one accounting object, and receives funds wrapped in a struct with *no abilities at
all* — so the compiler rejects any transaction where a strategy tries to keep them.

**The vault resists inflation attacks structurally rather than with a mitigation.** First
deposits mint 1:1 with no virtual shares or dead-shares seed. That is safe because share
price is computed from internal accounting (`total_idle + total_debt`), never from the live
token balance — so the classic donate-to-inflate attack has nowhere to land, and the only
function that resyncs to real balance is governance-gated.

**The upgrade counts read out the architecture.** Move has no dynamic dispatch, so the router
enumerates strategies by hardcoded address, which means every strategy added forces a router
upgrade. The router has the joint-highest upgrade count in the system. The core has zero.

## What I got wrong

Earlier versions of this documentation claimed the per-venue blocks were published immutable
alongside the core. They were not — all six are upgradeable, and one has been upgraded in
production. The claim is corrected throughout, against data fetched from the chain rather
than from memory. The immutable set is exactly two packages: the core and the rewards module.

That correction is left visible rather than quietly edited out, because the point of writing
documentation this way is that someone can check it.

## Reproducing

```bash
python3 tools/fetch-canopy-source.py     # stdlib only; writes ./canopy-source/
```

Aptos-style chains store each module's original source gzip-compressed in the
`0x1::code::PackageRegistry` resource on the publishing account — the same data block
explorers render. The tool decompresses it and prints each package's upgrade policy and
upgrade count as it goes.

`canopy-source/` is gitignored. Canopy's code carries no license: publicly readable is not
openly licensed, so it is quoted here in short excerpts as commentary and never
redistributed.

## Sources

Verified on-chain Move source; the public `Canopyxyz` GitHub organization; `docs.canopyhub.xyz`;
and the six published audit reports. No internal, proprietary, or post-acquisition
confidential material.

# Canopy

A yield-aggregation vault protocol on the Movement network.

**[▶ Interactive architecture map](https://bennettdavisv2.github.io/canopy-architecture/)**

---

## Contents

| | |
|---|---|
| [`docs/architecture.md`](docs/architecture.md) | The technical deep-dive: layer enforcement, a traced deposit path, share-pricing and inflation analysis, the immutability boundary. |
| [`docs/reference.md`](docs/reference.md) | Addresses, per-module ABI counts, public repositories, verification commands. |
| [`audits/`](audits/) | Third-party audit reports. |
| [`tools/`](tools/) | `fetch-canopy-source.py` pulls verified Move source for all mainnet packages from the public fullnode; `gen-package-index.py` regenerates the package index from that data. |

---

## The system

Three layers plus a router. 

A **core** package holds vault and strategy accounting. One
**block** adapter wraps each integrated venue (Echelon, MovePosition, LayerBank, Meridian).
**Strategy** packages compose a block into a yield strategy. The router is the entry point
for deposits and withdrawals.

## Source

Verified on-chain Move source.

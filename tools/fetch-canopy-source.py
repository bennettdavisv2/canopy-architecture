#!/usr/bin/env python3
"""
Pull verified Move source for Canopy's published packages from the public Movement
fullnode. Aptos-style chains store each module's original source, gzip-compressed, in the
0x1::code::PackageRegistry resource on the publishing account -- this is what block
explorers render. No repository access or credentials required.

Usage:
    python3 fetch-canopy-source.py                  # all known packages
    python3 fetch-canopy-source.py 0xb10bd32b...    # one address

Output: ./canopy-source/<package>/<module>.move
"""

import gzip
import json
import sys
import urllib.request
from pathlib import Path

FULLNODE = "https://mainnet.movementnetwork.xyz/v1"
OUT = Path("canopy-source")

# From canopy-sdk/packages/deployments/addresses/movement-mainnet.json
PACKAGES = {
    "core": "0xb10bd32b3979c9d04272c769d9ef52afbc6edc4bf03982a9e326b96ac25e7f2d",
    "router": "0x717b417949cd5bfa6dc02822eacb727d820de2741f6ea90bf16be6c0ed46ff4b",
    "block-echelon": "0x2859e4b5922d5c6746e51387eea923cd8630ecba132e3eafdf6924269b0dc319",
    "block-moveposition": "0xf35c3fb25b800e4e25b71e255bd3194812d08a0044b45373c53798280db58dca",
    "block-layerbank": "0x61a67557042baa9fd928e874b84ed53b5de73a0f5474fd278e4d73393125d32e",
    "block-placeholder": "0xf23a6e822ee3605642d7ce720f2dc0f8269c199da94d93136f56089bb005f309",
    "block-meridian-farming": "0x04d59ca485d294ce6645e456a7ec4ddf1363c844365e4a568ff9211c7e21c8b3",
    "block-layerbank-airdrop": "0xac80083d55f39c8a62eea93d3877b2f5fd40ef469ae54910ff27ff49dd42c8a6",
    "strategy-echelon-simple": "0x5d2b6a8b6478d86f62c9d3378e2a1fa265e85e69046946632d1fecae1940e851",
    "strategy-moveposition-simple": "0xd7c7b27e361434e18d2410fd02f7140a8c10d174c9be0efd5324578d243953bd",
    "strategy-layerbank-simple": "0xad1b34939f164ec6f6c0157da3a30bf9e5d408250978691872a79aa584852b85",
    "strategy-placeholder-simple": "0xa9cebc4e3a52f186c831666a6e2f0475d32ebd23244b207ffde0ce06d9813414",
    "strategy-meridian-rewards": "0x133b23036f4ac78279fd4cc75b798ccfe2d3c002585049d7483230653b924b7d",
    "rewards": "0x113a1769acc5ce21b5ece6f9533eef6dd34c758911fa5235124c87ff1298633b",
    "rewards-batcher": "0x265d62018bb6ec05859cdf5520cfc1efa8e84a4f9a853c66f139a2184d367be4",
    "rewards-std-batcher": "0x2a6b1dd5556386991fc6f4fa140ae65a6fc90414acec00e7f0254e98929ec140",
    "helpers": "0x93c6d4852a37be13ec1487a60d32433e396b048ce634b4e8b9f60ff0dac365d2",
    "views": "0x707462571715301b063d79c2cdb57c3bd1cfe2189889793b00077ceed86e0219",
}

POLICY = {0: "arbitrary", 1: "compatible", 2: "immutable"}


def registry(address):
    url = f"{FULLNODE}/accounts/{address}/resource/0x1::code::PackageRegistry"
    with urllib.request.urlopen(url, timeout=30) as r:
        return json.load(r)["data"]["packages"]


def decode(hex_str):
    """PackageRegistry stores source as gzipped bytes, hex-encoded. Empty means the
    publisher chose not to include source."""
    raw = bytes.fromhex(hex_str.removeprefix("0x"))
    if not raw:
        return None
    return gzip.decompress(raw).decode("utf-8", errors="replace")


def main():
    targets = (
        {"cli-arg": sys.argv[1]} if len(sys.argv) > 1 else PACKAGES
    )
    manifest = []
    for label, address in targets.items():
        try:
            packages = registry(address)
        except Exception as e:
            print(f"[!] {label}: {e}")
            continue
        for pkg in packages:
            policy = POLICY.get(pkg["upgrade_policy"]["policy"], "?")
            upgrades = pkg.get("upgrade_number", "?")
            name = pkg["name"]
            print(f"{label:32} {name:24} policy={policy:11} upgrades={upgrades}")
            manifest.append(
                {
                    "label": label,
                    "address": address,
                    "package": name,
                    "upgrade_policy": policy,
                    "upgrade_number": upgrades,
                    "modules": [m["name"] for m in pkg["modules"]],
                }
            )
            dest = OUT / label
            dest.mkdir(parents=True, exist_ok=True)
            for module in pkg["modules"]:
                src = decode(module.get("source", ""))
                if src is None:
                    print(f"    {module['name']}: no source published")
                    continue
                (dest / f"{module['name']}.move").write_text(src)
                print(f"    {module['name']}.move  ({len(src):,} bytes)")

    OUT.mkdir(exist_ok=True)
    (OUT / "manifest.json").write_text(json.dumps(manifest, indent=2))
    print(f"\n{len(manifest)} packages -> {OUT}/")


if __name__ == "__main__":
    main()

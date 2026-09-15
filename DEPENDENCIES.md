# Vendored dependencies

Only the transitive files needed by the included contracts, deployment script,
and tests are included. Paths and contents match the original build. Unused
remappings remain pinned because Solidity includes them in metadata.

| Dependency | Original version or commit | License files |
| --- | --- | --- |
| [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts/tree/v5.6.1) | v5.6.1 | `lib/openzeppelin-contracts-v5.6.1/LICENSE` (MIT) |
| [Uniswap V4 Core](https://github.com/Uniswap/v4-core/tree/e50237c43811bd9b526eff40f26772152a42daba) | v4.0.0, `e50237c43811bd9b526eff40f26772152a42daba` | `lib/v4-core/licenses/` (BUSL-1.1 and MIT; check each file's SPDX identifier) |
| [Forge Standard Library](https://github.com/foundry-rs/forge-std/tree/1de6eecf821de7fe2c908cc48d3ab3dced20717f) | `1de6eecf821de7fe2c908cc48d3ab3dced20717f` | `lib/forge-std/LICENSE-APACHE`, `LICENSE-MIT` |
| [Solmate](https://github.com/transmissions11/solmate/tree/4b47a19038b798b4a33d9749d25e570443520647) | `4b47a19038b798b4a33d9749d25e570443520647` | `lib/solmate/LICENSE` |

The forge-std MIT license was restored from the exact upstream pinned commit;
the original internal snapshot contained only its Apache license file. All
copied Solidity source hashes are listed in `verification/source-provenance.json`.

## Existing external deployments

| Dependency | Robinhood Chain address |
| --- | --- |
| PoolManager | `0x8366a39CC670B4001A1121B8F6A443A643e40951` |
| PositionManager | `0x58daec3116aae6D93017bAAea7749052E8a04fA7` |
| Permit2 | `0x000000000022D473030F116dDEE9F6B43aC78BA3` |

These are existing Uniswap deployments. Ctrl uses the interfaces in this source
tree; the deployment manifest records their reviewed runtime hashes.

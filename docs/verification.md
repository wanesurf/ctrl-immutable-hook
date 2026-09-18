# Reproduce and verify the deployed source

## Two deployment records

| Deployment | Source evidence | Historical manifest |
| --- | --- | --- |
| Arc, 5042 | [Compiler inputs, metadata, and provenance](../verification/5042-mainnet) | [5042-mainnet.json](../deployments/5042-mainnet.json) |
| Robinhood, 4663 | [Original source provenance](../verification/source-provenance.json) and metadata under `verification/` | [4663-mainnet.json](../deployments/4663-mainnet.json) |

The Arc hook and factory are `CtrlNativeLaunchHook` and `CtrlNativeV4Factory`.
The Robinhood equivalents are `CtrlLaunchHookV1` and `CtrlV4Factory`. Shared
contracts and vendored imports are byte-for-byte identical across these builds.
The Arc additions were uncommitted at deployment: the recorded source-base
commit alone does not identify them. Their original Standard JSON inputs,
whose SHA-256 digests are recorded in the Arc manifest, capture the exact source.

## Deterministic build

Both deployments use Solidity `0.8.26+commit.8a97fa7a`, optimizer 200 runs,
`viaIR: true`, Cancun EVM, IPFS bytecode metadata, and CBOR metadata. Source
paths, source bytes, and remappings affect the metadata hash.

The repository retains those paths and bytes. Its explicit `remappings.txt`
contains the complete deployment remapping list, including unused entries.
Automatic remapping detection is disabled. Dependencies are vendored.

```bash
forge build
python3 scripts/verify-source.py --chain-id 5042
python3 scripts/verify-source.py --chain-id 4663
```

Arc is the verifier's default if `--chain-id` is omitted. The verifier checks:

1. Copied source hashes against the selected provenance record.
2. Creation-bytecode fingerprints and exact compiler metadata for all seven
   deployed contracts, using artifacts from the local build.
3. Published ABIs against the compiled ABIs and absence of hook upgrade methods.
4. For Arc, original compiler-input hashes against the deployment manifest and
   every included source against that original compiler input.

The compiler-input and metadata checks do not strip metadata or rewrite the
contract source. The deployment helper's source is retained even though the
verification workflow never runs its deployment entry point.

## Live runtime comparison

Arc:

```bash
python3 scripts/verify-source.py --chain-id 5042 \
  --rpc-url https://rpc.mainnet.arc.io \
  --output verification/5042-mainnet/live-verification.json
```

Robinhood:

```bash
python3 scripts/verify-source.py --chain-id 4663 \
  --rpc-url https://rpc.ctrl.finance \
  --output verification/live-verification.json
```

The verifier rejects the wrong chain and chooses one latest block. For each
contract it substitutes recorded constructor immutable values into the
compiler-declared runtime offsets, compares every byte with `eth_getCode`,
and checks the runtime Keccak hash against the deployment manifest. This
includes metadata and immutable slots. It also records current factory pause
state and launch count, then rechecks the block hash.

Arc immutable values in its provenance record come from the manifest's original
`stateChecks`; Robinhood records them under `compiledRuntimeChecks`. The final
whole-runtime comparison checks those values against deployed code.

These operations use read-only RPC methods. No key is required and no transaction
is signed or broadcast. Historical deployment manifests remain unchanged; live
reports are observations at the block and timestamp recorded in each report.

## Tests

```bash
forge test
./scripts/test-immutable-deployment.sh
```

`CtrlNativeLaunchpad.t.sol` exercises the native-currency contracts locally,
including fee splits, claims, graduation, fixed economics, and absent upgrade
entry points. Its base fixture uses Robinhood-equivalent economic parameters;
it is not a replay of the Arc mainnet deployment. The live verifier checks the
actual deployed Arc values.

Optional Arc fork suite:

```bash
RUN_ARC_FORK_TESTS=true ARC_MAINNET_RPC_URL=https://rpc.mainnet.arc.io \
  forge test --match-contract CtrlArcForkTest
```

This suite defaults to block `21,173,458`, with an optional
`ARC_FORK_BLOCK_NUMBER` override. It creates a fresh local launch stack against
the real Arc PoolManager and PositionManager. It tests dependency fingerprints,
position custody, approval cleanup, four swap modes, graduation, and claims.
Exact-output swaps use a test helper router; they do not constitute a test of
every deployed aggregator or Universal Router version.

For Circle's Arc Foundry runtime, which models native-USDC restrictions beyond
standard Foundry's EVM fork:

```bash
RUN_ARC_FORK_TESTS=true ARC_MAINNET_RPC_URL=https://rpc.mainnet.arc.io \
  arc-forge test --network arc --match-contract CtrlArcForkTest
```

`arc-forge` denotes the separately installed Arc Foundry binary (the deployment
record identifies version `v0.8.0-1`). The RPC must retain state for the chosen
block. All fork tests run locally and never broadcast.

The existing Robinhood suite specifically exercising its deployed Universal
Router is:

```bash
RH_MAINNET_RPC_URL=https://rpc.ctrl.finance ./scripts/test-immutable-fork.sh
```

## Explorer verification

The manifests link Sourcify records for all seven contracts on each chain,
with exact creation/runtime matches recorded at deployment:

- [Arc hook](https://repo.sourcify.dev/5042/0xE0e48AE841741c1C5A6eFa1DEe2838E62d5168CC)
- [Robinhood hook](https://repo.sourcify.dev/4663/0x5aE59a607FBE48e62270272Ee0eC266a544368cc)

Arc's original [hook Standard JSON input](../verification/5042-mainnet/CtrlNativeLaunchHook.standard-input.json)
is included, alongside the other six inputs. Use compiler
`v0.8.26+commit.8a97fa7a` and the encoded constructor arguments recorded in the
manifest when verifying on an explorer.

For Robinhood, generate an equivalent input with:

```bash
forge verify-contract 0x5aE59a607FBE48e62270272Ee0eC266a544368cc \
  src/CtrlLaunchHookV1.sol:CtrlLaunchHookV1 --chain 4663 \
  --show-standard-json-input > hook-standard-input.json
```

Sourcify verification is source/bytecode matching. A provider may additionally
require matching verification in its preferred explorer, a funded example pool,
and its own hook review. This repository does not certify those provider approvals.
The [published security report](https://docs.ctrl.finance/security-audit) names
the earlier V2 hook and does not establish audit coverage of the exact Arc build.

## Deployment scripts

`script/DeployCtrlArc.s.sol` and `script/DeployCtrl.s.sol` are preserved deployment
sources, including their CREATE2 helper contracts. Building them does not deploy
anything. No Arc broadcast wrapper is added by this publication; the commands
above only build, test, or read deployed state. Existing Robinhood wrappers
simulate by default and require explicit `--broadcast` to send transactions.

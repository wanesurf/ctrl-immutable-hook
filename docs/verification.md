# Reproduce and verify the deployed source

## Deterministic build

The original compiler was `0.8.26+commit.8a97fa7a`, with optimizer enabled at
200 runs, `viaIR: true`, Cancun EVM, IPFS bytecode metadata and CBOR metadata.
Source paths, source bytes and remappings all affect the metadata hash.

The publication retains original Solidity paths and bytes. Its explicit
`remappings.txt` contains the complete effective deployment remapping list,
including unused entries. Automatic remapping detection is disabled so a fresh
checkout produces the same compiler input despite carrying only required files.

```bash
forge build
python3 scripts/verify-source.py
```

The verifier fails on a modified copied file, a changed contract creation-bytecode
fingerprint, or changed compiler metadata. It also checks the hook ABI for upgrade
entry points. Expected metadata and source fingerprints come from the deployment
build, before this publication was assembled.

## Live bytecode comparison

```bash
python3 scripts/verify-source.py --rpc-url https://rpc.ctrl.finance \
  --output verification/live-verification.json
```

This reads chain ID 4663 and selects a single latest block. For each deployed
contract it substitutes the independently recorded constructor immutable values
into compiler-declared immutable offsets, compares every byte with `eth_getCode`
at that block, and checks the runtime Keccak hash against the deployment manifest.
It does not strip metadata or ignore immutable slots. The report also records
the current factory's paused state and total launch count. No transaction is signed
or sent.

## Explorer verification

The [public Sourcify record](https://repo.sourcify.dev/4663/0x5aE59a607FBE48e62270272Ee0eC266a544368cc)
reports exact creation and runtime matches. All seven new deployment records
and their verification links are in `deployments/4663-mainnet.json`.

The native [Blockscout Code tab](https://robinhoodchain.blockscout.com/address/0x5aE59a607FBE48e62270272Ee0eC266a544368cc?tab=contract)
has not yet been confirmed imported. API access returned a Cloudflare challenge
during the publication check. A source repository and Sourcify evidence should
not be described as completed native explorer verification.

Generate Solidity Standard JSON input for the hook's explorer verification:

```bash
forge verify-contract 0x5aE59a607FBE48e62270272Ee0eC266a544368cc \
  src/CtrlLaunchHookV1.sol:CtrlLaunchHookV1 --chain 4663 \
  --show-standard-json-input > hook-standard-input.json
```

Choose Solidity Standard JSON and compiler `v0.8.26+commit.8a97fa7a` in the
explorer. Constructor arguments, in order, are PoolManager, PositionManager,
fee vault, referral registry, and initializer. Their exact encoded value is
recorded under `constructorArguments.hook` in the deployment manifest.

## Deployment script

`script/DeployCtrl.s.sol` is retained byte-for-byte, including the small
`CtrlHookCreate2Deployer` contract deployed onchain. The wrappers under `scripts/`
simulate by default and require an explicit `--broadcast` argument to send
transactions. Publishing or running the verification instructions above does
not invoke those deployment wrappers. Rebuilding the source never changes the
existing deployment.

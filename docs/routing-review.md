# Arc routing and indexing integration

Ctrl's Arc deployment uses native USDC and a direct immutable Uniswap v4 hook.
This guide is intended for routing providers, indexers, and hook reviewers.
For product context, see [Ctrl documentation](https://docs.ctrl.finance/),
[Protocol & contracts](https://docs.ctrl.finance/protocol), and
[Rewards](https://docs.ctrl.finance/rewards).

## Deployment identity

| Field | Arc mainnet | Robinhood mainnet |
| --- | --- | --- |
| Chain ID | `5042` | `4663` |
| Native currency | USDC, 18 decimals | ETH, 18 decimals |
| Hook | `0xE0e48AE841741c1C5A6eFa1DEe2838E62d5168CC` | `0x5aE59a607FBE48e62270272Ee0eC266a544368cc` |
| Factory | `0x936eED62da1a4e7A7fb1fABFe2e10C4bCbD7B322` | `0xf10677910B82bBC6861ED78d7706174924DD767d` |
| Factory start block | `21178639` | `63851940` |
| Source | [CtrlNativeLaunchHook](../src/CtrlNativeLaunchHook.sol) | [CtrlLaunchHookV1](../src/CtrlLaunchHookV1.sol) |
| Manifest | [5042-mainnet.json](../deployments/5042-mainnet.json) | [4663-mainnet.json](../deployments/4663-mainnet.json) |
| Hook permission mask | `0x28cc` | `0x28cc` |

Both hooks implement `IHooks` directly. Neither uses a proxy, hook extensions,
subhooks, or hooklets. Both enable `beforeInitialize`, `beforeAddLiquidity`,
`beforeSwap`, `afterSwap`, `beforeSwapReturnDelta`, and `afterSwapReturnDelta`.
The return deltas are material to quoting and settlement; reviewing only the
core LP fee omits the Ctrl hook fee.

## Native-USDC units and canonical pools

Arc canonical pool keys contain:

```text
currency0  = 0x0000000000000000000000000000000000000000  // native USDC, 18 decimals
currency1  = launched token address                    // CtrlToken, 18 decimals
fee        = 0                                        // core LP fee
tickSpacing = 200
hooks      = 0xE0e48AE841741c1C5A6eFa1DEe2838E62d5168CC
```

One native USDC is `10^18` base units in transaction value, pool deltas, and vault
accounting. The USDC ERC-20 interface at
`0x3600000000000000000000000000000000000000` exposes six decimals. It is not a
second balance and must not replace `currency0` in the canonical pool key.
A pool containing that ERC-20 address is a different pool.

Some shared ABI names retain an `Eth` suffix (`netEthPrincipal`,
`creatorClaimableEth`, `initialBuyEth`). On Arc these represent **native USDC
with 18 decimals**. Interpret their units using the chain, not the field name.

For ARAIDERS (`0x318e2D646b698ed632694113fd870a0e98ab6054`), the canonical PoolId is
`0xabb4fad3bfadb04fa90c917b327180d20141f57520c8fb26b48e6138ceaf9220`.
Other pools can use the same token with different currencies, fees, or hooks.
Resolve Ctrl's pool using factory/hook records before quoting or attaching
launchpad attribution.

## Fees, quotes, and settlement

The Ctrl fee is fixed at **1%**, denominated in the native currency. It allocates
80% of the fee to the creator, 5% to an eligible registered referrer, 2.5% to the
bounty before graduation, and the remainder to the protocol. Ineligible referral
shares, rounding remainders, and the post-graduation bounty share go to the
protocol. Dynamic LP fees are disabled. Core LP fee is zero; any independently
configured Uniswap protocol fee must still be included by the quoting path.

Use a hook-aware v4 quote/simulation. All four swap modes accept empty hook data:
exact-input buy, exact-output buy, exact-input sell, and exact-output sell.
Optional attribution is `abi.encode(beneficiary, referrer)`. Wrong-length data
or noncanonical address words are treated as absent context. Referral eligibility
comes from the registry and the hook's checks; a supplied address alone is not
an entitlement. Native-specified modes enforce full fill.

`CtrlLaunchRouter` exposes exact-input buy/sell methods. A compatible v4 router
can invoke other modes through PoolManager. Router compatibility and discovery
by a particular aggregator require that provider's review; this publication
makes no allowlisting claim.

Fee backing remains in PoolManager as native-currency ERC-6909 claims belonging
to the vault. Claim functions burn those claims and pay the credited recipient.

## Liquidity and graduation

Initialization is restricted to registered Ctrl launches through the factory.
Only the initial PositionManager seed addition is accepted; later liquidity
additions revert. The seed position NFT is permanently held by the locker,
which has no withdrawal function.

On Arc, graduation occurs when net native principal crosses **10,027.332 USDC**.
Buys increase principal; sells reduce it, floored at zero. This is not a
cumulative-volume or market-cap threshold. The hook marks graduation and
releases the accrued bounty; it does not migrate liquidity, change the pool key,
or replace Uniswap's pricing function. The Robinhood threshold is **4.2 ETH**.

## Indexing and token metadata

- Start Arc factory discovery at block **21,178,639**, filtering `TokenLaunched`
  by the factory address above. The event contains token, creator, PoolId,
  position ID, payout, and optional initial-purchase details.
- Confirm `launchFactory()` and `poolId()` on the token, and `poolIdForToken()` /
  `poolKey()` on the hook. Track the complete PoolId, not token symbol alone.
- Use the factory's `getLaunch()` and hook's `getLaunch()` for registered launch
  state. Index `CreatorPayoutUpdated` when maintaining future reward attribution.
- Read `name`, `symbol`, `decimals`, `totalSupply`, `metadataURI`, `logoURI`,
  `description`, `website`, `x`, `telegram`, `discord`, and `farcaster` from
  [CtrlToken](../src/CtrlToken.sol). Resolve metadata URIs as needed.
- Index PoolManager `Swap` events for the canonical PoolIds, together with the
  hook's `FeeAccrued`, `PrincipalUpdated`, and `TokenGraduated` events. Account
  for hook fees when distinguishing pool amounts from trader settlement.
- Namespace all data by chain ID and address/PoolId. Identical addresses on two
  chains can refer to different contract roles.

Contract ABIs are in [`abi/`](../abi). The runtime application APIs are separate
from these contracts; integration should agree on any offchain metadata feed
rather than assume an undocumented endpoint schema.

## Immutability and authority

The hook's executable code and constructor configuration are fixed. Ordinary
balances, launch records, fee accounting, and graduation state change normally.

| Component | Authority or mutable state |
| --- | --- |
| Hook | Immutable dependencies, graduation threshold and initial tick. One-time factory binding complete; no hook administrator or upgrade authority. |
| Factory | Owner can pause/unpause future launches and transfer ownership. Creators can update their own future payout address. Dependencies, launch fee and initial tick are fixed. |
| Fee vault | Owner can update the treasury and transfer ownership. Already credited recipient balances cannot be reassigned. Hook binding is one-time and complete. |
| Referral registry | Referrers can set or update their own payout address for future attribution. |
| Router | Immutable hook and PoolManager; no administrator. |
| Position locker | Immutable PositionManager; one-time factory binding complete; no position withdrawal path. |
| Token | Fixed supply and no token owner; canonical PoolId can be set once by its factory. |
| CREATE2 deployer | Public deployment helper; no control over the deployed hook. |

Factory owner, vault owner, and treasury recorded at deployment on both chains:
`0x99Ffd2FdcaF29AFDDbbd49655F9331FF3AC1aA09` (Safe).

**Unreleased bounty reserves differ from credited rewards.** When the graduating
swap supplies no beneficiary, the hook assigns the accumulated reserve to the
vault's treasury at graduation. A treasury rotation before that event changes
this fallback recipient, including for reserves accrued earlier. Once released,
only the credited recipient can claim. This behavior matters when reviewing the
[V12 documentation](https://docs.ctrl.finance/security-audit), whose named hook
scope is the earlier V2 deployment.

## Evidence and review scope

- [Arc manifest](../deployments/5042-mainnet.json): constructor arguments,
  deployment transactions, code hashes, wiring, and Sourcify links.
- [Arc compiler inputs and provenance](../verification/5042-mainnet): deployed
  source bytes and reproducible build fingerprints.
- [Arc live report](../verification/5042-mainnet/live-verification.json): exact
  runtime and launch-state observations at its recorded block.
- [Verification guide](verification.md): reproducible checks on either chain.
- [Native launchpad tests](../test/CtrlNativeLaunchpad.t.sol): fee accounting,
  economics validation, graduation, claims, and absence of upgrade entry points.
- [Arc fork tests](../test/CtrlArcFork.t.sol): production PoolManager and
  PositionManager, locked positions, four swap modes, graduation, and claims.
  The helper router in this suite is a test router, not the deployed Universal Router.
- [Robinhood routing tests](../test/CtrlImmutableRouting.t.sol) and
  [Universal Router fork tests](../test/CtrlImmutableRouterFork.t.sol).

The manifests contain historical paused-state observations. Rerun the read-only
verifier for current status. Source verification, local tests, and fork tests
are distinct from independent auditing and routing-provider approval. No
independent audit of the exact immutable Arc deployment is recorded here.

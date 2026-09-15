# Uniswap routing review guide

## Submission identity

| Field | Value |
| --- | --- |
| Hook name | Ctrl Immutable Launch Hook |
| Hook address | `0x5aE59a607FBE48e62270272Ee0eC266a544368cc` |
| Chain | Robinhood Chain mainnet, 4663 |
| Source entry point | [`src/CtrlLaunchHookV1.sol`](../src/CtrlLaunchHookV1.sol) |
| Website | https://ctrl.finance |
| Permission mask | `0x28cc` |
| Dynamic fees | No |
| Independent audit for this deployment | None |

## Hook behavior

Enabled callbacks are `beforeInitialize`, `beforeAddLiquidity`, `beforeSwap`,
and `afterSwap`, with both swap-return-delta flags. Because it uses return
deltas, this hook requires manual review under the
[submission form's criteria](https://developers.uniswap.org/hook-allowlist).

The fixed 1% hook fee is denominated in native ETH. Its allocations are 80% to
the creator, 5% to an eligible registered referrer, 2.5% to the graduation bounty
before graduation, and the remainder to the protocol treasury. Rounding and
ineligible referral amounts fall into the remainder. After graduation the
bounty allocation also falls into the protocol remainder.

The hook mints native-ETH ERC-6909 claims to `CtrlFeeVault` in the PoolManager.
The vault records recipient-specific liabilities and supports pull claims.
Graduation at 4.2 ETH net principal releases accumulated bounty claims without
migrating liquidity. If optional hook data omits a beneficiary, the bounty is
assigned to the vault treasury.

Empty hook data is accepted in all four modes: exact-input and exact-output,
buy and sell. The optional context is `abi.encode(beneficiary, referrer)`.
Wrong-length data or noncanonical address words are treated as absent context.
The native-specified modes enforce full fill. Relevant tests cover all four
modes, fee rounding, protocol fee accrual, and optional attribution.

Pools are restricted to registered Ctrl tokens paired with native ETH, zero
core LP fee and tick spacing 200. Initialization occurs through the factory.
Only the initial PositionManager seed addition is accepted; subsequent liquidity
additions revert. The locker has no withdrawal function for the initial position.
These liquidity restrictions must be disclosed in the routing review.

## Immutability and authority

The hook's executable code is fixed and executes directly. No upgrade authority
exists. Ordinary balances and protocol state continue to change.

| Component | Authority or mutable state |
| --- | --- |
| Hook | Five immutable constructor dependencies; one-time factory binding already completed. Launch state, fee accounting, principal and graduation state change through the protocol. |
| Factory | Safe owner can pause or open future launches and use inherited two-step ownership transfer. Creators can update their own future payout address. Dependency addresses and launch parameters are fixed. |
| Fee vault | Safe owner can change the treasury for future allocations and use inherited two-step ownership transfer. This does not redirect already credited balances. Hook binding is one-time and complete. |
| Referral registry | A referrer can set or update their own payout address for future attribution. |
| Router | Immutable hook and PoolManager; no administrator. |
| Position locker | Immutable PositionManager; one-time factory binding complete; no position withdrawal path. |
| Token | Fixed supply, ownerless token; canonical PoolId can be set once by its factory. |
| CREATE2 deployer | Public deployment helper; no control over the deployed hook. |

Factory and vault owner at deployment:
`0x99Ffd2FdcaF29AFDDbbd49655F9331FF3AC1aA09` (Safe).

## Evidence map

- [Deployment manifest](../deployments/4663-mainnet.json): addresses, constructor
  arguments, CREATE2 salt, receipts, code hashes, wiring and historical verification.
- [Live verification report](../verification/live-verification.json): runtime and
  paused-state observations at a recorded block, generated from this repository.
- [Build verification](verification.md): source hashes, exact metadata and bytecode reproduction.
- [`CtrlImmutableRouting.t.sol`](../test/CtrlImmutableRouting.t.sol): four swap
  modes with empty data, hook fee deltas and core protocol-fee regressions.
- [`CtrlImmutableRouterFork.t.sol`](../test/CtrlImmutableRouterFork.t.sol): the
  deployed Universal Router on a Robinhood fork.
- [`CtrlLaunchpad.t.sol`](../test/CtrlLaunchpad.t.sol),
  [`CtrlInvariant.t.sol`](../test/CtrlInvariant.t.sol),
  [`CtrlFactoryPoolBinding.t.sol`](../test/CtrlFactoryPoolBinding.t.sol): protocol
  accounting, solvency and pool-binding checks.
- [`DeployCtrlImmutable.t.sol`](../test/DeployCtrlImmutable.t.sol): deployment
  wiring, paused launch state and absence of upgrade entry points.

## Submission status

The source publication does not submit or complete the allowlist application.
At publication the new factory is paused and no funded demonstration pool is
recorded. Existing tokens continue using their original hook and pools.

Uniswap's [form](https://developers.uniswap.org/hook-allowlist) requires a pool
using this exact hook with nonzero liquidity, submitter contact details, and
matching source verification on the chain's explorer. Sourcify reports an exact
creation and runtime match; native Blockscout Code-tab import remains unconfirmed.
The applicant should confirm that explorer evidence before submitting. The form
also requires the submitter to accept Uniswap's terms.

No independent audit covers this immutable deployment. Tests, verification and
publication do not imply audit coverage or Uniswap routing approval.

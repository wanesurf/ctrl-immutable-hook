#!/usr/bin/env bash
set -euo pipefail

: "${RH_MAINNET_RPC_URL:?Set RH_MAINNET_RPC_URL}"
cd "$(dirname "$0")/.."
# Compile before selecting a block: pruned RPCs may discard its state during compilation.
forge build
fork_block="${RH_FORK_BLOCK_NUMBER:-$(cast block-number --rpc-url "$RH_MAINNET_RPC_URL")}"
if [[ ! "$fork_block" =~ ^[1-9][0-9]*$ ]]; then
  echo "RH_FORK_BLOCK_NUMBER must be a positive decimal block number" >&2
  exit 1
fi
export RUN_RH_FORK_TESTS=true RH_FORK_BLOCK_NUMBER="$fork_block"
echo "Immutable hook / official Universal Router rehearsal at block $fork_block"
forge test --match-contract '^CtrlImmutableRouterForkTest$' -vvv

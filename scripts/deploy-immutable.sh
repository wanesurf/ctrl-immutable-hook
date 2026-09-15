#!/usr/bin/env bash
set -euo pipefail

# Simulation is the default. Never infer permission to send transactions from env.
args=()
case "${1:-}" in
  "") ;;
  --broadcast) args+=(--broadcast) ;;
  --help|-h)
    echo "Usage: $0 [--broadcast]"
    echo "Deploy a new direct CtrlLaunchHookV1 stack; simulation only unless --broadcast is supplied."
    exit 0
    ;;
  *) echo "Usage: $0 [--broadcast]" >&2; exit 2 ;;
esac
if (( $# > 1 )); then
  echo "Usage: $0 [--broadcast]" >&2
  exit 2
fi

: "${RPC_URL:?Set RPC_URL}"
: "${PRIVATE_KEY:?Set PRIVATE_KEY in the environment}"
: "${OWNER:?Set OWNER explicitly}"
: "${TREASURY:?Set TREASURY explicitly}"
: "${EXPECTED_CHAIN_ID:?Set EXPECTED_CHAIN_ID explicitly}"
: "${POOL_MANAGER_CODEHASH:?Set POOL_MANAGER_CODEHASH from reviewed deployment evidence}"
: "${POSITION_MANAGER_CODEHASH:?Set POSITION_MANAGER_CODEHASH from reviewed deployment evidence}"
: "${PERMIT2_CODEHASH:?Set PERMIT2_CODEHASH from reviewed deployment evidence}"

cd "$(dirname "$0")/.."
forge script script/DeployCtrl.s.sol:DeployCtrl --rpc-url "$RPC_URL" ${args[@]+"${args[@]}"}

#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/bin"
cat > "$scratch/bin/forge" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$CAPTURE_ARGS"
exit "${FORGE_STATUS:-0}"
STUB
chmod +x "$scratch/bin/forge"
export PATH="$scratch/bin:$PATH"
export CAPTURE_ARGS="$scratch/args"
export RPC_URL=http://127.0.0.1:8545 PRIVATE_KEY=1 OWNER=fixture TREASURY=fixture EXPECTED_CHAIN_ID=31337
export POOL_MANAGER_CODEHASH=fixture POSITION_MANAGER_CODEHASH=fixture PERMIT2_CODEHASH=fixture

"$repo_root/scripts/deploy-immutable.sh"
if grep -q -- '--broadcast' "$CAPTURE_ARGS"; then
  echo "Default invocation unexpectedly broadcasts" >&2
  exit 1
fi
"$repo_root/scripts/deploy.sh" --broadcast
grep -qx -- '--broadcast' "$CAPTURE_ARGS"

for flag in --skip-simulation --resume --unknown; do
  if "$repo_root/scripts/deploy-immutable.sh" "$flag" >/dev/null 2>&1; then
    echo "Unexpectedly accepted $flag" >&2
    exit 1
  fi
done
if "$repo_root/scripts/deploy-immutable.sh" --broadcast --broadcast >/dev/null 2>&1; then
  echo "Unexpectedly accepted extra arguments" >&2
  exit 1
fi
if (unset OWNER; "$repo_root/scripts/deploy-immutable.sh" >/dev/null 2>&1); then
  echo "Unexpectedly accepted a missing owner" >&2
  exit 1
fi
if FORGE_STATUS=7 "$repo_root/scripts/deploy-immutable.sh" >/dev/null 2>&1; then
  echo "Swallowed a failed forge invocation" >&2
  exit 1
fi
echo "Immutable deployment wrapper tests passed."

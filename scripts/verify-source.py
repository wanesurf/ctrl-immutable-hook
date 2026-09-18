#!/usr/bin/env python3
"""Verify the source snapshot and, optionally, live deployed runtime. Read-only."""

import argparse
import datetime
import hashlib
import json
from pathlib import Path
import subprocess
import urllib.request


ROOT = Path(__file__).resolve().parents[1]


def require(condition, message):
    if not condition:
        raise SystemExit(message)


def read_json(path):
    return json.loads((ROOT / path).read_text())


def nodes(value):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from nodes(child)
    elif isinstance(value, list):
        for child in value:
            yield from nodes(child)


def rpc(url, method, params):
    data = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    request = urllib.request.Request(url, data=data, headers={
        "Content-Type": "application/json", "User-Agent": "ctrl-source-verifier/1.0",
    })
    with urllib.request.urlopen(request, timeout=30) as response:
        result = json.load(response)
    require("error" not in result, f"RPC method {method} failed")
    return result["result"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--chain-id", type=int, choices=(5042, 4663), default=5042,
                        help="Deployment to verify: Arc 5042 (default) or Robinhood 4663")
    parser.add_argument("--rpc-url", help="Enable read-only checks against the selected chain")
    parser.add_argument("--output", type=Path, help="Write the JSON verification report")
    args = parser.parse_args()
    evidence = Path("verification/5042-mainnet" if args.chain_id == 5042 else "verification")
    provenance = read_json(evidence / "source-provenance.json")
    manifest = read_json(f"deployments/{args.chain_id}-mainnet.json")

    for path, digest in provenance["files"].items():
        require(hashlib.sha256((ROOT / path).read_bytes()).hexdigest() == digest,
                f"Copied file changed: {path}")

    artifacts = {}
    for component, expected in provenance["artifacts"].items():
        contract = expected["contract"]
        artifact_path = ROOT / "out" / Path(expected["source"]).name / f"{contract}.json"
        require(artifact_path.is_file(), "Build artifacts missing; run forge build first")
        artifact = json.loads(artifact_path.read_text())
        creation = bytes.fromhex(artifact["bytecode"]["object"].removeprefix("0x"))
        require(hashlib.sha256(creation).hexdigest() == expected["creationBytecodeSha256"],
                f"Creation bytecode mismatch: {contract}")
        require(json.loads(artifact["rawMetadata"]) == read_json(evidence / f"{contract}.metadata.json"),
                f"Compiler metadata mismatch: {contract}")
        require(artifact["abi"] == read_json(f"abi/{contract}.json"), f"ABI mismatch: {contract}")
        if args.chain_id == 5042:
            input_path = evidence / f"{contract}.standard-input.json"
            require(hashlib.sha256((ROOT / input_path).read_bytes()).hexdigest()
                    == manifest["constructorArguments"][component]["standardInputSha256"],
                    f"Deployment compiler input changed: {contract}")
            for source, entry in read_json(input_path)["sources"].items():
                require((ROOT / source).read_bytes() == entry["content"].encode(),
                        f"Source differs from deployment compiler input: {source}")
        artifacts[component] = artifact

    hook_functions = {entry["name"] for entry in artifacts["hook"]["abi"] if entry["type"] == "function"}
    require(not hook_functions.intersection({"upgradeTo", "upgradeToAndCall", "proxiableUUID", "upgradeAuthority"}),
            "Unexpected upgrade entry point in hook ABI")
    report = {
        "checkedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "chainId": args.chain_id,
        "sourceFilesVerified": len(provenance["files"]),
        "creationBytecodeAndMetadataVerified": list(artifacts),
        "hookUpgradeEntrypointsAbsent": True,
    }

    if args.rpc_url:
        chain_id = int(rpc(args.rpc_url, "eth_chainId", []), 16)
        require(chain_id == manifest["chainId"], "Unexpected chain ID")
        block = rpc(args.rpc_url, "eth_getBlockByNumber", ["latest", False])
        block_number = block["number"]
        report.update(chainId=chain_id, blockNumber=int(block_number, 16), blockHash=block["hash"])
        report["runtimeChecks"] = {}
        for component, artifact in artifacts.items():
            runtime = bytearray.fromhex(artifact["deployedBytecode"]["object"].removeprefix("0x"))
            variables = {str(node["id"]): node["name"] for node in nodes(artifact["ast"])
                         if node.get("nodeType") == "VariableDeclaration" and node.get("mutability") == "immutable"}
            values = (provenance["artifacts"][component]["immutableValues"] if args.chain_id == 5042
                      else manifest["compiledRuntimeChecks"][component]["immutableValues"])
            referenced_names = set()
            for variable_id, offsets in artifact["deployedBytecode"].get("immutableReferences", {}).items():
                name = variables[variable_id]
                referenced_names.add(name)
                require(name in values, f"Missing recorded immutable: {component}.{name}")
                for offset in offsets:
                    replacement = int(values[name], 16).to_bytes(offset["length"], "big")
                    start = offset["start"]
                    require(start + len(replacement) <= len(runtime), "Invalid immutable offset")
                    runtime[start:start + len(replacement)] = replacement
            require(referenced_names == set(values), f"Immutable binding set mismatch: {component}")
            address = manifest["addresses"][component]
            live = bytes.fromhex(rpc(args.rpc_url, "eth_getCode", [address, block_number]).removeprefix("0x"))
            require(live == runtime, f"Live runtime mismatch: {component}")
            code_hash = subprocess.check_output(["cast", "keccak", "0x" + live.hex()], text=True).strip()
            require(code_hash.lower() == manifest["codeHashes"][component].lower(),
                    f"Recorded runtime hash mismatch: {component}")
            report["runtimeChecks"][component] = {
                "address": address, "exactMatch": True, "runtimeBytes": len(live), "codeHash": code_hash,
            }
        factory = manifest["addresses"]["factory"]
        for signature, field in [("launchesArePaused()", "factoryPaused"), ("totalLaunches()", "totalLaunches")]:
            calldata = subprocess.check_output(["cast", "calldata", signature], text=True).strip()
            value = int(rpc(args.rpc_url, "eth_call", [{"to": factory, "data": calldata}, block_number]), 16)
            report[field] = bool(value) if field == "factoryPaused" else value
        confirmed_block = rpc(args.rpc_url, "eth_getBlockByNumber", [block_number, False])
        require(confirmed_block["hash"] == block["hash"], "Block changed during checks; rerun verification")

    output = json.dumps(report, indent=2) + "\n"
    if args.output:
        args.output.write_text(output)
    print(output, end="")


if __name__ == "__main__":
    main()

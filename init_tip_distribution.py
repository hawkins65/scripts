#!/usr/bin/env python3
"""
From Ghosty | Galaxy
Initialize Jito Tip Distribution Account for the current epoch.

During an identity rotation, the block producer (old identity) cannot call
initialize_tip_distribution_account because the on-chain program checks:
    signer == vote_account.node_pubkey
and the node_pubkey has already been updated to the new identity.

This script runs on the machine that holds the NEW identity keypair
(which matches node_pubkey) to create the TDA externally. Once the TDA
exists, the block producer's crank only needs change_tip_receiver +
change_block_builder (crank2), which has no identity check.

Usage:
    python3 init_tip_distribution.py \
        --identity /path/to/new-identity.json \
        --vote-account <VOTE_ACCOUNT_PUBKEY> \
        --rpc https://api.mainnet-beta.solana.com \
        [--tip-distribution-program 4R3gSG8BpU4t19KYj8CfnbtRpnT8gtk4dvTHxVRwc2r7] \
        [--merkle-root-authority 8F4jGUmxF36vQ6yabnsxX6AQVXdKBhs8kGSUuRKSg8Xt] \
        [--commission-bps 2500] \
        [--dry-run]
"""

import argparse
import json
import struct
import sys
import urllib.request
from hashlib import sha256

from solders.pubkey import Pubkey
from solders.keypair import Keypair
from solders.system_program import ID as SYSTEM_PROGRAM_ID
from solders.transaction import Transaction
from solders.message import Message
from solders.instruction import Instruction, AccountMeta
from solders.hash import Hash


def load_keypair(path: str) -> Keypair:
    with open(path) as f:
        secret = json.load(f)
    return Keypair.from_bytes(bytes(secret[:64]))


def get_epoch_info(rpc_url: str) -> dict:
    payload = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "getEpochInfo"}).encode()
    req = urllib.request.Request(rpc_url, data=payload, headers={"Content-Type": "application/json"})
    resp = urllib.request.urlopen(req, timeout=15)
    return json.loads(resp.read())["result"]


def get_recent_blockhash(rpc_url: str) -> str:
    payload = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "getLatestBlockhash"}).encode()
    req = urllib.request.Request(rpc_url, data=payload, headers={"Content-Type": "application/json"})
    resp = urllib.request.urlopen(req, timeout=15)
    return json.loads(resp.read())["result"]["value"]["blockhash"]


def account_exists(rpc_url: str, pubkey: str) -> bool:
    payload = json.dumps({
        "jsonrpc": "2.0", "id": 1,
        "method": "getAccountInfo",
        "params": [pubkey, {"encoding": "base64"}]
    }).encode()
    req = urllib.request.Request(rpc_url, data=payload, headers={"Content-Type": "application/json"})
    resp = urllib.request.urlopen(req, timeout=10)
    return json.loads(resp.read())["result"]["value"] is not None


def get_node_pubkey(rpc_url: str, vote_account: str) -> str:
    payload = json.dumps({
        "jsonrpc": "2.0", "id": 1,
        "method": "getAccountInfo",
        "params": [vote_account, {"encoding": "jsonParsed"}]
    }).encode()
    req = urllib.request.Request(rpc_url, data=payload, headers={"Content-Type": "application/json"})
    resp = urllib.request.urlopen(req, timeout=10)
    return json.loads(resp.read())["result"]["value"]["data"]["parsed"]["info"]["nodePubkey"]


def send_transaction(rpc_url: str, tx_bytes: bytes, dry_run: bool = False) -> str:
    import base64
    tx_b64 = base64.b64encode(tx_bytes).decode()

    if dry_run:
        payload = json.dumps({
            "jsonrpc": "2.0", "id": 1,
            "method": "simulateTransaction",
            "params": [tx_b64, {"encoding": "base64"}]
        }).encode()
        req = urllib.request.Request(rpc_url, data=payload, headers={"Content-Type": "application/json"})
        resp = urllib.request.urlopen(req, timeout=30)
        result = json.loads(resp.read())
        sim = result["result"]["value"]
        if sim["err"]:
            print(f"Simulation FAILED: {sim['err']}")
            for log in sim.get("logs", []):
                print(f"  {log}")
            return None
        else:
            print("Simulation SUCCESS")
            for log in sim.get("logs", []):
                print(f"  {log}")
            return "dry-run"
    else:
        payload = json.dumps({
            "jsonrpc": "2.0", "id": 1,
            "method": "sendTransaction",
            "params": [tx_b64, {"encoding": "base64", "skipPreflight": False}]
        }).encode()
        req = urllib.request.Request(rpc_url, data=payload, headers={"Content-Type": "application/json"})
        resp = urllib.request.urlopen(req, timeout=30)
        result = json.loads(resp.read())
        if "error" in result:
            print(f"Send FAILED: {result['error']}")
            return None
        return result["result"]


def main():
    parser = argparse.ArgumentParser(description="Initialize Jito TDA for current epoch")
    parser.add_argument("--identity", required=True, help="Path to new identity keypair JSON")
    parser.add_argument("--vote-account", required=True, help="Vote account pubkey")
    parser.add_argument("--rpc", default="https://api.mainnet-beta.solana.com", help="RPC URL")
    parser.add_argument("--tip-distribution-program", default="4R3gSG8BpU4t19KYj8CfnbtRpnT8gtk4dvTHxVRwc2r7")
    parser.add_argument("--merkle-root-authority", default="8F4jGUmxF36vQ6yabnsxX6AQVXdKBhs8kGSUuRKSg8Xt")
    parser.add_argument("--commission-bps", type=int, default=2500)
    parser.add_argument("--dry-run", action="store_true", help="Simulate only, don't send")
    args = parser.parse_args()

    # Load keypair
    identity = load_keypair(args.identity)
    print(f"Identity: {identity.pubkey()}")

    # Verify identity matches node_pubkey
    vote_account = Pubkey.from_string(args.vote_account)
    node_pubkey = get_node_pubkey(args.rpc, args.vote_account)
    print(f"Vote account: {vote_account}")
    print(f"On-chain node_pubkey: {node_pubkey}")

    if str(identity.pubkey()) != node_pubkey:
        print(f"ERROR: identity ({identity.pubkey()}) != node_pubkey ({node_pubkey})")
        print("This script must be run with the keypair matching the vote account's node_pubkey")
        sys.exit(1)
    print("Identity matches node_pubkey ✓")

    # Get current epoch
    epoch_info = get_epoch_info(args.rpc)
    epoch = epoch_info["epoch"]
    print(f"Current epoch: {epoch}")

    # Derive TDA PDA
    tip_dist_program = Pubkey.from_string(args.tip_distribution_program)
    tda_pda, tda_bump = Pubkey.find_program_address(
        [b"TIP_DISTRIBUTION_ACCOUNT", bytes(vote_account), struct.pack("<Q", epoch)],
        tip_dist_program
    )
    print(f"TDA PDA: {tda_pda} (bump: {tda_bump})")

    # Check if already exists
    if account_exists(args.rpc, str(tda_pda)):
        print("TDA already exists for this epoch. Nothing to do.")
        sys.exit(0)
    print("TDA does not exist — creating...")

    # Derive config PDA
    config_pda, _ = Pubkey.find_program_address([b"CONFIG_ACCOUNT"], tip_dist_program)

    # Build instruction data
    # Anchor discriminator for initialize_tip_distribution_account
    discriminator = bytes([120, 191, 25, 182, 111, 49, 179, 55])
    merkle_authority = Pubkey.from_string(args.merkle_root_authority)
    ix_data = (
        discriminator
        + bytes(merkle_authority)
        + struct.pack("<H", args.commission_bps)
        + struct.pack("B", tda_bump)
    )

    # Build instruction
    ix = Instruction(
        tip_dist_program,
        ix_data,
        [
            AccountMeta(config_pda, is_signer=False, is_writable=False),
            AccountMeta(tda_pda, is_signer=False, is_writable=True),
            AccountMeta(vote_account, is_signer=False, is_writable=False),
            AccountMeta(identity.pubkey(), is_signer=True, is_writable=True),
            AccountMeta(SYSTEM_PROGRAM_ID, is_signer=False, is_writable=False),
        ]
    )

    # Build and sign transaction
    blockhash = get_recent_blockhash(args.rpc)
    msg = Message.new_with_blockhash([ix], identity.pubkey(), Hash.from_string(blockhash))
    tx = Transaction.new_unsigned(msg)
    tx.sign([identity], Hash.from_string(blockhash))

    print(f"Transaction built, blockhash: {blockhash}")
    print(f"{'Simulating' if args.dry_run else 'Sending'}...")

    sig = send_transaction(args.rpc, bytes(tx), dry_run=args.dry_run)
    if sig:
        print(f"{'Simulation' if args.dry_run else 'Transaction'} OK: {sig}")
    else:
        sys.exit(1)


if __name__ == "__main__":
    main()

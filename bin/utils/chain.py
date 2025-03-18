import subprocess
import json
import time
from typing import Optional, Dict, Any, List

class Chain:
    """Chain interaction utilities"""

    def __init__(self, network: str):
        self.network = network
        self.rpc_url = self._get_rpc_url(network)
        self.chain_id = self._get_chain_id()
        self.is_local = network.startswith("local")

    def _get_rpc_url(self, network: str) -> str:
        """Get RPC URL for network"""
        if network.startswith("local"):
            return "http://localhost:8545"

        # Implementation would map network names to RPC URLs
        # Alternatively, read from config or env vars
        network_map = {
            "mainnet": "ETH_RPC_URL",
            "sepolia": "SEPOLIA_RPC_URL",
            # Add other networks as needed
        }

        import os
        env_var = network_map.get(network)
        if env_var and env_var in os.environ:
            return os.environ[env_var]

        raise ValueError(f"No RPC URL available for network {network}")

    def _get_chain_id(self) -> int:
        """Get chain ID from RPC endpoint"""
        cmd = ["cast", "chain-id", "--rpc-url", self.rpc_url]
        result = subprocess.run(cmd, capture_output=True, text=True)

        if result.returncode != 0:
            raise Exception(f"Failed to get chain ID: {result.stderr}")

        return int(result.stdout.strip())

    def get_current_timestamp(self) -> int:
        """Get current block timestamp"""
        return int(time.time())

    def get_nonce(self, address: str) -> int:
        """Get account nonce"""
        cmd = ["cast", "nonce", "--rpc-url", self.rpc_url, address]
        result = subprocess.run(cmd, capture_output=True, text=True)

        if result.returncode != 0:
            raise Exception(f"Failed to get nonce: {result.stderr}")

        return int(result.stdout.strip())

    def get_balance(self, address: str) -> int:
        """Get account balance"""
        cmd = ["cast", "balance", "--rpc-url", self.rpc_url, address]
        result = subprocess.run(cmd, capture_output=True, text=True)

        if result.returncode != 0:
            raise Exception(f"Failed to get balance: {result.stderr}")

        return int(result.stdout.strip())

    def impersonate_account(self, address: str) -> bool:
        """Impersonate account (local only)"""
        if not self.is_local:
            raise ValueError("Cannot impersonate account on non-local network")

        cmd = ["cast", "rpc", "--rpc-url", self.rpc_url, "anvil_impersonateAccount", f'["{address}"]']
        result = subprocess.run(cmd, capture_output=True, text=True)

        if result.returncode != 0:
            raise Exception(f"Failed to impersonate account: {result.stderr}")

        return True

    def fund_account(self, address: str, amount: str = "100ether") -> bool:
        """Fund account with ETH (local only)"""
        if not self.is_local:
            raise ValueError("Cannot fund account on non-local network")

        # Convert amount to hex
        cmd_amount = ["cast", "--to-wei", amount.replace("ether", "")]
        amount_result = subprocess.run(cmd_amount, capture_output=True, text=True)
        if amount_result.returncode != 0:
            raise Exception(f"Failed to convert amount: {amount_result.stderr}")

        hex_amount = f"0x{int(amount_result.stdout.strip()):x}"

        # Set balance
        cmd = ["cast", "rpc", "--rpc-url", self.rpc_url, "anvil_setBalance", f'["{address}", "{hex_amount}"]']
        result = subprocess.run(cmd, capture_output=True, text=True)

        if result.returncode != 0:
            raise Exception(f"Failed to fund account: {result.stderr}")

        return True
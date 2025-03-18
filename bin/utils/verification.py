import subprocess
from typing import Dict, Any
from .chain import Chain

def verify_contract(contract_info: Dict[str, Any], chain: Chain, explorer: str = "etherscan") -> bool:
    """Verify contract on block explorer"""

    # Prepare verification command
    cmd = ["forge", "verify-contract", "--chain-id", str(chain.chain_id)]

    if explorer == "etherscan":
        cmd.extend(["--etherscan-api-key", get_etherscan_api_key()])

    # Add contract address and path
    cmd.extend([
        contract_info["address"],
        contract_info["contract_path"]
    ])

    # For proxies, special handling
    if contract_info.get("upgradeable"):
        cmd.append("--is-proxy")

    # Run verification
    result = subprocess.run(cmd, capture_output=True, text=True)

    if result.returncode != 0:
        print(f"Error verifying contract:")
        print(result.stderr)
        return False

    print(f"Successfully verified contract {contract_info['address']}")
    return True

def get_etherscan_api_key() -> str:
    """Get Etherscan API key from environment"""
    import os
    key = os.environ.get("ETHERSCAN_API_KEY")
    if not key:
        raise ValueError("ETHERSCAN_API_KEY environment variable not set")
    return key
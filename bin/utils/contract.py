from typing import Dict, Any, Optional, List

class Contract:
    """Contract representation with interaction methods"""

    def __init__(self, name: str, address: str, info: Dict[str, Any]):
        self.name = name
        self.address = address
        self.info = info

    def get_abi(self) -> List[Dict]:
        """Get contract ABI"""
        # Implementation would load ABI from artifacts
        pass

    def encode_function(self, function_name: str, args: List[Any]) -> str:
        """Encode function call to calldata"""
        import subprocess

        cmd = ["cast", "calldata", f"{function_name}({','.join(['string'] * len(args))})"]
        cmd.extend([str(arg) for arg in args])

        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode != 0:
            raise Exception(f"Failed to encode function: {result.stderr}")

        return result.stdout.strip()
from typing import Dict, List, Any, Optional
from .contract import Contract

class Transaction:
    """Transaction representation"""

    def __init__(self, contract: Contract, function_name: str, args: List[Any], value: int = 0):
        self.contract = contract
        self.function_name = function_name
        self.args = args
        self.value = value
        self.data = contract.encode_function(function_name, args)

    def to_dict(self) -> Dict:
        """Convert transaction to dictionary representation"""
        return {
            "to": self.contract.address,
            "data": self.data,
            "value": self.value
        }

class TransactionBatch:
    """Batch of transactions"""

    def __init__(self, description: str):
        self.description = description
        self.transactions = []

    def add(self, tx: Transaction):
        """Add transaction to batch"""
        self.transactions.append(tx)

    def to_dict(self) -> Dict:
        """Convert batch to dictionary representation"""
        return {
            "description": self.description,
            "transactions": [tx.to_dict() for tx in self.transactions]
        }
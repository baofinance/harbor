import os
import json
from pathlib import Path

class StateManager:
    def __init__(self, network_name):
        self.network_name = network_name
        self.state_dir = Path(os.getcwd()) / "deploy" / "state" / network_name
        self.state_file = self.state_dir / "deployed.json"

        os.makedirs(self.state_dir, exist_ok=True)

        self.load_state()

    def load_state(self):
        if self.state_file.exists():
            with open(self.state_file, 'r') as f:
                self.deployed_contracts = json.load(f)
        else:
            self.deployed_contracts = {}

    def save_state(self):
        with open(self.state_file, 'w') as f:
            json.dump(self.deployed_contracts, f, indent=2)

    def is_deployed(self, contract_name):
        return contract_name in self.deployed_contracts

    def get_address(self, contract_name):
        return self.deployed_contracts.get(contract_name)

    def set_deployed(self, contract_name, address):
        self.deployed_contracts[contract_name] = address
        self.save_state()

    def get_all_deployed(self):
        return self.deployed_contracts

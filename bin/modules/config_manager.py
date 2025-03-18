import os
import json
import yaml
from pathlib import Path

class ConfigManager:
    def __init__(self, network_name):
        self.network_name = network_name
        self.base_dir = Path(os.getcwd())

        self.network_config_path = self.base_dir / f"lib/bao-base/script/bcinfo.{network_name}.json"
        self.load_network_config()

        self.contracts_dir = self.base_dir / "deploy" / "contracts"
        os.makedirs(self.contracts_dir, exist_ok=True)

    def load_network_config(self):
        if not self.network_config_path.exists():
            raise FileNotFoundError(f"Network config not found: {self.network_config_path}")

        with open(self.network_config_path, 'r') as f:
            self.network_config = json.load(f)

    def get_network(self):
        return self.network_name

    def is_local_network(self):
        return self.network_name in ["local", "anvil", "localhost", "hardhat", "ganache"]

    def get_rpc_url(self):
        env_var_name = f"{self.network_name.upper()}_RPC_URL"
        rpc_url = os.environ.get(env_var_name)

        if not rpc_url and "rpc_url" in self.network_config:
            rpc_url = self.network_config["rpc_url"]

        if not rpc_url:
            raise ValueError(f"No RPC URL found for network {self.network_name}. "
                           f"Set {env_var_name} environment variable.")

        return rpc_url

    def get_private_key(self):
        return os.environ.get("PRIVATE_KEY")

    def get_contract_config(self, contract_name):
        contract_path = self.contracts_dir / f"{contract_name}.yaml"

        if not contract_path.exists():
            raise FileNotFoundError(f"Contract config not found: {contract_path}")

        with open(contract_path, 'r') as f:
            config = yaml.safe_load(f)

        self._process_variables(config)

        return config

    def get_address(self, key):
        if key in self.network_config and "address" in self.network_config[key]:
            return self.network_config[key]["address"]
        return None

    def _process_variables(self, config):
        def process_value(value):
            if isinstance(value, str) and value.startswith("$"):
                var_name = value[1:].lower()

                if var_name in self.network_config and "address" in self.network_config[var_name]:
                    return self.network_config[var_name]["address"]

                env_value = os.environ.get(value[1:])
                if env_value:
                    return env_value

                return value
            return value

        def walk_dict(d):
            for k, v in d.items():
                if isinstance(v, dict):
                    walk_dict(v)
                elif isinstance(v, list):
                    for i, item in enumerate(v):
                        if isinstance(item, dict):
                            walk_dict(item)
                        else:
                            d[k][i] = process_value(item)
                else:
                    d[k] = process_value(v)

        walk_dict(config)

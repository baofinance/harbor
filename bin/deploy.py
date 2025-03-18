#!/usr/bin/env python3
# filepath: bin/deploy

import os
import sys
import argparse
import yaml
import json
import subprocess
from pathlib import Path
import shutil
import logging

sys.path.append(os.path.join(os.path.dirname(__file__), "modules"))

from config_manager import ConfigManager
from state_manager import StateManager

class CustomLogger(logging.Logger):
    def __init__(self, name, level=logging.NOTSET):
        super().__init__(name, level)

    def setVerbosity(self, verbosity):
        self.verbosity = verbosity

    def _log(self, level, msg, args, exc_info=None, extra=None, stack_info=False, stacklevel=1):
        if self.verbosity >= 1:
            frame = sys._getframe(3)
            filename = frame.f_code.co_filename
            lineno = frame.f_lineno
            msg = f"{msg} ({filename}:{lineno})"
        super()._log(level, msg, args, exc_info, extra, stack_info, stacklevel)

def setup_logging(verbosity):
    log_level = logging.WARNING  # Default log level
    if verbosity == 1:
        log_level = logging.INFO
    elif verbosity == 2:
        log_level = logging.DEBUG
    elif verbosity >= 3:
        log_level = logging.NOTSET

    logging.setLoggerClass(CustomLogger)
    logger = logging.getLogger("deploy")
    logger.setLevel(log_level)
    logger.setVerbosity(verbosity)
    logging.basicConfig(level=log_level, format='%(levelname)s - %(message)s')

def main():
    parser = argparse.ArgumentParser(description="Ethereum Contract Deployment Engine")
    parser.add_argument("--rpc-url", required=True, help="RPC URL to deploy to")
    parser.add_argument("--config", required=True, help="Deployment configuration file")
    parser.add_argument("--simulate", action="store_true", help="Simulate without broadcasting")
    parser.add_argument("--force", action="store_true", help="Force redeployment")
    parser.add_argument("-v", "--verbose", action="count", default=1, help="Increase verbosity level")

    args = parser.parse_args()

    setup_logging(args.verbose)

    chain_id = get_chain_id(args.rpc_url)
    network_name = get_network_name(chain_id)
    config = ConfigManager(network_name)
    state = StateManager(network_name)

    config_file = args.config
    if not config_file.endswith(".yaml"):
        config_file += ".yaml"
    config_path = Path("deploy") / config_file

    try:
        with open(config_path, 'r') as f:
            deploy_config = yaml.safe_load(f)
    except FileNotFoundError:
        logging.error(f"Configuration file not found: {config_path}")
        sys.exit(1)

    for contract in deploy_config.get("contracts", []):
        deploy_contract(contract, config, state, args.simulate, args.force)

def get_chain_id(rpc_url):
    try:
        result = subprocess.run(["cast", "chain-id", "--rpc-url", rpc_url], capture_output=True, text=True, check=True)
        chain_id = int(result.stdout.strip())
        logging.info(f"Chain ID: {chain_id}")
        return chain_id
    except subprocess.CalledProcessError as e:
        logging.error(f"Failed to get chain ID from {rpc_url}: {e}")
        sys.exit(1)

def get_network_name(chain_id):
    networks_path = Path(os.getcwd()) / "lib" / "bao-base" / "script" / "networks.json"
    try:
        with open(networks_path, 'r') as f:
            networks = json.load(f)
        network_name = networks.get(str(chain_id), f"unknown-{chain_id}")
        logging.info(f"Network name: {network_name}")
        return network_name
    except FileNotFoundError:
        logging.error(f"Network config file not found: {networks_path}")
        sys.exit(1)

def deploy_contract(contract_name, config, state, simulate=False, force=False):
    if state.is_deployed(contract_name) and not force:
        logging.info(f"Contract {contract_name} already deployed at {state.get_address(contract_name)}")
        print("Use --force to redeploy")
        return

    contract_info = config.get_contract_config(contract_name)

    logging.info(f"Deploying {contract_name}...")

    is_upgradeable = contract_info.get("upgradeable", False)

    if is_upgradeable:
        cmd = build_upgradeable_deploy_cmd(contract_name, contract_info, config, simulate)
    else:
        cmd = build_deploy_cmd(contract_name, contract_info, config, simulate)

    logging.debug(f"Running: {' '.join(cmd)}")

    if not simulate:
        try:
            result = subprocess.run(cmd, capture_output=True, text=True, check=True)
            address = parse_address_from_output(result.stdout, is_upgradeable)

            state.set_deployed(contract_name, address)
            logging.info(f"Successfully deployed {contract_name} at {address}")

            if "initialize" in contract_info and not simulate:
                initialize_contract(contract_name, address, contract_info["initialize"],
                                   config, state)

            # Copy build data to artifacts directory
            copy_build_data(contract_name, config)

        except subprocess.CalledProcessError as e:
            logging.error(f"Deployment failed with exit code {e.returncode}")
            logging.error(f"STDOUT: {e.stdout}")
            logging.error(f"STDERR: {e.stderr}")
            sys.exit(1)
    else:
        logging.info("Simulation complete (no transactions broadcast)")

def build_deploy_cmd(contract_name, contract_info, config, simulate):
    cmd = ["forge", "create"]
    cmd.extend([contract_info["source_file"] + ":" + contract_info.get("contract_name", contract_name)])

    if "constructor_args" in contract_info and contract_info["constructor_args"]:
        cmd.append("--constructor-args")
        for arg in contract_info["constructor_args"]:
            value = process_template_arg(arg["value"], config.state_manager)
            cmd.append(str(value))

    if "create2" in contract_info and contract_info["create2"].get("enabled", False):
        cmd.extend(["--create2", contract_info["create2"]["salt"]])

    cmd.extend(["--rpc-url", config.get_rpc_url()])

    if not simulate and not config.is_local_network() and config.get_private_key():
        cmd.extend(["--private-key", config.get_private_key()])

    if not simulate:
        cmd.append("--broadcast")

    return cmd

def build_upgradeable_deploy_cmd(contract_name, contract_info, config, simulate):
    cmd = ["forge", "script"]
    script_path = contract_info.get("deploy_script", "script/deploy.s.sol:Deploy")
    cmd.append(script_path)

    cmd.extend(["--rpc-url", config.get_rpc_url()])

    if not simulate:
        cmd.append("--broadcast")

    cmd.append("--ffi")

    if not simulate and not config.is_local_network() and config.get_private_key():
        cmd.extend(["--private-key", config.get_private_key()])

    return cmd

def parse_address_from_output(output, is_upgradeable):
    for line in output.splitlines():
        if "Deployed to:" in line or "Contract Address:" in line:
            parts = line.split(":")
            if len(parts) >= 2:
                return parts[1].strip()

    raise ValueError("Could not parse deployment address from output")

def process_template_arg(arg, state):
    if isinstance(arg, str):
        if arg.startswith("{{") and arg.endswith("}}"):
            contract_name = arg[2:-2]
            address = state.get_address(contract_name)
            if not address:
                raise ValueError(f"Contract {contract_name} not found in deployment state")
            return address

    return arg

def initialize_contract(contract_name, address, init_config, config, state):
    for init in init_config:
        function = init["function"]
        args = []

        if "args" in init:
            for arg in init["args"]:
                value = process_template_arg(arg["value"], state)
                args.append(str(value))

        cmd = ["cast", "send", address, function]
        cmd.extend(args)
        cmd.extend(["--rpc-url", config.get_rpc_url()])

        if not config.is_local_network() and config.get_private_key():
            cmd.extend(["--private-key", config.get_private_key()])

        logging.debug(f"Initializing {contract_name}: {' '.join(cmd)}")

        try:
            result = subprocess.run(cmd, capture_output=True, text=True, check=True)
            logging.info(f"Initialization successful: {result.stdout}")
        except subprocess.CalledProcessError as e:
            logging.error(f"Initialization failed: {e.stderr}")
            raise RuntimeError(f"Failed to initialize {contract_name}")

def get_implementation_address(proxy_address, config):
    impl_slot = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc"

    cmd = ["cast", "storage", proxy_address, impl_slot, "--rpc-url", config.get_rpc_url()]

    result = subprocess.run(cmd, capture_output=True, text=True, check=True)
    value = result.stdout.strip()

    impl_address = "0x" + value[-40:]

    return impl_address

def copy_build_data(contract_name, config):
    build_dir = Path(os.getcwd()) / "out" / contract_name
    artifacts_dir = Path(os.getcwd()) / "deploy" / "artifacts" / config.get_network()
    os.makedirs(artifacts_dir, exist_ok=True)

    if build_dir.exists():
        for item in build_dir.iterdir():
            if item.is_file():
                shutil.copy(item, artifacts_dir / item.name)
        logging.info(f"Copied build data for {contract_name} to {artifacts_dir}")
    else:
        logging.warning(f"Build directory for {contract_name} not found")

if __name__ == "__main__":
    main()
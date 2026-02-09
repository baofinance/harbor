#!/usr/bin/env python3
"""
Stability Pool Overflow Risk Analyzer

Checks all stability pools across all markets for uint192 integral overflow risk.
"""

import json
import subprocess
import sys
from dataclasses import dataclass
from decimal import Decimal
from typing import List, Optional

# Constants
UINT192_MAX = 6277101735386680763835789423207666416102355444464034512895
SECONDS_PER_WEEK = 7 * 24 * 60 * 60
PRECISION = 10**18


@dataclass
class PoolConfig:
    """Configuration for a stability pool."""

    peg: str
    collateral: str
    liquidation: str

    @property
    def name(self) -> str:
        return f"{self.peg}::{self.collateral}::{self.liquidation}"

    @property
    def predict_key(self) -> str:
        return f"harbor_v1::{self.peg}::{self.collateral}::stabilityPool{self.liquidation}"


@dataclass
class TokenRiskAnalysis:
    """Risk analysis for a single reward token."""

    address: str
    symbol: str
    integral: int
    exponent: int
    capacity_used_pct: float
    queued: int
    rate: int
    weekly_growth: float
    weeks_to_overflow: float
    risk_level: str


@dataclass
class PoolAnalysis:
    """Analysis results for a pool."""

    config: PoolConfig
    address: str
    deployed: bool
    total_deposits: int
    magnitude: int
    tokens: List[TokenRiskAnalysis]


def run_command(cmd: List[str], capture_stderr=False) -> str:
    """Run a shell command and return output."""
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, check=False)
        if result.returncode != 0:
            return ""
        return result.stdout.strip()
    except Exception:
        return ""


def get_pool_address(config: PoolConfig) -> Optional[str]:
    """Get the pool address using the predict script."""
    output = run_command(["script/predict", "--porcelain", config.predict_key])
    if not output:
        return None

    # Extract first 0x address
    for line in output.split("\n"):
        if line.startswith("0x") and len(line) == 42:
            return line
    return None


def is_deployed(address: str, rpc_url: str) -> bool:
    """Check if contract is deployed at address."""
    code = run_command(["cast", "code", address, "--rpc-url", rpc_url])
    return code not in ["", "0x"]


def call_contract(address: str, signature: str, args: List[str], rpc_url: str, block: str = "latest") -> Optional[str]:
    """Call a contract method."""
    cmd = ["cast", "call", address, signature] + args + ["--rpc-url", rpc_url, "--block", block]
    return run_command(cmd) or None


def parse_uint(value: str) -> int:
    """Parse a hex or decimal uint from cast output."""
    if not value:
        return 0
    value = value.strip()

    # Handle hex values
    if value.startswith("0x"):
        return int(value, 16)

    # Handle formatted output like "98435264931344887 [9.843e16]"
    # Extract just the first part (the decimal number)
    if '[' in value:
        value = value.split('[')[0].strip()

    return int(value)


def get_token_symbol(address: str, rpc_url: str, block: str = "latest") -> str:
    """Get ERC20 token symbol."""
    result = call_contract(address, "symbol()(string)", [], rpc_url, block)
    if result:
        # Cast returns quoted strings, clean them up
        return result.strip('"').strip()
    return "UNKNOWN"


def calculate_risk_level(capacity_pct: float) -> str:
    """Determine risk level based on capacity used."""
    if capacity_pct >= 90:
        return "🔴 CRITICAL"
    elif capacity_pct >= 80:
        return "🟠 HIGH"
    elif capacity_pct >= 60:
        return "🟡 MEDIUM"
    else:
        return "🟢 LOW"


def format_large_number(num: int) -> str:
    """Format large numbers for display."""
    if num == 0:
        return "0"
    elif num < 1e15:
        return f"{num:,}"
    else:
        return f"{num:.3e}"


def keccak256(data_hex: str) -> str:
    """Calculate keccak256 hash using cast."""
    result = run_command(["cast", "keccak", data_hex])
    return result if result else "0x0"


def get_storage_slot_for_integral(pool_addr: str, token_addr: str, exponent: int, rpc_url: str, block: str = "latest") -> int:
    """Calculate and read the storage slot for tokenToExponentToIntegral[token][exponent]."""

    # Base storage slot for MultipleRewardCompoundingAccumulatorStorage
    base_slot = 0x47ddc56aaabfe9761e2e64ce86720771c5fd1fd7ef0605da74e07d71de0e7900

    # tokenToExponentToIntegral is the second field (index 1) in the struct
    mapping_slot = base_slot + 1

    # For nested mapping(address => mapping(uint8 => uint192)):
    # First calculate keccak256(abi.encode(token_addr, mapping_slot))
    # abi.encode pads address to 32 bytes and uint256 to 32 bytes
    token_padded = token_addr[2:].lower().zfill(64)
    mapping_slot_padded = f"{mapping_slot:064x}"
    inner_key = f"0x{token_padded}{mapping_slot_padded}"
    inner_slot = keccak256(inner_key)

    # Then calculate keccak256(abi.encode(exponent, inner_slot))
    # exponent is uint8, but abi.encode pads it to 32 bytes
    exponent_padded = f"{exponent:064x}"
    inner_slot_clean = inner_slot[2:] if inner_slot.startswith("0x") else inner_slot
    final_key = f"0x{exponent_padded}{inner_slot_clean}"
    final_slot = keccak256(final_key)

    # Read the storage slot
    result = run_command(["cast", "storage", pool_addr, final_slot, "--rpc-url", rpc_url, "--block", block])

    if not result:
        return 0

    return parse_uint(result)


def analyze_token(
    pool_addr: str, token_addr: str, total_deposits: int, magnitude: int, rpc_url: str, block: str = "latest"
) -> Optional[TokenRiskAnalysis]:
    """Analyze a single reward token."""

    print(f"    DEBUG: Analyzing token {token_addr}...", file=sys.stderr)

    # Get token symbol
    symbol = get_token_symbol(token_addr, rpc_url, block)
    print(f"    DEBUG: Symbol: {symbol}", file=sys.stderr)

    # Get integral at exponent 0 by reading storage directly
    integral = get_storage_slot_for_integral(pool_addr, token_addr, 0, rpc_url, block)
    print(f"    DEBUG: Integral from storage: {integral}", file=sys.stderr)

    # Calculate capacity used
    capacity_pct = (integral / UINT192_MAX) * 100

    # Get reward data
    reward_data = call_contract(pool_addr, "rewardData(address)(uint96,uint256,uint64,uint64)", [token_addr], rpc_url, block)
    print(f"    DEBUG: Raw reward data: {repr(reward_data)}", file=sys.stderr)

    queued = 0
    rate = 0
    weekly_growth = 0
    weeks_to_overflow = float("inf")

    if reward_data:
        # Parse tuple: queued, rate, finishAt, lastUpdate
        # Cast returns formatted like "123 [1.23e2]\n456 [4.56e2]..." - filter out bracketed values
        parts = [p.strip() for p in reward_data.replace('\n', ' ').split() if p.strip() and not p.startswith('[')]
        print(f"    DEBUG: Parsed parts: {parts}", file=sys.stderr)
        if len(parts) >= 2:
            try:
                queued = parse_uint(parts[0])
                rate = parse_uint(parts[1])
            except (ValueError, IndexError) as e:
                print(f"    DEBUG: Error parsing reward data: {e}, parts: {parts}", file=sys.stderr)

            # Calculate weekly growth
            if total_deposits > 0 and rate > 0:
                reward_amount = rate * SECONDS_PER_WEEK
                magnitude_val = magnitude if magnitude > 0 else 10**36

                print("    DEBUG: Calculation inputs:", file=sys.stderr)
                print(f"      total_deposits: {total_deposits}", file=sys.stderr)
                print(f"      rate: {rate}", file=sys.stderr)
                print(f"      reward_amount (rate * SECONDS_PER_WEEK): {reward_amount}", file=sys.stderr)
                print(f"      magnitude_val: {magnitude_val}", file=sys.stderr)

                # toAdd = (reward_amount * PRECISION * magnitude_val) / total_deposits
                to_add = (reward_amount * PRECISION * magnitude_val) // total_deposits
                weekly_growth = float(to_add)

                print(f"      to_add (weekly integral growth): {to_add}", file=sys.stderr)
                print(f"      current integral: {integral}", file=sys.stderr)

                # Calculate weeks to overflow
                headroom = UINT192_MAX - integral
                print(f"      headroom (max - current): {headroom}", file=sys.stderr)

                if to_add > 0:
                    weeks_to_overflow = headroom / to_add
                    print(f"      weeks_to_overflow: {weeks_to_overflow}", file=sys.stderr)

    risk_level = calculate_risk_level(capacity_pct)

    return TokenRiskAnalysis(
        address=token_addr,
        symbol=symbol,
        integral=integral,
        exponent=0,
        capacity_used_pct=capacity_pct,
        queued=queued,
        rate=rate,
        weekly_growth=weekly_growth,
        weeks_to_overflow=weeks_to_overflow,
        risk_level=risk_level,
    )


def analyze_pool(config: PoolConfig, rpc_url: str, block: str = "latest") -> PoolAnalysis:
    """Analyze a stability pool."""

    # Get pool address
    address = get_pool_address(config)
    if not address:
        return PoolAnalysis(config=config, address="", deployed=False, total_deposits=0, magnitude=0, tokens=[])

    # Check if deployed
    if not is_deployed(address, rpc_url):
        return PoolAnalysis(config=config, address=address, deployed=False, total_deposits=0, magnitude=0, tokens=[])

    # Get total deposits (returns plain uint256)
    total_supply = call_contract(address, "totalAssetSupply()(uint256)", [], rpc_url, block)
    if not total_supply:
        return PoolAnalysis(config=config, address=address, deployed=True, total_deposits=0, magnitude=0, tokens=[])

    total_deposits = parse_uint(total_supply)

    # For overflow calculations, we need the magnitude from the internal Product
    # At exponent=0 (no significant losses), magnitude is typically 1e36
    # We'll use this standard value for calculations
    magnitude = 10**36  # Standard magnitude at exponent 0

    # Get active reward tokens
    active_tokens_result = call_contract(address, "activeRewardTokens()(address[])", [], rpc_url, block)

    token_analyses = []
    if active_tokens_result:
        # Parse array - cast returns '[0xAddr1, 0xAddr2, ...]'
        # Remove brackets and split by comma
        cleaned = active_tokens_result.strip().strip('[]')
        token_addrs = [addr.strip() for addr in cleaned.split(',') if addr.strip() and addr.strip().startswith('0x')]

        print(f"  DEBUG: Found {len(token_addrs)} reward tokens: {token_addrs}", file=sys.stderr)

        for token_addr in token_addrs:
            analysis = analyze_token(address, token_addr, total_deposits, magnitude, rpc_url, block)
            if analysis:
                token_analyses.append(analysis)
            else:
                print(f"  DEBUG: Failed to analyze token {token_addr}", file=sys.stderr)

    return PoolAnalysis(
        config=config,
        address=address,
        deployed=True,
        total_deposits=total_deposits,
        magnitude=magnitude,
        tokens=token_analyses,
    )


def print_analysis(analysis: PoolAnalysis):
    """Print pool analysis."""
    print("─" * 80)
    print(f"Pool: {analysis.config.name}")
    print(f"Salt: {analysis.config.predict_key}")
    print(f"Address: {analysis.address or 'NOT FOUND'}")

    if not analysis.deployed:
        print("Status: NOT DEPLOYED")
        print()
        return

    print("Status: DEPLOYED ✅")
    print(f"Total Deposits: {format_large_number(analysis.total_deposits)}")
    print(f"Magnitude: {format_large_number(analysis.magnitude)}")

    if analysis.total_deposits == 0:
        print("⚠️  WARNING: POOL IS EMPTY")
        print()
        return

    if not analysis.tokens:
        print("Active Reward Tokens: None")
        print()
        return

    print(f"\nActive Reward Tokens ({len(analysis.tokens)}):")
    for i, token in enumerate(analysis.tokens, 1):
        print(f"\n  Token {i}: {token.symbol}")
        print(f"    Address: {token.address}")
        print(f"    Integral: {format_large_number(token.integral)}")
        print(f"    Capacity Used: {token.capacity_used_pct:.2f}%")
        print(f"    Risk Level: {token.risk_level}")

        if token.queued > 0:
            print(f"    ⚠️  Queued Rewards: {format_large_number(token.queued)}")

        if token.rate > 0:
            print(f"    Rate: {format_large_number(token.rate)} tokens/second")
            print(f"    Weekly Growth: {token.weekly_growth:.3e}")

            if token.weeks_to_overflow != float("inf"):
                if token.weeks_to_overflow < 2:
                    urgency = "🔴 URGENT"
                elif token.weeks_to_overflow < 4:
                    urgency = "🟠 SOON"
                elif token.weeks_to_overflow < 12:
                    urgency = "🟡 MODERATE"
                else:
                    urgency = "🟢 OK"

                print(f"    Time to Overflow: {token.weeks_to_overflow:.1f} weeks {urgency}")
            else:
                print(f"    Time to Overflow: ∞ (no active rewards)")

    print()


def main():
    """Main entry point."""
    network = sys.argv[1] if len(sys.argv) > 1 else "mainnet"
    block = sys.argv[2] if len(sys.argv) > 2 else "latest"

    # Get RPC URL from environment
    import os

    if network == "sepolia":
        rpc_url = os.getenv("SEPOLIA_RPC_URL", "")
    else:
        rpc_url = os.getenv("MAINNET_RPC_URL", "")

    if not rpc_url:
        print(f"Error: RPC URL not set for network {network}", file=sys.stderr)
        print(f"Set {network.upper()}_RPC_URL environment variable", file=sys.stderr)
        sys.exit(1)

    print("=" * 80)
    print("Stability Pool Overflow Risk Analysis")
    print(f"Network: {network}")
    print(f"Block: {block}")
    print("=" * 80)
    print()

    # All pool configurations
    configs = [
        PoolConfig(peg, collateral, liquidation)
        for peg in ["BTC", "ETH", "EUR"]
        for collateral in ["fxUSD", "stETH"]
        for liquidation in ["Collateral", "Leveraged"]
    ]

    # Analyze all pools
    analyses = []
    for config in configs:
        print(f"Analyzing {config.name}...", file=sys.stderr)
        analysis = analyze_pool(config, rpc_url, block)
        analyses.append(analysis)

    # Print results
    for analysis in analyses:
        print_analysis(analysis)

    # Summary
    print("=" * 80)
    print("SUMMARY")
    print("=" * 80)

    deployed = [a for a in analyses if a.deployed]
    critical = [a for a in deployed if any(t.capacity_used_pct >= 90 for t in a.tokens)]
    high_risk = [a for a in deployed if any(80 <= t.capacity_used_pct < 90 for t in a.tokens)]

    print(f"Total Pools: {len(configs)}")
    print(f"Deployed: {len(deployed)}")
    print(f"🔴 Critical Risk: {len(critical)}")
    print(f"🟠 High Risk: {len(high_risk)}")

    if critical:
        print("\n🔴 CRITICAL POOLS (>90% capacity):")
        for a in critical:
            for token in a.tokens:
                if token.capacity_used_pct >= 90:
                    weeks = token.weeks_to_overflow
                    print(
                        f"  • {a.config.name} - {token.symbol}: {token.capacity_used_pct:.2f}% "
                        f"({weeks:.1f} weeks to overflow)"
                    )

    if high_risk:
        print("\n🟠 HIGH RISK POOLS (80-90% capacity):")
        for a in high_risk:
            for token in a.tokens:
                if 80 <= token.capacity_used_pct < 90:
                    weeks = token.weeks_to_overflow
                    print(
                        f"  • {a.config.name} - {token.symbol}: {token.capacity_used_pct:.2f}% "
                        f"({weeks:.1f} weeks to overflow)"
                    )

    print()
    print("=" * 80)


if __name__ == "__main__":
    main()

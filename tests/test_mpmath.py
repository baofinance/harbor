# tests/test_stability_pool.py
"""Simple test demonstrating mpmath works with Wake tests."""

import mpmath as mp
from wake.testing import *


@chain.connect()
def test_precision_with_mpmath():
    """Test that mpmath can handle high-precision calculations."""
    # Set mpmath precision to 50 decimal places
    mp.mp.dps = 50

    # Perform high-precision calculation
    price = mp.mpf("1.000000000000000001")
    deposited = mp.mpf("1000.0")
    expected_loss = deposited * mp.mpf("0.003")

    # Verify precision is maintained
    assert price > mp.mpf("1.0")
    assert expected_loss == mp.mpf("3.0")
    assert str(price) == "1.000000000000000001"

    print(f"Price: {price}")
    print(f"Deposited: {deposited}")
    print(f"Expected loss: {expected_loss}")

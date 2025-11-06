# SPDX-License-Identifier: MIT
# @title Mock ERC20STEAM for testing gauge constructor

from vyper.interfaces import ERC20

implements: ERC20

event Transfer:
    _from: indexed(address)
    _to: indexed(address)
    _value: uint256

event Approval:
    _owner: indexed(address)
    _spender: indexed(address)
    _value: uint256

name: public(String[64])
symbol: public(String[32])
decimals: public(uint256)

balanceOf: public(HashMap[address, uint256])
allowances: HashMap[address, HashMap[address, uint256]]
totalSupply: public(uint256)
minter: public(address)

@external
def __init__():
    self.name = "STEAM"
    self.symbol = "STEAM"
    self.decimals = 18
    self.totalSupply = 61_000_000 * 10**18
    self.balanceOf[msg.sender] = self.totalSupply
    self.minter = msg.sender
    log Transfer(empty(address), msg.sender, self.totalSupply)

@external
def transfer(_to: address, _value: uint256) -> bool:
    self.balanceOf[msg.sender] -= _value
    self.balanceOf[_to] += _value
    log Transfer(msg.sender, _to, _value)
    return True

@external
def transferFrom(_from: address, _to: address, _value: uint256) -> bool:
    self.allowances[_from][msg.sender] -= _value
    self.balanceOf[_from] -= _value
    self.balanceOf[_to] += _value
    log Transfer(_from, _to, _value)
    return True

@external
def approve(_spender: address, _value: uint256) -> bool:
    self.allowances[msg.sender][_spender] = _value
    log Approval(msg.sender, _spender, _value)
    return True

@view
@external
def allowance(_owner: address, _spender: address) -> uint256:
    return self.allowances[_owner][_spender]

@view
@external
def rate() -> uint256:
    return 1_000_000_000_000_000_000  # dummy constant rate

@external
def future_epoch_time_write() -> uint256:
    return block.timestamp + 86400  # dummy value: 1 day ahead

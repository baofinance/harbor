// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

library deployed {
    address public constant wstETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address public constant BaoUSD = 0x7945b0A6674b175695e5d1D08aE1e6F13744Abb0;
    address public constant BaoETH = 0xf4edfad26EE0D23B69CA93112eccE52704E0006f;
}

library deployedSepolia {
    // block number that all the below work for
    uint256 public constant blockNumber = 6227500;

    // Bao dev contracts
    address public constant owner = 0x0DC59a2caD3e1fa5D6b8a0F7c1481FcEDFa0bBCA;
    address public constant BaoUSDxwstETH = 0x26C6effF04F8c77E13F1A465C648056B80A8aE9a;
    address public constant ReservePool = 0x82dcC46336e06F4921EfC46ee6A177456012C59A;
    address public constant MinterFeeDistributor = 0xEd659E305FA62C29122A87FAF1c5e4400ED98444;

    // other useful addresses
    // ERC20 tokens
    address public constant USDT = 0xbDeaD2A70Fe794D2f97b37EFDE497e68974a296d;
    address public constant MAGIC = 0x013Cb2854daAD8203C6686682f5d876e5D3de4a2;
    address public constant USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
}

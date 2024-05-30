# Minter

Minter is a system of contracts that allow tokens whose value is pegged to some underlying price.
Collateral is held to supply the balance of value.
This works due to four mechanisms, some of which operate throughout the collateral ratio spectrum and others kick in when collateral ration levels are tending downward.

## Incentives

Fees increase as the collateral ratio decreases for certain user actions and decrease for others.

## Rebalancing

## Pausing of certain user actions

## Reserve pool

Provides discounts for beneficial user actions.
The reserve pool is filled with a percentage of the fees collected, and can be filled by other mechanisms, e.g. simply transferring the collateral token to it.

# Development

## Foundry

https://book.getfoundry.sh/

## Usage

    $ yarn

to install node dependencies.
Then add a good definition of <code>MAINNET_RPC_URL</code> to your <code>.env</code>.

    $ yarn test
    $ yarn coverage (doesn't work for me)
    $ yarn slither

etc. Check the scripts in <code>package.json</code>

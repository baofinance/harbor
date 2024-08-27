# Minter

Minter is a system of contracts that pegs a given token to the value of some underlying asset, e.g. USD.
These pegged tokens are minted in exchange for a capital efficient amount of collateral tokens.
In addition, there are leveraged tokens whose total value is the difference in the value of the collateral and the pegged tokens.
Pegged tokens and Leveraged tokens can be both minted and redeemed by users.
The system maintains the pegging by varying the price of the leveraged token such that the pegged value equals the underlying asset's price.
This works perfectly while the value of the collateral held doesn't drop below the value of all the minted pegged tokens.
A healthy collateral ratio is maintained through four mechanisms some of which operate throughout the collateral ratio spectrum and others kick in when collateral ratio levels are tending downward.

## Stability mechanisms

### Incentives

Incentivising certain actions
Fees and discounts can be set for each of minting/redeeming of pegged/leveraged tokens. It is expected but not enforced that fees increase as action increase as the collateral ratio decreases for certain user actions and decrease for others.

### Rebalancing

### Pausing of certain user actions

### Reserve pool

Provides discounts for beneficial user actions.
The reserve pool is filled with a percentage of the fees collected, and can be filled by other mechanisms, e.g. simply transferring the collateral token to it.

## Pegged Tokens

Pegged tokens can be any ERC20 token and can be minted by other means not just by the Minter. Pegged tokens can therefore be minted by some other means and redeemed in the Mkinter.
The Minter maintains a count of how many have been minted and redeemed by the Minter itself and ensures that no more are redeemed than are minted in the Minter itself.

## Leveraged Tokens

Leveraged tokens operate on a one-to-one basis with the Minter. Only the Minter can mint them and redeem them.
Leverage token's value is derived from the difference between the value of collateral and the value of the total number of pegged tokens minted by the Minter and not redeemed.
Because of this the value of a leveraged token changes as the value of the collateral changes - by the price of the collateral changing.
Minting or redeeming pegged or leveraged tokens makes no difference to the price of the leveraged token as each mint/redeem increases/decreases the total amount of collateral such that the value of the leveraged token is unaffected.
Leveraged tokens act as a leveraged long collateral position.
Leveraged token's value drops to zero when the value of the collateral held equals the total value of the pegged tokend minted but not redeemed by the Minter.

# Development

## Foundry

Installation and usage is [here](https://book.getfoundry.sh/)

## Usage

    $ yarn

to install node dependencies.
Then add a good definition of <code>MAINNET_RPC_URL</code> to your <code>.env</code>.

    $ yarn test

which builds and tests the code, including generating coverage and gas usage reports, or

    $ yarn slither

which runs the slither code analyser, or

    $ yarn deploy:local

which deploys the Minter contracts, correctly connected up, on a local anvil instance.

etc. Check the scripts in <code>package.json</code>

Also note that config files for [wake](https://ackee.xyz/wake/docs/4.11.0/) are provided.

### Test artifacts

Note that some "yarn test" artifacts:

- the code-coverage report
- the gas reports
- geerated graphs

are stored in git. This provides a simple (albeit crude) mechanism to check for regressions in coverage, gas usage and model values.

./bao-minter/test/StabilityPoolClaimable.t.sol:        rewarder = vm.createWallet("rewarder").addr; // @audit-issue I: makeAddr("rewarder") is shorthand for this
./bao-minter/src/reward/steam/Steam_v1.sol:        for (uint256 i = 0; i < 999; i++) { // @audit-issue I: uint256 i; i < 999; ++i is the more gas efficient way of writing this loop; 22 for loops can be rewritten like this
./bao-minter/src/minter/TokenDistributor_v1.sol:// solhint-disable-next-line contract-name-camelcase @audit-issue I: _v1 naming messes with the natspec of 12 contracts, think about removing the camel case and just append V1 at the end - it will keep versioning clarity, enable IDE type hints and remove the need to disable rules
./bao-minter/src/minter/TokenDistributor_v1.sol:                // @audit-issue I: this loop can be removed, just require that recipients array is sorted by checking the next address is bigger u160 than the previous.
./bao-minter/src/minter/TokenDistributor_v1.sol:        // @audit-issue I: fn name should be addOrUpdateRecipient to reflect better what it does
./bao-minter/src/minter/TokenDistributor_v1.sol:        // @audit-issue I: natspec for function needs one more /
./bao-minter/src/minter/Minter_v1.sol:            revert ActionPaused(); // @audit-issue I: a better error can be emitted here; there was no pause enabled
./bao-minter/src/minter/Minter_v1.sol:        collateralOut = 0; // @audit-issue I: collateralOut & underlyingCollateralIn are confusingly named. Both are out, one is after fees
./bao-minter/src/minter/Genesis_v1.sol:        // @audit-issue I: since Minter supports ERC-165 you can just query for the IMinter interface and you will have stronger guarantees
./bao-minter/src/minter/Genesis_v1.sol:        // @audit-issue I: ideally this is the first call in the constructor
./bao-minter/src/minter/Genesis_v1.sol:        // @audit-issue I: you can remove nonReentrant and move this assignment right after if check; fn is safe -> onlyOwner & CEI pattern
./bao-minter/src/minter/StabilityPool_v1.sol:    uint256 internal immutable _VE_START; // @audit-issue I: unused variable
./bao-minter/src/minter/StabilityPool_v1.sol:        // @audit-issue I: unnecessary override
./bao-minter/src/minter/StabilityPool_v1.sol:    ) external virtual onlyRoles(REWARDER_ROLE + REBALANCER_ROLE) { // @audit-issue I: addition works but bitwise OR would express the intent of combining bitmasks better; + may be confusing to readers since they would have to know roles are a power of 2
./bao-base/src/Token.sol:            // @audit-issue I: I don't see this function being used anywhere, but its worth mentioning that: in its current state it is only suitable for calling Bao contracts. Applying it to external ones poses a risk because: First, there is no control of the amount of gas forwarded (always 63/64ths) which may be undesirable in sertain situaitons. Second, there's no cap on the return data size, making it susceptible to return data bombing.

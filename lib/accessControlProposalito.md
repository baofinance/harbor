## Background
Contracts need to restrict access to some functions. Each restricted function may need to be restricted in different ways such that different sets of users/contracts can call different functions.

There is also the common concept of a contract owner. Indeed there is a proposed standard for it: ERC-5313, (see https://eips.ethereum.org/EIPS/eip-5313).

OpenZeppelin has all of this, and more, in their library.

## Proposal
To give all our new contracts the same facilities for access control, consisting of a contract owner and a set of roles, bespoke to the contract but handled in the same secure way. The roles are granted to certain addresses so that they can access functions restricted to that role.

We do this by cutting down OpenZeppelin's implementation to give us a lightweight, but fully functional, base contract to be inherited in all our new contracts.

### Roles
* each contract can have zero or more roles, e.g. TOKEN_MINTER_ROLE for minting an ERC20 token like BaoUSD.
* a role is defined in the contract like this:
  ``` solidity
  bytes32 public constant TOKEN_MINTER_ROLE = keccak256("TOKEN_MINTER_ROLE");
  ```
* those roles are granted and revoked by the owner to addresses. So, e.g. The Minter can mint BaoUSD as can some other contracts.
  ``` solidity
  function grantRole(bytes32 role, address account);
  function revokeRole(bytes32 role, address account);
  ```
* additionally accounts can renounce a role they have been granted
  ``` solidity
  function renounceRole(bytes32 role, address callerConfirmation);
  ```
### Owner
* each contract has an owner, on deployment/initialization this is set to the Bao Multisig
* there can only be one owner
* transferring owner is a 2 step process:
  * the current owner, and only the current owner, starts the transfer.
    ``` solidity
    function transferOwnership(address newOwner);
    ```
  * the current owner can cancel the transfer or start a different transfer
    ``` solidity
    function cancelOwnershipTransfer();
    ```
  * the new owner accepts the transfer, completing the transfer. The new owner is not the owner.
    ``` solidity
    function acceptOwnership(address callerConfirmation);
    ```
  There are options in OpenZeppelin to insist on a time delay between startTransfer() and acceptTransfer(). This kind of thing is the role of the Governor contract - there would be a time delay, before the startTransfer is called.
* ownership can be renounced leaving the contract with no owners. This is a form of making a contract *immutable*.
  ``` solidity
    renounceOwnership(address callerConfirmation);
  ```
* by default the owner has one purpose and that is to grant and revoke roles to itself or other addresses.

### OpenZeppelin's offering
OpenZeppelin gives you four options:
* simple owner:
  ``` solidity
  contract Ownable {
      modifier onlyOwner();
      function owner() view returns (address);
      function renounceOwnership() onlyOwner;
      function transferOwnership(address newOwner) onlyOwner;
  }
  ```
  This has no roles and no 2 step transfer.
* 2 step owner:
  ``` solidity
  contract Ownable2Step is Ownable {
      function pendingOwner() view returns (address);
      function acceptOwnership(); // checks internally that the caller is pendingOwner()
  }
  ```
  This has no roles and ownership transfer cannot be cancelled.
* AccessControl
  ``` solidity
  contract AccessControl is Ownable {
      bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
      modifier onlyRole(bytes32 role);
      function hasRole(bytes32 role, address account) view returns (bool);
      function getRoleAdmin(bytes32 role) public view virtual returns (bytes32);
      function grantRole(bytes32 role, address account) onlyRole(getRoleAdmin(role));
      function revokeRole(bytes32 role, address account) onlyRole(getRoleAdmin(role));
      function renounceRole(bytes32 role, address callerConfirmation);
  }
  ```
  This has a sort of ownership - the ```DEFAULT_ADMIN_ROLE``` - but it has no 2 step transfer, and there can be multiple accounts holding this role. There is also bloat here in that there is a ```getAdminRole``` but no facility to set it - that would be left to the class inheriting ```AccessControl```

  It also has the unneeded function ```getRoleAdmin()```

* AccessControlDefaultAdminRules
  ```
  contract AccessControlDefaultAdminRules is AccessControl {
      function owner() view returns (address);
      // this adds no other new functions but adds retrictions to the existing functions
  }
  ```
  This has everything:
   * ownership: it is called both ```owner``` and ```DEFAULT_ADMIN_ROLE```
   * there can only be one address with the ```DEFAULT_ADMIN_ROLE```
   * transfer of ownership is a cancellable 2 step.
   * roles

   But too much:
   * a timelock for ownership transfer
   * role admins

  It is like the superset of ```Ownable2Step``` and ```AccessControl``` with a timelock which comes with a considerable cost in contract size.

### Implementation
The proposal is to produce a cut-down version of ```AccessControlDeafultAdminRules```, based on a cut-down version of ```AccessControl```, with naming aligned with the more standard ```Ownable2Step```.

This is very similar in design to another library: solady. The solady implementation is riddled with assembly language making it less understandable. I expect, however, that it is much more gas efficient...
// TODO: usae solady's?
requesttransfer
canceltransfer
completetransfer

What we remove from ```AccessControl``` is the concept of a ```DEFAULT_ADMIN_ROLE``` and replace it with a single address, ```owner```.

From ```AccessControlDeafultAdminRules``` we remove the timelock and and adapt it to the new modified ```AccessControl```.

The aim is to
* build on Openzeppelin's design where it suits us and
* remove superfluous code, which bloats.

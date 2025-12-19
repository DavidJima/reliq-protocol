# How to setup:

1. Deploy the ReliqHYPE.sol contract.
   1.1 The `constructor` accepts the address for the backing token address.
2. Set the fee address for the contract.
3. Call `setStart` to kick-off the protocol. This accepts parameters for how much the team would like to mint in the initial reserve and sets the asset:backing ratio to 1:1. Can optionally burn some of it as well. (Requires fee address to be set && `maxMintable` to be zero)
4.

## Admin-controlled parameters.

All of the following variables are in basis points (BPS). 100 BPS = 1%.

1. `buyFeeBPS`: fee charged on buy operations.
2. `sellFeeBPS`: fee charged on sell operations.
3. `buyLeverageFeeBPS`: discounted buy fee charged on buy leverage operations.
4. `flashCloseFeeBPS`: fee charged on flash close operations.
5. `protocolFeeShare`: share of fees going to the protocol treasury.
6. `interestRateBPS`: annual interest rate on borrow.
7. `treasury`: address of the protocol treasury.
8. `masterMinter`: address of the contract that can increase the mint cap implicitly by minting new tokens.

## Core protocol functions:

** Asset functions **

- `setStart`
- `buy`
- `sell`

** Lending Functions **

- `leverage`
- `borrow`
- `borrowMore`
- `removeCollateral`
- `repay`
- `closePosition`
- `flashClosePosition`
- `extendLoan`
- `liquidate`

---

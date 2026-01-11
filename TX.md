* grant roles to EUR and GOLD pegged
  * GOLD::pegged rolesOf(GOLD::stETH::minter) = 3
  * EUR::pegged rolesOf(EUR::stETH::minter) = 3

* update minter fee receiver to treasury
  * ETH::fxUSD::minter updateFeeReceiver(treasury)
  * BTC::fxUSD::minter updateFeeReceiver(treasury)
  * BTC::stETH::minter updateFeeReceiver(treasury)
  * EUR::fxUSD::minter updateFeeReceiver(treasury)
  * GOLD::fxUSD::minter updateFeeReceiver(treasury)

* update stabilityPoolManger fee receiver to treasury
  * ETH::fxUSD::stabilityPoolManager updateFeeReceiver(treasury)
  * BTC::fxUSD::stabilityPoolManager updateFeeReceiver(treasury)
  * BTC::stETH::stabilityPoolManager updateFeeReceiver(treasury)
  * EUR::fxUSD::stabilityPoolManager updateFeeReceiver(treasury)
  * GOLD::fxUSD::stabilityPoolManager updateFeeReceiver(treasury)


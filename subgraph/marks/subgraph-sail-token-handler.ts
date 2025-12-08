// This file should be placed in: /Users/andrewyoung/Harbor-App/harbor-app/subgraph/src/sailToken.ts
// Handler for sail token (leveraged token, hs) Transfer events
// Similar to haToken.ts but with 5x default multiplier

import { Transfer as TransferEvent } from "../generated/SailToken_hsPB/ERC20";
import { ERC20 } from "../generated/SailToken_hsPB/ERC20";
import {
  SailTokenBalance,
  MarksMultiplier,
  PriceFeed,
  UserTotalMarks,
} from "../generated/schema";
import { BigDecimal, BigInt, Bytes, Address, ethereum } from "@graphprotocol/graph-ts";

// Constants
const SECONDS_PER_DAY = BigDecimal.fromString("86400");
const DEFAULT_MULTIPLIER = BigDecimal.fromString("5.0"); // 5x for sail tokens (default)
const DEFAULT_MARKS_PER_DOLLAR_PER_DAY = BigDecimal.fromString("1.0");

// Helper to get or create price feed (simplified - using $1 for sail tokens)
function getOrCreatePriceFeed(tokenAddress: Bytes, block: ethereum.Block): PriceFeed {
  const id = tokenAddress.toHexString();
  let priceFeed = PriceFeed.load(id);

  if (priceFeed == null) {
    priceFeed = new PriceFeed(id);
    priceFeed.tokenAddress = tokenAddress;
    priceFeed.priceFeedAddress = Bytes.fromHexString("0x0000000000000000000000000000000000000000");
    priceFeed.priceUSD = BigDecimal.fromString("1.0"); // Default to $1 for sail tokens
    priceFeed.decimals = 8;
    priceFeed.lastUpdated = block.timestamp;
    priceFeed.save();
  }
  return priceFeed;
}

// Helper to calculate balance in USD
function calculateBalanceUSD(balance: BigInt, tokenAddress: Bytes, block: ethereum.Block): BigDecimal {
  const priceFeed = getOrCreatePriceFeed(tokenAddress, block);
  const balanceDecimal = balance.toBigDecimal().div(BigDecimal.fromString("1000000000000000000")); // 18 decimals
  return balanceDecimal.times(priceFeed.priceUSD);
}

// Helper to get or create sail token balance
function getOrCreateSailTokenBalance(
  tokenAddress: Bytes,
  userAddress: Bytes
): SailTokenBalance {
  const id = `${tokenAddress.toHexString()}-${userAddress.toHexString()}`;
  let balance = SailTokenBalance.load(id);

  if (balance == null) {
    balance = new SailTokenBalance(id);
    balance.tokenAddress = tokenAddress;
    balance.user = userAddress;
    balance.balance = BigInt.fromI32(0);
    balance.balanceUSD = BigDecimal.fromString("0");
    balance.marksPerDay = BigDecimal.fromString("0");
    balance.accumulatedMarks = BigDecimal.fromString("0");
    balance.totalMarksEarned = BigDecimal.fromString("0");
    balance.firstSeenAt = BigInt.fromI32(0);
    balance.lastUpdated = BigInt.fromI32(0);
    balance.marketId = null;
    balance.save();
  }
  return balance;
}

// Helper to query actual token balance from contract
function queryTokenBalance(tokenAddress: Address, userAddress: Address): BigInt {
  const token = ERC20.bind(tokenAddress);
  const balanceResult = token.try_balanceOf(userAddress);
  if (balanceResult.reverted) {
    return BigInt.fromI32(0);
  }
  return balanceResult.value;
}

// Get multiplier for sail token (default 5x)
function getSailTokenMultiplier(tokenAddress: Bytes, timestamp: BigInt): BigDecimal {
  const sourceType = "sailToken";
  const id = `${sourceType}-${tokenAddress.toHexString()}`;
  let multiplier = MarksMultiplier.load(id);

  if (multiplier == null) {
    multiplier = new MarksMultiplier(id);
    multiplier.sourceType = sourceType;
    multiplier.sourceAddress = tokenAddress;
    multiplier.multiplier = DEFAULT_MULTIPLIER; // 5x default
    multiplier.effectiveFrom = timestamp;
    multiplier.updatedAt = timestamp;
    multiplier.updatedBy = null;
    multiplier.save();
  }
  return multiplier.multiplier;
}

// Helper to accumulate marks (daily snapshot approach)
function accumulateMarks(
  balance: SailTokenBalance,
  block: ethereum.Block
): void {
  const currentTimestamp = block.timestamp;
  if (balance.balance.equals(BigInt.fromI32(0))) {
    balance.accumulatedMarks = BigDecimal.fromString("0");
    balance.marksPerDay = BigDecimal.fromString("0");
    balance.lastUpdated = currentTimestamp;
    balance.save();
    return;
  }

  const multiplier = getSailTokenMultiplier(balance.tokenAddress, currentTimestamp);
  const marksPerDollarPerDay = DEFAULT_MARKS_PER_DOLLAR_PER_DAY.times(multiplier);

  const lastUpdate = balance.lastUpdated.gt(BigInt.fromI32(0))
    ? balance.lastUpdated
    : balance.firstSeenAt;

  if (lastUpdate.equals(BigInt.fromI32(0))) {
    balance.firstSeenAt = currentTimestamp;
    balance.lastUpdated = currentTimestamp;
    balance.marksPerDay = balance.balanceUSD.times(marksPerDollarPerDay);
    balance.accumulatedMarks = BigDecimal.fromString("0");
    balance.save();
    return;
  }

  if (currentTimestamp.gt(lastUpdate)) {
    const timeSinceLastUpdate = currentTimestamp.minus(lastUpdate);
    const daysSinceLastUpdate = timeSinceLastUpdate.toBigDecimal().div(SECONDS_PER_DAY);
    const fullDays = daysSinceLastUpdate.truncate(0); // Round down to full days

    if (fullDays.gt(BigDecimal.fromString("0"))) {
      const marksAccumulated = balance.balanceUSD.times(marksPerDollarPerDay).times(fullDays);
      balance.accumulatedMarks = balance.accumulatedMarks.plus(marksAccumulated);
      balance.totalMarksEarned = balance.totalMarksEarned.plus(marksAccumulated);

      const daysAsBigInt = BigInt.fromString(fullDays.toString().split(".")[0]);
      const secondsToAdd = daysAsBigInt.times(BigInt.fromI32(86400));
      balance.lastUpdated = lastUpdate.plus(secondsToAdd);
    }
  }
  balance.marksPerDay = balance.balanceUSD.times(marksPerDollarPerDay);
  balance.save();
}

// Handler for Transfer event
export function handleSailTokenTransfer(event: TransferEvent): void {
  const tokenAddress = event.address;
  const fromAddress = event.params.from;
  const toAddress = event.params.to;
  const timestamp = event.block.timestamp;

  // Handle sender (if not zero address)
  if (!fromAddress.equals(Address.fromHexString("0x0000000000000000000000000000000000000000"))) {
    const senderBalance = getOrCreateSailTokenBalance(tokenAddress, fromAddress);
    accumulateMarks(senderBalance, event.block);
    
    const actualBalance = queryTokenBalance(Address.fromBytes(tokenAddress), fromAddress);
    senderBalance.balance = actualBalance;
    senderBalance.balanceUSD = calculateBalanceUSD(actualBalance, tokenAddress, event.block);
    
    if (senderBalance.firstSeenAt.equals(BigInt.fromI32(0)) && actualBalance.gt(BigInt.fromI32(0))) {
      senderBalance.firstSeenAt = timestamp;
    }
    
    if (actualBalance.equals(BigInt.fromI32(0))) {
      senderBalance.accumulatedMarks = BigDecimal.fromString("0");
      senderBalance.firstSeenAt = BigInt.fromI32(0);
    }
    
    senderBalance.lastUpdated = timestamp;
    senderBalance.save();
  }

  // Handle receiver (if not zero address)
  if (!toAddress.equals(Address.fromHexString("0x0000000000000000000000000000000000000000"))) {
    const receiverBalance = getOrCreateSailTokenBalance(tokenAddress, toAddress);
    accumulateMarks(receiverBalance, event.block);
    
    const actualBalance = queryTokenBalance(Address.fromBytes(tokenAddress), toAddress);
    receiverBalance.balance = actualBalance;
    receiverBalance.balanceUSD = calculateBalanceUSD(actualBalance, tokenAddress, event.block);
    
    if (receiverBalance.firstSeenAt.equals(BigInt.fromI32(0)) && actualBalance.gt(BigInt.fromI32(0))) {
      receiverBalance.firstSeenAt = timestamp;
    }
    
    receiverBalance.lastUpdated = timestamp;
    receiverBalance.save();
  }
}




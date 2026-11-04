import { ethers } from 'ethers';
import * as fs from 'fs';
import * as path from 'path';
import * as dotenv from 'dotenv';

dotenv.config();

// ABIs
const CHAINLINK_ABI = [
    'function latestRoundData() external view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)',
    'function getRoundData(uint80 _roundId) external view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)',
];

const WSTETH_ABI = ['function stEthPerToken() external view returns (uint256)'];

// Contract addresses
const STETH_PRICE_FEED = '0xCfE54B5cD566aB89272946F602D76Ea879CAb4a8';
const WSTETH_CONTRACT = '0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0';

// Configuration
const MAX_ROUNDS = 500;

async function main() {
    // Connect to provider
    const provider = new ethers.providers.JsonRpcProvider(process.env.RPC_URL);
    const network = await provider.getNetwork();
    console.log(`Connected to network: ${network.name}`);

    // Initialize contracts
    const priceFeed = new ethers.Contract(STETH_PRICE_FEED, CHAINLINK_ABI, provider);
    const wstETH = new ethers.Contract(WSTETH_CONTRACT, WSTETH_ABI, provider);

    // Get latest round data
    const latestData = await priceFeed.latestRoundData();
    const latestRoundId = latestData.roundId.toNumber();
    console.log(`Latest round ID: ${latestRoundId}`);

    // Calculate start round
    const startRound = Math.max(1, latestRoundId - MAX_ROUNDS);
    console.log(`Starting from round: ${startRound}`);

    const results = [];
    let validRounds = 0;

    // Process rounds
    for (let roundId = startRound; roundId <= latestRoundId; roundId++) {
        try {
            // Get price data
            const roundData = await priceFeed.getRoundData(roundId);
            const updatedAt = roundData.updatedAt.toNumber();

            // Skip invalid rounds
            if (updatedAt === 0) continue;

            // Find block for timestamp
            const block = await findBlockByTimestamp(provider, updatedAt);

            // Get wstETH rate at that block
            let stEthPerWstETHRate;
            let stEthPerWstETHFormatted: string | number = 'N/A';

            try {
                if (block) {
                    stEthPerWstETHRate = await wstETH.stEthPerToken({ blockTag: block });
                    stEthPerWstETHFormatted = parseFloat(ethers.utils.formatEther(stEthPerWstETHRate));
                } else {
                    stEthPerWstETHRate = ethers.BigNumber.from(0);
                }
            } catch (err) {
                console.log(`Error getting wstETH rate for round ${roundId}: ${err.message}`);
                stEthPerWstETHRate = ethers.BigNumber.from(0);
            }

            // Format price (8 decimals for Chainlink USD pairs)
            const priceFormatted = parseFloat(roundData.answer.toString()) / 1e8;

            // Format date
            const dateTime = new Date(updatedAt * 1000).toISOString();

            // Add data point
            results.push({
                roundId: roundData.roundId.toString(),
                price: roundData.answer.toString(),
                priceFormatted,
                timestamp: updatedAt,
                dateTime,
                blockNumber: block || 'unknown',
                stEthPerWstETH: stEthPerWstETHRate.toString(),
                stEthPerWstETHFormatted,
            });

            validRounds++;

            // Log progress
            if (roundId % 50 === 0 || roundId === latestRoundId) {
                console.log(`Processed round ${roundId}, timestamp: ${dateTime}`);
            }
        } catch (err) {
            console.log(`Error processing round ${roundId}: ${err.message}`);
        }
    }

    // Write to file
    const outputPath = path.join(__dirname, 'steth_wsteth_history.json');
    fs.writeFileSync(outputPath, JSON.stringify(results, null, 2));

    console.log(`Data collection complete`);
    console.log(`Total valid rounds: ${validRounds}`);
    console.log(`Output saved to: ${outputPath}`);

    // Basic summary statistics
    if (results.length > 0) {
        const prices = results.map(r => (typeof r.priceFormatted === 'number' ? r.priceFormatted : 0));
        const avgPrice = prices.reduce((a, b) => a + b, 0) / prices.length;
        const minPrice = Math.min(...prices);
        const maxPrice = Math.max(...prices);

        console.log('\nSample data analysis:');
        console.log(`Mean stETH price: $${avgPrice.toFixed(2)}`);
        console.log(`Price range: $${minPrice.toFixed(2)} - $${maxPrice.toFixed(2)}`);
    }
}

/**
 * Find the block that contains the target timestamp using binary search
 * Much more accurate than estimation, especially for historical data
 */
async function findBlockByTimestamp(
    provider: ethers.providers.JsonRpcProvider,
    targetTimestamp: number,
): Promise<number | null> {
    // Get latest block as the upper bound
    const latestBlock = await provider.getBlock('latest');

    // If target is after latest block, return latest
    if (targetTimestamp >= latestBlock.timestamp) {
        return latestBlock.number;
    }

    // Set initial search bounds
    let lowerBound = 1; // Ethereum genesis block
    let upperBound = latestBlock.number;
    let closestBlock = null;

    // First, try the estimation approach to get closer quickly
    const AVERAGE_BLOCK_TIME = 13;
    const estimatedBlocksBack = Math.floor((latestBlock.timestamp - targetTimestamp) / AVERAGE_BLOCK_TIME);
    const estimatedBlockNumber = Math.max(1, latestBlock.number - estimatedBlocksBack);

    try {
        // Use the estimation as a starting point to narrow the search range
        const estimatedBlock = await provider.getBlock(estimatedBlockNumber);

        if (estimatedBlock.timestamp <= targetTimestamp) {
            lowerBound = estimatedBlock.number;
        } else {
            upperBound = estimatedBlock.number;
        }

        console.log(`Initial bounds: [${lowerBound}, ${upperBound}] for timestamp ${targetTimestamp}`);
    } catch (err) {
        console.log(`Error fetching estimated block: ${err.message}`);
        // Continue with full binary search
    }

    // Perform binary search
    while (lowerBound <= upperBound) {
        // Check if we've narrowed down to consecutive blocks
        if (upperBound - lowerBound <= 1) {
            // Get the two blocks
            const lowerBlock = await provider.getBlock(lowerBound);
            const upperBlock = await provider.getBlock(upperBound);

            // Find the best match
            if (targetTimestamp >= lowerBlock.timestamp && targetTimestamp <= upperBlock.timestamp) {
                // Target is between these blocks
                // Return the block with the closest timestamp
                return targetTimestamp - lowerBlock.timestamp <= upperBlock.timestamp - targetTimestamp
                    ? lowerBlock.number
                    : upperBlock.number;
            } else if (targetTimestamp < lowerBlock.timestamp) {
                return lowerBlock.number; // Best approximation
            } else {
                return upperBlock.number; // Best approximation
            }
        }

        // Calculate the middle block
        const midBlockNumber = Math.floor((lowerBound + upperBound) / 2);
        const midBlock = await provider.getBlock(midBlockNumber);

        // Compare timestamps
        if (midBlock.timestamp === targetTimestamp) {
            // Exact match found
            return midBlock.number;
        } else if (midBlock.timestamp < targetTimestamp) {
            // Target is in the upper half
            lowerBound = midBlockNumber + 1;
            closestBlock = midBlock.number; // This is a possible answer if exact match not found
        } else {
            // Target is in the lower half
            upperBound = midBlockNumber - 1;
        }
    }

    // If we get here, return the closest block we found
    return closestBlock;
}

// Run the script
main()
    .then(() => process.exit(0))
    .catch(error => {
        console.error(`Error in main function: ${error.message}`);
        process.exit(1);
    });

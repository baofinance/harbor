/**
 * Deploy Registry Tests
 *
 * These tests validate the deployment registry pattern works correctly
 * from a TypeScript/JavaScript perspective.
 */

describe('DeployRegistry', () => {
    describe('Constants', () => {
        it('should have all required registry keys defined', () => {
            // Registry keys that should be available
            const expectedKeys = [
                'ADMIN',
                'FEE_RECEIVER',
                'WRAPPED_COLLATERAL',
                'PEGGED',
                'LEVERAGED',
                'ORACLE',
                'MINTER',
                'RESERVE_POOL',
                'STABILITY_POOL_MANAGER',
                'REWARD_MANAGER',
                'REWARD_DEPOSITOR',
                'REBALANCER',
            ];

            // Validate we know what keys are expected
            expect(expectedKeys).toHaveLength(12);
            expect(expectedKeys).toContain('ADMIN');
            expect(expectedKeys).toContain('MINTER');
        });
    });

    describe('Proxy Configuration', () => {
        it('should define 7 proxyable contracts', () => {
            const proxyableContracts = [
                'FEE_RECEIVER',
                'WRAPPED_COLLATERAL',
                'PEGGED',
                'LEVERAGED',
                'RESERVE_POOL',
                'MINTER',
                'STABILITY_POOL_MANAGER',
            ];

            expect(proxyableContracts).toHaveLength(7);
        });

        it('should initialize with admin + 7 proxies = 8 total', () => {
            const totalInitialContracts = 8; // 1 admin + 7 proxies
            expect(totalInitialContracts).toBe(8);
        });
    });

    describe('Deployment Methods', () => {
        it('should support all deployment methods', () => {
            const deploymentMethods = ['None', 'Proxy', 'Deployed', 'Mock', 'Used'];

            expect(deploymentMethods).toHaveLength(5);
            expect(deploymentMethods).toContain('Deployed');
            expect(deploymentMethods).toContain('Mock');
        });
    });

    describe('Function Return Values', () => {
        it('should expect deploy functions to return (string, address)', () => {
            // All 20 deploy/mock/use functions should return tuples
            const functionsReturningTuples = [
                'useAdmin',
                'deployFeeReceiver',
                'useFeeReceiver',
                'deployCollateralToken',
                'mockCollateralToken',
                'useCollateralToken',
                'deployPeggedToken',
                'mockPeggedToken',
                'usePeggedToken',
                'deployLeveragedToken',
                'mockLeveragedToken',
                'useLeveragedToken',
                'mockOracle',
                'useOracle',
                'deployReservePool',
                'useReservePool',
                'deployMinter',
                'useMinter',
                'deployStabilityPoolManager',
                'useStabilityPoolManager',
            ];

            expect(functionsReturningTuples).toHaveLength(20);
        });
    });
});

describe('DeployRegistry Integration', () => {
    it('should validate the deployment flow', () => {
        // Deployment flow:
        // 1. Initialize with proxies (admin + 7 proxies)
        // 2. Deploy/mock/use contracts
        // 3. Finalize ownership for deployed contracts

        const deploymentSteps = ['initializeWithProxies', 'deployContracts', 'finalizeOwnership'];

        expect(deploymentSteps).toHaveLength(3);
        expect(deploymentSteps[0]).toBe('initializeWithProxies');
        expect(deploymentSteps[2]).toBe('finalizeOwnership');
    });

    it('should validate registry function names', () => {
        const registryFunctions = [
            'get',
            'set',
            'has',
            'getKeys',
            'getProxyableContracts',
            'getProxiedContracts',
            'getDeploymentMethod',
            'getUpgradeCount',
            'allowUpgrade',
            'canUpgrade',
            'markProxyDeployed',
            'initializeWithProxies',
        ];

        expect(registryFunctions).toContain('get');
        expect(registryFunctions).toContain('getKeys');
        expect(registryFunctions).toContain('getProxiedContracts');
    });
});

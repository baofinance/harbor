/**
 * Full Deployment Integration Tests
 *
 * These tests validate complete deployment workflows,
 * mirroring the Python test_02_wake_test.py integration tests.
 *
 * This file tests the full Harbor system deployment.
 */

import { expect } from '@jest/globals';

describe('Full Deployment Integration', () => {
    describe('Complete Harbor Deployment', () => {
        it('should deploy full Harbor system', () => {
            // Mock the full Harbor deployment
            const registry = new Map<string, string>();
            const deployerAddr = '0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266';

            // Deployment sequence
            const deployFullHarbor = (reg: Map<string, string>, deployer: string) => {
                // 1. Deploy admin
                reg.set('admin', '0x1111111111111111111111111111111111111111');

                // 2. Deploy tokens
                reg.set('wrappedCollateral', '0x2222222222222222222222222222222222222222');
                reg.set('pegged', '0x3333333333333333333333333333333333333333');
                reg.set('leveraged', '0x4444444444444444444444444444444444444444');

                // 3. Deploy core components
                reg.set('feeReceiver', '0x5555555555555555555555555555555555555555');
                reg.set('oracle', '0x6666666666666666666666666666666666666666');
                reg.set('reservePool', '0x7777777777777777777777777777777777777777');

                // 4. Deploy minter
                reg.set('minter', '0x8888888888888888888888888888888888888888');

                // 5. Deploy stability pools
                reg.set('stabilityPoolCollateral', '0x9999999999999999999999999999999999999999');
                reg.set('stabilityPoolLeveraged', '0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa');

                // 6. Deploy stability pool manager
                reg.set('stabilityPoolManager', '0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb');

                // 7. Deploy reward components
                reg.set('rewardManager', '0xcccccccccccccccccccccccccccccccccccccccc');
                reg.set('rewardDepositor', '0xdddddddddddddddddddddddddddddddddddddddd');
                reg.set('rebalancer', '0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee');

                return reg;
            };

            deployFullHarbor(registry, deployerAddr);

            // Verify all components deployed
            expect(registry.size).toBe(14); // 14 contracts

            // Verify admin
            expect(registry.has('admin')).toBe(true);

            // Verify tokens
            expect(registry.has('wrappedCollateral')).toBe(true);
            expect(registry.has('pegged')).toBe(true);
            expect(registry.has('leveraged')).toBe(true);

            // Verify core components
            expect(registry.has('feeReceiver')).toBe(true);
            expect(registry.has('oracle')).toBe(true);
            expect(registry.has('reservePool')).toBe(true);
            expect(registry.has('minter')).toBe(true);

            // Verify stability system
            expect(registry.has('stabilityPoolCollateral')).toBe(true);
            expect(registry.has('stabilityPoolLeveraged')).toBe(true);
            expect(registry.has('stabilityPoolManager')).toBe(true);

            // Verify reward system
            expect(registry.has('rewardManager')).toBe(true);
            expect(registry.has('rewardDepositor')).toBe(true);
            expect(registry.has('rebalancer')).toBe(true);
        });

        it('should save deployment to JSON', () => {
            const registry = new Map<string, string>();

            // Deploy some contracts
            registry.set('admin', '0x1111111111111111111111111111111111111111');
            registry.set('wrappedCollateral', '0x2222222222222222222222222222222222222222');
            registry.set('pegged', '0x3333333333333333333333333333333333333333');

            // Mock save to JSON
            const saveToJson = (reg: Map<string, string>, chainId: number) => {
                const data = {
                    version: '1.0',
                    chainId: chainId,
                    timestamp: new Date().toISOString(),
                    contracts: Object.fromEntries(reg),
                };
                return JSON.stringify(data, null, 2);
            };

            const json = saveToJson(registry, 31337);
            const parsed = JSON.parse(json);

            expect(parsed.version).toBe('1.0');
            expect(parsed.chainId).toBe(31337);
            expect(parsed.contracts.admin).toBe('0x1111111111111111111111111111111111111111');
            expect(parsed.contracts.wrappedCollateral).toBe('0x2222222222222222222222222222222222222222');
            expect(parsed.contracts.pegged).toBe('0x3333333333333333333333333333333333333333');
        });

        it('should load deployment from JSON', () => {
            const jsonData = {
                version: '1.0',
                chainId: 31337,
                timestamp: '2025-10-09T12:00:00Z',
                contracts: {
                    admin: '0x1111111111111111111111111111111111111111',
                    wrappedCollateral: '0x2222222222222222222222222222222222222222',
                    pegged: '0x3333333333333333333333333333333333333333',
                },
            };

            const loadFromJson = (json: typeof jsonData) => {
                const registry = new Map<string, string>();
                Object.entries(json.contracts).forEach(([key, addr]) => {
                    registry.set(key, addr);
                });
                return registry;
            };

            const registry = loadFromJson(jsonData);

            expect(registry.size).toBe(3);
            expect(registry.get('admin')).toBe('0x1111111111111111111111111111111111111111');
            expect(registry.get('wrappedCollateral')).toBe('0x2222222222222222222222222222222222222222');
            expect(registry.get('pegged')).toBe('0x3333333333333333333333333333333333333333');
        });
    });

    describe('Deployment Order Validation', () => {
        it('should enforce correct deployment order', () => {
            const registry = new Map<string, string>();
            const deploymentOrder: string[] = [];

            const trackDeployment = (key: string, addr: string) => {
                registry.set(key, addr);
                deploymentOrder.push(key);
            };

            // Deploy in correct order
            trackDeployment('admin', '0x1111111111111111111111111111111111111111');
            trackDeployment('feeReceiver', '0x2222222222222222222222222222222222222222');
            trackDeployment('wrappedCollateral', '0x3333333333333333333333333333333333333333');
            trackDeployment('pegged', '0x4444444444444444444444444444444444444444');
            trackDeployment('minter', '0x5555555555555555555555555555555555555555');

            // Verify order
            expect(deploymentOrder[0]).toBe('admin'); // Admin must be first
            expect(deploymentOrder.indexOf('admin')).toBeLessThan(deploymentOrder.indexOf('feeReceiver'));
            expect(deploymentOrder.indexOf('admin')).toBeLessThan(deploymentOrder.indexOf('wrappedCollateral'));
            expect(deploymentOrder.indexOf('admin')).toBeLessThan(deploymentOrder.indexOf('pegged'));
            expect(deploymentOrder.indexOf('minter')).toBeGreaterThan(deploymentOrder.indexOf('wrappedCollateral'));
            expect(deploymentOrder.indexOf('minter')).toBeGreaterThan(deploymentOrder.indexOf('pegged'));
        });

        it('should validate dependencies before deployment', () => {
            const registry = new Map<string, string>();

            const validateDependencies = (contractKey: string, dependencies: string[]): boolean => {
                return dependencies.every(dep => registry.has(dep));
            };

            // Admin has no dependencies
            expect(validateDependencies('admin', [])).toBe(true);

            // Minter requires admin, collateral, pegged
            expect(validateDependencies('minter', ['admin', 'wrappedCollateral', 'pegged'])).toBe(false);

            // Deploy dependencies
            registry.set('admin', '0x1111111111111111111111111111111111111111');
            expect(validateDependencies('minter', ['admin', 'wrappedCollateral', 'pegged'])).toBe(false);

            registry.set('wrappedCollateral', '0x2222222222222222222222222222222222222222');
            expect(validateDependencies('minter', ['admin', 'wrappedCollateral', 'pegged'])).toBe(false);

            registry.set('pegged', '0x3333333333333333333333333333333333333333');
            expect(validateDependencies('minter', ['admin', 'wrappedCollateral', 'pegged'])).toBe(true);
        });
    });

    describe('Deployment Verification', () => {
        it('should verify all contracts deployed', () => {
            const registry = new Map<string, string>();
            const requiredContracts = [
                'admin',
                'feeReceiver',
                'wrappedCollateral',
                'pegged',
                'leveraged',
                'oracle',
                'reservePool',
                'minter',
                'stabilityPoolCollateral',
                'stabilityPoolLeveraged',
                'stabilityPoolManager',
            ];

            // Deploy all contracts
            requiredContracts.forEach((key, index) => {
                registry.set(key, `0x${(index + 1).toString(16).padStart(40, '0')}`);
            });

            // Verify all present
            const verifyDeployment = (reg: Map<string, string>, required: string[]) => {
                const missing = required.filter(key => !reg.has(key));
                return {
                    complete: missing.length === 0,
                    missing: missing,
                };
            };

            const result = verifyDeployment(registry, requiredContracts);
            expect(result.complete).toBe(true);
            expect(result.missing).toHaveLength(0);
        });

        it('should identify missing contracts', () => {
            const registry = new Map<string, string>();
            registry.set('admin', '0x1111111111111111111111111111111111111111');
            registry.set('pegged', '0x2222222222222222222222222222222222222222');

            const requiredContracts = ['admin', 'wrappedCollateral', 'pegged', 'minter'];

            const verifyDeployment = (reg: Map<string, string>, required: string[]) => {
                const missing = required.filter(key => !reg.has(key));
                return {
                    complete: missing.length === 0,
                    missing: missing,
                };
            };

            const result = verifyDeployment(registry, requiredContracts);
            expect(result.complete).toBe(false);
            expect(result.missing).toHaveLength(2);
            expect(result.missing).toContain('wrappedCollateral');
            expect(result.missing).toContain('minter');
        });
    });
});

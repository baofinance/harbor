/**
 * Deploy Registry Operations Tests
 *
 * These tests validate the deployment registry operations,
 * mirroring the Python test_deploy_registry.py tests.
 *
 * This file tests the TypeScript DeploymentRegistry helper class.
 */

import { DeploymentRegistry } from '../../lib/typescript/deployment/DeploymentRegistry';

describe('DeploymentRegistry Operations', () => {
    describe('Basic Operations', () => {
        it('should set and get addresses', () => {
            const testAddr = '0x1234567890123456789012345678901234567890';
            const registry = new DeploymentRegistry();

            registry.set(DeploymentRegistry.WRAPPED_COLLATERAL, testAddr);

            expect(registry.has(DeploymentRegistry.WRAPPED_COLLATERAL)).toBe(true);
            expect(registry.get(DeploymentRegistry.WRAPPED_COLLATERAL)).toBe(testAddr);
            expect(registry.count()).toBe(1);
        });

        it('should handle missing keys correctly', () => {
            const registry = new DeploymentRegistry();

            expect(registry.has(DeploymentRegistry.MINTER)).toBe(false);
            expect(registry.tryGet(DeploymentRegistry.MINTER)).toBeNull();
        });

        it('should throw on missing required dependency', () => {
            const registry = new DeploymentRegistry();

            expect(() => registry.get(DeploymentRegistry.MINTER)).toThrow('missing dependency');
        });
    });

    describe('Multiple Contracts', () => {
        it('should manage multiple contract addresses', () => {
            const registry = new DeploymentRegistry();

            const contracts = {
                [DeploymentRegistry.ADMIN]: '0x1111111111111111111111111111111111111111',
                [DeploymentRegistry.WRAPPED_COLLATERAL]: '0x2222222222222222222222222222222222222222',
                [DeploymentRegistry.MINTER]: '0x3333333333333333333333333333333333333333',
            };

            Object.entries(contracts).forEach(([key, addr]) => {
                registry.set(key, addr);
            });

            expect(registry.count()).toBe(3);
            Object.entries(contracts).forEach(([key, addr]) => {
                expect(registry.has(key)).toBe(true);
                expect(registry.get(key)).toBe(addr);
            });

            const deployedKeys = registry.getDeployedContracts();
            expect(deployedKeys).toHaveLength(3);
            expect(deployedKeys).toContain(DeploymentRegistry.ADMIN);
            expect(deployedKeys).toContain(DeploymentRegistry.WRAPPED_COLLATERAL);
            expect(deployedKeys).toContain(DeploymentRegistry.MINTER);
        });
    });

    describe('Address Validation', () => {
        it('should reject zero address', () => {
            const registry = new DeploymentRegistry();
            const zeroAddr = '0x0000000000000000000000000000000000000000';

            expect(() => registry.set(DeploymentRegistry.WRAPPED_COLLATERAL, zeroAddr)).toThrow('zero address');
            expect(registry.has(DeploymentRegistry.WRAPPED_COLLATERAL)).toBe(false);
        });

        it('should accept valid non-zero addresses', () => {
            const registry = new DeploymentRegistry();
            const validAddr = '0x1234567890123456789012345678901234567890';

            registry.set(DeploymentRegistry.WRAPPED_COLLATERAL, validAddr);

            expect(registry.has(DeploymentRegistry.WRAPPED_COLLATERAL)).toBe(true);
            expect(registry.get(DeploymentRegistry.WRAPPED_COLLATERAL)).toBe(validAddr);
        });

        it('should validate address format', () => {
            const testAddresses = [
                '0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed',
                '0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359',
                '0xdbF03B407c01E7cD3CBea99509d93f8DDDC8C6FB',
            ];

            testAddresses.forEach(addr => {
                expect(addr).toMatch(/^0x[a-fA-F0-9]{40}$/);
            });
        });
    });

    describe('State Management', () => {
        it('should track count of registered contracts', () => {
            const registry = new DeploymentRegistry();

            expect(registry.count()).toBe(0);

            registry.set(DeploymentRegistry.ADMIN, '0x1111111111111111111111111111111111111111');
            expect(registry.count()).toBe(1);

            registry.set(DeploymentRegistry.MINTER, '0x2222222222222222222222222222222222222222');
            expect(registry.count()).toBe(2);
        });

        it('should allow updating existing addresses', () => {
            const registry = new DeploymentRegistry();
            const addr1 = '0x1111111111111111111111111111111111111111';
            const addr2 = '0x2222222222222222222222222222222222222222';

            registry.set(DeploymentRegistry.ADMIN, addr1);
            expect(registry.get(DeploymentRegistry.ADMIN)).toBe(addr1);

            registry.set(DeploymentRegistry.ADMIN, addr2);
            expect(registry.get(DeploymentRegistry.ADMIN)).toBe(addr2);
            expect(registry.count()).toBe(1);
        });

        it('should support clearing specific entries', () => {
            const registry = new DeploymentRegistry();

            registry.set(DeploymentRegistry.ADMIN, '0x1111111111111111111111111111111111111111');
            registry.set(DeploymentRegistry.MINTER, '0x2222222222222222222222222222222222222222');
            expect(registry.count()).toBe(2);

            registry.remove(DeploymentRegistry.ADMIN);
            expect(registry.has(DeploymentRegistry.ADMIN)).toBe(false);
            expect(registry.has(DeploymentRegistry.MINTER)).toBe(true);
            expect(registry.count()).toBe(1);
        });

        it('should support clearing all entries', () => {
            const registry = new DeploymentRegistry();

            registry.set(DeploymentRegistry.ADMIN, '0x1111111111111111111111111111111111111111');
            registry.set(DeploymentRegistry.MINTER, '0x2222222222222222222222222222222222222222');
            expect(registry.count()).toBe(2);

            registry.clear();
            expect(registry.count()).toBe(0);
            expect(registry.has(DeploymentRegistry.ADMIN)).toBe(false);
            expect(registry.has(DeploymentRegistry.MINTER)).toBe(false);
        });
    });

    describe('JSON Serialization', () => {
        it('should export to JSON format', () => {
            const registry = new DeploymentRegistry();

            registry.set(DeploymentRegistry.ADMIN, '0x1111111111111111111111111111111111111111');
            registry.set(DeploymentRegistry.MINTER, '0x2222222222222222222222222222222222222222');

            const json: any = registry.toJSON(1);

            expect(json).toHaveProperty('chainId', 1);
            expect(json).toHaveProperty('contracts');
            expect(json).toHaveProperty('deploymentOrder');
            expect(json).toHaveProperty('timestamp');
        });

        it('should import from JSON format', () => {
            const jsonData = {
                chainId: 1,
                contracts: {
                    admin: '0x1111111111111111111111111111111111111111',
                    minter: '0x2222222222222222222222222222222222222222',
                },
                deploymentOrder: ['admin', 'minter'],
                timestamp: '2025-10-09T00:00:00.000Z',
            };

            const registry = DeploymentRegistry.fromJSON(jsonData);

            expect(registry.count()).toBe(2);
            expect(registry.get('admin')).toBe('0x1111111111111111111111111111111111111111');
            expect(registry.get('minter')).toBe('0x2222222222222222222222222222222222222222');
        });

        it('should preserve deployment order in JSON', () => {
            const registry = new DeploymentRegistry();

            registry.set(DeploymentRegistry.ADMIN, '0x1111111111111111111111111111111111111111');
            registry.set(DeploymentRegistry.FEE_RECEIVER, '0x2222222222222222222222222222222222222222');
            registry.set(DeploymentRegistry.MINTER, '0x3333333333333333333333333333333333333333');

            const json: any = registry.toJSON(1);
            const order = json.deploymentOrder;

            expect(order).toEqual([
                DeploymentRegistry.ADMIN,
                DeploymentRegistry.FEE_RECEIVER,
                DeploymentRegistry.MINTER,
            ]);
        });
    });

    describe('Validation', () => {
        it('should validate required contracts', () => {
            const registry = new DeploymentRegistry();

            registry.set(DeploymentRegistry.ADMIN, '0x1111111111111111111111111111111111111111');
            registry.set(DeploymentRegistry.MINTER, '0x2222222222222222222222222222222222222222');

            const required = [DeploymentRegistry.ADMIN, DeploymentRegistry.MINTER];

            expect(() => registry.validateRequired(required)).not.toThrow();
        });

        it('should throw if required contracts missing', () => {
            const registry = new DeploymentRegistry();

            registry.set(DeploymentRegistry.ADMIN, '0x1111111111111111111111111111111111111111');

            const required = [DeploymentRegistry.ADMIN, DeploymentRegistry.MINTER];

            expect(() => registry.validateRequired(required)).toThrow('missing required contracts');
        });
    });

    describe('Utility Methods', () => {
        it('should convert to plain object', () => {
            const registry = new DeploymentRegistry();

            registry.set(DeploymentRegistry.ADMIN, '0x1111111111111111111111111111111111111111');
            registry.set(DeploymentRegistry.MINTER, '0x2222222222222222222222222222222222222222');

            const obj = registry.toObject();

            expect(obj).toEqual({
                [DeploymentRegistry.ADMIN]: '0x1111111111111111111111111111111111111111',
                [DeploymentRegistry.MINTER]: '0x2222222222222222222222222222222222222222',
            });
        });
    });
});

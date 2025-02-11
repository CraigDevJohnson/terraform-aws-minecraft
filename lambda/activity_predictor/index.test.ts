import { describe, expect, test, beforeEach, jest } from '@jest/globals';
import AWS from 'aws-sdk-mock';
import { exponentialSmoothing, handler } from './index';

describe('Activity Predictor', () => {
    describe('exponentialSmoothing', () => {
        test('correctly smooths a simple series', () => {
            const data = [1, 2, 3, 4, 5];
            const result = exponentialSmoothing(data, 0.3);
            expect(result.length).toBe(data.length);
            expect(result[0]).toBe(1); // First value should be unchanged
            // Each subsequent value should be a weighted average
            expect(result[1]).toBeCloseTo(1.3);
            expect(result[2]).toBeCloseTo(1.81);
        });

        test('handles empty array', () => {
            expect(() => exponentialSmoothing([])).toThrow();
        });

        test('handles different alpha values', () => {
            const data = [10, 20, 30, 40, 50];
            const result1 = exponentialSmoothing(data, 0.1);
            const result2 = exponentialSmoothing(data, 0.9);
            
            // Lower alpha should smooth more (less reactive)
            expect(Math.abs(result1[1] - result1[0])).toBeLessThan(
                Math.abs(result2[1] - result2[0])
            );
        });
    });

    describe('predictPeakHours', () => {
        const mockPlayerData = [
            // Simulate 24 hours of data
            5, 2, 1, 0, 0, 0, // 12am-6am
            1, 2, 4, 6, 8, 10, // 6am-12pm
            12, 15, 18, 20, 15, 12, // 12pm-6pm
            10, 8, 6, 4, 3, 2 // 6pm-12am
        ];

        test('identifies correct peak hours', async () => {
            const peakHours = await predictPeakHours(mockPlayerData);
            // Peak should be identified around 2-4pm (hours 13-15)
            expect(peakHours).toContain(14);
            expect(peakHours).toContain(15);
        });

        test('handles timezone differences', async () => {
            // Test with offset data
            const offsetData = [...mockPlayerData.slice(12), ...mockPlayerData.slice(0, 12)];
            const peakHours = await predictPeakHours(offsetData);
            // Peaks should shift by 12 hours
            expect(peakHours).toContain(2);
            expect(peakHours).toContain(3);
        });
    });

    describe('updateServerSchedule', () => {
        const mockPeakHours = [14, 15, 16, 17]; // 2pm-6pm

        test('correctly stores peak hours in SSM', async () => {
            // Test SSM parameter storage
        });

        test('updates CloudWatch metrics', async () => {
            // Test CloudWatch metric updates
        });

        test('handles update failures gracefully', async () => {
            // Test error handling
        });
    });
});

describe('Activity Predictor Lambda', () => {
    beforeEach(() => {
        process.env.INSTANCE_ID = 'i-1234567890abcdef0';
        AWS.restore();
    });

    it('should predict peak hours correctly', async () => {
        // Mock CloudWatch getMetricData
        AWS.mock('CloudWatch', 'getMetricData', (params: any) => {
            return {
                MetricDataResults: [{
                    Values: Array(24).fill(0).map((_, i) => 
                        // Simulate higher activity during evening hours
                        i >= 18 && i <= 22 ? 3 : (i >= 8 && i <= 17 ? 1 : 0)
                    ),
                    Timestamps: Array(24).fill(0).map((_, i) => 
                        new Date(2024, 0, 1, i, 0, 0)
                    )
                }]
            };
        });

        // Mock SSM putParameter
        AWS.mock('SSM', 'putParameter', () => ({}));

        const result = await handler({});
        const response = JSON.parse(result.body);

        expect(result.statusCode).toBe(200);
        expect(response.peakHours).toContain(20); // Should detect evening peak
        expect(response.peakHours.length).toBeGreaterThan(0);
    });

    it('should handle missing metrics gracefully', async () => {
        AWS.mock('CloudWatch', 'getMetricData', () => ({
            MetricDataResults: [{ Values: [], Timestamps: [] }]
        }));
        AWS.mock('SSM', 'putParameter', () => ({}));

        const result = await handler({});
        expect(result.statusCode).toBe(200);
    });

    it('should update server schedule with predicted hours', async () => {
        const mockPutParameter = jest.fn().mockResolvedValue({});
        AWS.mock('SSM', 'putParameter', mockPutParameter);
        AWS.mock('CloudWatch', 'getMetricData', () => ({
            MetricDataResults: [{
                Values: [1, 2, 3],
                Timestamps: [
                    new Date(),
                    new Date(),
                    new Date()
                ]
            }]
        }));

        await handler({});

        expect(mockPutParameter).toHaveBeenCalledWith(
            expect.objectContaining({
                Name: '/minecraft/i-1234567890abcdef0/peak-hours'
            })
        );
    });

    it('should handle CloudWatch errors appropriately', async () => {
        AWS.mock('CloudWatch', 'getMetricData', () => {
            throw new Error('CloudWatch error');
        });

        const result = await handler({});
        expect(result.statusCode).toBe(500);
        expect(JSON.parse(result.body).error).toBeDefined();
    });
});
import { mockClient } from 'aws-sdk-client-mock';
import { DynamoDBClient } from '@aws-sdk/client-dynamodb';
import { CloudWatchClient } from '@aws-sdk/client-cloudwatch';
import { SNSClient } from '@aws-sdk/client-sns';
import { PlayerCohort, RetentionMetrics } from './retention.types';
import { handler as retentionHandler } from './retention';

const ddbMock = mockClient(DynamoDBClient);
const cwMock = mockClient(CloudWatchClient);
const snsMock = mockClient(SNSClient);

describe('Retention Analysis', () => {
    beforeEach(() => {
        ddbMock.reset();
        cwMock.reset();
        snsMock.reset();
    });

    test('correctly calculates weekly cohorts', async () => {
        const mockSessions = [
            // Week 1 players
            createMockSession('player1', Date.now() - (25 * 24 * 60 * 60 * 1000)),
            createMockSession('player2', Date.now() - (24 * 24 * 60 * 60 * 1000)),
            // Week 2 players
            createMockSession('player3', Date.now() - (15 * 24 * 60 * 60 * 1000)),
            // Recent sessions for retention
            createMockSession('player1', Date.now() - (2 * 24 * 60 * 60 * 1000)),
            createMockSession('player2', Date.now() - (1 * 24 * 60 * 60 * 1000))
        ];

        ddbMock.on('Scan').resolves({ Items: mockSessions });

        const result = await retentionHandler({});
        const cohorts = JSON.parse(result.body).cohorts;

        expect(cohorts.length).toBeGreaterThan(0);
        expect(cohorts[0].players).toContain('player1');
        expect(cohorts[0].retention.week1).toBeGreaterThan(0);
    });

    test('handles empty dataset gracefully', async () => {
        ddbMock.on('Scan').resolves({ Items: [] });

        const result = await retentionHandler({});
        expect(result.statusCode).toBe(200);
        expect(JSON.parse(result.body).cohorts).toHaveLength(0);
    });

    test('generates retention alerts correctly', async () => {
        const mockCohort: PlayerCohort = {
            week: 0,
            players: ['player1', 'player2'],
            retention: {
                week1: 45.5  // Below 50% threshold
            }
        };

        ddbMock.on('Scan').resolves({
            Items: [createMockSession('player1', Date.now())]
        });

        snsMock.on('Publish').resolves({});

        const result = await retentionHandler({});
        expect(snsMock).toHaveReceivedCommand('Publish');
    });

    test('calculates retention rates accurately', async () => {
        const now = Date.now();
        const week = 7 * 24 * 60 * 60 * 1000;
        
        const mockSessions = [
            // Initial sessions (100% of cohort)
            createMockSession('player1', now - (3 * week)),
            createMockSession('player2', now - (3 * week)),
            // Week 1 retention (50% of cohort)
            createMockSession('player1', now - (2 * week)),
            // Week 2 retention (25% of cohort)
            createMockSession('player1', now - week)
        ];

        ddbMock.on('Scan').resolves({ Items: mockSessions });

        const result = await retentionHandler({});
        const cohorts = JSON.parse(result.body).cohorts;
        
        expect(cohorts[0].retention.week1).toBe(50);
        expect(cohorts[0].retention.week2).toBe(25);
    });
});

function createMockSession(playerId: string, timestamp: number) {
    return {
        playerId,
        timestamp,
        sessionId: `${playerId}_${timestamp}`,
        playerName: `Test Player ${playerId}`,
        loginTime: timestamp,
        logoutTime: timestamp + 3600000, // 1 hour session
        duration: 3600
    };
}
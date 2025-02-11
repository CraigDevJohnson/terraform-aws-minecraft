import { DynamoDB, CloudWatch, SNS } from 'aws-sdk';
import { RetentionMetrics, PlayerCohort, RetentionEvent } from './types';

const dynamodb = new DynamoDB.DocumentClient();
const cloudwatch = new CloudWatch();
const sns = new SNS();

async function analyzeCohorts(): Promise<PlayerCohort[]> {
    const thirtyDaysAgo = Date.now() - (30 * 24 * 60 * 60 * 1000);
    const response = await dynamodb.scan({
        TableName: process.env.STATS_TABLE!,
        FilterExpression: 'timestamp >= :time',
        ExpressionAttributeValues: {
            ':time': thirtyDaysAgo
        }
    }).promise();

    const sessions = response.Items || [];
    const playerFirstSeen: { [key: string]: number } = {};
    
    // Group players by first seen date
    sessions.forEach(session => {
        const playerId = session.playerId;
        if (!playerFirstSeen[playerId] || session.timestamp < playerFirstSeen[playerId]) {
            playerFirstSeen[playerId] = session.timestamp;
        }
    });

    // Create weekly cohorts
    const cohorts: PlayerCohort[] = [];
    const now = Date.now();
    
    Object.entries(playerFirstSeen).forEach(([playerId, firstSeen]) => {
        const weekNumber = Math.floor((now - firstSeen) / (7 * 24 * 60 * 60 * 1000));
        const cohort = cohorts[weekNumber] || { week: weekNumber, players: [], retention: {} };
        cohort.players.push(playerId);
        cohorts[weekNumber] = cohort;
    });

    // Calculate retention rates
    return calculateRetentionRates(cohorts, sessions);
}

async function calculateRetentionRates(cohorts: PlayerCohort[], sessions: any[]): Promise<PlayerCohort[]> {
    cohorts.forEach(cohort => {
        const cohortPlayers = new Set(cohort.players);
        
        // Calculate retention for each week after joining
        for (let week = 1; week <= 4; week++) {
            const activeInWeek = new Set(
                sessions
                    .filter(s => {
                        const sessionWeek = Math.floor((s.timestamp - cohort.week * 7 * 24 * 60 * 60 * 1000) / (7 * 24 * 60 * 60 * 1000));
                        return sessionWeek === week && cohortPlayers.has(s.playerId);
                    })
                    .map(s => s.playerId)
            );
            
            cohort.retention[`week${week}`] = (activeInWeek.size / cohortPlayers.size) * 100;
        }
    });

    // Record retention metrics in CloudWatch
    await recordRetentionMetrics(cohorts);
    
    return cohorts;
}

async function recordRetentionMetrics(cohorts: PlayerCohort[]): Promise<void> {
    const metrics: RetentionMetrics[] = cohorts.flatMap(cohort => 
        Object.entries(cohort.retention).map(([week, rate]) => ({
            MetricName: 'PlayerRetention',
            Value: rate,
            Unit: 'Percent',
            Dimensions: [
                { Name: 'CohortWeek', Value: cohort.week.toString() },
                { Name: 'RetentionWeek', Value: week }
            ]
        }))
    );

    // Split metrics into chunks of 20 (CloudWatch API limit)
    for (let i = 0; i < metrics.length; i += 20) {
        await cloudwatch.putMetricData({
            Namespace: 'MinecraftServer/Retention',
            MetricData: metrics.slice(i, i + 20)
        }).promise();
    }
}

async function notifyRetentionChanges(cohorts: PlayerCohort[]): Promise<void> {
    // Alert if retention drops significantly
    const recentCohort = cohorts[cohorts.length - 1];
    if (recentCohort && recentCohort.retention.week1 < 50) {
        await sns.publish({
            TopicArn: process.env.ALERT_TOPIC_ARN,
            Subject: 'Low Player Retention Alert',
            Message: `Week 1 retention has dropped to ${recentCohort.retention.week1.toFixed(1)}% for the latest player cohort.`
        }).promise();
    }
}

export const handler = async (event: RetentionEvent): Promise<any> => {
    try {
        const cohorts = await analyzeCohorts();
        await notifyRetentionChanges(cohorts);
        
        return {
            statusCode: 200,
            body: JSON.stringify({
                cohorts,
                message: 'Retention analysis completed successfully'
            })
        };
    } catch (error) {
        console.error('Error:', error);
        throw error;
    }
};
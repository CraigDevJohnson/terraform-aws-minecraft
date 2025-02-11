const AWS = require('aws-sdk');
const moment = require('moment-timezone');

const dynamodb = new AWS.DynamoDB.DocumentClient();
const cloudwatch = new AWS.CloudWatch();

const STATS_TABLE = process.env.STATS_TABLE;
const PLAYER_TTL = 90 * 24 * 60 * 60; // 90 days in seconds

async function recordPlayerSession(playerData) {
    const timestamp = moment().unix();
    const ttl = timestamp + PLAYER_TTL;

    const item = {
        playerId: playerData.uuid,
        timestamp: timestamp,
        sessionId: `${playerData.uuid}_${timestamp}`,
        playerName: playerData.name,
        loginTime: playerData.loginTime,
        logoutTime: playerData.logoutTime,
        duration: playerData.logoutTime - playerData.loginTime,
        ttl: ttl
    };

    await dynamodb.put({
        TableName: STATS_TABLE,
        Item: item
    }).promise();

    // Record engagement metrics
    await cloudwatch.putMetricData({
        Namespace: 'MinecraftServer/Players',
        MetricData: [
            {
                MetricName: 'SessionDuration',
                Value: item.duration,
                Unit: 'Seconds',
                Dimensions: [
                    { Name: 'PlayerId', Value: playerData.uuid },
                    { Name: 'PlayerName', Value: playerData.name }
                ]
            },
            {
                MetricName: 'DailyEngagement',
                Value: 1,
                Unit: 'Count',
                Dimensions: [
                    { Name: 'PlayerId', Value: playerData.uuid },
                    { Name: 'PlayerName', Value: playerData.name }
                ]
            }
        ]
    }).promise();
}

async function generatePlayerStats(playerId) {
    const thirtyDaysAgo = moment().subtract(30, 'days').unix();
    
    const response = await dynamodb.query({
        TableName: STATS_TABLE,
        KeyConditionExpression: 'playerId = :pid AND timestamp >= :time',
        ExpressionAttributeValues: {
            ':pid': playerId,
            ':time': thirtyDaysAgo
        }
    }).promise();

    const sessions = response.Items;
    
    // Calculate statistics
    const totalSessions = sessions.length;
    const totalPlaytime = sessions.reduce((acc, session) => acc + session.duration, 0);
    const averageSession = totalSessions > 0 ? totalPlaytime / totalSessions : 0;
    
    // Record monthly stats
    await cloudwatch.putMetricData({
        Namespace: 'MinecraftServer/PlayerStats',
        MetricData: [
            {
                MetricName: 'MonthlyPlaytime',
                Value: totalPlaytime,
                Unit: 'Seconds',
                Dimensions: [{ Name: 'PlayerId', Value: playerId }]
            },
            {
                MetricName: 'MonthlySessions',
                Value: totalSessions,
                Unit: 'Count',
                Dimensions: [{ Name: 'PlayerId', Value: playerId }]
            },
            {
                MetricName: 'AverageSessionDuration',
                Value: averageSession,
                Unit: 'Seconds',
                Dimensions: [{ Name: 'PlayerId', Value: playerId }]
            }
        ]
    }).promise();

    return {
        totalSessions,
        totalPlaytime,
        averageSession,
        recentSessions: sessions.slice(0, 5)
    };
}

async function getServerStats() {
    const now = moment();
    const response = await dynamodb.scan({
        TableName: STATS_TABLE,
        FilterExpression: 'timestamp >= :time',
        ExpressionAttributeValues: {
            ':time': now.subtract(24, 'hours').unix()
        }
    }).promise();

    const sessions = response.Items;
    const uniquePlayers = new Set(sessions.map(s => s.playerId)).size;
    const totalPlaytime = sessions.reduce((acc, session) => acc + session.duration, 0);

    return {
        last24Hours: {
            uniquePlayers,
            totalPlaytime,
            sessionCount: sessions.length
        }
    };
}

exports.handler = async (event) => {
    switch (event.action) {
        case 'recordSession':
            await recordPlayerSession(event.playerData);
            return { message: 'Session recorded successfully' };
            
        case 'getPlayerStats':
            const playerStats = await generatePlayerStats(event.playerId);
            return playerStats;
            
        case 'getServerStats':
            const serverStats = await getServerStats();
            return serverStats;
            
        default:
            throw new Error('Unknown action');
    }
};
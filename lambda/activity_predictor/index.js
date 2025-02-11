const AWS = require('aws-sdk');
const cloudwatch = new AWS.CloudWatch();
const ssm = new AWS.SSM();
const ec2 = new AWS.EC2();

// Exponential smoothing for time series prediction
async function predictPeakHours(playerData) {
    const alpha = 0.3; // Smoothing factor
    let smoothedData = Array(24).fill(0);
    
    // Initialize with raw data
    for (let hour = 0; hour < 24; hour++) {
        smoothedData[hour] = playerData[hour] || 0;
    }

    // Apply exponential smoothing
    for (let i = 1; i < playerData.length; i++) {
        smoothedData[i] = alpha * playerData[i] + (1 - alpha) * smoothedData[i - 1];
    }

    // Identify peak hours (hours with activity above threshold)
    const threshold = 0.5; // 50% of max activity
    const maxActivity = Math.max(...smoothedData);
    const peakHours = smoothedData
        .map((value, hour) => ({ hour, value }))
        .filter(({ value }) => value > threshold * maxActivity)
        .map(({ hour }) => hour);

    return peakHours;
}

async function getHistoricalPlayerData(instanceId) {
    const endTime = new Date();
    const startTime = new Date(endTime - 7 * 24 * 60 * 60 * 1000); // Last 7 days

    const response = await cloudwatch.getMetricData({
        MetricDataQueries: [{
            Id: 'players',
            MetricStat: {
                Metric: {
                    Namespace: 'MinecraftServer',
                    MetricName: 'PlayerCount',
                    Dimensions: [{ Name: 'InstanceId', Value: instanceId }]
                },
                Period: 3600, // 1 hour
                Stat: 'Average'
            }
        }],
        StartTime: startTime,
        EndTime: endTime
    }).promise();

    // Aggregate data by hour
    const hourlyData = Array(24).fill(0);
    response.MetricDataResults[0].Timestamps.forEach((timestamp, i) => {
        const hour = new Date(timestamp).getHours();
        hourlyData[hour] += response.MetricDataResults[0].Values[i];
    });

    return hourlyData;
}

async function updateServerSchedule(instanceId, peakHours) {
    // Update SSM parameter with peak hours
    await ssm.putParameter({
        Name: `/minecraft/${instanceId}/peak-hours`,
        Value: JSON.stringify(peakHours),
        Type: 'String',
        Overwrite: true
    }).promise();

    // Stop instance if currently outside peak hours and no players
    const currentHour = new Date().getHours();
    if (!peakHours.includes(currentHour)) {
        const playerCount = await getCurrentPlayerCount(instanceId);
        if (playerCount === 0) {
            await initiateServerStop(instanceId);
        }
    }
}

async function getCurrentPlayerCount(instanceId) {
    const response = await cloudwatch.getMetricData({
        MetricDataQueries: [{
            Id: 'players',
            MetricStat: {
                Metric: {
                    Namespace: 'MinecraftServer',
                    MetricName: 'PlayerCount',
                    Dimensions: [{ Name: 'InstanceId', Value: instanceId }]
                },
                Period: 300,
                Stat: 'Maximum'
            }
        }],
        StartTime: new Date(Date.now() - 300000),
        EndTime: new Date()
    }).promise();

    return response.MetricDataResults[0].Values[0] || 0;
}

async function initiateServerStop(instanceId) {
    // Trigger graceful shutdown via SSM
    await ssm.sendCommand({
        DocumentName: 'AWS-RunShellScript',
        Parameters: {
            commands: ['/usr/local/bin/graceful-shutdown.sh']
        },
        InstanceIds: [instanceId]
    }).promise();
}

exports.handler = async (event) => {
    const instanceId = process.env.INSTANCE_ID;
    
    try {
        // Get historical player data
        const playerData = await getHistoricalPlayerData(instanceId);
        
        // Predict peak hours
        const peakHours = await predictPeakHours(playerData);
        
        // Update server schedule
        await updateServerSchedule(instanceId, peakHours);
        
        return {
            statusCode: 200,
            body: JSON.stringify({
                peakHours,
                message: 'Server schedule updated successfully'
            })
        };
    } catch (error) {
        console.error('Error in activity prediction:', error);
        return {
            statusCode: 500,
            body: JSON.stringify({
                error: error.message
            })
        };
    }
};
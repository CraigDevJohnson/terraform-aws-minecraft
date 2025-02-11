const AWS = require('aws-sdk');
const fs = require('fs').promises;
const path = require('path');

const cloudwatch = new AWS.CloudWatch();
const s3 = new AWS.S3();
const ssm = new AWS.SSM();

const METRICS_INTERVAL = 60000; // 1 minute
const INACTIVITY_THRESHOLD = 30 * 60 * 1000; // 30 minutes
const CPU_CREDIT_WARNING = 20; // Alert when CPU credits drop below 20

async function getBedrockPlayerCount(logPath) {
    try {
        const log = await fs.readFile(logPath, 'utf8');
        const lastLogs = log.split('\n').slice(-100).join('\n'); // Last 100 lines
        const matches = lastLogs.match(/Player connected|Player disconnected/g) || [];
        
        // Count current players
        let count = 0;
        matches.forEach(match => {
            count += match.includes('connected') ? 1 : -1;
        });
        return Math.max(0, count); // Ensure non-negative
    } catch (error) {
        console.error('Error reading player count:', error);
        return 0;
    }
}

async function getJavaPlayerCount(logPath) {
    try {
        const log = await fs.readFile(logPath, 'utf8');
        const joins = log.match(/joined the game/g) || [];
        const leaves = log.match(/left the game/g) || [];
        return joins.length - leaves.length;
    } catch (error) {
        console.error('Error reading Java log:', error);
        return 0;
    }
}

async function getSystemMetrics() {
    const metrics = {
        cpuUsage: 0,
        memoryUsage: 0,
        cpuCredits: 0,
        diskIO: 0
    };

    try {
        // Get CPU credits for t3a.small
        const cpuCredits = await cloudwatch.getMetricData({
            MetricDataQueries: [{
                Id: 'credits',
                MetricStat: {
                    Metric: {
                        Namespace: 'AWS/EC2',
                        MetricName: 'CPUCreditBalance',
                        Dimensions: [{
                            Name: 'InstanceId',
                            Value: process.env.INSTANCE_ID
                        }]
                    },
                    Period: 300,
                    Stat: 'Average'
                }
            }],
            StartTime: new Date(Date.now() - 300000), // Last 5 minutes
            EndTime: new Date()
        }).promise();

        metrics.cpuCredits = cpuCredits.MetricDataResults[0].Values[0] || 0;

        // Alert if CPU credits are low
        if (metrics.cpuCredits < CPU_CREDIT_WARNING) {
            console.warn(`Low CPU credits: ${metrics.cpuCredits}`);
            // Consider reducing view distance or other optimizations
        }

        // Read current memory usage
        const memInfo = await fs.readFile('/proc/meminfo', 'utf8');
        const memTotal = parseInt(memInfo.match(/MemTotal:\s+(\d+)/)[1]);
        const memAvailable = parseInt(memInfo.match(/MemAvailable:\s+(\d+)/)[1]);
        metrics.memoryUsage = ((memTotal - memAvailable) / memTotal) * 100;

    } catch (error) {
        console.error('Error getting system metrics:', error);
    }

    return metrics;
}

async function uploadMetrics(metrics, instanceId, serverType) {
    const now = new Date();
    const isActiveHour = await checkActiveHours();

    await cloudwatch.putMetricData({
        Namespace: 'MinecraftServer',
        MetricData: [
            {
                MetricName: 'PlayerCount',
                Value: metrics.playerCount,
                Unit: 'Count',
                Dimensions: [
                    { Name: 'InstanceId', Value: instanceId },
                    { Name: 'ServerType', Value: serverType }
                ]
            },
            {
                MetricName: 'CPUCredits',
                Value: metrics.cpuCredits,
                Unit: 'Count',
                Dimensions: [{ Name: 'InstanceId', Value: instanceId }]
            },
            {
                MetricName: 'MemoryUsage',
                Value: metrics.memoryUsage,
                Unit: 'Percent',
                Dimensions: [{ Name: 'InstanceId', Value: instanceId }]
            }
        ]
    }).promise();

    // Check for auto-shutdown conditions
    if (!isActiveHour && metrics.playerCount === 0) {
        const lastActivity = await getLastPlayerActivity();
        if (Date.now() - lastActivity > INACTIVITY_THRESHOLD) {
            await initiateShutdown(instanceId);
        }
    }
}

async function checkActiveHours() {
    const hour = new Date().getHours();
    const params = await ssm.getParameter({
        Name: '/minecraft/config/active-hours',
        WithDecryption: false
    }).promise();

    const { start, end } = JSON.parse(params.Parameter.Value);
    return hour >= start && hour <= end;
}

async function getLastPlayerActivity() {
    try {
        const params = await ssm.getParameter({
            Name: '/minecraft/status/last-activity',
            WithDecryption: false
        }).promise();
        return parseInt(params.Parameter.Value);
    } catch (error) {
        return Date.now(); // Default to current time if parameter doesn't exist
    }
}

async function initiateShutdown(instanceId) {
    console.log('Initiating server shutdown due to inactivity');
    await ssm.sendCommand({
        DocumentName: 'AWS-RunShellScript',
        Parameters: {
            commands: ['/usr/local/bin/graceful-shutdown.sh']
        },
        InstanceIds: [instanceId]
    }).promise();
}

async function monitorServer(config) {
    const {
        serverRoot,
        serverType,
        instanceId,
        logPath
    } = config;

    while (true) {
        try {
            const playerCount = serverType === 'bedrock' ?
                await getBedrockPlayerCount(logPath) :
                await getJavaPlayerCount(logPath);

            const systemMetrics = await getSystemMetrics();

            await uploadMetrics({
                playerCount,
                ...systemMetrics
            }, instanceId, serverType);

        } catch (error) {
            console.error('Error in monitoring loop:', error);
        }

        await new Promise(resolve => setTimeout(resolve, METRICS_INTERVAL));
    }
}

module.exports = { monitorServer };
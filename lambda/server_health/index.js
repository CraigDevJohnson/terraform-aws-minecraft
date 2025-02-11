const AWS = require('aws-sdk');
const cloudwatch = new AWS.CloudWatch();
const sns = new AWS.SNS();
const ssm = new AWS.SSM();

// Performance thresholds
const THRESHOLDS = {
    tps: {
        warning: 15,    // Below 15 TPS triggers warning
        critical: 10    // Below 10 TPS triggers critical alert
    },
    mspt: {
        warning: 45,    // Above 45ms per tick triggers warning
        critical: 50    // Above 50ms per tick triggers critical alert
    },
    memoryUsage: {
        warning: 85,    // Above 85% memory usage triggers warning
        critical: 95    // Above 95% memory usage triggers critical alert
    }
};

async function calculateTPS(tickTimes) {
    const recentTicks = tickTimes.slice(-20); // Last 20 ticks
    const avgTickTime = recentTicks.reduce((a, b) => a + b, 0) / recentTicks.length;
    return Math.min(20, 1000 / avgTickTime); // TPS capped at 20
}

async function monitorServerHealth(metrics) {
    const {
        tickTimes,
        memoryUsage,
        activeConnections,
        chunkLoadTime,
        worldSize
    } = metrics;

    const tps = await calculateTPS(tickTimes);
    const mspt = tickTimes[tickTimes.length - 1];

    // Record detailed metrics
    await cloudwatch.putMetricData({
        Namespace: 'MinecraftServer/Performance',
        MetricData: [
            {
                MetricName: 'TPS',
                Value: tps,
                Unit: 'Count/Second'
            },
            {
                MetricName: 'MSPT',
                Value: mspt,
                Unit: 'Milliseconds'
            },
            {
                MetricName: 'MemoryUsage',
                Value: memoryUsage,
                Unit: 'Percent'
            },
            {
                MetricName: 'ChunkLoadTime',
                Value: chunkLoadTime,
                Unit: 'Milliseconds'
            },
            {
                MetricName: 'WorldSize',
                Value: worldSize,
                Unit: 'Megabytes'
            }
        ]
    }).promise();

    // Check for performance issues
    const alerts = [];
    
    if (tps < THRESHOLDS.tps.critical) {
        alerts.push({
            severity: 'CRITICAL',
            metric: 'TPS',
            value: tps,
            message: 'Server experiencing severe lag'
        });
    } else if (tps < THRESHOLDS.tps.warning) {
        alerts.push({
            severity: 'WARNING',
            metric: 'TPS',
            value: tps,
            message: 'Server experiencing minor lag'
        });
    }

    if (mspt > THRESHOLDS.mspt.critical) {
        alerts.push({
            severity: 'CRITICAL',
            metric: 'MSPT',
            value: mspt,
            message: 'Tick processing time critically high'
        });
    }

    if (memoryUsage > THRESHOLDS.memoryUsage.critical) {
        alerts.push({
            severity: 'CRITICAL',
            metric: 'Memory',
            value: memoryUsage,
            message: 'Memory usage critically high'
        });
    }

    // Send alerts if needed
    if (alerts.length > 0) {
        await sendAlerts(alerts);
        await recommendActions(alerts);
    }

    return {
        healthStatus: alerts.length === 0 ? 'healthy' : 
                     alerts.some(a => a.severity === 'CRITICAL') ? 'critical' : 'warning',
        metrics: {
            tps,
            mspt,
            memoryUsage,
            activeConnections,
            chunkLoadTime,
            worldSize
        },
        alerts
    };
}

async function sendAlerts(alerts) {
    const message = alerts.map(alert => 
        `${alert.severity}: ${alert.metric} - ${alert.message} (Value: ${alert.value})`
    ).join('\n');

    await sns.publish({
        TopicArn: process.env.ALERT_TOPIC_ARN,
        Subject: `Minecraft Server Health Alert - ${alerts[0].severity}`,
        Message: message
    }).promise();
}

async function recommendActions(alerts) {
    const recommendations = [];
    
    for (const alert of alerts) {
        switch (alert.metric) {
            case 'TPS':
                recommendations.push(
                    'Check for problem chunks or entities',
                    'Consider reducing view distance',
                    'Review redstone contraptions'
                );
                break;
            case 'Memory':
                recommendations.push(
                    'Increase Java heap size',
                    'Clear unused chunks',
                    'Review plugin memory usage'
                );
                break;
            case 'MSPT':
                recommendations.push(
                    'Optimize entity processing',
                    'Review automated farms',
                    'Check for excessive item entities'
                );
                break;
        }
    }

    if (recommendations.length > 0) {
        await cloudwatch.putMetricData({
            Namespace: 'MinecraftServer/Recommendations',
            MetricData: [{
                MetricName: 'RecommendationCount',
                Value: recommendations.length,
                Unit: 'Count'
            }]
        }).promise();

        // Store recommendations for admin dashboard
        // Implementation depends on your storage solution
    }

    return recommendations;
}

async function collectBedrockMetrics(instanceId) {
    try {
        const params = {
            Name: `/minecraft/${instanceId}/server-stats`,
            WithDecryption: false
        };
        
        const stats = await ssm.getParameter(params).promise();
        const metrics = JSON.parse(stats.Parameter.Value);

        await cloudwatch.putMetricData({
            Namespace: 'MinecraftServer/Performance',
            MetricData: [
                {
                    MetricName: 'TPS',
                    Value: metrics.tps || 20,
                    Unit: 'Count',
                    Dimensions: [{ Name: 'InstanceId', Value: instanceId }]
                },
                {
                    MetricName: 'MSPT',
                    Value: metrics.mspt || 0,
                    Unit: 'Milliseconds',
                    Dimensions: [{ Name: 'InstanceId', Value: instanceId }]
                },
                {
                    MetricName: 'ChunkLoadTime',
                    Value: metrics.chunkLoadTime || 0,
                    Unit: 'Milliseconds',
                    Dimensions: [{ Name: 'InstanceId', Value: instanceId }]
                }
            ]
        }).promise();

        return true;
    } catch (error) {
        console.error('Error collecting metrics:', error);
        return false;
    }
}

async function checkServerHealth(instanceId) {
    try {
        const metrics = await cloudwatch.getMetricData({
            MetricDataQueries: [
                {
                    Id: 'tps',
                    MetricStat: {
                        Metric: {
                            Namespace: 'MinecraftServer/Performance',
                            MetricName: 'TPS',
                            Dimensions: [{ Name: 'InstanceId', Value: instanceId }]
                        },
                        Period: 300,
                        Stat: 'Average'
                    }
                },
                {
                    Id: 'mspt',
                    MetricStat: {
                        Metric: {
                            Namespace: 'MinecraftServer/Performance',
                            MetricName: 'MSPT',
                            Dimensions: [{ Name: 'InstanceId', Value: instanceId }]
                        },
                        Period: 300,
                        Stat: 'Average'
                    }
                }
            ],
            StartTime: new Date(Date.now() - 300000),
            EndTime: new Date()
        }).promise();

        // Analyze health and store results
        const health = {
            status: 'healthy',
            tps: metrics.MetricDataResults[0].Values[0] || 20,
            mspt: metrics.MetricDataResults[1].Values[0] || 0,
            timestamp: new Date().toISOString()
        };

        if (health.tps < 15) {
            health.status = 'degraded';
        }
        if (health.mspt > 45) {
            health.status = 'critical';
        }

        await ssm.putParameter({
            Name: `/minecraft/${instanceId}/health-status`,
            Value: JSON.stringify(health),
            Type: 'String',
            Overwrite: true
        }).promise();

        return health;
    } catch (error) {
        console.error('Error checking server health:', error);
        throw error;
    }
}

exports.handler = async (event) => {
    const instanceId = process.env.INSTANCE_ID;
    
    try {
        await collectBedrockMetrics(instanceId);
        const health = await checkServerHealth(instanceId);
        
        return {
            statusCode: 200,
            body: JSON.stringify({
                message: 'Health check completed',
                health
            })
        };
    } catch (error) {
        return {
            statusCode: 500,
            body: JSON.stringify({
                message: 'Error performing health check',
                error: error.message
            })
        };
    }
};
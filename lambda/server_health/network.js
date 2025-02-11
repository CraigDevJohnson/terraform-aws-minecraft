const AWS = require('aws-sdk');
const cloudwatch = new AWS.CloudWatch();
const net = require('net');
const dgram = require('dgram');

// Network performance thresholds
const NETWORK_THRESHOLDS = {
    latency: {
        warning: 100,    // Above 100ms triggers warning
        critical: 200    // Above 200ms triggers critical alert
    },
    packetLoss: {
        warning: 1,      // Above 1% triggers warning
        critical: 5      // Above 5% triggers critical alert
    },
    bandwidth: {
        warning: 80,     // Above 80% utilization triggers warning
        critical: 95     // Above 95% utilization triggers critical alert
    }
};

// Map of test regions and their endpoints
const LATENCY_TEST_REGIONS = {
    'us-east-1': ['us-east-1.compute.amazonaws.com', 'us-west-1.compute.amazonaws.com'],
    'eu-west-1': ['eu-west-1.compute.amazonaws.com', 'eu-central-1.compute.amazonaws.com'],
    'ap-southeast-1': ['ap-southeast-1.compute.amazonaws.com', 'ap-northeast-1.compute.amazonaws.com']
};

class NetworkMonitor {
    constructor(serverIp, serverPort) {
        this.serverIp = serverIp;
        this.serverPort = serverPort;
        this.results = new Map();
    }

    async measureLatency(endpoint) {
        const startTime = Date.now();
        try {
            const result = await new Promise((resolve, reject) => {
                const socket = net.createConnection(this.serverPort, this.serverIp, () => {
                    const latency = Date.now() - startTime;
                    socket.destroy();
                    resolve({ latency, status: 'success' });
                });

                socket.setTimeout(5000);
                socket.on('timeout', () => {
                    socket.destroy();
                    resolve({ latency: -1, status: 'timeout' });
                });

                socket.on('error', (err) => {
                    socket.destroy();
                    resolve({ latency: -1, status: 'error', error: err.message });
                });
            });
            return result;
        } catch (error) {
            return { latency: -1, status: 'error', error: error.message };
        }
    }

    async monitorRegions() {
        for (const [region, endpoints] of Object.entries(LATENCY_TEST_REGIONS)) {
            const latencies = await Promise.all(endpoints.map(endpoint => this.measureLatency(endpoint)));
            const validLatencies = latencies.filter(l => l.status === 'success').map(l => l.latency);
            
            if (validLatencies.length > 0) {
                const avgLatency = validLatencies.reduce((a, b) => a + b, 0) / validLatencies.length;
                this.results.set(region, avgLatency);
            }
        }
    }

    async publishMetrics(instanceId) {
        const metrics = [];
        
        for (const [region, latency] of this.results.entries()) {
            metrics.push({
                MetricName: 'RegionalLatency',
                Value: latency,
                Unit: 'Milliseconds',
                Dimensions: [
                    { Name: 'InstanceId', Value: instanceId },
                    { Name: 'Region', Value: region }
                ]
            });
        }

        if (metrics.length > 0) {
            await cloudwatch.putMetricData({
                Namespace: 'MinecraftServer/Network',
                MetricData: metrics
            }).promise();
        }

        return this.results;
    }
}

async function monitorNetworkPerformance(metrics) {
    const {
        playerLatencies,    // Map of player IDs to their latencies
        packetLossRates,   // Map of player IDs to packet loss rates
        bandwidthUsage,    // Current bandwidth usage in Mbps
        connectionCount    // Number of active connections
    } = metrics;

    // Calculate average latency
    const avgLatency = Object.values(playerLatencies)
        .reduce((sum, latency) => sum + latency, 0) / Object.keys(playerLatencies).length;

    // Calculate average packet loss
    const avgPacketLoss = Object.values(packetLossRates)
        .reduce((sum, rate) => sum + rate, 0) / Object.keys(packetLossRates).length;

    // Record network metrics
    await cloudwatch.putMetricData({
        Namespace: 'MinecraftServer/Network',
        MetricData: [
            {
                MetricName: 'AverageLatency',
                Value: avgLatency,
                Unit: 'Milliseconds'
            },
            {
                MetricName: 'PacketLoss',
                Value: avgPacketLoss,
                Unit: 'Percent'
            },
            {
                MetricName: 'BandwidthUsage',
                Value: bandwidthUsage,
                Unit: 'Megabits/Second'
            },
            {
                MetricName: 'ActiveConnections',
                Value: connectionCount,
                Unit: 'Count'
            }
        ]
    }).promise();

    // Check for individual player issues
    const playerIssues = [];
    Object.entries(playerLatencies).forEach(([playerId, latency]) => {
        if (latency > NETWORK_THRESHOLDS.latency.critical) {
            playerIssues.push({
                playerId,
                issue: 'High Latency',
                value: latency,
                severity: 'CRITICAL'
            });
        } else if (latency > NETWORK_THRESHOLDS.latency.warning) {
            playerIssues.push({
                playerId,
                issue: 'High Latency',
                value: latency,
                severity: 'WARNING'
            });
        }
    });

    Object.entries(packetLossRates).forEach(([playerId, lossRate]) => {
        if (lossRate > NETWORK_THRESHOLDS.packetLoss.critical) {
            playerIssues.push({
                playerId,
                issue: 'Packet Loss',
                value: lossRate,
                severity: 'CRITICAL'
            });
        }
    });

    return {
        status: avgLatency > NETWORK_THRESHOLDS.latency.critical ? 'critical' :
                avgLatency > NETWORK_THRESHOLDS.latency.warning ? 'warning' : 'healthy',
        metrics: {
            averageLatency: avgLatency,
            packetLoss: avgPacketLoss,
            bandwidthUsage,
            connectionCount
        },
        playerIssues
    };
}

async function checkBedrockConnectivity(host, port) {
    return new Promise((resolve) => {
        const client = dgram.createSocket('udp4');
        const timeout = setTimeout(() => {
            client.close();
            resolve({
                latency: -1,
                status: 'timeout'
            });
        }, 5000);

        const startTime = Date.now();
        
        // Bedrock ping packet
        const packet = Buffer.from([
            0x01, // Unconnected Ping
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // Request ID
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00  // Time
        ]);

        client.on('message', () => {
            clearTimeout(timeout);
            const latency = Date.now() - startTime;
            client.close();
            resolve({
                latency,
                status: 'online'
            });
        });

        client.send(packet, port, host, (err) => {
            if (err) {
                clearTimeout(timeout);
                client.close();
                resolve({
                    latency: -1,
                    status: 'error',
                    error: err.message
                });
            }
        });
    });
}

async function trackNetworkMetrics(instanceId, publicIp) {
    const cloudwatch = new AWS.CloudWatch();
    const regions = ['us-east-1', 'eu-west-1', 'ap-southeast-1']; // Key regions to test from
    const port = process.env.SERVER_PORT || 19132;

    const metrics = [];
    
    for (const region of regions) {
        const result = await checkBedrockConnectivity(publicIp, port);
        
        if (result.latency > 0) {
            metrics.push({
                MetricName: 'NetworkLatency',
                Value: result.latency,
                Unit: 'Milliseconds',
                Dimensions: [
                    { Name: 'InstanceId', Value: instanceId },
                    { Name: 'SourceRegion', Value: region }
                ]
            });
        }
    }

    if (metrics.length > 0) {
        await cloudwatch.putMetricData({
            Namespace: 'MinecraftServer/Network',
            MetricData: metrics
        }).promise();
    }

    return metrics;
}

exports.handler = async (event) => {
    try {
        const networkStatus = await monitorNetworkPerformance(event.metrics);
        return {
            statusCode: 200,
            body: JSON.stringify(networkStatus)
        };
    } catch (error) {
        console.error('Error:', error);
        throw error;
    }
};

module.exports = {
    checkBedrockConnectivity,
    trackNetworkMetrics,
    NetworkMonitor
};
const AWS = require('aws-sdk');
const dns = require('dns');
const net = require('net');
const { promisify } = require('util');

const s3 = new AWS.S3();
const cloudwatch = new AWS.CloudWatch();
const lookup = promisify(dns.lookup);

// Function to check if server is responding
async function checkServerStatus(host, port) {
    return new Promise((resolve) => {
        const socket = new net.Socket();
        const onError = () => {
            socket.destroy();
            resolve(false);
        };

        socket.setTimeout(5000);
        socket.on('error', onError);
        socket.on('timeout', onError);

        socket.connect(port, host, () => {
            socket.destroy();
            resolve(true);
        });
    });
}

// Generate status page HTML
function generateStatusHtml(status, serverInfo) {
    const timestamp = new Date().toLocaleString();
    return `
<!DOCTYPE html>
<html>
<head>
    <title>Minecraft Server Status</title>
    <meta http-equiv="refresh" content="300">
    <style>
        body { font-family: Arial, sans-serif; max-width: 800px; margin: 2em auto; padding: 0 1em; }
        .status { padding: 1em; border-radius: 4px; margin: 1em 0; }
        .online { background: #e6ffe6; color: #006600; }
        .offline { background: #ffe6e6; color: #660000; }
        .info { background: #f0f0f0; padding: 1em; border-radius: 4px; }
    </style>
</head>
<body>
    <h1>Minecraft Server Status</h1>
    <div class="status ${status ? 'online' : 'offline'}">
        Server is currently ${status ? 'ONLINE' : 'OFFLINE'}
    </div>
    <div class="info">
        <p><strong>Server Address:</strong> ${serverInfo.domain || serverInfo.ip}</p>
        <p><strong>Port:</strong> ${serverInfo.port}</p>
        <p><strong>Edition:</strong> ${serverInfo.type}</p>
        <p><strong>Last Updated:</strong> ${timestamp}</p>
    </div>
</body>
</html>`;
}

exports.handler = async (event) => {
    const { SERVER_IP, SERVER_PORT, SERVER_TYPE, DOMAIN_NAME, STATUS_BUCKET } = process.env;
    
    try {
        // Check server status
        const isOnline = await checkServerStatus(SERVER_IP, SERVER_PORT);
        
        // Generate status page
        const html = generateStatusHtml(isOnline, {
            ip: SERVER_IP,
            port: SERVER_PORT,
            type: SERVER_TYPE,
            domain: DOMAIN_NAME
        });
        
        // Upload to S3
        await s3.putObject({
            Bucket: STATUS_BUCKET,
            Key: 'index.html',
            Body: html,
            ContentType: 'text/html',
            CacheControl: 'max-age=60'
        }).promise();
        
        // Put metrics in CloudWatch
        await cloudwatch.putMetricData({
            Namespace: 'MinecraftServer',
            MetricData: [
                {
                    MetricName: 'ServerStatus',
                    Value: isOnline ? 1 : 0,
                    Unit: 'Count',
                    Dimensions: [
                        {
                            Name: 'ServerIP',
                            Value: SERVER_IP
                        },
                        {
                            Name: 'ServerType',
                            Value: SERVER_TYPE
                        }
                    ]
                }
            ]
        }).promise();
        
        return {
            statusCode: 200,
            body: JSON.stringify({
                status: isOnline ? 'online' : 'offline',
                timestamp: new Date().toISOString()
            })
        };
    } catch (error) {
        console.error('Error:', error);
        throw error;
    }
};
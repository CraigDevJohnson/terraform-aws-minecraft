const AWS = require('aws-sdk');
const axios = require('axios');
const ssm = new AWS.SSM();
const sns = new AWS.SNS();

async function getLatestBedrockVersion() {
    try {
        const response = await axios.get('https://www.minecraft.net/en-us/download/server/bedrock');
        const versionMatch = response.data.match(/bedrock-server-(\d+\.\d+\.\d+\.\d+)\.zip/);
        return versionMatch ? versionMatch[1] : null;
    } catch (error) {
        console.error('Error fetching latest version:', error);
        return null;
    }
}

async function getCurrentVersion(instanceId) {
    try {
        const response = await ssm.getParameter({
            Name: `/minecraft/${instanceId}/server-version`,
            WithDecryption: false
        }).promise();
        return response.Parameter.Value;
    } catch (error) {
        if (error.code === 'ParameterNotFound') {
            return null;
        }
        throw error;
    }
}

async function updateServer(instanceId, newVersion) {
    // Create SSM command to update server
    const commands = [
        'systemctl stop minecraft',
        'cd /home/minecraft',
        'aws s3 cp . s3://${BUCKET_NAME}/backup-$(date +%Y%m%d)/ --recursive',
        `wget -O bedrock-server.zip "https://minecraft.azureedge.net/bin-linux/bedrock-server-${newVersion}.zip"`,
        'unzip -o bedrock-server.zip',
        'chmod +x bedrock_server',
        'systemctl start minecraft'
    ];

    await ssm.sendCommand({
        DocumentName: 'AWS-RunShellScript',
        InstanceIds: [instanceId],
        Parameters: {
            commands
        }
    }).promise();

    // Update version in SSM
    await ssm.putParameter({
        Name: `/minecraft/${instanceId}/server-version`,
        Value: newVersion,
        Type: 'String',
        Overwrite: true
    }).promise();

    // Send notification
    if (process.env.SNS_TOPIC_ARN) {
        await sns.publish({
            TopicArn: process.env.SNS_TOPIC_ARN,
            Subject: 'Minecraft Server Update Complete',
            Message: `Server has been updated to version ${newVersion}`
        }).promise();
    }
}

exports.handler = async (event) => {
    const instanceId = process.env.INSTANCE_ID;
    const autoUpdate = process.env.AUTO_UPDATE === 'true';
    
    try {
        const latestVersion = await getLatestBedrockVersion();
        if (!latestVersion) {
            throw new Error('Could not determine latest version');
        }

        const currentVersion = await getCurrentVersion(instanceId);
        
        if (!currentVersion || currentVersion !== latestVersion) {
            console.log(`Version update available: ${currentVersion} -> ${latestVersion}`);
            
            // Send notification
            if (process.env.SNS_TOPIC_ARN) {
                await sns.publish({
                    TopicArn: process.env.SNS_TOPIC_ARN,
                    Subject: 'Minecraft Server Update Available',
                    Message: `New version available: ${latestVersion}\nCurrent version: ${currentVersion || 'unknown'}\n${autoUpdate ? 'Update will be applied automatically.' : 'Manual update required.'}`
                }).promise();
            }

            // Apply update if auto-update is enabled
            if (autoUpdate) {
                await updateServer(instanceId, latestVersion);
            }
        }

        return {
            statusCode: 200,
            body: JSON.stringify({
                currentVersion,
                latestVersion,
                updateAvailable: currentVersion !== latestVersion,
                autoUpdateEnabled: autoUpdate
            })
        };
    } catch (error) {
        console.error('Error:', error);
        return {
            statusCode: 500,
            body: JSON.stringify({
                error: error.message
            })
        };
    }
};
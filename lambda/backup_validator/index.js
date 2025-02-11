const AWS = require('aws-sdk');
const s3 = new AWS.S3();
const cloudwatch = new AWS.CloudWatch();
const sns = new AWS.SNS();

exports.handler = async (event) => {
    const BUCKET = process.env.BACKUP_BUCKET;
    const ALERT_TOPIC = process.env.ALERT_TOPIC;
    
    try {
        // List backups from last 24 hours
        const backups = await s3.listObjectsV2({
            Bucket: BUCKET,
            Prefix: 'backups/',
        }).promise();
        
        // Validate latest backup
        if (backups.Contents.length > 0) {
            const latestBackup = backups.Contents.sort((a, b) => b.LastModified - a.LastModified)[0];
            
            const validation = await validateBackup(latestBackup);
            
            // Put metrics
            await cloudwatch.putMetricData({
                Namespace: 'MinecraftServer/Backups',
                MetricData: [{
                    MetricName: 'BackupAge',
                    Value: validation.age,
                    Unit: 'Milliseconds'
                }, {
                    MetricName: 'BackupSize',
                    Value: validation.size,
                    Unit: 'Bytes'
                }]
            }).promise();
            
            // Alert if backup is too old or too small
            if (validation.age > 86400000 || !validation.isValid) {
                await sns.publish({
                    TopicArn: ALERT_TOPIC,
                    Subject: 'Minecraft Backup Alert',
                    Message: 'No recent backups found in last 24 hours or backup is too small'
                }).promise();
            }
        }
        
        return { statusCode: 200, body: 'Backup validation complete' };
    } catch (error) {
        console.error('Error:', error);
        throw error;
    }
};

async function validateBackup(backup) {
    let retries = 3;
    while (retries > 0) {
        try {
            const head = await s3.headObject({
                Bucket: BUCKET,
                Key: backup.Key
            }).promise();
            
            // Verify encryption
            const isEncrypted = head.ServerSideEncryption === 'AES256' || head.ServerSideEncryption === 'aws:kms';
            
            // Check if differential backup
            const isDifferential = backup.Key.includes('differential');
            const baseSize = isDifferential ? await getBaseBackupSize(backup.Key) : 0;
            const sizeChange = isDifferential ? (head.ContentLength / baseSize) : 1;
            
            // Put differential metrics
            if (isDifferential) {
                await cloudwatch.putMetricData({
                    Namespace: 'MinecraftServer/Backups',
                    MetricData: [{
                        MetricName: 'DifferentialRatio',
                        Value: sizeChange,
                        Unit: 'None'
                    }]
                }).promise();
            }

            return {
                isValid: head.ContentLength > 1024,
                isEncrypted,
                isDifferential,
                size: head.ContentLength,
                sizeChange,
                age: Date.now() - head.LastModified.getTime()
            };
        } catch (error) {
            retries--;
            if (retries === 0) throw error;
            await new Promise(resolve => setTimeout(resolve, 1000));
        }
    }
}

async function getBaseBackupSize(diffKey) {
    const baseKey = diffKey.replace('differential', 'base');
    const head = await s3.headObject({
        Bucket: BUCKET,
        Key: baseKey
    }).promise();
    return head.ContentLength;
}

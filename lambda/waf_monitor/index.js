const AWS = require('aws-sdk');
const wafv2 = new AWS.WAFV2();
const cloudwatch = new AWS.CloudWatch();

const RATE_INCREASE_THRESHOLD = 0.8; // 80% of current limit
const RATE_DECREASE_THRESHOLD = 0.2; // 20% of current limit
const MIN_RATE_LIMIT = 1000;
const MAX_RATE_LIMIT = 10000;

const RATE_LIMIT_RULE = 'RateBasedProtection';
const BLOCK_THRESHOLD = process.env.BLOCK_COUNT_THRESHOLD || 100;
const BLOCK_DURATION_HOURS = 24;

async function getCurrentRateLimit(webAclId, webAclName) {
    const response = await wafv2.getWebACL({
        Id: webAclId,
        Name: webAclName,
        Scope: 'REGIONAL'
    }).promise();

    const rateRule = response.WebACL.Rules.find(r => r.Name === 'RateBasedProtection');
    return rateRule.Statement.RateBasedStatement.Limit;
}

async function updateRateLimit(webAclId, webAclName, currentLimit, newLimit) {
    const response = await wafv2.getWebACL({
        Id: webAclId,
        Name: webAclName,
        Scope: 'REGIONAL'
    }).promise();

    const updatedRules = response.WebACL.Rules.map(rule => {
        if (rule.Name === 'RateBasedProtection') {
            return {
                ...rule,
                Statement: {
                    ...rule.Statement,
                    RateBasedStatement: {
                        ...rule.Statement.RateBasedStatement,
                        Limit: newLimit
                    }
                }
            };
        }
        return rule;
    });

    await wafv2.updateWebACL({
        Id: webAclId,
        Name: webAclName,
        Scope: 'REGIONAL',
        Rules: updatedRules,
        LockToken: response.LockToken,
        DefaultAction: response.WebACL.DefaultAction,
        Description: response.WebACL.Description,
        VisibilityConfig: response.WebACL.VisibilityConfig
    }).promise();

    // Log the change
    await cloudwatch.putMetricData({
        Namespace: 'MinecraftWAF',
        MetricData: [{
            MetricName: 'RateLimitAdjustment',
            Value: newLimit - currentLimit,
            Unit: 'Count',
            Dimensions: [{
                Name: 'WebACL',
                Value: webAclName
            }]
        }]
    }).promise();
}

async function getBlockedIPs(webAclId, region) {
    const params = {
        Scope: process.env.IP_SET_SCOPE || 'REGIONAL',
        Id: process.env.IP_SET_ID,
        Name: process.env.IP_SET_NAME
    };

    try {
        const response = await wafv2.getIPSet(params).promise();
        return response.IPSet.Addresses;
    } catch (error) {
        console.error('Error getting IP set:', error);
        throw error;
    }
}

async function updateBlockedIPs(newIPs) {
    const params = {
        Id: process.env.IP_SET_ID,
        Name: process.env.IP_SET_NAME,
        Scope: process.env.IP_SET_SCOPE || 'REGIONAL',
        Addresses: newIPs,
        LockToken: (await wafv2.getIPSet({
            Id: process.env.IP_SET_ID,
            Name: process.env.IP_SET_NAME,
            Scope: process.env.IP_SET_SCOPE || 'REGIONAL'
        }).promise()).LockToken
    };

    try {
        await wafv2.updateIPSet(params).promise();
        console.log('IP set updated successfully');
    } catch (error) {
        console.error('Error updating IP set:', error);
        throw error;
    }
}

async function getBlockCounts(webAclId, region) {
    const now = new Date();
    const hourAgo = new Date(now - 3600000);

    const params = {
        MetricDataQueries: [{
            Id: 'blocks',
            MetricStat: {
                Metric: {
                    MetricName: 'BlockedRequests',
                    Namespace: 'AWS/WAFV2',
                    Dimensions: [
                        { Name: 'WebACL', Value: webAclId },
                        { Name: 'Rule', Value: RATE_LIMIT_RULE }
                    ]
                },
                Period: 300,
                Stat: 'Sum'
            }
        }],
        StartTime: hourAgo,
        EndTime: now
    };

    try {
        const data = await cloudwatch.getMetricData(params).promise();
        return data.MetricDataResults[0].Values.reduce((a, b) => a + b, 0);
    } catch (error) {
        console.error('Error getting block counts:', error);
        throw error;
    }
}

async function publishMetrics(metrics) {
    const params = {
        MetricData: [
            {
                MetricName: 'BlockedIPCount',
                Value: metrics.blockedIPs,
                Unit: 'Count',
                Timestamp: new Date()
            },
            {
                MetricName: 'BlockedRequestsRate',
                Value: metrics.blockRate,
                Unit: 'Count/Second',
                Timestamp: new Date()
            }
        ],
        Namespace: 'MinecraftServer/WAF'
    };

    try {
        await cloudwatch.putMetricData(params).promise();
    } catch (error) {
        console.error('Error publishing metrics:', error);
    }
}

exports.handler = async (event) => {
    const { WEB_ACL_ID, WEB_ACL_NAME } = process.env;
    const region = process.env.AWS_REGION;

    try {
        const currentLimit = await getCurrentRateLimit(WEB_ACL_ID, WEB_ACL_NAME);
        
        // Get metrics for the last hour
        const metrics = await cloudwatch.getMetricData({
            MetricDataQueries: [{
                Id: 'm1',
                MetricStat: {
                    Metric: {
                        Namespace: 'AWS/WAFV2',
                        MetricName: 'BlockedRequests',
                        Dimensions: [{
                            Name: 'WebACL',
                            Value: WEB_ACL_NAME
                        }]
                    },
                    Period: 3600,
                    Stat: 'Sum'
                }
            }],
            StartTime: new Date(Date.now() - 3600000),
            EndTime: new Date()
        }).promise();

        const blockedRequests = metrics.MetricDataResults[0].Values[0] || 0;
        const blockRate = blockedRequests / currentLimit;

        let newLimit = currentLimit;
        if (blockRate > RATE_INCREASE_THRESHOLD && currentLimit < MAX_RATE_LIMIT) {
            newLimit = Math.min(currentLimit * 1.5, MAX_RATE_LIMIT);
        } else if (blockRate < RATE_DECREASE_THRESHOLD && currentLimit > MIN_RATE_LIMIT) {
            newLimit = Math.max(currentLimit * 0.8, MIN_RATE_LIMIT);
        }

        if (newLimit !== currentLimit) {
            await updateRateLimit(WEB_ACL_ID, WEB_ACL_NAME, currentLimit, newLimit);
            console.log(`Rate limit adjusted from ${currentLimit} to ${newLimit}`);
        }

        // Get current blocked IPs
        const currentBlockedIPs = await getBlockedIPs(WEB_ACL_ID, region);
        
        // Get block counts from the last hour
        const blockCount = await getBlockCounts(WEB_ACL_ID, region);
        
        // If block count exceeds threshold, update IP set
        if (blockCount > BLOCK_THRESHOLD) {
            // Get sampled requests to identify IPs to block
            const sampledRequests = await wafv2.getSampledRequests({
                WebAclName: WEB_ACL_NAME,
                RuleMetricName: RATE_LIMIT_RULE,
                Scope: 'REGIONAL',
                TimeWindow: {
                    StartTime: new Date(Date.now() - 3600000),
                    EndTime: new Date()
                },
                MaxItems: 500
            }).promise();

            // Extract IPs that exceeded rate limit
            const ipsToBlock = sampledRequests.SampledRequests
                .filter(req => req.Action === 'BLOCK')
                .map(req => req.ClientIP + '/32');

            // Update IP set with new blocks
            const newBlockedIPs = [...new Set([...currentBlockedIPs, ...ipsToBlock])];
            await updateBlockedIPs(newBlockedIPs);

            // Publish metrics
            await publishMetrics({
                blockedIPs: newBlockedIPs.length,
                blockRate: blockCount / 3600
            });
        }

        return {
            statusCode: 200,
            body: JSON.stringify({
                previousLimit: currentLimit,
                newLimit: newLimit,
                blockRate: blockRate,
                message: 'WAF monitoring completed successfully',
                metrics: {
                    blockCount,
                    blockedIPs: currentBlockedIPs.length
                }
            })
        };
    } catch (error) {
        console.error('Error:', error);
        return {
            statusCode: 500,
            body: JSON.stringify({
                message: 'Error in WAF monitoring',
                error: error.message
            })
        };
    }
};
# Minecraft Bedrock Server Cost & Performance Notes

## Infrastructure Decisions

### Instance Selection (t3a.small)
- CPU: 2 vCPUs (burstable)
- Memory: 2GB RAM
- Cost: ~$15/month (on-demand)
- Rationale: Bedrock server is more efficient than Java; testing shows stable performance for 3-5 players
- CPU Credit Monitoring enabled to ensure burst capacity

### Storage Configuration
- Root Volume: 30GB gp3
  - Cost: ~$2.40/month
  - IOPS: 3000 (baseline)
  - Throughput: 125 MB/s
- Backup Strategy:
  - S3 Standard -> S3-IA (30 days) -> Glacier (90 days) -> Delete (365 days)
  - Estimated backup cost: ~$1/month

### Network Optimization
- UDP Protocol (Bedrock specific)
- CloudWatch Network monitoring
- WAF rate limiting configured for cost-effective DDoS protection

### Cost Saving Measures
1. Auto-shutdown features:
   - Inactive period detection (30 mins)
   - Scheduled shutdown outside peak hours
   - Estimated 60% cost reduction during off-hours

2. Storage Optimization:
   - Reduced backup frequency (30 mins)
   - Tiered storage strategy
   - Automated cleanup of old backups

3. Monitoring Optimization:
   - Reduced CloudWatch metric frequency (1 min)
   - Custom metrics limited to essential data
   - Log retention set to 30 days

## Performance Optimizations

### Memory Allocation
- Initial: 1GB
- Maximum: 1.5GB
- Swap: Disabled for better performance
- Based on Bedrock server requirements for 3-5 players

### Network Settings
- UDP Port: 19132
- MTU: 1500
- TCP BBR enabled for better network performance

### Monitoring Thresholds
- CPU Credits: Alert at 20% remaining
- Memory: Alert at 85% usage
- Network: Alert at 5MB/s sustained

## Monthly Cost Breakdown (US-EAST-1)
1. EC2 (t3a.small): $15.00
2. EBS (gp3): $2.40
3. S3 Storage: ~$1.00
4. Data Transfer: ~$2.00
5. CloudWatch: Free tier eligible
6. WAF: Free tier eligible
Total: ~$20.40/month

## Potential Future Optimizations
1. Spot Instance Integration
   - Potential savings: 60-70%
   - Requires automated state management
   - Best for non-critical gameplay

2. Reserved Instance Consideration
   - 1-year commitment
   - Potential savings: ~40%
   - Break-even point: 6 months

3. Graviton Instance Migration
   - t4g.small offers better price/performance
   - Requires ARM64 compatibility testing
   - Potential savings: ~20%

## Operation Notes
1. CPU Credit Balance monitoring critical for t3a.small
2. Network baseline: 50-100KB/s per player
3. Disk I/O peaks during world saves
4. Memory usage stable after initial world load

## Monitoring Focus Areas
1. Player count vs. resource utilization
2. Network latency per region
3. Backup success rate
4. Auto-shutdown effectiveness

## Additional Recommendations

### Immediate Optimizations
1. Instance CPU Credits
   - Monitor credit balance through first week of operation
   - If consistently low, consider switching to t3a.medium only during peak hours
   - Use Lambda to handle automatic scaling based on credit balance

2. Network Optimization
   - Monitor UDP packet loss rates for Bedrock protocol
   - Consider enabling flow logs during initial deployment
   - Set up latency alerts per region

3. Backup Strategy Enhancement
   - Implement differential backups to reduce S3 costs
   - Add backup validation checks
   - Consider cross-region backup for critical worlds

### Long-term Considerations
1. Regional Deployment
   - Monitor player locations
   - Consider multi-region deployment if latency becomes an issue
   - Use Route 53 for intelligent routing

2. Cost Optimization
   - Evaluate Spot Instance viability after 1 month
   - Consider Reserved Instance if usage pattern is stable
   - Monitor S3 lifecycle transitions

3. Performance Monitoring
   - Create baseline performance metrics
   - Track player count vs. resource utilization
   - Setup automated performance reports

### Best Practices
1. Regular Maintenance
   - Weekly world optimization
   - Monthly performance review
   - Quarterly cost analysis

2. Security
   - Regular security group audit
   - WAF rule effectiveness review
   - IP allowlist maintenance

3. Backup Testing
   - Monthly restore testing
   - Validate backup integrity
   - Test cross-region recovery

## Migration Path
If the server grows beyond 5 players:
1. Transition plan to t3a.medium
2. Scale storage IOPS
3. Adjust memory allocation
4. Update monitoring thresholds
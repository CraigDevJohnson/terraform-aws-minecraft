#!/bin/bash

# Status Page Testing
echo "Testing Status Page Infrastructure..."

# Test WAF Rate Limiting
echo "Testing WAF rate limiting..."
for i in {1..2500}; do
    curl -s -o /dev/null -w "%{http_code}" https://${STATUS_PAGE_URL} &
done

# Test Error Handling
echo "Testing error handling..."
aws lambda invoke \
    --function-name ${STATUS_UPDATER_FUNCTION} \
    --payload '{"forceError": true}' \
    /dev/null

# Check DLQ
echo "Checking DLQ for error messages..."
aws sqs get-queue-attributes \
    --queue-url ${STATUS_DLQ_URL} \
    --attribute-names ApproximateNumberOfMessages

# Test Recovery
echo "Testing automatic recovery..."
aws lambda invoke \
    --function-name ${STATUS_UPDATER_FUNCTION} \
    --payload '{"forceRecovery": true}' \
    /dev/null

# Cleanup
echo "Cleaning up test resources..."
aws sqs purge-queue --queue-url ${STATUS_DLQ_URL}

echo "Status page tests completed."
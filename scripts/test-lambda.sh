#!/bin/bash
set -e

echo "Setting up Lambda test environment..."

# Create test event data
cat > events/activity-prediction-test.json << EOF
{
  "instanceId": "i-test123",
  "detail-type": "Scheduled Event",
  "time": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF

# Test activity predictor
cd lambda/activity_predictor
npm install --production
node -e "
const handler = require('./index.js').handler;
const event = require('../../events/activity-prediction-test.json');
handler(event).then(console.log).catch(console.error);
"
cd ../..

# Test backup validator
cd lambda/backup_validator
npm install --production
AWS_REGION=us-west-2 BACKUP_BUCKET=test-bucket node -e "
const handler = require('./index.js').handler;
handler({}).then(console.log).catch(console.error);
"
cd ../..

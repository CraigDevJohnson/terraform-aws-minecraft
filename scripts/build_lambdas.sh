#!/bin/bash
set -e

# Configuration
LAMBDA_DIR="lambda"
BUILD_DIR="build"
NODE_VERSION="18"

# Create build directory
mkdir -p $BUILD_DIR

# Function to build TypeScript Lambda
build_typescript_lambda() {
    local lambda_name=$1
    echo "Building TypeScript Lambda: $lambda_name"
    
    cd "$LAMBDA_DIR/$lambda_name"
    
    # Install dependencies
    npm install
    
    # Run tests if they exist
    if [ -f "*.test.ts" ]; then
        npm test
    fi
    
    # Build TypeScript
    npm run build
    
    # Package Lambda
    cd dist
    zip -r "../../../$BUILD_DIR/$lambda_name.zip" .
    cd ../../..
}

# Function to build JavaScript Lambda
build_javascript_lambda() {
    local lambda_name=$1
    echo "Building JavaScript Lambda: $lambda_name"
    
    cd "$LAMBDA_DIR/$lambda_name"
    
    # Install dependencies
    npm install
    
    # Run tests if they exist
    if [ -f "*.test.js" ]; then
        npm test
    fi
    
    # Package Lambda
    zip -r "../../$BUILD_DIR/$lambda_name.zip" ./* -x "*.test.js"
    cd ../..
}

# Build each Lambda function
for lambda in "$LAMBDA_DIR"/*; do
    if [ -d "$lambda" ]; then
        lambda_name=$(basename "$lambda")
        
        # Check if TypeScript configuration exists
        if [ -f "$lambda/tsconfig.json" ]; then
            build_typescript_lambda "$lambda_name"
        else
            build_javascript_lambda "$lambda_name"
        fi
    fi
done

echo "Lambda builds completed successfully"
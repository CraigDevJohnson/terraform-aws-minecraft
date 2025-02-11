#!/bin/bash

# Configuration
MC_ROOT="${mc_root:-/home/minecraft}"
BACKUP_ROOT="${MC_ROOT}/backups"
LAST_BACKUP_FILE="${BACKUP_ROOT}/last_backup.txt"
TEMP_DIR="/tmp/minecraft_backup"
AWS="aws --region $(curl -s http://169.254.169.254/latest/meta-data/placement/region)"

# Create backup directories if they don't exist
mkdir -p "${BACKUP_ROOT}"
mkdir -p "${TEMP_DIR}"

# Function to calculate file hashes
generate_hash_list() {
    local dir=$1
    local output=$2
    find "$dir" -type f -exec sha256sum {} \; | sort > "$output"
}

# Get the current timestamp
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Generate current file hashes
generate_hash_list "${MC_ROOT}/world" "${TEMP_DIR}/current_hashes.txt"

# If last backup exists, compare with it
if [ -f "${LAST_BACKUP_FILE}" ]; then
    # Get last backup manifest
    $AWS s3 cp "$(cat ${LAST_BACKUP_FILE})/manifest.txt" "${TEMP_DIR}/last_hashes.txt"
    
    # Find changed files
    diff "${TEMP_DIR}/last_hashes.txt" "${TEMP_DIR}/current_hashes.txt" | grep "^>" | cut -d" " -f3 > "${TEMP_DIR}/changed_files.txt"
    
    # Create differential backup
    if [ -s "${TEMP_DIR}/changed_files.txt" ]; then
        BACKUP_PATH="s3://${mc_bucket}/backups/diff_${TIMESTAMP}"
        
        # Copy only changed files
        while IFS= read -r file; do
            rel_path=$(realpath --relative-to="${MC_ROOT}/world" "$file")
            $AWS s3 cp "${MC_ROOT}/world/$rel_path" "${BACKUP_PATH}/world/$rel_path"
        done < "${TEMP_DIR}/changed_files.txt"
        
        # Store manifest for this backup
        cp "${TEMP_DIR}/current_hashes.txt" "${TEMP_DIR}/manifest.txt"
        $AWS s3 cp "${TEMP_DIR}/manifest.txt" "${BACKUP_PATH}/manifest.txt"
        
        # Update last backup pointer
        echo "${BACKUP_PATH}" > "${LAST_BACKUP_FILE}"
    fi
else
    # First time backup - do a full backup
    BACKUP_PATH="s3://${mc_bucket}/backups/full_${TIMESTAMP}"
    $AWS s3 sync "${MC_ROOT}/world" "${BACKUP_PATH}/world"
    
    # Store manifest for this backup
    cp "${TEMP_DIR}/current_hashes.txt" "${TEMP_DIR}/manifest.txt"
    $AWS s3 cp "${TEMP_DIR}/manifest.txt" "${BACKUP_PATH}/manifest.txt"
    
    # Create last backup pointer
    echo "${BACKUP_PATH}" > "${LAST_BACKUP_FILE}"
fi

# Cleanup
rm -rf "${TEMP_DIR}"/*

# Update backup metrics
$AWS cloudwatch put-metric-data \
    --namespace "MinecraftServer" \
    --metric-name "BackupSize" \
    --value $(du -s "${MC_ROOT}/world" | cut -f1) \
    --unit "Kilobytes" \
    --dimensions "Type=Differential"
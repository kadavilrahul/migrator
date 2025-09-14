#!/bin/bash
# WordPress Migration Configuration - SAMPLE
# Copy this file to config.sh and update with your actual values

# WordPress Path
WP_PATH="/var/www/your-site"

# Local Database (Target)
LOCAL_HOST="localhost"
LOCAL_DB="your_local_db"
LOCAL_USER="your_local_user"
LOCAL_PASS="your_local_password"
LOCAL_PREFIX="wp_"

# Remote Database (Source)
REMOTE_HOST="remote.server.com"
REMOTE_DB="your_remote_db"
REMOTE_USER="your_remote_user"
REMOTE_PASS="your_remote_password"
REMOTE_PREFIX="wp_"

# Migration Options
ENABLE_HPOS="true"              # Enable High Performance Order Storage
AUTO_BACKUP="true"               # Automatically backup before migration
COMPRESS_BACKUPS="true"          # Compress backup files with gzip
BATCH_SIZE="100"                 # Number of records to process at once
KEEP_BACKUPS_DAYS="30"           # Days to keep old backups
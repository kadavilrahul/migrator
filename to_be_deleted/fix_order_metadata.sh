#!/bin/bash

# Fix Order Metadata Migration
# This script fixes the metadata that failed to migrate properly

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$SCRIPT_DIR/../logs/fix_metadata_$(date +%Y%m%d_%H%M%S).log"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Load config
REMOTE_HOST="37.27.192.145"
REMOTE_DB="nilgiristores_in_db"
REMOTE_USER="nilgiristores_in_user"
REMOTE_PASS="nilgiristores_in_2@"
REMOTE_PREFIX="kdf_"

LOCAL_DB=$(grep "DB_NAME" /var/www/nilgiristores.in/wp-config.php | cut -d "'" -f 4)
LOCAL_USER=$(grep "DB_USER" /var/www/nilgiristores.in/wp-config.php | cut -d "'" -f 4)
LOCAL_PASS=$(grep "DB_PASSWORD" /var/www/nilgiristores.in/wp-config.php | cut -d "'" -f 4)
LOCAL_HOST="localhost"

echo "Order Metadata Fix Script"
echo "========================="

log "Starting metadata migration fix..."

# Create temp file for batch processing
TEMP_FILE="/tmp/metadata_fix_$(date +%s).sql"

log "Extracting metadata from remote database..."
export MYSQL_PWD="$REMOTE_PASS"

# Generate INSERT statements for metadata in batches
mysql -h "$REMOTE_HOST" -u "$REMOTE_USER" "$REMOTE_DB" -e "
SELECT CONCAT(
    'INSERT IGNORE INTO wp_postmeta (post_id, meta_key, meta_value) VALUES (',
    pm.post_id, ',',
    QUOTE(pm.meta_key), ',',
    QUOTE(pm.meta_value),
    ');'
)
FROM ${REMOTE_PREFIX}postmeta pm
INNER JOIN ${REMOTE_PREFIX}posts p ON pm.post_id = p.ID
WHERE p.post_type = 'shop_order'
ORDER BY pm.post_id, pm.meta_key;
" > "$TEMP_FILE"

unset MYSQL_PWD

# Count how many statements we have
STATEMENT_COUNT=$(wc -l < "$TEMP_FILE")
log "Generated $STATEMENT_COUNT metadata insert statements"

if [ "$STATEMENT_COUNT" -eq 0 ]; then
    log "ERROR: No metadata statements generated"
    exit 1
fi

log "Importing metadata to local database..."
export MYSQL_PWD="$LOCAL_PASS"

# Import metadata in smaller batches to avoid issues
split -l 1000 "$TEMP_FILE" /tmp/meta_batch_

for batch_file in /tmp/meta_batch_*; do
    if [ -f "$batch_file" ]; then
        mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" "$LOCAL_DB" < "$batch_file"
        rm "$batch_file"
    fi
done

unset MYSQL_PWD

# Clean up temp file
rm -f "$TEMP_FILE"

# Verify metadata migration
export MYSQL_PWD="$LOCAL_PASS"
META_COUNT=$(mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" "$LOCAL_DB" -se "SELECT COUNT(*) FROM wp_postmeta pm INNER JOIN wp_posts p ON pm.post_id = p.ID WHERE p.post_type = 'shop_order';" 2>/dev/null)
unset MYSQL_PWD

log "Metadata migration completed - $META_COUNT records imported"

# Re-sync HPOS to pick up the new metadata
log "Re-syncing HPOS to include metadata..."
cd /var/www/nilgiristores.in
wp --allow-root wc hpos disable >/dev/null 2>&1 || true
sleep 2
wp --allow-root wc hpos sync --batch-size=200 2>/dev/null
wp --allow-root wc hpos enable >/dev/null 2>&1

log "Checking final result..."
export MYSQL_PWD="$LOCAL_PASS"
mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" "$LOCAL_DB" -e "SELECT id, status, total_amount, customer_id FROM wp_wc_orders LIMIT 5;"
unset MYSQL_PWD

log "Metadata fix completed successfully!"
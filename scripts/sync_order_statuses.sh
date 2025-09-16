#!/bin/bash

###################################################################################
# QUICK ORDER STATUS SYNC 
###################################################################################

set -e

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/../config/config.sh"
source "$CONFIG_FILE"

echo "=== QUICK ORDER STATUS SYNC ==="
echo "Starting at: $(date)"

# Step 1: Export remote order statuses
echo "Fetching remote order statuses..."
mysql -h "$REMOTE_HOST" -u "$REMOTE_USER" -p"$REMOTE_PASS" "$REMOTE_DB" -e "SELECT ID, post_status FROM ${REMOTE_PREFIX}posts WHERE post_type='shop_order' AND post_status IN ('wc-delivered', 'wc-failed', 'wc-pre-order-booked')" 2>/dev/null > /tmp/remote_statuses.txt

if [ ! -s /tmp/remote_statuses.txt ]; then
    echo "❌ Error: Could not fetch remote statuses or file is empty"
    exit 1
fi

REMOTE_COUNT=$(wc -l < /tmp/remote_statuses.txt)
echo "Found $((REMOTE_COUNT - 1)) orders with custom statuses in remote database"

# Step 2: Generate SQL update statements
echo "Generating update statements..."
awk -F'\t' '
/wc-delivered/ {print "UPDATE " prefix "posts SET post_status=\"wc-delivered\", post_modified=NOW(), post_modified_gmt=UTC_TIMESTAMP() WHERE ID=" $1 " AND post_type=\"shop_order\"; UPDATE " prefix "wc_orders SET status=\"delivered\", date_updated_gmt=UTC_TIMESTAMP() WHERE id=" $1 ";"}
/wc-failed/ {print "UPDATE " prefix "posts SET post_status=\"wc-failed\", post_modified=NOW(), post_modified_gmt=UTC_TIMESTAMP() WHERE ID=" $1 " AND post_type=\"shop_order\"; UPDATE " prefix "wc_orders SET status=\"failed\", date_updated_gmt=UTC_TIMESTAMP() WHERE id=" $1 ";"}
/wc-pre-order-booked/ {print "UPDATE " prefix "posts SET post_status=\"wc-pre-order-booked\", post_modified=NOW(), post_modified_gmt=UTC_TIMESTAMP() WHERE ID=" $1 " AND post_type=\"shop_order\"; UPDATE " prefix "wc_orders SET status=\"pre-order-booked\", date_updated_gmt=UTC_TIMESTAMP() WHERE id=" $1 ";"} 
' prefix="${LOCAL_PREFIX}" /tmp/remote_statuses.txt > /tmp/status_updates.sql

UPDATE_COUNT=$(wc -l < /tmp/status_updates.sql)
echo "Generated $UPDATE_COUNT update statements"

# Step 3: Execute updates
echo "Executing status updates..."
mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" -p"$LOCAL_PASS" "$LOCAL_DB" < /tmp/status_updates.sql 2>/dev/null

# Step 4: Show results and clear caches
mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" -p"$LOCAL_PASS" "$LOCAL_DB" -e "
SELECT 'Final Status Distribution' as '';
SELECT post_status, COUNT(*) as count 
FROM ${LOCAL_PREFIX}posts 
WHERE post_type='shop_order' 
GROUP BY post_status 
ORDER BY count DESC;

DELETE FROM ${LOCAL_PREFIX}options WHERE option_name LIKE '%_transient_%';
" 2>/dev/null

echo ""
echo "✅ QUICK STATUS SYNC COMPLETED"
echo "Finished at: $(date)"
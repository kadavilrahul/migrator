#!/bin/bash

###################################################################################
# ORDER STATUS SYNC - PRESERVE ORIGINAL STATUSES
###################################################################################
# Syncs order statuses from remote WITHOUT converting custom statuses
# Preserves: wc-delivered, wc-failed, wc-pre-order-booked as-is
# For use when custom statuses are registered via plugin/code snippet
###################################################################################

set -e

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/../config/config.sh"
source "$CONFIG_FILE"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}=== ORDER STATUS SYNC (PRESERVE ORIGINAL) ===${NC}"
echo "Starting at: $(date)"
echo ""

# Step 1: Export remote order statuses
echo -e "${YELLOW}Step 1: Fetching remote order statuses...${NC}"
mysql -h "$REMOTE_HOST" -u "$REMOTE_USER" -p"$REMOTE_PASS" "$REMOTE_DB" -e "
SELECT ID, post_status 
FROM ${REMOTE_PREFIX}posts 
WHERE post_type='shop_order'" 2>/dev/null > /tmp/remote_statuses.txt

if [ ! -s /tmp/remote_statuses.txt ]; then
    echo -e "${RED}❌ Error: Could not fetch remote statuses${NC}"
    exit 1
fi

REMOTE_COUNT=$(wc -l < /tmp/remote_statuses.txt)
echo "Found $((REMOTE_COUNT - 1)) total orders in remote database"

# Count different status types
DELIVERED_COUNT=$(grep -c 'wc-delivered' /tmp/remote_statuses.txt || true)
FAILED_COUNT=$(grep -c 'wc-failed' /tmp/remote_statuses.txt || true)
PREORDER_COUNT=$(grep -c 'wc-pre-order-booked' /tmp/remote_statuses.txt || true)
COMPLETED_COUNT=$(grep -c 'wc-completed' /tmp/remote_statuses.txt || true)
CANCELLED_COUNT=$(grep -c 'wc-cancelled' /tmp/remote_statuses.txt || true)
REFUNDED_COUNT=$(grep -c 'wc-refunded' /tmp/remote_statuses.txt || true)

echo ""
echo "Status breakdown:"
echo "  wc-delivered: $DELIVERED_COUNT"
echo "  wc-failed: $FAILED_COUNT"
echo "  wc-pre-order-booked: $PREORDER_COUNT"
echo "  wc-completed: $COMPLETED_COUNT"
echo "  wc-cancelled: $CANCELLED_COUNT"
echo "  wc-refunded: $REFUNDED_COUNT"
echo ""

# Step 2: Generate SQL update statements WITHOUT conversion
echo -e "${YELLOW}Step 2: Generating update statements (preserving original statuses)...${NC}"

# Generate updates preserving original statuses
awk -F'\t' '
NR > 1 {
    status = $2
    # Keep original status - no conversion
    
    # Generate update for posts table
    print "UPDATE " prefix "posts SET post_status=\"" status "\", post_modified=NOW(), post_modified_gmt=UTC_TIMESTAMP() WHERE ID=" $1 " AND post_type=\"shop_order\";"
    
    # Also update HPOS table if it exists (remove wc- prefix for HPOS)
    hpos_status = status
    if (substr(status, 1, 3) == "wc-") {
        hpos_status = substr(status, 4)
    }
    print "UPDATE " prefix "wc_orders SET status=\"" hpos_status "\", date_updated_gmt=UTC_TIMESTAMP() WHERE id=" $1 ";"
}
' prefix="${LOCAL_PREFIX}" /tmp/remote_statuses.txt > /tmp/status_updates.sql

UPDATE_COUNT=$(wc -l < /tmp/status_updates.sql)
echo "Generated $((UPDATE_COUNT / 2)) order update statements"
echo ""

# Step 3: Ask for confirmation
echo -e "${YELLOW}⚠️  WARNING: This will sync ALL order statuses from remote, including custom statuses.${NC}"
echo -e "${YELLOW}Make sure you have registered these custom statuses in your code snippets plugin:${NC}"
echo "  - wc-delivered"
echo "  - wc-failed"
echo "  - wc-pre-order-booked"
echo ""
read -p "Do you want to continue? (y/N): " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}Sync cancelled.${NC}"
    rm -f /tmp/remote_statuses.txt /tmp/status_updates.sql
    exit 0
fi

# Step 4: Execute updates
echo ""
echo -e "${YELLOW}Step 3: Executing status updates...${NC}"
mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" -p"$LOCAL_PASS" "$LOCAL_DB" < /tmp/status_updates.sql 2>/dev/null
echo -e "${GREEN}✓ Status updates completed${NC}"
echo ""

# Step 5: Show results
echo -e "${YELLOW}Step 4: Final status distribution:${NC}"
mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" -p"$LOCAL_PASS" "$LOCAL_DB" -e "
SELECT post_status, COUNT(*) as count 
FROM ${LOCAL_PREFIX}posts 
WHERE post_type='shop_order' 
GROUP BY post_status 
ORDER BY count DESC;" 2>/dev/null

# Step 6: Clear caches
echo ""
echo -e "${YELLOW}Step 5: Clearing caches...${NC}"
mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" -p"$LOCAL_PASS" "$LOCAL_DB" -e "
DELETE FROM ${LOCAL_PREFIX}options WHERE option_name LIKE '%_transient_%';" 2>/dev/null
echo -e "${GREEN}✓ Caches cleared${NC}"

# Cleanup
rm -f /tmp/remote_statuses.txt /tmp/status_updates.sql

# Final message
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}✅ STATUS SYNC COMPLETED${NC}"
echo -e "${GREEN}========================================${NC}"
echo "Original custom statuses have been preserved:"
echo "  - wc-delivered (Delivered)"
echo "  - wc-failed (Failed)"
echo "  - wc-pre-order-booked (Pre-order Booked)"
echo ""
echo -e "${YELLOW}Note: Make sure these custom statuses are registered in your${NC}"
echo -e "${YELLOW}      Code Snippets plugin for them to appear in WooCommerce.${NC}"
echo ""
echo "Finished at: $(date)"
#!/bin/bash

###################################################################################
# ORDER STATUS SYNC WITH AUTOMATIC CONVERSION
###################################################################################
# Syncs order statuses from remote but converts custom statuses to standard ones:
# - wc-delivered → wc-completed
# - wc-failed → wc-cancelled  
# - wc-pre-order-booked → wc-on-hold
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

echo -e "${BLUE}=== ORDER STATUS SYNC WITH CONVERSION ===${NC}"
echo "Starting at: $(date)"
echo ""

# Step 1: Export remote order statuses
echo -e "${YELLOW}Step 1: Fetching remote order statuses...${NC}"
mysql -h "$REMOTE_HOST" -u "$REMOTE_USER" -p"$REMOTE_PASS" "$REMOTE_DB" -e "
SELECT ID, post_status 
FROM ${REMOTE_PREFIX}posts 
WHERE post_type='shop_order'" 2>/dev/null > /tmp/remote_statuses.txt

if [ ! -s /tmp/remote_statuses.txt ]; then
    echo -e "${RED}❌ Error: Could not fetch remote statuses or file is empty${NC}"
    exit 1
fi

REMOTE_COUNT=$(wc -l < /tmp/remote_statuses.txt)
echo "Found $((REMOTE_COUNT - 1)) total orders in remote database"

# Count custom statuses
CUSTOM_COUNT=$(grep -E 'wc-delivered|wc-failed|wc-pre-order-booked' /tmp/remote_statuses.txt | wc -l || true)
echo "Found $CUSTOM_COUNT orders with custom statuses that will be converted"
echo ""

# Step 2: Generate SQL update statements with conversion
echo -e "${YELLOW}Step 2: Generating update statements with status conversion...${NC}"
echo "Conversion mapping:"
echo "  wc-delivered → wc-completed"
echo "  wc-failed → wc-cancelled"
echo "  wc-pre-order-booked → wc-on-hold"
echo ""

# Generate updates with conversion
awk -F'\t' '
NR > 1 {
    status = $2
    # Convert custom statuses to standard ones
    if (status == "wc-delivered") status = "wc-completed"
    else if (status == "wc-failed") status = "wc-cancelled"
    else if (status == "wc-pre-order-booked") status = "wc-on-hold"
    
    # Generate update for posts table
    print "UPDATE " prefix "posts SET post_status=\"" status "\", post_modified=NOW(), post_modified_gmt=UTC_TIMESTAMP() WHERE ID=" $1 " AND post_type=\"shop_order\";"
    
    # Also update HPOS table if it exists (remove wc- prefix for HPOS)
    hpos_status = substr(status, 4)
    print "UPDATE " prefix "wc_orders SET status=\"" hpos_status "\", date_updated_gmt=UTC_TIMESTAMP() WHERE id=" $1 ";"
}
' prefix="${LOCAL_PREFIX}" /tmp/remote_statuses.txt > /tmp/status_updates.sql

UPDATE_COUNT=$(wc -l < /tmp/status_updates.sql)
echo "Generated $((UPDATE_COUNT / 2)) order update statements"
echo ""

# Step 3: Execute updates
echo -e "${YELLOW}Step 3: Executing status updates...${NC}"
mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" -p"$LOCAL_PASS" "$LOCAL_DB" < /tmp/status_updates.sql 2>/dev/null
echo -e "${GREEN}✓ Status updates completed${NC}"
echo ""

# Step 4: Show results
echo -e "${YELLOW}Step 4: Final status distribution:${NC}"
mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" -p"$LOCAL_PASS" "$LOCAL_DB" -e "
SELECT post_status, COUNT(*) as count 
FROM ${LOCAL_PREFIX}posts 
WHERE post_type='shop_order' 
GROUP BY post_status 
ORDER BY count DESC;" 2>/dev/null

# Step 5: Clear caches
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
echo -e "${GREEN}✅ STATUS SYNC COMPLETED SUCCESSFULLY${NC}"
echo -e "${GREEN}========================================${NC}"
echo "Custom statuses have been automatically converted to standard WooCommerce statuses"
echo "All orders should now appear in the WooCommerce dashboard"
echo ""
echo "Finished at: $(date)"
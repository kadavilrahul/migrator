#!/bin/bash

###################################################################################
# SYNC EXACT ORDER STATUSES FROM SOURCE
###################################################################################
# Purpose: Sync order statuses from remote to local, preserving exact statuses
# including custom statuses like wc-delivered, wc-failed, wc-pre-order-booked
###################################################################################

set -e

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/../config/config.sh"

if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo "Error: Configuration file not found: $CONFIG_FILE"
    exit 1
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${BLUE}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║         SYNC EXACT ORDER STATUSES FROM SOURCE                 ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${CYAN}This will sync order statuses from source to match exactly,${NC}"
echo -e "${CYAN}including custom statuses like wc-delivered, wc-failed, etc.${NC}"
echo ""

# Function to execute queries
execute_query() {
    mysql -h "$1" -u "$2" -p"$3" "$4" -e "$5" 2>/dev/null
}

# Function to get single value
get_value() {
    mysql -h "$1" -u "$2" -p"$3" "$4" -sN -e "$5" 2>/dev/null
}

# Step 1: Analyze source statuses
echo -e "${YELLOW}Step 1: Analyzing source database order statuses...${NC}"
echo ""

SOURCE_STATUSES=$(execute_query "$REMOTE_HOST" "$REMOTE_USER" "$REMOTE_PASS" "$REMOTE_DB" "
SELECT post_status, COUNT(*) as count 
FROM ${REMOTE_PREFIX}posts 
WHERE post_type = 'shop_order' 
GROUP BY post_status 
ORDER BY count DESC;")

echo "Source order statuses:"
echo "$SOURCE_STATUSES"
echo ""

# Count each status type in source
DELIVERED_COUNT=$(get_value "$REMOTE_HOST" "$REMOTE_USER" "$REMOTE_PASS" "$REMOTE_DB" \
    "SELECT COUNT(*) FROM ${REMOTE_PREFIX}posts WHERE post_type='shop_order' AND post_status='wc-delivered'")
FAILED_COUNT=$(get_value "$REMOTE_HOST" "$REMOTE_USER" "$REMOTE_PASS" "$REMOTE_DB" \
    "SELECT COUNT(*) FROM ${REMOTE_PREFIX}posts WHERE post_type='shop_order' AND post_status='wc-failed'")
PREORDER_COUNT=$(get_value "$REMOTE_HOST" "$REMOTE_USER" "$REMOTE_PASS" "$REMOTE_DB" \
    "SELECT COUNT(*) FROM ${REMOTE_PREFIX}posts WHERE post_type='shop_order' AND post_status='wc-pre-order-booked'")
COMPLETED_COUNT=$(get_value "$REMOTE_HOST" "$REMOTE_USER" "$REMOTE_PASS" "$REMOTE_DB" \
    "SELECT COUNT(*) FROM ${REMOTE_PREFIX}posts WHERE post_type='shop_order' AND post_status='wc-completed'")
CANCELLED_COUNT=$(get_value "$REMOTE_HOST" "$REMOTE_USER" "$REMOTE_PASS" "$REMOTE_DB" \
    "SELECT COUNT(*) FROM ${REMOTE_PREFIX}posts WHERE post_type='shop_order' AND post_status='wc-cancelled'")
REFUNDED_COUNT=$(get_value "$REMOTE_HOST" "$REMOTE_USER" "$REMOTE_PASS" "$REMOTE_DB" \
    "SELECT COUNT(*) FROM ${REMOTE_PREFIX}posts WHERE post_type='shop_order' AND post_status='wc-refunded'")

TOTAL_ORDERS=$(get_value "$REMOTE_HOST" "$REMOTE_USER" "$REMOTE_PASS" "$REMOTE_DB" \
    "SELECT COUNT(*) FROM ${REMOTE_PREFIX}posts WHERE post_type='shop_order'")

# Step 2: Show current local statuses
echo -e "${YELLOW}Step 2: Current local database order statuses...${NC}"
echo ""

LOCAL_STATUSES=$(execute_query "$LOCAL_HOST" "$LOCAL_USER" "$LOCAL_PASS" "$LOCAL_DB" "
SELECT post_status, COUNT(*) as count 
FROM ${LOCAL_PREFIX}posts 
WHERE post_type = 'shop_order' 
GROUP BY post_status 
ORDER BY count DESC;")

echo "Current local order statuses:"
echo "$LOCAL_STATUSES"
echo ""

# Step 3: Export order IDs and statuses from remote
echo -e "${YELLOW}Step 3: Fetching order statuses from source...${NC}"

# Create temp file for status mappings
TEMP_FILE="/tmp/order_status_sync_$$.txt"

mysql -h "$REMOTE_HOST" -u "$REMOTE_USER" -p"$REMOTE_PASS" "$REMOTE_DB" -sN -e "
SELECT ID, post_status 
FROM ${REMOTE_PREFIX}posts 
WHERE post_type = 'shop_order'
ORDER BY ID;" > "$TEMP_FILE" 2>/dev/null

ORDER_COUNT=$(wc -l < "$TEMP_FILE")
echo "Found $ORDER_COUNT orders to sync"
echo ""

# Step 4: Confirmation
echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}This will update $ORDER_COUNT orders to match source statuses:${NC}"
echo -e "  • wc-delivered: $DELIVERED_COUNT orders"
echo -e "  • wc-failed: $FAILED_COUNT orders"
echo -e "  • wc-pre-order-booked: $PREORDER_COUNT orders"
echo -e "  • wc-completed: $COMPLETED_COUNT orders"
echo -e "  • wc-cancelled: $CANCELLED_COUNT orders"
echo -e "  • wc-refunded: $REFUNDED_COUNT orders"
echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
echo ""
read -p "Do you want to continue? (y/N): " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}Operation cancelled.${NC}"
    rm -f "$TEMP_FILE"
    exit 0
fi

# Step 5: Generate and execute update statements
echo ""
echo -e "${YELLOW}Step 4: Syncing order statuses...${NC}"

# Create SQL update file
SQL_FILE="/tmp/order_status_updates_$$.sql"
echo "SET FOREIGN_KEY_CHECKS=0;" > "$SQL_FILE"
echo "START TRANSACTION;" >> "$SQL_FILE"

# Generate update statements
while IFS=$'\t' read -r order_id status; do
    echo "UPDATE ${LOCAL_PREFIX}posts SET post_status='$status', post_modified=NOW(), post_modified_gmt=UTC_TIMESTAMP() WHERE ID=$order_id AND post_type='shop_order';" >> "$SQL_FILE"
    
    # Also update HPOS table if exists
    if [ "$status" != "" ]; then
        hpos_status=$(echo "$status" | sed 's/^wc-//')
        echo "UPDATE ${LOCAL_PREFIX}wc_orders SET status='$hpos_status', date_updated_gmt=UTC_TIMESTAMP() WHERE id=$order_id;" >> "$SQL_FILE"
    fi
done < "$TEMP_FILE"

echo "COMMIT;" >> "$SQL_FILE"
echo "SET FOREIGN_KEY_CHECKS=1;" >> "$SQL_FILE"

# Execute the updates
echo "Executing status updates..."
mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" -p"$LOCAL_PASS" "$LOCAL_DB" < "$SQL_FILE" 2>/dev/null

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ Status updates executed successfully${NC}"
else
    echo -e "${RED}✗ Error executing status updates${NC}"
    rm -f "$TEMP_FILE" "$SQL_FILE"
    exit 1
fi

# Step 6: Clear caches
echo ""
echo -e "${YELLOW}Step 5: Clearing WordPress caches...${NC}"
execute_query "$LOCAL_HOST" "$LOCAL_USER" "$LOCAL_PASS" "$LOCAL_DB" "
DELETE FROM ${LOCAL_PREFIX}options WHERE option_name LIKE '_transient_%';
DELETE FROM ${LOCAL_PREFIX}options WHERE option_name LIKE '_site_transient_%';"
echo -e "${GREEN}✓ Caches cleared${NC}"

# Step 7: Show final results
echo ""
echo -e "${YELLOW}Step 6: Final status distribution in local database...${NC}"
echo ""

FINAL_STATUSES=$(execute_query "$LOCAL_HOST" "$LOCAL_USER" "$LOCAL_PASS" "$LOCAL_DB" "
SELECT post_status, COUNT(*) as count 
FROM ${LOCAL_PREFIX}posts 
WHERE post_type = 'shop_order' 
GROUP BY post_status 
ORDER BY count DESC;")

echo "Final local order statuses:"
echo "$FINAL_STATUSES"

# Cleanup
rm -f "$TEMP_FILE" "$SQL_FILE"

# Step 8: Summary
echo ""
echo -e "${GREEN}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║              STATUS SYNC COMPLETED SUCCESSFULLY               ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${CYAN}Order statuses have been synced to match source exactly.${NC}"
echo ""

# Check if custom statuses are present
CUSTOM_COUNT=$((DELIVERED_COUNT + FAILED_COUNT + PREORDER_COUNT))
if [ $CUSTOM_COUNT -gt 0 ]; then
    echo -e "${YELLOW}⚠️  Note: You have $CUSTOM_COUNT orders with custom statuses.${NC}"
    echo -e "${YELLOW}   Make sure these statuses are registered in your WordPress${NC}"
    echo -e "${YELLOW}   (via Code Snippets plugin or functions.php) for them to${NC}"
    echo -e "${YELLOW}   appear correctly in WooCommerce.${NC}"
    echo ""
    echo -e "${CYAN}Custom statuses synced:${NC}"
    echo "  • wc-delivered (Delivered): $DELIVERED_COUNT orders"
    echo "  • wc-failed (Failed): $FAILED_COUNT orders"  
    echo "  • wc-pre-order-booked (Pre-order): $PREORDER_COUNT orders"
else
    echo -e "${GREEN}All orders have standard WooCommerce statuses.${NC}"
fi

echo ""
echo "Finished at: $(date)"
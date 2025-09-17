#!/bin/bash

###################################################################################
# CONVERT CUSTOM ORDER STATUSES TO STANDARD WOOCOMMERCE STATUSES
###################################################################################
# Purpose: Convert non-standard order statuses to WooCommerce recognized statuses
# Maps: wc-delivered -> wc-completed, wc-failed -> wc-cancelled, 
#       wc-pre-order-booked -> wc-on-hold
###################################################################################

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/../config/config.sh"

if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo -e "${RED}Error: Configuration file not found: $CONFIG_FILE${NC}"
    exit 1
fi

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}CUSTOM STATUS CONVERSION${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Function to execute queries
execute_query() {
    mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" -p"$LOCAL_PASS" "$LOCAL_DB" -e "$1" 2>/dev/null
}

# Function to get count
get_count() {
    mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" -p"$LOCAL_PASS" "$LOCAL_DB" -sN -e "$1" 2>/dev/null
}

# Step 1: Show current custom statuses
echo -e "${YELLOW}Step 1: Current order status distribution:${NC}"
execute_query "
SELECT post_status, COUNT(*) as count 
FROM ${LOCAL_PREFIX}posts 
WHERE post_type = 'shop_order' 
GROUP BY post_status 
ORDER BY count DESC;"
echo ""

# Count custom statuses
DELIVERED_COUNT=$(get_count "SELECT COUNT(*) FROM ${LOCAL_PREFIX}posts WHERE post_type='shop_order' AND post_status='wc-delivered'")
FAILED_COUNT=$(get_count "SELECT COUNT(*) FROM ${LOCAL_PREFIX}posts WHERE post_type='shop_order' AND post_status='wc-failed'")
PREORDER_COUNT=$(get_count "SELECT COUNT(*) FROM ${LOCAL_PREFIX}posts WHERE post_type='shop_order' AND post_status='wc-pre-order-booked'")

TOTAL_CUSTOM=$((DELIVERED_COUNT + FAILED_COUNT + PREORDER_COUNT))

if [ "$TOTAL_CUSTOM" -eq 0 ]; then
    echo -e "${GREEN}No custom statuses found. All orders have standard WooCommerce statuses.${NC}"
    exit 0
fi

echo -e "${YELLOW}Step 2: Custom statuses to convert:${NC}"
echo "  wc-delivered (Delivered) → wc-completed: $DELIVERED_COUNT orders"
echo "  wc-failed (Failed) → wc-cancelled: $FAILED_COUNT orders"
echo "  wc-pre-order-booked (Pre-order) → wc-on-hold: $PREORDER_COUNT orders"
echo "  Total orders to convert: $TOTAL_CUSTOM"
echo ""

# Ask for confirmation
echo -e "${YELLOW}This will convert all custom statuses to standard WooCommerce statuses.${NC}"
read -p "Do you want to continue? (y/N): " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}Conversion cancelled.${NC}"
    exit 0
fi

echo ""
echo -e "${BLUE}Step 3: Converting custom statuses...${NC}"

# Start transaction
execute_query "START TRANSACTION;"

# Convert wc-delivered to wc-completed
if [ "$DELIVERED_COUNT" -gt 0 ]; then
    echo -n "Converting wc-delivered to wc-completed..."
    execute_query "
    UPDATE ${LOCAL_PREFIX}posts 
    SET post_status = 'wc-completed' 
    WHERE post_type = 'shop_order' 
    AND post_status = 'wc-delivered';"
    echo -e " ${GREEN}✓${NC} ($DELIVERED_COUNT orders)"
fi

# Convert wc-failed to wc-cancelled
if [ "$FAILED_COUNT" -gt 0 ]; then
    echo -n "Converting wc-failed to wc-cancelled..."
    execute_query "
    UPDATE ${LOCAL_PREFIX}posts 
    SET post_status = 'wc-cancelled' 
    WHERE post_type = 'shop_order' 
    AND post_status = 'wc-failed';"
    echo -e " ${GREEN}✓${NC} ($FAILED_COUNT orders)"
fi

# Convert wc-pre-order-booked to wc-on-hold
if [ "$PREORDER_COUNT" -gt 0 ]; then
    echo -n "Converting wc-pre-order-booked to wc-on-hold..."
    execute_query "
    UPDATE ${LOCAL_PREFIX}posts 
    SET post_status = 'wc-on-hold' 
    WHERE post_type = 'shop_order' 
    AND post_status = 'wc-pre-order-booked';"
    echo -e " ${GREEN}✓${NC} ($PREORDER_COUNT orders)"
fi

# Commit transaction
execute_query "COMMIT;"

echo ""
echo -e "${BLUE}Step 4: Final status distribution:${NC}"
execute_query "
SELECT post_status, COUNT(*) as count 
FROM ${LOCAL_PREFIX}posts 
WHERE post_type = 'shop_order' 
GROUP BY post_status 
ORDER BY count DESC;"

# Clear caches
echo ""
echo -e "${BLUE}Step 5: Clearing caches...${NC}"
execute_query "
DELETE FROM ${LOCAL_PREFIX}options WHERE option_name LIKE '_transient_%';
DELETE FROM ${LOCAL_PREFIX}options WHERE option_name LIKE '_site_transient_%';"

# Final count
FINAL_COUNT=$(get_count "SELECT COUNT(*) FROM ${LOCAL_PREFIX}posts WHERE post_type='shop_order'")
STANDARD_COUNT=$(get_count "SELECT COUNT(*) FROM ${LOCAL_PREFIX}posts WHERE post_type='shop_order' AND post_status IN ('wc-pending', 'wc-processing', 'wc-on-hold', 'wc-completed', 'wc-cancelled', 'wc-refunded', 'wc-failed')")

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}CONVERSION COMPLETED SUCCESSFULLY${NC}"
echo -e "${GREEN}========================================${NC}"
echo "Total orders: $FINAL_COUNT"
echo "Orders converted: $TOTAL_CUSTOM"
echo ""
echo -e "${GREEN}All orders should now appear in WooCommerce dashboard.${NC}"
echo -e "${YELLOW}Note: You may need to refresh your browser cache.${NC}"
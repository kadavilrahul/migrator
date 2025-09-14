#!/bin/bash

###################################################################################
# FIX CUSTOM ORDER STATUSES
###################################################################################
# Purpose: Convert custom order statuses to WooCommerce standard statuses
# This fixes orders not showing in WooCommerce dashboard
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

# Log file
LOG_FILE="$SCRIPT_DIR/../logs/fix_statuses_$(date +%Y%m%d_%H%M%S).log"

###################################################################################
# FUNCTIONS
###################################################################################

log_message() {
    echo -e "$1" | tee -a "$LOG_FILE"
}

execute_query() {
    mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" -p"$LOCAL_PASS" "$LOCAL_DB" -e "$1" 2>/dev/null
}

get_count() {
    mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" -p"$LOCAL_PASS" "$LOCAL_DB" -sN -e "$1" 2>/dev/null
}

###################################################################################
# MAIN
###################################################################################

log_message "${BLUE}=== FIX CUSTOM ORDER STATUSES ===${NC}"
log_message "${BLUE}Starting at: $(date)${NC}"
log_message ""

# Step 1: Check current custom statuses
log_message "${YELLOW}Step 1: Checking current order statuses...${NC}"
log_message ""

DELIVERED_COUNT=$(get_count "SELECT COUNT(*) FROM ${LOCAL_PREFIX}posts WHERE post_type='shop_order' AND post_status='wc-delivered'")
PREORDER_COUNT=$(get_count "SELECT COUNT(*) FROM ${LOCAL_PREFIX}posts WHERE post_type='shop_order' AND post_status='wc-pre-order-booked'")
FAILED_COUNT=$(get_count "SELECT COUNT(*) FROM ${LOCAL_PREFIX}posts WHERE post_type='shop_order' AND post_status='wc-failed'")

log_message "Custom statuses found:"
log_message "  wc-delivered: ${YELLOW}$DELIVERED_COUNT${NC} orders"
log_message "  wc-pre-order-booked: ${YELLOW}$PREORDER_COUNT${NC} orders"
log_message "  wc-failed: ${YELLOW}$FAILED_COUNT${NC} orders"
log_message ""

if [ "$DELIVERED_COUNT" -eq 0 ] && [ "$PREORDER_COUNT" -eq 0 ] && [ "$FAILED_COUNT" -eq 0 ]; then
    log_message "${GREEN}No custom statuses found. All orders have standard WooCommerce statuses.${NC}"
    exit 0
fi

# Step 2: Ask for confirmation
log_message "${YELLOW}This will convert custom statuses to standard WooCommerce statuses:${NC}"
log_message "  • wc-delivered → wc-completed"
log_message "  • wc-pre-order-booked → wc-on-hold"
log_message "  • wc-failed → wc-cancelled"
log_message ""
echo -n "Do you want to proceed? (y/n): "
read CONFIRM

if [ "$CONFIRM" != "y" ]; then
    log_message "${YELLOW}Operation cancelled${NC}"
    exit 0
fi

# Step 3: Backup current statuses
log_message ""
log_message "${YELLOW}Step 2: Creating backup of current statuses...${NC}"

# Create backup table
execute_query "CREATE TABLE IF NOT EXISTS ${LOCAL_PREFIX}order_status_backup (
    order_id BIGINT,
    original_status VARCHAR(50),
    backup_date DATETIME DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (order_id)
)"

# Backup current statuses
execute_query "INSERT IGNORE INTO ${LOCAL_PREFIX}order_status_backup (order_id, original_status)
SELECT ID, post_status FROM ${LOCAL_PREFIX}posts WHERE post_type='shop_order'"

log_message "${GREEN}Backup created in ${LOCAL_PREFIX}order_status_backup table${NC}"

# Step 4: Fix statuses in wp_posts
log_message ""
log_message "${YELLOW}Step 3: Updating order statuses in traditional tables...${NC}"

# Update delivered to completed
if [ "$DELIVERED_COUNT" -gt 0 ]; then
    execute_query "UPDATE ${LOCAL_PREFIX}posts 
                   SET post_status = 'wc-completed' 
                   WHERE post_type = 'shop_order' 
                   AND post_status = 'wc-delivered'"
    log_message "  ✅ Converted $DELIVERED_COUNT 'delivered' orders to 'completed'"
fi

# Update pre-order-booked to on-hold
if [ "$PREORDER_COUNT" -gt 0 ]; then
    execute_query "UPDATE ${LOCAL_PREFIX}posts 
                   SET post_status = 'wc-on-hold' 
                   WHERE post_type = 'shop_order' 
                   AND post_status = 'wc-pre-order-booked'"
    log_message "  ✅ Converted $PREORDER_COUNT 'pre-order-booked' orders to 'on-hold'"
fi

# Update failed to cancelled
if [ "$FAILED_COUNT" -gt 0 ]; then
    execute_query "UPDATE ${LOCAL_PREFIX}posts 
                   SET post_status = 'wc-cancelled' 
                   WHERE post_type = 'shop_order' 
                   AND post_status = 'wc-failed'"
    log_message "  ✅ Converted $FAILED_COUNT 'failed' orders to 'cancelled'"
fi

# Step 5: Fix statuses in HPOS tables
log_message ""
log_message "${YELLOW}Step 4: Updating order statuses in HPOS tables...${NC}"

HPOS_EXISTS=$(get_count "SELECT COUNT(*) FROM information_schema.tables 
                         WHERE table_schema = '$LOCAL_DB' 
                         AND table_name = '${LOCAL_PREFIX}wc_orders'")

if [ "$HPOS_EXISTS" -gt 0 ]; then
    # Update delivered to completed
    execute_query "UPDATE ${LOCAL_PREFIX}wc_orders 
                   SET status = 'completed' 
                   WHERE status = 'delivered'"
    
    # Update pre-order-booked to on-hold
    execute_query "UPDATE ${LOCAL_PREFIX}wc_orders 
                   SET status = 'on-hold' 
                   WHERE status = 'pre-order-booked'"
    
    # Update failed to cancelled
    execute_query "UPDATE ${LOCAL_PREFIX}wc_orders 
                   SET status = 'cancelled' 
                   WHERE status = 'failed'"
    
    log_message "${GREEN}HPOS tables updated${NC}"
else
    log_message "${YELLOW}HPOS tables not found, skipping${NC}"
fi

# Step 6: Update order status history in postmeta
log_message ""
log_message "${YELLOW}Step 5: Updating status history in metadata...${NC}"

# Update status in postmeta
execute_query "UPDATE ${LOCAL_PREFIX}postmeta 
               SET meta_value = 'completed' 
               WHERE meta_key = '_order_status' 
               AND meta_value = 'delivered'"

execute_query "UPDATE ${LOCAL_PREFIX}postmeta 
               SET meta_value = 'on-hold' 
               WHERE meta_key = '_order_status' 
               AND meta_value = 'pre-order-booked'"

execute_query "UPDATE ${LOCAL_PREFIX}postmeta 
               SET meta_value = 'cancelled' 
               WHERE meta_key = '_order_status' 
               AND meta_value = 'failed'"

log_message "${GREEN}Metadata updated${NC}"

# Step 7: Verify results
log_message ""
log_message "${YELLOW}Step 6: Verifying results...${NC}"

# Check standard statuses
COMPLETED=$(get_count "SELECT COUNT(*) FROM ${LOCAL_PREFIX}posts WHERE post_type='shop_order' AND post_status='wc-completed'")
ONHOLD=$(get_count "SELECT COUNT(*) FROM ${LOCAL_PREFIX}posts WHERE post_type='shop_order' AND post_status='wc-on-hold'")
CANCELLED=$(get_count "SELECT COUNT(*) FROM ${LOCAL_PREFIX}posts WHERE post_type='shop_order' AND post_status='wc-cancelled'")
REFUNDED=$(get_count "SELECT COUNT(*) FROM ${LOCAL_PREFIX}posts WHERE post_type='shop_order' AND post_status='wc-refunded'")
PROCESSING=$(get_count "SELECT COUNT(*) FROM ${LOCAL_PREFIX}posts WHERE post_type='shop_order' AND post_status='wc-processing'")
PENDING=$(get_count "SELECT COUNT(*) FROM ${LOCAL_PREFIX}posts WHERE post_type='shop_order' AND post_status='wc-pending'")

log_message ""
log_message "${GREEN}Final Order Status Distribution:${NC}"
log_message "  wc-completed: ${GREEN}$COMPLETED${NC}"
log_message "  wc-cancelled: ${GREEN}$CANCELLED${NC}"
log_message "  wc-refunded: ${GREEN}$REFUNDED${NC}"
log_message "  wc-on-hold: ${GREEN}$ONHOLD${NC}"
log_message "  wc-processing: ${GREEN}$PROCESSING${NC}"
log_message "  wc-pending: ${GREEN}$PENDING${NC}"

# Check for any remaining custom statuses
CUSTOM_REMAINING=$(get_count "SELECT COUNT(*) FROM ${LOCAL_PREFIX}posts 
                              WHERE post_type='shop_order' 
                              AND post_status NOT IN ('wc-completed', 'wc-processing', 'wc-on-hold', 
                                                      'wc-cancelled', 'wc-refunded', 'wc-failed', 
                                                      'wc-pending', 'wc-pending-payment')")

if [ "$CUSTOM_REMAINING" -gt 0 ]; then
    log_message ""
    log_message "${YELLOW}Warning: $CUSTOM_REMAINING orders still have non-standard statuses${NC}"
    log_message "Run this query to see them:"
    log_message "SELECT DISTINCT post_status FROM ${LOCAL_PREFIX}posts WHERE post_type='shop_order';"
else
    log_message ""
    log_message "${GREEN}✅ All orders now have standard WooCommerce statuses!${NC}"
fi

# Step 8: Clear cache
log_message ""
log_message "${YELLOW}Step 7: Clearing cache...${NC}"

# Clear transients
execute_query "DELETE FROM ${LOCAL_PREFIX}options WHERE option_name LIKE '%_transient_%'"

log_message "${GREEN}Cache cleared${NC}"

log_message ""
log_message "${GREEN}✅ === ORDER STATUS FIX COMPLETED ===${NC}"
log_message "${GREEN}All custom statuses have been converted to standard WooCommerce statuses${NC}"
log_message ""
log_message "${YELLOW}Note: If you need to restore original statuses, use the backup table: ${LOCAL_PREFIX}order_status_backup${NC}"
log_message ""
log_message "${BLUE}Finished at: $(date)${NC}"
log_message "Log saved to: $LOG_FILE"
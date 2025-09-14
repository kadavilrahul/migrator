#!/bin/bash

###################################################################################
# WOOCOMMERCE ORDER MIGRATION SCRIPT
###################################################################################
# Purpose: Migrate orders from remote database to local database
# Updated: Direct database to database migration (no CSV needed)
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
    # Simply source the shell configuration
    source "$CONFIG_FILE"
else
    echo "${RED}Error: Configuration file not found: $CONFIG_FILE${NC}"
    exit 1
fi

# Log file
LOG_FILE="/tmp/order_migration_$(date +%Y%m%d_%H%M%S).log"

###################################################################################
# FUNCTIONS
###################################################################################

log_message() {
    echo -e "$1" | tee -a "$LOG_FILE"
}

execute_local_query() {
    mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" -p"$LOCAL_PASS" "$LOCAL_DB" -e "$1" 2>/dev/null
}

execute_remote_query() {
    mysql -h "$REMOTE_HOST" -u "$REMOTE_USER" -p"$REMOTE_PASS" "$REMOTE_DB" -e "$1" 2>/dev/null
}

get_local_count() {
    mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" -p"$LOCAL_PASS" "$LOCAL_DB" -sN -e "$1" 2>/dev/null
}

get_remote_count() {
    mysql -h "$REMOTE_HOST" -u "$REMOTE_USER" -p"$REMOTE_PASS" "$REMOTE_DB" -sN -e "$1" 2>/dev/null
}

###################################################################################
# MAIN MIGRATION
###################################################################################

log_message "${BLUE}=== WOOCOMMERCE ORDER MIGRATION ===${NC}"
log_message "${BLUE}Starting at: $(date)${NC}"
log_message ""

# Step 1: Check remote orders
log_message "${YELLOW}Step 1: Checking remote database...${NC}"
REMOTE_ORDER_COUNT=$(get_remote_count "SELECT COUNT(*) FROM ${REMOTE_PREFIX}posts WHERE post_type = 'shop_order'")
log_message "Remote orders found: ${GREEN}$REMOTE_ORDER_COUNT${NC}"

if [ "$REMOTE_ORDER_COUNT" -eq 0 ]; then
    log_message "${RED}No orders found in remote database${NC}"
    exit 1
fi

# Step 2: Check local orders
log_message ""
log_message "${YELLOW}Step 2: Checking local database...${NC}"
LOCAL_ORDER_COUNT=$(get_local_count "SELECT COUNT(*) FROM ${LOCAL_PREFIX}posts WHERE post_type = 'shop_order'")
log_message "Local orders found: ${GREEN}$LOCAL_ORDER_COUNT${NC}"

if [ "$LOCAL_ORDER_COUNT" -gt 0 ]; then
    log_message "${YELLOW}Warning: Local database already has orders${NC}"
    echo -n "Do you want to DELETE existing orders and re-import? (y/n): "
    read CONFIRM
    if [ "$CONFIRM" != "y" ]; then
        log_message "${YELLOW}Migration cancelled${NC}"
        exit 0
    fi
    
    log_message "${YELLOW}Cleaning existing orders...${NC}"
    execute_local_query "SET FOREIGN_KEY_CHECKS = 0;"
    execute_local_query "DELETE FROM ${LOCAL_PREFIX}woocommerce_order_itemmeta;"
    execute_local_query "DELETE FROM ${LOCAL_PREFIX}woocommerce_order_items;"
    execute_local_query "DELETE FROM ${LOCAL_PREFIX}postmeta WHERE post_id IN (SELECT ID FROM ${LOCAL_PREFIX}posts WHERE post_type = 'shop_order');"
    execute_local_query "DELETE FROM ${LOCAL_PREFIX}posts WHERE post_type = 'shop_order';"
    execute_local_query "SET FOREIGN_KEY_CHECKS = 1;"
    log_message "${GREEN}Existing orders cleaned${NC}"
fi

# Step 3: Create temporary dump file
log_message ""
log_message "${YELLOW}Step 3: Exporting orders from remote database...${NC}"
DUMP_FILE="/tmp/orders_export_$(date +%Y%m%d_%H%M%S).sql"

# Add timeout and better options for remote connection
DUMP_OPTIONS="--single-transaction --quick --lock-tables=false --no-tablespaces --column-statistics=0"

log_message "Exporting order posts..."
timeout 30 mysqldump -h "$REMOTE_HOST" -u "$REMOTE_USER" -p"$REMOTE_PASS" "$REMOTE_DB" \
    $DUMP_OPTIONS \
    --no-create-info \
    --where="post_type='shop_order'" \
    "${REMOTE_PREFIX}posts" > "$DUMP_FILE" 2>/dev/null

if [ $? -ne 0 ]; then
    log_message "${RED}Error: Failed to export orders. Connection timeout or access denied.${NC}"
    log_message "${YELLOW}Try using the Fast migration option instead (option 2)${NC}"
    rm -f "$DUMP_FILE"
    exit 1
fi

log_message "Exporting order metadata..."
timeout 30 mysqldump -h "$REMOTE_HOST" -u "$REMOTE_USER" -p"$REMOTE_PASS" "$REMOTE_DB" \
    $DUMP_OPTIONS \
    --no-create-info \
    --where="post_id IN (SELECT ID FROM ${REMOTE_PREFIX}posts WHERE post_type='shop_order')" \
    "${REMOTE_PREFIX}postmeta" >> "$DUMP_FILE" 2>/dev/null

if [ $? -ne 0 ]; then
    log_message "${YELLOW}Warning: Failed to export order metadata${NC}"
fi

log_message "Exporting order items..."
timeout 30 mysqldump -h "$REMOTE_HOST" -u "$REMOTE_USER" -p"$REMOTE_PASS" "$REMOTE_DB" \
    $DUMP_OPTIONS \
    --no-create-info \
    --where="order_id IN (SELECT ID FROM ${REMOTE_PREFIX}posts WHERE post_type='shop_order')" \
    "${REMOTE_PREFIX}woocommerce_order_items" >> "$DUMP_FILE" 2>/dev/null

if [ $? -ne 0 ]; then
    log_message "${YELLOW}Warning: Failed to export order items${NC}"
fi

log_message "Exporting order item metadata..."
timeout 30 mysqldump -h "$REMOTE_HOST" -u "$REMOTE_USER" -p"$REMOTE_PASS" "$REMOTE_DB" \
    $DUMP_OPTIONS \
    --no-create-info \
    --where="order_item_id IN (SELECT order_item_id FROM ${REMOTE_PREFIX}woocommerce_order_items WHERE order_id IN (SELECT ID FROM ${REMOTE_PREFIX}posts WHERE post_type='shop_order'))" \
    "${REMOTE_PREFIX}woocommerce_order_itemmeta" >> "$DUMP_FILE" 2>/dev/null

if [ $? -ne 0 ]; then
    log_message "${YELLOW}Warning: Failed to export order item metadata${NC}"
fi

# Check if dump file has content
if [ ! -s "$DUMP_FILE" ]; then
    log_message "${RED}Error: Export file is empty. Remote connection may have failed.${NC}"
    log_message "${YELLOW}Try using the Fast migration option instead (option 2)${NC}"
    rm -f "$DUMP_FILE"
    exit 1
fi

log_message "${GREEN}Export completed${NC}"

# Step 4: Update table prefixes and clean dump
if [ "$REMOTE_PREFIX" != "$LOCAL_PREFIX" ]; then
    log_message "${YELLOW}Updating table prefixes from $REMOTE_PREFIX to $LOCAL_PREFIX...${NC}"
    sed -i "s/\`${REMOTE_PREFIX}/\`${LOCAL_PREFIX}/g" "$DUMP_FILE"
fi

# Remove LOCK/UNLOCK statements that cause issues
sed -i '/^LOCK TABLES/d; /^UNLOCK TABLES/d' "$DUMP_FILE"

# Replace INSERT with INSERT IGNORE to skip duplicates
sed -i 's/^INSERT INTO/INSERT IGNORE INTO/g' "$DUMP_FILE"

# Step 5: Import to local database
log_message ""
log_message "${YELLOW}Step 4: Importing orders to local database...${NC}"
mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" -p"$LOCAL_PASS" "$LOCAL_DB" < "$DUMP_FILE" 2>/dev/null

if [ $? -ne 0 ]; then
    log_message "${YELLOW}Import completed with some warnings (duplicates skipped)${NC}"
fi

# Step 6: Verify import
log_message ""
log_message "${YELLOW}Step 5: Verifying migration...${NC}"
IMPORTED_ORDERS=$(get_local_count "SELECT COUNT(*) FROM ${LOCAL_PREFIX}posts WHERE post_type = 'shop_order'")
IMPORTED_META=$(get_local_count "SELECT COUNT(*) FROM ${LOCAL_PREFIX}postmeta WHERE post_id IN (SELECT ID FROM ${LOCAL_PREFIX}posts WHERE post_type = 'shop_order')")
IMPORTED_ITEMS=$(get_local_count "SELECT COUNT(*) FROM ${LOCAL_PREFIX}woocommerce_order_items")
IMPORTED_ITEM_META=$(get_local_count "SELECT COUNT(*) FROM ${LOCAL_PREFIX}woocommerce_order_itemmeta")

log_message "${GREEN}Migration Results:${NC}"
log_message "  Orders imported: ${GREEN}$IMPORTED_ORDERS${NC} (expected: $REMOTE_ORDER_COUNT)"
log_message "  Order metadata: ${GREEN}$IMPORTED_META${NC}"
log_message "  Order items: ${GREEN}$IMPORTED_ITEMS${NC}"
log_message "  Item metadata: ${GREEN}$IMPORTED_ITEM_META${NC}"

# Clean up
rm -f "$DUMP_FILE"

# Step 7: Fix custom order statuses
log_message ""
log_message "${YELLOW}Step 6: Checking for custom order statuses...${NC}"

CUSTOM_STATUS_COUNT=$(get_local_count "SELECT COUNT(*) FROM ${LOCAL_PREFIX}posts WHERE post_type='shop_order' AND post_status IN ('wc-delivered', 'wc-pre-order-booked', 'wc-failed')")

if [ "$CUSTOM_STATUS_COUNT" -gt 0 ]; then
    log_message "${YELLOW}Found $CUSTOM_STATUS_COUNT orders with custom statuses${NC}"
    log_message "Converting to standard WooCommerce statuses..."
    
    # Convert custom statuses
    execute_local_query "UPDATE ${LOCAL_PREFIX}posts SET post_status = 'wc-completed' WHERE post_type = 'shop_order' AND post_status = 'wc-delivered'"
    execute_local_query "UPDATE ${LOCAL_PREFIX}posts SET post_status = 'wc-on-hold' WHERE post_type = 'shop_order' AND post_status = 'wc-pre-order-booked'"
    execute_local_query "UPDATE ${LOCAL_PREFIX}posts SET post_status = 'wc-cancelled' WHERE post_type = 'shop_order' AND post_status = 'wc-failed'"
    
    log_message "${GREEN}Custom statuses converted successfully${NC}"
fi

# Step 8: Success message
if [ "$IMPORTED_ORDERS" -eq "$REMOTE_ORDER_COUNT" ]; then
    log_message ""
    log_message "${GREEN}✅ === ORDER MIGRATION COMPLETED SUCCESSFULLY ===${NC}"
    log_message "${GREEN}All $IMPORTED_ORDERS orders have been migrated${NC}"
    log_message ""
    log_message "${YELLOW}Note: Run HPOS migration next if you want to enable High Performance Order Storage${NC}"
else
    log_message ""
    log_message "${RED}⚠ Warning: Order count mismatch${NC}"
    log_message "Expected: $REMOTE_ORDER_COUNT, Got: $IMPORTED_ORDERS"
fi

log_message ""
log_message "${BLUE}Finished at: $(date)${NC}"
log_message "Log saved to: $LOG_FILE"
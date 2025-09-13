#!/bin/bash

###################################################################################
# FINAL WOOCOMMERCE ORDER MIGRATION SCRIPT
###################################################################################
# Purpose: Import all 2,375 orders with complete metadata from CSV exports
# Date: September 13, 2025
# This is the ONLY script needed for order migration
###################################################################################

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
LOCAL_HOST="localhost"
LOCAL_USER="root"
LOCAL_PASS="Karimpadam2@"
LOCAL_DB="nilgiristores_in_db"
LOCAL_PREFIX="wp_"

# CSV Export Directory
EXPORT_DIR="/var/www/nilgiristores.in/migrator/exports/orders_20250913_180416"

# Log file
LOG_FILE="/tmp/order_migration_$(date +%Y%m%d_%H%M%S).log"

###################################################################################
# FUNCTIONS
###################################################################################

log_message() {
    echo -e "$1" | tee -a "$LOG_FILE"
}

execute_query() {
    mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" -p"$LOCAL_PASS" "$LOCAL_DB" -e "$1" 2>/dev/null
}

###################################################################################
# MAIN MIGRATION
###################################################################################

log_message "${BLUE}=== WOOCOMMERCE ORDER MIGRATION ===${NC}"
log_message "${BLUE}Starting at: $(date)${NC}"

# Step 1: Verify CSV files exist
log_message "${YELLOW}Step 1: Verifying CSV export files...${NC}"
if [ ! -f "$EXPORT_DIR/orders.csv" ]; then
    log_message "${RED}ERROR: CSV export files not found in $EXPORT_DIR${NC}"
    exit 1
fi

log_message "${GREEN}Found CSV files:${NC}"
ls -lh "$EXPORT_DIR"/*.csv | awk '{print "  " $9 ": " $5}'

# Step 2: Clean existing orders
log_message "${YELLOW}Step 2: Cleaning existing orders...${NC}"
execute_query "SET FOREIGN_KEY_CHECKS = 0;"
execute_query "DELETE FROM ${LOCAL_PREFIX}woocommerce_order_itemmeta;"
execute_query "DELETE FROM ${LOCAL_PREFIX}woocommerce_order_items;"
execute_query "DELETE FROM ${LOCAL_PREFIX}postmeta WHERE post_id IN (SELECT ID FROM ${LOCAL_PREFIX}posts WHERE post_type = 'shop_order');"
execute_query "DELETE FROM ${LOCAL_PREFIX}posts WHERE post_type = 'shop_order';"
execute_query "DELETE FROM ${LOCAL_PREFIX}wc_orders;"
execute_query "DELETE FROM ${LOCAL_PREFIX}wc_orders_meta;"
execute_query "DELETE FROM ${LOCAL_PREFIX}wc_order_addresses;"
execute_query "SET FOREIGN_KEY_CHECKS = 1;"
log_message "${GREEN}Existing orders cleaned${NC}"

# Step 3: Import orders from CSV (tab-separated)
log_message "${YELLOW}Step 3: Importing orders...${NC}"

# Convert and import orders
tail -n +2 "$EXPORT_DIR/orders.csv" | while IFS=$'\t' read -r ID post_author post_date post_date_gmt post_content post_title post_excerpt post_status comment_status ping_status post_password post_name to_ping pinged post_modified post_modified_gmt post_content_filtered post_parent guid menu_order post_type post_mime_type comment_count; do
    # Escape single quotes
    post_content=$(echo "$post_content" | sed "s/'/\\\\'/g")
    post_title=$(echo "$post_title" | sed "s/'/\\\\'/g")
    post_excerpt=$(echo "$post_excerpt" | sed "s/'/\\\\'/g")
    guid=$(echo "$guid" | sed "s/'/\\\\'/g")
    
    execute_query "INSERT INTO ${LOCAL_PREFIX}posts (ID, post_author, post_date, post_date_gmt, post_content, post_title, post_excerpt, post_status, comment_status, ping_status, post_password, post_name, to_ping, pinged, post_modified, post_modified_gmt, post_content_filtered, post_parent, guid, menu_order, post_type, post_mime_type, comment_count) VALUES ('$ID', '$post_author', '$post_date', '$post_date_gmt', '$post_content', '$post_title', '$post_excerpt', '$post_status', '$comment_status', '$ping_status', '$post_password', '$post_name', '$to_ping', '$pinged', '$post_modified', '$post_modified_gmt', '$post_content_filtered', '$post_parent', '$guid', '$menu_order', '$post_type', '$post_mime_type', '$comment_count');"
done

ORDER_COUNT=$(execute_query "SELECT COUNT(*) FROM ${LOCAL_PREFIX}posts WHERE post_type = 'shop_order';" | tail -1)
log_message "${GREEN}Imported $ORDER_COUNT orders${NC}"

# Step 4: Import metadata from CSV
log_message "${YELLOW}Step 4: Importing order metadata...${NC}"

# Process metadata in batches
BATCH_SIZE=1000
COUNTER=0
TOTAL_META=0

tail -n +2 "$EXPORT_DIR/order_metadata.csv" | while IFS=$'\t' read -r meta_id post_id meta_key meta_value; do
    # Escape single quotes
    meta_value=$(echo "$meta_value" | sed "s/'/\\\\'/g")
    
    # Build batch insert
    if [ $COUNTER -eq 0 ]; then
        QUERY="INSERT INTO ${LOCAL_PREFIX}postmeta (meta_id, post_id, meta_key, meta_value) VALUES "
    else
        QUERY="$QUERY,"
    fi
    
    QUERY="$QUERY('$meta_id', '$post_id', '$meta_key', '$meta_value')"
    COUNTER=$((COUNTER + 1))
    TOTAL_META=$((TOTAL_META + 1))
    
    # Execute batch when it reaches BATCH_SIZE
    if [ $COUNTER -eq $BATCH_SIZE ]; then
        execute_query "$QUERY;"
        echo -ne "\r  Imported $TOTAL_META metadata records..."
        COUNTER=0
    fi
done

# Execute remaining records
if [ $COUNTER -gt 0 ]; then
    execute_query "$QUERY;"
fi

echo ""
log_message "${GREEN}Imported metadata records${NC}"

# Step 5: Import order items
log_message "${YELLOW}Step 5: Importing order items...${NC}"

tail -n +2 "$EXPORT_DIR/order_items.csv" | while IFS=$'\t' read -r order_item_id order_item_name order_item_type order_id; do
    order_item_name=$(echo "$order_item_name" | sed "s/'/\\\\'/g")
    execute_query "INSERT INTO ${LOCAL_PREFIX}woocommerce_order_items (order_item_id, order_item_name, order_item_type, order_id) VALUES ('$order_item_id', '$order_item_name', '$order_item_type', '$order_id');"
done

ITEM_COUNT=$(execute_query "SELECT COUNT(*) FROM ${LOCAL_PREFIX}woocommerce_order_items;" | tail -1)
log_message "${GREEN}Imported $ITEM_COUNT order items${NC}"

# Step 6: Import order item metadata
log_message "${YELLOW}Step 6: Importing order item metadata...${NC}"

tail -n +2 "$EXPORT_DIR/order_item_metadata.csv" | while IFS=$'\t' read -r meta_id order_item_id meta_key meta_value; do
    meta_value=$(echo "$meta_value" | sed "s/'/\\\\'/g")
    execute_query "INSERT INTO ${LOCAL_PREFIX}woocommerce_order_itemmeta (meta_id, order_item_id, meta_key, meta_value) VALUES ('$meta_id', '$order_item_id', '$meta_key', '$meta_value');"
done

ITEM_META_COUNT=$(execute_query "SELECT COUNT(*) FROM ${LOCAL_PREFIX}woocommerce_order_itemmeta;" | tail -1)
log_message "${GREEN}Imported $ITEM_META_COUNT order item metadata${NC}"

# Step 7: Ensure HPOS is disabled
log_message "${YELLOW}Step 7: Configuring WooCommerce settings...${NC}"
execute_query "UPDATE ${LOCAL_PREFIX}options SET option_value = 'no' WHERE option_name IN ('woocommerce_custom_orders_table_enabled', 'woocommerce_custom_orders_table_data_sync_enabled', 'woocommerce_feature_custom_order_tables_enabled');"
log_message "${GREEN}HPOS disabled - using traditional posts storage${NC}"

# Step 8: Clear caches
log_message "${YELLOW}Step 8: Clearing caches...${NC}"
execute_query "DELETE FROM ${LOCAL_PREFIX}options WHERE option_name LIKE '_transient_%';"
execute_query "DELETE FROM ${LOCAL_PREFIX}options WHERE option_name LIKE '_site_transient_%';"
log_message "${GREEN}Caches cleared${NC}"

# Step 9: Final verification
log_message "${YELLOW}Step 9: Verification...${NC}"
log_message "${BLUE}=== MIGRATION RESULTS ===${NC}"

FINAL_ORDERS=$(execute_query "SELECT COUNT(*) FROM ${LOCAL_PREFIX}posts WHERE post_type = 'shop_order';" | tail -1)
FINAL_META=$(execute_query "SELECT COUNT(*) FROM ${LOCAL_PREFIX}postmeta WHERE post_id IN (SELECT ID FROM ${LOCAL_PREFIX}posts WHERE post_type = 'shop_order');" | tail -1)
FINAL_ITEMS=$(execute_query "SELECT COUNT(*) FROM ${LOCAL_PREFIX}woocommerce_order_items;" | tail -1)
FINAL_ITEM_META=$(execute_query "SELECT COUNT(*) FROM ${LOCAL_PREFIX}woocommerce_order_itemmeta;" | tail -1)

log_message "Total Orders: ${GREEN}$FINAL_ORDERS${NC}"
log_message "Total Metadata: ${GREEN}$FINAL_META${NC}"
log_message "Total Order Items: ${GREEN}$FINAL_ITEMS${NC}"
log_message "Total Item Metadata: ${GREEN}$FINAL_ITEM_META${NC}"

log_message "${BLUE}Order Status Breakdown:${NC}"
execute_query "SELECT post_status, COUNT(*) as count FROM ${LOCAL_PREFIX}posts WHERE post_type = 'shop_order' GROUP BY post_status ORDER BY count DESC;"

log_message "${GREEN}=== MIGRATION COMPLETE ===${NC}"
log_message "Log saved to: $LOG_FILE"
log_message ""
log_message "${YELLOW}IMPORTANT: To see all orders in WooCommerce dashboard:${NC}"
log_message "1. Clear browser cache (Ctrl+Shift+R)"
log_message "2. Go to WooCommerce > Status > Tools > Clear transients"
log_message "3. Verify 'wc-delivered' status is registered in Code Snippets"
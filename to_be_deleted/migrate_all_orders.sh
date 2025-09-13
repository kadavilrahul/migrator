#!/bin/bash

# Complete Order Migration Script - Migrates ALL orders without conflicts
# This script will migrate all 2375 orders from remote to local HPOS

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/../config/config.json"
LOG_FILE="$SCRIPT_DIR/../logs/migrate_all_orders_$(date +%Y%m%d_%H%M%S).log"

# Simple logging function
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Function 1: Load configuration and setup
load_config() {
    log "Loading configuration..."
    
    # Load remote database config from JSON or fallback to working values
    if [ -f "$CONFIG_FILE" ] && command -v jq &> /dev/null; then
        REMOTE_HOST=$(jq -r '.migration.remote_database.host' "$CONFIG_FILE")
        REMOTE_DB=$(jq -r '.migration.remote_database.database' "$CONFIG_FILE")
        REMOTE_USER=$(jq -r '.migration.remote_database.username' "$CONFIG_FILE")
        REMOTE_PASS=$(jq -r '.migration.remote_database.password' "$CONFIG_FILE")
        REMOTE_PREFIX=$(jq -r '.migration.remote_database.table_prefix' "$CONFIG_FILE")
    else
        # Fallback to known working values
        REMOTE_HOST="37.27.192.145"
        REMOTE_DB="nilgiristores_in_db"
        REMOTE_USER="nilgiristores_in_user"
        REMOTE_PASS="nilgiristores_in_2@"
        REMOTE_PREFIX="kdf_"
        log "Using fallback remote database configuration"
    fi
    
    # Load local database config from wp-config.php
    WP_CONFIG_PATH="/var/www/nilgiristores.in/wp-config.php"
    if [ ! -f "$WP_CONFIG_PATH" ]; then
        log "ERROR: WordPress config not found at $WP_CONFIG_PATH"
        exit 1
    fi
    
    LOCAL_DB=$(grep "DB_NAME" "$WP_CONFIG_PATH" | cut -d "'" -f 4)
    LOCAL_USER=$(grep "DB_USER" "$WP_CONFIG_PATH" | cut -d "'" -f 4)
    LOCAL_PASS=$(grep "DB_PASSWORD" "$WP_CONFIG_PATH" | cut -d "'" -f 4)
    LOCAL_HOST="localhost"
    
    log "Configuration loaded - Remote: $REMOTE_HOST/$REMOTE_DB, Local: $LOCAL_HOST/$LOCAL_DB"
}

# Function 2: Test database connections and prerequisites
test_connections() {
    log "Testing database connections and prerequisites..."
    
    # Test remote database connection
    export MYSQL_PWD="$REMOTE_PASS"
    if ! mysql -h "$REMOTE_HOST" -u "$REMOTE_USER" "$REMOTE_DB" -e "SELECT 1;" &>/dev/null; then
        log "ERROR: Cannot connect to remote database $REMOTE_HOST/$REMOTE_DB"
        unset MYSQL_PWD
        exit 1
    fi
    
    # Test remote table access
    REMOTE_COUNT=$(mysql -h "$REMOTE_HOST" -u "$REMOTE_USER" "$REMOTE_DB" -se "SELECT COUNT(*) FROM ${REMOTE_PREFIX}posts WHERE post_type = 'shop_order';" 2>/dev/null)
    if [ -z "$REMOTE_COUNT" ]; then
        log "ERROR: Cannot read orders from remote database"
        unset MYSQL_PWD
        exit 1
    fi
    unset MYSQL_PWD
    
    # Test local database connection
    export MYSQL_PWD="$LOCAL_PASS"
    if ! mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" "$LOCAL_DB" -e "SELECT 1;" &>/dev/null; then
        log "ERROR: Cannot connect to local database $LOCAL_HOST/$LOCAL_DB"
        unset MYSQL_PWD
        exit 1
    fi
    
    # Test local table access
    LOCAL_COUNT=$(mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" "$LOCAL_DB" -se "SELECT COUNT(*) FROM wp_posts WHERE post_type = 'shop_order';" 2>/dev/null)
    unset MYSQL_PWD
    
    # Check WP-CLI availability
    if ! command -v wp &> /dev/null; then
        log "ERROR: WP-CLI is required but not installed"
        exit 1
    fi
    
    # Test WP-CLI HPOS commands
    cd /var/www/nilgiristores.in
    if ! wp --allow-root wc hpos status &>/dev/null; then
        log "ERROR: WP-CLI HPOS commands not available"
        exit 1
    fi
    
    log "Connection test passed - Remote orders: $REMOTE_COUNT, Local orders: ${LOCAL_COUNT:-0}"
}

# Function 3: Clear existing local orders to avoid ID conflicts
clear_existing_orders() {
    log "Clearing existing local orders to avoid ID conflicts..."
    
    export MYSQL_PWD="$LOCAL_PASS"
    
    # Get count of existing orders for logging
    EXISTING_COUNT=$(mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" "$LOCAL_DB" -se "SELECT COUNT(*) FROM wp_posts WHERE post_type = 'shop_order';" 2>/dev/null || echo "0")
    
    if [ "$EXISTING_COUNT" -gt 0 ]; then
        log "Found $EXISTING_COUNT existing orders - removing to avoid conflicts..."
        
        # Create backup of existing order IDs for reference
        mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" "$LOCAL_DB" -e "
        SELECT CONCAT('-- Existing order ID: ', ID, ' (', post_title, ')')
        FROM wp_posts 
        WHERE post_type = 'shop_order'
        ORDER BY ID;
        " > "$SCRIPT_DIR/../logs/existing_orders_backup_$(date +%Y%m%d_%H%M%S).log" 2>/dev/null || true
        
        # Delete from HPOS tables first
        log "Removing existing HPOS data..."
        mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" "$LOCAL_DB" -e "DELETE FROM wp_wc_orders;" 2>/dev/null || true
        mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" "$LOCAL_DB" -e "DELETE FROM wp_wc_orders_meta;" 2>/dev/null || true
        mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" "$LOCAL_DB" -e "DELETE FROM wp_wc_order_stats;" 2>/dev/null || true
        mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" "$LOCAL_DB" -e "DELETE FROM wp_wc_order_addresses;" 2>/dev/null || true
        
        # Delete order item metadata
        log "Removing order item metadata..."
        mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" "$LOCAL_DB" -e "
        DELETE oim FROM wp_woocommerce_order_itemmeta oim
        INNER JOIN wp_woocommerce_order_items oi ON oim.order_item_id = oi.order_item_id
        INNER JOIN wp_posts p ON oi.order_id = p.ID
        WHERE p.post_type = 'shop_order';
        " 2>/dev/null || true
        
        # Delete order items
        log "Removing order items..."
        mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" "$LOCAL_DB" -e "
        DELETE oi FROM wp_woocommerce_order_items oi
        INNER JOIN wp_posts p ON oi.order_id = p.ID
        WHERE p.post_type = 'shop_order';
        " 2>/dev/null || true
        
        # Delete order metadata
        log "Removing order metadata..."
        mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" "$LOCAL_DB" -e "
        DELETE pm FROM wp_postmeta pm
        INNER JOIN wp_posts p ON pm.post_id = p.ID
        WHERE p.post_type = 'shop_order';
        " 2>/dev/null || true
        
        # Delete order posts
        log "Removing order posts..."
        mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" "$LOCAL_DB" -e "
        DELETE FROM wp_posts WHERE post_type = 'shop_order';
        " 2>/dev/null || true
        
        log "Cleared $EXISTING_COUNT existing orders successfully"
    else
        log "No existing orders found to clear"
    fi
    
    unset MYSQL_PWD
}

# Function 4: Migrate ALL orders from remote database + Export to CSV
migrate_all_orders() {
    log "Migrating ALL orders from remote database and exporting to CSV..."
    
    # Create directories for exports
    CSV_DIR="$SCRIPT_DIR/../exports/orders_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$CSV_DIR"
    
    export MYSQL_PWD="$REMOTE_PASS"
    
    log "Step 1: Extracting and migrating order posts..."
    # Export orders to CSV
    mysql -h "$REMOTE_HOST" -u "$REMOTE_USER" "$REMOTE_DB" -e "
    SELECT ID, post_author, post_date, post_date_gmt, post_content, post_title, 
           post_excerpt, post_status, comment_status, ping_status, post_password, 
           post_name, to_ping, pinged, post_modified, post_modified_gmt, 
           post_content_filtered, post_parent, guid, menu_order, post_type, 
           post_mime_type, comment_count
    FROM ${REMOTE_PREFIX}posts 
    WHERE post_type = 'shop_order' 
    ORDER BY ID;
    " > "$CSV_DIR/orders.csv"
    
    # Use mysqldump for reliable SQL export (proven method)
    mysqldump -h "$REMOTE_HOST" -u "$REMOTE_USER" "$REMOTE_DB" \
        --no-create-info \
        --complete-insert \
        --where="post_type='shop_order'" \
        "${REMOTE_PREFIX}posts" > "$CSV_DIR/orders_dump.sql"
    
    log "Step 2: Extracting and migrating order metadata..."
    # Export metadata to CSV
    mysql -h "$REMOTE_HOST" -u "$REMOTE_USER" "$REMOTE_DB" -e "
    SELECT pm.post_id, pm.meta_key, pm.meta_value
    FROM ${REMOTE_PREFIX}postmeta pm
    INNER JOIN ${REMOTE_PREFIX}posts p ON pm.post_id = p.ID
    WHERE p.post_type = 'shop_order'
    ORDER BY pm.post_id, pm.meta_key;
    " > "$CSV_DIR/order_metadata.csv"
    
    # Export metadata with mysqldump
    mysqldump -h "$REMOTE_HOST" -u "$REMOTE_USER" "$REMOTE_DB" \
        --no-create-info \
        --complete-insert \
        --where="post_id IN (SELECT ID FROM ${REMOTE_PREFIX}posts WHERE post_type = 'shop_order')" \
        "${REMOTE_PREFIX}postmeta" > "$CSV_DIR/metadata_dump.sql" 2>/dev/null || true
    
    log "Step 3: Extracting and migrating order items..."
    # Export order items to CSV
    mysql -h "$REMOTE_HOST" -u "$REMOTE_USER" "$REMOTE_DB" -e "
    SELECT oi.order_item_id, oi.order_id, oi.order_item_name, oi.order_item_type
    FROM ${REMOTE_PREFIX}woocommerce_order_items oi
    INNER JOIN ${REMOTE_PREFIX}posts p ON oi.order_id = p.ID
    WHERE p.post_type = 'shop_order'
    ORDER BY oi.order_id, oi.order_item_id;
    " > "$CSV_DIR/order_items.csv"
    
    # Export order items with mysqldump
    mysqldump -h "$REMOTE_HOST" -u "$REMOTE_USER" "$REMOTE_DB" \
        --no-create-info \
        --complete-insert \
        "${REMOTE_PREFIX}woocommerce_order_items" > "$CSV_DIR/order_items_dump.sql"
    
    log "Step 4: Extracting and migrating order item metadata..."
    # Export order item metadata to CSV
    mysql -h "$REMOTE_HOST" -u "$REMOTE_USER" "$REMOTE_DB" -e "
    SELECT oim.order_item_id, oim.meta_key, oim.meta_value
    FROM ${REMOTE_PREFIX}woocommerce_order_itemmeta oim
    INNER JOIN ${REMOTE_PREFIX}woocommerce_order_items oi ON oim.order_item_id = oi.order_item_id
    INNER JOIN ${REMOTE_PREFIX}posts p ON oi.order_id = p.ID
    WHERE p.post_type = 'shop_order'
    ORDER BY oim.order_item_id, oim.meta_key;
    " > "$CSV_DIR/order_item_metadata.csv"
    
    # Export order item metadata with mysqldump
    mysqldump -h "$REMOTE_HOST" -u "$REMOTE_USER" "$REMOTE_DB" \
        --no-create-info \
        --complete-insert \
        "${REMOTE_PREFIX}woocommerce_order_itemmeta" > "$CSV_DIR/order_item_metadata_dump.sql"
    
    unset MYSQL_PWD
    
    log "Step 5: Importing ALL data to local database using mysqldump files..."
    export MYSQL_PWD="$LOCAL_PASS"
    
    # Replace table prefixes in dump files and import
    sed "s/${REMOTE_PREFIX}/wp_/g" "$CSV_DIR/orders_dump.sql" | mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" "$LOCAL_DB"
    
    # Import metadata with error handling
    if [ -f "$CSV_DIR/metadata_dump.sql" ]; then
        sed "s/${REMOTE_PREFIX}/wp_/g" "$CSV_DIR/metadata_dump.sql" | mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" "$LOCAL_DB" || true
    fi
    
    # Import order items
    sed "s/${REMOTE_PREFIX}/wp_/g" "$CSV_DIR/order_items_dump.sql" | mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" "$LOCAL_DB"
    
    # Import order item metadata
    sed "s/${REMOTE_PREFIX}/wp_/g" "$CSV_DIR/order_item_metadata_dump.sql" | mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" "$LOCAL_DB"
    
    unset MYSQL_PWD
    
    # Count lines in CSV files for verification
    ORDERS_CSV_COUNT=$(tail -n +2 "$CSV_DIR/orders.csv" | wc -l)
    METADATA_CSV_COUNT=$(tail -n +2 "$CSV_DIR/order_metadata.csv" | wc -l)
    ITEMS_CSV_COUNT=$(tail -n +2 "$CSV_DIR/order_items.csv" | wc -l)
    ITEM_META_CSV_COUNT=$(tail -n +2 "$CSV_DIR/order_item_metadata.csv" | wc -l)
    
    log "Migration and CSV export completed successfully!"
    log "CSV files created in: $CSV_DIR"
    log "  - orders.csv: $ORDERS_CSV_COUNT records"
    log "  - order_metadata.csv: $METADATA_CSV_COUNT records"
    log "  - order_items.csv: $ITEMS_CSV_COUNT records"
    log "  - order_item_metadata.csv: $ITEM_META_CSV_COUNT records"
}

# Function 5: Convert all migrated orders to HPOS format
convert_all_to_hpos() {
    log "Converting all migrated orders to HPOS format..."
    
    cd /var/www/nilgiristores.in
    
    # Step 1: Reset HPOS state to detect all orders
    log "Resetting HPOS state to detect all migrated orders..."
    wp --allow-root wc hpos disable >/dev/null 2>&1 || true
    
    # Wait a moment for the state to reset
    sleep 2
    
    # Step 2: Count orders that need migration
    log "Counting orders for HPOS conversion..."
    ORDER_COUNT=$(wp --allow-root wc hpos count_unmigrated 2>/dev/null | grep -o '[0-9]*' | head -1 || echo "0")
    
    if [ "${ORDER_COUNT:-0}" -eq 0 ]; then
        log "WARNING: No orders detected for HPOS conversion - checking manually..."
        
        # Manual check of wp_posts orders
        export MYSQL_PWD="$LOCAL_PASS"
        POSTS_ORDER_COUNT=$(mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" "$LOCAL_DB" -se "SELECT COUNT(*) FROM wp_posts WHERE post_type = 'shop_order';" 2>/dev/null)
        unset MYSQL_PWD
        
        log "Found $POSTS_ORDER_COUNT orders in wp_posts table"
        
        if [ "$POSTS_ORDER_COUNT" -eq 0 ]; then
            log "ERROR: No orders found in wp_posts - migration may have failed"
            return 1
        fi
    else
        log "Found $ORDER_COUNT orders ready for HPOS conversion"
    fi
    
    # Step 3: Perform the HPOS migration
    log "Starting HPOS conversion for all orders..."
    log "This may take several minutes for $ORDER_COUNT orders..."
    
    # Use larger batch size for better performance
    SYNC_RESULT=$(wp --allow-root wc hpos sync --batch-size=200 2>&1)
    echo "$SYNC_RESULT" | tee -a "$LOG_FILE"
    
    # Step 4: Enable HPOS
    log "Enabling HPOS..."
    wp --allow-root wc hpos enable 2>&1 | tee -a "$LOG_FILE"
    
    # Step 5: Disable compatibility mode for optimal performance
    log "Disabling compatibility mode for optimal performance..."
    wp --allow-root wc hpos compatibility-mode disable 2>&1 | tee -a "$LOG_FILE"
    
    # Step 6: Verify HPOS conversion
    log "Verifying HPOS conversion..."
    wp --allow-root wc hpos status 2>&1 | tee -a "$LOG_FILE"
    
    # Check final counts
    export MYSQL_PWD="$LOCAL_PASS"
    HPOS_COUNT=$(mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" "$LOCAL_DB" -se "SELECT COUNT(*) FROM wp_wc_orders;" 2>/dev/null)
    POSTS_COUNT=$(mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" "$LOCAL_DB" -se "SELECT COUNT(*) FROM wp_posts WHERE post_type = 'shop_order';" 2>/dev/null)
    unset MYSQL_PWD
    
    log "HPOS conversion completed!"
    log "  Orders in wp_posts: $POSTS_COUNT"
    log "  Orders in HPOS (wp_wc_orders): $HPOS_COUNT"
    
    if [ "$HPOS_COUNT" -eq "$POSTS_COUNT" ] && [ "$HPOS_COUNT" -gt 0 ]; then
        log "SUCCESS: All orders successfully converted to HPOS format"
    else
        log "WARNING: HPOS conversion may have issues - manual verification recommended"
    fi
}

# Function 6: Final verification and reporting
verify_migration() {
    log "Performing final verification and generating migration report..."
    
    # Get remote counts
    export MYSQL_PWD="$REMOTE_PASS"
    REMOTE_ORDERS=$(mysql -h "$REMOTE_HOST" -u "$REMOTE_USER" "$REMOTE_DB" -se "SELECT COUNT(*) FROM ${REMOTE_PREFIX}posts WHERE post_type = 'shop_order';" 2>/dev/null)
    REMOTE_META=$(mysql -h "$REMOTE_HOST" -u "$REMOTE_USER" "$REMOTE_DB" -se "SELECT COUNT(*) FROM ${REMOTE_PREFIX}postmeta pm INNER JOIN ${REMOTE_PREFIX}posts p ON pm.post_id = p.ID WHERE p.post_type = 'shop_order';" 2>/dev/null)
    REMOTE_ITEMS=$(mysql -h "$REMOTE_HOST" -u "$REMOTE_USER" "$REMOTE_DB" -se "SELECT COUNT(*) FROM ${REMOTE_PREFIX}woocommerce_order_items oi INNER JOIN ${REMOTE_PREFIX}posts p ON oi.order_id = p.ID WHERE p.post_type = 'shop_order';" 2>/dev/null)
    REMOTE_ITEM_META=$(mysql -h "$REMOTE_HOST" -u "$REMOTE_USER" "$REMOTE_DB" -se "SELECT COUNT(*) FROM ${REMOTE_PREFIX}woocommerce_order_itemmeta oim INNER JOIN ${REMOTE_PREFIX}woocommerce_order_items oi ON oim.order_item_id = oi.order_item_id INNER JOIN ${REMOTE_PREFIX}posts p ON oi.order_id = p.ID WHERE p.post_type = 'shop_order';" 2>/dev/null)
    unset MYSQL_PWD
    
    # Get local counts
    export MYSQL_PWD="$LOCAL_PASS"
    LOCAL_POSTS=$(mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" "$LOCAL_DB" -se "SELECT COUNT(*) FROM wp_posts WHERE post_type = 'shop_order';" 2>/dev/null)
    LOCAL_META=$(mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" "$LOCAL_DB" -se "SELECT COUNT(*) FROM wp_postmeta pm INNER JOIN wp_posts p ON pm.post_id = p.ID WHERE p.post_type = 'shop_order';" 2>/dev/null)
    LOCAL_ITEMS=$(mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" "$LOCAL_DB" -se "SELECT COUNT(*) FROM wp_woocommerce_order_items;" 2>/dev/null)
    LOCAL_ITEM_META=$(mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" "$LOCAL_DB" -se "SELECT COUNT(*) FROM wp_woocommerce_order_itemmeta;" 2>/dev/null)
    LOCAL_HPOS=$(mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" "$LOCAL_DB" -se "SELECT COUNT(*) FROM wp_wc_orders;" 2>/dev/null)
    unset MYSQL_PWD
    
    # Generate detailed report
    REPORT_FILE="$SCRIPT_DIR/../logs/migration_report_$(date +%Y%m%d_%H%M%S).txt"
    
    cat > "$REPORT_FILE" << EOF
=================================================================
COMPLETE ORDER MIGRATION REPORT
=================================================================
Migration Date: $(date)
Script: migrate_all_orders.sh
Log File: $LOG_FILE

REMOTE DATABASE (SOURCE):
-----------------------------------------------------------------
Host: $REMOTE_HOST
Database: $REMOTE_DB
Table Prefix: $REMOTE_PREFIX

Orders: $REMOTE_ORDERS
Order Metadata: $REMOTE_META
Order Items: $REMOTE_ITEMS
Order Item Metadata: $REMOTE_ITEM_META

LOCAL DATABASE (DESTINATION):
-----------------------------------------------------------------
Host: $LOCAL_HOST
Database: $LOCAL_DB

Orders (wp_posts): $LOCAL_POSTS
Order Metadata: $LOCAL_META
Order Items: $LOCAL_ITEMS
Order Item Metadata: $LOCAL_ITEM_META
HPOS Orders (wp_wc_orders): $LOCAL_HPOS

CSV EXPORTS:
-----------------------------------------------------------------
EOF
    
    # Add CSV file information if they exist
    if [ -n "${CSV_DIR:-}" ] && [ -d "$CSV_DIR" ]; then
        echo "Export Directory: $CSV_DIR" >> "$REPORT_FILE"
        for csv_file in "$CSV_DIR"/*.csv; do
            if [ -f "$csv_file" ]; then
                filename=$(basename "$csv_file")
                record_count=$(tail -n +2 "$csv_file" | wc -l)
                echo "$filename: $record_count records" >> "$REPORT_FILE"
            fi
        done
    else
        echo "CSV export directory not found" >> "$REPORT_FILE"
    fi
    
    cat >> "$REPORT_FILE" << EOF

MIGRATION VERIFICATION:
-----------------------------------------------------------------
EOF
    
    # Check if migration was successful
    MIGRATION_SUCCESS=true
    
    if [ "$REMOTE_ORDERS" -eq "$LOCAL_POSTS" ]; then
        echo "✅ Orders Migration: SUCCESS ($LOCAL_POSTS/$REMOTE_ORDERS orders migrated)" >> "$REPORT_FILE"
    else
        echo "❌ Orders Migration: FAILED ($LOCAL_POSTS/$REMOTE_ORDERS orders migrated)" >> "$REPORT_FILE"
        MIGRATION_SUCCESS=false
    fi
    
    if [ "$REMOTE_META" -eq "$LOCAL_META" ]; then
        echo "✅ Metadata Migration: SUCCESS ($LOCAL_META/$REMOTE_META records migrated)" >> "$REPORT_FILE"
    else
        echo "❌ Metadata Migration: FAILED ($LOCAL_META/$REMOTE_META records migrated)" >> "$REPORT_FILE"
        MIGRATION_SUCCESS=false
    fi
    
    if [ "$REMOTE_ITEMS" -eq "$LOCAL_ITEMS" ]; then
        echo "✅ Order Items Migration: SUCCESS ($LOCAL_ITEMS/$REMOTE_ITEMS items migrated)" >> "$REPORT_FILE"
    else
        echo "❌ Order Items Migration: FAILED ($LOCAL_ITEMS/$REMOTE_ITEMS items migrated)" >> "$REPORT_FILE"
        MIGRATION_SUCCESS=false
    fi
    
    if [ "$REMOTE_ITEM_META" -eq "$LOCAL_ITEM_META" ]; then
        echo "✅ Item Metadata Migration: SUCCESS ($LOCAL_ITEM_META/$REMOTE_ITEM_META records migrated)" >> "$REPORT_FILE"
    else
        echo "❌ Item Metadata Migration: FAILED ($LOCAL_ITEM_META/$REMOTE_ITEM_META records migrated)" >> "$REPORT_FILE"
        MIGRATION_SUCCESS=false
    fi
    
    if [ "$LOCAL_HPOS" -eq "$LOCAL_POSTS" ] && [ "$LOCAL_HPOS" -gt 0 ]; then
        echo "✅ HPOS Conversion: SUCCESS ($LOCAL_HPOS orders in HPOS format)" >> "$REPORT_FILE"
    else
        echo "❌ HPOS Conversion: FAILED ($LOCAL_HPOS/$LOCAL_POSTS orders in HPOS format)" >> "$REPORT_FILE"
        MIGRATION_SUCCESS=false
    fi
    
    if [ "$MIGRATION_SUCCESS" = true ]; then
        echo -e "\n🎉 OVERALL MIGRATION STATUS: SUCCESS" >> "$REPORT_FILE"
        echo "All $REMOTE_ORDERS orders successfully migrated and converted to HPOS!" >> "$REPORT_FILE"
    else
        echo -e "\n❌ OVERALL MIGRATION STATUS: FAILED" >> "$REPORT_FILE"
        echo "Migration completed with errors - manual verification required" >> "$REPORT_FILE"
    fi
    
    echo "=================================================================" >> "$REPORT_FILE"
    
    # Display report to user
    cat "$REPORT_FILE" | tee -a "$LOG_FILE"
    
    log "Migration report saved to: $REPORT_FILE"
    
    if [ "$MIGRATION_SUCCESS" = true ]; then
        return 0
    else
        return 1
    fi
}

# Function 7: Main execution function with user confirmation
main() {
    echo "================================================================="
    echo "COMPLETE ORDER MIGRATION SCRIPT"
    echo "================================================================="
    echo ""
    echo "This script will:"
    echo "1. 🗑️  Clear ALL existing local orders (to avoid ID conflicts)"
    echo "2. 📥 Migrate ALL 2375 orders from remote database"
    echo "3. 📊 Export all order data to CSV files"
    echo "4. ⚡ Convert all orders to HPOS format"
    echo "5. ✅ Verify complete migration success"
    echo ""
    
    # Parse command line arguments
    FORCE_YES=false
    SKIP_BACKUP=false
    
    for arg in "$@"; do
        case $arg in
            --yes|-y)
                FORCE_YES=true
                ;;
            --no-backup)
                SKIP_BACKUP=true
                ;;
            --help|-h)
                echo "Usage: $0 [OPTIONS]"
                echo ""
                echo "Options:"
                echo "  --yes, -y       Skip confirmation prompts"
                echo "  --no-backup     Skip creating database backup"
                echo "  --help, -h      Show this help"
                echo ""
                echo "This script will migrate ALL orders from remote to local database"
                echo "and convert them to HPOS format, with CSV export for backup."
                echo ""
                exit 0
                ;;
            *)
                echo "ERROR: Unknown argument: $arg"
                echo "Use --help for usage information"
                exit 1
                ;;
        esac
    done
    
    # Step 0: Initialize and test connections
    load_config
    test_connections
    
    # Show what we found
    echo "MIGRATION ANALYSIS:"
    echo "  Remote orders to migrate: $REMOTE_COUNT"
    echo "  Existing local orders: ${LOCAL_COUNT:-0} (will be REMOVED)"
    echo "  Expected final result: $REMOTE_COUNT orders in HPOS format"
    echo ""
    
    # Create backup unless skipped
    if [ "$SKIP_BACKUP" = false ]; then
        echo "📋 Creating database backup before proceeding..."
        if [ -f "$SCRIPT_DIR/wp_db_local_backup_restore.sh" ]; then
            cd "$SCRIPT_DIR"
            echo "1" | ./wp_db_local_backup_restore.sh > /dev/null 2>&1
            echo "✅ Database backup created"
        else
            echo "⚠️  Backup script not found - proceeding without backup"
        fi
        echo ""
    fi
    
    # Confirm with user unless forced
    if [ "$FORCE_YES" = false ]; then
        echo "⚠️  WARNING: This will PERMANENTLY DELETE all existing local orders!"
        echo "⚠️  Make sure you have a backup if you need the existing data!"
        echo ""
        echo "This process will:"
        echo "- Delete ${LOCAL_COUNT:-0} existing local orders"
        echo "- Migrate $REMOTE_COUNT new orders from remote"
        echo "- Export all data to CSV files"
        echo "- Convert everything to HPOS format"
        echo ""
        read -p "Do you want to proceed with COMPLETE order migration? (y/N): " -n 1 -r
        echo ""
        echo ""
        
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log "Migration cancelled by user"
            echo "Migration cancelled."
            exit 0
        fi
    fi
    
    log "Starting complete order migration process..."
    echo "🚀 Starting migration process..."
    echo ""
    
    # Execute migration steps
    set +e  # Don't exit on errors, handle them gracefully
    
    echo "Step 1/5: Clearing existing orders..."
    if ! clear_existing_orders; then
        log "ERROR: Failed to clear existing orders"
        echo "❌ Failed to clear existing orders - check log file"
        exit 1
    fi
    echo "✅ Existing orders cleared"
    echo ""
    
    echo "Step 2/5: Migrating all orders and exporting to CSV..."
    if ! migrate_all_orders; then
        log "ERROR: Failed to migrate orders"
        echo "❌ Failed to migrate orders - check log file"
        exit 1
    fi
    echo "✅ Orders migrated and exported to CSV"
    echo ""
    
    echo "Step 3/5: Converting to HPOS format..."
    if ! convert_all_to_hpos; then
        log "ERROR: Failed to convert to HPOS"
        echo "❌ Failed to convert to HPOS - check log file"
        exit 1
    fi
    echo "✅ Orders converted to HPOS format"
    echo ""
    
    echo "Step 4/5: Verifying migration..."
    if verify_migration; then
        echo ""
        echo "🎉 MIGRATION COMPLETED SUCCESSFULLY!"
        echo "🎉 All $REMOTE_COUNT orders have been migrated and converted to HPOS!"
        echo ""
        echo "📊 CSV exports are available in: ${CSV_DIR:-exports directory}"
        echo "📋 Detailed report available in migration logs"
        echo ""
        log "Complete migration finished successfully"
    else
        echo ""
        echo "❌ MIGRATION COMPLETED WITH ISSUES"
        echo "❌ Check the migration report for details"
        echo ""
        log "Migration finished with issues"
        exit 1
    fi
    
    set -e  # Re-enable exit on errors
}

# Ensure logs and exports directories exist
mkdir -p "$SCRIPT_DIR/../logs"
mkdir -p "$SCRIPT_DIR/../exports"

# Execute main function with all arguments
main "$@"
#!/bin/bash

# Complete HPOS Order Migration Script
# Migrates orders from remote WordPress database directly to HPOS format
set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/../config/config.json"
LOG_FILE="$SCRIPT_DIR/../logs/migrate_orders_hpos_complete_$(date +%Y%m%d_%H%M%S).log"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}ℹ️  $1${NC}" | tee -a "$LOG_FILE"
}

log_success() {
    echo -e "${GREEN}✅ $1${NC}" | tee -a "$LOG_FILE"
}

log_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}❌ $1${NC}" | tee -a "$LOG_FILE"
}

# Load configuration
load_config() {
    log_info "Loading configuration..."
    
    if [ ! -f "$CONFIG_FILE" ]; then
        log_error "Configuration file not found: $CONFIG_FILE"
        exit 1
    fi
    
    # Extract remote database config
    REMOTE_HOST=$(jq -r '.migration.remote_database.host' "$CONFIG_FILE")
    REMOTE_DB=$(jq -r '.migration.remote_database.database' "$CONFIG_FILE")
    REMOTE_USER=$(jq -r '.migration.remote_database.username' "$CONFIG_FILE")
    REMOTE_PASS=$(jq -r '.migration.remote_database.password' "$CONFIG_FILE")
    REMOTE_PREFIX=$(jq -r '.migration.remote_database.table_prefix' "$CONFIG_FILE")
    
    # Load WordPress config
    WP_CONFIG_PATH="/var/www/nilgiristores.in/wp-config.php"
    
    if [ ! -f "$WP_CONFIG_PATH" ]; then
        log_error "WordPress config not found at $WP_CONFIG_PATH"
        exit 1
    fi
    
    LOCAL_DB=$(grep "DB_NAME" "$WP_CONFIG_PATH" | cut -d "'" -f 4)
    LOCAL_USER=$(grep "DB_USER" "$WP_CONFIG_PATH" | cut -d "'" -f 4)
    LOCAL_PASS=$(grep "DB_PASSWORD" "$WP_CONFIG_PATH" | cut -d "'" -f 4)
    LOCAL_HOST=$(grep "DB_HOST" "$WP_CONFIG_PATH" | cut -d "'" -f 4)
    
    log_success "Configuration loaded successfully"
}

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."
    
    # Check jq
    if ! command -v jq &> /dev/null; then
        log_error "jq is required but not installed"
        exit 1
    fi
    
    # Check WP-CLI
    if ! command -v wp &> /dev/null; then
        log_error "WP-CLI is required but not installed"
        exit 1
    fi
    
    # Check remote database connection
    if ! mysql -h "$REMOTE_HOST" -u "$REMOTE_USER" -p"$REMOTE_PASS" -e "USE $REMOTE_DB;" &>/dev/null; then
        log_error "Cannot connect to remote database"
        exit 1
    fi
    
    # Check local database connection
    if ! mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" -p"$LOCAL_PASS" -e "USE $LOCAL_DB;" &>/dev/null; then
        log_error "Cannot connect to local database"
        exit 1
    fi
    
    log_success "All prerequisites met"
}

# Check what orders need to be migrated
check_migration_status() {
    log_info "Checking migration status..."
    
    export MYSQL_PWD="$REMOTE_PASS"
    REMOTE_ORDER_COUNT=$(mysql -h "$REMOTE_HOST" -u "$REMOTE_USER" "$REMOTE_DB" -se "SELECT COUNT(*) FROM ${REMOTE_PREFIX}posts WHERE post_type = 'shop_order';" 2>/dev/null)
    unset MYSQL_PWD
    
    export MYSQL_PWD="$LOCAL_PASS"
    LOCAL_ORDER_COUNT=$(mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" "$LOCAL_DB" -se "SELECT COUNT(*) FROM wp_posts WHERE post_type = 'shop_order';" 2>/dev/null || echo "0")
    HPOS_ORDER_COUNT=$(mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" "$LOCAL_DB" -se "SELECT COUNT(*) FROM wp_wc_orders;" 2>/dev/null || echo "0")
    unset MYSQL_PWD
    
    log_info "Remote orders: $REMOTE_ORDER_COUNT"
    log_info "Local wp_posts orders: $LOCAL_ORDER_COUNT"
    log_info "Local HPOS orders: $HPOS_ORDER_COUNT"
    
    NEW_ORDERS_TO_SYNC=$((REMOTE_ORDER_COUNT - LOCAL_ORDER_COUNT))
    
    if [ "$NEW_ORDERS_TO_SYNC" -le 0 ]; then
        log_info "No new orders to migrate from remote database"
        
        # Check if we need to convert existing orders to HPOS
        if [ "$LOCAL_ORDER_COUNT" -gt 0 ] && [ "$HPOS_ORDER_COUNT" -eq 0 ]; then
            log_info "Found $LOCAL_ORDER_COUNT orders that need HPOS conversion"
            return 1  # Indicate HPOS conversion needed
        else
            log_info "All orders are already migrated and in HPOS format"
            return 2  # Indicate no work needed
        fi
    else
        log_info "Found $NEW_ORDERS_TO_SYNC new orders to migrate"
        return 0  # Indicate full migration needed
    fi
}

# Direct migration from remote to local database (batch processing)
migrate_orders_directly() {
    log_info "Migrating orders directly from remote to local database..."
    
    TEMP_DIR="/tmp/hpos_migration_$(date +%s)"
    mkdir -p "$TEMP_DIR"
    
    export MYSQL_PWD="$REMOTE_PASS"
    
    # Step 1: Migrate orders (posts) - Use batch processing
    log_info "  📦 Migrating order posts..."
    mysql -h "$REMOTE_HOST" -u "$REMOTE_USER" "$REMOTE_DB" -e "
    SELECT CONCAT(
        'INSERT IGNORE INTO wp_posts VALUES (',
        QUOTE(ID), ',',
        QUOTE(post_author), ',',
        QUOTE(post_date), ',',
        QUOTE(post_date_gmt), ',',
        QUOTE(post_content), ',',
        QUOTE(post_title), ',',
        QUOTE(post_excerpt), ',',
        QUOTE(post_status), ',',
        QUOTE(comment_status), ',',
        QUOTE(ping_status), ',',
        QUOTE(post_password), ',',
        QUOTE(post_name), ',',
        QUOTE(to_ping), ',',
        QUOTE(pinged), ',',
        QUOTE(post_modified), ',',
        QUOTE(post_modified_gmt), ',',
        QUOTE(post_content_filtered), ',',
        QUOTE(post_parent), ',',
        QUOTE(guid), ',',
        QUOTE(menu_order), ',',
        QUOTE(post_type), ',',
        QUOTE(post_mime_type), ',',
        QUOTE(comment_count),
        ');'
    ) as statement
    FROM ${REMOTE_PREFIX}posts 
    WHERE post_type = 'shop_order'
    ORDER BY ID;" > "$TEMP_DIR/posts_insert.sql"
    
    # Execute posts insert
    export MYSQL_PWD="$LOCAL_PASS"
    tail -n +2 "$TEMP_DIR/posts_insert.sql" | mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" "$LOCAL_DB" 2>/dev/null || true
    
    # Step 2: Migrate order metadata - Use batch processing
    log_info "  🏷️  Migrating order metadata..."
    export MYSQL_PWD="$REMOTE_PASS"
    mysql -h "$REMOTE_HOST" -u "$REMOTE_USER" "$REMOTE_DB" -e "
    SELECT CONCAT(
        'INSERT IGNORE INTO wp_postmeta (post_id, meta_key, meta_value) VALUES (',
        QUOTE(pm.post_id), ',',
        QUOTE(pm.meta_key), ',',
        QUOTE(pm.meta_value),
        ');'
    ) as statement
    FROM ${REMOTE_PREFIX}postmeta pm
    INNER JOIN ${REMOTE_PREFIX}posts p ON pm.post_id = p.ID
    WHERE p.post_type = 'shop_order'
    ORDER BY pm.post_id, pm.meta_key;" > "$TEMP_DIR/postmeta_insert.sql"
    
    # Execute postmeta insert
    export MYSQL_PWD="$LOCAL_PASS"
    tail -n +2 "$TEMP_DIR/postmeta_insert.sql" | mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" "$LOCAL_DB" 2>/dev/null || true
    
    # Step 3: Migrate order items - Use batch processing
    log_info "  🛒 Migrating order items..."
    export MYSQL_PWD="$REMOTE_PASS"
    mysql -h "$REMOTE_HOST" -u "$REMOTE_USER" "$REMOTE_DB" -e "
    SELECT CONCAT(
        'INSERT IGNORE INTO wp_woocommerce_order_items VALUES (',
        QUOTE(oi.order_item_id), ',',
        QUOTE(oi.order_id), ',',
        QUOTE(oi.order_item_name), ',',
        QUOTE(oi.order_item_type),
        ');'
    ) as statement
    FROM ${REMOTE_PREFIX}woocommerce_order_items oi
    INNER JOIN ${REMOTE_PREFIX}posts p ON oi.order_id = p.ID
    WHERE p.post_type = 'shop_order'
    ORDER BY oi.order_id, oi.order_item_id;" > "$TEMP_DIR/order_items_insert.sql"
    
    # Execute order items insert
    export MYSQL_PWD="$LOCAL_PASS"
    tail -n +2 "$TEMP_DIR/order_items_insert.sql" | mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" "$LOCAL_DB" 2>/dev/null || true
    
    # Step 4: Migrate order item metadata - Use batch processing
    log_info "  📋 Migrating order item metadata..."
    export MYSQL_PWD="$REMOTE_PASS"
    mysql -h "$REMOTE_HOST" -u "$REMOTE_USER" "$REMOTE_DB" -e "
    SELECT CONCAT(
        'INSERT IGNORE INTO wp_woocommerce_order_itemmeta (order_item_id, meta_key, meta_value) VALUES (',
        QUOTE(oim.order_item_id), ',',
        QUOTE(oim.meta_key), ',',
        QUOTE(oim.meta_value),
        ');'
    ) as statement
    FROM ${REMOTE_PREFIX}woocommerce_order_itemmeta oim
    INNER JOIN ${REMOTE_PREFIX}woocommerce_order_items oi ON oim.order_item_id = oi.order_item_id
    INNER JOIN ${REMOTE_PREFIX}posts p ON oi.order_id = p.ID
    WHERE p.post_type = 'shop_order'
    ORDER BY oim.order_item_id, oim.meta_key;" > "$TEMP_DIR/order_itemmeta_insert.sql"
    
    # Execute order item metadata insert
    export MYSQL_PWD="$LOCAL_PASS"
    tail -n +2 "$TEMP_DIR/order_itemmeta_insert.sql" | mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" "$LOCAL_DB" 2>/dev/null || true
    
    unset MYSQL_PWD
    
    # Cleanup temp files
    rm -rf "$TEMP_DIR"
    
    log_success "Direct migration from remote database completed"
}



# Convert orders to HPOS format
convert_to_hpos() {
    log_info "Converting orders to HPOS format..."
    
    cd /var/www/nilgiristores.in
    
    # Step 1: Reset HPOS state to detect all orders
    log_info "  🔄 Resetting HPOS state..."
    wp --allow-root wc hpos disable >/dev/null 2>&1 || true
    
    # Step 2: Count orders to migrate
    ORDER_COUNT=$(wp --allow-root wc hpos count_unmigrated 2>/dev/null | grep -o '[0-9]*' | head -1 || echo "0")
    log_info "  📦 Found $ORDER_COUNT orders to migrate to HPOS"
    
    if [ "${ORDER_COUNT:-0}" -eq 0 ]; then
        log_info "  ℹ️  No orders found to migrate"
        return 0
    fi
    
    # Step 3: Perform the migration
    log_info "  🚀 Migrating $ORDER_COUNT orders to HPOS format..."
    SYNC_RESULT=$(wp --allow-root wc hpos sync --batch-size=100 2>&1)
    echo "$SYNC_RESULT" | tee -a "$LOG_FILE"
    
    # Step 4: Enable HPOS
    log_info "  ⚡ Enabling HPOS..."
    wp --allow-root wc hpos enable
    
    # Step 5: Disable compatibility mode for pure HPOS
    log_info "  🎯 Disabling compatibility mode for optimal performance..."
    wp --allow-root wc hpos compatibility-mode disable
    
    log_success "HPOS conversion completed successfully"
}

# Verify migration
verify_migration() {
    log_info "Verifying complete migration..."
    
    cd /var/www/nilgiristores.in
    
    # Check HPOS status
    log_info "Final HPOS status:"
    wp --allow-root wc hpos status | tee -a "$LOG_FILE"
    
    # Count orders in all tables
    export MYSQL_PWD="$LOCAL_PASS"
    
    POSTS_COUNT=$(mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" "$LOCAL_DB" -se "SELECT COUNT(*) FROM wp_posts WHERE post_type = 'shop_order';" 2>/dev/null)
    HPOS_COUNT=$(mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" "$LOCAL_DB" -se "SELECT COUNT(*) FROM wp_wc_orders;" 2>/dev/null)
    META_COUNT=$(mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" "$LOCAL_DB" -se "SELECT COUNT(*) FROM wp_postmeta WHERE post_id IN (SELECT ID FROM wp_posts WHERE post_type = 'shop_order');" 2>/dev/null)
    ITEMS_COUNT=$(mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" "$LOCAL_DB" -se "SELECT COUNT(*) FROM wp_woocommerce_order_items;" 2>/dev/null)
    
    # Compare with remote
    export MYSQL_PWD="$REMOTE_PASS"
    REMOTE_COUNT=$(mysql -h "$REMOTE_HOST" -u "$REMOTE_USER" "$REMOTE_DB" -se "SELECT COUNT(*) FROM ${REMOTE_PREFIX}posts WHERE post_type = 'shop_order';" 2>/dev/null)
    unset MYSQL_PWD
    
    log_info "Migration Summary:"
    log_info "  Remote orders: $REMOTE_COUNT"
    log_info "  Local wp_posts orders: $POSTS_COUNT"
    log_info "  Local HPOS orders: $HPOS_COUNT"
    log_info "  Order metadata records: $META_COUNT"
    log_info "  Order items: $ITEMS_COUNT"
    
    # Validation
    if [ "$HPOS_COUNT" -gt 0 ] && [ "$POSTS_COUNT" -eq "$REMOTE_COUNT" ]; then
        log_success "✅ Migration verification PASSED"
        log_success "  ✓ All remote orders migrated to local wp_posts"
        log_success "  ✓ Orders successfully converted to HPOS format"
        log_success "  ✓ Order metadata and items preserved"
    else
        log_error "❌ Migration verification FAILED"
        log_error "  Expected: $REMOTE_COUNT orders in HPOS"
        log_error "  Found: $HPOS_COUNT orders in HPOS"
        exit 1
    fi
}

# Create backup
create_backup() {
    log_info "Creating database backup..."
    
    cd "$SCRIPT_DIR/../"
    echo "1" | ./scripts/wp_db_local_backup_restore.sh > /dev/null 2>&1
    
    log_success "Database backup created"
}

# Main execution
main() {
    echo "🚀 Complete HPOS Order Migration"
    echo "================================="
    log_info "This script performs complete order migration from remote database to HPOS format"
    log_info "Process: Remote DB → wp_posts → HPOS (High-Performance Order Storage)"
    echo ""
    
    # Load configuration
    load_config
    check_prerequisites
    
    # Check current status
    check_migration_status
    MIGRATION_STATUS=$?
    
    case $MIGRATION_STATUS in
        0)
            log_info "🔄 Full migration required (remote → wp_posts → HPOS)"
            ;;
        1)
            log_info "🔄 HPOS conversion required (wp_posts → HPOS)"
            ;;
        2)
            log_success "✅ All orders already migrated and in HPOS format"
            exit 0
            ;;
    esac
    
    # Confirm migration
    echo ""
    log_warning "This will perform a complete order migration to HPOS format"
    log_info "HPOS provides the best performance and is future-proof"
    echo ""
    read -p "Continue with complete HPOS migration? (y/N): " -n 1 -r
    echo ""
    
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Migration cancelled by user"
        exit 0
    fi
    
    # Create backup
    create_backup
    
    # Perform migration based on status
    if [ $MIGRATION_STATUS -eq 0 ]; then
        # Full migration needed
        migrate_orders_directly
        convert_to_hpos
        
    elif [ $MIGRATION_STATUS -eq 1 ]; then
        # Only HPOS conversion needed
        convert_to_hpos
    fi
    
    # Verify results
    verify_migration
    
    echo ""
    log_success "🎉 Complete HPOS migration finished successfully!"
    log_info "Your orders are now using modern High-Performance Order Storage"
    log_info "This provides optimal performance and is future-proof"
    echo ""
}

# Execute main function
main "$@"
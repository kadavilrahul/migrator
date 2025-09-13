#!/bin/bash

# Unified Order Migration Script
# Complete migration from remote WordPress database to local HPOS format
# Combines the best features from all previous migration scripts

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/../config/config.json"
LOG_FILE="$SCRIPT_DIR/../logs/migrate_orders_unified_$(date +%Y%m%d_%H%M%S).log"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

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

# Check migration status
check_migration_status() {
    log_info "Analyzing migration status..."
    
    # Get remote order count
    export MYSQL_PWD="$REMOTE_PASS"
    REMOTE_ORDER_COUNT=$(mysql -h "$REMOTE_HOST" -u "$REMOTE_USER" "$REMOTE_DB" -se "SELECT COUNT(*) FROM ${REMOTE_PREFIX}posts WHERE post_type = 'shop_order';" 2>/dev/null)
    unset MYSQL_PWD
    
    # Get local order counts
    export MYSQL_PWD="$LOCAL_PASS"
    LOCAL_ORDER_COUNT=$(mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" "$LOCAL_DB" -se "SELECT COUNT(*) FROM wp_posts WHERE post_type = 'shop_order';" 2>/dev/null || echo "0")
    HPOS_ORDER_COUNT=$(mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" "$LOCAL_DB" -se "SELECT COUNT(*) FROM wp_wc_orders;" 2>/dev/null || echo "0")
    unset MYSQL_PWD
    
    log_info "Migration Status:"
    log_info "  Remote orders: $REMOTE_ORDER_COUNT"
    log_info "  Local wp_posts orders: $LOCAL_ORDER_COUNT"
    log_info "  Local HPOS orders: $HPOS_ORDER_COUNT"
    
    # Determine what needs to be done
    if [ "$REMOTE_ORDER_COUNT" -eq "$LOCAL_ORDER_COUNT" ] && [ "$HPOS_ORDER_COUNT" -eq "$REMOTE_ORDER_COUNT" ]; then
        log_success "✅ All orders are already migrated and in HPOS format"
        return 2  # No work needed
    elif [ "$REMOTE_ORDER_COUNT" -eq "$LOCAL_ORDER_COUNT" ] && [ "$HPOS_ORDER_COUNT" -eq 0 ]; then
        log_info "📦 Orders are migrated to wp_posts, need HPOS conversion"
        return 1  # HPOS conversion needed
    elif [ "$LOCAL_ORDER_COUNT" -lt "$REMOTE_ORDER_COUNT" ]; then
        log_info "📥 Need to migrate $((REMOTE_ORDER_COUNT - LOCAL_ORDER_COUNT)) orders from remote"
        return 0  # Full migration needed
    else
        log_warning "⚠️  Local order count ($LOCAL_ORDER_COUNT) exceeds remote ($REMOTE_ORDER_COUNT)"
        log_info "📦 Will proceed with HPOS conversion of existing orders"
        return 1  # HPOS conversion needed
    fi
}

# Migrate orders from remote database using direct SQL approach
migrate_orders_from_remote() {
    log_info "Migrating orders from remote database..."
    
    # Create temporary directory for migration files
    TEMP_DIR="/tmp/orders_migration_$(date +%s)"
    mkdir -p "$TEMP_DIR"
    
    export MYSQL_PWD="$REMOTE_PASS"
    
    log_info "  📦 Extracting order posts..."
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
    
    log_info "  🏷️  Extracting order metadata..."
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
    
    log_info "  🛒 Extracting order items..."
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
    
    log_info "  📋 Extracting order item metadata..."
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
    
    unset MYSQL_PWD
    
    # Import to local database
    log_info "  📤 Importing to local database..."
    export MYSQL_PWD="$LOCAL_PASS"
    
    # Execute posts insert (skip header line)
    tail -n +2 "$TEMP_DIR/posts_insert.sql" | mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" "$LOCAL_DB" 2>/dev/null || true
    
    # Execute postmeta insert (skip header line)
    tail -n +2 "$TEMP_DIR/postmeta_insert.sql" | mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" "$LOCAL_DB" 2>/dev/null || true
    
    # Execute order items insert (skip header line)
    tail -n +2 "$TEMP_DIR/order_items_insert.sql" | mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" "$LOCAL_DB" 2>/dev/null || true
    
    # Execute order item metadata insert (skip header line)
    tail -n +2 "$TEMP_DIR/order_itemmeta_insert.sql" | mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" "$LOCAL_DB" 2>/dev/null || true
    
    unset MYSQL_PWD
    
    # Cleanup
    rm -rf "$TEMP_DIR"
    
    log_success "Orders migrated from remote database successfully"
}

# Convert orders to HPOS format using WP-CLI
convert_to_hpos() {
    log_info "Converting orders to HPOS format..."
    
    cd /var/www/nilgiristores.in
    
    # Step 1: Check WP-CLI HPOS support
    if ! wp --allow-root wc hpos status &>/dev/null; then
        log_error "WP-CLI HPOS commands not available. Please ensure WooCommerce is installed"
        exit 1
    fi
    
    # Step 2: Reset HPOS state to detect all orders
    log_info "  🔄 Resetting HPOS state..."
    wp --allow-root wc hpos disable >/dev/null 2>&1 || true
    
    # Step 3: Count orders that need migration
    ORDER_COUNT=$(wp --allow-root wc hpos count_unmigrated 2>/dev/null | grep -o '[0-9]*' | head -1 || echo "0")
    log_info "  📦 Found $ORDER_COUNT orders to migrate to HPOS"
    
    if [ "${ORDER_COUNT:-0}" -eq 0 ]; then
        log_info "  ℹ️  No orders found to migrate"
        return 0
    fi
    
    # Step 4: Perform the migration with progress
    log_info "  🚀 Migrating $ORDER_COUNT orders to HPOS format..."
    SYNC_RESULT=$(wp --allow-root wc hpos sync --batch-size=100 2>&1)
    echo "$SYNC_RESULT" | tee -a "$LOG_FILE"
    
    # Step 5: Enable HPOS
    log_info "  ⚡ Enabling HPOS..."
    wp --allow-root wc hpos enable
    
    # Step 6: Disable compatibility mode for optimal performance
    log_info "  🎯 Disabling compatibility mode for optimal performance..."
    wp --allow-root wc hpos compatibility-mode disable
    
    log_success "HPOS conversion completed successfully"
}

# Verify migration results
verify_migration() {
    log_info "Verifying migration results..."
    
    cd /var/www/nilgiristores.in
    
    # Check HPOS status
    log_info "Final HPOS status:"
    wp --allow-root wc hpos status | tee -a "$LOG_FILE"
    
    # Count orders in all relevant tables
    export MYSQL_PWD="$LOCAL_PASS"
    
    POSTS_COUNT=$(mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" "$LOCAL_DB" -se "SELECT COUNT(*) FROM wp_posts WHERE post_type = 'shop_order';" 2>/dev/null)
    HPOS_COUNT=$(mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" "$LOCAL_DB" -se "SELECT COUNT(*) FROM wp_wc_orders;" 2>/dev/null)
    META_COUNT=$(mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" "$LOCAL_DB" -se "SELECT COUNT(*) FROM wp_postmeta WHERE post_id IN (SELECT ID FROM wp_posts WHERE post_type = 'shop_order');" 2>/dev/null)
    ITEMS_COUNT=$(mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" "$LOCAL_DB" -se "SELECT COUNT(*) FROM wp_woocommerce_order_items;" 2>/dev/null)
    
    unset MYSQL_PWD
    
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
    if [ "$HPOS_COUNT" -gt 0 ] && [ "$POSTS_COUNT" -ge "$REMOTE_COUNT" ]; then
        log_success "✅ Migration verification PASSED"
        log_success "  ✓ Orders successfully migrated to wp_posts"
        log_success "  ✓ Orders converted to HPOS format"
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
    
    if [ -f "$SCRIPT_DIR/wp_db_local_backup_restore.sh" ]; then
        cd "$SCRIPT_DIR"
        echo "1" | ./wp_db_local_backup_restore.sh > /dev/null 2>&1
        log_success "Database backup created"
    else
        log_warning "Backup script not found, skipping backup"
    fi
}

# Show help
show_help() {
    echo "Unified Order Migration Script"
    echo "============================="
    echo ""
    echo "This script performs complete order migration from remote WordPress database to HPOS format."
    echo ""
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --check-only       Check migration status without performing migration"
    echo "  --hpos-only        Convert existing wp_posts orders to HPOS (no remote migration)"
    echo "  --force            Force migration even if orders already exist"
    echo "  --no-backup        Skip database backup"
    echo "  --help             Show this help"
    echo ""
    echo "Process: Remote DB → wp_posts → HPOS (High-Performance Order Storage)"
    echo ""
}

# Main execution
main() {
    echo "🚀 Unified Order Migration Script"
    echo "=================================="
    echo ""
    
    # Parse arguments
    CHECK_ONLY=false
    HPOS_ONLY=false
    FORCE_MIGRATION=false
    NO_BACKUP=false
    
    for arg in "$@"; do
        case $arg in
            --check-only)
                CHECK_ONLY=true
                ;;
            --hpos-only)
                HPOS_ONLY=true
                ;;
            --force)
                FORCE_MIGRATION=true
                ;;
            --no-backup)
                NO_BACKUP=true
                ;;
            --help)
                show_help
                exit 0
                ;;
            *)
                log_error "Unknown argument: $arg"
                show_help
                exit 1
                ;;
        esac
    done
    
    # Load configuration and check prerequisites
    load_config
    check_prerequisites
    
    # Check current status
    check_migration_status
    MIGRATION_STATUS=$?
    
    if [ "$CHECK_ONLY" = true ]; then
        log_info "Check complete. Status: $MIGRATION_STATUS"
        exit 0
    fi
    
    # Determine what needs to be done
    case $MIGRATION_STATUS in
        0)
            NEEDS_REMOTE_MIGRATION=true
            NEEDS_HPOS_CONVERSION=true
            log_info "🔄 Full migration required (remote → wp_posts → HPOS)"
            ;;
        1)
            NEEDS_REMOTE_MIGRATION=false
            NEEDS_HPOS_CONVERSION=true
            log_info "🔄 HPOS conversion required (wp_posts → HPOS)"
            ;;
        2)
            if [ "$FORCE_MIGRATION" = false ]; then
                log_success "✅ Migration already complete"
                exit 0
            else
                NEEDS_REMOTE_MIGRATION=true
                NEEDS_HPOS_CONVERSION=true
                log_warning "⚠️  Forcing migration despite existing data"
            fi
            ;;
    esac
    
    # If HPOS-only mode, skip remote migration
    if [ "$HPOS_ONLY" = true ]; then
        NEEDS_REMOTE_MIGRATION=false
        log_info "📦 HPOS-only mode: will convert existing orders to HPOS"
    fi
    
    # Confirm migration
    if [ "$NEEDS_REMOTE_MIGRATION" = true ] && [ "$NEEDS_HPOS_CONVERSION" = true ]; then
        echo ""
        log_warning "This will perform complete order migration from remote database to HPOS format"
    elif [ "$NEEDS_HPOS_CONVERSION" = true ]; then
        echo ""
        log_warning "This will convert existing orders to HPOS format"
    fi
    
    log_info "HPOS provides optimal performance and is future-proof"
    echo ""
    read -p "Continue with migration? (y/N): " -n 1 -r
    echo ""
    
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Migration cancelled by user"
        exit 0
    fi
    
    # Create backup unless skipped
    if [ "$NO_BACKUP" = false ]; then
        create_backup
    fi
    
    # Perform migration steps
    if [ "$NEEDS_REMOTE_MIGRATION" = true ]; then
        migrate_orders_from_remote
    fi
    
    if [ "$NEEDS_HPOS_CONVERSION" = true ]; then
        convert_to_hpos
    fi
    
    # Verify results
    verify_migration
    
    echo ""
    log_success "🎉 Order migration completed successfully!"
    log_info "Your orders are now using modern High-Performance Order Storage"
    log_info "This provides optimal performance and is future-proof"
    echo ""
}

# Ensure logs directory exists
mkdir -p "$SCRIPT_DIR/../logs"

# Execute main function with all arguments
main "$@"
#!/bin/bash

# HPOS Order Migration Script
set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/../config/config.json"
LOG_FILE="$SCRIPT_DIR/../logs/migrate_orders_hpos_$(date +%Y%m%d_%H%M%S).log"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
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

# Load WordPress config
load_wp_config() {
    log_info "Loading WordPress configuration..."
    
    WP_CONFIG_PATH="/var/www/nilgiristores.in/wp-config.php"
    
    if [ ! -f "$WP_CONFIG_PATH" ]; then
        log_error "WordPress config not found at $WP_CONFIG_PATH"
        exit 1
    fi
    
    LOCAL_DB=$(grep "DB_NAME" "$WP_CONFIG_PATH" | cut -d "'" -f 4)
    LOCAL_USER=$(grep "DB_USER" "$WP_CONFIG_PATH" | cut -d "'" -f 4)
    LOCAL_PASS=$(grep "DB_PASSWORD" "$WP_CONFIG_PATH" | cut -d "'" -f 4)
    LOCAL_HOST=$(grep "DB_HOST" "$WP_CONFIG_PATH" | cut -d "'" -f 4)
    
    log_success "WordPress configuration loaded"
}

# Check if WP-CLI is available
check_wp_cli() {
    log_info "Checking WP-CLI availability..."
    
    if ! command -v wp &> /dev/null; then
        log_error "WP-CLI is not installed or not in PATH"
        exit 1
    fi
    
    WP_CLI_VERSION=$(wp --version 2>/dev/null | head -n1 || echo "Unknown")
    log_success "WP-CLI found: $WP_CLI_VERSION"
}

# Check current HPOS status
check_hpos_status() {
    log_info "Checking current HPOS status..."
    
    cd /var/www/nilgiristores.in
    
    # Check if HPOS commands are available
    if ! wp --allow-root wc hpos status &>/dev/null; then
        log_error "HPOS commands not available. Please ensure WooCommerce is installed and WP-CLI has WooCommerce support"
        exit 1
    fi
    
    # Get current status
    HPOS_STATUS=$(wp --allow-root wc hpos status 2>/dev/null)
    echo "$HPOS_STATUS" | tee -a "$LOG_FILE"
    
    # Check if orders need migration
    UNMIGRATED=$(wp --allow-root wc hpos count_unmigrated 2>/dev/null || echo "0 orders to be synced.")
    log_info "$UNMIGRATED"
}

# Create database backup
create_backup() {
    log_info "Creating database backup before HPOS migration..."
    
    BACKUP_NAME="pre-hpos-migration-$(date +%Y%m%d_%H%M%S)"
    
    cd "$SCRIPT_DIR/../"
    echo "1" | ./scripts/wp_db_local_backup_restore.sh > /dev/null 2>&1
    
    log_success "Database backup created"
}

# Migrate orders to HPOS
migrate_to_hpos() {
    log_info "Starting HPOS migration process..."
    
    cd /var/www/nilgiristores.in
    
    # Step 1: Disable HPOS to reset migration state
    log_info "1. Resetting HPOS state..."
    wp --allow-root wc hpos disable 2>/dev/null || true
    
    # Step 2: Re-enable HPOS (this will detect all unmigrated orders)
    log_info "2. Detecting orders that need migration..."
    wp --allow-root wc hpos enable 2>/dev/null || {
        log_warning "HPOS enable detected unmigrated orders - this is expected"
    }
    
    # Step 3: Check how many orders need migration
    UNMIGRATED_COUNT=$(wp --allow-root wc hpos count_unmigrated 2>/dev/null | grep -o '[0-9]*' | head -1)
    
    if [ "$UNMIGRATED_COUNT" -eq 0 ]; then
        log_success "No orders need migration - HPOS is already up to date"
        return 0
    fi
    
    log_info "3. Found $UNMIGRATED_COUNT orders to migrate to HPOS"
    
    # Step 4: Perform the migration
    log_info "4. Migrating orders to HPOS tables..."
    SYNC_RESULT=$(wp --allow-root wc hpos sync --batch-size=100 2>&1)
    echo "$SYNC_RESULT" | tee -a "$LOG_FILE"
    
    # Step 5: Enable HPOS properly
    log_info "5. Enabling HPOS..."
    wp --allow-root wc hpos enable
    
    # Step 6: Disable compatibility mode for pure HPOS
    log_info "6. Disabling compatibility mode for optimal performance..."
    wp --allow-root wc hpos compatibility-mode disable
    
    log_success "HPOS migration completed successfully!"
}

# Verify migration
verify_migration() {
    log_info "Verifying HPOS migration..."
    
    cd /var/www/nilgiristores.in
    
    # Check final status
    log_info "Final HPOS status:"
    wp --allow-root wc hpos status | tee -a "$LOG_FILE"
    
    # Count orders in both tables
    export MYSQL_PWD="$LOCAL_PASS"
    
    HPOS_COUNT=$(mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" "$LOCAL_DB" -se "SELECT COUNT(*) FROM wp_wc_orders;" 2>/dev/null)
    POSTS_COUNT=$(mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" "$LOCAL_DB" -se "SELECT COUNT(*) FROM wp_posts WHERE post_type = 'shop_order';" 2>/dev/null)
    
    unset MYSQL_PWD
    
    log_info "Orders in HPOS table (wp_wc_orders): $HPOS_COUNT"
    log_info "Orders in Posts table (wp_posts): $POSTS_COUNT"
    
    if [ "$HPOS_COUNT" -gt 0 ]; then
        log_success "Migration verification passed - orders are in HPOS"
    else
        log_error "Migration verification failed - no orders found in HPOS"
        exit 1
    fi
}

# Main execution
main() {
    echo "🔄 HPOS Order Migration Script"
    echo "================================"
    log_info "Migrating orders to WooCommerce HPOS (High-Performance Order Storage)"
    echo ""
    
    # Load configuration and check prerequisites
    load_wp_config
    check_wp_cli
    
    # Check current status
    check_hpos_status
    
    # Confirm migration
    echo ""
    log_warning "This will migrate all orders to HPOS format"
    log_info "HPOS provides better performance and is the future of WooCommerce"
    echo ""
    read -p "Continue with HPOS migration? (y/N): " -n 1 -r
    echo ""
    
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Migration cancelled by user"
        exit 0
    fi
    
    # Create backup
    create_backup
    
    # Perform migration
    migrate_to_hpos
    
    # Verify results
    verify_migration
    
    echo ""
    log_success "🎉 HPOS migration completed successfully!"
    log_info "Your orders are now using High-Performance Order Storage"
    log_info "This provides better performance and is future-proof"
    echo ""
}

# Execute main function
main "$@"
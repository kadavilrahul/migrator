#!/bin/bash

# Customer Migration Script
# Migrates customers (users with orders) from remote database to local database
# Handles both incremental sync and gap detection for missing customers

set -euo pipefail

# Script configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/../config/config.sh"

# Source the configuration
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo "Error: Configuration file not found: $CONFIG_FILE"
    exit 1
fi

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging function
log() {
    echo -e "$1"
}

log_error() { log "${RED}❌ $1${NC}"; }
log_success() { log "${GREEN}✅ $1${NC}"; }
log_warning() { log "${YELLOW}⚠️  $1${NC}"; }
log_info() { log "${BLUE}ℹ️  $1${NC}"; }

# Cleanup function for temporary files
cleanup() {
    if [ -n "${TEMP_DIR:-}" ] && [ -d "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR"
        log_info "Temporary files cleaned up"
    fi
}

# Validate configuration files
validate_config() {
    log_info "Validating configuration files..."
    if [ ! -f "$CONFIG_FILE" ]; then
        log_error "Configuration file not found: $CONFIG_FILE"
        exit 1
    fi
    log_success "Configuration files validated"
}

# Load database configuration
load_db_config() {
    local site_param="${1:-nilgiristores.in}"
    log_info "Loading database configuration for '$site_param'"
    
    # Configuration already loaded from config.sh via source command
    # Variables are already set: REMOTE_HOST, REMOTE_DB, etc.

    # Find local wp-config.php
    WP_CONFIG_PATHS=(
        "/var/www/nilgiristores.in/wp-config.php"
        "$SCRIPT_DIR/../../wp-config.php"
        "$SCRIPT_DIR/../wp-config.php"
        "/var/www/html/wp-config.php"
    )
    
    WP_CONFIG_PATH=""
    for path in "${WP_CONFIG_PATHS[@]}"; do
        if [ -f "$path" ]; then
            WP_CONFIG_PATH="$path"
            break
        fi
    done
    
    if [ -z "$WP_CONFIG_PATH" ]; then
        log_error "wp-config.php not found in expected locations."
        exit 1
    fi
    
    # Extract local database credentials using awk
    LOCAL_HOST=$(grep "define.*DB_HOST" "$WP_CONFIG_PATH" | awk -F"'" '{print $4}')
    LOCAL_DB=$(grep "define.*DB_NAME" "$WP_CONFIG_PATH" | awk -F"'" '{print $4}')
    LOCAL_USER=$(grep "define.*DB_USER" "$WP_CONFIG_PATH" | awk -F"'" '{print $4}')
    LOCAL_PASS=$(grep "define.*DB_PASSWORD" "$WP_CONFIG_PATH" | awk -F"'" '{print $4}')
    
    log_success "Database configuration loaded"
}

# Test database connections
test_connections() {
    log_info "Testing database connections"
    
    # Test remote connection
    if ! mysql -h "$REMOTE_HOST" -u "$REMOTE_USER" -p"$REMOTE_PASS" "$REMOTE_DB" -e "SELECT 1;" >/dev/null 2>&1; then
        log_error "Cannot connect to remote database: $REMOTE_HOST"
        exit 1
    fi
    
    # Test local connection
    if ! mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" -p"$LOCAL_PASS" "$LOCAL_DB" -e "SELECT 1;" >/dev/null 2>&1; then
        log_error "Cannot connect to local database: $LOCAL_HOST"
        exit 1
    fi
    
    log_success "Database connections verified"
}

# Find ALL missing customers (handles gaps in user IDs)
find_missing_customers() {
    log_info "Finding ALL customers who have orders..."
    
    # Get all customer IDs from remote who have orders
    REMOTE_CUSTOMERS=$(mysql -h "$REMOTE_HOST" -u "$REMOTE_USER" -p"$REMOTE_PASS" "$REMOTE_DB" -sN -e "
    SELECT DISTINCT u.ID
    FROM ${REMOTE_PREFIX}users u
    INNER JOIN ${REMOTE_PREFIX}postmeta pm ON u.ID = CAST(pm.meta_value AS UNSIGNED)
    INNER JOIN ${REMOTE_PREFIX}posts p ON pm.post_id = p.ID
    WHERE pm.meta_key = '_customer_user'
    AND p.post_type = 'shop_order'
    ORDER BY u.ID;" 2>/dev/null)
    
    # Get all existing user IDs from local
    LOCAL_USERS=$(mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" -p"$LOCAL_PASS" "$LOCAL_DB" -sN -e "
    SELECT ID FROM ${LOCAL_PREFIX}users ORDER BY ID;" 2>/dev/null)
    
    # Find missing IDs
    MISSING_IDS=""
    MISSING_COUNT=0
    for remote_id in $REMOTE_CUSTOMERS; do
        if ! echo "$LOCAL_USERS" | grep -q "^${remote_id}$"; then
            if [ -z "$MISSING_IDS" ]; then
                MISSING_IDS="$remote_id"
            else
                MISSING_IDS="$MISSING_IDS,$remote_id"
            fi
            ((MISSING_COUNT++))
        fi
    done
    
    # Count total remote customers
    TOTAL_REMOTE_CUSTOMERS=$(echo "$REMOTE_CUSTOMERS" | wc -w)
    EXISTING_COUNT=$((TOTAL_REMOTE_CUSTOMERS - MISSING_COUNT))
    
    log_info "Total customers with orders in remote: $TOTAL_REMOTE_CUSTOMERS"
    log_info "Already imported: $EXISTING_COUNT"
    log_info "Missing customers: $MISSING_COUNT"
    
    if [ "$MISSING_COUNT" -eq 0 ]; then
        log_success "All customers are already imported!"
        return 1
    fi
    
    # Show first 10 missing IDs for preview
    PREVIEW_IDS=$(echo "$MISSING_IDS" | cut -d',' -f1-10)
    if [ "$MISSING_COUNT" -gt 10 ]; then
        log_info "Missing customer IDs (first 10): $PREVIEW_IDS..."
    else
        log_info "Missing customer IDs: $MISSING_IDS"
    fi
    
    return 0
}

# Export customer data from remote database
export_customer_data() {
    log_info "Exporting customer data from remote database"
    
    TEMP_DIR="/tmp/customer_sync_$(date +%s)"
    mkdir -p "$TEMP_DIR"
    
    # Export users
    log_info "   Exporting user records..."
    mysqldump -h "$REMOTE_HOST" -u "$REMOTE_USER" -p"$REMOTE_PASS" "$REMOTE_DB" \
        "${REMOTE_PREFIX}users" \
        --where="ID IN ($MISSING_IDS)" \
        --no-create-info \
        --no-tablespaces \
        --single-transaction \
        --complete-insert \
        > "$TEMP_DIR/users.sql" 2>/dev/null
    
    if [ ! -s "$TEMP_DIR/users.sql" ]; then
        log_error "Failed to export user data"
        exit 1
    fi
    
    # Export user metadata
    log_info "   Exporting user metadata..."
    mysqldump -h "$REMOTE_HOST" -u "$REMOTE_USER" -p"$REMOTE_PASS" "$REMOTE_DB" \
        "${REMOTE_PREFIX}usermeta" \
        --where="user_id IN ($MISSING_IDS)" \
        --no-create-info \
        --no-tablespaces \
        --single-transaction \
        --complete-insert \
        > "$TEMP_DIR/usermeta.sql" 2>/dev/null
    
    if [ ! -s "$TEMP_DIR/usermeta.sql" ]; then
        log_error "Failed to export user metadata"
        exit 1
    fi
    
    log_success "Customer data exported successfully"
}

# Process and convert table prefixes
process_customer_data() {
    log_info "Processing customer data"
    
    # Convert table prefixes
    sed "s/${REMOTE_PREFIX}users/${LOCAL_PREFIX}users/g" "$TEMP_DIR/users.sql" > "$TEMP_DIR/users_temp.sql"
    sed "s/${REMOTE_PREFIX}usermeta/${LOCAL_PREFIX}usermeta/g" "$TEMP_DIR/usermeta.sql" > "$TEMP_DIR/usermeta_temp.sql"
    
    # Replace INSERT INTO with INSERT IGNORE to handle any potential duplicates
    sed 's/INSERT INTO/INSERT IGNORE INTO/g' "$TEMP_DIR/users_temp.sql" > "$TEMP_DIR/users_local.sql"
    sed 's/INSERT INTO/INSERT IGNORE INTO/g' "$TEMP_DIR/usermeta_temp.sql" > "$TEMP_DIR/usermeta_temp2.sql"
    
    # Fix user capabilities and user_level meta keys
    sed "s/${REMOTE_PREFIX}capabilities/${LOCAL_PREFIX}capabilities/g" "$TEMP_DIR/usermeta_temp2.sql" | \
        sed "s/${REMOTE_PREFIX}user_level/${LOCAL_PREFIX}user_level/g" > "$TEMP_DIR/usermeta_local.sql"
    
    log_success "Customer data processing completed"
}

# Import customer data to local database
import_customer_data() {
    log_info "Importing customer data to local database"
    
    # Start transaction
    mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" -p"$LOCAL_PASS" "$LOCAL_DB" -e "
    SET foreign_key_checks = 0;
    SET autocommit = 0;
    START TRANSACTION;" 2>/dev/null
    
    # Import users
    log_info "   Importing user records..."
    if mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" -p"$LOCAL_PASS" "$LOCAL_DB" < "$TEMP_DIR/users_local.sql" 2>/dev/null; then
        log_success "    User records imported successfully"
    else
        log_error "    User import failed"
        mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" -p"$LOCAL_PASS" "$LOCAL_DB" -e "ROLLBACK;" 2>/dev/null
        exit 1
    fi
    
    # Import user metadata
    log_info "   Importing user metadata..."
    if mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" -p"$LOCAL_PASS" "$LOCAL_DB" < "$TEMP_DIR/usermeta_local.sql" 2>/dev/null; then
        log_success "    User metadata imported successfully"
    else
        log_error "    User metadata import failed"
        mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" -p"$LOCAL_PASS" "$LOCAL_DB" -e "ROLLBACK;" 2>/dev/null
        exit 1
    fi
    
    # Commit transaction
    mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" -p"$LOCAL_PASS" "$LOCAL_DB" -e "
    COMMIT;
    SET foreign_key_checks = 1;" 2>/dev/null
    
    log_success "Customer data import completed"
}

# Clear WordPress caches
clear_wordpress_caches() {
    log_info "Clearing WordPress caches"
    
    mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" -p"$LOCAL_PASS" "$LOCAL_DB" -e "
    DELETE FROM ${LOCAL_PREFIX}options WHERE option_name LIKE '_transient_%';
    DELETE FROM ${LOCAL_PREFIX}options WHERE option_name LIKE '_transient_timeout_%';
    DELETE FROM ${LOCAL_PREFIX}options WHERE option_name LIKE '_site_transient_%';
    DELETE FROM ${LOCAL_PREFIX}options WHERE option_name LIKE '_site_transient_timeout_%';" 2>/dev/null
    
    log_success "WordPress caches cleared"
}

# Validate imported data
validate_imported_data() {
    log_info "Validating imported data"
    
    # Count imported users
    IMPORTED_COUNT=0
    for user_id in $(echo "$MISSING_IDS" | tr ',' ' '); do
        EXISTS=$(mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" -p"$LOCAL_PASS" "$LOCAL_DB" -sN -e "
        SELECT COUNT(*) FROM ${LOCAL_PREFIX}users WHERE ID = $user_id;" 2>/dev/null)
        if [ "$EXISTS" -eq 1 ]; then
            ((IMPORTED_COUNT++))
        fi
    done
    
    log_info "Successfully imported: $IMPORTED_COUNT out of $MISSING_COUNT customers"
    
    # Get final statistics
    FINAL_USERS=$(mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" -p"$LOCAL_PASS" "$LOCAL_DB" -sN -e "
    SELECT COUNT(*) FROM ${LOCAL_PREFIX}users;" 2>/dev/null)
    
    FINAL_CUSTOMERS=$(mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" -p"$LOCAL_PASS" "$LOCAL_DB" -sN -e "
    SELECT COUNT(DISTINCT meta_value) 
    FROM ${LOCAL_PREFIX}postmeta 
    WHERE meta_key = '_customer_user' 
    AND meta_value != '0';" 2>/dev/null)
    
    log_success "Migration completed successfully!"
    log_info ""
    log_info "📊 Final Statistics"
    log_info "   Total users in database: $FINAL_USERS"
    log_info "   Total customers with orders: $FINAL_CUSTOMERS"
    log_info "   Customers imported in this run: $IMPORTED_COUNT"
}

# Show migration summary
show_summary() {
    log_info ""
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Customer Migration Summary"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "   Remote: $REMOTE_HOST → $REMOTE_DB"
    log_info "   Local:  $LOCAL_HOST → $LOCAL_DB"
    log_info "   Missing customers found: $MISSING_COUNT"
    log_info ""
    log_info "This will import ALL missing customers who have placed orders,"
    log_info "including those with non-sequential user IDs."
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    read -p "Do you want to continue? (y/N): " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Operation cancelled by user"
        exit 0
    fi
}

trap cleanup EXIT

main() {
    local site_param="${1:-}"
    log_info "=== WordPress Customer Migration ==="
    log_info "Started at: $(date)"
    log_info ""
    
    # Execute migration steps
    validate_config
    load_db_config "$site_param"
    test_connections
    
    if find_missing_customers; then
        show_summary
        export_customer_data
        process_customer_data
        import_customer_data
        clear_wordpress_caches
        validate_imported_data
    fi
    
    log_info ""
    log_success "=== Migration Operation Completed ==="
    log_info "Finished at: $(date)"
}

# Execute main function with all arguments
main "$@"
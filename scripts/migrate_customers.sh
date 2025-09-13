#!/bin/bash

# Customer Migration Script
# Migrates ONLY customers (users with orders or customer role) from remote database to local database

set -euo pipefail

# Script configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/../config/config.json"

# Shared functions for WordPress user management scripts

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
        log_info "Debug: Temporary files in $TEMP_DIR - keeping for debugging"
        # rm -rf "$TEMP_DIR"
        # log_info "Temporary files cleaned up"
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
    
    # Load remote database configuration from config.json
    REMOTE_HOST=$(jq -r ".migration.remote_database.host" "$CONFIG_FILE")
    REMOTE_DB=$(jq -r ".migration.remote_database.database" "$CONFIG_FILE")
    REMOTE_USER=$(jq -r ".migration.remote_database.username" "$CONFIG_FILE")
    REMOTE_PASS=$(jq -r ".migration.remote_database.password" "$CONFIG_FILE")
    REMOTE_PREFIX=$(jq -r ".migration.remote_database.table_prefix" "$CONFIG_FILE")

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

# Get the last local user ID
get_last_local_user_id() {
    log_info "Getting last local user ID"
    
    LAST_LOCAL_USER_ID=$(mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" -p"$LOCAL_PASS" "$LOCAL_DB" -se "SELECT COALESCE(MAX(ID), 0) FROM wp_users;" 2>/dev/null)
    
    log_info "Last local user ID: $LAST_LOCAL_USER_ID"
}

# Check for new customers in remote database
check_new_remote_users() {
    log_info "Checking for new customers in remote database"
    
    # Count customers only (users who have placed orders)
    NEW_USERS_COUNT=$(mysql -h "$REMOTE_HOST" -u "$REMOTE_USER" -p"$REMOTE_PASS" "$REMOTE_DB" -se "
    SELECT COUNT(DISTINCT u.ID) 
    FROM ${REMOTE_PREFIX}users u
    INNER JOIN ${REMOTE_PREFIX}postmeta pm ON u.ID = CAST(pm.meta_value AS UNSIGNED)
    INNER JOIN ${REMOTE_PREFIX}posts p ON pm.post_id = p.ID
    WHERE u.ID > $LAST_LOCAL_USER_ID 
    AND pm.meta_key = '_customer_user'
    AND p.post_type = 'shop_order';" 2>/dev/null)
    
    # Count customer metadata
    NEW_USERMETA_COUNT=$(mysql -h "$REMOTE_HOST" -u "$REMOTE_USER" -p"$REMOTE_PASS" "$REMOTE_DB" -se "
    SELECT COUNT(um.umeta_id)
    FROM ${REMOTE_PREFIX}usermeta um
    WHERE um.user_id IN (
        SELECT DISTINCT u.ID 
        FROM ${REMOTE_PREFIX}users u
        INNER JOIN ${REMOTE_PREFIX}postmeta pm ON u.ID = CAST(pm.meta_value AS UNSIGNED)
        INNER JOIN ${REMOTE_PREFIX}posts p ON pm.post_id = p.ID
        WHERE u.ID > $LAST_LOCAL_USER_ID 
        AND pm.meta_key = '_customer_user'
        AND p.post_type = 'shop_order'
    );" 2>/dev/null)
    
    log_info "New customers found: $NEW_USERS_COUNT"
    log_info "New customer metadata records: $NEW_USERMETA_COUNT"
    
    if [ "$NEW_USERS_COUNT" -eq 0 ]; then
        log_info "No new customers to sync."
        return 1
    fi
    
    log_success "New customers available for sync"
    return 0
}

# Display confirmation prompt for customer sync
show_sync_confirmation() {
    log_info "Customer Sync Operation Summary"
    log_info "   Remote: $REMOTE_HOST → $REMOTE_DB (${REMOTE_PREFIX})"
    log_info "   Local:  $LOCAL_HOST → $LOCAL_DB (wp_)"
    log_info "   New customers to sync: $NEW_USERS_COUNT"
    log_info "   New customer metadata records: $NEW_USERMETA_COUNT"
    log_info "   Starting from user ID: $((LAST_LOCAL_USER_ID + 1))"
    echo
    log_info "INFO: This will sync only CUSTOMERS (users with orders or customer role) without affecting existing users."
    echo
    read -p "Do you want to continue? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Operation cancelled by user"
        exit 0
    fi
}

# Extract new customer data from remote database
extract_new_user_data() {
    log_info "Extracting new customer data from remote database"
    
    TEMP_DIR="/tmp/customer_sync_$(date +%s)"
    mkdir -p "$TEMP_DIR"
    
    # Create customer WHERE clause for filtering (customers who placed orders)
    CUSTOMER_WHERE="ID > $LAST_LOCAL_USER_ID AND ID IN (
        SELECT DISTINCT u.ID 
        FROM ${REMOTE_PREFIX}users u
        INNER JOIN ${REMOTE_PREFIX}postmeta pm ON u.ID = CAST(pm.meta_value AS UNSIGNED)
        INNER JOIN ${REMOTE_PREFIX}posts p ON pm.post_id = p.ID
        WHERE u.ID > $LAST_LOCAL_USER_ID 
        AND pm.meta_key = '_customer_user'
        AND p.post_type = 'shop_order'
    )"
    
    log_info "   Extracting new customers (ID > $LAST_LOCAL_USER_ID)"
    mysqldump -h "$REMOTE_HOST" -u "$REMOTE_USER" -p"$REMOTE_PASS" "$REMOTE_DB" \
        "${REMOTE_PREFIX}users" \
        --where="$CUSTOMER_WHERE" \
        --no-create-info \
        --no-tablespaces \
        --single-transaction \
        > "$TEMP_DIR/new_users.sql" 2>/dev/null
    
    if [ ! -s "$TEMP_DIR/new_users.sql" ]; then
        log_error "Failed to extract new customers"
        exit 1
    fi
    
    log_info "   Extracting new customer metadata"
    mysqldump -h "$REMOTE_HOST" -u "$REMOTE_USER" -p"$REMOTE_PASS" "$REMOTE_DB" \
        "${REMOTE_PREFIX}usermeta" \
        --where="user_id IN (
            SELECT DISTINCT u.ID 
            FROM ${REMOTE_PREFIX}users u
            INNER JOIN ${REMOTE_PREFIX}postmeta pm ON u.ID = CAST(pm.meta_value AS UNSIGNED)
            INNER JOIN ${REMOTE_PREFIX}posts p ON pm.post_id = p.ID
            WHERE u.ID > $LAST_LOCAL_USER_ID 
            AND pm.meta_key = '_customer_user'
            AND p.post_type = 'shop_order'
        )" \
        --no-create-info \
        --no-tablespaces \
        --single-transaction \
        > "$TEMP_DIR/new_usermeta.sql" 2>/dev/null
    
    if [ ! -s "$TEMP_DIR/new_usermeta.sql" ]; then
        log_error "Failed to extract new customer metadata"
        exit 1
    fi
    
    log_success "New customer data extraction completed"
}

# Process and convert table prefixes for new customer data
process_new_user_data() {
    log_info "Processing new customer data"
    
    # Convert table prefixes and handle potential duplicates
    sed "s/${REMOTE_PREFIX}users/wp_users/g" "$TEMP_DIR/new_users.sql" > "$TEMP_DIR/users_temp.sql"
    sed "s/${REMOTE_PREFIX}usermeta/wp_usermeta/g" "$TEMP_DIR/new_usermeta.sql" > "$TEMP_DIR/usermeta_temp.sql"
    
    # Replace INSERT INTO with INSERT IGNORE to handle any potential duplicates
    sed 's/INSERT INTO/INSERT IGNORE INTO/g' "$TEMP_DIR/users_temp.sql" > "$TEMP_DIR/users_local.sql"
    sed 's/INSERT INTO/INSERT IGNORE INTO/g' "$TEMP_DIR/usermeta_temp.sql" > "$TEMP_DIR/usermeta_temp2.sql"
    
    # Fix user capabilities: change kdf_capabilities to wp_capabilities  
    sed 's/kdf_capabilities/wp_capabilities/g' "$TEMP_DIR/usermeta_temp2.sql" > "$TEMP_DIR/usermeta_local.sql"
    
    log_success "New customer data processing completed"
}

# Check if there's any new customer data to import
check_import_new_user_data() {
    local has_data=false
    
    if [ -s "$TEMP_DIR/users_local.sql" ] && [ "$(wc -l < "$TEMP_DIR/users_local.sql")" -gt 0 ]; then
        has_data=true
    fi
    
    if [ "$has_data" = false ]; then
        log_info "No new customer data to import."
        return 1
    fi
    
    return 0
}

# Import new customer data with transaction safety
import_new_user_data() {
    log_info "Importing new customer data to local database"
    
    if ! check_import_new_user_data; then
        return 0
    fi
    
    mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" -p"$LOCAL_PASS" "$LOCAL_DB" -e "\
    SET foreign_key_checks = 0;\
    SET autocommit = 0;\
    START TRANSACTION;\
    " 2>/dev/null
    
    log_info "   Importing new customers"
    if mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" -p"$LOCAL_PASS" "$LOCAL_DB" < "$TEMP_DIR/users_local.sql" 2>&1; then
        log_success "    New customers imported successfully"
    else
        log_error "    New customers import failed"
        log_error "    Checking SQL file content..."
        head -10 "$TEMP_DIR/users_local.sql"
        mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" -p"$LOCAL_PASS" "$LOCAL_DB" -e "ROLLBACK;" 2>/dev/null
        exit 1
    fi
    
    log_info "   Importing new customer metadata"
    if mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" -p"$LOCAL_PASS" "$LOCAL_DB" < "$TEMP_DIR/usermeta_local.sql" 2>/dev/null; then
        log_success "    New customer metadata imported successfully"
    else
        log_error "    New customer metadata import failed"
        mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" -p"$LOCAL_PASS" "$LOCAL_DB" -e "ROLLBACK;" 2>/dev/null
        exit 1
    fi
    
    mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" -p"$LOCAL_PASS" "$LOCAL_DB" -e "\
    COMMIT;\
    SET foreign_key_checks = 1;\
    " 2>/dev/null
    
    log_success "New customer data import completed"
}

# Clear WordPress caches for users
clear_wordpress_caches() {
    log_info "Clearing WordPress caches for users"
    
    mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" -p"$LOCAL_PASS" "$LOCAL_DB" -e "\
    DELETE FROM wp_options WHERE option_name LIKE '_transient_user_%';\
    DELETE FROM wp_options WHERE option_name LIKE '_transient_timeout_user_%';\
    DELETE FROM wp_options WHERE option_name LIKE '_site_transient_user_%';\
    DELETE FROM wp_options WHERE option_name LIKE '_site_transient_timeout_user_%';\
    " 2>/dev/null
    
    log_success "WordPress caches cleared"
}

# Validate synced user data
validate_synced_user_data() {
    log_info "Validating synced user data"
    
    FINAL_USERS=$(mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" -p"$LOCAL_PASS" "$LOCAL_DB" -se "SELECT COUNT(*) FROM wp_users;" 2>/dev/null)
    FINAL_USERMETA=$(mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" -p"$LOCAL_PASS" "$LOCAL_DB" -se "SELECT COUNT(*) FROM wp_usermeta;" 2>/dev/null)
    SYNCED_USERS=$((FINAL_USERS - 2)) # Subtract the original 2 users
    
    log_success "User sync completed successfully!"
    log_info ""
    log_info " Sync Results"
    log_info "   New customers synced: $SYNCED_USERS"
    log_info "   Total users now: $FINAL_USERS"
    log_info "   Total user metadata: $FINAL_USERMETA"
    log_info ""
    log_info " Please refresh your WordPress Users page to see the synced customers"
}

trap cleanup EXIT

main() {
    local site_param="${1:-}"
    log_info "=== WordPress Customer Migration ==="
    log_info "Started at: $(date)"
    log_info ""
    
    # Execute sync steps
    validate_config
    load_db_config "$site_param"
    test_connections
    get_last_local_user_id
    
    if ! check_new_remote_users; then
        log_info ""
        log_success "=== No New Customers to Sync ==="
        log_info "Finished at: $(date)"
        exit 0
    fi
    
    show_sync_confirmation
    extract_new_user_data
    process_new_user_data
    import_new_user_data
    clear_wordpress_caches
    validate_synced_user_data
    
    log_info ""
    log_success "=== Sync Operation Completed Successfully ==="
    log_info "Finished at: $(date)"
}

# Execute main function with all arguments
main "$@"

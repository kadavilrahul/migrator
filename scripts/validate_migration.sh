#!/bin/bash

# Migration Validation Script
# Validates data integrity after migration

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/../config/config.sh"
LOG_FILE="$SCRIPT_DIR/../logs/validation_$(date +%Y%m%d_%H%M%S).log"

# Source the configuration
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo "Error: Configuration file not found: $CONFIG_FILE"
    exit 1
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "$1" | tee -a "$LOG_FILE"; }
log_error() { log "${RED}❌ $1${NC}"; }
log_success() { log "${GREEN}✅ $1${NC}"; }
log_warning() { log "${YELLOW}⚠️  $1${NC}"; }
log_info() { log "${BLUE}ℹ️  $1${NC}"; }

# Load database configuration
load_config() {
    local site_param="${1:-nilgiristores.in}"
    
    # Configuration already loaded from config.sh via source command
    # Variables are already set: REMOTE_HOST, REMOTE_DB, etc.
    
    # Local DB from wp-config.php
    WP_CONFIG_PATHS=(
        "/var/www/nilgiristores.in/wp-config.php"
        "../../wp-config.php"
        "../../../wp-config.php"
    )
    
    WP_CONFIG=""
    for path in "${WP_CONFIG_PATHS[@]}"; do
        if [ -f "$path" ]; then
            WP_CONFIG="$path"
            break
        fi
    done
    
    if [ -z "$WP_CONFIG" ]; then
        log_error "wp-config.php not found"
        exit 1
    fi
    
    LOCAL_HOST=$(grep "define.*DB_HOST" "$WP_CONFIG" | sed -n "s/.*['\"]\\([^'\"]*\\)['\"].*/\\1/p")
    LOCAL_DB=$(grep "define.*DB_NAME" "$WP_CONFIG" | sed -n "s/.*['\"]\\([^'\"]*\\)['\"].*/\\1/p")
    LOCAL_USER=$(grep "define.*DB_USER" "$WP_CONFIG" | sed -n "s/.*['\"]\\([^'\"]*\\)['\"].*/\\1/p")
    LOCAL_PASS=$(grep "define.*DB_PASSWORD" "$WP_CONFIG" | sed -n "s/.*['\"]\\([^'\"]*\\)['\"].*/\\1/p")
}

# Test database connections
test_connections() {
    log_info "Testing database connections..."
    
    export MYSQL_PWD="$REMOTE_PASS"
    if mysql -h "$REMOTE_HOST" -u "$REMOTE_USER" "$REMOTE_DB" -e "SELECT 1;" >/dev/null 2>&1; then
        log_success "Remote database connection OK"
    else
        log_error "Remote database connection failed"
        exit 1
    fi
    unset MYSQL_PWD
    
    export MYSQL_PWD="$LOCAL_PASS"
    if mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" "$LOCAL_DB" -e "SELECT 1;" >/dev/null 2>&1; then
        log_success "Local database connection OK"
    else
        log_error "Local database connection failed"
        exit 1
    fi
    unset MYSQL_PWD
}

# Validate user counts
validate_users() {
    log_info "Validating user migration..."
    
    export MYSQL_PWD="$REMOTE_PASS"
    REMOTE_USER_COUNT=$(mysql -h "$REMOTE_HOST" -u "$REMOTE_USER" "$REMOTE_DB" -se "SELECT COUNT(*) FROM ${REMOTE_PREFIX}users;" 2>/dev/null)
    unset MYSQL_PWD
    
    export MYSQL_PWD="$LOCAL_PASS"
    LOCAL_USER_COUNT=$(mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" "$LOCAL_DB" -se "SELECT COUNT(*) FROM wp_users;" 2>/dev/null)
    LOCAL_USERMETA_COUNT=$(mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" "$LOCAL_DB" -se "SELECT COUNT(*) FROM wp_usermeta;" 2>/dev/null)
    unset MYSQL_PWD
    
    log_info "User Validation Results:"
    log_info "  Remote users: $REMOTE_USER_COUNT"
    log_info "  Local users: $LOCAL_USER_COUNT"
    log_info "  Local user metadata: $LOCAL_USERMETA_COUNT"
    
    if [ "$LOCAL_USER_COUNT" -ge 2 ]; then
        log_success "User migration appears successful"
    else
        log_warning "Low user count - check migration"
    fi
}

# Validate order counts
validate_orders() {
    log_info "Validating order migration..."
    
    export MYSQL_PWD="$REMOTE_PASS"
    REMOTE_ORDER_COUNT=$(mysql -h "$REMOTE_HOST" -u "$REMOTE_USER" "$REMOTE_DB" -se "SELECT COUNT(*) FROM ${REMOTE_PREFIX}posts WHERE post_type='shop_order';" 2>/dev/null)
    unset MYSQL_PWD
    
    export MYSQL_PWD="$LOCAL_PASS"
    LOCAL_ORDER_COUNT=$(mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" "$LOCAL_DB" -se "SELECT COUNT(*) FROM wp_posts WHERE post_type='shop_order';" 2>/dev/null)
    LOCAL_ORDER_META_COUNT=$(mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" "$LOCAL_DB" -se "SELECT COUNT(*) FROM wp_postmeta pm JOIN wp_posts p ON pm.post_id = p.ID WHERE p.post_type='shop_order';" 2>/dev/null)
    LOCAL_ORDER_ITEMS_COUNT=$(mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" "$LOCAL_DB" -se "SELECT COUNT(*) FROM wp_woocommerce_order_items;" 2>/dev/null)
    unset MYSQL_PWD
    
    log_info "Order Validation Results:"
    log_info "  Remote orders: $REMOTE_ORDER_COUNT"
    log_info "  Local orders: $LOCAL_ORDER_COUNT"
    log_info "  Local order metadata: $LOCAL_ORDER_META_COUNT"
    log_info "  Local order items: $LOCAL_ORDER_ITEMS_COUNT"
    
    MIGRATION_PERCENTAGE=$((LOCAL_ORDER_COUNT * 100 / REMOTE_ORDER_COUNT))
    
    if [ "$MIGRATION_PERCENTAGE" -ge 95 ]; then
        log_success "Order migration appears successful ($MIGRATION_PERCENTAGE% migrated)"
    elif [ "$MIGRATION_PERCENTAGE" -ge 80 ]; then
        log_warning "Partial order migration ($MIGRATION_PERCENTAGE% migrated)"
    else
        log_error "Low order migration rate ($MIGRATION_PERCENTAGE% migrated)"
    fi
}

# Validate order statuses
validate_order_statuses() {
    log_info "Validating order status distribution..."
    
    export MYSQL_PWD="$LOCAL_PASS"
    mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" "$LOCAL_DB" -e "
    SELECT 
        post_status,
        COUNT(*) as count,
        ROUND(COUNT(*) * 100.0 / (SELECT COUNT(*) FROM wp_posts WHERE post_type='shop_order'), 2) as percentage
    FROM wp_posts 
    WHERE post_type='shop_order' 
    GROUP BY post_status 
    ORDER BY count DESC;" 2>/dev/null | while read -r line; do
        log_info "  $line"
    done
    unset MYSQL_PWD
}

# Validate WooCommerce functionality
validate_woocommerce() {
    log_info "Validating WooCommerce integration..."
    
    export MYSQL_PWD="$LOCAL_PASS"
    
    # Check for critical order metadata
    ORDERS_WITH_TOTAL=$(mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" "$LOCAL_DB" -se "SELECT COUNT(*) FROM wp_postmeta WHERE meta_key='_order_total';" 2>/dev/null)
    ORDERS_WITH_EMAIL=$(mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" "$LOCAL_DB" -se "SELECT COUNT(*) FROM wp_postmeta WHERE meta_key='_billing_email';" 2>/dev/null)
    ORDERS_WITH_STATUS=$(mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" "$LOCAL_DB" -se "SELECT COUNT(*) FROM wp_postmeta WHERE meta_key='_order_status';" 2>/dev/null)
    
    unset MYSQL_PWD
    
    log_info "WooCommerce Data Validation:"
    log_info "  Orders with totals: $ORDERS_WITH_TOTAL"
    log_info "  Orders with billing emails: $ORDERS_WITH_EMAIL"
    log_info "  Orders with status metadata: $ORDERS_WITH_STATUS"
    
    if [ "$ORDERS_WITH_TOTAL" -gt 0 ] && [ "$ORDERS_WITH_EMAIL" -gt 0 ]; then
        log_success "WooCommerce integration appears functional"
    else
        log_warning "WooCommerce integration may need attention"
    fi
}

# Check data integrity
check_data_integrity() {
    log_info "Checking data integrity..."
    
    export MYSQL_PWD="$LOCAL_PASS"
    
    # Check for orphaned order metadata
    ORPHANED_META=$(mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" "$LOCAL_DB" -se "
    SELECT COUNT(*) FROM wp_postmeta pm 
    LEFT JOIN wp_posts p ON pm.post_id = p.ID 
    WHERE p.ID IS NULL;" 2>/dev/null)
    
    # Check for orders without customer data
    ORDERS_WITHOUT_CUSTOMER=$(mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" "$LOCAL_DB" -se "
    SELECT COUNT(*) FROM wp_posts p 
    LEFT JOIN wp_postmeta pm ON p.ID = pm.post_id AND pm.meta_key = '_customer_user'
    WHERE p.post_type = 'shop_order' AND pm.meta_value IS NULL;" 2>/dev/null)
    
    unset MYSQL_PWD
    
    log_info "Data Integrity Check:"
    log_info "  Orphaned metadata records: $ORPHANED_META"
    log_info "  Orders without customer data: $ORDERS_WITHOUT_CUSTOMER"
    
    if [ "$ORPHANED_META" -eq 0 ] && [ "$ORDERS_WITHOUT_CUSTOMER" -lt 100 ]; then
        log_success "Data integrity looks good"
    else
        log_warning "Some data integrity issues detected"
    fi
}

# Main validation function
main() {
    log_info "=== Migration Validation Started ==="
    log_info "Timestamp: $(date)"
    echo ""
    
    load_config "${1:-}"
    test_connections
    
    echo ""
    validate_users
    echo ""
    validate_orders
    echo ""
    validate_order_statuses
    echo ""
    validate_woocommerce
    echo ""
    check_data_integrity
    echo ""
    
    log_success "=== Validation Completed ==="
    log_info "Check log file for details: $LOG_FILE"
}

# Execute main
main "$@"
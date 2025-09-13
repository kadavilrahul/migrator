#!/bin/bash

# WooCommerce HPOS Sync Script
# Syncs orders from wp_posts to WooCommerce HPOS tables

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/../config/config.json"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "$1"; }
log_error() { log "${RED}❌ $1${NC}"; }
log_success() { log "${GREEN}✅ $1${NC}"; }
log_warning() { log "${YELLOW}⚠️  $1${NC}"; }
log_info() { log "${BLUE}ℹ️  $1${NC}"; }

# Get local database credentials
get_db_credentials() {
    WP_CONFIG_PATHS=(
        "/var/www/nilgiristores.in/wp-config.php"
        "../wp-config.php"
        "../../wp-config.php"
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

# Sync orders to wp_wc_orders
sync_wc_orders() {
    log_info "Syncing orders to wp_wc_orders..."
    
    export MYSQL_PWD="$LOCAL_PASS"
    mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" "$LOCAL_DB" -e "
    INSERT IGNORE INTO wp_wc_orders (
        id, status, type, currency, customer_id, 
        date_created_gmt, date_updated_gmt, total_amount
    )
    SELECT 
        p.ID,
        REPLACE(p.post_status, 'wc-', ''),
        'shop_order',
        'INR',
        COALESCE((SELECT meta_value FROM wp_postmeta WHERE post_id = p.ID AND meta_key = '_customer_user'), 0),
        p.post_date_gmt,
        p.post_modified_gmt,
        COALESCE((SELECT meta_value FROM wp_postmeta WHERE post_id = p.ID AND meta_key = '_order_total'), 0)
    FROM wp_posts p 
    WHERE p.post_type = 'shop_order';"
    unset MYSQL_PWD
    
    log_success "Orders synced to wp_wc_orders"
}

# Sync order metadata to wp_wc_orders_meta
sync_wc_orders_meta() {
    log_info "Syncing order metadata to wp_wc_orders_meta..."
    
    export MYSQL_PWD="$LOCAL_PASS"
    mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" "$LOCAL_DB" -e "
    INSERT IGNORE INTO wp_wc_orders_meta (order_id, meta_key, meta_value)
    SELECT 
        pm.post_id,
        pm.meta_key,
        pm.meta_value
    FROM wp_postmeta pm
    INNER JOIN wp_posts p ON pm.post_id = p.ID
    WHERE p.post_type = 'shop_order';"
    unset MYSQL_PWD
    
    log_success "Order metadata synced to wp_wc_orders_meta"
}

# Sync order stats to wp_wc_order_stats
sync_wc_order_stats() {
    log_info "Syncing order stats to wp_wc_order_stats..."
    
    export MYSQL_PWD="$LOCAL_PASS"
    mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" "$LOCAL_DB" -e "
    INSERT IGNORE INTO wp_wc_order_stats (
        order_id, date_created, date_created_gmt, 
        num_items_sold, total_sales, tax_total, shipping_total, net_total,
        status, customer_id
    )
    SELECT 
        p.ID,
        p.post_date,
        p.post_date_gmt,
        COALESCE((
            SELECT SUM(CAST(oim.meta_value AS DECIMAL(10,2)))
            FROM wp_woocommerce_order_items oi
            JOIN wp_woocommerce_order_itemmeta oim ON oi.order_item_id = oim.order_item_id
            WHERE oi.order_id = p.ID AND oim.meta_key = '_qty'
        ), 0),
        COALESCE((SELECT meta_value FROM wp_postmeta WHERE post_id = p.ID AND meta_key = '_order_total'), 0),
        COALESCE((SELECT meta_value FROM wp_postmeta WHERE post_id = p.ID AND meta_key = '_order_tax'), 0),
        COALESCE((SELECT meta_value FROM wp_postmeta WHERE post_id = p.ID AND meta_key = '_order_shipping'), 0),
        COALESCE((SELECT meta_value FROM wp_postmeta WHERE post_id = p.ID AND meta_key = '_order_total'), 0),
        REPLACE(p.post_status, 'wc-', ''),
        COALESCE((SELECT meta_value FROM wp_postmeta WHERE post_id = p.ID AND meta_key = '_customer_user'), 0)
    FROM wp_posts p 
    WHERE p.post_type = 'shop_order';"
    unset MYSQL_PWD
    
    log_success "Order stats synced to wp_wc_order_stats"
}

# Sync order addresses to wp_wc_order_addresses
sync_wc_order_addresses() {
    log_info "Syncing order addresses to wp_wc_order_addresses..."
    
    export MYSQL_PWD="$LOCAL_PASS"
    mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" "$LOCAL_DB" -e "
    INSERT IGNORE INTO wp_wc_order_addresses (order_id, address_type, first_name, last_name, email, phone, address_1, city, state, postcode, country)
    SELECT 
        p.ID,
        'billing',
        COALESCE((SELECT meta_value FROM wp_postmeta WHERE post_id = p.ID AND meta_key = '_billing_first_name'), ''),
        COALESCE((SELECT meta_value FROM wp_postmeta WHERE post_id = p.ID AND meta_key = '_billing_last_name'), ''),
        COALESCE((SELECT meta_value FROM wp_postmeta WHERE post_id = p.ID AND meta_key = '_billing_email'), ''),
        COALESCE((SELECT meta_value FROM wp_postmeta WHERE post_id = p.ID AND meta_key = '_billing_phone'), ''),
        COALESCE((SELECT meta_value FROM wp_postmeta WHERE post_id = p.ID AND meta_key = '_billing_address_1'), ''),
        COALESCE((SELECT meta_value FROM wp_postmeta WHERE post_id = p.ID AND meta_key = '_billing_city'), ''),
        COALESCE((SELECT meta_value FROM wp_postmeta WHERE post_id = p.ID AND meta_key = '_billing_state'), ''),
        COALESCE((SELECT meta_value FROM wp_postmeta WHERE post_id = p.ID AND meta_key = '_billing_postcode'), ''),
        COALESCE((SELECT meta_value FROM wp_postmeta WHERE post_id = p.ID AND meta_key = '_billing_country'), '')
    FROM wp_posts p 
    WHERE p.post_type = 'shop_order'
    UNION
    SELECT 
        p.ID,
        'shipping',
        COALESCE((SELECT meta_value FROM wp_postmeta WHERE post_id = p.ID AND meta_key = '_shipping_first_name'), ''),
        COALESCE((SELECT meta_value FROM wp_postmeta WHERE post_id = p.ID AND meta_key = '_shipping_last_name'), ''),
        '',
        '',
        COALESCE((SELECT meta_value FROM wp_postmeta WHERE post_id = p.ID AND meta_key = '_shipping_address_1'), ''),
        COALESCE((SELECT meta_value FROM wp_postmeta WHERE post_id = p.ID AND meta_key = '_shipping_city'), ''),
        COALESCE((SELECT meta_value FROM wp_postmeta WHERE post_id = p.ID AND meta_key = '_shipping_state'), ''),
        COALESCE((SELECT meta_value FROM wp_postmeta WHERE post_id = p.ID AND meta_key = '_shipping_postcode'), ''),
        COALESCE((SELECT meta_value FROM wp_postmeta WHERE post_id = p.ID AND meta_key = '_shipping_country'), '')
    FROM wp_posts p 
    WHERE p.post_type = 'shop_order';"
    unset MYSQL_PWD
    
    log_success "Order addresses synced to wp_wc_order_addresses"
}

# Main function
main() {
    log_info "=== WooCommerce HPOS Sync ==="
    
    get_db_credentials
    
    # Test database connection
    export MYSQL_PWD="$LOCAL_PASS"
    if ! mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" "$LOCAL_DB" -e "SELECT 1;" >/dev/null 2>&1; then
        log_error "Cannot connect to database"
        exit 1
    fi
    unset MYSQL_PWD
    
    log_success "Database connection verified"
    
    # Get order counts
    export MYSQL_PWD="$LOCAL_PASS"
    TOTAL_ORDERS=$(mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" "$LOCAL_DB" -se "SELECT COUNT(*) FROM wp_posts WHERE post_type='shop_order';" 2>/dev/null)
    unset MYSQL_PWD
    
    log_info "Found $TOTAL_ORDERS orders to sync"
    
    # Sync all HPOS tables
    sync_wc_orders
    sync_wc_orders_meta  
    sync_wc_order_stats
    sync_wc_order_addresses
    
    # Verify results
    export MYSQL_PWD="$LOCAL_PASS"
    WC_ORDERS=$(mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" "$LOCAL_DB" -se "SELECT COUNT(*) FROM wp_wc_orders;" 2>/dev/null)
    WC_META=$(mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" "$LOCAL_DB" -se "SELECT COUNT(*) FROM wp_wc_orders_meta;" 2>/dev/null)
    WC_STATS=$(mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" "$LOCAL_DB" -se "SELECT COUNT(*) FROM wp_wc_order_stats;" 2>/dev/null)
    WC_ADDRESSES=$(mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" "$LOCAL_DB" -se "SELECT COUNT(*) FROM wp_wc_order_addresses;" 2>/dev/null)
    unset MYSQL_PWD
    
    log_success "HPOS Sync Results:"
    log_info "  Orders: $WC_ORDERS"
    log_info "  Order metadata: $WC_META"
    log_info "  Order stats: $WC_STATS"
    log_info "  Order addresses: $WC_ADDRESSES"
    
    log_success "WooCommerce HPOS sync completed!"
}

# Execute main function
main "$@"
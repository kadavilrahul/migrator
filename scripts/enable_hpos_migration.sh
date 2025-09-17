#!/bin/bash

###################################################################################
# HPOS MIGRATION SCRIPT - FIXED VERSION
###################################################################################
# Purpose: Migrate orders from traditional WordPress tables to HPOS tables
# Fixed: Simplified queries for better compatibility
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

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}HPOS MIGRATION STARTING${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Function to execute queries
execute_query() {
    mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" -p"$LOCAL_PASS" "$LOCAL_DB" -e "$1" 2>/dev/null
}

# Function to get count
get_count() {
    mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" -p"$LOCAL_PASS" "$LOCAL_DB" -sN -e "$1" 2>/dev/null
}

# Step 1: Check current status
echo -e "${BLUE}Step 1: Checking current status...${NC}"
ORDER_COUNT=$(get_count "SELECT COUNT(*) FROM ${LOCAL_PREFIX}posts WHERE post_type = 'shop_order'")
HPOS_COUNT=$(get_count "SELECT COUNT(*) FROM ${LOCAL_PREFIX}wc_orders")
echo "Orders in traditional tables: $ORDER_COUNT"
echo "Orders in HPOS tables: $HPOS_COUNT"
echo ""

# Step 2: Clean HPOS tables
echo -e "${BLUE}Step 2: Cleaning HPOS tables...${NC}"
execute_query "SET FOREIGN_KEY_CHECKS=0;"
execute_query "TRUNCATE TABLE ${LOCAL_PREFIX}wc_orders;"
execute_query "TRUNCATE TABLE ${LOCAL_PREFIX}wc_orders_meta;"
execute_query "TRUNCATE TABLE ${LOCAL_PREFIX}wc_order_addresses;"
execute_query "TRUNCATE TABLE ${LOCAL_PREFIX}wc_order_operational_data;"
execute_query "TRUNCATE TABLE ${LOCAL_PREFIX}wc_order_stats;"
execute_query "TRUNCATE TABLE ${LOCAL_PREFIX}wc_order_product_lookup;"
execute_query "SET FOREIGN_KEY_CHECKS=1;"
echo -e "${GREEN}HPOS tables cleaned${NC}"
echo ""

# Step 3: Migrate orders to HPOS tables
echo -e "${BLUE}Step 3: Migrating orders to ${LOCAL_PREFIX}wc_orders...${NC}"

# First, create a temporary table with order metadata
execute_query "
CREATE TEMPORARY TABLE temp_order_meta AS
SELECT 
    post_id,
    MAX(CASE WHEN meta_key = '_order_currency' THEN meta_value END) as currency,
    MAX(CASE WHEN meta_key = '_order_tax' THEN meta_value END) as tax,
    MAX(CASE WHEN meta_key = '_order_total' THEN meta_value END) as total,
    MAX(CASE WHEN meta_key = '_customer_user' THEN meta_value END) as customer_id,
    MAX(CASE WHEN meta_key = '_billing_email' THEN meta_value END) as billing_email,
    MAX(CASE WHEN meta_key = '_payment_method' THEN meta_value END) as payment_method,
    MAX(CASE WHEN meta_key = '_payment_method_title' THEN meta_value END) as payment_method_title,
    MAX(CASE WHEN meta_key = '_transaction_id' THEN meta_value END) as transaction_id,
    MAX(CASE WHEN meta_key = '_customer_ip_address' THEN meta_value END) as ip_address,
    MAX(CASE WHEN meta_key = '_customer_user_agent' THEN meta_value END) as user_agent
FROM ${LOCAL_PREFIX}postmeta
WHERE post_id IN (SELECT ID FROM ${LOCAL_PREFIX}posts WHERE post_type = 'shop_order')
GROUP BY post_id;"

# Now insert into wc_orders table
execute_query "
INSERT INTO ${LOCAL_PREFIX}wc_orders (
    id, status, currency, type, tax_amount, total_amount,
    customer_id, billing_email, date_created_gmt, date_updated_gmt,
    parent_order_id, payment_method, payment_method_title,
    transaction_id, customer_note, ip_address, user_agent
)
SELECT 
    p.ID,
    REPLACE(p.post_status, 'wc-', ''),
    COALESCE(m.currency, 'INR'),
    'shop_order',
    CAST(COALESCE(m.tax, 0) AS DECIMAL(26,8)),
    CAST(COALESCE(m.total, 0) AS DECIMAL(26,8)),
    CAST(COALESCE(m.customer_id, 0) AS UNSIGNED),
    COALESCE(m.billing_email, ''),
    p.post_date_gmt,
    p.post_modified_gmt,
    p.post_parent,
    COALESCE(m.payment_method, ''),
    COALESCE(m.payment_method_title, ''),
    COALESCE(m.transaction_id, ''),
    p.post_excerpt,
    COALESCE(m.ip_address, ''),
    COALESCE(m.user_agent, '')
FROM ${LOCAL_PREFIX}posts p
LEFT JOIN temp_order_meta m ON p.ID = m.post_id
WHERE p.post_type = 'shop_order';"

ORDERS_MIGRATED=$(get_count "SELECT COUNT(*) FROM ${LOCAL_PREFIX}wc_orders")
echo -e "${GREEN}Migrated $ORDERS_MIGRATED orders${NC}"
echo ""

# Step 4: Migrate order metadata
echo -e "${BLUE}Step 4: Migrating order metadata...${NC}"
execute_query "
INSERT INTO ${LOCAL_PREFIX}wc_orders_meta (order_id, meta_key, meta_value)
SELECT post_id, meta_key, meta_value
FROM ${LOCAL_PREFIX}postmeta
WHERE post_id IN (SELECT ID FROM ${LOCAL_PREFIX}posts WHERE post_type = 'shop_order');"

META_COUNT=$(get_count "SELECT COUNT(*) FROM ${LOCAL_PREFIX}wc_orders_meta")
echo -e "${GREEN}Migrated $META_COUNT metadata records${NC}"
echo ""

# Step 5: Migrate addresses
echo -e "${BLUE}Step 5: Migrating addresses...${NC}"

# Billing addresses
execute_query "
CREATE TEMPORARY TABLE temp_billing_addresses AS
SELECT 
    post_id,
    MAX(CASE WHEN meta_key = '_billing_first_name' THEN meta_value END) as first_name,
    MAX(CASE WHEN meta_key = '_billing_last_name' THEN meta_value END) as last_name,
    MAX(CASE WHEN meta_key = '_billing_company' THEN meta_value END) as company,
    MAX(CASE WHEN meta_key = '_billing_address_1' THEN meta_value END) as address_1,
    MAX(CASE WHEN meta_key = '_billing_address_2' THEN meta_value END) as address_2,
    MAX(CASE WHEN meta_key = '_billing_city' THEN meta_value END) as city,
    MAX(CASE WHEN meta_key = '_billing_state' THEN meta_value END) as state,
    MAX(CASE WHEN meta_key = '_billing_postcode' THEN meta_value END) as postcode,
    MAX(CASE WHEN meta_key = '_billing_country' THEN meta_value END) as country,
    MAX(CASE WHEN meta_key = '_billing_email' THEN meta_value END) as email,
    MAX(CASE WHEN meta_key = '_billing_phone' THEN meta_value END) as phone
FROM ${LOCAL_PREFIX}postmeta
WHERE post_id IN (SELECT ID FROM ${LOCAL_PREFIX}posts WHERE post_type = 'shop_order')
AND meta_key LIKE '_billing_%'
GROUP BY post_id;"

execute_query "
INSERT INTO ${LOCAL_PREFIX}wc_order_addresses (
    order_id, address_type, first_name, last_name, company,
    address_1, address_2, city, state, postcode, country,
    email, phone
)
SELECT 
    post_id, 'billing',
    COALESCE(first_name, ''), COALESCE(last_name, ''), COALESCE(company, ''),
    COALESCE(address_1, ''), COALESCE(address_2, ''), COALESCE(city, ''),
    COALESCE(state, ''), COALESCE(postcode, ''), COALESCE(country, ''),
    COALESCE(email, ''), COALESCE(phone, '')
FROM temp_billing_addresses;"

# Shipping addresses
execute_query "
CREATE TEMPORARY TABLE temp_shipping_addresses AS
SELECT 
    post_id,
    MAX(CASE WHEN meta_key = '_shipping_first_name' THEN meta_value END) as first_name,
    MAX(CASE WHEN meta_key = '_shipping_last_name' THEN meta_value END) as last_name,
    MAX(CASE WHEN meta_key = '_shipping_company' THEN meta_value END) as company,
    MAX(CASE WHEN meta_key = '_shipping_address_1' THEN meta_value END) as address_1,
    MAX(CASE WHEN meta_key = '_shipping_address_2' THEN meta_value END) as address_2,
    MAX(CASE WHEN meta_key = '_shipping_city' THEN meta_value END) as city,
    MAX(CASE WHEN meta_key = '_shipping_state' THEN meta_value END) as state,
    MAX(CASE WHEN meta_key = '_shipping_postcode' THEN meta_value END) as postcode,
    MAX(CASE WHEN meta_key = '_shipping_country' THEN meta_value END) as country,
    MAX(CASE WHEN meta_key = '_shipping_phone' THEN meta_value END) as phone
FROM ${LOCAL_PREFIX}postmeta
WHERE post_id IN (SELECT ID FROM ${LOCAL_PREFIX}posts WHERE post_type = 'shop_order')
AND meta_key LIKE '_shipping_%'
GROUP BY post_id;"

execute_query "
INSERT INTO ${LOCAL_PREFIX}wc_order_addresses (
    order_id, address_type, first_name, last_name, company,
    address_1, address_2, city, state, postcode, country,
    email, phone
)
SELECT 
    post_id, 'shipping',
    COALESCE(first_name, ''), COALESCE(last_name, ''), COALESCE(company, ''),
    COALESCE(address_1, ''), COALESCE(address_2, ''), COALESCE(city, ''),
    COALESCE(state, ''), COALESCE(postcode, ''), COALESCE(country, ''),
    '', COALESCE(phone, '')
FROM temp_shipping_addresses;"

ADDRESSES_COUNT=$(get_count "SELECT COUNT(*) FROM ${LOCAL_PREFIX}wc_order_addresses")
echo -e "${GREEN}Migrated $ADDRESSES_COUNT addresses${NC}"
echo ""

# Step 6: Migrate operational data
echo -e "${BLUE}Step 6: Migrating operational data...${NC}"

execute_query "
CREATE TEMPORARY TABLE temp_operational_data AS
SELECT 
    post_id,
    MAX(CASE WHEN meta_key = '_created_via' THEN meta_value END) as created_via,
    MAX(CASE WHEN meta_key = '_order_version' THEN meta_value END) as wc_version,
    MAX(CASE WHEN meta_key = '_prices_include_tax' THEN meta_value END) as prices_include_tax,
    MAX(CASE WHEN meta_key = '_recorded_coupon_usage_counts' THEN meta_value END) as coupon_counted,
    MAX(CASE WHEN meta_key = '_download_permissions_granted' THEN meta_value END) as download_granted,
    MAX(CASE WHEN meta_key = '_cart_hash' THEN meta_value END) as cart_hash,
    MAX(CASE WHEN meta_key = '_new_order_email_sent' THEN meta_value END) as email_sent,
    MAX(CASE WHEN meta_key = '_order_key' THEN meta_value END) as order_key,
    MAX(CASE WHEN meta_key = '_order_stock_reduced' THEN meta_value END) as stock_reduced,
    MAX(CASE WHEN meta_key = '_date_paid' THEN meta_value END) as date_paid,
    MAX(CASE WHEN meta_key = '_date_completed' THEN meta_value END) as date_completed,
    MAX(CASE WHEN meta_key = '_order_shipping_tax' THEN meta_value END) as shipping_tax,
    MAX(CASE WHEN meta_key = '_order_shipping' THEN meta_value END) as shipping_total,
    MAX(CASE WHEN meta_key = '_cart_discount_tax' THEN meta_value END) as discount_tax,
    MAX(CASE WHEN meta_key = '_cart_discount' THEN meta_value END) as discount_total,
    MAX(CASE WHEN meta_key = '_recorded_sales' THEN meta_value END) as recorded_sales
FROM ${LOCAL_PREFIX}postmeta
WHERE post_id IN (SELECT ID FROM ${LOCAL_PREFIX}posts WHERE post_type = 'shop_order')
GROUP BY post_id;"

execute_query "
INSERT INTO ${LOCAL_PREFIX}wc_order_operational_data (
    order_id, created_via, woocommerce_version, prices_include_tax,
    coupon_usages_are_counted, download_permission_granted, cart_hash,
    new_order_email_sent, order_key, order_stock_reduced,
    date_paid_gmt, date_completed_gmt, shipping_tax_amount,
    shipping_total_amount, discount_tax_amount, discount_total_amount,
    recorded_sales
)
SELECT 
    post_id,
    COALESCE(created_via, 'checkout'),
    COALESCE(wc_version, '9.3.3'),
    CASE WHEN prices_include_tax = 'yes' THEN 1 ELSE 0 END,
    CASE WHEN coupon_counted = 'yes' THEN 1 ELSE 0 END,
    CASE WHEN download_granted = 'yes' THEN 1 ELSE 0 END,
    COALESCE(cart_hash, ''),
    CASE WHEN email_sent = 'true' THEN 1 ELSE 0 END,
    COALESCE(order_key, CONCAT('wc_order_', post_id)),
    CASE WHEN stock_reduced = 'yes' THEN 1 ELSE 0 END,
    CASE WHEN date_paid IS NOT NULL THEN FROM_UNIXTIME(date_paid) ELSE NULL END,
    CASE WHEN date_completed IS NOT NULL THEN FROM_UNIXTIME(date_completed) ELSE NULL END,
    CAST(COALESCE(shipping_tax, 0) AS DECIMAL(26,8)),
    CAST(COALESCE(shipping_total, 0) AS DECIMAL(26,8)),
    CAST(COALESCE(discount_tax, 0) AS DECIMAL(26,8)),
    CAST(COALESCE(discount_total, 0) AS DECIMAL(26,8)),
    CASE WHEN recorded_sales = 'yes' THEN 1 ELSE 0 END
FROM temp_operational_data;"

OPERATIONAL_COUNT=$(get_count "SELECT COUNT(*) FROM ${LOCAL_PREFIX}wc_order_operational_data")
echo -e "${GREEN}Migrated $OPERATIONAL_COUNT operational records${NC}"
echo ""

# Step 7: Enable HPOS
echo -e "${BLUE}Step 7: Enabling HPOS in WooCommerce...${NC}"
execute_query "
INSERT INTO ${LOCAL_PREFIX}options (option_name, option_value, autoload)
VALUES 
    ('woocommerce_custom_orders_table_enabled', 'yes', 'yes'),
    ('woocommerce_custom_orders_table_data_sync_enabled', 'yes', 'yes'),
    ('woocommerce_feature_custom_order_tables_enabled', 'yes', 'yes'),
    ('woocommerce_cot_authoritative_source', 'cot', 'yes')
ON DUPLICATE KEY UPDATE option_value = VALUES(option_value);"

echo -e "${GREEN}HPOS settings enabled${NC}"
echo ""

# Final verification
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}HPOS MIGRATION RESULTS${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

FINAL_TRADITIONAL=$(get_count "SELECT COUNT(*) FROM ${LOCAL_PREFIX}posts WHERE post_type = 'shop_order'")
FINAL_HPOS=$(get_count "SELECT COUNT(*) FROM ${LOCAL_PREFIX}wc_orders")

echo "Traditional Orders: $FINAL_TRADITIONAL"
echo "HPOS Orders: $FINAL_HPOS"
echo ""

if [ "$FINAL_HPOS" -eq "$FINAL_TRADITIONAL" ] && [ "$FINAL_HPOS" -gt 0 ]; then
    echo -e "${GREEN}✅ HPOS MIGRATION COMPLETED SUCCESSFULLY!${NC}"
    echo -e "${GREEN}All $FINAL_HPOS orders migrated to HPOS${NC}"
else
    echo -e "${YELLOW}⚠ Migration completed with differences${NC}"
    echo "Please check the data and run validation"
fi

echo ""
echo "HPOS is now enabled. Orders should appear in WooCommerce dashboard."
echo "If orders don't appear, try:"
echo "1. Clear WordPress cache"
echo "2. Visit WooCommerce → Status → Tools → Clear transients"
echo "3. Check WooCommerce → Settings → Advanced → Features"
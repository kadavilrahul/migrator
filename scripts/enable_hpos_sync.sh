#!/bin/bash

# Enable HPOS and sync orders for WooCommerce dashboard visibility

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Database credentials
LOCAL_HOST="localhost"
LOCAL_USER="root"
LOCAL_PASS="Karimpadam2@"
LOCAL_DB="nilgiristores_in_db"
LOCAL_PREFIX="wp_"

WP_PATH="/var/www/nilgiristores.in"

echo -e "${BLUE}=== ENABLING HPOS AND SYNCING ORDERS ===${NC}"

# Step 1: First disable HPOS completely to reset
echo -e "${YELLOW}Step 1: Resetting HPOS settings...${NC}"
mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" -p"$LOCAL_PASS" "$LOCAL_DB" << EOF 2>/dev/null
-- Disable HPOS temporarily
UPDATE ${LOCAL_PREFIX}options 
SET option_value = 'no' 
WHERE option_name IN (
    'woocommerce_custom_orders_table_enabled',
    'woocommerce_custom_orders_table_data_sync_enabled',
    'woocommerce_feature_custom_order_tables_enabled'
);

-- Insert if not exists
INSERT IGNORE INTO ${LOCAL_PREFIX}options (option_name, option_value, autoload)
VALUES 
    ('woocommerce_custom_orders_table_enabled', 'no', 'yes'),
    ('woocommerce_custom_orders_table_data_sync_enabled', 'no', 'yes'),
    ('woocommerce_feature_custom_order_tables_enabled', 'no', 'yes');
EOF

echo -e "${GREEN}HPOS settings reset${NC}"

# Step 2: Enable compatibility mode first (this syncs posts to HPOS)
echo -e "${YELLOW}Step 2: Enabling compatibility mode...${NC}"
mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" -p"$LOCAL_PASS" "$LOCAL_DB" << EOF 2>/dev/null
UPDATE ${LOCAL_PREFIX}options 
SET option_value = 'yes' 
WHERE option_name = 'woocommerce_custom_orders_table_data_sync_enabled';
EOF

# Step 3: Manually populate HPOS tables since WP-CLI might not work
echo -e "${YELLOW}Step 3: Populating HPOS tables manually...${NC}"

# Clear existing HPOS data
mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" -p"$LOCAL_PASS" "$LOCAL_DB" << EOF 2>/dev/null
DELETE FROM ${LOCAL_PREFIX}wc_orders;
DELETE FROM ${LOCAL_PREFIX}wc_orders_meta;
DELETE FROM ${LOCAL_PREFIX}wc_order_addresses;
DELETE FROM ${LOCAL_PREFIX}wc_order_operational_data;
DELETE FROM ${LOCAL_PREFIX}wc_order_stats;
DELETE FROM ${LOCAL_PREFIX}wc_order_product_lookup;
EOF

# Populate wp_wc_orders
echo -e "${BLUE}  Populating wp_wc_orders...${NC}"
mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" -p"$LOCAL_PASS" "$LOCAL_DB" << EOF 2>/dev/null
INSERT IGNORE INTO ${LOCAL_PREFIX}wc_orders (
    id, status, currency, type, tax_amount, total_amount, 
    customer_id, billing_email, date_created_gmt, date_updated_gmt,
    parent_order_id, payment_method, payment_method_title,
    transaction_id, customer_note, date_completed_gmt, date_paid_gmt,
    cart_hash, ip_address, user_agent
)
SELECT 
    p.ID,
    REPLACE(p.post_status, 'wc-', ''),
    COALESCE((SELECT meta_value FROM ${LOCAL_PREFIX}postmeta WHERE post_id = p.ID AND meta_key = '_order_currency' LIMIT 1), 'INR'),
    'shop_order',
    COALESCE((SELECT CAST(meta_value AS DECIMAL(10,2)) FROM ${LOCAL_PREFIX}postmeta WHERE post_id = p.ID AND meta_key = '_order_tax' LIMIT 1), 0),
    COALESCE((SELECT CAST(meta_value AS DECIMAL(10,2)) FROM ${LOCAL_PREFIX}postmeta WHERE post_id = p.ID AND meta_key = '_order_total' LIMIT 1), 0),
    COALESCE((SELECT CAST(meta_value AS UNSIGNED) FROM ${LOCAL_PREFIX}postmeta WHERE post_id = p.ID AND meta_key = '_customer_user' LIMIT 1), 0),
    COALESCE((SELECT meta_value FROM ${LOCAL_PREFIX}postmeta WHERE post_id = p.ID AND meta_key = '_billing_email' LIMIT 1), ''),
    p.post_date_gmt,
    p.post_modified_gmt,
    p.post_parent,
    COALESCE((SELECT meta_value FROM ${LOCAL_PREFIX}postmeta WHERE post_id = p.ID AND meta_key = '_payment_method' LIMIT 1), ''),
    COALESCE((SELECT meta_value FROM ${LOCAL_PREFIX}postmeta WHERE post_id = p.ID AND meta_key = '_payment_method_title' LIMIT 1), ''),
    COALESCE((SELECT meta_value FROM ${LOCAL_PREFIX}postmeta WHERE post_id = p.ID AND meta_key = '_transaction_id' LIMIT 1), ''),
    p.post_excerpt,
    (SELECT meta_value FROM ${LOCAL_PREFIX}postmeta WHERE post_id = p.ID AND meta_key = '_date_completed' LIMIT 1),
    (SELECT meta_value FROM ${LOCAL_PREFIX}postmeta WHERE post_id = p.ID AND meta_key = '_date_paid' LIMIT 1),
    COALESCE((SELECT meta_value FROM ${LOCAL_PREFIX}postmeta WHERE post_id = p.ID AND meta_key = '_cart_hash' LIMIT 1), ''),
    COALESCE((SELECT meta_value FROM ${LOCAL_PREFIX}postmeta WHERE post_id = p.ID AND meta_key = '_customer_ip_address' LIMIT 1), ''),
    COALESCE((SELECT meta_value FROM ${LOCAL_PREFIX}postmeta WHERE post_id = p.ID AND meta_key = '_customer_user_agent' LIMIT 1), '')
FROM ${LOCAL_PREFIX}posts p
WHERE p.post_type = 'shop_order';
EOF

# Populate wp_wc_orders_meta
echo -e "${BLUE}  Populating wp_wc_orders_meta...${NC}"
mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" -p"$LOCAL_PASS" "$LOCAL_DB" << EOF 2>/dev/null
INSERT IGNORE INTO ${LOCAL_PREFIX}wc_orders_meta (order_id, meta_key, meta_value)
SELECT post_id, meta_key, meta_value
FROM ${LOCAL_PREFIX}postmeta pm
WHERE pm.post_id IN (SELECT ID FROM ${LOCAL_PREFIX}posts WHERE post_type = 'shop_order');
EOF

# Populate wp_wc_order_addresses (billing)
echo -e "${BLUE}  Populating billing addresses...${NC}"
mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" -p"$LOCAL_PASS" "$LOCAL_DB" << EOF 2>/dev/null
INSERT IGNORE INTO ${LOCAL_PREFIX}wc_order_addresses (
    order_id, address_type, first_name, last_name, company,
    address_1, address_2, city, state, postcode, country,
    email, phone
)
SELECT 
    p.ID,
    'billing',
    COALESCE((SELECT meta_value FROM ${LOCAL_PREFIX}postmeta WHERE post_id = p.ID AND meta_key = '_billing_first_name' LIMIT 1), ''),
    COALESCE((SELECT meta_value FROM ${LOCAL_PREFIX}postmeta WHERE post_id = p.ID AND meta_key = '_billing_last_name' LIMIT 1), ''),
    COALESCE((SELECT meta_value FROM ${LOCAL_PREFIX}postmeta WHERE post_id = p.ID AND meta_key = '_billing_company' LIMIT 1), ''),
    COALESCE((SELECT meta_value FROM ${LOCAL_PREFIX}postmeta WHERE post_id = p.ID AND meta_key = '_billing_address_1' LIMIT 1), ''),
    COALESCE((SELECT meta_value FROM ${LOCAL_PREFIX}postmeta WHERE post_id = p.ID AND meta_key = '_billing_address_2' LIMIT 1), ''),
    COALESCE((SELECT meta_value FROM ${LOCAL_PREFIX}postmeta WHERE post_id = p.ID AND meta_key = '_billing_city' LIMIT 1), ''),
    COALESCE((SELECT meta_value FROM ${LOCAL_PREFIX}postmeta WHERE post_id = p.ID AND meta_key = '_billing_state' LIMIT 1), ''),
    COALESCE((SELECT meta_value FROM ${LOCAL_PREFIX}postmeta WHERE post_id = p.ID AND meta_key = '_billing_postcode' LIMIT 1), ''),
    COALESCE((SELECT meta_value FROM ${LOCAL_PREFIX}postmeta WHERE post_id = p.ID AND meta_key = '_billing_country' LIMIT 1), ''),
    COALESCE((SELECT meta_value FROM ${LOCAL_PREFIX}postmeta WHERE post_id = p.ID AND meta_key = '_billing_email' LIMIT 1), ''),
    COALESCE((SELECT meta_value FROM ${LOCAL_PREFIX}postmeta WHERE post_id = p.ID AND meta_key = '_billing_phone' LIMIT 1), '')
FROM ${LOCAL_PREFIX}posts p
WHERE p.post_type = 'shop_order';
EOF

# Populate wp_wc_order_addresses (shipping)
echo -e "${BLUE}  Populating shipping addresses...${NC}"
mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" -p"$LOCAL_PASS" "$LOCAL_DB" << EOF 2>/dev/null
INSERT IGNORE INTO ${LOCAL_PREFIX}wc_order_addresses (
    order_id, address_type, first_name, last_name, company,
    address_1, address_2, city, state, postcode, country,
    email, phone
)
SELECT 
    p.ID,
    'shipping',
    COALESCE((SELECT meta_value FROM ${LOCAL_PREFIX}postmeta WHERE post_id = p.ID AND meta_key = '_shipping_first_name' LIMIT 1), ''),
    COALESCE((SELECT meta_value FROM ${LOCAL_PREFIX}postmeta WHERE post_id = p.ID AND meta_key = '_shipping_last_name' LIMIT 1), ''),
    COALESCE((SELECT meta_value FROM ${LOCAL_PREFIX}postmeta WHERE post_id = p.ID AND meta_key = '_shipping_company' LIMIT 1), ''),
    COALESCE((SELECT meta_value FROM ${LOCAL_PREFIX}postmeta WHERE post_id = p.ID AND meta_key = '_shipping_address_1' LIMIT 1), ''),
    COALESCE((SELECT meta_value FROM ${LOCAL_PREFIX}postmeta WHERE post_id = p.ID AND meta_key = '_shipping_address_2' LIMIT 1), ''),
    COALESCE((SELECT meta_value FROM ${LOCAL_PREFIX}postmeta WHERE post_id = p.ID AND meta_key = '_shipping_city' LIMIT 1), ''),
    COALESCE((SELECT meta_value FROM ${LOCAL_PREFIX}postmeta WHERE post_id = p.ID AND meta_key = '_shipping_state' LIMIT 1), ''),
    COALESCE((SELECT meta_value FROM ${LOCAL_PREFIX}postmeta WHERE post_id = p.ID AND meta_key = '_shipping_postcode' LIMIT 1), ''),
    COALESCE((SELECT meta_value FROM ${LOCAL_PREFIX}postmeta WHERE post_id = p.ID AND meta_key = '_shipping_country' LIMIT 1), ''),
    '',
    COALESCE((SELECT meta_value FROM ${LOCAL_PREFIX}postmeta WHERE post_id = p.ID AND meta_key = '_shipping_phone' LIMIT 1), '')
FROM ${LOCAL_PREFIX}posts p
WHERE p.post_type = 'shop_order';
EOF

# Step 4: Enable HPOS
echo -e "${YELLOW}Step 4: Enabling HPOS...${NC}"
mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" -p"$LOCAL_PASS" "$LOCAL_DB" << EOF 2>/dev/null
UPDATE ${LOCAL_PREFIX}options 
SET option_value = 'yes' 
WHERE option_name IN (
    'woocommerce_custom_orders_table_enabled',
    'woocommerce_feature_custom_order_tables_enabled'
);
EOF

# Step 5: Try WP-CLI sync if available
echo -e "${YELLOW}Step 5: Attempting WP-CLI sync...${NC}"
if command -v wp &> /dev/null; then
    cd "$WP_PATH" 2>/dev/null && wp wc cot sync --path="$WP_PATH" 2>/dev/null || echo "WP-CLI sync attempted"
else
    echo "WP-CLI not available, skipping"
fi

# Step 6: Verify
echo -e "${BLUE}=== VERIFICATION ===${NC}"

# Check traditional tables
POSTS_COUNT=$(mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" -p"$LOCAL_PASS" "$LOCAL_DB" -sN -e "
    SELECT COUNT(*) FROM ${LOCAL_PREFIX}posts WHERE post_type = 'shop_order'
" 2>/dev/null)

# Check HPOS tables
HPOS_COUNT=$(mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" -p"$LOCAL_PASS" "$LOCAL_DB" -sN -e "
    SELECT COUNT(*) FROM ${LOCAL_PREFIX}wc_orders
" 2>/dev/null)

HPOS_META_COUNT=$(mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" -p"$LOCAL_PASS" "$LOCAL_DB" -sN -e "
    SELECT COUNT(*) FROM ${LOCAL_PREFIX}wc_orders_meta
" 2>/dev/null)

HPOS_ADDR_COUNT=$(mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" -p"$LOCAL_PASS" "$LOCAL_DB" -sN -e "
    SELECT COUNT(*) FROM ${LOCAL_PREFIX}wc_order_addresses
" 2>/dev/null)

echo -e "${GREEN}Traditional posts table: $POSTS_COUNT orders${NC}"
echo -e "${GREEN}HPOS wc_orders table: $HPOS_COUNT orders${NC}"
echo -e "${GREEN}HPOS metadata: $HPOS_META_COUNT records${NC}"
echo -e "${GREEN}HPOS addresses: $HPOS_ADDR_COUNT records${NC}"

# Check HPOS settings
echo -e "\n${BLUE}HPOS Settings:${NC}"
mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" -p"$LOCAL_PASS" "$LOCAL_DB" -e "
    SELECT option_name, option_value 
    FROM ${LOCAL_PREFIX}options 
    WHERE option_name LIKE '%custom_order%' 
    OR option_name LIKE '%hpos%'
    ORDER BY option_name
" 2>/dev/null

echo -e "\n${GREEN}=== HPOS SYNC COMPLETED ===${NC}"
echo -e "${YELLOW}Please check the WooCommerce dashboard now.${NC}"
echo -e "${YELLOW}If orders still don't appear, try:${NC}"
echo -e "  1. Clear browser cache"
echo -e "  2. Go to WooCommerce > Status > Tools > Clear transients"
echo -e "  3. Check WooCommerce > Settings > Advanced > Features"
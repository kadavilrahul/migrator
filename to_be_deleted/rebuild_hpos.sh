#!/bin/bash

# Force Complete HPOS Rebuild
set -e

echo "Complete HPOS Rebuild Script"
echo "============================"

LOCAL_DB=$(grep "DB_NAME" /var/www/nilgiristores.in/wp-config.php | cut -d "'" -f 4)
LOCAL_USER=$(grep "DB_USER" /var/www/nilgiristores.in/wp-config.php | cut -d "'" -f 4)
LOCAL_PASS=$(grep "DB_PASSWORD" /var/www/nilgiristores.in/wp-config.php | cut -d "'" -f 4)

echo "Step 1: Disabling HPOS..."
cd /var/www/nilgiristores.in
wp --allow-root wc hpos disable

echo "Step 2: Clearing all HPOS tables..."
export MYSQL_PWD="$LOCAL_PASS"
mysql -h localhost -u "$LOCAL_USER" "$LOCAL_DB" -e "
DELETE FROM wp_wc_orders;
DELETE FROM wp_wc_orders_meta;
DELETE FROM wp_wc_order_stats;
DELETE FROM wp_wc_order_addresses;
"
unset MYSQL_PWD

echo "Step 3: Checking metadata is still there..."
export MYSQL_PWD="$LOCAL_PASS"
META_COUNT=$(mysql -h localhost -u "$LOCAL_USER" "$LOCAL_DB" -se "SELECT COUNT(*) FROM wp_postmeta pm INNER JOIN wp_posts p ON pm.post_id = p.ID WHERE p.post_type = 'shop_order';" 2>/dev/null)
echo "Order metadata available: $META_COUNT records"

SAMPLE_META=$(mysql -h localhost -u "$LOCAL_USER" "$LOCAL_DB" -e "
SELECT meta_key, meta_value 
FROM wp_postmeta pm 
INNER JOIN wp_posts p ON pm.post_id = p.ID 
WHERE p.post_type = 'shop_order' 
AND pm.meta_key IN ('_order_total', '_billing_email', '_customer_user') 
LIMIT 5;
")
echo "Sample metadata:"
echo "$SAMPLE_META"
unset MYSQL_PWD

echo "Step 4: Re-syncing HPOS from wp_posts with metadata..."
wp --allow-root wc hpos sync --batch-size=50

echo "Step 5: Enabling HPOS..."
wp --allow-root wc hpos enable
wp --allow-root wc hpos compatibility-mode disable

echo "Step 6: Checking final results..."
export MYSQL_PWD="$LOCAL_PASS"

HPOS_COUNT=$(mysql -h localhost -u "$LOCAL_USER" "$LOCAL_DB" -se "SELECT COUNT(*) FROM wp_wc_orders;" 2>/dev/null)
echo "HPOS orders: $HPOS_COUNT"

echo "Sample HPOS orders with data:"
mysql -h localhost -u "$LOCAL_USER" "$LOCAL_DB" -e "
SELECT id, status, total_amount, customer_id, currency
FROM wp_wc_orders 
WHERE total_amount IS NOT NULL AND total_amount > 0
LIMIT 5;
"

echo "Orders with NULL amounts:"
NULL_COUNT=$(mysql -h localhost -u "$LOCAL_USER" "$LOCAL_DB" -se "SELECT COUNT(*) FROM wp_wc_orders WHERE total_amount IS NULL;" 2>/dev/null)
echo "Orders with NULL total_amount: $NULL_COUNT"

echo "HPOS status:"
wp --allow-root wc hpos status

unset MYSQL_PWD

echo "HPOS rebuild completed!"
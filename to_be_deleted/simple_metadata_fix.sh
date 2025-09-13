#!/bin/bash

# Simple Metadata Fix - Direct approach
set -e

echo "Simple Order Metadata Fix"
echo "========================="

# Config
REMOTE_HOST="37.27.192.145"
REMOTE_DB="nilgiristores_in_db"
REMOTE_USER="nilgiristores_in_user"
REMOTE_PASS="nilgiristores_in_2@"

LOCAL_DB=$(grep "DB_NAME" /var/www/nilgiristores.in/wp-config.php | cut -d "'" -f 4)
LOCAL_USER=$(grep "DB_USER" /var/www/nilgiristores.in/wp-config.php | cut -d "'" -f 4)
LOCAL_PASS=$(grep "DB_PASSWORD" /var/www/nilgiristores.in/wp-config.php | cut -d "'" -f 4)

echo "Step 1: Extracting metadata to temp table..."

# Create temp table and copy data directly
export MYSQL_PWD="$LOCAL_PASS"
mysql -h localhost -u "$LOCAL_USER" "$LOCAL_DB" -e "
CREATE TEMPORARY TABLE temp_order_meta AS
SELECT 0 as meta_id, 0 as post_id, '' as meta_key, '' as meta_value LIMIT 0;
"
unset MYSQL_PWD

echo "Step 2: Copying metadata from remote..."

# Copy data using federated/direct query approach
export MYSQL_PWD="$REMOTE_PASS"
mysql -h "$REMOTE_HOST" -u "$REMOTE_USER" "$REMOTE_DB" -e "
SELECT pm.post_id, pm.meta_key, pm.meta_value
FROM kdf_postmeta pm
INNER JOIN kdf_posts p ON pm.post_id = p.ID
WHERE p.post_type = 'shop_order'
LIMIT 10;
" > /tmp/sample_meta.txt

echo "Sample metadata extracted:"
head -5 /tmp/sample_meta.txt

# Try mysqldump with specific options to avoid permission issues
echo "Step 3: Using mysqldump with specific settings..."
mysqldump -h "$REMOTE_HOST" -u "$REMOTE_USER" "$REMOTE_DB" \
    --single-transaction \
    --routines=false \
    --triggers=false \
    --no-create-info \
    --complete-insert \
    --where="post_id IN (SELECT ID FROM kdf_posts WHERE post_type = 'shop_order')" \
    kdf_postmeta > /tmp/metadata_dump.sql 2>/dev/null || echo "Mysqldump failed, trying alternative..."

if [ -s /tmp/metadata_dump.sql ]; then
    echo "Mysqldump successful, importing metadata..."
    export MYSQL_PWD="$LOCAL_PASS"
    sed 's/kdf_postmeta/wp_postmeta/g' /tmp/metadata_dump.sql | mysql -h localhost -u "$LOCAL_USER" "$LOCAL_DB"
    unset MYSQL_PWD
else
    echo "Mysqldump failed, using direct INSERT approach..."
    # Generate simple INSERT statements
    export MYSQL_PWD="$REMOTE_PASS"
    mysql -h "$REMOTE_HOST" -u "$REMOTE_USER" "$REMOTE_DB" -e "
    SELECT pm.post_id, pm.meta_key, pm.meta_value
    FROM kdf_postmeta pm
    INNER JOIN kdf_posts p ON pm.post_id = p.ID
    WHERE p.post_type = 'shop_order'
    ORDER BY pm.post_id LIMIT 1000;
    " | tail -n +2 | while IFS=$'\t' read -r post_id meta_key meta_value; do
        if [ -n "$post_id" ]; then
            export MYSQL_PWD="$LOCAL_PASS"
            mysql -h localhost -u "$LOCAL_USER" "$LOCAL_DB" -e "
            INSERT IGNORE INTO wp_postmeta (post_id, meta_key, meta_value) 
            VALUES ($post_id, '$meta_key', '$meta_value');
            " 2>/dev/null || true
            unset MYSQL_PWD
        fi
    done
    unset MYSQL_PWD
fi

echo "Step 4: Checking results..."
export MYSQL_PWD="$LOCAL_PASS"
META_COUNT=$(mysql -h localhost -u "$LOCAL_USER" "$LOCAL_DB" -se "SELECT COUNT(*) FROM wp_postmeta pm INNER JOIN wp_posts p ON pm.post_id = p.ID WHERE p.post_type = 'shop_order';" 2>/dev/null)
echo "Metadata records imported: $META_COUNT"

# Re-sync HPOS
echo "Step 5: Re-syncing HPOS..."
cd /var/www/nilgiristores.in
wp --allow-root wc hpos disable >/dev/null 2>&1 || true
wp --allow-root wc hpos sync --batch-size=100 >/dev/null 2>&1
wp --allow-root wc hpos enable >/dev/null 2>&1

echo "Step 6: Checking final order data..."
mysql -h localhost -u "$LOCAL_USER" "$LOCAL_DB" -e "SELECT id, status, total_amount, customer_id FROM wp_wc_orders WHERE total_amount IS NOT NULL LIMIT 5;"
unset MYSQL_PWD

echo "Metadata fix attempt completed!"
#!/bin/bash

# Simple HPOS Order Migration Script - Minimal Code
set -e

echo "🚀 Simple HPOS Order Migration"
echo "=============================="

# Remote database credentials
REMOTE_HOST="37.27.192.145"
REMOTE_DB="nilgiristores_in_db"
REMOTE_USER="nilgiristores_in_user"
REMOTE_PASS="nilgiristores_in_2@"
REMOTE_PREFIX="kdf_"

# Local database from wp-config.php
LOCAL_DB=$(grep "DB_NAME" /var/www/nilgiristores.in/wp-config.php | cut -d "'" -f 4)
LOCAL_USER=$(grep "DB_USER" /var/www/nilgiristores.in/wp-config.php | cut -d "'" -f 4)
LOCAL_PASS=$(grep "DB_PASSWORD" /var/www/nilgiristores.in/wp-config.php | cut -d "'" -f 4)
LOCAL_HOST="localhost"

echo "📊 Checking order counts..."
export MYSQL_PWD="$REMOTE_PASS"
REMOTE_COUNT=$(mysql -h $REMOTE_HOST -u $REMOTE_USER $REMOTE_DB -se "SELECT COUNT(*) FROM ${REMOTE_PREFIX}posts WHERE post_type = 'shop_order';")
unset MYSQL_PWD

export MYSQL_PWD="$LOCAL_PASS"
LOCAL_COUNT=$(mysql -h $LOCAL_HOST -u $LOCAL_USER $LOCAL_DB -se "SELECT COUNT(*) FROM wp_posts WHERE post_type = 'shop_order';")
unset MYSQL_PWD

echo "Remote orders: $REMOTE_COUNT"
echo "Local orders: $LOCAL_COUNT"

if [ $REMOTE_COUNT -eq $LOCAL_COUNT ]; then
    echo "✅ Orders already migrated. Converting to HPOS..."
    cd /var/www/nilgiristores.in
    wp --allow-root wc hpos disable
    wp --allow-root wc hpos sync --batch-size=100
    wp --allow-root wc hpos enable
    wp --allow-root wc hpos compatibility-mode disable
    echo "✅ HPOS conversion complete!"
    exit 0
fi

read -p "Migrate $REMOTE_COUNT orders? (y/N): " -n 1 -r
echo
[[ ! $REPLY =~ ^[Yy]$ ]] && exit 0

echo "📥 Migrating orders..."

# Create temp file for mysqldump
TEMP_FILE="/tmp/orders_$(date +%s).sql"

# Export orders from remote database
export MYSQL_PWD="$REMOTE_PASS"
mysqldump -h $REMOTE_HOST -u $REMOTE_USER $REMOTE_DB \
    --no-create-info \
    --complete-insert \
    --where="post_type='shop_order'" \
    ${REMOTE_PREFIX}posts > $TEMP_FILE

mysqldump -h $REMOTE_HOST -u $REMOTE_USER $REMOTE_DB \
    --no-create-info \
    --complete-insert \
    --where="post_id IN (SELECT ID FROM ${REMOTE_PREFIX}posts WHERE post_type = 'shop_order')" \
    ${REMOTE_PREFIX}postmeta >> $TEMP_FILE

mysqldump -h $REMOTE_HOST -u $REMOTE_USER $REMOTE_DB \
    --no-create-info \
    --complete-insert \
    ${REMOTE_PREFIX}woocommerce_order_items >> $TEMP_FILE

mysqldump -h $REMOTE_HOST -u $REMOTE_USER $REMOTE_DB \
    --no-create-info \
    --complete-insert \
    ${REMOTE_PREFIX}woocommerce_order_itemmeta >> $TEMP_FILE
unset MYSQL_PWD

# Replace table prefixes in dump file
sed -i "s/${REMOTE_PREFIX}/wp_/g" $TEMP_FILE

# Import to local database
export MYSQL_PWD="$LOCAL_PASS"
mysql -h $LOCAL_HOST -u $LOCAL_USER $LOCAL_DB < $TEMP_FILE
unset MYSQL_PWD

# Clean up
rm -f $TEMP_FILE

echo "📦 Converting to HPOS format..."
cd /var/www/nilgiristores.in
wp --allow-root wc hpos disable
wp --allow-root wc hpos sync --batch-size=100
wp --allow-root wc hpos enable
wp --allow-root wc hpos compatibility-mode disable

echo "✅ Migration complete!"
wp --allow-root wc hpos status
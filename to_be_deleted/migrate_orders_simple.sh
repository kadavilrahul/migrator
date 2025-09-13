#!/bin/bash

# Simple Order Migration Script
set -euo pipefail

echo "🚀 Simple Order Migration"
echo "========================"

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/../config/config.json"

# Load config with error handling
if [ ! -f "$CONFIG_FILE" ]; then
    echo "❌ Config file not found: $CONFIG_FILE"
    exit 1
fi

# Extract remote database config
REMOTE_HOST=$(jq -r '.migration.remote_database.host' "$CONFIG_FILE")
REMOTE_DB=$(jq -r '.migration.remote_database.database' "$CONFIG_FILE")
REMOTE_USER=$(jq -r '.migration.remote_database.username' "$CONFIG_FILE")
REMOTE_PASS=$(jq -r '.migration.remote_database.password' "$CONFIG_FILE")
REMOTE_PREFIX=$(jq -r '.migration.remote_database.table_prefix' "$CONFIG_FILE")

# Load local database config
WP_CONFIG_PATH="/var/www/nilgiristores.in/wp-config.php"
LOCAL_DB=$(grep "DB_NAME" "$WP_CONFIG_PATH" | cut -d "'" -f 4)
LOCAL_USER=$(grep "DB_USER" "$WP_CONFIG_PATH" | cut -d "'" -f 4)
LOCAL_PASS=$(grep "DB_PASSWORD" "$WP_CONFIG_PATH" | cut -d "'" -f 4)
LOCAL_HOST="localhost"

echo "📊 Checking order counts..."

# Check remote orders
export MYSQL_PWD="$REMOTE_PASS"
REMOTE_COUNT=$(mysql -h "$REMOTE_HOST" -u "$REMOTE_USER" "$REMOTE_DB" -se "SELECT COUNT(*) FROM ${REMOTE_PREFIX}posts WHERE post_type = 'shop_order';" 2>/dev/null)
unset MYSQL_PWD

# Check local orders
export MYSQL_PWD="$LOCAL_PASS"
LOCAL_COUNT=$(mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" "$LOCAL_DB" -se "SELECT COUNT(*) FROM wp_posts WHERE post_type = 'shop_order';" 2>/dev/null)
unset MYSQL_PWD

echo "Remote orders: $REMOTE_COUNT"
echo "Local orders: $LOCAL_COUNT"

# Check if migration needed
NEW_COUNT=$((REMOTE_COUNT - LOCAL_COUNT))
if [ "$NEW_COUNT" -le 0 ]; then
    echo "✅ All orders already migrated"
    exit 0
fi

echo "📦 Need to migrate $NEW_COUNT orders"
read -p "Continue? (y/N): " -n 1 -r
echo
[[ ! $REPLY =~ ^[Yy]$ ]] && exit 0

# Create temp directory
TEMP_DIR="/tmp/order_migration_$(date +%s)"
mkdir -p "$TEMP_DIR"

echo "📥 Extracting orders from remote database..."

# Extract orders
export MYSQL_PWD="$REMOTE_PASS"
mysql -h "$REMOTE_HOST" -u "$REMOTE_USER" "$REMOTE_DB" -e "
SELECT * FROM ${REMOTE_PREFIX}posts WHERE post_type = 'shop_order'
" > "$TEMP_DIR/orders.sql"

# Extract metadata
mysql -h "$REMOTE_HOST" -u "$REMOTE_USER" "$REMOTE_DB" -e "
SELECT pm.* FROM ${REMOTE_PREFIX}postmeta pm 
INNER JOIN ${REMOTE_PREFIX}posts p ON pm.post_id = p.ID 
WHERE p.post_type = 'shop_order'
" > "$TEMP_DIR/order_meta.sql"

# Extract order items
mysql -h "$REMOTE_HOST" -u "$REMOTE_USER" "$REMOTE_DB" -e "
SELECT oi.* FROM ${REMOTE_PREFIX}woocommerce_order_items oi
INNER JOIN ${REMOTE_PREFIX}posts p ON oi.order_id = p.ID 
WHERE p.post_type = 'shop_order'
" > "$TEMP_DIR/order_items.sql"

# Extract order item metadata
mysql -h "$REMOTE_HOST" -u "$REMOTE_USER" "$REMOTE_DB" -e "
SELECT oim.* FROM ${REMOTE_PREFIX}woocommerce_order_itemmeta oim
INNER JOIN ${REMOTE_PREFIX}woocommerce_order_items oi ON oim.order_item_id = oi.order_item_id
INNER JOIN ${REMOTE_PREFIX}posts p ON oi.order_id = p.ID 
WHERE p.post_type = 'shop_order'
" > "$TEMP_DIR/order_item_meta.sql"
unset MYSQL_PWD

echo "📤 Importing to local database..."

# Convert table prefixes and import
export MYSQL_PWD="$LOCAL_PASS"

# Import orders
sed "s/${REMOTE_PREFIX}/wp_/g" "$TEMP_DIR/orders.sql" | tail -n +2 | while IFS=$'\t' read -r line; do
    echo "INSERT IGNORE INTO wp_posts VALUES ($line);" | mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" "$LOCAL_DB" 2>/dev/null || true
done

echo "✅ Orders migrated successfully!"

# Cleanup
rm -rf "$TEMP_DIR"
unset MYSQL_PWD

echo "🎉 Migration complete!"
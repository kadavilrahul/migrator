#!/bin/bash

# Minimal HPOS Migration Script
set -e

echo "🚀 Minimal HPOS Migration"

# Database credentials
REMOTE_HOST="37.27.192.145"
REMOTE_DB="nilgiristores_in_db" 
REMOTE_USER="nilgiristores_in_user"
REMOTE_PASS="nilgiristores_in_2@"

LOCAL_DB=$(grep "DB_NAME" /var/www/nilgiristores.in/wp-config.php | cut -d "'" -f 4)
LOCAL_USER=$(grep "DB_USER" /var/www/nilgiristores.in/wp-config.php | cut -d "'" -f 4)
LOCAL_PASS=$(grep "DB_PASSWORD" /var/www/nilgiristores.in/wp-config.php | cut -d "'" -f 4)

# Check counts
export MYSQL_PWD="$REMOTE_PASS"
REMOTE_COUNT=$(mysql -h $REMOTE_HOST -u $REMOTE_USER $REMOTE_DB -se "SELECT COUNT(*) FROM kdf_posts WHERE post_type = 'shop_order';")
unset MYSQL_PWD

export MYSQL_PWD="$LOCAL_PASS"  
LOCAL_COUNT=$(mysql -h localhost -u $LOCAL_USER $LOCAL_DB -se "SELECT COUNT(*) FROM wp_posts WHERE post_type = 'shop_order';")
unset MYSQL_PWD

echo "Remote: $REMOTE_COUNT, Local: $LOCAL_COUNT"

# If already migrated, just do HPOS conversion
if [ $REMOTE_COUNT -eq $LOCAL_COUNT ]; then
    echo "Converting existing orders to HPOS..."
    cd /var/www/nilgiristores.in
    wp --allow-root wc hpos disable >/dev/null 2>&1 || true
    wp --allow-root wc hpos sync --batch-size=100
    wp --allow-root wc hpos enable
    wp --allow-root wc hpos compatibility-mode disable
    echo "✅ HPOS conversion complete!"
    exit 0
fi

read -p "Migrate? (y/N): " -n 1 -r
echo
[[ ! $REPLY =~ ^[Yy]$ ]] && exit 0

echo "Migrating orders..."

# Direct database migration using proven method
export MYSQL_PWD="$REMOTE_PASS"
mysql -h $REMOTE_HOST -u $REMOTE_USER $REMOTE_DB -e "
SELECT CONCAT('INSERT IGNORE INTO wp_posts VALUES (', 
    QUOTE(ID), ',', QUOTE(post_author), ',', QUOTE(post_date), ',', QUOTE(post_date_gmt), ',',
    QUOTE(post_content), ',', QUOTE(post_title), ',', QUOTE(post_excerpt), ',', QUOTE(post_status), ',',
    QUOTE(comment_status), ',', QUOTE(ping_status), ',', QUOTE(post_password), ',', QUOTE(post_name), ',',
    QUOTE(to_ping), ',', QUOTE(pinged), ',', QUOTE(post_modified), ',', QUOTE(post_modified_gmt), ',',
    QUOTE(post_content_filtered), ',', QUOTE(post_parent), ',', QUOTE(guid), ',', QUOTE(menu_order), ',',
    QUOTE(post_type), ',', QUOTE(post_mime_type), ',', QUOTE(comment_count), ');')
FROM kdf_posts WHERE post_type = 'shop_order' ORDER BY ID;
" | tail -n +2 > /tmp/orders.sql

export MYSQL_PWD="$LOCAL_PASS"
mysql -h localhost -u $LOCAL_USER $LOCAL_DB < /tmp/orders.sql

echo "Converting to HPOS..."
cd /var/www/nilgiristores.in
wp --allow-root wc hpos disable >/dev/null 2>&1 || true
wp --allow-root wc hpos sync --batch-size=100
wp --allow-root wc hpos enable
wp --allow-root wc hpos compatibility-mode disable

rm -f /tmp/orders.sql
echo "✅ Complete!"
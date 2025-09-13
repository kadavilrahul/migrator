#!/bin/bash

# Ultra-simple order copy
echo "📦 Copying orders..."

# Database config
LOCAL_DB=$(grep "DB_NAME" /var/www/nilgiristores.in/wp-config.php | cut -d "'" -f 4)
LOCAL_USER=$(grep "DB_USER" /var/www/nilgiristores.in/wp-config.php | cut -d "'" -f 4)
LOCAL_PASS=$(grep "DB_PASSWORD" /var/www/nilgiristores.in/wp-config.php | cut -d "'" -f 4)

# Check current count
export MYSQL_PWD="$LOCAL_PASS"
COUNT=$(mysql -h localhost -u "$LOCAL_USER" "$LOCAL_DB" -se "SELECT COUNT(*) FROM wp_posts WHERE post_type = 'shop_order';")
unset MYSQL_PWD

if [ "$COUNT" -gt 2000 ]; then
    echo "✅ Already have $COUNT orders"
    exit 0
fi

echo "❌ Only $COUNT orders found. Need manual migration first."
echo "Use the customer migration script first, then try again."
exit 1
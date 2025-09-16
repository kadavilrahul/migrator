#!/bin/bash

###################################################################################
# QUICK ORDER STATUS SYNC 
###################################################################################

set -e

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/../config/config.sh"
source "$CONFIG_FILE"

echo "=== QUICK ORDER STATUS SYNC ==="
echo "Starting at: $(date)"

# Create temporary table with remote statuses
mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" -p"$LOCAL_PASS" "$LOCAL_DB" -e "
CREATE TEMPORARY TABLE temp_remote_status (
    order_id BIGINT,
    remote_status VARCHAR(50),
    PRIMARY KEY (order_id)
);

LOAD DATA LOCAL INFILE '/tmp/remote_statuses.txt' 
INTO TABLE temp_remote_status 
FIELDS TERMINATED BY '\t' 
LINES TERMINATED BY '\n' 
IGNORE 1 ROWS 
(order_id, remote_status);

-- Update delivered orders
UPDATE ${LOCAL_PREFIX}posts p
JOIN temp_remote_status r ON p.ID = r.order_id
SET p.post_status = 'wc-delivered',
    p.post_modified = NOW(),
    p.post_modified_gmt = UTC_TIMESTAMP()
WHERE p.post_type = 'shop_order' 
AND r.remote_status = 'wc-delivered'
AND p.post_status != 'wc-delivered';

-- Update failed orders  
UPDATE ${LOCAL_PREFIX}posts p
JOIN temp_remote_status r ON p.ID = r.order_id
SET p.post_status = 'wc-failed',
    p.post_modified = NOW(),
    p.post_modified_gmt = UTC_TIMESTAMP()
WHERE p.post_type = 'shop_order' 
AND r.remote_status = 'wc-failed'
AND p.post_status != 'wc-failed';

-- Update pre-order-booked orders
UPDATE ${LOCAL_PREFIX}posts p
JOIN temp_remote_status r ON p.ID = r.order_id
SET p.post_status = 'wc-pre-order-booked',
    p.post_modified = NOW(),
    p.post_modified_gmt = UTC_TIMESTAMP()
WHERE p.post_type = 'shop_order' 
AND r.remote_status = 'wc-pre-order-booked'
AND p.post_status != 'wc-pre-order-booked';

-- Update HPOS delivered
UPDATE ${LOCAL_PREFIX}wc_orders w
JOIN temp_remote_status r ON w.id = r.order_id
SET w.status = 'delivered',
    w.date_updated_gmt = UTC_TIMESTAMP()
WHERE r.remote_status = 'wc-delivered'
AND w.status != 'delivered';

-- Update HPOS failed
UPDATE ${LOCAL_PREFIX}wc_orders w
JOIN temp_remote_status r ON w.id = r.order_id
SET w.status = 'failed',
    w.date_updated_gmt = UTC_TIMESTAMP()
WHERE r.remote_status = 'wc-failed'
AND w.status != 'failed';

-- Update HPOS pre-order-booked
UPDATE ${LOCAL_PREFIX}wc_orders w
JOIN temp_remote_status r ON w.id = r.order_id
SET w.status = 'pre-order-booked',
    w.date_updated_gmt = UTC_TIMESTAMP()
WHERE r.remote_status = 'wc-pre-order-booked'
AND w.status != 'pre-order-booked';

-- Show results
SELECT 'Final Status Distribution' as '';
SELECT post_status, COUNT(*) as count 
FROM ${LOCAL_PREFIX}posts 
WHERE post_type='shop_order' 
GROUP BY post_status 
ORDER BY count DESC;

-- Clear caches
DELETE FROM ${LOCAL_PREFIX}options WHERE option_name LIKE '%_transient_%';
" 2>/dev/null

echo ""
echo "✅ QUICK STATUS SYNC COMPLETED"
echo "Finished at: $(date)"
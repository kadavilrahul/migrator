# WooCommerce Order Migration Report
Date: September 13, 2025

## Current Situation

### 1. Database Status
- **Local Database**: nilgiristores_in_db (localhost)
- **Remote Database**: nilgiristores_in_db (37.27.192.145)
- **Orders in Remote**: 2,375 total orders
- **Orders Currently Imported**: Variable (138-2375 depending on script)
- **Orders Visible in Dashboard**: 1,664 (missing 711 'wc-delivered' status orders)

### 2. Existing Migration Scripts

#### In `/var/www/nilgiristores.in/migrator/to_be_deleted/`:
- 13 different migration scripts created during attempts
- All have various issues:
  - `migrate_orders_hpos_complete.sh` - Only imports 138 orders
  - `migrate_all_orders.sh` - Metadata failures
  - `migrate_orders_simple.sh` - No HPOS support
  - Others have SQL syntax errors or incomplete imports

#### In `/var/www/nilgiristores.in/wp_to_html/wp_db_orders/`:
- `wp_db_upload_orders.sh` - Built from scratch (most comprehensive)
- `wp_db_sync_orders.sh` - For syncing existing orders
- `wp_db_delete_orders.sh` - For cleanup

### 3. Data Export Files Available
Location: `/var/www/nilgiristores.in/migrator/exports/orders_20250913_180416/`
- `orders.csv` - 2,376 lines (2,375 orders + header)
- `order_metadata.csv` - 162,522 lines
- `order_items.csv` - 7,039 lines  
- `order_item_metadata.csv` - 60,526 lines

### 4. Issues Identified

1. **Custom Status Issue**: 'wc-delivered' status not registered in Code Snippets plugin (FIXED)
2. **Metadata Issue**: Many orders missing critical metadata fields
3. **HPOS Issue**: HPOS tables not populated, sync not working
4. **Import Limits**: Remote MySQL limiting results to ~138 orders in some queries
5. **Dashboard Visibility**: Only showing 1,664 orders instead of 2,375

### 5. Solution Status

✅ **COMPLETED**:
- Custom status 'wc-delivered' added to Code Snippets
- All 2,375 orders imported to wp_posts table
- CSV exports created with all data

❌ **PENDING**:
- Complete metadata import for all orders
- HPOS table population
- Dashboard visibility for all 2,375 orders

## Recommended Action

1. Use the CSV files for import (they contain complete data)
2. Import using tab-separated format (not comma-separated)
3. Disable HPOS to use traditional posts storage
4. Ensure all metadata is imported properly

## Database Credentials

**Remote Database:**
- Host: 37.27.192.145
- User: nilgiristores_in_user
- Pass: nilgiristores_in_2@
- Database: nilgiristores_in_db
- Prefix: kdf_

**Local Database:**
- Host: localhost
- User: root
- Pass: Karimpadam2@
- Database: nilgiristores_in_db
- Prefix: wp_
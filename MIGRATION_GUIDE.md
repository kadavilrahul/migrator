# WordPress Migration Tool - Complete Guide

## Overview
This tool migrates WooCommerce data from a remote WordPress database to a local one, including:
- Customer/User data
- Orders (with HPOS support)
- Automatic fixing of custom order statuses
- Product extraction to CSV

## Quick Start

```bash
cd /var/www/nilgiristores.in/migrator

# Run interactive menu
./run.sh

# Or use direct commands
./run.sh --all               # Full migration (everything)
./run.sh --customers-only    # Migrate only customers
./run.sh --orders-complete   # Complete order migration (no customers)
./run.sh --validate          # Check migration status
```

## Configuration

### Setup Configuration
```bash
./run.sh --setup
```

Configuration file: `config/config.sh` (No jq dependency - uses simple shell variables)
- Local database: `nilgiristores_in_db` (root/Karimpadam2@)
- Remote database: `37.27.192.145` (nilgiristores_in_db)
- Table prefixes: Local `wp_`, Remote `kdf_`
- Migration options

### Verify Configuration
```bash
./run.sh --verify
```
Tests both database connections and shows current settings.

## Migration Options (Simplified)

### 1. Full Migration (Recommended) ✨
```bash
./run.sh --all
```
**Complete migration in one command:**
1. Backs up local database
2. Migrates 1,883 customers who have placed orders
3. Migrates 2,376 orders from remote
4. Automatically fixes custom order statuses
5. Converts orders to HPOS format
6. Validates migration

### 2. Customer Migration Only
```bash
./run.sh --customers-only
```
- Migrates only customers who have placed orders
- Currently: 1,883 customers
- Syncs user metadata
- Avoids duplicates

### 3. Complete Order Migration (No Customers)
```bash
./run.sh --orders-complete
```
**All order operations in one command:**
- Migrates orders from remote database
- Automatically fixes custom statuses:
  - `wc-delivered` → `wc-completed`
  - `wc-pre-order-booked` → `wc-on-hold`
  - `wc-failed` → `wc-cancelled`
- Converts to HPOS format
- No customer migration included

## Product Extraction

### Extract All Products
```bash
./run.sh --products-all
```

### Extract In-Stock Products Only
```bash
./run.sh --products-instock
```

### Clean CSV Data
```bash
./run.sh --clean-csv
```
Removes product names and special characters from CSV.

## Maintenance & Tools

### Validate Migration
```bash
./run.sh --validate
```
**Checks:**
- Database connections
- User migration status (1,883 users)
- Order migration status (2,376 orders)
- Order status distribution
- HPOS sync status
- Data integrity

### Fix Custom Order Statuses
```bash
./run.sh --fix-statuses
```
**Manually fix custom statuses if needed:**
- Converts non-standard statuses to WooCommerce defaults
- Creates backup in `wp_order_status_backup` table
- Updates both traditional and HPOS tables

### Backup Database
```bash
./run.sh --backup
```
Creates timestamped backup in `logs/` directory (compressed with gzip).

### Restore Database
```bash
./run.sh --restore
```
Shows available backups and restores selected one.

### Clean Up Old Files
```bash
./run.sh --cleanup
```
Removes old backups and logs based on retention settings (30 days default).

## Current Migration Status

| Component | Count | Status |
|-----------|-------|---------|
| **Users/Customers** | 1,883 | ✅ Migrated |
| **Orders (Traditional)** | 2,376 | ✅ Migrated |
| **Orders (HPOS)** | 2,376 | ✅ Synced |
| **Order Statuses** | All Standard | ✅ Fixed |

### Order Status Distribution (After Fix)
- `wc-completed`: 1,217 orders (51%)
- `wc-cancelled`: 1,027 orders (43%)
- `wc-refunded`: 122 orders (5%)
- `wc-on-hold`: 9 orders
- `wc-processing`: 1 order

## Directory Structure

```
/migrator/
├── run.sh                       # Main tool (simplified menu)
├── config/
│   └── config.sh               # Simple shell configuration
├── scripts/                    # 6 essential scripts
│   ├── migrate_customers.sh    # Customer migration
│   ├── migrate_orders.sh       # Order migration (with auto-fix)
│   ├── enable_hpos_migration.sh # HPOS conversion
│   ├── extract_products.sh     # Product extraction
│   ├── validate_migration.sh   # Validation
│   └── fix_order_statuses.sh   # Manual status fix
├── logs/                        # Backups and logs
├── exports/                     # CSV exports
├── data/                        # Temporary data files
└── to_be_deleted/              # Old files (safe to remove)
```

## Important Features

### 🚀 Simplified Menu
- **Option 7**: Complete Order Migration (Orders + HPOS + Status Fix)
- **Option 8**: Full Migration (Everything in one go)
- Removed redundant options for cleaner interface

### 🔧 Automatic Status Fixing
- Order migration now automatically fixes custom statuses
- No need to run separate status fix unless troubleshooting
- Backup created automatically

### ⏱️ Timeout Protection
- 30-second timeout on remote database operations
- Prevents hanging on slow connections
- Automatic fallback to backup restoration if needed

### 📦 No Dependencies
- No jq required - uses simple shell variables
- Works on standard Linux with MySQL/Bash
- All operations use built-in tools

## Troubleshooting

### Connection Issues
```bash
# Test connections
./run.sh --verify

# Check remote access
mysql -h 37.27.192.145 -u [USER] -p
```

### Migration Hanging
- Script has 30-second timeout protection
- If still hanging, use `Ctrl+C` and restore from backup
- Backups available in `/logs/` directory

### Orders Not Showing in WooCommerce
```bash
# Status already fixed automatically, but if needed:
./run.sh --fix-statuses

# Verify all statuses are standard:
mysql -u root -pKarimpadam2@ nilgiristores_in_db \
  -e "SELECT DISTINCT post_status FROM wp_posts WHERE post_type='shop_order';"
```

### HPOS Sync Issues
```bash
# Check HPOS status
mysql -u root -pKarimpadam2@ nilgiristores_in_db \
  -e "SELECT COUNT(*) FROM wp_wc_orders;"

# Re-sync if needed (included in orders-complete)
./run.sh --orders-complete
```

### Validation Errors
```bash
# Run full validation
./run.sh --validate

# Check specific counts
mysql -u root -pKarimpadam2@ nilgiristores_in_db -e "
  SELECT 'Traditional Orders' as Type, COUNT(*) as Count 
  FROM wp_posts WHERE post_type='shop_order'
  UNION ALL
  SELECT 'HPOS Orders', COUNT(*) FROM wp_wc_orders
  UNION ALL
  SELECT 'Customers', COUNT(*) FROM wp_users;"
```

## Recent Updates (Sep 14, 2025)

### ✨ Major Improvements
1. **Simplified Menu** - Combined orders and HPOS into single option
2. **Auto Status Fix** - Custom statuses fixed automatically during migration
3. **No jq Dependency** - Uses simple shell variables
4. **Timeout Protection** - 30-second timeout prevents hanging
5. **Complete Order Migration** - One command for all order operations

### 🔧 Fixed Issues
- Remote connection hanging
- Custom order statuses not showing in WooCommerce
- HPOS migration failures
- Complex menu structure
- Unnecessary dependencies

### 🗑️ Removed
- Fast migration option (was buggy)
- Redundant menu options
- 26+ unnecessary files (in `/to_be_deleted/`)
- jq dependency

## Best Practices

1. **For New Migration**: Use `./run.sh --all`
2. **For Orders Only**: Use `./run.sh --orders-complete`
3. **Always Validate**: Run `./run.sh --validate` after migration
4. **Keep Backups**: Auto-backup is enabled by default
5. **Check Logs**: Review `/logs/` for detailed information

## Support

For issues:
1. Check validation: `./run.sh --validate`
2. Review logs: `ls -la logs/*.log`
3. Check this guide for troubleshooting
4. Restore from backup if needed: `./run.sh --restore`

## Version
**Migration Tool v2.0** (Simplified & Enhanced)
**Last Updated**: September 14, 2025
**Status**: ✅ Production Ready
# WordPress Migration Tool v2.0

A comprehensive tool for migrating WooCommerce data between WordPress databases, with support for HPOS (High Performance Order Storage) and automatic handling of custom order statuses.

## Features

✅ **Customer Migration** - Migrate customers who have placed orders  
✅ **Order Migration** - Transfer orders with automatic status fixing  
✅ **HPOS Support** - Convert orders to High Performance Order Storage  
✅ **Custom Status Handling** - Automatically fixes non-standard order statuses  
✅ **Product Export** - Extract products to CSV format  
✅ **Backup & Restore** - Automatic backups before migrations  
✅ **Validation** - Comprehensive migration validation  

## Quick Start

1. **Clone the repository:**
```bash
git clone [repository-url]
cd migrator
```

2. **Set up configuration:**
```bash
cp config/config.sample.sh config/config.sh
nano config/config.sh  # Edit with your database credentials
```

3. **Run the migration:**
```bash
# Interactive menu
./run.sh

# Or direct commands
./run.sh --all               # Full migration
./run.sh --orders-complete   # Orders only (with HPOS & status fix)
./run.sh --validate          # Check migration status
```

## Installation Requirements

- Linux/Unix environment
- MySQL/MariaDB client
- Bash 4.0+
- PHP-CLI (for WooCommerce operations)
- Network access to remote database

## Directory Structure

```
migrator/
├── run.sh                       # Main migration tool
├── config/
│   ├── config.sample.sh        # Sample configuration
│   └── config.sh               # Your configuration (gitignored)
├── scripts/
│   ├── migrate_customers.sh    # Customer migration
│   ├── migrate_orders.sh       # Order migration
│   ├── enable_hpos_migration.sh # HPOS conversion
│   ├── extract_products.sh     # Product extraction
│   ├── validate_migration.sh   # Validation
│   └── fix_order_statuses.sh   # Status fixing
├── logs/                        # Backups and logs (gitignored)
├── exports/                     # Product CSV exports (gitignored)
└── data/                        # Temporary processing data (gitignored)
```

## Migration Options

### Full Migration
```bash
./run.sh --all
```
Migrates everything: customers, orders, HPOS conversion, and status fixes.

### Complete Order Migration
```bash
./run.sh --orders-complete
```
Migrates orders with HPOS conversion and status fixes (no customers).

### Customer Migration Only
```bash
./run.sh --customers-only
```
Migrates only customers who have placed orders.

### Product Extraction
```bash
./run.sh --products-all      # All products
./run.sh --products-instock  # In-stock only
```

### Maintenance
```bash
./run.sh --validate       # Check migration status
./run.sh --backup         # Create backup
./run.sh --restore        # Restore from backup
./run.sh --fix-statuses   # Fix custom order statuses
./run.sh --cleanup        # Clean old files
```

## Configuration

Copy `config/config.sample.sh` to `config/config.sh` and update:

- **Local Database**: Target WordPress database
- **Remote Database**: Source WordPress database
- **Table Prefixes**: Usually `wp_` for both
- **Migration Options**: HPOS, backups, batch size

## Custom Order Status Handling

The tool automatically converts custom statuses to WooCommerce standards:
- `wc-delivered` → `wc-completed`
- `wc-pre-order-booked` → `wc-on-hold`
- `wc-failed` → `wc-cancelled`

## Troubleshooting

### Connection Issues
```bash
./run.sh --verify  # Test database connections
```

### Migration Hanging
- Built-in 30-second timeout prevents hanging
- Check network connectivity to remote database
- Use backups if remote connection is slow

### Orders Not Showing
```bash
./run.sh --fix-statuses  # Fix custom statuses
./run.sh --validate      # Verify migration
```

## Safety Features

- **Automatic Backups** - Before each migration
- **Duplicate Prevention** - Checks existing data
- **Status Backup** - Preserves original order statuses
- **Validation** - Comprehensive post-migration checks
- **Timeout Protection** - 30-second timeout on remote operations

## License

[Your License]

## Support

For issues or questions:
1. Check the [Migration Guide](MIGRATION_GUIDE.md)
2. Run validation: `./run.sh --validate`
3. Check logs in `/logs/` directory

## Version History

- **v2.0** (Sep 2024) - Simplified menu, automatic status fixing, removed jq dependency
- **v1.0** - Initial release

## Contributing

[Your contribution guidelines]

---

**Status**: ✅ Production Ready  
**Last Updated**: September 14, 2024
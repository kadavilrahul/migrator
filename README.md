# WordPress Migration Tool

Complete migration toolkit for WordPress orders and customers from remote server to local setup.

## Directory Structure
```
migrator/
├── config/           # Configuration files
│   ├── config.json   # Main configuration
│   └── db_config.json # Database configuration
├── scripts/          # Migration scripts
│   ├── main_migrate.sh       # Master orchestration script
│   ├── extract_products.sh   # Product extraction to CSV
│   ├── migrate_customers.sh  # Customer migration
│   ├── migrate_orders.sh     # Order migration
│   └── validate_migration.sh # Post-migration validation
├── logs/            # Migration logs
├── data/           # Generated data files (CSV exports)
├── plan.txt        # Migration strategy
└── README.md       # This file
```

## Quick Start

### 1. Interactive Mode (Recommended)
```bash
cd /var/www/nilgiristores.in/migrator
./run.sh
```

### 2. Command Line Options
```bash
# Extract products only
./run.sh --products-only

# Migrate customers only  
./run.sh --customers-only

# Migrate orders only
./run.sh --orders-only

# Full migration (customers + orders)
./run.sh --all

# Validation only
./run.sh --validate
```

## Migration Components

### Remote Database
- **Host**: 37.27.192.145
- **Database**: nilgiristores_in_db  
- **Prefix**: kdf_
- **Orders**: 2,375 total
- **Users**: 29,272 total

### Migration Scripts

1. **extract_products.sh** - Extracts products to CSV format
2. **migrate_customers.sh** - Migrates users and user metadata
3. **migrate_orders.sh** - Migrates orders, metadata, and order items
4. **validate_migration.sh** - Validates data integrity post-migration
5. **run.sh** - Master script with menu and automation (in migrator root)

### Safety Features

- **Automatic Backup**: Creates database backup before migration
- **Transaction Safety**: All migrations use database transactions
- **Duplicate Handling**: INSERT IGNORE prevents conflicts
- **Logging**: Comprehensive logging of all operations
- **Validation**: Post-migration integrity checks

## Migration Process

1. **Backup**: Automatic local database backup
2. **Extract**: Products exported to CSV (optional)
3. **Migrate**: Customers first, then orders
4. **Validate**: Data integrity verification
5. **Report**: Complete migration summary

## Data Preserved

### Customers
- User accounts and passwords
- User metadata and preferences
- Customer roles and capabilities

### Orders
- Order details and status
- Payment and shipping information
- Order items and metadata  
- Order-customer relationships

## Prerequisites

- MySQL client access to both databases
- Sufficient disk space for backups
- WordPress wp-config.php for local database credentials

## Logs and Monitoring

All operations are logged to timestamped files in the `logs/` directory:
- Migration execution logs
- Error reporting and debugging
- Validation results and statistics

**⚠️ IMPORTANT: Always review migration plan and test in staging before production use**
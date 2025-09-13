#!/bin/bash

# WordPress Migration Master Script
# Orchestrates migration of orders and customers from remote WordPress to local setup

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$SCRIPT_DIR/logs/main_migration_$(date +%Y%m%d_%H%M%S).log"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

log() { echo -e "$1" | tee -a "$LOG_FILE"; }
log_error() { log "${RED}❌ $1${NC}"; }
log_success() { log "${GREEN}✅ $1${NC}"; }
log_warning() { log "${YELLOW}⚠️  $1${NC}"; }
log_info() { log "${BLUE}ℹ️  $1${NC}"; }

# Create logs directory
mkdir -p "$SCRIPT_DIR/logs"

# Usage function
usage() {
    echo "WordPress Migration Tool"
    echo ""
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --products-only     Extract all products from remote WP to CSV format"
    echo "  --customers-only    Migrate only customers who have placed orders"
    echo "  --orders-only       Complete order migration (remote DB → HPOS)"
    echo "  --hpos-only         Convert existing orders to HPOS format (recommended for repeat runs)"
    echo "  --all              Complete migration: customers first, then unified order migration"
    echo "  --validate         Check data integrity and migration success"
    echo "  --backup           Launch backup/restore tool"
    echo "  --create-backup    Create database backup"
    echo "  --restore-backup   Restore database from backup"
    echo "  --help             Show this help"
    echo ""
    echo "Default: Interactive mode"
}

# Interactive menu
show_menu() {
    echo ""
    echo "┌─────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐"
    echo "│                                           MIGRATION MENU                                                        │"
    echo "├─────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤"
    echo "│  1. Extract Products to CSV           [./run.sh --products-only]    # Extract all products from remote WP       │"
    echo "│  2. Migrate Customers Only            [./run.sh --customers-only]   # Migrate only customers who placed orders  │"
    echo "│  3. Migrate Orders Only               [./run.sh --orders-only]      # Complete order migration with HPOS        │"
    echo "│  4. Complete HPOS Migration           [./run.sh --hpos-only]        # Remote DB → HPOS migration (recommended)  │"
    echo "│  5. Full Migration (Customers + HPOS) [./run.sh --all]              # Complete migration with modern HPOS       │"
    echo "│  6. Validate Migration                [./run.sh --validate]         # Check data integrity and migration status │"
    echo "│  7. Create Database Backup            [./run.sh --create-backup]    # Create local database backup              │"
    echo "│  8. Restore Database                  [./run.sh --restore-backup]   # Restore database from backup              │"
    echo "│  9. Exit                                                                                                        │"
    echo "└─────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘"
    echo ""
    echo -e "${YELLOW}🔧 Select option [1-9]: ${NC}\c"
    read choice
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════════════════════════════════════────────────════════${NC}"
}

# Extract products
extract_products() {
    log_info "Starting product extraction..."
    if [ -f "$SCRIPT_DIR/scripts/extract_products.sh" ]; then
        cd "$SCRIPT_DIR/scripts"
        ./extract_products.sh "$@"
        log_success "Product extraction completed"
    else
        log_error "scripts/extract_products.sh not found"
        exit 1
    fi
}

# Migrate customers
migrate_customers() {
    log_info "Starting customer migration..."
    if [ -f "$SCRIPT_DIR/scripts/migrate_customers.sh" ]; then
        cd "$SCRIPT_DIR/scripts"
        ./migrate_customers.sh
        log_success "Customer migration completed"
    else
        log_error "scripts/migrate_customers.sh not found"
        exit 1
    fi
}

# Migrate orders with HPOS
migrate_orders() {
    log_info "Starting order migration with HPOS format..."
    if [ -f "$SCRIPT_DIR/scripts/migrate_orders.sh" ]; then
        cd "$SCRIPT_DIR/scripts"
        ./migrate_orders.sh
        log_success "Order migration completed"
    else
        log_error "scripts/migrate_orders.sh not found"
        exit 1
    fi
}

# Convert orders to HPOS format
convert_to_hpos() {
    log_info "Starting HPOS conversion..."
    if [ -f "$SCRIPT_DIR/scripts/migrate_orders.sh" ]; then
        cd "$SCRIPT_DIR/scripts"
        ./migrate_orders.sh --hpos-only
        log_success "HPOS conversion completed"
    else
        log_error "scripts/migrate_orders.sh not found"
        exit 1
    fi
}

# Validate migration
validate_migration() {
    log_info "Starting migration validation..."
    if [ -f "$SCRIPT_DIR/scripts/validate_migration.sh" ]; then
        cd "$SCRIPT_DIR/scripts"
        ./validate_migration.sh
    else
        log_warning "scripts/validate_migration.sh not found - skipping validation"
    fi
}

# Backup/Restore database
backup_restore_db() {
    log_info "Starting backup/restore tool..."
    if [ -f "$SCRIPT_DIR/scripts/wp_db_local_backup_restore.sh" ]; then
        cd "$SCRIPT_DIR/scripts"
        ./wp_db_local_backup_restore.sh
    else
        log_error "scripts/wp_db_local_backup_restore.sh not found"
        exit 1
    fi
}

# Backup database
backup_database() {
    log_info "Creating database backup..."
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    BACKUP_FILE="$SCRIPT_DIR/logs/local_db_backup_${TIMESTAMP}.sql"
    BACKUP_FILE_GZ="${BACKUP_FILE}.gz"
    
    # Get local DB config from wp-config.php
    WP_CONFIG_PATHS=(
        "/var/www/nilgiristores.in/wp-config.php"
        "../wp-config.php"
        "../../wp-config.php"
    )
    
    WP_CONFIG=""
    for path in "${WP_CONFIG_PATHS[@]}"; do
        if [ -f "$path" ]; then
            WP_CONFIG="$path"
            break
        fi
    done
    
    if [ -n "$WP_CONFIG" ]; then
        LOCAL_HOST=$(grep "define.*DB_HOST" "$WP_CONFIG" | sed -n "s/.*['\"]\\([^'\"]*\\)['\"].*/\\1/p")
        LOCAL_DB=$(grep "define.*DB_NAME" "$WP_CONFIG" | sed -n "s/.*['\"]\\([^'\"]*\\)['\"].*/\\1/p")
        LOCAL_USER=$(grep "define.*DB_USER" "$WP_CONFIG" | sed -n "s/.*['\"]\\([^'\"]*\\)['\"].*/\\1/p")
        LOCAL_PASS=$(grep "define.*DB_PASSWORD" "$WP_CONFIG" | sed -n "s/.*['\"]\\([^'\"]*\\)['\"].*/\\1/p")
        
        # Create backup and compress it
        log_info "Dumping database..."
        if MYSQL_PWD="$LOCAL_PASS" mysqldump -h "$LOCAL_HOST" -u "$LOCAL_USER" "$LOCAL_DB" | gzip -9 > "$BACKUP_FILE_GZ" 2>/dev/null; then
            # Get compressed file size
            FILE_SIZE=$(du -h "$BACKUP_FILE_GZ" | cut -f1)
            log_success "Database backup created: $BACKUP_FILE_GZ (Size: $FILE_SIZE)"
        else
            log_error "Database backup failed"
            exit 1
        fi
    else
        log_error "wp-config.php not found - cannot create backup"
        exit 1
    fi
}

# Restore database
restore_database() {
    log_info "Restoring database from backup..."
    
    # List available backup files
    BACKUP_DIR="$SCRIPT_DIR/logs"
    if [ ! -d "$BACKUP_DIR" ]; then
        log_error "Backup directory not found: $BACKUP_DIR"
        exit 1
    fi
    
    # Find both .sql and .sql.gz files with various naming patterns
    BACKUP_FILES=($(find "$BACKUP_DIR" \( -name "*backup*.sql" -o -name "*backup*.sql.gz" \) -type f | sort -r))
    
    if [ ${#BACKUP_FILES[@]} -eq 0 ]; then
        log_error "No backup files found in $BACKUP_DIR"
        exit 1
    fi
    
    echo "Available backup files:"
    for i in "${!BACKUP_FILES[@]}"; do
        FILEPATH="${BACKUP_FILES[$i]}"
        FILENAME=$(basename "$FILEPATH")
        
        # Get file modification time
        if [[ "$OSTYPE" == "darwin"* ]]; then
            # macOS
            FILE_MTIME=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$FILEPATH")
        else
            # Linux
            FILE_MTIME=$(stat -c "%y" "$FILEPATH" | cut -d'.' -f1)
        fi
        
        # Get file size
        FILE_SIZE=$(du -h "$FILEPATH" | cut -f1)
        
        # Extract date from filename for display (handle different naming patterns)
        if [[ "$FILENAME" =~ ([0-9]{8})_([0-9]{6}) ]]; then
            DATE_PART="${BASH_REMATCH[1]}"
            TIME_PART="${BASH_REMATCH[2]}"
            # Format date as YYYY-MM-DD
            FORMATTED_DATE="${DATE_PART:0:4}-${DATE_PART:4:2}-${DATE_PART:6:2}"
            # Format time as HH:MM:SS
            FORMATTED_TIME="${TIME_PART:0:2}:${TIME_PART:2:2}:${TIME_PART:4:2}"
            DISPLAY_DATE="$FORMATTED_DATE $FORMATTED_TIME"
        else
            DISPLAY_DATE="$FILE_MTIME"
        fi
        
        # Check if compressed
        if [[ "$FILENAME" == *.gz ]]; then
            COMPRESSION_INFO=" [Compressed]"
        else
            COMPRESSION_INFO=""
        fi
        
        echo "  $((i+1)). $FILENAME (Created: $DISPLAY_DATE, Size: $FILE_SIZE$COMPRESSION_INFO)"
    done
    
    echo -e "\n${YELLOW}Select backup file to restore [1-${#BACKUP_FILES[@]}]: ${NC}\c"
    read backup_choice
    
    if [[ "$backup_choice" =~ ^[0-9]+$ ]] && [ "$backup_choice" -ge 1 ] && [ "$backup_choice" -le ${#BACKUP_FILES[@]} ]; then
        SELECTED_BACKUP="${BACKUP_FILES[$((backup_choice-1))]}"
        log_info "Selected backup: $(basename "$SELECTED_BACKUP")"
        
        # Confirm restore
        echo -e "\n${RED}⚠️  WARNING: This will replace your current database with the backup!${NC}"
        echo -e "${YELLOW}Are you sure you want to continue? (y/N): ${NC}\c"
        read confirm
        
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            # Get local DB config from wp-config.php
            WP_CONFIG_PATHS=(
                "/var/www/nilgiristores.in/wp-config.php"
                "../wp-config.php"
                "../../wp-config.php"
            )
            
            WP_CONFIG=""
            for path in "${WP_CONFIG_PATHS[@]}"; do
                if [ -f "$path" ]; then
                    WP_CONFIG="$path"
                    break
                fi
            done
            
            if [ -n "$WP_CONFIG" ]; then
                LOCAL_HOST=$(grep "define.*DB_HOST" "$WP_CONFIG" | sed -n "s/.*['\"]\\([^'\"]*\\)['\"].*/\\1/p")
                LOCAL_DB=$(grep "define.*DB_NAME" "$WP_CONFIG" | sed -n "s/.*['\"]\\([^'\"]*\\)['\"].*/\\1/p")
                LOCAL_USER=$(grep "define.*DB_USER" "$WP_CONFIG" | sed -n "s/.*['\"]\\([^'\"]*\\)['\"].*/\\1/p")
                LOCAL_PASS=$(grep "define.*DB_PASSWORD" "$WP_CONFIG" | sed -n "s/.*['\"]\\([^'\"]*\\)['\"].*/\\1/p")
                
                # Restore based on file type
                if [[ "$SELECTED_BACKUP" == *.gz ]]; then
                    # Compressed file - decompress and restore
                    log_info "Decompressing and restoring backup..."
                    if gunzip -c "$SELECTED_BACKUP" | MYSQL_PWD="$LOCAL_PASS" mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" "$LOCAL_DB" 2>/dev/null; then
                        log_success "Database restored successfully from compressed backup: $(basename "$SELECTED_BACKUP")"
                    else
                        log_error "Database restore failed"
                        exit 1
                    fi
                else
                    # Regular SQL file
                    if MYSQL_PWD="$LOCAL_PASS" mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" "$LOCAL_DB" < "$SELECTED_BACKUP" 2>/dev/null; then
                        log_success "Database restored successfully from: $(basename "$SELECTED_BACKUP")"
                    else
                        log_error "Database restore failed"
                        exit 1
                    fi
                fi
            else
                log_error "wp-config.php not found - cannot restore database"
                exit 1
            fi
        else
            log_info "Database restore cancelled"
        fi
    else
        log_error "Invalid selection: $backup_choice"
        exit 1
    fi
}

# Main execution
main() {
    log_info "Migration started at: $(date)"
    log_info "Log file: $LOG_FILE"
    echo ""
    
    case "${1:-}" in
        --products-only)
            extract_products "${@:2}"
            ;;
        --customers-only)
            backup_database
            migrate_customers
            validate_migration
            ;;
        --orders-only)
                        log_info "Starting order migration..."
            backup_database
            migrate_orders
            validate_migration
            ;;
        --hpos-only)
            backup_database
            convert_to_hpos
            validate_migration
            ;;
        --all)
            backup_database
            migrate_customers
            convert_to_hpos
            validate_migration
            ;;
        --validate)
            validate_migration
            ;;
        --backup)
            backup_restore_db
            ;;
        --create-backup)
            backup_database
            ;;
        --restore-backup)
            restore_database
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        "")
            # Interactive mode
            while true; do
                show_menu
                case $choice in
                    1)
                        extract_products
                        ;;
                    2)
                        backup_database
                        migrate_customers
                        validate_migration
                        ;;
                    3)
            log_info "Starting order migration..."
                        backup_database
                        migrate_orders
                        validate_migration
                        ;;
                    4)
                        backup_database
                        convert_to_hpos
                        validate_migration
                        ;;
                    5)
                        backup_database
                        migrate_customers
                        convert_to_hpos
                        validate_migration
                        ;;
                    6)
                        validate_migration
                        ;;
                    7)
                        backup_database
                        ;;
                    8)
                        restore_database
                        ;;
                    9)
                        log_info "Exiting..."
                        exit 0
                        ;;
                    *)
                        log_error "Invalid option: $choice"
                        ;;
                esac
                echo ""
                read -p "Press Enter to continue..." 
                echo ""
            done
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
    
    log_success "Migration completed at: $(date)"
}

# Execute main with all arguments
main "$@"
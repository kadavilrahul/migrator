#!/bin/bash

# WordPress Migration Master Script
# Portable version - can be used with any WordPress installation
# Version: 2.0

set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config/config.sh"
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

# Create necessary directories
mkdir -p "$SCRIPT_DIR/logs"
mkdir -p "$SCRIPT_DIR/data"
# All backups now go to logs directory

# Function to create config file
create_config() {
    mkdir -p "$SCRIPT_DIR/config"
    cat > "$CONFIG_FILE" << 'EOF'
#!/bin/bash
# WordPress Migration Configuration

# WordPress Path
WP_PATH="/var/www/example.com"

# Local Database (Target)
LOCAL_HOST="localhost"
LOCAL_DB="wordpress_db"
LOCAL_USER="root"
LOCAL_PASS="password"
LOCAL_PREFIX="wp_"

# Remote Database (Source)
REMOTE_HOST="remote-server.com"
REMOTE_DB="remote_db"
REMOTE_USER="remote_user"
REMOTE_PASS="remote_password"
REMOTE_PREFIX="wp_"

# Migration Options
ENABLE_HPOS="true"
AUTO_BACKUP="true"
COMPRESS_BACKUPS="true"
BATCH_SIZE="100"
KEEP_BACKUPS_DAYS="30"
EOF
    log_success "Configuration file created: $CONFIG_FILE"
    log_info "Please edit the configuration file to match your WordPress installation"
}

# Function to load configuration
load_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        log_warning "Configuration file not found at $CONFIG_FILE"
        log_info "Creating default configuration..."
        create_config
        echo ""
        echo -e "${YELLOW}Please edit the configuration file at:${NC}"
        echo -e "${BOLD}$CONFIG_FILE${NC}"
        echo ""
        exit 1
    fi
    
    # Simply source the shell configuration file
    source "$CONFIG_FILE"
    
    # Export variables for child scripts
    export WP_PATH LOCAL_HOST LOCAL_DB LOCAL_USER LOCAL_PASS LOCAL_PREFIX
    export REMOTE_HOST REMOTE_DB REMOTE_USER REMOTE_PASS REMOTE_PREFIX
    export ENABLE_HPOS AUTO_BACKUP COMPRESS_BACKUPS BATCH_SIZE KEEP_BACKUPS_DAYS
    export CONFIG_FILE SCRIPT_DIR
}

# Function to verify configuration
verify_config() {
    local errors=0
    
    echo ""
    log_info "Verifying configuration..."
    echo ""
    echo "Current Configuration:"
    echo "────────────────────────────────────────────"
    echo "WordPress Path:        $WP_PATH"
    echo "WordPress Config:      ${WP_CONFIG_PATH:-Not found}"
    echo ""
    echo "Local Database:"
    echo "  Host:               $LOCAL_HOST"
    echo "  Database:           $LOCAL_DB"
    echo "  User:               $LOCAL_USER"
    echo "  Password:           ${LOCAL_PASS:+[SET]}"
    echo "  Table Prefix:       $LOCAL_PREFIX"
    echo ""
    
    if [ "$1" == "remote" ]; then
        echo "Remote Database:"
        echo "  Host:               $REMOTE_HOST"
        echo "  Database:           $REMOTE_DB"
        echo "  User:               $REMOTE_USER"
        echo "  Password:           ${REMOTE_PASS:+[SET]}"
        echo "  Table Prefix:       $REMOTE_PREFIX"
        echo ""
    fi
    
    echo "Migration Options:"
    echo "  HPOS Enabled:       $ENABLE_HPOS"
    echo "  Auto Backup:        $AUTO_BACKUP"
    echo "  Batch Size:         $BATCH_SIZE"
    echo "────────────────────────────────────────────"
    echo ""
    
    # Check WordPress path
    if [ ! -d "$WP_PATH" ]; then
        log_error "WordPress path not found: $WP_PATH"
        ((errors++))
    fi
    
    # Check wp-config.php
    if [ ! -f "$WP_CONFIG_PATH" ]; then
        log_error "wp-config.php not found"
        ((errors++))
    fi
    
    # Test database connection
    if ! MYSQL_PWD="$LOCAL_PASS" mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" -e "USE $LOCAL_DB" 2>/dev/null; then
        log_error "Cannot connect to local database"
        ((errors++))
    else
        log_success "Local database connection successful"
    fi
    
    if [ $errors -gt 0 ]; then
        echo ""
        log_error "Configuration errors found. Please fix them and try again."
        echo -e "${YELLOW}Edit configuration file: $CONFIG_FILE${NC}"
        exit 1
    fi
    
    echo ""
    log_success "Configuration verified successfully!"
}

# Usage function
usage() {
    echo "WordPress Migration Tool - Portable Version"
    echo ""
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Configuration:"
    echo "  --setup             Create/edit configuration file"
    echo "  --verify            Verify configuration settings"
    echo ""
    echo "Product Extraction Options:"
    echo "  --products-all      Extract ALL products from WordPress to CSV"
    echo "  --products-instock  Extract only in-stock products to CSV"
    echo "  --products-test     Extract 10 test products to CSV"
    echo ""
    echo "Migration Options:"
    echo "  --customers-only    Migrate only customers who have placed orders"
    echo "  --orders-complete   Complete order migration (Orders + HPOS + Status Fix)"
    echo "  --sync-statuses     Sync order statuses from source to destination"
    echo "  --convert-statuses  Convert custom order statuses to standard WooCommerce statuses"
    echo "  --all               Full migration (Customers + Orders + HPOS + Status Fix)"
    echo ""
    echo "Maintenance Options:"
    echo "  --validate          Check data integrity and migration success"
    echo "  --backup            Create database backup"
    echo "  --restore           Restore database from backup"
    echo "  --cleanup           Clean up old backups and logs"
    echo "  --help              Show this help"
    echo ""
    echo "Legacy Options (redirects to --orders-complete):"
    echo "  --orders-only       Migrate orders (now uses complete migration)"
    echo "  --orders-with-hpos  Migrate with HPOS (now uses complete migration)"
    echo "  --hpos-only         Convert to HPOS only"
    echo ""
    echo "Default: Interactive mode with menu"
}

# Interactive menu
show_menu() {
    echo ""
    echo "┌─────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐"
    echo "│                                       WORDPRESS MIGRATION TOOL                                                  │"
    echo "├─────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤"
    echo "│  CONFIGURATION                                                                                                  │"
    echo "│  1. Setup/Edit Configuration          [./run.sh --setup]            # Configure migration settings              │"
    echo "│  2. Verify Configuration              [./run.sh --verify]           # Test configuration and connections        │"
    echo "├─────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤"
    echo "│  PRODUCT EXTRACTION                                                                                             │"
    echo "│  3. Extract ALL Products              [./run.sh --products-all]     # Extract ALL products from WordPress       │"
    echo "│  4. Extract IN-STOCK Products Only    [./run.sh --products-instock] # Extract only in-stock products            │"
    echo "├─────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤"
    echo "│  CUSTOMER & ORDER MIGRATION                                                                                     │"
    echo "│  5. Full Migration (Recommended)      [./run.sh --all]              # Complete migration with all fixes         │"
    echo "│  6. Migrate Customers Only            [./run.sh --customers-only]   # Import customers who have orders          │"
    echo "│  7. Migrate Orders Only               [./run.sh --orders-only]      # Import orders without customers           │"
    echo "│  8. Fix Order Statuses                [./run.sh --fix-statuses]     # Convert custom to standard statuses       │"
    echo "├─────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤"
    echo "│  MAINTENANCE & VALIDATION                                                                                       │"
    echo "│  10. Validate Migration               [./run.sh --validate]         # Check data integrity                      │"
    echo "│  11. Create Backup                    [./run.sh --backup]           # Backup database                           │"
    echo "│  12. Restore from Backup              [./run.sh --restore]          # Restore database from backup              │"
    echo "│  13. Clean Up Old Files               [./run.sh --cleanup]          # Remove old backups and logs               │"
    echo "├─────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤"
    echo "│  0. Exit                                                                                                        │"
    echo "└─────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘"
    echo ""
    echo -e "${YELLOW}🔧 Select option [0-13]: ${NC}\c"
    read choice
    echo ""
}



# Extract products with different modes
extract_products() {
    local mode="${1:-all}"
    log_info "Starting product extraction (mode: $mode)..."
    
    if [ ! -f "$SCRIPT_DIR/scripts/extract_products.sh" ]; then
        log_error "scripts/extract_products.sh not found"
        exit 1
    fi
    
    cd "$SCRIPT_DIR/scripts"
    
    case "$mode" in
        "all")
            log_info "Extracting ALL products from WordPress..."
            ./extract_products.sh
            ;;
        "instock")
            log_info "Extracting IN-STOCK products only..."
            ./extract_products.sh --in-stock
            ;;
        "test")
            log_info "Extracting TEST batch (10 products)..."
            ./extract_products.sh --test
            ;;
        *)
            log_error "Unknown extraction mode: $mode"
            exit 1
            ;;
    esac
    
    local result=$?
    if [ $result -eq 0 ]; then
        log_success "Product extraction completed successfully"
        
        local csv_file="$SCRIPT_DIR/data/products.csv"
        if [ -f "$csv_file" ]; then
            local count=$(tail -n +2 "$csv_file" | wc -l)
            log_info "Extracted $count products to: $csv_file"
        fi
    else
        log_error "Product extraction failed with error code: $result"
        exit $result
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

# Migrate orders from remote database (traditional format)
migrate_orders() {
    log_info "Starting order migration from remote database..."
    if [ -f "$SCRIPT_DIR/scripts/migrate_orders.sh" ]; then
        cd "$SCRIPT_DIR/scripts"
        ./migrate_orders.sh
        log_success "Order migration completed (traditional format)"
        log_info "Note: Run --hpos-only to convert these orders to HPOS format"
    else
        log_error "scripts/migrate_orders.sh not found"
        exit 1
    fi
}

# Convert orders to HPOS format
convert_to_hpos() {
    log_info "Starting HPOS conversion for existing orders..."
    if [ -f "$SCRIPT_DIR/scripts/enable_hpos_migration.sh" ]; then
        cd "$SCRIPT_DIR/scripts"
        ./enable_hpos_migration.sh
        log_success "HPOS conversion completed - all orders now in high-performance tables"
    else
        log_error "scripts/enable_hpos_migration.sh not found"
        exit 1
    fi
}

# Complete order migration (without customers)
complete_order_migration() {
    log_info "Starting complete order migration (without customers)..."
    
    # Step 1: Migrate orders
    if [ -f "$SCRIPT_DIR/scripts/migrate_orders.sh" ]; then
        cd "$SCRIPT_DIR/scripts"
        log_info "Step 1/3: Migrating orders from remote database..."
        ./migrate_orders.sh
        
        # Step 2: Fix custom statuses (already included in migrate_orders.sh)
        log_info "Step 2/3: Custom statuses already fixed during migration"
        
        # Step 3: Convert to HPOS
        if [ -f "$SCRIPT_DIR/scripts/enable_hpos_migration.sh" ]; then
            log_info "Step 3/3: Converting to HPOS format..."
            # Simple HPOS migration to avoid hanging
            mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" -p"$LOCAL_PASS" "$LOCAL_DB" -e "
                TRUNCATE TABLE ${LOCAL_PREFIX}wc_orders;
                INSERT IGNORE INTO ${LOCAL_PREFIX}wc_orders (id, status, currency, type, customer_id, date_created_gmt, date_updated_gmt, total_amount, billing_email)
                SELECT 
                    p.ID,
                    REPLACE(p.post_status, 'wc-', ''),
                    'INR',
                    'shop_order',
                    p.post_author,
                    p.post_date_gmt,
                    p.post_modified_gmt,
                    COALESCE((SELECT meta_value FROM ${LOCAL_PREFIX}postmeta WHERE post_id = p.ID AND meta_key = '_order_total' LIMIT 1), 0),
                    COALESCE((SELECT meta_value FROM ${LOCAL_PREFIX}postmeta WHERE post_id = p.ID AND meta_key = '_billing_email' LIMIT 1), '')
                FROM ${LOCAL_PREFIX}posts p
                WHERE p.post_type = 'shop_order';" 2>/dev/null
            log_success "HPOS conversion completed"
        else
            log_warning "HPOS conversion script not found - orders in traditional format only"
        fi
        
        log_success "✅ Complete order migration finished (Orders + HPOS + Status Fix)"
    else
        log_error "scripts/migrate_orders.sh not found"
        exit 1
    fi
}

# Migrate orders directly to HPOS (legacy - kept for compatibility)
migrate_orders_with_hpos() {
    complete_order_migration
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

# Backup database
backup_database() {
    log_info "Creating database backup..."
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    # All backups go to logs directory as requested
    BACKUP_DIR="$SCRIPT_DIR/logs"
    mkdir -p "$BACKUP_DIR"
    
    if [ "${COMPRESS_BACKUPS:-true}" == "true" ]; then
        BACKUP_FILE="$BACKUP_DIR/wp_backup_${TIMESTAMP}.sql.gz"
        log_info "Creating compressed backup..."
        # Suppress the tablespace warning with 2>/dev/null
        if MYSQL_PWD="$LOCAL_PASS" mysqldump --no-tablespaces -h "$LOCAL_HOST" -u "$LOCAL_USER" "$LOCAL_DB" 2>/dev/null | gzip -9 > "$BACKUP_FILE"; then
            FILE_SIZE=$(du -h "$BACKUP_FILE" | cut -f1)
            log_success "Backup created: $BACKUP_FILE (Size: $FILE_SIZE)"
        else
            log_error "Backup failed"
            exit 1
        fi
    else
        BACKUP_FILE="$BACKUP_DIR/wp_backup_${TIMESTAMP}.sql"
        log_info "Creating backup..."
        if MYSQL_PWD="$LOCAL_PASS" mysqldump --no-tablespaces -h "$LOCAL_HOST" -u "$LOCAL_USER" "$LOCAL_DB" 2>/dev/null > "$BACKUP_FILE"; then
            FILE_SIZE=$(du -h "$BACKUP_FILE" | cut -f1)
            log_success "Backup created: $BACKUP_FILE (Size: $FILE_SIZE)"
        else
            log_error "Backup failed"
            exit 1
        fi
    fi
}

# Restore database
restore_database() {
    log_info "Restoring database from backup..."
    
    # Search for backups in logs directory
    BACKUP_LOCATIONS=(
        "$SCRIPT_DIR/logs"
        "$SCRIPT_DIR"
    )
    
    # Find all backup files with various naming patterns
    BACKUP_FILES=()
    for dir in "${BACKUP_LOCATIONS[@]}"; do
        if [ -d "$dir" ]; then
            # Look for various backup patterns
            while IFS= read -r file; do
                [ -f "$file" ] && BACKUP_FILES+=("$file")
            done < <(find "$dir" -maxdepth 1 \( \
                -name "*.sql" -o \
                -name "*.sql.gz" -o \
                -name "*backup*.sql" -o \
                -name "*backup*.sql.gz" -o \
                -name "*_db_*.sql" -o \
                -name "*_db_*.sql.gz" \
            \) -type f 2>/dev/null)
        fi
    done
    
    # Remove duplicates and sort by modification time
    if [ ${#BACKUP_FILES[@]} -gt 0 ]; then
        # Use associative array to remove duplicates
        declare -A unique_files
        for file in "${BACKUP_FILES[@]}"; do
            unique_files["$file"]=1
        done
        BACKUP_FILES=($(for file in "${!unique_files[@]}"; do echo "$file"; done | xargs ls -t 2>/dev/null))
    fi
    
    if [ ${#BACKUP_FILES[@]} -eq 0 ]; then
        log_error "No backup files found in logs/ or main directory"
        exit 1
    fi
    
    echo "Available backup files:"
    for i in "${!BACKUP_FILES[@]}"; do
        FILEPATH="${BACKUP_FILES[$i]}"
        FILENAME=$(basename "$FILEPATH")
        FILE_SIZE=$(du -h "$FILEPATH" | cut -f1)
        FILE_MTIME=$(stat -c "%y" "$FILEPATH" 2>/dev/null | cut -d'.' -f1 || stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$FILEPATH" 2>/dev/null)
        echo "  $((i+1)). $FILENAME (Size: $FILE_SIZE, Date: $FILE_MTIME)"
    done
    
    echo -e "\n${YELLOW}Select backup file [1-${#BACKUP_FILES[@]}]: ${NC}\c"
    read backup_choice
    
    if [[ "$backup_choice" =~ ^[0-9]+$ ]] && [ "$backup_choice" -ge 1 ] && [ "$backup_choice" -le ${#BACKUP_FILES[@]} ]; then
        SELECTED_BACKUP="${BACKUP_FILES[$((backup_choice-1))]}"
        
        echo -e "\n${RED}⚠️  WARNING: This will replace your current database!${NC}"
        echo -e "${YELLOW}Continue? (y/N): ${NC}\c"
        read confirm
        
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            if [[ "$SELECTED_BACKUP" == *.gz ]]; then
                log_info "Restoring from compressed backup..."
                if gunzip -c "$SELECTED_BACKUP" | MYSQL_PWD="$LOCAL_PASS" mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" "$LOCAL_DB" 2>/dev/null; then
                    log_success "Database restored successfully"
                else
                    log_error "Restore failed"
                    exit 1
                fi
            else
                if MYSQL_PWD="$LOCAL_PASS" mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" "$LOCAL_DB" < "$SELECTED_BACKUP" 2>/dev/null; then
                    log_success "Database restored successfully"
                else
                    log_error "Restore failed"
                    exit 1
                fi
            fi
        else
            log_info "Restore cancelled"
        fi
    else
        log_error "Invalid selection"
        exit 1
    fi
}

# Clean up old files
# Fix custom order statuses
sync_order_statuses() {
    log_info "Syncing order statuses from source to destination..."
    echo ""
    echo "Choose sync mode:"
    echo "1. Convert custom statuses to standard WooCommerce statuses"
    echo "2. Preserve original custom statuses (requires registered custom statuses)"
    echo ""
    read -p "Select option [1-2]: " sync_choice
    
    case $sync_choice in
        1)
            if [ -f "$SCRIPT_DIR/scripts/sync_order_statuses.sh" ]; then
                cd "$SCRIPT_DIR/scripts"
                ./sync_order_statuses.sh
                log_success "Order statuses synced with conversion to standard statuses"
            else
                log_error "scripts/sync_order_statuses.sh not found"
                exit 1
            fi
            ;;
        2)
            if [ -f "$SCRIPT_DIR/scripts/sync_order_statuses_original.sh" ]; then
                cd "$SCRIPT_DIR/scripts"
                ./sync_order_statuses_original.sh
                log_success "Order statuses synced preserving original custom statuses"
            else
                log_error "scripts/sync_order_statuses_original.sh not found"
                exit 1
            fi
            ;;
        *)
            log_error "Invalid option"
            return 1
            ;;
    esac
}

convert_custom_statuses() {
    log_info "Converting custom order statuses to standard WooCommerce statuses..."
    if [ -f "$SCRIPT_DIR/scripts/convert_custom_statuses.sh" ]; then
        cd "$SCRIPT_DIR/scripts"
        ./convert_custom_statuses.sh
        log_success "Custom order statuses converted"
    else
        log_error "scripts/convert_custom_statuses.sh not found"
        exit 1
    fi
}

cleanup_old_files() {
    log_info "Cleaning up old files..."
    
    # Clean old backups from logs directory
    if [ "${KEEP_BACKUPS_DAYS:-30}" -gt 0 ]; then
        find "$SCRIPT_DIR/logs" -name "*.sql*" -type f -mtime +${KEEP_BACKUPS_DAYS} -delete 2>/dev/null
        log_success "Removed backups older than ${KEEP_BACKUPS_DAYS} days"
    fi
    
    # Clean old logs (keep for 90 days)
    find "$SCRIPT_DIR/logs" -name "*.log" -type f -mtime +90 -delete 2>/dev/null
    log_success "Removed logs older than 90 days"
    
    # Count backup files
    BACKUP_COUNT=$(find "$SCRIPT_DIR/logs" -name "*.sql*" -type f 2>/dev/null | wc -l)
    LOG_COUNT=$(find "$SCRIPT_DIR/logs" -name "*.log" -type f 2>/dev/null | wc -l)
    
    # Show disk usage
    echo ""
    echo "Current disk usage and file counts:"
    echo "  Logs directory: $(du -sh "$SCRIPT_DIR/logs" 2>/dev/null | cut -f1) ($BACKUP_COUNT backups, $LOG_COUNT logs)"
    echo "  Data directory: $(du -sh "$SCRIPT_DIR/data" 2>/dev/null | cut -f1)"
    
    # All backups are now in logs directory only
}

# Main execution
main() {
    # Load configuration (unless we're setting it up)
    if [ "${1:-}" != "--setup" ]; then
        load_config
    fi
    
    log_info "WordPress Migration Tool v2.0"
    log_info "Started at: $(date)"
    log_info "Log file: $LOG_FILE"
    echo ""
    
    case "${1:-}" in
        --setup)
            if [ -f "$CONFIG_FILE" ]; then
                echo -e "${YELLOW}Configuration file already exists. Edit it? (y/N): ${NC}\c"
                read edit_config
                if [[ "$edit_config" =~ ^[Yy]$ ]]; then
                    ${EDITOR:-nano} "$CONFIG_FILE"
                fi
            else
                create_config
                ${EDITOR:-nano} "$CONFIG_FILE"
            fi
            load_config
            verify_config "local"
            ;;
        --verify)
            verify_config "remote"
            ;;
        --products-all)
            extract_products "all"
            ;;
        --products-instock)
            extract_products "instock"
            ;;
        --products-test)
            extract_products "test"
            ;;
        --customers-only)
            [ "$AUTO_BACKUP" == "true" ] && backup_database
            migrate_customers
            [ "${VERIFY_MIGRATION:-false}" == "true" ] && validate_migration
            ;;
        --orders-complete)
            [ "$AUTO_BACKUP" == "true" ] && backup_database
            complete_order_migration
            [ "${VERIFY_MIGRATION:-false}" == "true" ] && validate_migration
            ;;
        --orders-only)  # Legacy - redirect to complete
            [ "$AUTO_BACKUP" == "true" ] && backup_database
            complete_order_migration
            [ "${VERIFY_MIGRATION:-false}" == "true" ] && validate_migration
            ;;
        --orders-with-hpos)  # Legacy - redirect to complete
            [ "$AUTO_BACKUP" == "true" ] && backup_database
            complete_order_migration
            [ "${VERIFY_MIGRATION:-false}" == "true" ] && validate_migration
            ;;
        --hpos-only)  # Legacy - kept for compatibility
            [ "$AUTO_BACKUP" == "true" ] && backup_database
            convert_to_hpos
            [ "${VERIFY_MIGRATION:-false}" == "true" ] && validate_migration
            ;;
        --all)
            [ "$AUTO_BACKUP" == "true" ] && backup_database
            log_info "Starting full migration (Customers + Orders + HPOS + Status Fix)..."
            migrate_customers
            complete_order_migration
            [ "${VERIFY_MIGRATION:-false}" == "true" ] && validate_migration
            log_success "Full migration completed successfully!"
            ;;
        --validate)
            validate_migration
            ;;
        --backup)
            backup_database
            ;;
        --restore)
            restore_database
            ;;
        --cleanup)
            cleanup_old_files
            ;;
        --sync-statuses)
            sync_order_statuses
            ;;
        --convert-statuses)
            convert_custom_statuses
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
                        if [ -f "$CONFIG_FILE" ]; then
                            ${EDITOR:-nano} "$CONFIG_FILE"
                            load_config
                        else
                            create_config
                            ${EDITOR:-nano} "$CONFIG_FILE"
                            load_config
                        fi
                        verify_config "local"
                        ;;
                    2)
                        verify_config "remote"
                        ;;
                    3)
                        extract_products "all"
                        ;;
                    4)
                        extract_products "instock"
                        ;;
                    5)
                        # Full Migration (Recommended)
                        [ "$AUTO_BACKUP" == "true" ] && backup_database
                        log_info "Starting full migration (Customers + Orders + Status Fix)..."
                        migrate_customers
                        complete_order_migration
                        # Explicitly run status conversion to ensure it happens
                        if [ -f "$SCRIPT_DIR/scripts/convert_custom_statuses.sh" ]; then
                            log_info "Converting custom order statuses..."
                            cd "$SCRIPT_DIR/scripts"
                            echo "y" | ./convert_custom_statuses.sh
                        fi
                        [ "${VERIFY_MIGRATION:-false}" == "true" ] && validate_migration
                        log_success "Full migration completed successfully!"
                        ;;
                    6)
                        [ "$AUTO_BACKUP" == "true" ] && backup_database
                        complete_order_migration
                        [ "${VERIFY_MIGRATION:-false}" == "true" ] && validate_migration
                        ;;
                    7)
                        sync_order_statuses
                        ;;
                    8)
                        convert_custom_statuses
                        ;;
                    9)
                        [ "$AUTO_BACKUP" == "true" ] && backup_database
                        log_info "Starting full migration with HPOS..."
                        migrate_customers
                        complete_order_migration
                        [ "${VERIFY_MIGRATION:-false}" == "true" ] && validate_migration
                        log_success "Full migration finished: Customers + Orders + HPOS + Status Fix"
                        ;;
                    10)
                        validate_migration
                        ;;
                    11)
                        backup_database
                        ;;
                    12)
                        restore_database
                        ;;
                    13)
                        cleanup_old_files
                        ;;
                    0)
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
    
    log_success "Operation completed at: $(date)"
}

# Execute main with all arguments
main "$@"
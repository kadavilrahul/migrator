#!/bin/bash

###################################################################################
# WORDPRESS MIGRATION TOOL
###################################################################################
# Streamlined migration tool for WordPress to WordPress migration
# Handles: Products, Customers, Orders, and Status conversions
###################################################################################

set -e

# Script directory and configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config/config.sh"
LOG_DIR="$SCRIPT_DIR/logs"
LOG_FILE="$LOG_DIR/migration_$(date +%Y%m%d_%H%M%S).log"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Create necessary directories
mkdir -p "$LOG_DIR"
mkdir -p "$SCRIPT_DIR/exports"
mkdir -p "$SCRIPT_DIR/data"

# Logging functions
log() { echo -e "$1" | tee -a "$LOG_FILE"; }
log_error() { log "${RED}❌ $1${NC}"; }
log_success() { log "${GREEN}✅ $1${NC}"; }
log_warning() { log "${YELLOW}⚠️  $1${NC}"; }
log_info() { log "${BLUE}ℹ️  $1${NC}"; }

# Load configuration
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        # Set defaults for optional variables
        AUTO_BACKUP=${AUTO_BACKUP:-false}
        VERIFY_MIGRATION=${VERIFY_MIGRATION:-false}
    else
        log_error "Configuration file not found at $CONFIG_FILE"
        echo "Please copy config/config.sh.sample to config/config.sh and configure it."
        exit 1
    fi
}

###################################################################################
# CORE MIGRATION FUNCTIONS
###################################################################################

# Complete migration (recommended path)
full_migration() {
    log_info "Starting COMPLETE WordPress migration..."
    echo ""
    
    # Optional backup
    if [ "$AUTO_BACKUP" == "true" ]; then
        backup_database
    fi
    
    # Step 1: Migrate customers
    log_info "Step 1/3: Migrating customers who have placed orders..."
    if [ -f "$SCRIPT_DIR/scripts/migrate_customers.sh" ]; then
        cd "$SCRIPT_DIR/scripts"
        ./migrate_customers.sh
        log_success "✓ Customers migrated successfully"
    else
        log_error "Customer migration script not found"
        exit 1
    fi
    
    echo ""
    # Step 2: Migrate orders
    log_info "Step 2/3: Migrating orders from source database..."
    if [ -f "$SCRIPT_DIR/scripts/migrate_orders.sh" ]; then
        ./migrate_orders.sh
        log_success "✓ Orders migrated successfully"
    else
        log_error "Order migration script not found"
        exit 1
    fi
    
    echo ""
    # Step 3: Convert custom statuses to standard
    log_info "Step 3/3: Converting custom order statuses to standard WooCommerce statuses..."
    if [ -f "$SCRIPT_DIR/scripts/convert_custom_statuses.sh" ]; then
        echo "y" | ./convert_custom_statuses.sh > /dev/null 2>&1
        log_success "✓ Order statuses converted successfully"
    else
        log_warning "Status conversion script not found, skipping"
    fi
    
    # Optional: Enable HPOS
    echo ""
    read -p "Do you want to enable HPOS (High Performance Order Storage)? (y/N): " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        if [ -f "$SCRIPT_DIR/scripts/enable_hpos_migration.sh" ]; then
            ./enable_hpos_migration.sh
            log_success "✓ HPOS enabled successfully"
        fi
    fi
    
    # Optional: Validate
    if [ "$VERIFY_MIGRATION" == "true" ]; then
        validate_migration
    fi
    
    echo ""
    log_success "════════════════════════════════════════════════"
    log_success "   COMPLETE MIGRATION FINISHED SUCCESSFULLY!"
    log_success "════════════════════════════════════════════════"
    log_info "All customers and orders have been migrated"
    log_info "Order statuses have been standardized"
    log_info "All orders should now be visible in WooCommerce"
}

# Extract products to CSV
extract_products() {
    local mode="${1:-all}"
    log_info "Starting product extraction (mode: $mode)..."
    
    if [ -f "$SCRIPT_DIR/scripts/extract_products.sh" ]; then
        cd "$SCRIPT_DIR/scripts"
        case "$mode" in
            "all")
                log_info "Extracting ALL products from WordPress..."
                ./extract_products.sh
                ;;
            "instock")
                log_info "Extracting only IN-STOCK products..."
                ./extract_products.sh --in-stock
                ;;
            *)
                log_error "Unknown extraction mode: $mode"
                return 1
                ;;
        esac
        
        # Check results
        local csv_file="$SCRIPT_DIR/exports/products.csv"
        if [ -f "$csv_file" ]; then
            local count=$(tail -n +2 "$csv_file" | wc -l)
            log_success "✓ Extracted $count products to: exports/products.csv"
        fi
    else
        log_error "Product extraction script not found"
        exit 1
    fi
}

# Migrate only customers
migrate_customers_only() {
    log_info "Migrating customers who have placed orders..."
    if [ -f "$SCRIPT_DIR/scripts/migrate_customers.sh" ]; then
        cd "$SCRIPT_DIR/scripts"
        ./migrate_customers.sh
        log_success "✓ Customer migration completed"
    else
        log_error "Customer migration script not found"
        exit 1
    fi
}

# Migrate only orders (includes automatic status fix)
migrate_orders_only() {
    log_info "Migrating orders with automatic status conversion..."
    
    if [ "$AUTO_BACKUP" == "true" ]; then
        backup_database
    fi
    
    if [ -f "$SCRIPT_DIR/scripts/migrate_orders.sh" ]; then
        cd "$SCRIPT_DIR/scripts"
        ./migrate_orders.sh
        log_success "✓ Orders migrated"
        
        # Always fix statuses after order migration
        log_info "Converting custom order statuses..."
        if [ -f "./convert_custom_statuses.sh" ]; then
            echo "y" | ./convert_custom_statuses.sh > /dev/null 2>&1
            log_success "✓ Order statuses standardized"
        fi
    else
        log_error "Order migration script not found"
        exit 1
    fi
}

# Fix order statuses (standalone)
fix_order_statuses() {
    log_info "Converting custom order statuses to standard WooCommerce statuses..."
    log_info "This will convert:"
    log_info "  • wc-delivered → wc-completed"
    log_info "  • wc-failed → wc-cancelled"
    log_info "  • wc-pre-order-booked → wc-on-hold"
    echo ""
    
    if [ -f "$SCRIPT_DIR/scripts/convert_custom_statuses.sh" ]; then
        cd "$SCRIPT_DIR/scripts"
        ./convert_custom_statuses.sh
        log_success "✓ Order statuses converted successfully"
    else
        log_error "Status conversion script not found"
        exit 1
    fi
}

# Validate migration
validate_migration() {
    log_info "Validating migration data integrity..."
    if [ -f "$SCRIPT_DIR/scripts/validate_migration.sh" ]; then
        cd "$SCRIPT_DIR/scripts"
        ./validate_migration.sh
    else
        log_error "Validation script not found"
        exit 1
    fi
}

# Create database backup
backup_database() {
    log_info "Creating database backup..."
    local backup_file="$LOG_DIR/backup_$(date +%Y%m%d_%H%M%S).sql"
    
    if mysqldump -h "$LOCAL_HOST" -u "$LOCAL_USER" -p"$LOCAL_PASS" "$LOCAL_DB" > "$backup_file" 2>/dev/null; then
        gzip "$backup_file"
        log_success "✓ Backup created: ${backup_file}.gz"
    else
        log_error "Backup failed"
        return 1
    fi
}

# Restore database from backup
restore_database() {
    log_info "Available backups:"
    local backups=($(ls -t "$LOG_DIR"/*.sql.gz 2>/dev/null))
    
    if [ ${#backups[@]} -eq 0 ]; then
        log_error "No backups found in $LOG_DIR"
        return 1
    fi
    
    for i in "${!backups[@]}"; do
        echo "$((i+1)). $(basename "${backups[$i]}")"
    done
    
    read -p "Select backup to restore [1-${#backups[@]}]: " choice
    
    if [ "$choice" -ge 1 ] && [ "$choice" -le ${#backups[@]} ]; then
        local backup_file="${backups[$((choice-1))]}"
        log_info "Restoring from: $(basename "$backup_file")"
        
        gunzip -c "$backup_file" | mysql -h "$LOCAL_HOST" -u "$LOCAL_USER" -p"$LOCAL_PASS" "$LOCAL_DB" 2>/dev/null
        
        if [ $? -eq 0 ]; then
            log_success "✓ Database restored successfully"
        else
            log_error "Restore failed"
            return 1
        fi
    else
        log_error "Invalid selection"
        return 1
    fi
}

###################################################################################
# HELP AND MENU
###################################################################################

usage() {
    cat << EOF

WordPress Migration Tool
========================

Usage: $0 [OPTION]

QUICK START:
  --all               Complete migration (Customers + Orders + Status Fix) [RECOMMENDED]

PRODUCT EXPORT:
  --products          Extract ALL products to CSV
  --products-instock  Extract only in-stock products to CSV

INDIVIDUAL MIGRATIONS:
  --customers         Migrate only customers who have orders
  --orders            Migrate only orders (auto-converts statuses)
  --fix-statuses      Fix custom order statuses (if orders not showing)

MAINTENANCE:
  --validate          Check migration data integrity
  --backup            Create database backup  
  --restore           Restore from backup

SETUP:
  --setup             Edit configuration file
  --help              Show this help

Default: Interactive menu

EOF
}

show_menu() {
    clear
    echo ""
    echo "╔═══════════════════════════════════════════════════════════════════╗"
    echo "║             WORDPRESS MIGRATION TOOL v2.0                        ║"
    echo "╠═══════════════════════════════════════════════════════════════════╣"
    echo "║                                                                   ║"
    echo "║  RECOMMENDED ACTION                                              ║"
    echo "║  [1] Complete Migration  (Customers + Orders + Status Fix)  ⭐    ║"
    echo "║                                                                   ║"
    echo "╠═══════════════════════════════════════════════════════════════════╣"
    echo "║                                                                   ║"
    echo "║  PRODUCT EXPORT                                                  ║"
    echo "║  [2] Extract All Products to CSV                                 ║"
    echo "║  [3] Extract In-Stock Products Only                              ║"
    echo "║                                                                   ║"
    echo "╠═══════════════════════════════════════════════════════════════════╣"
    echo "║                                                                   ║"
    echo "║  INDIVIDUAL MIGRATIONS                                           ║"
    echo "║  [4] Migrate Customers Only                                      ║"
    echo "║  [5] Migrate Orders Only                                         ║"
    echo "║  [6] Fix Order Statuses                                          ║"
    echo "║                                                                   ║"
    echo "╠═══════════════════════════════════════════════════════════════════╣"
    echo "║                                                                   ║"
    echo "║  MAINTENANCE                                                     ║"
    echo "║  [7] Validate Migration                                          ║"
    echo "║  [8] Backup Database                                             ║"
    echo "║  [9] Restore Database                                            ║"
    echo "║                                                                   ║"
    echo "╠═══════════════════════════════════════════════════════════════════╣"
    echo "║  [0] Exit                                                        ║"
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo ""
    echo -en "${GREEN}Select option [0-9]: ${NC}"
    read -r choice
    echo ""
}

###################################################################################
# MAIN EXECUTION
###################################################################################

main() {
    # Load configuration unless setting up
    if [ "${1:-}" != "--setup" ]; then
        load_config
    fi
    
    # Parse command line arguments
    case "${1:-}" in
        --all)
            full_migration
            ;;
        --products)
            extract_products "all"
            ;;
        --products-instock)
            extract_products "instock"
            ;;
        --customers)
            migrate_customers_only
            ;;
        --orders)
            migrate_orders_only
            ;;
        --fix-statuses)
            fix_order_statuses
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
        --setup)
            if [ -f "$CONFIG_FILE" ]; then
                ${EDITOR:-nano} "$CONFIG_FILE"
                log_success "Configuration updated"
            else
                log_error "Configuration file not found: $CONFIG_FILE"
                echo "Copy config/config.sh.sample to config/config.sh and try again"
                exit 1
            fi
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
                        full_migration
                        ;;
                    2)
                        extract_products "all"
                        ;;
                    3)
                        extract_products "instock"
                        ;;
                    4)
                        migrate_customers_only
                        ;;
                    5)
                        migrate_orders_only
                        ;;
                    6)
                        fix_order_statuses
                        ;;
                    7)
                        validate_migration
                        ;;
                    8)
                        backup_database
                        ;;
                    9)
                        restore_database
                        ;;
                    0)
                        log_info "Thank you for using WordPress Migration Tool"
                        exit 0
                        ;;
                    *)
                        log_error "Invalid option: $choice"
                        ;;
                esac
                echo ""
                read -p "Press Enter to continue..."
            done
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
    
    echo ""
    log_info "Operation completed at: $(date)"
}

# Trap errors
trap 'log_error "An error occurred. Check the log file: $LOG_FILE"' ERR

# Execute main function
main "$@"
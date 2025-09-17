#!/bin/bash

###################################################################################
# WORDPRESS MIGRATION TOOL - SIMPLIFIED VERSION
###################################################################################
# Streamlined migration tool with logical workflow
###################################################################################

set -e

# Script directory
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
    else
        log_error "Configuration file not found. Run with --setup first."
        exit 1
    fi
}

# Create log directory
mkdir -p "$LOG_DIR"

###################################################################################
# SIMPLIFIED FUNCTIONS
###################################################################################

# Complete migration (recommended)
full_migration() {
    log_info "Starting complete WordPress migration..."
    
    # Step 1: Migrate customers
    log_info "Step 1/3: Migrating customers..."
    if [ -f "$SCRIPT_DIR/scripts/migrate_customers.sh" ]; then
        cd "$SCRIPT_DIR/scripts"
        ./migrate_customers.sh
        log_success "Customers migrated successfully"
    else
        log_error "Customer migration script not found"
        exit 1
    fi
    
    # Step 2: Migrate orders
    log_info "Step 2/3: Migrating orders..."
    if [ -f "$SCRIPT_DIR/scripts/migrate_orders.sh" ]; then
        ./migrate_orders.sh
        log_success "Orders migrated successfully"
    else
        log_error "Order migration script not found"
        exit 1
    fi
    
    # Step 3: Fix order statuses
    log_info "Step 3/3: Converting custom order statuses..."
    if [ -f "$SCRIPT_DIR/scripts/convert_custom_statuses.sh" ]; then
        echo "y" | ./convert_custom_statuses.sh
        log_success "Order statuses converted to standard WooCommerce statuses"
    else
        log_warning "Status conversion script not found, skipping"
    fi
    
    # Optional: Enable HPOS if needed
    read -p "Do you want to enable HPOS (High Performance Order Storage)? (y/N): " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        if [ -f "$SCRIPT_DIR/scripts/enable_hpos_migration.sh" ]; then
            ./enable_hpos_migration.sh
            log_success "HPOS enabled"
        fi
    fi
    
    log_success "✅ COMPLETE MIGRATION FINISHED SUCCESSFULLY!"
    log_info "Total customers and orders migrated with status fixes applied"
}

# Migrate only customers
migrate_customers_only() {
    log_info "Migrating customers who have placed orders..."
    if [ -f "$SCRIPT_DIR/scripts/migrate_customers.sh" ]; then
        cd "$SCRIPT_DIR/scripts"
        ./migrate_customers.sh
        log_success "Customer migration completed"
    else
        log_error "Customer migration script not found"
        exit 1
    fi
}

# Migrate only orders
migrate_orders_only() {
    log_info "Migrating orders..."
    if [ -f "$SCRIPT_DIR/scripts/migrate_orders.sh" ]; then
        cd "$SCRIPT_DIR/scripts"
        ./migrate_orders.sh
        log_success "Order migration completed"
        
        # Always fix statuses after order migration
        log_info "Converting custom order statuses..."
        if [ -f "./convert_custom_statuses.sh" ]; then
            echo "y" | ./convert_custom_statuses.sh
            log_success "Order statuses fixed"
        fi
    else
        log_error "Order migration script not found"
        exit 1
    fi
}

# Fix order statuses
fix_order_statuses() {
    log_info "Converting custom order statuses to standard WooCommerce statuses..."
    if [ -f "$SCRIPT_DIR/scripts/convert_custom_statuses.sh" ]; then
        cd "$SCRIPT_DIR/scripts"
        ./convert_custom_statuses.sh
        log_success "Order statuses converted successfully"
    else
        log_error "Status conversion script not found"
        exit 1
    fi
}

# Extract products
extract_products() {
    local mode="${1:-all}"
    log_info "Extracting products from WordPress..."
    
    if [ -f "$SCRIPT_DIR/scripts/extract_products.sh" ]; then
        cd "$SCRIPT_DIR/scripts"
        case "$mode" in
            "all")
                ./extract_products.sh
                ;;
            "instock")
                ./extract_products.sh --in-stock
                ;;
        esac
        log_success "Product extraction completed"
    else
        log_error "Product extraction script not found"
        exit 1
    fi
}

# Validate migration
validate_migration() {
    log_info "Validating migration integrity..."
    if [ -f "$SCRIPT_DIR/scripts/validate_migration.sh" ]; then
        cd "$SCRIPT_DIR/scripts"
        ./validate_migration.sh
    else
        log_error "Validation script not found"
        exit 1
    fi
}

# Backup database
backup_database() {
    log_info "Creating database backup..."
    BACKUP_FILE="$LOG_DIR/backup_$(date +%Y%m%d_%H%M%S).sql"
    
    mysqldump -h "$LOCAL_HOST" -u "$LOCAL_USER" -p"$LOCAL_PASS" "$LOCAL_DB" > "$BACKUP_FILE" 2>/dev/null
    
    if [ -f "$BACKUP_FILE" ]; then
        gzip "$BACKUP_FILE"
        log_success "Backup created: ${BACKUP_FILE}.gz"
    else
        log_error "Backup failed"
        exit 1
    fi
}

###################################################################################
# HELP AND MENU
###################################################################################

usage() {
    echo ""
    echo "WordPress Migration Tool - Simplified Version"
    echo "============================================="
    echo ""
    echo "Usage: $0 [OPTION]"
    echo ""
    echo "Quick Start:"
    echo "  --all               Complete migration (Customers + Orders + Status Fix) [RECOMMENDED]"
    echo ""
    echo "Product Options:"
    echo "  --products          Extract ALL products to CSV"
    echo "  --products-instock  Extract only in-stock products to CSV"
    echo ""
    echo "Migration Options:"
    echo "  --customers         Migrate only customers who have orders"
    echo "  --orders            Migrate only orders (includes status fix)"
    echo "  --fix-statuses      Fix custom order statuses (if orders not showing)"
    echo ""
    echo "Maintenance:"
    echo "  --validate          Check migration integrity"
    echo "  --backup            Create database backup"
    echo ""
    echo "Setup:"
    echo "  --setup             Configure database connections"
    echo "  --help              Show this help"
    echo ""
    echo "Default: Interactive menu"
}

show_menu() {
    echo ""
    echo "┌─────────────────────────────────────────────────────────────────────┐"
    echo "│              WORDPRESS MIGRATION TOOL - SIMPLIFIED                  │"
    echo "├─────────────────────────────────────────────────────────────────────┤"
    echo "│  QUICK ACTIONS                                                      │"
    echo "│  1. Complete Migration    [Customers + Orders + Fixes] RECOMMENDED  │"
    echo "│  2. Extract Products      [Export products to CSV]                  │"
    echo "├─────────────────────────────────────────────────────────────────────┤"
    echo "│  INDIVIDUAL MIGRATIONS                                              │"
    echo "│  3. Migrate Customers     [Import customers who have orders]        │"
    echo "│  4. Migrate Orders        [Import orders with status fix]           │"
    echo "│  5. Fix Order Statuses    [Convert custom to standard statuses]     │"
    echo "├─────────────────────────────────────────────────────────────────────┤"
    echo "│  MAINTENANCE                                                        │"
    echo "│  6. Validate Migration    [Check data integrity]                    │"
    echo "│  7. Create Backup         [Backup local database]                   │"
    echo "├─────────────────────────────────────────────────────────────────────┤"
    echo "│  0. Exit                                                            │"
    echo "└─────────────────────────────────────────────────────────────────────┘"
    echo ""
    echo -e "${YELLOW}Select option [0-7]: ${NC}\c"
    read choice
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
    
    log_info "WordPress Migration Tool - Simplified"
    log_info "Started at: $(date)"
    echo ""
    
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
        --setup)
            if [ -f "$CONFIG_FILE" ]; then
                ${EDITOR:-nano} "$CONFIG_FILE"
            else
                log_error "Configuration file not found at $CONFIG_FILE"
                echo "Please copy config/config.sh.sample to config/config.sh and edit it"
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
                        echo "Select product export mode:"
                        echo "1. All products"
                        echo "2. In-stock only"
                        read -p "Choice [1-2]: " export_choice
                        case $export_choice in
                            1) extract_products "all" ;;
                            2) extract_products "instock" ;;
                            *) log_error "Invalid choice" ;;
                        esac
                        ;;
                    3)
                        migrate_customers_only
                        ;;
                    4)
                        migrate_orders_only
                        ;;
                    5)
                        fix_order_statuses
                        ;;
                    6)
                        validate_migration
                        ;;
                    7)
                        backup_database
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
            done
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
    
    echo ""
    log_info "Finished at: $(date)"
}

# Execute main function
main "$@"
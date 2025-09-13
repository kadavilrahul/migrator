#!/bin/bash

# Load configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/../config/config.json"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "❌ Configuration file not found: $CONFIG_FILE"
    exit 1
fi

# Extract configuration values
DOCUMENT_ROOT=$(grep '"documentRoot"' "$CONFIG_FILE" | head -1 | cut -d'"' -f4)

echo "=== WordPress Database Backup & Restore ==="
echo "Available options:"
echo "1. Create backup of current database"
echo "2. Restore database from backup"
echo ""
read -p "Choose option (1/2): " main_choice

case $main_choice in
    1)
        ;;
    2)
        ;;
    *)
        echo "❌ Invalid choice. Exiting."
        exit 1
        ;;
esac

# Find wp-config.php
WP_CONFIG_PATHS=(
    "/var/www/nilgiristores.in/wp-config.php"
    "../wp-config.php"
    "../../wp-config.php"
    "/var/www/html/wp-config.php"
)

WP_CONFIG_PATH=""
for path in "${WP_CONFIG_PATHS[@]}"; do
    if [ -f "$path" ]; then
        WP_CONFIG_PATH="$path"
        break
    fi
done

if [ -z "$WP_CONFIG_PATH" ]; then
    echo "❌ wp-config.php not found"
    exit 1
fi

# Extract database credentials
DB_HOST=$(grep "define.*DB_HOST" "$WP_CONFIG_PATH" | sed -n "s/.*define[[:space:]]*([[:space:]]*['\"]DB_HOST['\"][[:space:]]*,[[:space:]]*['\"]\\([^'\"]*\\)['\"].*).*/\\1/p")
DB_NAME=$(grep "define.*DB_NAME" "$WP_CONFIG_PATH" | sed -n "s/.*define[[:space:]]*([[:space:]]*['\"]DB_NAME['\"][[:space:]]*,[[:space:]]*['\"]\\([^'\"]*\\)['\"].*).*/\\1/p")
DB_USER=$(grep "define.*DB_USER" "$WP_CONFIG_PATH" | sed -n "s/.*define[[:space:]]*([[:space:]]*['\"]DB_USER['\"][[:space:]]*,[[:space:]]*['\"]\\([^'\"]*\\)['\"].*).*/\\1/p")
DB_PASS=$(grep "define.*DB_PASSWORD" "$WP_CONFIG_PATH" | sed -n "s/.*define[[:space:]]*([[:space:]]*['\"]DB_PASSWORD['\"][[:space:]]*,[[:space:]]*['\"]\\([^'\"]*\\)['\"].*).*/\\1/p")

if [ -z "$DB_HOST" ] || [ -z "$DB_NAME" ] || [ -z "$DB_USER" ] || [ -z "$DB_PASS" ]; then
    echo "❌ Failed to extract database credentials"
    exit 1
fi

# Handle restore option
if [ "$main_choice" == "2" ]; then
    BACKUP_DIR="$SCRIPT_DIR/../logs"
    
    echo "🔍 Looking for available backups..."
    
    if [ ! -d "$BACKUP_DIR" ]; then
        echo "❌ No backup directory found: $BACKUP_DIR"
        exit 1
    fi
    
    # Find available backups (both .sql.gz and .sql files)
    BACKUPS_GZ=($(ls -t "$BACKUP_DIR"/backup_*.sql.gz 2>/dev/null))
    BACKUPS_SQL=($(ls -t "$BACKUP_DIR"/local_db_backup_*.sql 2>/dev/null))
    
    # Combine both arrays and sort by modification time
    BACKUPS=()
    for file in "${BACKUPS_GZ[@]}" "${BACKUPS_SQL[@]}"; do
        BACKUPS+=("$file")
    done
    
    # Sort by modification time (newest first)
    if [ ${#BACKUPS[@]} -gt 0 ]; then
        IFS=$'\n' BACKUPS=($(printf '%s\n' "${BACKUPS[@]}" | xargs ls -t))
    fi
    
    if [ ${#BACKUPS[@]} -eq 0 ]; then
        echo "❌ No backups found in $BACKUP_DIR"
        echo "   Looking for: backup_*.sql.gz and local_db_backup_*.sql"
        exit 1
    fi
    
    echo "📋 Available backups:"
    for i in "${!BACKUPS[@]}"; do
        backup_file="${BACKUPS[$i]}"
        backup_name=$(basename "$backup_file")
        backup_date=$(stat -c %y "$backup_file" | cut -d' ' -f1,2 | cut -d'.' -f1)
        backup_size=$(du -h "$backup_file" | cut -f1)
        backup_type="SQL"
        if [[ "$backup_name" == *.sql.gz ]]; then
            backup_type="Compressed"
        fi
        echo "  $((i+1)). $backup_name ($backup_type, $backup_size) - $backup_date"
    done
    
    read -p "Select backup to restore [1-${#BACKUPS[@]}]: " backup_choice
    
    if ! [[ "$backup_choice" =~ ^[0-9]+$ ]] || [ "$backup_choice" -lt 1 ] || [ "$backup_choice" -gt ${#BACKUPS[@]} ]; then
        echo "❌ Invalid selection"
        exit 1
    fi
    
    RESTORE_FILE="${BACKUPS[$((backup_choice-1))]}"
    
    echo "⚠️  WARNING: This will completely replace your current database!"
    echo "Database: $DB_NAME"
    echo "Restore file: $(basename "$RESTORE_FILE")"
    read -p "Are you sure? Type 'yes' to confirm: " confirm
    
    if [ "$confirm" != "yes" ]; then
        echo "❌ Restore cancelled"
        exit 0
    fi
    
    echo "🔄 Restoring database..."
    export MYSQL_PWD="$DB_PASS"
    
    # Handle both compressed (.sql.gz) and uncompressed (.sql) files
    if [[ "$RESTORE_FILE" == *.sql.gz ]]; then
        echo "   Decompressing and restoring compressed backup..."
        gunzip -c "$RESTORE_FILE" | mysql -h "$DB_HOST" -u "$DB_USER" "$DB_NAME"
    else
        echo "   Restoring uncompressed backup..."
        mysql -h "$DB_HOST" -u "$DB_USER" "$DB_NAME" < "$RESTORE_FILE"
    fi
    
    restore_result=$?
    unset MYSQL_PWD
    
    if [ $restore_result -eq 0 ]; then
        echo "✅ Database restored successfully!"
    else
        echo "❌ Database restore failed!"
        exit 1
    fi
    
    exit 0
fi

# Create backup
BACKUP_DIR="$SCRIPT_DIR/../logs"
mkdir -p "$BACKUP_DIR"

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
BACKUP_FILE="$BACKUP_DIR/backup_${TIMESTAMP}.sql.gz"

echo "💾 Creating backup: $BACKUP_FILE"

export MYSQL_PWD="$DB_PASS"
mysqldump -h "$DB_HOST" -u "$DB_USER" \
    --single-transaction \
    --no-tablespaces \
    --skip-comments \
    "$DB_NAME" | gzip > "$BACKUP_FILE"
unset MYSQL_PWD

if [ $? -eq 0 ] && [ -f "$BACKUP_FILE" ]; then
    echo "✅ Backup completed successfully!"
else
    echo "❌ Backup failed"
    exit 1
fi
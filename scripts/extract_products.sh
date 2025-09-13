#!/bin/bash

# Extracts all product data including images, descriptions, prices, categories, and WooCommerce tags to CSV file in /wp_data directory.


# Load configuration
CONFIG_FILE="../config/config.json"

echo "=== Enhanced WordPress Product Data Extraction ==="
echo ""

# Check if test mode is passed as argument
if [[ "$1" == "--test" ]]; then
    TEST_MODE=true
    echo "Mode: Test mode (10 rows)"
else
    # Interactive mode selection
    echo "Product extraction options:"
    echo "1. Test mode (10 products only)"
    echo "2. Full extraction (ALL products)"
    echo ""
    read -p "Select option [1-2] (or press Enter for full extraction): " mode_choice

    case "$mode_choice" in
        "1")
            TEST_MODE=true
            echo "Selected: Test mode (10 products)"
            ;;
        ""|"2")
            TEST_MODE=false
            echo "Selected: Full extraction (ALL products)"
            ;;
        *)
            echo "Invalid choice. Using full extraction"
            TEST_MODE=false
            ;;
    esac
fi
echo ""

# Set output format to CSV
FILE_EXTENSION="csv"
echo "Output format: CSV"
echo ""

# Set product limit based on test mode
if [ "$TEST_MODE" = true ]; then
    PRODUCT_LIMIT=10
else
    PRODUCT_LIMIT=""
fi
echo ""

# Extract database credentials from config.json
DB_HOST=$(jq -r ".migration.remote_database.host" "$CONFIG_FILE")
DB_NAME=$(jq -r ".migration.remote_database.database" "$CONFIG_FILE")
DB_USER=$(jq -r ".migration.remote_database.username" "$CONFIG_FILE")
DB_PASS=$(jq -r ".migration.remote_database.password" "$CONFIG_FILE")
DB_PREFIX=$(jq -r ".migration.remote_database.table_prefix" "$CONFIG_FILE")
DOMAIN=$(jq -r ".website.domain" "$CONFIG_FILE")

# Output files
OUTPUT_DIR="../data"
COMPLETE_FILE="$OUTPUT_DIR/products.${FILE_EXTENSION}"

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Get total product count first
echo "1. Counting total products..."
total_products=$(unset LD_LIBRARY_PATH && /usr/bin/mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "
SELECT COUNT(*) 
FROM ${DB_PREFIX}posts p
LEFT JOIN ${DB_PREFIX}postmeta pm_thumb ON pm_thumb.post_id = p.ID AND pm_thumb.meta_key = '_thumbnail_id'
LEFT JOIN ${DB_PREFIX}postmeta pm_image ON pm_image.post_id = pm_thumb.meta_value AND pm_image.meta_key = '_wp_attached_file'
WHERE p.post_type = 'product' 
AND p.post_status = 'publish'
AND pm_image.meta_value IS NOT NULL 
AND pm_image.meta_value != ''
" --batch --raw | tail -n +2)

echo "Total products to extract: $total_products"

# Batch processing parameters
BATCH_SIZE=5000
current_offset=0
batch_number=1

# Create CSV header
echo "product_id,post_title,slug,short_description,description,image_url,price,sku,category,product_type,tags" > "$COMPLETE_FILE"

# Determine extraction method based on limit
if [ -n "$PRODUCT_LIMIT" ]; then
    echo "2. Extracting limited products with tags ($PRODUCT_LIMIT)..."
    
    # Single query for limited extraction
    unset LD_LIBRARY_PATH && /usr/bin/mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "
    SELECT 
        p.ID as product_id,
        REPLACE(REPLACE(REPLACE(REPLACE(p.post_title, '\n', ' '), '\r', ' '), '\t', ' '), '\"', '\"\"') as post_title,
        p.post_name as slug,
        REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(p.post_excerpt, '\n', ' '), '\r', ' '), '\t', ' '), '\"', '\"\"'), '${DELIMITER}', ' ') as short_description,
        REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(p.post_content, '\n', ' '), '\r', ' '), '\t', ' '), '\"', '\"\"'), '${DELIMITER}', ' ') as description,
        CASE 
            WHEN pm_image.meta_value IS NOT NULL 
            THEN CONCAT('https://${DOMAIN}/wp-content/uploads/', pm_image.meta_value)
            ELSE NULL
        END as image_url,
        COALESCE(
            (SELECT meta_value FROM ${DB_PREFIX}postmeta WHERE post_id = p.ID AND meta_key = '_price' LIMIT 1),
            (SELECT meta_value FROM ${DB_PREFIX}postmeta WHERE post_id = p.ID AND meta_key = '_regular_price' LIMIT 1),
            '0'
        ) AS price,
        COALESCE(
            (SELECT meta_value FROM ${DB_PREFIX}postmeta WHERE post_id = p.ID AND meta_key = '_sku' LIMIT 1),
            ''
        ) AS sku,
        COALESCE(
            (SELECT GROUP_CONCAT(t.name SEPARATOR ', ')
             FROM ${DB_PREFIX}term_relationships tr
             JOIN ${DB_PREFIX}term_taxonomy tt ON tr.term_taxonomy_id = tt.term_taxonomy_id
             JOIN ${DB_PREFIX}terms t ON tt.term_id = t.term_id
             WHERE tr.object_id = p.ID AND tt.taxonomy = 'product_cat'
             GROUP BY tr.object_id),
            'Uncategorized'
        ) AS category,
        CASE 
            WHEN (SELECT COUNT(*) FROM ${DB_PREFIX}term_relationships tr3
                  JOIN ${DB_PREFIX}term_taxonomy tt3 ON tr3.term_taxonomy_id = tt3.term_taxonomy_id
                  JOIN ${DB_PREFIX}terms t3 ON tt3.term_id = t3.term_id
                  WHERE tr3.object_id = p.ID AND tt3.taxonomy = 'product_tag' AND t3.name = '30days') > 0
            THEN '30days'
            WHEN (SELECT COUNT(*) FROM ${DB_PREFIX}term_relationships tr2
                  JOIN ${DB_PREFIX}term_taxonomy tt2 ON tr2.term_taxonomy_id = tt2.term_taxonomy_id
                  JOIN ${DB_PREFIX}terms t2 ON tt2.term_id = t2.term_id
                  WHERE tr2.object_id = p.ID AND tt2.taxonomy = 'product_tag' AND t2.name = 'buynow') > 0
            THEN 'buynow'
            ELSE '30days'
        END AS product_type,
        COALESCE(
            (SELECT GROUP_CONCAT(t_tag.name SEPARATOR ', ')
             FROM ${DB_PREFIX}term_relationships tr_tag
             JOIN ${DB_PREFIX}term_taxonomy tt_tag ON tr_tag.term_taxonomy_id = tt_tag.term_taxonomy_id
             JOIN ${DB_PREFIX}terms t_tag ON tt_tag.term_id = t_tag.term_id
             WHERE tr_tag.object_id = p.ID AND tt_tag.taxonomy = 'product_tag'
             AND t_tag.name IN ('buynow', '30days')
             GROUP BY tr_tag.object_id),
            ''
        ) AS tags
    FROM ${DB_PREFIX}posts p
    LEFT JOIN ${DB_PREFIX}postmeta pm_thumb ON pm_thumb.post_id = p.ID AND pm_thumb.meta_key = '_thumbnail_id'
    LEFT JOIN ${DB_PREFIX}postmeta pm_image ON pm_image.post_id = pm_thumb.meta_value AND pm_image.meta_key = '_wp_attached_file'
    WHERE p.post_type = 'product' 
    AND p.post_status = 'publish'
    AND pm_image.meta_value IS NOT NULL 
    AND pm_image.meta_value != ''
    ORDER BY p.post_date DESC
    LIMIT $PRODUCT_LIMIT
    " | sed 's/\t/","/g; s/^/"/; s/$/"/' | tail -n +2 >> "$COMPLETE_FILE"
    
    echo "   ✓ Extracted $PRODUCT_LIMIT products with tags"
else
    echo "2. Extracting products with tags in batches of $BATCH_SIZE..."
    
    while [ $current_offset -lt $total_products ]; do
        echo "   Processing batch $batch_number (offset: $current_offset, limit: $BATCH_SIZE)..."
        
        # Enhanced SQL query to include WooCommerce product tags
        unset LD_LIBRARY_PATH && /usr/bin/mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "
        SELECT 
            p.ID as product_id,
            REPLACE(REPLACE(REPLACE(REPLACE(p.post_title, '\n', ' '), '\r', ' '), '\t', ' '), '\"', '\"\"') as post_title,
            p.post_name as slug,
            REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(p.post_excerpt, '\n', ' '), '\r', ' '), '\t', ' '), '\"', '\"\"'), '${DELIMITER}', ' ') as short_description,
            REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(p.post_content, '\n', ' '), '\r', ' '), '\t', ' '), '\"', '\"\"'), '${DELIMITER}', ' ') as description,
            CASE 
                WHEN pm_image.meta_value IS NOT NULL 
                THEN CONCAT('https://${DOMAIN}/wp-content/uploads/', pm_image.meta_value)
                ELSE NULL
            END as image_url,
            COALESCE(
                (SELECT meta_value FROM ${DB_PREFIX}postmeta WHERE post_id = p.ID AND meta_key = '_price' LIMIT 1),
                (SELECT meta_value FROM ${DB_PREFIX}postmeta WHERE post_id = p.ID AND meta_key = '_regular_price' LIMIT 1),
                '0'
            ) AS price,
            COALESCE(
                (SELECT meta_value FROM ${DB_PREFIX}postmeta WHERE post_id = p.ID AND meta_key = '_sku' LIMIT 1),
                ''
            ) AS sku,
            COALESCE(
                (SELECT GROUP_CONCAT(t.name SEPARATOR ', ')
                 FROM ${DB_PREFIX}term_relationships tr
                 JOIN ${DB_PREFIX}term_taxonomy tt ON tr.term_taxonomy_id = tt.term_taxonomy_id
                 JOIN ${DB_PREFIX}terms t ON tt.term_id = t.term_id
                 WHERE tr.object_id = p.ID AND tt.taxonomy = 'product_cat'
                 GROUP BY tr.object_id),
                'Uncategorized'
            ) AS category,
            CASE 
                WHEN (SELECT COUNT(*) FROM ${DB_PREFIX}term_relationships tr3
                      JOIN ${DB_PREFIX}term_taxonomy tt3 ON tr3.term_taxonomy_id = tt3.term_taxonomy_id
                      JOIN ${DB_PREFIX}terms t3 ON tt3.term_id = t3.term_id
                      WHERE tr3.object_id = p.ID AND tt3.taxonomy = 'product_tag' AND t3.name = '30days') > 0
                THEN '30days'
                WHEN (SELECT COUNT(*) FROM ${DB_PREFIX}term_relationships tr2
                      JOIN ${DB_PREFIX}term_taxonomy tt2 ON tr2.term_taxonomy_id = tt2.term_taxonomy_id
                      JOIN ${DB_PREFIX}terms t2 ON tt2.term_id = t2.term_id
                      WHERE tr2.object_id = p.ID AND tt2.taxonomy = 'product_tag' AND t2.name = 'buynow') > 0
                THEN 'buynow'
                ELSE '30days'
            END AS product_type,
            COALESCE(
                (SELECT GROUP_CONCAT(t_tag.name SEPARATOR ', ')
                 FROM ${DB_PREFIX}term_relationships tr_tag
                 JOIN ${DB_PREFIX}term_taxonomy tt_tag ON tr_tag.term_taxonomy_id = tt_tag.term_taxonomy_id
                 JOIN ${DB_PREFIX}terms t_tag ON tt_tag.term_id = t_tag.term_id
                 WHERE tr_tag.object_id = p.ID AND tt_tag.taxonomy = 'product_tag'
                 AND t_tag.name IN ('buynow', '30days')
                 GROUP BY tr_tag.object_id),
                ''
            ) AS tags
        FROM ${DB_PREFIX}posts p
        LEFT JOIN ${DB_PREFIX}postmeta pm_thumb ON pm_thumb.post_id = p.ID AND pm_thumb.meta_key = '_thumbnail_id'
        LEFT JOIN ${DB_PREFIX}postmeta pm_image ON pm_image.post_id = pm_thumb.meta_value AND pm_image.meta_key = '_wp_attached_file'
        WHERE p.post_type = 'product' 
        AND p.post_status = 'publish'
        AND pm_image.meta_value IS NOT NULL 
        AND pm_image.meta_value != ''
        ORDER BY p.post_date DESC
        LIMIT $BATCH_SIZE OFFSET $current_offset
        " | sed 's/\t/","/g; s/^/"/; s/$/"/' | tail -n +2 >> "$COMPLETE_FILE"

        
        # Update counters
        current_offset=$((current_offset + BATCH_SIZE))
        batch_number=$((batch_number + 1))
        
        # Show progress
        processed=$((current_offset < total_products ? current_offset : total_products))
        percentage=$((processed * 100 / total_products))
        echo "   Progress: $processed/$total_products ($percentage%)"
        
        # Small delay to prevent overwhelming the database
        sleep 1
    done
fi

echo ""
echo "Enhanced product data extraction completed!"
echo "File created: $COMPLETE_FILE"
echo "Format: CSV"

echo ""
echo "=== Statistics ==="
total_products=$(tail -n +2 "$COMPLETE_FILE" | wc -l)
echo "Total products: $total_products"
echo ""
echo "Extraction completed successfully!"
echo "Use this data with the enhanced static generator for proper product type handling."
#!/usr/bin/env bash
#
# fetch_usda.sh
#
# Builds the USDA FoodData Central SQLite database the on-device AI tier uses
# for nutrition grounding. Run this on a developer machine before cutting a
# release; the resulting `usda_foods.sqlite` is committed to the app bundle
# at `ios/calorietracker/Resources/usda_foods.sqlite` and shipped as-is.
#
# Why a script instead of bundling the raw CSVs:
#   - USDA ships ~1 GB of CSVs across ten files; we only need ~15 columns from
#     two of them. SQLite + FTS5 trims that to ~80–120 MB depending on which
#     food category subset you keep.
#   - LIKE-based search is too slow on >300k rows in an app's main thread; FTS5
#     gives sub-millisecond lookups.
#
# Usage:
#   ./ios/scripts/fetch_usda.sh                   # full Foundation + Survey datasets
#   ./ios/scripts/fetch_usda.sh --foundation-only # smaller (~25 MB), just Foundation Foods
#
# Requirements: bash, curl, unzip, python3, sqlite3 (>=3.35 for FTS5).
#
# Outputs:
#   ios/calorietracker/Resources/usda_foods.sqlite    (final bundle artifact)
#   .build/usda/                                       (download/staging cache)

set -euo pipefail

# Resolve script + project paths so the script works whether invoked from
# the repo root or from anywhere else.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
IOS_DIR="$(cd -- "$SCRIPT_DIR/.." &>/dev/null && pwd)"
RESOURCES_DIR="$IOS_DIR/calorietracker/Resources"
CACHE_DIR="$IOS_DIR/.build/usda"
OUTPUT_DB="$RESOURCES_DIR/usda_foods.sqlite"

# Latest USDA FoodData Central full download (April 2024 dataset; update the URL
# when USDA cuts a new release — they publish a fresh ZIP roughly twice a year).
DATASET_URL="${USDA_DATASET_URL:-https://fdc.nal.usda.gov/fdc-datasets/FoodData_Central_csv_2024-04-18.zip}"

FOUNDATION_ONLY=0
for arg in "$@"; do
    case "$arg" in
        --foundation-only) FOUNDATION_ONLY=1 ;;
        -h|--help)
            sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "Unknown argument: $arg" >&2; exit 1 ;;
    esac
done

echo "→ Preparing directories"
mkdir -p "$RESOURCES_DIR" "$CACHE_DIR"

ZIP_PATH="$CACHE_DIR/fdc.zip"
if [[ ! -f "$ZIP_PATH" ]]; then
    echo "→ Downloading USDA dataset (this takes a while; ~1 GB)"
    curl --fail --location --output "$ZIP_PATH" "$DATASET_URL"
else
    echo "→ Using cached dataset at $ZIP_PATH"
fi

EXTRACT_DIR="$CACHE_DIR/extracted"
if [[ ! -d "$EXTRACT_DIR" ]]; then
    echo "→ Extracting"
    mkdir -p "$EXTRACT_DIR"
    unzip -q "$ZIP_PATH" -d "$EXTRACT_DIR"
fi

# USDA's CSVs live one level inside the zip (the dataset directory shifts on
# every release). Resolve it dynamically so the script doesn't break each time.
DATA_DIR="$(find "$EXTRACT_DIR" -mindepth 1 -maxdepth 2 -name "food.csv" -exec dirname {} \; | head -n 1)"
if [[ -z "${DATA_DIR:-}" ]]; then
    echo "✘ Could not find food.csv inside the extracted dataset" >&2
    exit 1
fi
echo "→ Using CSVs from $DATA_DIR"

# Schema must match USDAFoodDatabase.swift's expectations exactly. If you add
# a column, update both this script AND the Swift `runQuery` decoder.
TMP_DB="$CACHE_DIR/usda_foods.sqlite.tmp"
rm -f "$TMP_DB"

echo "→ Building schema"
sqlite3 "$TMP_DB" <<'SQL'
PRAGMA journal_mode = OFF;
PRAGMA synchronous = OFF;
PRAGMA temp_store = MEMORY;

CREATE TABLE foods (
    fdc_id INTEGER PRIMARY KEY,
    description TEXT NOT NULL,
    food_category TEXT,
    kcal_per_100g REAL,
    protein_per_100g REAL,
    carbs_per_100g REAL,
    fat_per_100g REAL,
    sugar_per_100g REAL,
    added_sugar_per_100g REAL,
    fiber_per_100g REAL,
    sat_fat_per_100g REAL,
    mono_fat_per_100g REAL,
    poly_fat_per_100g REAL,
    cholesterol_mg_per_100g REAL,
    sodium_mg_per_100g REAL,
    potassium_mg_per_100g REAL
);
SQL

echo "→ Loading and pivoting CSVs (this is the slow step)"
# USDA's CSVs are tall (one row per food×nutrient) so we pivot in Python
# rather than try to do a 15-column self-join in SQLite. The output is fed
# directly into sqlite3 .import for speed.
python3 - "$DATA_DIR" "$TMP_DB" "$FOUNDATION_ONLY" <<'PY'
import csv, sqlite3, sys, pathlib

data_dir, db_path, foundation_only = sys.argv[1], sys.argv[2], sys.argv[3] == "1"

# USDA nutrient IDs we care about. Map → SQLite column. Only these are pivoted;
# everything else is dropped (saves ~30% on final DB size).
NUTRIENT_MAP = {
    "1008": "kcal_per_100g",            # Energy (kcal)
    "1003": "protein_per_100g",         # Protein
    "1005": "carbs_per_100g",           # Carbohydrate, by difference
    "1004": "fat_per_100g",             # Total lipid (fat)
    "2000": "sugar_per_100g",           # Total sugars
    "1235": "added_sugar_per_100g",     # Added sugars
    "1079": "fiber_per_100g",           # Fiber, total dietary
    "1258": "sat_fat_per_100g",         # Fatty acids, total saturated
    "1292": "mono_fat_per_100g",        # Fatty acids, total monounsaturated
    "1293": "poly_fat_per_100g",        # Fatty acids, total polyunsaturated
    "1253": "cholesterol_mg_per_100g",  # Cholesterol
    "1093": "sodium_mg_per_100g",       # Sodium, Na
    "1092": "potassium_mg_per_100g",    # Potassium, K
}

# Optional category filter — Foundation Foods is the highest-quality subset.
if foundation_only:
    allowed_data_types = {"foundation_food"}
else:
    allowed_data_types = {"foundation_food", "sr_legacy_food", "survey_fndds_food"}

print("  · reading food.csv")
foods = {}
with open(pathlib.Path(data_dir, "food.csv"), newline="", encoding="utf-8") as f:
    reader = csv.DictReader(f)
    for row in reader:
        if row["data_type"] not in allowed_data_types:
            continue
        foods[row["fdc_id"]] = {
            "description": row["description"],
            "food_category": row.get("food_category_id") or None,
            "nutrients": {col: None for col in NUTRIENT_MAP.values()},
        }

print(f"  · {len(foods):,} foods kept")

# Pivot food_nutrient.csv (one row per food×nutrient) into the per-food dict.
print("  · pivoting food_nutrient.csv")
fn_path = pathlib.Path(data_dir, "food_nutrient.csv")
with open(fn_path, newline="", encoding="utf-8") as f:
    reader = csv.DictReader(f)
    for row in reader:
        food = foods.get(row["fdc_id"])
        if food is None:
            continue
        column = NUTRIENT_MAP.get(row["nutrient_id"])
        if column is None:
            continue
        try:
            food["nutrients"][column] = float(row["amount"])
        except (TypeError, ValueError):
            pass

# Resolve food_category_id → name.
print("  · reading food_category.csv")
categories = {}
cat_path = pathlib.Path(data_dir, "food_category.csv")
if cat_path.exists():
    with open(cat_path, newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            categories[row["id"]] = row["description"]

print("  · inserting rows")
conn = sqlite3.connect(db_path)
conn.execute("BEGIN")
columns = list(NUTRIENT_MAP.values())
placeholders = ", ".join(["?"] * (3 + len(columns)))
column_list = "fdc_id, description, food_category, " + ", ".join(columns)
sql = f"INSERT INTO foods ({column_list}) VALUES ({placeholders})"

for fdc_id, food in foods.items():
    conn.execute(sql, [
        int(fdc_id),
        food["description"],
        categories.get(food["food_category"]),
        *[food["nutrients"][col] for col in columns],
    ])
conn.commit()
conn.close()
print("  · done")
PY

echo "→ Building FTS5 index"
sqlite3 "$TMP_DB" <<'SQL'
-- Contentless FTS5 (content='foods', content_rowid='fdc_id') keeps only the
-- index, no duplicate text. ~30% smaller than a content-bearing FTS table.
CREATE VIRTUAL TABLE foods_fts USING fts5(description, content='foods', content_rowid='fdc_id');
INSERT INTO foods_fts (rowid, description) SELECT fdc_id, description FROM foods;
ANALYZE;
VACUUM;
SQL

mv "$TMP_DB" "$OUTPUT_DB"
echo "✓ Wrote $OUTPUT_DB ($(du -h "$OUTPUT_DB" | cut -f1))"
echo
echo "Next steps:"
echo "  1. Verify the file: sqlite3 \"$OUTPUT_DB\" \"SELECT COUNT(*) FROM foods;\""
echo "  2. Commit it (it auto-bundles via PBXFileSystemSynchronizedRootGroup)"
echo "  3. Build the app — USDAFoodDatabase will pick it up automatically"

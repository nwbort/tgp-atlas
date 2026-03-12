#!/usr/bin/env bash
#
# download - Fetch TGP fuel pricing from API and save as CSV
# Usage: ./download.sh URL

set -e

CURRENT_CSV="tgp-atlas-current.csv"
HISTORY_CSV="tgp-atlas-history.csv"
CURRENT_DIR="$(pwd)"
SCRAPED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

if [ $# -ne 1 ]; then
  echo "Usage: $0 URL"
  exit 1
fi

URL="$1"

if [[ ! "$URL" =~ ^https?:// ]]; then
  echo "Error: URL must start with http:// or https://"
  exit 1
fi

echo "Downloading $URL"
TEMP_JSON=$(mktemp)
curl -s -L "$URL" -o "$TEMP_JSON" || {
  echo "Error: Failed to download $URL"
  rm -f "$TEMP_JSON"
  exit 1
}

python3 - "$TEMP_JSON" "${CURRENT_DIR}/${CURRENT_CSV}" "${CURRENT_DIR}/${HISTORY_CSV}" "$SCRAPED_AT" << 'PYEOF'
import sys
import csv
import json
import os

temp_file, current_csv, history_csv, scraped_at = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

with open(temp_file, 'r', encoding='utf-8') as f:
    records = json.load(f)

if not records:
    print("Error: Empty response from API", file=sys.stderr)
    sys.exit(1)

FIELDS = ['state_name', 'city_name', 'product_name', 'margin_price', 'fuel_price', 'final_price', 'created_at', 'updated_at']
header = FIELDS + ['scraped_at']
data_rows = [[str(r.get(f, '')) for f in FIELDS] + [scraped_at] for r in records]

print(f"Fetched {len(data_rows)} records")

# Write current CSV (overwrite each run)
with open(current_csv, 'w', newline='', encoding='utf-8') as f:
    writer = csv.writer(f)
    writer.writerow(header)
    writer.writerows(data_rows)
print(f"Written to {current_csv}")

# Append only new unique rows to history CSV
# Uniqueness is based on all columns except scraped_at
existing_keys = set()
history_exists = os.path.exists(history_csv)
if history_exists:
    with open(history_csv, 'r', newline='', encoding='utf-8') as f:
        reader = csv.reader(f)
        next(reader, None)  # skip header
        for row in reader:
            existing_keys.add(tuple(row[:-1]))

new_rows = [row for row in data_rows if tuple(row[:-1]) not in existing_keys]

with open(history_csv, 'a', newline='', encoding='utf-8') as f:
    writer = csv.writer(f)
    if not history_exists:
        writer.writerow(header)
    writer.writerows(new_rows)
print(f"Appended {len(new_rows)} new row(s) to {history_csv}")
PYEOF

rm -f "$TEMP_JSON"

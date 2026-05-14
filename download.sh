#!/usr/bin/env bash
#
# download - Fetch TGP fuel pricing from API and save as CSV
# Usage: ./download.sh URL

set -e

CURRENT_CSV="tgp-atlas-current.csv"
HISTORY_CSV="tgp-atlas-history.csv"
NORMALISED_CSV="tgp_data.csv"
NORMALISED_JSON="tgp_data.json"
PROVIDER="atlas"
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

python3 - "${CURRENT_DIR}/${HISTORY_CSV}" "${CURRENT_DIR}/${NORMALISED_CSV}" "${CURRENT_DIR}/${NORMALISED_JSON}" "$PROVIDER" << 'PYEOF'
import sys
import csv
import json
from datetime import datetime, timezone

history_csv, normalised_csv, normalised_json, provider = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

STATE_MAP = {
    'New South Wales': 'NSW',
    'Victoria': 'VIC',
    'Queensland': 'QLD',
    'South Australia': 'SA',
    'Western Australia': 'WA',
    'Northern Territory': 'NT',
    'Tasmania': 'TAS',
    'Australian Capital Territory': 'ACT',
}

FUEL_MAP = {
    'Unleaded 91 (ULP)': 'ulp91',
    'Blended E10': 'e10',
    'Pulp - 95': 'p95',
    'Premium - 95': 'p95',
    'Premium - 98': 'p98',
    'Diesel': 'diesel',
    'Premium Diesel': 'prediesel',
    'Biodiesel B5': 'b5',
}

FIELDS = ['date', 'state', 'location', 'fuel_type', 'price_cpl']

seen = set()
rows = []
skipped = 0

with open(history_csv, 'r', newline='', encoding='utf-8') as f:
    reader = csv.DictReader(f)
    for r in reader:
        state = STATE_MAP.get(r['state_name'])
        fuel = FUEL_MAP.get(r['product_name'])
        if not state or not fuel:
            skipped += 1
            continue
        try:
            dollars_per_litre = float(r['final_price'])
        except (ValueError, TypeError):
            skipped += 1
            continue
        if dollars_per_litre <= 0:
            skipped += 1
            continue
        price_cpl = round(dollars_per_litre * 100, 1)
        date = r['scraped_at'][:10]
        location = r['city_name']
        key = (date, state, location, fuel)
        if key in seen:
            continue
        seen.add(key)
        rows.append([date, state, location, fuel, price_cpl])

rows.sort(key=lambda x: (x[0], x[1], x[2], x[3]))

with open(normalised_csv, 'w', newline='', encoding='utf-8') as f:
    writer = csv.writer(f)
    writer.writerow(FIELDS)
    writer.writerows(rows)
print(f"Written {len(rows)} rows to {normalised_csv} (skipped {skipped})")

payload = {
    'provider': provider,
    'updated': datetime.now(timezone.utc).strftime('%Y-%m-%d'),
    'fields': FIELDS,
    'records': rows,
}

with open(normalised_json, 'w', encoding='utf-8') as f:
    json.dump(payload, f, separators=(',', ':'))
    f.write('\n')
print(f"Written {len(rows)} records to {normalised_json}")
PYEOF

rm -f "$TEMP_JSON"

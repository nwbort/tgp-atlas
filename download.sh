#!/usr/bin/env bash
#
# download - Fetch TGP fuel pricing table and save as CSV
# Usage: ./download.sh URL

set -e

CURRENT_CSV="tgp-atlas-current.csv"
HISTORY_CSV="tgp-atlas-history.csv"
CURRENT_DIR="$(pwd)"
SCRAPED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Check if URL provided
if [ $# -ne 1 ]; then
  echo "Usage: $0 URL"
  exit 1
fi

URL="$1"

# Validate URL format (must start with http:// or https://)
if [[ ! "$URL" =~ ^https?:// ]]; then
  echo "Error: URL must start with http:// or https://"
  exit 1
fi

# Fetch the rates page
echo "Downloading $URL"
TEMP_TABLE=$(mktemp)
curl -s -L "$URL" -o "$TEMP_TABLE" || {
  echo "Error: Failed to download $URL"
  rm -f "$TEMP_TABLE"
  exit 1
}

# Parse table and write CSVs using Python
python3 - "$TEMP_TABLE" "${CURRENT_DIR}/${CURRENT_CSV}" "${CURRENT_DIR}/${HISTORY_CSV}" "$SCRAPED_AT" << 'PYEOF'
import sys
import csv
import os
from html.parser import HTMLParser

class TableParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.tables = []
        self._in_table = False
        self._in_row = False
        self._in_cell = False
        self._current_rows = []
        self._current_row = []
        self._current_cell_parts = []

    def handle_starttag(self, tag, attrs):
        if tag == 'table':
            self._in_table = True
            self._current_rows = []
        elif tag == 'tr' and self._in_table:
            self._in_row = True
            self._current_row = []
        elif tag in ('td', 'th') and self._in_row:
            self._in_cell = True
            self._current_cell_parts = []

    def handle_endtag(self, tag):
        if tag == 'table':
            self._in_table = False
            if self._current_rows:
                self.tables.append(self._current_rows)
        elif tag == 'tr' and self._in_row:
            self._in_row = False
            if self._current_row:
                self._current_rows.append(self._current_row)
        elif tag in ('td', 'th') and self._in_cell:
            self._in_cell = False
            self._current_row.append(' '.join(self._current_cell_parts).strip())

    def handle_data(self, data):
        if self._in_cell:
            stripped = data.strip()
            if stripped:
                self._current_cell_parts.append(stripped)


temp_file, current_csv, history_csv, scraped_at = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

with open(temp_file, 'r', encoding='utf-8', errors='replace') as f:
    html_content = f.read()

parser = TableParser()
parser.feed(html_content)

if not parser.tables:
    print("Error: No table found in the fetched content", file=sys.stderr)
    sys.exit(1)

# Use the largest table (most rows)
rows = max(parser.tables, key=len)

if len(rows) < 2:
    print("Error: Table has no data rows", file=sys.stderr)
    sys.exit(1)

print(f"Found table with {len(rows) - 1} data rows")

header = rows[0] + ['scraped_at']
data_rows = [row + [scraped_at] for row in rows[1:]]

# Write current CSV (overwrite each run)
with open(current_csv, 'w', newline='', encoding='utf-8') as f:
    writer = csv.writer(f)
    writer.writerow(header)
    writer.writerows(data_rows)
print(f"Written to {current_csv}")

# Append only new unique rows to history CSV
existing_keys = set()
history_exists = os.path.exists(history_csv)
if history_exists:
    with open(history_csv, 'r', newline='', encoding='utf-8') as f:
        reader = csv.reader(f)
        next(reader, None)  # skip header
        for row in reader:
            # Key on all columns except scraped_at (last column)
            existing_keys.add(tuple(row[:-1]))

new_rows = [row for row in data_rows if tuple(row[:-1]) not in existing_keys]

with open(history_csv, 'a', newline='', encoding='utf-8') as f:
    writer = csv.writer(f)
    if not history_exists:
        writer.writerow(header)
    writer.writerows(new_rows)
print(f"Appended {len(new_rows)} new row(s) to {history_csv}")
PYEOF

rm -f "$TEMP_TABLE"

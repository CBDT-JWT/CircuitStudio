#!/usr/bin/env python3
"""Export the private contact list locally. No public email-list endpoint exists."""
import argparse
import csv
from pathlib import Path
import sqlite3

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--database', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--downloaded-only', action='store_true')
args = parser.parse_args()
connection = sqlite3.connect('file:' + str(args.database.resolve()) + '?mode=ro', uri=True)
query = 'SELECT email,created_at,first_download_at,last_download_at,last_version FROM contacts'
if args.downloaded_only:
    query += ' WHERE first_download_at IS NOT NULL'
rows = connection.execute(query + ' ORDER BY created_at').fetchall()
args.output.parent.mkdir(parents=True, exist_ok=True)
with args.output.open('w', newline='') as stream:
    writer = csv.writer(stream)
    writer.writerow(['email', 'requested_at', 'first_download_at', 'last_download_at', 'last_version'])
    writer.writerows([("'" + value if isinstance(value, str) and value.startswith(('=', '+', '-', '@')) else value) for value in row] for row in rows)
args.output.chmod(0o600)
print(f'Exported {len(rows)} contacts to {args.output}')

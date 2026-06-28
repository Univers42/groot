#!/usr/bin/env bash
# ============================================================
# sqlite-to-csv.sh  <sqlite.db>  <out-dir>
# ============================================================
# Dump EVERY table of a SQLite .db file to individual CSV files
# (with header row) in <out-dir>/<table>.csv.
#
# Docker-only: uses a throwaway alpine+sqlite3 container.
# No host sqlite3 required — only Docker.
#
# This bridges any SQLite dataset (e.g. CS50 .db files) into the
# CSV shape consumed by the other loaders in this directory.
#
# Usage:
#   bash sqlite-to-csv.sh path/to/movies.db /tmp/movies-csv
#   bash sqlite-to-csv.sh cs50/downloads/pset1-relating/packages/packages.db /tmp/pkg-csv
# ============================================================
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <sqlite.db> <out-dir>" >&2
  exit 1
fi

SQLITE_DB="$1"
OUT_DIR="$2"

# Resolve absolute paths (required for docker -v mounts)
SQLITE_ABS="$(cd "$(dirname "${SQLITE_DB}")" && pwd)/$(basename "${SQLITE_DB}")"
SQLITE_DIR="$(dirname "${SQLITE_ABS}")"
SQLITE_FILE="$(basename "${SQLITE_ABS}")"

mkdir -p "${OUT_DIR}"
OUT_ABS="$(cd "${OUT_DIR}" && pwd)"

echo "==> [sqlite-to-csv] Source : ${SQLITE_ABS}"
echo "==> [sqlite-to-csv] Output : ${OUT_ABS}/"
echo ""

docker run --rm \
  -e "SQLITE_FILE=${SQLITE_FILE}" \
  -v "${SQLITE_DIR}:/input:ro" \
  -v "${OUT_ABS}:/output" \
  alpine sh -c '
    set -e
    apk add --no-cache sqlite >/dev/null 2>&1

    db="/input/${SQLITE_FILE}"

    # List all user-visible tables (trim whitespace, one per line)
    tables=$(sqlite3 "$db" ".tables" 2>/dev/null \
      | tr " " "\n" | tr "\t" "\n" | grep -v "^[[:space:]]*$" | sort)

    if [ -z "$tables" ]; then
      echo "ERROR: no tables found in ${SQLITE_FILE}" >&2
      exit 1
    fi

    count=0
    for table in $tables; do
      out_file="/output/${table}.csv"
      # Use dot commands: the -header CLI flag is silently ignored in sqlite3 ≥3.45
      # when a query is supplied as an argument; dot commands always work.
      printf ".mode csv\n.headers on\nSELECT * FROM \"%s\";\n" "${table}" \
        | sqlite3 "$db" > "$out_file"
      # Count data rows (header is line 1); strip \r in case of CRLF output
      # Use double quotes for awk/tr patterns: outer sh -c uses single quotes
      rows=$(awk "NR>1" "$out_file" | tr -d "\r" | grep -c .)
      printf "  %-24s -> %s.csv  (%d data rows)\n" "${table}" "${table}" "${rows}"
      count=$((count + 1))
    done

    echo ""
    echo "Exported ${count} table(s) to /output/"
  '

echo ""
echo "==> [sqlite-to-csv] Done. CSVs in ${OUT_ABS}/"

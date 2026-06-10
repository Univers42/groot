#!/usr/bin/env python3
"""Append/refresh the gourmand-db entry in the osionos app's
VITE_BAAS_LIVE_MOUNTS fallback JSON (mode-preserving, idempotent).

Usage: GOURMAND_DB_ID=<uuid> gourmand_app_env.py <app .env path>
"""
import json
import os
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
db_id = os.environ.get("GOURMAND_DB_ID")
if not db_id:
    sys.exit("GOURMAND_DB_ID is required (source .gourmand-tenant.env)")
mode = os.stat(path).st_mode & 0o777 if path.exists() else 0o600
lines = path.read_text().splitlines() if path.exists() else []
idx = next((i for i, line in enumerate(lines)
            if line.startswith("VITE_BAAS_LIVE_MOUNTS=")), None)
mounts = json.loads(lines[idx].split("=", 1)[1]) if idx is not None else []
mounts = [m for m in mounts if m.get("name") != "gourmand-db"]
mounts.append({"dbId": db_id, "name": "gourmand-db", "engine": "postgresql"})
line = "VITE_BAAS_LIVE_MOUNTS=" + json.dumps(mounts, separators=(",", ":"))
if idx is not None:
    lines[idx] = line
else:
    lines.append(line)
path.write_text("\n".join(lines) + "\n")
os.chmod(path, mode)
print(f"VITE_BAAS_LIVE_MOUNTS now lists gourmand-db {db_id}")

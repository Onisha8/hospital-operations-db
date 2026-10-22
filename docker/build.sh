#!/bin/bash
# Builds HospitalOps inside Docker: runs sql/*.sql in order, then tests/*.sql.
# Invoked by the "build" service in docker-compose.yml. Exits non-zero on the first failure.
set -euo pipefail

SQLCMD=/opt/mssql-tools18/bin/sqlcmd
# -C trust the container's self-signed certificate   -b exit on error
# -I QUOTED_IDENTIFIER ON (required by filtered indexes and persisted computed columns;
#    sqlcmd defaults it to OFF, unlike SSMS and .NET)
# DataDir is where the db container sees ./data (mounted at /data)
ARGS=(-S db -U sa -P "$MSSQL_SA_PASSWORD" -C -b -I -W -v DataDir=/data)

start=$(date +%s)
run() {
    echo "==> $(basename "$1")"
    local out=/tmp/$(basename "$1").log
    if ! "$SQLCMD" "${ARGS[@]}" -i "$1" > "$out" 2>&1; then
        cat "$out"                                   # full output (incl. test result tables) on failure
        echo "FAILED: $(basename "$1")"
        exit 1
    fi
    grep -E "completed|passed|Total rows" "$out" | sed 's/^/    /' || true   # summary lines only
}

for f in /repo/sql/*.sql; do run "$f"; done

if [ "${RUN_TESTS:-1}" = "1" ]; then
    for f in /repo/tests/*.sql; do run "$f"; done
fi

echo "HospitalOps built successfully in $(( $(date +%s) - start )) s."
echo "Connect: server localhost,14333  user sa  database HospitalOps"

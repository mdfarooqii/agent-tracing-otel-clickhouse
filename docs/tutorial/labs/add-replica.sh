#!/usr/bin/env bash
# Module 10 lab: make clickhouse-03 a third replica of every otel table.
#
#   docs/tutorial/labs/add-replica.sh
#
# Copies each table's DDL from clickhouse-01, keeping the table UUID. The Keeper
# path is /clickhouse/tables/{uuid}/{shard}, so the same UUID plus a new
# {replica} macro registers clickhouse-03 as one more replica of the same table,
# and it fetches every existing part from its peers.
set -euo pipefail

src() { docker exec clickhouse-01 clickhouse-client --password demo "$@"; }
dst() { docker exec -i clickhouse-03 clickhouse-client --password demo "$@"; }

dst -q "CREATE DATABASE IF NOT EXISTS otel"

# Tables first, then the materialized views that write into them.
tables=$(src -q "SELECT name FROM system.tables WHERE database = 'otel' ORDER BY engine = 'MaterializedView', name")
for table in $tables; do
  ddl=$(src --format TSVRaw -q "SHOW CREATE TABLE otel.$table SETTINGS show_table_uuid_in_table_create_query_if_not_nil = 1")
  echo "$ddl" | sed -E '1s/^CREATE (TABLE|MATERIALIZED VIEW) /CREATE \1 IF NOT EXISTS /' | dst --multiquery
  echo "created otel.$table"
done

#!/usr/bin/env bash
# Appendix B, rolling restart and upgrade: the health gate between servers.
# Waits until a restarted ClickHouse server has loaded its tables and caught
# up on replication, then checks for new errors. Exit 0 = gate passed.
#
# usage: docs/tutorial/labs/rolling-gate.sh <container> [timeout seconds]
# In production, replace `docker exec` with clickhouse-client --host <server>.
set -uo pipefail

server=${1:?usage: rolling-gate.sh <container> [timeout seconds]}
timeout=${2:-900}
max_delay=60
q() { docker exec "$server" clickhouse-client --password demo -q "$1" 2>/dev/null; }

wait_for() {  # wait_for <description> <query that returns 0 when ready>
  local deadline=$(( $(date +%s) + timeout ))
  until [ "$(q "$2")" = "0" ]; do
    if [ "$(date +%s)" -ge "$deadline" ]; then echo "FAIL  $1 (after ${timeout}s)"; exit 1; fi
    sleep 5
  done
  echo "ok    $1"
}

wait_for "accepting queries" "SELECT 0"
wait_for "all tables loaded" \
  "SELECT count() FROM system.asynchronous_loader WHERE status != 'OK'"
wait_for "no read-only replicas, lag under ${max_delay}s" \
  "SELECT count() FROM system.replicas WHERE is_readonly OR absolute_delay > $max_delay"

for t in $(q "SELECT database || '.' || table FROM system.replicas WHERE database NOT IN ('system')"); do
  q "SYSTEM SYNC REPLICA $t LIGHTWEIGHT" >/dev/null \
    || { echo "FAIL  replica sync $t"; exit 1; }
done
echo "ok    replication queues fetched (SYSTEM SYNC REPLICA ... LIGHTWEIGHT)"

echo "info  version $(q 'SELECT version()')"
sleep 30
new_errors=$(q "SELECT groupArray(name) FROM system.errors
                WHERE last_error_time >= now() - uptime()")
if [ "$new_errors" != "[]" ]; then echo "WARN  errors since start, check they are expected: $new_errors"; fi
echo "PASS  $server"

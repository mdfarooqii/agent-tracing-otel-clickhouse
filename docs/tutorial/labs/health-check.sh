#!/usr/bin/env bash
# Module 12 lab: one-screen health check of the pipeline, from gateway to Keeper.
#
#   docs/tutorial/labs/health-check.sh
#
# Thresholds are starting points for this demo, not production values.
set -uo pipefail

CLICKHOUSE_NODES=(clickhouse-01 clickhouse-02)
status=0

ok()   { printf '  \033[32mOK  \033[0m %s\n' "$*"; }
warn() { printf '  \033[33mWARN\033[0m %s\n' "$*"; status=1; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; status=2; }
ch()   { docker exec "$1" clickhouse-client --password demo -q "$2" 2>/dev/null; }
metric() {
  # Sum one gateway metric over all its label sets, optionally filtered by a label match.
  curl -sf localhost:18888/metrics | grep -E "^$1(\{|\s)" | grep -E "${2:-.}" | awk '{s += $NF} END {printf "%d", s}'
}

echo "Gateway (otel-gateway)"
if curl -sf localhost:13133 >/dev/null; then ok "health check endpoint answers"; else fail "health check endpoint down"; fi
if curl -sf localhost:18888/metrics >/dev/null; then
  size=$(metric otelcol_exporter_queue_size 'exporter="clickhouse"')
  capacity=$(metric otelcol_exporter_queue_capacity 'exporter="clickhouse"')
  accepted=$(metric otelcol_receiver_accepted_spans_total)
  refused=$(metric otelcol_receiver_refused_spans_total)
  filtered=$(metric otelcol_processor_filter_spans_filtered_total)
  sent=$(metric otelcol_exporter_sent_spans_total 'exporter="clickhouse"')
  failed=$(metric otelcol_exporter_send_failed_spans_total 'exporter="clickhouse"')
  enqueue_failed=$(metric otelcol_exporter_enqueue_failed_spans_total 'exporter="clickhouse"')
  if ((size * 2 > capacity)); then warn "export queue $size/$capacity batches"; else ok "export queue $size/$capacity batches"; fi
  ok "since start: accepted $accepted, filtered $filtered, sent $sent"
  if ((refused > 0)); then warn "refused $refused spans (memory limiter): apps had to retry or drop"; else ok "refused 0 spans"; fi
  if ((failed + enqueue_failed > 0)); then fail "lost $failed spans after retries, $enqueue_failed with the queue full"; else ok "lost 0 spans"; fi
else
  fail "metrics endpoint :18888 not reachable"
fi

echo "Keeper (clickhouse-keeper)"
keeper() { docker exec clickhouse-01 bash -c "exec 3<>/dev/tcp/clickhouse-keeper/9181; echo -n $1 >&3; cat <&3" 2>/dev/null; }
if [[ $(keeper ruok) == imok ]]; then
  mntr=$(keeper mntr)
  get() { awk -v k="$1" '$1 == k {print $2}' <<<"$mntr"; }
  ok "ruok: imok, state $(get zk_server_state), $(get zk_znode_count) znodes"
  if (($(get zk_outstanding_requests) > 10)); then warn "$(get zk_outstanding_requests) outstanding requests"; else ok "outstanding requests $(get zk_outstanding_requests), max latency $(get zk_max_latency) ms"; fi
else
  fail "Keeper does not answer ruok: replicated tables will be read-only"
fi

for node in "${CLICKHOUSE_NODES[@]}"; do
  echo "ClickHouse ($node)"
  if [[ $(ch "$node" "SELECT 1") != 1 ]]; then fail "not answering"; continue; fi
  read -r readonly max_delay max_queue <<<"$(ch "$node" "SELECT sum(is_readonly), max(absolute_delay), max(queue_size) FROM system.replicas WHERE database = 'otel'")"
  if ((readonly > 0)); then fail "$readonly read-only replicated tables (Keeper session lost?)"; else ok "no read-only tables"; fi
  if ((max_delay > 60 || max_queue > 100)); then warn "replication lag ${max_delay}s, queue $max_queue"; else ok "replication lag ${max_delay}s, queue $max_queue"; fi
  parts=$(ch "$node" "SELECT max(c) FROM (SELECT count() AS c FROM system.parts WHERE active GROUP BY database, table, partition)")
  if ((parts > 300)); then warn "$parts parts in one partition (inserts slow down at 1000, fail at 3000)"; else ok "max $parts parts in a partition"; fi
  free=$(ch "$node" "SELECT round(100 * free_space / total_space) FROM system.disks WHERE name = 'default'")
  if ((free < 15)); then warn "local disk ${free}% free"; else ok "local disk ${free}% free"; fi
  memory=$(ch "$node" "SELECT round(100 * (SELECT value FROM system.metrics WHERE metric = 'MemoryTracking') / (SELECT toUInt64(value) FROM system.server_settings WHERE name = 'max_server_memory_usage'))")
  if ((memory > 80)); then warn "memory ${memory}% of the server limit"; else ok "memory ${memory}% of the server limit"; fi
  lag=$(ch "$node" "SELECT dateDiff('second', max(Timestamp), now64(9)) FROM otel.otel_traces WHERE Timestamp > now() - INTERVAL 1 HOUR")
  if [[ -z $lag || $lag -gt 120 ]]; then warn "newest span is ${lag:-more than 3600}s old (no traffic, or ingestion stalled)"; else ok "newest span ${lag}s old"; fi
  rejected=$(ch "$node" "SELECT sum(value) FROM system.events WHERE event IN ('RejectedInserts', 'DelayedInserts')")
  if ((rejected > 0)); then warn "$rejected delayed or rejected inserts since start (too many parts)"; else ok "no delayed or rejected inserts"; fi
  stuck=$(ch "$node" "SELECT count() FROM system.mutations WHERE NOT is_done AND create_time < now() - INTERVAL 10 MINUTE")
  if ((stuck > 0)); then warn "$stuck mutations running for more than 10 minutes"; else ok "no stuck mutations"; fi
  s3=$(ch "$node" "SELECT count() FROM system.disks WHERE name = 's3'")
  if ((s3 > 0)); then
    s3_errors=$(ch "$node" "SELECT sum(value) FROM system.events WHERE event IN ('S3WriteRequestsErrors', 'S3ReadRequestsErrors')")
    on_s3=$(ch "$node" "SELECT count() FROM system.parts WHERE active AND disk_name LIKE 's3%'")
    if ((s3_errors > 0)); then warn "$s3_errors S3 request errors since start"; else ok "S3: $on_s3 parts in cold storage, no request errors"; fi
  fi
  recent=$(ch "$node" "SELECT arrayStringConcat(groupArray(name), ', ') FROM system.errors WHERE last_error_time > now() - INTERVAL 10 MINUTE AND name NOT IN ('UNKNOWN_TABLE', 'SYNTAX_ERROR')")
  if [[ -n $recent ]]; then warn "errors in the last 10 minutes: $recent"; fi
done

exit $status

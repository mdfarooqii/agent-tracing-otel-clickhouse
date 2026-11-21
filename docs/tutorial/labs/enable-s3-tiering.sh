#!/usr/bin/env bash
# Module 11 lab: switch the otel tables to the "tiered" storage policy and add
# a TTL rule that moves parts to S3 after MOVE_AFTER.
#
#   MOVE_AFTER='10 MINUTE' docs/tutorial/labs/enable-s3-tiering.sh
#
# MOVE_AFTER (default '1 DAY') and DELETE_AFTER (default '72 HOUR') are
# ClickHouse INTERVAL expressions. Needs compose.s3-tiering.yaml running.
set -euo pipefail

MOVE_AFTER=${MOVE_AFTER:-1 DAY}
DELETE_AFTER=${DELETE_AFTER:-72 HOUR}

ch() { docker exec clickhouse-01 clickhouse-client --password demo -q "$1" >/dev/null; }

# A table can only switch to a policy that keeps its old policy's volumes;
# "tiered" keeps the local disk as a volume named "default".
for table in otel_traces otel_traces_trace_id_ts trace_entry; do
  ch "ALTER TABLE otel.$table ON CLUSTER tracing MODIFY SETTING storage_policy = 'tiered'"
done
ch "ALTER TABLE otel.span_red_1m ON CLUSTER tracing MODIFY SETTING storage_policy = 'tiered'"

ch "ALTER TABLE otel.otel_traces ON CLUSTER tracing MODIFY TTL
      toDateTime(Timestamp) + INTERVAL $MOVE_AFTER TO VOLUME 'cold',
      toDateTime(Timestamp) + INTERVAL $DELETE_AFTER DELETE"
ch "ALTER TABLE otel.otel_traces_trace_id_ts ON CLUSTER tracing MODIFY TTL
      Start + INTERVAL $MOVE_AFTER TO VOLUME 'cold',
      Start + INTERVAL $DELETE_AFTER DELETE"
ch "ALTER TABLE otel.trace_entry ON CLUSTER tracing MODIFY TTL
      toDateTime(Start) + INTERVAL $MOVE_AFTER TO VOLUME 'cold',
      toDateTime(Start) + INTERVAL $DELETE_AFTER DELETE"
ch "ALTER TABLE otel.span_red_1m ON CLUSTER tracing MODIFY TTL
      minute + INTERVAL $MOVE_AFTER TO VOLUME 'cold',
      minute + INTERVAL 1 YEAR DELETE"

echo "Tiered storage on: parts move to S3 after $MOVE_AFTER, are deleted after $DELETE_AFTER (span_red_1m: 1 YEAR)."

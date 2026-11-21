# Module 12: Operational readiness, from gateway to ClickHouse (40 min)

## Idea

A tracing pipeline is itself a production system. It has to answer four
questions at all times, and every metric below serves one of them:

| Question | Signal | How to measure it here |
|---|---|---|
| **Is data arriving?** (freshness) | Age of the newest span in ClickHouse | `now() - max(Timestamp)` |
| **Is data complete?** (loss) | Spans refused, dropped or failed at each hop | Gateway counters; SDK export errors |
| **Is it keeping up?** (saturation) | Queues, parts, replication lag, memory, disk | Gateway queue; `system.replicas`, `system.parts`, `system.disks` |
| **Can people use it?** (query health) | Query latency and errors | `system.query_log` |

Data can be lost at four hops. Know all four, because each needs its own
metric:

```text
 app SDK ──▶ gateway receiver ──▶ processors ──▶ export queue ──▶ ClickHouse ──▶ Keeper
   │              │                    │               │               │            │
 queue full,   memory limiter      filter drops     queue full,     too many     down: tables
 process exits refuses data        (by design)      retries         parts,       go read-only
 (lost)        (app must retry)                     exhausted       disk full,
                                                    (lost)          read-only
```

A healthy pipeline balances its books:
**accepted = filtered + sent + still in queue + failed**. If the numbers don't
add up, something is losing data silently.

## Per component: what to watch, what fails, what to do

### 1. Application SDKs

| Watch | Why | Notes |
|---|---|---|
| Export errors in app logs (`Failed to export spans batch`) | The SDK drops spans after a few retries | Module 4 lab: a 45 s gateway outage lost every turn in that window |
| `OTEL_BSP_MAX_QUEUE_SIZE` vs traffic | A full queue drops new spans silently | Default 2048 spans |
| Sampling settings | Inconsistent samplers create orphans | Parent-based everywhere (module 5) |
| Resource labels present | The gateway drops spans without `org.owner` and `org.service` | Watch the filter counter below per service |

**Handle**: short-lived processes (jobs, CLIs, serverless) must call
`provider.shutdown()` to flush. For anything critical, send to a local agent
collector instead of a remote gateway, so the app hands off in milliseconds.

### 2. Gateway (OpenTelemetry Collector)

Metrics come from the Collector itself, in Prometheus format at
<http://localhost:18888/metrics> (`service.telemetry` in
`otel-gateway-config.yaml`).

| Metric | Meaning | Alert when |
|---|---|---|
| `otelcol_receiver_accepted_spans_total` | Spans received | Rate drops to zero: senders are down, or the network is |
| `otelcol_receiver_refused_spans_total` | Rejected by `memory_limiter` (back-pressure) | Any sustained rate |
| `otelcol_processor_filter_spans_filtered_total` | Dropped by the label filter | Sudden rise: a service lost its labels |
| `otelcol_exporter_queue_size` / `otelcol_exporter_queue_capacity` | Batches waiting to be written | Above 50% for minutes: ClickHouse is slow or down |
| `otelcol_exporter_sent_spans_total` | Written to ClickHouse | Rate falls below the accepted rate |
| `otelcol_exporter_send_failed_spans_total` | **Lost** after retries ran out | Any increase |
| `otelcol_exporter_enqueue_failed_spans_total` | **Lost** because the queue was full | Any increase |
| `otelcol_process_memory_rss_bytes` | Gateway memory | Near the container limit or `memory_limiter.limit_mib` |
| `otelcol_processor_batch_batch_send_size` | Spans per batch | Mostly tiny batches mean many small inserts into ClickHouse |
| Health check `:13133` | Liveness | Fails |

Failure modes and handling:

| Failure | Symptom | Handle |
|---|---|---|
| ClickHouse slow or down | Queue grows; then `send_failed` after `max_elapsed_time` (300 s) | Size the queue for your longest expected outage; add `sending_queue.storage` with `file_storage` so restarts don't lose it |
| Gateway restart | In-memory queue lost | Persistent queue; run 2 or more gateway replicas behind a load balancer |
| Memory pressure | `refused_spans` rising; OOM kills | `memory_limiter` first in the pipeline; set container limits about 20% above `limit_mib` |
| Label regression in a service | `filtered` jumps | Alert per service; make the filter visible to teams |
| Tail sampling at scale | Fragmented traces | Load-balancing tier by trace id (module 5) |
| Config error on deploy | Gateway won't start | Validate before deploying: `otelcol-contrib validate --config=...` |

### 3. ClickHouse servers

Everything is queryable in SQL, on each node. For Prometheus, enable
ClickHouse's built-in endpoint (`<prometheus><port>9363</port>...</prometheus>`
in the server config), which exposes `system.metrics`, `system.events` and
`system.asynchronous_metrics`.

| Watch | Where | Alert when |
|---|---|---|
| Freshness | `SELECT now() - max(Timestamp) FROM otel.otel_traces` | Above a few minutes, with traffic running |
| Parts per partition | `MaxPartCountForPartition` in `system.asynchronous_metrics` | Above 300. Inserts are **delayed at 1000** (`parts_to_delay_insert`) and **rejected at 3000** (`parts_to_throw_insert`) |
| Delayed and rejected inserts | `DelayedInserts`, `RejectedInserts` in `system.events` | Any |
| Failed inserts | `FailedInsertQuery` in `system.events` | Rising |
| Memory | `MemoryTracking` in `system.metrics` vs `max_server_memory_usage` | Above 80% |
| Disk | `system.disks`: `free_space / total_space` | Under 15% free, or near `move_factor` with S3 tiering |
| Merges keeping up | `BackgroundMergesAndMutationsPoolTask` in `system.metrics`; `system.merges` | Pool always full and parts rising |
| Stuck mutations | `system.mutations WHERE NOT is_done` | Running for more than ~10 minutes |
| Errors | `system.errors` (by name, count, last time) | New error names, or rates rising |
| Slow queries | `system.query_log`: `query_duration_ms`, `memory_usage`, `read_rows` | p95 over your target |
| TTL working | `system.parts`: oldest `min_time` per table | Older than the retention period |

Failure modes and handling:

| Failure | Symptom | Handle |
|---|---|---|
| Too many small inserts | Parts rising, `DelayedInserts`, then `Too many parts` | Bigger gateway batches; or `async_insert` |
| Disk full | Inserts and merges fail | TTL retention; S3 tiering with `move_factor`; alert at 15% free |
| Memory limit exceeded | Queries fail with `MEMORY_LIMIT_EXCEEDED` | Per-user limits (`max_memory_usage`); query patterns that use the sorting key |
| Heavy ad hoc queries | Ingestion slows | Separate users and quotas for dashboards and ad hoc use; `max_execution_time` |
| Cardinality explosion | Map columns and indexes grow; queries slow | Watch distinct values per attribute key; keep ids out of span names |
| Schema change | Exporter insert errors | `ALTER ... ON CLUSTER`, add-only changes; never rename stock columns |

### 4. Replication

| Watch | Where | Alert when |
|---|---|---|
| Read-only replicas | `system.replicas.is_readonly`; `ReadonlyReplica` in `system.metrics` | Any |
| Lag | `absolute_delay`, `queue_size` in `system.replicas`; `ReplicasMaxAbsoluteDelay` | Delay above about 60 s |
| Active replicas | `active_replicas < total_replicas` | Any, for more than a few minutes |
| Failed fetches | `ReplicatedPartFailedFetches` in `system.events`; `system.replication_queue.last_exception` | Rising |
| Distributed DDL | `system.distributed_ddl_queue WHERE status != 'Finished'` | Entries stuck |

Handle: a replica that was down catches up by itself (module 6). A replica
gone for good stays registered in Keeper; remove it with
`SYSTEM DROP REPLICA '<name>' FROM TABLE ...`. If Keeper lost a replica's
metadata, use `SYSTEM RESTORE REPLICA`.

### 5. Keeper

Keeper answers four-letter commands on its client port (9181): `ruok` gives
`imok`, and `mntr` gives the metrics.

| `mntr` field | Meaning | Alert when |
|---|---|---|
| `zk_server_state` | `leader`, `follower`, or `standalone` (single node) | No leader in a multi-node ensemble |
| `zk_followers`, `zk_synced_followers` | Ensemble health, on the leader | Synced followers below the majority |
| `zk_outstanding_requests` | Queued requests | Sustained above 10 |
| `zk_avg_latency`, `zk_max_latency` | Request latency, ms | Rising: slow disk or overload |
| `zk_znode_count`, `zk_approximate_data_size` | Metadata size | Growing without bound (old replicas, DDL queue) |

On the ClickHouse side, `system.zookeeper_connection` shows each node's
session, and `KEEPER_EXCEPTION` in `system.errors` shows trouble.

Handle: run **3 Keepers** (survive 1 failure) on separate hosts with fast
disks; this demo runs 1. Keeper down means replicated tables are read-only:
reads still work, and the gateway queue buys you up to `max_elapsed_time`.

### 6. S3 (with tiering, module 11)

| Watch | Where | Alert when |
|---|---|---|
| S3 errors | `S3ReadRequestsErrors`, `S3WriteRequestsErrors` in `system.events` | Rising |
| Moves keeping up | `BackgroundMovePoolTask`; local disk usage | Local disk fills although data is old enough to move |
| Cache hit ratio | `CachedReadBufferReadFromCacheBytes` vs `ReadBufferFromS3Bytes` | Mostly S3 reads for repeated queries |
| Cost | Requests and bytes in the cloud bill | Merges on S3 parts multiply requests |

Handle: S3 credentials through IAM roles, not files; a bucket lifecycle
rule must not delete objects ClickHouse still references.

## Readiness checklist

Before calling this production-ready:

- **Capacity**
  - Measure spans per second and bytes per span (lab step 4), then size
    disk for retention plus 30% headroom.
  - Size the gateway queue for your longest tolerated ClickHouse outage.
- **Redundancy**
  - 2 or more gateway replicas behind a load balancer.
  - 3 Keepers.
  - 2 or more ClickHouse replicas per shard, on separate hosts or zones.
- **Durability**
  - A persistent gateway queue.
  - ClickHouse backups (`BACKUP ... TO S3(...)`), with a tested restore.
- **Security**
  - TLS on OTLP and the ClickHouse ports.
  - No passwords in config files: this demo's `demo` password is for the
    laptop only.
  - Separate ClickHouse users: the gateway can only insert; readers can
    only read, with quotas.
- **Observability of the pipeline itself**
  - Scrape the gateway (`:8888`) and ClickHouse (`:9363`) into Prometheus.
  - Alert on the "Alert when" column above.
  - Run a synthetic trace every minute and alert if it doesn't arrive.
- **Change safety**
  - Pin image versions, as `compose.yaml` does.
  - Validate the Collector config in CI.
  - Make schema changes add-only and `ON CLUSTER`.
  - Upgrade one replica at a time.
- **Runbooks**
  - Keeper down, replica lost, too many parts, disk full, gateway queue full,
    S3 errors: each module's lab is a rehearsal for one of them.

## Remember it

> **Fresh, complete, keeping up, usable.** Every alert answers one of those.
> And **the books must balance**: accepted = filtered + sent + queued + failed.

## In this repo

- `otel-gateway-config.yaml`: `service.telemetry.metrics` exposes the
  gateway's metrics on 8888, mapped to <http://localhost:18888/metrics>.
- `docs/tutorial/labs/health-check.sh` (also `./stack.sh health`): one screen
  covering the gateway, Keeper and both ClickHouse nodes, with OK, WARN and
  FAIL.

## Lab (20 min)

1. **Run the health check:**

   ```bash
   ./stack.sh health
   ```

   ```text
   Gateway (otel-gateway)
     OK   health check endpoint answers
     OK   export queue 0/1000 batches
     OK   since start: accepted 1106, filtered 29, sent 1075
     OK   refused 0 spans
     OK   lost 0 spans
   Keeper (clickhouse-keeper)
     OK   ruok: imok, state standalone, 2114 znodes
     OK   outstanding requests 0, max latency 62 ms
   ClickHouse (clickhouse-01)
     OK   no read-only tables
     OK   replication lag 0s, queue 0
     OK   max 6 parts in a partition
     ...
   ```

   Check the books: accepted (1106) minus filtered (29) is sent (1075), plus
   whatever is in the queue or in the batch processor at that moment.

2. **Read the gateway's own metrics:**

   ```bash
   curl -s localhost:18888/metrics | grep -E '^otelcol_(receiver_accepted|receiver_refused|processor_filter_spans_filtered|exporter_sent|exporter_send_failed|exporter_queue)'
   ```

3. **Rehearse two incidents, and watch the check catch them.**

   ClickHouse down (both nodes) for 45 seconds:

   ```bash
   docker stop clickhouse-01 clickhouse-02
   sleep 20; curl -s localhost:18888/metrics | grep '^otelcol_exporter_queue_size'
   sleep 25; docker start clickhouse-01 clickhouse-02
   ```

   In a test run, the queue grew to 3 batches during the outage and drained
   to 0 afterwards, with `send_failed` staying at 0: nothing lost.

   Keeper down:

   ```bash
   docker stop clickhouse-keeper; sleep 20; ./stack.sh health
   docker start clickhouse-keeper
   ```

   ```text
   Keeper (clickhouse-keeper)
     FAIL Keeper does not answer ruok: replicated tables will be read-only
   ClickHouse (clickhouse-01)
     FAIL 4 read-only replicated tables (Keeper session lost?)
     WARN errors in the last 10 minutes: CANNOT_READ_ALL_DATA, DNS_ERROR, TABLE_IS_READ_ONLY, KEEPER_EXCEPTION
   ```

4. **Measure capacity from your own data:**

   ```sql
   SELECT table, sum(rows) AS n,
          round(sum(data_compressed_bytes) / n) AS bytes_per_row_on_disk,
          round(sum(data_uncompressed_bytes) / n) AS bytes_per_row_raw
   FROM system.parts WHERE database = 'otel' AND active GROUP BY table;

   SELECT round(count() / dateDiff('second', min(Timestamp), max(Timestamp)), 1) AS spans_per_second
   FROM otel.otel_traces WHERE Timestamp > now() - INTERVAL 10 MINUTE;
   ```

   A test run measured 54 bytes per span on disk (615 raw) at 3.5 spans per
   second. Demo spans are small; real spans with more attributes are often
   several times larger, so measure with your own traffic. Then:
   `disk = spans/s x bytes/span x 86400 x retention days x replicas x 1.3 headroom`.

5. **Find the heaviest queries:**

   ```sql
   SELECT normalizeQuery(query) AS q, count() AS runs,
          round(quantile(0.95)(query_duration_ms)) AS p95_ms,
          formatReadableSize(max(memory_usage)) AS max_memory,
          max(read_rows) AS max_rows_read
   FROM system.query_log
   WHERE type = 'QueryFinish' AND event_time > now() - INTERVAL 1 HOUR AND query_kind = 'Select'
   GROUP BY q ORDER BY p95_ms DESC LIMIT 5;
   ```

## Explain it back

> "Operating the pipeline means answering four questions: is data fresh, is
> it complete, is the system keeping up, and can people query it. Loss can
> happen at the SDK queue, at the gateway's memory limiter, in the gateway's
> export queue when retries run out, and in ClickHouse when it rejects
> inserts or Keeper is down. So we watch the gateway's accepted, refused,
> filtered, sent and failed counters and its queue size; ClickHouse
> freshness, parts per partition, delayed inserts, memory, disk and errors;
> replication read-only state and lag; and Keeper's `ruok` and `mntr`. For
> readiness, we run redundant gateways, three Keepers and two replicas,
> persistent queues and tested backups, TLS and separate users, and every
> failure has a rehearsed runbook."

## Check yourself

<details><summary>Spans per second accepted by the gateway equals spans per second sent. Is anything lost?</summary>

Not at the gateway. But spans can still be lost before it (SDK queues, apps
that exit) and won't appear in any gateway counter. Watch freshness, and run a
synthetic trace end to end.
</details>

<details><summary>Parts per partition climbs steadily into the hundreds. What do you look at first?</summary>

Insert size and rate: many small batches (check the batch size metric and the
number of gateway replicas or senders writing directly), then whether merges
keep up (the background pool is always full, or disk or CPU is saturated).
Fix the batching before raising limits.
</details>

<details><summary>Why is <code>otelcol_exporter_send_failed_spans_total</code> the most important alert?</summary>

It counts spans permanently dropped after every retry. Other signals warn
that loss may come; this one says it happened.
</details>

<details><summary>Keeper is down. What still works, and how long have you got?</summary>

Reads work everywhere; replicated inserts fail. The gateway queues and
retries for up to `max_elapsed_time` (300 s here) as long as the queue has
room. After that, data is lost. That's your time budget, and the reason to
run 3 Keepers.
</details>

## Read more

- [Collector internal telemetry](https://opentelemetry.io/docs/collector/internal-telemetry/)
- [Monitoring the Collector](https://opentelemetry.io/docs/collector/troubleshooting/)
- [Collector scaling](https://opentelemetry.io/docs/collector/scaling/)
- [ClickHouse monitoring](https://clickhouse.com/docs/operations/monitoring)
- [ClickHouse Prometheus endpoint](https://clickhouse.com/docs/operations/server-configuration-parameters/settings#prometheus)
- [`system.replicas`](https://clickhouse.com/docs/operations/system-tables/replicas), [`system.parts`](https://clickhouse.com/docs/operations/system-tables/parts), [`system.query_log`](https://clickhouse.com/docs/operations/system-tables/query_log), [`system.errors`](https://clickhouse.com/docs/operations/system-tables/errors)
- [Keeper four-letter commands](https://clickhouse.com/docs/guides/sre/keeper/clickhouse-keeper#four-letter-word-commands)
- [Too many parts](https://clickhouse.com/docs/knowledgebase/exception-too-many-parts)
- [Backup and restore](https://clickhouse.com/docs/operations/backup)

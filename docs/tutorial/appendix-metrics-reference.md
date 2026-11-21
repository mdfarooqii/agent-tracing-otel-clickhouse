# Appendix: metrics reference, from SDK to Keeper

This page is a reference, not a lesson. [Module 12](12-operations.md) teaches
how to think about the pipeline's health and walks through the ten signals
that matter most. Come here when you need the full list: every metric worth
watching at each hop, what it means, what a bad value looks like, and what to
do. The second half explains every line of `./stack.sh health`.

Each entry uses the same four points:

- **Means**: what the number is.
- **Why it matters**: what goes wrong if you ignore it.
- **Bad value**: a starting threshold. These are demo starting points, not
  production values; tune them to your traffic.
- **What to do**: the first things to check or change.

Two reminders before you start. A **counter** only goes up from when the
program started, so watch its **rate** (how fast it rises), not its total. A
**gauge** goes up and down, so watch its current value and trend. Module 12
explains both.

S3 tiering metrics are in [module 11](11-s3-tiering.md#what-to-watch-once-its-on).

## 1. Application SDKs

The **SDK** is the OpenTelemetry library inside each app
([module 1](01-otel-core.md)). It creates spans, queues them in memory, and
sends them over OTLP (OpenTelemetry Protocol) to the gateway. The SDK doesn't
publish metrics here; you watch its logs and settings.

**Export errors in app logs** (`Failed to export spans batch`)

- Means: the SDK tried to send a batch, retried, and gave up.
- Why it matters: that batch is gone. The gateway never saw it, so no gateway
  counter shows the loss.
- Bad value: any. In the [module 4](04-collector.md) lab, a 45-second gateway
  outage lost every turn in that window.
- What to do: find out why the gateway was unreachable (down, network, wrong
  address). For critical apps, send to a local Collector next to the app.

**`OTEL_BSP_MAX_QUEUE_SIZE` against your traffic**

- Means: how many finished spans the SDK's `BatchSpanProcessor` holds while
  waiting to send. The default is 2048.
- Why it matters: when it's full, new spans are dropped silently.
- Bad value: a busy service that makes more than 2048 spans in the time the
  gateway might be unreachable.
- What to do: raise it (it costs memory), or add a local Collector so the
  queue drains in milliseconds.

**Sampling settings**

- Means: `OTEL_TRACES_SAMPLER` decides which traces each service records
  ([module 5](05-sampling.md)).
- Why it matters: if services decide independently, you get **orphans**:
  spans whose parent was never recorded.
- Bad value: any service using `traceidratio` (not parent-based) downstream of
  another.
- What to do: use a `parentbased_*` sampler everywhere.

**Resource labels present** (`org.owner` and `org.service` on the resource)

- Means: the labels that say who owns the service. The gateway drops spans
  without them.
- Why it matters: a service with missing labels disappears from ClickHouse
  entirely.
- Bad value: a rise in the gateway's filter counter (below), or a service
  with no rows.
- What to do: fix the service's resource setup, as in `agent/run.py`.

**How to handle the SDK hop**: short-lived processes (jobs, command-line
tools, serverless functions) must call `provider.shutdown()` before exiting,
which sends whatever is still queued. `agent/run.py` does this. For anything
critical, send to a local agent Collector instead of a remote gateway, so the
app hands off its spans in milliseconds.

## 2. Gateway (OpenTelemetry Collector)

The **gateway** is the central OpenTelemetry Collector
([module 4](04-collector.md)). It receives spans, drops unlabeled ones, stamps
platform labels, batches them, and writes them to ClickHouse with a queue and
retries.

The Collector reports on itself in **Prometheus format**: a plain-text page
with one `name{labels} value` line per metric. Open
<http://localhost:18888/metrics> to see it. The `service.telemetry` block in
`otel-gateway-config.yaml` turns this on, on port 8888 inside the container,
and `compose.yaml` maps it to 18888 on your machine.

A counter that has never gone up may not appear on the page at all. On a
healthy gateway you won't see `otelcol_exporter_send_failed_spans_total`,
because nothing has failed yet. The health check treats a missing counter as
0. Also note that the `debug` exporter has its own `sent` line; filter on
`exporter="clickhouse"`.

**`otelcol_receiver_accepted_spans_total`** (counter)

- Means: spans the OTLP receiver took in from apps.
- Why it matters: it's the top of the books. If it stops rising, nothing is
  reaching the gateway.
- Bad value: the rate drops to zero while apps are running.
- What to do: check the apps' logs for export errors, the network, and the
  address apps send to.

**`otelcol_receiver_refused_spans_total`** (counter)

- Means: spans the gateway turned away because `memory_limiter` said memory
  was too high. This is back-pressure.
- Why it matters: refused spans aren't lost yet; the app retries. But if the
  app's own queue fills, they will be.
- Bad value: any sustained rate.
- What to do: find out why memory is high (usually a slow ClickHouse filling
  the queue), give the gateway more memory, or add gateway replicas.

**`otelcol_processor_filter_spans_filtered_total`** (counter)

- Means: spans dropped by `filter/require_org_labels`, because their resource
  lacks `org.owner` or `org.service`.
- Why it matters: it's loss by design, but a sudden jump means a service lost
  its labels after a deploy.
- Bad value: a step change. In this repo, a steady trickle is normal: those
  are `legacy-hr-api`'s spans.
- What to do: find the service (it'll have stopped appearing in ClickHouse)
  and fix its resource labels.

**`otelcol_exporter_queue_size` and `otelcol_exporter_queue_capacity`** (gauges)

- Means: batches waiting for ClickHouse now, and the most the queue can hold
  (1000 here, the default, since the config sets no `sending_queue`).
- Why it matters: this is the earliest warning that ClickHouse is slow or
  down. The queue buys you time; when it's full, data is dropped.
- Bad value: above 50% of capacity for minutes, or growing steadily.
- What to do: check ClickHouse (section 3) and Keeper (section 5). If it
  happens often, make the queue bigger or persistent.

**`otelcol_exporter_sent_spans_total`** (counter)

- Means: spans successfully written to ClickHouse.
- Why it matters: it's the bottom of the books; this is what users will see.
- Bad value: its rate falls below accepted minus filtered for more than a
  few seconds.
- What to do: look at the queue size and the failed counters to see where
  the difference went.

**`otelcol_exporter_send_failed_spans_total`** (counter)

- Means: spans **lost** because the exporter gave up on them. That happens
  in two ways. Retryable errors (ClickHouse down, timeouts) are retried until
  `max_elapsed_time` (300 s) runs out. Errors an exporter marks as
  **permanent** (non-retryable) are dropped at once, with no retries.
- Why it matters: this is the one metric that says loss has *happened*, not
  that it might.
- Bad value: any increase.
- What to do: treat it as an incident. Read the gateway log for the error.
  If ClickHouse was down, fix it, then make the outage budget bigger (longer
  `max_elapsed_time`, bigger or persistent queue). If the error is one that
  retrying can't fix, such as a schema mismatch between the exporter and the
  table, fix the schema: every batch will fail until you do.

**`otelcol_exporter_enqueue_failed_spans_total`** (counter)

- Means: spans **lost** because the export queue was full when they arrived.
- Why it matters: the queue was too small for the outage.
- Bad value: any increase.
- What to do: same as above; size the queue for your longest expected outage.

**`otelcol_process_memory_rss_bytes`** (gauge)

- Means: memory the gateway process uses right now. RSS (resident set size)
  is the memory actually held in RAM.
- Why it matters: if it hits a container memory limit, the operating system
  kills the gateway (OOM, out of memory) and the in-memory queue is lost.
- Bad value: close to `memory_limiter.limit_mib` (512 MiB here), or to the
  container limit if you set one.
- What to do: give the gateway more memory, or spread load over more
  gateways. In production, set a container memory limit about 20% above
  `limit_mib`. Note that this repo's `compose.yaml` sets **no** container
  memory limit, so here `memory_limiter` is the only cap, and the OOM killer
  only acts if the whole Docker machine runs out of memory.

**`otelcol_processor_batch_batch_send_size`** (histogram)

- Means: how many spans each batch from the `batch` processor held.
- Why it matters: every batch becomes one ClickHouse insert, and every insert
  makes a part. Tiny batches mean many tiny parts.
- Bad value: mostly tiny batches on a busy system.
- What to do: raise the `batch` processor's `timeout` or `send_batch_size`.
  With many gateways, each sends its own small batches, so fewer, larger
  gateways (or `async_insert` in ClickHouse) also help.

**Health check endpoint `:13133`**

- Means: the `health_check` extension answers HTTP on port 13133 if the
  gateway is running.
- Why it matters: it's how `./stack.sh up`, a load balancer or a container
  platform knows the gateway is alive.
- Bad value: no answer.
- What to do: `docker logs otel-gateway`, then restart it.

Failure modes and how to handle them:

| Failure | What you see | How to handle it |
|---|---|---|
| ClickHouse slow or down | The queue grows; then `send_failed` rises after `max_elapsed_time` (300 s) | Size the queue for your longest expected outage. Add `sending_queue.storage` with a `file_storage` extension, so the queue is kept on disk and survives restarts |
| Gateway restart | The in-memory queue is lost | A persistent queue; run 2 or more gateway replicas behind a load balancer |
| Memory pressure | `refused_spans` rising; the gateway is OOM-killed | Keep `memory_limiter` first in the pipeline; set a container limit about 20% above `limit_mib` (this repo sets none) |
| A service loses its labels | The `filtered` counter jumps | Alert on it per service; make the filter visible to teams |
| Tail sampling at scale | Traces arrive in fragments | A load-balancing tier routing by trace id ([module 5](05-sampling.md)) |
| Bad config on deploy | The gateway won't start | Check the config before deploying: `otelcol-contrib validate --config=...` |

## 3. ClickHouse servers

**ClickHouse** is the database that stores spans as rows
([module 7](07-clickhouse.md)). Each insert becomes a **part**; parts are
merged in the background; data is split by day into **partitions**.

ClickHouse reports on itself through **system tables**, which you query with
SQL on each node:

- `system.metrics`: gauges, right now (memory in use, merges running).
- `system.events`: counters since the server started (inserts delayed, S3
  errors).
- `system.asynchronous_metrics`: values computed every few seconds in the
  background (largest part count in any partition).
- `system.metric_log`: a history of `system.metrics` and `system.events`,
  one row per second, so you can see *when* a counter rose.
- Plus tables such as `system.parts`, `system.disks`, `system.replicas`,
  `system.mutations`, `system.errors` and `system.query_log`.

To feed these into Prometheus, you'd turn on ClickHouse's built-in endpoint
(`<prometheus><port>9363</port>...</prometheus>` in the server config). This
repo doesn't turn it on; the health check queries the tables directly.

**Freshness**: `SELECT dateDiff('second', max(Timestamp), now()) FROM otel.otel_traces WHERE Timestamp > now() - INTERVAL 1 HOUR`

- Means: how many seconds old the newest stored span is. `dateDiff` gives a
  plain number of seconds; subtracting a `DateTime64` from `now()` directly
  doesn't. The `WHERE` limits the read to recent data.
- Why it matters: it's the simplest end-to-end check. If anything along the
  path is broken, this number grows.
- Bad value: more than a few minutes while traffic is running.
- What to do: walk the path backwards: ClickHouse inserts, gateway queue and
  counters, app logs.

**Parts per partition**: `MaxPartCountForPartition` in `system.asynchronous_metrics`

- Means: the largest number of active parts in any single partition.
- Why it matters: too many parts make queries and merges slow. ClickHouse
  protects itself: at **1000** parts in a partition it **delays** inserts
  (`parts_to_delay_insert`), and at **3000** it **rejects** them with
  `Too many parts` (`parts_to_throw_insert`).
- Bad value: above 300 and rising.
- What to do: make inserts bigger and rarer (gateway batching), check merges
  are keeping up (below). Fix batching before raising the limits.

**Delayed and rejected inserts**: `DelayedInserts`, `RejectedInserts` in `system.events`

- Means: how many inserts ClickHouse slowed down or refused because of the
  parts limit, since the server started.
- Why it matters: delayed inserts make the gateway's queue grow; rejected
  ones become retries and maybe loss.
- Bad value: any increase.
- What to do: same as parts per partition.

**Failed inserts**: `FailedInsertQuery` in `system.events`

- Means: inserts that failed for any reason (read-only table, schema
  mismatch, memory).
- Why it matters: the gateway will retry them, but something is wrong.
- Bad value: rising.
- What to do: look at `system.errors` for the error names.

**Memory**: `MemoryTracking` in `system.metrics`, compared with `max_server_memory_usage`

- Means: memory ClickHouse uses now, against the most it allows itself. By
  default that limit is 90% of the RAM the server can see.
- Why it matters: near the limit, queries and inserts fail with
  `MEMORY_LIMIT_EXCEEDED`.
- Bad value: above 80% of the limit.
- What to do: find heavy queries ([module 12](12-operations.md) stretch
  exercise B), set per-user limits. In this repo `compose.yaml` sets no
  container memory limit, so each ClickHouse server sees the whole Docker
  machine's RAM and sets its limit from that, even though both servers and the
  gateway share it. In production, give each server a container limit (or set
  `max_server_memory_usage` yourself) so the percentage means something.

**Disk**: `free_space / total_space` in `system.disks`

- Means: how much of the local disk is free.
- Why it matters: when the disk is full, inserts and merges fail. That's an
  outage.
- Bad value: under 15% free, or close to `move_factor` if you use S3 tiering
  ([module 11](11-s3-tiering.md)).
- What to do: check that TTL is deleting old data, shorten retention, add
  disk, or move old data to S3.

**Merges keeping up**: `BackgroundMergesAndMutationsPoolTask` in `system.metrics`; `system.merges`

- Means: how many background merges and mutations are running now, out of
  the pool's size. `system.merges` lists them.
- Why it matters: if merges can't keep up, parts pile up.
- Bad value: the pool always full while parts keep rising.
- What to do: bigger inserts; check CPU and disk aren't maxed out.

**Stuck mutations**: `system.mutations WHERE NOT is_done`

- Means: background rewrites (such as `MATERIALIZE INDEX` or
  `MATERIALIZE TTL`) still running.
- Why it matters: a stuck mutation keeps using resources and can block
  other changes.
- Bad value: running for more than about 10 minutes.
- What to do: look at `latest_fail_reason` in `system.mutations`; cancel it
  with `KILL MUTATION` if needed.

**Errors**: `system.errors` (name, count, last time)

- Means: every error code the server has hit, with how often and when last.
- Why it matters: new error names are often the first clue.
- Bad value: new names, or counts rising fast.
- What to do: search the error name; it usually points straight at the cause
  (`TABLE_IS_READ_ONLY` means Keeper, for example).

**Slow queries**: `query_duration_ms`, `memory_usage`, `read_rows` in `system.query_log`

- Means: how long each query took, how much memory it used, and how many rows
  it read.
- Why it matters: this is "can people use it?". It also finds queries that
  hurt ingestion.
- Bad value: p95 (the value 95% of queries are faster than) above your SLO.
- What to do: rewrite the heavy queries to filter on the sorting key (owner,
  service, span name, time), add limits per user.

**TTL working**: the oldest `min_time` per table in `system.parts`

- Means: the oldest data still stored. TTL (time to live) should delete spans
  after 72 hours.
- Why it matters: if TTL isn't working, the disk fills up slowly.
- Bad value: data well past the retention period. Some lag is normal: TTL
  deletes run in TTL merges, at most every 4 hours per partition by default
  ([module 11](11-s3-tiering.md#ttl-moves-versus-ttl-deletes)).
- What to do: check the table's `TTL` clause, and that merges are running.

Failure modes and how to handle them:

| Failure | What you see | How to handle it |
|---|---|---|
| Too many small inserts | Parts rising, `DelayedInserts`, then `Too many parts` | Bigger gateway batches; or `async_insert`, where ClickHouse does the batching |
| Disk full | Inserts and merges fail | TTL retention; S3 tiering with `move_factor`; alert at 15% free |
| Memory limit exceeded | Queries fail with `MEMORY_LIMIT_EXCEEDED` | Per-user limits (`max_memory_usage`); queries that use the sorting key |
| Heavy ad hoc queries | Ingestion slows | Separate users and quotas for dashboards and one-off queries; `max_execution_time` |
| Cardinality explosion (too many distinct values, [module 1](01-otel-core.md)) | Map columns and indexes grow; queries slow | Watch distinct values per attribute key; keep ids out of span names |
| Schema change | The exporter's inserts fail | `ALTER ... ON CLUSTER`, add-only changes; never rename stock columns |

## 4. Replication

**Replication** keeps a copy of each table on both ClickHouse servers
([module 7](07-clickhouse.md)). Each copy is a **replica**. A new part on one
replica is logged in Keeper, and the other replica downloads it.

**Read-only replicas**: `is_readonly` in `system.replicas`; `ReadonlyReplica` in `system.metrics`

- Means: a table copy that refuses inserts. Almost always, it has lost its
  connection to Keeper, so it can't record new parts.
- Why it matters: inserts fail; the gateway starts queueing.
- Bad value: any.
- What to do: check Keeper (section 5). Once Keeper is back, the replica
  recovers by itself.

**Lag**: `absolute_delay` and `queue_size` in `system.replicas`; `ReplicasMaxAbsoluteDelay`

- Means: how many seconds this replica is behind, and how many replication
  tasks (parts to fetch, merges to do) it still has queued.
- Why it matters: queries to a lagging replica return stale data.
- Bad value: delay above about 60 s.
- What to do: check the network between replicas, the disk and the
  replication queue's errors.

**Active replicas**: `active_replicas < total_replicas` in `system.replicas`

- Means: fewer replicas are online than are registered.
- Why it matters: you've lost your redundancy; one more failure stops writes.
- Bad value: any, for more than a few minutes.
- What to do: start the missing replica. It catches up on its own.

**Failed fetches**: `ReplicatedPartFailedFetches` in `system.events`; `last_exception` in `system.replication_queue`

- Means: a replica tried to download a part from its peer and failed.
- Why it matters: it can't catch up.
- Bad value: rising.
- What to do: read `last_exception`; usually network or disk.

**Distributed DDL**: `system.distributed_ddl_queue WHERE status != 'Finished'`

- Means: `ON CLUSTER` schema changes (DDL, data definition language: `CREATE`,
  `ALTER`, `DROP`) that haven't finished on every node.
- Why it matters: nodes with different schemas cause insert errors.
- Bad value: entries stuck.
- What to do: find the node that didn't finish and why.

How to handle replica problems: a replica that was down catches up by itself
([module 7](07-clickhouse.md)). A replica that's gone for good stays
registered in Keeper; remove it with
`SYSTEM DROP REPLICA '<name>' FROM TABLE ...`. If Keeper lost a replica's
metadata, rebuild it with `SYSTEM RESTORE REPLICA`. Adding a replica is in
[module 10](10-copying-data.md).

## 5. Keeper

**ClickHouse Keeper** is the coordination service that holds replication
metadata: which parts exist, the replication log, and the queue of
`ON CLUSTER` commands ([module 7](07-clickhouse.md)). It holds no span data.

Keeper answers **four-letter commands** on its client port, 9181: send `ruok`
("are you OK?") and it replies `imok`; send `mntr` ("monitor") and it replies
with metrics, one `name value` per line.

**`zk_server_state`**

- Means: Keeper's role: `leader`, `follower`, or `standalone` (a single node,
  as in this repo).
- Why it matters: a group of Keepers (an *ensemble*) needs one leader to accept
  writes.
- Bad value: no leader in a multi-node ensemble.
- What to do: check that a majority of Keeper nodes are up and can reach each
  other.

**`zk_followers`, `zk_synced_followers`** (reported by the leader)

- Means: how many other Keepers are connected, and how many are up to date.
- Why it matters: Keeper needs a **majority** (quorum) to work: 2 of 3, or 3
  of 5.
- Bad value: synced followers below what a majority needs.
- What to do: bring the missing Keepers back before another one fails.

**`zk_outstanding_requests`**

- Means: requests waiting to be handled, a queue.
- Why it matters: a growing number means Keeper can't keep up, and every
  insert waits on it.
- Bad value: above 10 for a sustained period.
- What to do: check Keeper's disk speed and CPU.

**`zk_avg_latency`, `zk_max_latency`**

- Means: how long Keeper takes to answer, in milliseconds. `zk_max_latency`
  is the slowest answer since Keeper started.
- Why it matters: slow Keeper means slow inserts.
- Bad value: rising over time.
- What to do: put Keeper on fast disks, away from busy ClickHouse servers.

**`zk_znode_count`, `zk_approximate_data_size`**

- Means: how many metadata entries (znodes) Keeper holds, and how big they
  are.
- Why it matters: metadata should stay roughly flat. Steady growth means
  something isn't being cleaned up.
- Bad value: growing without limit (old replicas never dropped, a stuck DDL
  queue).
- What to do: drop dead replicas, clear stuck DDL entries.

On the ClickHouse side, `system.zookeeper_connection` shows each node's
connection to Keeper, and `KEEPER_EXCEPTION` in `system.errors` shows trouble.

How to handle it: in production, run **3 Keepers** (so one can fail) on
separate hosts with fast disks. This demo runs 1, so Keeper is a single point
of failure for writes. When Keeper is down, replicated tables are read-only:
reads still work, and the gateway queue buys you up to `max_elapsed_time`
(300 s).

## The health check, line by line

`./stack.sh health` runs `docs/tutorial/labs/health-check.sh`. Each line is
one check, marked **OK**, **WARN** ("look at this soon") or **FAIL**
("something is broken now"). If any line is WARN or FAIL, the script exits
with a non-zero code, so a scheduler could run it and raise an alert.

The **Kind** column says what the number covers. **Now** is a live value.
**Since start** is a counter total since the gateway or server last started:
one old blip keeps the line at WARN or FAIL until a restart, so check whether
it's still rising ([module 12](12-operations.md#totals-versus-rates)).
**Window** covers a fixed recent period.

### Gateway section

| Line | Kind | What it checks | When it isn't OK | What to do |
|---|---|---|---|---|
| `health check endpoint answers` | Now | `curl localhost:13133`: is the gateway process up? | FAIL `health check endpoint down` | `docker logs otel-gateway`; `docker start otel-gateway` |
| `export queue 0/1000 batches` | Now | `otelcol_exporter_queue_size` out of `otelcol_exporter_queue_capacity`, for the `clickhouse` exporter | WARN when more than half full: ClickHouse is slow or not accepting writes | Read the ClickHouse and Keeper sections of the output |
| `since start: accepted ..., filtered ..., sent ...` | Since start | The three main counters. Always OK: it's information for you to balance the books | n/a | accepted minus filtered should be close to sent |
| `refused 0 spans` | Since start | `otelcol_receiver_refused_spans_total`: spans turned away by `memory_limiter` | WARN with a count: apps had to retry, and may have dropped spans | Look at gateway memory and the queue; check whether the count is still rising |
| `lost 0 spans` | Since start | `send_failed` plus `enqueue_failed` | FAIL `lost N spans after retries, M with the queue full` | An incident: data is gone. Read the gateway log, fix the cause, then size the queue and retry window |
| (only if broken) `metrics endpoint :18888 not reachable` | Now | Could the script read the metrics page at all? | FAIL | The gateway is down, or the port mapping is wrong |

### Keeper section

The script runs a tiny shell command inside `clickhouse-01` that opens a TCP
connection to `clickhouse-keeper:9181`, sends a four-letter command and prints
the answer.

| Line | Kind | What it checks | When it isn't OK | What to do |
|---|---|---|---|---|
| `ruok: imok, state standalone, N znodes` | Now | Keeper answered `imok` to `ruok`. Then from `mntr`: its role and how many znodes it holds | FAIL `Keeper does not answer ruok: replicated tables will be read-only` | `docker start clickhouse-keeper`. The gateway's queue covers you for up to 300 s |
| `outstanding requests 0, max latency N ms` | Now (latency: since start) | `zk_outstanding_requests` and `zk_max_latency` | WARN `N outstanding requests` when more than 10 | Keeper is overloaded or its disk is slow |

### ClickHouse section

Once per node, `clickhouse-01` then `clickhouse-02`. First the script runs
`SELECT 1`. If that fails, it prints FAIL `not answering` and skips the rest
of that node's checks.

| Line | Kind | What it checks | When it isn't OK | What to do |
|---|---|---|---|---|
| `no read-only tables` | Now | Sum of `is_readonly` in `system.replicas` for the `otel` tables | FAIL `N read-only replicated tables (Keeper session lost?)` | Check Keeper. Reads still work |
| `replication lag 0s, queue 0` | Now | The largest `absolute_delay` and `queue_size` | WARN when lag is over 60 s or the queue over 100 | Check the other replica is up, and the network between them |
| `max N parts in a partition` | Now | The largest number of active parts in any one partition, across all tables | WARN over 300 (inserts slow down at 1000, fail at 3000) | Bigger, rarer inserts; check merges |
| `local disk N% free` | Now | `free_space / total_space` of the `default` disk | WARN under 15% free | Check TTL deletes, add disk, or tier to S3 |
| `memory N% of the server limit` | Now | `MemoryTracking` as a share of `max_server_memory_usage` | WARN over 80% | Find heavy queries. Without a container limit, the limit comes from the whole Docker machine's RAM |
| `newest span Ns old` | Now | Seconds since the newest span from the last hour: freshness | WARN over 120 s, or no spans in the last hour | If traffic is off (`./stack.sh traffic off`), this is expected. Otherwise, walk back: gateway queue, gateway counters, app logs |
| `no delayed or rejected inserts` | Since start | `DelayedInserts` plus `RejectedInserts` in `system.events` | WARN with a count | Too many parts; check whether it's still rising |
| `no stuck mutations` | Now | Mutations not done after 10 minutes | WARN with a count | Look at `system.mutations`; `KILL MUTATION` if needed |
| (only with module 11) `S3: N parts in cold storage, no request errors` | Since start | Appears only if an `s3` disk exists. Counts parts on S3 and S3 request errors | WARN `N S3 request errors since start` | Check whether the count is still rising; if so, check S3 credentials and endpoint |
| (only if any) `errors in the last 10 minutes: ...` | Window (10 min) | Error names from `system.errors` seen in the last 10 minutes. `UNKNOWN_TABLE` and `SYNTAX_ERROR` are left out, since they usually come from people typing queries | WARN with the names | Each name is a clue: `TABLE_IS_READ_ONLY` and `KEEPER_EXCEPTION` point at Keeper, for example |

## Read more

- [Collector internal telemetry](https://opentelemetry.io/docs/collector/internal-telemetry/)
- [Monitoring the Collector](https://opentelemetry.io/docs/collector/troubleshooting/)
- [ClickHouse monitoring](https://clickhouse.com/docs/operations/monitoring)
- [`system.replicas`](https://clickhouse.com/docs/operations/system-tables/replicas), [`system.parts`](https://clickhouse.com/docs/operations/system-tables/parts), [`system.metric_log`](https://clickhouse.com/docs/operations/system-tables/metric_log), [`system.errors`](https://clickhouse.com/docs/operations/system-tables/errors)
- [Keeper four-letter commands](https://clickhouse.com/docs/guides/sre/keeper/clickhouse-keeper#four-letter-word-commands)
- [Too many parts](https://clickhouse.com/docs/knowledgebase/exception-too-many-parts)

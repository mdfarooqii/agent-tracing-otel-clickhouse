# Module 12: Operational readiness, from gateway to ClickHouse (60 min)

## Why this matters

The tracing pipeline you built is a production system in its own right. If it
quietly loses spans, nobody notices until someone opens a trace during an
incident and half of it is missing. This module teaches you what to watch at
each hop, from the app's SDK to the gateway to ClickHouse and Keeper, what a bad
number looks like, and what to do about it.

By the end, you'll be able to read the repo's one-screen health check line by
line, rehearse two outages and watch the check catch them, size disks from
your own data, and work through a production readiness checklist.

## Key terms

| Term | Plain meaning |
|---|---|
| **Operational readiness** | Being able to run a system day to day: you know when it's unhealthy, why, and what to do, before users tell you |
| **Monitoring** | Collecting numbers about a running system and looking at them over time |
| **Metric** | A number a program reports about itself, with a name, such as "spans sent so far" or "memory in use now" |
| **Counter** | A metric that only goes up, like a car's odometer. You care about how fast it rises (its *rate*) |
| **Gauge** | A metric that goes up and down, like a fuel gauge: queue size, memory, free disk |
| **Histogram** | A metric that counts values in buckets, so you can ask "how big were most batches?" |
| **Rate** | How much a counter grew per second over a time window |
| **Threshold** | The value at which a metric counts as bad, such as "queue more than half full" |
| **Alert** | An automatic message to a person when a metric crosses a threshold for long enough |
| **SLI** (service level indicator) | A measurement of what users experience, such as "age of the newest span" |
| **SLO** (service level objective) | A target for an SLI, such as "the newest span is under 2 minutes old 99.9% of the time" |
| **p95** (95th percentile) | The value 95% of measurements are below. "p95 query time 800 ms" means 1 in 20 queries is slower |
| **Prometheus** | A popular monitoring system. It *scrapes* (fetches) metrics from an HTTP page every few seconds and stores them |
| **Endpoint** | An address (host and port, sometimes a path) that a program answers on |
| **Queue** | A waiting line for work. A queue that keeps growing means the next step can't keep up |
| **Back-pressure** | A busy component telling the sender "not now, try later" instead of crashing |
| **Lag** | How far behind something is: here, how many seconds a replica is behind its peer |
| **Read-only replica** | A ClickHouse table copy that can still answer queries but refuses inserts, usually because it lost contact with Keeper |
| **Part** | One chunk of a ClickHouse table on disk. Every insert creates a new part (module 6) |
| **Parts limit** | ClickHouse slows inserts when one partition has 1000 parts, and rejects them at 3000 |
| **Merge** | ClickHouse combining small parts into bigger ones in the background |
| **Mutation** | A background job that rewrites existing parts, for example `ALTER ... MATERIALIZE INDEX` |
| **Znode** | One entry in Keeper's tree of metadata, like a file in a folder tree |
| **OOM** (out of memory) | A process using more memory than allowed; the operating system kills it |
| **Runbook** | A written, step-by-step "what to do when X happens" for the person on call |
| **Synthetic trace** | A fake request you send on a schedule, just to check it arrives end to end |

## Idea

### What "operational readiness" means

Think of a car. Driving it is one skill. Knowing that the oil light means
"stop soon", that a rising temperature gauge means "pull over", and having a
spare tyre and the steps to change it is another. That second skill is
operational readiness.

For this pipeline, it means three things:

1. **You can see its health.** Every component reports metrics, and you know
   which ones matter.
2. **You hear about trouble early.** Alerts fire before data is lost, not
   after.
3. **You know what to do.** Each likely failure has a runbook, and you've
   practised it (the labs in modules 4, 6, 10 and 11 are those practice runs).

Without it, the most common failure of a tracing system is silent: spans
stop arriving, or arrive incomplete, and nobody finds out until they need
them.

### Metrics, alerts and SLOs in plain words

A **metric** is a named number. Programs in this stack publish two kinds:

- **Counters** only go up, from the moment the program starts:
  `otelcol_exporter_sent_spans_total` is "spans written to ClickHouse since
  the gateway started". A counter's absolute value tells you little. Its
  **rate**, how fast it rises, tells you a lot. If the sent counter stops
  rising, nothing is being written.
- **Gauges** go up and down: `otelcol_exporter_queue_size` is "batches waiting
  right now". You care about their current value and trend.

Counters reset to zero when the program restarts. That's normal, and
monitoring tools like Prometheus handle it.

An **alert** is a rule over a metric: "if the gateway's queue is more than
half full for 5 minutes, message the on-call person." Good alerts have two
properties. They fire **before** users are hurt, and they **mean something**,
so people don't learn to ignore them.

An **SLO** is a promise you make about the pipeline, measured by an **SLI**.
For a tracing pipeline, two useful ones are:

| SLI (what you measure) | Example SLO (the target) |
|---|---|
| Age of the newest span in ClickHouse | Under 2 minutes, 99.9% of the time over 30 days |
| p95 time of trace lookup queries | Under 1 second |

These targets are examples, not values from this repo. Pick yours from what
your users need. The point is that an SLO turns "is it OK?" into a yes or no
question.

### Four questions every metric answers

A tracing pipeline must answer four questions at all times. Every metric in
this module serves one of them:

| Question | Plain words | Signal | How to measure it here |
|---|---|---|---|
| **Is data arriving?** (freshness) | Are new spans showing up? | Age of the newest span in ClickHouse | `now() - max(Timestamp)` |
| **Is data complete?** (loss) | Are spans going missing on the way? | Spans refused, dropped or failed at each hop | Gateway counters; SDK export errors |
| **Is it keeping up?** (saturation) | Is any component running out of room or falling behind? | Queues, parts, replication lag, memory, disk | Gateway queue; `system.replicas`, `system.parts`, `system.disks` |
| **Can people use it?** (query health) | Do queries come back quickly and without errors? | Query latency and errors | `system.query_log` |

**Saturation** means "how full a resource is". A queue at 90% of its
capacity, or a disk with 5% free, is saturated: one more push and something
fails.

### Where one request's spans can be lost

Follow one real request. A user asks the HR agent "I need a new laptop."
The agent opens a root span, `agent_turn`, calls a fake LLM, and calls two
tools, which make HTTP calls to `legacy-hr-api` and `ticket-api`. Each
process records its spans with the SDK. Then the spans travel:

```text
 app SDK ──▶ gateway receiver ──▶ processors ──▶ export queue ──▶ ClickHouse ──▶ Keeper
    │              │                    │               │               │            │
 queue full,   memory limiter      filter drops     queue full,     too many     down: tables
 process exits refuses data        (by design)      retries         parts,       go read-only
 (lost)        (app must retry)                     exhausted       disk full,
                                                    (lost)          read-only
```

Read it left to right:

1. **App SDK.** The SDK holds finished spans in an in-memory queue (2048 spans
   by default) and sends them in batches. If the gateway can't be reached for
   long, the queue fills and new spans are dropped. If the process exits
   before it sends, those spans are gone.
2. **Gateway receiver and `memory_limiter`.** If the gateway is nearly out of
   memory, it refuses new data. That's **back-pressure**: the gateway tells
   the app "try later" instead of crashing. The app retries, but its own queue
   may fill.
3. **Processors.** The `filter/require_org_labels` processor drops spans
   whose resource lacks `org.owner` or `org.service`. That's loss **by
   design**, but you still want to see it: a sudden jump means some service
   lost its labels. In this request, the `legacy-hr-api` server span is
   dropped here (module 4).
4. **Export queue.** Batches wait here for ClickHouse. If ClickHouse is down,
   the queue fills, and batches that can't be written within 300 s
   (`max_elapsed_time`) are dropped.
5. **ClickHouse.** It can reject inserts (too many parts, disk full, out of
   memory) or refuse writes because a table is read-only.
6. **Keeper.** If ClickHouse loses contact with Keeper, replicated tables go
   **read-only**: reads work, inserts fail, and the gateway has to queue and
   retry.

Each hop needs its own metric, because each fails in its own way.

### Queues, back-pressure and lag

These three ideas explain most incidents, so here they are with an everyday
picture.

- A **queue** is the line at a coffee shop. A short line that comes and goes
  is healthy. A line that keeps getting longer means the barista can't keep
  up. In this stack the gateway's export queue holds batches waiting for
  ClickHouse. It's sized at 1000 batches (the default, since the config sets
  no `sending_queue`).
- **Back-pressure** is the shop putting up a sign: "full, come back in five
  minutes". It's better than letting people pile up until the shop collapses.
  The gateway's `memory_limiter` does this by refusing data when memory is
  high.
- **Lag** is how far behind a copy is. The second ClickHouse replica copies
  every new part from the first. If it's 90 seconds behind, a query sent to
  it won't see the last 90 seconds of spans.

### The books must balance

The gateway keeps counters for every way a span can leave it. Like a bank
statement, they must add up:

**accepted = filtered + sent + still in queue or batch + failed**

- **accepted**: spans the receiver took in.
- **filtered**: spans the label filter dropped on purpose.
- **sent**: spans written to ClickHouse.
- **still in queue or batch**: spans waiting in the `batch` processor (up to
  5 s) or the export queue right now.
- **failed**: spans lost after retries, or because the queue was full.

If the numbers don't add up over time, something is losing data in a way no
counter shows.

## Per component: what to watch, what fails, what to do

For each component: a reminder of what it is, then each metric with what it
means, why it matters, what bad looks like, and what you'd do.

### 1. Application SDKs

The **SDK** is the OpenTelemetry library inside each app (module 1). It
creates spans, queues them in memory, and sends them over OTLP (OpenTelemetry
Protocol) to the gateway. The SDK doesn't publish metrics here; you watch its
logs and settings.

**Export errors in app logs** (`Failed to export spans batch`)

- Means: the SDK tried to send a batch, retried, and gave up.
- Why it matters: that batch is gone. The gateway never saw it, so no gateway
  counter shows the loss.
- Bad value: any. In the module 4 lab, a 45-second gateway outage lost every
  turn in that window.
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
  (module 5).
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

### 2. Gateway (OpenTelemetry Collector)

The **gateway** is the central OpenTelemetry Collector (module 4). It
receives spans, drops unlabelled ones, stamps platform labels, batches them,
and writes them to ClickHouse with a queue and retries.

The Collector reports on itself in **Prometheus format**: a plain-text page
with one `name{labels} value` line per metric. Open
<http://localhost:18888/metrics> to see it. The `service.telemetry` block in
`otel-gateway-config.yaml` turns this on, on port 8888 inside the container,
and `compose.yaml` maps it to 18888 on your machine.

One thing to know before you read it: a counter that has never gone up may
not appear on the page at all. On a healthy gateway you won't see
`otelcol_exporter_send_failed_spans_total`, because nothing has failed yet.
The health check treats a missing counter as 0.

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
  (1000 here).
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

- Means: spans **lost** because every retry failed for 300 s
  (`max_elapsed_time`).
- Why it matters: this is the one metric that says loss has *happened*, not
  that it might.
- Bad value: any increase.
- What to do: treat it as an incident. Fix ClickHouse, then make the outage
  budget bigger (longer `max_elapsed_time`, bigger or persistent queue).

**`otelcol_exporter_enqueue_failed_spans_total`** (counter)

- Means: spans **lost** because the export queue was full when they arrived.
- Why it matters: the queue was too small for the outage.
- Bad value: any increase.
- What to do: same as above; size the queue for your longest expected outage.

**`otelcol_process_memory_rss_bytes`** (gauge)

- Means: memory the gateway process uses right now. RSS (resident set size)
  is the memory actually held in RAM.
- Why it matters: if it hits the container's limit, the operating system kills
  the gateway (OOM) and the in-memory queue is lost.
- Bad value: close to the container limit, or to `memory_limiter.limit_mib`
  (512 MiB here).
- What to do: give the gateway more memory, keep the container limit about 20%
  above `limit_mib`, or spread load over more gateways.

**`otelcol_processor_batch_batch_send_size`** (histogram)

- Means: how many spans each batch from the `batch` processor held.
- Why it matters: every batch becomes one ClickHouse insert, and every insert
  makes a part. Tiny batches mean many tiny parts.
- Bad value: mostly tiny batches on a busy system.
- What to do: fewer senders writing straight to ClickHouse, or a larger
  `timeout` in the `batch` processor.

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
| Gateway restart | The in-memory queue is lost | A persistent queue; run 2 or more gateway replicas behind a load balancer (a component that spreads incoming connections across them) |
| Memory pressure | `refused_spans` rising; the gateway is OOM-killed | Keep `memory_limiter` first in the pipeline; set the container limit about 20% above `limit_mib` |
| A service loses its labels | The `filtered` counter jumps | Alert on it per service; make the filter visible to teams |
| Tail sampling at scale | Traces arrive in fragments | A load-balancing tier routing by trace id (module 5) |
| Bad config on deploy | The gateway won't start | Check the config before deploying: `otelcol-contrib validate --config=...` |

### 3. ClickHouse servers

**ClickHouse** is the database that stores spans as rows (module 6). Each
insert becomes a **part**; parts are merged in the background; data is
split by day into **partitions**.

ClickHouse reports on itself through **system tables**, which you query with
SQL on each node:

- `system.metrics`: gauges, right now (memory in use, merges running).
- `system.events`: counters since the server started (inserts delayed, S3
  errors).
- `system.asynchronous_metrics`: values computed every few seconds in the
  background (largest part count in any partition).
- Plus tables such as `system.parts`, `system.disks`, `system.replicas`,
  `system.mutations`, `system.errors` and `system.query_log`.

To feed these into Prometheus, you'd turn on ClickHouse's built-in endpoint
(`<prometheus><port>9363</port>...</prometheus>` in the server config). This
repo doesn't turn it on; the health check queries the tables directly.

**Freshness**: `SELECT now() - max(Timestamp) FROM otel.otel_traces`

- Means: how old the newest stored span is.
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
- Bad value: any.
- What to do: same as parts per partition.

**Failed inserts**: `FailedInsertQuery` in `system.events`

- Means: inserts that failed for any reason (read-only table, schema
  mismatch, memory).
- Why it matters: the gateway will retry them, but something is wrong.
- Bad value: rising.
- What to do: look at `system.errors` for the error names.

**Memory**: `MemoryTracking` in `system.metrics`, compared with `max_server_memory_usage`

- Means: memory ClickHouse uses now, against the most it allows itself.
- Why it matters: near the limit, queries and inserts fail with
  `MEMORY_LIMIT_EXCEEDED`.
- Bad value: above 80% of the limit.
- What to do: find heavy queries (lab step 5), set per-user limits.

**Disk**: `free_space / total_space` in `system.disks`

- Means: how much of the local disk is free.
- Why it matters: when the disk is full, inserts and merges fail. That's an
  outage.
- Bad value: under 15% free, or close to `move_factor` if you use S3 tiering
  (module 11).
- What to do: check that TTL is deleting old data, shorten retention, add
  disk, or move old data to S3.

**Merges keeping up**: `BackgroundMergesAndMutationsPoolTask` in `system.metrics`; `system.merges`

- Means: how many background merges and mutations are running now, out of
  the pool's size. `system.merges` lists them.
- Why it matters: if merges can't keep up, parts pile up.
- Bad value: the pool always full while parts keep rising.
- What to do: bigger inserts; check CPU and disk aren't maxed out.

**Stuck mutations**: `system.mutations WHERE NOT is_done`

- Means: background rewrites (such as `MATERIALIZE INDEX`) still running.
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
- Bad value: p95 above your SLO.
- What to do: rewrite the heavy queries to filter on the sorting key (owner,
  service, span name, time), add limits per user.

**TTL working**: the oldest `min_time` per table in `system.parts`

- Means: the oldest data still stored. TTL (time to live) should delete spans
  after 72 hours.
- Why it matters: if TTL isn't working, the disk fills up slowly.
- Bad value: data older than the retention period.
- What to do: check the table's `TTL` clause, and that merges are running.

Failure modes and how to handle them:

| Failure | What you see | How to handle it |
|---|---|---|
| Too many small inserts | Parts rising, `DelayedInserts`, then `Too many parts` | Bigger gateway batches; or `async_insert`, where ClickHouse does the batching |
| Disk full | Inserts and merges fail | TTL retention; S3 tiering with `move_factor`; alert at 15% free |
| Memory limit exceeded | Queries fail with `MEMORY_LIMIT_EXCEEDED` | Per-user limits (`max_memory_usage`); queries that use the sorting key |
| Heavy ad hoc queries | Ingestion slows | Separate users and quotas for dashboards and one-off queries; `max_execution_time` |
| Cardinality explosion (too many distinct values, module 1) | Map columns and indexes grow; queries slow | Watch distinct values per attribute key; keep ids out of span names |
| Schema change | The exporter's inserts fail | `ALTER ... ON CLUSTER`, add-only changes; never rename stock columns |

### 4. Replication

**Replication** keeps a copy of each table on both ClickHouse servers
(module 6). Each copy is a **replica**. A new part on one replica is logged in
Keeper, and the other replica downloads it.

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
(module 6). A replica that's gone for good stays registered in Keeper; remove
it with `SYSTEM DROP REPLICA '<name>' FROM TABLE ...`. If Keeper lost a
replica's metadata, rebuild it with `SYSTEM RESTORE REPLICA`.

### 5. Keeper

**ClickHouse Keeper** is the coordination service that holds replication
metadata: which parts exist, the replication log, and the queue of
`ON CLUSTER` commands (module 6). It holds no span data.

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

- Means: how long Keeper takes to answer, in milliseconds.
- Why it matters: slow Keeper means slow inserts.
- Bad value: rising over time.
- What to do: put Keeper on fast disks, away from busy ClickHouse servers.

**`zk_znode_count`, `zk_approximate_data_size`**

- Means: how many metadata entries Keeper holds, and how big they are.
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

### 6. S3 (only with tiering, module 11)

With module 11's setup, older parts move from local disk to **S3**, cheap
object storage, with a local cache in front for repeated reads.

**S3 errors**: `S3ReadRequestsErrors`, `S3WriteRequestsErrors` in `system.events`

- Means: requests to S3 that failed, since the server started.
- Why it matters: failed writes mean parts can't move; failed reads mean
  queries on old data fail.
- Bad value: rising. A small count that stays the same is less urgent than
  one that keeps growing.
- What to do: check credentials, the endpoint and the bucket.

**Moves keeping up**: `BackgroundMovePoolTask`; local disk usage

- Means: background jobs moving parts to S3, and how full the local disk is.
- Why it matters: if moves stall, the local disk fills.
- Bad value: the local disk fills although data is old enough to move.
- What to do: check S3 errors and the table's `TTL ... TO VOLUME` rule.

**Cache hit ratio**: `CachedReadBufferReadFromCacheBytes` against `ReadBufferFromS3Bytes`

- Means: how many bytes came from the local cache, against straight from S3.
- Why it matters: S3 reads are slower and cost money per request.
- Bad value: mostly S3 reads for queries that repeat.
- What to do: make the cache bigger.

**Cost**: requests and bytes in the cloud bill

- Means: what S3 costs you.
- Why it matters: merges of parts already on S3 read and write S3 again.
- Bad value: request costs rising faster than data.
- What to do: move only older, settled partitions; avoid small parts on S3.

How to handle it: give ClickHouse S3 access through an IAM role (a cloud
identity attached to the machine), not keys in files. And make sure no bucket
lifecycle rule (the bucket's own auto-delete) removes objects ClickHouse
still uses.

## Readiness checklist

Before calling this production-ready, work through these:

- **Capacity** (enough room for the traffic)
  - Measure spans per second and bytes per span (lab step 4), then size disk
    for your retention plus 30% headroom.
  - Size the gateway queue for the longest ClickHouse outage you're willing
    to survive.
- **Redundancy** (no single failure stops the pipeline)
  - 2 or more gateway replicas behind a load balancer.
  - 3 Keepers.
  - 2 or more ClickHouse replicas per shard, on separate hosts or zones.
- **Durability** (data survives restarts and mistakes)
  - A persistent gateway queue.
  - ClickHouse backups (`BACKUP ... TO S3(...)`), with a restore you've
    actually tested.
- **Security**
  - TLS (encrypted connections) on OTLP and the ClickHouse ports.
  - No passwords in config files: this demo's `demo` password is for a laptop
    only.
  - Separate ClickHouse users: the gateway can only insert; readers can only
    read, with quotas (limits on how much each user may run).
- **Observability of the pipeline itself**
  - Scrape the gateway (`:8888`) and ClickHouse (`:9363`) into Prometheus.
  - Alert on the "Bad value" items above.
  - Send a synthetic trace every minute, and alert if it doesn't arrive.
- **Change safety**
  - Pin image versions, as `compose.yaml` does.
  - Check the Collector config in CI (your automated build and test system).
  - Make schema changes add-only and `ON CLUSTER`.
  - Upgrade one replica at a time.
- **Runbooks**
  - Keeper down, replica lost, too many parts, disk full, gateway queue full,
    S3 errors. Each module's lab is a rehearsal for one of them.

## Remember it

> **Fresh, complete, keeping up, usable.** Every alert answers one of those.
> And **the books must balance**: accepted = filtered + sent + queued + failed.

And the coffee shop: **the queue is the line, back-pressure is the "come back
later" sign, and lag is how far the second barista is behind on orders.**

## In this repo

- `otel-gateway-config.yaml`: `service.telemetry.metrics` publishes the
  gateway's own metrics on port 8888, which `compose.yaml` maps to
  <http://localhost:18888/metrics>. `health_check` answers on 13133.
- `docs/tutorial/labs/health-check.sh` (also `./stack.sh health`): one screen
  covering the gateway, Keeper and both ClickHouse nodes, marking each check
  OK, WARN or FAIL. It reads the gateway's metrics page with `curl`, talks to
  Keeper on port 9181, and runs SQL on each ClickHouse node with
  `docker exec ... clickhouse-client`. Its thresholds are starting points for
  this demo, not production values.

## Lab (25 min)

1. **Run the health check:**

   ```bash
   ./stack.sh health
   ```

   You'll see something like this:

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

   Each line is one check. **OK** means fine, **WARN** means "look at this
   soon", **FAIL** means "something is broken now". If any line is WARN or
   FAIL, the script exits with a non-zero code, so a scheduler could run it
   and raise an alert.

   Here is every line, what it checks, and what to do when it isn't OK.

   **Gateway section**

   | Line | What it checks | When it isn't OK | What to do |
   |---|---|---|---|
   | `health check endpoint answers` | `curl localhost:13133`: is the gateway process up? | FAIL `health check endpoint down` | `docker logs otel-gateway`; `docker start otel-gateway` |
   | `export queue 0/1000 batches` | `otelcol_exporter_queue_size` out of `otelcol_exporter_queue_capacity`, for the `clickhouse` exporter: batches waiting to be written | WARN when more than half full: ClickHouse is slow or not accepting writes | Read the ClickHouse and Keeper sections of the output |
   | `since start: accepted 1106, filtered 29, sent 1075` | The three main counters, since the gateway started. Always OK: it's information for you to balance the books | n/a | See the arithmetic below |
   | `refused 0 spans` | `otelcol_receiver_refused_spans_total`: spans turned away by `memory_limiter` | WARN with a count: apps had to retry, and may have dropped spans | Look at gateway memory and the queue. It counts since start, so it stays WARN until the gateway restarts |
   | `lost 0 spans` | `send_failed` plus `enqueue_failed`: spans dropped after retries ran out, or with the queue full | FAIL `lost N spans after retries, M with the queue full` | An incident: data is gone. Fix the cause, then size the queue and retry window |
   | (only if broken) `metrics endpoint :18888 not reachable` | Could the script read the metrics page at all? | FAIL | The gateway is down, or the port mapping is wrong |

   Check the books with the example numbers: accepted 1106 minus filtered 29
   is 1077. Sent is 1075. The 2 missing spans were waiting in the `batch`
   processor (it holds spans for up to 5 s) or the queue at that moment.
   Run the check again a few seconds later and the gap moves, but it doesn't
   keep growing. A gap that keeps growing, with "lost 0", means spans are
   stuck somewhere.

   **Keeper section**

   The script runs a tiny shell command inside `clickhouse-01` that opens a
   TCP connection to `clickhouse-keeper:9181`, sends a four-letter command and
   prints the answer.

   | Line | What it checks | When it isn't OK | What to do |
   |---|---|---|---|
   | `ruok: imok, state standalone, 2114 znodes` | Keeper answered `imok` to `ruok`. Then from `mntr`: its role (`standalone`, because there's only one Keeper here) and how many metadata entries (znodes) it holds | FAIL `Keeper does not answer ruok: replicated tables will be read-only` | `docker start clickhouse-keeper`. The gateway's queue covers you for up to 300 s |
   | `outstanding requests 0, max latency 62 ms` | `zk_outstanding_requests` (requests waiting) and `zk_max_latency` (the slowest answer since Keeper started, in milliseconds) | WARN `N outstanding requests` when more than 10 | Keeper is overloaded or its disk is slow |

   **ClickHouse section** (once per node, `clickhouse-01` then `clickhouse-02`)

   First the script runs `SELECT 1`. If that fails, it prints FAIL
   `not answering` and skips the rest of that node's checks.

   | Line | What it checks | When it isn't OK | What to do |
   |---|---|---|---|
   | `no read-only tables` | Sum of `is_readonly` in `system.replicas` for the `otel` tables | FAIL `N read-only replicated tables (Keeper session lost?)` | Check Keeper. Reads still work |
   | `replication lag 0s, queue 0` | The largest `absolute_delay` (seconds behind) and `queue_size` (replication tasks waiting) | WARN when lag is over 60 s or the queue over 100 | Check the other replica is up, and the network between them |
   | `max 6 parts in a partition` | The largest number of active parts in any one partition, across all tables | WARN over 300 (inserts slow down at 1000, fail at 3000) | Bigger, rarer inserts; check merges |
   | `local disk 89% free` | `free_space / total_space` of the `default` disk | WARN under 15% free | Check TTL deletes, add disk, or tier to S3 |
   | `memory 5% of the server limit` | `MemoryTracking` as a share of `max_server_memory_usage` | WARN over 80% | Find heavy queries (step 5) |
   | `newest span 49s old` | Seconds since the newest span from the last hour: freshness | WARN over 120 s, or no spans in the last hour | If traffic is off (`./stack.sh traffic off`), this is expected. Otherwise, walk back: gateway queue, gateway counters, app logs |
   | `no delayed or rejected inserts` | `DelayedInserts` plus `RejectedInserts` in `system.events`, since the server started | WARN with a count | Too many parts; see above |
   | `no stuck mutations` | Mutations not done after 10 minutes | WARN with a count | Look at `system.mutations`; `KILL MUTATION` if needed |
   | (only with module 11) `S3: N parts in cold storage, no request errors` | Appears only if an `s3` disk exists. Counts parts on S3 and S3 request errors since start | WARN `N S3 request errors since start` | Check S3 credentials and endpoint. It counts since start, so watch whether it grows |
   | (only if any) `errors in the last 10 minutes: ...` | Error names from `system.errors` seen in the last 10 minutes. `UNKNOWN_TABLE` and `SYNTAX_ERROR` are left out, since they usually come from people typing queries | WARN with the names | Each name is a clue: `TABLE_IS_READ_ONLY` and `KEEPER_EXCEPTION` point at Keeper, for example |

2. **Read the gateway's own metrics.** This shows the raw lines the health
   check adds up:

   ```bash
   curl -s localhost:18888/metrics | grep -E '^otelcol_(receiver_accepted|receiver_refused|processor_filter_spans_filtered|exporter_sent|exporter_send_failed|exporter_queue)'
   ```

   Each line reads `metric_name{labels} value`. The labels say which
   component the number is for, for example `exporter="clickhouse"`. The
   value of a counter is the total since the gateway started. Run the command
   twice, 30 seconds apart, and compare: the difference divided by 30 is the
   rate per second. Don't worry if there are no `exporter_send_failed` lines:
   a counter that has never gone up isn't printed.

3. **Rehearse two incidents, and watch the check catch them.**

   First, ClickHouse down (both nodes) for 45 seconds. This stops both
   servers, looks at the gateway queue during the outage, then starts them
   again:

   ```bash
   docker stop clickhouse-01 clickhouse-02
   sleep 20; curl -s localhost:18888/metrics | grep '^otelcol_exporter_queue_size'
   sleep 25; docker start clickhouse-01 clickhouse-02
   ```

   In a test run, the queue grew to 3 batches during the outage and drained
   to 0 afterwards, with `send_failed` staying at 0: nothing was lost. The
   queue and retries did their job, because the outage (45 s) was shorter
   than the retry window (300 s) and the queue (1000 batches) never filled.

   Second, Keeper down. This stops Keeper, waits for ClickHouse to notice,
   runs the check, and starts Keeper again:

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

   Read it as a story. Keeper doesn't answer. Because of that, all 4
   replicated tables in `otel` (`otel_traces` and the three tables the
   materialized views fill) are read-only. The error names point the same way:
   `KEEPER_EXCEPTION` (ClickHouse couldn't talk to Keeper), `DNS_ERROR` (the
   name `clickhouse-keeper` couldn't be looked up while its container was
   stopped), and `TABLE_IS_READ_ONLY` (inserts refused). Run
   `./stack.sh health` again a minute after starting Keeper, and it's back to
   OK (the errors line stays for 10 minutes).

4. **Measure capacity from your own data.** The first query shows how many
   bytes each row takes, compressed on disk and uncompressed. The second
   shows how many spans per second arrived in the last 10 minutes:

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

   `disk = spans/s x bytes/span x 86400 x retention days x replicas x 1.3 headroom`

   86400 is the number of seconds in a day, and 1.3 adds 30% headroom. For
   example, 1000 spans per second at 300 bytes, kept 3 days on 2 replicas, is
   about 1000 x 300 x 86400 x 3 x 2 x 1.3, roughly 200 GB.

5. **Find the heaviest queries.** This groups the last hour's finished
   `SELECT` queries by their shape (`normalizeQuery` replaces literal values,
   so the same query with different ids counts as one), and shows the 5
   slowest by p95:

   ```sql
   SELECT normalizeQuery(query) AS q, count() AS runs,
          round(quantile(0.95)(query_duration_ms)) AS p95_ms,
          formatReadableSize(max(memory_usage)) AS max_memory,
          max(read_rows) AS max_rows_read
   FROM system.query_log
   WHERE type = 'QueryFinish' AND event_time > now() - INTERVAL 1 HOUR AND query_kind = 'Select'
   GROUP BY q ORDER BY p95_ms DESC LIMIT 5;
   ```

   Look at `max_rows_read`. A query that reads millions of rows to return a
   few usually doesn't filter on the sorting key. Rewriting it to filter on
   owner, service, span name or time is the cheapest fix.

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

## Recap

- Operational readiness means you can see the pipeline's health, hear about
  trouble early, and know what to do.
- Counters only go up; watch their rate. Gauges go up and down; watch their
  value. SLOs turn "is it OK?" into a measurable target.
- Every metric answers one of four questions: fresh, complete, keeping up,
  usable.
- Spans can be lost at the SDK, the gateway's memory limiter, the export
  queue, and in ClickHouse or Keeper. Each needs its own metric.
- The gateway's books must balance: accepted = filtered + sent + queued +
  failed. `send_failed` and `enqueue_failed` mean loss has happened.
- ClickHouse delays inserts at 1000 parts per partition and rejects them at
  3000; alert well before.
- Keeper down means read-only tables: reads work, writes wait in the
  gateway's queue for up to 300 s.
- `./stack.sh health` checks all of this on one screen.

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

<details><summary>Is a counter's value of 5,000 good or bad?</summary>

You can't tell from the value alone. Counters only go up from when the
program started, so 5,000 could be one minute or one month of data. Look at
the rate: how much it rose over the last few minutes, and whether that's
normal.
</details>

<details><summary>The health check says <code>newest span 900s old</code>, but everything else is OK. What's the likely cause?</summary>

Nothing is being sent. Check whether the traffic loop is paused
(`./stack.sh status`, or you ran `./stack.sh traffic off`). If traffic is on,
check the gateway's accepted counter: if it isn't rising, the apps can't reach
the gateway, so look at the apps' logs for export errors.
</details>

<details><summary>The <code>refused</code> line shows WARN, but the queue is empty and memory is low now. Is there a problem?</summary>

Probably not right now. The refused counter counts since the gateway started,
so it records an earlier spike. Find out when it happened (if you have
Prometheus, look at the counter's rate over time), and whether apps lost
spans then.
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
- [Prometheus: metric types](https://prometheus.io/docs/concepts/metric_types/)
- [Google SRE book: service level objectives](https://sre.google/sre-book/service-level-objectives/)

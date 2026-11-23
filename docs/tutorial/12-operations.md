# Module 12: Operational readiness, from gateway to ClickHouse (80 min)

## Why this matters

The tracing pipeline you built is a production system in its own right. If it
quietly loses spans, nobody notices until someone opens a trace during an
incident and half of it is missing. [Module 11](11-s3-tiering.md) added the
last moving part, S3. This module asks how you know, day to day, that the
whole pipeline is healthy.

By the end, you'll be able to name the few signals that matter, read the
repo's one-screen health check (including its blind spots), rehearse two
outages and watch the check catch them, and size and run the pipeline like a
service with its own targets. You'll also know how to run a large ClickHouse
cluster day to day: when to scale and which way, how to grow disks and change
S3 tiering without surprises, and what to do when something breaks, using the
[runbooks appendix](appendix-runbooks.md), several of which you rehearse here.
The full per-component catalogue of metrics is in the
[metrics reference appendix](appendix-metrics-reference.md).

## Key terms

| Term | Plain meaning |
|---|---|
| **Operational readiness** | Being able to run a system day to day: you know when it's unhealthy, why, and what to do, before users tell you |
| **Counter** | A metric that only goes up from when the program started, like a car's odometer |
| **Gauge** | A metric that goes up and down, like a fuel gauge: queue size, memory, free disk |
| **Rate** | How much a counter grew per second over a time window. For counters, the rate is what you watch |
| **Alert** | An automatic message to a person when a metric crosses a threshold for long enough. |
| **SLI and SLO** | A service level indicator measures what users experience ("age of the newest span"); a service level objective is the target for it ("under 2 minutes, 99.9% of the time") |
| **Saturation** | How full a resource is: a queue at 90% of capacity, or a disk with 5% free. One more push and something fails |
| **Lag** | How far behind something is: here, how many seconds a replica is behind its peer |
| **Runbook** | A written, step-by-step "what to do when X happens" for the person on call |
| **Headroom** | How much of a resource is left before it runs out, and how long that lasts at the current growth |
| **Rolling change** | Restarting or upgrading servers one at a time, so the service never goes down |
| **Quorum** | The majority of Keeper nodes that must agree for Keeper to work: 2 of 3, or 3 of 5 |

Reminders: the **gateway** is the central OpenTelemetry Collector, and its
**exporter** writes spans to ClickHouse ([module 4](04-collector.md)). A
**part** is one chunk of a table on disk, made by every insert
([module 7](07-clickhouse.md)). **Keeper** holds the replication metadata;
without it, replicated tables go **read-only**: reads work, inserts fail
([module 7](07-clickhouse.md)).

## Idea

### What "operational readiness" means

Driving a car is one skill. Knowing that the oil light means "stop soon",
and carrying a spare tire you know how to change, is another: that's
operational readiness. For this pipeline, it means you **see its health**
(you know which metrics matter), you **hear about trouble early** (alerts
fire before data is lost), and you **know what to do** (each likely failure
has a practiced runbook). The outage labs in modules [4](04-collector.md),
[7](07-clickhouse.md), [10](10-copying-data.md) and [11](11-s3-tiering.md)
were that practice. Without it, a tracing system fails silently: spans go
missing, and nobody notices until they need them.

### Metrics and the four questions

A **metric** is a named number. `otelcol_exporter_sent_spans_total` is a
counter ("spans written since the gateway started"): if its rate drops to
zero, nothing is being written. `otelcol_exporter_queue_size` is a gauge
("batches waiting now"). Monitoring tools like Prometheus (a system that
fetches metrics every few seconds and stores them) handle counters resetting
on restart. A good **alert** fires before users are hurt and always means
something, so people don't learn to ignore it.

Every signal in this module answers one of four questions: **is data
arriving** (freshness), **is it complete** (no loss), **is the system keeping
up** (saturation), and **can people use it** (query health).

### Where spans can be lost

Follow the HR agent's "I need a new laptop" request. Its spans travel:

```text
 app SDK ──▶ receiver ──▶ processors ──▶ export queue ──▶ exporter ──▶ ClickHouse ──▶ Keeper
    │            │             │              │               │             │            │
 queue full,  memory_limiter  filter drops   full: new      gives up      too many    down: tables
 or process   refuses         (by design)    batch dropped  after 300 s   parts, disk go read-only
 exits (lost) (not lost yet)                 (lost)         (lost)        full, memory
```

1. **App SDK.** Holds finished spans in memory (2048 by default). If the
   gateway is unreachable for long, the queue fills and new spans are
   dropped; if the process exits first, they're gone. No gateway counter
   sees this.
2. **Receiver.** Near its memory limit, `memory_limiter` refuses new data.
   That's not a loss yet: the SDK keeps the spans and retries.
3. **Processors.** `filter/require_org_labels` drops spans without
   `org.owner` or `org.service`: loss by design, like the laptop request's
   `legacy-hr-api` span ([module 4](04-collector.md)).
4. **Export queue.** When it already holds 1000 batches, each new batch is
   dropped on arrival (`enqueue_failed`). A gateway restart also empties it:
   it lives in memory.
5. **Exporter.** A batch it has retried for 300 s (`max_elapsed_time`) is
   dropped (`send_failed`).
6. **ClickHouse** can reject inserts (too many parts, disk full, memory), and
   **Keeper** down makes tables read-only. Both turn into exporter retries,
   so they become loss only through steps 4 and 5.

> **Remember from module 4:** only `memory_limiter` pushes back on the apps.
> The queue and the exporter drop data silently: the apps think it arrived.

> **Quick check:** ClickHouse is down for 20 minutes. Which gateway loss
> counter rises first, and which one later?
>
> <details><summary>Answer</summary>
>
> Usually `send_failed`, after 300 s, as the batches being retried run out of
> time. `enqueue_failed` follows once the queue holds 1000 batches. If
> batches arrive faster than about 3 a second, the queue fills before 300 s
> and the order flips.
> </details>

### The books must balance

The gateway counts every way a span can leave it. Like a bank statement:

**accepted = filtered + sent + still in queue or batch + failed**

Accepted is what the receiver took in; filtered, what the label filter
dropped; sent, what reached ClickHouse; in queue or batch, what's waiting (the
`batch` processor holds spans up to 5 s); failed, `send_failed` plus
`enqueue_failed`. If the numbers don't add up over time, something is losing
data in a way no counter shows.

> **Quick check:** accepted 1000, filtered 20, sent 900, lost 0, and the queue
> is empty. A minute later the numbers haven't changed. Where are the other
> 80 spans?
>
> <details><summary>Answer</summary>
>
> Unaccounted for. The `batch` processor flushes within 5 s and the queue is
> empty, so 80 spans are stuck or were dropped where no counter sees it.
> That's what the books are for: start with the gateway's log.
> </details>

### The ten signals that matter most

The [appendix](appendix-metrics-reference.md) lists dozens of metrics. These
ten cover the four questions:

| Question | Signal | Where | Bad looks like |
|---|---|---|---|
| Arriving | Age of the newest span | `dateDiff('second', max(Timestamp), now())` on `otel.otel_traces` | Over 2 minutes while traffic runs |
| Arriving | Spans accepted | `otelcol_receiver_accepted_spans_total` (rate) | Drops to zero while apps run |
| Complete | Spans lost | `otelcol_exporter_send_failed_spans_total` + `otelcol_exporter_enqueue_failed_spans_total` (rate) | Any increase |
| Complete | Spans refused | `otelcol_receiver_refused_spans_total` (rate) | A sustained rate |
| Complete | Spans filtered | `otelcol_processor_filter_spans_filtered_total` (rate) | A sudden step up: a service lost its labels |
| Keeping up | Export queue fill | `otelcol_exporter_queue_size` / `_capacity` | Over half full, or growing for minutes |
| Keeping up | Parts per partition | `MaxPartCountForPartition` | Over 300 and rising (delays at 1000, rejects at 3000) |
| Keeping up | Read-only replicas, lag | `is_readonly`, `absolute_delay` in `system.replicas` | Any read-only table; lag over 60 s |
| Keeping up | Local disk free | `free_space / total_space` in `system.disks` | Under 15% |
| Usable | Query latency and errors | `system.query_log`, `system.errors` | p95 over your SLO; new error names |

`Timestamp` is a `DateTime64` (time with fractions of a second), so use
`dateDiff('second', ...)` to get a plain number of seconds.

`send_failed` also counts permanent errors, dropped at once without retries.
A schema mismatch fails every batch until you fix it.

### Totals versus rates

The rule for counters is "watch the rate", and the health check you'll run
next doesn't fully follow it. For four lines it compares the **total since
start** with zero: `refused` and `lost` on the gateway, delayed or rejected
inserts and S3 request errors on ClickHouse. So a single blip, say one failed
S3 request at 5 a.m., keeps that line at WARN or FAIL until the gateway or
server restarts, even if nothing has gone wrong since.

A script that runs once has no history to compute a rate from. So when one
of those lines isn't OK, ask "is it still rising?"; lab 1 shows two ways to
answer. Prometheus, alerting on the rate, answers it for you.

> **Quick check:** the check shows `WARN refused 12 spans` on a gateway that
> has run for a week. Should you page someone?
>
> <details><summary>Answer</summary>
>
> Not yet. Refused spans aren't lost, and 12 in a week may be one old blip.
> Sample the counter twice a minute apart: if it's still rising, memory is
> under pressure now; if not, it's history.
> </details>

### Running a large ClickHouse cluster

Everything so far works the same on two servers or forty. What changes at
scale is that something is always happening somewhere: a disk filling, a
server being replaced, a schema change rolling out, an upgrade half done.
Running it well means four habits: **watch headroom**, **change storage
without moving data**, **keep Keeper boring**, and **change one server at a
time**. When something does break, the person on call follows a runbook
instead of improvising.

**1. Watch headroom, and scale before it runs out.** For each resource, know
the signal, the level at which you act, and the action. These levels are
starting points; tune them to how fast your data grows and how long the
action takes:

| Resource | Signal | Plan at | Page at | Usual action |
|---|---|---|---|---|
| Local disk | `free_space / total_space` per disk | 40% free | 15% free | Grow the volume; tier old data to S3; then add disks or shards |
| CPU | Server CPU at the daily peak | 60% | 85% | Bigger servers; more replicas if reads dominate, more shards if inserts do |
| Memory | Memory vs the server limit | 70% | 90% | Query limits per user; bigger servers |
| Parts | Max parts in a partition | 300 | 1000 (inserts delayed) | Bigger batches, `async_insert`; check merges |
| Replication | `absolute_delay`, `queue_size` | 30 s | 300 s | Check fetches, disk, network ([runbook](appendix-runbooks.md#replica-read-only-or-lagging)) |
| Keeper | Latency, outstanding requests, its disk | Rising trend | `ruok` fails | Faster disks, dedicated hosts, fewer tiny inserts |

Which way to scale is [module 10](10-copying-data.md)'s question "what is
running out?": disk and server size move nothing and are the first choice;
a replica adds reads and safety; a shard adds space and insert capacity but
takes a TTL to balance, so plan it months ahead, at the "plan" level, not
the "page" level.

**2. Change storage without moving data.** Most storage work is online:

- **Grow a cloud volume in place** (EBS `modify-volume`, then
  `xfs_growfs`): ClickHouse sees the space without a restart. It can't
  shrink, and the next change on that volume waits until the current one is
  `completed`, so grow by enough
  ([runbook](appendix-runbooks.md#grow-an-ebs-volume-in-place)).
- **Add a disk** through a new storage policy that contains the old one;
  new parts spread over both, old parts stay, and the switch is one-way
  ([runbook](appendix-runbooks.md#add-a-disk-to-a-server), lab in module 10).
- **Local NVMe** (instance store) is fast but lost when the instance stops:
  treat every such server as replaceable, with at least two replicas per
  shard ([runbook](appendix-runbooks.md#servers-with-local-nvme-instance-store)).
- **Change S3 tiering** (the move age, the bucket, credentials) without
  rewriting every partition at once: `materialize_ttl_after_modify = 0`,
  then `MATERIALIZE TTL IN PARTITION`, one day at a time
  ([runbook](appendix-runbooks.md#change-s3-tiering)).
- **ClickHouse's own log tables** (`system.text_log`, `query_log`...) have
  no TTL by default. Give them one, or they quietly become the biggest
  tables on the disk.

**3. Keep Keeper boring.** Every insert into a replicated table writes to
Keeper, so Keeper is in the path of every span. Run three nodes (five if
you must survive two failures), on separate hosts and zones, on fast
durable disks, not on the busiest ClickHouse servers. Alert on `ruok`, its
latency and its free disk. Upgrade it separately from ClickHouse. If it
loses its quorum for good, there's a last-resort recovery mode; rehearse it
before you need it ([runbook](appendix-runbooks.md#keeper-down-or-quorum-lost)).

**4. Change one server at a time.**

- **Config is code.** `remote_servers`, macros and storage policies come
  from one source (Ansible, Helm, the ClickHouse operator) and reach every
  server in one change. Check the result on all of them with
  `clusterAllReplicas('tracing', system.clusters)` or
  `system.storage_policies`.
- **Restarts and upgrades roll**: one replica per shard at a time, checking
  health between servers, with versions less than a year apart
  ([runbook](appendix-runbooks.md#rolling-restart-and-upgrade)).
- **Schema changes** are add-only and `ON CLUSTER`. A server that was down
  runs them from Keeper's DDL queue when it returns; check
  `system.distributed_ddl_queue` after each change
  ([runbook](appendix-runbooks.md#on-cluster-ddl-not-finished)).
- **Backups** run on a schedule, to storage outside the cluster's own
  account, and a restore drill proves them monthly
  ([runbook](appendix-runbooks.md#backup-and-restore-drill)).

**5. When something breaks: the runbooks.** The
[runbooks appendix](appendix-runbooks.md) has one page per likely problem
(disk full, too many parts, read-only or lagging replicas, Keeper down, a
failed node, runaway queries, stuck mutations, the `Distributed` queue,
the gateway queue), each with symptom, impact, diagnosis, fix, verification
and prevention. It starts with **the first five minutes**, the same snapshot
for every alert: is data being lost now, is it one table, one server or
everything, and what changed. Lab 3 rehearses four of them.

> **Quick check:** A 6-server cluster's disks are at 55% free and drop 2 points a week; CPU at peak is 35%. What do you do, and when?
>
> <details><summary>Answer</summary>
>
> Nothing urgent: about 7 weeks to the 40% "plan" level. Then grow the volumes in place (or tier more data to S3): disk is the only thing running out. No shard: CPU is fine, and a shard would take a full TTL to balance.
> </details>

> **Quick check:** One server of a shard dies. While you rebuild it, what must you not do?
>
> <details><summary>Answer</summary>
>
> Restart, upgrade or stop the shard's remaining replica: it's the only copy. Pause rolling changes until the rebuilt server shows `queue_size = 0` and matching counts.
> </details>

## Remember it

> **Fresh, complete, keeping up, usable.** Every alert answers one of those.
> **The books must balance**: accepted = filtered + sent + queued + failed.
> And **a total is history; the rate is news**.
>
> **At scale: act on headroom, not on outages; grow what moves nothing first;
> change one server at a time; and follow the runbook, not your memory.**

## In this repo

- `otel-gateway-config.yaml`: the gateway publishes its own metrics on port
  8888, mapped to <http://localhost:18888/metrics>; `health_check` answers on
  13133. `memory_limiter.limit_mib` is 512, `max_elapsed_time` is 300 s, and
  the exporter's `endpoint` lists both ClickHouse nodes.
- `compose.yaml` sets **no container memory limits**: the gateway's only cap
  is `memory_limiter`, and each ClickHouse server sets its limit (90% of RAM)
  from the whole Docker machine, which all three share. So "memory N% of the
  server limit" is optimistic here. In production, set container limits
  (gateway: about 20% above `limit_mib`).
- `docs/tutorial/appendix-runbooks.md`: the runbooks. The steps marked
  "tested" were run on this stack.
- `docs/tutorial/labs/compose.replication.yaml` and
  `docs/tutorial/labs/compose.replication-s3.yaml`: the extra server
  `clickhouse-03` that lab 3 breaks and rebuilds.
- `docs/tutorial/labs/health-check.sh` (also `./stack.sh health`): one screen
  covering the gateway, Keeper and both ClickHouse nodes. It reads the
  metrics page with `curl`, talks to Keeper on port 9181, and runs SQL on each
  node with `docker exec`. Thresholds are demo starting points. Every line is
  explained in the
  [appendix](appendix-metrics-reference.md#the-health-check-line-by-line).

## Principal engineer's notes

**Touch points**
- App to gateway: OTLP/HTTP on 4318 (14318 on the host). A refusal is a
  retryable error, so SDK retry and queue settings matter as much as the
  gateway's.
- Gateway to ClickHouse: native protocol on 9000; the contract is the stock
  columns ([module 8](08-data-model.md)). With `create_schema: false`, a
  breaking schema change shows up as `send_failed`.
- ClickHouse to Keeper on 9181: each insert registers a part per replicated
  table, so one gateway insert plus 3 materialized views is up to 4 Keeper
  writes.

**SLOs for the pipeline itself**
- **Delivery**: sent / (accepted - filtered) per hour, say 99.9%. It can't
  see SDK loss, so add a synthetic trace every minute.
- **Freshness**: that synthetic trace is queryable within 60 s, 99% of the
  time. This is the end-to-end lag users feel.
- **Query latency**: p95 trace lookup by `TraceId` under 1 s
  (`system.query_log`).
- **Page on symptoms** (an SLO at risk, `lost` rising); **ticket the
  causes** (parts, disk, lag, Keeper latency). Many causes never hurt anyone.

**At scale: capacity planning**
- Disk = spans/s x bytes/span x 86400 x retention days x replicas x 1.3.
  This stack's busiest hour: 5 x 53 bytes (619 raw) x 86400 x 3 x 2 x 1.3 is
  about 180 MB. At 1000 spans/s of real 300-byte spans: about 200 GB.
- Inserts per second hurt before rows do. Each gateway inserts per 1000 spans
  or 5 s; many gateways mean many small parts and Keeper writes. Bigger
  batches or `async_insert` are the knob.
- The queue's real limit is memory: 1000 batches of 1000 spans at 600+ bytes
  is over 600 MB, past the 512 MiB `memory_limiter`. Refusals come first.

**Operational issues**
- Keep self-monitoring **outside** the pipeline: alerts stored in the
  ClickHouse they watch go silent when it fails. Add a "dead man's switch",
  an always-firing alert whose silence pages.
- Every alert links to a runbook (symptom, checks, fix, verify, undo). The
  outage labs are small **game days**, rehearsed failures; repeat them in
  staging and check that the books balance afterwards.

**Design trade-offs**
- In-memory queue (here) versus `file_storage`: a disk queue survives
  restarts but costs disk I/O. Choose it when losing a restart's worth of
  spans is unacceptable.

## Lab 1 (15 min): read the health check

1. **Run it:**

   ```bash
   ./stack.sh health
   ```

   ```text
   Gateway (otel-gateway)
     OK   health check endpoint answers
     OK   export queue 0/1000 batches
     OK   since start: accepted 341, filtered 8, sent 333
     OK   refused 0 spans
     OK   lost 0 spans
   Keeper (clickhouse-keeper)
     OK   ruok: imok, state standalone, 2043 znodes
     OK   outstanding requests 0, max latency 69 ms
   ClickHouse (clickhouse-01)
     OK   no read-only tables
     OK   replication lag 0s, queue 0
     OK   max 7 parts in a partition
     OK   local disk 89% free
     OK   memory 5% of the server limit
     OK   newest span 7s old
     OK   no delayed or rejected inserts
     OK   no stuck mutations
     WARN 1 S3 request errors since start
   ...
   ```

   **OK** means fine, **WARN** "look at this soon", **FAIL** "broken now". Any
   WARN or FAIL makes the script exit non-zero, so a scheduler could run it
   and alert. The S3 line appears only with [module 11](11-s3-tiering.md)'s
   setup.

2. **Map each line to a question.** **Arriving**: `newest span`, and
   `accepted`. **Complete**: `refused`, `lost`, and the books in
   `since start`. **Keeping up**: the export queue, Keeper `ruok` and
   outstanding requests, read-only tables, lag, parts, disk, memory, delayed
   inserts, mutations, S3. **Usable**: the `errors in the last 10 minutes`
   line when it appears; the script doesn't check query latency (stretch
   exercise B does).

3. **Balance the books.** Accepted 341 minus filtered 8 is 333, and sent is
   333: nothing in flight. Usually there's a small gap, spans waiting in the
   `batch` processor or the queue. Run the check again a few seconds later:
   the gap moves but doesn't keep growing. A gap that keeps growing, with
   `lost 0`, means spans are stuck somewhere.

4. **Read the rate behind a "since start" line.** The run above shows
   `WARN 1 S3 request errors since start`. Is S3 broken? The total can't say.
   ClickHouse keeps a per-second history of its counters in
   `system.metric_log`, so ask *when* they rose:

   ```sql
   SELECT toStartOfHour(event_time) AS hour,
          sum(ProfileEvent_S3ReadRequestsErrors + ProfileEvent_S3WriteRequestsErrors) AS s3_errors,
          sum(ProfileEvent_DelayedInserts + ProfileEvent_RejectedInserts) AS slow_inserts
   FROM system.metric_log
   WHERE event_time > now() - INTERVAL 24 HOUR
   GROUP BY hour HAVING s3_errors + slow_inserts > 0 ORDER BY hour;
   ```

   ```text
   2026-11-21 05:00:00   1   0
   ```

   One error, twelve hours ago (server time, UTC here), and nothing since:
   history, not an incident. Rows in the latest hours would be news.

   The gateway has no history table, so take two samples and subtract:

   ```bash
   refused() { curl -s localhost:18888/metrics | grep '^otelcol_receiver_refused_spans_total' | awk '{s += $NF} END {print s + 0}'; }
   a=$(refused); sleep 60; b=$(refused); echo "refused in the last minute: $((b - a))"
   ```

   The function adds the counter up over all its label sets, like the health
   check does; `+ 0` turns a missing counter (one that has never gone up isn't
   printed) into 0. Swap in `otelcol_exporter_send_failed_spans_total` to
   check `lost` the same way.

## Readiness checklist

The health check tells you about today. Before calling the pipeline
production-ready, work through these:

- **Capacity**: disk from your own numbers (stretch exercise A); gateway
  queue and memory for the longest outage you'll accept; container limits.
- **Redundancy**: 2 or more gateways behind a load balancer; 3 Keepers; 2 or
  more ClickHouse replicas per shard, on separate hosts or zones.
- **Durability**: a persistent gateway queue (`sending_queue.storage` with
  `file_storage`); ClickHouse backups (`BACKUP ... TO S3(...)`) with a restore
  you've actually tested.
- **Security**: TLS on OTLP and the ClickHouse ports; no passwords in config
  files (this demo's `demo` password is for a laptop only); separate
  ClickHouse users, so the gateway can only insert and readers can only read,
  with quotas (per-user limits on queries, rows read and run time).
- **Watching the pipeline itself**: scrape the gateway (`:8888`) and
  ClickHouse (`:9363`, once enabled) into a separate Prometheus; alert on
  rates and SLOs; send a synthetic trace every minute.
- **Change safety**: pin image versions, as `compose.yaml` does; validate the
  Collector config in CI (`otelcol-contrib validate --config=...`); make
  schema changes add-only and `ON CLUSTER`; upgrade one replica at a time.
- **Runbooks**: the [runbooks appendix](appendix-runbooks.md), adapted to
  your hosts and linked from every alert: disk full, growing a volume,
  adding a disk, S3 tiering changes, too many parts, read-only or lagging
  replicas, Keeper down, replacing a node, adding a shard, runaway queries,
  stuck mutations, the `Distributed` queue, `ON CLUSTER` DDL, rolling
  upgrades, backups, the gateway queue. Each one rehearsed once in staging.
  Labs 2 and 3 rehearse six of them.
- **Headroom**: an owner and a "plan at" level for disk, CPU, memory, parts,
  lag and Keeper (the table in "Running a large ClickHouse cluster"), and
  dates for the next capacity change.

## Lab 2 (15 min): rehearse two outages

1. **ClickHouse down for 45 seconds.** This stops **both** servers, looks at
   the gateway queue during the outage, then starts them again:

   ```bash
   docker stop clickhouse-01 clickhouse-02
   sleep 20; curl -s localhost:18888/metrics | grep '^otelcol_exporter_queue_size'
   sleep 25; docker start clickhouse-01 clickhouse-02
   ```

   Why both? The exporter's `endpoint` is
   `tcp://clickhouse-01:9000,clickhouse-02:9000`. If one node is down, the
   ClickHouse client connects to the other, inserts keep succeeding, and
   replication fills in the stopped node when it returns. The queue would
   never move. Only with both down does the gateway have nowhere to write.

   In a test run, the queue grew to 3 batches during the outage and drained
   to 0 afterwards, with `lost 0`. The outage (45 s) was shorter than the
   retry window (300 s), and the queue (1000 batches) never filled.

2. **Keeper down.** This stops Keeper, waits for ClickHouse to notice, runs
   the check, and starts Keeper again:

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

   Read it as a story. Keeper doesn't answer, so all 4 replicated tables in
   `otel` are read-only. The error names agree: `KEEPER_EXCEPTION` (couldn't
   talk to Keeper), `DNS_ERROR` (the name `clickhouse-keeper` didn't resolve
   while its container was stopped), `TABLE_IS_READ_ONLY` (inserts refused).
   A minute after starting Keeper the check is back to OK, except the errors
   line, which stays for its 10-minute window.

> **Quick check:** in production, Keeper is down and you have 1 gateway with
> the default in-memory queue. How long do you have before spans are lost,
> and what would shorten that?
>
> <details><summary>Answer</summary>
>
> About 300 s: after that, the batches the exporter is retrying start to be
> dropped. A full queue (or, on a busy gateway, `memory_limiter` refusing
> data) would shorten it, and a gateway restart would lose the queue at once.
> </details>

## Lab 3 (20 min): rehearse four runbooks

Each step follows a page of the [runbooks appendix](appendix-runbooks.md):
read the page first, then do it. You need a third ClickHouse server to
break, the one from module 10. With S3 tiering on (module 11), it needs the
S3 settings too. This function runs Docker Compose with all four files, so
it can be reused below:

```bash
dc() { docker compose -f compose.yaml -f docs/tutorial/labs/compose.s3-tiering.yaml \
  -f docs/tutorial/labs/compose.replication.yaml -f docs/tutorial/labs/compose.replication-s3.yaml "$@"; }
dc up -d --no-deps clickhouse-03
sleep 10; docs/tutorial/labs/add-replica.sh
```

(Without module 11's S3, use only `compose.yaml` and
`compose.replication.yaml`, and skip step 4.)

1. **[Replace a failed node](appendix-runbooks.md#replace-a-failed-node).**
   Destroy `clickhouse-03` with its data, the way a lost instance would,
   and look at what the other replicas see:

   ```bash
   dc rm -sfv clickhouse-03
   docker exec clickhouse-01 clickhouse-client --password demo -q \
     "SELECT table, total_replicas, active_replicas FROM system.replicas WHERE database = 'otel'"
   ```

   Every table shows `3  2`: Keeper still lists three replicas, two are
   active. Now start a new, empty server with the same name, and try to
   rejoin:

   ```bash
   dc up -d --no-deps clickhouse-03
   sleep 10; docs/tutorial/labs/add-replica.sh
   ```

   It fails: `Replica /clickhouse/tables/<uuid>/01/replicas/clickhouse-03
   already exists. (REPLICA_ALREADY_EXISTS)`. Keeper still has the dead
   replica's entry. Remove it from a live server, and try again:

   ```bash
   docker exec clickhouse-01 clickhouse-client --password demo -q "SYSTEM DROP REPLICA 'clickhouse-03' FROM DATABASE otel"
   docs/tutorial/labs/add-replica.sh
   sleep 20
   docker exec clickhouse-03 clickhouse-client --password demo -q \
     "SELECT table, total_replicas, active_replicas, queue_size FROM system.replicas WHERE database = 'otel'"
   for h in clickhouse-01 clickhouse-03; do
     docker exec $h clickhouse-client --password demo -q "SELECT '$h', count() FROM otel.otel_traces"
   done
   ```

   In a test run, all six tables showed `3  3  0` and both servers the same
   count (134151) 20 seconds later: the new server fetched everything from
   its peers.

2. **[A runaway query](appendix-runbooks.md#query-using-too-much-memory-or-running-too-long).**
   Start a query that takes two minutes, find it, and stop it:

   ```bash
   docker exec clickhouse-01 clickhouse-client --password demo --query_id runaway-1 \
     -q "SELECT sleepEachRow(1) FROM numbers(120) SETTINGS max_block_size = 1" &
   sleep 3
   docker exec clickhouse-01 clickhouse-client --password demo --format PrettyCompactMonoBlock -q \
     "SELECT query_id, user, round(elapsed) AS secs, formatReadableSize(memory_usage) AS mem FROM system.processes WHERE query_id = 'runaway-1'"
   docker exec clickhouse-01 clickhouse-client --password demo -q "KILL QUERY WHERE query_id = 'runaway-1' SYNC"
   ```

   `KILL` reports `finished`, and the background client prints
   `QUERY_WAS_CANCELLED`. In real life you'd look it up in
   `system.processes` by `elapsed` or `memory_usage`; `user` says whose it
   is.

3. **[A stuck mutation](appendix-runbooks.md#stuck-mutation).** An update
   that fails on half the rows retries forever. Create one on a scratch
   table, read why it's stuck, and kill it:

   ```bash
   ch() { docker exec -i clickhouse-01 clickhouse-client --password demo --multiquery --format PrettyCompactMonoBlock; }
   ch <<'SQL'
   CREATE DATABASE IF NOT EXISTS drill;
   CREATE TABLE drill.t (id UInt64, v String) ENGINE = MergeTree ORDER BY id;
   INSERT INTO drill.t SELECT number, 'x' FROM numbers(1000);
   ALTER TABLE drill.t UPDATE v = toString(throwIf(id > 500, 'bad row')) WHERE 1;
   SQL
   sleep 4
   ch <<'SQL'
   SELECT mutation_id, parts_to_do, is_done, latest_fail_error_code_name FROM system.mutations WHERE database = 'drill';
   KILL MUTATION WHERE database = 'drill';
   SELECT count() AS open_mutations FROM system.mutations WHERE database = 'drill' AND NOT is_done;
   SELECT countIf(v = 'x') AS unchanged FROM drill.t;
   SQL
   ```

   The mutation shows `parts_to_do 1`, `is_done 0`, and the error
   `FUNCTION_THROW_IF_VALUE_IS_NON_ZERO`. After `KILL MUTATION`, nothing
   is open, and all 1000 rows are unchanged: the failed mutation hadn't
   rewritten anything. (Parts a mutation has already rewritten stay
   rewritten; there's no rollback.)

4. **[Backup and restore drill](appendix-runbooks.md#backup-and-restore-drill).**
   Back up `trace_entry` to the local S3 server, restore it into the
   scratch database, and compare:

   ```bash
   ch <<'SQL'
   BACKUP TABLE otel.trace_entry TO S3('http://seaweedfs:8333/traces/backups/lab-1', 'demo', 'demo');
   RESTORE TABLE otel.trace_entry AS drill.trace_entry FROM S3('http://seaweedfs:8333/traces/backups/lab-1', 'demo', 'demo');
   SELECT (SELECT count() FROM drill.trace_entry) AS restored, (SELECT count() FROM otel.trace_entry) AS live;
   SQL
   ```

   Both statements report their status (`BACKUP_CREATED`, `RESTORED`), and
   the counts match (10796 in a test run; with traffic running, `live` may
   be a little higher by the time it's counted). A backup name can be used
   once: running the same backup again fails with `BACKUP_ALREADY_EXISTS`;
   use `lab-2`.

5. **Clean up.** The scratch database, then `clickhouse-03`, unregistering
   it first as in module 10:

   ```bash
   docker exec clickhouse-01 clickhouse-client --password demo -q "DROP DATABASE drill SYNC"
   docker exec clickhouse-03 clickhouse-client --password demo -q "DROP DATABASE otel SYNC"
   dc rm -sfv clickhouse-03
   ```

   For the next 10 minutes, `./stack.sh health` shows the drills' own errors
   on `clickhouse-01` (`QUERY_WAS_CANCELLED`,
   `FUNCTION_THROW_IF_VALUE_IS_NON_ZERO`) in its errors line: a reminder
   that a WARN needs reading, not just counting.

### Stretch exercises (optional)

**A. Measure your own capacity numbers.** Bytes per row, then spans per
second over the last 10 minutes (needs the traffic loop running):

```sql
SELECT table, sum(rows) AS n,
       round(sum(data_compressed_bytes) / n) AS bytes_per_row_on_disk,
       round(sum(data_uncompressed_bytes) / n) AS bytes_per_row_raw
FROM system.parts WHERE database = 'otel' AND active GROUP BY table;

SELECT round(count() / dateDiff('second', min(Timestamp), max(Timestamp)), 1) AS spans_per_second
FROM otel.otel_traces WHERE Timestamp > now() - INTERVAL 10 MINUTE;
```

A test run measured 53 bytes per span on disk (619 raw). Real spans, with
prompts and longer attributes, are often several times larger. Use your
numbers in the disk formula from the principal engineer's notes.

**B. Find the heaviest queries.** The last hour's `SELECT` queries, grouped
by shape (`normalizeQuery` replaces literal values), 5 slowest by p95:

```sql
SELECT normalizeQuery(query) AS q, count() AS runs,
       round(quantile(0.95)(query_duration_ms)) AS p95_ms,
       formatReadableSize(max(memory_usage)) AS max_memory,
       max(read_rows) AS max_rows_read
FROM system.query_log
WHERE type = 'QueryFinish' AND event_time > now() - INTERVAL 1 HOUR AND query_kind = 'Select'
GROUP BY q ORDER BY p95_ms DESC LIMIT 5;
```

A query that reads millions of rows to return a few usually doesn't filter on
the sorting key (owner, service, span name, time). Rewriting it to do so is
the cheapest fix.

## Explain it back

> "Operating the pipeline means four questions: is data fresh, complete,
> keeping up, and usable. Spans are lost in the SDK, at a full export queue,
> on a gateway restart, or when the exporter gives up after 300 s; refusals
> aren't loss yet. The gateway's books must balance, and for counters I watch
> the rate. I set SLOs on delivery, freshness and query latency, page on
> symptoms, keep monitoring outside the pipeline, size disk from spans per
> second and bytes per span, and rehearse runbooks as game days. On a large
> ClickHouse cluster I act on headroom (disk, CPU, memory, parts, lag,
> Keeper) at a 'plan' level, not when it pages. I grow volumes or add disks
> before adding shards, change S3 tiering one partition at a time, keep
> Keeper on three dedicated nodes, and change one server at a time. When
> something breaks, I start with the first five minutes and follow the
> runbook: for a dead server, drop its replica from Keeper and let a new
> one fetch everything."

## Recap

- Four questions (fresh, complete, keeping up, usable), about ten signals;
  the appendix has the rest.
- Loss happens in the SDK, at a full export queue (`enqueue_failed`), on a
  gateway restart, and when the exporter gives up (`send_failed`). Refusals
  are back-pressure, not loss. The books must balance.
- Counters: watch the rate. The health check's `refused`, `lost`, delayed
  inserts and S3 lines are all-time totals; use `system.metric_log` or two
  samples to see whether they're still rising.
- Run the pipeline as a service: SLOs on delivery, freshness and query
  latency; page on symptoms; monitoring stored elsewhere; capacity from
  spans/s x bytes/span x retention x replicas.
- The exporter fails over between ClickHouse nodes; the queue grows only
  when both are down.
- At scale: a headroom table with "plan" and "page" levels per resource;
  online storage changes first (grow the volume, add a disk, tier to S3);
  Keeper on three dedicated nodes; config as code; one server at a time.
- The [runbooks appendix](appendix-runbooks.md) covers each likely failure
  and planned change. Rehearsed here: replacing a node (`SYSTEM DROP
  REPLICA`, then recreate with the same UUIDs), `KILL QUERY`, `KILL
  MUTATION`, and a backup restored into a scratch database.

## Check yourself

<details><summary>Spans per second accepted by the gateway equals spans per second sent. Is anything lost?</summary>

Not at the gateway. But spans can still be lost before it (SDK queues, apps
that exit) and won't appear in any gateway counter. Watch freshness, and run a
synthetic trace end to end.
</details>

<details><summary>The health check shows <code>WARN 1 S3 request errors since start</code>. Is S3 broken?</summary>

Not necessarily. The line compares an all-time total with zero, so one error
hours ago keeps it at WARN until the server restarts. Group
`system.metric_log` by hour as in lab 1. If the recent hours are empty, it's
history; if they're rising, check credentials and the endpoint.
</details>

<details><summary>You stop only <code>clickhouse-01</code>, and the gateway queue stays at 0. Why? (mixes module 7)</summary>

The exporter's endpoint lists both nodes. When one is down, the client
connects to the other and inserts keep succeeding; `clickhouse-01` catches up
through replication when it returns.
</details>

<details><summary>Your team stores the gateway's metrics in the same ClickHouse cluster and alerts from there. What goes wrong?</summary>

When ClickHouse is down, the metrics and the alerts go with it, so the outage
you most need to hear about is silent. Store self-monitoring separately, and
add an always-firing "dead man's switch" alert so silence itself pages.
</details>

<details><summary>With S3 tiering on, you backfill last month's spans with <code>remote()</code>, and S3 write errors start rising. Are live spans from the gateway at risk? (mixes modules 10 and 11)</summary>

Not directly. Move rules apply at insert time, so only the backfilled rows,
already past the move age, go straight to S3; that `INSERT` fails and reports
it to whoever runs it. Live spans are seconds old and land on local disk, so
`lost` and freshness stay OK. The risk comes later: if background moves keep
failing, the local disk fills.
</details>

<details><summary>The health check says <code>newest span 900s old</code>, but everything else is OK. What's the likely cause?</summary>

Nothing is being sent. Check whether the traffic loop is paused
(`./stack.sh status`). If traffic is on and the gateway's accepted counter
isn't rising, the apps can't reach the gateway: look at their logs for
export errors.
</details>

<details><summary>A replacement server with the old name fails with <code>REPLICA_ALREADY_EXISTS</code>. What do you run, and where?</summary>

`SYSTEM DROP REPLICA 'clickhouse-03' FROM DATABASE otel`, on a **live**
server: Keeper still holds the dead replica's entry. Then create the tables
again with the same UUIDs (`add-replica.sh`), and the new server fetches all
parts from its peers.
</details>

<details><summary>You must move spans to S3 after 12 hours instead of 1 day, on a 20 TB table. Why not just run <code>MODIFY TTL</code>?</summary>

By default it rewrites every partition to apply the new rule
(`materialize_ttl_after_modify = 1`): hours of disk and S3 I/O at once. Set
it to 0, then `MATERIALIZE TTL IN PARTITION` one day at a time, and repeat
the delete rule in the new TTL, because `MODIFY TTL` replaces the whole TTL.
</details>

<details><summary>Disk at 12% free on one server at 3 a.m. What do you try first?</summary>

The cheap and safe things: empty or put a TTL on ClickHouse's own log tables
(they have none by default), drop detached parts you've checked, move old
partitions to S3. Then grow the volume, which takes minutes and no restart.
Dropping partitions comes last: on a replicated table it removes them from
every replica.
</details>

## Next

You've now seen every piece of the pipeline, from the first span to the
on-call screen. [Module 13](13-cheat-sheet.md) pulls it all together: one
request followed end to end, a cheat sheet and glossary, and interview and
design review questions to test yourself.

## Read more

- [Metrics reference appendix](appendix-metrics-reference.md): every metric
  per component, and every health check line
- [Collector internal telemetry](https://opentelemetry.io/docs/collector/internal-telemetry/)
- [Collector scaling](https://opentelemetry.io/docs/collector/scaling/)
- [ClickHouse monitoring](https://clickhouse.com/docs/operations/monitoring)
- [ClickHouse Prometheus endpoint](https://clickhouse.com/docs/operations/server-configuration-parameters/settings#prometheus)
- [`system.metric_log`](https://clickhouse.com/docs/operations/system-tables/metric_log), [`system.query_log`](https://clickhouse.com/docs/operations/system-tables/query_log)
- [Backup and restore](https://clickhouse.com/docs/operations/backup)
- [Runbooks appendix](appendix-runbooks.md): every runbook, with its sources
- [ClickHouse: self-managed upgrade](https://clickhouse.com/docs/operations/update)
- [ClickHouse Keeper, including recovery after losing quorum](https://clickhouse.com/docs/guides/oss/deployment-and-scaling/keeper)
- [Prometheus: metric types](https://prometheus.io/docs/concepts/metric_types/)
- [Google SRE book: service level objectives](https://sre.google/sre-book/service-level-objectives/)
- [Google SRE workbook: alerting on SLOs](https://sre.google/workbook/alerting-on-slos/)

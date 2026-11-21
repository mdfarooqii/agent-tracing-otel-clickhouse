# Module 12: Operational readiness, from gateway to ClickHouse (50 min)

## Why this matters

The tracing pipeline you built is a production system in its own right. If it
quietly loses spans, nobody notices until someone opens a trace during an
incident and half of it is missing. [Module 11](11-s3-tiering.md) added the
last moving part, S3. This module asks how you know, day to day, that the
whole pipeline is healthy.

By the end, you'll be able to name the few signals that matter, read the
repo's one-screen health check (including its blind spots), rehearse two
outages and watch the check catch them, and size and run the pipeline like a
service with its own targets. The full per-component catalogue is in the
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

## Remember it

> **Fresh, complete, keeping up, usable.** Every alert answers one of those.
> **The books must balance**: accepted = filtered + sent + queued + failed.
> And **a total is history; the rate is news**.

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
- **Runbooks**: Keeper down, replica lost, too many parts, disk full, gateway
  queue full, S3 errors. Lab 2 rehearses two of them.

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
> second and bytes per span, and rehearse runbooks as game days."

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
- [Prometheus: metric types](https://prometheus.io/docs/concepts/metric_types/)
- [Google SRE book: service level objectives](https://sre.google/sre-book/service-level-objectives/)
- [Google SRE workbook: alerting on SLOs](https://sre.google/workbook/alerting-on-slos/)

# Module 12: Operational readiness, from gateway to ClickHouse (45 min)

## Why this matters

The tracing pipeline you built is a production system in its own right. If it
quietly loses spans, nobody notices until someone opens a trace during an
incident and half of it is missing. [Module 11](11-s3-tiering.md) added the
last moving part, S3. This module asks how you know, day to day, that the
whole pipeline is healthy.

By the end, you'll be able to name the few signals that matter, read the
repo's one-screen health check (including its blind spots), rehearse two
outages and watch the check catch them, and work through a production
readiness checklist. The full per-component catalogue is in the
[metrics reference appendix](appendix-metrics-reference.md).

## Key terms

| Term | Plain meaning |
|---|---|
| **Operational readiness** | Being able to run a system day to day: you know when it's unhealthy, why, and what to do, before users tell you |
| **Counter** | A metric that only goes up from when the program started, like a car's odometer |
| **Gauge** | A metric that goes up and down, like a fuel gauge: queue size, memory, free disk |
| **Rate** | How much a counter grew per second over a time window. For counters, the rate is what you watch |
| **Alert** | An automatic message to a person when a metric crosses a threshold for long enough |
| **SLI and SLO** | A service level indicator measures what users experience ("age of the newest span"); a service level objective is the target for it ("under 2 minutes, 99.9% of the time") |
| **Saturation** | How full a resource is: a queue at 90% of capacity, or a disk with 5% free. One more push and something fails |
| **Back-pressure** | A busy component telling the sender "not now, try later" instead of crashing |
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

Think of a car. Driving it is one skill. Knowing that the oil light means
"stop soon", and having a spare tire and the steps to change it, is another.
That second skill is operational readiness. For this pipeline, it means:

1. **You can see its health.** You know which metrics matter.
2. **You hear about trouble early.** Alerts fire before data is lost.
3. **You know what to do.** Each likely failure has a runbook, and you've
   practiced it. The labs in modules [4](04-collector.md) (gateway down),
   [7](07-clickhouse.md) (Keeper and a replica down),
   [10](10-copying-data.md) (adding a replica) and [11](11-s3-tiering.md)
   (S3) are those practice runs.

Without it, the most common failure of a tracing system is silent: spans stop
arriving, or arrive incomplete, and nobody finds out until they need them.

### Metrics, alerts and SLOs in plain words

A **metric** is a named number. **Counters** only go up:
`otelcol_exporter_sent_spans_total` is "spans written to ClickHouse since the
gateway started". Its total tells you little; its **rate** tells you a lot. If
it stops rising, nothing is being written. **Gauges** go up and down:
`otelcol_exporter_queue_size` is "batches waiting right now". Counters reset
to zero on restart; monitoring tools like Prometheus (a popular system that
fetches metrics every few seconds and stores them) handle that.

An **alert** is a rule over a metric: "if the gateway's queue is more than
half full for 5 minutes, message the on-call person." Good alerts fire
**before** users are hurt, and they **mean something**, so people don't learn
to ignore them. An **SLO** turns "is it OK?" into a yes or no question. Two
examples (not values from this repo): the newest span is under 2 minutes old
99.9% of the time; p95 trace lookup time (95% of queries are faster) is under
1 second.

### Four questions every metric answers

| Question | Plain words | How to measure it here |
|---|---|---|
| **Is data arriving?** (freshness) | Are new spans showing up? | Age of the newest span: `dateDiff('second', max(Timestamp), now())` on `otel.otel_traces` |
| **Is data complete?** (loss) | Are spans going missing on the way? | Gateway refused, lost and filtered counters; SDK export errors in app logs |
| **Is it keeping up?** (saturation) | Is anything running out of room or falling behind? | Gateway queue; `system.replicas`, `system.parts`, `system.disks` |
| **Can people use it?** (query health) | Do queries come back quickly and without errors? | `system.query_log` |

`Timestamp` is a `DateTime64` (time with fractions of a second), so use
`dateDiff('second', ...)` to get a plain number of seconds rather than
subtracting it from `now()`.

### Where spans can be lost

Follow the HR agent's "I need a new laptop" request
([module 13](13-cheat-sheet.md) retells it end to end). Its spans travel:

```text
 app SDK ──▶ gateway receiver ──▶ processors ──▶ export queue ──▶ ClickHouse ──▶ Keeper
    │              │                    │               │               │            │
 queue full,   memory limiter      filter drops     queue full,     too many     down: tables
 process exits refuses data        (by design)      exporter        parts,       go read-only
 (lost)        (app must retry)                     gives up        disk full,
                                                    (lost)          read-only
```

1. **App SDK.** Holds finished spans in memory (2048 by default). If the
   gateway is unreachable for long, the queue fills and spans are dropped; if
   the process exits first, they're gone. No gateway counter sees this.
2. **Gateway receiver.** Near its memory limit, `memory_limiter` refuses new
   data; the app retries, but its own queue may fill.
3. **Processors.** `filter/require_org_labels` drops spans without
   `org.owner` or `org.service`: loss by design, like the laptop request's
   `legacy-hr-api` span ([module 4](04-collector.md)).
4. **Export queue.** Batches wait for ClickHouse; ones that can't be written
   within 300 s (`max_elapsed_time`) are dropped.
5. **ClickHouse** can reject inserts (too many parts, disk full, memory), and
   **Keeper** down makes tables read-only, so the gateway queues and retries.

### Queues, back-pressure and lag

Picture a coffee shop. A **queue** is the line: one that comes and goes is
healthy; one that keeps growing means the barista can't keep up. The
gateway's export queue holds up to 1000 batches (the default; the config sets
no `sending_queue`). **Back-pressure** is the sign on the door, "full, come
back in five minutes": better than collapsing. That's `memory_limiter`.
**Lag** is how far behind the second barista is: if the second replica is 90
seconds behind, queries sent to it miss the last 90 seconds of spans.

### The books must balance

The gateway counts every way a span can leave it. Like a bank statement:

**accepted = filtered + sent + still in queue or batch + failed**

Accepted is what the receiver took in; filtered, what the label filter
dropped; sent, what reached ClickHouse; in queue or batch, what's waiting (the
`batch` processor holds spans up to 5 s); failed, what the exporter gave up on
or found the queue full. If the numbers don't add up over time, something is
losing data in a way no counter shows.

### The ten signals that matter most

The [appendix](appendix-metrics-reference.md) lists dozens of metrics. These
ten cover the four questions:

| Question | Signal | Where | Bad looks like |
|---|---|---|---|
| Arriving | Age of the newest span | `dateDiff('second', max(Timestamp), now())` | Over 2 minutes while traffic runs |
| Arriving | Spans accepted | `otelcol_receiver_accepted_spans_total` (rate) | Drops to zero while apps run |
| Complete | Spans lost | `otelcol_exporter_send_failed_spans_total` + `otelcol_exporter_enqueue_failed_spans_total` (rate) | Any increase |
| Complete | Spans refused | `otelcol_receiver_refused_spans_total` (rate) | A sustained rate |
| Complete | Spans filtered | `otelcol_processor_filter_spans_filtered_total` (rate) | A sudden step up: a service lost its labels |
| Keeping up | Export queue fill | `otelcol_exporter_queue_size` / `_capacity` | Over half full, or growing for minutes |
| Keeping up | Parts per partition | `MaxPartCountForPartition` | Over 300 and rising (delays at 1000, rejects at 3000) |
| Keeping up | Read-only replicas, lag | `is_readonly`, `absolute_delay` in `system.replicas` | Any read-only table; lag over 60 s |
| Keeping up | Local disk free | `free_space / total_space` in `system.disks` | Under 15% |
| Usable | Query latency and errors | `system.query_log`, `system.errors` | p95 over your SLO; new error names |

A note on "lost". `send_failed` counts spans the exporter **gave up on**, not
only retries that ran out. Retryable errors (ClickHouse down, a timeout) are
retried for up to 300 s; errors an exporter marks as permanent are dropped at
once. Either way, an error that retrying can't fix, such as a schema mismatch
between the exporter and the table, fails every batch until you fix the cause.

### Totals versus rates

The rule for counters is "watch the rate", and the health check you'll run
next doesn't fully follow it. For four lines it compares the **total since
start** with zero: `refused` and `lost` on the gateway, delayed or rejected
inserts and S3 request errors on ClickHouse. So a single blip, say one failed
S3 request at 5 a.m., keeps that line at WARN or FAIL until the gateway or
server restarts, even if nothing has gone wrong since.

That's a simplification: a script that runs once has no history to compute a
rate from. When one of those lines isn't OK, your next question is "is it
still rising?". Lab 1 shows two ways to answer it. A real monitoring setup
(Prometheus scraping the gateway, alerting on the rate) answers it for you.

## Remember it

> **Fresh, complete, keeping up, usable.** Every alert answers one of those.
> **The books must balance**: accepted = filtered + sent + queued + failed.
> And **a total is history; the rate is news**.

## In this repo

- `otel-gateway-config.yaml`: the gateway publishes its own metrics on port
  8888, mapped to <http://localhost:18888/metrics>; `health_check` answers on
  13133. `memory_limiter.limit_mib` is 512, `max_elapsed_time` is 300 s, and
  the exporter's `endpoint` lists both ClickHouse nodes.
- `compose.yaml` sets **no container memory limits**. The gateway's only
  memory cap is `memory_limiter`. Each ClickHouse server sets its own limit
  (`max_server_memory_usage`, 90% of RAM by default) from the whole Docker
  machine's RAM, which both servers and the gateway share, so "memory N% of
  the server limit" is optimistic here. In production, set container limits
  (gateway: about 20% above `limit_mib`).
- `docs/tutorial/labs/health-check.sh` (also `./stack.sh health`): one screen
  covering the gateway, Keeper and both ClickHouse nodes. It reads the
  metrics page with `curl`, talks to Keeper on port 9181, and runs SQL on each
  node with `docker exec`. Thresholds are demo starting points. Every line is
  explained in the
  [appendix](appendix-metrics-reference.md#the-health-check-line-by-line).

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

- **Capacity**: measure spans per second and bytes per span (stretch
  exercise A) and size disk for retention plus 30%; size the gateway queue for
  the longest ClickHouse outage you'll accept; set container memory limits
  (this demo sets none).
- **Redundancy**: 2 or more gateways behind a load balancer; 3 Keepers; 2 or
  more ClickHouse replicas per shard, on separate hosts or zones.
- **Durability**: a persistent gateway queue (`sending_queue.storage` with
  `file_storage`); ClickHouse backups (`BACKUP ... TO S3(...)`) with a restore
  you've actually tested.
- **Security**: TLS on OTLP and the ClickHouse ports; no passwords in config
  files (this demo's `demo` password is for a laptop only); separate
  ClickHouse users, so the gateway can only insert and readers can only read,
  with quotas.
- **Watching the pipeline itself**: scrape the gateway (`:8888`) and
  ClickHouse (`:9363`, once enabled) into Prometheus; alert on the **rate** of
  the ten signals, not all-time totals; send a synthetic trace (a fake request
  just to check it arrives) every minute and alert if it doesn't.
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

### Stretch exercises (optional)

**A. Size the disk from your own data.** Bytes per row, then spans per second
over the last 10 minutes (needs the traffic loop running):

```sql
SELECT table, sum(rows) AS n,
       round(sum(data_compressed_bytes) / n) AS bytes_per_row_on_disk,
       round(sum(data_uncompressed_bytes) / n) AS bytes_per_row_raw
FROM system.parts WHERE database = 'otel' AND active GROUP BY table;

SELECT round(count() / dateDiff('second', min(Timestamp), max(Timestamp)), 1) AS spans_per_second
FROM otel.otel_traces WHERE Timestamp > now() - INTERVAL 10 MINUTE;
```

A test run measured 54 bytes per span on disk (615 raw) at 3.5 spans per
second; real spans are often several times larger. Then
`disk = spans/s x bytes/span x 86400 x retention days x replicas x 1.3`
(86400 seconds a day, 30% headroom). For example, 1000 spans per second at
300 bytes, kept 3 days on 2 replicas, is roughly 200 GB.

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

> "Operating the pipeline means answering four questions: is data fresh, is
> it complete, is the system keeping up, and can people query it. Spans can be
> lost in the SDK, at the gateway's memory limiter, when the exporter gives
> up, and in ClickHouse or Keeper. About ten signals cover it: freshness, the
> gateway's accepted, lost, refused and filtered counters and its queue, parts
> per partition, read-only replicas and lag, disk, and query health. For
> counters I watch the rate: the health check flags some lines from all-time
> totals, so WARN there means 'check whether it's still rising'. Readiness
> adds redundancy, persistent queues, tested backups, memory limits, security,
> and a rehearsed runbook for each failure."

## Recap

- Readiness: see the pipeline's health, hear about trouble early, know what
  to do.
- Four questions (fresh, complete, keeping up, usable), about ten signals;
  the appendix has the rest.
- SDK loss shows up only as freshness. The gateway's books must balance, and
  `send_failed` means the exporter gave up: after retries, or at once for
  permanent errors.
- Counters: watch the rate. The health check's `refused`, `lost`, delayed
  inserts and S3 lines are all-time totals; use `system.metric_log` or two
  samples to see whether they're still rising.
- This repo sets no container memory limits, so its memory percentages are
  optimistic.
- The exporter fails over between ClickHouse nodes, so the gateway queue only
  grows when both are down.

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

<details><summary>Why is <code>otelcol_exporter_send_failed_spans_total</code> the most important alert?</summary>

It counts spans the exporter dropped for good, after retries ran out or at
once for permanent errors. Other signals warn that loss may come; this one
says it happened.
</details>

<details><summary>You stop only <code>clickhouse-01</code>, and the gateway queue stays at 0. Why?</summary>

The exporter's endpoint lists both nodes. When one is down, the client
connects to the other and inserts keep succeeding; `clickhouse-01` catches up
through replication when it returns.
</details>

<details><summary>The health check says <code>memory 5% of the server limit</code>. Is there plenty of headroom?</summary>

Less than it looks. `compose.yaml` sets no container memory limit, so each
ClickHouse server sets its limit from the whole Docker machine's RAM, which
both servers and the gateway share.
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
request followed end to end, a cheat sheet and glossary, and interview-style
questions to test yourself.

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

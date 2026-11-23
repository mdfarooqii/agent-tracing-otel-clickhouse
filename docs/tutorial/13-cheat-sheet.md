# Module 13: Cheat sheet, glossary and interview questions (40 min, plus the glossary as a reference)

## Why this matters

This is the last page of the course. It recaps all twelve modules as one
story: a user of the HR agent types "I need a new laptop", and you follow that
request from the first span to a row in ClickHouse, a copy on another server,
a part on S3, and the on-call screen that proves none of it was lost.

What you'll be able to do: explain the whole pipeline out loud in about five
minutes, answer interview and design review questions about it, and look up
any term quickly when you go back to a module.

## Key terms

Nothing new here: every term from the course is in the
[glossary](#glossary-a-to-z) at the end of this page, with the module that
explains it.

## How to use this page

Close the other modules. Explain each section out loud, then check yourself
against the text. If you stumble, go back to that module's "Explain it back"
section. Use the glossary whenever a word in any module isn't clear.

## The whole system in one breath

> "A user asks the HR agent 'I need a new laptop', and that turn is one trace,
> rooted at `agent_turn`. LangChain callbacks report each graph node, model
> call and tool call, and our tracer turns them into spans named by the GenAI
> conventions: `invoke_workflow`, `invoke_agent`, `chat`, `execute_tool`. The
> SDK batches spans and sends OTLP to a Collector gateway, which drops
> unlabelled spans, stamps platform labels, batches, and retries into
> ClickHouse. If we sample, it's parent-based at the head or trace-routed at
> the tail. The tools pass `traceparent` and `baggage`, so `ticket-api`'s
> spans join the same trace, in any environment. ClickHouse stores one row
> per span in sorted, compressed daily parts, replicated through Keeper. The
> schema promotes hot attributes into real columns and fills a trace lookup,
> a request list and a per-minute rollup. To scale out, we shard by a hash of
> the trace id, so each trace stays on one shard. A new replica copies itself
> through Keeper; other servers copy with `remote()` over an overlapping
> window. Old parts move to S3. And we know it's healthy because spans are
> fresh, the gateway's books balance, and we page on symptoms."

That's the short version. Below is the same story slowly.

## The whole system in five minutes

Think of the request as a parcel: it's made, labelled, shipped, sorted,
shelved, copied and archived, and the tracking number (the trace id) stays the
same the whole way.

```mermaid
sequenceDiagram
    participant U as User
    participant A as hr-agent (run.py + LangGraph)
    participant L as legacy-hr-api
    participant T as ticket-api
    participant G as otel-gateway (Collector)
    participant C as ClickHouse (2 replicas)
    participant K as Keeper
    U->>A: "I need a new laptop."
    Note over A: root span agent_turn<br/>baggage: tenant, request id
    A->>L: GET /employees/{id} + traceparent
    A->>T: POST /v1/tickets + traceparent
    A-->>G: OTLP: batch of finished spans
    L-->>G: OTLP: its spans
    T-->>G: OTLP: its spans
    Note over G: memory check, label filter,<br/>platform labels, batch
    G->>C: INSERT (one batch = one part)
    C->>K: "new part exists"
    Note over C: replica 2 fetches the part<br/>from replica 1
```

**1. The turn starts, and the trace is born** ([module 1](01-otel-core.md)).
`agent/run.py` opens a span called `agent_turn`. It's the **root span**: it
has no parent, and it gets a fresh **trace id** that every other span of this
request shares. `run.py` puts the tenant (for example `acme_corp`) and a
request id into **baggage**, data that travels with the request. The
process's **resource** says who is reporting: `service.name = hr-agent`,
`org.owner = people-tech`, `org.service = hr-agent`. Attributes passed in code
win; `OTEL_RESOURCE_ATTRIBUTES` can only add keys.

**2. The agent graph runs, and callbacks become spans** ([module 2](02-langgraph.md)).
The HR agent is a small **LangGraph** graph called `hr_helpdesk`, with one
node, `hr_assistant`. As it runs, LangChain fires **callbacks** ("I started",
"I finished") with a run id and a parent run id. The repo's
`LangGraphTracer` opens a span for each one that matters, and makes the tool
span current, so HTTP calls inside the tool become its children.

**3. The spans get standard names** ([module 3](03-genai-semconv.md)).
The **GenAI semantic conventions** name each span and its attributes:

```text
agent_turn                                  root, from run.py
  invoke_workflow hr_helpdesk               the graph run
    invoke_agent hr_assistant               the agent node
      execute_tool lookup_employee          tool call
        GET /employees/{employee_id}        HTTP client span
      chat fake-hr                          LLM call: model, tokens
      execute_tool create_ticket            tool call
        POST /v1/tickets                    HTTP client span
```

Token counts go on the `chat` span only, so totals are never counted twice.

**4. Each process ships its spans, and the gateway sorts them** ([module 1](01-otel-core.md), [module 4](04-collector.md)).
Spans are exported when they *end*. The SDK's `BatchSpanProcessor` queues
finished spans in memory (2048 at most) and sends a batch over **OTLP/HTTP**
to the gateway at `localhost:14318` every 5 seconds; `provider.shutdown()`
sends the rest on exit. The gateway, an **OpenTelemetry Collector**, runs four
**processors** in order:

- `memory_limiter`: refuses data when memory is high (**back-pressure**). Not
  a loss yet: the SDK retries.
- `filter/require_org_labels`: drops spans whose resource lacks `org.owner`
  or `org.service`. `legacy-hr-api` puts its labels in the wrong place, so
  its server span is **dropped**; the agent's client span survives.
- `resource/org_platform`: stamps where the gateway runs: `org.env`,
  `org.region`, `org.platform`, `org.cluster`.
- `batch`: bundles spans, up to 1000 or 5 seconds, so ClickHouse gets few,
  large inserts.

The `clickhouse` **exporter** then writes each batch through a **sending
queue** (1000 batches, in memory) and retries for up to 300 seconds. A full
queue or an expired retry drops data silently; only `memory_limiter` pushes
back on the apps.

**5. Sampling decides what's kept** ([module 5](05-sampling.md)).
This repo keeps everything. At scale, a **parent-based head sampler** decides
when `agent_turn` starts, and the decision travels in `traceparent`'s flags,
so `ticket-api`, also parent-based, follows it. Or a **tail sampler** in a
Collector decides after the whole trace arrives, keeping errors and slow
turns, as long as every span of a trace reaches the same instance. A Collector's `probabilistic_sampler` is
neither: the apps already sent every span.

**6. The trace crosses services and environments** ([module 6](06-cross-environment.md)).
Before each tool's HTTP call, the agent **injects** `traceparent` (trace id,
plus its client span id as the new parent) and `baggage`. `ticket-api`
**extracts** them and starts a **server span** under the agent's client span,
then records `INSERT tickets` for its database call. No merging later: the
same trace id is passed along. If `ticket-api` runs in another environment,
its own gateway stamps its `org.env`, which you trust over the app's own
`deployment.environment.name`, and the trace still joins as long as no proxy
strips the headers.

**7. ClickHouse shelves the spans, and Keeper keeps the replicas in step** ([module 7](07-clickhouse.md)).
Each span becomes **one row** in `otel.otel_traces`, a **column store** where
each column is compressed on its own. The insert creates a **part**, sorted
by `(org_owner, org_service, SpanName, time)`, inside today's **partition**;
background **merges** combine small parts. The gateway writes to one
replica, say `clickhouse-01`, which tells **Keeper** "a new part exists", and
`clickhouse-02` downloads it from its peer. Keeper is the notary, never the
warehouse. If Keeper is down, tables go **read-only**: reads work, and the
gateway queues and retries.

**8. The schema does the extra work at insert time** ([module 8](08-data-model.md)).
The exporter writes the **stock columns**; **MATERIALIZED columns** copy hot
attributes (owner, agent name, tokens) out of the maps into real columns.
Three **materialized views** fire on each insert: a trace-id lookup table, the
request list `trace_entry`, and the per-minute rollup `span_red_1m`. The
laptop request lands in `trace_entry` twice (`agent_turn` and `ticket-api`'s
entry span); `ReplacingMergeTree(IsRoot)` keeps the root's row, and `FINAL`
shows one row per request now. `span_red_1m`'s counts are
`SimpleAggregateFunction(sum, ...)`, so rows add up on merge. **TTL** deletes
raw spans after 72 hours.

**9. Someone looks at the trace** ([module 9](09-sharding-indexes.md)).
A query asks for `WHERE TraceId = '...'`. The trace id isn't in the sorting
key, so a **bloom filter skip index** skips blocks that can't contain it, and
the lookup table says when the trace happened, so other days are skipped. At
larger scale, rows are **sharded** by `cityHash64(TraceId)`, so the whole
trace still sits on one shard.

**10. The cluster grows, and other servers get copies** ([module 10](10-copying-data.md)).
Disks grow in place, or a new disk joins through a storage policy that
contains the old one. A new shard gets new rows only; nothing moves, and the
shards even out as old data ages out. Readers, ClickStack included, query
the `Distributed` table (`otel_traces`), never a shard's local table, with
`readonly = 2` accounts and a cluster `<secret>` so row policies apply on
every shard. A third server that creates the same table with its own `{replica}` name
registers in Keeper and fetches every part from its peers. A server with its
own Keeper pulls rows with `INSERT ... SELECT FROM remote(...)`. To keep
copying, each run re-reads an **overlapping window** (10 minutes before its
newest span, because `agent_turn` and retried batches arrive late) and skips
spans it already has with `GLOBAL NOT IN`.

**11. A day later, the laptop request moves to S3** ([module 11](11-s3-tiering.md)).
With tiering on, once its day's partition is past the move age (1 day in the
lab), a **TTL move** copies its parts to the `cold` volume (S3, through a
local cache disk), and queries read them as before. Rows that are already
old when inserted, like a backfill, are written straight to S3. The `DELETE` rule still removes them after 72 hours.

**12. On-call proves nothing was lost** ([module 12](12-operations.md)).
`./stack.sh health` shows the request's spans are fresh, the gateway's books
balance (accepted = filtered + sent + queued + failed), queues and parts are
under control, replicas are in sync, and Keeper answers. In production, SLOs
on delivery, freshness and query latency page a person only on symptoms.

## One line per module

| # | Concept | One line |
|---|---|---|
| 1 | Span, trace, context | A span is a timed operation with a parent; a trace is all spans sharing a trace id; context is the current span, and `traceparent` carries it between processes |
| 1 | Resource versus attributes | The resource says *who* sent the span (set once per process); attributes say *what* happened |
| 2 | Callbacks to spans | LangChain reports every step with run ids; the tracer maps run ids to spans and makes tool spans current |
| 3 | GenAI semconv | Standard `gen_ai.*` names for operation, agent, model, tool and tokens; still in development |
| 4 | Collector | Receivers, processors in order, exporters; the queue and retries live in the exporter, and only `memory_limiter` pushes back |
| 5 | Head and tail sampling | Decide at the start (cheap, blind, parent-based) or after the trace ends (smart, costly, one instance per trace) |
| 6 | Across environments | The trace joins only if every hop passes `traceparent`; trust the gateway's `org.env` over the app's claim |
| 7 | ClickHouse storage | An insert makes a part, parts merge; sparse index on `ORDER BY`; daily partitions for retention; Keeper coordinates replicas |
| 8 | Data model | Stock columns from the exporter, MATERIALIZED columns for speed, three views for lookup, request list and rollup |
| 9 | Sharding and indexes | Replicas are copies, shards are slices: hash the trace id; skip indexes say "not here", never "here" |
| 10 | Copying data | Same Keeper: let replication copy. Different Keeper: `remote()`, looking back further than spans can be late |
| 11 | S3 tiering | Disks are shelves, the policy orders them, TTL moves whole parts once their newest row is old enough |
| 12 | Operations | Fresh, complete, keeping up, usable; the books must balance; a total is history, the rate is news |

## Where things fail, and what you lose

"Loss" means spans that never reach ClickHouse. This matches the loss story
in [module 4](04-collector.md) and the signals in [module 12](12-operations.md).

| Failure | Symptom | Loss |
|---|---|---|
| Gateway unreachable | `Failed to export spans batch` in the app's log | Spans in an SDK queue that fills (2048) or a process that exits. No gateway counter sees it (module 4 lab) |
| Gateway memory high | `refused` rising | Nothing yet: the SDK keeps the spans and retries |
| Service missing `org.*` labels | `filtered` steps up | That service's spans, by design |
| ClickHouse or Keeper down, under 300 s | `Code: 242` read-only, gateway queue grows | Nothing (module 7 and 12 labs) |
| ClickHouse or Keeper down, over 300 s | `send_failed` rising | Batches whose 300 s of retries ran out |
| Export queue full (1000 batches) | `enqueue_failed` rising; apps see no error | Every new batch, silently |
| Gateway restart or crash | Counters reset to 0 | Everything in the `batch` processor and in-memory queue |
| Too many parts | `DelayedInserts` at 1000 parts per partition, `Too many parts` at 3000 | Nothing while delayed; rejected inserts are retried, then count as `send_failed` |
| Local disk full | Inserts and merges fail | Like ClickHouse down: retries, then `send_failed` |
| S3 errors | `S3WriteRequestsErrors`, `S3ReadRequestsErrors` rising | Live spans: nothing, they land locally. Moves stall and the disk fills later; backfills and cold reads fail |
| One replica down | `active_replicas = 1` | Nothing; it catches up |
| Proxy strips headers | Every API span is a root | The trace's continuity |
| Non-parent-based sampler downstream | Orphan spans | Trace completeness |
| Tail sampling across gateways without trace-id routing | Fragmented traces | Trace completeness |

## Commands you should know by heart

The stack controls. `up` starts everything (add `--no-traffic` to skip the
background traffic), `down --wipe` also deletes the data, `status` shows
spans per service, `demo` runs one round of traffic, `queries` runs the saved
SQL, `logs` follows the traffic loop, and `health` runs the module 12 check:

```bash
./stack.sh up | down [--wipe] | status | demo | queries | logs | traffic on|off | health
```

Head sampling is set from the environment only. This keeps 30% of new
traces, and children follow their parent:

```bash
OTEL_TRACES_SAMPLER=parentbased_traceidratio OTEL_TRACES_SAMPLER_ARG=0.3 .venv/bin/python simulate.py
```

Tail sampling on, by merging a second config file into the gateway, and then
off again:

```bash
docker compose -f compose.yaml -f docs/tutorial/labs/compose.tail-sampling.yaml up -d otel-gateway
docker compose up -d otel-gateway
```

Five queries worth knowing:

```sql
-- One trace in order (Duration is in nanoseconds)
SELECT ServiceName, SpanKind, SpanName, Duration / 1e6 AS ms FROM otel.otel_traces WHERE TraceId = '...' ORDER BY Timestamp;

-- Recent requests, one row each, led by the root span
SELECT Start, org_request_id, org_service, Duration / 1e6 AS ms, StatusCode FROM otel.trace_entry FINAL WHERE org_request_id != '' ORDER BY Start DESC LIMIT 10;

-- Replication health: read-only, tasks waiting, seconds behind, copies online
SELECT table, is_readonly, queue_size, absolute_delay, active_replicas FROM system.replicas WHERE database = 'otel';

-- Parts per day (keep it well under 1000)
SELECT partition, count() AS parts, sum(rows) FROM system.parts WHERE table = 'otel_traces' AND active GROUP BY partition;

-- Does my index skip anything?
EXPLAIN indexes = 1 SELECT count() FROM otel.otel_traces WHERE ...;
```

## Memory hooks

- **Parcel route**: make, label, ship, sort, shelve (SDK, resource, OTLP, Collector, ClickHouse).
- **Family tree**: trace id is the surname, span id the first name, parent id the parent.
- **Letter of introduction**: `traceparent` is the letter you carry into the next service.
- **Luggage**: baggage travels with you, but nobody unpacks it unless they choose to.
- **Mailroom**: drop the junk mail first, bundle last; the loading dock is the queue.
- **Bouncer and reviewer**: head sampling judges at the door; tail sampling after the party.
- **Passport**: a trace crosses environments only if `traceparent` gets through every border.
- **Lego bricks**: each insert is a brick (a part); merges glue them; too many small bricks jam it.
- **Notary, not warehouse**: Keeper records which parts exist; replicas ship the parts to each other.
- **The root wins**: in `trace_entry`, the highest `IsRoot` survives, so the turn describes the request.
- **Same house**: hash the trace id, and the whole family lives on one shard.
- **"Not here" sign**: a skip index skips granules; it never finds rows.
- **Look back before you copy**: re-read further back than spans can be late.
- **Shelves in a warehouse**: a box moves to the cheap back shelf once everything in it is old.
- **Bank statement**: accepted = filtered + sent + queued + failed.

## Recap

- One user turn is one trace, rooted at `agent_turn`; callbacks become GenAI
  spans, and `traceparent` carries the trace into each API, in any
  environment.
- The SDK batches spans to the gateway; the gateway filters, labels, batches
  and writes with a queue and retries. Loss is silent except through
  counters, so the books must balance.
- ClickHouse stores one row per span in sorted daily parts, replicated
  through Keeper; MATERIALIZED columns and three views do work at insert time.
- At scale: sample consistently, shard by trace id, copy with replication or
  `remote()`, tier old parts to S3, and run the pipeline against its own SLOs.

## Interview-style questions

Answer them without notes, then check. They follow the module order.

<details><summary>How does an API in another process know which trace it belongs to? (modules 1, 6)</summary>

The caller's client span injects `traceparent` (trace id, its own span id,
sampled flag) into the HTTP headers; the API extracts it and starts its
server span as a child of that client span.
</details>

<details><summary>What's the difference between the resource and an attribute? (module 1)</summary>

The resource says who sent the span (service name, owner), and is set once
per process. Attributes say what happened in this one operation (status code,
model, tool name).
</details>

<details><summary>Where should token counts go, and why there? (module 3)</summary>

On `chat` spans only, as `gen_ai.usage.*`. Recording them once, where they
happen, means sums over agents or turns don't count anything twice.
</details>

<details><summary>In the HR agent's turn, why is there a <code>GET /employees/{employee_id}</code> client span but no matching server span in ClickHouse? (module 4)</summary>

`legacy-hr-api` puts `org.owner` and `org.service` on its span attributes
instead of its resource. The gateway's `filter/require_org_labels` processor
drops spans whose resource lacks those labels, so only the agent's client
span is stored.
</details>

<details><summary>Why does the gateway batch spans before ClickHouse? (modules 4, 7)</summary>

Every insert creates a part. Many small inserts create parts faster than
merges can combine them, leading to "too many parts" errors and slow queries.
</details>

<details><summary>Your tail sampler keeps half-traces. What's the likely cause? (module 5)</summary>

Spans of one trace are reaching different Collector instances. Route by trace
id with the `loadbalancing` exporter in front of the tail-sampling tier.
</details>

<details><summary>Keeper goes down. Can people still look at traces, and how long until spans are lost? (modules 7, 12)</summary>

Reads work; inserts into replicated tables fail (read-only), and the gateway
queues and retries. After about 300 s (`max_elapsed_time`), the batches being
retried start to be dropped. A full queue, `memory_limiter` refusals on a
busy gateway, or a gateway restart (in-memory queue) shorten that budget.
</details>

<details><summary>Why are <code>org_owner</code> and <code>gen_ai_tokens_in</code> MATERIALIZED columns, and why doesn't <code>SELECT *</code> show them? (module 8)</summary>

Reading a value out of the attribute map means decompressing the whole map,
and the value is a string. A real column is small, typed (tokens can be
summed), and can be in the sorting key or indexed. MATERIALIZED columns are
computed on insert, hidden from `SELECT *` and can't be inserted into, so the
exporter keeps inserting only the stock columns and never notices them.
</details>

<details><summary><code>trace_entry</code> shows two rows for one laptop request. Is that a bug, and which row wins? (module 8)</summary>

No. The view sees each insert on its own, and two spans match: the
`agent_turn` root (`IsRoot = 1`) and `ticket-api`'s entry span (`IsRoot = 0`).
`ReplacingMergeTree(IsRoot)` keeps the row with the highest version, the
root, when parts merge. Until then, read with `FINAL` to get one row per
request.
</details>

<details><summary>Why are <code>span_red_1m.calls</code> and <code>errors</code> <code>SimpleAggregateFunction(sum, UInt64)</code> and not plain <code>UInt64</code>? (module 8)</summary>

`AggregatingMergeTree` combines rows with the same key on merge, but only as
each column's type says. A plain `UInt64` keeps one row's value (3 and 5
merge to 3); `SimpleAggregateFunction(sum, ...)` adds them (8). Merges are
eventual, so you still read with `GROUP BY` and `sum(calls)`.
</details>

<details><summary>Why shard by trace id and not by time or service? (module 9)</summary>

Every span of a trace then lands on one shard, so trace lookups go to one
shard and per-trace work stays local, while random trace ids still spread
load evenly. Time-based sharding makes a hot shard for "now"; service-based
sharding splits traces and creates hot shards.
</details>

<details><summary>An incremental copy runs <code>WHERE Timestamp &gt; (SELECT max(Timestamp) FROM target)</code> every minute. What goes wrong, and what's the fix? (module 10)</summary>

`Timestamp` is when a span started, not when it arrived. `agent_turn` is
exported last, and retried batches land up to 300 s late, so spans that start
before the target's newest one are skipped forever. Re-read an overlapping
window (10 minutes before the watermark) and skip existing
`(TraceId, SpanId)` pairs with `GLOBAL NOT IN`, so the subquery runs on the
target, not the source.
</details>

<details><summary>Today's partition never moves to S3, though the TTL says 1 day. Yet yesterday's backfill went straight to S3. Why both? (module 11)</summary>

TTL moves whole parts once their newest row is past the age. Today's
partition keeps getting new parts, and merges keep its newest row recent.
Move rules also apply when a part is written: backfilled rows were already
older than a day, so they were written straight to the `cold` volume.
</details>

<details><summary>The gateway says accepted 10,000, filtered 200, sent 9,500, lost 0, and 250 spans are waiting. Do the books balance? (module 12)</summary>

No: 200 + 9,500 + 250 = 9,950, so 50 spans are unaccounted for. Wait a few
seconds (the `batch` processor holds spans up to 5 s) and check again. If
the gap stays, spans are being lost where no counter sees it: read the
gateway log.
</details>

<details><summary>The gateway's accepted and sent counters match, but a turn is missing in ClickHouse. Where was it lost? (modules 1, 12)</summary>

Before the gateway: in the app's SDK. Its queue filled while the gateway was
unreachable, or the process exited before sending. No gateway counter can
see that, which is why freshness checks and synthetic traces matter.
</details>

## Design review

Principal-level questions have no single right answer. Say what you'd measure
first, what breaks first, and what you'd change. The model answers show one
good line of reasoning.

<details><summary>Traffic grows 20x. What breaks first, and what do you change?</summary>

Measure first: spans per second, bytes per span, inserts per second. At this
repo's few spans per second, 20x breaks nothing. At 1000 to 20,000 spans/s:

- **Inserts and parts break first.** 20 batches a second across the fleet,
  each writing up to 4 tables and 4 Keeper entries, outpace merges. Raise
  `send_batch_size` so each gateway inserts about once a second, or use
  `async_insert`.
- **Gateway memory.** `memory_limiter` starts refusing. Add gateway replicas
  behind a load balancer; they're stateless while there's no tail sampling.
- **Keeper.** Run 3 on fast disks, away from busy ClickHouse servers.
- **Disk.** About 200 GB for 3 days becomes 4 TB. Tier to S3, sample, or
  trim large attributes.
- **Write capacity of one shard.** Add shards keyed by `cityHash64(TraceId)`;
  existing rows stay where they are.
</details>

<details><summary>A tenant demands that their spans never leave their region.</summary>

Make the region part of the pipeline, not a filter on it: an in-region
gateway, ClickHouse, S3 bucket and backups, and that tenant's apps send only
there. Don't route on `org.tenant` from baggage: a caller can set it. Exclude
the tenant from dual-writes and `remote()` copies. A global UI may query
in-region data at read time only if results may cross regions (often only
aggregates may). A call that crosses regions still shares a trace id; each
half is stored in its own region. Prove it with a recurring check: zero rows
for that tenant outside the region.
</details>

<details><summary>You need tail sampling, and you run 4 gateways.</summary>

Every span of a trace must reach the same sampler, so split into two tiers:
the 4 gateways use the `loadbalancing` exporter, routing by trace id, to a
tail-sampling tier. Costs to plan for:

- Memory: spans/s x `decision_wait` x memory per span. At 20,000 spans/s,
  10 s and roughly 1 KB, that's about 200 MB across the tier.
- Resizing the tier remaps trace ids, briefly splitting traces in flight.
- Spans that arrive after the decision.

Put `spanmetrics` before sampling so rate and error counts stay true, and
combine an error policy, a latency policy and a small probabilistic baseline.
</details>

<details><summary>The team wants full prompts and completions on every <code>chat</code> span.</summary>

Size, privacy, then cost. Prompts are kilobytes, not 50 bytes, so storage,
network and gateway memory grow 10 to 100 times. They often hold personal
data, so they need redaction, access control and shorter retention. Options:
keep content capture off by default (the GenAI conventions treat it as
opt-in), redact at the gateway, or store content in a separate table with
its own TTL and stricter grants, keeping only a reference on the span. Don't
promote it to a column; the bloom index on map values would bloat too.
</details>

<details><summary>Product wants 13 months of p95 latency per agent, and 30 days of raw traces.</summary>

Two stores with different costs. Latency trends: `span_red_1m` already keeps
a year of per-minute summaries; raise its TTL to 13 months (tiny rows; apply
`MODIFY TTL` with `materialize_ttl_after_modify = 0`, then materialize per
partition). Raw traces: size 30 days from spans/s x bytes/span x 2 replicas,
since each replica writes its own S3 copy. Keep a few days local and the rest
on S3 behind a cache disk, keep `otel_traces_trace_id_ts` for 30 days too so
lookups stay narrow, and budget for S3 request costs from merges.
</details>

<details><summary>How do you change <code>otel_traces</code>' sorting key on a live cluster without losing spans?</summary>

ClickHouse can only append newly added columns to a sorting key, so build a
new table. Create `otel_traces_v2 ON CLUSTER` with the new `ORDER BY`; add a
materialized view from `otel_traces` into it so new spans land in both;
backfill older days partition by partition with `INSERT ... SELECT`
(MATERIALIZED columns recompute); compare row counts per partition; switch
the exporter's `traces_table_name` and the three derived views to the new
table, then drop the bridge view; drop the old table once retention has
passed. Adding a promoted column is easier: `ADD COLUMN ...
MATERIALIZED` on cluster, and old parts compute it on read.
</details>

## Glossary A to Z

Each term has a plain definition, an everyday comparison where it helps, and
the module where it's explained ("A" is the
[metrics reference appendix](appendix-metrics-reference.md)). Code names are
listed under their first letter, ignoring backticks and symbols.

[A](#a) · [B](#b) · [C](#c) · [D](#d) · [E](#e) · [F](#f) · [G](#g) · [H](#h) · [I](#i) · [K](#k) · [L](#l) · [M](#m) · [N](#n) · [O](#o) · [P](#p) · [Q](#q) · [R](#r) · [S](#s) · [T](#t) · [U](#u) · [V](#v) · [W](#w) · [Z](#z)

### A

| Term | Meaning | Module |
|---|---|---|
| `absolute_delay` | Column in `system.replicas`: how many seconds a replica is behind its peer | [7](07-clickhouse.md), [12](12-operations.md) |
| `active_replicas` | Column in `system.replicas`: how many copies of the table are online now, out of `total_replicas` | [7](07-clickhouse.md) |
| Agent (AI) | A program that uses an LLM to decide what to do next, and calls tools. Here: `support-agent`, `hr-agent`, `sales-agent` | [0](00-setup.md) |
| Agent (Collector pattern) | A Collector running next to the app (a sidecar, or one per machine), so the app hands off spans quickly. Unrelated to AI agents | [4](04-collector.md) |
| `agent_turn` | This repo's root span: one per user turn, opened by `agent/run.py` | [2](02-langgraph.md) |
| AggregatingMergeTree | ClickHouse table engine that stores partial aggregation states (half-finished sums and percentiles) and combines them during merges. Used by `span_red_1m` | [8](08-data-model.md) |
| Alert | An automatic message to a person when a metric crosses a threshold for long enough | [12](12-operations.md) |
| ALIAS column | A ClickHouse column computed when you query it, never stored | [8](08-data-model.md) |
| `any(x)` | ClickHouse aggregate: "some value of `x` from the group, I don't care which". Not the same as OTLP's `AnyValue` | [9](09-sharding-indexes.md) |
| `AnyValue` | The OTLP data type that lets an attribute value be a string, number, boolean, list or map | [9](09-sharding-indexes.md) |
| API (OpenTelemetry) | The `opentelemetry-api` package that libraries call to create spans. Without an SDK installed, it does nothing, so it costs nothing | [1](01-otel-core.md) |
| API (HTTP) | A service that answers HTTP requests. Here: `kb-search-api`, `ticket-api`, `pricing-api`, `legacy-hr-api` | [0](00-setup.md) |
| `ARRAY JOIN` | ClickHouse clause that turns each element of an array (such as a span's events) into its own row | [8](08-data-model.md) |
| `async_insert` | ClickHouse setting where the server collects many small inserts and writes them together, instead of the client batching | [7](07-clickhouse.md), [12](12-operations.md) |
| Attribute | A key-value fact on a span, such as `http.response.status_code = 504`. Like a label on a parcel | [1](01-otel-core.md) |
| Auto-instrumentation | Libraries that add spans and header propagation to common frameworks without code changes, such as `opentelemetry-instrument python app.py` | [6](06-cross-environment.md) |

### B

| Term | Meaning | Module |
|---|---|---|
| Back-pressure | A busy component telling the sender "not now, try later" instead of crashing. Like a "full, come back later" sign on a shop door | [4](04-collector.md), [12](12-operations.md) |
| Backend | Where telemetry is finally stored and queried. Here, ClickHouse | [4](04-collector.md) |
| Backoff (exponential) | Waiting longer between each retry (5 s, then about 7 s, and so on, up to 30 s here), so a struggling server isn't hammered | [4](04-collector.md) |
| BACKUP / RESTORE | ClickHouse statements that save tables to a disk or S3 and load them back, on any server | [10](10-copying-data.md), [12](12-operations.md) |
| Baggage | Key-value data that travels with a request in the `baggage` header, such as `org.tenant`. It isn't put on spans unless a service chooses to copy it. Like luggage you carry but don't unpack | [1](01-otel-core.md) |
| Batch | A group of spans sent together in one request | [1](01-otel-core.md), [4](04-collector.md) |
| `batch` processor | Collector processor that groups spans (here up to 1000, or every 5 s) so ClickHouse gets few, large inserts | [4](04-collector.md) |
| `BatchSpanProcessor` | SDK component that queues finished spans in memory (2048 at most) and exports them in batches (512, every 5 s) from a background thread. Full queue: new spans are dropped | [1](01-otel-core.md) |
| Block (insert block) | A chunk of rows ClickHouse handles as one unit during an insert. Materialized views run once per block; Keeper keeps block hashes to spot duplicates | [7](07-clickhouse.md) |
| Bloom filter | A compact structure that answers "definitely not here" or "maybe here". As a skip index, it lets ClickHouse skip blocks that can't contain an id | [9](09-sharding-indexes.md) |
| Bucket | A top-level container in object storage; objects live inside it under names. The lab's bucket is on SeaweedFS | [11](11-s3-tiering.md) |

### C

| Term | Meaning | Module |
|---|---|---|
| Cache disk (S3 cache) | A disk of type `cache` wrapped around the S3 disk: local space that keeps recently read S3 data, so repeated queries on old data don't go to S3 again | [11](11-s3-tiering.md) |
| Callback | A function LangChain calls on every start, end or error of a step (`on_chain_start`, `on_tool_end`...). Our tracer turns them into spans | [2](02-langgraph.md) |
| Cardinality | How many distinct values something has. A span name with an id in it has unbounded cardinality, which breaks grouping and bloats indexes | [1](01-otel-core.md), [8](08-data-model.md) |
| `chat` span | GenAI span for one LLM call: provider, model, finish reasons and token usage | [3](03-genai-semconv.md) |
| Checkpointer | LangGraph component that saves the graph's state after every step, so the next turn of the same conversation continues. Here `InMemorySaver` | [2](02-langgraph.md) |
| `cityHash64` | A fast hash function. `cityHash64(TraceId)` turns a trace id into a number that picks the shard | [9](09-sharding-indexes.md) |
| ClickHouse | The column-store database that stores the spans here, as two replicas | [7](07-clickhouse.md) |
| `clickhouse-init` | One-off container that applies `clickhouse/schema.sql` and waits until all tables are writable before the gateway starts | [7](07-clickhouse.md) |
| Client span | A span of kind `CLIENT`: "I called someone". Paired with the callee's server span, it shows an edge between two services | [1](01-otel-core.md) |
| Clock skew | Different machines' clocks disagreeing, so a child span can seem to start before its parent. Trust the parent links over the timestamps | [6](06-cross-environment.md) |
| Cluster | A named group of ClickHouse servers. `tracing` here: 1 shard, 2 replicas | [7](07-clickhouse.md) |
| `clusterAllReplicas()` | ClickHouse function that runs a query on every replica of a cluster | [7](07-clickhouse.md) |
| Codec | How a ClickHouse column is compressed, such as `CODEC(Delta, ZSTD(1))` | [8](08-data-model.md) |
| Collector | The OpenTelemetry Collector: a separate program that receives telemetry, processes it, and sends it on. Like a company mailroom | [4](04-collector.md) |
| Column store | A database that stores each column separately, so a query reading 3 of 40 columns reads only those 3 | [7](07-clickhouse.md) |
| Conditional edge | A LangGraph edge that picks the next node at run time, for example from the supervisor's `next` field | [2](02-langgraph.md) |
| Connector | A Collector component that is the exporter of one pipeline and the receiver of another, such as `spanmetrics` (spans to metrics) | [4](04-collector.md) |
| Consumers (queue) | Workers that take batches from the exporter's sending queue and send them; 10 by default | [4](04-collector.md) |
| Context | The "current span" (plus baggage), carried along inside a process. Spans started inside it become its children | [1](01-otel-core.md) |
| `context.attach` | Makes a span current. The tracer does this on tool start, so HTTP calls made by the tool become its children | [2](02-langgraph.md) |
| Conversation id | `gen_ai.conversation.id`: the attribute that links the turns of one session | [3](03-genai-semconv.md) |
| Counter | A metric that only goes up, like a car's odometer. You watch how fast it rises | [12](12-operations.md) |
| `create_schema: false` | Exporter setting: don't create tables automatically; this repo's `schema.sql` defines them | [4](04-collector.md), [8](08-data-model.md) |

### D

| Term | Meaning | Module |
|---|---|---|
| DaemonSet | Kubernetes term for "run one copy on every machine"; a common way to deploy agent Collectors | [4](04-collector.md) |
| DDL | Data definition language: SQL that changes structure (`CREATE`, `ALTER`, `DROP`) rather than data | [8](08-data-model.md) |
| DDL queue | Keeper's list of `ON CLUSTER` commands that every node must run | [7](07-clickhouse.md), [8](08-data-model.md) |
| Dead man's switch | An alert that always fires, so if it stops arriving, the monitoring itself is broken | [12](12-operations.md) |
| `debug` exporter | Collector exporter that prints a short summary of each batch to the gateway's log | [4](04-collector.md) |
| `decision_wait` | Tail sampling setting: how long to wait for late spans of a trace before deciding (10 s in the lab) | [5](05-sampling.md) |
| Deduplication (insert) | Replicated tables keep hashes of recent insert blocks in Keeper, so a retried identical batch isn't stored twice | [7](07-clickhouse.md) |
| DEFAULT column | A ClickHouse column filled from an expression on insert, unless the insert gives a value | [8](08-data-model.md) |
| Delayed inserts | ClickHouse slowing inserts down because a partition has too many parts (1000 by default) | [12](12-operations.md) |
| `deployment.environment.name` | Standard resource attribute: the environment the app *says* it runs in. Hard-coded to `local` here; trust the gateway's `org.env` instead | [1](01-otel-core.md), [4](04-collector.md), [6](06-cross-environment.md) |
| Detached folder | A table's `detached/` directory: parts on disk that aren't part of the table yet. `FETCH PARTITION` fills it; `ATTACH` moves them in | [10](10-copying-data.md) |
| Disk (ClickHouse) | A place bytes can live: the local disk, an S3 bucket, or a cache | [11](11-s3-tiering.md) |
| Distributed table | A ClickHouse table that stores nothing; it routes inserts to shards and fans queries out to all of them | [9](09-sharding-indexes.md) |
| Distribution (Collector) | A build of the Collector with a chosen set of components. This repo uses `otelcol-contrib` | [4](04-collector.md) |
| Dual-write | Sending the same data to two destinations, for example two `clickhouse` exporters in one gateway | [10](10-copying-data.md) |

### E

| Term | Meaning | Module |
|---|---|---|
| Edge (LangGraph) | A connection that says which node runs next | [2](02-langgraph.md) |
| Endpoint | An address a program answers on: host and port, sometimes a path | [4](04-collector.md), [12](12-operations.md) |
| `enqueue_failed_spans` | Gateway counter of spans dropped because the sending queue was full. Apps see no error; alert on any increase | [4](04-collector.md), [12](12-operations.md) |
| Environment | A separate place where software runs, such as dev, staging or prod, or another region or cloud account | [6](06-cross-environment.md) |
| `error_mode: ignore` | Filter setting: if a rule can't be evaluated, log it and carry on | [4](04-collector.md) |
| Eval (evaluation) | A quality score for a turn or span ("was the answer good?"), usually added later, with `gen_ai.evaluation.*` attributes | [3](03-genai-semconv.md) |
| Event (span event) | A timestamped point inside a span, such as an `exception` with a stack trace | [1](01-otel-core.md), [8](08-data-model.md) |
| `execute_tool` | GenAI span for one tool call, named `execute_tool {tool name}` | [3](03-genai-semconv.md) |
| `EXPLAIN indexes = 1` | ClickHouse command that shows how many parts and granules each index skipped | [9](09-sharding-indexes.md) |
| Exporter (SDK) | The part of the SDK that sends spans out, here `OTLPSpanExporter` over HTTP | [1](01-otel-core.md) |
| Exporter (Collector) | The part of a Collector that sends data on, such as `clickhouse` | [4](04-collector.md) |
| Exporter helper | Queue, retry and timeout settings that every Collector exporter shares | [4](04-collector.md) |
| Extension | A Collector helper that isn't on the data path, such as `health_check` | [4](04-collector.md) |
| Extract | Reading trace context from incoming headers (`propagate.extract`) so the new span joins the caller's trace | [1](01-otel-core.md) |

### F

| Term | Meaning | Module |
|---|---|---|
| `FakeChatModel` | This repo's stand-in for an LLM: fakes latency and token usage, so no API key is needed | [2](02-langgraph.md) |
| FETCH / ATTACH PARTITION | ClickHouse statements that download a partition from another replicated table into the detached folder, then add it to this table | [10](10-copying-data.md) |
| `file_storage` | Collector extension that keeps data on disk; with `sending_queue.storage`, the queue survives restarts | [4](04-collector.md) |
| `filter` processor | Collector processor that drops data matching a rule. Here it drops spans whose resource lacks `org.owner` or `org.service` | [4](04-collector.md) |
| FINAL | ClickHouse query keyword that finishes deduplication at read time for ReplacingMergeTree tables: `trace_entry FINAL` shows one row per request. Exact but slower | [8](08-data-model.md), [10](10-copying-data.md) |
| Finish reasons | `gen_ai.response.finish_reasons`: why the model stopped, such as `stop` or a length limit | [3](03-genai-semconv.md) |
| Flags (trace flags) | The last field of `traceparent`. `01` means sampled; `02` means the trace id is random | [1](01-otel-core.md) |
| Freshness | Age of the newest stored span: the first sign that ingestion has stalled | [12](12-operations.md) |

### G

| Term | Meaning | Module |
|---|---|---|
| Game day | A planned, rehearsed failure to practice a runbook. The course's outage labs are small ones | [12](12-operations.md) |
| `gen_ai.*` | The GenAI part of semantic conventions: operation, agent, model, provider, tool, tokens, conversation | [3](03-genai-semconv.md) |
| Gateway | A Collector that runs centrally, that every app sends to. Here, the `otel-gateway` container | [4](04-collector.md) |
| Gauge | A metric that goes up and down, like a fuel gauge: queue size, memory, free disk | [12](12-operations.md) |
| GenAI semantic conventions | OpenTelemetry's standard names for AI workloads. Status: development, so names can still change | [3](03-genai-semconv.md) |
| Granule | A block of 8192 rows in a ClickHouse part; the smallest unit an index can skip | [7](07-clickhouse.md) |
| GRANULARITY | Skip index setting: how many granules one index entry covers | [9](09-sharding-indexes.md) |
| gRPC | A network protocol for calling services, one of the two ways to send OTLP (port 4317) | [1](01-otel-core.md), [4](04-collector.md) |

### H

| Term | Meaning | Module |
|---|---|---|
| Head sampling | Deciding whether to keep a trace when its root span starts, in the SDK; the decision travels in `traceparent`. Cheap, but it can't know whether the trace will fail. Like a bouncer at the door | [5](05-sampling.md) |
| Header (HTTP) | A named value sent with an HTTP request, such as `traceparent` | [1](01-otel-core.md) |
| Health check | An endpoint that says whether a program is alive. The gateway's is on port 13133 | [4](04-collector.md), [12](12-operations.md) |
| Histogram | A metric that counts values in buckets, so you can see their spread | [A](appendix-metrics-reference.md) |
| Hot and cold data | Hot: recent data people query often, on fast local disk. Cold: older data read rarely, moved to cheap S3 | [11](11-s3-tiering.md) |
| Hot shard | A shard that gets far more load than the others, for example from sharding by time or service | [9](09-sharding-indexes.md) |

### I

| Term | Meaning | Module |
|---|---|---|
| IAM role | A cloud identity attached to a machine or pod, so programs get credentials without key files | [11](11-s3-tiering.md) |
| Index (ClickHouse) | A structure that lets a query skip data. The main one is the sparse primary index; skip indexes are extra | [7](07-clickhouse.md), [9](09-sharding-indexes.md) |
| Inject | Writing trace context into outgoing headers (`propagate.inject`) | [1](01-otel-core.md) |
| `insert_quorum` | ClickHouse setting that makes an insert wait until N replicas have it | [7](07-clickhouse.md) |
| Instrumentation | Code that creates telemetry, by hand or automatically | [1](01-otel-core.md) |
| Instrumentation scope | The name (and version) of the library that created a span; here `agent-tracing`. Stored as `ScopeName` | [1](01-otel-core.md), [8](08-data-model.md) |
| `invoke_agent` | GenAI span for one agent's run, named `invoke_agent {agent name}` | [3](03-genai-semconv.md) |
| `invoke_workflow` | GenAI span for a whole graph run, named `invoke_workflow {workflow}` | [3](03-genai-semconv.md) |
| `IsRoot` | Column in `trace_entry`: 1 for a trace's root span, 0 otherwise. It's the version column, so the root's row wins | [8](08-data-model.md) |

### K

| Term | Meaning | Module |
|---|---|---|
| Keeper (ClickHouse Keeper) | The coordination service that holds replication metadata (which parts exist, the log, the DDL queue), never the data. Like a notary, not a warehouse | [7](07-clickhouse.md) |
| Kind (span kind) | Who is calling whom: `INTERNAL`, `CLIENT`, `SERVER`, `PRODUCER`, `CONSUMER` | [1](01-otel-core.md) |

### L

| Term | Meaning | Module |
|---|---|---|
| Labels | This repo's word for its `org.*` attributes: resource labels (who and where) and span labels (this request) | [1](01-otel-core.md) |
| Lag | How far behind something is; here, how many seconds a replica is behind its peer | [12](12-operations.md) |
| LangChain | A Python framework that gives models, tools and chains one interface (the Runnable) and reports each step to callbacks | [2](02-langgraph.md) |
| LangGraph | A framework built on LangChain that runs an agent as a state machine of nodes and edges | [2](02-langgraph.md) |
| `LangGraphTracer` | This repo's callback handler in `agent/telemetry.py` that turns LangChain callbacks into spans | [2](02-langgraph.md) |
| Latency | How long something takes | [5](05-sampling.md), [12](12-operations.md) |
| Leader / follower | Roles in a Keeper ensemble: the leader handles writes, followers copy it. A single node is `standalone` | [7](07-clickhouse.md), [A](appendix-metrics-reference.md) |
| LLM | Large language model: the AI model the agent sends prompts to. Faked here | [0](00-setup.md) |
| Load balancer | A component that spreads incoming connections across several copies of a service, such as gateways, skipping unhealthy ones | [4](04-collector.md), [12](12-operations.md) |
| `loadbalancing` exporter | Collector exporter that sends every span of a trace to the same next-tier Collector, by hashing the trace id | [5](05-sampling.md) |
| LowCardinality | ClickHouse type for strings with few distinct values; stores them as a dictionary of codes | [8](08-data-model.md) |

### M

| Term | Meaning | Module |
|---|---|---|
| Macro | A per-server value such as `{shard}` or `{replica}`, from `clickhouse/macros-0N.xml` | [7](07-clickhouse.md) |
| Map column | A ClickHouse column holding key-value pairs. `SpanAttributes` and `ResourceAttributes` are maps, and every value is a string | [8](08-data-model.md) |
| Mark | One entry of the sparse primary index, one per granule | [7](07-clickhouse.md) |
| MATERIALIZE INDEX / COLUMN | Statements that build a new index or column for old parts, as a mutation | [9](09-sharding-indexes.md), [8](08-data-model.md) |
| MATERIALIZED column | A column computed from other columns on insert and stored; it isn't in `SELECT *` and can't be inserted into | [8](08-data-model.md) |
| Materialized view | A ClickHouse insert trigger: runs its `SELECT` on each inserted block and writes the result to another table | [7](07-clickhouse.md), [8](08-data-model.md) |
| `max_elapsed_time` | How long the exporter keeps retrying one batch before dropping it: 300 s here | [4](04-collector.md) |
| `memory_limiter` | First Collector processor: refuses new data when memory is high (limit 512 MiB here). That's back-pressure, not yet loss | [4](04-collector.md) |
| Merge | ClickHouse combining small parts into bigger ones in the background. Like gluing small Lego bricks into big ones | [7](07-clickhouse.md) |
| MergeTree | ClickHouse's main family of table engines: inserts write sorted parts that are merged later | [7](07-clickhouse.md) |
| Metric | A named number a program reports about itself, such as "spans sent" or "memory in use" | [12](12-operations.md) |
| `mntr` / `ruok` | Keeper's four-letter commands: `ruok` ("are you OK?") answers `imok`; `mntr` returns metrics | [12](12-operations.md), [A](appendix-metrics-reference.md) |
| Monitoring | Collecting a system's metrics over time and alerting on them. Keep the pipeline's monitoring outside the pipeline | [12](12-operations.md) |
| `move_factor` | Storage policy setting: when the local volume has less than this share free (0.1 = 10%), move the largest parts to the next volume | [11](11-s3-tiering.md) |
| Mutation | A ClickHouse background job that rewrites existing parts | [9](09-sharding-indexes.md), [12](12-operations.md) |

### N

| Term | Meaning | Module |
|---|---|---|
| Namespace (attributes) | The prefix that groups attribute names, such as `gen_ai.` or this repo's own `org.` | [3](03-genai-semconv.md) |
| Nested | ClickHouse type that stores a list of records as parallel arrays; used for span events and links | [8](08-data-model.md) |
| Node (LangGraph) | A function in the graph that takes the state and returns an update, such as `hr_assistant` | [2](02-langgraph.md) |
| Non-agentic service | Any callee without an LLM, such as an HTTP API. It joins the trace by continuing the trace id it receives | [2](02-langgraph.md), [6](06-cross-environment.md) |

### O

| Term | Meaning | Module |
|---|---|---|
| Object storage | Storage where you upload and download whole files (objects) by name over HTTP, such as S3. Cheap and practically unlimited, but slower, and objects can't be edited in place | [11](11-s3-tiering.md) |
| `ocb` | OpenTelemetry Collector Builder: a tool to build your own slim Collector distribution | [4](04-collector.md) |
| ON CLUSTER | Runs a ClickHouse DDL statement on every node of a cluster, through Keeper's DDL queue | [7](07-clickhouse.md), [8](08-data-model.md) |
| OOM | Out of memory: a process used more than allowed, and the operating system killed it | [A](appendix-metrics-reference.md) |
| Operational readiness | Being able to run a system day to day: you see its health, hear about trouble early, and know what to do | [12](12-operations.md) |
| `ORDER BY` (sorting key) | The order of rows inside each ClickHouse part, and the basis of the sparse primary index. Here `(org_owner, org_service, SpanName, time)` | [7](07-clickhouse.md) |
| `org.env` | The environment label the gateway stamps on every span it receives. Apps can't fake it, so queries filter on `org_env` | [4](04-collector.md), [6](06-cross-environment.md) |
| `org.*` labels | This repo's own attributes: `org.owner`, `org.service` (set by apps), `org.env`, `org.region`, `org.platform`, `org.cluster` (set by the gateway), `org.tenant`, `org.request_id` (per request) | [1](01-otel-core.md), [4](04-collector.md) |
| Orphan span | A span whose parent was never recorded, usually because services sampled inconsistently | [5](05-sampling.md) |
| `otel_traces` | The main table: one row per span; a trace is all rows with one `TraceId` | [8](08-data-model.md) |
| `otel_traces_trace_id_ts` | Lookup table filled by a materialized view: trace id to start and end time, so a trace query can narrow the time range | [8](08-data-model.md), [9](09-sharding-indexes.md) |
| `OTEL_RESOURCE_ATTRIBUTES` | Environment variable of `key=value` pairs the SDK adds to the resource. It only adds keys: attributes passed in code win | [1](01-otel-core.md), [6](06-cross-environment.md) |
| `otelcol-contrib` | The Collector distribution with hundreds of components, including the ClickHouse exporter | [4](04-collector.md) |
| OTLP | OpenTelemetry Protocol: the standard format for sending telemetry, as protobuf over HTTP (port 4318) or gRPC (4317) | [1](01-otel-core.md) |
| OTTL | OpenTelemetry Transformation Language: short conditions and statements used by processors such as `filter` | [4](04-collector.md) |

### P

| Term | Meaning | Module |
|---|---|---|
| p95 (percentile) | The value 95% of measurements are below; 1 in 20 is slower | [12](12-operations.md) |
| Parent span id | The id of the span that caused this one; it turns a flat list into a tree. Empty on the root. Like "who's your parent" in a family tree | [1](01-otel-core.md) |
| Parent-based sampler | A sampler that does what the parent did: keep the span if the parent was kept. Keeps traces whole | [5](05-sampling.md) |
| Part | An immutable chunk of a ClickHouse table on disk: a folder of sorted column files. Every insert creates one | [7](07-clickhouse.md) |
| Parts per partition | Number of active parts in one partition. Inserts are delayed at 1000 and rejected at 3000; alert well before | [12](12-operations.md) |
| Partition | A group of parts that's managed together; here one per day (`PARTITION BY toDate(Timestamp)`). Parts never merge across partitions | [7](07-clickhouse.md) |
| Persistent queue | An export queue kept on disk (`sending_queue.storage`), so a gateway restart doesn't lose it | [4](04-collector.md), [12](12-operations.md) |
| Pipeline | One wired-up path in a Collector: receivers, then processors in order, then exporters | [4](04-collector.md) |
| Play UI | ClickHouse's browser page for running SQL, at <http://localhost:8123/play> | [0](00-setup.md) |
| Policy (tail sampling) | A rule that says which traces to keep, such as "has an error" or "slower than 1.5 s" | [5](05-sampling.md) |
| Prefix (S3) | The start of object names, grouping them like a folder. Each replica writes under its own, such as `clickhouse-01/` | [11](11-s3-tiering.md) |
| `probabilistic_sampler` | Collector processor that keeps a percentage of traces, chosen from the trace id. Not head sampling (apps already sent every span) and not tail sampling (it never sees the whole trace) | [5](05-sampling.md) |
| Processor | A Collector step that changes, drops, groups or samples data, in order | [4](04-collector.md) |
| Projection | A hidden second copy of a ClickHouse table's data inside each part, sorted another way | [9](09-sharding-indexes.md) |
| Prometheus | A monitoring system that scrapes metrics from HTTP pages and stores them. The gateway publishes its metrics in Prometheus format | [12](12-operations.md) |
| Propagation | Carrying trace context between processes in request headers (`traceparent`, `baggage`) | [1](01-otel-core.md) |
| Protobuf | Protocol Buffers: a compact binary format; OTLP uses it | [1](01-otel-core.md) |
| `provider.shutdown()` | Flushes and sends any queued spans before a process exits | [1](01-otel-core.md) |
| Provider (GenAI) | `gen_ai.provider.name`: which AI vendor served a model call | [3](03-genai-semconv.md) |

### Q

| Term | Meaning | Module |
|---|---|---|
| Queue | A waiting line for work. A queue that keeps growing means the next step can't keep up | [4](04-collector.md), [12](12-operations.md) |
| `queue_size` (replication) | Column in `system.replicas`: replication tasks a replica still has to do | [7](07-clickhouse.md), [12](12-operations.md) |
| Quorum (majority) | More than half the members. Keeper needs a majority to work: 2 of 3, or 3 of 5 | [7](07-clickhouse.md) |
| Quota | A ClickHouse per-user limit over a time window (queries, rows read, run time), so one heavy user can't starve the rest | [12](12-operations.md), [A](appendix-metrics-reference.md) |

### R

| Term | Meaning | Module |
|---|---|---|
| Raft | The agreement algorithm Keeper uses so its nodes agree on the same metadata | [7](07-clickhouse.md) |
| Rate | How much a counter grew per second over a time window | [12](12-operations.md) |
| Read-only replica | A table copy that answers queries but refuses inserts, usually because it lost contact with Keeper (`Code: 242 TABLE_IS_READ_ONLY`) | [7](07-clickhouse.md), [12](12-operations.md) |
| Receiver | The part of a Collector that accepts incoming data; here `otlp` | [4](04-collector.md) |
| RED | Rate, errors, duration: the three basic service metrics. `span_red_1m` stores them per minute | [3](03-genai-semconv.md), [8](08-data-model.md) |
| Reducer | LangGraph rule for merging a node's update into the state, such as `add_messages` (append, don't replace) | [2](02-langgraph.md) |
| Refused spans | Spans the gateway's `memory_limiter` turned away with a retryable error. Not lost yet: the SDK keeps them and retries | [4](04-collector.md), [12](12-operations.md) |
| `remote()` | ClickHouse function that reads a table on another server; `INSERT ... SELECT FROM remote()` copies it | [6](06-cross-environment.md), [10](10-copying-data.md) |
| ReplacingMergeTree | ClickHouse engine that keeps one row per sorting key, eventually: duplicates disappear when parts merge, and the version column picks the survivor. Used by `trace_entry` | [8](08-data-model.md), [10](10-copying-data.md) |
| Replica | One copy of a table. Adds availability and read capacity | [7](07-clickhouse.md), [9](09-sharding-indexes.md) |
| ReplicatedMergeTree | MergeTree that keeps copies on several servers, coordinated by Keeper | [7](07-clickhouse.md) |
| Replication | Keeping copies in sync. Here, a new part is logged in Keeper and the other replica downloads it from its peer | [7](07-clickhouse.md) |
| Resource | Who sent the span: `service.name`, `org.owner`, `org.service`. Set once per process; code wins over `OTEL_RESOURCE_ATTRIBUTES`. Resource = who, attributes = what | [1](01-otel-core.md) |
| `resource` processor | Collector processor that edits resource labels; here it stamps the platform labels | [4](04-collector.md) |
| Retry | Trying again after a failure; the SDK and the exporter both do it | [4](04-collector.md) |
| Root span | The span with no parent; the top of the tree. Here `agent_turn` | [1](01-otel-core.md) |
| RSS | Resident set size: the memory a process actually holds in RAM, such as `otelcol_process_memory_rss_bytes` | [A](appendix-metrics-reference.md) |
| Run id | The id LangChain gives each step; `parent_run_id` says who called it | [2](02-langgraph.md) |
| Runbook | A written, step-by-step "what to do when X happens" | [12](12-operations.md), [B](appendix-runbooks.md) |
| Runnable | LangChain's common interface (`.invoke(input, config)`) for models, tools, chains and graphs | [2](02-langgraph.md) |

### S

| Term | Meaning | Module |
|---|---|---|
| S3 | Amazon's object storage service, and the API many other stores copy. Cheap, slower than local disk | [11](11-s3-tiering.md) |
| Sampler | SDK component that decides, when a span starts, whether to record it | [5](05-sampling.md) |
| Sampling | Keeping only some traces to save cost | [5](05-sampling.md) |
| Saturation | How full a resource is: a queue, a disk, memory. Near 100%, the next push fails | [12](12-operations.md) |
| Schema URL | The version of the semantic conventions the telemetry follows, such as `.../schemas/1.44.0` | [3](03-genai-semconv.md) |
| Scrape | When a monitoring system fetches a metrics page on a schedule | [12](12-operations.md) |
| SDK | The OpenTelemetry library inside the app that creates, samples, batches and exports spans | [1](01-otel-core.md) |
| SeaweedFS | A small S3-compatible server used in the tiering lab instead of real S3 | [11](11-s3-tiering.md) |
| Semantic conventions (semconv) | OpenTelemetry's shared dictionary of span names and attribute names, so every team means the same thing | [3](03-genai-semconv.md) |
| `send_failed_spans` | Gateway counter of spans the exporter gave up on: after 300 s of retries, or at once for permanent errors. Alert on any increase | [4](04-collector.md), [12](12-operations.md) |
| Sending queue | A waiting area in front of a Collector exporter, holding batches until they're sent: 1000 batches, in memory, here. When full, new batches are dropped (`enqueue_failed`); a restart empties it | [4](04-collector.md) |
| Server span | A span of kind `SERVER`: "I answered a call". Its parent is the caller's client span | [1](01-otel-core.md) |
| Session | A conversation of many turns, linked by `gen_ai.conversation.id`; not one trace | [3](03-genai-semconv.md) |
| Shard | A slice of the data on its own servers. Adds storage and write capacity | [9](09-sharding-indexes.md) |
| Sharding key | The expression that picks a row's shard, here `cityHash64(TraceId)` | [9](09-sharding-indexes.md) |
| Sidecar | A helper container running next to an app, such as an agent Collector | [4](04-collector.md) |
| SimpleAggregateFunction | ClickHouse column type, such as `SimpleAggregateFunction(sum, UInt64)`, that `AggregatingMergeTree` adds up on merge. Used for `span_red_1m.calls` and `errors` | [8](08-data-model.md) |
| Skip index | A ClickHouse index (`minmax`, `set`, `bloom_filter`...) that lets a query skip granules that can't match. It never finds rows; it's a "not here" sign | [9](09-sharding-indexes.md) |
| SLI | Service level indicator: a measurement of what users experience, such as span freshness | [12](12-operations.md) |
| SLO | Service level objective: a target for an SLI, such as "newest span under 2 minutes old 99.9% of the time" | [12](12-operations.md) |
| Span | One timed operation: name, start and end, status, kind, attributes, events, links | [1](01-otel-core.md) |
| Span id | 16 hex characters unique to one span. In the family tree, the first name | [1](01-otel-core.md) |
| Span link | A pointer to a span in another trace, for async, batch or trust-boundary cases; not a parent | [6](06-cross-environment.md), [8](08-data-model.md) |
| Span name | A short, low-cardinality name such as `GET /v1/prices/{sku}`, never with ids in it | [1](01-otel-core.md) |
| `span_red_1m` | Per-minute rate, errors and duration per service and span name, kept a year. Read with `sum(calls)` and `quantilesMerge` | [7](07-clickhouse.md), [8](08-data-model.md) |
| `spanmetrics` connector | Collector connector that turns spans into metrics, best placed before any sampling | [5](05-sampling.md) |
| Sparse index | ClickHouse's primary index: one entry (mark) per granule of 8192 rows, not one per row | [7](07-clickhouse.md) |
| Stability level | How settled a semconv area is: HTTP is stable; GenAI is still in development | [3](03-genai-semconv.md) |
| State (LangGraph) | A typed dict shared by all nodes, like a whiteboard. Here `TurnState` or `HrState` | [2](02-langgraph.md) |
| Status | A span's outcome: `UNSET`, `OK` or `ERROR` | [1](01-otel-core.md) |
| Stock columns | The 22 columns the Collector's ClickHouse exporter writes, the same for every user of that exporter. Never rename or retype them | [8](08-data-model.md) |
| Storage policy | An ordered list of volumes a ClickHouse table may use, such as `tiered`: local first, then S3 | [11](11-s3-tiering.md) |
| Supervisor pattern | One LangGraph node routes; worker nodes do the work and hand control back | [2](02-langgraph.md) |
| Superstep | One round of a LangGraph run, in which the scheduled nodes execute | [2](02-langgraph.md) |
| Synthetic trace | A fake request sent on a schedule, just to check it arrives end to end | [12](12-operations.md) |
| System tables | ClickHouse's built-in tables about itself: `system.parts`, `system.replicas`, `system.metrics`, `system.events`, `system.query_log`... | [7](07-clickhouse.md), [12](12-operations.md) |

### T

| Term | Meaning | Module |
|---|---|---|
| Tail sampling | Deciding whether to keep a trace after all its spans arrived, in a Collector. Can keep all errors, but every span of a trace must reach the same instance. Like a reviewer after the party | [5](05-sampling.md) |
| Telemetry | Data a program emits about itself: traces, metrics and logs | [4](04-collector.md) |
| Tenant | The customer a request is for (`org.tenant`), carried in baggage | [1](01-otel-core.md) |
| Thread id | LangGraph's id for one conversation, so the checkpointer can save and restore its state | [2](02-langgraph.md) |
| Threshold | The value at which a metric counts as bad | [12](12-operations.md) |
| Tiered storage | Keeping new data on fast local disk and moving older data to cheap S3 | [11](11-s3-tiering.md) |
| TLS | Transport Layer Security: encryption for network connections | [12](12-operations.md) |
| Tokens | The units LLMs count and bill text in. `gen_ai.usage.input_tokens` and `output_tokens`, on `chat` spans only | [3](03-genai-semconv.md) |
| Tool | A function an agent can call, such as `lookup_employee`; here tools call HTTP APIs | [2](02-langgraph.md) |
| Too many parts | ClickHouse error when a partition reaches 3000 active parts (inserts are delayed from 1000); caused by many small inserts | [7](07-clickhouse.md), [12](12-operations.md) |
| Touch point | An interface between two components: protocol, port, contract and owner. Change one side and the other breaks | [12](12-operations.md) |
| Trace | All spans that share one trace id, joined into a tree. Like a family tree | [1](01-otel-core.md) |
| Trace id | 32 hex characters shared by every span of one request, across services. In the family tree, the surname | [1](01-otel-core.md) |
| `trace_entry` | The request list: rows for each request's entry spans and each trace's root, filled by a view. `ReplacingMergeTree(IsRoot)` keeps the root's row; `FINAL` shows one per request | [8](08-data-model.md) |
| `traceparent` | W3C header carrying the version, trace id, parent span id and flags. Like a letter of introduction you carry into the next service | [1](01-otel-core.md) |
| Tracer | The object code uses to start spans | [1](01-otel-core.md) |
| `TracerProvider` | The SDK object that holds the resource, sampler and processors, and hands out tracers | [1](01-otel-core.md) |
| `tracestate` | A second W3C header for vendor-specific trace data; stored as `TraceState` | [8](08-data-model.md) |
| Trust boundary | A point where outside callers come in, such as a public API. There you may start a new trace and link to the caller's | [6](06-cross-environment.md) |
| TTL | Time to live: a rule that deletes or moves data once it's old enough. Here, raw spans are deleted after 72 hours | [7](07-clickhouse.md) |
| TTL move | `TTL ... TO VOLUME 'cold'`: a part moves to another volume once its newest row passes the age. Applies at insert time too, so old rows are written straight there | [11](11-s3-tiering.md) |
| Turn | One user message and the agent's full response; one trace | [3](03-genai-semconv.md) |

### U

| Term | Meaning | Module |
|---|---|---|
| Upsert | "Update or insert": set the value, overwriting it if it's already there | [4](04-collector.md) |
| `url.template` | Attribute holding the route pattern, such as `/v1/prices/{sku}`, used for low-cardinality span names | [1](01-otel-core.md) |
| Usage attributes | `gen_ai.usage.*`: input, output, cached and reasoning token counts | [3](03-genai-semconv.md) |

### V

| Term | Meaning | Module |
|---|---|---|
| Version column | The column in `ReplacingMergeTree(ver)` that picks which duplicate survives a merge: the highest wins. `IsRoot` in `trace_entry` | [8](08-data-model.md) |
| Volume | A group of disks inside a storage policy, such as `default` (local) or `cold` (S3) | [11](11-s3-tiering.md) |

### W

| Term | Meaning | Module |
|---|---|---|
| W3C Trace Context | The web standard that defines the `traceparent` and `tracestate` headers. W3C is the World Wide Web Consortium | [1](01-otel-core.md) |
| WAF | Web application firewall: a filter in front of web services that can strip unknown headers | [6](06-cross-environment.md) |

### Z

| Term | Meaning | Module |
|---|---|---|
| Zero-copy replication | A ClickHouse mode where replicas share one copy of S3 data instead of each writing its own. Not recommended for production | [11](11-s3-tiering.md) |
| Znode | One entry in Keeper's tree of metadata, like a file in a folder tree | [12](12-operations.md) |
| ZooKeeper | An older coordination service. Keeper speaks the same protocol, which is why ClickHouse tables mention `zookeeper` | [7](07-clickhouse.md) |

## Where to go next

- Add a real model: replace `chat_model` in `agent/graph.py` with a real
  LangChain chat model. The tracer doesn't change.
- Add metrics: a `spanmetrics` connector in the gateway, ahead of any
  sampling.
- Put a UI on top: Grafana with the ClickHouse data source, or ClickStack
  (HyperDX).

## Read more

- [OpenTelemetry concepts](https://opentelemetry.io/docs/concepts/)
- [OpenTelemetry glossary](https://opentelemetry.io/docs/concepts/glossary/)
- [GenAI semantic conventions](https://opentelemetry.io/docs/specs/semconv/gen-ai/)
- [Collector overview](https://opentelemetry.io/docs/collector/)
- [ClickHouse: Observability with OpenTelemetry](https://clickhouse.com/docs/observability/integrating-opentelemetry)
- [ClickHouse glossary](https://clickhouse.com/docs/concepts/glossary)
- [Google SRE book: service level objectives](https://sre.google/sre-book/service-level-objectives/)

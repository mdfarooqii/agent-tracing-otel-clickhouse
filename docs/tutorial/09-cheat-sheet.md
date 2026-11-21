# Module 9: Explain-it-back cheat sheet and glossary (10 min)

Close the other modules. Explain each section out loud in about a minute, then
check yourself against the text. If you stumble, go back to that module's
"Explain it back" section.

## The whole system in one breath

> "Each agent turn is one trace. LangChain callbacks report every graph node,
> model call and tool call with run ids, and our handler turns them into
> OpenTelemetry spans named by the GenAI conventions: `invoke_workflow`,
> `invoke_agent`, `chat`, `execute_tool`. Tools call HTTP APIs and pass
> `traceparent` and `baggage`, so the API spans join the same trace. The SDK
> batches spans and sends OTLP to a Collector gateway, which drops unlabelled
> spans, stamps platform labels, batches, retries, and writes to ClickHouse.
> ClickHouse stores spans as columns in a MergeTree table, sorted by owner,
> service and span name, partitioned by day, and replicated to a second node
> through Keeper. To scale out, we'd shard by a hash of the trace id, so every
> trace stays on one shard."

## Ten one-liners

| Concept | One line |
|---|---|
| Span | A timed operation with attributes, status and a parent |
| Trace | All spans that share one trace id: a tree |
| Context | The current span, carried implicitly; nested spans become children |
| Propagation | `traceparent` plus `baggage` headers carry context between processes |
| Resource | *Who* sent the span (service, owner); attributes say *what* happened |
| GenAI semconv | Standard `gen_ai.*` names: operation, agent, model, tool, tokens; still in development |
| Collector | Receivers, then processors in order, then exporters; queue and retry in the exporter |
| Head and tail sampling | Decide at the start (cheap, blind), or after the trace ends (smart, costly, one instance per trace) |
| ClickHouse storage | Insert creates a part, parts merge; sparse index on `ORDER BY`; partitions for retention |
| Replication and sharding | Replicas are copies (Keeper holds metadata); shards are slices (hash the trace id) |

## Glossary

| Term | Meaning | Module |
|---|---|---|
| Span | One timed operation: name, start and end, status, kind, attributes | [1](01-otel-core.md) |
| Trace id | 32 hex characters shared by every span of one request, across services | [1](01-otel-core.md) |
| Parent span id | The span that caused this one; turns a flat list into a tree. Empty on the root | [1](01-otel-core.md) |
| Root span | The span with no parent; here `agent_turn` | [1](01-otel-core.md) |
| Span kind | `INTERNAL`, `CLIENT`, `SERVER`, `PRODUCER`, `CONSUMER`; a client/server pair is a service edge | [1](01-otel-core.md) |
| `traceparent` | W3C header carrying trace id, parent span id and the sampled flag | [1](01-otel-core.md) |
| Baggage | Request-wide key/values in the `baggage` header; copied onto spans only if a service chooses to | [1](01-otel-core.md) |
| Resource | Who sent the span: `service.name`, `org.owner`, `org.service` | [1](01-otel-core.md) |
| Labels | This repo's `org.*` attributes: resource labels (who and where) and span labels (this request) | [1](01-otel-core.md) |
| Semconv | OpenTelemetry's shared names for spans and attributes, versioned by schema URL | [3](03-genai-semconv.md) |
| `gen_ai.*` | The GenAI part of semconv: operation, agent, model, provider, tool, tokens, conversation | [3](03-genai-semconv.md) |
| Turn | One user message and the agent's response; one trace | [3](03-genai-semconv.md) |
| Session | A conversation of many turns, linked by `gen_ai.conversation.id`; not one trace | [3](03-genai-semconv.md) |
| Eval | A quality score for a turn or span, usually added later, using `gen_ai.evaluation.*` | [3](03-genai-semconv.md) |
| Span link | A pointer to a span in another trace, for async, batch or trust-boundary cases | [8](08-cross-environment.md) |
| Non-agentic service | Any callee without an LLM; it joins the trace by continuing the trace id it receives | [8](08-cross-environment.md) |
| `any(x)` | ClickHouse aggregate: some value of `x` from the group (not OTLP's `AnyValue` type) | [7](07-sharding-indexes.md) |
| `otel_traces` | One row per span; a trace is all rows with one `TraceId` | [10](10-data-model.md) |
| MATERIALIZED column | Computed from the attribute maps on insert, stored, not in `SELECT *` | [10](10-data-model.md) |
| `remote()` | Read a table on another ClickHouse server; `INSERT ... SELECT FROM remote()` copies it | [10](10-data-model.md) |
| Adding a replica | Same table and UUID, new `{replica}` macro: it fetches every part via Keeper | [10](10-data-model.md) |
| Storage policy | Ordered volumes a table may use; here `default` (local) then `cold` (S3) | [11](11-s3-tiering.md) |
| TTL move | `TTL ... TO VOLUME 'cold'`: a part moves once its newest row passes the threshold | [11](11-s3-tiering.md) |

## Memory hooks

- **Parcel route**: make, label, ship, sort, shelve (SDK, resource, OTLP, Collector, ClickHouse).
- **Family tree**: trace id is the surname, span id the first name, parent id the parent.
- **Letter of introduction**: `traceparent` is the letter you carry into the next service.
- **Luggage**: baggage travels with you, but nobody unpacks it unless they choose to.
- **Post office**: drop the junk mail first, bundle last; the loading dock is the queue.
- **Bouncer and reviewer**: head sampling judges at the door; tail sampling after the party.
- **Lego bricks**: each insert is a brick; merges glue them; too many small bricks jam it.
- **Notary, not warehouse**: Keeper records which parts exist; replicas ship the parts.
- **Same house**: hash the trace id, and the whole family lives on one shard.
- **"Not here" sign**: a skip index skips granules; it never finds rows.
- **Passport**: a trace crosses environments only if `traceparent` gets through every border.

## Where things fail, and what you lose

| Failure | Symptom | Loss |
|---|---|---|
| SDK queue full, or the process exits while the gateway is down | `Failed to export spans batch` | Those spans (module 4 lab) |
| Gateway down | Apps retry briefly | Spans from short-lived processes |
| ClickHouse or Keeper down, less than 5 min | `Code: 242` read-only, gateway retries | Nothing (module 6 lab) |
| ClickHouse down, more than `max_elapsed_time` | Gateway drops batches | Batches past the retry window |
| One replica down | `active_replicas = 1` | Nothing; it catches up |
| Proxy strips headers | Every API span is a root | The trace's continuity |
| Non-parent-based sampler downstream | Orphan spans | Trace completeness |
| Tail sampling across replicas without trace-id routing | Fragmented traces | Trace completeness |

## Commands you should know by heart

```bash
./stack.sh up | down [--wipe] | status | demo | queries | logs | traffic on|off

# Head sampling, from the environment only
OTEL_TRACES_SAMPLER=parentbased_traceidratio OTEL_TRACES_SAMPLER_ARG=0.3 .venv/bin/python simulate.py

# Tail sampling on, then off
docker compose -f compose.yaml -f docs/tutorial/labs/compose.tail-sampling.yaml up -d otel-gateway
docker compose up -d otel-gateway
```

```sql
-- One trace as a tree, in order
SELECT ServiceName, SpanKind, SpanName, Duration / 1e6 AS ms FROM otel.otel_traces WHERE TraceId = '...' ORDER BY Timestamp;

-- Replication health
SELECT table, is_readonly, queue_size, absolute_delay, active_replicas FROM system.replicas WHERE database = 'otel';

-- Parts and merges
SELECT partition, count() AS parts, sum(rows) FROM system.parts WHERE table = 'otel_traces' AND active GROUP BY partition;

-- Does my index skip anything?
EXPLAIN indexes = 1 SELECT count() FROM otel.otel_traces WHERE ...;
```

## Interview-style questions

Answer them without notes, then check.

<details><summary>How does an API in another process know which trace it belongs to?</summary>

The caller's client span injects `traceparent` (trace id, its own span id,
sampled flag) into the HTTP headers; the API extracts it and starts its
server span as a child of that client span.
</details>

<details><summary>Where should token counts go, and why there?</summary>

On `chat` spans only, as `gen_ai.usage.*`. Recording them once, where they
happen, means sums over agents or turns don't count anything twice.
</details>

<details><summary>Your tail sampler keeps half-traces. What's the likely cause?</summary>

Spans of one trace are reaching different Collector instances. Route by trace
id with the `loadbalancing` exporter in front of the tail-sampling tier.
</details>

<details><summary>Why does the gateway batch spans before ClickHouse?</summary>

Every insert creates a part. Many small inserts create parts faster than
merges can combine them, leading to "too many parts" errors and slow queries.
</details>

<details><summary>Keeper goes down. Can people still look at traces?</summary>

Yes. Reads work; only writes to replicated tables stop (read-only). The
gateway queues and retries, so if Keeper returns within the retry window,
nothing is lost.
</details>

<details><summary>Why shard by trace id and not by time or service?</summary>

Every span of a trace then lands on one shard, so trace lookups go to one
shard and per-trace work stays local, while random trace ids still spread
load evenly. Time-based sharding makes a hot shard for "now"; service-based
sharding splits traces and creates hot shards.
</details>

## Where to go next

- Add a real model: replace `chat_model` in `agent/graph.py` with a real
  LangChain chat model. The tracer doesn't change.
- Add metrics: a `spanmetrics` connector in the gateway, ahead of any sampling.
- Make the gateway queue durable: a `file_storage` extension plus
  `sending_queue.storage`.
- Run 3 Keepers and see the cluster survive one Keeper failure.
- Put a UI on top: Grafana with the ClickHouse data source, or ClickStack
  (HyperDX).

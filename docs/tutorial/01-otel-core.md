# Module 1: OpenTelemetry core (40 min)

## Idea

### Trace and span

A **span** is one timed operation: a name, a start and end time, a **status**,
**attributes** (key/value facts), and a **kind**. A **trace** is all the spans
that share one **trace id**, joined into a tree by each span's **parent span id**.

| Field | Example | Note |
|---|---|---|
| `trace_id` | `12d64ae6b9afa411e15ca3a7c1726609` | 16 bytes, same for every span in the trace |
| `span_id` | `01aa4e70b23ff052` | 8 bytes, unique per span |
| `parent_span_id` | `2d1b1ef9f9ccc966` | Empty for the root span |
| `name` | `execute_tool search_knowledge_base` | Low cardinality: no ids in names |
| `kind` | `INTERNAL`, `CLIENT`, `SERVER`, `PRODUCER`, `CONSUMER` | Who is calling whom |
| `status` | `UNSET`, `OK`, `ERROR` | Only set `ERROR` for failures |
| attributes | `http.response.status_code=504` | Facts about this operation |
| events | `exception` with a stack trace | Timestamped points inside a span |
| links | Pointer to a span in another trace | For batches and fan-in, not parent/child |

A `CLIENT` span in the caller and a `SERVER` span in the callee are a pair: the
server span's parent is the client span. That pair is how the backend draws an
edge between two services (query 7 in `queries.sql` does exactly this join).

### Context and propagation

**Context** is the "current span" (plus baggage) carried implicitly through
your code. `start_as_current_span` puts a span into the context, so any span
started inside it becomes its child automatically.

Across a network, context has to be written into the request.
**Propagation** does this. `propagate.inject(headers)` writes two W3C headers;
`propagate.extract(headers)` reads them on the other side:

```text
traceparent: 00-12d64ae6b9afa411e15ca3a7c1726609-01aa4e70b23ff052-03
             │  │                                │                └ flags (01 = sampled)
             │  │                                └ span id of the caller (the new parent)
             │  └ trace id
             └ version
baggage:     org.tenant=acme_corp
```

**Baggage** is key/value data that travels with the request but is *not*
automatically added to spans. The receiver decides whether to copy it onto its
own spans. In this repo the APIs copy `org.tenant` and `org.request_id` from
baggage onto their server spans.

### Resource

The **resource** describes *who produced* the spans: `service.name`,
`service.version`, `deployment.environment.name`, and here also `org.owner`
and `org.service`. It's set once per process and attached to every span the
process exports. Rule of thumb: **resource = who, attributes = what**.

### The SDK pipeline

```text
Tracer ─start_span─▶ Sampler ─▶ Span ─end()─▶ SpanProcessor ─▶ Exporter ─OTLP─▶ Collector
          (API)       (keep?)                  (Batch: queue)     (HTTP/gRPC)
```

- The **API** (`opentelemetry-api`) is what libraries call. With no SDK
  installed, it's a no-op, so instrumented libraries cost nothing.
- The **SDK** (`opentelemetry-sdk`) does the real work: `TracerProvider`,
  sampler, processors, exporters.
- `BatchSpanProcessor` keeps finished spans in an in-memory queue and exports
  them in batches from a background thread. Defaults: queue 2048 spans, batch
  512, every 5 s. **If the queue is full, new spans are dropped**, and
  `provider.shutdown()` flushes whatever is left (that's why `run.py` calls it).
- **OTLP** is the wire protocol: protobuf over HTTP (port 4318) or gRPC
  (port 4317). This repo maps them to 14318 and 14317 on the host.

Almost everything can be configured through environment variables, without
code changes: `OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_RESOURCE_ATTRIBUTES`,
`OTEL_TRACES_SAMPLER`, `OTEL_BSP_MAX_QUEUE_SIZE`, `OTEL_BSP_SCHEDULE_DELAY`.

## Remember it

> **A trace is a family tree. The trace id is the surname, the span id is
> the first name, the parent id says who your parent is. `traceparent` is the
> letter of introduction you carry when you visit another service.**

And: **resource = who, attributes = what, baggage = luggage you carry but
don't unpack unless you choose to.**

## In this repo

- `agent/telemetry.py`, `setup_tracing`: resource, `TracerProvider`,
  `BatchSpanProcessor`, `OTLPSpanExporter`. The endpoint defaults to
  `http://localhost:14318`.
- `agent/telemetry.py`, `call_api`: a `CLIENT` span per HTTP call, and
  `propagate.inject(headers)`.
- `agent/apis.py`, the request handler: `propagate.extract(...)` and a
  `SERVER` span whose parent is the caller's client span. Note the header
  names are lower-cased first, because Python's `urllib` sends
  `Traceparent` with a capital T, and the extractor looks up lower-case keys.
- `agent/run.py`: puts `org.request_id` and `org.tenant` into baggage before
  each turn.

## Lab (15 min)

1. Make spans and print them, without any backend:

   ```bash
   cd agent && .venv/bin/python ../docs/tutorial/labs/hello_span.py
   ```

   Look for:
   - The `Headers a client would send:` line, with `traceparent` and `baggage`.
   - `child` printed **before** `parent`: spans are exported when they *end*.
   - `child.parent_id` equals `parent.context.span_id`, and both share a `trace_id`.
   - The resource block: your attributes plus `telemetry.sdk.*` added by the SDK.

2. Change the resource without changing code:

   ```bash
   OTEL_RESOURCE_ATTRIBUTES=deployment.environment.name=lab .venv/bin/python ../docs/tutorial/labs/hello_span.py | grep environment
   ```

3. Find the client/server pair in ClickHouse:

   ```sql
   SELECT c.ServiceName AS caller, s.ServiceName AS callee, c.SpanName, count() AS calls
   FROM otel.otel_traces AS c
   JOIN otel.otel_traces AS s ON s.TraceId = c.TraceId AND s.ParentSpanId = c.SpanId
   WHERE c.SpanKind = 'Client' AND s.SpanKind = 'Server'
   GROUP BY caller, callee, c.SpanName;
   ```

## Explain it back

> "A span is a timed operation with attributes and a status; spans with the
> same trace id form a tree through parent ids. Inside a process, the current
> span lives in the context, so nested spans become children. Between
> processes, the client injects the W3C `traceparent` header, and the server
> extracts it and starts its span as a child of the client span. Baggage rides
> along for request-wide values like tenant. The SDK samples, buffers spans in
> a batch processor, and exports them over OTLP; the resource tells the backend
> which service sent them."

## Check yourself

<details><summary>A span's name is <code>GET /v1/prices/sku-123</code>. What's wrong?</summary>

The name contains an id, so it has unbounded cardinality: every SKU becomes a
different span name, which breaks grouping and indexing. Use the route
template (`GET /v1/prices/{sku}`) and put the SKU in an attribute if needed.
This repo does that through `url.template`.
</details>

<details><summary>What happens to spans if the collector is down for 10 minutes?</summary>

The exporter fails and retries; meanwhile the `BatchSpanProcessor` queue fills
up (2048 spans by default) and then **drops new spans**. The SDK is not a
durable buffer. That's one reason to run a Collector close to the app.
</details>

<details><summary>Why doesn't baggage show up as span attributes by itself?</summary>

Baggage is propagated data, not telemetry; copying it everywhere could leak
data or blow up cardinality. Each service decides which baggage keys to copy
onto its spans (or uses a baggage span processor to do it for all spans).
</details>

<details><summary>What do the flags <code>03</code> in <code>traceparent</code> mean?</summary>

Bit `01` is "sampled": the caller recorded this trace, so a parent-based
sampler downstream will record it too. Bit `02` is the newer "random" flag
(W3C Trace Context level 2): the trace id was generated randomly, which lets
ratio samplers make consistent decisions from it.
</details>

## Read more

- [Traces](https://opentelemetry.io/docs/concepts/signals/traces/)
- [Context propagation](https://opentelemetry.io/docs/concepts/context-propagation/)
- [Resources](https://opentelemetry.io/docs/concepts/resources/)
- [Python instrumentation guide](https://opentelemetry.io/docs/languages/python/instrumentation/)
- [SDK environment variables](https://opentelemetry.io/docs/specs/otel/configuration/sdk-environment-variables/)
- [W3C Trace Context](https://www.w3.org/TR/trace-context/) and [W3C Baggage](https://www.w3.org/TR/baggage/)
- [OTLP specification](https://opentelemetry.io/docs/specs/otlp/)

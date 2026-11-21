# Module 1: OpenTelemetry core (50 min)

## Why this matters

Every other module builds on the words in this one. When the gateway drops a
span, when a trace is "broken" between two services, or when a ClickHouse
query joins a client span to a server span, the explanation is always one of
the ideas here: spans, context, propagation, resources, or the SDK's export
pipeline.

What you'll be able to do after this module:

- Look at one span and say what each of its fields means.
- Explain how a span knows its parent, inside one program and across an HTTP
  call, and read a `traceparent` header by eye.
- Say whether a fact belongs on the resource, on a span attribute, or in
  baggage.
- Follow a finished span through the SDK and out over OTLP, and say what
  happens when that path is blocked.

## Key terms

Reminder from [module 0](00-setup.md): a **span** is the record of one timed
step, and a **trace** is all the spans of one request.

| Term | Plain meaning |
|---|---|
| **Span id, parent span id** | A span's own random id, and the id of the span it sits under. A span with no parent is the **root span** |
| **Span kind** | The span's role: internal work, calling out (`CLIENT`), or being called (`SERVER`) |
| **Status** | Whether the operation failed: `UNSET` (default), `OK`, or `ERROR` |
| **Attribute** | A key-value fact about one span, such as `http.response.status_code = 504` |
| **Context** | An invisible "which span am I inside right now?" value that OpenTelemetry carries through your code |
| **Propagation, `traceparent`** | Writing the context into an outgoing request's headers, and reading it back on the other side. `traceparent` is the standard header for it |
| **Baggage** | Key-value pairs (such as a tenant name) that travel with a request to downstream services, in the `baggage` header |
| **Resource** | Key-value facts about *who* produced the spans: service name, version, owner. Set once per process |
| **API, SDK** | The API is the package code calls to create spans, and does nothing on its own. The SDK is the package that records and sends them |
| **Tracer provider, tracer, instrumentation scope** | The provider holds the SDK setup for a process; a tracer starts spans; the tracer's name is the instrumentation scope |
| **Span processor, exporter, OTLP** | The processor queues finished spans; the exporter sends them; OTLP (OpenTelemetry Protocol) is the format they travel in |

## Idea

### The running example

We'll follow one request through every concept: the **support agent**'s turn
where the user asks *"What is a trace?"*. During that turn:

1. `run.py` starts a span called `agent_turn` for the whole turn.
2. The LangGraph graph runs ([module 2](02-langgraph.md)). Its supervisor and
   researcher nodes each make an LLM call.
3. The researcher calls the tool `search_knowledge_base`, which sends
   `GET /v1/search` to `kb-search-api`, a separate Python process on port
   `18081`.
4. `kb-search-api` searches, replies, and records its own span.
5. Both processes send their spans, separately, to the gateway at
   `localhost:14318`, which writes them to ClickHouse.

The puzzle this module solves: two different processes record spans on their
own, yet in ClickHouse they show up as **one** trace, with the API's span
correctly nested under the agent's HTTP call. How?

### Trace and span

**Why.** "The turn took 2 seconds" doesn't tell you *where* the 2 seconds
went. You want each step timed separately, and you want to know which step was
inside which, so you can find the slow or broken one.

**What.** A **span** is the record of one timed operation. Think of it as one
line on a restaurant order ticket: "grill steak, started 19:02:10, finished
19:09:40, table 12". A **trace** is the whole ticket: every line for one
order. The thing that ties the lines together is the **trace id**: every span
of one request carries the same one.

The tree shape comes from the **parent span id**. Each span remembers which
span was running when it started. A good picture is a family tree: the trace
id is the family surname (everyone shares it), the span id is each person's
own first name, and the parent span id says who their parent is. The one span
with no parent is the **root span**.

Here are the fields every span has:

| Field | Example | Note |
|---|---|---|
| `trace_id` | `386d73b95ebe85beba3ae0906345d043` | 16 bytes (32 hex characters), same for every span in the trace |
| `span_id` | `2b82646cf09c0fad` | 8 bytes (16 hex characters), unique per span |
| `parent_span_id` | `9d8147dae245aec6` | Empty for the root span |
| `name` | `GET /v1/search` | What kind of operation; no ids in names |
| `kind` | `INTERNAL`, `CLIENT`, `SERVER` | Who is calling whom |
| `status` | `UNSET`, `OK`, `ERROR` | Only set `ERROR` for failures |
| start and end time | `2026-11-21T05:32:34.227963Z` | Duration is end minus start |
| attributes | `http.response.status_code=200` | Facts about this operation |
| events | `exception` with a stack trace | Timestamped notes inside a span |

The example values are the `kb-search-api` span from module 0.

**Name.** The name says *what kind* of operation this is, so you can group
"all searches" together. It must not contain ids: a name with a SKU in it
would be a new name for every SKU, and grouping by name would stop working.
Specific values go in attributes instead. This repo names HTTP spans after the
**route template**, the URL pattern with placeholders: `pricing-api`'s span is
called `GET /v1/prices/{sku}`, not `GET /v1/prices/SKU-200`.

**Kind.** The kind says what role the span plays:

- `INTERNAL`: work inside one process. `agent_turn`, `invoke_agent ...` and
  `execute_tool ...` are internal.
- `CLIENT`: this process is calling something else and waiting for the
  answer. `call_api` creates a `CLIENT` span for each HTTP call. The `chat`
  spans for LLM calls are `CLIENT` too.
- `SERVER`: this process is handling a call from someone else. Every API
  request handler in `apis.py` creates a `SERVER` span.

(There are two more kinds for message queues; this repo doesn't use them.)

**Status.** Status answers one question: did this operation fail? It starts
as `UNSET`, which means "nothing went wrong that we know of". Code sets
`ERROR` when it fails. In `apis.py`, the server span is set to `ERROR` only for
5xx responses: a 404 is the caller's mistake, not a failure of the API.
`run.py` sets `OK` on `agent_turn` when the turn succeeds.

**Attributes and events.** Attributes are key-value facts about this one span:
the HTTP method, the response code, the model name. Standard names such as
`http.request.method` come from the **semantic conventions** (semconv), an
agreed list of attribute names so every tool reads them the same way; the
`gen_ai.*` ones are the subject of [module 3](03-genai-semconv.md). An
**event** is a timestamped note inside a span; when a tool fails, the repo
records an `exception` event with the error message and stack trace.

**Worked example: the client/server pair.** When the researcher's tool calls
`kb-search-api`, two spans describe the same HTTP call, one in each process:

```text
support-agent process                       kb-search-api process
─────────────────────                       ─────────────────────
GET /v1/search  kind=CLIENT                 GET /v1/search  kind=SERVER
  trace_id = 386d73b9...                      trace_id = 386d73b9...   (same)
  span_id  = 9d8147da...  ◀──────────────────  parent_span_id = 9d8147da...
                                              span_id  = 2b82646c...
```

The server span's parent is the client span. The client span measures the
whole call from the agent's side, including the network. The server span
measures only the time the API spent handling it. That pair is how a backend
draws an edge between two services: query 7 in `queries.sql` joins every
server span to the client span that is its parent, and reports "which service
calls which".

### Context: the current span inside one process

**Why.** When `call_api` starts its client span, how does it know its parent
is the tool span? Passing a "parent" argument through every function would be
tedious, and libraries you don't control couldn't do it.

**What.** OpenTelemetry keeps a **context**: an invisible value that holds
"the current span" (plus the current baggage) for the code that's running
right now. Think of it as a name badge you're wearing: anyone who meets you
can see which team you're on without asking.

`start_as_current_span(...)` does two things: it starts a span whose parent
is the current span, and it makes the new span current until the `with` block
ends. So nesting `with` blocks makes nesting spans, with no extra arguments.
This is the core of `docs/tutorial/labs/hello_span.py`:

```python
with tracer.start_as_current_span("parent"):
    with tracer.start_as_current_span("child", attributes={"step": 1}):
        ...
```

`child` is started while `parent` is current, so `child`'s parent span id is
`parent`'s span id, and both get the same trace id. `parent` started when no
span was current, so it became a root span and got a brand-new random trace
id. The same thing happens in `run.py`: `agent_turn` starts with nothing
current, so it is the root of the turn's trace.

### Propagation: carrying context across the network

**Why.** Context lives in memory, inside one process. `kb-search-api` is a
different process; it can't see the agent's memory. Without help, its server
span would start with no current span, become a root span, and get its *own*
new trace id. You'd have two unrelated traces and no way to join them.

**What.** **Propagation** copies the context into the outgoing request, and
copies it back out on the other side. For HTTP, it travels in **headers**:
the `name: value` lines sent before the body of an HTTP request (like
`Content-Type: application/json`). OpenTelemetry uses two standard headers
from the W3C (the web standards body):

- `traceparent`: the trace id and the caller's span id.
- `baggage`: the baggage key-value pairs (explained below).

The analogy: when you visit another office, you carry a letter of
introduction that says "this visitor belongs to case 386d73b9, sent by person
9d8147da". The receiving office files its own notes under the same case and
names the sender as the parent.

**How it looks in this repo.** Two calls do the work:

- `propagate.inject(headers)` reads the current context and writes the
  headers into a dictionary. `call_api` in `agent/telemetry.py` calls it
  *inside* its client span, so the span id it writes is the client span's id:

  ```python
  with get_tracer().start_as_current_span(f"{method} {route}", kind=SpanKind.CLIENT, ...) as span:
      headers = {"Content-Type": "application/json"}
      propagate.inject(headers)
  ```

- `propagate.extract(headers)` reads those headers on the receiving side and
  returns a context. `apis.py` passes that context when it starts its server
  span, so the server span becomes a child of the agent's client span:

  ```python
  parent = propagate.extract({key.lower(): value for key, value in self.headers.items()})
  ...
  with tracer.start_as_current_span(name, context=parent, kind=SpanKind.SERVER, ...) as span:
  ```

  The header names are lower-cased first. Python's `urllib` sends the header
  as `Traceparent` with a capital T, and the extractor looks up the
  lower-case key `traceparent`.

**Reading a `traceparent` header.** Here is a pair of headers printed by the
lab script:

```text
traceparent: 00-12d64ae6b9afa411e15ca3a7c1726609-01aa4e70b23ff052-03
             │  │                                │                └ flags (01 = sampled)
             │  │                                └ span id of the caller (the new parent)
             │  └ trace id
             └ version
baggage:     org.tenant=acme_corp
```

Four parts separated by dashes: the format version (`00`), the trace id (32
hex characters), the span id of the span that sent the request (16 hex
characters), and flags. The receiver keeps the trace id and uses the span id
as its parent. The flags are explained in "Check yourself" below.

```mermaid
sequenceDiagram
  participant T as support-agent: execute_tool span
  participant C as support-agent: GET /v1/search (CLIENT)
  participant S as kb-search-api: GET /v1/search (SERVER)
  T->>C: start_as_current_span (child of tool span)
  C->>C: propagate.inject(headers)
  C->>S: HTTP GET with traceparent + baggage headers
  S->>S: propagate.extract(headers)
  S->>S: start server span with context=parent
  S-->>C: HTTP 200
```

Nothing about this is AI-specific: any HTTP service, database client or batch
job joins a trace the same way. [Module 6](06-cross-environment.md) covers
what has to hold for that to work across services and environments.

### Lab 1 (5 min): spans, context and headers

Run the lab script. It sets up OpenTelemetry with an exporter that prints
spans to the terminal instead of sending them, starts `parent` and then
`child` inside it, and prints the headers that `propagate.inject` would send:

```bash
cd agent && .venv/bin/python ../docs/tutorial/labs/hello_span.py
```

You should see something like this (ids are random, and the output is
shortened):

```text
Headers a client would send: {'traceparent': '00-979bfbd9d471a3865291b978e75b8e35-d90841a00167415a-03', 'baggage': 'org.tenant=acme_corp'}
{
    "name": "child",
    "context": {
        "trace_id": "0x979bfbd9d471a3865291b978e75b8e35",
        "span_id": "0xd90841a00167415a",
        ...
    },
    "kind": "SpanKind.INTERNAL",
    "parent_id": "0x321b58bf3d7e32fa",
    ...
    "attributes": {
        "step": 1
    },
    ...
    "resource": {
        "attributes": {
            "telemetry.sdk.language": "python",
            "telemetry.sdk.name": "opentelemetry",
            "telemetry.sdk.version": "...",
            "service.instance.id": "...",
            "service.name": "hello",
            "org.owner": "me"
        },
        ...
    }
}
{
    "name": "parent",
    "context": {
        "trace_id": "0x979bfbd9d471a3865291b978e75b8e35",
        "span_id": "0x321b58bf3d7e32fa",
        ...
    },
    "parent_id": null,
    ...
}
```

Look for:

- `child.parent_id` equals `parent`'s `span_id`, and both share a `trace_id`.
  `parent` has `parent_id: null`: it's the root.
- The span id inside `traceparent` is `child`'s span id, because `inject` ran
  while `child` was current. A server receiving this request would become
  `child`'s child.
- `child` printed **before** `parent`: spans are sent when they *end*, and the
  inner `with` block ends first.

Keep this output handy: the `baggage` header and the `resource` block are the
next two sections.

### Baggage: request-wide values you carry along

**Why.** Some facts belong to the whole request, not to one span: which
customer (tenant) it's for, or a request id that support staff can search for.
The API needs them too, but the agent's attributes stay in the agent's
process.

**What.** **Baggage** is a set of key-value pairs stored in the context and
sent in the `baggage` header with every outgoing call. The key point:
baggage is *not* automatically added to spans. It's like luggage you carry on
a trip: it goes everywhere with you, but nobody unpacks it unless they choose
to. Each receiver decides which keys, if any, to copy onto its own spans. Look
at the Lab 1 output: `org.tenant` is in the `baggage` header but in neither
span's attributes.

**How it looks in this repo.**

1. `agent/run.py`, before each turn, puts a fresh request id and (if the
   agent has tenants) a tenant into baggage, and attaches that context:

   ```python
   ctx = baggage.set_baggage("org.request_id", request_id)
   if tenant:
       ctx = baggage.set_baggage("org.tenant", tenant, ctx)
   token = context.attach(ctx)
   ```

   `run.py` also puts the same two values on `agent_turn` as attributes,
   because baggage alone wouldn't make them show up there.

2. `propagate.inject(...)` in `call_api` writes them into the `baggage`
   header of every API call made during the turn.

3. `apis.py` reads the keys listed in each service's `span_labels` out of the
   extracted context and copies them onto its server span:

   ```python
   for label in service.span_labels:
       value = baggage.get_baggage(label, parent)
       if value:
           attributes[label] = value
   ```

   `kb-search-api` and `pricing-api` copy `org.tenant` and `org.request_id`.
   `ticket-api` copies only `org.request_id`, so its spans have no tenant even
   though the header carried one.

### Resource: who produced the spans

**Why.** A span that says "GET /v1/search took 230 ms" is useless if you
don't know which service sent it, which version, or which team to call. You
could add `service.name` to every span by hand, but you'd forget some, and
you'd repeat the same values millions of times.

**What.** The **resource** describes the producer: `service.name`,
`service.version`, `deployment.environment.name`, and in this repo also
`org.owner` and `org.service`. It's set once, when the process sets up
tracing, and attached to every span the process exports. In the Lab 1 output,
the `resource` block is identical on both spans for that reason. Rule of
thumb: **resource = who, attributes = what**. The resource is the return
address on an envelope; attributes are what's written in the letter.

**How it looks in this repo.** `setup_tracing` in `agent/telemetry.py` builds
it from the service name plus whatever attributes the caller passes:

```python
resource = Resource.create({"service.name": service_name, **attributes}, schema_url=SCHEMA_URL)
```

`run.py` passes `service.namespace`, `service.version`,
`deployment.environment.name=local`, `org.service` and `org.owner` (for
support-agent, `org.owner=ai-platform`). `apis.py` passes the shared
`COMMON_RESOURCE` plus each API's own labels.

`Resource.create` also merges in two other sources: `telemetry.sdk.*`
attributes (the SDK's language, name and version) and anything in the
`OTEL_RESOURCE_ATTRIBUTES` environment variable. The attributes passed in code
are applied **last, on top**, so the environment variable can only **add**
keys the code doesn't set; it can't change ones it does. For example, `run.py`
hard-codes `deployment.environment.name=local`, so setting
`OTEL_RESOURCE_ATTRIBUTES=deployment.environment.name=prod` on an agent changes
nothing, while `OTEL_RESOURCE_ATTRIBUTES=lab.run=test1` adds a new
`lab.run` key. Lab 2 shows both.

### Labels: resource labels and span labels

"Labels" is this repo's word for the ownership and context attributes in the
`org.*` namespace. Which kind a label is depends on where it lives:

| Kind | Lives on | Describes | Examples | Set by |
|---|---|---|---|---|
| Resource label | The resource, once per process | Who sent the span, and where it runs | `org.owner`, `org.service`; `org.env`, `org.region` | The service; the gateway stamps the platform ones |
| Span label | Each span | This particular request | `org.tenant`, `org.request_id`, `org.agent.interface` | The service, per request, often copied from baggage |

Where a label lives matters. The gateway drops spans whose **resource** lacks
`org.owner` and `org.service`. `legacy-hr-api` puts those two labels on its
spans (through `span_attributes` in `apis.py`) and leaves its resource empty,
so every one of its spans is dropped. Same keys, wrong place.
[Module 4](04-collector.md) shows the filter that does it.

A quick way to decide where a fact goes:

| Question | Put it on | Example |
|---|---|---|
| Is it the same for every span this process sends? | The resource | `org.owner=search-platform` |
| Does it describe this one operation? | A span attribute | `http.response.status_code=504` |
| Does a *downstream* service need it too? | Baggage, then copy it onto spans where wanted | `org.tenant=globex` |

### API and SDK: why there are two packages

**Why.** A library author (say, of an HTTP client) wants to add spans to their
library. But they can't force every user to send telemetry, or pick where it
goes. So OpenTelemetry splits the job in two.

**What.**

- The **API** (`opentelemetry-api`) is the set of calls that create spans:
  `trace.get_tracer(...)`, `start_as_current_span(...)`,
  `propagate.inject(...)`. Libraries depend only on this. If no SDK has been
  set up, every call is a **no-op** (it does nothing and records nothing), so
  instrumented libraries cost almost nothing.
- The **SDK** (`opentelemetry-sdk`) is the real implementation, chosen by the
  application owner: the tracer provider, span processors, exporters.

It's like a wall socket and a power plant. Appliances (libraries) are built to
the socket standard (the API). Until someone connects the house to a power
plant (installs and configures the SDK), plugging in does nothing.

In this repo, `get_tracer()` and the span code use the API. `setup_tracing`
is the only place that touches the SDK, and it runs once at process start.

### The SDK pipeline: from a span to the network

Here is the path a span takes inside one process:

```text
Tracer ─start span─▶ Span ─end()─▶ SpanProcessor ─▶ Exporter ─OTLP─▶ Collector
 (API)                              (Batch: queue)    (HTTP)
```

The analogy is a post office. You write letters (spans) at your desk. When a
letter is finished, you drop it in the out-tray (the span processor). A clerk
collects the tray every few seconds, or sooner if it fills up, and drives the
bundle to the sorting center (the exporter sends it to the Collector).

Each piece, as `setup_tracing` builds it:

```python
os.environ.setdefault("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:14318")  # 1
resource = Resource.create({"service.name": service_name, **attributes}, ...)   # 2
provider = TracerProvider(resource=resource)                                    # 3
provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter()))            # 4
trace.set_tracer_provider(provider)                                             # 5
```

1. Sets the default address to send to, unless the environment variable is
   already set.
2. Builds the resource ("who am I").
3. Creates the **tracer provider**: the one object per process that holds the
   SDK setup. It also holds the sampler, the part that decides whether to
   record a trace at all. No sampler is passed here, so the SDK default,
   `parentbased_always_on`, is used unless `OTEL_TRACES_SAMPLER` says
   otherwise: root spans are always recorded, and child spans follow their
   parent's decision. [Module 5](05-sampling.md) covers sampling.
4. Adds a **batch span processor** that feeds an **OTLP exporter**.
5. Registers the provider globally, so every API call in the process now
   goes to the SDK instead of being a no-op.

**The tracer and its instrumentation scope.** `get_tracer()` asks the provider
for a **tracer**, the object with `start_as_current_span`:

```python
trace.get_tracer("agent-tracing", "0.1.0", schema_url=SCHEMA_URL)
```

The name and version, `agent-tracing` and `0.1.0`, are the **instrumentation
scope**: they say which code made the span (an instrumented HTTP library would
use its own name). Every span carries its scope, and in ClickHouse it becomes
the `ScopeName` and `ScopeVersion` columns ([module 8](08-data-model.md)). In
this repo every span, from agents and APIs alike, has scope `agent-tracing`.

**The batch span processor.** `BatchSpanProcessor` keeps finished spans in an
in-memory queue and exports them in batches from a background thread, so your
code never waits for the network. Defaults: queue 2048 spans, batch 512,
every 5 s. Two consequences:

- **If the queue is full, new spans are dropped.** The queue is in memory; it
  is not a durable buffer.
- Spans still in the queue when the process exits are lost, unless you call
  `provider.shutdown()`, which flushes whatever is left. That's why `run.py`
  and `apis.py` both call it before exiting.

The lab script uses the simpler `SimpleSpanProcessor` instead, which exports
each span immediately when it ends. That's handy for printing, but too slow
for real services because the code waits for every export.

**The exporter and OTLP.** The exporter turns spans into bytes and sends them.
This repo uses `OTLPSpanExporter` from the
`opentelemetry.exporter.otlp.proto.http` package. **OTLP** is the
OpenTelemetry Protocol: spans encoded with protobuf (a compact binary format)
and sent either over HTTP (port 4318) or over gRPC (a binary RPC protocol
built on HTTP/2, port 4317). This repo maps them to 14318 and 14317 on the
host; the Python code uses HTTP. The lab uses `ConsoleSpanExporter`, which
prints spans as JSON instead of sending them.

**Configuration without code changes.** Much of this can be set through
environment variables: `OTEL_EXPORTER_OTLP_ENDPOINT` (where to send),
`OTEL_RESOURCE_ATTRIBUTES` (extra resource attributes; adds keys, but can't
replace keys set in code), `OTEL_TRACES_SAMPLER` (which sampler),
`OTEL_BSP_MAX_QUEUE_SIZE` and `OTEL_BSP_SCHEDULE_DELAY` (the batch processor's
queue size and delay; BSP stands for batch span processor).

### Putting it together

The running example, end to end, with each concept named:

```text
run.py         setup_tracing: resource + TracerProvider + BatchSpanProcessor + OTLP exporter
run.py         baggage: org.request_id, org.tenant       (context now holds baggage)
run.py         agent_turn                ROOT, new trace id, INTERNAL
                 ...graph spans (module 2)...
telemetry.py     execute_tool search_knowledge_base      made current
telemetry.py       GET /v1/search  CLIENT  propagate.inject -> traceparent + baggage headers
apis.py              GET /v1/search  SERVER  propagate.extract, same trace id,
                                             parent = client span, copies baggage labels
both processes   spans end -> batch queue -> OTLP/HTTP -> localhost:14318 -> gateway
```

## Remember it

> **A trace is a family tree. The trace id is the surname, the span id is
> the first name, the parent id says who your parent is. `traceparent` is the
> letter of introduction you carry when you visit another service.**

And: **resource = who, attributes = what, baggage = luggage you carry but
don't unpack unless you choose to.**

And for the SDK: **API = the socket, SDK = the power plant, batch processor =
the out-tray, exporter = the courier, OTLP = the shape of the parcel.**

## In this repo

- `agent/telemetry.py`, `setup_tracing`: resource, `TracerProvider`,
  `BatchSpanProcessor`, `OTLPSpanExporter`. The endpoint defaults to
  `http://localhost:14318`.
- `agent/telemetry.py`, `get_tracer`: the tracer every span in the repo is
  started from (scope `agent-tracing`).
- `agent/telemetry.py`, `call_api`: a `CLIENT` span per HTTP call, and
  `propagate.inject(headers)`.
- `agent/apis.py`, the request handler: `propagate.extract(...)` on
  lower-cased headers, and a `SERVER` span whose parent is the caller's client
  span. `SERVICES` shows each API's resource labels and which baggage keys it
  copies (`span_labels`).
- `agent/run.py`: puts `org.request_id` and `org.tenant` into baggage before
  each turn, starts the root `agent_turn` span, and calls
  `provider.shutdown()` at the end.
- `agent/agents.py`: each agent's `owner` (which becomes the `org.owner`
  resource label) and `tenants` (which `run.py` picks from for baggage).
  `sales-agent` has no tenants, so its requests carry no `org.tenant`.
- `docs/tutorial/labs/hello_span.py`: the smallest possible example: two
  nested spans, baggage, and the headers `inject` writes.

## Lab 2 (10 min): resource, and spans in ClickHouse

Lab 1 is in the middle of the Idea section. Run these from the `agent`
directory.

1. **Add to the resource without changing code, and see what you can't
   change.** `hello_span.py` sets `service.name` and `org.owner=me` in code,
   but not `deployment.environment.name`. Set both through
   `OTEL_RESOURCE_ATTRIBUTES` (comma-separated `key=value` pairs); `grep`
   keeps only the matching lines:

   ```bash
   OTEL_RESOURCE_ATTRIBUTES=deployment.environment.name=lab,org.owner=someone-else \
     .venv/bin/python ../docs/tutorial/labs/hello_span.py | grep -E 'environment|org.owner'
   ```

   ```text
               "deployment.environment.name": "lab",
               "org.owner": "me",
               "deployment.environment.name": "lab",
               "org.owner": "me",
   ```

   What to notice:
   - Two of each line, one per span, because the resource is attached to
     every span the process exports.
   - `deployment.environment.name=lab` was **added**: the code didn't set it.
   - `org.owner` is still `me`: the code sets it, and code attributes win. The
     agents and APIs behave the same way, since `setup_tracing` also uses
     `Resource.create`. That's why the agents' `deployment.environment.name`
     stays `local` whatever the variable says.

2. **Find the client/server pair in ClickHouse.** Open
   <http://localhost:8123/play> (user `default`, password `demo`). This query
   joins the table to itself: for each `Client` span `c`, it finds a `Server`
   span `s` in the same trace whose parent is `c`, then counts the pairs:

   ```sql
   SELECT c.ServiceName AS caller, s.ServiceName AS callee, c.SpanName, count() AS calls
   FROM otel.otel_traces AS c
   JOIN otel.otel_traces AS s ON s.TraceId = c.TraceId AND s.ParentSpanId = c.SpanId
   WHERE c.SpanKind = 'Client' AND s.SpanKind = 'Server'
   GROUP BY caller, callee, c.SpanName;
   ```

   You should see something like this (counts will differ):

   ```text
   hr-agent       ticket-api     POST /v1/tickets       1355
   sales-agent    pricing-api    GET /v1/prices/{sku}   3391
   support-agent  kb-search-api  GET /v1/search         1373
   ```

   What to notice:
   - Each row is one edge in a service map, found purely from trace ids and
     parent span ids. Nothing else tells ClickHouse that these services talk.
   - The span names are route templates (`{sku}`), so all prices group into
     one row.
   - `hr-agent` also calls `legacy-hr-api`, but there's no row for it: the
     gateway dropped `legacy-hr-api`'s server spans, so the join finds no
     partner.

3. **See the instrumentation scope.** In the same Play UI:

   ```sql
   SELECT ScopeName, ScopeVersion, count() AS spans
   FROM otel.otel_traces GROUP BY ScopeName, ScopeVersion;
   ```

   ```text
   agent-tracing  0.1.0  51562
   ```

   One row: every span in the repo comes from the tracer `get_tracer()`
   returns. If you added an auto-instrumented library, its spans would show up
   under its own scope name.

## Explain it back

> "A span is a timed operation with attributes and a status; spans with the
> same trace id form a tree through parent ids. Inside a process, the current
> span lives in the context, so nested spans become children. Between
> processes, the client injects the W3C `traceparent` header, and the server
> extracts it and starts its span as a child of the client span. Baggage rides
> along for request-wide values like tenant. The SDK buffers spans in a batch
> processor and exports them over OTLP; the resource tells the backend which
> service sent them."

## Recap

- A span is one timed step; a trace is every span of one request, tied
  together by a shared trace id and arranged into a tree by parent span ids.
- Span names don't contain ids (route templates, not SKUs); specific values
  go in attributes.
- A `CLIENT` span in the caller and a `SERVER` span in the callee describe the
  same call; the server span's parent is the client span.
- Context holds the current span inside a process. `start_as_current_span`
  uses it and updates it, so nested blocks make nested spans.
- Propagation carries context across HTTP: `inject` writes `traceparent` and
  `baggage` headers, `extract` reads them.
- Baggage travels with the request but only lands on spans when code copies
  it, as `apis.py` does for `org.tenant` and `org.request_id`.
- Resource = who (once per process), attributes = what (per span). The
  gateway requires `org.owner` and `org.service` on the resource.
  `OTEL_RESOURCE_ATTRIBUTES` can add resource keys but not override keys set
  in code.
- The API is a no-op until the SDK is set up. The tracer provider holds the
  setup; the tracer's name is the instrumentation scope (`ScopeName`); the
  batch processor queues spans; the exporter sends them over OTLP;
  `shutdown()` flushes the queue.

## Check yourself

<details><summary>A span's name is <code>GET /v1/prices/sku-123</code>. What's wrong?</summary>

The name contains an id, so every SKU becomes a different span name, which
breaks grouping and indexing. Use the route template
(`GET /v1/prices/{sku}`) and put the SKU in an attribute if needed. This repo
does that through `url.template` on the client span (and `http.route` on the
server span).
</details>

<details><summary>What happens to spans if the collector is down for 10 minutes?</summary>

The exporter fails and retries; meanwhile the `BatchSpanProcessor` queue fills
up (2048 spans by default) and then **drops new spans**. The SDK is not a
durable buffer. That's one reason to run a Collector close to the app.
</details>

<details><summary>Why doesn't baggage show up as span attributes by itself?</summary>

Baggage is propagated data, not telemetry; copying it everywhere could leak
data or add a huge number of distinct values to every span. Each service
decides which baggage keys to copy onto its spans (or uses a baggage span
processor to do it for all spans).
</details>

<details><summary>You run an agent with <code>OTEL_RESOURCE_ATTRIBUTES=deployment.environment.name=staging</code>. What environment do its spans show?</summary>

Still `local`. `run.py` passes `deployment.environment.name=local` to
`setup_tracing`, and `Resource.create` applies code attributes on top of the
environment variable. The variable can only add keys the code doesn't set. To
change the environment, change the code (or stop hard-coding that key).
</details>

<details><summary>What do the flags <code>03</code> in <code>traceparent</code> mean?</summary>

The flags are two hex digits holding bits. `03` is bits `01` and `02` both set.
Bit `01` is "sampled": the caller recorded this trace, so a downstream service
using the default parent-based sampler will record it too
([module 5](05-sampling.md)). Bit `02` is the newer "random" flag (W3C Trace
Context level 2): the trace id was generated randomly.
</details>

<details><summary><code>kb-search-api</code> forgets to call <code>propagate.extract</code>. What does the trace look like?</summary>

The agent's trace still has its `GET /v1/search` client span, but it has no
child. The API's server span starts with no current span, so it becomes a
root span with a new trace id: a separate, one-span trace. The query in Lab 2
step 2 would find no pair for it. You can see this effect with
`STRIP_TRACE_HEADERS=1`, which makes `apis.py` extract from empty headers.
</details>

<details><summary><code>legacy-hr-api</code> sends <code>org.owner</code> and <code>org.service</code>. Why are its spans dropped anyway?</summary>

It sends them as span attributes, not as resource attributes. The gateway's
filter checks only the resource, so to the gateway these spans have no owner
or service, and it drops them.
</details>

<details><summary>Why does <code>run.py</code> call <code>provider.shutdown()</code> at the end?</summary>

The batch processor sends spans every 5 seconds from a background thread. When
`run.py` finishes its last turn, the most recent spans are probably still in
the queue. `shutdown()` flushes them to the exporter before the process exits;
without it, the last turn would often be missing.
</details>

<details><summary>A library you use is instrumented with OpenTelemetry, but you never call <code>setup_tracing</code>. Do you get spans?</summary>

No. The library calls the API, and with no SDK tracer provider registered,
those calls are no-ops. Nothing is recorded or sent.
</details>

## Next

You now know how one span finds its parent. But who creates the
`invoke_agent`, `chat` and `execute_tool` spans inside a turn, when LangGraph
runs the graph and not our code? [Module 2](02-langgraph.md) shows how
LangChain callbacks are turned into those spans, and where context has to be
set by hand so HTTP calls get the right parent.

## Read more

- [Traces](https://opentelemetry.io/docs/concepts/signals/traces/)
- [Context propagation](https://opentelemetry.io/docs/concepts/context-propagation/)
- [Resources](https://opentelemetry.io/docs/concepts/resources/)
- [Python instrumentation guide](https://opentelemetry.io/docs/languages/python/instrumentation/)
- [SDK environment variables](https://opentelemetry.io/docs/specs/otel/configuration/sdk-environment-variables/)
- [W3C Trace Context](https://www.w3.org/TR/trace-context/) and [W3C Baggage](https://www.w3.org/TR/baggage/)
- [OTLP specification](https://opentelemetry.io/docs/specs/otlp/)

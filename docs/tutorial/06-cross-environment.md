# Module 6: Joining services and environments into one trace (30 min)

## Why this matters

A real request rarely stays inside the agent. The agent calls plain HTTP APIs,
those APIs call databases, and some of them run in a different environment
(dev versus prod, another cluster, another cloud account). In
[module 1](01-otel-core.md) you saw how one hop works: the caller injects
`traceparent`, the callee extracts it. This module is about everything else:
**the checklist** that must hold for every service and environment to land in
one trace, and **the failure modes** you'll see in storage when one item on
that checklist is missing.

**What you'll be able to do:**

- List the five conditions a service must meet to appear inside the agent's
  trace, and recognize the mark each failure leaves.
- Name the extra things that must hold when the request crosses environments.
- Choose between central collection and per-environment storage.
- Run two gateways for two environments and see one trace in the database.

Modules 7 and 8 cover ClickHouse, the database the gateway writes to. For now
you only need to know that every span becomes one row in the table
`otel.otel_traces`, and that the gateway's labels show up as columns such as
`org_env`.

## Key terms

Reminders from earlier modules: a **span** is one timed operation and a
**trace** is all the spans of one request ([module 1](01-otel-core.md));
**`traceparent`** and **baggage** are the headers that carry the trace across
processes (module 1); an **orphan span** is one whose parent was never stored
([module 5](05-sampling.md)); the **gateway** is the Collector that labels and
stores spans ([module 4](04-collector.md)).

| Term | Plain meaning |
|---|---|
| **Hop** | One step from one process to another: an HTTP call, a message on a queue, a request through a proxy. |
| **Environment** | One place the software runs: a cluster, cloud account, or region. Here labeled `org.env` (`dev`, `prod`). |
| **Uninstrumented callee** | A service you call that emits no spans: a database, a SaaS API, a legacy system you don't own. |
| **Auto-instrumentation** | A library or agent that creates spans and handles inject/extract for common frameworks, without you writing that code. |
| **Span link** | A pointer from one span to a span in *another* trace. Used when you want "related to" rather than "child of". |
| **Clock skew** | Two hosts' clocks disagreeing by a few milliseconds or more, so their timestamps don't line up exactly. |
| **Trust boundary** | The edge where requests from outside callers you don't control enter your system. |
| **Central collection** | Every environment's gateway forwards to one central gateway and one store. |

## Idea

### Recap: one hop, from module 1

The running example: a user asks the HR assistant, "I need a new laptop." The
`hr-agent` runs its `create_ticket` tool, which calls `ticket-api` over HTTP.

1. `call_api` in `agent/telemetry.py` opens a client span, `POST /v1/tickets`,
   and calls `propagate.inject(headers)`. That writes `traceparent` (trace id
   plus the client span's id) and `baggage` (`org.request_id`, `org.tenant`).
2. `ticket-api` (`agent/apis.py`) calls `propagate.extract(...)` and starts
   its server span with `context=parent`. The server span gets the same trace
   id, and its parent is the client span.
3. Each process exports only its own spans. There is **no merge step**: the
   shared trace id *is* the join.

[Module 1](01-otel-core.md#propagation-carrying-context-across-the-network)
walks through the code and the `traceparent` format. The rest of this module
asks: what has to go right, on every hop, for that to keep working?

### The checklist: five conditions per service

The same pattern applies to any service with no LLM in it: an HTTP API, a
database client, a batch job. In this repo, `kb-search-api`, `ticket-api`,
`pricing-api` and `legacy-hr-api` are such services. All five conditions
must hold for a service's spans to sit inside the agent's trace:

| # | Condition | In this repo | If it doesn't hold |
|---|---|---|---|
| 1 | The caller **injects** context into the request | `propagate.inject(headers)` in `call_api` writes `traceparent` and `baggage` | The callee starts a new, unrelated trace |
| 2 | The service **extracts** it and starts its server span from it | `propagate.extract(...)` in `apis.py` | Same: a new trace per request |
| 3 | Every hop in between **forwards the headers** | Direct calls on localhost | Separate traces (`STRIP_TRACE_HEADERS=1`, lab step 2) |
| 4 | The service's spans **reach the same store** and pass its rules | Gateway requires `org.owner` and `org.service` on the resource | Only the caller's client span appears (`legacy-hr-api`, lab step 3) |
| 5 | The service samples **parent-based** (follows the caller's "sampled" flag) | The SDK default | Orphan spans, or missing halves ([module 5](05-sampling.md)) |

The HR laptop request touches three callees, and each shows a different row
of this table:

- `ticket-api` meets all five, so its `POST /v1/tickets` server span sits
  under the agent's client span.
- `legacy-hr-api` (called by the `lookup_employee` tool) fails condition 4.
  Its spans are sent, but dropped by the gateway.
- Postgres, which `ticket-api` writes the ticket to, is an uninstrumented
  callee (see below).

For a real service you rarely write conditions 1 and 2 yourself.
**Auto-instrumentation** does it for common frameworks and HTTP clients:
`opentelemetry-instrument python app.py` with the Flask, FastAPI or requests
instrumentation packages in Python; the Java agent jar; or
`@opentelemetry/auto-instrumentations-node` for Node. This repo writes the two
calls by hand so you can see them.

**Callees you can't instrument.** You still get the caller's **client span**,
with its duration, status and error, but nothing inside the callee.
`INSERT tickets` from `ticket-api` to Postgres is such a span here: `ticket-api`
records how long the insert took, and that's all. Beyond that, the fallback is
matching on a business id the callee logs (such as `org.request_id`). That's a
workaround, not a trace.

### What breaks the chain

Each failure leaves a recognizable mark in storage.

**1. Something in between strips the headers.** Proxies, API gateways, load
balancers and WAFs (web application firewalls) sometimes drop headers they
don't recognize. The request still arrives, but without `traceparent` and
`baggage`. The service extracts an empty context, so its server span becomes
the root of a brand-new trace, and the tenant from baggage is gone.

This repo can fake that proxy. In `agent/apis.py`:

```python
if os.environ.get("STRIP_TRACE_HEADERS") == "1":
    # Simulates a proxy between environments that drops traceparent and baggage.
    parent = propagate.extract({})
else:
    parent = propagate.extract({key.lower(): value for key, value in self.headers.items()})
```

With `STRIP_TRACE_HEADERS=1`, the service extracts from an empty dict, exactly
as if a proxy had removed the headers. Lab step 2 runs it.

```text
Healthy:   agent ──traceparent──▶ proxy ──traceparent──▶ api      one trace
Stripped:  agent ──traceparent──▶ proxy ───(nothing)───▶ api      two traces
```

**2. The service's spans never reach storage.** The gateway's
`filter/require_org_labels` drops spans whose resource lacks `org.owner` or
`org.service`; `legacy-hr-api` puts them on the span instead
([module 4](04-collector.md)). Mark: a client span with nothing under it.

**3. Orphan spans.** The callee kept its span but the caller's sampler
dropped the parent, because the two didn't agree
([module 5](05-sampling.md)). Mark: a `ParentSpanId` that matches no row.

**4. The callee emits nothing.** Not a breakage: the client span is all you
will ever get for an uninstrumented callee.

### Across environments

Now put the agent in one environment (say, `dev`) and the APIs in another
(`prod`), each with its own gateway. Everything above still applies, and four
more things have to hold:

| # | Requirement | Typical way it breaks | Fix |
|---|---|---|---|
| 1 | **Context crosses the boundary** | A proxy, API gateway or WAF drops or rewrites `traceparent` and `baggage`; a message queue carries no headers; an async job starts later | Allow-list the W3C headers on every hop; inject context into message headers; use **span links** for async or batch work |
| 2 | **Spans end up queryable together** | Each environment writes to its own backend | Forward to one central store, **or** query across stores by trace id |
| 3 | **Sampling decisions agree** | Each side samples independently | Parent-based sampling everywhere; tail sampling only where all spans of a trace meet ([module 5](05-sampling.md)) |
| 4 | **You can tell environments apart** | Same service name in both; no environment label | Each environment's gateway stamps `org.env`, `org.region` and so on |

Requirement 4 is why the environment labels are set by the gateway, not by
the services. A service doesn't need to know where it runs; the gateway in
each environment knows, and stamps every span passing through with `upsert`,
which overwrites whatever the service sent ([module 4](04-collector.md)). So
`org.env` is the authoritative environment label. You'll see in lab step 1
that a service's own `deployment.environment.name` can say something else.

### Clock skew

Each host timestamps its own spans with its own clock. If two clocks differ by
a few milliseconds, a server span in `prod` can appear to start before its
client span in `dev`, which is impossible in reality. Trust the parent/child
ids over the timestamps, and keep hosts in sync with NTP (the Network Time
Protocol). Don't compute "time spent in the network" from timestamps taken on
two different hosts unless you know their clocks agree.

### Trust boundaries

At a public edge, you may *not* want to continue a caller's trace. An outside
client could set the "sampled" flag to force you to keep everything, or send
made-up trace ids that collide with yours. Start a new trace there, and add a
**span link** to the incoming context, so the relationship is still recorded
without letting outsiders control your trace ids or sampling.

### Architecture patterns

**A. Central collection** (simplest to query). Each environment has its own
gateway, and they all forward to one central gateway and one database:

```text
env A apps ─▶ env A gateway ─┐
                             ├─ OTLP ─▶ central gateway ─▶ one ClickHouse
env B apps ─▶ env B gateway ─┘
```

Each environment's gateway stamps its own `org.env` and region, then exports
with the `otlphttp` exporter (the Collector's output that sends OTLP over
HTTP, the same protocol the SDK uses in this repo) to the central tier. The
trace ids already match, because context was propagated, so nothing needs to
be merged: the spans simply land in the same table. Tail sampling, if you
use it, belongs at this central tier, where all spans of a trace meet.

**B. Store per environment, combine at query time.** The data stays in each
environment, for example because of data-residency rules. You ask both stores
for the same trace id and glue the results together. In ClickHouse, the
`remote()` function queries a table on another server from inside a query, so
one `UNION ALL` can combine both halves:

```sql
SELECT * FROM otel.otel_traces WHERE TraceId = '...'
UNION ALL
SELECT * FROM remote('clickhouse.env-b.internal', otel.otel_traces, 'reader', '...') WHERE TraceId = '...';
```

A `Distributed` table (a table that forwards queries to a list of servers,
[module 9](09-sharding-indexes.md)) can do the same thing permanently. Either
way, the trace id is the join key. Copying data between ClickHouse servers,
including `remote()`, is covered in [module 10](10-copying-data.md).

**C. Propagation was lost: correlate after the fact.** If something on the
way drops the trace headers, the two halves have different trace ids, and no
storage trick can rejoin them reliably. You can correlate on a business id
that survives (an `X-Request-Id` header the proxy keeps, a ticket id), but
it's a workaround. **Fix the propagation.**

## Remember it

> **A trace crosses environments only if its passport (`traceparent`) gets
> through every border, and all its travel photos end up in one album, or
> albums you can flip through together.**
>
> Merge happens at the **trace id**, never by time or service name.

## In this repo

| What | Where | What it does |
|---|---|---|
| Inject | `call_api` in `agent/telemetry.py` | `propagate.inject(headers)` adds `traceparent` and `baggage` to every API call |
| Extract | request handler in `agent/apis.py` | `propagate.extract(...)`, then starts the server span with `context=parent` and copies baggage values onto it |
| Fake header-stripping proxy | `agent/apis.py` | `STRIP_TRACE_HEADERS=1` makes the APIs ignore incoming `traceparent` and `baggage` |
| Environment labels | `otel-gateway-config.yaml` (`resource/org_platform`), `compose.yaml` | The gateway stamps `org.env`, `org.region`, `org.platform` and `org.cluster` from its own environment variables (`ORG_ENV` defaults to `dev`) |
| Mandatory labels | `otel-gateway-config.yaml` (`filter/require_org_labels`) | Drops spans whose resource lacks `org.owner` or `org.service` |
| Uninstrumented callee | `_create_ticket` in `agent/apis.py` | `ticket-api` records an `INSERT tickets` client span; Postgres records nothing |

In ClickHouse, `org.env` also has its own column, `org_env`, which the table
fills automatically from the resource attribute (module 8 explains how), so
you can filter and group on it directly.

## Lab (15 min)

Pause the background traffic first, so the lab's spans are easy to find:
`./stack.sh traffic off`.

Every command below tags its spans with a `lab.run` resource attribute
through `OTEL_RESOURCE_ATTRIBUTES` (a standard environment variable the SDK
reads to add resource labels). That lets each query pick out just that run.

1. **Two environments, one trace.** Start a second gateway, the "prod"
   environment, on host port 24318, writing to the same ClickHouse.
   `docker compose run` starts an extra container from the existing
   `otel-gateway` service definition; `-e` overrides its environment labels
   and `-p` publishes its OTLP HTTP port:

   ```bash
   docker compose run -d --name otel-gateway-prod -e ORG_ENV=prod -e ORG_REGION=eu-west \
     -p 24318:4318 otel-gateway
   ```

   Like `docker compose up`, `run` first starts the service's dependencies.
   You'll see `clickhouse-init` start and exit again; that's harmless, because
   the schema only creates what doesn't exist yet. Add `--no-deps` to skip it.

   Now run the APIs in "prod" (they send to port 24318, the prod gateway) and
   the HR agent in "dev" (it uses its default endpoint,
   `http://localhost:14318`, the normal gateway). `OTEL_EXPORTER_OTLP_ENDPOINT`
   is the standard variable that tells the SDK where to send spans. Turn 2 is
   "I need a new laptop."; every HR turn calls `ticket-api`:

   ```bash
   cd agent
   for s in kb-search-api ticket-api pricing-api legacy-hr-api; do
     OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:24318 OTEL_RESOURCE_ATTRIBUTES=lab.run=twoenv \
       .venv/bin/python apis.py --service $s >/dev/null 2>&1 &
   done
   sleep 2
   OTEL_RESOURCE_ATTRIBUTES=lab.run=twoenv .venv/bin/python run.py --agent hr-agent --turns 2
   pkill -f 'apis.py --service'
   ```

   Group the run's spans by trace id, listing which environments and services
   appear in each trace:

   ```sql
   SELECT TraceId, groupArray(DISTINCT org_env) AS envs, groupArray(DISTINCT ServiceName) AS services
   FROM otel.otel_traces WHERE ResourceAttributes['lab.run'] = 'twoenv' GROUP BY TraceId;
   ```

   ```text
   321fa6a12fa7c178883034012df40b5e  ['prod','dev']  ['ticket-api','hr-agent']
   339c05c820bfd5927e9fa051349ece83  ['prod','dev']  ['ticket-api','hr-agent']
   ```

   Each row is one trace that contains spans from both environments. The
   agent's spans went through the dev gateway and `ticket-api`'s through the
   prod gateway, yet they share a trace id, so they form one trace.
   `legacy-hr-api` is missing, as expected: the gateway drops its spans.

   Now compare the two environment labels per service:

   ```sql
   SELECT ServiceName, org_env, org_region,
          ResourceAttributes['deployment.environment.name'] AS deploy_env, count()
   FROM otel.otel_traces WHERE ResourceAttributes['lab.run'] = 'twoenv'
   GROUP BY ALL ORDER BY ServiceName;
   ```

   ```text
   hr-agent    dev   local    local  16
   ticket-api  prod  eu-west  local   4
   ```

   Both "environments" still report `deployment.environment.name = local`.
   That label is set in code (`run.py` and `COMMON_RESOURCE` in `apis.py`),
   and attributes passed in code win over `OTEL_RESOURCE_ATTRIBUTES`, which
   can only add new keys. `org.env` is stamped by whichever gateway the span
   passed through, so it's the authoritative environment label (the same
   point as in [module 4](04-collector.md)).

   Clean up the extra gateway: `docker rm -f otel-gateway-prod`.

   (Querying another environment's ClickHouse directly, and copying data
   between servers, is in [module 10](10-copying-data.md).)

2. **Break propagation.** Run some traffic with the APIs dropping the trace
   headers, like a proxy would:

   ```bash
   STRIP_TRACE_HEADERS=1 OTEL_RESOURCE_ATTRIBUTES=lab.run=stripped .venv/bin/python simulate.py --turns 3
   ```

   For each service, count how many traces its spans belong to, and how many
   of its spans are roots (empty parent id):

   ```sql
   SELECT ServiceName, uniqExact(TraceId) AS traces, countIf(ParentSpanId = '') AS root_spans
   FROM otel.otel_traces WHERE ResourceAttributes['lab.run'] = 'stripped'
   GROUP BY ServiceName ORDER BY ServiceName;
   ```

   ```text
   hr-agent       3  3
   kb-search-api  3  3
   pricing-api    6  6
   sales-agent    3  3
   support-agent  3  3
   ticket-api     3  3
   ```

   For the agents, three turns means three traces with one root each, as
   normal. But the APIs should have **zero** root spans: their server spans
   ought to be children of the agents' client spans. Instead, every API span
   is the **root of its own trace**. (`pricing-api`'s count varies, because
   the sales agent retries failed price calls.) The tenant from baggage is
   gone too: `SpanAttributes['org.tenant']` is empty on `kb-search-api`.
   This is what a header-stripping proxy does to you.

   Then turn the background traffic back on: `cd .. && ./stack.sh traffic on`.

3. **Find callees that never joined the trace.** This query lists every
   outgoing call (client span) and counts how often no server span sits under
   it. The `LEFT JOIN` looks for a server span in the same trace whose parent
   is the client span; when none exists, the joined `SpanId` comes back empty:

   ```sql
   SELECT c.ServiceName AS caller, c.SpanName, count() AS calls, countIf(s.SpanId = '') AS no_server_span
   FROM otel.otel_traces AS c
   LEFT JOIN (SELECT TraceId, SpanId, ParentSpanId FROM otel.otel_traces WHERE SpanKind = 'Server') AS s
     ON s.TraceId = c.TraceId AND s.ParentSpanId = c.SpanId
   WHERE c.SpanKind = 'Client' AND c.SpanName NOT LIKE 'chat%' AND c.Timestamp > now() - INTERVAL 1 HOUR
   GROUP BY caller, c.SpanName ORDER BY caller;
   ```

   (`NOT LIKE 'chat%'` skips the LLM calls, which go to an external model and
   never have a server span here.) Your numbers depend on how much traffic
   ran in the last hour; the pattern is what matters:

   ```text
   hr-agent      GET /employees/{employee_id}   459   459
   hr-agent      POST /v1/tickets               459     3
   sales-agent   GET /v1/prices/{sku}          1163     8
   support-agent GET /v1/search                 477     3
   ticket-api    INSERT tickets                 460   460
   ```

   Read it row by row:
   - `GET /employees/...`: **always** missing. `legacy-hr-api` sends spans,
     but the gateway drops them because `org.owner` and `org.service` are on
     the span, not the resource (condition 4).
   - `INSERT tickets`: always missing, and that's expected. It's a database
     call, and Postgres doesn't emit spans; the client span is all you get.
   - The few misses on the other routes are the stripped-headers runs from
     step 2 (condition 3).

## Explain it back

> "To see one trace across services and environments, five things must hold
> per service: the caller injects, the callee extracts, every hop forwards the
> headers, the callee's spans reach the same store and pass its rules, and
> sampling is parent-based. Across environments, the spans also have to be
> queryable together, either by forwarding every environment's gateway to a
> central store, or by querying each store by trace id at read time. Each
> environment's gateway stamps `org.env`, which is the label to trust. There's
> no merge step: the shared trace id *is* the merge. If propagation breaks,
> you get two unrelated traces, and the only way back is correlating on a
> business id."

## Recap

- Spans from different services form one trace because they share a **trace
  id** and each server span points at its caller's client span. Nothing is
  merged afterwards.
- Five conditions per service: inject, extract, headers forwarded, spans
  stored, parent-based sampling. Each failure has its own mark in storage.
- Anything that drops the headers (a proxy, a queue, `STRIP_TRACE_HEADERS=1`)
  splits the request into unrelated traces, with the callee's span as a new
  root and no baggage.
- A client span with no server span under it means: the callee isn't
  instrumented, its spans were dropped (like `legacy-hr-api`), or propagation
  broke.
- Across environments, each gateway stamps `org.env` and friends, which beat
  whatever the service says. Store centrally, or query each store by trace id.
- Trust ids over timestamps (clock skew), and start a new trace with a span
  link at a public edge (trust boundary).

## Check yourself

<details><summary>A plain REST service with no LLM is called by an agent. What does it need to show up inside the agent's trace?</summary>

It has to extract `traceparent` from incoming requests and start its server
span from that context; auto-instrumentation does this for common frameworks.
Every proxy in between must forward the headers. It also needs the resource
labels the gateway requires, an exporter pointing at the gateway, and
parent-based sampling. Nothing is merged afterwards: the shared trace id makes
it part of the trace.
</details>

<details><summary>An agent's client span has no server span under it. What are the possible causes?</summary>

The callee isn't instrumented (a database, a SaaS API). Or it's instrumented
but didn't receive or extract the headers. Or its spans were dropped on the
way, by the gateway's filter or by a sampler. Or they went to a different
backend.
</details>

<details><summary>Spans from both environments are in the same table, but the trace shows as two. Why?</summary>

The two halves have different trace ids: context didn't cross the boundary
(stripped headers, a queue without context, or a new trace started at an
edge). Look at the first server span on the far side: an empty
`ParentSpanId` means it started a new trace.
</details>

<details><summary>With <code>STRIP_TRACE_HEADERS=1</code>, why is <code>org.tenant</code> missing on <code>kb-search-api</code> spans as well?</summary>

The tenant travels in the `baggage` header, which is stripped along with
`traceparent`. The API copies `org.tenant` from baggage onto its server span,
so with no baggage there is nothing to copy.
</details>

<details><summary>In lab step 1, both services say <code>deployment.environment.name = local</code>, but <code>org_env</code> says <code>dev</code> and <code>prod</code>. Which do you trust, and why?</summary>

`org.env`. It's stamped by the gateway in the environment the span passed
through, and `upsert` overwrites anything the service sent.
`deployment.environment.name` is whatever the service's code set, and here the
code hard-codes `local`; `OTEL_RESOURCE_ATTRIBUTES` can add keys but not
override it.
</details>

<details><summary>A server span in prod starts 3 ms before its parent client span in dev. Is the trace broken?</summary>

No. That's clock skew: each host stamps its own spans with its own clock. The
parent/child ids are correct, so trust them over the timestamps, and keep the
hosts' clocks in sync.
</details>

<details><summary>Why not tail sample in each environment's gateway?</summary>

Each gateway sees only its environment's part of the trace, so they'd make
different decisions, and you'd keep fragments. Tail sample at the central tier
where the whole trace meets, or use head sampling, parent-based, end to end.
</details>

<details><summary>When should a service deliberately <em>not</em> continue an incoming trace?</summary>

At a trust boundary, such as a public API. Start a new trace and record a span
link to the caller's context. That keeps the relationship visible without
letting outside callers control your trace ids or sampling.
</details>

## Next

You've seen how spans from many services and environments end up in one
table. [Module 7](07-clickhouse.md) opens that table up: how ClickHouse writes
spans to disk, why queries on it are fast, and how two replicas and Keeper
keep the data safe when a server fails.

## Read more

- [Context propagation](https://opentelemetry.io/docs/concepts/context-propagation/)
- [W3C Trace Context (the `traceparent` header)](https://www.w3.org/TR/trace-context/)
- [W3C Baggage](https://www.w3.org/TR/baggage/)
- [Span links](https://opentelemetry.io/docs/concepts/signals/traces/#span-links)
- [Messaging semantic conventions (context in message headers)](https://opentelemetry.io/docs/specs/semconv/messaging/messaging-spans/)
- [Collector deployment: gateway](https://opentelemetry.io/docs/collector/deploy/gateway/)
- [OTLP/HTTP exporter (Collector to Collector)](https://github.com/open-telemetry/opentelemetry-collector/blob/main/exporter/otlphttpexporter/README.md)
- [ClickHouse `remote()` table function](https://clickhouse.com/docs/sql-reference/table-functions/remote)
- [W3C Trace Context: privacy and security considerations](https://www.w3.org/TR/trace-context/#privacy-considerations)

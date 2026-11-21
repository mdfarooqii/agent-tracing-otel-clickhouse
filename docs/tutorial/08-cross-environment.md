# Module 8: Joining services and environments into one trace (25 min)

## Idea

### First: joining spans from non-agentic services

An HTTP API, a database client or a batch job with no LLM joins an agent's
trace the same way any service does. **There is no merge step**: a service's
spans are part of the trace if they carry the same trace id, with a parent id
pointing at the caller's span. In this repo, `kb-search-api`, `ticket-api` and
`pricing-api` are such services. Five things have to hold:

| # | Condition | In this repo | If it doesn't hold |
|---|---|---|---|
| 1 | The caller **injects** context into the request | `propagate.inject(headers)` in `call_api` writes `traceparent` and `baggage` | The callee starts a new, unrelated trace |
| 2 | The service **extracts** it and starts its server span from it | `propagate.extract(...)` in `apis.py` | Same: a new trace per request |
| 3 | Every hop in between **forwards the headers** | Direct calls on localhost | Separate traces (`STRIP_TRACE_HEADERS=1`, lab step 3) |
| 4 | The service's spans **reach the same store** and pass its rules | Gateway requires `org.owner` and `org.service` on the resource | Only the caller's client span appears (`legacy-hr-api`, lab step 4) |
| 5 | The service samples **parent-based** | The SDK default | Orphan spans, or missing halves (module 5) |

For a real service you rarely write conditions 1 and 2 yourself.
**Auto-instrumentation** does it for common frameworks and clients:
`opentelemetry-instrument python app.py` with the Flask, FastAPI or requests
instrumentation packages in Python; the Java agent jar; or
`@opentelemetry/auto-instrumentations-node` for Node.

Some callees can't be instrumented at all: a database, a SaaS API, a legacy
system. You still get the caller's **client span**, with its duration, status
and error, but nothing inside the callee. `INSERT tickets` from `ticket-api`
to Postgres is such a span here. Beyond that, the fallback is correlating on a
business id the callee logs (such as `org.request_id`), which is a workaround,
not a trace.

### Across environments

An agent runs in one environment (a cluster, a cloud account, a region), and
the services it calls run in another. You want **one trace** showing both.
Everything above still applies, and four more things have to hold, each of
which fails in its own way.

| # | Requirement | Typical way it breaks | Fix |
|---|---|---|---|
| 1 | **Context crosses the boundary** | A proxy, API gateway or WAF drops or rewrites `traceparent` and `baggage`; a message queue has no headers; an async job starts later | Allow-list the W3C headers on every hop; inject context into message headers; use **span links** for async or batch work |
| 2 | **Spans end up queryable together** | Each environment writes to its own backend | Forward to one central store, **or** query across stores by trace id |
| 3 | **Sampling decisions agree** | Each side samples independently | Parent-based sampling everywhere; tail sampling only where all spans of a trace meet |
| 4 | **You can tell environments apart** | Same service name in both; no environment label | Each environment's gateway stamps `org.env`, `org.region` and so on |

Two more practical points:

- **Clock skew.** Each host timestamps its own spans. If clocks differ, a child
  can appear to start before its parent. Trust the parent/child links over
  the timestamps.
- **Trust boundaries.** At a public edge, you may *not* want to continue a
  caller's trace (a client could force sampling or inject ids). Start a new
  trace there, and add a **span link** to the incoming context.

### Architecture patterns

**A. Central collection** (simplest to query):

```text
env A apps ─▶ env A gateway ─┐
                             ├─ OTLP ─▶ central gateway ─▶ one ClickHouse
env B apps ─▶ env B gateway ─┘
```

Each environment's gateway stamps its own `org.env` and region, then exports
with the `otlp` exporter to a central tier. Trace ids already match, because
context was propagated, so nothing needs to be "merged": the spans simply land
in the same table. With ClickHouse sharded by `cityHash64(TraceId)`, they even
land on the same shard.

**B. Store per environment, merge at query time** (data stays local, for
example for data residency):

```sql
SELECT * FROM otel.otel_traces WHERE TraceId = '...'
UNION ALL
SELECT * FROM remote('clickhouse.env-b.internal', otel.otel_traces, 'reader', '...') WHERE TraceId = '...';
```

A `Distributed` table over a cluster that lists both environments' servers
does the same thing permanently. The trace id is the join key.

**C. Propagation was lost: correlate after the fact.** If something on the
way drops the trace headers, the two halves have different trace ids, and no
storage trick can rejoin them reliably. You can correlate on a business id
that survives (an `X-Request-Id` header the proxy keeps, an order id),
but it's a workaround. **Fix the propagation.**

## Remember it

> **A trace crosses environments only if its passport (`traceparent`) gets
> through every border, and all its travel photos end up in one album, or
> albums you can flip through together.**
>
> Merge happens at the **trace id**, never by time or service name.

## In this repo

- Each gateway stamps `org.env`, `org.region`, `org.platform` and
  `org.cluster` from its own environment variables (`compose.yaml`,
  `otel-gateway-config.yaml`).
- `agent/apis.py`: setting `STRIP_TRACE_HEADERS=1` makes the APIs ignore
  incoming `traceparent` and `baggage`, like a proxy that drops them.

## Lab (10 min)

Pause the background traffic first: `./stack.sh traffic off`.

1. **Two environments, one trace.** Start a second gateway, the "prod"
   environment, on port 24318, writing to the same ClickHouse:

   ```bash
   docker compose run -d --name otel-gateway-prod -e ORG_ENV=prod -e ORG_REGION=eu-west \
     -p 24318:4318 otel-gateway
   ```

   Run the APIs in "prod" and the agent in "dev":

   ```bash
   cd agent
   for s in kb-search-api ticket-api pricing-api legacy-hr-api; do
     OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:24318 OTEL_RESOURCE_ATTRIBUTES=lab.run=twoenv \
       .venv/bin/python apis.py --service $s >/dev/null 2>&1 &
   done
   sleep 2
   OTEL_RESOURCE_ATTRIBUTES=lab.run=twoenv .venv/bin/python run.py --agent support-agent --turns 2
   pkill -f 'apis.py --service'
   ```

   ```sql
   SELECT TraceId, groupArray(DISTINCT org_env) AS envs, groupArray(DISTINCT ServiceName) AS services
   FROM otel.otel_traces WHERE ResourceAttributes['lab.run'] = 'twoenv' GROUP BY TraceId;
   ```

   ```text
   6a309b7aae07ec370bfa682264ff2aba  ['dev','prod']  ['support-agent','kb-search-api']
   1610a5185b7ffa730e406977730fc887  ['dev','prod']  ['support-agent','kb-search-api']
   ```

   One trace, two environments, two gateways. Clean up:
   `docker rm -f otel-gateway-prod`.

2. **Query another store by trace id.** `clickhouse-02` stands in for
   "another environment's ClickHouse" here:

   ```sql
   SELECT hostName() AS host, count() FROM otel.otel_traces WHERE ResourceAttributes['lab.run'] = 'twoenv' GROUP BY host
   UNION ALL
   SELECT 'remote clickhouse-02', count() FROM remote('clickhouse-02', otel.otel_traces, 'default', 'demo')
   WHERE ResourceAttributes['lab.run'] = 'twoenv';
   ```

3. **Break propagation.** Run with the APIs dropping trace headers:

   ```bash
   STRIP_TRACE_HEADERS=1 OTEL_RESOURCE_ATTRIBUTES=lab.run=stripped .venv/bin/python simulate.py --turns 3
   ```

   ```sql
   SELECT ServiceName, uniqExact(TraceId) AS traces, countIf(ParentSpanId = '') AS root_spans
   FROM otel.otel_traces WHERE ResourceAttributes['lab.run'] = 'stripped'
   GROUP BY ServiceName ORDER BY ServiceName;
   ```

   ```text
   hr-agent       3  3
   kb-search-api  3  3
   pricing-api    8  8
   ...
   ```

   Every API span is now a **root of its own trace**, and the tenant from
   baggage is gone too (`SpanAttributes['org.tenant']` is empty on
   `kb-search-api`). This is what a header-stripping proxy does to you.

   Then `cd .. && ./stack.sh traffic on`.

4. **Find callees that never joined the trace.** List every outgoing call and
   how often it has no server span under it:

   ```sql
   SELECT c.ServiceName AS caller, c.SpanName, count() AS calls, countIf(s.SpanId = '') AS no_server_span
   FROM otel.otel_traces AS c
   LEFT JOIN (SELECT TraceId, SpanId, ParentSpanId FROM otel.otel_traces WHERE SpanKind = 'Server') AS s
     ON s.TraceId = c.TraceId AND s.ParentSpanId = c.SpanId
   WHERE c.SpanKind = 'Client' AND c.SpanName NOT LIKE 'chat%' AND c.Timestamp > now() - INTERVAL 1 HOUR
   GROUP BY caller, c.SpanName ORDER BY caller;
   ```

   ```text
   hr-agent     GET /employees/{employee_id}   459   459
   hr-agent     POST /v1/tickets               459     3
   sales-agent  GET /v1/prices/{sku}          1163     8
   support-agent GET /v1/search                477     3
   ticket-api   INSERT tickets                 460   460
   ```

   Read it row by row:
   - `GET /employees/...`: **always** missing. `legacy-hr-api` sends spans, but
     the gateway drops them (condition 4).
   - `INSERT tickets`: always missing, and that's expected. It's a database
     call, and Postgres doesn't emit spans; the client span is all you get.
   - The few misses on the other routes are the stripped-headers runs from
     step 3 (condition 3).

## Explain it back

> "To see one trace across environments, the W3C trace headers have to survive
> every hop: proxies, gateways and queues. Then the spans have to be queryable
> together, either by forwarding every environment's gateway to a central
> store, or by querying each store by trace id at read time. Each environment's
> gateway stamps its own environment labels, so you can tell the halves apart.
> Sampling must be parent-based, so both sides agree. There's no merge step:
> the shared trace id *is* the merge. If propagation breaks, you get two
> unrelated traces, and the only way back is correlating on a business id."

## Check yourself

<details><summary>A plain REST service with no LLM is called by an agent. What does it need to show up inside the agent's trace?</summary>

It has to extract `traceparent` from incoming requests and start its server
span from that context; auto-instrumentation does this for common frameworks.
It also needs the resource labels the gateway requires, an exporter pointing
at the gateway, and parent-based sampling. Nothing is merged afterwards: the
shared trace id makes it part of the trace.
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

## Read more

- [Context propagation](https://opentelemetry.io/docs/concepts/context-propagation/)
- [Span links](https://opentelemetry.io/docs/concepts/signals/traces/#span-links)
- [Messaging semantic conventions (context in message headers)](https://opentelemetry.io/docs/specs/semconv/messaging/messaging-spans/)
- [Collector deployment: gateway](https://opentelemetry.io/docs/collector/deploy/gateway/)
- [OTLP exporter (Collector to Collector)](https://github.com/open-telemetry/opentelemetry-collector/blob/main/exporter/otlpexporter/README.md)
- [ClickHouse `remote()` table function](https://clickhouse.com/docs/sql-reference/table-functions/remote)
- [W3C Trace Context: privacy and security considerations](https://www.w3.org/TR/trace-context/#privacy-considerations)

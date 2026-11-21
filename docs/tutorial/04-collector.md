# Module 4: The Collector as a gateway (40 min)

## Idea

### What the Collector is

The **OpenTelemetry Collector** is a separate process that receives telemetry,
changes it, and sends it on. Apps send OTLP to it and stop caring about the
backend; the Collector owns batching, retries, credentials, filtering,
enrichment, sampling and routing.

Its configuration has five kinds of components:

| Component | Job | In this repo |
|---|---|---|
| **Receivers** | Accept data (push or pull) | `otlp` on 4317 (gRPC) and 4318 (HTTP) |
| **Processors** | Change, drop, batch, sample, in order | `memory_limiter`, `filter`, `resource`, `batch` |
| **Exporters** | Send data out | `clickhouse`, `debug` |
| **Connectors** | Exporter of one pipeline plus receiver of another (e.g. spans to metrics) | none |
| **Extensions** | Things that aren't data: health, auth, storage | `health_check` on 13133 |

Defining a component does nothing until a **pipeline** under `service:` uses it:

```yaml
service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [memory_limiter, filter/require_org_labels, resource/org_platform, batch]
      exporters: [clickhouse, debug]
```

`type/name` (like `filter/require_org_labels`) lets you have several of one
type. **Processor order matters**: data flows left to right.

- `memory_limiter` goes first, so it can refuse data before anything else
  spends memory on it.
- Drop things (`filter`) early, so you don't spend work on them.
- `batch` goes last, after anything that drops or rewrites spans.

### Distributions

`otelcol` (core) has few components. **`otelcol-contrib`** (used here) has
hundreds, including the ClickHouse exporter and tail sampling. In production,
teams often build their own slim distribution with the **OpenTelemetry
Collector Builder** (`ocb`), containing only what they use.

### Agent and gateway patterns

| Pattern | Where it runs | Good for |
|---|---|---|
| **Agent** (sidecar or DaemonSet) | Next to the app, one per host or pod | Fast local hand-off, host metadata, offloading the app quickly |
| **Gateway** | A central, load-balanced pool | Credentials, org-wide policy, tail sampling, one place to change the backend |
| Both | App to agent to gateway | Most large deployments |

This repo runs only a **gateway**, called `otel-gateway`.

### OTTL: the transformation language

Processors such as `filter`, `transform` and `routing` use **OTTL**, the
OpenTelemetry Transformation Language. Conditions read like code:

```yaml
filter/require_org_labels:
  error_mode: ignore
  traces:
    span:
      - resource.attributes["org.owner"] == nil or resource.attributes["org.service"] == nil
```

In the `filter` processor, a span that **matches is dropped**. So this means
"drop spans whose resource lacks the owner or service label". That's why
`legacy-hr-api` never appears: it puts those labels on spans, not on the resource.

### Buffering, retries and back-pressure

Every exporter gets the same **exporter helper** settings:

| Setting | What it does | Here |
|---|---|---|
| `timeout` | Per-request time limit | `10s` |
| `retry_on_failure` | Exponential backoff for retryable errors | 5 s to 30 s, give up after 300 s |
| `sending_queue` | Buffer between pipeline and exporter, drained by N consumers | default: on, in memory, 1000 batches, 10 consumers |
| `sending_queue.storage` | Point at a `file_storage` extension to survive restarts | not used |

Here's what happens when ClickHouse slows down or fails:

```text
SDK ──▶ receiver ──▶ memory_limiter ──▶ ... ──▶ batch ──▶ [sending_queue] ──▶ exporter ──X ClickHouse
                                                              ▲ fills up          │ retries with backoff
                     ◀── refuses data when memory is high ────┘                   │ gives up after 300 s: data lost
SDK retries, then its own queue fills and it drops spans
```

Three places can lose data, and you should know all three:

1. **The SDK**: its queue is full, or the process exits before the collector
   is back.
2. **The Collector's memory**: its queue is full, it restarts (an in-memory
   queue is lost), or `memory_limiter` refuses data.
3. **The exporter**: the retry window (`max_elapsed_time`) runs out.

The `batch` processor groups spans so ClickHouse gets fewer, larger inserts:
it sends at 1000 spans or every 5 s, whichever comes first. ClickHouse
strongly prefers this (see module 6).

### Config tricks used in this repo

- `${env:ORG_ENV}`: environment variable substitution at startup.
- **Several `--config` files are merged.** Module 5 adds tail sampling by
  passing a second file that only lists the new processor and the new
  pipeline; maps merge, lists are replaced.

## Remember it

> **The Collector is a post office: receivers are the letterbox, processors
> are the sorting room (in order, so drop junk mail first and bundle last),
> exporters are the delivery vans, and the sending queue is the loading dock.
> If the vans can't leave, the dock fills, and then the post office stops
> accepting letters.**

## In this repo

- `otel-gateway-config.yaml`: the full pipeline. The `clickhouse` exporter has
  `create_schema: false` (tables come from `clickhouse/schema.sql`), and lists
  both nodes in `endpoint`, so it can fail over.
- `compose.yaml`: the `otel-gateway` service, the image tag
  (`opentelemetry-collector-contrib:0.146.1`), and the `ORG_*` defaults.

## Lab (20 min)

1. See the filter work. The HR agent calls the legacy API, but only the client
   side reaches ClickHouse:

   ```sql
   SELECT ServiceName, SpanKind, count() FROM otel.otel_traces
   WHERE SpanName LIKE 'GET /employees%' GROUP BY ALL;
   ```

   You'll see `hr-agent | Client` only. The `legacy-hr-api | Server` spans
   were dropped by `filter/require_org_labels`.

2. Platform labels are the gateway's job. Restart the gateway as if it ran in
   staging:

   ```bash
   ORG_ENV=staging docker compose up -d otel-gateway
   sleep 40
   docker exec clickhouse-01 clickhouse-client --password demo -q \
     "SELECT org_env, org_region, count() FROM otel.otel_traces WHERE Timestamp > now() - INTERVAL 30 SECOND GROUP BY ALL"
   docker compose up -d otel-gateway      # back to dev
   ```

   Every new span says `staging`, though no app changed.

3. Watch batches leave the gateway (the `debug` exporter logs one line per
   batch):

   ```bash
   docker logs --since 1m otel-gateway 2>&1 | grep '"spans"'
   ```

4. **Break the gateway** and see what the apps lose. With traffic on:

   ```bash
   docker stop otel-gateway; sleep 45; docker start otel-gateway
   grep -E 'Transient error|Failed to export' .run/traffic.log | tail -3
   ```

   ```text
   Transient error ... Connection refused ... retrying in 0.96s.
   Transient error ... Connection refused ... retrying in 2.10s.
   Failed to export spans batch due to timeout, max retries or shutdown.
   ```

   Then count turns in 10-second buckets around the outage:

   ```sql
   SELECT toStartOfInterval(Timestamp, INTERVAL 10 SECOND) AS t, count() AS turns
   FROM otel.otel_traces WHERE SpanName = 'agent_turn' AND Timestamp > now() - INTERVAL 5 MINUTE
   GROUP BY t ORDER BY t;
   ```

   Turns that ran while the gateway was down are **missing**. The agents are
   short-lived processes: they retried, then shut down, and their spans went
   with them. Compare with module 6, where ClickHouse is down but the gateway
   is up: there, the gateway's queue holds the data and nothing is lost.

## Explain it back

> "The Collector is a pipeline of receivers, processors and exporters. Our
> gateway receives OTLP, protects itself with a memory limiter, drops spans
> without owner and service labels, stamps platform labels from its own
> environment, batches, and writes to ClickHouse. Exporters have a sending
> queue and retries with backoff, so a backend outage of a few minutes is
> absorbed. The queue is in memory, though, so a gateway restart loses it, and
> when the gateway itself is down, the SDKs only retry briefly. For more
> safety, you'd add a persistent queue or a local agent collector."

## Check yourself

<details><summary>Why is <code>memory_limiter</code> first and <code>batch</code> last?</summary>

`memory_limiter` has to refuse data before other processors use memory on
it. `batch` should group what's left after filtering, sampling and rewriting;
batching earlier wastes work and makes batches uneven.
</details>

<details><summary>Should a service set <code>org.env</code> itself?</summary>

No. Where something runs is a fact about the platform, so the gateway in that
environment stamps it (`upsert` overwrites whatever the app sent). Apps set
what only they know: owner and service.
</details>

<details><summary>ClickHouse is down for 10 minutes. What's lost?</summary>

With `max_elapsed_time: 300s`, batches that can't be written within 5 minutes
are dropped, and while the queue is full, new data is refused. You'd raise
`max_elapsed_time`, size the queue, and use `sending_queue.storage` with a
`file_storage` extension to survive longer outages and restarts.
</details>

## Read more

- [Collector overview](https://opentelemetry.io/docs/collector/)
- [Collector configuration](https://opentelemetry.io/docs/collector/configuration/)
- [Deployment patterns: agent and gateway](https://opentelemetry.io/docs/collector/deploy/)
- [Exporter helper: queue and retry settings](https://github.com/open-telemetry/opentelemetry-collector/blob/main/exporter/exporterhelper/README.md)
- [Memory limiter processor](https://github.com/open-telemetry/opentelemetry-collector/blob/main/processor/memorylimiterprocessor/README.md)
- [Batch processor](https://github.com/open-telemetry/opentelemetry-collector/blob/main/processor/batchprocessor/README.md)
- [Filter processor](https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/processor/filterprocessor/README.md)
- [OTTL](https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/pkg/ottl/README.md)
- [ClickHouse exporter](https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/exporter/clickhouseexporter/README.md)
- [Collector Builder (ocb)](https://opentelemetry.io/docs/collector/custom-collector/)

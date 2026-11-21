# Module 5: Head and tail sampling (30 min)

## Idea

Storing every span of every request gets expensive fast. **Sampling** keeps
a subset. The key question is **when** you decide, because that decides
**what you know** when you decide.

| | Head sampling | Tail sampling |
|---|---|---|
| Decided | When the **root span starts**, in the SDK | After the **whole trace has arrived**, in a Collector |
| Knows | Only the trace id and the start attributes | Everything: errors, duration, every attribute |
| Can keep "all errors" | No (it decides before anything fails) | Yes |
| Cost | Nothing: dropped spans are never even exported | Every span is sent and held in Collector memory until the decision |
| Scaling | Trivial | Every span of a trace must reach **the same** Collector instance |

### Head sampling in the SDK

A **sampler** runs when a span starts and returns record-and-sample or drop.
The decision travels downstream in the `traceparent` flags (`...-01` means
sampled).

| `OTEL_TRACES_SAMPLER` | Behaviour |
|---|---|
| `parentbased_always_on` | **The default.** Root spans are kept; children follow their parent |
| `traceidratio` + `OTEL_TRACES_SAMPLER_ARG=0.3` | Keep 30%, decided from the trace id; **ignores the parent** |
| `parentbased_traceidratio` | Roots: 30% by trace id. Children: follow the parent |
| `always_on` / `always_off` | Keep everything, or nothing |

**"Parent-based" is what keeps traces whole.** If the agent dropped a trace,
the API respects that and drops its spans too. With a non-parent-based sampler
in the API, it decides on its own, and you get **orphans**: API spans whose
parent was never recorded.

Because a ratio sampler decides from the trace id itself, two services using
the same ratio make the same decision for the same trace. Still, rely on
parent-based sampling rather than on that coincidence.

### Tail sampling in the Collector

The `tail_sampling` processor groups spans by trace id, **waits**
(`decision_wait`), then evaluates **policies**. A trace is kept if **any**
policy says keep (simplified; policies can also be combined with `and`,
`composite` and drop rules).

```yaml
tail_sampling:
  decision_wait: 10s     # wait for late spans of the trace
  num_traces: 20000      # traces held in memory at once
  policies:
    - { name: keep-errors, type: status_code, status_code: { status_codes: [ERROR] } }
    - { name: keep-slow,   type: latency,     latency: { threshold_ms: 1500 } }
    - { name: keep-10-percent-of-the-rest, type: probabilistic, probabilistic: { sampling_percentage: 10 } }
```

Other policy types: `string_attribute`, `numeric_attribute`, `rate_limiting`,
`span_count`, `ottl_condition`, `trace_state`, `boolean_attribute`, `and`,
`composite`.

The two big costs:

- **Memory**: `num_traces x average spans per trace` must fit. If more traces
  arrive than `num_traces`, the oldest are evicted (decided early).
- **One trace, one instance.** With several gateway replicas behind a load
  balancer, a trace's spans arrive at different replicas, and each one sees
  only part of the trace. The fix is two tiers: a first tier using the
  **`loadbalancing` exporter** with `routing_key: traceID`, sending every span of a
  trace to the same second-tier instance, which runs `tail_sampling`.

```text
apps ─▶ LB ─▶ tier 1 (loadbalancing exporter, hash by trace id) ─▶ tier 2 (tail_sampling) ─▶ ClickHouse
```

### Sampling changes your counts

After sampling, `count()` no longer equals the number of requests. Either
compute rate/error/duration metrics **before** sampling (for example with the
`spanmetrics` connector ahead of `tail_sampling`), or weight counts by the
sampling rate. In this repo, the `span_red_1m` table is filled from stored
spans, so it would undercount if you turned sampling on permanently.

## Remember it

> **Head sampling is a bouncer at the door: fast, cheap, but judges you before
> the party. Tail sampling is a reviewer after the party: knows who caused
> trouble, but has to watch everyone, and everyone from the same group has to
> be watched by the same reviewer.**

And: **parent-based means "do what your parent did"**, which is what keeps
traces whole.

## In this repo

- Head sampling: nothing in code. The SDK reads `OTEL_TRACES_SAMPLER` and
  `OTEL_TRACES_SAMPLER_ARG` from the environment.
- Tail sampling: `docs/tutorial/labs/otel-gateway-tail-sampling.yaml`, merged
  into the gateway by `docs/tutorial/labs/compose.tail-sampling.yaml`.

## Lab (15 min)

Use `OTEL_RESOURCE_ATTRIBUTES=lab.run=...` to tag each experiment, so you can
find its spans afterwards.

1. **Head sampling at 30%** (pause the background traffic first):

   ```bash
   ./stack.sh traffic off
   cd agent
   OTEL_RESOURCE_ATTRIBUTES=lab.run=head30 \
   OTEL_TRACES_SAMPLER=parentbased_traceidratio OTEL_TRACES_SAMPLER_ARG=0.3 \
     .venv/bin/python simulate.py --turns 10
   ```

   ```sql
   SELECT ServiceName, countIf(SpanName = 'agent_turn') AS turns_kept, uniqExact(TraceId) AS traces
   FROM otel.otel_traces WHERE ResourceAttributes['lab.run'] = 'head30'
   GROUP BY ServiceName ORDER BY ServiceName;
   ```

   Out of 30 turns (10 per agent), about 9 are kept; a test run kept 11. The
   APIs have spans only for kept traces, because they follow the parent.

2. **Inconsistent sampling makes orphans.** Start one API that keeps
   everything, and an agent that samples 30% *without* parent-based sampling:

   ```bash
   OTEL_RESOURCE_ATTRIBUTES=lab.run=orphans OTEL_TRACES_SAMPLER=always_on \
     .venv/bin/python apis.py --service kb-search-api &
   sleep 2
   OTEL_RESOURCE_ATTRIBUTES=lab.run=orphans OTEL_TRACES_SAMPLER=traceidratio OTEL_TRACES_SAMPLER_ARG=0.3 \
     .venv/bin/python run.py --agent support-agent --turns 10
   pkill -f 'apis.py --service'
   ```

   ```sql
   SELECT ServiceName, uniqExact(TraceId) AS traces,
          countIf(SpanKind = 'Server' AND ParentSpanId NOT IN
                  (SELECT SpanId FROM otel.otel_traces WHERE ResourceAttributes['lab.run'] = 'orphans')) AS orphans
   FROM otel.otel_traces WHERE ResourceAttributes['lab.run'] = 'orphans' GROUP BY ServiceName;
   ```

   A test run: the agent kept 4 traces; the API recorded 10, and 6 of them
   are orphans pointing at parents that don't exist.

3. **Tail sampling at the gateway.** From the repo root, with traffic on:

   ```bash
   ./stack.sh traffic on
   docker compose -f compose.yaml -f docs/tutorial/labs/compose.tail-sampling.yaml up -d otel-gateway
   ```

   Wait 2 minutes, then compare traces per minute before and after:

   ```sql
   SELECT toStartOfMinute(Timestamp) AS m, uniqExact(TraceId) AS traces,
          uniqExactIf(TraceId, StatusCode = 'Error') AS with_errors
   FROM otel.otel_traces WHERE Timestamp > now() - INTERVAL 10 MINUTE
   GROUP BY m ORDER BY m;
   ```

   In a test run (traffic every 10 s), traces went from about 36 per minute
   to about 15, and most of the kept ones had errors (the pricing API fails
   30% of the time) or were slow. Every kept trace was **complete**, with
   root and API spans together. That's the point of deciding per trace.

   Turn it off again:

   ```bash
   docker compose up -d otel-gateway
   ```

## Explain it back

> "Head sampling decides in the SDK when the root span starts, usually as a
> ratio of trace ids; it's free, but it can't know whether the trace will fail.
> Children use parent-based sampling, so they follow the decision in the
> `traceparent` flags and traces stay whole. Tail sampling decides in the
> Collector after waiting for the whole trace, so it can keep all errors and
> slow traces plus a percentage of the rest; the cost is memory, and every span
> of a trace has to reach the same Collector, which at scale means a
> load-balancing tier keyed by trace id. Either way, compute your metrics
> before sampling, or weight them."

## Check yourself

<details><summary>Why can't head sampling keep 100% of errors?</summary>

The decision is made when the root span starts, before anything has failed.
Only something that sees the finished trace, like a tail sampler, can choose
by outcome.
</details>

<details><summary>You run 3 gateway replicas behind a round-robin load balancer with tail sampling. What goes wrong?</summary>

Each replica sees roughly a third of each trace's spans and decides on its
own: one may keep the error part while another drops the rest. You get
fragments. Put a `loadbalancing` exporter tier in front, routing by trace id.
</details>

<details><summary>What does <code>decision_wait: 10s</code> trade off?</summary>

Longer waits catch slow, late spans, but hold more traces in memory and add
delay before data is visible. Too short, and long traces are decided before
their last spans arrive; those late spans are then handled separately.
</details>

## Read more

- [Sampling concepts](https://opentelemetry.io/docs/concepts/sampling/)
- [Python SDK sampling](https://opentelemetry-python.readthedocs.io/en/latest/sdk/trace.sampling.html)
- [Tail sampling processor](https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/processor/tailsamplingprocessor/README.md)
- [Load-balancing exporter](https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/exporter/loadbalancingexporter/README.md)
- [Probabilistic sampler processor](https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/processor/probabilisticsamplerprocessor/README.md)
- [Span metrics connector](https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/connector/spanmetricsconnector/README.md)

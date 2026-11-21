# Module 5: Head and tail sampling (65 min)

## Why this matters

Recording every span of every request costs money: network, gateway memory,
and disk in ClickHouse. **Sampling** means keeping only some traces on purpose.
The hard part is choosing *which* ones without losing the traces you'll need
when something breaks. By the end of this module, you'll be able to say where a
keep-or-drop decision can be made, what each place knows at that moment, what
it costs, and how to turn each kind on in this repo.

## Key terms

From earlier modules you need: a **trace** (all the spans of one request; here,
one agent turn), its **trace id** and **root span** (`agent_turn`), the
**`traceparent`** header that carries them between services, and the SDK's
**sampler** ([module 1](01-otel-core.md)); and the **gateway**, the Collector
that forwards spans to ClickHouse ([module 4](04-collector.md)).

| Term | Plain meaning |
|---|---|
| **Sampling** | Keeping a subset of traces and dropping the rest, on purpose. Each keep-or-drop choice is a **sampling decision** |
| **Head sampling** | Deciding at the very start of a trace, inside the app's SDK |
| **Tail sampling** | Deciding after the whole trace has finished, inside a Collector |
| **Ratio sampling** | Keeping a fixed fraction, such as 30%, chosen from the trace id |
| **Parent-based sampling** | "Do what my parent did": follow the decision the caller already made |
| **Orphan span** | A span whose parent was never recorded, so it hangs loose outside its tree |
| **Policy** | One rule in tail sampling, such as "keep traces with an error" |
| **Load balancer** | Something that spreads incoming requests across several copies (replicas) of a service |
| **Adjusted count** | How many real traces one stored trace stands for: 1 divided by the chance it was kept |

## Idea

### Why sample at all?

A rough example: 1,000 requests a second at 20 spans each is 20,000 spans a
second, about 1.7 billion a day, all sent, held, written and stored. Most say
the same thing: "it worked, at normal speed". You need:

- **every** trace where something failed,
- **every** trace that was unusually slow,
- **some** normal traces, to know what "normal" looks like.

The key question is **when** you decide, because that sets **what you know**.

### Head and tail: an analogy

Imagine a sports TV network covering hundreds of amateur matches every
weekend.

- **Head sampling**: on Friday, before any match starts, the network picks
  30% of the matches at random and sends camera crews to those only. It's
  cheap: no crew, no footage. But if a match nobody filmed turns out to be the
  upset of the season, it's gone.
- **Tail sampling**: the network films *every* match. On Sunday night, an editor
  watches the finished footage and keeps the upsets, the injuries, the overtime
  thrillers, plus 10% of the rest. Nothing important is missed. But they need
  storage for a whole weekend of footage, and all the footage of one match
  has to end up in the **same** editing room, or nobody can judge the match as a
  whole.

Back to this repo: a "match" is one agent turn (one trace). "Filming" is
recording and sending spans. The "editing room" is a Collector instance.

### Comparing the two

| | Head sampling | Tail sampling |
|---|---|---|
| Decided | When the **root span starts**, in the app's SDK | After the **whole trace has arrived**, in a Collector |
| Knows | Only the trace id and the attributes set at the start | Everything: errors, total duration, every attribute of every span |
| Can keep "all errors" | No: it decides before anything has failed | Yes |
| Cost | Almost nothing: dropped spans are never even sent | Every span is sent and held in Collector memory until the decision |
| Scaling | Trivial: each service decides locally | Every span of a trace must reach **the same** Collector instance |

You can use either one, or both: head sampling cuts the volume first, and
tail sampling chooses among what's left.

### Head sampling in the SDK

A **sampler** runs inside the SDK every time a span starts. It answers one
question: record and send this span, or drop it?

For a **root span** (the start of a new trace), the sampler has to decide on its
own. For a **child span**, it can look at the parent's decision. That decision
travels between services in the `traceparent` header, in the last field (the
flags). The header looks like this:

```text
traceparent: 00-12d64ae6b9afa411e15ca3a7c1726609-201baf240807604d-01
             ^^ ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ ^^^^^^^^^^^^^^^^ ^^
          version          trace id               parent span id  flags
```

Flags `01` mean the caller sampled (kept) the trace; `00` means it dropped it.
Only the lowest bit means "sampled". Newer versions of the standard use the
next bit for something else (`02` says "this trace id is random"), so `03` also
means sampled. Check the lowest bit, not the whole value.

> **Quick check:** `ticket-api` receives `traceparent: 00-...-...-02`. With the
> default sampler, does it record its span?
>
> <details><summary>Answer</summary>
>
> No. `02` has the lowest bit off, so the caller dropped the trace, and the
> parent-based default follows that. Only the "random trace id" bit is set.
> </details>

The Python SDK picks its sampler from environment variables, so you don't
change any code:

| `OTEL_TRACES_SAMPLER` | Behavior |
|---|---|
| `parentbased_always_on` | **The default.** Root spans are always kept; child spans follow their parent |
| `traceidratio` with `OTEL_TRACES_SAMPLER_ARG=0.3` | Keep 30%, decided from the trace id. **Ignores the parent** |
| `parentbased_traceidratio` with `OTEL_TRACES_SAMPLER_ARG=0.3` | Root spans: keep 30% by trace id. Child spans: follow the parent |
| `always_on` / `always_off` | Keep everything, or nothing, ignoring the parent |

#### Ratio sampling

"Keep 30%" can't mean "flip a coin", because then each service would flip its
own coin and keep different parts of the same trace. Instead, a **ratio
sampler** treats the trace id, which is random, as a number and keeps the trace
if that number falls in the lowest 30% of the range. The same trace id always
gives the same answer.

#### Parent-based sampling

**"Parent-based" is what keeps traces whole.** Follow the HR agent's "I need a
new laptop" turn:

1. The `agent_turn` root span starts in `hr-agent`. With
   `parentbased_traceidratio` at 0.3, it's a root, so the ratio rule decides.
   Say the answer is "drop".
2. The agent still runs its tools normally. Its spans just aren't recorded.
   When a tool calls `ticket-api`, the SDK still sends `traceparent`, now with
   flags `00`.
3. `ticket-api` starts its server span. It has a parent, so the parent-based
   sampler reads the flag, sees "dropped", and drops its span too.

The result: either the whole trace is stored, or none of it is.

Now imagine the API used a sampler that ignores the parent, like
`always_on`. It would record its server span even though the agent dropped the
trace. That span points to a parent span id that was never stored. That's an
**orphan**: a piece of a tree with no tree. Orphans make traces confusing and
still cost storage.

Two services with the same ratio and algorithm happen to agree on the same
trace id, but different ratios or SDKs break that. Use parent-based sampling
in every service that isn't the start of a trace.

> **Quick check:** The HR agent keeps 30% of turns with
> `parentbased_traceidratio`, and `ticket-api` keeps 100% with `always_on`.
> Out of 10 turns, how many `ticket-api` spans are orphans?
>
> <details><summary>Answer</summary>
>
> About 7: the turns the agent dropped. `ticket-api` records them anyway, and
> their parent span was never stored.
> </details>

#### Stateless probabilistic sampling in a Collector

The `probabilistic_sampler` processor sits in between. It keeps a percentage
of traces chosen from the trace id, span by span, without holding traces in
memory ("stateless"). So it saves nothing between apps and Collector (unlike
head sampling) and can't see failures (unlike tail sampling), but it still
keeps whole traces, since every span shares the trace id. Use it when you
can't change the apps' settings. This repo doesn't.

### Tail sampling in the Collector

The `tail_sampling` processor works like this:

1. It groups incoming spans by trace id, in memory.
2. It **waits** for `decision_wait` (10 seconds here) after the first span of a
   trace arrives, so the rest of the trace can catch up.
3. It runs the **policies** against the whole trace.
4. A trace is kept if **any** policy says keep. Kept traces go on to the next
   processor (`batch`) and then to ClickHouse. Dropped traces are discarded.

That's simplified: policies can also be combined with `and` and `composite`,
and some can drop traces explicitly. This repo only uses "keep if any matches".

Here is the lab file `docs/tutorial/labs/otel-gateway-tail-sampling.yaml`,
block by block.

```yaml
processors:
  tail_sampling:
    decision_wait: 10s        # hold each trace this long so all its spans arrive
    num_traces: 20000         # traces held in memory at once
```

- `decision_wait: 10s`: wait 10 seconds per trace before deciding. An agent turn
  must finish, and its spans must reach the gateway, within that time, or the
  decision is made on an incomplete trace.
- `num_traces: 20000`: the most traces held in memory at once. If more arrive,
  the oldest are removed from memory. If no decision was made for them yet,
  they're lost.

```yaml
    policies:                 # a trace is kept if ANY policy matches
      - name: keep-errors
        type: status_code
        status_code: { status_codes: [ERROR] }
```

**Keep every trace with an error.** If any span in the trace has status
`ERROR`, keep it. In this repo, that catches the pricing API's random 500
errors (it fails 30% of calls) and the support agent's failed search on its
second turn (the traffic loop passes `--fail-turn 2`).

```yaml
      - name: keep-slow
        type: latency
        latency: { threshold_ms: 1500 }
```

**Keep every slow trace.** If the trace took longer than 1500 ms (1.5 seconds),
from the earliest span's start to the latest span's end, keep it.

```yaml
      - name: keep-10-percent-of-the-rest
        type: probabilistic
        probabilistic: { sampling_percentage: 10 }
```

**Keep 10% of everything else**, chosen from the trace id. This gives you a
baseline of normal traces, so you can compare "slow" with "usual".

```yaml
service:
  pipelines:
    traces:
      processors: [memory_limiter, filter/require_org_labels, resource/org_platform, tail_sampling, batch]
```

This file is **merged** on top of `otel-gateway-config.yaml`. When Collector
config files are merged, maps (key: value sections) combine, but lists replace.
So the whole processor list has to be written out again, with `tail_sampling`
inserted. It goes after the filter and the resource processor, and before
`batch`, so only kept traces are batched.

`docs/tutorial/labs/compose.tail-sampling.yaml` is what makes the gateway load
both files: it changes the gateway's command to pass two `--config` flags, and
mounts the lab file into the container.

Other policy types exist: `string_attribute`, `numeric_attribute`,
`boolean_attribute`, `rate_limiting`, `span_count`, `ottl_condition`,
`trace_state`, `and` and `composite`.

> **Quick check:** An HR turn has no errors and takes 0.8 s. Which policy can
> keep it, and how likely is that?
>
> <details><summary>Answer</summary>
>
> Only `keep-10-percent-of-the-rest`, so about a 1 in 10 chance, decided by
> its trace id. `keep-errors` and `keep-slow` don't match.
> </details>

### The trade-offs of tail sampling

**Memory.** Every span of every trace in its wait window sits in the gateway's
memory. Too small a `num_traces` and traces are removed before they're
decided; too big and the gateway hits its `memory_limiter` (remember from
module 4: the guard that refuses data near 410 MiB). The principal engineer's
notes below work out the size.

**Completeness and delay.** The processor judges only what arrived within
`decision_wait`. A longer wait catches slower traces but holds more memory and
delays data in ClickHouse. A span arriving after the decision is "late": once
the trace has left memory, it's judged again on its own, as a fragment.

**Transport cost.** Unlike head sampling, every span still travels from the app
to the gateway. Tail sampling saves the network from the gateway to ClickHouse,
and the storage there, but not the network from the apps to the gateway.

**One trace, one instance.** This is the big one. Behind a plain load
balancer, a trace's spans spread across gateway replicas. One replica sees the
error and keeps its part; another sees only healthy spans and drops its part.
You get fragments.

The fix is two tiers of Collectors:

```mermaid
flowchart LR
  apps[apps] --> LB[load balancer]
  LB --> T1a[tier 1 Collector]
  LB --> T1b[tier 1 Collector]
  T1a -->|"loadbalancing exporter:<br/>hash of trace id"| T2a[tier 2 Collector<br/>tail_sampling]
  T1a --> T2b[tier 2 Collector<br/>tail_sampling]
  T1b --> T2a
  T1b --> T2b
  T2a --> CH[(ClickHouse)]
  T2b --> CH
```

- **Tier 1** doesn't sample. It uses the **`loadbalancing` exporter** with
  `routing_key: traceID`. That exporter picks a tier 2 instance from the trace
  id, so every span of the same trace goes to the same instance, whichever tier
  1 instance received it.
- **Tier 2** runs `tail_sampling`. Each instance now sees whole traces.

This repo runs a single gateway, so it doesn't need this.

### Sampling changes your counts

After sampling, `count()` in ClickHouse no longer equals the number of
requests. With 10% sampling of normal traffic, 1 stored normal trace stands
for about 10 real ones. And because tail sampling keeps *all* errors but only
*some* successes, the stored error rate looks far higher than the real one.

The numbers you usually want per service are **RED metrics**: rate (requests
counted), errors, and duration (latency). Two ways to keep them right:

- Compute them **before** sampling. A connector (module 4) can't sit "ahead of"
  a processor inside one pipeline, so you use two pipelines that both receive
  from `otlp`, and each gets every span. The first exports to the
  `spanmetrics` connector, which turns every span into RED metrics and feeds
  them to a metrics pipeline. The second runs `tail_sampling` and writes the
  kept traces to ClickHouse. (Not in this repo.)
- Or weight each stored trace by its **adjusted count**: 1 divided by the
  probability it was kept. A trace kept at 10% counts as 10; an error trace
  kept at 100% counts as 1. This needs the probability stored with the trace.

```mermaid
flowchart LR
  R[otlp receiver] --> P1["traces pipeline 1:<br/>no sampling"]
  R --> P2["traces pipeline 2:<br/>tail_sampling, batch"]
  P1 --> SM[spanmetrics connector] --> M["metrics pipeline"] --> MB[(metrics store)]
  P2 --> CH[(ClickHouse)]
```

In this repo, the `otel.span_red_1m` table (calls, errors and latency per
minute) is filled by a materialized view: a query ClickHouse runs on every
insert into `otel.otel_traces`. It only sees spans that were stored, so it would
undercount if you turned sampling on permanently.

> **Quick check:** With tail sampling on, a minute has 40 stored error traces
> and 50 stored normal ones. Roughly how many turns really ran?
>
> <details><summary>Answer</summary>
>
> About 540: 40 errors at adjusted count 1, plus 50 normal traces at adjusted
> count 10 (kept at 10%). Slow traces, also kept at 100%, would count as 1 each.
> </details>

## Remember it

> **Head sampling picks which matches to film before kickoff: cheap, but blind
> to the upset. Tail sampling films everything and an editor keeps the best
> after the final whistle, which only works if all footage of one match
> reaches the same editing room.**

And: **parent-based means "do what your parent did"**, which is what keeps
traces whole.

## In this repo

- **Head sampling**: nothing in code. `TracerProvider` in `agent/telemetry.py`
  is created without a sampler, so the SDK reads `OTEL_TRACES_SAMPLER` and
  `OTEL_TRACES_SAMPLER_ARG` from the environment. With neither set, it uses
  `parentbased_always_on`: everything is kept.
- **Tail sampling**: `docs/tutorial/labs/otel-gateway-tail-sampling.yaml`,
  merged into the gateway by `docs/tutorial/labs/compose.tail-sampling.yaml`.
  It's off unless you start the gateway with that compose file.

## Principal engineer's notes

**Touch points**
- Head sampling's contract is the `traceparent` sampled bit (touch point 1 in
  the [module 0 map](00-setup.md#the-touch-points-map)). Any service whose
  sampler ignores it breaks traces for everyone downstream.
- Two-tier tail sampling adds a Collector-to-Collector OTLP hop. Tier 1 must
  know the list of tier 2 instances (a static list, DNS, or Kubernetes
  lookup in the `loadbalancing` exporter); that list is the new contract.

**At scale**
- Tail sampling memory is about **traces per second x `decision_wait` x
  average trace size**. Worked example: 1,000 turns a second, a 10 s wait,
  20 spans per turn at about 1 KB each: 10,000 traces in flight x 20 KB =
  200 MB, before the Collector's own overhead (budget roughly double). That
  already crowds this gateway's 410 MiB refusal point. `num_traces` must also
  exceed traces in flight (10,000 here); the lab's 20,000 gives 2x headroom.
- Agent turns are long. Child spans arrive as they finish, but the root
  `agent_turn` span arrives only after the turn ends, plus up to 5 s in the
  SDK's batch. `decision_wait` must cover the longest normal turn plus that
  delay. A 30 s LLM-heavy turn needs about 40 s, which quadruples memory.
- When tier 2 grows or shrinks, the `loadbalancing` exporter's hash ring
  moves some trace ids to a different instance. Traces in flight at that
  moment are split and decided twice, so you get fragments for about one
  `decision_wait`. Scale tier 2 in quiet periods, not in the middle of an incident.

**Operational issues**
- Watch for traces evicted before a decision
  (`otelcol_processor_tail_sampling_sampling_trace_dropped_too_early`) and late
  spans; both mean `num_traces` or `decision_wait` is too small. More gateway
  signals: [module 12](12-operations.md) and the
  [metrics appendix](appendix-metrics-reference.md).
- Head and tail together compound: at 10% head sampling, tail's "keep all
  errors" only sees errors in that 10%.

**Design trade-offs**
- This repo stores everything by default and computes RED metrics with a
  materialized view on stored spans. With permanent sampling, move RED to
  before sampling (`spanmetrics`) so dashboards stay exact.
- **Consistent probability sampling** is the standard way to keep counts
  correct: each sampler writes the probability it used into the `tracestate`
  header, so every stage agrees and any backend can compute the adjusted
  count. Choose it when several stages sample, or when you need weighted
  counts from stored traces.

## Lab (25 min)

Each experiment sets `OTEL_RESOURCE_ATTRIBUTES=lab.run=...`. The SDK adds that
label to the resource of every span, so you can find exactly that experiment's
spans afterwards with `ResourceAttributes['lab.run']`.

Run SQL in <http://localhost:8123/play> (user `default`, password `demo`).

1. **Head sampling at 30%.** First pause the background traffic, so it doesn't
   mix with your experiment:

   ```bash
   ./stack.sh traffic off
   cd agent
   OTEL_RESOURCE_ATTRIBUTES=lab.run=head30 \
   OTEL_TRACES_SAMPLER=parentbased_traceidratio OTEL_TRACES_SAMPLER_ARG=0.3 \
     .venv/bin/python simulate.py --turns 10
   ```

   `simulate.py` starts the four APIs and runs 10 turns in each of the three
   agents. The APIs are started by `simulate.py`, so they inherit the same
   environment variables: the same sampler and the same `lab.run` label.

   Now count what was kept, per service:

   ```sql
   SELECT ServiceName, countIf(SpanName = 'agent_turn') AS turns_kept, uniqExact(TraceId) AS traces
   FROM otel.otel_traces WHERE ResourceAttributes['lab.run'] = 'head30'
   GROUP BY ServiceName ORDER BY ServiceName;
   ```

   `turns_kept` counts root spans (one per kept turn) and `traces` counts
   distinct trace ids. Out of 30 turns (10 per agent), about 9 are kept; a test
   run kept 11. The exact number varies, because trace ids are random. The
   APIs have spans only for kept traces, because they follow the parent.
   (`legacy-hr-api` won't appear at all; the gateway filter drops it, as in
   module 4.)

2. **Inconsistent sampling makes orphans.** Still in the `agent` folder, start
   one API that keeps everything, and an agent that samples 30% *without*
   parent-based sampling:

   ```bash
   OTEL_RESOURCE_ATTRIBUTES=lab.run=orphans OTEL_TRACES_SAMPLER=always_on \
     .venv/bin/python apis.py --service kb-search-api &
   sleep 2
   OTEL_RESOURCE_ATTRIBUTES=lab.run=orphans OTEL_TRACES_SAMPLER=traceidratio OTEL_TRACES_SAMPLER_ARG=0.3 \
     .venv/bin/python run.py --agent support-agent --turns 10
   pkill -f 'apis.py --service'
   ```

   The first command starts `kb-search-api` in the background with
   `always_on`: it records every request, whatever the caller decided. The
   second runs 10 support-agent turns with `traceidratio`. The last stops the
   API.

   This query counts, per service, the traces and the server spans whose
   parent span was never stored in this experiment:

   ```sql
   SELECT ServiceName, uniqExact(TraceId) AS traces,
          countIf(SpanKind = 'Server' AND ParentSpanId NOT IN
                  (SELECT SpanId FROM otel.otel_traces WHERE ResourceAttributes['lab.run'] = 'orphans')) AS orphans
   FROM otel.otel_traces WHERE ResourceAttributes['lab.run'] = 'orphans' GROUP BY ServiceName;
   ```

   A test run: the agent kept 4 traces; the API recorded 10, and 6 of them are
   orphans pointing at parents that don't exist. Those 6 are the turns the
   agent dropped but the API recorded anyway.

3. **Tail sampling at the gateway.** Go back to the repo root and turn the
   traffic on with a round every 10 seconds instead of the default 30, so the
   numbers are big enough to compare. Wait 2 minutes for a baseline, then
   restart the gateway with the tail sampling config:

   ```bash
   cd ..
   TRAFFIC_INTERVAL=10 ./stack.sh traffic on
   sleep 120
   docker compose -f compose.yaml -f docs/tutorial/labs/compose.tail-sampling.yaml up -d otel-gateway
   ```

   Wait 2 more minutes, then compare traces per minute before and after the
   switch. `traces` counts all stored traces; `with_errors` counts those with
   at least one error span:

   ```sql
   SELECT toStartOfMinute(Timestamp) AS m, uniqExact(TraceId) AS traces,
          uniqExactIf(TraceId, StatusCode = 'Error') AS with_errors
   FROM otel.otel_traces WHERE Timestamp > now() - INTERVAL 10 MINUTE
   GROUP BY m ORDER BY m;
   ```

   In a test run with `TRAFFIC_INTERVAL=10`, traces went from about 36 per
   minute to about 15, and most of the kept ones had errors (the pricing API
   fails 30% of the time) or were slow. Your numbers will differ a little; with
   the default 30-second interval they'd be much lower.

   Now check that every kept trace is **complete**. This query takes the
   traces whose root span started between 90 and 30 seconds ago (old enough to
   be decided, and after the switch), and for each one counts root spans and
   spans whose parent is missing from the same trace:

   ```sql
   SELECT count() AS traces, countIf(roots = 1) AS with_root,
          countIf(missing_parents = 0) AS no_missing_parent
   FROM (
     SELECT TraceId, countIf(ParentSpanId = '') AS roots,
            groupArray(SpanId) AS ids, groupArray(ParentSpanId) AS parents,
            arrayCount(p -> p != '' AND NOT has(ids, p), parents) AS missing_parents
     FROM otel.otel_traces
     WHERE TraceId IN (SELECT TraceId FROM otel.otel_traces WHERE ParentSpanId = ''
                       AND Timestamp BETWEEN now() - INTERVAL 90 SECOND AND now() - INTERVAL 30 SECOND)
     GROUP BY TraceId);
   ```

   All three numbers should be equal: every kept trace has its one root span,
   and no span points at a parent that wasn't stored. The sampler kept or
   dropped each trace as a whole. (Compare lab step 2, where `missing_parents`
   would be non-zero for the orphans.)

   Turn tail sampling off again, and put the traffic back to its default
   interval:

   ```bash
   docker compose up -d otel-gateway
   ./stack.sh traffic off && ./stack.sh traffic on
   ```

## Explain it back

> "Head sampling decides in the SDK when the root span starts: free, but blind
> to failures. Children follow the `traceparent` flag, so traces stay whole.
> Tail sampling decides in the Collector after the whole trace arrives, so it
> keeps all errors and slow traces; it costs memory, and needs every span of a
> trace on one instance. Compute metrics before sampling, or weight them."

## Recap

- Sampling keeps a useful subset of traces to cut network, memory and storage
  cost.
- Head sampling decides at the start, in the SDK: cheap, but blind to the
  outcome. Tail sampling decides at the end, in a Collector: it can keep all
  errors and slow traces, but holds every trace in memory while it waits.
- Ratio sampling decides from the trace id. Parent-based sampling makes every
  downstream service follow the root's decision, so traces stay whole and
  there are no orphans.
- This repo's tail policies keep errors, traces slower than 1.5 s, and 10% of
  the rest, after a 10-second wait.
- With several gateways, tail sampling needs a first tier that routes by trace
  id. And after any sampling, raw `count()` no longer equals real traffic.

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
their last spans arrive; those late spans then arrive after the decision and
can end up as fragments.
</details>

<details><summary>You turn on tail sampling with <code>decision_wait: 10s</code>. The gateway's <code>otelcol_receiver_refused_spans_total</code> (module 4) starts rising during busy minutes. What's happening, and what are your options?</summary>

The traces held for their 10 s wait push gateway memory past the
`memory_limiter` threshold, so it refuses new data and SDKs retry. Options:
give the gateway more memory and raise `limit_mib`, shorten `decision_wait`
(at the risk of incomplete traces), or add tier 2 instances behind a
`loadbalancing` tier so each holds fewer traces.
</details>

<details><summary>With tail sampling on, the stored error rate jumps from 5% to 40%. Did the service get worse?</summary>

Probably not. The `keep-errors` policy keeps every error trace, while
`keep-10-percent-of-the-rest` keeps only a tenth of the normal ones. Errors
are over-represented in what's stored. Compute error rates before sampling
(for example with the `spanmetrics` connector), or weight the counts.
</details>

<details><summary>Why does the tail sampling lab file repeat the whole processor list, instead of just adding <code>tail_sampling</code>?</summary>

When the Collector merges config files, lists are replaced, not appended. The
second file's `processors: [...]` becomes the complete list, so it must include
every processor from the main file plus `tail_sampling`.
</details>

## Next

Whole traces only work if every service joins the same trace: the
`traceparent` header that carries the sampled flag also carries the trace id.
[Module 6](06-cross-environment.md) shows how separate services, and separate
environments with their own gateways, end up in one trace, and what quietly
breaks that.

## Read more

- [Sampling concepts](https://opentelemetry.io/docs/concepts/sampling/)
- [Python SDK sampling](https://opentelemetry-python.readthedocs.io/en/latest/sdk/trace.sampling.html)
- [Tail sampling processor](https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/processor/tailsamplingprocessor/README.md)
- [Load-balancing exporter](https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/exporter/loadbalancingexporter/README.md)
- [Probabilistic sampler processor](https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/processor/probabilisticsamplerprocessor/README.md)
- [Span metrics connector](https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/connector/spanmetricsconnector/README.md)

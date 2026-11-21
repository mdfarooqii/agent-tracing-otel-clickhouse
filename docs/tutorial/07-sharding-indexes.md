# Module 7: Sharding, trace locality and indexes (25 min)

## Idea

### Shards and replicas

| | Replica | Shard |
|---|---|---|
| Is | A **copy** of the same data | A **slice** of the data |
| Adds | Availability and read capacity | Storage and write capacity |
| Here | `tracing`: 1 shard, 2 replicas | `lab_2shards` (lab only): the same 2 servers seen as 2 shards |

A real cluster has both: for example 3 shards with 2 replicas each.

### The Distributed table

A `Distributed` table stores nothing. It's a router:

- **Insert**: compute the **sharding key** for each row, take it modulo the
  total shard weight, and send the row to that shard's local table.
- **Select**: send the query to every shard, let each one work on its slice,
  and merge the partial results.

```sql
CREATE TABLE lab.spans_by_trace AS lab.spans_by_trace_local
ENGINE = Distributed(lab_2shards, lab, spans_by_trace_local, cityHash64(TraceId));
```

### Why `cityHash64(TraceId)` keeps a trace together

The shard is a pure function of the trace id. Every span of a trace has the
same trace id, so every span lands on the **same shard**, whichever service
sent it and whenever it arrived. That gives you three things:

1. **Trace lookups hit one shard.** With `optimize_skip_unused_shards = 1`,
   ClickHouse computes the shard from `WHERE TraceId = '...'` and asks only
   that one.
2. **Per-trace work stays local.** Building a span tree, or computing a
   trace's duration, needs no data from other shards.
3. **Even spread.** Trace ids are random, so the hash spreads load evenly.

A random key (`rand()`) also spreads evenly, but scatters every trace over
all shards, so every trace query has to ask every shard.

Production variant: instead of inserting through a `Distributed` table, a
gateway tier can route by trace id itself (the `loadbalancing` exporter, as
in module 5) and write straight to each shard's local table. The principle is
the same: **shard by trace id**.

### Indexes you can add

| Tool | What it does | Use for |
|---|---|---|
| **Sorting key** (`ORDER BY`) | Sparse primary index; the only physical order | Your most common filters (here: owner, service, span name, time) |
| **MATERIALIZED column** | Pulls a value out of a map into a real column on insert | Map keys you filter or group by often |
| **Skip index** `minmax` | Min and max per index block | Ranges on values that rise with time or cluster (duration) |
| **Skip index** `set(N)` | Up to N distinct values per block | Low-cardinality columns (agent name) |
| **Skip index** `bloom_filter` | "Definitely not here" or "maybe here" per block | Equality on high-cardinality ids (trace id, request id, tenant) |
| `tokenbf_v1`, `ngrambf_v1` | Bloom filters over words or n-grams | Searching inside text |
| **Projection** | A second, hidden copy of the data inside each part, in another order | A second access pattern, e.g. `ORDER BY TraceId` |
| **Lookup table + MV** | A small table fed by a materialized view | Here, `otel_traces_trace_id_ts`: trace id to time range |

A **skip index** never finds rows; it only lets ClickHouse **skip** blocks of
granules that can't match. It helps only if the values you search for are
clustered or rare across granules. `GRANULARITY 4` means one index entry per 4
granules (4 x 8192 rows). Always check with `EXPLAIN indexes = 1` that it
actually skips something.

Adding an index to an existing table only affects new parts until you run
`MATERIALIZE INDEX`, which rewrites old parts as a mutation.

## Remember it

> **Hash the trace id, and the whole family moves into the same house.**
> Any shard can tell you everything about a trace it holds, and you know which
> house to knock on.
>
> **A skip index is a "not here" sign on a box of granules.** It never points
> to the right box; it lets you skip the wrong ones.

## In this repo

- `clickhouse/cluster.xml`: `tracing` (1 shard x 2 replicas) and `lab_2shards`.
- `clickhouse/schema.sql`: the comment explains why there are no Distributed
  tables (one shard); the skip indexes on `otel_traces`; the
  `otel_traces_trace_id_ts` lookup table.
- `docs/tutorial/labs/sharding.sql`: the two-shard experiment.

## Lab (15 min)

1. **Sharding by trace id against random sharding:**

   ```bash
   docker exec -i clickhouse-01 clickhouse-client --password demo --multiquery \
     < docs/tutorial/labs/sharding.sql
   ```

   The `ON CLUSTER` statements print one row per host first. Then:

   ```text
   ┌─sharding────┬─shard─┬─spans─┬─traces─┐
   │ by trace id │     1 │ 12281 │    980 │
   │ by trace id │     2 │ 13783 │   1099 │
   │ random      │     1 │ 12980 │   2079 │
   │ random      │     2 │ 13084 │   2077 │
   ┌─sharding────┬─traces─┬─traces_split_across_shards─┐
   │ by trace id │   2079 │                          0 │
   │ random      │   2079 │                       2077 │
   ┌─spans_in_trace─┐
   │             16 │
   ```

   Both spread spans evenly. With the trace-id key, each shard holds about
   half of the traces and **none are split**. With `rand()`, almost every trace
   is on both shards.

   Now try the single-shard lookup on the random table:

   ```sql
   SELECT count() FROM lab.spans_random
   WHERE TraceId = (SELECT any(TraceId) FROM otel.otel_traces)
   SETTINGS optimize_skip_unused_shards = 1, force_optimize_skip_unused_shards = 1;
   ```

   ```text
   Code: 507. DB::Exception: Sharding key is not deterministic. (UNABLE_TO_SKIP_UNUSED_SHARDS)
   ```

   `any(TraceId)` is ClickHouse's "give me some value from the group, I don't
   care which": a cheap way to pick one trace to look at. Don't confuse it
   with OTLP's `AnyValue`, the protobuf type that lets an attribute value be a
   string, number, boolean, list or map.

   Clean up: `DROP DATABASE lab ON CLUSTER lab_2shards SYNC`.

2. **See the trace-id bloom filter skip granules:**

   ```sql
   EXPLAIN indexes = 1
   SELECT * FROM otel.otel_traces
   WHERE TraceId = (SELECT any(TraceId) FROM otel.otel_traces);
   ```

   Under `Skip`, `Name: idx_trace_id` shows fewer parts and granules than the
   primary key step; a test run read 1 of 6 parts and 3 of 9 granules.

3. **Add your own index, measure it, drop it:**

   ```sql
   ALTER TABLE otel.otel_traces ON CLUSTER tracing
     ADD INDEX idx_agent_name gen_ai_agent_name TYPE set(100) GRANULARITY 4;
   ALTER TABLE otel.otel_traces ON CLUSTER tracing MATERIALIZE INDEX idx_agent_name;
   SELECT command, is_done FROM system.mutations WHERE table = 'otel_traces' ORDER BY create_time DESC LIMIT 1;

   EXPLAIN indexes = 1 SELECT count() FROM otel.otel_traces WHERE gen_ai_agent_name = 'quoter';

   ALTER TABLE otel.otel_traces ON CLUSTER tracing DROP INDEX idx_agent_name;
   ```

   With only a few thousand spans per part, the index skips little (6 of 7
   granules read in a test run). Agent names appear in every granule here,
   so the index can't rule many out. **That's the lesson**: an index only
   pays off when the value is rare or clustered across granules. Compare with
   a filter on the sorting key:

   ```sql
   EXPLAIN indexes = 1 SELECT count() FROM otel.otel_traces
   WHERE org_owner = 'sales-eng' AND org_service = 'sales-agent';
   ```

   This one is handled by `PrimaryKey`, with no extra index needed.

## Explain it back

> "Replicas are copies, shards are slices. A Distributed table routes each
> inserted row to a shard by a sharding key, and fans queries out to all
> shards. We shard by `cityHash64(TraceId)`, so every span of a trace lands on
> the same shard, wherever it came from. Trace lookups can then go to just one
> shard, and per-trace work stays local. A random key would scatter traces
> over every shard. Inside a shard, the sorting key is the main index; skip
> indexes like bloom filters on ids and sets on low-cardinality columns only
> let ClickHouse skip granules, so I check with `EXPLAIN indexes = 1` that
> they actually skip something."

## Check yourself

<details><summary>Why not shard by service name?</summary>

A trace crosses services, so its spans would be scattered over shards. And
one busy service would overload one shard (a hot shard).
</details>

<details><summary>A bloom filter on <code>TraceId</code> is in place. Why also keep the <code>otel_traces_trace_id_ts</code> table?</summary>

The bloom filter still has to be checked for every part in every partition.
The lookup table is sorted by trace id, so it answers "when did this trace
happen?" in a few granules. The main query can then add a tight `Timestamp`
range and skip whole partitions and parts.
</details>

<details><summary>You add a skip index and queries get no faster. What do you check?</summary>

`EXPLAIN indexes = 1`: are granules actually skipped? Was the index
materialized for old parts (`system.mutations`)? Is the value present in
nearly every granule (then no index helps; consider the sorting key or a
projection)? Is `GRANULARITY` too coarse?
</details>

## Read more

- [Distributed table engine](https://clickhouse.com/docs/engines/table-engines/special/distributed)
- [Sharding and replication: horizontal scaling](https://clickhouse.com/docs/architecture/horizontal-scaling)
- [Data skipping indexes](https://clickhouse.com/docs/optimize/skipping-indexes)
- [Projections](https://clickhouse.com/docs/data-modeling/projections)
- [`EXPLAIN`](https://clickhouse.com/docs/sql-reference/statements/explain)
- [Schema design for observability (ClickHouse)](https://clickhouse.com/docs/use-cases/observability/schema-design)

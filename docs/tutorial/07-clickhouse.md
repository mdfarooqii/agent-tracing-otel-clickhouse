# Module 7: ClickHouse storage, replicas and Keeper (45 min)

> **Where we are.** Part 1 (modules 0 to 6) followed a span from the Python
> code to the gateway: the SDK creates spans, the gateway checks, samples and
> batches them, and trace headers join services into one trace. Part 2 starts
> here, at the database end of the pipe: touch points 3 to 5 on the
> [touch points map](00-setup.md#the-touch-points-map).

## Why this matters

Every span the agents produce ends up as a row in ClickHouse, the database
this repo uses to store traces. This module looks inside that table. To
understand why queries are fast, why the gateway sends spans in batches, and
what breaks when a server goes down, you need a picture of how ClickHouse
writes data to disk and how it keeps two copies in sync.

**What you'll be able to do after this module:**

- Explain what a column-oriented database is and why it suits traces.
- Describe what happens on disk when the gateway inserts a batch of spans:
  parts, merges, partitions, the sorting key.
- Explain how two ClickHouse servers keep the same data, and why that
  needs a third service, ClickHouse Keeper.
- Predict what you'll see when Keeper, one server, or both servers fail,
  and then check it by breaking them on purpose.

## Key terms

Reminder: **cardinality** is how many distinct values a field has
([module 1](01-otel-core.md)). `SpanKind` has a handful (low); `TraceId` has
millions (high).

| Term | Plain meaning |
|---|---|
| Column store | A database that stores each column in its own file, instead of storing whole rows together |
| MergeTree | ClickHouse's main table engine (the part that decides how data is stored): data arrives in small sorted chunks that are merged in the background |
| Part / merge | A part is one immutable (never edited) chunk of a table on disk; every insert creates one. A merge combines small parts into a bigger one |
| Sorting key (`ORDER BY`) | The columns a table's rows are sorted by inside each part |
| Sparse primary index | One index entry (a **mark**) per **granule** of 8192 rows, used to skip granules that can't match a filter |
| Partition | A group of parts for one value of the partition key; here, one day of spans |
| TTL (time to live) | A rule that deletes data automatically once it reaches a certain age |
| Materialized view | A trigger that runs a query on every insert and writes the result to another table |
| Replica | A full copy of a table on another server |
| ClickHouse Keeper | A small coordination service that replicas use to agree on which parts exist. It stores no span data |
| Quorum | A majority of Keeper servers; a change counts only once a quorum has saved it |

## Idea

### The running example

Take one request. A user asks the HR assistant, "I need a new laptop." The
`hr-agent` service starts a trace (the record of the whole request, module
1). It creates an `agent_turn` span (a record of one timed operation,
module 1), then spans for the LangGraph run, the `hr_assistant` agent,
its model call (`chat fake-hr`), and its tool calls (`lookup_employee`,
`create_ticket`). The `create_ticket` tool calls the `ticket-api` HTTP
service, which records its own span in the same trace.

Each of those spans goes over OTLP (the OpenTelemetry Protocol, module 1)
to the gateway (the OpenTelemetry Collector, module 4). The gateway mixes
them with spans from the other agents, and once it has 1000 spans or 5
seconds have passed, sends the batch as a single `INSERT` into the
`otel.otel_traces` table on `clickhouse-01`. The rest of this module follows that insert.

### Why a column store suits traces

**The problem.** A typical tracing question is "what was the slowest
`agent_turn` per service in the last hour?" That touches 4 fields:
time, service, span name and duration. But each span row in this repo has
48 columns, including big ones like the attribute maps. A database that
stores whole rows together has to read all 48 columns from disk just to
look at 4 of them.

**What a column store does.** ClickHouse stores each column in its own
file. A query reads only the files for the columns it uses.

```text
Row store: rows stored one after another     Column store: one file per column
-----------------------------------------    -----------------------------------------------
[09:00:01, trace-a, agent_turn, 900 ms, ...] Timestamp : 09:00:01, 09:00:01, 09:00:02, ...
[09:00:01, trace-a, chat,       400 ms, ...] TraceId   : trace-a,  trace-a,  trace-b,  ...
[09:00:02, trace-b, agent_turn, 700 ms, ...] SpanName  : agent_turn, chat, agent_turn, ...
                                             Duration  : 900 ms,   400 ms,   700 ms,   ...
To read Duration, you read every row.        To read Duration, you read one file.
```

There's a second win: **compression**. Values in one column file are all
the same type and often repeat (`agent_turn`, `agent_turn`, `chat`...), so
they compress very well. You'll measure this in the lab.

The trade-off: column stores are bad at changing single rows. That's fine
for traces: spans are written once and never edited.

### Tables, engines and MergeTree

Every ClickHouse table has a **table engine**, which decides how its data
is stored. Almost every real table uses the **MergeTree** family. Variants
add behavior on top: `ReplicatedMergeTree` keeps copies on several servers,
`ReplacingMergeTree` removes duplicate rows, `AggregatingMergeTree` keeps
running totals. This repo uses all three (module 8 walks through each
table).

### Parts and background merges

**The problem.** Keeping one big sorted file per column, and inserting new
rows into the middle of it, would mean rewriting the file on every insert.
That's far too slow when spans arrive every second.

**What MergeTree does instead.** The life of an insert:

1. Every `INSERT` writes a new **part**: a folder holding the inserted rows,
   column by column, sorted by the table's `ORDER BY`. A part is
   **immutable**: once written, it's never edited.
2. In the background, ClickHouse **merges** small parts into bigger ones.
   Because each part is already sorted, merging is cheap, like merging two
   sorted decks of cards. The merged part replaces the small ones, which are
   deleted shortly after.
3. Each part has a **level**: 0 for a freshly inserted part, and one more
   than the highest of its inputs after each merge.

```text
INSERT (1000 spans) ──▶ part 20261121_5_5_0   level 0
INSERT (1000 spans) ──▶ part 20261121_6_6_0   level 0
INSERT (1000 spans) ──▶ part 20261121_7_7_0   level 0
                               │
                      background merge
                               ▼
                       part 20261121_5_7_1    level 1, 3000 rows, still sorted
```

**Reading a part name.** Names read `partition_minBlock_maxBlock_level`.
Every insert into a partition gets the next **block number**, so a part
covers a range of inserts. For example, `20261121_0_467_107` is the
2026-11-21 partition, holding inserts 0 to 467, after 107 rounds of
merging.

**What goes wrong: "too many parts".** Each insert creates a part, and
merges take time. If clients send many tiny inserts (one span at a time,
say), parts pile up faster than merges can combine them. Queries get slower,
because they have to open many small parts, and eventually ClickHouse
rejects inserts with a **"too many parts"** error.

That's why the gateway **batches**. Remember from [module 4](04-collector.md):
the `batch` processor sends one insert when 1000 spans have arrived or 5
seconds have passed, whichever comes first. For setups with many small
clients and no batching layer, ClickHouse offers `async_insert`: the server
collects small inserts in memory and writes them as one part.

> **Quick check:** Someone sets the gateway's batch size to 10 spans "for
> fresher data", and you run 20 gateways. What do you expect in ClickHouse?
>
> <details><summary>Answer</summary>
>
> About 100 times more parts per second than with 1000-span batches. Merges
> fall behind, queries open many tiny parts, and inserts start being delayed
> and then rejected with "too many parts".
> </details>

### The sorting key and the sparse primary index

**The problem.** Even reading only the right columns, you don't want to
read every row of them. For "spans of the `hr-agent` service", you'd like
to jump straight to that service's rows.

**What ClickHouse does.** The table's `ORDER BY` decides how rows are
sorted inside each part:

```sql
ORDER BY (org_owner, org_service, SpanName, toDateTime(Timestamp))
```

Rows are sorted by owner team first, then service within each owner, then
span name, then time (to the second). So all `people-tech` / `hr-agent` /
`agent_turn` rows sit next to each other.

Where do `org_owner` and `org_service` come from? The gateway doesn't send
them as columns; it sends the resource labels inside the `ResourceAttributes`
map. The table fills these columns **automatically on insert** from
`ResourceAttributes['org.owner']` and `ResourceAttributes['org.service']`.
They are `MATERIALIZED` columns, and [module 8](08-data-model.md) walks
through all of them. A real column, unlike a map value, can be part of the
sorting key.

> **Two unrelated meanings of "materialized".** A `MATERIALIZED` *column* is
> a column computed from other columns of the same row when the row is
> inserted. A *materialized view* (later in this module) is an insert trigger
> that writes rows into a different table. Same word, different features.

ClickHouse doesn't keep an index entry for every row; that index would be
huge. Instead it splits each part into **granules** of 8192 rows and keeps
one index entry, a **mark**, per granule: the key values of the granule's
first row. This is a **sparse index**. It's like the guide words at the top
of each dictionary page: you don't need an entry per word to find the right
page.

```text
primary index of one part (one mark per 8192 rows)
mark 0 ─▶ ('ai-platform', 'support-agent', 'agent_turn', 09:00:00)
mark 1 ─▶ ('ai-platform', 'support-agent', 'chat ...',   09:00:00)
mark 2 ─▶ ('people-tech', 'hr-agent',      'agent_turn', 09:00:00)   ◀─ hr-agent starts here
mark 3 ─▶ ('people-tech', 'hr-agent',      'execute_tool ...', ...)
mark 4 ─▶ ('sales-eng',   'sales-agent',   'agent_turn', 09:00:00)   ◀─ and has ended by here
```

For `WHERE org_owner = 'people-tech' AND org_service = 'hr-agent'`,
ClickHouse reads granules 1, 2 and 3 and skips 0 and 4. Why granule 1? A
mark only says where a granule *starts*; granule 1 runs until granule 2
begins, so its last rows could already be `hr-agent` rows. (The values are
an illustration; real granules hold 8192 rows each.)

The index works best for filters on the **start** of the key (owner, then
owner and service, and so on).

> **Quick check:** A query filters on `TraceId` only. Can the primary index
> help?
>
> <details><summary>Answer</summary>
>
> No. `TraceId` isn't in the sorting key, so the marks say nothing about
> where a trace id is, and ClickHouse reads every granule. Module 9 covers
> the bloom filter index and lookup table that fix this.
> </details>

**Choosing a key.** Pick it from your most common filters, and put
**low-cardinality columns first** (cardinality is the number of distinct
values). A few owners, then more services, then more span names, then time.
Low-cardinality columns first create long runs of equal values, which
keeps the later columns sorted within each run and makes everything
compress better. This key fits "show me this team's service" queries.

### Partitions and TTL

**The problem.** Spans are only useful for a few days, and this repo keeps
raw spans for 72 hours. Deleting old rows one by one would mean rewriting
parts, which is slow and costly.

**What partitions do.** `PARTITION BY toDate(Timestamp)` puts each day's
spans in separate parts, like keeping one folder per day in a filing
cabinet. The partition is the first part of each part's name (`20261121`).
Two rules follow:

- Parts **never merge across partitions**. A Monday part and a Tuesday part
  always stay separate.
- So a whole day can be dropped by deleting its folders, which is instant.

**TTL** (time to live) automates that. The table says "a row expires 72
hours after its timestamp", plus a setting, `ttl_only_drop_parts`, that says
"don't rewrite parts to remove some of their rows; wait until **every** row
in a part has expired, then drop the whole part". Each part holds one day, so
a part expires 72 hours after the *end* of its day. A span written just after
midnight therefore lives about 96 hours, and one written just before midnight
about 72. The part is actually removed when the next TTL merge runs, which
can add a few hours. [Module 8](08-data-model.md) goes through the
`PARTITION BY` and `TTL` clauses line by line.

Partitions are mainly for **managing data**, not for speed. A time filter
can skip whole partitions, but the sorting key does most of the speed work.
Keep partitions coarse: one per day is good. One per hour, or one per
service, multiplies the number of parts and brings back the "too many
parts" problem.

> **Quick check:** Why would `PARTITION BY ServiceName` be a bad idea?
>
> <details><summary>Answer</summary>
>
> Parts never merge across partitions, so services times days means many
> small parts that can't be combined, slower queries and "too many parts".
> Partition by time, for retention; put the service in the sorting key.
> </details>

### Materialized views are insert triggers

**The problem.** Some questions are asked all the time: "list today's
requests", "error rate per service per minute". Answering them from raw
spans every time is wasteful.

**What a materialized view does.** In ClickHouse, a materialized view is
**a trigger on insert**. Every time a block of rows is inserted into the
source table, the view runs its `SELECT` on **just those new rows** and
writes the result into a target table. Think of a restaurant order ticket
with a carbon copy: when the order is written, the kitchen and the bill
each get their own copy automatically.

Here, every span insert into `otel_traces` also fills three smaller tables:

| Table | What it answers |
|---|---|
| `otel_traces_trace_id_ts` | "When did trace X happen?", so a trace lookup can narrow the time range first |
| `trace_entry` | "List recent requests": the trace list page |
| `span_red_1m` | Rate, errors and duration (RED) per service and span name per minute, kept 1 year |

So the HR laptop request's spans land in `otel_traces`, every span updates
the per-minute counts in `span_red_1m`, and its entry spans add rows to
`trace_entry`. Because a view sees only one insert at a time, these tables
can hold several rows for the same request or minute until merges combine
them. [Module 8](08-data-model.md) shows how each table's engine handles
that, and how to read them correctly.

### Replication: why one server isn't enough

**The problem.** With one ClickHouse server, a crash, a restart for an
upgrade, or a broken disk means no new spans can be stored, and possibly
data lost for good.

**What replication does.** A `ReplicatedMergeTree` table keeps a full copy
on each of several servers, called **replicas**. This repo runs two:
`clickhouse-01` and `clickhouse-02`. Both hold all the spans.

Each replica needs two pieces of identity, which come from **macros**
(per-server variables in ClickHouse config). Here is
`clickhouse/macros-01.xml`:

```xml
<macros>
    <cluster>tracing</cluster>         <!-- the cluster this server belongs to -->
    <shard>01</shard>                  <!-- which slice of the data (module 9); only one here -->
    <replica>clickhouse-01</replica>   <!-- this server's name among the replicas -->
</macros>
```

`macros-02.xml` is identical except for `<replica>clickhouse-02</replica>`.
The table registers itself in Keeper at the default path
`/clickhouse/tables/{uuid}/{shard}`. `{uuid}` is the table's unique id,
the same on both servers. So both replicas meet at the same path, and each
signs in under its own `{replica}` name.

**What happens on insert:**

```mermaid
sequenceDiagram
  participant G as Gateway
  participant C1 as clickhouse-01
  participant K as Keeper
  participant C2 as clickhouse-02
  G->>C1: INSERT batch of spans
  C1->>C1: write new part to disk
  C1->>K: log entry "new part X on clickhouse-01"
  C1-->>G: OK
  K-->>C2: (watching the log) sees the entry
  C2->>C1: fetch part X over HTTP, port 9009
  C2->>C2: save part X
```

1. The gateway inserts into one replica. Its endpoint lists both
   servers (`tcp://clickhouse-01:9000,clickhouse-02:9000`). It uses
   `clickhouse-01`, and switches to `clickhouse-02` if it can't connect.
2. That replica writes the part to its own disk and adds a "new part" entry
   to the table's **log** in Keeper.
3. The other replica watches the log, sees the entry, and **downloads the
   part directly from its peer** over HTTP (the interserver port, 9009).
   The span data never goes through Keeper; only the short log entry does.

So replication is:

- **Asynchronous**: the insert returns once the first replica has the
  part. The second catches up a moment later.
- **Multi-leader**: any replica can take writes. An insert into
  `clickhouse-02` replicates to `clickhouse-01` the same way.

If you need an insert to wait until several replicas have it, the
`insert_quorum` setting does that, at the cost of slower inserts.

**Insert deduplication.** Suppose the gateway sends a batch, the network
times out before the "OK" comes back, and the gateway sends the same batch
again. Replicated tables keep a hash (a short fingerprint) of each recent
inserted block in Keeper, in a node called `blocks`. If an identical block
arrives again, ClickHouse ignores it. So retries don't create duplicate
spans, as long as the retried batch is byte-for-byte the same and among the
last 1000 blocks (`replicated_deduplication_window`).

> **Quick check:** Does span data pass through Keeper during replication?
>
> <details><summary>Answer</summary>
>
> No. Keeper holds the log entry "part X exists on replica A"; replica B
> downloads the part from replica A directly, over port 9009.
> </details>

### Keeper: the coordinator

**The problem.** Two replicas that both accept writes and both merge parts
need to agree on things: which parts exist, which merge to do next, which
schema change to apply. Without a referee, they could make different
choices and drift apart.

**What Keeper is.** ClickHouse Keeper is a small coordination service that
holds that shared state. It's compatible with Apache ZooKeeper (an older
tool that does the same job), which is why ClickHouse config calls it
`<zookeeper>` and the system table is `system.zookeeper`. It stores:

- each replicated table's log of new parts, merges and other changes
- the list of parts each replica has
- the hashes of recent insert blocks, for deduplication
- the queue of `ON CLUSTER` commands. A schema change written once with
  `ON CLUSTER tracing` is queued there, and each server picks it up and runs it

It does **not** store span data.

**Quorum.** In production you run several Keeper servers, so Keeper itself
isn't a single point of failure. They vote using the Raft algorithm: a change
counts only once a **majority** (the **quorum**) has saved it, so two halves
of a broken network can never both accept conflicting changes. Run 3 Keepers
to survive 1 failure, or 5 to survive 2.

This repo runs **one** Keeper, for simplicity: `clickhouse/keeper.xml` lists
a single voting member, and ClickHouse servers connect to it on port 9181.
With one member the majority is 1, so it works alone; but if it stops,
replicated tables can't accept writes.

> **Quick check:** Why run 3 Keepers in production, not 2?
>
> <details><summary>Answer</summary>
>
> With 2 nodes the majority is 2, so losing either one stops Keeper: no
> better than 1. With 3 the majority is still 2, so it survives one failure.
> </details>

### Failure modes

| What fails | What you see | What happens to data |
|---|---|---|
| **Keeper** | Replicated tables go **read-only**: `Code: 242 TABLE_IS_READ_ONLY`. Selects still work | Gateway retries; nothing lost if Keeper returns within `max_elapsed_time` (300 s) |
| **One replica** | `active_replicas = 1`. The other replica takes all writes | The returning replica fetches the missing parts from its peer |
| **Both replicas** | Inserts fail | Gateway queue and retries, then data loss after 300 s |
| **Too many small inserts** | `Too many parts` errors | Inserts rejected until merges catch up |
| **Disk full** | Inserts and merges fail | Same as an outage |
| **Lag** | `absolute_delay` and `queue_size` grow in `system.replicas` | Reads from that replica are stale |

The two rows worth reasoning through:

- **Keeper down.** A replica can't write a part without logging it in
  Keeper, or the other replica would never hear about it, so replicated
  tables refuse writes. Reading needs only local parts, so selects work. The
  gateway's `retry_on_failure` holds failed batches for up to 300 seconds.
- **One replica down.** The other still has Keeper and takes all writes.
  When the stopped one returns, it reads the log in Keeper, sees the parts
  it missed, and fetches them from its peer.

## Remember it

> **Parts are Lego bricks: every insert is a new brick, merges glue small
> bricks into big ones, and too many small bricks jam the machine.**
>
> **Keeper is the notary, not the warehouse.** It records which bricks exist
> and in what order; replicas ship the bricks to each other. If the notary is
> away, nobody may add bricks (read-only), but everyone can still look at them.

## In this repo

- `clickhouse/cluster.xml`: the `tracing` cluster (1 shard, 2 replicas) and
  the Keeper address (`clickhouse-keeper:9181`), plus the Keeper path for the
  `ON CLUSTER` command queue (`/clickhouse/task_queue/ddl`).
- `clickhouse/macros-01.xml`, `macros-02.xml`: the `{shard}` and `{replica}`
  values for each server.
- `clickhouse/keeper.xml`: the single Keeper node.
- `clickhouse/schema.sql`: all tables and materialized views, created with
  `ON CLUSTER tracing` so they appear on both servers.
- `compose.yaml`: the `clickhouse-init` service applies the schema, then
  waits until the schema's four replicated tables (plus any a lab added) are
  writable on both servers, before the gateway starts.
- `otel-gateway-config.yaml`: the `batch` processor (1000 spans or 5 s) and
  the exporter's `retry_on_failure` (up to 300 s).

[Module 8](08-data-model.md) walks through every table's DDL (the
`CREATE TABLE` statements). Adding a replica and copying data to another
ClickHouse server are in [module 10](10-copying-data.md).

## Principal engineer's notes

**Touch points**
- Gateway to ClickHouse (native protocol, `9000`): one `INSERT` per batch.
  Failover to `clickhouse-02` happens when a connection fails, not when an
  insert is rejected; a read-only `clickhouse-01` means retries, not failover.
- ClickHouse to Keeper (`9181`): every insert into a replicated table means
  several Keeper writes (log entry, block hash, part list). One span batch
  into `otel_traces` is four replicated inserts, because each view's target
  table is replicated too.
- Replica to replica (`9009`): whole parts, so network cost is roughly
  insert volume times (replicas - 1).

**At scale**
- Insert rate, not row count, is what hurts first. Aim for few, large
  inserts: thousands to a hundred thousand rows each, about one per second
  per table. To grow, raise `send_batch_size` before adding inserting clients.
- `async_insert` moves batching into the server instead. Trade-offs: the
  buffer lives in server memory; with `wait_for_async_insert = 0` the client
  gets "OK" before the data is on disk, so a crash loses it. Choose it when
  many clients you don't control insert directly, with no gateway.
- "Too many parts" is a per-partition limit. In 25.8, at 1000 active parts in
  one partition (`parts_to_delay_insert`) inserts are slowed down; at 3000
  (`parts_to_throw_insert`) they fail. Reaching it means merges are falling
  behind: slow disk, too little CPU, or too many tiny inserts.
- Keeper load grows with inserts times replicated tables. Keeper waits for
  its disk on every write, so give it fast local SSDs (not the ClickHouse data
  disk), and run 3 nodes for a quorum that survives one failure.
- Memory: a `GROUP BY TraceId` over days can hit the server limit (90% of
  RAM here, no per-query limit). Set `max_memory_usage` per user, and
  `max_bytes_before_external_group_by` / `_sort` to spill to disk instead.

**Operational issues**
- Replication lag is silent: a lagging replica answers queries with old
  data, so counts can jump when a load balancer switches replicas. Alert on
  `absolute_delay` ([module 12](12-operations.md)).
- Stuck `ON CLUSTER` DDL: if a host is down, the statement times out after
  `distributed_ddl_task_timeout` (180 s) but stays queued and runs when the
  host returns. Look in `system.distributed_ddl_queue` before re-running it.
- Version upgrades: pin the image (25.8, a long-term-support release, here),
  upgrade one replica at a time, wait for `queue_size = 0` before the next,
  and upgrade Keeper separately.

**Design trade-offs**
- Replication is asynchronous with no `insert_quorum`: fast inserts, but if
  `clickhouse-01` dies before `-02` fetched a part, that batch is gone if
  the disk is. Use `insert_quorum = 2` when acknowledged data must never be
  lost; for traces, it rarely pays.

## Lab (25 min)

Keep the background traffic on for this module (`./stack.sh traffic on`), so
new spans keep arriving. Run the SQL in the Play UI at
<http://localhost:8123/play> (that's `clickhouse-01`). The `system.*` tables
used below are built-in, read-only tables in which ClickHouse describes its
own state.

1. **Parts and merges.** This lists the live parts of `otel_traces`
   (`active` excludes old parts that a merge has already replaced). Run it
   twice, a minute apart:

   ```sql
   SELECT name, partition, rows, formatReadableSize(bytes_on_disk) AS size, level
   FROM system.parts WHERE database = 'otel' AND table = 'otel_traces' AND active ORDER BY name;
   ```

   You'll see one big part with a high `level`, plus a few small `level 0`
   parts, one per gateway batch. The second time, the small ones have been
   merged in, and new small ones have appeared. Read a name or two using the
   `partition_minBlock_maxBlock_level` pattern.

2. **Compression per column.** This compares each column's size on disk
   (compressed) with its size in memory (raw), for the 8 biggest columns:

   ```sql
   SELECT name, formatReadableSize(sum(data_compressed_bytes)) AS compressed,
          formatReadableSize(sum(data_uncompressed_bytes)) AS raw
   FROM system.columns WHERE database = 'otel' AND table = 'otel_traces'
   GROUP BY name ORDER BY sum(data_compressed_bytes) DESC LIMIT 8;
   ```

   `SpanAttributes` compresses about 13 times (3.2 MiB to 250 KiB in a test
   run): its keys and many values repeat from span to span. Random ids
   (`SpanId`) only compress about 2 times: random values have no repeats to
   exploit.

3. **What Keeper holds.** The first query shows this replica's view of
   replication. The second lists what Keeper stores under the table's path:

   ```sql
   SELECT zookeeper_path, replica_name, queue_size, absolute_delay, active_replicas
   FROM system.replicas WHERE table = 'otel_traces';

   SELECT name FROM system.zookeeper
   WHERE path = (SELECT zookeeper_path FROM system.replicas WHERE table = 'otel_traces' AND database = 'otel');
   ```

   In the first result, `zookeeper_path` is the
   `/clickhouse/tables/{uuid}/{shard}` path with the values filled in,
   `queue_size` and `absolute_delay` should be near 0, and
   `active_replicas` should be 2. In the second, you'll see `log`, `blocks`,
   `replicas`, `mutations` and more: metadata only, no spans.

4. **Stop Keeper.** First, while Keeper is still up, create a small
   replicated table in a separate `lab` database, so the test insert doesn't
   put a junk row into the real trace tables. `ON CLUSTER tracing` creates it
   on both servers:

   ```bash
   docker exec clickhouse-01 clickhouse-client --password demo -q \
     "CREATE DATABASE IF NOT EXISTS lab ON CLUSTER tracing"
   docker exec clickhouse-01 clickhouse-client --password demo -q \
     "CREATE TABLE IF NOT EXISTS lab.keeper_demo ON CLUSTER tracing (id UInt32, note String)
      ENGINE = ReplicatedMergeTree ORDER BY id"
   ```

   Now stop the Keeper container, wait for the servers to notice, check
   whether the tables are read-only, then try an insert into the lab table:

   ```bash
   docker stop clickhouse-keeper
   sleep 30
   docker exec clickhouse-01 clickhouse-client --password demo -q \
     "SELECT database, table, is_readonly FROM system.replicas WHERE database IN ('otel', 'lab')"
   docker exec clickhouse-01 clickhouse-client --password demo -q \
     "INSERT INTO lab.keeper_demo VALUES (1, 'during the outage')"
   ```

   Every replicated table shows `is_readonly = 1`, the four `otel` tables
   and `lab.keeper_demo` alike, and the insert fails (it can take a while to
   give up):

   ```text
   Code: 242. DB::Exception: Table is in readonly mode: replica_path=/clickhouse/tables/.../01/replicas/clickhouse-01. (TABLE_IS_READ_ONLY)
   ```

   Notice the `replica_path` in the message: it's the Keeper path, plus
   `replicas/clickhouse-01`, this server's `{replica}` name.

   Reads still work; try any `SELECT`. The gateway logs
   `Exporting failed. Will retry the request after interval.` (see it with
   `docker logs otel-gateway`). Now bring Keeper back within 5 minutes, before
   the gateway's 300-second retry limit runs out:

   ```bash
   docker start clickhouse-keeper
   sleep 30
   ```

   Then count spans per minute for the last 10 minutes:

   ```sql
   SELECT toStartOfMinute(Timestamp) AS m, count() FROM otel.otel_traces
   WHERE Timestamp > now() - INTERVAL 10 MINUTE GROUP BY m ORDER BY m;
   ```

   The minutes during the outage have spans: they waited in the gateway's
   queue and were written once Keeper was back. Nothing was lost. Run the lab
   insert again and it succeeds. When you're done, remove the lab table:
   `DROP TABLE lab.keeper_demo ON CLUSTER tracing SYNC`.

5. **Stop one replica.** This stops `clickhouse-02`, checks the replica
   count from `clickhouse-01`, starts it again, then counts spans on each
   server:

   ```bash
   docker stop clickhouse-02
   sleep 40
   docker exec clickhouse-01 clickhouse-client --password demo -q \
     "SELECT total_replicas, active_replicas FROM system.replicas WHERE table = 'otel_traces'"
   docker start clickhouse-02
   sleep 30
   docker exec clickhouse-01 clickhouse-client --password demo -q \
     "SELECT hostName(), count() FROM clusterAllReplicas('tracing', otel.otel_traces) GROUP BY 1"
   ```

   While it's down: `2  1` (two replicas, one active), and writes continue on
   `clickhouse-01`. `clusterAllReplicas('tracing', ...)` runs the query on
   every replica of the `tracing` cluster and returns all the results
   together. After `clickhouse-02` is back, both servers report the same
   count: the returning replica fetched every part it missed.

## Explain it back

> "ClickHouse stores each column separately and sorted by the table's
> `ORDER BY`, with a sparse index of one mark per 8192 rows, so filters on the
> key prefix skip most of the data. Every insert becomes an immutable part, and
> merges combine parts in the background, which is why we batch inserts. We
> partition by day so TTL can drop whole days. ReplicatedMergeTree keeps two
> replicas: an insert to either one is logged in Keeper, and the other replica
> fetches the part directly. Keeper only holds metadata, using Raft. If Keeper
> is down, tables go read-only, but reads still work and the gateway retries;
> if one replica is down, the other carries on, and the first catches up when
> it returns."

## Recap

- A column store reads only the columns a query uses, and compresses each
  column well. Tracing queries touch few columns over many rows, so it fits.
- Every insert creates an immutable, sorted part. Background merges combine
  parts. Too many small inserts cause "too many parts", so the gateway
  batches.
- `ORDER BY` sorts rows inside each part. The sparse index (one mark per
  8192-row granule) skips granules for filters on the start of the key.
- Partitions (one per day here) never merge with each other, so TTL can drop
  a whole day at once.
- With `ttl_only_drop_parts`, a day's spans live about 72 to 96 hours, and
  go when a TTL merge drops the day's parts.
- Materialized views run on each insert and fill summary tables. A
  `MATERIALIZED` column is something else: a column computed on insert.
- Replicas are full copies. Keeper holds the log of parts, not the data;
  replicas fetch parts from each other.
- Keeper down: read-only, reads OK. One replica down: the other carries on.
  Both down: the gateway retries for 300 seconds, then drops data.

## Check yourself

<details><summary>Why does the gateway batch spans instead of inserting each one as it arrives?</summary>

Every insert creates a new part. One span per insert would create parts far
faster than merges can combine them, slowing queries and finally triggering
"too many parts" errors. Batching (1000 spans or 5 seconds) turns many spans
into one part.
</details>

<details><summary>Keeper is down. Can you still run dashboards on the spans?</summary>

Yes. Reads only need the parts already on each server's disk. Only writes
(and merges, which must be logged) stop until Keeper returns.
</details>

<details><summary>The gateway times out mid-insert and retries the same batch. Do you get duplicate spans?</summary>

Usually not. Replicated tables keep hashes of recent insert blocks in Keeper
and ignore an identical block. This only works if the retried batch is
byte-for-byte the same.
</details>

<details><summary>Keeper is down for 8 minutes. Using the gateway's retry settings from module 4, which spans are lost?</summary>

Each failed batch is retried for up to 300 seconds, then dropped. Batches
from roughly the first 3 minutes of the outage run out of retry time before
Keeper returns and are lost; later batches are still retrying and get
written. (If the gateway's queue fills first, it drops even more.)
</details>

<details><summary>A span was written at 00:05 on Monday. Roughly when is it deleted?</summary>

Its part holds all of Monday, and with `ttl_only_drop_parts` the part is
dropped only once every row has expired: 72 hours after Monday ends, so about
Friday 00:00, roughly 96 hours later, at the next TTL merge.
</details>

## Next

You now know how ClickHouse stores any table. [Module 8](08-data-model.md)
answers "what exactly is in *our* tables?": it walks through `schema.sql`
line by line, including the `MATERIALIZED` columns, the partition and TTL
clauses, and the three tables the materialized views fill.

## Read more

- [MergeTree engine](https://clickhouse.com/docs/engines/table-engines/mergetree-family/mergetree)
- [Sparse primary indexes: a practical guide](https://clickhouse.com/docs/guides/best-practices/sparse-primary-indexes)
- [Table parts](https://clickhouse.com/docs/parts)
- [Table partitions](https://clickhouse.com/docs/partitions)
- [Data replication](https://clickhouse.com/docs/engines/table-engines/mergetree-family/replication)
- [ClickHouse Keeper](https://clickhouse.com/docs/guides/sre/keeper/clickhouse-keeper)
- [Materialized views](https://clickhouse.com/docs/materialized-view/incremental-materialized-view)
- [Asynchronous inserts](https://clickhouse.com/docs/optimize/asynchronous-inserts)
- [Insert deduplication](https://clickhouse.com/docs/guides/developer/deduplicating-inserts-on-retries)

# Module 6: ClickHouse storage, replicas and Keeper (45 min)

## Idea

### Columns, parts and merges

ClickHouse is a **column store**: each column is stored (and compressed) on
its own, so a query that reads 3 of 40 columns reads only those 3. That's why
it suits spans: queries usually touch a handful of fields over millions of rows.

Tables use the **MergeTree** family. The life of an insert:

1. Every `INSERT` writes a new, immutable **part**: a folder of column files,
   sorted by the table's `ORDER BY`.
2. In the background, ClickHouse **merges** small parts into bigger ones
   (the `level` goes up with each merge).
3. Too many tiny inserts create parts faster than merges can keep up, and
   ClickHouse eventually rejects inserts with **"too many parts"**. That's why
   the gateway batches (1000 spans or 5 s). The alternative, for many small
   clients, is `async_insert`, which makes the server do the batching.

Part names read `partition_minBlock_maxBlock_level`, for example
`20261121_0_467_107`: the 2026-11-21 partition, blocks 0 to 467, merged 107
times.

### Sorting key and the sparse primary index

`ORDER BY (org_owner, org_service, SpanName, toDateTime(Timestamp))` sorts the
rows inside each part. ClickHouse doesn't index every row. It splits rows into
**granules** of 8192 and keeps one index entry (**mark**) per granule: a
**sparse index**. A filter on a prefix of the key (`org_owner = ...`, then
`org_service = ...`) skips whole granules. A filter on a column that isn't in
the key (`TraceId = ...`) can't use it; module 7 covers what to do then.

**Pick the key from your most common filters, lowest cardinality first.**
Owner, then service, then span name, then time fits "show me this team's
service" queries.

### Partitions and TTL

`PARTITION BY toDate(Timestamp)` keeps each day in separate parts. Parts never
merge across partitions. Partitions are for **data management, not speed**:
dropping a day is instant. `TTL ... + INTERVAL 72 HOUR` with
`ttl_only_drop_parts = 1` deletes whole parts once all their rows have
expired, instead of rewriting parts row by row.

Keep partitions coarse: one per day is good; one per hour or per service
creates too many parts.

### Materialized views are insert triggers

A ClickHouse **materialized view** runs its `SELECT` on **each inserted
block** and writes the result into another table. Here, every span insert
also fills:

| Table | Engine | Purpose |
|---|---|---|
| `otel_traces_trace_id_ts` | ReplicatedMergeTree | Trace id to time range, so a trace lookup can narrow the time range first |
| `trace_entry` | ReplicatedReplacingMergeTree | One row per trace root: the "trace list" page |
| `span_red_1m` | ReplicatedAggregatingMergeTree | Rate, errors and duration per service and span per minute, kept 1 year |

### Replication

`ReplicatedMergeTree` keeps copies of a table on several servers
(**replicas**). The table is registered in **Keeper** at a path; here the
default `/clickhouse/tables/{uuid}/{shard}`, with each replica named by the
`{replica}` macro from `clickhouse/macros-0N.xml`.

What happens on insert:

1. The gateway inserts into any replica (`clickhouse-01` by default).
2. That replica writes the part locally and adds a "new part" entry to the
   table's **log** in Keeper.
3. The other replica sees the entry and **fetches the part directly from its
   peer** over HTTP (port 9009). The data doesn't go through Keeper; only
   the metadata does.

So replication is **asynchronous and multi-leader**: any replica takes
writes, and the others catch up within moments. (`insert_quorum` can make
inserts wait for N replicas, if you need that.)

Keeper also stores hashes of recent insert blocks (the `blocks` node), so if
the gateway **retries the same batch** after a timeout, the duplicate insert
is ignored. That's insert deduplication.

### Keeper

**ClickHouse Keeper** is a ZooKeeper-compatible coordination service, built
on the Raft consensus algorithm. It stores replication logs, part lists, block
hashes, and the queue of `ON CLUSTER` DDL commands. It does **not** store data.

Raft needs a **majority** (quorum): run 3 Keepers to survive 1 failure, or 5
to survive 2. This repo runs **one**, for simplicity, so Keeper is a single
point of failure for writes.

### Failure modes

| What fails | What you see | What happens to data |
|---|---|---|
| **Keeper** | Replicated tables go **read-only**: `Code: 242 TABLE_IS_READ_ONLY`. Selects still work | Gateway retries; nothing lost if Keeper returns within `max_elapsed_time` (300 s) |
| **One replica** | `active_replicas = 1`. The other replica takes all writes | The returning replica fetches the missing parts from its peer |
| **Both replicas** | Inserts fail | Gateway queue and retries, then data loss after 300 s |
| **Too many small inserts** | `Too many parts` errors | Inserts rejected until merges catch up |
| **Disk full** | Inserts and merges fail | Same as an outage |
| **Lag** | `absolute_delay` and `queue_size` grow in `system.replicas` | Reads from that replica are stale |

## Remember it

> **Parts are Lego bricks: every insert is a new brick, merges glue small
> bricks into big ones, and too many small bricks jam the machine.**
>
> **Keeper is the notary, not the warehouse.** It records which bricks exist
> and in what order; replicas ship the bricks to each other. If the notary is
> away, nobody may add bricks (read-only), but everyone can still look at them.

## In this repo

- `clickhouse/cluster.xml`: the `tracing` cluster (1 shard, 2 replicas) and the
  Keeper address.
- `clickhouse/macros-01.xml`, `macros-02.xml`: `{shard}` and `{replica}` per node.
- `clickhouse/keeper.xml`: the single Keeper node.
- `clickhouse/schema.sql`: all tables and materialized views, `ON CLUSTER tracing`.
- `compose.yaml`: `clickhouse-init` applies the schema, then waits until all
  four replicated tables are writable on both nodes, before the gateway starts.

## Lab (25 min)

Keep the background traffic on for this module (`./stack.sh traffic on`).

1. **Parts and merges.** Run this twice, a minute apart:

   ```sql
   SELECT name, partition, rows, formatReadableSize(bytes_on_disk) AS size, level
   FROM system.parts WHERE database = 'otel' AND table = 'otel_traces' AND active ORDER BY name;
   ```

   One big part with a high `level`, plus a few small `level 0` parts, one per
   gateway batch. The second time, the small ones have been merged in.

2. **Compression per column:**

   ```sql
   SELECT name, formatReadableSize(sum(data_compressed_bytes)) AS compressed,
          formatReadableSize(sum(data_uncompressed_bytes)) AS raw
   FROM system.columns WHERE database = 'otel' AND table = 'otel_traces'
   GROUP BY name ORDER BY sum(data_compressed_bytes) DESC LIMIT 8;
   ```

   `SpanAttributes` compresses about 13 times (3.2 MiB to 250 KiB in a test
   run); random ids (`SpanId`) only about 2 times.

3. **What Keeper holds.** Look inside it from SQL:

   ```sql
   SELECT zookeeper_path, replica_name, is_leader, queue_size, absolute_delay, active_replicas
   FROM system.replicas WHERE table = 'otel_traces';

   SELECT name FROM system.zookeeper
   WHERE path = (SELECT zookeeper_path FROM system.replicas WHERE table = 'otel_traces' AND database = 'otel');
   ```

   You'll see `log`, `blocks`, `replicas`, `mutations` and more: metadata only.

4. **Stop Keeper:**

   ```bash
   docker stop clickhouse-keeper
   sleep 30
   docker exec clickhouse-01 clickhouse-client --password demo -q \
     "SELECT table, is_readonly FROM system.replicas WHERE database = 'otel'"
   docker exec clickhouse-01 clickhouse-client --password demo -q \
     "INSERT INTO otel.trace_entry (TraceId) VALUES ('x')"
   ```

   All four tables show `is_readonly = 1`, and the insert fails (it can take a
   while to give up):

   ```text
   Code: 242. DB::Exception: Table is in readonly mode: replica_path=/clickhouse/tables/.../01/replicas/clickhouse-01. (TABLE_IS_READ_ONLY)
   ```

   Reads still work; try any `SELECT`. The gateway logs
   `Exporting failed. Will retry the request after interval.` Now bring Keeper
   back within 5 minutes:

   ```bash
   docker start clickhouse-keeper
   sleep 30
   ```

   ```sql
   SELECT toStartOfMinute(Timestamp) AS m, count() FROM otel.otel_traces
   WHERE Timestamp > now() - INTERVAL 10 MINUTE GROUP BY m ORDER BY m;
   ```

   The minutes during the outage have spans: they waited in the gateway's
   queue and were written once Keeper was back. Nothing was lost.

5. **Stop one replica:**

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
   `clickhouse-01`. After it's back, both nodes report the same count: the
   returning replica fetched every part it missed.

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

## Check yourself

<details><summary>Does the data go through Keeper during replication?</summary>

No. Keeper holds the log entry "part X exists on replica A"; replica B
downloads the part from replica A directly (the interserver HTTP port, 9009).
</details>

<details><summary>Why would partitioning by <code>ServiceName</code> be a bad idea?</summary>

Parts never merge across partitions, so many services times many days means
many small parts, slower merges and "too many parts" errors. Partition by
time, for retention; put the service in the sorting key, for speed.
</details>

<details><summary>Why run 3 Keepers in production, not 2?</summary>

Raft needs a majority. With 2 nodes, the majority is 2, so losing either one
stops the cluster, which is no better than having 1. With 3, the majority is
2, so the cluster survives one failure.
</details>

<details><summary>The gateway times out mid-insert and retries the same batch. Do you get duplicate spans?</summary>

Usually not. Replicated tables keep hashes of recent insert blocks in Keeper
and ignore an identical block. This only works if the retried batch is
byte-for-byte the same.
</details>

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

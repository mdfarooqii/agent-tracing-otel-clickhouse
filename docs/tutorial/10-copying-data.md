# Module 10: Growing the cluster and copying data between ClickHouse servers (60 min)

## Why this matters

Sooner or later the cluster has to grow (disks fill up, queries get slower,
a server dies), and sooner or later you need spans somewhere else: a copy for
testing, a second region. ClickHouse grows in four different ways (more
disk, bigger servers, more replicas, more shards), and they differ in what
they add, what moves, and what the people querying it notice. Copying has
several methods too, and picking the wrong one either doesn't work or
quietly loses rows.

This module covers both. First growth: when to use which option, how local
and `Distributed` tables split the work, how to add a node, a shard and a
disk, and what ClickStack, Grafana and other readers should point at. Then
copying, sorted by one question, **do the two servers share a Keeper?**, and
including an ongoing copy that doesn't drop late spans.

**What you'll be able to do after this module:**

- Pick the right way to grow (disk, server size, replica or shard) for a
  given bottleneck.
- Say which component uses the local tables and which uses the `Distributed`
  tables, and set up ClickStack and read-only users on a sharded cluster.
- Add a node to the cluster definition, add a shard, and give a server more
  disks, and check each step in system tables.
- Add a third replica that copies all existing data by itself.
- Copy tables to an unrelated ClickHouse server with `remote()`, once and
  then incrementally, without missing spans that arrive late.
- Move partitions between replicated tables with `FETCH` and `ATTACH`.
- Choose between replication, `remote()`, dual-write and backups for a
  given situation.

## Key terms

| Term | Plain meaning |
|---|---|
| Table function | A function used in place of a table name in `FROM`, like `remote(...)` or `numbers(10)` |
| `remote()` | A table function that reads a table on another ClickHouse server, as if it were local |
| `GLOBAL IN` | An `IN (subquery)` whose subquery runs on your server and is sent to the remote one, instead of running over there |
| Watermark | "How far the copy has got": here, the newest `Timestamp` already in the target |
| Late span | A span that reaches ClickHouse after spans that started later than it |
| Dual-write | Sending every span to two destinations, for example two `clickhouse` exporters in the gateway |
| Refreshable materialized view | A materialized view that re-runs its query on a schedule, instead of on each insert |
| Detached folder | A per-table folder where parts sit on disk without being part of the table, until attached |
| `FETCH` / `ATTACH PARTITION` | Download a partition from another replicated table into the detached folder, then add it to this table |
| Hard link | An extra file name pointing to the same data on disk, so "copying" costs nothing |
| Local table | The table that really stores rows on one server (here a `ReplicatedMergeTree`), for example `otel_traces_local` |
| Cluster definition | The `<remote_servers>` section in every server's config: named lists of shards and replicas ([module 9](09-sharding-indexes.md)) |
| Shard weight | A number per shard in the cluster definition; a `Distributed` table sends each shard a share of new rows proportional to it |
| Storage policy | A table setting that lists the **volumes** (groups of disks) the table may write to, in order ([module 11](11-s3-tiering.md)) |
| JBOD | "Just a bunch of disks": several disks in one volume, used side by side, with no RAID |
| `readonly = 2` | A user setting: may read and change query settings, but may not write or change tables |
| Row policy | A filter ClickHouse adds to every read of a table by given users, for example "only `org_owner = 'hr'`" |

## Idea

### Four ways to grow, and what each one buys

The first question is never "how do I add a server", it's "what is running
out?" Each option fixes a different bottleneck:

| Option | Fixes | What moves | Who notices |
|---|---|---|---|
| **More disk** on each server (grow the volume, or add a disk) | Disk filling up, while CPU and memory are fine | Nothing (optionally old partitions, by hand) | Nobody |
| **Bigger servers** (more CPU and RAM, same disks) | Slow or memory-limited queries, merges falling behind | Nothing; a rolling restart, one replica at a time | Nobody, if a replica stays up |
| **Add a replica** to every shard | Too many concurrent queries; surviving a lost server | All data of that shard is copied to the new replica | Nobody; reads spread over more servers |
| **Add a shard** | One server can't hold its share of the data, or can't take the insert rate | **Nothing**; only new rows go to the new shard | The routing changes, so some traces in flight split (below) |
| **Move old data to S3** | Disk, when most data is rarely read | Old parts, automatically ([module 11](11-s3-tiering.md)) | Old-data queries are slower |

Two consequences:

- **A replica never adds storage**, and a shard never adds safety. A
  replica holds the same rows; a shard holds different rows.
- **Prefer the options that move nothing.** Disk and server size are cheap
  to change on cloud volumes. Adding a shard is the big step: plan it
  months ahead, because the data is only balanced once the old data has aged
  out (72 hours here, much longer elsewhere).

### Local tables and `Distributed` tables: who uses which

This repo's `tracing` cluster has one shard, so there is one table per kind
of data, and everybody uses it ([module 9](09-sharding-indexes.md)). With two
or more shards, each kind of data becomes a **pair**: a local table on every
server that stores that server's slice, and a `Distributed` table on top that
stores nothing and routes. The usual naming keeps the familiar name for the
`Distributed` table, so tools and users never have to change:

```sql
-- On every server: stores this shard's rows (what schema.sql creates today).
CREATE TABLE otel.otel_traces_local ON CLUSTER tracing (...)
ENGINE = ReplicatedMergeTree ...;

-- On every server: the name everyone uses.
CREATE TABLE otel.otel_traces ON CLUSTER tracing AS otel.otel_traces_local
ENGINE = Distributed(tracing, otel, otel_traces_local, cityHash64(TraceId));
```

Who uses which:

| Component | Uses | Why |
|---|---|---|
| Gateway's `clickhouse` exporter | `otel_traces` (`Distributed`) | It routes each span to its shard by trace id. Alternative: a routing gateway tier that writes straight to each shard's local table (module 9, production variant) |
| Materialized views (`trace_entry_mv`, `span_red_1m_mv`, ...) | **Read from the local table**, write to local tables | A view fires on the table that receives the insert. A `Distributed` insert ends up as an insert into one shard's `otel_traces_local`, so the views must hang off the local table there |
| ClickStack, Grafana, people, scripts | `Distributed` tables only | They see all shards. Querying a local table silently returns one shard's slice |
| `CREATE`, `ALTER`, `DROP` | Both, always `ON CLUSTER` | Every server needs the same local table and the same `Distributed` table |
| Operators | Local tables on one server | `system.parts`, `OPTIMIZE`, `MOVE PARTITION`, `FETCH`, `SYSTEM DROP REPLICA` all work per server |

The derived tables in `schema.sql` show why the sharding key has to be the
trace id:

- **`trace_entry`** is a `ReplacingMergeTree`: merges keep the root span's
  row over the `org_request_id` row of the same trace. Merges only combine
  rows **on one shard**, and `FINAL` is applied per shard too. Sharded by
  trace id, both rows are on the same shard, and replacing works.
  Sharded any other way, both rows survive.
- **`span_red_1m`** stores partial aggregates (`quantilesState`). Each shard
  has its own partial rows for a minute; a query on its `Distributed` table
  with `quantilesMerge` combines them across shards correctly. Aggregate
  tables don't care about the key.
- **`otel_traces_trace_id_ts`** (start and end per trace, for ClickStack's
  trace lookup) is read with `min` and `max`, which also combine correctly.

> **Quick check:** After sharding, someone creates a new view `FROM otel.otel_traces` (the `Distributed` table). It stays empty although spans arrive. Why?
>
> <details><summary>Answer</summary>
>
> A view fires on the table that receives the insert. The rows are inserted into `otel_traces_local` on each shard; the `Distributed` table only forwards them, and on the receiving shards nothing is inserted into `otel_traces` itself. Create the view `FROM otel.otel_traces_local`, `ON CLUSTER`, writing to a local table, plus a `Distributed` table over that for reads.
> </details>

### Adding a node to the cluster definition

A new server becomes part of a cluster in two independent ways, and it
needs both:

1. **Keeper membership** decides what it stores: its replicated tables
   register under a Keeper path, and it fetches parts from its peers.
2. **The cluster definition** (`<remote_servers>` in `cluster.xml`) decides
   who *talks* to it: `ON CLUSTER` DDL runs on every listed host, a
   `Distributed` table sends rows and queries to the listed shards, and
   `cluster()` / `clusterAllReplicas()` read from the listed hosts.

A replica that is in Keeper but not in the definition holds all the data,
but `ON CLUSTER` changes skip it (so its tables drift from the others), and
`Distributed` queries never use it. The lab shows this with `clickhouse-03`.

To add a host:

- Add its `<replica>` (or a new `<shard>`) to the cluster in `cluster.xml`
  on **every** server, from your config management, in the same change. A
  server whose file is out of date routes with the old layout.
- No restart is needed: ClickHouse watches its config files and reloads
  `remote_servers` within seconds (`SYSTEM RELOAD CONFIG` forces it). In a
  test, an existing `Distributed` table started using a newly added shard
  about 12 seconds after the file changed, without being recreated.
- Check on every server: `SELECT cluster, shard_num, replica_num, host_name
  FROM system.clusters WHERE cluster = 'tracing'`, and `errors_count` there
  for hosts it can't reach.

> **Quick check:** You add `ch-05` to `cluster.xml` on four of five servers and forget the fifth. What goes wrong?
>
> <details><summary>Answer</summary>
>
> `ON CLUSTER` DDL started from the fifth server skips `ch-05`, and if `ch-05` is a new shard, inserts arriving at the fifth server are routed with the old shard count, so their traces go to different shards than the same trace ids written elsewhere. Roll cluster definitions out everywhere at once, and compare `system.clusters` across servers (`clusterAllReplicas('tracing', system.clusters)`).
> </details>

### Adding a replica

A replicated table is identified in Keeper by its path. If a new server
creates a table that resolves to the **same path** (here: the same UUID and
`{shard}`), with a **new** `{replica}` name, it joins as one more replica.
Keeper's log lists every part, so the new replica downloads all of them from
its peers. You copy no data yourself. (Remember from module 7: replicas
download parts from each other over port 9009; Keeper holds only the list.)

The `{shard}` macro decides which shard the new server joins
([module 9](09-sharding-indexes.md)). In a sharded cluster, you add replicas
shard by shard: a new server with `<shard>02</shard>` becomes a copy of
shard 2 only. Adding a replica never adds storage capacity; adding a shard
does, but existing rows stay where they are (module 9).

> **Quick check:** You create the table on the new server but copy the DDL without its UUID. What happens?
>
> <details><summary>Answer</summary>
>
> The table gets a new UUID, so `{uuid}` resolves to a new Keeper path. It becomes the first replica of a brand-new, empty table instead of joining the existing one. That's why `add-replica.sh` copies the DDL with the UUID.
> </details>

### Adding a shard

**What happens.** A `Distributed` table names a cluster, not servers. Add a
shard to the cluster definition and every `Distributed` table on that
cluster starts routing new rows over the new count of shards, within
seconds and without being recreated. **No existing row moves.** The lab
shows both: after going from two shards to three, shard 3 held none of the
old 3000 rows and a third of the new ones.

**The steps, for this repo's tables:**

1. Start the new shard's servers, as many as the other shards have replicas,
   each with `{shard}` set to the new number (`03`) and its own
   `{replica}`, pointing at the same Keeper.
2. Add the shard to the cluster definition on every server, and check
   `system.clusters` everywhere.
3. Create the schema on the new servers: run the `CREATE ... IF NOT EXISTS
   ... ON CLUSTER` statements again, in schema order (local tables, then
   views, then `Distributed` tables). Servers that have the tables skip
   them. The new shard's tables get their own Keeper path anyway (its
   `{shard}` differs), so their UUID needn't match the other shards'; its
   replicas must share one, which a single `ON CLUSTER` statement gives
   them. Do this **before** step 2's change reaches the servers that
   insert: otherwise rows routed to the new shard fail there and pile up
   in the sender's queue (`system.distribution_queue`). They aren't lost:
   in a test, the queue's `error_count` reached 5 while the table was
   missing, and all rows arrived once it existed.
4. Watch the new shard's share grow:
   `SELECT shardNum(), count() FROM otel.otel_traces GROUP BY 1`.

**What breaks a little, for a while:**

- **Traces in flight split.** The shard is `cityHash64(TraceId)` modulo the
  number of shards. Spans of a trace that arrive after the change can go to a
  different shard than its earlier spans. In the lab 136 of 200 traces that
  got one more span were split. Queries through the `Distributed` table
  still return the whole trace; `trace_entry`'s replacing doesn't happen
  across shards, so a split trace can have two rows there until it ages out.
  Add shards when traffic is low.
- **Lookups that skip shards** (`optimize_skip_unused_shards = 1`, module 9)
  compute the shard from the trace id with the *new* count, and miss old
  traces. Turn that setting off for the length of the TTL.
- **The old shards stay fuller** until their old data ages out (72 hours
  here). That's the usual answer: wait. To fill the new shard faster, give it
  a higher `<weight>` in the cluster definition; each shard then gets a share
  of new rows proportional to its weight. Every weight change re-routes trace
  ids again (more splits), including the one that sets it back.
- **Real rebalancing** means re-inserting old rows through the `Distributed`
  table and deleting them from their old shard: the copying tools below,
  at the cost of moving almost all data. With short retention, don't.

> **Quick check:** You add shard 3 at 14:00. At 14:05, a user opens a trace that started at 13:59. Is it complete?
>
> <details><summary>Answer</summary>
>
> Yes, through the `Distributed` table: it asks every shard, so spans written before 14:00 to shard 1 and after 14:00 to shard 3 both come back. It would be incomplete with `optimize_skip_unused_shards = 1`, which asks only the shard the new count points to, or for anyone querying a local table directly.
> </details>

### More disk on a server

Two ways, both online. ClickHouse doesn't care which one you use; it only
sees a mount point and the free space on it (`system.disks`).

**Grow the volume you have.** Cloud volumes can grow in place: on AWS,
modify the EBS volume's size, then grow the partition (`growpart`, if the
volume has one) and the file system (`xfs_growfs` for XFS). The new size
can be used once the modification reaches the `optimizing` state, usually
seconds later. ClickHouse reads free space from the file system each time,
so it sees the new space without a restart. This is the simplest option,
and the one to reach for first. Two limits: a volume can't shrink, and the
next modification of the same volume has to wait until the current one is
`completed` (at most four in 24 hours). The full steps are in the
[runbooks](appendix-runbooks.md#grow-an-ebs-volume-in-place).

**Add a disk.** When one volume can't grow more, or for more throughput,
mount a second volume and let ClickHouse use both:

1. Format and mount it (say `/mnt/disk2`), owned by the `clickhouse` user.
2. Add it to the config as a disk, and add a **new storage policy** that
   contains everything the table's current policy has, plus the new disk:
   same volume names, same order, same disks, one more disk in a volume.
   For a table on the built-in `default` policy, that's a volume named
   `default` holding `default` and `disk2`
   (`docs/tutorial/labs/storage-more-disks.xml`).
3. Reload the config (automatic within seconds, or `SYSTEM RELOAD
   CONFIG`). Added disks and policies appear in `system.disks` and
   `system.storage_policies`.
4. Switch the table:
   `ALTER TABLE ... ON CLUSTER tracing MODIFY SETTING storage_policy = 'grown'`.
   The policy must already be in the config on every server the `ALTER`
   reaches.
5. Optionally move some old partitions:
   `ALTER TABLE ... MOVE PARTITION '2026-11-01' TO DISK 'disk2'`.

What to expect, all checked in the lab:

- **New parts go to the disks of a volume in turn** (round-robin), so new
  data spreads over both disks, while existing parts stay where they are
  until merged or moved.
- **The switch is one-way.** Going back from `grown` to `default` fails:
  "New storage policy `default` shall contain disks of the old storage
  policy `grown`". Renaming a volume fails the same way, with "volumes".
- **A disk in use can't be removed from the config**; reloading such a
  config fails ([module 11](11-s3-tiering.md) shows the same for S3). Even
  a disk no table uses any more stays in `system.disks` after a reload, until
  the server restarts.
- Tables on the `tiered` policy (`otel_traces` after module 11) need their
  own new policy, `tiered_v2`: volume `default` with `default` and `disk2`,
  then volume `cold` with `s3_cache`, unchanged.

Several disks in a volume are **JBOD**: no RAID, so a disk failure loses
the parts on that disk, on this server. With replicas that's an ordinary
server repair ([runbook](appendix-runbooks.md#replace-a-failed-node)); a
non-replicated table loses them.

> **Quick check:** Disks are 85% full. The cluster has 2 shards × 2 replicas, CPU is at 30%. Add a shard or grow the disks?
>
> <details><summary>Answer</summary>
>
> Grow the disks (or tier old data to S3, module 11). Disk is the only thing running out, growing it moves nothing and nobody notices. A shard would add CPU you don't need, take until the TTL to balance, and split traces in flight.
> </details>

### What users and tools see

With a sharded cluster, everything that reads goes through the
`Distributed` tables, and every read-only account is set up so it can't do
otherwise.

**ClickStack (HyperDX), Grafana, scripts.** A ClickStack **Trace source**
names a database and a table, plus column expressions (timestamp, trace id,
span id, duration...). Point it at `otel.otel_traces`, the `Distributed`
table, never at a local one. Two source settings matter on a cluster:

- **Known Columns List** is for sources over a `Distributed` or `Merge`
  table whose underlying tables don't all have the same columns, for example
  halfway through a rolling `ALTER ... ADD COLUMN`. ClickStack then fetches
  those columns instead of `SELECT *`.
- **Query Settings** (up to ten) are added to every query of the source, for
  example `max_execution_time`.

The same goes for Grafana's ClickHouse data source and for scripts: query
the `Distributed` tables.

**Accounts.** One per tool or team, created `ON CLUSTER` so every server
knows it:

```sql
CREATE USER clickstack ON CLUSTER tracing IDENTIFIED BY '...' SETTINGS readonly = 2;
GRANT ON CLUSTER tracing SELECT ON otel.otel_traces, otel.otel_traces_local TO clickstack;
```

- **`readonly = 2`**: may read, may change query settings, may not write
  or change tables. With `readonly = 1`, any query that sets a setting
  (a source's Query Settings, a UI's timeout) fails with "Cannot modify
  'max_execution_time' setting in readonly mode".
- **Grant both tables.** A query on the `Distributed` table also needs
  SELECT on the local table. In the lab, the grant on the `Distributed`
  table alone failed with "it's necessary to have the grant SELECT for at
  least one column on grow.spans_local".
- **Row policies go on the local tables**, `ON CLUSTER`: the data is read
  there. In the lab, a policy on `grow.spans_local` cut a read-only user's
  count through `grow.spans` from 6200 to 1700 rows.
- **Give the cluster a `<secret>`, or row policies leak.** The other shards
  run their part of a `Distributed` query as some user. With a `<user>` and
  `<password>` per replica in the cluster definition (as in this repo's
  `tracing` and `lab_2shards`), that's the listed user, usually `default`,
  with no row policy: only the server you queried filters. With a shared
  `<secret>` in the cluster definition, the shards run it as the user who
  sent it, with that user's grants and policies. In the lab, the same user
  and the same policy returned 1700 rows through a cluster with a secret
  and 3369 through one without: shard 2 sent all its rows. (Users can't
  route around this with `cluster()` or `remote()`: those need the
  `REMOTE` grant, which read-only accounts don't get.)
- **Limits** belong in a settings profile (`max_execution_time`,
  `max_memory_usage`, `max_rows_to_read`) and a quota (queries or rows per
  hour), so one dashboard can't starve the gateway's inserts.
- The gateway's own account needs INSERT on both tables too: with INSERT on
  the `Distributed` table only, the insert fails with "necessary to have
  the grant INSERT(...) ON grow.spans_local".

> **Quick check:** A team's Grafana panel queries `otel.otel_traces_local` and its numbers are about half of ClickStack's. What happened?
>
> <details><summary>Answer</summary>
>
> With two shards, a local table holds one shard's slice, so a query on it counts about half the rows. Point the panel at `otel.otel_traces`. Grants can't prevent this, because queries on the `Distributed` table need SELECT on the local table too; the naming does: the familiar name is the `Distributed` table, and `_local` signals "not this one".
> </details>

### Copying data: same Keeper or not

Quick reminders: a **replica** is a full copy of a table on another server,
kept in step through **Keeper**, the coordinator that holds each replicated
table's list of parts under a path like `/clickhouse/tables/{uuid}/{shard}`
([module 7](07-clickhouse.md)). A **partition** is one day of spans, here.
Servers that share a Keeper can use replication. Servers that don't have to
copy rows over the network.

| Goal | How | Shared Keeper needed |
|---|---|---|
| **Add a replica**, or rebuild a lost one | Create the same table (same UUID or path) on the new server with its own `{replica}` macro. It registers in Keeper and **fetches every part** from its peers | Yes |
| **One-off copy from any ClickHouse** | `INSERT INTO t SELECT * FROM remote('host', db.t, 'user', 'password')` (`remoteSecure` for TLS) | No |
| **Keep copying** | Repeat the `remote()` insert for an overlapping time window and skip rows you already have; or a refreshable materialized view; or **dual-write** at the gateway | No |
| Copy partitions between replicated tables | `ALTER TABLE t FETCH PARTITION ... FROM '<keeper path>'`, then `ATTACH PARTITION` | Yes |
| Copy within one server | `ALTER TABLE t ATTACH PARTITION ... FROM other_table` (instant, hard links) | No |
| Snapshot and restore | `BACKUP TABLE ... TO Disk(...)` or `S3(...)`; `RESTORE` | No |
| Turn a single-node `MergeTree` into `ReplicatedMergeTree` | Create a replicated table and `ATTACH PARTITION FROM` the old one; or put a `convert_to_replicated` flag file in the table's data directory and restart | Yes, afterwards |

> **Quick check:** A test team wants yesterday's spans on their own laptop ClickHouse. Which row of the table?
>
> <details><summary>Answer</summary>
>
> A one-off `remote()` copy with a `WHERE` on yesterday's date. The laptop shares no Keeper, and making it a replica would pull every part of every table and add it to production's replica set.
> </details>

### `remote()`: pull rows from any server

`remote('host', db.table, 'user', 'password')` reads a table on another
server over the normal ClickHouse port (9000). `INSERT INTO t SELECT * FROM
remote(...)` pulls every row across. `remoteSecure` does the same over TLS
(encrypted connections). The servers share nothing but a network and a
password.

Remember from [module 6](06-cross-environment.md): `remote()` also works
without copying, joining two environments' halves of a trace at query time
with `UNION ALL`.

### Keep copying, without losing late spans

**The problem.** After a full copy, you want to copy only what's new, on a
schedule. The obvious version uses the newest timestamp the target already
has as the watermark:

```sql
INSERT INTO otel.otel_traces
SELECT * FROM remote('clickhouse-01', otel.otel_traces, 'default', 'demo')
WHERE Timestamp > (SELECT max(Timestamp) FROM otel.otel_traces);
```

This **drops spans**. `Timestamp` is when a span *started*, not when it
reached ClickHouse, and spans don't arrive in start order:

- The HR request's `agent_turn` span starts first, but it's exported only
  when the turn ends, after all its children. By the time it arrives, the
  source already holds child spans that started later.
- The gateway retries failed writes for up to 300 seconds
  (`retry_on_failure.max_elapsed_time: 300s` in `otel-gateway-config.yaml`),
  so a batch can land minutes after newer ones.

If a copy runs between those moments, the target's `max(Timestamp)` is
already past the late span's start, and no later run looks back far enough
to pick it up.

**The fix: overlap and deduplicate.** Re-read a window that starts well
before the watermark, longer than spans can be late (10 minutes covers the
300-second retry limit plus a long turn), and skip the spans the target
already has:

```sql
INSERT INTO otel.otel_traces
WITH (SELECT max(Timestamp) - INTERVAL 10 MINUTE FROM otel.otel_traces) AS since
SELECT * FROM remote('clickhouse-01', otel.otel_traces, 'default', 'demo')
WHERE Timestamp > since
  AND (TraceId, SpanId) GLOBAL NOT IN
      (SELECT TraceId, SpanId FROM otel.otel_traces WHERE Timestamp > since);
```

- `since` is computed once, on the target: its newest span minus 10 minutes.
- The overlap would copy some spans twice, so `(TraceId, SpanId)`, which
  identifies a span, filters out those already present.
- **`GLOBAL` matters.** With a plain `NOT IN`, ClickHouse sends the whole
  `WHERE`, subquery included, to the remote server, which then compares its
  table with itself and copies nothing. `GLOBAL NOT IN` runs the subquery
  here and ships the list of ids across.

Another way to deduplicate is to make the target a `ReplacingMergeTree`
with `SpanId` in its sorting key, copy the overlap blindly, and let merges
remove duplicates (read with `FINAL`, as in [module 8](08-data-model.md)).
That moves the cost from the copy to reads and merges.

A **refreshable materialized view** can run this kind of query on a
schedule inside ClickHouse. Or skip copying entirely: give the gateway two
`clickhouse` exporters, one per destination, so every span is written to
both (**dual-write**).

> **Quick check:** Someone raises the gateway's `max_elapsed_time` to 30 minutes. What must change in the copy job?
>
> <details><summary>Answer</summary>
>
> The overlap. Spans can now arrive up to 30 minutes late, so a 10-minute look-back misses some. Make the window longer than the new limit plus the longest turn, for example 40 minutes.
> </details>

### Moving partitions and snapshots

- **`FETCH PARTITION` and `ATTACH PARTITION`.** `FETCH` downloads all parts
  of one partition (one day, here) from another replicated table's replicas,
  using that table's Keeper path, into this table's **detached** folder.
  Detached parts sit on disk but aren't part of the table yet. `ATTACH`
  moves them in, and they become visible.
- **`ATTACH PARTITION ... FROM other_table`** on the same server doesn't copy
  data at all: it creates **hard links**. It's instant, but both tables need
  the same structure and partition key.
- **`BACKUP` and `RESTORE`** write a snapshot of tables to a disk or to S3
  storage, and restore it later on any server.

### Two things that catch people out

- **`SELECT *` skips `MATERIALIZED` columns** (module 8), so a `remote()`
  copy inserts only the stock columns, and the target recomputes the rest.
  That's what you want: the copy is consistent with the target's own schema.
- **Materialized views fire on inserts, not on replication.** Parts fetched
  by a new replica don't run its views, but they don't need to: the target
  tables replicate on their own. A new replica still needs the views, so
  that inserts it receives *directly* fill the derived tables.

## Remember it

> **Find what's running out first. Disk and server size move nothing; a
> replica adds reads and safety, not space; a shard adds space and moves
> nothing either, so it's balanced only after the TTL.**
>
> **Everything that reads goes through `Distributed` tables; views and
> grants are anchored on the local tables.**
>
> **Same Keeper? Let replication do it. Different Keeper? Pull with
> `remote()`.**
>
> **An incremental copy must look back further than spans can be late, and
> skip what it already has.**

## In this repo

- `docs/tutorial/labs/compose.replication.yaml`: two extra servers for this
  lab: `clickhouse-03` (a third replica, same Keeper, using
  `docs/tutorial/labs/macros-03.xml`, which sets `{shard}` to `01` and
  `{replica}` to `clickhouse-03`; its Play UI is on port 8125) and
  `clickhouse-solo` (standalone, no Keeper; its Play UI is on port 8126).
- `clickhouse/cluster.xml`: `lab_3shards` lists `clickhouse-01`, `-02`
  and `-03` as three shards, for the add-a-shard lab, with a `<secret>` so
  shards run queries as the user who sent them. `tracing` doesn't list
  `clickhouse-03`, on purpose: lab step 2 shows what that changes.
- `docs/tutorial/labs/storage-more-disks.xml`: a second disk and the
  `grown` policy, for the more-disk lab on `clickhouse-solo`.
- `docs/tutorial/labs/add-replica.sh`: copies each `otel` table's DDL, with
  its UUID, from `clickhouse-01` to `clickhouse-03`. Tables first, then the
  views that write into them.
- `otel-gateway-config.yaml`: `retry_on_failure`, which bounds how late a
  span can arrive.

## Principal engineer's notes

**Touch points**
- Adding a replica uses touch points 4 and 5 from [module 0](00-setup.md):
  Keeper for the part list, port 9009 for the bytes. `remote()` uses the
  native port 9000 and a ClickHouse user, so the copy job needs a read-only
  account on the source and a network path to it.
- The copy contract is the **schema**. If source and target differ (a column
  added on one side, columns reordered), `INSERT ... SELECT *` matches
  columns by position: it fails on a count mismatch, or worse, puts values
  in the wrong column when types happen to fit. List columns explicitly in
  long-lived copy jobs, and change both sides in the same release.

**At scale**
- **Plan shards from the insert rate and the retention, not today's disk.**
  Disks grow online in minutes; a shard takes a TTL to balance. A common
  rule of thumb: keep disks under about 70% full, and add capacity at 60%,
  so a failed replica's rebuild or a big merge never runs a disk out.
- **The cluster definition is code.** Generate `remote_servers` and the
  macros from one inventory (Ansible, Helm, the ClickHouse operator) and
  roll it to every server in one change. Hand-edited copies drift.
- A new replica copies **everything** over the network. 5 TB at an
  effective 1 Gbit/s is about 11 hours, while the peers spend disk and
  network on serving it. Throttle with the table setting
  `max_replicated_fetches_network_bandwidth` or the server-wide
  `max_replicated_fetches_network_bandwidth_for_server` (both bytes per
  second, 0 = unlimited), and add replicas off-peak.
- `GLOBAL NOT IN` ships the id list across the network and holds it in
  memory. Keep the window short (minutes, run often) rather than long and
  rare, or switch to a `ReplacingMergeTree` target.

**Operational issues**
- **Backups are not replicas.** A bad `ALTER ... DELETE` or a dropped table
  replicates instantly to every copy. Only `BACKUP ... TO S3(...)` protects
  against that. Restore into a scratch database on a schedule; a backup
  never restored is a hope, not a backup.
- **Idempotency.** Every copy job must survive being run twice or killed
  halfway. Overlap plus dedup gives that; a watermark kept outside the data
  (a file, a variable) usually doesn't.
- A replica stuck fetching shows as a growing `queue_size` in
  `system.replicas` ([module 12](12-operations.md)).

**Design trade-offs**
- **Shard at the gateway or in ClickHouse?** Inserting through
  `Distributed` tables is simplest. It costs a second hop (the receiving
  server forwards most rows) and a local queue that can fill a disk while a
  shard is down. A routing gateway tier that writes to each shard's local
  table avoids both, at the cost of keeping the shard list in two places.
- **Cross-region:** prefer dual-write from the gateway, so each
  region gets spans on its own and a region outage loses nothing already
  written. A scheduled `remote()` copy is simpler to add later but lags by
  its interval. A stretched Keeper across regions is the option to avoid.

## Lab (35 min)

Start the two extra servers (from the repo root). Passing two `-f` files
tells Docker Compose to combine them, so the lab file adds services to the
main stack:

```bash
docker compose -f compose.yaml -f docs/tutorial/labs/compose.replication.yaml up -d clickhouse-03 clickhouse-solo
```

If you've already done [module 11](11-s3-tiering.md) and S3 tiering is on,
`otel_traces` uses the `tiered` storage policy, and a replica needs it too:
start `clickhouse-03` with the command at the top of
`docs/tutorial/labs/compose.replication-s3.yaml` instead. `add-replica.sh`
stops with that hint if the policy is missing.

1. **Add a third replica.** It copies everything by itself. The script
   creates empty tables with the same UUIDs on `clickhouse-03`; then this
   checks replication status there, and compares row counts:

   ```bash
   docs/tutorial/labs/add-replica.sh
   sleep 15
   docker exec clickhouse-03 clickhouse-client --password demo -q \
     "SELECT table, total_replicas, active_replicas, queue_size FROM system.replicas WHERE database = 'otel'"
   for h in clickhouse-01 clickhouse-03; do
     docker exec $h clickhouse-client --password demo -q "SELECT '$h', count() FROM otel.otel_traces"
   done
   ```

   ```text
   otel_traces              3  3  0
   ...
   clickhouse-01  35003
   clickhouse-03  35003
   ```

   `3  3  0` means three replicas, all active, nothing left in the fetch
   queue; the two counts match (yours will differ). The script only created
   empty tables; Keeper told `clickhouse-03` which parts exist, and it
   fetched them. New spans keep arriving on all three. Writes work in
   any direction: a row inserted on `clickhouse-03` shows up on
   `clickhouse-01`, including in `trace_entry`, via `clickhouse-03`'s own
   view.

2. **Is the new node in the cluster?** `clickhouse-03` now holds every
   `otel` table, but it isn't listed in the `tracing` cluster definition
   (only in `lab_3shards`). See what that means:

   ```bash
   docker exec -i clickhouse-01 clickhouse-client --password demo --multiquery --format PrettyCompactMonoBlock <<'SQL'
   SELECT cluster, shard_num, replica_num, host_name FROM system.clusters
   WHERE cluster IN ('tracing', 'lab_3shards') ORDER BY cluster, shard_num, replica_num;
   SELECT hostName() AS host, count() AS spans
   FROM clusterAllReplicas('tracing', otel.otel_traces) GROUP BY host ORDER BY host;
   SQL
   ```

   ```text
   ┌─cluster─────┬─shard_num─┬─replica_num─┬─host_name─────┐
   │ lab_3shards │         1 │           1 │ clickhouse-01 │
   │ lab_3shards │         2 │           1 │ clickhouse-02 │
   │ lab_3shards │         3 │           1 │ clickhouse-03 │
   │ tracing     │         1 │           1 │ clickhouse-01 │
   │ tracing     │         1 │           2 │ clickhouse-02 │
   ┌─host──────────┬──spans─┐
   │ clickhouse-01 │ 131110 │
   │ clickhouse-02 │ 131110 │
   ```

   (Your span counts differ.) Keeper knows three replicas (step 1 showed
   `3  3  0`), but anything that
   goes through the cluster definition sees two: `clusterAllReplicas`
   leaves out `clickhouse-03`, and so would `ON CLUSTER tracing` DDL. In
   production you'd add a `<replica>` for it to `tracing` in `cluster.xml`
   on every server; ClickHouse rereads the file by itself within seconds.
   The lab leaves `tracing` alone, so that removing `clickhouse-03` at the
   end leaves nothing behind.

3. **Add a shard.** `docs/tutorial/labs/add-shard.sql` builds a small
   sharded table on two shards, adds `clickhouse-03` as a third shard, sends
   more traffic, and shows where rows landed:

   ```bash
   docker exec -i clickhouse-01 clickhouse-client --password demo --multiquery \
     --format PrettyCompactMonoBlock < docs/tutorial/labs/add-shard.sql
   ```

   ```text
   ┌─step───────┬─shard─┬─spans─┐
   │ two shards │     1 │  1512 │
   │ two shards │     2 │  1488 │
   ┌─step─────────┬─shard─┬─before─┬─after─┐
   │ three shards │     1 │   1512 │  1064 │
   │ three shards │     2 │   1488 │  1066 │
   │ three shards │     3 │      0 │  1070 │
   ┌─traces─┬─split_across_shards─┐
   │   2000 │                 136 │
   ```

   The numbers are the same on every run, because trace ids and hashes are
   fixed. Read them:

   - **Nothing moved.** Shard 3 has none of the `before` rows; shards 1 and
     2 still hold all 3000.
   - **New rows spread over three shards**, about a third each.
   - **136 traces are split.** Each of 200 old traces got one late span
     after the change; for 136 of them the new count picked a different
     shard than the old one. `SELECT count() FROM grow.spans WHERE TraceId
     = '7'` still returns all 4 spans, because the `Distributed` table asks
     every shard.

   Leave the `grow` database for the next step.

4. **What a read-only user sees.** Create an account the way you would for
   ClickStack, try it with only the `Distributed` table granted, then with
   both, then add a row policy on the local tables:

   ```bash
   ch()     { docker exec -i clickhouse-01 clickhouse-client --password demo --multiquery; }
   viewer() { docker exec clickhouse-01 clickhouse-client --user viewer --password view -q "$1"; }

   echo "CREATE USER viewer ON CLUSTER lab_3shards IDENTIFIED BY 'view' SETTINGS readonly = 2;
         GRANT ON CLUSTER lab_3shards SELECT ON grow.spans TO viewer;" | ch > /dev/null
   viewer "SELECT count() FROM grow.spans"

   echo "GRANT ON CLUSTER lab_3shards SELECT ON grow.spans_local TO viewer;" | ch > /dev/null
   viewer "SELECT count() FROM grow.spans SETTINGS max_execution_time = 5"
   viewer "INSERT INTO grow.spans VALUES ('x', 1, 'x')"

   echo "CREATE ROW POLICY early ON CLUSTER lab_3shards ON grow.spans_local
         FOR SELECT USING toUInt32(TraceId) < 500 TO viewer;" | ch > /dev/null
   viewer "SELECT count() FROM grow.spans"
   ```

   - The first count fails: "it's necessary to have the grant SELECT for at
     least one column on grow.spans_local". A query on a `Distributed`
     table reads the local tables, so it needs both grants.
   - With both, it returns `6200`, and the `max_execution_time` setting is
     allowed, because `readonly = 2` permits settings.
   - The insert fails on a missing INSERT grant.
   - With the row policy, the count drops to `1700` (traces 0 to 499: 1500
     spans, plus the 200 late spans). It was applied on all three shards:
     it was created `ON CLUSTER`, and `lab_3shards` has a `<secret>`
     (see `clickhouse/cluster.xml`), so the shards ran their part as
     `viewer`.

   Now the same local tables through a cluster **without** a secret.
   `lab_2shards` lists `<user>default</user>` for each replica:

   ```bash
   echo "CREATE TABLE grow.spans_no_secret ON CLUSTER lab_3shards AS grow.spans_local
         ENGINE = Distributed(lab_2shards, grow, spans_local, cityHash64(TraceId));
         GRANT ON CLUSTER lab_3shards SELECT ON grow.spans_no_secret TO viewer;" | ch > /dev/null
   viewer "SELECT shardNum() AS shard, count() FROM grow.spans_no_secret GROUP BY shard ORDER BY shard"
   ```

   ```text
   1	815
   2	2554
   ```

   Shard 1 is the server you queried, and it filtered. Shard 2 ran its
   part as `default`, which has no policy, and sent all 2554 of its rows
   (filtered, it has 817). On a real sharded cluster, put a `<secret>` in
   the cluster definition before you rely on row policies.

5. **Copy into a standalone server with `remote()`.** No shared Keeper, so
   replication can't help; pull the data instead. First create a
   non-replicated copy of the table on `clickhouse-solo`. The pipeline below
   prints the table's DDL from `clickhouse-01` (`TSVRaw` prints it without
   escaping), uses `sed` to replace the `ReplicatedMergeTree(...)` engine
   with a plain `MergeTree`, and runs the result on `clickhouse-solo`:

   ```bash
   docker exec clickhouse-solo clickhouse-client --password demo -q "CREATE DATABASE IF NOT EXISTS otel"
   docker exec clickhouse-01 clickhouse-client --password demo --format TSVRaw -q "SHOW CREATE TABLE otel.otel_traces" \
     | sed -E "s/ReplicatedMergeTree\(.*\)/MergeTree/" \
     | docker exec -i clickhouse-solo clickhouse-client --password demo --multiquery
   ```

   Then, in the solo server's Play UI at <http://localhost:8126/play>, make
   a first copy that pretends the newest turns' `agent_turn` spans hadn't
   arrived yet: it leaves out `agent_turn` spans from the last 5 minutes of
   turns.

   ```sql
   INSERT INTO otel.otel_traces
   SELECT * FROM remote('clickhouse-01', otel.otel_traces, 'default', 'demo')
   WHERE NOT (SpanName = 'agent_turn' AND Timestamp > (
     SELECT max(Timestamp) - INTERVAL 5 MINUTE
     FROM remote('clickhouse-01', otel.otel_traces, 'default', 'demo') WHERE SpanName = 'agent_turn'));
   ```

   This query counts the spans the source has and the target doesn't. Run it
   after each step below:

   ```sql
   SELECT count() AS missing
   FROM remote('clickhouse-01', otel.otel_traces, 'default', 'demo')
   WHERE (TraceId, SpanId) GLOBAL NOT IN (SELECT TraceId, SpanId FROM otel.otel_traces);
   ```

   A test run showed `11` missing: the held-back turns.

6. **The naive incremental copy misses them.** Count what the
   `max(Timestamp)` watermark would copy:

   ```sql
   SELECT count() FROM remote('clickhouse-01', otel.otel_traces, 'default', 'demo')
   WHERE Timestamp > (SELECT max(Timestamp) FROM otel.otel_traces);
   ```

   With traffic paused this shows `0` (with traffic running, only spans
   newer than the watermark). Either way, the 11 `agent_turn` spans aren't
   included: each started before its own children, which are already in
   the target, so they sit below the watermark. This copy would never
   fetch them.

7. **The overlapping copy gets them.** Run the overlap-and-deduplicate copy
   from the Idea section, then the `missing` query again, and then a check
   that both servers hold the same spans:

   ```sql
   INSERT INTO otel.otel_traces
   WITH (SELECT max(Timestamp) - INTERVAL 10 MINUTE FROM otel.otel_traces) AS since
   SELECT * FROM remote('clickhouse-01', otel.otel_traces, 'default', 'demo')
   WHERE Timestamp > since
     AND (TraceId, SpanId) GLOBAL NOT IN
         (SELECT TraceId, SpanId FROM otel.otel_traces WHERE Timestamp > since);

   -- Verify: same rows, same checksum, same recomputed columns
   SELECT count(), sum(cityHash64(SpanId)) % 1000000, sum(gen_ai_tokens_in) FROM otel.otel_traces;
   ```

   `missing` is now `0`. Run the verify query on
   <http://localhost:8123/play> too. In a test run, both returned
   `51702  964727  141539`. The token sum matching shows the MATERIALIZED
   columns were rebuilt on the solo server. Run the copy a second time: the
   count doesn't change, because every span in the window is already there.
   (If traffic is running, `clickhouse-01` may have a few more rows by the
   time you check; run the copy again first.)

   Try it once with `NOT IN` instead of `GLOBAL NOT IN`: it copies nothing,
   because the subquery then runs on `clickhouse-01` and finds every span
   there.

8. **The other direction: a single server into the replicated cluster.**
   Insert once on any replica, and replication copies it to the others.
   This creates a small `notes` table on the solo server, a replicated one
   on the cluster, pulls the rows across, and checks every replica has them:

   ```sql
   -- on clickhouse-solo
   CREATE TABLE otel.notes (id UInt32, note String) ENGINE = MergeTree ORDER BY id;
   INSERT INTO otel.notes SELECT number, concat('note ', toString(number)) FROM numbers(1000);

   -- on clickhouse-01
   CREATE TABLE otel.notes ON CLUSTER tracing (id UInt32, note String) ENGINE = ReplicatedMergeTree ORDER BY id;
   INSERT INTO otel.notes SELECT * FROM remote('clickhouse-solo', otel.notes, 'default', 'demo');
   SELECT hostName(), count() FROM clusterAllReplicas('tracing', otel.notes) GROUP BY 1;
   DROP TABLE otel.notes ON CLUSTER tracing SYNC;
   ```

   Every replica of `tracing` reports 1000 rows, though you inserted only
   on `clickhouse-01`. If a replica is missing from the result, it hasn't
   fetched the part yet; run the `SELECT` again a second later.
   `clickhouse-03` never appears, and has no `notes` table: as step 2
   showed, `ON CLUSTER tracing` and `clusterAllReplicas('tracing', ...)`
   only reach the servers in the `tracing` definition.

9. **Fetch a partition from another replicated table** (shared Keeper).
   This creates an empty replicated table with an explicit Keeper path,
   fetches one day of `otel_traces` into its detached folder, attaches it,
   counts it, and drops the table. Run it on `clickhouse-01`:

   ```sql
   CREATE TABLE otel.otel_traces_restore AS otel.otel_traces
   ENGINE = ReplicatedMergeTree('/clickhouse/tables/lab/otel_traces_restore', '{replica}')
   PARTITION BY toDate(Timestamp) ORDER BY (org_owner, org_service, SpanName, toDateTime(Timestamp));

   -- the source path comes from system.replicas
   ALTER TABLE otel.otel_traces_restore FETCH PARTITION ID '20261121'
     FROM '/clickhouse/tables/<otel_traces uuid>/01';
   ALTER TABLE otel.otel_traces_restore ATTACH PARTITION ID '20261121';
   SELECT count() FROM otel.otel_traces_restore;
   DROP TABLE otel.otel_traces_restore SYNC;
   ```

   Use your own partition id (`SELECT DISTINCT partition_id FROM system.parts
   WHERE table = 'otel_traces'`), and the real source path (`SELECT
   zookeeper_path FROM system.replicas WHERE table = 'otel_traces'`). The
   `01` at the end is the `{shard}`. The explicit path for the new table is
   needed because `{uuid}` only works with `ON CLUSTER` or an explicit UUID.
   The count matches that day's rows in `otel_traces`.

10. **Give a server a second disk.** On `clickhouse-solo`: create a table
    on the built-in `default` policy, "mount" a second disk (a folder
    standing in for a new volume), add it with
    `docs/tutorial/labs/storage-more-disks.xml`, and switch the table over:

    ```bash
    solo() { docker exec -i clickhouse-solo clickhouse-client --password demo --multiquery --format PrettyCompactMonoBlock; }

    solo <<'SQL'
    CREATE DATABASE IF NOT EXISTS disks;
    CREATE TABLE disks.events (day Date, n UInt64) ENGINE = MergeTree PARTITION BY day ORDER BY n;
    INSERT INTO disks.events SELECT toDate('2026-11-01') + number % 3, number FROM numbers(30000);
    SQL

    docker exec -u 0 clickhouse-solo sh -c 'mkdir -p /mnt/disk2 && chown clickhouse:clickhouse /mnt/disk2'
    docker cp docs/tutorial/labs/storage-more-disks.xml clickhouse-solo:/etc/clickhouse-server/config.d/

    solo <<'SQL'
    SYSTEM RELOAD CONFIG;
    SELECT name, path FROM system.disks;
    SELECT policy_name, volume_name, disks FROM system.storage_policies WHERE policy_name = 'grown';
    ALTER TABLE disks.events MODIFY SETTING storage_policy = 'grown';
    SYSTEM STOP MERGES disks.events;
    INSERT INTO disks.events SELECT toDate('2026-11-04'), number FROM numbers(1000);
    INSERT INTO disks.events SELECT toDate('2026-11-04'), number FROM numbers(1000);
    INSERT INTO disks.events SELECT toDate('2026-11-04'), number FROM numbers(1000);
    INSERT INTO disks.events SELECT toDate('2026-11-04'), number FROM numbers(1000);
    ALTER TABLE disks.events MOVE PARTITION '2026-11-01' TO DISK 'disk2';
    SELECT partition, groupArray(disk_name) AS disks FROM system.parts
    WHERE database = 'disks' AND active GROUP BY partition ORDER BY partition;
    SYSTEM START MERGES disks.events;
    SQL
    ```

    ```text
    ┌─name────┬─path─────────────────┐
    │ default │ /var/lib/clickhouse/ │
    │ disk2   │ /mnt/disk2/          │
    ┌─policy_name─┬─volume_name─┬─disks───────────────┐
    │ grown       │ default     │ ['default','disk2'] │
    ┌─partition──┬─disks─────────────────────────────────┐
    │ 2026-11-01 │ ['disk2']                             │
    │ 2026-11-02 │ ['default']                           │
    │ 2026-11-03 │ ['default']                           │
    │ 2026-11-04 │ ['default','disk2','default','disk2'] │
    ```

    - The disk and policy appeared without a restart.
    - The four new parts of `2026-11-04` alternate between the disks
      (round-robin; merges were stopped so you can see every part).
    - The old partitions stayed on `default` until `MOVE PARTITION` moved
      one.

    Now try to go back:

    ```bash
    echo "ALTER TABLE disks.events MODIFY SETTING storage_policy = 'default'" | solo
    ```

    It fails: "New storage policy `default` shall contain disks of the old
    storage policy `grown`". A policy switch is one-way, which is why the
    new policy has to contain the old one. Here `disk2` is a folder on the
    same file system, so it adds no real space (`SELECT name,
    formatReadableSize(free_space) FROM system.disks` shows both with
    almost the same free space, `disk2` 1 GiB less for its
    `keep_free_space_bytes`); on a server it would be a separate volume.

11. **Clean up.** First the shard lab's objects, on all three servers. Then
   unregister the extra replica from Keeper *before* removing its
   container. Otherwise the others keep a dead replica in their metadata,
   and you'd have to remove it with `SYSTEM DROP REPLICA 'clickhouse-03'
   FROM TABLE ...`:

   ```bash
   echo "DROP ROW POLICY IF EXISTS early ON grow.spans_local ON CLUSTER lab_3shards;
         DROP USER IF EXISTS viewer ON CLUSTER lab_3shards;
         DROP DATABASE IF EXISTS grow ON CLUSTER lab_3shards SYNC;" \
     | docker exec -i clickhouse-01 clickhouse-client --password demo --multiquery > /dev/null
   docker exec clickhouse-03 clickhouse-client --password demo -q "DROP DATABASE otel SYNC"
   docker compose -f compose.yaml -f docs/tutorial/labs/compose.replication.yaml rm -sfv clickhouse-03 clickhouse-solo
   ```

   Dropping a replicated table on one replica only removes **that replica**;
   the data stays on the others (`total_replicas` goes back to 2).

## Explain it back

> "To grow, I first find what's running out. Disk: I grow the volume, or add
> a disk with a new policy that contains the old one. CPU or memory: bigger
> servers, one replica at a time. Read load or safety: another replica per
> shard. Only if one server can't hold its share do I add a shard; nothing
> moves, new rows spread over the new count, a few in-flight traces split,
> and the shards even out as old data ages out. Every server must list the
> same shards in its cluster definition. Everything that reads, ClickStack
> included, goes through the `Distributed` tables, with readonly = 2
> accounts that have SELECT on both the `Distributed` and the local tables;
> views and row policies sit on the local tables."
>
> "To get spans into another ClickHouse, I first ask whether it shares our
> Keeper. If it does, I create the same table, with the same UUID and shard
> but a new replica name, and it fetches every part by itself; I can also
> `FETCH` and `ATTACH` single partitions. If it doesn't, I pull rows with
> `INSERT ... SELECT FROM remote()`. For an ongoing copy I don't trust
> `max(Timestamp)`, because spans arrive late: the agent turn is exported
> after its children and the gateway retries for up to five minutes. So each
> run re-reads a 10-minute overlap and skips spans already copied, using
> `GLOBAL NOT IN` so the check runs on the target. Alternatives are
> dual-write at the gateway, or `BACKUP` and `RESTORE` for snapshots."

## Recap

- Growth options: more disk and bigger servers move nothing; a replica
  copies its shard and adds reads and safety; a shard adds capacity, moves
  nothing, and is balanced only once old data ages out.
- Sharded data is a pair: `otel_traces_local` stores, `otel_traces`
  (`Distributed`) routes. Exporter and readers use the `Distributed` table;
  views fire on, and row policies filter, the local table.
- A node needs Keeper membership (what it stores) *and* a place in every
  server's cluster definition (who talks to it). Definitions reload
  without a restart.
- A new disk joins through a new storage policy with the same volumes and
  disks plus the new one; the switch is one-way.
- Same Keeper: add a replica (same path, new `{replica}`), or `FETCH` and
  `ATTACH` partitions. The new replica fetches all parts by itself.
- Different Keeper: `INSERT ... SELECT FROM remote()`, dual-write at the
  gateway, or `BACKUP`/`RESTORE`. `remote()` can also combine servers at
  query time, without copying.
- `Timestamp` is a span's start time, and spans arrive out of order. An
  incremental copy must overlap the last copy by more than the maximum
  lateness, and deduplicate (`GLOBAL NOT IN` on `(TraceId, SpanId)`, or a
  `ReplacingMergeTree` target).
- `SELECT *` leaves out MATERIALIZED columns; the target recomputes them.
  Views fire on direct inserts, not on fetched parts.
- Backups protect against bad deletes; replicas don't. Drop a replica's
  tables before removing the server, or use `SYSTEM DROP REPLICA`.

## Check yourself

<details><summary>Disks are filling up on every server of a 2 x 2 cluster; CPU is low. What's the cheapest fix?</summary>

Grow the disks in place (for example, modify the EBS volumes and run
`xfs_growfs`), or move older parts to S3 (module 11). Both move nothing.
Adding a shard would also add space, but only for new data, and it takes a
full TTL to even out.
</details>

<details><summary>After adding shard 3, a ClickStack trace view is complete but a script using <code>optimize_skip_unused_shards = 1</code> misses old traces. Why?</summary>

The script asks only the shard that `cityHash64(TraceId)` modulo the *new*
shard count points to. Traces written before the change sit on the shard
the old count picked. ClickStack queries the `Distributed` table without
that setting, so it asks every shard. Turn the setting off until data from
before the change has aged out.
</details>

<details><summary>A new read-only account for ClickStack gets "Not enough privileges" on <code>otel.otel_traces</code> although it has SELECT on it. What's missing?</summary>

SELECT on the local table `otel.otel_traces_local`: a query on a
`Distributed` table reads the local tables, and needs both grants. Give it
`readonly = 2` too, so the source's query settings are allowed.
</details>

<details><summary>You copied <code>otel_traces</code> with <code>SELECT *</code>. Are the <code>org_*</code> and <code>gen_ai_*</code> columns lost?</summary>

No. `SELECT *` leaves them out, and the target table recomputes them on
insert from its own definitions. If the target defines them differently,
the copy follows the target's definition.
</details>

<details><summary>Your hourly copy uses <code>WHERE Timestamp > (SELECT max(Timestamp) FROM target)</code>. A few <code>agent_turn</code> spans are missing in the target. Why?</summary>

`Timestamp` is the span's start time. The `agent_turn` span starts first but
is exported last, when the turn ends, and the gateway can retry a batch for
up to 300 seconds. If a copy ran after the children arrived but before the
turn's span did, the watermark was already past the turn's start time, so
no later run looks at it. Re-read an overlapping window and skip spans you
already have.
</details>

<details><summary>Why <code>GLOBAL NOT IN</code> and not <code>NOT IN</code> in the incremental copy?</summary>

The `WHERE` is sent to the remote server. A plain `NOT IN (subquery)` runs
its subquery there too, so it checks the source against itself and excludes
everything. `GLOBAL` runs the subquery on the target and sends the result.
</details>

<details><summary>You need the same spans in two regions with separate Keepers. Which approach?</summary>

Either dual-write at the gateway (two `clickhouse` exporters, one per
region), which costs nothing at query time, or a scheduled incremental
`remote()` copy. Replication needs a shared Keeper, and stretching one across
regions makes every insert depend on cross-region latency.
</details>

<details><summary>Mixing module 9: you add a replica to a cluster with two shards. Does it get all the data?</summary>

No, only its shard's. Its `{shard}` macro decides which Keeper path it
joins, so it becomes a copy of that one shard. Each shard needs its own
replicas.
</details>

## Next

You can now copy and grow the cluster, but every replica still keeps every
span on local disk until the 72-hour TTL drops it. [Module
11](11-s3-tiering.md) moves older parts to cheap object storage (S3)
automatically, so you can keep more data without buying bigger disks.

## Read more

- [Distributed table engine, including shard weights](https://clickhouse.com/docs/engines/table-engines/special/distributed)
- [Storage policies: disks and volumes](https://clickhouse.com/docs/engines/table-engines/mergetree-family/mergetree#table_engine-mergetree-multiple-volumes)
- [ClickStack source settings, including Known Columns List](https://clickhouse.com/docs/clickstack/managing/config)
- [Access control: users, row policies, quotas, settings profiles](https://clickhouse.com/docs/operations/access-rights)
- [AWS: extend the file system after resizing an EBS volume](https://docs.aws.amazon.com/ebs/latest/userguide/recognize-expanded-volume-linux.html)
- [Replication, including converting MergeTree to ReplicatedMergeTree](https://clickhouse.com/docs/engines/table-engines/mergetree-family/replication)
- [`remote` and `remoteSecure`](https://clickhouse.com/docs/sql-reference/table-functions/remote)
- [`IN` and `GLOBAL IN`](https://clickhouse.com/docs/sql-reference/operators/in)
- [Refreshable materialized views](https://clickhouse.com/docs/materialized-view/refreshable-materialized-view)
- [Manipulating partitions: FETCH, ATTACH, MOVE](https://clickhouse.com/docs/sql-reference/statements/alter/partition)
- [Backup and restore](https://clickhouse.com/docs/operations/backup)
- [SYSTEM statements: DROP REPLICA, RESTORE REPLICA](https://clickhouse.com/docs/sql-reference/statements/system)

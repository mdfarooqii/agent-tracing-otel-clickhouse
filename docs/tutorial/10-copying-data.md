# Module 10: Adding a replica and copying data between ClickHouse servers (35 min)

## Why this matters

Sooner or later you need spans somewhere else: a new server to replace a
broken one, a copy for testing, a second region. ClickHouse has several ways
to do it, and picking the wrong one either doesn't work or quietly loses
rows. This module sorts them by one question, **do the two servers share a
Keeper?**, and runs each method in a lab, including an ongoing copy that
doesn't drop late spans.

**What you'll be able to do after this module:**

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

## Idea

### Same Keeper or not: pick the tool

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

### Adding a replica

A replicated table is identified in Keeper by its path. If a new server
creates a table that resolves to the **same path** (here: the same UUID and
`{shard}`), with a **new** `{replica}` name, it joins as one more replica.
Keeper's log lists every part, so the new replica downloads all of them from
its peers. You copy no data yourself.

The `{shard}` macro decides which shard the new server joins
([module 9](09-sharding-indexes.md)). In a sharded cluster, you add replicas
shard by shard: a new server with `<shard>02</shard>` becomes a copy of
shard 2 only. Adding a replica never adds storage capacity; adding a shard
does, but existing rows stay where they are (module 9).

### `remote()`: pull rows from any server

`remote('host', db.table, 'user', 'password')` reads a table on another
server over the normal ClickHouse port (9000). `INSERT INTO t SELECT * FROM
remote(...)` pulls every row across. `remoteSecure` does the same over TLS
(encrypted connections). The servers share nothing but a network and a
password.

`remote()` is also useful without copying anything. [Module
6](06-cross-environment.md) kept each environment's spans in its own
ClickHouse and combined them at query time:

```sql
SELECT * FROM otel.otel_traces WHERE TraceId = '...'
UNION ALL
SELECT * FROM remote('clickhouse.env-b.internal', otel.otel_traces, 'reader', '...') WHERE TraceId = '...';
```

That reads both halves of one trace in one query, and nothing is stored
twice.

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
- `docs/tutorial/labs/add-replica.sh`: copies each `otel` table's DDL, with
  its UUID, from `clickhouse-01` to `clickhouse-03`. Tables first, then the
  views that write into them.
- `otel-gateway-config.yaml`: `retry_on_failure`, which bounds how late a
  span can arrive.

## Lab (20 min)

Start the two extra servers (from the repo root). Passing two `-f` files
tells Docker Compose to combine them, so the lab file adds services to the
main stack:

```bash
docker compose -f compose.yaml -f docs/tutorial/labs/compose.replication.yaml up -d clickhouse-03 clickhouse-solo
```

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

   `3  3  0` means three replicas, all three active, and nothing left in the
   fetch queue, and the two counts match (yours will differ). The script did nothing but create empty tables with the
   same UUIDs. Keeper told `clickhouse-03` which parts exist, and it fetched
   them from its peers. New spans keep arriving on all three. Writes work in
   any direction: a row inserted on `clickhouse-03` shows up on
   `clickhouse-01`, including in `trace_entry`, via `clickhouse-03`'s own
   view.

2. **Copy into a standalone server with `remote()`.** No shared Keeper, so
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

3. **The naive incremental copy misses them.** Count what the
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

4. **The overlapping copy gets them.** Run the overlap-and-deduplicate copy
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

5. **The other direction: a single server into the replicated cluster.**
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

6. **Fetch a partition from another replicated table** (shared Keeper).
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

7. **Clean up.** Unregister the extra replica from Keeper *before* removing
   its container. Otherwise the others keep a dead replica in their
   metadata, and you'd have to remove it with `SYSTEM DROP REPLICA
   'clickhouse-03' FROM TABLE ...`:

   ```bash
   docker exec clickhouse-03 clickhouse-client --password demo -q "DROP DATABASE otel SYNC"
   docker compose -f compose.yaml -f docs/tutorial/labs/compose.replication.yaml rm -sfv clickhouse-03 clickhouse-solo
   ```

   Dropping a replicated table on one replica only removes **that replica**;
   the data stays on the others (`total_replicas` goes back to 2).

## Explain it back

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
- Materialized views fire on direct inserts, not on fetched parts; derived
  tables replicate on their own.
- Drop a replica's tables before removing the server, or clean up with
  `SYSTEM DROP REPLICA`.

## Check yourself

<details><summary>You copied <code>otel_traces</code> with <code>SELECT *</code>. Are the <code>org_*</code> and <code>gen_ai_*</code> columns lost?</summary>

No. `SELECT *` leaves them out, and the target table recomputes them on
insert from its own definitions. If the target defines them differently,
the copy follows the target's definition.
</details>

<details><summary>A new replica's materialized views didn't run for the parts it fetched. Is the derived data missing?</summary>

No. The derived tables are replicated themselves, so the new replica fetches
their parts too. Views only run on inserts the server receives directly.
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

<details><summary>You add a replica to a cluster with two shards. Does it get all the data?</summary>

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

- [Replication, including converting MergeTree to ReplicatedMergeTree](https://clickhouse.com/docs/engines/table-engines/mergetree-family/replication)
- [`remote` and `remoteSecure`](https://clickhouse.com/docs/sql-reference/table-functions/remote)
- [`IN` and `GLOBAL IN`](https://clickhouse.com/docs/sql-reference/operators/in)
- [Refreshable materialized views](https://clickhouse.com/docs/materialized-view/refreshable-materialized-view)
- [Manipulating partitions: FETCH, ATTACH, MOVE](https://clickhouse.com/docs/sql-reference/statements/alter/partition)
- [Backup and restore](https://clickhouse.com/docs/operations/backup)
- [SYSTEM statements: DROP REPLICA, RESTORE REPLICA](https://clickhouse.com/docs/sql-reference/statements/system)

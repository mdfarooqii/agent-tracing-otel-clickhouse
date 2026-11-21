# Module 11: Moving older data to S3 (30 min)

## Idea

Recent traces are queried all the time; last week's are rarely touched but
still need to be kept. **Tiered storage** keeps new data on fast local disk
and moves older data to cheap object storage (S3), while queries keep working
on both as if nothing moved.

ClickHouse builds this from three pieces of configuration:

| Piece | Where | What it says |
|---|---|---|
| **Disks** | Server config (`storage_configuration`) | Where bytes can live: the local disk, an S3 bucket, a local cache in front of S3 |
| **Storage policy** | Server config | An ordered list of **volumes** (groups of disks) a table may use, and when to spill between them |
| **Move rules** | Each table's `TTL` and `storage_policy` setting | *Which* data moves, and *when* |

```text
                 storage policy "tiered"
INSERT ─▶ volume "default" (local disk) ──TTL: older than N──▶ volume "cold" (S3, via a local cache)
                      │                                              ▲
                      └──── move_factor: local disk almost full ─────┘
                                                        TTL: older than M ─▶ DELETE
```

### Two kinds of trigger

1. **Age (TTL move).** In the table:

   ```sql
   TTL toDateTime(Timestamp) + INTERVAL 1 DAY  TO VOLUME 'cold',
       toDateTime(Timestamp) + INTERVAL 72 HOUR DELETE
   ```

   A background task moves a **part** once **all** its rows are past the
   threshold (the part's newest row decides: see `move_ttl_info.max` in
   `system.parts`). That's why **partitioning by day matters**: a finished
   day's parts stop changing and move as a unit. A part still receiving
   merges with today's data won't move until it's entirely old.

2. **Space (`move_factor`).** In the policy: `move_factor = 0.1` means that
   when the local volume has less than 10% free space, the largest parts move
   to the next volume. This is a safety valve, not a schedule.

You can also move by hand:
`ALTER TABLE t MOVE PARTITION '2026-11-14' TO VOLUME 'cold'` (or
`TO VOLUME 'default'` to bring it back).

### Things that work the way you'd hope

- **Queries don't change.** A query reads local and S3 parts together.
- **Inserts always go to the first volume** (local), so ingestion speed
  doesn't depend on S3.
- **A local cache** (`type cache` disk) keeps recently read S3 data on local
  disk, so repeated queries on cold data don't hit S3 again.
- **Credentials come from the environment** (`from_env`), or from an IAM role
  with `<use_environment_credentials>true</use_environment_credentials>`; no
  secrets in config files.

### Things to know before using it in production

- **Each replica writes its own copy to S3.** Two replicas means twice the S3
  storage, under separate prefixes (here `clickhouse-01/` and
  `clickhouse-02/`). "Zero-copy replication" shares one copy, but ClickHouse
  doesn't recommend it for production. ClickHouse Cloud's SharedMergeTree
  solves this differently.
- **Switching policy is one-way.** A table can only switch to a policy that
  keeps its current volumes, and once it uses a policy, **that policy and its
  S3 disk must stay in the server config**. Remove them, and the server can't
  load the table.
- **Changing an existing policy's volumes needs a server restart**;
  `SYSTEM RELOAD CONFIG` isn't enough.
- **The local volume must be called `default`** if existing tables are to
  switch to the new policy: their old policy (`default`) has a volume named
  `default`, and the new one must keep it.
- **S3 costs requests, not just bytes.** Merges of parts on S3 read and write
  S3. Small parts are worse there than locally.
- **The S3 disk is checked at startup**, so ClickHouse waits for S3 to be
  reachable. In compose, the ClickHouse services depend on the bucket being
  created.

## Remember it

> **Disks are shelves, the policy is the order of the shelves, and the TTL is
> the rule for when a box moves to the cheaper shelf in the back. Boxes are
> parts, and a box only moves when everything in it is old, so pack one box
> per day.**

## In this repo

All lab files, nothing in the default stack:

| File | What it does |
|---|---|
| `docs/tutorial/labs/storage-s3.xml` | Disks `s3` and `s3_cache`, policy `tiered` with volumes `default` (local) and `cold` (S3), `move_factor` 0.1 |
| `docs/tutorial/labs/compose.s3-tiering.yaml` | Adds SeaweedFS (a small S3-compatible server) on port 8333, creates the `traces` bucket, mounts the config into both replicas, and gives each replica its own S3 prefix |
| `docs/tutorial/labs/enable-s3-tiering.sh` | Switches the `otel` tables to `tiered` and sets move and delete TTLs; `MOVE_AFTER` and `DELETE_AFTER` are configurable |

The configuration knobs, all in one place:

| Knob | Where | Default here |
|---|---|---|
| S3 endpoint (bucket and prefix) | `S3_ENDPOINT_BASE` env var | `http://seaweedfs:8333/traces` |
| Credentials, region | `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY`, `S3_REGION` env vars | `demo`, `demo`, `us-east-1` |
| Move to S3 after | `MOVE_AFTER` for the script, or the table's `TTL ... TO VOLUME 'cold'` | `1 DAY` |
| Delete after | `DELETE_AFTER`, or `TTL ... DELETE` | `72 HOUR` (`span_red_1m`: 1 year) |
| Move when the local disk is full | `move_factor` in `storage-s3.xml` | `0.1` (less than 10% free) |
| Local cache size for S3 reads | `max_size` of `s3_cache` | `1Gi` |

## Lab (20 min)

1. **Turn it on, and keep it on.** Compose reads `COMPOSE_FILE` from `.env`,
   so adding this line makes every `docker compose` and `./stack.sh` command
   include the S3 override from now on:

   ```bash
   echo 'COMPOSE_FILE=compose.yaml:docs/tutorial/labs/compose.s3-tiering.yaml' >> .env
   ./stack.sh up
   ```

   This recreates both ClickHouse containers with the new config (data is
   kept). Check that the disks and policy are there:

   ```sql
   SELECT name, type, path FROM system.disks;
   SELECT policy_name, volume_name, disks, move_factor FROM system.storage_policies;
   ```

   ```text
   default   Local          /var/lib/clickhouse/
   s3        ObjectStorage  /var/lib/clickhouse/disks/s3/
   s3_cache  ObjectStorage  /var/lib/clickhouse/disks/s3/
   default   default  ['default']  0
   tiered    default  ['default']  0.1
   tiered    cold     ['s3']       0.1
   ```

2. **Apply the policy and TTL to the trace tables.** A short threshold, so
   you can watch it happen today:

   ```bash
   MOVE_AFTER='10 MINUTE' docs/tutorial/labs/enable-s3-tiering.sh
   ```

   Then look at where the parts are, and when each one becomes eligible:

   ```sql
   SELECT table, disk_name, count() AS parts, sum(rows) AS rows
   FROM system.parts WHERE database = 'otel' AND active GROUP BY table, disk_name ORDER BY table;

   SELECT name, rows, move_ttl_info.max FROM system.parts
   WHERE table = 'otel_traces' AND active ORDER BY rows DESC LIMIT 3;
   ```

   Probably nothing has moved yet. The big merged part covers today from the
   first span until a minute ago, so its `move_ttl_info.max` is still in the
   future. That's the "a part moves when all its rows are old" rule. In
   production, with `MOVE_AFTER = '1 DAY'`, yesterday's partition moves as a
   whole.

3. **Watch age-based moves on backdated data.** Make a table with seven days
   of rows, and a 1-day move rule:

   ```sql
   CREATE DATABASE IF NOT EXISTS lab ON CLUSTER tracing;

   CREATE TABLE lab.tiering_demo ON CLUSTER tracing
   (ts DateTime, service LowCardinality(String), duration_ms UInt32)
   ENGINE = ReplicatedMergeTree
   PARTITION BY toDate(ts) ORDER BY (service, ts)
   TTL ts + INTERVAL 1 DAY TO VOLUME 'cold',
       ts + INTERVAL 30 DAY DELETE
   SETTINGS storage_policy = 'tiered';

   INSERT INTO lab.tiering_demo
   SELECT now() - toIntervalSecond(number * 60),
          ['support-agent', 'hr-agent', 'sales-agent'][number % 3 + 1],
          rand() % 2000
   FROM numbers(7 * 24 * 60);
   ```

   Wait about 10 seconds, then:

   ```sql
   SELECT partition, disk_name, sum(rows) AS rows FROM system.parts
   WHERE database = 'lab' AND table = 'tiering_demo' AND active
   GROUP BY partition, disk_name ORDER BY partition;
   ```

   ```text
   2026-11-14  s3       1154
   2026-11-15  s3       1440
   ...
   2026-11-19  s3       1440
   2026-11-20  default  1440      yesterday: its last rows are less than 1 day old
   2026-11-21  default   286      today
   ```

   Every day whose newest row is more than a day old moved to S3. Run the same
   query against `clickhouse-02` (port 8124): it moved its own copy too.

4. **See the objects in S3**, one prefix per replica:

   ```bash
   echo "fs.ls /buckets/traces" | docker exec -i seaweedfs weed shell -master=localhost:9333
   echo "fs.du /buckets/traces/clickhouse-01" | docker exec -i seaweedfs weed shell -master=localhost:9333
   ```

5. **Query cold data, and see the cache work.** Run this twice:

   ```sql
   SYSTEM DROP FILESYSTEM CACHE;   -- before the first run only

   SELECT service, count(), round(avg(duration_ms))
   FROM lab.tiering_demo WHERE ts < now() - INTERVAL 2 DAY GROUP BY service;

   SYSTEM FLUSH LOGS;
   SELECT query_duration_ms,
          ProfileEvents['ReadBufferFromS3Bytes'] AS from_s3,
          ProfileEvents['CachedReadBufferReadFromCacheBytes'] AS from_cache
   FROM system.query_log
   WHERE type = 'QueryFinish' AND query LIKE 'SELECT service, count()%tiering_demo%'
   ORDER BY event_time_microseconds DESC LIMIT 2;
   ```

   In a test run, the first query read about 63 KB from S3; the second read
   0 bytes from S3 and everything from the local cache.

6. **Move by hand**, both ways:

   ```sql
   ALTER TABLE lab.tiering_demo MOVE PARTITION '2026-11-20' TO VOLUME 'cold';
   ALTER TABLE lab.tiering_demo MOVE PARTITION '2026-11-14' TO VOLUME 'default';
   ```

   Use your own dates. The TTL rule will move the second one back to S3 in
   the background, since it's still older than a day.

7. **Clean up the lab table** (this deletes its S3 objects too):

   ```sql
   DROP DATABASE lab ON CLUSTER tracing SYNC;
   ```

### Using real S3

Only the endpoint and credentials change. Set them before `./stack.sh up`, in
`.env` or the shell:

```bash
S3_ENDPOINT_BASE=https://my-bucket.s3.us-east-1.amazonaws.com/agent-tracing
S3_REGION=us-east-1
S3_ACCESS_KEY_ID=...          # or use an IAM role: see below
S3_SECRET_ACCESS_KEY=...
```

Then remove the `seaweedfs` and `seaweedfs-init` services (and the
`depends_on` on them) from your copy of `compose.s3-tiering.yaml`. On AWS,
with an instance or pod role, replace the two key elements in
`storage-s3.xml` with `<use_environment_credentials>true</use_environment_credentials>`.

### Turning it off

Because of the one-way policy rule, there's no "undo" that keeps the data in
place. Your choices:

- **Keep the policy but stop moving data**: remove the `TO VOLUME 'cold'` rule
  (`ALTER TABLE ... MODIFY TTL toDateTime(Timestamp) + INTERVAL 72 HOUR DELETE`)
  and move parts back with `MOVE PARTITION ... TO VOLUME 'default'`. Keep the
  `COMPOSE_FILE` line, since the config must stay.
- **Start over**: `./stack.sh down --wipe` (with `COMPOSE_FILE` still set, so
  the S3 volume is removed too), then delete the `COMPOSE_FILE` line from
  `.env`, then `./stack.sh up`.

## Explain it back

> "ClickHouse tiers storage with disks, storage policies and TTL rules. The
> server config defines a local disk and an S3 disk with a local cache, and a
> policy `tiered` whose first volume is local and second is S3. Inserts always
> land locally. A table TTL like `+ INTERVAL 1 DAY TO VOLUME 'cold'` moves each
> part to S3 once its newest row is a day old, which is why we partition by
> day, and `move_factor` also moves parts when the local disk is nearly full.
> Queries read both tiers transparently, and the cache keeps hot S3 data local.
> Each replica writes its own copy to S3, and once a table uses a policy, the
> policy must stay in the config."

## Check yourself

<details><summary>You set <code>TTL ... + INTERVAL 1 HOUR TO VOLUME 'cold'</code>, but nothing moves for hours. Why?</summary>

A part moves only when all its rows are past the threshold. With daily
partitions, today's parts keep merging new rows in, so their newest row is
always recent. Check `move_ttl_info.max` in `system.parts`. Either accept
day-level granularity, or partition more finely, which means more parts.
</details>

<details><summary>Does moving data to S3 slow down ingestion?</summary>

No. Inserts always write to the first volume (local disk). Moves happen in
the background. Only queries and merges that touch S3 parts pay S3 latency,
and the cache softens repeated reads.
</details>

<details><summary>With two replicas and S3 tiering, how many copies of an old part are in S3?</summary>

Two, one per replica, under separate prefixes. Each replica owns its S3 data.
Plan S3 cost for it, or look at architectures where replicas share storage.
</details>

<details><summary>Someone removes <code>storage-s3.xml</code> to "turn off S3". What happens?</summary>

Tables whose `storage_policy` is `tiered` refer to a policy that no longer
exists, so the server can't load them. The policy has to stay; stop moves
with the TTL instead, or rebuild the tables.
</details>

## Read more

- [Storing data on external disks, including S3 and the local cache](https://clickhouse.com/docs/operations/storing-data)
- [Using multiple block devices: volumes, policies, move_factor](https://clickhouse.com/docs/engines/table-engines/mergetree-family/mergetree#table_engine-mergetree-multiple-volumes)
- [TTL for moving and deleting data](https://clickhouse.com/docs/guides/developer/ttl)
- [Separation of storage and compute](https://clickhouse.com/docs/guides/separation-storage-compute)
- [Integrating S3 with ClickHouse](https://clickhouse.com/docs/integrations/s3)
- [`ALTER ... MOVE PARTITION`](https://clickhouse.com/docs/sql-reference/statements/alter/partition)
- [SeaweedFS](https://github.com/seaweedfs/seaweedfs)

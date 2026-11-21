# Module 11: Moving older data to S3 (40 min)

## Why this matters

Traces pile up fast. Today's traces are queried all the time, while last
week's are rarely opened but still need to be kept. Keeping all of it on fast
local disks gets expensive, and those disks fill up. This module shows how
ClickHouse can move older data, automatically, to cheap object storage (S3)
while your queries keep working exactly as before.

**What you'll be able to do:**

- Explain what object storage and S3 are, and why "hot" and "cold" data
  belong in different places.
- Read a ClickHouse storage configuration: disks, volumes, storage policies,
  and the S3 read cache.
- Write TTL rules that move data to S3 after a time and delete it later.
- Run the lab with a local S3 stand-in (SeaweedFS), and know what changes for
  real AWS S3.

## Key terms

| Term | Plain meaning |
|---|---|
| **Object storage** | A storage service where you save whole files ("objects") under a name and read them back over HTTP. No folders to mount, no disk to manage; you pay per gigabyte stored and per request. |
| **S3** | Amazon's object storage service. Its HTTP API became a de facto standard, so many other products speak it too ("S3-compatible"). |
| **Bucket** | A named container for objects in S3, like a top-level drive. This lab uses a bucket called `traces`. |
| **Prefix** | The start of an object's name, used like a folder path (`clickhouse-01/...`). |
| **SeaweedFS** | A small open-source storage server that speaks the S3 API. Here it plays the role of S3 on your laptop. |
| **Hot / cold data** | Hot data is recent and queried often; cold data is older and rarely read. |
| **Tiered storage** | Keeping hot data on fast, expensive storage and cold data on slow, cheap storage, and moving data between them automatically. |
| **Part** | A chunk of a ClickHouse table on disk: a folder of files holding a batch of rows. Every insert creates a part ([module 6](06-clickhouse.md)). |
| **Merge** | ClickHouse combines small parts into bigger ones in the background. |
| **Partition** | A group of parts that share a key, here one calendar day (`PARTITION BY toDate(Timestamp)`). Parts in different partitions are never merged together. |
| **Disk** | In ClickHouse config, one named place bytes can live: the local filesystem, an S3 bucket, or a cache in front of S3. |
| **Volume** | A named, ordered group of one or more disks, used as one tier. |
| **Storage policy** | An ordered list of volumes a table may use, plus the rules for spilling from one to the next. |
| **TTL** | "Time to live": a rule on a table saying what to do with rows once they reach a certain age. Either move them (`TO VOLUME`) or delete them (`DELETE`). |
| **`move_factor`** | A policy setting: when a volume's free space drops below this fraction, ClickHouse starts moving parts to the next volume. |
| **Cache disk** | A ClickHouse disk type that keeps a local copy of recently read S3 data, so repeated reads skip S3. |
| **Replica** | One of the two ClickHouse servers (`clickhouse-01`, `clickhouse-02`) that each hold a full copy of the data ([module 6](06-clickhouse.md)). |

## Idea

### First: what is object storage, and why use it?

Your laptop's disk is **block storage**: the operating system can read or
change any byte of any file, very fast. Servers in the cloud use the same kind
of disk (SSDs attached to the machine). It's fast, but you pay for the full
size of the disk whether you use it or not, and it's tied to one machine.

**Object storage** works differently. You upload a whole file under a name,
like `traces/clickhouse-01/abc/data.bin`, and later download it by that name,
all over HTTP. You can't edit a few bytes in the middle; you replace the whole
object. In return:

- It's much cheaper per gigabyte than SSDs.
- It's practically unlimited: you never "run out of disk".
- You pay only for what you store, plus a small fee per request.
- It's slower: every read is an HTTP request over the network.

**S3** (Amazon Simple Storage Service) is the best-known object store. Its API
is so widely copied that "S3-compatible" servers exist everywhere, including
SeaweedFS, which this lab runs on your laptop.

Analogy: local disk is your desk drawer, quick to reach but small. Object
storage is a cheap storage unit across town: huge, but each trip takes a
while.

### Why tiered storage?

Look at how traces are used. When something breaks, people search the last
few hours. Data from last week is opened only now and then, for a
postmortem or a trend chart. So:

- Recent data (**hot**) needs speed: keep it on local disk.
- Older data (**cold**) needs to be cheap and kept: put it on S3.

**Tiered storage** does this automatically. New data lands locally; as it
ages, ClickHouse moves it to S3. Queries don't change: ClickHouse reads local
and S3 parts together and returns one answer.

Without it, your choices are worse: buy ever-bigger disks, or delete data
sooner than you'd like.

### How ClickHouse builds it: three pieces

ClickHouse puts tiered storage together from three pieces of configuration.
Think of a warehouse:

| Piece | Warehouse analogy | Where it's set | What it says |
|---|---|---|---|
| **Disks** | Shelves | Server config (`storage_configuration`) | Where bytes can live: the local disk, an S3 bucket, a local cache in front of S3 |
| **Storage policy** (made of **volumes**) | The order of the shelves, front to back | Server config | An ordered list of volumes (groups of disks) a table may use, and when to spill from one to the next |
| **Move rules** | The rule for when a box goes to the back | Each table's `TTL` and `storage_policy` setting | *Which* data moves, and *when* |

Here's the whole flow for this repo's `tiered` policy:

```text
                 storage policy "tiered"
INSERT ─▶ volume "default" (local disk) ──TTL: older than N──▶ volume "cold" (S3, via a local cache)
                      │                                              ▲
                      └──── move_factor: local disk almost full ─────┘
                                                        TTL: older than M ─▶ DELETE
```

Read it left to right: inserts always land on the first volume (local disk).
Parts move to the `cold` volume (S3) when they get old enough, or early if the
local disk is almost full. Later, a delete rule removes them entirely.

### Disks, one at a time

The lab defines two new disks next to the built-in `default` disk:

- **`default`**: the local filesystem (`/var/lib/clickhouse/`). Always exists.
- **`s3`**: a bucket and prefix in S3. ClickHouse stores the real data as
  objects in S3, and keeps only small **metadata** files on the local disk
  that record which S3 objects make up each file.
- **`s3_cache`**: a **cache** disk wrapped around `s3`. When ClickHouse reads
  from S3, it keeps a copy on local disk (up to a size limit). The next read of
  the same data comes from the cache instead of S3.

### Volumes and the storage policy

A **volume** is a tier: one or more disks treated as one place. A **storage
policy** lists volumes in order. The `tiered` policy has two:

1. `default`, containing the local disk.
2. `cold`, containing `s3_cache` (which in turn reads and writes `s3`).

A table opts in with `SETTINGS storage_policy = 'tiered'`. Tables that don't
set it use a built-in policy also called `default`, which has one volume,
also called `default`, holding the local disk.

### Two kinds of trigger

What actually makes data move?

1. **Age (TTL move).** A table's TTL clause says "when a row is this old, move
   it to that volume" and, separately, "when it's this old, delete it":

   ```sql
   TTL toDateTime(Timestamp) + INTERVAL 1 DAY  TO VOLUME 'cold',
       toDateTime(Timestamp) + INTERVAL 72 HOUR DELETE
   ```

   Line by line: rows whose `Timestamp` is more than 1 day old go to the
   `cold` volume; rows more than 72 hours old are deleted.

   ClickHouse doesn't move single rows; it moves whole **parts**. A
   background task moves a part once **all** its rows are past the threshold.
   In other words, the part's newest row decides; you can see that time in
   `move_ttl_info.max` in `system.parts`. That's why **partitioning by day
   matters**: once a day is over, that day's parts stop receiving new rows and
   move together. A part that's still merging with today's data won't move
   until it's entirely old.

2. **Space (`move_factor`).** Set in the policy. `move_factor = 0.1` means
   that when the local volume has less than 10% free space, ClickHouse moves
   parts (largest first) to the next volume until enough space is free. This
   is a safety valve so the disk never fills, not a schedule.

### TTL moves versus TTL deletes

Both are TTL rules, but they behave differently:

| | `TO VOLUME 'cold'` (move) | `DELETE` |
|---|---|---|
| What happens | Part is copied to S3, then removed locally | Rows are gone for good |
| Data still queryable? | Yes, from S3 | No |
| When it runs | A background move task | During background merges. With this repo's `ttl_only_drop_parts = 1` setting, ClickHouse drops a whole part only once every row in it has expired, which is cheap |

Deletes can lag behind the exact deadline, because they wait for background
work; don't rely on the exact minute.

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
  (an AWS identity attached to the machine or pod) with
  `<use_environment_credentials>true</use_environment_credentials>`; no
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
  S3. Many small parts are worse there than locally.
- **The S3 disk is checked at startup**, so ClickHouse waits for S3 to be
  reachable. In compose, the ClickHouse services depend on the bucket being
  created.

## Remember it

> **Disks are shelves, the policy is the order of the shelves, and the TTL is
> the rule for when a box moves to the cheaper shelf in the back. Boxes are
> parts, and a box only moves when everything in it is old, so pack one box
> per day.**

## In this repo

The default stack keeps everything on local disk. Tiering is a lab add-on,
made of three files:

| File | What it does |
|---|---|
| `docs/tutorial/labs/storage-s3.xml` | Disks `s3` and `s3_cache`, policy `tiered` with volumes `default` (local) and `cold` (S3), `move_factor` 0.1 |
| `docs/tutorial/labs/compose.s3-tiering.yaml` | Adds SeaweedFS (a small S3-compatible server) on port 8333, creates the `traces` bucket, mounts the config into both replicas, and gives each replica its own S3 prefix |
| `docs/tutorial/labs/enable-s3-tiering.sh` | Switches the `otel` tables to `tiered` and sets move and delete TTLs; `MOVE_AFTER` and `DELETE_AFTER` are configurable |

### Walkthrough: `storage-s3.xml`

ClickHouse reads its main config file, then merges in every XML file found in
`/etc/clickhouse-server/config.d/`. The compose override mounts this file
there in both replicas, so it adds to the config instead of replacing it.

```xml
<clickhouse>
    <storage_configuration>
        <disks>
            <s3>                                   <!-- a disk named "s3" -->
                <type>s3</type>                    <!-- stored in an S3 bucket -->
                <endpoint from_env="S3_ENDPOINT"/> <!-- bucket URL + prefix, read from an env var -->
                <access_key_id from_env="S3_ACCESS_KEY_ID"/>
                <secret_access_key from_env="S3_SECRET_ACCESS_KEY"/>
                <region from_env="S3_REGION"/>
                <metadata_path>/var/lib/clickhouse/disks/s3/</metadata_path>
                                                   <!-- local folder for the small files
                                                        that point at S3 objects -->
            </s3>
            <s3_cache>                             <!-- a disk named "s3_cache" -->
                <type>cache</type>                 <!-- a read cache... -->
                <disk>s3</disk>                    <!-- ...in front of the "s3" disk -->
                <path>/var/lib/clickhouse/disks/s3_cache/</path> <!-- where cached bytes live -->
                <max_size>1Gi</max_size>           <!-- cache at most 1 GiB locally -->
            </s3_cache>
        </disks>
        <policies>
            <tiered>                               <!-- a storage policy named "tiered" -->
                <volumes>
                    <default>                      <!-- 1st volume (hot); must be called "default" -->
                        <disk>default</disk>       <!-- the local disk -->
                    </default>
                    <cold>                         <!-- 2nd volume (cold) -->
                        <disk>s3_cache</disk>      <!-- S3, read through the cache -->
                    </cold>
                </volumes>
                <move_factor>0.1</move_factor>     <!-- spill to "cold" when local free space < 10% -->
            </tiered>
        </policies>
    </storage_configuration>
</clickhouse>
```

(The real file also has explanatory comments; this version shows only the
settings, annotated.)

What to notice:

- `from_env="..."` means "read this value from that environment variable when
  the server starts". No secrets are written into the file, and the same file
  works for SeaweedFS and for real S3.
- Volumes are tried in order: new parts always go to the first one.
- The `cold` volume uses `s3_cache`, not `s3` directly, so reads go through
  the cache. In `system.storage_policies` the volume is listed as `['s3']`
  (you'll see this in lab step 1); the cache is still in use, as lab step 5
  shows.

### How each replica gets its own prefix

`compose.s3-tiering.yaml` sets the `S3_ENDPOINT` environment variable
differently for each replica:

```text
clickhouse-01:  S3_ENDPOINT = ${S3_ENDPOINT_BASE}/clickhouse-01/
clickhouse-02:  S3_ENDPOINT = ${S3_ENDPOINT_BASE}/clickhouse-02/
                S3_ENDPOINT_BASE defaults to http://seaweedfs:8333/traces
```

So both replicas share one bucket (`traces`) but write under different
prefixes, and never touch each other's objects. The same file also adds two
services: `seaweedfs` (the S3 server) and `seaweedfs-init` (a one-off
container that creates the `traces` bucket). Both ClickHouse services wait for
`seaweedfs-init` to finish before starting, because the S3 disk must be
reachable at startup.

### Walkthrough: `enable-s3-tiering.sh`

The script runs a few `ALTER TABLE` statements through `clickhouse-client` in
the `clickhouse-01` container. `ON CLUSTER tracing` makes each statement run on
every server in the cluster, so both replicas get the change.

```bash
MOVE_AFTER=${MOVE_AFTER:-1 DAY}          # how old before moving to S3 (default 1 day)
DELETE_AFTER=${DELETE_AFTER:-72 HOUR}    # how old before deleting (default 72 hours)
```

Both values are ClickHouse interval expressions, like `10 MINUTE` or `2 DAY`.

**Step 1: switch the tables to the `tiered` policy.**

```bash
for table in otel_traces otel_traces_trace_id_ts trace_entry; do
  ch "ALTER TABLE otel.$table ON CLUSTER tracing MODIFY SETTING storage_policy = 'tiered'"
done
ch "ALTER TABLE otel.span_red_1m ON CLUSTER tracing MODIFY SETTING storage_policy = 'tiered'"
```

This covers every table in the `otel` database ([module 10](10-data-model.md)):
the raw spans table, its trace-id lookup table, a one-row-per-request table
(`trace_entry`), and the per-minute rollup `span_red_1m`. This step works only because
`tiered` keeps a volume named `default` on the local disk, like the tables'
old policy.

**Step 2: replace each table's TTL with "move, then delete".**

```bash
ch "ALTER TABLE otel.otel_traces ON CLUSTER tracing MODIFY TTL
      toDateTime(Timestamp) + INTERVAL $MOVE_AFTER TO VOLUME 'cold',
      toDateTime(Timestamp) + INTERVAL $DELETE_AFTER DELETE"
```

`MODIFY TTL` replaces the table's whole TTL clause. Before, the schema had only
a 72-hour delete rule; now there's a move rule as well. The other two raw
tables get the same rule on their own time column (`Start`). `span_red_1m`
moves after `MOVE_AFTER` too, but keeps its one-year delete rule, since it's
small and meant for long-term trends.

### The configuration knobs, all in one place

| Knob | Where | Default here |
|---|---|---|
| S3 endpoint (bucket and prefix) | `S3_ENDPOINT_BASE` env var (each replica appends its own name) | `http://seaweedfs:8333/traces` |
| Credentials, region | `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY`, `S3_REGION` env vars | `demo`, `demo`, `us-east-1` |
| Move to S3 after | `MOVE_AFTER` for the script, or the table's `TTL ... TO VOLUME 'cold'` | `1 DAY` |
| Delete after | `DELETE_AFTER`, or `TTL ... DELETE` | `72 HOUR` (`span_red_1m`: 1 year) |
| Move when the local disk is full | `move_factor` in `storage-s3.xml` | `0.1` (less than 10% free) |
| Local cache size for S3 reads | `max_size` of `s3_cache` | `1Gi` |

## Lab (25 min)

1. **Turn it on, and keep it on.** Docker Compose reads a `COMPOSE_FILE`
   variable from the `.env` file in the repo root; it lists which compose
   files to combine. Adding this line makes every `docker compose` and
   `./stack.sh` command include the S3 override from now on:

   ```bash
   echo 'COMPOSE_FILE=compose.yaml:docs/tutorial/labs/compose.s3-tiering.yaml' >> .env
   ./stack.sh up
   ```

   This starts SeaweedFS, creates the bucket, and recreates both ClickHouse
   containers with the new config (your data is kept). Check that the disks
   and policy are there:

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

   The first three rows are the disks: the local one plus the two new ones.
   The last three are the policies: the built-in `default` (one volume; its
   `move_factor` is 0 because there's nowhere to move to) and the new `tiered`
   with its two volumes.

2. **Apply the policy and TTL to the trace tables.** Use a short threshold, so
   you can watch it happen today:

   ```bash
   MOVE_AFTER='10 MINUTE' docs/tutorial/labs/enable-s3-tiering.sh
   ```

   Then look at which disk each table's parts are on, and when each big part
   becomes eligible to move:

   ```sql
   SELECT table, disk_name, count() AS parts, sum(rows) AS rows
   FROM system.parts WHERE database = 'otel' AND active GROUP BY table, disk_name ORDER BY table;

   SELECT name, rows, move_ttl_info.max FROM system.parts
   WHERE table = 'otel_traces' AND active ORDER BY rows DESC LIMIT 3;
   ```

   (`active` filters out old parts that have been merged away and are waiting
   to be cleaned up.)

   Probably nothing has moved yet. The big merged part covers today from the
   first span until a minute ago, so its `move_ttl_info.max` (the time its
   newest row crosses the threshold) is still in the future. That's the "a
   part moves when all its rows are old" rule. In production, with
   `MOVE_AFTER = '1 DAY'`, yesterday's partition moves as a whole.

3. **Watch age-based moves on backdated data.** Make a small test table with
   seven days of rows, a 1-day move rule, and a 30-day delete rule. It's
   partitioned by day, like the real tables:

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

   The `INSERT` generates one row per minute going back seven days
   (`7 * 24 * 60` rows), cycling through three service names with random
   durations.

   Wait about 10 seconds, then see which disk each day ended up on:

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

   Every day whose newest row is more than a day old moved to S3. Yesterday
   stays local because its last rows (late last night) aren't a full day old
   yet. Your dates and row counts will differ. Run the same query against
   `clickhouse-02` (port 8124): it moved its own copy too.

4. **See the objects in S3**, one prefix per replica. `weed shell` is
   SeaweedFS's admin shell; `fs.ls` lists a folder and `fs.du` shows how much
   space it uses:

   ```bash
   echo "fs.ls /buckets/traces" | docker exec -i seaweedfs weed shell -master=localhost:9333
   echo "fs.du /buckets/traces/clickhouse-01" | docker exec -i seaweedfs weed shell -master=localhost:9333
   ```

   You should see the `clickhouse-01` and `clickhouse-02` prefixes. The object
   names inside are random-looking: ClickHouse maps them to part files through
   the local metadata, so you never read them directly.

5. **Query cold data, and see the cache work.** First empty the cache, then
   run a query that only touches old (S3) days, then check where its bytes
   came from. `system.query_log` records every finished query, and its
   `ProfileEvents` column holds counters such as bytes read from S3 and from
   the cache. Run the `SELECT service ...` query and the log query twice:

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

   (`SYSTEM FLUSH LOGS` writes pending log rows right away, so the query you
   just ran shows up.)

   In a test run, the first query read about 63 KB from S3; the second read
   0 bytes from S3 and everything from the local cache. That's the cache disk
   doing its job.

6. **Move by hand**, both ways:

   ```sql
   ALTER TABLE lab.tiering_demo MOVE PARTITION '2026-11-20' TO VOLUME 'cold';
   ALTER TABLE lab.tiering_demo MOVE PARTITION '2026-11-14' TO VOLUME 'default';
   ```

   Use your own dates from step 3. The first sends a day to S3 early. The
   second pulls one back to local disk, but the TTL rule will move it back to
   S3 in the background, since it's still older than a day.

7. **Clean up the lab table** (this deletes its S3 objects too):

   ```sql
   DROP DATABASE lab ON CLUSTER tracing SYNC;
   ```

   `SYNC` waits until the data is really removed instead of returning at once.

### Using real S3

Only the endpoint and credentials change; the XML stays the same. Set them
before `./stack.sh up`, in `.env` or the shell:

```bash
S3_ENDPOINT_BASE=https://my-bucket.s3.us-east-1.amazonaws.com/agent-tracing
S3_REGION=us-east-1
S3_ACCESS_KEY_ID=...          # or use an IAM role: see below
S3_SECRET_ACCESS_KEY=...
```

What each line means:

- `S3_ENDPOINT_BASE`: your bucket's URL (`my-bucket` in region `us-east-1`)
  plus a prefix (`agent-tracing`). Each replica appends its own name, so
  `clickhouse-01` writes under `agent-tracing/clickhouse-01/`.
- `S3_REGION`: the AWS region the bucket lives in.
- `S3_ACCESS_KEY_ID` / `S3_SECRET_ACCESS_KEY`: credentials of an AWS user
  allowed to list, read, write and delete objects under that prefix.

Then remove the `seaweedfs` and `seaweedfs-init` services (and the
`depends_on` on them) from your copy of `compose.s3-tiering.yaml`, since you
no longer need a local S3.

On AWS, if the machine or Kubernetes pod already has an IAM role with access
to the bucket, you don't need keys at all. Replace the two key elements
(`access_key_id` and `secret_access_key`) in `storage-s3.xml` with
`<use_environment_credentials>true</use_environment_credentials>`, and
ClickHouse picks up the role's credentials automatically.

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

## Recap

- Object storage (S3) is cheap, practically unlimited and slower; local disk
  is fast and limited. Tiered storage keeps hot data local and cold data on S3.
- ClickHouse builds tiers from **disks** (where bytes live), a **storage
  policy** (ordered **volumes**), and table **TTL** rules (when to move or
  delete).
- Inserts always land on the first volume. Parts move when *all* their rows
  are old, so daily partitions move one day at a time. `move_factor` moves
  parts early if the local disk is nearly full.
- A **cache disk** in front of S3 keeps recently read cold data local.
- Each replica writes its own S3 copy, and once a table uses a policy, that
  policy must stay in the server config.
- Locally, SeaweedFS stands in for S3; for real S3, change only the endpoint
  and credentials (or use an IAM role).

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

<details><summary>What's the difference between a disk, a volume and a storage policy?</summary>

A disk is one place bytes can live (local filesystem, S3, a cache over S3). A
volume is a group of disks used as one tier. A storage policy is the ordered
list of volumes a table uses, plus spill rules like `move_factor`.
</details>

<details><summary>What's the difference between <code>TTL ... TO VOLUME 'cold'</code> and <code>TTL ... DELETE</code>?</summary>

The first moves parts to the S3 volume, where they stay queryable. The second
removes the rows for good. A table can have both: move after a day, delete
after 72 hours.
</details>

<details><summary>With two replicas and S3 tiering, how many copies of an old part are in S3?</summary>

Two, one per replica, under separate prefixes. Each replica owns its S3 data.
Plan S3 cost for it, or look at architectures where replicas share storage.
</details>

<details><summary>What does the <code>s3_cache</code> disk buy you, and what happens when it's full?</summary>

Repeated queries on cold data read from local disk instead of S3, which is
faster and saves S3 requests. It's capped by `max_size` (1 GiB here); when
full, older cached data is evicted to make room, and the next read of that
data goes to S3 again.
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
- [What is Amazon S3?](https://docs.aws.amazon.com/AmazonS3/latest/userguide/Welcome.html)

# Module 11: Moving older data to S3 (45 min)

## Why this matters

Traces pile up fast. Today's traces are queried all the time, while older
ones are rarely opened but still need to be kept. Keeping all of it on fast
local disks gets expensive, and those disks fill up. This module shows how
ClickHouse can move older data, automatically, to cheap object storage (S3)
while your queries keep working exactly as before.

[Module 10](10-copying-data.md) showed how to copy data between servers and add
a replica. This module stays on the same two servers and asks a different
question: where on each server should older data live?

**What you'll be able to do:**

- Explain what object storage and S3 are, and why "hot" and "cold" data
  belong in different places.
- Read a ClickHouse storage configuration: disks, volumes, storage policies,
  and the S3 read cache.
- Write TTL rules that move data to S3 after a time and delete it later, and
  know when they actually run.
- Run the lab with a local S3 stand-in (SeaweedFS), know what changes for
  real AWS S3, and know what to watch once it's on.

## Key terms

| Term | Plain meaning |
|---|---|
| **Object storage (S3)** | A storage service where you save whole files ("objects") under a name and read them back over HTTP. S3 is Amazon's; its API became a de facto standard, so many other products are "S3-compatible". |
| **Bucket and prefix** | A bucket is a named container for objects, like a top-level drive (`traces` here). A prefix is the start of an object's name, used like a folder path (`clickhouse-01/...`). |
| **SeaweedFS** | A small open-source storage server that speaks the S3 API. Here it plays the role of S3 on your laptop. |
| **Tiered storage (hot / cold)** | Keeping recent, often-read data (hot) on fast, expensive storage and older, rarely-read data (cold) on slow, cheap storage, moving it between them automatically. |
| **Disk** | In ClickHouse config, one named place bytes can live: the local filesystem, an S3 bucket, or a cache in front of S3. |
| **Volume** | A named, ordered group of one or more disks, used as one tier. |
| **Storage policy** | An ordered list of volumes a table may use, plus the rules for spilling from one to the next. |
| **TTL move** | A TTL ("time to live") rule that moves rows to another volume once they reach an age (`TO VOLUME 'cold'`), instead of deleting them. |
| **`move_factor`** | A policy setting: when a volume's free space drops below this fraction, ClickHouse starts moving parts to the next volume. |
| **Cache disk** | A ClickHouse disk type that keeps a local copy of recently read S3 data, so repeated reads skip S3. |

> **Remember from [module 7](07-clickhouse.md):** every insert creates a
> **part** (one folder of rows); **merges** combine parts; parts in different
> **partitions** (here, days) never merge; each **replica** holds a full copy.
> The schema's 72-hour delete TTL is in [module 8](08-data-model.md).

## Idea

### First: what is object storage, and why use it?

Your laptop's disk is **block storage**: the operating system can read or
change any byte of any file, very fast. Cloud servers use the same kind (SSDs
attached to the machine): fast, but you pay for the full size whether you use
it or not, and it's tied to one machine.

**Object storage** works differently. You upload a whole file under a name,
like `traces/clickhouse-01/abc/data.bin`, and later download it by that name,
all over HTTP. You can't edit a few bytes in the middle; you replace the whole
object. In return:

- It's much cheaper per gigabyte than SSDs.
- It's practically unlimited: you never "run out of disk".
- You pay only for what you store, plus a small fee per request.
- It's slower: every read is an HTTP request over the network.

Analogy: local disk is your desk drawer, quick to reach but small. Object
storage is a cheap storage unit across town: huge, but each trip takes a
while.

### Why tiered storage?

Look at how traces are used. When something breaks, people search the last
few hours. Older data is opened only now and then, for a postmortem or a
trend chart. So:

- Recent data (**hot**) needs speed: keep it on local disk.
- Older data (**cold**) needs to be cheap and kept: put it on S3.

**Tiered storage** does this automatically. Live data lands locally; as it
ages, ClickHouse moves it to S3. Queries don't change: ClickHouse reads local
and S3 parts together and returns one answer. Without it, you buy ever-bigger
disks or delete data sooner than you'd like.

A word on the numbers. A production setup typically keeps days to a couple of
weeks on local disk and months on S3. This lab's defaults are much shorter:
move after **1 day**, delete after **72 hours**, so a part spends only about
**2 days** on S3. They're short so you can watch it happen on a laptop, not
because they're good production values.

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
   │                  │                                              ▲
   │                  └──── move_factor: local disk almost full ─────┘
   └──── rows already older than N (a backfill) ─────────────────────┘
                                                        TTL: older than M ─▶ DELETE
```

Read it left to right. Live spans are seconds old, so they land on the first
volume (local disk). Parts move to the `cold` volume (S3) when they get old
enough, or early if the local disk is almost full. Rows that are already old
when you insert them go straight to S3 (more on that below). Later, a delete
rule removes them entirely.

### The disks and volumes in this lab

Three disks:

- **`default`**: the local filesystem (`/var/lib/clickhouse/`). Always exists.
- **`s3`**: a bucket and prefix in S3. The real data lives there as objects;
  the local disk keeps only small **metadata** files that record which S3
  objects make up each part file.
- **`s3_cache`**: a **cache** disk wrapped around `s3`. Data read from S3 is
  kept on local disk (up to a size limit), so the next read skips S3.

The `tiered` policy puts them into two volumes, in order: `default` (the local
disk) and `cold` (`s3_cache`, which reads and writes `s3`). A table opts in
with `SETTINGS storage_policy = 'tiered'`. Tables that don't use the built-in
policy also called `default`: one volume, also called `default`, on the local
disk.

> **Quick check:** The `s3` disk "stores data in S3". Why does it still need a
> local `metadata_path`, and what would losing that folder mean?
>
> <details><summary>Answer</summary>
>
> S3 object names are random; the local metadata files are the only map from
> part files to objects. Lose them and the objects are still in S3 but
> ClickHouse can't find them. Those parts are lost on that replica, and you'd
> recover them from the other replica's copy.
> </details>

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
   matters**. Parts never merge across partitions, so once a day is over, no
   new rows can join that day's parts. Their newest row is fixed, and the
   whole day becomes eligible to move together. Today's partition is
   different: it keeps getting new parts, and merges fold them into bigger
   parts whose newest row is always recent, so today stays local.

2. **Space (`move_factor`).** Set in the policy. `move_factor = 0.1` means
   that when the local volume has less than 10% free space, ClickHouse moves
   parts (largest first) to the next volume until enough space is free. This
   is a safety valve so the disk never fills, not a schedule.

> **Quick check:** You set `TTL ... + INTERVAL 1 HOUR TO VOLUME 'cold'` on a
> table partitioned by day, but nothing moves for hours. Why?
>
> <details><summary>Answer</summary>
>
> A part moves only when its newest row is past the threshold. Today's parts
> keep merging with fresh rows, so their newest row is always recent
> (`move_ttl_info.max` in `system.parts` shows it). Accept day-level moves, or
> partition more finely and pay with more parts.
> </details>

### Move rules also apply at insert time

TTL moves aren't only a background job. When ClickHouse writes a new part,
whether from an insert, a merge, or a replica fetching a part from its peer,
it works out the part's TTL first. If the whole part is already past the move
threshold, it writes the part straight to the `cold` volume. Nothing is
written locally and moved later.

For live tracing traffic this changes nothing: new spans are seconds old, so
they always land on local disk, and ingestion never waits on S3. But if you
**backfill** old data (load last month's spans, or `INSERT ... SELECT` from
another server as in [module 10](10-copying-data.md)), those inserts write
directly to S3, at S3 speed and S3 request cost. Lab step 3 shows this: its
backdated rows end up on S3 the moment the insert finishes.

> **Quick check:** S3 is unreachable for an hour. Do live spans from the
> gateway still get stored? Does a backfill of last week's spans?
>
> <details><summary>Answer</summary>
>
> Live spans, yes: they are seconds old, so their parts are written locally.
> The backfill fails: its parts are already past the move age, so ClickHouse
> tries to write them straight to S3.
> </details>

### TTL moves versus TTL deletes

Both are TTL rules, but they run differently:

| | `TO VOLUME 'cold'` (move) | `DELETE` |
|---|---|---|
| What happens | Part is copied to S3, then removed locally | Rows are gone for good |
| Data still queryable? | Yes, from S3 | No |
| When it runs | At insert time, or later by a background move task | In a **TTL merge**: a background merge that rewrites or drops parts with expired rows. With this repo's `ttl_only_drop_parts = 1`, ClickHouse drops a whole part only once every row in it has expired, which is cheap |

Deletes can lag by **hours**. ClickHouse runs a TTL merge on a partition at most
once every `merge_with_ttl_timeout` seconds, which defaults to 14400 (4 hours).
So "delete after 72 hours" really means "deleted some time after 72 hours,
often within about 4 hours more". Don't build anything that relies on the
exact minute.

You can also move by hand:
`ALTER TABLE t MOVE PARTITION '2026-11-14' TO VOLUME 'cold'` (or
`TO VOLUME 'default'` to bring it back).

> **Quick check:** Your `DELETE` TTL is 72 hours, but 75-hour-old spans are
> still there. Is TTL broken?
>
> <details><summary>Answer</summary>
>
> Probably not. TTL merges run on a partition at most every 4 hours by
> default, and with `ttl_only_drop_parts = 1` a part goes only when every row
> in it has expired. Expect hours of lag.
> </details>

### Before you use it in production

These are the things that surprise people. Read them before turning tiering
on for a real cluster.

| Caveat | What it means for you |
|---|---|
| **Each replica writes its own copy to S3** | Two replicas means twice the S3 storage, under separate prefixes (here `clickhouse-01/` and `clickhouse-02/`). See the principal engineer's notes for the zero-copy alternative. |
| **Switching policy is one-way** | A table can only switch to a policy that keeps its current volumes, and once it uses a policy, **that policy and its S3 disk must stay in the server config**. Remove them, and the server can't load the table. |
| **The local volume must be called `default`** | Existing tables use the built-in `default` policy, whose volume is named `default`. The new policy must keep that volume for them to switch. |
| **`MODIFY TTL` rewrites existing data** | With the default `materialize_ttl_after_modify = 1`, `ALTER ... MODIFY TTL` starts a **mutation** (a background job that rewrites existing parts) to apply the new rule to every existing part. On a big table that's hours of disk and CPU work, plus S3 uploads. On large tables, run `SET materialize_ttl_after_modify = 0` in the same session first, then apply it later in a quiet period with `ALTER TABLE ... MATERIALIZE TTL IN PARTITION '...'`, one day at a time. |
| **Config changes: add yes, remove no** | ClickHouse reloads its config when the files change (or on `SYSTEM RELOAD CONFIG`), and in recent versions it picks up **new** disks and policies without a restart. Removing or renaming a disk or volume isn't applied until a restart, and isn't allowed at all while a table uses it. In this lab the question doesn't come up: adding the file means recreating the containers anyway. |
| **S3 must be reachable at startup** | When it starts, ClickHouse checks that it can write to and read from each S3 disk. If S3 is unreachable, the check fails and the server doesn't start; it doesn't wait. In compose, the ClickHouse services depend on the bucket being created, and `restart: unless-stopped` retries a failed start. |

S3 request costs, bucket lifecycle rules and S3 outages are in the
principal engineer's notes below.

### What to watch once it's on

Tiering adds one more thing that can fail quietly: if moves stall, the local
disk fills anyway. Four signals cover it:

| Signal | Where | What bad looks like | What to do |
|---|---|---|---|
| S3 request errors | `S3ReadRequestsErrors`, `S3WriteRequestsErrors` in `system.events` | Rising. Failed writes mean parts can't move; failed reads mean queries on old data fail | Check credentials, endpoint and bucket |
| Moves keeping up | `BackgroundMovePoolTask` in `system.metrics`; local disk free space | The local disk fills although data is old enough to move | Check S3 errors and the table's `TTL ... TO VOLUME` rule |
| Cache hit ratio | `CachedReadBufferReadFromCacheBytes` against `ReadBufferFromS3Bytes` (in `system.events`, or per query in `system.query_log`) | Repeated queries still read mostly from S3 | Make the cache bigger |
| Cost | Requests and bytes in the cloud bill | Request costs rising faster than data | Fewer, bigger parts on S3; move only settled partitions |

`./stack.sh health` ([module 12](12-operations.md)) adds an S3 line when an
`s3` disk exists. Like the other `system.events` checks, it counts errors
**since the server started**, so one failed request a day ago still shows
WARN. What matters is whether the count is growing; module 12 shows how to
read the rate.

## Remember it

> **Disks are shelves, the policy is the order of the shelves, and the TTL is
> the rule for when a box moves to the cheaper shelf in the back. Boxes are
> parts, and a box only moves when everything in it is old, so pack one box
> per day. A box that's already old when it arrives goes straight to the
> back.**

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
- Volumes are listed in order, hot first. A new part goes to the first volume
  unless its TTL already points further down the list.
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
`seaweedfs-init` to finish before starting, because the server won't start if
its S3 disk isn't reachable.

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

This covers every table in the `otel` database ([module 8](08-data-model.md)):
the raw spans table, its trace-id lookup table, a one-row-per-request table
(`trace_entry`), and the per-minute rollup `span_red_1m`. This step works only
because `tiered` keeps a volume named `default` on the local disk, like the
tables' old policy.

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

Each `MODIFY TTL` also starts a `MATERIALIZE TTL` mutation that applies the new
rule to every existing part (see the production table above). On the demo's
small tables it finishes in seconds; you can see it in `system.mutations`. On
a large production table, plan for it.

### The configuration knobs, all in one place

| Knob | Where | Default here |
|---|---|---|
| S3 endpoint (bucket and prefix) | `S3_ENDPOINT_BASE` env var (each replica appends its own name) | `http://seaweedfs:8333/traces` |
| Credentials, region | `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY`, `S3_REGION` env vars | `demo`, `demo`, `us-east-1` |
| Move to S3 after | `MOVE_AFTER` for the script, or the table's `TTL ... TO VOLUME 'cold'` | `1 DAY` |
| Delete after | `DELETE_AFTER`, or `TTL ... DELETE` | `72 HOUR` (`span_red_1m`: 1 year) |
| Move when the local disk is full | `move_factor` in `storage-s3.xml` | `0.1` (less than 10% free) |
| Local cache size for S3 reads | `max_size` of `s3_cache` | `1Gi` |

## Principal engineer's notes

**Touch points**
- ClickHouse to S3 is touch point 6 in [module 0's map](00-setup.md): the S3
  HTTP API, with bucket, per-replica prefix, region and credentials as the
  contract. The cloud team usually owns the bucket and its lifecycle rules;
  ClickHouse owns every object under its prefix. Rename either and the local
  metadata points at nothing.
- A part on S3 is local metadata plus remote objects. A disk snapshot of one
  half restores nothing; use `BACKUP` ([module 12](12-operations.md)).
- Prefer an IAM role (auto-refreshed) scoped to the prefix: list, get, put,
  delete, multipart upload. Env-var keys are read at startup, so rotating
  them means recreating the container.

**At scale**
- S3 bills per request. A wide part stores each column as its own files;
  `otel_traces` has 48 columns, so one part is roughly a hundred objects:
  about a hundred PUTs to move, and GETs per column, per part, to query.
  Many small parts multiply both, so move only settled, merged days. Merges
  on the cold volume re-download and re-upload; the volume setting
  `prefer_not_to_merge` turns them off.
- Each S3 GET waits tens of milliseconds for its first byte, against well
  under one for a local SSD. Cold queries take seconds; keep incident
  dashboards on the hot window.
- Size the cache to the cold working set (say, the week people reopen for
  postmortems). It sits on the local disk, competing with hot parts for the
  free space `move_factor` watches.

**Operational issues**
- *Regional S3 outage.* Queries on recent partitions keep working (pruning
  skips cold parts); queries over cold days fail, often after hanging on
  retries. Live inserts continue; backfills fail (insert-time moves); merges
  and TTL moves on S3 fail and retry. Stalled moves let the local disk fill;
  once it's full, inserts fail and the gateway queues ([module 4](04-collector.md)).
  Don't restart a server mid-outage: it won't start until S3 is back.
- *Lifecycle rules.* Never let S3 expire or archive (Glacier-type classes)
  objects ClickHouse still lists; queries and merges on those parts then fail
  with missing-object errors. Let ClickHouse's TTL delete. The safe rule is
  "abort incomplete multipart uploads after N days".
- *Orphaned objects.* Interrupted writes can leave objects no part uses.
  Compare the bucket size with `bytes_on_disk` of parts on the `s3` disk.
- Rates and alerting: [module 12](12-operations.md) and the [appendix](appendix-metrics-reference.md).

**Design trade-offs**
- *Per-replica copies vs zero-copy.* Zero-copy replication
  (`allow_remote_fs_zero_copy_replication`, off by default) shares one set of
  objects, with Keeper locks deciding who may delete them. Bugs there have
  lost data and leaked objects; ClickHouse doesn't recommend it for
  production. Paying twice for cold storage is cheaper than that risk.
  ClickHouse Cloud's SharedMergeTree is the supported way to share storage.
- *Tiering vs exporting.* Tiering keeps one table and one query surface. For
  archives almost never read, exporting old days to Parquet in S3 (read with
  the `s3()` table function) is cheaper and independent of server config.

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

   Today's data probably hasn't moved yet. The big merged part covers today
   from the first span until a minute ago, so its `move_ttl_info.max` (the
   time its newest row crosses the threshold) is still in the future. That's
   the "a part moves when all its rows are old" rule. In production, with
   `MOVE_AFTER = '1 DAY'`, yesterday's partition moves as a whole.

3. **Insert backdated data and see where it lands.** Make a small test table
   with seven days of rows, a 1-day move rule, and a 30-day delete rule. It's
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
   durations. ClickHouse splits it into one new part per day.

   Right away, without waiting, see which disk each day is on:

   ```sql
   SELECT partition, disk_name, sum(rows) AS rows FROM system.parts
   WHERE database = 'lab' AND table = 'tiering_demo' AND active
   GROUP BY partition, disk_name ORDER BY partition;
   ```

   ```text
   2026-11-14  s3        370
   2026-11-15  s3       1440
   ...
   2026-11-19  s3       1440
   2026-11-20  default  1440      yesterday: its last rows are less than 1 day old
   2026-11-21  default  1070      today
   ```

   Every day whose newest row is more than a day old is already on S3. No
   background move did that: ClickHouse saw that each of those new parts was
   entirely past the move TTL and wrote it straight to the `cold` volume. The
   part log, a system table that records every part created, moved or merged,
   confirms it:

   ```sql
   SYSTEM FLUSH LOGS;
   SELECT event_type, disk_name, count() FROM system.part_log
   WHERE database = 'lab' AND table = 'tiering_demo' GROUP BY ALL;
   ```

   You'll see `NewPart` rows on `s3` and on `default`, and no `MovePart`.
   (`SYSTEM FLUSH LOGS` writes pending log rows right away.) Yesterday stays
   local because its last rows (late last night) aren't a full day old yet;
   a background move will take it to S3 later. Your dates and row counts will
   differ. Run the same `system.parts` query against `clickhouse-02` (port
   8124): when it fetched the parts, it also wrote the old days straight to
   its own S3 prefix.

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

   In a test run, the first query read about 63 KB from S3; the second read
   0 bytes from S3 and everything from the local cache. That's the cache disk
   doing its job, and it's the "cache hit ratio" signal from the watch table
   above, measured for one query.

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
   DROP TABLE lab.tiering_demo ON CLUSTER tracing SYNC;
   ```

   `SYNC` waits until the data is really removed instead of returning at once.
   If nothing else uses the `lab` database, you can drop it too with
   `DROP DATABASE lab ON CLUSTER tracing SYNC`.

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

## Explain it back

> "ClickHouse tiers storage with disks, storage policies and TTL rules. The
> server config defines a local disk and an S3 disk with a local cache, and a
> policy `tiered` whose first volume is local and second is S3. A table TTL
> like `+ INTERVAL 1 DAY TO VOLUME 'cold'` moves each part to S3 once its
> newest row is a day old, which is why we partition by day: parts never merge
> across days, so a finished day moves as a whole. The rule is also checked
> when a part is written, so live spans land locally but backfilled old rows
> go straight to S3. `move_factor` moves parts early when the local disk is
> nearly full. Deletes happen in TTL merges, which can lag by hours. Queries
> read both tiers, and the cache keeps hot S3 data local. Each replica writes
> its own copy to S3, and once a table uses a policy, the policy must stay."

## Recap

- Object storage (S3) is cheap, practically unlimited and slower; local disk
  is fast and limited. Tiered storage keeps hot data local and cold data on S3.
- ClickHouse builds tiers from **disks** (where bytes live), a **storage
  policy** (ordered **volumes**), and table **TTL** rules (when to move or
  delete).
- Parts move when *all* their rows are old, so daily partitions move one day
  at a time. `move_factor` moves parts early if the local disk is nearly full.
- Move rules apply when a part is written too: live data lands locally, but a
  backfill of old rows goes straight to S3.
- TTL deletes run in TTL merges, at most every 4 hours per partition by
  default, so expiry can lag.
- A **cache disk** in front of S3 keeps recently read cold data local.
- Each replica writes its own S3 copy; `MODIFY TTL` starts a mutation over
  existing parts; once a table uses a policy, that policy must stay in the
  server config; and the server won't start if S3 is unreachable.
- Watch S3 errors (their growth, not their total), moves, the cache hit ratio
  and the bill.
- The lab's 1 day local / about 2 days on S3 are demo values; production keeps
  data much longer.

## Check yourself

<details><summary>During an S3 outage, an engineer looks up one trace by trace id from 20 minutes ago and it works; the same lookup for a trace from three days ago fails. Why? (mixes modules 9 and 11)</summary>

The trace-id lookup table points the query at the right time range
([module 9](09-sharding-indexes.md)), and the time filter prunes to the
matching day's partition. Twenty minutes ago is today, on local disk; three
days ago is on S3, which is unreachable. Pruning is why recent queries survive
an S3 outage.
</details>

<details><summary>A cloud admin adds a bucket rule "delete objects older than 30 days" to save money, while ClickHouse keeps <code>span_red_1m</code> for a year. What happens?</summary>

After 30 days S3 deletes objects that `span_red_1m` parts on the cold volume
still use. ClickHouse still lists those parts, so queries and merges touching
them fail with missing-object errors. Remove the rule and let ClickHouse's
TTL do the deleting.
</details>

<details><summary>What's the difference between a disk, a volume and a storage policy?</summary>

A disk is one place bytes can live (local filesystem, S3, a cache over S3). A
volume is a group of disks used as one tier. A storage policy is the ordered
list of volumes a table uses, plus spill rules like `move_factor`.
</details>

<details><summary>You're about to run <code>enable-s3-tiering.sh</code> on a 5 TB table. What should worry you?</summary>

`MODIFY TTL` starts a `MATERIALIZE TTL` mutation over every existing part
(`materialize_ttl_after_modify = 1` by default). On 5 TB that's a long, heavy
rewrite plus a big S3 upload. Set `materialize_ttl_after_modify = 0` for the
change, then run `MATERIALIZE TTL IN PARTITION` one day at a time when the
cluster is quiet.
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

<details><summary>The S3 bucket is down when you restart <code>clickhouse-01</code>. What happens?</summary>

The server checks access to its S3 disk at startup, the check fails, and the
server exits instead of waiting. Docker's restart policy keeps retrying; it
comes up once S3 is reachable again.
</details>

## Next

Tiering adds one more moving part to a pipeline that already has an SDK, a
gateway, ClickHouse and Keeper. [Module 12](12-operations.md) asks how you
know, day to day, that all of it is healthy: what to watch, what a bad number
looks like, and what to do about it.

## Read more

- [Storing data on external disks, including S3 and the local cache](https://clickhouse.com/docs/operations/storing-data)
- [Using multiple block devices: volumes, policies, move_factor](https://clickhouse.com/docs/engines/table-engines/mergetree-family/mergetree#table_engine-mergetree-multiple-volumes)
- [TTL for moving and deleting data](https://clickhouse.com/docs/guides/developer/ttl)
- [`merge_with_ttl_timeout`](https://clickhouse.com/docs/operations/settings/merge-tree-settings#merge_with_ttl_timeout) and [`materialize_ttl_after_modify`](https://clickhouse.com/docs/operations/settings/settings#materialize_ttl_after_modify)
- [Separation of storage and compute](https://clickhouse.com/docs/guides/separation-storage-compute)
- [Integrating S3 with ClickHouse](https://clickhouse.com/docs/integrations/s3)
- [`ALTER ... MOVE PARTITION`](https://clickhouse.com/docs/sql-reference/statements/alter/partition)
- [SeaweedFS](https://github.com/seaweedfs/seaweedfs)
- [What is Amazon S3?](https://docs.aws.amazon.com/AmazonS3/latest/userguide/Welcome.html)

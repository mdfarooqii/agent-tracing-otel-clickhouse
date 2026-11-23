# Appendix B: Runbooks for the tracing pipeline

A **runbook** is the page the person on call opens when an alert fires: what
the alert means, how bad it is, how to find the cause, what to do, and how to
check it worked. This appendix has one per likely problem with the gateway,
ClickHouse, Keeper and S3, plus the planned changes that go wrong when done
from memory: growing disks, adding a node, changing S3 tiering, upgrading.

Each runbook has the same parts:

- **Symptom**: the alert, health check line or error that brings you here.
- **Impact**: what users and data lose, and how much time you have.
- **Diagnose**: queries and commands, in the order to run them.
- **Fix**: steps, safest and fastest first.
- **Verify**: how you know it worked.
- **Prevent**: what to change so it doesn't come back.

The SQL uses this repo's names (`otel.otel_traces`, cluster `tracing`, disks
`default` and `s3_cache`) and runs on any ClickHouse server unless a step
says otherwise. Steps marked **tested** were run on this repo's stack, and
the outputs and error messages quoted are from those runs. Steps on real
hosts (EBS, mounting disks, Keeper on several hosts) can't be run on a
laptop; they follow the vendor documentation linked in each runbook. Try
every runbook once in staging before you need it.

[Module 12](12-operations.md) explains the signals; the
[metrics reference](appendix-metrics-reference.md) explains each metric and
health check line; [module 10](10-copying-data.md) and
[module 11](11-s3-tiering.md) explain the storage and growth concepts used
here.

## Index

| Runbook | Typical symptom | Urgency |
|---|---|---|
| [First five minutes](#first-five-minutes) | Any alert | - |
| [Local disk filling up](#local-disk-filling-up) | `local disk N% free` WARN/FAIL, `NOT_ENOUGH_SPACE` | High: inserts and merges stop when full |
| [Grow an EBS volume in place](#grow-an-ebs-volume-in-place) | Planned, or disk alert | Planned |
| [Add a disk to a server](#add-a-disk-to-a-server) | Planned, volume at its size limit | Planned |
| [Servers with local NVMe (instance store)](#servers-with-local-nvme-instance-store) | Instance stopped or replaced | High if a shard has one replica left |
| [Change S3 tiering](#change-s3-tiering) | Planned: move age, bucket, credentials, S3 outage | Planned / medium |
| [Too many parts](#too-many-parts) | `max N parts in a partition` WARN, `TOO_MANY_PARTS` | High: inserts rejected at 3000 |
| [Replica read-only or lagging](#replica-read-only-or-lagging) | `read-only replicated tables`, lag WARN | High if all replicas |
| [Keeper down or quorum lost](#keeper-down-or-quorum-lost) | `Keeper does not answer ruok` | Critical: about 300 s before spans are lost |
| [Replace a failed node](#replace-a-failed-node) | A server is gone; `active_replicas < total_replicas` | High: one less copy |
| [Add a shard](#add-a-shard) | Planned | Planned |
| [Query using too much memory or running too long](#query-using-too-much-memory-or-running-too-long) | `MEMORY_LIMIT_EXCEEDED`, slow dashboards | Medium |
| [Stuck mutation](#stuck-mutation) | `stuck mutations` WARN | Medium: blocks later mutations, can starve merges |
| [Distributed insert queue backlog](#distributed-insert-queue-backlog) | `system.distribution_queue` growing (sharded clusters) | High: local disk fills |
| [`ON CLUSTER` DDL not finished](#on-cluster-ddl-not-finished) | Code 159 after a schema change | Medium: servers drift |
| [Rolling restart and upgrade](#rolling-restart-and-upgrade) | Planned; on large clusters in waves by replica | Planned |
| [Backup and restore drill](#backup-and-restore-drill) | Monthly drill, or a bad `DELETE` | Planned / critical |
| [Gateway export queue filling, spans lost](#gateway-export-queue-filling-spans-lost) | Queue over half full, `lost` rising | Critical |

## First five minutes

Whatever the alert, take the same snapshot first, so you know whether it's
one table, one server, or everything, and whether data is being lost now.

1. **The whole pipeline on one screen:** `./stack.sh health`
   ([module 12](12-operations.md)). In production, your dashboard of the
   same signals.
2. **Is data being lost right now?** The gateway's `lost` and `refused`
   rates, and the export queue fill. If the queue is filling, you have
   minutes: the exporter gives up on a batch after 300 s.
3. **Every server at once.** `clusterAllReplicas` runs a query on every
   server in the cluster definition:

   ```sql
   -- read-only tables, lag, replication queue, per server
   SELECT hostName() AS host, database, table, is_readonly, absolute_delay, queue_size
   FROM clusterAllReplicas('tracing', system.replicas)
   WHERE is_readonly OR absolute_delay > 60 OR queue_size > 50;

   -- free disk, per server and disk
   SELECT hostName() AS host, name, round(100 * free_space / total_space) AS pct_free
   FROM clusterAllReplicas('tracing', system.disks) WHERE total_space > 0;

   -- new error names in the last 10 minutes, per server
   SELECT hostName() AS host, name, value, last_error_time, substring(last_error_message, 1, 100) AS msg
   FROM clusterAllReplicas('tracing', system.errors)
   WHERE last_error_time > now() - INTERVAL 10 MINUTE ORDER BY last_error_time DESC;
   ```

4. **What changed?** Deploys, config changes, schema changes, a new
   dashboard, a backfill. Most incidents follow a change.
5. **Write down the time and what you see** in the incident channel
   before you change anything.

## Local disk filling up

**Symptom.** `local disk N% free` WARN or FAIL in the health check; inserts
failing with `NOT_ENOUGH_SPACE` ("Cannot reserve ... bytes"); the gateway's
`send_failed` rising.

**Impact.** At full, inserts fail (spans queue at the gateway, then are lost
after 300 s), and merges stop, so parts pile up
([too many parts](#too-many-parts)). Merges need free space about the size of
the parts they combine, so a nearly full disk stops the big merges first.

**Diagnose.** What is using the space:

```sql
SELECT name, path, formatReadableSize(free_space) AS free,
       formatReadableSize(total_space) AS total, round(100 * free_space / total_space) AS pct_free
FROM system.disks WHERE total_space > 0;

-- biggest tables per disk, including ClickHouse's own system tables
SELECT database, table, disk_name, formatReadableSize(sum(bytes_on_disk)) AS size, count() AS parts
FROM system.parts WHERE active
GROUP BY database, table, disk_name ORDER BY sum(bytes_on_disk) DESC LIMIT 15;

-- old parts waiting to be deleted, and detached parts nobody uses
SELECT formatReadableSize(sum(bytes_on_disk)) AS inactive FROM system.parts WHERE NOT active;
SELECT database, table, reason, count() AS parts, formatReadableSize(sum(bytes_on_disk)) AS size
FROM system.detached_parts GROUP BY database, table, reason;
```

**Fix**, fastest and safest first:

1. **ClickHouse's own log tables.** `system.text_log`, `trace_log`,
   `query_log`, `metric_log` and friends have **no TTL** by default (on this
   stack, `text_log` was the biggest table in `system`). Emptying one loses
   only history: `TRUNCATE TABLE system.text_log` (**tested**: 68.83 MiB to
   0). Then add a TTL in the server config, for example
   `<text_log><ttl>event_date + INTERVAL 7 DAY DELETE</ttl></text_log>` in a
   `config.d` file; after a restart ClickHouse creates the table with it and
   renames the old one (`text_log_0`), which you drop.
2. **Detached parts** you've checked aren't needed (`reason` says why they
   were detached): `ALTER TABLE db.t DROP DETACHED PARTITION '<partition>'
   SETTINGS allow_drop_detached = 1` (**tested**).
3. **Move old partitions to S3**, on tables with the `tiered` policy
   ([module 11](11-s3-tiering.md)):
   `ALTER TABLE otel.otel_traces MOVE PARTITION '2026-11-20' TO VOLUME 'cold'`.
4. **Grow the disk** ([next runbook](#grow-an-ebs-volume-in-place)): on a
   cloud volume this takes minutes and needs no restart.
5. **Drop the oldest data you can lose.** On a replicated table, `ALTER TABLE
   ... DROP PARTITION` removes it from **every replica**, not only the full
   one. Partitions over 50 GB (`max_partition_size_to_drop`) need a one-time
   flag file: `sudo touch /var/lib/clickhouse/flags/force_drop_table && sudo
   chmod 666 /var/lib/clickhouse/flags/force_drop_table`.

**Verify.** `pct_free` rising; the gateway's sent rate back to normal and
`send_failed` flat; parts per partition falling as merges resume.

**Prevent.** Alert at 25% free (ticket) and 15% (page). Give the system log
tables a TTL. Keep `keep_free_space_bytes` on each disk so ClickHouse stops
writing before the file system is full. Size disks with the formula in
module 12, and grow them at about 60% full, not at 90%.

## Grow an EBS volume in place

**When.** A server's data volume is filling up and CPU and memory are fine.
This is the first choice: nothing moves and nothing restarts.

**Impact.** None expected. The volume stays usable during the change; its
performance is in between the old and new settings until optimization
finishes.

**Steps** (from the AWS documentation linked below):

1. Optional but recommended by AWS: snapshot the volume first.
2. Grow it (size, and for `gp3` also IOPS and throughput if needed):

   ```bash
   aws ec2 modify-volume --volume-id vol-0123456789abcdef0 --size 2000
   aws ec2 describe-volumes-modifications --volume-ids vol-0123456789abcdef0 \
     --query 'VolumesModifications[0].ModificationState'
   ```

   The new size can be used once the state is `optimizing`, usually after a
   few seconds; you don't have to wait for `completed`.
3. On the server, grow the partition if the volume has one, then the file
   system:

   ```bash
   lsblk                                   # is there a partition (nvme1n1p1)?
   sudo growpart /dev/nvme1n1 1            # only if there is a partition
   sudo xfs_growfs -d /var/lib/clickhouse  # XFS: takes the mount point
   # ext4 instead: sudo resize2fs /dev/nvme1n1p1
   df -h /var/lib/clickhouse
   ```

4. ClickHouse reads free space from the file system each time, so no
   restart: check `SELECT name, formatReadableSize(total_space) FROM
   system.disks`.
5. Do one replica first, then the others.

**Limits.** A volume can't shrink. After a modification you must wait until
it's `completed` before the next one on the same volume, and there are at
most four modifications per volume in a rolling 24 hours. Full optimization
of a large volume can take hours, so the next increase may not be possible
the same day: grow by enough.

## Add a disk to a server

**When.** A volume can't grow more, or you want more disk throughput; or the
servers use several local SSDs.

**Impact.** None expected. Existing parts stay where they are; new parts
spread over the old and new disks.

**Steps** (the ClickHouse part is **tested** in the
[module 10](10-copying-data.md) lab):

1. **Attach, format, mount.** For example a new EBS volume as
   `/dev/nvme2n1`:

   ```bash
   sudo mkfs.xfs /dev/nvme2n1
   sudo mkdir -p /mnt/disk2
   echo "UUID=$(sudo blkid -s UUID -o value /dev/nvme2n1) /mnt/disk2 xfs defaults,noatime 0 2" | sudo tee -a /etc/fstab
   sudo mount /mnt/disk2 && sudo chown clickhouse:clickhouse /mnt/disk2
   ```

   Make the ClickHouse service wait for the mount, so it can never start
   writing into an empty folder on the root disk when the volume is missing
   (`sudo systemctl edit clickhouse-server`, then add
   `RequiresMountsFor=/mnt/disk2` under `[Unit]`).
2. **Add the disk and a new policy** in a `config.d` file, on every
   replica. The new policy must contain the old one: same volume names, in
   the same order, with all their disks, plus the new disk. For tables on
   `default`, and for `otel_traces` on `tiered`:

   ```xml
   <clickhouse>
     <storage_configuration>
       <disks>
         <disk2><path>/mnt/disk2/</path><keep_free_space_bytes>10737418240</keep_free_space_bytes></disk2>
       </disks>
       <policies>
         <grown>
           <volumes><default><disk>default</disk><disk>disk2</disk></default></volumes>
         </grown>
         <tiered_v2>
           <volumes>
             <default><disk>default</disk><disk>disk2</disk></default>
             <cold><disk>s3_cache</disk></cold>
           </volumes>
           <move_factor>0.1</move_factor>
         </tiered_v2>
       </policies>
     </storage_configuration>
   </clickhouse>
   ```

   Keep the old policies in the config: a policy a table uses can't
   disappear.
3. **Reload and check** on every server: config files are reread within
   seconds, or `SYSTEM RELOAD CONFIG`.

   ```sql
   SELECT hostName(), policy_name, volume_name, disks
   FROM clusterAllReplicas('tracing', system.storage_policies)
   WHERE policy_name IN ('grown', 'tiered_v2');
   ```

4. **Switch the tables**, once every server has the policies:

   ```sql
   ALTER TABLE otel.trace_entry ON CLUSTER tracing MODIFY SETTING storage_policy = 'grown';
   ALTER TABLE otel.otel_traces ON CLUSTER tracing MODIFY SETTING storage_policy = 'tiered_v2';
   ```

5. **Optionally balance** by moving some old partitions:
   `ALTER TABLE otel.trace_entry MOVE PARTITION '2026-11-20' TO DISK 'disk2'`.

**Verify.** `SELECT disk_name, count(), formatReadableSize(sum(bytes_on_disk))
FROM system.parts WHERE active GROUP BY disk_name`: new parts appear on
`disk2`.

**Undo.** There's no switching back: going from `grown` to `default` fails
with "New storage policy `default` shall contain disks of the old storage
policy `grown`" (**tested**). To retire a disk later, move its partitions to
other disks of the volume, switch to yet another policy that still contains
it... in practice, you keep it until the data on it has aged out, and remove
it from the config with a restart once no table uses it.

**Note.** Several disks in one volume are JBOD: losing one disk loses the
parts on it on that server. With replicas, rebuild the server
([replace a failed node](#replace-a-failed-node)).

## Servers with local NVMe (instance store)

**What's different.** Instance-store NVMe disks are fast and included in the
instance price, but their data is gone when the instance stops, is
terminated, or its hardware fails. They can't be grown or snapshotted.

**Rules.**

- Run at least two replicas per shard in different availability zones, and
  never stop all replicas of a shard at the same time.
- A stopped or replaced instance is a **new, empty node**: follow
  [replace a failed node](#replace-a-failed-node). Rebuild time is the
  whole shard's data over the network, so throttle
  (`max_replicated_fetches_network_bandwidth_for_server`) and plan for it.
- Grow with bigger instances, more shards, or S3 tiering for old data, not
  with bigger disks.
- Keep Keeper's data on durable storage (EBS), not on instance store.

## Change S3 tiering

All of these build on [module 11](11-s3-tiering.md), which explains the
`tiered` policy, TTL moves, what happens during an S3 outage, and how to
turn tiering off. Two rules hold throughout:

- **`MODIFY TTL` replaces the whole TTL.** Always repeat the delete rule
  (`toDateTime(Timestamp) + INTERVAL 72 HOUR`), or data stops being deleted.
- **By default, changing a TTL rewrites every partition** to apply it
  (`materialize_ttl_after_modify = 1`), which on a big table is hours of
  I/O. Turn that off and apply it one partition at a time.

### Change the move age

**Tested** on a scratch table with the `tiered` policy: after `MODIFY TTL`
with `materialize_ttl_after_modify = 0`, no part moved; after `MATERIALIZE
TTL IN PARTITION` for one day, that day moved to S3 and the other stayed.

```sql
ALTER TABLE otel.otel_traces ON CLUSTER tracing
  MODIFY TTL toDateTime(Timestamp) + INTERVAL 12 HOUR TO VOLUME 'cold',
             toDateTime(Timestamp) + INTERVAL 72 HOUR
  SETTINGS materialize_ttl_after_modify = 0;

-- then, partition by partition, oldest first, watching S3 errors and disk I/O
ALTER TABLE otel.otel_traces ON CLUSTER tracing MATERIALIZE TTL IN PARTITION '2026-11-20';
```

New parts get the new rule at once; old parts get it when merged or
materialized. Do the same for `otel_traces_trace_id_ts`, which also uses
`tiered`.

### Bring data back from S3

`ALTER TABLE otel.otel_traces MOVE PARTITION '2026-11-20' TO VOLUME
'default'` moves it back, but if the TTL still says it belongs on `cold`,
the background mover sends it out again (**tested**: back on S3 within 30
seconds). Raise the move age first (above), then move the partitions back.
Check local free space before you do: it all has to fit.

### A new bucket or endpoint

An S3 disk's data stays in its bucket; ClickHouse's local metadata points at
objects there. You can't repoint a disk with data on it. Instead:

1. Add a second S3 disk (and its cache disk) for the new bucket.
2. Add a policy that contains the old one and adds the new cache disk to the
   `cold` volume.
3. Switch the tables, then move partitions from the old disk to the new one
   with `MOVE PARTITION ... TO DISK`, or let the old data age out (72 hours
   here).
4. Remove the old disk from the config only when nothing uses it, with a
   restart.

This follows the same policy rules as adding a local disk, but it hasn't
been run on this stack: rehearse it in staging.

### Rotate S3 credentials

Best: don't keep keys in config at all. On AWS, give the servers an IAM role
(the disk setting `use_environment_credentials`), and there's nothing to
rotate. With keys (this lab reads them from environment variables):

1. Create the new key; keep the old one valid.
2. On one replica, put in the new key and reload (`SYSTEM RELOAD CONFIG`)
   or, if your version doesn't pick it up on reload, restart it.
3. Check it writes: move a small partition to `cold`, and watch
   `S3WriteRequestsErrors` in `system.events` stay flat.
4. Repeat on the other replicas, one at a time. Then retire the old key.

### S3 is down or slow

See [module 11](11-s3-tiering.md) for the detail. In short: new spans still
land on local disk; queries that touch moved data fail or slow down;
background moves fail and retry, so **local disk fills** at the rate data
should have moved. Watch [local disk](#local-disk-filling-up), and if S3
stays down for long, raise the move age so ClickHouse stops trying.

## Too many parts

**Symptom.** `max N parts in a partition` WARN; `DelayedInserts` rising;
inserts failing with `TOO_MANY_PARTS`.

**Impact.** At 1000 active parts in one partition, inserts are slowed
(`parts_to_delay_insert`); at 3000 they're rejected (`parts_to_throw_insert`),
and the gateway's retry clock starts.

**Diagnose.**

```sql
SELECT database, table, partition, count() AS parts
FROM system.parts WHERE active GROUP BY database, table, partition ORDER BY parts DESC LIMIT 10;

-- are merges running, and how far along?
SELECT database, table, round(elapsed) AS secs, round(progress * 100) AS pct, num_parts,
       formatReadableSize(total_size_bytes_compressed) AS size, is_mutation
FROM system.merges;

-- inserts per table in the last 5 minutes: who makes so many parts?
SELECT tables, count() AS inserts, sum(written_rows) AS rows
FROM system.query_log
WHERE type = 'QueryFinish' AND query_kind = 'Insert' AND event_time > now() - INTERVAL 5 MINUTE
GROUP BY tables ORDER BY inserts DESC;
```

**Causes and fixes.**

- **Too many small inserts.** Each insert makes a part per table, and each
  materialized view adds one more in its target. Batch bigger at the gateway
  (`batch` processor size and timeout), use fewer gateways writing to the
  same table, or turn on `async_insert` so ClickHouse batches for you.
- **Merges can't keep up or are blocked.** Disk nearly full (merges need
  room), a stuck mutation hogging the merge pool, merges stopped by hand
  (`SYSTEM START MERGES db.table`), too little CPU.
- **A partition key that's too fine** (per hour, per tenant) makes many
  partitions that each need merging. Here it's per day.

**Buy time, not a fix.** Raise the limits on one table while you fix the
cause: `ALTER TABLE otel.otel_traces MODIFY SETTING parts_to_delay_insert =
2000, parts_to_throw_insert = 6000`. Set them back afterwards.

**Verify.** Parts per partition falling; `DelayedInserts` flat.

**Prevent.** Alert at 300 parts. Size the gateway's batches so each one
inserts thousands of rows.

## Replica read-only or lagging

**Symptom.** `N read-only replicated tables` FAIL; inserts failing with
`TABLE_IS_READ_ONLY` (code 242); `replication lag Ns` WARN.

**Impact.** A read-only table answers queries but refuses inserts. If every
replica is read-only, the gateway can't write anywhere: same clock as
[Keeper down](#keeper-down-or-quorum-lost). If one replica lags, queries
that land on it miss recent spans.

**Diagnose.**

```sql
SELECT database, table, is_readonly, is_session_expired, absolute_delay, queue_size,
       inserts_in_queue, merges_in_queue, substring(zookeeper_exception, 1, 100) AS keeper_error,
       substring(last_queue_update_exception, 1, 100) AS queue_error
FROM system.replicas WHERE is_readonly OR absolute_delay > 60 OR queue_size > 50;

-- the replication tasks that keep failing
SELECT database, table, type, new_part_name, num_tries, substring(last_exception, 1, 120) AS error, postpone_reason
FROM system.replication_queue ORDER BY num_tries DESC LIMIT 10;
```

**Causes and fixes.**

- **Keeper unreachable** (all tables read-only, `keeper_error` set): go to
  [Keeper down](#keeper-down-or-quorum-lost). When Keeper is back, tables
  leave read-only by themselves (module 12, lab 2: back to OK about a minute
  after Keeper started).
- **One table stuck** while Keeper is fine: `SYSTEM RESTART REPLICA
  otel.otel_traces` reconnects that table to Keeper.
- **Fetches failing** (`replication_queue` errors on `GET_PART`): replicas
  download parts from each other on port 9009, at the address in
  `interserver_http_host`. Check that the lagging server can reach its peers
  there, and that its disk isn't full.
- **Big merges or a slow disk** on one replica: lag that shrinks on its own.
  Wait, or check the disk.
- **Keeper lost the table's metadata** (a Keeper restored from an old
  snapshot, or wiped), while the data is still on the servers: the tables
  stay read-only. `SYSTEM RESTORE REPLICA otel.otel_traces` on a read-only
  replica recreates its metadata in Keeper from the local parts; run it for
  each table, on one replica first.

**Verify.** No rows from the first query; the gateway's sent rate normal.

**Prevent.** Alert on any read-only table and on lag over 60 s. Make Keeper
redundant (next runbook).

## Keeper down or quorum lost

**Symptom.** `Keeper does not answer ruok`; every replicated table
read-only; error names `KEEPER_EXCEPTION`, `TABLE_IS_READ_ONLY`.

**Impact.** Critical. No inserts into any replicated table, on any server.
The gateway retries each batch for 300 s and then drops it; the in-memory
queue (1000 batches) may fill sooner. Queries still work.

**Diagnose.** Keeper answers short "four-letter" commands on its client port
(9181 here):

```bash
echo ruok | nc keeper-1 9181     # imok = the process is up
echo mntr | nc keeper-1 9181     # zk_server_state (leader / follower), latency, outstanding requests
echo stat | nc keeper-1 9181     # mode and connections
```

Ask each node. A three-node ensemble needs two nodes to agree (a quorum); a
five-node one, three. Check each node's log and disk: a full disk under
Keeper's log or snapshot folders stops it too.

**Fixes.**

- **One of three nodes down**: no impact yet, but one more failure stops
  everything. Restart it, or replace it with a new host using the same
  `server_id` and address; it catches up from the leader.
- **Quorum lost, nodes can come back**: start them. Keeper resumes once a
  majority is up, and ClickHouse reconnects by itself.
- **Quorum lost for good** (too many nodes destroyed): Keeper has a
  last-resort recovery mode. From the ClickHouse Keeper documentation:
  1. Make sure the failed nodes can't come back and rejoin.
  2. Pick the surviving node with the newest state; it becomes the leader
     and its data is used for the whole cluster. **Back up** its
     `log_storage_path` and `snapshot_storage_path` folders first.
  3. Change the cluster configuration (`raft_configuration`) on every node
     you'll use.
  4. Send it `rcvr` (`echo rcvr | nc keeper-1 9181`), or restart it with
     `--force-recovery`.
  5. Start the new nodes **one at a time**, each only after `mntr` on the
     previous one shows `zk_server_state follower`.
  6. When the leader has a quorum, it leaves recovery mode; `mntr` on it
     shows `leader`.
- **Afterwards**, if Keeper came back from older data, some tables may stay
  read-only: see `SYSTEM RESTORE REPLICA` in the
  [previous runbook](#replica-read-only-or-lagging).

**Verify.** `mntr` shows one leader and the rest followers; no read-only
tables; the gateway's queue drains, `lost` flat.

**Prevent.** Three Keeper nodes (five if two may fail at once) on separate
hosts in separate zones, on fast durable disks, not on the busiest
ClickHouse servers. Alert on `ruok`, `zk_avg_latency`,
`zk_outstanding_requests` and free disk on Keeper hosts. Upgrade Keeper
separately from ClickHouse.

## Replace a failed node

**Symptom.** A server is gone: hardware, a terminated instance, a lost disk.
`total_replicas` is bigger than `active_replicas` on the others.

**Impact.** Its shard has one copy fewer. Queries and inserts continue on
the other replicas. If it was the last replica of its shard, that shard's
data is unavailable (and lost without a backup).

**Steps** (**tested** with `clickhouse-03`: container and data deleted, then
rebuilt):

1. **Confirm** from a live replica:

   ```sql
   SELECT table, total_replicas, active_replicas FROM system.replicas WHERE database = 'otel';
   ```

   In the test: `otel_traces  3  2`.
2. **Build the new server** with the same Keeper, the same storage
   policies, and macros for the **same shard**. Either reuse the old
   `{replica}` name (and host name), or give it a new one.
3. **Remove the dead replica from Keeper**, from a live server. Reusing the
   name without this fails: `Replica /clickhouse/tables/<uuid>/01/replicas/clickhouse-03
   already exists. (REPLICA_ALREADY_EXISTS)`. With a new name, do it anyway:
   otherwise Keeper keeps a replication log for a replica that will never
   read it.

   ```sql
   SYSTEM DROP REPLICA 'clickhouse-03' FROM DATABASE otel;
   ```

4. **Create the tables** on the new server with the same UUIDs (so they
   resolve to the same Keeper paths), tables first, then views:
   `docs/tutorial/labs/add-replica.sh` does exactly that. It needs every
   storage policy the tables use; without `tiered`, the create fails with
   `Unknown storage policy`.
5. **Watch it catch up:** `queue_size` falls to 0 and counts match. In the
   test, all six tables showed `3  3  0` and both servers 134151 spans,
   20 seconds later. For terabytes, set
   `max_replicated_fetches_network_bandwidth_for_server` so the rebuild
   doesn't starve the peers.
6. **Cluster definition**: if the host name changed, update `remote_servers`
   on every server ([module 10](10-copying-data.md)), or `ON CLUSTER` DDL and
   `Distributed` queries won't use the new node.

**Verify.** `total_replicas = active_replicas`, `queue_size = 0`, same
`count()` on every replica.

## Add a shard

Planned growth when one server can't hold its share of the data or take its
share of inserts. [Module 10](10-copying-data.md#adding-a-shard) has the
steps, what changes for in-flight traces and `optimize_skip_unused_shards`,
and a lab. Checklist:

1. New servers (as many as the other shards have replicas), macros with the
   new `{shard}`, same Keeper, same storage policies.
2. Schema on the new servers first (`CREATE ... IF NOT EXISTS ... ON
   CLUSTER`), then the new shard in `remote_servers` on every server.
3. Turn off `optimize_skip_unused_shards` for queries until data from before
   the change has aged out.
4. Watch the new shard's share grow, and `system.distribution_queue` stay
   empty.

## Query using too much memory or running too long

**Symptom.** Errors `MEMORY_LIMIT_EXCEEDED` (code 241) or `TIMEOUT_EXCEEDED`;
slow dashboards; `memory N% of the server limit` WARN.

**Impact.** One heavy query can slow every other query and the inserts on
that server. At the server limit, ClickHouse cancels queries.

**Diagnose** (**tested**):

```sql
-- running now, longest first
SELECT query_id, user, round(elapsed) AS secs, formatReadableSize(memory_usage) AS mem,
       substring(query, 1, 80) AS q
FROM system.processes ORDER BY elapsed DESC;

-- the heaviest query shapes in the last hour
SELECT normalizeQuery(query) AS q, user, count() AS runs,
       formatReadableSize(max(memory_usage)) AS max_mem, max(read_rows) AS max_rows
FROM system.query_log
WHERE type IN ('QueryFinish', 'ExceptionWhileProcessing') AND event_time > now() - INTERVAL 1 HOUR
GROUP BY q, user ORDER BY max(memory_usage) DESC LIMIT 5;
```

**Fix.**

- Stop it: `KILL QUERY WHERE query_id = '...' SYNC` (**tested**: status
  `finished`, and the client got `QUERY_WAS_CANCELLED`). On a sharded
  cluster add `ON CLUSTER tracing`.
- Find its owner (the `user` column; one account per tool or team makes
  this possible) and fix the query: filter on the sorting key (owner,
  service, span name, time), select fewer columns, use a summary table
  ([module 8](08-data-model.md)).

**Prevent.** Settings profiles per user with `max_memory_usage`,
`max_execution_time` and `max_rows_to_read`, plus quotas
([module 10](10-copying-data.md#what-users-and-tools-see)).

## Stuck mutation

**Symptom.** `N stuck mutations` WARN; an `ALTER ... UPDATE` or `DELETE`
that never finishes.

**Impact.** A failing mutation retries forever and blocks the mutations
after it on that table. Large ones also compete with merges.

**Diagnose** (**tested** with an update that throws on half the rows):

```sql
SELECT database, table, mutation_id, command, parts_to_do, is_done,
       latest_fail_error_code_name, substring(latest_fail_reason, 1, 120) AS reason
FROM system.mutations WHERE NOT is_done;
```

In the test: `parts_to_do 1`, `latest_fail_error_code_name
FUNCTION_THROW_IF_VALUE_IS_NON_ZERO`.

**Fix.** `KILL MUTATION WHERE database = 'otel' AND table = '...' AND
mutation_id = '...'`. Parts already rewritten stay rewritten: there's no
rollback. In the test the failing mutation had changed nothing, and the
data was intact afterwards.

**Prevent.** Avoid `ALTER ... UPDATE`/`DELETE` on span tables; let TTL
delete. Try a mutation on a copy first (`ATTACH PARTITION ... FROM`,
[module 10](10-copying-data.md)).

## Distributed insert queue backlog

Only on sharded clusters that insert through `Distributed` tables
([module 10](10-copying-data.md)).

**Symptom.** `system.distribution_queue` growing on the servers the gateway
writes to; their local disk filling.

**Impact.** The gateway sees successful inserts, but the rows sit on the
receiving server's disk until a shard accepts them. Queries don't see them
yet. If that server's disk is lost, so are they.

**Diagnose.**

```sql
SELECT database, table, is_blocked, error_count, data_files,
       formatReadableSize(data_compressed_bytes) AS size, broken_data_files,
       substring(last_exception, 1, 120) AS error
FROM system.distribution_queue WHERE data_files > 0 OR error_count > 0;
```

**Causes and fixes.** A shard down (bring it back); the local table missing
on a new shard (create it; **tested**: rows arrived by themselves once it
existed, after `error_count` reached 5); wrong credentials in
`remote_servers`. After fixing, `SYSTEM FLUSH DISTRIBUTED otel.otel_traces`
sends the queue at once. Files ClickHouse can't send at all are moved
aside (`broken_data_files`); inspect them before deleting.

**Prevent.** Alert on `data_files` growing for 5 minutes. Or route by trace
id at the gateway and write to local tables directly.

## `ON CLUSTER` DDL not finished

**Symptom.** A schema change fails with code 159: "Distributed DDL task ...
is not finished on 1 of 3 hosts ... They are going to execute the query in
background" (**tested**, with one server stopped).

**Impact.** Servers have different schemas until the stragglers run it. The
statement isn't lost: it's in Keeper's DDL queue, and the stopped server ran
it when it started again.

**Diagnose.**

```sql
SELECT host, status, exception_code, substring(exception_text, 1, 120) AS error, query_create_time
FROM system.distributed_ddl_queue
WHERE query_create_time > now() - INTERVAL 1 HOUR ORDER BY query_create_time DESC, host;
```

In the test: `Finished` on two hosts, `Inactive` on the stopped one, then
`Finished` on all three once it was back. A status with an `exception_code`
means it ran and failed there: read `error`, fix that server, and rerun the
statement (with `IF NOT EXISTS` / `IF EXISTS` it's safe to repeat).

**Prevent.** Make schema changes add-only and idempotent; check
`system.distributed_ddl_queue` after every change; don't change schemas
while a server is down for maintenance.

## Rolling restart and upgrade

**When.** Config changes that need a restart, version upgrades, OS patches.

**Rules** (from the ClickHouse upgrade guide):

- Keep at least one replica of **every shard** up at all times; restart or
  upgrade one replica at a time.
- Keep config in `config.d/` files, not the main `config.xml`, which an
  upgrade may overwrite.
- Read the changelogs between your version and the target for backward
  incompatible changes.
- Versions less than a year apart can run in one cluster during the upgrade;
  finish quickly, because mixed versions can slow distributed queries and
  log harmless replication errors (such as `CHECKSUM_DOESNT_MATCH` after
  merges). Further apart: upgrade through an intermediate version.
- Upgrade ClickHouse servers and Keeper separately; Keeper must be stable
  while servers restart.
- Downgrade is possible only to a recent version, and only if no new
  features have been used.

First check whether the change needs a restart at all. The cluster
definition (`remote_servers`) reloads without one (module 10).

**Per server:**

1. Before: the server is healthy (no read-only tables, `queue_size` near 0,
   lag under 60 s), and so are the other replicas of its shard.
2. Drain: take it out of the query load balancer (or ClickStack's
   connection) and the gateway's endpoint list, and let running queries
   finish. Setting `shutdown_wait_unfinished_queries` to `1` in the server
   config makes a shutdown wait up to `shutdown_wait_unfinished` seconds
   (default 5) for them.
3. Stop, upgrade (or change config), start.
4. Gate: [`labs/rolling-gate.sh`](labs/rolling-gate.sh) waits until the
   server accepts queries, has loaded every table (`system.asynchronous_loader`),
   has no read-only replica and lag under 60 s, and has fetched what it
   missed (`SYSTEM SYNC REPLICA <table> LIGHTWEIGHT`, which waits for the
   queued fetches but not merges). Then it prints the version and any error
   names in `system.errors` since the start. Then check the gateway's sent
   rate is unchanged, put the server back, and go to the next one.

The table-loading check matters because `async_load_databases` is on (it is
in this repo): the server accepts connections before its tables are
loaded, so "it answers `SELECT 1`" doesn't mean "it's ready". In a test run
here, `clickhouse-02` answered after 8 s and the whole gate passed after
36 s. Its one warning, `DNS_ERROR`, was expected: the `lab_3shards`
cluster definition names `clickhouse-03`, which wasn't running. Know your
usual errors, so the gate reports new ones.

In this repo, the version is pinned in `compose.yaml`
(`clickhouse/clickhouse-server:25.8`); change the tag and recreate one
server at a time (`docker compose up -d clickhouse-02`, run the gate, then
`clickhouse-01`).

### Large clusters: hundreds of servers, petabytes

The rules above hold at any size. The per-server loop doesn't, because it
is serial. An illustration, not a measurement: 5 PB with two replicas at
about 50 TB per server is about 200 servers; at 20 to 30 minutes each, one
at a time takes 70 to 100 hours, far from "finish quickly". In-place
rolling is still the only practical way: an upgrade rewrites no data, while
building a second cluster means copying petabytes. What changes is how you
batch, gate and automate it.

- **Waves by replica, not by server.** A shard can lose one replica, so a
  wave restarts at most one replica of each shard, across all shards
  together (with `{replica}` macros `01` and `02`: all `01` servers, then
  all `02`). Two or three replicas means two or three waves, each split into
  batches. Never put two replicas of one shard in the same batch.
- **Canary first.** Upgrade one server, run the gate, and time it. That
  time sets the batch plan. Leave the canary for a while under real queries
  and inserts before wave 1: a mixed-version problem shows up there, on one
  server, and downgrading one server is still easy.
- **Startup time grows with the number of parts, not bytes.** Each server
  loads the metadata of every part it holds, including parts tiered to S3
  (their metadata is on local disk). A server with millions of parts can
  take much longer than this lab's 8 s. Fewer, larger parts (daily
  partitions, merges keeping up) shorten every restart.
- **Batch size is set by Keeper and catch-up.** Every restarted server
  reconnects to Keeper, reloads its replication queues and fetches the
  parts it missed, while its peer took the inserts. Many at once means
  Keeper load and network load. Start small, watch Keeper latency and
  outstanding requests and the restarted servers' lag, and grow the batch
  while they stay normal. The next batch starts only when every gate in
  the current one passed.
- **A wave runs each shard on one copy.** With two replicas, a second
  failure in a shard during its wave takes that shard down. Before each
  batch, skip shards with any other problem (a lagging or read-only
  replica, a server being rebuilt). At petabyte scale, three replicas make
  waves safer: a batch still leaves two copies.
- **Automate the loop and stop on the first failure.** A script, Ansible,
  or the Kubernetes ClickHouse operator: drain, restart, gate, return, for
  every server in the batch, and stop the rollout when any gate fails
  (timeout, new errors, lag that doesn't fall, the gateway's sent rate
  dropping). Someone watches the dashboards; nobody types per-server
  commands.
- **Keep the gateway writing.** Each gateway must list more than one
  endpoint per shard (or sit behind a load balancer), so a batch never
  leaves it nowhere to write. Inserts into a restarting server fail and
  the exporter retries another endpoint.
- **Rollback.** Downgrade only works to a recent version and only before
  new features are used, so don't use new features, settings or data types
  until the whole cluster runs the new version and has run it for a while.

**Verify.** `SELECT version(), count() FROM clusterAllReplicas('<cluster>',
system.one) GROUP BY 1` shows one version; every replica writable with
`queue_size` near 0; the gateway's sent rate and the query latency SLO as
before.

## Backup and restore drill

**Why.** Replicas copy mistakes instantly: a bad `DELETE` or `DROP` reaches
every replica. Only a backup brings data back, and only a restore you've
practiced counts.

**Backup** (**tested** against this repo's local S3):

```sql
BACKUP TABLE otel.trace_entry TO S3('http://seaweedfs:8333/traces/backups/drill-1', 'demo', 'demo');

SELECT name, status, formatReadableSize(total_size) AS size, num_files,
       dateDiff('second', start_time, end_time) AS secs
FROM system.backups ORDER BY start_time DESC LIMIT 1;
```

In the test: `BACKUP_CREATED`, 960 KiB, 106 files. For whole databases use
`BACKUP DATABASE otel`; for a sharded cluster add `ON CLUSTER tracing` so
each shard backs up its slice; for daily backups use incremental ones
(`SETTINGS base_backup = S3('.../previous')`).

**Restore drill:** restore into a scratch database, never over live data,
and compare:

```sql
CREATE DATABASE IF NOT EXISTS drill;
RESTORE TABLE otel.trace_entry AS drill.trace_entry
  FROM S3('http://seaweedfs:8333/traces/backups/drill-1', 'demo', 'demo');
SELECT (SELECT count() FROM drill.trace_entry) AS restored, (SELECT count() FROM otel.trace_entry) AS live;
DROP DATABASE drill SYNC;
```

In the test: `RESTORED`, 10796 rows in both. The restored table is a new
replicated table with its own Keeper path; `DROP ... SYNC` removes that path
again.

**Real restore after a mistake:** restore into a scratch database as above,
check it, then copy the missing rows or partitions back
(`ALTER TABLE ... ATTACH PARTITION ... FROM`, [module 10](10-copying-data.md)).

**Prevent.** Schedule backups outside the cluster's own bucket and account;
alert when the newest successful backup is too old; run the restore drill
monthly.

## Gateway export queue filling, spans lost

**Symptom.** Export queue over half full or growing for minutes;
`enqueue_failed` or `send_failed` rising (`lost` in the health check).

**Impact.** Critical: spans that leave the gateway this way are gone, and
the apps don't know.

**Diagnose.** Is ClickHouse refusing or slow? Follow the order of
[module 12](12-operations.md): the gateway log (exporter errors name the
ClickHouse error), then [first five minutes](#first-five-minutes). Most
causes are on the ClickHouse side: [Keeper](#keeper-down-or-quorum-lost),
[read-only replicas](#replica-read-only-or-lagging),
[too many parts](#too-many-parts), [disk full](#local-disk-filling-up). If
ClickHouse is healthy and the queue still grows, the gateways can't keep up
with the incoming rate.

**Fix.** Fix the ClickHouse cause first. Then, if needed: more gateways
behind the load balancer (with tail sampling, behind a trace-id-aware
`loadbalancing` tier, [module 5](05-sampling.md)); bigger batches; more
`sending_queue` consumers. A schema mismatch (`code: 16, message: No such
column ...` in the log) is retried like any other error, so it fills the
queue and drops batches after `max_elapsed_time`: restore the column the
exporter expects ([module 8](08-data-model.md#schema-evolution-new-attributes-and-new-columns)).

**Prevent.** A persistent queue (`sending_queue.storage` with
`file_storage`) so a restart doesn't drop it; alert on the queue fill and on
any `lost`; capacity headroom from module 12.

## Read more

- [ClickHouse Keeper: recovering after losing quorum](https://clickhouse.com/docs/guides/oss/deployment-and-scaling/keeper)
- [ClickHouse: self-managed upgrade](https://clickhouse.com/docs/operations/update)
- [SYSTEM statements: DROP REPLICA, RESTART REPLICA, RESTORE REPLICA, FLUSH DISTRIBUTED](https://clickhouse.com/docs/sql-reference/statements/system)
- [KILL QUERY and KILL MUTATION](https://clickhouse.com/docs/sql-reference/statements/kill)
- [Manipulating partitions: MOVE, DROP, DROP DETACHED](https://clickhouse.com/docs/sql-reference/statements/alter/partition)
- [TTL for columns and tables](https://clickhouse.com/docs/engines/table-engines/mergetree-family/mergetree#table_engine-mergetree-ttl)
- [Backup and restore](https://clickhouse.com/docs/operations/backup)
- [System log table settings (`ttl`)](https://clickhouse.com/docs/operations/server-configuration-parameters/settings#query_log)
- [AWS: modify an EBS volume](https://docs.aws.amazon.com/ebs/latest/userguide/ebs-modify-volume.html)
- [AWS: extend the file system after resizing](https://docs.aws.amazon.com/ebs/latest/userguide/recognize-expanded-volume-linux.html)
- [AWS: instance store lifetime](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/instance-store-lifetime.html)

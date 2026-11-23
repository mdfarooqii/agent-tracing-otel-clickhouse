-- Module 10 lab: grow a sharded table from two shards to three.
--
-- Needs clickhouse-03 running (docs/tutorial/labs/compose.replication.yaml).
-- Run on clickhouse-01, from the repo root:
--   docker exec -i clickhouse-01 clickhouse-client --password demo --multiquery \
--     --format PrettyCompactMonoBlock < docs/tutorial/labs/add-shard.sql
--
-- The `grow` database stands in for the otel tables of a sharded cluster:
-- a local table per server plus a Distributed table, keyed by trace id.
-- Each "trace" here is three spans with the same TraceId.
-- In production you add the shard to the existing cluster's definition, and
-- the Distributed table follows it. Here the two layouts are two clusters
-- (lab_2shards, lab_3shards in clickhouse/cluster.xml), so the script
-- re-points the Distributed table instead.
-- Remove everything with:  DROP DATABASE grow ON CLUSTER lab_3shards SYNC;

CREATE DATABASE IF NOT EXISTS grow ON CLUSTER lab_3shards FORMAT Null;

-- 1. Two shards: a local table on clickhouse-01 and -02, a Distributed table
--    in front, and 1000 traces of 3 spans each.
CREATE TABLE grow.spans_local ON CLUSTER lab_2shards
    (TraceId String, SpanId UInt32, batch String)
ENGINE = MergeTree ORDER BY TraceId FORMAT Null;

CREATE TABLE grow.spans ON CLUSTER lab_2shards AS grow.spans_local
ENGINE = Distributed(lab_2shards, grow, spans_local, cityHash64(TraceId)) FORMAT Null;

INSERT INTO grow.spans
SELECT toString(intDiv(number, 3)), number % 3, 'before' FROM numbers(3000)
SETTINGS distributed_foreground_insert = 1;

SELECT 'two shards' AS step, shardNum() AS shard, count() AS spans
FROM grow.spans GROUP BY shard ORDER BY shard;

-- 2. Add the shard. First the local table on the new server: IF NOT EXISTS
--    makes the servers that have it skip it. Then route over three shards.
CREATE TABLE IF NOT EXISTS grow.spans_local ON CLUSTER lab_3shards
    (TraceId String, SpanId UInt32, batch String)
ENGINE = MergeTree ORDER BY TraceId FORMAT Null;

CREATE OR REPLACE TABLE grow.spans ON CLUSTER lab_3shards AS grow.spans_local
ENGINE = Distributed(lab_3shards, grow, spans_local, cityHash64(TraceId)) FORMAT Null;

-- 3. New traffic: 1000 new traces, plus one late span for each of 200 old
--    traces that were still in flight when the shard was added.
INSERT INTO grow.spans
SELECT toString(1000 + intDiv(number, 3)), number % 3, 'after' FROM numbers(3000)
SETTINGS distributed_foreground_insert = 1;

INSERT INTO grow.spans
SELECT toString(number), 3, 'after' FROM numbers(200)
SETTINGS distributed_foreground_insert = 1;

-- Where rows are: old rows didn't move; new rows use all three shards.
SELECT 'three shards' AS step, shardNum() AS shard,
       countIf(batch = 'before') AS before, countIf(batch = 'after') AS after
FROM grow.spans GROUP BY shard ORDER BY shard;

-- Traces with spans on more than one shard.
SELECT count() AS traces, countIf(shards > 1) AS split_across_shards
FROM (SELECT TraceId, uniqExact(shardNum()) AS shards FROM grow.spans GROUP BY TraceId);

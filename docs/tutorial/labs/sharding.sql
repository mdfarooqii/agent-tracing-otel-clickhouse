-- Lab: how a sharding key decides which shard a span lands on.
--
-- Uses the lab_2shards cluster from clickhouse/cluster.xml: the same two
-- servers, viewed as two shards. Run step by step in http://localhost:8123/play,
-- or all at once with:
--   docker exec -i clickhouse-01 clickhouse-client --password demo --multiquery < docs/tutorial/labs/sharding.sql

-- 1. One plain local table per shard, and two Distributed tables that route
--    rows to those shards: one by trace id, one at random.
CREATE DATABASE IF NOT EXISTS lab ON CLUSTER lab_2shards;

CREATE TABLE IF NOT EXISTS lab.spans_by_trace_local ON CLUSTER lab_2shards
(
    TraceId     String,
    SpanId      String,
    ServiceName LowCardinality(String),
    SpanName    LowCardinality(String),
    Timestamp   DateTime64(9)
)
ENGINE = MergeTree
ORDER BY (TraceId, Timestamp);

CREATE TABLE IF NOT EXISTS lab.spans_random_local ON CLUSTER lab_2shards
AS lab.spans_by_trace_local
ENGINE = MergeTree
ORDER BY (TraceId, Timestamp);

CREATE TABLE IF NOT EXISTS lab.spans_by_trace ON CLUSTER lab_2shards
AS lab.spans_by_trace_local
ENGINE = Distributed(lab_2shards, lab, spans_by_trace_local, cityHash64(TraceId));

CREATE TABLE IF NOT EXISTS lab.spans_random ON CLUSTER lab_2shards
AS lab.spans_random_local
ENGINE = Distributed(lab_2shards, lab, spans_random_local, rand());

-- 2. Copy the real spans in through both Distributed tables.
INSERT INTO lab.spans_by_trace
SELECT TraceId, SpanId, ServiceName, SpanName, Timestamp FROM otel.otel_traces
SETTINGS distributed_foreground_insert = 1;

INSERT INTO lab.spans_random
SELECT TraceId, SpanId, ServiceName, SpanName, Timestamp FROM otel.otel_traces
SETTINGS distributed_foreground_insert = 1;

-- 3. Both tables spread spans over both shards...
SELECT * FROM
(
    SELECT 'by trace id' AS sharding, shardNum() AS shard, count() AS spans, uniqExact(TraceId) AS traces
    FROM lab.spans_by_trace GROUP BY shard
    UNION ALL
    SELECT 'random' AS sharding, shardNum() AS shard, count() AS spans, uniqExact(TraceId) AS traces
    FROM lab.spans_random GROUP BY shard
)
ORDER BY sharding, shard
FORMAT PrettyCompact;

-- 4. ...but only the trace-id key keeps each trace whole on one shard.
SELECT
    'by trace id' AS sharding,
    count() AS traces,
    countIf(shards > 1) AS traces_split_across_shards
FROM (SELECT TraceId, uniqExact(shardNum()) AS shards FROM lab.spans_by_trace GROUP BY TraceId)
UNION ALL
SELECT 'random', count(), countIf(shards > 1)
FROM (SELECT TraceId, uniqExact(shardNum()) AS shards FROM lab.spans_random GROUP BY TraceId)
FORMAT PrettyCompact;

-- 5. Because the shard is a function of TraceId, a trace lookup can skip the
--    other shard. force_optimize_skip_unused_shards turns "could not skip" into
--    an error, so this succeeds on spans_by_trace. Try the same on spans_random:
--    it fails, because a random key gives ClickHouse no way to know the shard.
SELECT count() AS spans_in_trace
FROM lab.spans_by_trace
WHERE TraceId = (SELECT any(TraceId) FROM otel.otel_traces)
SETTINGS optimize_skip_unused_shards = 1, force_optimize_skip_unused_shards = 1
FORMAT PrettyCompact;

-- 6. Clean up.
-- DROP DATABASE lab ON CLUSTER lab_2shards SYNC;

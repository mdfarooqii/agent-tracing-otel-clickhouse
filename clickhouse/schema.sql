-- Trace schema: the stock OTel ClickHouse exporter table, plus a real column for
-- every org.* label and core GenAI attribute, and two derived tables.
--
--   * Cluster `tracing` (1 shard x 2 replicas), so no Distributed tables.
--   * Raw spans are kept for 72 hours; the per-minute rollup for a year.
--
-- Applied by the clickhouse-init service in compose.yaml. Idempotent.

CREATE DATABASE IF NOT EXISTS otel ON CLUSTER tracing;

CREATE TABLE IF NOT EXISTS otel.otel_traces ON CLUSTER tracing
(
    -- OTel span fields (stock exporter)
    Timestamp           DateTime64(9)                           CODEC(Delta, ZSTD(1)),
    TraceId             String                                  CODEC(ZSTD(1)),
    SpanId              String                                  CODEC(ZSTD(1)),
    ParentSpanId        String                                  CODEC(ZSTD(1)),
    TraceState          String                                  CODEC(ZSTD(1)),
    SpanName            LowCardinality(String)                  CODEC(ZSTD(1)),
    SpanKind            LowCardinality(String)                  CODEC(ZSTD(1)),
    ServiceName         LowCardinality(String)                  CODEC(ZSTD(1)),
    ResourceAttributes  Map(LowCardinality(String), String)     CODEC(ZSTD(1)),
    ScopeName           String                                  CODEC(ZSTD(1)),
    ScopeVersion        String                                  CODEC(ZSTD(1)),
    SpanAttributes      Map(LowCardinality(String), String)     CODEC(ZSTD(1)),
    Duration            UInt64                                  CODEC(ZSTD(1)),
    StatusCode          LowCardinality(String)                  CODEC(ZSTD(1)),
    StatusMessage       String                                  CODEC(ZSTD(1)),
    Events Nested (
        Timestamp  DateTime64(9),
        Name       LowCardinality(String),
        Attributes Map(LowCardinality(String), String)
    ) CODEC(ZSTD(1)),
    Links Nested (
        TraceId    String,
        SpanId     String,
        TraceState String,
        Attributes Map(LowCardinality(String), String)
    ) CODEC(ZSTD(1)),

    -- org.* labels on the resource. owner and service are set by the service (mandatory);
    -- region, platform, cluster and env are stamped by the gateway.
    org_owner            LowCardinality(String) MATERIALIZED ResourceAttributes['org.owner'],
    org_service          LowCardinality(String) MATERIALIZED ResourceAttributes['org.service'],
    org_region           LowCardinality(String) MATERIALIZED ResourceAttributes['org.region'],
    org_platform         LowCardinality(String) MATERIALIZED ResourceAttributes['org.platform'],
    org_cluster          LowCardinality(String) MATERIALIZED ResourceAttributes['org.cluster'],
    org_env              LowCardinality(String) MATERIALIZED ResourceAttributes['org.env'],

    -- org.* labels on spans (optional): tenant per request; request id and interface on entry spans.
    org_tenant           String                 MATERIALIZED SpanAttributes['org.tenant'],
    org_agent_interface  LowCardinality(String) MATERIALIZED SpanAttributes['org.agent.interface'],
    org_request_id       String                 MATERIALIZED SpanAttributes['org.request_id'],

    -- Hot OTel attributes
    http_route           LowCardinality(String) MATERIALIZED SpanAttributes['http.route'],
    http_status          UInt16                 MATERIALIZED toUInt16OrZero(SpanAttributes['http.response.status_code']),

    -- GenAI semantic conventions (OTel semconv-genai, status: Development)
    gen_ai_operation         LowCardinality(String) MATERIALIZED SpanAttributes['gen_ai.operation.name'],
    gen_ai_provider          LowCardinality(String) MATERIALIZED SpanAttributes['gen_ai.provider.name'],
    gen_ai_request_model     LowCardinality(String) MATERIALIZED SpanAttributes['gen_ai.request.model'],
    gen_ai_response_model    LowCardinality(String) MATERIALIZED SpanAttributes['gen_ai.response.model'],
    gen_ai_finish_reasons    String                 MATERIALIZED SpanAttributes['gen_ai.response.finish_reasons'],
    gen_ai_conversation_id   String                 MATERIALIZED SpanAttributes['gen_ai.conversation.id'],
    gen_ai_agent_name        LowCardinality(String) MATERIALIZED SpanAttributes['gen_ai.agent.name'],
    gen_ai_agent_id          LowCardinality(String) MATERIALIZED SpanAttributes['gen_ai.agent.id'],
    gen_ai_agent_version     LowCardinality(String) MATERIALIZED SpanAttributes['gen_ai.agent.version'],
    gen_ai_tool_name         LowCardinality(String) MATERIALIZED SpanAttributes['gen_ai.tool.name'],
    gen_ai_tool_type         LowCardinality(String) MATERIALIZED SpanAttributes['gen_ai.tool.type'],
    gen_ai_tokens_in         UInt32                 MATERIALIZED toUInt32OrZero(SpanAttributes['gen_ai.usage.input_tokens']),
    gen_ai_tokens_out        UInt32                 MATERIALIZED toUInt32OrZero(SpanAttributes['gen_ai.usage.output_tokens']),
    gen_ai_tokens_cache_read UInt32                 MATERIALIZED toUInt32OrZero(SpanAttributes['gen_ai.usage.cache_read.input_tokens']),
    gen_ai_tokens_reasoning  UInt32                 MATERIALIZED toUInt32OrZero(SpanAttributes['gen_ai.usage.reasoning.output_tokens']),

    INDEX idx_trace_id   TraceId                TYPE bloom_filter(0.001) GRANULARITY 1,
    INDEX idx_request_id org_request_id         TYPE bloom_filter(0.001) GRANULARITY 1,
    INDEX idx_tenant     org_tenant             TYPE bloom_filter(0.01)  GRANULARITY 1,
    INDEX idx_conv_id    gen_ai_conversation_id TYPE bloom_filter(0.001) GRANULARITY 1,
    INDEX idx_res_keys   mapKeys(ResourceAttributes)   TYPE bloom_filter(0.01) GRANULARITY 1,
    INDEX idx_res_vals   mapValues(ResourceAttributes) TYPE bloom_filter(0.01) GRANULARITY 1,
    INDEX idx_span_keys  mapKeys(SpanAttributes)       TYPE bloom_filter(0.01) GRANULARITY 1,
    INDEX idx_span_vals  mapValues(SpanAttributes)     TYPE bloom_filter(0.01) GRANULARITY 1,
    INDEX idx_duration   Duration               TYPE minmax GRANULARITY 1
)
ENGINE = ReplicatedMergeTree
PARTITION BY toDate(Timestamp)
ORDER BY (org_owner, org_service, SpanName, toDateTime(Timestamp))
TTL toDateTime(Timestamp) + INTERVAL 72 HOUR
SETTINGS ttl_only_drop_parts = 1;

CREATE TABLE IF NOT EXISTS otel.otel_traces_trace_id_ts ON CLUSTER tracing
(
    TraceId String,
    Start   DateTime,
    End     DateTime,
    INDEX idx_trace_id TraceId TYPE bloom_filter(0.01) GRANULARITY 1
)
ENGINE = ReplicatedMergeTree
PARTITION BY toDate(Start)
ORDER BY (TraceId, Start)
TTL Start + INTERVAL 72 HOUR
SETTINGS ttl_only_drop_parts = 1;

CREATE MATERIALIZED VIEW IF NOT EXISTS otel.otel_traces_trace_id_ts_mv ON CLUSTER tracing
TO otel.otel_traces_trace_id_ts AS
SELECT TraceId,
       min(Timestamp) AS Start,
       max(Timestamp) AS End
FROM otel.otel_traces
WHERE TraceId != ''
GROUP BY TraceId;

CREATE TABLE IF NOT EXISTS otel.trace_entry ON CLUSTER tracing
(
    Start                DateTime64(9),
    TraceId              String,
    org_request_id String,
    org_agent_interface   LowCardinality(String),
    org_owner             LowCardinality(String),
    org_service           LowCardinality(String),
    org_tenant            String,
    Duration             UInt64,
    StatusCode           LowCardinality(String),
    IsRoot               UInt8,
    INDEX idx_trace_id TraceId TYPE bloom_filter(0.001) GRANULARITY 1
)
ENGINE = ReplicatedReplacingMergeTree(IsRoot)
PARTITION BY toDate(Start)
ORDER BY (org_request_id, TraceId)
TTL toDateTime(Start) + INTERVAL 72 HOUR
SETTINGS ttl_only_drop_parts = 1;

CREATE MATERIALIZED VIEW IF NOT EXISTS otel.trace_entry_mv ON CLUSTER tracing
TO otel.trace_entry AS
SELECT Timestamp AS Start, TraceId,
       org_request_id, org_agent_interface,
       org_owner, org_service, org_tenant,
       Duration, StatusCode,
       ParentSpanId = '' AS IsRoot
FROM otel.otel_traces
WHERE org_request_id != '' OR ParentSpanId = '';

CREATE TABLE IF NOT EXISTS otel.span_red_1m ON CLUSTER tracing
(
    minute       DateTime,
    org_owner     LowCardinality(String),
    org_service   LowCardinality(String),
    SpanName     LowCardinality(String),
    calls        SimpleAggregateFunction(sum, UInt64),
    errors       SimpleAggregateFunction(sum, UInt64),
    duration_q   AggregateFunction(quantiles(0.5, 0.95, 0.99), UInt64)
)
ENGINE = ReplicatedAggregatingMergeTree
PARTITION BY toDate(minute)
ORDER BY (org_owner, org_service, SpanName, minute)
TTL minute + INTERVAL 1 YEAR
SETTINGS ttl_only_drop_parts = 1;

CREATE MATERIALIZED VIEW IF NOT EXISTS otel.span_red_1m_mv ON CLUSTER tracing
TO otel.span_red_1m AS
SELECT toStartOfMinute(Timestamp) AS minute,
       org_owner, org_service, SpanName,
       count()                       AS calls,
       countIf(StatusCode = 'Error') AS errors,
       quantilesState(0.5, 0.95, 0.99)(Duration) AS duration_q
FROM otel.otel_traces
GROUP BY minute, org_owner, org_service, SpanName;

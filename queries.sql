-- Run with ./stack.sh queries, or paste individual queries into
-- http://localhost:8123/play (user default, password demo) without the FORMAT line.

-- 1. Turns: one row per user turn, with outcome and duration.
SELECT
    Timestamp,
    TraceId,
    SpanAttributes['gen_ai.conversation.id'] AS conversation_id,
    org_service                              AS agent_service,
    SpanAttributes['org.agent.turn.index']   AS turn,
    StatusCode,
    StatusMessage,
    round(Duration / 1e6)                    AS ms
FROM otel.otel_traces
WHERE SpanName = 'agent_turn'
ORDER BY Timestamp DESC
LIMIT 20
FORMAT PrettyCompact;

-- 2. Per-agent latency and invocation count across all turns.
SELECT
    SpanAttributes['gen_ai.agent.name'] AS agent,
    count()                             AS invocations,
    round(avg(Duration) / 1e6)          AS avg_ms,
    round(quantile(0.95)(Duration) / 1e6) AS p95_ms,
    countIf(StatusCode = 'Error')       AS errors
FROM otel.otel_traces
WHERE SpanAttributes['gen_ai.operation.name'] = 'invoke_agent'
GROUP BY agent
ORDER BY invocations DESC
FORMAT PrettyCompact;

-- 3. LLM and tool calls, attributed to the agent that made them.
SELECT
    SpanAttributes['gen_ai.agent.name']     AS agent,
    SpanAttributes['gen_ai.operation.name'] AS op,
    if(op = 'chat', SpanAttributes['gen_ai.request.model'], SpanAttributes['gen_ai.tool.name']) AS target,
    count()                                 AS calls,
    round(avg(Duration) / 1e6)              AS avg_ms,
    countIf(StatusCode = 'Error')           AS errors
FROM otel.otel_traces
WHERE op IN ('chat', 'execute_tool')
GROUP BY agent, op, target
ORDER BY agent, op
FORMAT PrettyCompact;

-- 4. Failed turns: the deepest failing span is the root cause.
SELECT
    t.TraceId,
    t.SpanName,
    t.SpanAttributes['gen_ai.agent.name'] AS agent,
    t.SpanAttributes['error.type']        AS error_type,
    t.StatusMessage
FROM otel.otel_traces AS t
WHERE t.StatusCode = 'Error'
  AND t.SpanAttributes['gen_ai.operation.name'] = 'execute_tool'
ORDER BY t.Timestamp DESC
LIMIT 20
FORMAT PrettyCompact;

-- 5. Agent hand-off sequence per turn (multi-agent routing path).
SELECT
    TraceId,
    arrayStringConcat(groupArray(agent), ' -> ') AS path
FROM (
    SELECT TraceId, Timestamp, SpanAttributes['gen_ai.agent.name'] AS agent
    FROM otel.otel_traces
    WHERE SpanAttributes['gen_ai.operation.name'] = 'invoke_agent'
    ORDER BY TraceId, Timestamp
)
GROUP BY TraceId
LIMIT 20
FORMAT PrettyCompact;

-- 6. Labels each service sends. legacy-hr-api never appears: the gateway drops it
--    because org.owner and org.service are on its spans, not its resource.
SELECT
    ServiceName,
    org_owner,
    count()                                                                           AS spans,
    length(arrayFilter(k -> startsWith(k, 'org.'), mapKeys(any(ResourceAttributes)))) AS org_resource_labels,
    countIf(org_tenant != '')                                                         AS with_tenant,
    countIf(org_request_id != '')                                                     AS with_request_id,
    arrayFilter(k -> startsWith(k, 'org.') AND k NOT IN ('org.owner', 'org.service', 'org.region',
        'org.platform', 'org.cluster', 'org.env'),
        mapKeys(any(ResourceAttributes)))                                             AS labels_outside_schema
FROM otel.otel_traces
GROUP BY ServiceName, org_owner
ORDER BY ServiceName
FORMAT PrettyCompact;

-- 7. Service dependencies: which agent calls which API, by HTTP client span -> server span.
SELECT
    client.ServiceName                                AS caller,
    server.ServiceName                                AS callee,
    server.SpanName                                   AS endpoint,
    count()                                           AS calls,
    countIf(server.StatusCode = 'Error')              AS errors,
    round(quantile(0.95)(server.Duration) / 1e6)      AS p95_ms
FROM otel.otel_traces AS server
INNER JOIN otel.otel_traces AS client
    ON server.TraceId = client.TraceId AND server.ParentSpanId = client.SpanId
WHERE server.SpanKind = 'Server' AND client.ServiceName != server.ServiceName
GROUP BY caller, callee, endpoint
ORDER BY caller, callee
FORMAT PrettyCompact;

-- 8. Span tree of the most recent turn, across every service it touched.
--    To see a specific trace, replace the latest_turn query with its TraceId.
WITH
    (SELECT argMax(TraceId, Timestamp) FROM otel.otel_traces WHERE SpanName = 'agent_turn') AS latest_turn,
    spans AS (
        SELECT SpanId, ParentSpanId, SpanName, ServiceName, StatusCode, Duration, Timestamp,
               SpanAttributes['http.response.status_code'] AS http
        FROM otel.otel_traces
        WHERE TraceId = latest_turn
    ),
    d1 AS (SELECT SpanId FROM spans WHERE ParentSpanId = ''),
    d2 AS (SELECT SpanId FROM spans WHERE ParentSpanId IN d1),
    d3 AS (SELECT SpanId FROM spans WHERE ParentSpanId IN d2),
    d4 AS (SELECT SpanId FROM spans WHERE ParentSpanId IN d3),
    d5 AS (SELECT SpanId FROM spans WHERE ParentSpanId IN d4),
    d6 AS (SELECT SpanId FROM spans WHERE ParentSpanId IN d5)
SELECT
    repeat('  ', multiIf(SpanId IN d1, 0, SpanId IN d2, 1, SpanId IN d3, 2, SpanId IN d4, 3,
                         SpanId IN d5, 4, SpanId IN d6, 5, 6)) || SpanName AS span,
    ServiceName           AS service,
    StatusCode            AS status,
    http,
    round(Duration / 1e6) AS ms
FROM spans
ORDER BY Timestamp
FORMAT PrettyCompactMonoBlock;

-- 9. Replication check: run on both clickhouse-01 and clickhouse-02, counts should match.
SELECT hostName() AS host, count() AS spans FROM otel.otel_traces FORMAT PrettyCompact;

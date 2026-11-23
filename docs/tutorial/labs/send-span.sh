#!/usr/bin/env bash
# Module 8: send one span through the gateway (OTLP/HTTP on localhost:14318)
# with attributes the schema has never seen: a resource attribute
# org.cost_center and span attributes of four types.
#
# usage: docs/tutorial/labs/send-span.sh <trace-id: 32 hex chars> [span name]
set -euo pipefail

trace_id=${1:?usage: send-span.sh <trace-id: 32 hex chars> [span name]}
name=${2:-schema-demo}
start=$(python3 -c 'import time; print(time.time_ns())')
end=$((start + 5000000))

curl -s -o /dev/null -w "gateway answered HTTP %{http_code}\n" \
  http://localhost:14318/v1/traces -H 'Content-Type: application/json' -d @- <<JSON
{"resourceSpans": [{
  "resource": {"attributes": [
    {"key": "service.name",    "value": {"stringValue": "schema-demo"}},
    {"key": "org.owner",       "value": {"stringValue": "platform"}},
    {"key": "org.service",     "value": {"stringValue": "schema-demo"}},
    {"key": "org.cost_center", "value": {"stringValue": "cc-42"}}]},
  "scopeSpans": [{"scope": {"name": "schema-demo"}, "spans": [{
    "traceId": "$trace_id", "spanId": "00000000000000a1", "name": "$name", "kind": 1,
    "startTimeUnixNano": "$start", "endTimeUnixNano": "$end",
    "attributes": [
      {"key": "agent.retry_count", "value": {"intValue": "3"}},
      {"key": "agent.cached",      "value": {"boolValue": true}},
      {"key": "agent.score",       "value": {"doubleValue": 0.75}},
      {"key": "agent.tags",        "value": {"arrayValue": {"values": [
        {"stringValue": "a"}, {"stringValue": "b"}]}}}]}]}]}]}
JSON

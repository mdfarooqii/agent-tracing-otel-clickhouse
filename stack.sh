#!/usr/bin/env bash
# One-command control for the agent tracing stack.
#
#   ./stack.sh up                ClickHouse cluster, OTel gateway, and background agent traffic
#   ./stack.sh up --no-traffic   same, without the traffic loop
#   ./stack.sh down              stop everything; ClickHouse data is kept
#   ./stack.sh down --wipe       stop everything and delete ClickHouse data
#   ./stack.sh status            containers, traffic loop, spans per service
#   ./stack.sh demo              one round of traffic in the foreground
#   ./stack.sh queries           run the saved ClickHouse queries in queries.sql
#   ./stack.sh logs              follow the traffic loop's output
#
# TRAFFIC_INTERVAL (seconds, default 30) and TRAFFIC_TURNS (default 3) tune the loop.
set -euo pipefail
cd "$(dirname "$0")"

RUN_DIR=.run
PID_FILE=$RUN_DIR/traffic.pid
LOG_FILE=$RUN_DIR/traffic.log
VENV=agent/.venv
API_PORTS=(18081 18082 18083 18084)
TRAFFIC_INTERVAL=${TRAFFIC_INTERVAL:-30}
TRAFFIC_TURNS=${TRAFFIC_TURNS:-3}
COLIMA_SOCKET="$HOME/.colima/default/docker.sock"

ensure_docker() {
  if [[ -z "${DOCKER_HOST:-}" && -S "$COLIMA_SOCKET" ]]; then
    export DOCKER_HOST="unix://$COLIMA_SOCKET"
  fi
  if docker info >/dev/null 2>&1; then
    return
  fi
  if command -v colima >/dev/null; then
    echo "Starting Colima..."
    colima start
    export DOCKER_HOST="unix://$COLIMA_SOCKET"
  else
    echo "Docker is not running." >&2
    exit 1
  fi
}

ensure_venv() {
  if [[ -x $VENV/bin/python ]] && $VENV/bin/python -c 'import langgraph, opentelemetry.sdk' 2>/dev/null; then
    return
  fi
  # Packages come from PyPI; set PIP_INDEX_URL to use a mirror.
  echo "Creating $VENV..."
  "$(command -v python3.12 || command -v python3)" -m venv "$VENV"
  "$VENV/bin/pip" install -q -r agent/requirements.txt 2>&1 | sed -E 's#//[^@ ]+@#//***@#g'
  "$VENV/bin/python" -c 'import langgraph, opentelemetry.sdk'
}

traffic_running() {
  [[ -f $PID_FILE ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null
}

wait_for_gateway() {
  for _ in $(seq 60); do
    curl -sf http://localhost:13133 >/dev/null && return
    sleep 1
  done
  echo "OTel gateway did not become healthy:" >&2
  docker compose logs --tail 20 otel-gateway >&2
  exit 1
}

start_traffic() {
  if traffic_running; then
    echo "Traffic loop already running (pid $(cat "$PID_FILE"))."
    return
  fi
  mkdir -p "$RUN_DIR"
  # Own session, so closing the terminal or Ctrl-C does not stop it; ./stack.sh down does.
  (cd agent && exec .venv/bin/python -c 'import os, sys; os.setsid(); os.execv(sys.argv[1], sys.argv[1:])' \
    .venv/bin/python -u simulate.py --turns "$TRAFFIC_TURNS" --fail-turn 2 --loop "$TRAFFIC_INTERVAL") \
    </dev/null >>"$LOG_FILE" 2>&1 &
  echo $! >"$PID_FILE"
  echo "Traffic loop started (pid $!): a round of $TRAFFIC_TURNS turns per agent every ${TRAFFIC_INTERVAL}s."
}

stop_traffic() {
  if traffic_running; then
    local pid
    pid=$(cat "$PID_FILE")
    kill "$pid"
    for _ in $(seq 20); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 1
    done
    kill -9 "$pid" 2>/dev/null || true
    echo "Traffic loop stopped."
  fi
  rm -f "$PID_FILE"
  local port pids
  if command -v lsof >/dev/null; then
    for port in "${API_PORTS[@]}"; do
      pids=$(lsof -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null || true)
      [[ -n $pids ]] && kill $pids 2>/dev/null || true
    done
  else
    pkill -f 'apis.py --service' 2>/dev/null || true
  fi
}

print_endpoints() {
  cat <<EOF

Agent tracing stack is up.
  ClickHouse UI    http://localhost:8123/play   (user default, password demo)
  Replica 2 UI     http://localhost:8124/play
  OTel gateway     OTLP http://localhost:14318, gRPC localhost:14317
  Saved queries    ./stack.sh queries
Stop with: ./stack.sh down
EOF
}

up() {
  local traffic=1
  [[ "${1:-}" == "--no-traffic" ]] && traffic=0
  ensure_docker
  ensure_venv
  docker compose up -d
  wait_for_gateway
  if ((traffic)); then
    start_traffic
  fi
  print_endpoints
}

down() {
  ensure_docker
  stop_traffic
  if [[ "${1:-}" == "--wipe" ]]; then
    docker compose down -v
  else
    docker compose down
  fi
}

status() {
  ensure_docker
  docker compose ps -a --format 'table {{.Name}}\t{{.Status}}'
  if traffic_running; then
    echo "Traffic loop: running (pid $(cat "$PID_FILE"))"
  else
    echo "Traffic loop: stopped"
  fi
  if docker exec clickhouse-01 true 2>/dev/null; then
    docker exec clickhouse-01 clickhouse-client --password demo -q \
      "SELECT ServiceName, count() AS spans, max(Timestamp) AS latest FROM otel.otel_traces GROUP BY ServiceName ORDER BY ServiceName FORMAT PrettyCompact"
  fi
}

demo() {
  ensure_docker
  ensure_venv
  if traffic_running; then
    echo "The traffic loop is running and already uses the API ports; see ./stack.sh logs." >&2
    exit 1
  fi
  (cd agent && .venv/bin/python simulate.py --turns 5 --fail-turn 2)
}

queries() {
  ensure_docker
  docker exec -i clickhouse-01 clickhouse-client --password demo --multiquery <queries.sql
}

case "${1:-}" in
  up) shift; up "$@" ;;
  down) shift; down "$@" ;;
  status) status ;;
  demo) demo ;;
  queries) queries ;;
  logs) tail -f "$LOG_FILE" ;;
  *) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac

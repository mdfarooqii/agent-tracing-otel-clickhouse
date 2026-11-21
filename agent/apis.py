"""Temporary HTTP APIs that the agents' tools call, one process per service.

    .venv/bin/python apis.py --service kb-search-api

Each service sends a different set of org.* labels, to show how the gateway
and ClickHouse treat each case:

    kb-search-api   all mandatory resource labels; org.tenant and org.request_id on its entry span
    ticket-api      mandatory resource labels; org.request_id only (no tenant)
    pricing-api     mandatory labels plus org.cost_center, which is not in the label schema; fails 30% of calls
    legacy-hr-api   org.owner and org.service on the span instead of the resource; the gateway drops it

The entry-span labels arrive as W3C baggage from the calling agent.
"""

from __future__ import annotations

import argparse
import json
import os
import random
import re
import signal
import time
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Callable
from urllib.parse import parse_qs, urlparse

from opentelemetry import baggage, propagate
from opentelemetry.trace import SpanKind, Status, StatusCode

from telemetry import get_tracer, setup_tracing

KNOWLEDGE_BASE = {
    "trace": "A trace is the tree of spans for one request; a span is one timed operation.",
    "collector": "The collector receives OTLP, batches it, and exports it to a backend.",
    "clickhouse": "ClickHouse stores spans as rows; replicas share data through Keeper.",
    "refund": "Refunds over 500 USD need a manager's approval.",
    "laptop": "Laptop replacements are handled by the IT queue.",
}
EMPLOYEES = {
    "E1001": {"name": "Ana Silva", "department": "Finance"},
    "E1042": {"name": "Raj Patel", "department": "Engineering"},
    "E2210": {"name": "Mei Chen", "department": "Sales"},
}
PRICES = {"SKU-100": 120.0, "SKU-200": 480.0, "SKU-300": 35.5}


class HttpError(Exception):
    def __init__(self, status: int, message: str) -> None:
        super().__init__(message)
        self.status = status


@dataclass(frozen=True)
class Route:
    method: str
    template: str
    handler: Callable[[dict[str, str], dict[str, list[str]], Any], tuple[int, Any]]

    @property
    def pattern(self) -> re.Pattern[str]:
        return re.compile("^" + re.sub(r"\{(\w+)\}", r"(?P<\1>[^/]+)", self.template) + "$")


@dataclass(frozen=True)
class Service:
    port: int
    resource: dict[str, str]
    routes: list[Route]
    span_labels: tuple[str, ...] = ()
    span_attributes: dict[str, str] = field(default_factory=dict)


def _search(params: dict[str, str], query: dict[str, list[str]], body: Any) -> tuple[int, Any]:
    time.sleep(random.uniform(0.05, 0.25))
    if query.get("fail") == ["1"]:
        raise HttpError(504, "search backend timed out")
    text = (query.get("q") or [""])[0].lower()
    return 200, {"hits": [note for key, note in KNOWLEDGE_BASE.items() if key in text]}


def _create_ticket(params: dict[str, str], query: dict[str, list[str]], body: Any) -> tuple[int, Any]:
    with get_tracer().start_as_current_span(
        "INSERT tickets",
        kind=SpanKind.CLIENT,
        attributes={"db.system.name": "postgresql", "db.operation.name": "INSERT", "db.collection.name": "tickets"},
    ):
        time.sleep(random.uniform(0.02, 0.08))
    return 201, {"id": f"TCK-{random.randint(1000, 9999)}", "queue": (body or {}).get("queue", "general")}


def _price(params: dict[str, str], query: dict[str, list[str]], body: Any) -> tuple[int, Any]:
    time.sleep(random.uniform(0.03, 0.12))
    if random.random() < 0.3:
        raise HttpError(500, "pricing engine error")
    sku = params["sku"]
    if sku not in PRICES:
        raise HttpError(404, f"unknown sku {sku}")
    return 200, {"sku": sku, "price": PRICES[sku], "currency": "USD"}


def _employee(params: dict[str, str], query: dict[str, list[str]], body: Any) -> tuple[int, Any]:
    time.sleep(random.uniform(0.2, 0.5))
    employee = EMPLOYEES.get(params["employee_id"])
    if employee is None:
        raise HttpError(404, "employee not found")
    return 200, employee


COMMON_RESOURCE = {"service.namespace": "agent-tracing", "service.version": "1.0.0", "deployment.environment.name": "local"}

SERVICES = {
    "kb-search-api": Service(
        port=18081,
        resource={"org.owner": "search-platform", "org.service": "kb-search-api"},
        routes=[Route("GET", "/v1/search", _search)],
        span_labels=("org.tenant", "org.request_id"),
    ),
    "ticket-api": Service(
        port=18082,
        resource={"org.owner": "itsm", "org.service": "ticket-api"},
        routes=[Route("POST", "/v1/tickets", _create_ticket)],
        span_labels=("org.request_id",),
    ),
    "pricing-api": Service(
        port=18083,
        resource={"org.owner": "revenue-eng", "org.service": "pricing-api", "org.cost_center": "cc-4512"},
        routes=[Route("GET", "/v1/prices/{sku}", _price)],
        span_labels=("org.tenant", "org.request_id"),
    ),
    "legacy-hr-api": Service(
        port=18084,
        resource={},
        routes=[Route("GET", "/employees/{employee_id}", _employee)],
        span_attributes={"org.owner": "people-tech", "org.service": "legacy-hr-api"},
    ),
}


def make_handler(service: Service) -> type[BaseHTTPRequestHandler]:
    tracer = get_tracer()

    class Handler(BaseHTTPRequestHandler):
        def _handle(self) -> None:
            url = urlparse(self.path)
            route, params = None, {}
            for candidate in service.routes:
                match = candidate.pattern.match(url.path)
                if candidate.method == self.command and match:
                    route, params = candidate, match.groupdict()
                    break

            if os.environ.get("STRIP_TRACE_HEADERS") == "1":
                # Simulates a proxy between environments that drops traceparent and baggage.
                parent = propagate.extract({})
            else:
                parent = propagate.extract({key.lower(): value for key, value in self.headers.items()})
            attributes: dict[str, Any] = {
                "http.request.method": self.command,
                "url.path": url.path,
                "url.scheme": "http",
                "server.port": service.port,
                **service.span_attributes,
            }
            if route is not None:
                attributes["http.route"] = route.template
            for label in service.span_labels:
                value = baggage.get_baggage(label, parent)
                if value:
                    attributes[label] = value

            name = f"{self.command} {route.template}" if route else self.command
            with tracer.start_as_current_span(
                name, context=parent, kind=SpanKind.SERVER, attributes=attributes,
                record_exception=False, set_status_on_exception=False,
            ) as span:
                length = int(self.headers.get("Content-Length") or 0)
                body = json.loads(self.rfile.read(length)) if length else None
                try:
                    if route is None:
                        raise HttpError(404, "no such route")
                    status, payload = route.handler(params, parse_qs(url.query), body)
                except HttpError as exc:
                    status, payload = exc.status, {"error": str(exc)}
                    if exc.status >= 500:
                        span.set_attribute("error.type", str(exc.status))
                        span.set_status(Status(StatusCode.ERROR, str(exc)))
                span.set_attribute("http.response.status_code", status)
                data = json.dumps(payload).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

        do_GET = _handle
        do_POST = _handle

        def log_message(self, format: str, *args: Any) -> None:
            pass

    return Handler


def _stop(*_: Any) -> None:
    raise SystemExit(0)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--service", choices=sorted(SERVICES), required=True)
    args = parser.parse_args()

    service = SERVICES[args.service]
    provider = setup_tracing(args.service, {**COMMON_RESOURCE, **service.resource})
    server = ThreadingHTTPServer(("127.0.0.1", service.port), make_handler(service))
    signal.signal(signal.SIGTERM, _stop)
    print(f"{args.service} listening on http://127.0.0.1:{service.port}", flush=True)
    try:
        server.serve_forever()
    except (KeyboardInterrupt, SystemExit):
        pass
    finally:
        server.server_close()
        provider.shutdown()


if __name__ == "__main__":
    main()

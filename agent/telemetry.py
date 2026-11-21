"""OpenTelemetry setup, and a LangChain callback handler that turns LangGraph runs into spans.

Span hierarchy produced for one turn:

    agent_turn                         created by the caller, one trace per turn
      invoke_workflow <graph>          the LangGraph run
        invoke_agent <node>            one per agent node execution
          chat <model>                 each chat model call
          execute_tool <tool>          each tool call
"""

from __future__ import annotations

import json
import os
import threading
import urllib.error
import urllib.request
from typing import Any
from urllib.parse import urlparse
from uuid import UUID

from langchain_core.callbacks import BaseCallbackHandler
from langchain_core.outputs import LLMResult
from opentelemetry import context, propagate, trace
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.semconv.schemas import Schemas
from opentelemetry.trace import Span, SpanKind, Status, StatusCode, Tracer

SCHEMA_URL = Schemas.V1_44_0.value


def setup_tracing(service_name: str, attributes: dict[str, str]) -> TracerProvider:
    """Register a tracer provider for one process, exporting OTLP over HTTP.

    The endpoint comes from OTEL_EXPORTER_OTLP_ENDPOINT. OTEL_RESOURCE_ATTRIBUTES
    is still merged in, so labels can be overridden without code changes.
    """
    os.environ.setdefault("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:14318")
    resource = Resource.create({"service.name": service_name, **attributes}, schema_url=SCHEMA_URL)
    provider = TracerProvider(resource=resource)
    provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter()))
    trace.set_tracer_provider(provider)
    return provider


def get_tracer() -> Tracer:
    return trace.get_tracer("agent-tracing", "0.1.0", schema_url=SCHEMA_URL)


class ApiError(RuntimeError):
    pass


def call_api(method: str, url: str, route: str, body: Any = None, timeout_s: float = 5.0) -> Any:
    """Call a JSON HTTP API in an HTTP client span, propagating trace context and baggage."""
    parsed = urlparse(url)
    with get_tracer().start_as_current_span(
        f"{method} {route}",
        kind=SpanKind.CLIENT,
        attributes={
            "http.request.method": method,
            "url.full": url,
            "url.template": route,
            "server.address": parsed.hostname,
            "server.port": parsed.port,
        },
        record_exception=False,
        set_status_on_exception=False,
    ) as span:
        headers = {"Content-Type": "application/json"}
        propagate.inject(headers)
        data = json.dumps(body).encode() if body is not None else None
        request = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(request, timeout=timeout_s) as response:
                span.set_attribute("http.response.status_code", response.status)
                return json.loads(response.read() or b"null")
        except urllib.error.HTTPError as exc:
            span.set_attribute("http.response.status_code", exc.code)
            span.set_attribute("error.type", str(exc.code))
            span.set_status(Status(StatusCode.ERROR))
            raise ApiError(f"{parsed.netloc}{route} returned {exc.code}") from None
        except OSError as exc:
            span.set_attribute("error.type", type(exc).__qualname__)
            span.set_status(Status(StatusCode.ERROR, str(exc)))
            raise ApiError(f"{parsed.netloc}{route} unreachable: {exc}") from None


def _clean(attributes: dict[str, Any]) -> dict[str, Any]:
    return {key: value for key, value in attributes.items() if value is not None}


class LangGraphTracer(BaseCallbackHandler):
    """Creates spans for the graph run, agent nodes, chat model calls and tool calls.

    LangGraph also emits callback runs for internal plumbing (channel writes,
    routing functions). Those get no span; their children attach to the
    nearest span above them.

    Prompt, completion and tool content is never recorded.
    """

    def __init__(
        self,
        tracer: Tracer,
        turn_span: Span,
        *,
        conversation_id: str,
        agents: dict[str, str],
        agent_version: str,
        tenant: str | None = None,
    ) -> None:
        self._tracer = tracer
        self._turn_span = turn_span
        self._conversation_id = conversation_id
        self._agents = agents
        self._agent_version = agent_version
        self._tenant = tenant
        self._workflow = "graph"
        self._spans: dict[UUID, Span] = {}
        self._owned: set[UUID] = set()
        self._tool_contexts: dict[UUID, object] = {}
        self._lock = threading.Lock()

    def _parent(self, parent_run_id: UUID | None) -> Span:
        if parent_run_id is None:
            return self._turn_span
        with self._lock:
            return self._spans.get(parent_run_id, self._turn_span)

    def _start(
        self,
        run_id: UUID,
        parent_run_id: UUID | None,
        name: str,
        kind: SpanKind,
        attributes: dict[str, Any],
    ) -> Span:
        parent = self._parent(parent_run_id)
        span = self._tracer.start_span(
            name,
            context=trace.set_span_in_context(parent),
            kind=kind,
            attributes=_clean({**attributes, "org.tenant": self._tenant}),
        )
        with self._lock:
            self._spans[run_id] = span
            self._owned.add(run_id)
        return span

    def _alias(self, run_id: UUID, parent_run_id: UUID | None) -> None:
        parent = self._parent(parent_run_id)
        with self._lock:
            self._spans[run_id] = parent

    def _owned_span(self, run_id: UUID) -> Span | None:
        with self._lock:
            return self._spans.get(run_id) if run_id in self._owned else None

    def _finish(self, run_id: UUID, error: BaseException | None = None) -> None:
        with self._lock:
            span = self._spans.pop(run_id, None)
            owned = run_id in self._owned
            self._owned.discard(run_id)
        if span is None or not owned:
            return
        if error is not None:
            span.record_exception(error)
            span.set_attribute("error.type", type(error).__qualname__)
            span.set_status(Status(StatusCode.ERROR, str(error)))
        span.end()

    def on_chain_start(
        self,
        serialized: dict[str, Any],
        inputs: dict[str, Any],
        *,
        run_id: UUID,
        parent_run_id: UUID | None = None,
        tags: list[str] | None = None,
        metadata: dict[str, Any] | None = None,
        **kwargs: Any,
    ) -> None:
        metadata = metadata or {}
        name = kwargs.get("name") or (serialized or {}).get("name") or "graph"
        node = metadata.get("langgraph_node")

        if parent_run_id is None:
            self._workflow = name
            self._start(
                run_id,
                None,
                f"invoke_workflow {name}",
                SpanKind.INTERNAL,
                {
                    "gen_ai.operation.name": "invoke_workflow",
                    "gen_ai.conversation.id": self._conversation_id,
                    "org.agent.workflow": name,
                },
            )
        elif node in self._agents and name == node:
            self._start(
                run_id,
                parent_run_id,
                f"invoke_agent {node}",
                SpanKind.INTERNAL,
                {
                    "gen_ai.operation.name": "invoke_agent",
                    "gen_ai.agent.name": node,
                    "gen_ai.agent.id": f"{self._workflow}.{node}",
                    "gen_ai.agent.version": self._agent_version,
                    "gen_ai.conversation.id": self._conversation_id,
                    "org.agent.role": self._agents[node],
                    "org.agent.step": metadata.get("langgraph_step"),
                },
            )
        else:
            self._alias(run_id, parent_run_id)

    def on_chain_end(self, outputs: dict[str, Any], *, run_id: UUID, **kwargs: Any) -> None:
        self._finish(run_id)

    def on_chain_error(self, error: BaseException, *, run_id: UUID, **kwargs: Any) -> None:
        self._finish(run_id, error)

    def on_chat_model_start(
        self,
        serialized: dict[str, Any],
        messages: list[list[Any]],
        *,
        run_id: UUID,
        parent_run_id: UUID | None = None,
        tags: list[str] | None = None,
        metadata: dict[str, Any] | None = None,
        **kwargs: Any,
    ) -> None:
        metadata = metadata or {}
        model = metadata.get("ls_model_name") or kwargs.get("name") or (serialized or {}).get("name") or "unknown"
        self._start(
            run_id,
            parent_run_id,
            f"chat {model}",
            SpanKind.CLIENT,
            {
                "gen_ai.operation.name": "chat",
                "gen_ai.provider.name": metadata.get("ls_provider") or "unknown",
                "gen_ai.request.model": model,
                "gen_ai.conversation.id": self._conversation_id,
                "gen_ai.agent.name": metadata.get("langgraph_node"),
            },
        )

    def on_llm_end(self, response: LLMResult, *, run_id: UUID, **kwargs: Any) -> None:
        span = self._owned_span(run_id)
        if span is not None and response.generations and response.generations[0]:
            generation = response.generations[0][0]
            message = getattr(generation, "message", None)
            usage = getattr(message, "usage_metadata", None) or {}
            if "input_tokens" in usage:
                span.set_attribute("gen_ai.usage.input_tokens", usage["input_tokens"])
            if "output_tokens" in usage:
                span.set_attribute("gen_ai.usage.output_tokens", usage["output_tokens"])
            cache_read = (usage.get("input_token_details") or {}).get("cache_read")
            if cache_read is not None:
                span.set_attribute("gen_ai.usage.cache_read.input_tokens", cache_read)
            reasoning = (usage.get("output_token_details") or {}).get("reasoning")
            if reasoning is not None:
                span.set_attribute("gen_ai.usage.reasoning.output_tokens", reasoning)
            response_metadata = getattr(message, "response_metadata", None) or {}
            if response_metadata.get("model_name"):
                span.set_attribute("gen_ai.response.model", response_metadata["model_name"])
            finish_reason = (generation.generation_info or {}).get("finish_reason") or response_metadata.get(
                "finish_reason"
            )
            if finish_reason:
                span.set_attribute("gen_ai.response.finish_reasons", [finish_reason])
        self._finish(run_id)

    def on_llm_error(self, error: BaseException, *, run_id: UUID, **kwargs: Any) -> None:
        self._finish(run_id, error)

    def on_tool_start(
        self,
        serialized: dict[str, Any],
        input_str: str,
        *,
        run_id: UUID,
        parent_run_id: UUID | None = None,
        tags: list[str] | None = None,
        metadata: dict[str, Any] | None = None,
        inputs: dict[str, Any] | None = None,
        **kwargs: Any,
    ) -> None:
        metadata = metadata or {}
        name = (serialized or {}).get("name") or kwargs.get("name") or "tool"
        span = self._start(
            run_id,
            parent_run_id,
            f"execute_tool {name}",
            SpanKind.INTERNAL,
            {
                "gen_ai.operation.name": "execute_tool",
                "gen_ai.tool.name": name,
                "gen_ai.tool.type": "function",
                "gen_ai.tool.call.id": kwargs.get("tool_call_id"),
                "gen_ai.agent.name": metadata.get("langgraph_node"),
            },
        )
        # LangChain runs the tool body in a copy of the current context, so the
        # tool span must be current here for its HTTP calls to become children.
        self._tool_contexts[run_id] = context.attach(trace.set_span_in_context(span))

    def _detach_tool(self, run_id: UUID) -> None:
        token = self._tool_contexts.pop(run_id, None)
        if token is not None:
            context.detach(token)

    def on_tool_end(self, output: Any, *, run_id: UUID, **kwargs: Any) -> None:
        self._detach_tool(run_id)
        self._finish(run_id)

    def on_tool_error(self, error: BaseException, *, run_id: UUID, **kwargs: Any) -> None:
        self._detach_tool(run_id)
        self._finish(run_id, error)

"""Run a multi-turn conversation through one agent service, one trace per turn.

    .venv/bin/python run.py --agent support-agent --turns 3
    .venv/bin/python run.py --agent support-agent --turns 3 --fail-turn 2

Tools call the APIs in apis.py, so start those first (simulate.py does both).
"""

from __future__ import annotations

import argparse
import random
import uuid

from langchain_core.messages import HumanMessage
from opentelemetry import baggage, context
from opentelemetry.trace import SpanKind, Status, StatusCode

from agents import AGENTS
from telemetry import LangGraphTracer, get_tracer, setup_tracing

AGENT_VERSION = "0.1.0"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--agent", choices=sorted(AGENTS), default="support-agent")
    parser.add_argument("--turns", type=int, default=3)
    parser.add_argument("--fail-turn", type=int, default=0, help="Make the support researcher's search fail on this turn.")
    args = parser.parse_args()

    spec = AGENTS[args.agent]
    provider = setup_tracing(
        args.agent,
        {
            "service.namespace": "agent-tracing",
            "service.version": AGENT_VERSION,
            "deployment.environment.name": "local",
            "org.service": args.agent,
            "org.owner": spec.owner,
        },
    )
    tracer = get_tracer()
    graph = spec.build()
    conversation_id = str(uuid.uuid4())
    print(f"{args.agent}  conversation {conversation_id}")

    for index in range(1, args.turns + 1):
        question = spec.questions[(index - 1) % len(spec.questions)]
        tenant = random.choice(spec.tenants) if spec.tenants else None
        request_id = str(uuid.uuid4())

        # Downstream APIs read these from W3C baggage for their own entry spans.
        ctx = baggage.set_baggage("org.request_id", request_id)
        if tenant:
            ctx = baggage.set_baggage("org.tenant", tenant, ctx)
        token = context.attach(ctx)

        attributes = {
            "gen_ai.conversation.id": conversation_id,
            "org.agent.turn.id": str(uuid.uuid4()),
            "org.agent.turn.index": index,
            "org.request_id": request_id,
            "org.agent.interface": spec.interface,
        }
        if tenant:
            attributes["org.tenant"] = tenant
        try:
            with tracer.start_as_current_span(
                "agent_turn",
                kind=SpanKind.INTERNAL,
                attributes=attributes,
                record_exception=False,
                set_status_on_exception=False,
            ) as turn:
                trace_id = format(turn.get_span_context().trace_id, "032x")
                handler = LangGraphTracer(
                    tracer,
                    turn,
                    conversation_id=conversation_id,
                    agents=spec.roles,
                    agent_version=AGENT_VERSION,
                    tenant=tenant,
                )
                try:
                    result = graph.invoke(
                        {
                            **spec.turn_state,
                            "messages": [HumanMessage(question)],
                            "fail_tool": index == args.fail_turn,
                        },
                        config={"callbacks": [handler], "configurable": {"thread_id": conversation_id}},
                    )
                    turn.set_status(Status(StatusCode.OK))
                    print(f"{args.agent}  turn {index}  trace {trace_id}  {result.get('answer')}")
                except Exception as exc:
                    turn.record_exception(exc)
                    turn.set_attribute("error.type", type(exc).__qualname__)
                    turn.set_status(Status(StatusCode.ERROR, str(exc)))
                    print(f"{args.agent}  turn {index}  trace {trace_id}  failed: {exc}")
        finally:
            context.detach(token)

    provider.shutdown()


if __name__ == "__main__":
    main()

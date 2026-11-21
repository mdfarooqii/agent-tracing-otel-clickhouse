"""The agent fleet: three agent services, each with its own org.* labels and tools.

    support-agent   supervisor -> researcher, writer     kb-search-api
    hr-agent        single hr_assistant agent            legacy-hr-api, ticket-api
    sales-agent     sales_planner -> quoter              pricing-api (flaky, retried)

Owners, interfaces and tenants are made-up demo values.
"""

from __future__ import annotations

import random
from dataclasses import dataclass
from typing import Annotated, Any, Callable, TypedDict

from langchain_core.messages import AIMessage, BaseMessage, HumanMessage, SystemMessage
from langchain_core.runnables import RunnableConfig
from langgraph.checkpoint.memory import InMemorySaver
from langgraph.graph import END, START, StateGraph
from langgraph.graph.message import add_messages

import graph as support
from graph import chat_model
from tools import create_ticket, get_price, lookup_employee


def _question(state: dict[str, Any]) -> str:
    return next(m.content for m in reversed(state["messages"]) if isinstance(m, HumanMessage))


class HrState(TypedDict):
    messages: Annotated[list[BaseMessage], add_messages]
    answer: str
    fail_tool: bool


def hr_assistant(state: HrState, config: RunnableConfig) -> dict[str, Any]:
    question = _question(state)
    employee = lookup_employee.invoke({"employee_id": random.choice(["E1001", "E1042", "E2210"])}, config)
    reply = chat_model("fake-hr", f"{employee['name']} works in {employee['department']}.", 0.3).invoke(
        [SystemMessage("Answer HR questions using the employee record."), HumanMessage(question)],
        config,
    )
    ticket = create_ticket.invoke({"summary": question, "queue": "hr"}, config)
    answer = f"{reply.content} Opened {ticket}."
    return {"answer": answer, "messages": [AIMessage(answer, name="hr_assistant")]}


def build_hr_graph():
    graph = StateGraph(HrState)
    graph.add_node("hr_assistant", hr_assistant)
    graph.add_edge(START, "hr_assistant")
    graph.add_edge("hr_assistant", END)
    return graph.compile(checkpointer=InMemorySaver(), name="hr_helpdesk")


class SalesState(TypedDict):
    messages: Annotated[list[BaseMessage], add_messages]
    next: str
    quote: str
    answer: str
    fail_tool: bool


def sales_planner(state: SalesState, config: RunnableConfig) -> dict[str, Any]:
    decision = "FINISH" if state.get("quote") else "quoter"
    chat_model("fake-planner", decision, 0.1).invoke(
        [SystemMessage("Route to quoter or FINISH."), HumanMessage(_question(state))],
        config,
    )
    return {"next": decision, "answer": state.get("quote", "")}


def quoter(state: SalesState, config: RunnableConfig) -> dict[str, Any]:
    skus = random.sample(["SKU-100", "SKU-200", "SKU-300"], k=2)
    prices = {sku: get_price.invoke({"sku": sku}, config) for sku in skus}
    total = sum(prices.values())
    reply = chat_model("fake-quoter", f"Quote: {', '.join(skus)} for {total:.2f} USD.", 0.4).invoke(
        [SystemMessage("Write a short quote."), HumanMessage(str(prices))],
        config,
    )
    return {"quote": reply.content, "messages": [AIMessage(reply.content, name="quoter")]}


def build_sales_graph():
    graph = StateGraph(SalesState)
    graph.add_node("sales_planner", sales_planner)
    graph.add_node("quoter", quoter)
    graph.add_edge(START, "sales_planner")
    graph.add_conditional_edges("sales_planner", lambda state: state["next"], {"quoter": "quoter", "FINISH": END})
    graph.add_edge("quoter", "sales_planner")
    return graph.compile(checkpointer=InMemorySaver(), name="sales_quoting")


@dataclass(frozen=True)
class AgentSpec:
    owner: str
    interface: str
    # Empty: the agent does not send org.tenant, which is optional.
    tenants: tuple[str, ...]
    roles: dict[str, str]
    build: Callable[[], Any]
    questions: tuple[str, ...]
    # Per-turn fields cleared at the start of each turn; messages persist across turns.
    turn_state: dict[str, Any]


AGENTS = {
    "support-agent": AgentSpec(
        owner="ai-platform",
        interface="slack",
        tenants=("acme_corp", "globex", "initech"),
        roles=support.AGENTS,
        build=support.build_graph,
        questions=("What is a trace?", "What does the collector do?", "How does ClickHouse keep replicas in sync?"),
        turn_state={"notes": "", "answer": ""},
    ),
    "hr-agent": AgentSpec(
        owner="people-tech",
        interface="web",
        tenants=("acme_corp", "umbrella"),
        roles={"hr_assistant": "agent"},
        build=build_hr_graph,
        questions=("Which department is my manager in?", "I need a new laptop.", "How do I update my address?"),
        turn_state={"answer": ""},
    ),
    "sales-agent": AgentSpec(
        owner="sales-eng",
        interface="api",
        tenants=(),
        roles={"sales_planner": "supervisor", "quoter": "worker"},
        build=build_sales_graph,
        questions=("Quote two items for a new customer.", "What would a starter bundle cost?"),
        turn_state={"quote": "", "answer": ""},
    ),
}

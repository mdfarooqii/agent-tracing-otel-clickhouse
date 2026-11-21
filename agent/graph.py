"""A supervisor multi-agent graph.

Each turn the supervisor routes to the researcher, then the writer, then
finishes. Chat models are offline fakes with simulated latency, so the graph
runs without an LLM endpoint. Replace `chat_model` to use a real model; the
tracing handler does not change.
"""

from __future__ import annotations

import random
import time
from typing import Annotated, Any, TypedDict

from langchain_core.language_models.fake_chat_models import FakeListChatModel
from langchain_core.messages import AIMessage, BaseMessage, HumanMessage, SystemMessage
from langchain_core.outputs import ChatResult
from langchain_core.runnables import RunnableConfig
from langgraph.checkpoint.memory import InMemorySaver
from langgraph.graph import END, START, StateGraph
from langgraph.graph.message import add_messages

from tools import count_words, search_knowledge_base

# Node name -> role. The tracing handler creates an invoke_agent span for each.
AGENTS = {"supervisor": "supervisor", "researcher": "worker", "writer": "worker"}


class TurnState(TypedDict):
    messages: Annotated[list[BaseMessage], add_messages]
    next: str
    notes: str
    answer: str
    fail_tool: bool


class FakeChatModel(FakeListChatModel):
    """FakeListChatModel with latency and usage metadata, shaped like a real provider response.

    Token counts are word counts, not real tokens. The system prompt is reported
    as cached input, the way providers report a reused prompt prefix.
    """

    latency_s: float = 0.3

    def _call(self, *args: Any, **kwargs: Any) -> str:
        time.sleep(random.uniform(0.5, 1.5) * self.latency_s)
        return super()._call(*args, **kwargs)

    def _generate(self, messages: list[BaseMessage], *args: Any, **kwargs: Any) -> ChatResult:
        result = super()._generate(messages, *args, **kwargs)
        message = result.generations[0].message
        input_tokens = sum(len(str(m.content).split()) for m in messages)
        output_tokens = len(str(message.content).split())
        cached = sum(len(str(m.content).split()) for m in messages if isinstance(m, SystemMessage))
        message.usage_metadata = {
            "input_tokens": input_tokens,
            "output_tokens": output_tokens,
            "total_tokens": input_tokens + output_tokens,
            "input_token_details": {"cache_read": cached},
        }
        message.response_metadata = {"model_name": self.name, "finish_reason": "stop"}
        return result


def chat_model(model: str, reply: str, latency_s: float) -> FakeChatModel:
    return FakeChatModel(name=model, responses=[reply], latency_s=latency_s)


def _question(state: TurnState) -> str:
    return next(m.content for m in reversed(state["messages"]) if isinstance(m, HumanMessage))


def supervisor(state: TurnState, config: RunnableConfig) -> dict[str, Any]:
    if not state.get("notes"):
        decision = "researcher"
    elif not state.get("answer"):
        decision = "writer"
    else:
        decision = "FINISH"
    chat_model("fake-supervisor", decision, 0.1).invoke(
        [SystemMessage("Route the turn to researcher, writer, or FINISH."), HumanMessage(_question(state))],
        config,
    )
    return {"next": decision}


def researcher(state: TurnState, config: RunnableConfig) -> dict[str, Any]:
    question = _question(state)
    notes = search_knowledge_base.invoke(
        {"query": question, "simulate_failure": state.get("fail_tool", False)}, config
    )
    summary = chat_model("fake-researcher", f"Relevant notes: {notes}", 0.4).invoke(
        [SystemMessage("Summarise the notes for the writer."), HumanMessage(f"{question}\n\n{notes}")],
        config,
    )
    return {"notes": summary.content, "messages": [AIMessage(summary.content, name="researcher")]}


def writer(state: TurnState, config: RunnableConfig) -> dict[str, Any]:
    draft = chat_model("fake-writer", f"Answer: {state['notes']}", 0.5).invoke(
        [SystemMessage("Write a short answer from the notes."), HumanMessage(state["notes"])],
        config,
    )
    words = count_words.invoke({"text": draft.content}, config)
    answer = f"{draft.content} ({words} words)"
    return {"answer": answer, "messages": [AIMessage(answer, name="writer")]}


def build_graph():
    graph = StateGraph(TurnState)
    graph.add_node("supervisor", supervisor)
    graph.add_node("researcher", researcher)
    graph.add_node("writer", writer)
    graph.add_edge(START, "supervisor")
    graph.add_conditional_edges(
        "supervisor",
        lambda state: state["next"],
        {"researcher": "researcher", "writer": "writer", "FINISH": END},
    )
    graph.add_edge("researcher", "supervisor")
    graph.add_edge("writer", "supervisor")
    return graph.compile(checkpointer=InMemorySaver(), name="support_supervisor")

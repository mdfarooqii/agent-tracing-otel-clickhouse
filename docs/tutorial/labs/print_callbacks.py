"""Module 2 lab: print the raw LangChain callbacks for one support-agent turn.

    cd agent && .venv/bin/python ../docs/tutorial/labs/print_callbacks.py

These are the events LangGraphTracer in telemetry.py turns into spans. No spans
are exported here; only the knowledge-base API is started, because the
researcher's tool calls it.
"""

from __future__ import annotations

import subprocess
import sys
import time
from typing import Any
from uuid import UUID

sys.path.insert(0, ".")

from langchain_core.callbacks import BaseCallbackHandler  # noqa: E402
from langchain_core.messages import HumanMessage  # noqa: E402

from graph import build_graph  # noqa: E402

ids: dict[UUID, int] = {}


def short(run_id: UUID | None) -> str:
    if run_id is None:
        return "-"
    return f"#{ids.setdefault(run_id, len(ids) + 1)}"


class Printer(BaseCallbackHandler):
    def _show(self, event: str, name: str, run_id: UUID, parent_run_id: UUID | None, metadata: dict | None) -> None:
        node = (metadata or {}).get("langgraph_node", "")
        print(f"{event:<20} {short(run_id):>4} parent={short(parent_run_id):>4}  node={node:<11} {name}")

    def on_chain_start(self, serialized: Any, inputs: Any, *, run_id: UUID, parent_run_id: UUID | None = None,
                       metadata: dict | None = None, **kwargs: Any) -> None:
        self._show("on_chain_start", kwargs.get("name") or "?", run_id, parent_run_id, metadata)

    def on_chat_model_start(self, serialized: Any, messages: Any, *, run_id: UUID, parent_run_id: UUID | None = None,
                            metadata: dict | None = None, **kwargs: Any) -> None:
        name = (metadata or {}).get("ls_model_name") or kwargs.get("name") or (serialized or {}).get("name", "?")
        self._show("on_chat_model_start", name, run_id, parent_run_id, metadata)

    def on_tool_start(self, serialized: Any, input_str: str, *, run_id: UUID, parent_run_id: UUID | None = None,
                      metadata: dict | None = None, **kwargs: Any) -> None:
        self._show("on_tool_start", (serialized or {}).get("name", "?"), run_id, parent_run_id, metadata)


api = subprocess.Popen([sys.executable, "apis.py", "--service", "kb-search-api"])
time.sleep(2)
try:
    build_graph().invoke(
        {"messages": [HumanMessage("What is a span?")], "notes": "", "answer": "", "fail_tool": False},
        config={"callbacks": [Printer()], "configurable": {"thread_id": "lab"}},
    )
finally:
    api.terminate()

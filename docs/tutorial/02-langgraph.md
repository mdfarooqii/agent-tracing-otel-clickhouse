# Module 2: LangChain, LangGraph and callbacks (35 min)

## Idea

### LangChain in one paragraph

LangChain gives every building block (chat model, tool, prompt, chain) the
same interface, the **Runnable**: `.invoke(input, config)`. The `config` is
passed down to every Runnable called inside, and it carries **callbacks**.
Every Runnable reports `on_*_start` and `on_*_end` (or `_error`) to those
callbacks, with a `run_id` for itself and a `parent_run_id` for whoever called
it. That's a ready-made call tree, and it's what we turn into spans.

| Callback | Fired for | Span we create |
|---|---|---|
| `on_chain_start` / `_end` | The graph, each node, internal plumbing | `invoke_workflow` for the root, `invoke_agent` for agent nodes, nothing for plumbing |
| `on_chat_model_start` / `on_llm_end` | Each chat model call | `chat <model>` with token usage |
| `on_tool_start` / `_end` | Each tool call | `execute_tool <tool>` |
| `on_*_error` | Any failure | Same span, with status `ERROR` and an `exception` event |

### LangGraph in one paragraph

LangGraph builds an agent as a **state machine**:

- **State**: a typed dict shared by all nodes. Here it's `TurnState`, with
  `messages`, `notes`, `answer` and `next`. **Reducers** say how updates merge;
  `add_messages` appends rather than replaces.
- **Nodes**: plain functions `state -> partial update`. Here: `supervisor`,
  `researcher`, `writer`.
- **Edges**: fixed (`researcher -> supervisor`) or **conditional** (the
  supervisor's `next` field picks the next node, or `END`).
- **Checkpointer** + `thread_id`: saves the state after every step, so the
  next turn of the same conversation continues where the last one stopped.
- **Supervisor pattern**: one node routes; worker nodes do the work and hand
  control back.

LangGraph runs the graph in **steps** (supersteps). Each node run is a chain
run whose callback metadata includes `langgraph_node` and `langgraph_step`.
That metadata is how the tracer tells an agent node from internal plumbing.

### How callbacks become spans

`LangGraphTracer` in `agent/telemetry.py` keeps a map `run_id -> span`:

1. On start, look up the span for `parent_run_id` (or the turn span if there's
   none), and start a child span under it.
2. For plumbing runs (routing functions, channel writes), don't create a span;
   map their `run_id` to the parent's span (`_alias`), so their children still
   attach to the right place.
3. On end, close the span; on error, record the exception and set `ERROR`.

There's one subtlety with **tool calls that make HTTP requests**. Callbacks
only report the tree; they don't make our span "current". LangChain runs the
tool body in a copy of the current context, so `on_tool_start` attaches the
tool span to the context (`context.attach(...)`). The HTTP client span in
`call_api` then becomes a child of the tool span, and `traceparent` carries it
to the API. Without that, the API spans would hang off the turn span instead.

### Where does the trace start?

Not in LangGraph. `run.py` opens an `agent_turn` span (the root) for each user
turn, puts tenant and request id into baggage, and passes the tracer in
`config={"callbacks": [handler]}`. The graph run becomes `invoke_workflow`
under it.

## Remember it

> **LangChain shouts "I started, I finished" with a run id and a parent id.
> The tracer just listens and writes a span for each shout that matters.**

And: **state = whiteboard, node = worker, edge = "who's next", checkpointer =
saving the whiteboard between turns.**

## In this repo

- `agent/graph.py`: the support agent: `StateGraph(TurnState)`, three nodes,
  conditional edges, and `InMemorySaver`. `FakeChatModel` fakes latency and
  `usage_metadata`, so the graph runs without an LLM key.
- `agent/agents.py`: all three agents (`support-agent`, `hr-agent`,
  `sales-agent`) with owner, interface, tenants and node roles. `turn_state`
  resets per-turn fields, since the checkpointer would otherwise carry the
  previous turn's answer into the next turn.
- `agent/telemetry.py`, `LangGraphTracer`: the callbacks-to-spans mapping.
- `agent/run.py`: the turn span, baggage, and `graph.invoke(...)` with the
  tracer as a callback.

## Lab (15 min)

1. See the raw callbacks for one turn (pause traffic first so port 18081 is free):

   ```bash
   ./stack.sh traffic off
   cd agent && .venv/bin/python ../docs/tutorial/labs/print_callbacks.py
   ```

   ```text
   on_chain_start         #1 parent=   -  node=            support_supervisor
   on_chain_start         #2 parent=  #1  node=supervisor  supervisor
   on_chat_model_start    #3 parent=  #2  node=supervisor  fake-supervisor
   on_chain_start         #4 parent=  #2  node=supervisor  RunnableCallable
   on_chain_start         #5 parent=  #1  node=researcher  researcher
   on_tool_start          #6 parent=  #5  node=researcher  search_knowledge_base
   on_chat_model_start    #7 parent=  #5  node=researcher  fake-researcher
   on_chain_start         #8 parent=  #1  node=supervisor  supervisor
   ...
   ```

   Match each line to the span tree from module 0. Run `#1` is the root (no
   parent), so it becomes `invoke_workflow support_supervisor`. `#4` is the
   routing function, plumbing, so it gets no span.

2. Run one agent by itself and find its traces:

   ```bash
   .venv/bin/python simulate.py --turns 2      # starts the APIs, runs all three agents
   ```

   ```sql
   SELECT ServiceName, SpanName, count() FROM otel.otel_traces
   WHERE Timestamp > now() - INTERVAL 2 MINUTE AND SpanName LIKE 'invoke_agent%'
   GROUP BY ServiceName, SpanName ORDER BY ServiceName;
   ```

   Then `./stack.sh traffic on` again.

3. See a failed tool. The background loop makes turn 2 of the support agent
   fail its search:

   ```sql
   SELECT ServiceName, SpanName, StatusMessage, SpanAttributes['error.type'] AS error
   FROM otel.otel_traces WHERE StatusCode = 'Error'
   ORDER BY Timestamp DESC LIMIT 10;
   ```

   Pick one failed trace and list it. The error starts at the API and is
   recorded again by each layer it passes through on the way up; the earlier
   supervisor step, which didn't fail, stays `Unset`:

   ```text
   support-agent  agent_turn                          Error  ApiError
   support-agent  invoke_workflow support_supervisor  Error  ApiError
   support-agent  invoke_agent supervisor             Unset
   support-agent  chat fake-supervisor                Unset
   support-agent  invoke_agent researcher             Error  ApiError
   support-agent  execute_tool search_knowledge_base  Error  ApiError
   support-agent  GET /v1/search                      Error  504
   kb-search-api  GET /v1/search                      Error  504     search backend timed out
   ```

## Explain it back

> "LangGraph models an agent as a state machine: nodes are functions, edges
> pick the next node, and a checkpointer keeps state per conversation thread.
> Every node, model and tool call is a LangChain Runnable, and Runnables report
> start and end events to callbacks with a run id and a parent run id. Our
> callback handler maps those events to OpenTelemetry spans: the root becomes
> `invoke_workflow`, agent nodes become `invoke_agent`, model calls become
> `chat`, tools become `execute_tool`. The tool span is made current so the
> HTTP calls it makes, and the APIs behind them, join the same trace."

## Check yourself

<details><summary>Why not create a span for every <code>on_chain_start</code>?</summary>

LangGraph emits chain runs for internal plumbing (routing functions, channel
writes). Spans for those add noise and cost without telling you anything about
the agent. The tracer skips them but keeps their children attached to the
nearest real span.
</details>

<details><summary>If you swap <code>FakeChatModel</code> for a real OpenAI or Anthropic model, what changes in the tracer?</summary>

Nothing. The tracer reads model name, provider and token usage from the
callback's metadata and the `LLMResult`, which real chat models fill in the
same way. You'd likely see real `gen_ai.provider.name` values instead of
`unknown`.
</details>

<details><summary>What would the trace look like without <code>context.attach</code> in <code>on_tool_start</code>?</summary>

The `GET /v1/search` client span, and the API's server span, would become
children of `agent_turn` (the context's current span) instead of
`execute_tool search_knowledge_base`. The trace would still be connected, but
you couldn't tell which tool made which call.
</details>

## Read more

- [LangChain callbacks reference: `BaseCallbackHandler`](https://github.com/langchain-ai/langchain/blob/master/libs/core/langchain_core/callbacks/base.py)
- [LangGraph overview](https://docs.langchain.com/oss/python/langgraph/overview)
- [LangGraph graph API (state, nodes, edges, reducers)](https://docs.langchain.com/oss/python/langgraph/graph-api)
- [LangGraph persistence (checkpointers and threads)](https://docs.langchain.com/oss/python/langgraph/persistence)
- [LangGraph multi-agent systems](https://docs.langchain.com/oss/python/langchain/multi-agent)
- [OpenTelemetry Python: context](https://opentelemetry-python.readthedocs.io/en/latest/api/context.html)

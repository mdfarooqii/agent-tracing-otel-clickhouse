# Module 3: GenAI semantic conventions (55 min)

## Why this matters

In [module 2](02-langgraph.md) you saw the tracer write spans named
`invoke_agent supervisor`, `chat fake-writer` and `execute_tool count_words`.
Those names, and the labels on each span, weren't invented by this repo. They
come from a public, shared rulebook called the **GenAI semantic conventions**.
This module explains that rulebook: why it exists, which labels go on which
span, and how those labels answer real questions such as "how many tokens did
this conversation cost?" and "which agent is slow?".

What you'll be able to do after this module:

- Explain what semantic conventions are, and why standard attribute names
  matter more than good attribute names.
- Look at any GenAI span in this repo and say what kind of operation it is,
  and which attributes it should carry.
- Explain tokens, cached tokens, turns, sessions (conversations) and evals,
  and query them in ClickHouse.

## Key terms

Spans, traces, attributes, resources and span kinds (`CLIENT`, `SERVER`,
`INTERNAL`) were covered in [module 1](01-otel-core.md); tokens, tools and
agents in [module 2](02-langgraph.md). These are the new words.

| Term | Plain meaning |
|---|---|
| Semantic conventions (semconv) | OpenTelemetry's shared dictionary of span names, attribute names and allowed values for common kinds of work. The **GenAI** part covers generative AI: models that produce text from a prompt, and the agents built on them. |
| Namespace | The prefix of an attribute name, such as `gen_ai.` or `http.`. It groups related names and prevents clashes. |
| Operation name | The attribute `gen_ai.operation.name`. It says what kind of GenAI work a span records: `chat`, `invoke_agent`, `execute_tool`, `invoke_workflow` and a few others. |
| Schema URL | A web address that names the exact version of the conventions a piece of telemetry follows. |
| Stability level | How settled a part of the conventions is. *Stable* names won't change; *development* names may. |
| Provider | Who serves the model, for example a model vendor's API. Here it's the fake model, reported as `fakechatmodel`. |
| Prompt cache | A provider feature that remembers a prompt prefix it has seen before. Reused tokens are cheaper. |
| Finish reason | Why the model stopped writing, for example `stop` (it finished normally) or because it hit a length limit. |
| Session, conversation | A series of turns with one user, tied together by `gen_ai.conversation.id`. |
| Eval (evaluation) | A score of answer *quality* (correct, safe, helpful), usually produced after the turn. |

## Idea

### The running example

We'll follow the same request as modules 0 to 2. A user of the **support
agent** asks *"What is a trace?"*, the first turn of a new conversation. The
supervisor routes to the researcher, the researcher searches the knowledge
base and summarizes, the supervisor routes to the writer, the writer drafts
an answer and counts its words, and the supervisor finishes. That's 5 agent
steps, 5 LLM calls and 2 tool calls, all inside one trace.

Every attribute in this module is shown on a span from that request.

### What semantic conventions are, and why they matter

**The problem.** Imagine three teams each add tracing to their own AI agent.
Each team picks reasonable names for "which model did we call?":

```text
team A:   llm.model      = "model-x"
team B:   model_name     = "model-x"
team C:   ai.model.id    = "model-x"
```

None of these is wrong. But now:

- A dashboard of "calls per model" has to know all three names, and breaks
  when team D picks a fourth.
- A question across teams ("which model costs us the most?") needs a
  translation table in every query.
- An observability tool can't show a nice "LLM calls" screen, because it
  can't tell which spans are LLM calls.
- Swapping one tracing library for another changes every name, so every
  dashboard and alert breaks.

**The fix.** Everyone agrees on one dictionary. **Semantic conventions**
(often shortened to **semconv**) are OpenTelemetry's shared dictionary. For
common kinds of work, such as HTTP requests, database queries, messaging and
GenAI, they say:

- what to **name the span** (for example `chat {model}`),
- which **attribute names** to use (for example `gen_ai.request.model`),
- which **values** are allowed (for example `chat`, not `Chat` or `llm_call`),
- and which **span kind** to use.

If every team calls the model attribute `gen_ai.request.model`, one dashboard
works for every team, every library, and every backend that understands
OpenTelemetry. "Semantic" just means "about meaning": the conventions fix
what each name *means*, so that a name means the same thing everywhere.

You've already met another set of conventions in this repo: the HTTP ones.
`call_api` in `agent/telemetry.py` uses `http.request.method`,
`http.response.status_code` and `url.full`. Those come from the HTTP
conventions, exactly as the `gen_ai.*` names come from the GenAI conventions.

### Three facts about semantic conventions

1. **They're versioned.** Each release of the conventions has a **schema
   URL**, a web address that names the version. This repo uses
   `https://opentelemetry.io/schemas/1.44.0`. Telemetry says which version it
   follows, so a backend could, in principle, translate names that were later
   renamed. In `agent/telemetry.py`:

   ```python
   SCHEMA_URL = Schemas.V1_44_0.value
   ```

   It's passed to both `Resource.create(...)` and `get_tracer(...)`, so
   every span is stamped "I follow version 1.44.0".

2. **They have stability levels.** The HTTP conventions are *stable*: the
   names won't change. **The GenAI conventions are still in *development***:
   names can change between releases. A real example: the attribute
   `gen_ai.system` (which provider) was replaced by `gen_ai.provider.name`.
   So pin the version you emit (that's what the schema URL does), and expect
   to migrate some names one day. `clickhouse/schema.sql` says the same in a
   comment above the GenAI columns: `status: Development`.

3. **Custom attributes go in your own namespace.** The conventions own
   prefixes such as `gen_ai.` and `http.`. If you invent your own attribute,
   say `gen_ai.agent.role`, a future release might define that exact name
   with a different meaning. That's why this repo puts its own labels under
   `org.*` (`org.tenant`, `org.agent.role`, `org.agent.turn.index`, and the
   `org.owner` and `org.service` labels from [module 0](00-setup.md) and
   [module 1](01-otel-core.md#resource-who-produced-the-spans)). No official
   name will ever start with `org.`, so they can't collide.

> **Quick check:** You want a "customer tier" label on every agent span. Why
> not call it `gen_ai.customer.tier`?
>
> <details><summary>Answer</summary>
>
> The `gen_ai.` prefix belongs to the conventions; a future release could
> define that name with a different meaning. Use your own namespace:
> `org.customer.tier`.
> </details>

### The four operations this repo uses

The single most important GenAI attribute is **`gen_ai.operation.name`**. It
says what kind of GenAI work a span records. It drives the span name, the
span kind, and which other attributes belong on the span.

Think of it as the "type of parcel" box on a shipping label: once you know
the parcel type, you know which other fields to look for.

The four operations this repo writes, from the outside in:

| Operation | What it means | Span name | Kind | Who creates it here |
|---|---|---|---|---|
| `invoke_workflow` | Running a whole multi-step workflow (the LangGraph graph) | `invoke_workflow {workflow}` | `INTERNAL` | `on_chain_start`, for the outermost run |
| `invoke_agent` | Running one agent (one agent node) | `invoke_agent {gen_ai.agent.name}` | `INTERNAL` when the agent runs in the same process; `CLIENT` when you call a remote agent over the network | `on_chain_start`, for agent nodes |
| `chat` | One call to a chat model | `chat {gen_ai.request.model}` | `CLIENT` | `on_chat_model_start` |
| `execute_tool` | Running one tool | `execute_tool {gen_ai.tool.name}` | `INTERNAL` | `on_tool_start` |

Why is `chat` a `CLIENT` span? A chat call normally leaves your process: it's
a network request to the provider's API. `CLIENT` says "I called something
outside myself". The fake model in this repo runs in-process, but it's built to
look exactly like a real one, so the tracer still uses `CLIENT`. The agent and
tool spans record work inside the agent process, so they're `INTERNAL`.

The conventions define a few more operations that this repo doesn't produce:
`embeddings` (turn text into vectors), `retrieval` (fetch documents for the
model to read), `create_agent`, `generate_content` and `text_completion`. The
installed `opentelemetry-semantic-conventions` package (0.66b2) lists all
nine: `chat`, `generate_content`, `text_completion`, `embeddings`,
`retrieval`, `create_agent`, `invoke_agent`, `execute_tool`,
`invoke_workflow`.

> **Quick check:** The researcher's tool makes an HTTP call. Which of the
> spans under `invoke_agent researcher` are `CLIENT` spans?
>
> <details><summary>Answer</summary>
>
> `chat fake-researcher` (a model call normally leaves the process) and the
> client-side `GET /v1/search`. The `execute_tool` span itself is `INTERNAL`:
> it records the tool function running inside the agent.
> </details>

### Which span gets which attribute

> Remember from [module 2](02-langgraph.md#what-a-callback-is): each GenAI
> span is opened by one callback (`on_chain_start`, `on_chat_model_start`,
> `on_tool_start`), so the attributes are whatever that callback can see.

Here is every `gen_ai.*` attribute this repo writes, and which spans carry it.
It's taken straight from `LangGraphTracer` in `agent/telemetry.py`, and checked
against real spans in ClickHouse.

| Attribute | Meaning | `invoke_workflow` | `invoke_agent` | `chat` | `execute_tool` |
|---|---|:-:|:-:|:-:|:-:|
| `gen_ai.operation.name` | Which of the four operations this is | yes | yes | yes | yes |
| `gen_ai.conversation.id` | Which conversation (session) this belongs to | yes | yes | yes | |
| `gen_ai.agent.name` | The agent's name: the LangGraph node name | | yes | yes | yes |
| `gen_ai.agent.id` | A unique id for the agent: `{graph}.{node}`, such as `support_supervisor.researcher` | | yes | | |
| `gen_ai.agent.version` | The agent code's version (`AGENT_VERSION = "0.1.0"` in `run.py`) | | yes | | |
| `gen_ai.provider.name` | Who serves the model | | | yes | |
| `gen_ai.request.model` | The model you *asked* for | | | yes | |
| `gen_ai.response.model` | The model that *actually answered* | | | yes | |
| `gen_ai.response.finish_reasons` | Why the model stopped, as a list | | | yes | |
| `gen_ai.usage.*` | Token counts (next section) | | | yes | |
| `gen_ai.tool.name` | The tool's name | | | | yes |
| `gen_ai.tool.type` | The kind of tool. Always `function` here | | | | yes |

A few things worth noticing:

- **Request model vs response model.** You might ask for a model alias and
  get a specific dated version back. Recording both tells you what you asked
  for and what you actually got. With the fake model, they're the same.
- **`gen_ai.agent.name` on chat and tool spans.** The tracer copies the node
  name (from LangGraph's `langgraph_node` metadata) onto chat and tool spans
  too. That's a practical choice: you can group LLM and tool calls by agent
  with a simple `GROUP BY`, without walking up the span tree to the parent
  `invoke_agent` span. Query 3 in `queries.sql` does exactly that.
- **Tool spans have no conversation id.** `on_tool_start` doesn't set it. To
  find a tool span's conversation, go through its trace (every span in a trace
  belongs to the same turn, and the turn's spans carry the id).
- **`gen_ai.tool.call.id` is in the code but not in the data.** The tracer
  sets it from `tool_call_id`, which LangChain only fills in when a model
  asked for the tool through a structured "tool call". In this demo, nodes
  call tools directly (`search_knowledge_base.invoke({...}, config)`), so the
  value is empty, and `_clean()` drops empty attributes before the span is
  created.
- **Errors.** When a span fails, the tracer also sets `error.type` (for
  example `ApiError`). That's a general OpenTelemetry attribute, not a GenAI
  one, so it has no `gen_ai.` prefix.

Every span the tracer creates also gets `org.tenant` (when the turn has a
tenant). `invoke_workflow` gets `org.agent.workflow`, and `invoke_agent` gets
`org.agent.role` (`supervisor` or `worker`) and `org.agent.step` (LangGraph's
step number). These are the repo's own labels, in its own namespace.

### One request, span by span

Here is the real trace of our request, as stored in ClickHouse: turn 1 of a
support-agent conversation for the tenant `globex`. Ids are shortened, and
`org.tenant = globex` (on every agent span) is left out to save space. Every
turn 1 of the support agent asks the same question and gets the same canned
replies, so the token numbers below are the same in every turn-1 trace (lab
step 1 finds one for you).

```text
agent_turn                                   INTERNAL   created by run.py
  gen_ai.conversation.id   = 1b531786-...
  org.agent.turn.index     = 1
  org.agent.interface      = slack
│
└── invoke_workflow support_supervisor       INTERNAL
      gen_ai.operation.name  = invoke_workflow
      gen_ai.conversation.id = 1b531786-...
      org.agent.workflow     = support_supervisor
    │
    ├── invoke_agent supervisor              INTERNAL
    │     gen_ai.operation.name  = invoke_agent
    │     gen_ai.agent.name      = supervisor
    │     gen_ai.agent.id        = support_supervisor.supervisor
    │     gen_ai.agent.version   = 0.1.0
    │     gen_ai.conversation.id = 1b531786-...
    │     org.agent.role         = supervisor
    │     org.agent.step         = 1
    │   │
    │   └── chat fake-supervisor             CLIENT
    │         gen_ai.operation.name               = chat
    │         gen_ai.agent.name                   = supervisor
    │         gen_ai.provider.name                = fakechatmodel
    │         gen_ai.request.model                = fake-supervisor
    │         gen_ai.response.model               = fake-supervisor
    │         gen_ai.response.finish_reasons      = ["stop"]
    │         gen_ai.usage.input_tokens           = 12
    │         gen_ai.usage.cache_read.input_tokens = 8
    │         gen_ai.usage.output_tokens          = 1
    │         gen_ai.conversation.id              = 1b531786-...
    │
    ├── invoke_agent researcher              INTERNAL   (agent.id = support_supervisor.researcher, role = worker, step 2)
    │   ├── execute_tool search_knowledge_base   INTERNAL
    │   │     gen_ai.operation.name = execute_tool
    │   │     gen_ai.agent.name     = researcher
    │   │     gen_ai.tool.name      = search_knowledge_base
    │   │     gen_ai.tool.type      = function
    │   │   └── GET /v1/search  (client, then the kb-search-api server span: HTTP conventions, no gen_ai.*)
    │   └── chat fake-researcher             CLIENT     input 26, cache_read 6, output 18
    │
    ├── invoke_agent supervisor              INTERNAL   step 3
    │   └── chat fake-supervisor             CLIENT     input 12, cache_read 8, output 1
    │
    ├── invoke_agent writer                  INTERNAL   (agent.id = support_supervisor.writer, role = worker, step 4)
    │   ├── chat fake-writer                 CLIENT     input 25, cache_read 7, output 19
    │   └── execute_tool count_words         INTERNAL   tool.name = count_words, tool.type = function
    │
    └── invoke_agent supervisor              INTERNAL   step 5
        └── chat fake-supervisor             CLIENT     input 12, cache_read 8, output 1
```

How to read it:

- **Read the operation name first.** It tells you what kind of span you're
  looking at, and therefore which other attributes to expect.
- **Identity lives on `invoke_agent`.** Name, id and version say *which*
  agent ran, and which release of its code.
- **Money lives on `chat`.** Only chat spans have tokens. The supervisor reads
  12 tokens and writes just 1: its reply is a single routing word such as
  `researcher` or `FINISH`.
- **Actions live on `execute_tool`.** The tool name says what the agent *did*.
  The HTTP spans below it use the HTTP conventions instead, because they're
  HTTP requests, not GenAI operations.
- **The conversation id appears on the root span and on all workflow, agent
  and chat spans.** That's what ties this turn to the other turns of the same
  conversation.
- **`org.agent.step` is 1 to 5** because this is the first turn. On later
  turns of the same conversation the numbers keep climbing, because LangGraph's
  checkpointer carries the step counter over
  ([module 2](02-langgraph.md#under-the-hood-steps-and-the-checkpointer)).

Where do these values come from? The tracer reads them from what LangChain
hands its callbacks: the model name from the `ls_model_name` metadata, the
provider from `ls_provider`, the agent name from `langgraph_node`, and the
tokens, response model and finish reason from the model's reply (the
`LLMResult` passed to `on_llm_end`). It never reads the prompt or the answer.

### Token usage: where the money is

**Why.** LLM providers bill per token, and agents make many LLM calls per
turn. Token counts are how you answer "what does a turn cost?", "which agent
is the expensive one?" and "is our prompt cache working?".

**What.** These attributes go on `chat` spans:

| Attribute | Meaning | Set by this repo? |
|---|---|---|
| `gen_ai.usage.input_tokens` | Tokens the model read (the prompt), as billed for this call | yes |
| `gen_ai.usage.output_tokens` | Tokens the model wrote (the reply) | yes |
| `gen_ai.usage.cache_read.input_tokens` | Input tokens served from the provider's prompt cache (cheaper) | yes |
| `gen_ai.usage.cache_creation.input_tokens` | Input tokens written into the cache for next time | no (the fake model doesn't report it) |
| `gen_ai.usage.reasoning.output_tokens` | Hidden "thinking" tokens, for reasoning models | only if the model reports them; the fake model doesn't |

A **prompt cache** works like this. Every call from the supervisor starts with
the same system message ("Route the turn to researcher, writer, or FINISH.").
A provider with a prompt cache recognizes that repeated beginning and charges
less for it. The fake model imitates this: it reports the system message's
words as cached. That's why the supervisor's chat span says
`input_tokens = 12` and `cache_read.input_tokens = 8`: 8 words of system
message plus the 4 words of "What is a trace?".

Two important rules:

1. **Cached tokens are part of the input, not extra.** `cache_read = 8` means
   "8 of the 12 input tokens came from the cache". Don't add them together.
2. **Tokens live on `chat` spans only.** To get the total for an agent, a
   turn or a conversation, *sum* the chat spans below it. Never copy totals
   onto the parent `invoke_agent` or `agent_turn` span. If you did, any query
   that sums tokens over a trace would count them twice.

> **Watch out with real providers.** Providers don't agree on whether their
> own "input tokens" figure already includes the cached tokens. Some report
> one total with the cached part inside it; others report cached tokens as a
> separate number next to a smaller "input" figure. The conventions ask for
> `gen_ai.usage.input_tokens` to be the full input, cached tokens included,
> so instrumentation for the second kind of provider has to add the parts
> together. Check your provider's usage fields before trusting a cache ratio.

For our request, summing the five chat spans gives 87 input tokens (37 of
them cached) and 40 output tokens. That sum is a query, not an attribute (lab
step 3).

> **Quick check:** A provider reports "200 input, 800 cached" as two separate
> numbers. What do you record?
>
> <details><summary>Answer</summary>
>
> `input_tokens = 1000` and `cache_read.input_tokens = 800`. The input is
> the full prompt; the cache figure is a breakdown of it, priced differently.
> </details>

In this repo the fake model reports **word counts as token counts** (see
`FakeChatModel` in `agent/graph.py`). The numbers are realistic in shape but
not in size. With a real model, the same attributes would carry real counts,
and the tracer wouldn't change.

### Turns, sessions and evals

These three ideas sit *above* individual spans. They're about how a user
experiences the agent.

```text
Session / conversation   gen_ai.conversation.id = 1b531786-...   many turns, minutes to days
├── Turn 1   one trace, root span agent_turn   "What is a trace?"
├── Turn 2   another trace                     "What does the collector do?"
└── Turn 3   another trace                     "How does ClickHouse keep replicas in sync?"
    Evals: scores attached later to a turn or a chat span ("was this answer good?")
```

**Turn.** One user message and the agent's complete response to it. In this
repo, **one turn is one trace**, rooted at the `agent_turn` span that
`run.py` creates. A turn has a clear start and end, so it can be timed,
sampled and debugged as a unit. Each turn also gets its own
`org.agent.turn.id` and `org.agent.turn.index` (1, 2, 3, ...) on the
`agent_turn` span. The background traffic runs three turns per conversation
(`TRAFFIC_TURNS=3` in `stack.sh`).

**Session (conversation).** A series of turns with one user. The conventions
call its id `gen_ai.conversation.id`. `run.py` creates one random id per run
(`conversation_id = str(uuid.uuid4())`) and gives the same id to every turn.

Why not make the whole conversation one big trace? Because a conversation can
last hours or days. A trace that long:

- never clearly "finishes", so it can't be **tail sampled** (deciding which
  whole traces to keep once they're complete, [module 5](05-sampling.md)),
- has a duration that means nothing ("3 hours", mostly waiting for the user),
- is too big for a trace viewer to show sensibly.

Instead, every turn is its own short trace, and every turn carries the same
`gen_ai.conversation.id`. A "session view" is then just a query: "all traces
with this conversation id, in time order" (lab step 4). Think of a support
ticket with several emails: each email is handled on its own, and the ticket
number ties them together.

> **Quick check:** A user comes back four days later and continues the same
> conversation. Will the session query show all their turns?
>
> <details><summary>Answer</summary>
>
> No. The id still ties the turns together, but `otel.otel_traces` keeps
> spans for 72 hours (its TTL), so the older turns are gone. Long-lived
> session history needs its own, longer-lived table.
> </details>

**Evals (evaluations).** Everything so far measures *performance*: how long,
how many tokens, did it fail. Evals measure *quality*: was the answer
correct, grounded in the notes, safe, helpful? They're usually produced
*after* the turn, by one of:

- an **LLM judge** (a second model asked "rate this answer from 1 to 5"),
- a **rule** (for example "the answer must mention a ticket id"),
- a **user's feedback**, such as a thumbs-up.

The GenAI conventions record an eval as an **event** named
`gen_ai.evaluation.result`: a timestamped record, sent as an OpenTelemetry
log record, that carries the trace id and span id of the span it judges. The
event carries
`gen_ai.evaluation.name` (what was judged, such as "relevance"),
`gen_ai.evaluation.score.value` (a number), `gen_ai.evaluation.score.label`
(a word, such as "pass") and `gen_ai.evaluation.explanation` (why). **This
repo doesn't produce evals yet.** Adding them would mean a job that reads
finished turns, scores them, and emits `gen_ai.evaluation.result` events
keyed by `TraceId` and `SpanId`, so queries can join scores to traces.

### Content is opt-in

**Why.** Prompts and answers can contain personal data (an employee's name, a
customer's question) and can be large. Storing them by default would be a
privacy risk and expensive.

**What.** The conventions do define attributes for content:
`gen_ai.input.messages` (the prompt), `gen_ai.output.messages` (the reply),
`gen_ai.system_instructions` (the system message),
`gen_ai.tool.call.arguments` and `gen_ai.tool.call.result`. But they say
**don't capture them by default**. Instrumentation libraries (ready-made
tracing code for a framework) usually turn them on with a setting such as
`OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT=true`.

**In this repo.** The tracer never records content. Its docstring says so:
"Prompt, completion and tool content is never recorded." You can confirm it in
the trace above: there's no `gen_ai.input.messages` anywhere. (The HTTP client
span's `url.full` does include the search query string,
`...?q=What+is+a+trace%3F`, because it's a URL. That's the HTTP conventions
at work, not the GenAI ones.)

### GenAI metrics

The same conventions also define **metrics** (numbers aggregated over time,
rather than one record per operation): `gen_ai.client.token.usage` (a
histogram, meaning a count of values per size bucket, of tokens by token type)
and `gen_ai.client.operation.duration` (how long GenAI calls take). This repo
emits only spans. It derives rate, errors and duration per minute in
ClickHouse instead, in the `span_red_1m` table (RED = rate, errors,
duration).

## Remember it

> **Operation name first, then "who, which model, how many tokens".**
> `chat` spans carry the money (tokens); `invoke_agent` spans carry the
> identity (which agent); `execute_tool` spans carry the action (which tool).

And: **GenAI semconv is wet paint.** It works, but it's still changing, so
pin the schema version.

## In this repo

- `agent/telemetry.py`: `SCHEMA_URL = Schemas.V1_44_0.value`, used for both
  the resource and the tracer. All the `gen_ai.*` attribute names are in
  `LangGraphTracer`: `on_chain_start` (workflow and agent spans),
  `on_chat_model_start` and `on_llm_end` (chat spans and tokens),
  `on_tool_start` (tool spans).
- `agent/run.py`: the `agent_turn` root span with `gen_ai.conversation.id`,
  `org.agent.turn.id` and `org.agent.turn.index`, and `AGENT_VERSION`, which
  becomes `gen_ai.agent.version`.
- `agent/graph.py`: `FakeChatModel` fills in `usage_metadata` (input, output
  and cache-read tokens) and `response_metadata` (model name, finish reason),
  shaped like a real provider's reply.
- `clickhouse/schema.sql`: every attribute is stored in the `SpanAttributes`
  map column of `otel.otel_traces`, the table the gateway writes to. The
  table also keeps a fast copy of the most-queried GenAI attributes as their
  own columns, such as `gen_ai_operation`, `gen_ai_agent_name` and
  `gen_ai_tokens_in`, filled in automatically from the map. The lab uses
  them; [module 8](08-data-model.md) explains how they work.
- `queries.sql`: queries 2, 3, 4 and 5 group and filter by
  `gen_ai.operation.name` and `gen_ai.agent.name`, for example per-agent
  latency and the agent hand-off path per turn.

## Principal engineer's notes

**Touch points**

- An attribute name is a contract with three owners: the tracer, the
  `MATERIALIZED` column in `schema.sql`, and every saved query. Rename it in
  the tracer and nothing errors; new rows just read `''` or `0`.
- The schema URL travels in OTLP, but `otel.otel_traces` has no column for
  it: stored rows don't say which version they followed.

**At scale**

- Content dwarfs everything. A span's attributes are a few hundred bytes; a
  prompt with history is kilobytes and grows every turn. If you capture it,
  send it as log events to a separate table with its own short TTL and access
  rules, keyed by `TraceId` and `SpanId`.
- High-cardinality ids (conversation, turn, user) belong in attributes or
  plain `String` columns with a bloom filter (`idx_conv_id`), never in
  `LowCardinality` columns or metric labels (`span_red_1m` has none).
- Evals run as an asynchronous, sampled job (some successes, every error),
  keyed by trace id. Evaluate traces you kept: after tail sampling
  ([module 5](05-sampling.md)) a score can point at a deleted trace.

**Operational issues**

- *Names change.* Instrumentation libraries read `OTEL_SEMCONV_STABILITY_OPT_IN`
  to emit old names, new names, or both during a migration. Do the same: pin
  the package and schema URL, emit both for a release, query either
  (`if(new != '', new, old)`). A changed `MATERIALIZED` expression only
  affects new inserts; `ALTER TABLE ... MATERIALIZE COLUMN` recomputes old parts.
- *Cost per tenant or agent* is a `GROUP BY` over `chat` spans. Watch the
  empty bucket: `sales-agent` has no tenants, so its tokens land under `''`.
  Keep prices in a table keyed by model and date; join at query time.
- *Double counting.* A second instrumentation layer beside these callbacks
  (say, a provider SDK's) means two chat spans per call. Retries are real,
  separately billed calls: count each.
- *Sampling skews totals.* For billing-grade numbers, count before sampling
  (`gen_ai.client.token.usage` metrics) or weight by the sample rate.

**Design trade-offs**

- No content, ever (this repo) vs opt-in capture to a separate store: choose
  the latter to debug prompts or run text-based evals, after PII review.
- `org.agent.workflow` over `gen_ai.workflow.name`: safe now, one more name
  to migrate later.

## Lab (15 min)

Run SQL in <http://localhost:8123/play> (user `default`, password `demo`).
The stack should be running with traffic on (`./stack.sh up`), so there are
spans from all three agent services.

1. Find a turn-1 trace like the one above. The `WITH` line picks the most
   recent support-agent `agent_turn` span whose turn index is 1; the main
   query lists that trace's support-agent spans with their step and tokens:

   ```sql
   WITH (SELECT TraceId FROM otel.otel_traces
         WHERE ServiceName = 'support-agent' AND SpanName = 'agent_turn'
           AND SpanAttributes['org.agent.turn.index'] = '1'
         ORDER BY Timestamp DESC LIMIT 1) AS t
   SELECT SpanName, SpanAttributes['org.agent.step'] AS step,
          gen_ai_tokens_in AS tokens_in, gen_ai_tokens_cache_read AS cached,
          gen_ai_tokens_out AS tokens_out
   FROM otel.otel_traces WHERE TraceId = t AND ServiceName = 'support-agent'
   ORDER BY Timestamp;
   ```

   ```text
   agent_turn                                    0   0   0
   invoke_workflow support_supervisor            0   0   0
   invoke_agent supervisor              1        0   0   0
   chat fake-supervisor                         12   8   1
   invoke_agent researcher              2        0   0   0
   execute_tool search_knowledge_base            0   0   0
   GET /v1/search                                0   0   0
   chat fake-researcher                         26   6  18
   invoke_agent supervisor              3        0   0   0
   chat fake-supervisor                         12   8   1
   invoke_agent writer                  4        0   0   0
   chat fake-writer                             25   7  19
   execute_tool count_words                      0   0   0
   invoke_agent supervisor              5        0   0   0
   chat fake-supervisor                         12   8   1
   ```

   What to notice: only `chat` rows have tokens (the token columns read `0`
   when the attribute is missing), and only `invoke_agent` rows have a step.
   To see every attribute of one span, select `SpanAttributes` instead.

2. Which attributes does each operation actually carry? This query takes every
   GenAI span, collects all the attribute keys seen for each operation, and
   prints one sorted list per operation:

   ```sql
   SELECT gen_ai_operation, arraySort(groupUniqArrayArray(mapKeys(SpanAttributes))) AS keys
   FROM otel.otel_traces WHERE gen_ai_operation != '' GROUP BY 1 FORMAT Vertical;
   ```

   (`mapKeys` lists the keys of the map; `groupUniqArrayArray` merges those
   lists across rows and removes duplicates. `FORMAT Vertical` prints one
   field per line, which is easier to read for long lists.)

   Compare with the "which span gets which attribute" table above. `chat` has
   the usage and model keys; `execute_tool` has `gen_ai.tool.*`; only the
   `invoke_agent` spans have `gen_ai.agent.id` and `.version`. You'll also see
   `org.*` keys, and `error.type` on operations that sometimes fail. Notice
   what's *missing*: no `gen_ai.tool.call.id`, and no `gen_ai.conversation.id`
   on `execute_tool`.

3. Tokens per turn, and cache hit ratio by agent. First, sum the chat spans
   of each trace; remember, one trace is one turn:

   ```sql
   SELECT ServiceName, TraceId, sum(gen_ai_tokens_in + gen_ai_tokens_out) AS tokens
   FROM otel.otel_traces WHERE gen_ai_operation = 'chat'
   GROUP BY ServiceName, TraceId ORDER BY tokens DESC LIMIT 5;
   ```

   This is the "sum, don't copy" rule in action: the turn total is computed
   from the chat spans, not stored on `agent_turn`. Support-agent turns
   usually top the list, because they make five LLM calls each. (A
   successful turn 1 always comes to 87 + 40 = 127.)

   Then, for each service and agent, count the chat calls and sum the tokens.
   The cache ratio is "what share of input tokens came from the cache":

   ```sql
   SELECT ServiceName, gen_ai_agent_name, count() AS calls,
          sum(gen_ai_tokens_in) AS tokens_in, sum(gen_ai_tokens_out) AS tokens_out,
          round(sum(gen_ai_tokens_cache_read) / sum(gen_ai_tokens_in), 2) AS cache_ratio
   FROM otel.otel_traces WHERE gen_ai_operation = 'chat'
   GROUP BY 1, 2 ORDER BY 1, 2;
   ```

   The supervisor makes the most calls but writes 1 token each (a routing
   word); the writer writes the most. That's the kind of insight these
   attributes are for. The query can group by agent directly because the
   tracer puts `gen_ai.agent.name` on chat spans.

4. One session, turn by turn (each turn is its own trace). The `WITH` line
   picks any one support-agent conversation id. The main query then lists every
   trace with that id, with its start time, its duration, and whether anything
   in it failed:

   ```sql
   WITH (SELECT any(gen_ai_conversation_id) FROM otel.otel_traces
         WHERE ServiceName = 'support-agent' AND gen_ai_conversation_id != '') AS conversation
   SELECT TraceId, min(Timestamp) AS started, round(max(Duration) / 1e6) AS turn_ms,
          max(StatusCode = 'Error') AS failed
   FROM otel.otel_traces
   WHERE gen_ai_conversation_id = conversation
   GROUP BY TraceId ORDER BY started;
   ```

   What to notice: several different trace ids share one conversation id;
   that's the session. `turn_ms` is the longest span in the trace, which is
   the `agent_turn` root (`Duration` is in nanoseconds, so dividing by `1e6`
   gives milliseconds). The first row is turn 1, *"What is a trace?"*. The
   background traffic runs the support agent with `--fail-turn 2`, so the
   second turn usually shows `failed = 1` and a much shorter time: it stopped
   at the failed search.

## Explain it back

> "The GenAI conventions are OpenTelemetry's shared names for AI work.
> `gen_ai.operation.name` says what a span is (workflow, agent, chat, tool)
> and sets its name. Chat spans carry model and tokens, agent spans carry
> identity, tool spans carry the action. Content is opt-in. The conventions
> are still in development, so we pin the version and keep our own labels
> under `org.*`."

## Recap

- Semantic conventions are a shared dictionary of span names, attribute names
  and values. Standard names let one dashboard or query work across teams,
  libraries and backends.
- They're versioned (schema URL, here 1.44.0) and have stability levels. GenAI
  is still in development, so names can change. Your own labels go in your own
  namespace (`org.*` here).
- `gen_ai.operation.name` comes first: `invoke_workflow` (the graph),
  `invoke_agent` (one agent), `chat` (one LLM call, kind `CLIENT`),
  `execute_tool` (one tool).
- Identity on agent spans, tokens on chat spans, actions on tool spans. This
  repo also copies `gen_ai.agent.name` onto chat and tool spans for easy
  grouping.
- Tokens are stored once, on chat spans. Cached tokens are part of the input,
  though providers differ in how they report them. Totals for agents, turns
  and sessions are sums in queries.
- One turn is one trace; a session is all the traces sharing a
  `gen_ai.conversation.id`; evals are `gen_ai.evaluation.result` events
  attached later by trace and span id.
- Prompts and answers are not recorded by default, and never in this repo.

## Check yourself

<details><summary>What problem do semantic conventions solve?</summary>

Without them, every team and library picks its own names for the same thing
(`llm.model`, `model_name`, `ai.model.id`). Dashboards, alerts and cross-team
queries then need to know every variant, and break when a new one appears.
With one shared name, such as `gen_ai.request.model`, one query works
everywhere, and tools can recognize what a span is.
</details>

<details><summary>Which span carries the token counts, which carries the agent version, and which carries the tool name?</summary>

Tokens: the `chat` span. Agent version (and agent id): the `invoke_agent`
span. Tool name: the `execute_tool` span. In this repo, `gen_ai.agent.name`
is on all three, so you can group any of them by agent.
</details>

<details><summary>Why is a session not one long trace?</summary>

A session can last hours or days. A trace that long never "finishes", so it
can't be tail sampled, its duration means nothing, and a viewer can't show it.
Make each turn a trace, and link the turns through `gen_ai.conversation.id`.
</details>

<details><summary>An LLM judge scores an answer an hour after the turn. How does the score find its trace?</summary>

The judge reads the finished turn, so it knows the trace id and the span id
of the turn or chat span. It emits a `gen_ai.evaluation.result` event tied to
those ids, with the `gen_ai.evaluation.*` attributes (name, score, label,
explanation). A query can then join scores to traces on `TraceId`.
</details>

<details><summary>Why put tokens on chat spans, and not on the agent span too?</summary>

Any query that sums tokens over a trace would count them twice. Store each
fact once, on the span where it happened, and aggregate in queries.
</details>

<details><summary>Mixing with module 2: a LangChain upgrade stops filling <code>usage_metadata</code> on model replies. What breaks, and how would you notice?</summary>

`on_llm_end` finds no usage, so chat spans lose their `gen_ai.usage.*`
attributes. Nothing errors: `gen_ai_tokens_in` reads `0` for new rows and cost
dashboards quietly drop. Notice it with an alert on "chat spans with zero
input tokens" or a golden-trace test after each upgrade.
</details>

<details><summary>Why doesn't this repo use <code>gen_ai.workflow.name</code>?</summary>

It records the workflow name as `org.agent.workflow` instead. The installed
semconv package does define `gen_ai.workflow.name`, so switching to it would be
a small, reasonable change. That's what "development" status means in practice:
check what the current version offers.
</details>

## Next

You now know what the spans say. [Module 4](04-collector.md) answers how they
get from the agent to ClickHouse: through the OpenTelemetry Collector, the
gateway in the middle that checks, labels and batches every span, and
decides what's lost when something goes down.

## Read more

- [Semantic conventions overview](https://opentelemetry.io/docs/specs/semconv/)
- [GenAI semantic conventions](https://opentelemetry.io/docs/specs/semconv/gen-ai/)
- [GenAI spans](https://opentelemetry.io/docs/specs/semconv/gen-ai/gen-ai-spans/)
- [GenAI agent and framework spans](https://opentelemetry.io/docs/specs/semconv/gen-ai/gen-ai-agent-spans/)
- [GenAI events (including evaluation results)](https://opentelemetry.io/docs/specs/semconv/gen-ai/gen-ai-events/)
- [GenAI metrics](https://opentelemetry.io/docs/specs/semconv/gen-ai/gen-ai-metrics/)
- [GenAI attribute registry](https://opentelemetry.io/docs/specs/semconv/registry/attributes/gen-ai/)
- [Schemas and schema URLs](https://opentelemetry.io/docs/specs/otel/schemas/)

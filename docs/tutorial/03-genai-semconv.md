# Module 3: GenAI semantic conventions (30 min)

## Idea

### What semantic conventions are

**Semantic conventions** (semconv) are OpenTelemetry's shared dictionary:
which **span names**, **attribute names** and **values** to use for common
things (HTTP, databases, messaging, GenAI). If every team calls the model
attribute `gen_ai.request.model`, one dashboard works for every team and every
vendor's backend.

Three facts to remember:

1. **They're versioned.** Each set has a schema URL
   (`https://opentelemetry.io/schemas/1.44.0` here). Telemetry says which
   version it follows, so backends can translate renamed attributes.
2. **They have stability levels.** HTTP is *stable*. **GenAI is still in
   *development***: names can change between releases. Example: `gen_ai.system`
   was replaced by `gen_ai.provider.name`. Pin the version you emit, and expect
   to migrate.
3. **Custom attributes go in your own namespace.** That's why this repo uses
   `org.*` for its labels: it can never collide with a future official name.

### The GenAI span types

`gen_ai.operation.name` says what kind of GenAI operation a span is. It drives
the span name, the kind, and which other attributes apply.

| Operation | Span name | Kind | Key attributes |
|---|---|---|---|
| `invoke_workflow` | `invoke_workflow {workflow}` | `INTERNAL` | `gen_ai.conversation.id` |
| `invoke_agent` | `invoke_agent {gen_ai.agent.name}` | `INTERNAL` in-process; `CLIENT` for a remote agent | `gen_ai.agent.name`, `.id`, `.version` |
| `chat` | `chat {gen_ai.request.model}` | `CLIENT` | `gen_ai.provider.name`, `gen_ai.request.model`, `gen_ai.response.model`, `gen_ai.usage.*`, `gen_ai.response.finish_reasons` |
| `execute_tool` | `execute_tool {gen_ai.tool.name}` | `INTERNAL` | `gen_ai.tool.name`, `gen_ai.tool.type`, `gen_ai.tool.call.id` |
| Others | `embeddings`, `retrieval`, `create_agent`, `generate_content`, `text_completion` | | |

The installed `opentelemetry-semantic-conventions` package (0.66b2) lists these
operation names: `chat`, `generate_content`, `text_completion`, `embeddings`,
`retrieval`, `create_agent`, `invoke_agent`, `execute_tool`, `invoke_workflow`.

### Usage attributes: where the money is

| Attribute | Meaning |
|---|---|
| `gen_ai.usage.input_tokens` | Prompt tokens billed for this call |
| `gen_ai.usage.output_tokens` | Completion tokens |
| `gen_ai.usage.cache_read.input_tokens` | Input tokens served from the provider's prompt cache (cheaper) |
| `gen_ai.usage.cache_creation.input_tokens` | Input tokens written to the cache |
| `gen_ai.usage.reasoning.output_tokens` | Hidden "thinking" tokens, for reasoning models |

Tokens live on **`chat` spans only**. To get an agent's or a turn's total,
sum the chat spans below it; never copy totals onto parent spans, or you'll
count them twice.

### Content is opt-in

Prompts, completions, system instructions, tool arguments and tool results
have attributes (`gen_ai.input.messages`, `gen_ai.output.messages`,
`gen_ai.system_instructions`, `gen_ai.tool.call.arguments`,
`gen_ai.tool.call.result`), but the conventions say **don't capture them by
default**: they can hold personal data and are large. Instrumentation
libraries turn them on with a setting such as
`OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT=true`. This repo's tracer
never records content.

### GenAI metrics

The same conventions define metrics: `gen_ai.client.token.usage` (a histogram
by token type) and `gen_ai.client.operation.duration`. This repo only emits
spans and derives rate, errors and latency per minute in ClickHouse (the
`span_red_1m` table).

## Remember it

> **Operation name first, then "who, which model, how many tokens".**
> `chat` spans carry the money (tokens); `invoke_agent` spans carry the
> identity (which agent); `execute_tool` spans carry the action (which tool).

And: **GenAI semconv is wet paint**: it works, but it's still changing, so pin
the schema version.

## In this repo

- `agent/telemetry.py`: `SCHEMA_URL = Schemas.V1_44_0.value`, and the
  attribute names in `LangGraphTracer`.
- `clickhouse/schema.sql`: `gen_ai_*` **MATERIALIZED columns** copy the most
  queried attributes out of the `SpanAttributes` map into real columns, for
  example:

  ```sql
  gen_ai_operation   LowCardinality(String) MATERIALIZED SpanAttributes['gen_ai.operation.name'],
  gen_ai_tokens_in   UInt32 MATERIALIZED toUInt32OrZero(SpanAttributes['gen_ai.usage.input_tokens']),
  ```

  A map lookup reads the whole map column; a real column is compact,
  compressed on its own, and can be indexed.

## Lab (10 min)

1. Which attributes does each operation actually carry?

   ```sql
   SELECT gen_ai_operation, arraySort(groupUniqArrayArray(mapKeys(SpanAttributes))) AS keys
   FROM otel.otel_traces WHERE gen_ai_operation != '' GROUP BY 1 FORMAT Vertical;
   ```

   Compare with the table above. `chat` has the usage and model keys;
   `execute_tool` has `gen_ai.tool.*`; only the agent spans have
   `gen_ai.agent.id` and `.version`.

2. Tokens and cache hit ratio by agent:

   ```sql
   SELECT ServiceName, gen_ai_agent_name, count() AS calls,
          sum(gen_ai_tokens_in) AS tokens_in, sum(gen_ai_tokens_out) AS tokens_out,
          round(sum(gen_ai_tokens_cache_read) / sum(gen_ai_tokens_in), 2) AS cache_ratio
   FROM otel.otel_traces WHERE gen_ai_operation = 'chat'
   GROUP BY 1, 2 ORDER BY 1, 2;
   ```

   The supervisor makes the most calls but writes 1 token each (a routing
   word); the writer writes the most. That's the kind of insight these
   attributes are for.

3. Tokens per turn (sum the chat spans of each trace):

   ```sql
   SELECT ServiceName, TraceId, sum(gen_ai_tokens_in + gen_ai_tokens_out) AS tokens
   FROM otel.otel_traces WHERE gen_ai_operation = 'chat'
   GROUP BY ServiceName, TraceId ORDER BY tokens DESC LIMIT 5;
   ```

## Explain it back

> "The GenAI semantic conventions are OpenTelemetry's shared names for AI
> workloads. `gen_ai.operation.name` says what a span is: a workflow, an agent
> invocation, a chat call or a tool execution, and that sets the span name.
> Chat spans carry the provider, the model and the token usage, including
> cached and reasoning tokens; agent spans carry the agent's name, id and
> version; tool spans carry the tool name. Message content is opt-in because of
> privacy and size. The conventions are still in development, so we pin the
> schema version and keep our own labels in an `org` namespace."

## Check yourself

<details><summary>Why put tokens on chat spans, and not on the agent span too?</summary>

Any query that sums tokens over a trace would count them twice. Store each
fact once, on the span where it happened, and aggregate in queries.
</details>

<details><summary>A provider reports 1,000 input tokens, 800 of them cache reads. What do you record?</summary>

`gen_ai.usage.input_tokens = 1000` and
`gen_ai.usage.cache_read.input_tokens = 800`. The cache figure is a breakdown
of the input, not an addition; cost models price the two parts differently.
</details>

<details><summary>Why doesn't this repo use <code>gen_ai.workflow.name</code>?</summary>

It records the workflow name as `org.agent.workflow` instead. The installed
semconv package does define `gen_ai.workflow.name`, so switching to it would be
a small, reasonable change. That's what "development" status means in practice:
check what the current version offers.
</details>

## Read more

- [Semantic conventions overview](https://opentelemetry.io/docs/specs/semconv/)
- [GenAI semantic conventions](https://opentelemetry.io/docs/specs/semconv/gen-ai/)
- [GenAI spans](https://opentelemetry.io/docs/specs/semconv/gen-ai/gen-ai-spans/)
- [GenAI agent and framework spans](https://opentelemetry.io/docs/specs/semconv/gen-ai/gen-ai-agent-spans/)
- [GenAI metrics](https://opentelemetry.io/docs/specs/semconv/gen-ai/gen-ai-metrics/)
- [GenAI attribute registry](https://opentelemetry.io/docs/specs/semconv/registry/attributes/gen-ai/)
- [Schemas and schema URLs](https://opentelemetry.io/docs/specs/otel/schemas/)

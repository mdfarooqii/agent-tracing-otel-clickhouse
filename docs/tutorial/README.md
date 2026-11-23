# Agent tracing, end to end: a hands-on tutorial

This tutorial takes you from "what is a span?" to explaining, and breaking on
purpose, every layer of this repo: OpenTelemetry in a LangGraph agent, the GenAI
semantic conventions, the OpenTelemetry Collector as a gateway, head and tail
sampling, and a replicated ClickHouse cluster.

You don't need to know any of those words yet. This page explains what they
are, why they matter, and how the pieces fit together. Each module then
explains its own words again before using them.

## What is this and why would I care?

### The problem: "it was slow, and then it failed"

Imagine you run an HR and IT assistant chatbot. A user types *"I need a new
laptop"*. Nine seconds later they get an error.

What happened? Behind that one message, a lot of things ran:

- an **agent** program decided what to do,
- it asked a **language model** (LLM) several times,
- it called a **tool** that opens a support ticket,
- that tool sent an HTTP request to a **separate ticket service**,
- which wrote to its own database.

Each of those pieces runs in its own process, maybe on its own machine, owned
by a different team. Each one might write some log lines, but nothing ties
them together. Was it the model? The ticket service? A retry loop? Without
help, you're guessing.

### Observability and tracing, in plain words

**Observability** means being able to answer questions about what your running
software is doing, using data the software sends out about itself, without
adding new code each time you have a new question. That data is called
**telemetry**. It comes in three main kinds, called **signals**:

| Signal | What it is | Example |
|---|---|---|
| Logs | Text lines a program writes as things happen | `ticket created TCK-4821` |
| Metrics | Numbers measured over time | "120 requests per minute, 3% errors" |
| Traces | The step-by-step story of one request, with timings | "this message took 9 s; 7 s of it was the ticket service" |

This tutorial is about **traces**.

Think of parcel tracking. Every time a parcel is scanned (picked up, sorted,
loaded on a truck, delivered), the scan is recorded with the same tracking
number. Later, you type that number in and see the parcel's whole journey,
with times. A **trace** is the same idea for a request: every step records
what it did and how long it took, tagged with a shared id, and a database
stitches the steps back into one story. Each recorded step is called a
**span**.

### What an AI agent is

An **AI agent** is a program that uses a large language model to decide what
to do next, step by step. It can call **tools**: ordinary functions that look
something up or take an action, such as "search the knowledge base" or "open a
ticket". Some setups use several agents that hand work to each other, for
example a *supervisor* that routes the question to a *researcher* and then a
*writer*.

The agents in this repo are built with **LangGraph**, a Python library where an
agent is a graph: boxes (called *nodes*) are steps, and arrows say which step
runs next. The language model is a **fake, offline model** with made-up delays
and token counts, so you need no API key and no internet access to an LLM.

Agents especially need tracing because:

- the model decides the path, so two runs of the same question can take
  different steps,
- one question can cause many model and tool calls, each with its own delay,
- model calls cost money per **token** (a token is a chunk of text, roughly a
  word or part of a word), and you want to know which agent spent them.

### What this whole stack does

This repo shows a complete, working answer to the problem above:

1. Every user question (one **turn**) becomes **one trace**.
2. The trace shows which agent ran, every model call with its token counts,
   every tool call, and every HTTP API the tools called, even though those
   APIs are separate programs.
3. Every span carries **labels**: which team owns it, which service sent it,
   which customer (tenant) it was for.
4. All spans travel through one central checkpoint (the **gateway**) that
   checks the labels and adds a few more.
5. They're stored in **ClickHouse**, a database built for huge tables, kept as
   two identical copies so one server can fail without losing data.
6. You ask questions with plain SQL, such as "which API made the sales agent
   slow today?".

### The whole system in one picture

The top half runs as ordinary Python programs on your machine (or in your
Codespace). The bottom half runs in Docker containers.

```text
   stack.sh ──starts──▶ simulate.py
                           │
             ┌─────────────┴──────────────┐
             ▼                            ▼
   ┌───────────────────┐  HTTP call   ┌───────────────┐
   │ Agent services    │  + trace     │ Tool APIs     │
   │   support-agent   │  headers     │   kb-search   │
   │   hr-agent        │ ───────────▶ │   ticket      │
   │   sales-agent     │              │   pricing     │
   │                   │              │   legacy-hr   │
   │ LangGraph         │              │               │
   │ fake LLM          │              │               │
   │ OTel SDK          │              │ OTel SDK      │
   └─────────┬─────────┘              └───────┬───────┘
             │      spans, sent over OTLP     │
             └───────────────┬────────────────┘
                             │ localhost:14318
 - - - - - - - - - - - - - - │ - - - - - - - - - - - - - -  above: Python    below: Docker
                             ▼
                    ┌─────────────────┐
                    │  otel-gateway   │   receives spans, checks labels,
                    │  (Collector)    │   adds labels, batches, retries
                    └────────┬────────┘
                             │ inserts rows
                             ▼
          ┌───────────────┐       ┌───────────────┐
          │ clickhouse-01 │ ◀───▶ │ clickhouse-02 │   two identical copies
          └───────┬───────┘       └───────┬───────┘
                  └──── clickhouse-keeper ┘           keeps the copies in agreement
                             ▲
                             │ SQL at localhost:8123/play
                        Your browser
```

Every box in one line:

| Box | What it is, in one line |
|---|---|
| `stack.sh` | The one script you run: starts the containers, the Python traffic, and has helper commands |
| `simulate.py` | Starts the four tool APIs, then runs all three agents every 30 seconds to create traffic |
| Agent services | Three Python programs (support, HR, sales) that each answer questions with LangGraph and record spans |
| Fake LLM | An offline stand-in for a language model, with simulated delay and token counts |
| Tool APIs | Four small HTTP services the agents' tools call; each records its own spans |
| OTel SDK | The OpenTelemetry library inside every Python process that creates spans and sends them out |
| OTLP | OpenTelemetry Protocol: the standard format and network protocol for sending spans |
| `otel-gateway` | An OpenTelemetry Collector: receives all spans, drops unlabelled ones, adds labels, writes to ClickHouse |
| `clickhouse-01`, `clickhouse-02` | Two ClickHouse database servers holding identical copies (replicas) of the span tables |
| `clickhouse-keeper` | A small coordination service the two ClickHouse servers use to agree on what data exists |
| `clickhouse-init` | A one-off container that creates the database and tables, then exits |
| Docker / Docker Compose | Runs the gateway, ClickHouse and Keeper as containers, all described in `compose.yaml` |
| Browser Play UI | ClickHouse's built-in web page where you type SQL and see results |

[Module 0](00-setup.md) walks through each of these properly and follows one
question from Python all the way to a row in ClickHouse.

## How to use this tutorial

- **Go in order.** Each module builds on the one before. Modules repeat a
  one-line reminder when they reuse a word, but the full explanation is in the
  module that introduces it.
- **Run the labs.** Reading gets you the words; the labs make them stick. Each
  lab shows the output you should expect. Your ids, counts and timings will
  differ, because traffic is random; the shape should match.
- **Answer before you peek.** "Check yourself" answers are hidden under each
  question. Click the question to open the answer.
- **Say it out loud.** "Explain it back" is a 30-second script. If you can say
  it without reading, you've got the module.
- **Lost a word?** Every module has a "Key terms" table near the top, and
  [module 13](13-cheat-sheet.md) has a glossary of everything.
- **Something broken?** `./stack.sh status` and `./stack.sh logs` show what's
  running. `./stack.sh down --wipe && ./stack.sh up` resets everything.

Every module has the same shape:

- **Why this matters**: what you'll be able to do by the end.
- **Key terms**: the new words, each with a one-line plain meaning.
- **Idea**: the concept in plain words, starting with the problem it solves.
- **Remember it**: a one-line hook or picture.
- **In this repo**: where the concept lives in the code.
- **Lab**: commands to run, with the output you should see.
- **Explain it back**: a 30-second script to say out loud.
- **Quick checks**: short questions right after each big idea, answers hidden.
- **Principal engineer's notes**: touch points, scale, operational issues and
  design trade-offs, for readers who will run this in production.
- **Recap**: the main points in a few bullets.
- **Check yourself**: questions; answers are hidden under each one.
- **Next**: what the next module answers, and why it comes next.
- **Read more**: the primary docs.

## Before you start

You need the stack running, either in GitHub Codespaces (in the browser) or on
your own machine with Docker. The [main README](../../README.md) has both. Then
run these from the repo's top folder:

```bash
./stack.sh up           # start ClickHouse, Keeper, the gateway, and background agent traffic
./stack.sh status       # spans per service; the numbers should grow every 30 s
```

You'll write SQL in one of two places:

- In the browser at <http://localhost:8123/play> (user `default`, password
  `demo`). Type a query and press Ctrl+Enter (Cmd+Enter on a Mac).
- From a terminal, inside the first ClickHouse container:

  ```bash
  docker exec -it clickhouse-01 clickhouse-client --password demo
  ```

Some labs need the API ports (18081 to 18084) to themselves. Pause and resume
the background traffic with `./stack.sh traffic off` and `./stack.sh traffic on`.

## The plan (two sessions, about 11.5 hours in total)

The course comes in two parts. Part 1 follows a span from the agent to the
gateway; part 2 follows it into ClickHouse and covers running it in
production. Each part is a full day, or two half-days. Module 6 ends part 1 with a
mixed review of modules 0 to 6.

### Part 1: making and shipping spans (about 6.5 hours)

| # | Module | Time | You will be able to explain |
|---|---|---|---|
| 0 | [Setup and the mental model](00-setup.md) | 30 min | What each component does, and the path of one question from Python to a ClickHouse row |
| 1 | [OpenTelemetry core](01-otel-core.md) | 55 min | Trace, span, context, propagation, baggage, resource, SDK pipeline, OTLP |
| 2 | [LangChain, LangGraph and callbacks](02-langgraph.md) | 55 min | How a graph run becomes a span tree |
| 3 | [GenAI semantic conventions](03-genai-semconv.md) | 55 min | Which `gen_ai.*` attributes go on which span; sessions, turns and evals |
| 4 | [The Collector as a gateway](04-collector.md) | 55 min | Receivers, processors, exporters, buffering, retries, and where data can be lost |
| 5 | [Head and tail sampling](05-sampling.md) | 95 min | Where a keep/drop decision is made and what it costs; a balanced sampling plan; finding a slow dependency without keeping every trace |
| 6 | [Joining services and environments](06-cross-environment.md) | 45 min | The checklist for one trace across services and environments, and what breaks it |

### Part 2: storing and running it (about 5 hours)

| # | Module | Time | You will be able to explain |
|---|---|---|---|
| 7 | [ClickHouse storage, replicas and Keeper](07-clickhouse.md) | 45 min | Parts, partitions, the sorting key, replication, what fails and how |
| 8 | [The data model](08-data-model.md) | 40 min | Every column and table in `schema.sql`, and which summary table answers which question |
| 9 | [Sharding, trace locality and indexes](09-sharding-indexes.md) | 45 min | How a cluster is laid out; why all spans of a trace land on one shard; skip indexes |
| 10 | [Adding a replica and copying data](10-copying-data.md) | 38 min | A third replica, `remote()`, FETCH/ATTACH PARTITION, safe incremental copies |
| 11 | [Moving older data to S3](11-s3-tiering.md) | 45 min | Disks, storage policies and TTL moves; local S3 with SeaweedFS; real S3 settings |
| 12 | [Operational readiness, gateway to ClickHouse](12-operations.md) | 50 min | The signals to watch, reading the health check, and a production checklist |
| 13 | [Cheat sheet and glossary](13-cheat-sheet.md) | 40 min | The whole system in five minutes, from memory |
| A | [Metrics reference](appendix-metrics-reference.md) | reference | Every metric per component: what it means, a bad value, what to do |

Suggested breaks: after modules 2 and 4 in part 1, and after modules 8 and 10
in part 2.

If you only have two hours, do modules 0, 1, 2, 4 and 7, and read the
cheat sheet.

## Lab files

The `labs/` folder holds extra files that some labs use. You don't need to
open them in advance; each module tells you when.

| File | What it's for |
|---|---|
| [`labs/hello_span.py`](labs/hello_span.py) | Module 1: makes two spans and prints them on screen, with no database needed |
| [`labs/print_callbacks.py`](labs/print_callbacks.py) | Module 2: prints the raw events LangChain fires while a graph runs |
| [`labs/otel-gateway-tail-sampling.yaml`](labs/otel-gateway-tail-sampling.yaml) | Module 5: extra gateway settings that keep or drop whole traces after they finish |
| [`labs/compose.tail-sampling.yaml`](labs/compose.tail-sampling.yaml) | Module 5: restarts the gateway with those extra settings |
| [`labs/otel-gateway-smart-sampling.yaml`](labs/otel-gateway-smart-sampling.yaml) | Module 5: metrics from every span (span metrics, service graph), then per-agent and per-team tail sampling |
| [`labs/compose.smart-sampling.yaml`](labs/compose.smart-sampling.yaml) | Module 5: restarts the gateway with the smart sampling settings |
| [`labs/metrics-tables.sql`](labs/metrics-tables.sql) | Module 5: the ClickHouse tables those metrics are written to |
| [`labs/sharding.sql`](labs/sharding.sql) | Module 9: splits data across the two servers instead of copying it, to see where spans land |
| [`labs/compose.replication.yaml`](labs/compose.replication.yaml), [`labs/macros-03.xml`](labs/macros-03.xml) | Module 10: adds a third ClickHouse copy and a separate standalone server |
| [`labs/add-replica.sh`](labs/add-replica.sh) | Module 10: registers the third copy, which then pulls in all existing data |
| [`labs/storage-s3.xml`](labs/storage-s3.xml), [`labs/compose.s3-tiering.yaml`](labs/compose.s3-tiering.yaml) | Module 11: lets ClickHouse store data in S3, and runs a local S3-compatible server |
| [`labs/enable-s3-tiering.sh`](labs/enable-s3-tiering.sh) | Module 11: tells the span tables to move older data to S3 and delete it later |
| [`labs/health-check.sh`](labs/health-check.sh) | Module 12: a one-screen health check of every component (also `./stack.sh health`) |

The labs only add things (a `lab` database, an extra index you drop again,
an extra gateway config you turn off again). `./stack.sh down --wipe` resets
everything.

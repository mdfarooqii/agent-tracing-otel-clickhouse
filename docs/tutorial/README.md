# Agent tracing, end to end: a 5-hour tutorial

This tutorial takes you from "what is a span?" to explaining, and breaking on
purpose, every layer of this repo: OpenTelemetry in a LangGraph agent, the GenAI
semantic conventions, the OTel Collector as a gateway, head and tail sampling,
and a replicated ClickHouse cluster.

Every module has the same shape:

- **Idea**: the concept in plain words.
- **Remember it**: a one-line hook or picture.
- **In this repo**: where the concept lives in the code.
- **Lab**: commands to run, with the output you should see.
- **Explain it back**: a 30-second script to say out loud.
- **Check yourself**: questions; answers are hidden under each one.
- **Read more**: the primary docs.

## Before you start

You need the stack running (Codespaces or local; see the [main README](../../README.md)):

```bash
./stack.sh up           # ClickHouse, Keeper, gateway, and background agent traffic
./stack.sh status       # spans per service; numbers should grow every 30s
```

ClickHouse SQL runs in the browser at <http://localhost:8123/play> (user
`default`, password `demo`), or from a terminal with:

```bash
docker exec -it clickhouse-01 clickhouse-client --password demo
```

Some labs need the API ports to themselves. Pause and resume the background
traffic with `./stack.sh traffic off` and `./stack.sh traffic on`.

## The plan (about 5 hours)

| # | Module | Time | You will be able to explain |
|---|---|---|---|
| 0 | [Setup and the mental model](00-setup.md) | 15 min | The path of one span from Python to a ClickHouse row |
| 1 | [OpenTelemetry core](01-otel-core.md) | 40 min | Trace, span, context, propagation, resource, SDK pipeline |
| 2 | [LangChain, LangGraph and callbacks](02-langgraph.md) | 35 min | How a graph run becomes a span tree |
| 3 | [GenAI semantic conventions](03-genai-semconv.md) | 35 min | Which `gen_ai.*` attributes go on which span; sessions, turns and evals |
| 4 | [The Collector as a gateway](04-collector.md) | 40 min | Receivers, processors, exporters, buffering and retries |
| 5 | [Head and tail sampling](05-sampling.md) | 30 min | Where a keep/drop decision is made and what it costs |
| 6 | [ClickHouse storage, replicas and Keeper](06-clickhouse.md) | 45 min | Parts, partitions, replication, what fails and how |
| 7 | [Sharding, trace locality and indexes](07-sharding-indexes.md) | 25 min | Why all spans of a trace land on one shard; skip indexes |
| 8 | [Joining services and environments](08-cross-environment.md) | 25 min | How non-agentic services and other environments join one trace |
| 9 | [Explain-it-back cheat sheet and glossary](09-cheat-sheet.md) | 10 min | The whole system in five minutes, from memory |
| 10 | [The data model, the DDL, and copying between ClickHouse servers](10-data-model.md) | 35 min | Every column and table in `schema.sql`; adding a replica; copying with `remote()` |
| 11 | [Moving older data to S3](11-s3-tiering.md) | 30 min | Disks, storage policies and TTL moves; local S3 with SeaweedFS; real S3 settings |

Suggested breaks: after module 3 (10 min) and after module 6 (10 min).

Modules 0 to 9 take about 5 hours. Modules 10 and 11 add about an hour; they
fit best right after module 6, or as a follow-up session.

If you only have two hours, do modules 0, 1, 2, 4 and 6, and read the
cheat sheet.

## Lab files

| File | Used in |
|---|---|
| [`labs/otel-gateway-tail-sampling.yaml`](labs/otel-gateway-tail-sampling.yaml) | Module 5: tail sampling config, merged into the gateway |
| [`labs/compose.tail-sampling.yaml`](labs/compose.tail-sampling.yaml) | Module 5: restarts the gateway with that config |
| [`labs/sharding.sql`](labs/sharding.sql) | Module 7: two-shard experiment on the same two servers |
| [`labs/compose.replication.yaml`](labs/compose.replication.yaml), [`labs/macros-03.xml`](labs/macros-03.xml) | Module 10: a third replica and a standalone server |
| [`labs/add-replica.sh`](labs/add-replica.sh) | Module 10: registers the third replica, which then copies everything |
| [`labs/storage-s3.xml`](labs/storage-s3.xml), [`labs/compose.s3-tiering.yaml`](labs/compose.s3-tiering.yaml) | Module 11: S3 disk, `tiered` storage policy, and a local S3 server |
| [`labs/enable-s3-tiering.sh`](labs/enable-s3-tiering.sh) | Module 11: puts the `otel` tables on the policy, with move and delete TTLs |
| [`labs/hello_span.py`](labs/hello_span.py), [`labs/print_callbacks.py`](labs/print_callbacks.py) | Modules 1 and 2: spans and raw LangChain callbacks |

The labs only add things (a `lab` database, an extra index you drop again,
an extra gateway config you turn off again). `./stack.sh down --wipe` resets
everything.

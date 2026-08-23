---
title: Architecture
tags: [sluice, architecture, design]
created: 23/08/2026
updated: 23/08/2026
---

# Architecture

Index: [[00_index]] · Next: [[02_tech_stack]]

---

## Processes

Four binaries. Everything stateless except Postgres and RabbitMQ.

| Process | Language | Replicas | Owns |
|---|---|---|---|
| `gateway` | Go | n (behind LB) | HTTP API, authn, admission control, payload write, publish, job reads |
| `worker` | Python | n | consume, claim, run inference, write result |
| `reaper` | Go | n (safe to run several) | release stale leases, expire past-deadline jobs |
| `outbox-publisher` | Go | n (safe) | drain `outbox` → broker with confirms — see [[05_messaging_topology#Transactional outbox]] |

`reaper` and `outbox-publisher` are separate `cmd/` entrypoints but can be compiled into one `sluice-workers` binary with a subcommand if you'd rather run fewer containers. Both are safe at n>1 because every claim uses `FOR UPDATE SKIP LOCKED` — **no leader election required**.

---

## Container view

```mermaid
flowchart LR
    C([client])

    subgraph app["application"]
        GW["gateway :8080<br/>Go + chi"]
        W["worker<br/>Python + aio-pika"]
        R["reaper<br/>tick 10s"]
        OP["outbox-publisher<br/>tick 1s"]
    end

    subgraph infra["infrastructure"]
        MQ{{"RabbitMQ<br/>job_queue"}}
        DLQ{{"job_dlq"}}
        PG[("Postgres<br/>jobs · job_events<br/>job_payloads · outbox")]
    end

    C -->|"POST /v1/jobs"| GW
    C -.->|"GET /v1/jobs/:id"| GW
    GW --> PG
    OP --> PG
    OP -->|"publish + confirm"| MQ
    MQ -->|"consume prefetch=1"| W
    MQ -->|"attempt >= max"| DLQ
    W --> PG
    R --> PG
    R -->|"republish on requeue"| MQ
```

Note what is **not** there: the gateway never talks to the worker, and the worker never talks to the gateway. All coordination is through Postgres and the broker. That is what makes both horizontally scalable and independently deployable.

---

## Submit path

```mermaid
sequenceDiagram
    autonumber
    actor C as client
    participant GW as gateway
    participant PG as Postgres
    participant OP as outbox-publisher
    participant MQ as RabbitMQ

    C->>GW: POST /v1/jobs
    GW->>GW: authn + validate + hash body
    GW->>GW: check cached queue depth
    alt depth > SHED_QUEUE_DEPTH
        GW-->>C: 429 Retry-After
    else admitted
        GW->>PG: BEGIN
        GW->>PG: INSERT job_payloads (input)
        GW->>PG: INSERT jobs (status=queued)
        GW->>PG: INSERT job_events (null -> queued)
        GW->>PG: INSERT outbox (job.created)
        GW->>PG: COMMIT
        GW-->>C: 202 Accepted {job_id}
    end

    Note over OP,MQ: independent loop, at-least-once
    OP->>PG: SELECT unpublished FOR UPDATE SKIP LOCKED
    OP->>MQ: publish (persistent, mandatory, confirmed)
    MQ-->>OP: ack
    OP->>PG: UPDATE outbox SET published_at = now()
```

Four writes in one transaction, then a `202`. The client is never blocked on the broker. If the broker is down, jobs still accept and drain later — the outbox absorbs it.

---

## Execute path

```mermaid
sequenceDiagram
    autonumber
    participant MQ as RabbitMQ
    participant W as worker
    participant PG as Postgres
    participant M as model adapter

    MQ->>W: deliver {job_id, attempt, traceparent}
    W->>PG: claim WHERE status='queued'
    alt zero rows
        W->>MQ: ack
        Note over W: duplicate — expected, metric not alert
    else claimed
        PG-->>W: job row + input_ref + version
        W->>W: start lease-renew task (every 10s)
        W->>PG: read payload from input_ref
        W->>M: infer(payload, deadline)
        M-->>W: result
        W->>PG: BEGIN
        W->>PG: INSERT job_payloads (result)
        W->>PG: UPDATE jobs SET status='done' WHERE version=?
        W->>PG: INSERT job_events (running -> done)
        W->>PG: COMMIT
        W->>MQ: ack
    end
```

**Durable before acknowledged.** The `COMMIT` precedes the `ack`. Reverse them and a crash in between silently loses the job; in this order a crash produces a redelivery, which the claim guard turns into a harmless duplicate skip.

---

## Transition ownership

Every transition has exactly one writer. Where two components could write the same transition, there is a race.

| Transition | Owner | Guard |
|---|---|---|
| `∅ → queued` | gateway | `INSERT`, unique on `idempotency_key` |
| `queued → running` | worker | `WHERE status = 'queued'` |
| `running → done` | worker | `WHERE version = ? AND lease_owner = ?` |
| `running → failed_retry → queued` | worker | `attempt < max_attempts` |
| `running → dead` | worker | `attempt >= max_attempts`, or terminal error |
| `running → queued` | reaper | `WHERE lease_expires_at < now()` |
| `queued → expired` | reaper | `WHERE deadline_at < now()` |

Full SQL for each: [[04_data_model#Guarded transitions]].

---

## Why the reaper exists

A worker claims a job, sets `status = 'running'`, then is `SIGKILL`ed.

RabbitMQ behaves correctly — the delivery was never acked, so it redelivers. But the row still says `running`, and the claim guard only accepts `queued`. The redelivery matches zero rows, the worker acks it as a duplicate, and the job is stranded in `running` **forever**, with no error and no alert. This is the worst class of bug: silent, permanent, and invisible to both systems involved.

The fix is a dead man's switch. On claim the worker sets `lease_expires_at = now() + 30s` and renews every 10 s while working. Liveness is proven by continued action, because a dead process cannot report its own death. The reaper releases anything whose lease has gone stale.

```mermaid
flowchart TD
    A["worker claims<br/>status=running, lease=+30s"] --> B["worker dies"]
    B --> C{"who notices?"}
    C -->|broker| D["delivery unacked<br/>knows nothing of the row"]
    C -->|database| E["row says running<br/>knows nothing of the delivery"]
    D --> F["reaper<br/>the third party"]
    E --> F
    F --> G["lease stale -> status=queued<br/>+ republish"]
```

The general shape, worth internalising: **two systems that can silently disagree need a third to reconcile them.** The broker knows the message is unacked. The database knows the row is running. Neither knows about the other, and neither can be taught to without coupling them.

---

## What the reaper is *not*

It is not a retry mechanism, and it must not become one. It only ever restores a row to a state the normal flow can pick up from. If you find yourself adding business logic to the reaper, the transition you are modelling has the wrong owner.

---

Next: [[02_tech_stack]]

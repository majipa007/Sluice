---
title: Sluice — Documentation Index
tags: [sluice, moc, index]
created: 23/08/2026
updated: 23/08/2026
---

# Sluice — Documentation Index

A resilient async inference runner. Go gateway, Python workers, RabbitMQ, Postgres.

The root `README.MD` states **why** the system exists and what it guarantees. These notes state **how** it gets built: exact libraries, exact SQL, exact queue arguments, exact phase gates.

---

## Read in this order

| # | Note | Answers |
|---|---|---|
| 1 | [[01_architecture]] | What processes exist, who owns which state transition, why a reaper is necessary |
| 2 | [[02_tech_stack]] | Which libraries, and what was rejected on what grounds |
| 3 | [[03_api_contract]] | Endpoints, status codes, error envelope, idempotency semantics |
| 4 | [[04_data_model]] | DDL, indexes, and the guarded SQL for every transition |
| 5 | [[05_messaging_topology]] | Exchanges, queues, DLQ, delayed retry, publisher confirms, outbox |
| 6 | [[06_worker_and_serving]] | Worker loop, model adapter interface, error taxonomy |
| 7 | [[07_reliability_and_drills]] | The five drills, failure modes, known gaps |
| 8 | [[08_observability]] | Metrics, traces, logs, the alerts worth having |
| 9 | [[09_project_layout]] | Directory tree, module boundaries, Makefile targets |
| 10 | [[10_roadmap]] | Phases, each with a done-gate |
| 11 | [[11_learning_plan]] | The same work sliced into 1–2 h sessions, with the Go concept each one teaches |
| 12 | [[12_session_log]] | Running log — where you stopped and what to do next |

**Building this?** Start at [[11_learning_plan#Stage A — Phase 0: foundations]] and keep [[12_session_log]] open. Read notes 1–4 first; the rest are reference you return to per session rather than read front to back.

---

## Locked decisions

| Layer | Choice | Note |
|---|---|---|
| HTTP router | `chi/v5` | `http.Handler` all the way down; no lock-in — see [[02_tech_stack#HTTP layer]] |
| Postgres driver | `pgx/v5` + `pgxpool` | |
| Query layer | `sqlc` | You write the guard SQL; it generates typed Go |
| Migrations | `goose/v3` | Plain SQL, embedded in the binary via `embed` |
| Broker client (Go) | `rabbitmq/amqp091-go` | Publisher with confirms |
| Broker client (Python) | `aio-pika` | Lease renewal as a sibling `asyncio.Task` |
| Claim-check store | Postgres `job_payloads` table | `db://` refs, swappable for `s3://` — see [[04_data_model#job_payloads]] |
| Logging | `log/slog` | stdlib, structured |
| Metrics | `prometheus/client_golang` | |
| Tracing | OpenTelemetry + `otelhttp` | W3C `traceparent` across the queue boundary |
| Python tooling | `uv` | |

---

## Refinements to the README

These notes deliberately differ from `README.MD` in seven places. Each is a correction or a sharpening, not a whim — the reasoning lives at the link.

1. **The claim needs no `version` guard.** `WHERE status = 'queued'` is already atomic and sufficient. Version earns its keep on the *result write*, not the claim → [[04_data_model#Why the claim needs no version guard]]
2. **Idempotent replay returns `200` with the existing `job_id`.** `409` is reserved for the same key reused with a *different* body → [[03_api_contract#Idempotency]]
3. **Dead-letter via `x-dead-letter-exchange` + `nack(requeue=false)`** rather than an explicit publish. Less code, and `x-death` headers come free → [[05_messaging_topology#Dead-lettering]]
4. **Partial indexes** on `lease_expires_at` and `deadline_at` instead of one composite `(status, lease_expires_at)` → [[04_data_model#Indexes]]
5. **`traceparent` travels in AMQP headers**, not the JSON body — propagators expect a carrier map, and tracing shouldn't be coupled to message schema → [[05_messaging_topology#Message contract]]
6. **Terminal vs transient errors.** A malformed payload dead-letters on attempt 1 instead of burning all three → [[06_worker_and_serving#Error taxonomy]]
7. **The reaper republishes when it requeues**, closing a gap of up to `CONSUMER_TIMEOUT` where the row says `queued` but no message is in flight → [[07_reliability_and_drills#The two clocks problem]]

---

## Phase status

Tracked in full at [[10_roadmap]].

| Phase | Gate | Status |
|---|---|---|
| 0 — Foundations | compose healthy, migrations run, `/readyz` green | not started |
| 1 — Happy path | submit → `done` | not started |
| 2 — Idempotency | duplicate replay returns same `job_id` | not started |
| 3 — Leases & reaper | **drill 1** | not started |
| 4 — Retries & DLQ | **drill 3** | not started |
| 5 — Admission control | **drill 4** | not started |
| 6 — Bulkheads & drain | **drill 2 + drill 5** | not started |
| 7 — Transactional outbox | kill gateway mid-submit, job still runs | not started |
| 8 — Observability | trace continuity end to end | not started |

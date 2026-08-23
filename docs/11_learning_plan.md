---
title: Learning Plan
tags: [sluice, learning, plan, go]
created: 23/08/2026
updated: 23/08/2026
---

# Learning Plan

Index: [[00_index]] · Roadmap: [[10_roadmap]] · Log: [[12_session_log]]

[[10_roadmap]] says *what* gets built and in what order. This note slices the same work into **sessions of 1–2 hours**, sized for a couple of days a week, and maps which Go concept each one teaches.

---

## Assumptions

| | |
|---|---|
| Cadence | 2–3 sessions/week, 1–2 h each — roughly 3 h/week |
| Go experience | has used `net/http`, understands it, not yet fluent |
| Distributed systems | first project of this kind |
| Who writes the code | Phase 0–1 mostly Claude, annotated · Phase 2+ mostly you, reviewed · boilerplate always Claude |

Change any of these and the session count moves. The **order** does not change — it is driven by what each concept depends on.

**Session markers:**

- ○ **Mechanical** — safe on a tired evening. Typing, config, wiring.
- ● **Conceptual** — wants a clear head. New idea, or a race to reason about.

Roughly one in three is `●`. Save those for a better day; do an `○` when you are low. Working out of order within a stage is fine as long as the dependencies hold.

---

## The honest timeline

**45 sessions ≈ 15–20 weeks ≈ 4–5 months** to Phase 8.

That is a long time, so here is where the payoffs actually land:

| Milestone | Session | Week (at 2–3/wk) |
|---|---|---|
| Infra, schema, config solid | 5 | ~2 |
| **First job end-to-end** | 12 | ~5 |
| Exactly-once proven by test | 17 | ~7 |
| **Drill 1 passes — the reaper works** | 23 | ~10 |
| Retries and DLQ | 28 | ~13 |
| **All five drills pass** | 36 | ~16 |
| Outbox + observability | 45 | ~20 |

**Session 36 is the real finish line** — five drills passing is the definition of done in `README.MD`. Phases 7 and 8 are hardening, worth doing but not what makes the project complete.

The two sessions to look forward to are 12 (a job you submitted comes back with a result) and 23 (you `SIGKILL` a worker and watch the system heal itself). Everything before each is in service of it.

---

## On learning Go alongside

**Do not do a Go course first.** This project introduces the language in a better order than any tutorial will, because each concept arrives when something needs it.

The lucky part: **you do not need goroutines until session 19.** Most Go material front-loads concurrency, which is backwards — you end up learning channels before you have a reason to want one. Here the first goroutine is the lease renewal loop, and it is a goroutine for an obvious reason. `context` cancellation lands the same way: you meet it because a worker that lost its lease must abandon work in flight.

Read just-in-time instead, roughly 15 minutes per topic as it comes up:

| When | Read |
|---|---|
| Session 3 | Effective Go — errors; `errors.Is` / `%w` wrapping |
| Session 4 | `net/http` — `Handler`, `HandlerFunc`; the `context` package intro |
| Session 5 | Effective Go — interfaces and embedding |
| Session 7 | `encoding/json` struct tags; pointers vs values |
| Session 19 | Tour of Go — goroutines, channels, `select`; `context.WithCancel` |
| Session 31 | `sync/atomic`, `sync.RWMutex` |
| Session 33 | `signal.NotifyContext`, graceful shutdown patterns |

Go by Example is the best quick reference for all of these.

---

## Stage A — Phase 0: foundations

**5 sessions.**

Goal: everything boots and reports its health honestly.

| # | | Focus | Teaches | Ends when |
|---|---|---|---|---|
| 1 | ○ | Repo skeleton, `go.mod` deps, fix `docker-compose.yaml` (healthchecks, `service_healthy`, `rabbitmq.conf`, `stop_grace_period`), Makefile | modules, packages, `go get` | `make up` → all three containers healthy |
| 2 | ○ | `migrations/00001_init.sql` — full DDL, constraints, partial indexes, `sluice_app` grants. goose wired with `embed` | `//go:embed`, error wrapping | `make migrate` clean; then **try to violate a CHECK by hand in psql** and watch it refuse |
| 3 | ● | `internal/config` — typed struct, defaults, the three boot invariants, table-driven test | structs, methods, `time.Duration`, sentinel errors, `%w`, table tests | `go test ./internal/config` green; a bad `LEASE_RENEW_INTERVAL` fails at boot with a readable message |
| 4 | ○ | `cmd/gateway` — chi router, pgxpool, `/healthz` `/readyz` `/metrics` | `http.Handler`, `context`, interfaces | **Phase 0 gate**: stop Postgres → `/readyz` `503` naming postgres, `/healthz` still `200` |
| 5 | ● | Hand-write `AccessLog` middleware **including the `statusWriter` wrapper**, then swap to chi's and diff them | closures, struct embedding, interface satisfaction | request logs show status + duration, and you can explain what `WrapResponseWriter` does |

Session 2's second half is the point of it: seeing `jobs_lease_consistency` reject a bad row teaches more about the design than writing the DDL did.

Session 5 is the deliberate answer to `net/http` having been a hassle before. You write the fiddly part **once, on purpose**, understand it, then let chi own it. One session instead of a week of accidental discovery.

---

## Stage B — Phase 1: happy path

**7 sessions.**

Goal: one job, submit to result. No failure handling yet.

| # | | Focus | Teaches | Ends when |
|---|---|---|---|---|
| 6 | ○ | `internal/job` domain types, `Status`; first sqlc queries (insert, get by id) | type declarations, `sqlc generate` loop | `make sqlc` generates; `go build` clean |
| 7 | ● | `POST /v1/jobs` — validate, `MaxBytesReader`, blob write + job row + event in **one transaction** | JSON tags, `pgx.BeginFunc`, `defer` | `curl` returns `202` with a `job_id`; all three rows present in psql |
| 8 | ○ | `GET /v1/jobs/{id}` and `/result`; `problem/` package for RFC 9457 | error types, `http.Error` alternatives | `GET` returns the job; unknown id returns `problem+json` `404` |
| 9 | ○ | `internal/broker` — declare topology, publish (no confirms yet) | third-party API, `amqp.Table` | message visible in the RabbitMQ UI after a submit |
| 10 | ○ | Python worker skeleton — `uv init`, pydantic-settings, aio-pika connect, consume, ack immediately | uv, asyncio entrypoint | worker drains the queue (doing nothing useful yet) |
| 11 | ● | Worker claim via asyncpg, read payload, `EchoAdapter` | asyncpg, `Protocol`, the claim guard | worker logs a claimed job and an inference result |
| 12 | ● | Write result + status in one tx, **then** ack | tx ordering, durable-before-ack | **Phase 1 gate**: submit → `done`, result matches, `job_events` shows `queued → running → done` |

Session 12 is the first real payoff. Stop and enjoy it.

---

## Stage C — Phase 2: idempotency and concurrency

**5 sessions.**

Goal: duplicates are harmless, and exactly-once is proven rather than asserted.

| # | | Focus | Teaches | Ends when |
|---|---|---|---|---|
| 13 | ● | `Idempotency-Key` header, `request_hash`, `ON CONFLICT DO NOTHING`, `200` on replay | `crypto/sha256`, `errors.Is(pgx.ErrNoRows)` | same key twice → same `job_id`, `200` |
| 14 | ● | `409` on key reuse with a different body; **the MVCC snapshot gotcha** | why the re-read must be a separate statement | different body, same key → `409` |
| 15 | ● | Version guard on `CompleteJob`; orphaned-result path | optimistic concurrency | a hand-forced stale version write is rejected |
| 16 | ○ | testcontainers-go harness, `//go:build integration`, `make test-int` | build tags, test fixtures | `make test-int` spins real Postgres and passes |
| 17 | ● | The 16-concurrent-claims test | goroutines in tests, `sync.WaitGroup`, `atomic` | **Phase 2 gate**: exactly one of 16 racers wins |

Session 17 is your first goroutines, and note *where* — in a test, proving a property. A gentler introduction than production concurrency.

---

## Stage D — Phase 3: leases and the reaper

**6 sessions.**

The heart of the system. Also the hardest stage.

| # | | Focus | Teaches | Ends when |
|---|---|---|---|---|
| 18 | ● | **Run drill 1 with no reaper.** Kill a worker mid-job and watch the job strand in `running` forever | the failure that justifies everything after it | you have seen `stuck` return a row that never resolves |
| 19 | ● | Lease columns on claim; renew loop as an asyncio task; **no version bump on renew** | asyncio tasks, cancellation | lease TTL visibly advances in psql during a long job |
| 20 | ● | `LeaseLost` detection, racing inference against loss | `asyncio.wait(FIRST_COMPLETED)` | manually expire a lease in psql → worker abandons within 10 s |
| 21 | ● | `cmd/reaper` — lease sweep, `FOR UPDATE SKIP LOCKED`, the `CASE` on exhausted attempts | first Go goroutine + `time.Ticker`, `context` cancellation | reaper logs a reclaim; two reapers running concurrently do not collide |
| 22 | ○ | Reaper republish on requeue; deadline sweep; interim `queued` sweep | same loop, more sweeps | a reclaimed job gets picked up again promptly |
| 23 | ● | **Drill 1 passes** | — | **Phase 3 gate**: four events, `attempt = 2`, exactly one `done` |

Session 18 exists because a failure you have watched is one you remember. Do not skip it to save an hour — it is the highest-value hour in the project.

---

## Stage E — Phase 4: retries and dead-lettering

**5 sessions.**

| # | | Focus | Teaches | Ends when |
|---|---|---|---|---|
| 24 | ○ | `TransientError` / `TerminalError`, classification table, `boom` + `unstable` stubs | exception hierarchies, type switches | `boom` dies on attempt 1 |
| 25 | ● | `attempt` counting, `RequeueForRetry`, `KillJob` | bounded retry logic | `unstable` reaches `attempt = 3` then `dead` |
| 26 | ○ | Retry tier queues — TTL + DLX, one queue per tier | AMQP queue arguments | message visibly parked in `job_retry_5s` |
| 27 | ○ | `job_dlq` via `x-dead-letter-exchange` + `nack(requeue=False)`; `x-delivery-limit` backstop | DLX semantics, `x-death` | dead job lands in `job_dlq` with a reason header |
| 28 | ● | **Drill 3, both variants** | — | **Phase 4 gate**: neither variant loops; both dead-letter |

---

## Stage F — Phase 5: admission control

**4 sessions.**

| # | | Focus | Teaches | Ends when |
|---|---|---|---|---|
| 29 | ○ | `deadline_at` checked before claim and before inference; deadline sweep | time arithmetic across processes | an old job expires instead of running |
| 30 | ○ | `job_payloads` retention purge on a slow reaper tick | **PDPA-relevant** — see [[04_data_model#Data retention and PDPA]] | payloads of old terminal jobs are gone; `job_events` survives |
| 31 | ● | Cached queue depth via `QueueDeclarePassive` behind a ticker | `sync.RWMutex` or `atomic.Int64`, cache invalidation | depth gauge tracks the UI without per-request calls |
| 32 | ● | `ShedOnQueueDepth` middleware on `POST` only; `429` + `Retry-After` | middleware composition, scoped routes | **Phase 5 gate — drill 4**: mix of `202`/`429`, depth plateaus |

---

## Stage G — Phase 6: bulkheads and drain

**4 sessions.**

| # | | Focus | Teaches | Ends when |
|---|---|---|---|---|
| 33 | ● | Worker graceful shutdown — `basic_cancel`, drain, `SHUTDOWN_GRACE` | signal handling, `asyncio.wait_for` | `SIGTERM` mid-job finishes the job then exits |
| 34 | ○ | Gateway `srv.Shutdown`, `signal.NotifyContext`; grace-period ordering | `os/signal`, context trees | no dropped connections on restart |
| 35 | ● | **Drill 2** — reproduce head-of-line blocking at `PREFETCH_COUNT=20`, then fix it | prefetch semantics | four workers visibly idle, then visibly busy |
| 36 | ● | **Drill 5** | — | **All five drills pass. README's definition of done.** |

---

## Stage H — Phase 7: transactional outbox

**4 sessions.**

| # | | Focus | Teaches | Ends when |
|---|---|---|---|---|
| 37 | ● | `outbox` insert in the job transaction; retire the direct publish | the pattern itself | job row and outbox row commit together |
| 38 | ● | `cmd/publisher` — `SKIP LOCKED` drain loop, publisher confirms, `mandatory`, `NotifyReturn` | deferred confirms, channels | publish is confirmed before the row is marked |
| 39 | ○ | `traceparent` persisted in `outbox.headers`, re-injected at publish | propagation across processes | trace survives the outbox hop |
| 40 | ● | **Gate**: stop RabbitMQ, submit 100 jobs, restart, watch all 100 drain | — | 100 × `202` with the broker down, then 100 × `done` |

---

## Stage I — Phase 8: observability and tooling

**5 sessions.**

| # | | Focus | Teaches | Ends when |
|---|---|---|---|---|
| 41 | ○ | Full metric set, correct buckets, `RoutePattern()` not `URL.Path` | Prometheus types, cardinality | `/metrics` shows the whole set |
| 42 | ● | OTel wiring end to end, `traceparent` in AMQP headers both sides | propagators, span kinds | one trace spans gateway and worker |
| 43 | ○ | slog with `job_id` + `trace_id` + `request_id` on every line | structured logging | one `request_id` finds trace and job |
| 44 | ○ | Dashboard — six panels; five alerts | PromQL basics | queue-wait vs service-time side by side |
| 45 | ● | `sluicectl dlq list / inspect / replay / purge` | CLI structure, `flag` or cobra | **Phase 8 gate**: replay a dead job, see both attempts in one history |

---

## Working protocol

**Start of session (5 min).** Read your last entry in [[12_session_log]]. Run `make up && make test`. If tests are red, that is the session — do not build on a broken base.

**End of session (5 min).** Commit, even if incomplete, on a branch. Append a log entry. **Write down the next concrete action** — not "continue the reaper" but "add the deadline sweep query to reaper.go, mirroring ReleaseStaleLeases". Future-you with a four-day gap needs a starting instruction, not a topic.

**If you only have one hour**, pick an `○`, or do just the first half of a `●` and log exactly where you stopped.

**If you are stuck for more than 20 minutes**, stop debugging and write down: what you expected, what happened, what you have ruled out. Bring that. Twenty minutes of being stuck is learning; ninety is attrition, and with 3 h a week it costs a third of your month.

**Never end a session mid-refactor.** Either finish the change or `git stash` it and log that you did. A half-migrated codebase is the most expensive thing to come back to.

---

## Scope discipline

The thing most likely to derail this is not difficulty, it is scope. At 3 h a week, one unplanned detour costs a fortnight.

Three temptations, all of which should be resisted until Phase 8:

- **A real model.** The stub is a design choice, not a placeholder. A real adapter teaches you nothing about the parts you are building here.
- **Kubernetes.** Compose is sufficient for all five drills, and `--scale` is exactly the control the drills need.
- **A web UI.** The RabbitMQ management console plus three psql helpers already answer every operational question. Building a UI is a second project.

Log the temptation in [[12_session_log]] and move on. Phase 9 in [[10_roadmap]] is where deferred ideas live, each with a trigger that says when it becomes worth building.

---
title: Tech Stack & Decisions
tags: [sluice, decisions, libraries]
created: 23/08/2026
updated: 23/08/2026
---

# Tech Stack & Decisions

Index: [[00_index]] · Prev: [[01_architecture]] · Next: [[03_api_contract]]

Each decision records what was chosen, what was rejected, and the reason. A decision without a rejected alternative is not a decision, it is a default.

---

## Go — gateway, reaper, outbox-publisher

```
go 1.22.2

github.com/go-chi/chi/v5
github.com/jackc/pgx/v5              // + pgxpool
github.com/rabbitmq/amqp091-go
github.com/pressly/goose/v3
github.com/prometheus/client_golang
github.com/google/uuid
go.opentelemetry.io/otel
go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp
go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc

// tools (not imported)
sqlc            // sqlc.dev — SQL -> typed Go
golangci-lint
github.com/testcontainers/testcontainers-go   // integration tests
```

### HTTP layer

**chi/v5.** Rejected: stdlib-only, gin, echo, fiber.

Go 1.22's `ServeMux` handles the routing fine — `POST /v1/jobs` and `GET /v1/jobs/{id}` are native. Routing was never the issue. Middleware is.

The gateway needs request ID, panic recovery, access logging, timeout, authn, OTel span, and shed-on-queue-depth. Writing that stack by hand means writing a `ResponseWriter` wrapper that correctly forwards `Flush`, `Hijack`, `ReadFrom`, and `Unwrap` — miss `Flush` and streaming breaks; miss `Unwrap` and `http.ResponseController` breaks. Both access logs and metrics need that wrapper. It is the one genuinely error-prone piece, and `chi/middleware.WrapResponseWriter` already has it right.

Critically, chi is **not a framework**: it is `http.Handler`, `http.HandlerFunc`, and `func(http.Handler) http.Handler`. Handlers stay stdlib-shaped, so `httptest`, `otelhttp`, and `promhttp` work unchanged, and removing chi later is mechanical. Learning chi *is* learning `net/http`.

`gin` and `echo` were rejected for real lock-in — `func(*gin.Context)` is not an `http.Handler`, so every handler and every middleware becomes framework-shaped. `fiber` was rejected outright: it is built on `fasthttp`, not `net/http`, which puts it outside the entire standard instrumentation ecosystem.

> **Middleware split.** Use chi's for generic plumbing (`RequestID`, `Recoverer`, `Timeout`, `WrapResponseWriter`). Hand-write the ones that are actually ours — `Auth`, `ShedOnQueueDepth`, `Deadline` — because those encode Sluice's behaviour and are worth understanding line by line.

### Postgres access

**pgx/v5 + pgxpool + sqlc.** Rejected: `database/sql` + `lib/pq`, raw pgx with hand-written scans, GORM, `sqlx`, ent.

`pgx` is the current standard for Postgres in Go: native protocol, real support for `uuid`, `timestamptz`, `jsonb`, `bytea`, and `COPY`, and a connection pool that is not `database/sql`'s lowest-common-denominator abstraction. `lib/pq` is in maintenance mode and should not be chosen for new work.

`sqlc` is the right fit specifically *because* this design depends on hand-written guard SQL. You write the `UPDATE ... WHERE status = 'queued' ... RETURNING *` yourself; sqlc reads it at build time against the real schema and generates a typed method. You keep total control of the SQL and lose every `rows.Scan` block. When a column is added, codegen fails loudly instead of a `Scan` silently drifting.

GORM was rejected because it fights this design at exactly the point that matters: optimistic-concurrency predicates, `RETURNING`, and `now() + interval` all need raw-SQL escape hatches, so you pay the ORM's cost and get none of its benefit. Raw pgx without sqlc is a reasonable second choice — the only loss is scan boilerplate.

### Migrations

**goose/v3.** Rejected: golang-migrate, atlas, sqlc-managed, GORM AutoMigrate.

Plain `.sql` files with `-- +goose Up` / `-- +goose Down`, embeddable via `//go:embed` so migrations ship inside the binary and cannot drift from the code that expects them. `atlas` is more capable (declarative diffing, linting) and worth revisiting if the schema grows; it is more machinery than four tables need. Never `AutoMigrate` — schema changes on a live table must be reviewed, not inferred.

### Broker client

**rabbitmq/amqp091-go.** Rejected: `streadway/amqp`, `wagslane/go-rabbitmq`.

`amqp091-go` is the maintained successor to `streadway/amqp`, adopted by the RabbitMQ team. It is deliberately low-level — you declare your own topology and manage your own reconnect loop. That is the correct trade here: [[05_messaging_topology]] depends on precise queue arguments and publisher confirms, and a convenience wrapper would obscure exactly the behaviour these drills exist to observe.

### Config

**Hand-written `internal/config`.** Rejected: viper, envconfig, koanf.

Roughly 80 lines that read environment variables into a typed struct, apply defaults, and **validate invariants at boot**. That last part is the reason to hand-write it: the config in [[README|README.MD]] has real cross-field constraints that a generic loader cannot express.

```go
// Fail at startup, not at 03:00 in production.
if c.LeaseRenewInterval >= c.LeaseTTL/2 {
    return fmt.Errorf("LEASE_RENEW_INTERVAL (%s) must be < LEASE_TTL/2 (%s): "+
        "a single missed renewal would expire a live lease",
        c.LeaseRenewInterval, c.LeaseTTL/2)
}
if c.ConsumerTimeout <= c.JobDeadlineDefault {
    return fmt.Errorf("CONSUMER_TIMEOUT (%s) must exceed JOB_DEADLINE_DEFAULT (%s): "+
        "the broker would kill the channel mid-job",
        c.ConsumerTimeout, c.JobDeadlineDefault)
}
if c.ShutdownGrace <= c.JobDeadlineDefault {
    return fmt.Errorf("SHUTDOWN_GRACE (%s) must exceed JOB_DEADLINE_DEFAULT (%s)",
        c.ShutdownGrace, c.JobDeadlineDefault)
}
```

Viper's file-watching, remote-config, and precedence layers are dead weight for a twelve-variable service.

### Observability

**`log/slog` + `prometheus/client_golang` + OpenTelemetry.** Rejected: zap/zerolog, OTel metrics.

`slog` is stdlib as of Go 1.21 and structurally good enough; the marginal throughput of zap does not matter for a service whose unit of work takes 20 ms to 40 s. Prometheus for metrics rather than the OTel metrics SDK, because `promhttp` scraping is simpler to run locally and the ecosystem around it is deeper. OTel for **traces only**, which is where it is unambiguously the standard — and the reason `traceparent` rides on every message.

---

## Python — worker

```toml
# worker/pyproject.toml  (managed with uv)
requires-python = ">=3.12"
dependencies = [
    "aio-pika>=9.4",
    "asyncpg>=0.29",
    "pydantic>=2.7",
    "pydantic-settings>=2.3",
    "prometheus-client>=0.20",
    "opentelemetry-sdk>=1.25",
    "opentelemetry-exporter-otlp>=1.25",
    "httpx>=0.27",          # for the vllm adapter later
]
[dependency-groups]
dev = ["pytest>=8", "pytest-asyncio>=0.23", "ruff>=0.5", "mypy>=1.10"]
```

### Package manager

**uv.** Rejected: poetry, pip-tools, bare pip.

`uv` has become the default choice for new Python projects: one tool for resolution, locking, virtualenvs, and Python installation, with a committed `uv.lock`. Order-of-magnitude faster than poetry, and `uv run` makes the Makefile targets trivial.

### AMQP client

**aio-pika.** Rejected: `pika`, `kombu`, Celery.

The worker must renew its lease every 10 s *while* an inference call is in flight. Under `asyncio` that is a sibling task and nothing more. With blocking `pika` you may not touch the connection from another thread, so renewal has to go through `connection.add_callback_threadsafe` — correct but easy to get subtly wrong, and the failure mode is a silently expired lease.

Blocking model calls stay off the event loop via `asyncio.to_thread`, so a real GPU-bound adapter behaves correctly too.

**Celery was rejected deliberately, and it is the most important rejection here.** Celery would supply the queue plumbing, retries, and a result backend out of the box — and in doing so it would hide the claim guard, the lease, the reaper, and the ack ordering behind its own abstractions. Those are not incidental to Sluice; they *are* Sluice. Reach for Celery when you want the problem solved. Build this when you want to understand it. (See also the [[README|README.MD]] non-goal: not a workflow engine.)

### Postgres driver

**asyncpg.** Rejected: `psycopg3`, SQLAlchemy.

Native asyncio, fast, and the worker's query set is five statements — an ORM would be pure overhead. `psycopg3` with async support is a fine alternative; `asyncpg` is faster and the API is smaller.

---

## Local infrastructure

| Service | Image | Ports | Note |
|---|---|---|---|
| postgres | `postgres:17-alpine` | `5432` | already running |
| rabbitmq | `rabbitmq:4-management` | `5672`, `15672` | needs a mounted `rabbitmq.conf` for `consumer_timeout` |
| pg-admin | `dpage/pgadmin4` | `5050` | connect to host `postgres`, not `localhost` |

Two fixes needed on the current `docker-compose.yaml`:

1. **Healthchecks plus `depends_on: condition: service_healthy`.** Bare `depends_on` waits for the container to *start*, not to be *ready* — so the gateway currently races Postgres on a cold boot.
2. **A mounted `rabbitmq.conf`** to set `consumer_timeout`. The default is 30 min; a job that legitimately runs longer has its channel closed mid-flight, which looks exactly like a worker crash.

```conf
# deploy/rabbitmq.conf
consumer_timeout = 900000   # 15 min, in ms — must exceed p99 job duration
```

```yaml
# healthchecks to add
postgres:
  healthcheck:
    test: ["CMD-SHELL", "pg_isready -U postgres -d sluice"]
    interval: 5s
    timeout: 3s
    retries: 10
rabbitmq:
  healthcheck:
    test: ["CMD", "rabbitmq-diagnostics", "-q", "check_running"]
    interval: 10s
    timeout: 5s
    retries: 10
```

> Credentials in `docker-compose.yaml` are local-development values only. Anything deployed beyond a laptop must take them from a secret store, and the pgAdmin login should be a placeholder such as `[admin_email]` in any committed example.

---

Next: [[03_api_contract]]

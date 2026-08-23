---
title: Session Log
tags: [sluice, log, progress]
created: 23/08/2026
updated: 23/08/2026
---

# Session Log

Index: [[00_index]] · Plan: [[11_learning_plan]]

Newest entry at the top. Two minutes to write, and it is what makes a four-day gap cost five minutes instead of forty.

The field that matters most is **Next action** — write it as an instruction to someone who has forgotten everything, because in four days that is who reads it.

---

## Template

```markdown
## Session NN — DD/MM/YYYY — <stage/phase>

**Did:** one or two lines. What actually landed.

**Next action:** one concrete instruction. A file and a change, not a topic.

**Open question:** anything unresolved, or blank.

**Learned:** the Go or systems thing that clicked. Blank is fine.

**Parked:** a temptation you resisted, so it is captured rather than nagging.
```

Copy that block, fill it in, put it above the previous entry.

---

## Worked example

Not a real entry — this is what a good one looks like.

```markdown
## Session 21 — 06/10/2026 — Stage D, Phase 3

**Did:** cmd/reaper with the lease sweep. Ticker loop + graceful stop on
SIGTERM. Watched it reclaim a job I killed by hand. Ran two reapers at once
and confirmed SKIP LOCKED keeps them off each other's rows.

**Next action:** add ExpireOverdueJobs to internal/store/queries/jobs.sql,
mirroring ReleaseStaleLeases but on deadline_at with status='queued'. Then
call it from the same tick in reaper.go. Query is written in
04_data_model#Reaper — expire overdue jobs, just needs wiring.

**Open question:** REAPER_BATCH_SIZE is hardcoded to 100. Should it be config?
Leaving it until there is a reason.

**Learned:** context cancellation finally clicked. The ticker loop selects on
ctx.Done() and the ticker channel, so SIGTERM stops it between sweeps rather
than mid-sweep. Same shape as the worker's renew loop — one pattern, twice.

**Parked:** wanted to add a /v1/admin/jobs endpoint to watch state without
psql. The census helper in 07_reliability_and_drills already does this.
Not now.
```

---

## Entries

<!-- newest first -->

## Session 01 — 23/08/2026 — Stage A, Phase 0 (non-Go half)

**Did:** Everything in Phase 0 that is not Go.

- `docker-compose.yaml` — explicit `name: sluice`, healthchecks on postgres
  and rabbitmq, `depends_on: condition: service_healthy`, `.env` indirection
  with dev fallbacks, `deploy/rabbitmq.conf` mounted to
  `conf.d/20-sluice.conf`. Kept at the repo **root**, not moved to `deploy/`,
  because Compose derives the project name from the directory and the move
  would have orphaned `sluice_postgres-data`.
- `deploy/rabbitmq.conf` — `consumer_timeout = 900000`. **Verified in effect:**
  `rabbitmqctl eval` returns `{ok,900000}`, and the image's own
  `10-defaults.conf` survives alongside it.
- `migrations/00001_init.sql` — all four tables, 5 CHECK constraints, 3 partial
  indexes, `updated_at` trigger. Applied to a **scratch database** and verified,
  then dropped, so `sluice` has no goose state yet and session 2 owns the first
  real `up`.
- `deploy/sql/01_app_role.sql` — `sluice_app` role, no password in git,
  least-privilege grants. No UPDATE/DELETE on `job_events`, so append-only is
  enforced by the database rather than by convention.
- `sqlc.yaml`, `internal/store/queries/{jobs,events,payloads}.sql` — Phase 0–1
  queries only; the reaper/retry SQL is left as TODOs naming its doc section so
  the session staging holds.
- `Makefile`, `deploy/env.example`, `.gitignore`.

**Verified:** all 5 CHECKs reject correctly (`jobs_lease_consistency`,
`jobs_done_has_result`, `jobs_attempt_bounded`, `jobs_status_valid`,
`job_payloads_kind_check`); `byte_size` generated column computes; the
`updated_at` trigger fires; `ON DELETE CASCADE` leaves no orphaned payloads;
`docker compose up -d --wait` reports all three healthy and pg-admin starts
only after postgres is Healthy.

**Toolchain (was a blocker, now resolved).** Go was not installed at all.
Installed Go 1.27 via mise, then added `goose` and `sqlc` as project-local
pinned tools in `mise.toml`. `go.mod` is back to two lines.

Tried `go get -tool` first and reverted it: goose's CLI bundles drivers for
ClickHouse, MSSQL, MySQL, Vertica, YDB, Turso and SQLite, so pinning it in
go.mod pulled **60+ indirect dependencies** into a Postgres-only project and
silently bumped the go directive to 1.25.7. Both tools are standalone binaries
this app never imports, so they belong in the tool manager rather than the
app's dependency graph. Versions in `mise.toml` are exact, not `latest` —
sqlc generates code, so an unpinned version could quietly emit different Go
from identical SQL.

**Verified working:** `make dev` runs end to end and is idempotent —
containers healthy, `goose up` applied `00001_init.sql` (version 1 recorded),
grants applied, `sluice_app` password set, 6 fixtures loaded. `sqlc compile`
passes, so `sqlc.yaml` plus the schema and all queries are valid.

**Next action:** session 2's Go half — wire goose behind `//go:embed` so
migrations ship inside the binary, replacing the CLI call in the `migrate`
target. Spec: [[09_project_layout#Migrations]]. After that, session 3 is
`internal/config`.

**Open question:** `go.mod` says `go 1.24` while mise installs Go 1.27. That is
deliberate — 1.24 is the minimum for the language features used and keeps the
module buildable on older toolchains. Revisit only if something needs newer.

**Learned:** `depends_on: condition: service_healthy` is observable in the
`up --wait` output — pg-admin's "Starting" appears only after postgres logs
"Healthy". Bare `depends_on` would have started them together, which is the
cold-boot race the docs warned about.

**Parked:** nothing.

## Session 00 — 23/08/2026 — planning

**Did:** Infra running (postgres, rabbitmq, pg-admin). Added a host port
mapping for postgres. Wrote docs 00–12: architecture, stack decisions, API
contract, data model, messaging topology, worker design, drills,
observability, layout, roadmap, and this plan.

**Stack locked:** chi v5 · pgx v5 + sqlc · goose · amqp091-go · aio-pika +
asyncpg + uv · Postgres job_payloads for claim check · slog + Prometheus +
OTel traces.

**Next action:** Session 1 in [[11_learning_plan]] — fix
`docker-compose.yaml` (healthchecks, `depends_on: condition:
service_healthy`, mounted `deploy/rabbitmq.conf` with `consumer_timeout =
900000`, `stop_grace_period: 120s` on the worker), then add the Makefile with
`up` / `down` / `logs` / `migrate`. Done when `make up` reports all
containers healthy.

**Open question:** none.

**Learned:** chi is `http.Handler` all the way down, so learning it *is*
learning `net/http` — the fiddly part being skipped is only the
ResponseWriter wrapper, which gets hand-written once in session 5 on purpose.

**Parked:** nothing yet.

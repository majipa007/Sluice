# Sluice — dev tasks. Requires tabs, not spaces.
# Load .env if present; every var below has a dev-safe fallback so a missing
# .env is never fatal.
-include .env
export

POSTGRES_USER     ?= postgres
POSTGRES_PASSWORD ?= postgres_password
POSTGRES_DB       ?= sluice
POSTGRES_HOST     ?= localhost
POSTGRES_PORT     ?= 5432
SLUICE_APP_PASSWORD ?= sluice_app_dev_password

DATABASE_URL ?= postgres://$(POSTGRES_USER):$(POSTGRES_PASSWORD)@$(POSTGRES_HOST):$(POSTGRES_PORT)/$(POSTGRES_DB)?sslmode=disable
PSQL := docker compose exec -T postgres psql -v ON_ERROR_STOP=1 -U $(POSTGRES_USER) -d $(POSTGRES_DB)

.DEFAULT_GOAL := help
.PHONY: help tools dev ready wait-db services db-shell run up down nuke logs ps psql \
        migrate migrate-down migrate-status \
        db-grants db-app-password db-setup verify-schema seed seed-show seed-clean \
        sqlc build test test-int lint fmt

help: ## list targets
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

## --- infrastructure -------------------------------------------------------

dev: up db-setup seed ## fresh start: infra up, schema applied, fixtures loaded
	@echo "ready — pgAdmin :5050  rabbitmq :15672"

ready: up db-setup ## like dev but WITHOUT fixtures — used on workspace open
	@echo "ready — pgAdmin :5050  rabbitmq :15672"

wait-db: ## block until postgres accepts connections (no setup, no migrations)
	@until docker compose exec -T postgres \
	  pg_isready -U $(POSTGRES_USER) -d $(POSTGRES_DB) >/dev/null 2>&1; \
	do sleep 1; done

## --- workspace entrypoints (herdr-spreader panes) ------------------------
# Single-word commands on purpose: the pane config stays free of shell
# operators, so it does not matter whether the runner uses a shell or execs
# directly. Sequencing belongs in make, not in a YAML string.

services: ## services pane: infra to ready, then lazydocker
	@$(MAKE) --no-print-directory ready
	lazydocker

db-shell: ## db pane: wait for postgres, then psql
	@$(MAKE) --no-print-directory wait-db
	docker compose exec postgres psql -U $(POSTGRES_USER) -d $(POSTGRES_DB)

run: ## server pane: run the gateway (exists from session 4)
	@test -d cmd/gateway || { \
	  echo "cmd/gateway does not exist yet — that is session 4."; \
	  echo "See docs/11_learning_plan.md. Next up is session 2: goose behind //go:embed."; \
	  exit 1; }
	@$(MAKE) --no-print-directory wait-db
	go run ./cmd/gateway

up: ## start infra and wait for healthchecks to pass
	docker compose up -d --wait

down: ## stop containers, keep volumes
	docker compose down

nuke: ## stop AND DELETE volumes — destroys all job history
	@printf 'This deletes postgres-data, rabbitmq-data, pg-admin-data. Type yes: ' \
	  && read ans && [ "$$ans" = yes ] && docker compose down -v

logs: ## follow infra logs
	docker compose logs -f

ps: ## container status
	docker compose ps

psql: ## interactive psql shell
	docker compose exec postgres psql -U $(POSTGRES_USER) -d $(POSTGRES_DB)

## --- database -------------------------------------------------------------

db-setup: migrate db-grants db-app-password ## migrate + grants + app password

migrate: ## apply migrations (embedded ia goose library, cmd/ migrate)
	go run ./cmd/migrate

migrate-down: ## roll back one migration
	goose -dir migrations postgres "$(DATABASE_URL)" down

migrate-status: ## show applied migrations
	goose -dir migrations postgres "$(DATABASE_URL)" status

db-grants: ## create sluice_app role and apply least-privilege grants
	$(PSQL) -f - < deploy/sql/01_app_role.sql

db-app-password: ## set sluice_app password from .env (never in git)
	@$(PSQL) -c "ALTER ROLE sluice_app PASSWORD '$(SLUICE_APP_PASSWORD)';" >/dev/null \
	  && echo "sluice_app password set from SLUICE_APP_PASSWORD"

seed: ## load dev fixtures — 6 jobs, one per status (local only)
	@$(PSQL) -q -f - < deploy/sql/dev_fixtures.sql && echo "fixtures loaded"
	@$(MAKE) --no-print-directory seed-show

seed-show: ## show what the fixtures look like
	@$(PSQL) -c "SELECT right(id::text,4) AS id, idempotency_key, status, attempt, \
	  CASE WHEN lease_expires_at IS NULL THEN '-' \
	       WHEN lease_expires_at < now() THEN 'STALE' ELSE 'ok' END AS lease \
	  FROM jobs WHERE idempotency_key LIKE 'fixture_%' ORDER BY idempotency_key;"

seed-clean: ## remove ALL job data (fixtures and real)
	@$(PSQL) -q -c "TRUNCATE jobs CASCADE;" && echo "all job data removed"

verify-schema: ## prove the Phase 0 schema landed correctly
	@echo '--- tables ---'
	@$(PSQL) -c "\dt"
	@echo '--- constraints on jobs ---'
	@$(PSQL) -tAc "SELECT conname, contype FROM pg_constraint \
	  WHERE conrelid = 'jobs'::regclass ORDER BY conname;"
	@echo '--- indexes (partial ones show a WHERE clause) ---'
	@$(PSQL) -tAc "SELECT indexname, indexdef FROM pg_indexes \
	  WHERE schemaname = 'public' ORDER BY indexname;"
	@echo '--- sluice_app grants ---'
	@$(PSQL) -tAc "SELECT table_name, string_agg(privilege_type, ',' ORDER BY privilege_type) \
	  FROM information_schema.table_privileges WHERE grantee = 'sluice_app' \
	  GROUP BY table_name ORDER BY table_name;"

## --- code -----------------------------------------------------------------

sqlc: ## regenerate typed Go from queries, then prove callers still compile
	sqlc generate
	go build ./...

build: ## build all binaries
	go build -o bin/ ./cmd/...

test: ## unit tests only, no containers
	go test ./...

test-int: ## integration tests against real Postgres + RabbitMQ
	go test -tags=integration -count=1 ./...

lint:
	golangci-lint run

fmt:
	go fmt ./...

## --- setup ----------------------------------------------------------------

tools: ## install pinned CLI tools (versions live in mise.toml)
	mise install
	@mise exec -- goose --version && mise exec -- sqlc version

# Why mise and not `go get -tool`: goose's CLI bundles drivers for ClickHouse,
# MSSQL, MySQL, Vertica, YDB, Turso and SQLite, so pinning it in go.mod drags
# 60+ indirect deps into a Postgres-only project and makes go.mod unreadable.
# goose and sqlc are standalone binaries this app never imports, so they belong
# in the tool manager, not in the app's dependency graph. mise.toml pins the
# versions per-project, which is what `go tool` was buying us.

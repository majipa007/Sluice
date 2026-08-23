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
.PHONY: help tools up down nuke logs ps psql migrate migrate-down migrate-status \
        db-grants db-app-password db-setup verify-schema sqlc build test test-int lint fmt

help: ## list targets
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

## --- infrastructure -------------------------------------------------------

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

migrate: ## apply migrations (goose CLI; session 2 adds the embedded path)
	goose -dir migrations postgres "$(DATABASE_URL)" up

migrate-down: ## roll back one migration
	goose -dir migrations postgres "$(DATABASE_URL)" down

migrate-status: ## show applied migrations
	goose -dir migrations postgres "$(DATABASE_URL)" status

db-grants: ## create sluice_app role and apply least-privilege grants
	$(PSQL) -f - < deploy/sql/01_app_role.sql

db-app-password: ## set sluice_app password from .env (never in git)
	@$(PSQL) -c "ALTER ROLE sluice_app PASSWORD '$(SLUICE_APP_PASSWORD)';" >/dev/null \
	  && echo "sluice_app password set from SLUICE_APP_PASSWORD"

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

tools: ## install goose and sqlc CLIs
	go install github.com/pressly/goose/v3/cmd/goose@latest
	go install github.com/sqlc-dev/sqlc/cmd/sqlc@latest
	@echo "ensure $$(go env GOPATH)/bin is on PATH"

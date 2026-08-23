-- Application role and grants. Applied by `make db-grants`, after migrations.
--
-- Kept out of migrations/ on purpose: roles are cluster-level provisioning
-- rather than per-database schema, and pointing sqlc at migrations/ means
-- anything in there must be parseable schema DDL.
--
-- Least privilege, two deliberate consequences:
--   * No UPDATE or DELETE on job_events, which makes the audit log
--     append-only STRUCTURALLY rather than by a convention a future bug
--     can violate.
--   * DELETE on job_payloads exists solely for the retention purge
--     (docs/04_data_model.md#Data retention and PDPA).
--
-- Migrations run as the owner; services connect as sluice_app. No service
-- ever connects as a superuser.

-- The role is created WITHOUT a password. Credentials must not live in
-- version control — `make db-app-password` sets it from .env. Until then the
-- role exists but cannot authenticate, which is the safe default.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'sluice_app') THEN
        CREATE ROLE sluice_app LOGIN;
    END IF;
END
$$;

GRANT CONNECT ON DATABASE sluice TO sluice_app;
GRANT USAGE   ON SCHEMA public   TO sluice_app;

GRANT SELECT, INSERT, UPDATE         ON jobs         TO sluice_app;
GRANT SELECT, INSERT                 ON job_events   TO sluice_app;  -- append-only
GRANT SELECT, INSERT, DELETE         ON job_payloads TO sluice_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON outbox       TO sluice_app;

GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO sluice_app;

-- Revoke the implicit public-schema create right (PG15+ already restricts
-- this, but being explicit costs nothing).
REVOKE CREATE ON SCHEMA public FROM PUBLIC;

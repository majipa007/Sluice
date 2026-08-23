-- Sluice initial schema: jobs, job_events, job_payloads, outbox.
-- Reference: docs/04_data_model.md
--
-- Roles and grants are deliberately NOT here — see deploy/sql/01_app_role.sql.
-- Roles are cluster-level provisioning, not per-database schema, and goose's
-- version table should not claim to own them.

-- +goose Up

CREATE TABLE jobs (
    id                uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    idempotency_key   text        NOT NULL,
    request_hash      bytea       NOT NULL,
    model_id          text        NOT NULL,
    status            text        NOT NULL DEFAULT 'queued',
    attempt           int         NOT NULL DEFAULT 0,
    max_attempts      int         NOT NULL DEFAULT 3,
    version           int         NOT NULL DEFAULT 1,
    lease_owner       text,
    lease_expires_at  timestamptz,
    deadline_at       timestamptz NOT NULL,
    input_ref         text        NOT NULL,
    result_ref        text,
    error_code        text,
    error_detail      text,
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT jobs_idempotency_key_uniq UNIQUE (idempotency_key),

    CONSTRAINT jobs_status_valid CHECK (
        status IN ('queued', 'running', 'done', 'dead', 'expired')
    ),

    CONSTRAINT jobs_attempt_bounded CHECK (attempt <= max_attempts),

    -- A lease exists exactly when the job is running. Makes "running with
    -- nobody holding it" unrepresentable, which forces every exit from
    -- running to clear the lease.
    CONSTRAINT jobs_lease_consistency CHECK (
        (status = 'running')
        = (lease_owner IS NOT NULL AND lease_expires_at IS NOT NULL)
    ),

    -- A done job always has a result to collect.
    CONSTRAINT jobs_done_has_result CHECK (
        status <> 'done' OR result_ref IS NOT NULL
    )
);

CREATE TABLE job_events (
    id          bigserial   PRIMARY KEY,
    job_id      uuid        NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
    from_status text,                      -- NULL on creation
    to_status   text        NOT NULL,
    actor       text        NOT NULL,      -- gateway | worker:<id> | reaper:<id>
    attempt     int         NOT NULL,
    detail      jsonb,                     -- never payload content; see PDPA note
    created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE job_payloads (
    job_id       uuid        NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
    kind         text        NOT NULL CHECK (kind IN ('input', 'result')),
    content_type text        NOT NULL DEFAULT 'application/octet-stream',
    body         bytea       NOT NULL,
    byte_size    int         GENERATED ALWAYS AS (octet_length(body)) STORED,
    created_at   timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (job_id, kind)
);

CREATE TABLE outbox (
    id           bigserial   PRIMARY KEY,
    job_id       uuid        NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
    exchange     text        NOT NULL,
    routing_key  text        NOT NULL,
    payload      jsonb       NOT NULL,
    headers      jsonb       NOT NULL DEFAULT '{}',
    attempt      int         NOT NULL DEFAULT 0,
    published_at timestamptz,
    created_at   timestamptz NOT NULL DEFAULT now()
);

-- Indexes -------------------------------------------------------------------
-- Three of four are partial. Both reaper sweeps run every 10s forever, so
-- their cost must scale with work in flight, not with total history.

-- Reaper lease sweep. Only running rows can hold a stale lease.
CREATE INDEX jobs_stale_lease_idx ON jobs (lease_expires_at)
    WHERE status = 'running';

-- Reaper deadline sweep.
CREATE INDEX jobs_deadline_idx ON jobs (deadline_at)
    WHERE status = 'queued';

-- Audit read path: "how did this job get here?"
CREATE INDEX job_events_job_idx ON job_events (job_id, created_at);

-- Outbox drain. Normally near-empty, and the index reflects that.
CREATE INDEX outbox_pending_idx ON outbox (created_at)
    WHERE published_at IS NULL;

-- updated_at ----------------------------------------------------------------
-- A trigger rather than a column set by hand in every UPDATE. It is the one
-- field that is pure bookkeeping, and forgetting it in a single statement
-- produces a quietly wrong audit trail.

-- +goose StatementBegin
CREATE FUNCTION set_updated_at() RETURNS trigger AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
-- +goose StatementEnd

CREATE TRIGGER jobs_updated_at BEFORE UPDATE ON jobs
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- +goose Down

DROP TRIGGER IF EXISTS jobs_updated_at ON jobs;
DROP FUNCTION IF EXISTS set_updated_at();
DROP TABLE IF EXISTS outbox;
DROP TABLE IF EXISTS job_payloads;
DROP TABLE IF EXISTS job_events;
DROP TABLE IF EXISTS jobs;

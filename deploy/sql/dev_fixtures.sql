-- DEV FIXTURES — local development only. Applied by `make seed`.
--
-- NOT a seed file and NOT a migration, on purpose:
--   * Seeds are reference data an app needs to function. Sluice has none —
--     every row in every table is created by the system at runtime.
--   * Migrations run in every environment. Fake jobs must never be one.
--
-- These rows exist so you can look at the data model before the API exists.
-- Once the gateway works (Phase 1), create jobs with `curl` instead: going
-- through POST /v1/jobs exercises validation, request hashing, and the outbox,
-- none of which raw INSERTs touch. Fixtures made by hand are shaped roughly
-- like real rows, not exactly.
--
-- Fixed UUIDs so re-running is predictable and rows are easy to reference.

BEGIN;

-- Idempotent: clear only the fixture rows, leave anything real alone.
DELETE FROM jobs WHERE id IN (
    '00000000-0000-0000-0000-000000000001',
    '00000000-0000-0000-0000-000000000002',
    '00000000-0000-0000-0000-000000000003',
    '00000000-0000-0000-0000-000000000004',
    '00000000-0000-0000-0000-000000000005',
    '00000000-0000-0000-0000-000000000006'
);  -- ON DELETE CASCADE removes their events, payloads and outbox rows

-- 1. queued — waiting for a worker. The normal starting state.
INSERT INTO jobs (id, idempotency_key, request_hash, model_id, status,
                  attempt, deadline_at, input_ref, created_at)
VALUES ('00000000-0000-0000-0000-000000000001', 'fixture_queued',
        sha256('queued'::bytea), 'echo', 'queued', 0,
        now() + interval '5 minutes',
        'db://job_payloads/00000000-0000-0000-0000-000000000001?kind=input',
        now() - interval '10 seconds');

-- 2. running, lease HEALTHY — a worker holds it and is renewing.
INSERT INTO jobs (id, idempotency_key, request_hash, model_id, status,
                  attempt, version, lease_owner, lease_expires_at,
                  deadline_at, input_ref, created_at)
VALUES ('00000000-0000-0000-0000-000000000002', 'fixture_running_ok',
        sha256('running_ok'::bytea), 'echo', 'running', 1, 2,
        'worker:host-a:1234:aabbccdd', now() + interval '25 seconds',
        now() + interval '4 minutes',
        'db://job_payloads/00000000-0000-0000-0000-000000000002?kind=input',
        now() - interval '35 seconds');

-- 3. running, lease STALE — the worker died. This is what the reaper hunts,
--    and what the `stuck` helper in the drills harness finds. Until the reaper
--    exists (Phase 3) this row sits here forever, which is exactly the failure
--    drill 1 is designed to show you.
INSERT INTO jobs (id, idempotency_key, request_hash, model_id, status,
                  attempt, version, lease_owner, lease_expires_at,
                  deadline_at, input_ref, created_at)
VALUES ('00000000-0000-0000-0000-000000000003', 'fixture_running_stale',
        sha256('running_stale'::bytea), 'slow', 'running', 1, 2,
        'worker:host-b:5678:eeff0011', now() - interval '45 seconds',
        now() + interval '3 minutes',
        'db://job_payloads/00000000-0000-0000-0000-000000000003?kind=input',
        now() - interval '2 minutes');

-- 4. done — finished, result collectable.
INSERT INTO jobs (id, idempotency_key, request_hash, model_id, status,
                  attempt, version, deadline_at, input_ref, result_ref,
                  created_at)
VALUES ('00000000-0000-0000-0000-000000000004', 'fixture_done',
        sha256('done'::bytea), 'echo', 'done', 1, 3,
        now() + interval '2 minutes',
        'db://job_payloads/00000000-0000-0000-0000-000000000004?kind=input',
        'db://job_payloads/00000000-0000-0000-0000-000000000004?kind=result',
        now() - interval '3 minutes');

-- 5. dead — exhausted its attempts. Note attempt = max_attempts.
INSERT INTO jobs (id, idempotency_key, request_hash, model_id, status,
                  attempt, max_attempts, version, deadline_at, input_ref,
                  error_code, error_detail, created_at)
VALUES ('00000000-0000-0000-0000-000000000005', 'fixture_dead',
        sha256('dead'::bytea), 'unstable', 'dead', 3, 3, 7,
        now() + interval '1 minute',
        'db://job_payloads/00000000-0000-0000-0000-000000000005?kind=input',
        'upstream_unavailable', 'connection refused after 3 attempts',
        now() - interval '5 minutes');

-- 6. expired — deadline passed before a worker ever picked it up.
INSERT INTO jobs (id, idempotency_key, request_hash, model_id, status,
                  attempt, version, deadline_at, input_ref, error_code,
                  created_at)
VALUES ('00000000-0000-0000-0000-000000000006', 'fixture_expired',
        sha256('expired'::bytea), 'echo', 'expired', 0, 2,
        now() - interval '30 seconds',
        'db://job_payloads/00000000-0000-0000-0000-000000000006?kind=input',
        'deadline_exceeded', now() - interval '6 minutes');

-- Payloads. Every job has an input; only the done one has a result.
INSERT INTO job_payloads (job_id, kind, content_type, body)
SELECT id, 'input', 'text/plain', ('hello from ' || idempotency_key)::bytea
  FROM jobs WHERE idempotency_key LIKE 'fixture_%';

INSERT INTO job_payloads (job_id, kind, content_type, body)
VALUES ('00000000-0000-0000-0000-000000000004', 'result', 'text/plain',
        'hello from fixture_done'::bytea);

-- Event history. This is the table that explains how each job got where it is.
-- Note the dead one: three attempts, each with its own claim and failure.
INSERT INTO job_events (job_id, from_status, to_status, actor, attempt, created_at)
VALUES
  ('00000000-0000-0000-0000-000000000001', NULL, 'queued', 'gateway', 0, now() - interval '10 seconds'),

  ('00000000-0000-0000-0000-000000000002', NULL, 'queued', 'gateway', 0, now() - interval '35 seconds'),
  ('00000000-0000-0000-0000-000000000002', 'queued', 'running', 'worker:host-a:1234:aabbccdd', 1, now() - interval '30 seconds'),

  ('00000000-0000-0000-0000-000000000003', NULL, 'queued', 'gateway', 0, now() - interval '2 minutes'),
  ('00000000-0000-0000-0000-000000000003', 'queued', 'running', 'worker:host-b:5678:eeff0011', 1, now() - interval '105 seconds'),

  ('00000000-0000-0000-0000-000000000004', NULL, 'queued', 'gateway', 0, now() - interval '3 minutes'),
  ('00000000-0000-0000-0000-000000000004', 'queued', 'running', 'worker:host-a:1234:aabbccdd', 1, now() - interval '170 seconds'),
  ('00000000-0000-0000-0000-000000000004', 'running', 'done', 'worker:host-a:1234:aabbccdd', 1, now() - interval '160 seconds'),

  ('00000000-0000-0000-0000-000000000005', NULL, 'queued', 'gateway', 0, now() - interval '5 minutes'),
  ('00000000-0000-0000-0000-000000000005', 'queued', 'running', 'worker:host-a:1234:aabbccdd', 1, now() - interval '295 seconds'),
  ('00000000-0000-0000-0000-000000000005', 'running', 'queued', 'worker:host-a:1234:aabbccdd', 1, now() - interval '290 seconds'),
  ('00000000-0000-0000-0000-000000000005', 'queued', 'running', 'worker:host-b:5678:eeff0011', 2, now() - interval '280 seconds'),
  ('00000000-0000-0000-0000-000000000005', 'running', 'queued', 'worker:host-b:5678:eeff0011', 2, now() - interval '275 seconds'),
  ('00000000-0000-0000-0000-000000000005', 'queued', 'running', 'worker:host-b:5678:eeff0011', 3, now() - interval '250 seconds'),
  ('00000000-0000-0000-0000-000000000005', 'running', 'dead', 'worker:host-b:5678:eeff0011', 3, now() - interval '245 seconds'),

  ('00000000-0000-0000-0000-000000000006', NULL, 'queued', 'gateway', 0, now() - interval '6 minutes'),
  ('00000000-0000-0000-0000-000000000006', 'queued', 'expired', 'reaper:host-c:9012:22334455', 0, now() - interval '25 seconds');

COMMIT;

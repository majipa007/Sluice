-- Job queries. The WHERE clauses here are where exactly-once execution is
-- actually constructed — see docs/04_data_model.md#Guarded transitions.
--
-- Every timestamp is computed with now() INSIDE Postgres, never passed in
-- from Go or Python. The reaper's correctness rests on comparing
-- lease_expires_at < now(); if those two values came from different clocks,
-- skew would either strand dead jobs or steal live ones. One clock makes
-- skew unrepresentable rather than merely unlikely.

-- name: InsertJob :one
-- Returns zero rows (pgx.ErrNoRows) when the idempotency key already exists.
-- The caller must then re-read with GetJobByIdempotencyKey in a SEPARATE
-- statement — see the MVCC snapshot note in
-- docs/03_api_contract.md#The concurrent-duplicate race.
INSERT INTO jobs (
    idempotency_key,
    request_hash,
    model_id,
    deadline_at,
    input_ref,
    max_attempts
) VALUES (
    $1,
    $2,
    $3,
    now() + sqlc.arg(deadline)::interval,
    $4,
    $5
)
ON CONFLICT (idempotency_key) DO NOTHING
RETURNING *;

-- name: GetJobByID :one
SELECT * FROM jobs WHERE id = $1;

-- name: GetJobByIdempotencyKey :one
-- Deliberately a standalone statement, not a CTE arm of InsertJob: it needs a
-- fresh MVCC snapshot to see a row a concurrent transaction just committed.
SELECT * FROM jobs WHERE idempotency_key = $1;

-- TODO Phase 3+ — the remaining guarded transitions are specified in
-- docs/04_data_model.md and get added in their own sessions:
--   ClaimJob            session 11  (#Claim: queued to running)
--   CompleteJob         session 12  (#Complete: running to done)
--   RenewLease          session 19  (#Renew lease)
--   ReleaseStaleLeases  session 21  (#Reaper — release stale leases)
--   ExpireOverdueJobs   session 22  (#Reaper — expire overdue jobs)
--   RequeueForRetry     session 25  (#Retry: running to queued)
--   KillJob             session 25  (#Kill: running to dead)

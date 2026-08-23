-- Append-only audit log. The app role has no UPDATE or DELETE here
-- (deploy/sql/01_app_role.sql), so this is enforced by the database rather
-- than by convention.
--
-- Every event MUST be inserted in the same transaction as the state change it
-- describes. If they were separate statements, a crash between them would
-- produce a job whose history has a hole — precisely the situation this table
-- exists to explain.

-- name: InsertEvent :exec
INSERT INTO job_events (job_id, from_status, to_status, actor, attempt, detail)
VALUES ($1, $2, $3, $4, $5, $6);

-- name: ListEventsForJob :many
SELECT * FROM job_events
 WHERE job_id = $1
 ORDER BY id;

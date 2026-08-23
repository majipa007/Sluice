-- Claim-check store. The payload never rides the queue; the message carries
-- only a reference. See docs/04_data_model.md#job_payloads.
--
-- Refs are db://job_payloads/<job_id>?kind=input|result. They are internal —
-- clients collect results via GET /v1/jobs/{id}/result, so swapping this for
-- S3 later is invisible to every caller.

-- name: PutPayload :exec
INSERT INTO job_payloads (job_id, kind, content_type, body)
VALUES ($1, $2, $3, $4);

-- name: GetPayload :one
SELECT content_type, body, byte_size
  FROM job_payloads
 WHERE job_id = $1 AND kind = $2;

-- TODO Phase 5, session 30 — retention purge. PDPA-relevant: payloads are
-- arbitrary client input and may contain personal data, so they need a
-- bounded lifetime. jobs and job_events survive the purge, so the audit trail
-- outlives the data it describes.
-- Spec: docs/04_data_model.md#Data retention and PDPA

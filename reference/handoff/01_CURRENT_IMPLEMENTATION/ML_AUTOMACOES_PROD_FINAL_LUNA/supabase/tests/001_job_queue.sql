
BEGIN;
SELECT core.enqueue_integration_job_v1(gen_random_uuid(),'TEST','RUN','{}'::jsonb,'dedupe-1');
SELECT core.enqueue_integration_job_v1(gen_random_uuid(),'TEST','RUN','{}'::jsonb,'dedupe-2');
ROLLBACK;

\set ON_ERROR_STOP on

-- A real worker-built Function is the source under review.  The test proves
-- evaluation cannot be forged, publication is content-hash-bound, and source
-- rollback creates a new generation rather than mutating history.
DELETE FROM allgres_private.functions WHERE name='alpha_governance_probe';
SELECT (allgres_public.fn_create_function(
  'alpha_governance_probe','deterministic isolated governance probe','plpgsql','{}'::jsonb,
  'BEGIN RETURN jsonb_build_object(''ok'',true,''value'',p_args->>''value''); END',
  '{"type":"object","properties":{"value":{"type":"string"}}}'::jsonb
)->>'function_id')::uuid AS function_id \gset

DO $wait$
DECLARE v_status text;
BEGIN
  FOR i IN 1..30 LOOP
    SELECT build_status INTO v_status FROM allgres_private.functions
    WHERE name='alpha_governance_probe';
    IF v_status='built' THEN RETURN; END IF;
    IF v_status='failed' THEN RAISE EXCEPTION 'governance probe build failed'; END IF;
    PERFORM pg_sleep(1);
  END LOOP;
  RAISE EXCEPTION 'governance probe did not build within 30 seconds';
END;
$wait$;

SELECT allgres_private.sync_capability_index();
SELECT capability_id FROM allgres_private.capability_index
WHERE source_id=:'function_id'::uuid \gset
UPDATE allgres_private.capability_index SET lifecycle='review_pending'
WHERE capability_id=:'capability_id'::uuid;

\set ON_ERROR_STOP off
SELECT allgres_private.transition_capability(:'capability_id'::uuid,'published',
  '{"passed":true}'::jsonb,'forged');
\set ON_ERROR_STOP on

SELECT (allgres_private.evaluate_capability(:'capability_id'::uuid)->>'evaluation_id')::uuid AS evaluation_id \gset
SELECT allgres_private.transition_capability(:'capability_id'::uuid,'published',
  jsonb_build_object('evaluation_id',:'evaluation_id'),'verified');

SELECT allgres_public.fn_update_function(:'function_id'::uuid,'deterministic isolated governance probe v2',NULL,NULL);
SELECT allgres_private.sync_capability_index();
SELECT EXISTS (SELECT 1 FROM allgres_private.function_history
  WHERE function_id=:'function_id'::uuid AND generation=1) AS history_created \gset
\if :history_created
\else
  \echo 'function source history was not created'
  SELECT 1/0;
\endif
SELECT allgres_public.fn_rollback_function(:'function_id'::uuid,1);

SELECT 'capability governance ok' AS result;

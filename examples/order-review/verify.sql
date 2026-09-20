\set ON_ERROR_STOP on

-- The worker builds asynchronously.  Wait without holding a lock it needs.
DO $block$
DECLARE v_status text; v_proc_status text;
BEGIN
  FOR i IN 1..200 LOOP
    SELECT build_status INTO v_status FROM allgres_private.functions WHERE name='sample_order_total';
    SELECT build_status INTO v_proc_status FROM allgres_private.procedures WHERE name='sample-order-review';
    EXIT WHEN v_status='built' AND v_proc_status='built';
    IF v_status='failed' OR v_proc_status='failed' THEN
      RAISE EXCEPTION 'sample build failed: function=%, procedure=%',v_status,v_proc_status;
    END IF;
    PERFORM pg_sleep(0.1);
  END LOOP;
  IF v_status<>'built' OR v_proc_status<>'built' THEN
    RAISE EXCEPTION 'sample build timed out: function=%, procedure=%',v_status,v_proc_status;
  END IF;
END
$block$;

-- Execute as the sample Agent's own PostgreSQL role, not as the installer.
SELECT format(
  'SET ROLE %I; SELECT allgres_functions.%I(%L::jsonb) AS function_result; RESET ROLE;',
  a.pg_role,f.sql_ident,
  '{"currency":"KRW","items":[{"quantity":2,"unit_price":15000}]}'
)
FROM allgres_private.agents a CROSS JOIN allgres_private.functions f
WHERE a.name='sample_order_agent' AND f.name='sample_order_total' \gexec

SELECT format(
  'SET ROLE %I; CALL allgres_functions.%I(%L::jsonb,NULL::jsonb); RESET ROLE;',
  a.pg_role,p.sql_ident,
  '{"currency":"KRW","review_threshold":50000,"items":[{"quantity":2,"unit_price":15000}]}'
)
FROM allgres_private.agents a CROSS JOIN allgres_private.procedures p
WHERE a.name='sample_order_agent' AND p.name='sample-order-review' \gexec

-- Boundary and invalid-input assertions use the generated Function directly.
DO $block$
DECLARE f_ident text; r jsonb;
BEGIN
  SELECT sql_ident INTO f_ident FROM allgres_private.functions WHERE name='sample_order_total';
  EXECUTE format('SELECT allgres_functions.%I($1)',f_ident)
    INTO r USING '{"items":[{"quantity":2,"unit_price":25000}]}'::jsonb;
  IF (r->>'total')::numeric <> 50000 THEN RAISE EXCEPTION 'boundary total mismatch: %',r; END IF;
  BEGIN
    EXECUTE format('SELECT allgres_functions.%I($1)',f_ident)
      USING '{"items":[{"quantity":0,"unit_price":1}]}'::jsonb;
    RAISE EXCEPTION 'invalid quantity unexpectedly succeeded';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM='invalid quantity unexpectedly succeeded' THEN RAISE; END IF;
  END;
END
$block$;

SELECT 'order-review sample verified' AS result;

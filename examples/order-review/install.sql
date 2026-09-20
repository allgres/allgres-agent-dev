\set ON_ERROR_STOP on

-- Offline, deterministic example: a Function calculates an order total and
-- a Procedure composes it into a review decision.  Refuse to overwrite a
-- same-named capability so running examples can never replace user code.
DO $block$
BEGIN
  IF EXISTS (SELECT 1 FROM allgres_private.functions WHERE name='sample_order_total')
     OR EXISTS (SELECT 1 FROM allgres_private.procedures WHERE name='sample-order-review') THEN
    RAISE EXCEPTION 'sample already exists; run remove.sql explicitly before reinstalling';
  END IF;
END
$block$;

SELECT (allgres_public.fn_create_function(
  'sample_order_total',
  'Validate order items and calculate quantity times unit_price. Use for deterministic order totals; do not use for payment or currency conversion.',
  'plpgsql',
  '{}'::jsonb,
  $body$
DECLARE
  v_item jsonb;
  v_total numeric := 0;
  v_qty numeric;
  v_price numeric;
BEGIN
  IF jsonb_typeof(p_args->'items') <> 'array' OR jsonb_array_length(p_args->'items') = 0 THEN
    RAISE EXCEPTION 'items must be a non-empty array';
  END IF;
  FOR v_item IN SELECT value FROM jsonb_array_elements(p_args->'items') LOOP
    v_qty := (v_item->>'quantity')::numeric;
    v_price := (v_item->>'unit_price')::numeric;
    IF v_qty <= 0 OR v_price < 0 THEN
      RAISE EXCEPTION 'quantity must be positive and unit_price non-negative';
    END IF;
    v_total := v_total + v_qty * v_price;
  END LOOP;
  RETURN jsonb_build_object('currency',COALESCE(p_args->>'currency','KRW'),'total',v_total);
END
  $body$,
  '{"type":"object","required":["items"],"properties":{"currency":{"type":"string"},"items":{"type":"array"}}}'::jsonb
)->>'function_id') AS function_id \gset

SELECT allgres_public.fn_create_procedure(
  'sample-order-review',
  'Calculate an order total with sample_order_total and return approved when it is below or equal to review_threshold, otherwise needs_review. This sample never charges money.',
  format($body$
DECLARE
  v_total_result jsonb;
  v_total numeric;
  v_threshold numeric := COALESCE((p_args->>'review_threshold')::numeric,50000);
BEGIN
  SELECT allgres_functions.%I(p_args) INTO v_total_result;
  v_total := (v_total_result->>'total')::numeric;
  p_result := v_total_result || jsonb_build_object(
    'review_threshold',v_threshold,
    'decision',CASE WHEN v_total <= v_threshold THEN 'approved' ELSE 'needs_review' END
  );
END
  $body$, 'fn_' || replace(:'function_id','-',''))
)->>'procedure_id' AS procedure_id \gset

SELECT (allgres_public.fn_create_agent(
  'sample_order_agent',
  'Use the sample order capabilities for deterministic examples. Never represent an approval as a payment.'
)->>'agent_id') AS agent_id \gset

SELECT allgres_public.fn_bind_procedure_function(:'procedure_id'::uuid,:'function_id'::uuid);
SELECT allgres_public.fn_grant_permission(:'agent_id'::uuid,'function','sample_order_total');
SELECT allgres_public.fn_grant_permission(:'agent_id'::uuid,'procedure','sample-order-review');

SELECT jsonb_build_object(
  'function_id',:'function_id','procedure_id',:'procedure_id','agent_id',:'agent_id',
  'status','queued_for_worker_build'
) AS installed;

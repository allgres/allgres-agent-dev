-- Shared pre-flight, included (\ir) by every test that needs a real DNS
-- failure: tests/fixed_url_procedure_e2e.sql,
-- tests/legacy_reserved_name_row.sql, tests/dump_restore_exec.sql.
--
-- Those tests expect the runtime worker to record error_kind = 'dns' for an
-- RFC 2606 .invalid host. Some sandboxes run a resolver that answers every
-- name (e.g. with a 198.18/15 address); the worker's private-network guard
-- then refuses the call (error_kind = 'blocked_address') and the test would
-- fail for a reason that says nothing about the code. So first resolve a
-- random name that cannot exist, through the executor's own resolution
-- path (allgres.resolve_host_addresses: getaddrinfo in a backend of the
-- worker's postmaster), and stop with an explicit environment error if it
-- resolves. A real resolver -- CI runners included -- fails that lookup and
-- this passes silently.
DO $dnsguard$
DECLARE
  v_name text := 'allgres-dnsprobe-' || md5(random()::text || clock_timestamp()::text)
                 || '.allgres-test.invalid';
  v_addrs text[];
BEGIN
  v_addrs := allgres.resolve_host_addresses(v_name);
  IF cardinality(v_addrs) > 0 THEN
    RAISE EXCEPTION 'environment unsuitable: resolver answers .invalid names (got % for %); run the cluster under scripts/with_nodns.sh (see docs/testing.md)',
      array_to_string(v_addrs, ', '), v_name
      USING ERRCODE = '55000';
  END IF;
END
$dnsguard$;

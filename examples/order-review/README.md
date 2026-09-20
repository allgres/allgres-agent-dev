# Order review Function and Procedure

This deterministic example needs no LLM or external API. `sample_order_total`
validates line items and computes a total. `sample-order-review` calls that
Function and classifies the result as `approved` or `needs_review`. It does
not perform a payment and is unrelated to Allgres human Approvals.

Run `install.sql` with `psql`, keep the Allgres worker running, then run
`verify.sql`. The expected example result is a total of `30000 KRW` and an
`approved` decision at a threshold of `50000`. Installation refuses to
overwrite an existing object with either sample name.

The verification executes the generated objects under
`sample_order_agent`'s own PostgreSQL role so it exercises the same
`SECURITY INVOKER` boundary as a real Agent call.

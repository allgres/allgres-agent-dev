//! The `allgres web` background worker: an HTTP listener with no SPI
//! access at all (see the crate-level doc comment in lib.rs). Every
//! dashboard/API request is forwarded to the `allgres runtime` worker
//! over the unix socket in `crate::config`/`crate::rpc`; one thread per
//! connection, bounded, so a slow client cannot stall the accept loop.

use crate::config::{configured_http_addr, rpc_socket_path};
use crate::http_protocol::{parse_form_body, read_http_request, HttpRequest};
use crate::{CANVAS_HTML, DASHBOARD_HTML, MAX_WEB_THREADS, SSE_INTERVAL, SSE_TICKET_TTL, SSE_TOTAL};
use pgrx::bgworkers::{BackgroundWorker, SignalWakeFlags};
use pgrx::prelude::*;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::fs;
use std::io::{Read, Write};
use std::net::{IpAddr, Shutdown, TcpListener, TcpStream};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, LazyLock, Mutex};
use std::time::{Duration, Instant};

// ---------------------------------------------------------------------------
// Web worker
// ---------------------------------------------------------------------------

#[derive(Clone)]
pub(crate) struct WebConfig {
    pub(crate) token: String,
    pub(crate) socket: PathBuf,
    pub(crate) mock_enabled: bool,
}

static WEB_THREADS: AtomicUsize = AtomicUsize::new(0);

pub(crate) static SSE_TICKETS: LazyLock<Mutex<HashMap<String, (Instant, String)>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

/// Mints a fresh single-use SSE ticket, sweeping expired ones first so this
/// map cannot grow without bound from tickets nobody ever redeemed.
pub(crate) fn mint_sse_ticket(session_token: &str) -> String {
    let ticket = nonce();
    let now = Instant::now();
    let mut tickets = SSE_TICKETS.lock().unwrap();
    tickets.retain(|_, (issued, _)| now.duration_since(*issued) < SSE_TICKET_TTL);
    tickets.insert(ticket.clone(), (now, session_token.to_string()));
    ticket
}

pub(crate) fn valid_sse_ticket(t: &str) -> bool {
    let now = Instant::now();
    let mut tickets = SSE_TICKETS.lock().unwrap();
    tickets.retain(|_, (issued, _)| now.duration_since(*issued) < SSE_TICKET_TTL);
    tickets.contains_key(t)
}

/// Consumes a ticket and returns the account session captured when it was
/// minted. The ticket remains single-use while SSE snapshots retain the same
/// per-user scope as the dashboard request that created it.
pub(crate) fn consume_sse_ticket(t: &str) -> Option<String> {
    let now = Instant::now();
    let mut tickets = SSE_TICKETS.lock().unwrap();
    tickets.retain(|_, (issued, _)| now.duration_since(*issued) < SSE_TICKET_TTL);
    tickets.remove(t).map(|(_, session)| session)
}

/// Per-IP request accounting for `rate_limited`.  Two independent windows:
/// `general` (every request) and `auth_fail` (only 401 responses, a much
/// tighter cap) so one slow analyst tab can never itself trip the lockout
/// meant for a token-guessing script.  IPs are swept lazily, on the same
/// call that would insert a new one, rather than on a timer -- there is no
/// background thread appropriate to own that here.
pub(crate) struct RateWindows {
    pub(crate) general: HashMap<IpAddr, Vec<Instant>>,
    pub(crate) auth_fail: HashMap<IpAddr, Vec<Instant>>,
}
pub(crate) static RATE_LIMIT: LazyLock<Mutex<RateWindows>> = LazyLock::new(|| {
    Mutex::new(RateWindows { general: HashMap::new(), auth_fail: HashMap::new() })
});
pub(crate) const RATE_GENERAL_LIMIT: usize = 120;
/// `RATE_GENERAL_LIMIT` unless ALLGRES_RATE_LIMIT_PER_MINUTE names another
/// positive number, read once.  Only for a deployment whose clients really
/// share one address (a browser test suite, a reverse proxy that does not
/// forward the client address); the default is what everyone else gets.
static RATE_GENERAL_CAP: LazyLock<usize> = LazyLock::new(|| {
    crate::config::env_opt("ALLGRES_RATE_LIMIT_PER_MINUTE")
        .and_then(|v| v.trim().parse::<usize>().ok())
        .filter(|n| *n > 0)
        .unwrap_or(RATE_GENERAL_LIMIT)
});
pub(crate) const RATE_GENERAL_WINDOW: Duration = Duration::from_secs(60);
pub(crate) const RATE_AUTH_FAIL_LIMIT: usize = 20;
const RATE_AUTH_FAIL_WINDOW: Duration = Duration::from_secs(300);

/// Records one hit against `ip` in `window` (via `pick`) and reports whether
/// it is still under `limit` -- sliding window, not a fixed bucket: entries
/// older than the window are dropped before counting, on every call, so a
/// burst right at a window boundary cannot double an attacker's effective
/// budget the way a fixed-bucket reset would.
fn rate_check(
    map: &mut HashMap<IpAddr, Vec<Instant>>,
    ip: IpAddr,
    window: Duration,
    limit: usize,
) -> bool {
    let now = Instant::now();
    let hits = map.entry(ip).or_default();
    hits.retain(|t| now.duration_since(*t) < window);
    if hits.len() >= limit {
        return false;
    }
    hits.push(now);
    // An IP with no recent hits after the retain above is dead weight; drop
    // it here rather than in a separate sweep pass so the map never holds
    // more live entries than there are IPs that have hit it inside the
    // window right now.
    map.retain(|_, v| !v.is_empty());
    true
}

/// `false` means "reject with 429" -- called once per request, before auth,
/// for the general cap; `record_auth_failure` is called separately, only
/// after a 401, for the tighter one.
pub(crate) fn rate_limited(ip: IpAddr) -> bool {
    let mut w = RATE_LIMIT.lock().unwrap();
    !rate_check(&mut w.general, ip, RATE_GENERAL_WINDOW, *RATE_GENERAL_CAP)
}

pub(crate) fn auth_failures_exceeded(ip: IpAddr) -> bool {
    let mut w = RATE_LIMIT.lock().unwrap();
    let hits = w.auth_fail.entry(ip).or_default();
    let now = Instant::now();
    hits.retain(|t| now.duration_since(*t) < RATE_AUTH_FAIL_WINDOW);
    hits.len() >= RATE_AUTH_FAIL_LIMIT
}

pub(crate) fn record_auth_failure(ip: IpAddr) {
    let mut w = RATE_LIMIT.lock().unwrap();
    w.auth_fail.entry(ip).or_default().push(Instant::now());
}

pub(crate) fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    let mut diff = 0u8;
    for (x, y) in a.iter().zip(b.iter()) {
        diff |= x ^ y;
    }
    diff == 0
}

pub(crate) fn percent_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'%' if i + 2 < bytes.len() => {
                let hex = std::str::from_utf8(&bytes[i + 1..i + 3]).ok();
                match hex.and_then(|h| u8::from_str_radix(h, 16).ok()) {
                    Some(b) => {
                        out.push(b);
                        i += 3;
                    }
                    None => {
                        out.push(bytes[i]);
                        i += 1;
                    }
                }
            }
            b'+' => {
                out.push(b' ');
                i += 1;
            }
            b => {
                out.push(b);
                i += 1;
            }
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn query_param(query: &str, key: &str) -> Option<String> {
    query
        .split('&')
        .filter_map(|kv| kv.split_once('='))
        .find(|(k, _)| *k == key)
        .map(|(_, v)| percent_decode(v))
}

pub(crate) fn authorized(r: &HttpRequest, cfg: &WebConfig) -> bool {
    if cfg.token.is_empty() {
        return true;
    }
    if let Some(v) = r.header("authorization") {
        if let Some(t) = v.strip_prefix("Bearer ") {
            if constant_time_eq(t.as_bytes(), cfg.token.as_bytes()) {
                return true;
            }
        }
    }
    // EventSource cannot set request headers, so the stream endpoint accepts a
    // short-lived, single-use ticket (see `mint_sse_ticket`/`consume_sse_ticket`)
    // as a query parameter instead of the durable token itself. Minting one
    // still requires the real bearer token, via POST /api/v1/events/ticket,
    // which is not exempted from the check above.
    if r.route() == "/api/v1/events" {
        if let Some(t) = query_param(r.query(), "ticket") {
            return valid_sse_ticket(&t);
        }
    }
    false
}

/// A cross-origin browser request must fail even when no token is configured.
/// Two rules do that: reject a mismatched `Origin`, and require a custom header
/// that a form or `<img>` cannot set (which forces a preflight we never allow).
pub(crate) fn csrf_ok(r: &HttpRequest) -> bool {
    if let Some(origin) = r.header("origin") {
        let host = r.header("host").unwrap_or("");
        let origin_host = origin.split("://").nth(1).unwrap_or("");
        if origin_host.is_empty() || !origin_host.eq_ignore_ascii_case(host) {
            return false;
        }
    }
    // A cross-origin EventSource can never read our response because we emit no
    // CORS headers, and the endpoint has no side effects.
    if r.route() == "/api/v1/events" {
        return true;
    }
    r.header("x-allgres-client").is_some()
}

fn nonce() -> String {
    let mut buf = [0u8; 16];
    let filled = fs::File::open("/dev/urandom")
        .and_then(|mut f| f.read_exact(&mut buf))
        .is_ok();
    if !filled {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        let pid = std::process::id() as u128;
        let mix = nanos ^ (pid << 64) ^ (&buf as *const _ as u128);
        buf.copy_from_slice(&mix.to_le_bytes());
    }
    buf.iter().map(|b| format!("{b:02x}")).collect()
}

fn security_headers() -> &'static str {
    "X-Content-Type-Options: nosniff\r\n\
     X-Frame-Options: DENY\r\n\
     Referrer-Policy: no-referrer\r\n\
     Cross-Origin-Resource-Policy: same-origin\r\n"
}

fn respond(s: &mut TcpStream, status: &str, content_type: &str, body: &str, extra: &str) {
    let head = format!(
        "HTTP/1.1 {status}\r\n\
         Content-Type: {content_type}\r\n\
         Content-Length: {len}\r\n\
         Cache-Control: no-store\r\n\
         Connection: close\r\n\
         {sec}{extra}\r\n",
        len = body.as_bytes().len(),
        sec = security_headers(),
    );
    let _ = s.write_all(head.as_bytes());
    let _ = s.write_all(body.as_bytes());
    let _ = s.flush();
}

fn html_escape(s: &str) -> String {
    s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;").replace('\'', "&#39;")
}

fn respond_json(s: &mut TcpStream, status: &str, body: &str) {
    respond(s, status, "application/json", body, "");
}

fn rpc(cfg: &WebConfig, req: &Value) -> Value {
    let mut stream = match UnixStream::connect(&cfg.socket) {
        Ok(s) => s,
        Err(e) => return json!({"ok": false, "error": format!("runtime unavailable: {e}")}),
    };
    let _ = stream.set_read_timeout(Some(Duration::from_secs(5)));
    let _ = stream.set_write_timeout(Some(Duration::from_secs(5)));

    if stream.write_all(req.to_string().as_bytes()).is_err() {
        return json!({"ok": false, "error": "rpc_write_failed"});
    }
    let _ = stream.shutdown(Shutdown::Write);

    let mut out = String::new();
    if stream.read_to_string(&mut out).is_err() {
        return json!({"ok": false, "error": "rpc_read_failed"});
    }
    serde_json::from_str(&out).unwrap_or_else(|_| json!({"ok": false, "error": "invalid_rpc_response"}))
}

fn body_json(r: &HttpRequest) -> Value {
    serde_json::from_str(&r.body).unwrap_or_else(|_| json!({}))
}

fn api_route(cfg: &WebConfig, r: &HttpRequest) -> Option<Value> {
    let path = r.route();
    match (r.method.as_str(), path) {
        ("GET", "/api/v1/status") => Some(rpc(cfg, &json!({
            "action": "overview", "session_token": r.header("x-allgres-session")
        }))),
        ("GET", "/api/v1/agents") => Some(rpc(cfg, &json!({
            "action": "agents.list", "session_token": r.header("x-allgres-session")
        }))),
        ("POST", "/api/v1/agents") => {
            let mut b = body_json(r);
            b["action"] = json!("agents.create");
            Some(rpc(cfg, &b))
        }
        ("POST", "/api/v1/run") => {
            let mut b = body_json(r);
            b["action"] = json!("run");
            Some(rpc(cfg, &b))
        }
        // Both admin-only monitoring views (dashboard_rpc gates them with
        // require_admin_if_accounts_exist). Unlike the POST-based legacy
        // routes above, a GET here carries no body for the browser to put
        // session_token in -- read from a header instead of a query
        // string, which would otherwise land the token in server access
        // logs, browser history, and the Referer header, the same
        // long-lived-credential-in-a-URL concern /api/v1/events' own
        // ticket system exists to avoid.
        ("GET", "/api/v1/tasks") => Some(rpc(cfg, &json!({
            "action": "tasks.list", "limit": 200,
            "session_token": r.header("x-allgres-session")
        }))),
        ("GET", "/api/v1/logs") => Some(rpc(cfg, &json!({
            "action": "logs.list", "limit": 250,
            "session_token": r.header("x-allgres-session")
        }))),
        ("GET", "/api/v1/settings") => Some(rpc(cfg, &json!({
            "action": "settings.get", "session_token": r.header("x-allgres-session")
        }))),
        ("POST", "/api/v1/selftest") => Some(rpc(cfg, &json!({
            "action": "selftest", "session_token": r.header("x-allgres-session")
        }))),
        ("POST", "/api/v1/settings/provider") => {
            let mut b = body_json(r);
            b["action"] = json!("provider.update");
            Some(rpc(cfg, &b))
        }
        ("PATCH", p) if p.starts_with("/api/v1/agents/") => {
            let mut b = body_json(r);
            b["action"] = json!("agents.update");
            b["agent_id"] = json!(p.trim_start_matches("/api/v1/agents/"));
            Some(rpc(cfg, &b))
        }
        // Generic passthrough: the request body IS the dashboard_rpc request
        // (it just needs an "action" key). allgres.dashboard_rpc is already
        // the actual trust boundary -- it decides what's a valid action, and
        // runs SECURITY DEFINER regardless of how the call reached it -- so a
        // named Rust route per action added nothing but boilerplate that
        // needed a recompile for every new SQL-side capability. The routes
        // above predate this and stay for compatibility; every action added
        // since (projects.*, approvals.*, sessions.*, permissions.*,
        // allowlist.*, policy.history, ...) reaches here instead.
        ("POST", "/api/v1/rpc") => {
            let b = body_json(r);
            if b.get("action").and_then(Value::as_str).is_none() {
                return Some(json!({"ok": false, "error": "action_required"}));
            }
            Some(rpc(cfg, &b))
        }
        _ => None,
    }
}

/// A real event stream: one connection, a snapshot per second, no
/// Content-Length.  The previous version sent a single framed snapshot and
/// closed, which made `retry:` the actual polling mechanism.
fn stream_events(s: &mut TcpStream, cfg: &WebConfig, session_token: &str) {
    let head = format!(
        "HTTP/1.1 200 OK\r\n\
         Content-Type: text/event-stream; charset=utf-8\r\n\
         Cache-Control: no-store\r\n\
         Connection: close\r\n\
         X-Accel-Buffering: no\r\n\
         {sec}\r\n",
        sec = security_headers(),
    );
    // No `retry:` field: a single-use ticket cannot authorize the browser's
    // native retry-with-the-same-URL, so reconnection is client-driven
    // instead (`startEvents` in web/index.html mints a fresh ticket and opens
    // a new EventSource on every `error` event).
    let _ = s.set_write_timeout(Some(Duration::from_secs(5)));
    if s.write_all(head.as_bytes()).is_err() {
        return;
    }

    let deadline = Instant::now() + SSE_TOTAL;
    while Instant::now() < deadline {
        let snapshot = rpc(cfg, &json!({"action": "events", "session_token": session_token}));
        // serde_json never emits a raw newline, so this stays a single SSE frame.
        let frame = format!("event: snapshot\ndata: {snapshot}\n\n");
        if s.write_all(frame.as_bytes()).is_err() || s.flush().is_err() {
            return;
        }
        std::thread::sleep(SSE_INTERVAL);
    }
}

fn handle_web_connection(mut s: TcpStream, cfg: &WebConfig) {
    let peer_ip = s.peer_addr().map(|a| a.ip()).ok();
    if let Some(ip) = peer_ip {
        if rate_limited(ip) {
            respond(&mut s, "429 Too Many Requests", "application/json",
                    "{\"ok\":false,\"error\":\"rate_limited\"}", "Retry-After: 60\r\n");
            return;
        }
    }

    let Some(r) = read_http_request(&mut s) else { return };
    let path = r.route();

    if r.method == "OPTIONS" {
        // No CORS headers, ever: this makes every cross-origin preflight fail.
        respond(&mut s, "405 Method Not Allowed", "application/json",
                "{\"ok\":false,\"error\":\"method_not_allowed\"}", "Allow: GET, POST, PATCH\r\n");
        return;
    }

    if path == "/healthz" {
        respond_json(&mut s, "200 OK", "{\"ok\":true}");
        return;
    }

    if path == "/mock/models" || path == "/mock/v1/models" {
        if !cfg.mock_enabled {
            respond_json(&mut s, "404 Not Found", "{\"ok\":false,\"error\":\"not_found\"}");
            return;
        }
        // Settings' Test connection is GET {base_url}/models (openai_compat)
        // or /v1/models (anthropic). The other /mock/* doubles already speak
        // those providers' wire formats; without this, a first-run operator
        // who pointed a provider at the built-in mock saw
        // last_probe_status='error' with body {"ok":false,"error":"not_found"}
        // even though /mock/chat/completions would have answered a turn.
        // Same {"data":[{"id":...}]} shape fn_complete_provider_probe parses.
        let body = json!({
            "object": "list",
            "data": [
                { "id": "allgres-mock", "object": "model",
                  "pricing": { "prompt": "0.000001", "completion": "0.000002" } },
                { "id": "allgres-mock-embed", "object": "model" }
            ]
        })
        .to_string();
        respond_json(&mut s, "200 OK", &body);
        return;
    }

    if path == "/mock/chat/completions" || path == "/mock/slow/chat/completions" {
        if !cfg.mock_enabled {
            respond_json(&mut s, "404 Not Found", "{\"ok\":false,\"error\":\"not_found\"}");
            return;
        }
        // The /mock/slow variant exists only for scripts/fault_injection_drill.sh:
        // a deliberately slow response gives that drill a genuine multi-second
        // window in which a real outbound_calls row is in_flight on a real HTTP
        // pool thread, wide enough to reliably SIGKILL the worker mid-request
        // before this ever replies (see KNOWN_ISSUES.md item 6/26 -- proving a
        // worker crash between claim and complete is recovered from needs an
        // actual in-flight call to kill, not a synthetic 'in_flight' row).
        // Comfortably under HTTP_TIMEOUT (45s) so an unkilled request here still
        // completes normally -- used again by that same drill's automatic-retry
        // phase, which lets this one actually finish.
        if path == "/mock/slow/chat/completions" {
            std::thread::sleep(Duration::from_secs(15));
        }
        // A test can script an agent: a line "MOCK_SCRIPT: <text>" in any
        // message of the request (in practice the agent's system prompt) makes
        // the mock answer with that text, \n standing for a line break. With
        // no such line it keeps answering "Allgres mock runtime OK".
        let request = serde_json::from_str::<Value>(&r.body).unwrap_or_else(|_| json!({}));
        let scripted = request
            .get("messages")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(|m| m.get("content").and_then(Value::as_str))
            .find_map(|c| {
                c.lines()
                    .find_map(|l| l.trim_start().strip_prefix("MOCK_SCRIPT:"))
                    .map(|t| t.trim().replace("\\n", "\n"))
            })
            .unwrap_or_else(|| "Allgres mock runtime OK".to_string());
        // "MOCK_ACTION: <json>" answers with that action instead, once: when
        // the request already carries a proposal that action made (a message
        // holding "proposal_id"), the mock finishes with a plain answer so the
        // agent does not propose the same thing again.
        let scripted_action = request
            .get("messages")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(|m| m.get("content").and_then(Value::as_str))
            .find_map(|c| {
                c.lines()
                    .find_map(|l| l.trim_start().strip_prefix("MOCK_ACTION:"))
                    .map(|t| t.trim().to_string())
            });
        let already_proposed = request
            .get("messages")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter(|m| m.get("role").and_then(Value::as_str) != Some("system"))
            .filter_map(|m| m.get("content").and_then(Value::as_str))
            .any(|c| c.contains("proposal_id"));
        let content = match scripted_action {
            Some(action) if !already_proposed => action,
            Some(_) => json!({"action": "final_answer", "answer": "Proposed for approval."}).to_string(),
            None => json!({"action": "final_answer", "answer": scripted}).to_string(),
        };
        let body = json!({
            "id": "allgres-mock",
            "object": "chat.completion",
            "choices": [{
                "index": 0,
                "message": {"role": "assistant", "content": content},
                "finish_reason": "stop"
            }]
        })
        .to_string();
        respond_json(&mut s, "200 OK", &body);
        return;
    }

    // A mock OAuth token endpoint, gated the same way as /mock/chat/completions:
    // lets tests/e2e_mock.sql drive the real fn_claim_oauth -> perform_http
    // (send_form) -> fn_complete_oauth path through the actual background
    // worker, without a real external OAuth provider. Echoes the exchanged
    // `code` and `client_secret` back into the response so the test can prove
    // both actually arrived here -- not just that a request was sent.
    if path == "/mock/oauth/token" {
        if !cfg.mock_enabled {
            respond_json(&mut s, "404 Not Found", "{\"ok\":false,\"error\":\"not_found\"}");
            return;
        }
        let form = parse_form_body(&r.body);
        let code = form.get("code").cloned().unwrap_or_default();
        let secret = form.get("client_secret").cloned().unwrap_or_default();
        if code.is_empty() || secret != "allgres-mock-oauth-secret" {
            respond_json(&mut s, "401 Unauthorized", "{\"error\":\"invalid_client\"}");
            return;
        }
        let body = json!({
            "access_token": format!("allgres-mock-access-{code}"),
            "refresh_token": "allgres-mock-refresh",
            "expires_in": 3600,
            "token_type": "bearer"
        })
        .to_string();
        respond_json(&mut s, "200 OK", &body);
        return;
    }

    // --- Signing in to an MCP server (sql/mcp_oauth.sql) ---------------------
    // The browser returns here from the authorization server. There is no
    // dashboard session on this request; the one-time `state` is what the SQL
    // side checks. The page only reports the outcome.
    if path == "/oauth/callback" && r.method == "GET" {
        let q = parse_form_body(r.query());
        let get = |k: &str| q.get(k).cloned().unwrap_or_default();
        let reply = rpc(cfg, &json!({
            "action": "oauth.callback",
            "state": get("state"), "code": get("code"), "iss": get("iss"),
            "error": get("error"),
        }));
        let ok = reply.get("ok").and_then(Value::as_bool).unwrap_or(false);
        let message = if ok {
            "Signed in. You can close this tab and go back to Allgres.".to_string()
        } else {
            html_escape(reply.get("error").and_then(Value::as_str).unwrap_or("Sign-in failed."))
        };
        let page = format!(
            "<!doctype html><meta charset=\"utf-8\"><title>Allgres sign-in</title>\
             <body style=\"font-family:system-ui;margin:3rem;max-width:40rem\"><h2>{}</h2>\
             <p>{message}</p><p><a href=\"/\">Open Allgres</a></p></body>",
            if ok { "Signed in" } else { "Sign-in did not finish" }
        );
        respond(&mut s, if ok { "200 OK" } else { "400 Bad Request" }, "text/html; charset=utf-8", &page, "");
        return;
    }

    // Inbound events (sql/inbound_events.sql): a signed POST from an outside
    // system. No dashboard session; the signature is the only credential, and
    // the SQL side answers every refusal the same way.
    if let Some(name) = path.strip_prefix("/inbound/") {
        if r.method != "POST" || name.is_empty() || name.contains('/') {
            respond_json(&mut s, "404 Not Found", "{\"ok\":false,\"error\":\"not_found\"}");
            return;
        }
        if let Some(ip) = peer_ip {
            if auth_failures_exceeded(ip) {
                respond(&mut s, "429 Too Many Requests", "application/json",
                        "{\"ok\":false,\"error\":\"rate_limited\"}", "Retry-After: 300\r\n");
                return;
            }
        }
        let reply = rpc(cfg, &json!({
            "action": "inbound.receive",
            "source": name,
            "timestamp": r.header("x-allgres-timestamp").unwrap_or(""),
            "signature": r.header("x-allgres-signature").unwrap_or(""),
            "sender_id": r.header("x-allgres-event-id").unwrap_or(""),
            "body": r.body,
        }));
        let status = reply.get("status").and_then(Value::as_i64).unwrap_or(500);
        if status == 401 {
            if let Some(ip) = peer_ip {
                record_auth_failure(ip);
            }
        }
        let line = match status {
            200 => "200 OK",
            202 => "202 Accepted",
            401 => "401 Unauthorized",
            413 => "413 Payload Too Large",
            429 => "429 Too Many Requests",
            _ => "500 Internal Server Error",
        };
        let ok = reply.get("ok").and_then(Value::as_bool).unwrap_or(false);
        let body = if ok {
            json!({"ok": true, "duplicate": reply.get("duplicate").cloned().unwrap_or(json!(false))})
        } else {
            json!({"ok": false, "error": reply.get("error").cloned().unwrap_or(json!("failed"))})
        };
        respond_json(&mut s, line, &body.to_string());
        return;
    }

    // The Client ID Metadata Document: the client id itself is this address,
    // so an authorization server that supports it can read who is asking
    // without registering. Only meaningful when Allgres is reached over https.
    if path == "/oauth/client.json" && r.method == "GET" {
        let host = r.header("host").unwrap_or("localhost");
        let base = format!("https://{host}");
        let doc = json!({
            "client_id": format!("{base}/oauth/client.json"),
            "client_name": "Allgres",
            "redirect_uris": [format!("{base}/oauth/callback")],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none",
            "application_type": "web"
        });
        respond_json(&mut s, "200 OK", &doc.to_string());
        return;
    }

    // Mock sign-in for tests: a protected MCP endpoint, its resource
    // metadata, an authorization server (metadata, registration, authorize,
    // token). Gated like the other /mock/* doubles. It does not verify PKCE;
    // the SQL tests check the challenge itself.
    if path == "/mock/mcp-oauth" || path.starts_with("/mock/as/") || path == "/mock/oauth-prm"
        || path.starts_with("/.well-known/oauth-authorization-server/mock")
    {
        if !cfg.mock_enabled {
            respond_json(&mut s, "404 Not Found", "{\"ok\":false,\"error\":\"not_found\"}");
            return;
        }
        let host = r.header("host").unwrap_or("127.0.0.1:8088").to_string();
        let base = format!("http://{host}");
        let issuer = format!("{base}/mock/as");
        if path == "/mock/mcp-oauth" {
            let token = r.header("authorization").unwrap_or("");
            if !token.starts_with("Bearer mock-access-token") {
                let extra = format!(
                    "WWW-Authenticate: Bearer resource_metadata=\"{base}/mock/oauth-prm\"\r\n"
                );
                respond(&mut s, "401 Unauthorized", "application/json", "{\"error\":\"unauthorized\"}", &extra);
                return;
            }
            let req = body_json(&r);
            let id = req.get("id").cloned().unwrap_or(Value::Null);
            let reply = match req.get("method").and_then(Value::as_str).unwrap_or("") {
                "initialize" => json!({"jsonrpc": "2.0", "id": id, "result": {
                    "protocolVersion": "2025-06-18", "capabilities": {"tools": {}},
                    "serverInfo": {"name": "allgres-mock-oauth-mcp", "version": "1"}}}),
                "notifications/initialized" => {
                    respond(&mut s, "202 Accepted", "application/json", "", "");
                    return;
                }
                "tools/list" => json!({"jsonrpc": "2.0", "id": id, "result": {"tools": [
                    {"name": "get_status", "description": "Read the machine status",
                     "inputSchema": {"type": "object", "properties": {}}, "annotations": {"readOnlyHint": true}}]}}),
                _ => json!({"jsonrpc": "2.0", "id": id, "error": {"code": -32601, "message": "Method not found"}}),
            };
            respond_json(&mut s, "200 OK", &reply.to_string());
            return;
        }
        if path == "/mock/oauth-prm" {
            let doc = json!({"resource": format!("{base}/mock/mcp-oauth"),
                             "authorization_servers": [issuer], "scopes_supported": ["tools"]});
            respond_json(&mut s, "200 OK", &doc.to_string());
            return;
        }
        if path == "/.well-known/oauth-authorization-server/mock/as" {
            let doc = json!({
                "issuer": issuer,
                "authorization_endpoint": format!("{issuer}/authorize"),
                "token_endpoint": format!("{issuer}/token"),
                "registration_endpoint": format!("{issuer}/register"),
                "code_challenge_methods_supported": ["S256"],
                "authorization_response_iss_parameter_supported": true
            });
            respond_json(&mut s, "200 OK", &doc.to_string());
            return;
        }
        if path == "/mock/as/register" {
            let req = body_json(&r);
            let doc = json!({"client_id": "mock-client", "redirect_uris": req.get("redirect_uris")});
            respond(&mut s, "201 Created", "application/json", &doc.to_string(), "");
            return;
        }
        if path == "/mock/as/authorize" {
            let q = parse_form_body(r.query());
            let back = q.get("redirect_uri").cloned().unwrap_or_default();
            let state = q.get("state").cloned().unwrap_or_default();
            let iss: String = issuer
                .bytes()
                .map(|b| if b.is_ascii_alphanumeric() || b"-._~".contains(&b) { (b as char).to_string() } else { format!("%{b:02X}") })
                .collect();
            let extra = format!("Location: {back}?code=mockcode&state={state}&iss={iss}\r\n");
            respond(&mut s, "302 Found", "text/plain", "", &extra);
            return;
        }
        if path == "/mock/as/token" {
            let form = parse_form_body(&r.body);
            let grant = form.get("grant_type").cloned().unwrap_or_default();
            let ok = (grant == "authorization_code" && form.get("code").map(String::as_str) == Some("mockcode")
                && form.get("code_verifier").is_some_and(|v| v.len() >= 43)
                && form.get("client_id").is_some())
                || (grant == "refresh_token" && form.get("refresh_token").map(String::as_str) == Some("mock-refresh-token"));
            if !ok {
                respond_json(&mut s, "400 Bad Request", "{\"error\":\"invalid_grant\"}");
                return;
            }
            let token = if grant == "refresh_token" { "mock-access-token-renewed" } else { "mock-access-token" };
            let doc = json!({"access_token": token, "refresh_token": "mock-refresh-token",
                             "expires_in": 3600, "token_type": "Bearer"});
            respond_json(&mut s, "200 OK", &doc.to_string());
            return;
        }
        respond_json(&mut s, "404 Not Found", "{\"ok\":false,\"error\":\"not_found\"}");
        return;
    }

    // Mock decision model server (laya-serve's POST /v1/systemone). It picks
    // a label from the question's criteria by a word in the state, so a test
    // can steer it: LAYA_PICK:<label> chooses that label, LAYA_REJECT picks
    // reject or decline, anything else picks approve or confirm (or the first
    // label); LAYA_LOW answers with low confidence; LAYA_DOWN answers 503.
    if path == "/mock/laya/v1/systemone" {
        if !cfg.mock_enabled {
            respond_json(&mut s, "404 Not Found", "{\"ok\":false,\"error\":\"not_found\"}");
            return;
        }
        if r.header("authorization").is_some_and(|h| h != "Bearer laya-mock-key") {
            respond_json(&mut s, "401 Unauthorized", "{\"detail\":\"bad key\"}");
            return;
        }
        let req = serde_json::from_str::<Value>(&r.body).unwrap_or_else(|_| json!({}));
        let state = match req.get("state") {
            Some(Value::String(t)) => t.clone(),
            Some(other) => other.to_string(),
            None => String::new(),
        };
        if state.contains("LAYA_DOWN") {
            respond_json(&mut s, "503 Service Unavailable", "{\"detail\":\"unavailable\"}");
            return;
        }
        let min_conf = req.get("min_confidence").and_then(Value::as_f64);
        let mut answers = serde_json::Map::new();
        if let Some(qs) = req.get("questions").and_then(Value::as_object) {
            for (qid, q) in qs {
                let labels: Vec<String> = q
                    .get("criteria")
                    .and_then(Value::as_object)
                    .map(|o| o.keys().cloned().collect())
                    .unwrap_or_default();
                let picked = state
                    .split("LAYA_PICK:")
                    .nth(1)
                    .and_then(|t| t.split_whitespace().next())
                    .map(str::to_string)
                    .filter(|l| labels.contains(l))
                    .or_else(|| {
                        if state.contains("LAYA_REJECT") {
                            ["reject", "decline"].iter().find(|l| labels.iter().any(|x| x == *l)).map(|l| l.to_string())
                        } else {
                            ["approve", "confirm"].iter().find(|l| labels.iter().any(|x| x == *l)).map(|l| l.to_string())
                        }
                    })
                    .or_else(|| labels.first().cloned())
                    .unwrap_or_default();
                let conf = if state.contains("LAYA_LOW") { 0.30 } else { 0.95 };
                let mut node = json!({"choice": picked, "confidence": 0.5, "answer_confidence": conf,
                                      "probabilities": {picked.clone(): conf}});
                if let Some(m) = min_conf {
                    let abstained = conf < m;
                    node["abstention"] = json!(if abstained { "abstained" } else { "passed" });
                    node["abstention_threshold"] = json!(m);
                    if abstained {
                        node["low_confidence"] = json!(true);
                    }
                }
                answers.insert(qid.clone(), node);
            }
        }
        let doc = json!({"answers": answers, "usage": {"input_tokens": 1, "output_tokens": 1}});
        respond_json(&mut s, "200 OK", &doc.to_string());
        return;
    }

    // Mock decision model server (laya-serve's GET /health): with the right
    // key it lists loaded checkpoints; without it, only {"status":"ok"}, as
    // the real server does when LAYA_API_KEY is set.
    if path == "/mock/laya/health" {
        if !cfg.mock_enabled {
            respond_json(&mut s, "404 Not Found", "{\"ok\":false,\"error\":\"not_found\"}");
            return;
        }
        let doc = if r.header("authorization") == Some("Bearer laya-mock-key") {
            json!({"status": "ok", "loaded": ["support-triage"],
                   "revisions": {"support-triage": "0123456789abcdef0123456789abcdef01234567"},
                   "device": "cpu", "device_is_preference": false,
                   "checkpoint_devices": {"support-triage": "cpu"}, "cpu_fallbacks": {}})
        } else {
            json!({"status": "ok"})
        };
        respond_json(&mut s, "200 OK", &doc.to_string());
        return;
    }

    // Mock MCP servers for tests, gated like the other /mock/* doubles. They
    // let a test drive discovery and tool calls through the real worker
    // without an external server. Variants: /mock/mcp (initialize
    // handshake), /mock/mcp-auth (needs "Authorization: Bearer mcp-secret"),
    // /mock/mcp-sse (answers as a text/event-stream), and /mock/mcp-stateless
    // (no initialize; every request must carry the Mcp-Method header).
    if path.starts_with("/mock/mcp") {
        if !cfg.mock_enabled || r.method != "POST" {
            respond_json(&mut s, "404 Not Found", "{\"ok\":false,\"error\":\"not_found\"}");
            return;
        }
        if path == "/mock/mcp-auth" && r.header("authorization") != Some("Bearer mcp-secret") {
            respond_json(&mut s, "401 Unauthorized", "{\"error\":\"unauthorized\"}");
            return;
        }
        let req = body_json(&r);
        let method = req.get("method").and_then(Value::as_str).unwrap_or("").to_string();
        let id = req.get("id").cloned().unwrap_or(Value::Null);
        if path == "/mock/mcp-stateless" && r.header("mcp-method") != Some(method.as_str()) {
            respond_json(&mut s, "400 Bad Request", "{\"error\":\"Mcp-Method header required\"}");
            return;
        }
        let reply = match method.as_str() {
            "initialize" if path == "/mock/mcp-stateless" => {
                json!({"jsonrpc": "2.0", "id": id, "error": {"code": -32601, "message": "Method not found"}})
            }
            "initialize" => json!({"jsonrpc": "2.0", "id": id, "result": {
                "protocolVersion": "2025-06-18", "capabilities": {"tools": {}},
                "serverInfo": {"name": "allgres-mock-mcp", "version": "1"}}}),
            "notifications/initialized" => {
                respond(&mut s, "202 Accepted", "application/json", "", "");
                return;
            }
            "tools/list" => json!({"jsonrpc": "2.0", "id": id, "result": {"tools": [
                {"name": "get_status", "description": "Read the machine status",
                 "inputSchema": {"type": "object", "properties": {}},
                 "annotations": {"readOnlyHint": true}},
                {"name": "move_arm", "description": "Move the arm to a position",
                 "inputSchema": {"type": "object", "properties": {"x": {"type": "number"}}, "required": ["x"]}},
                {"name": "frobnicate", "description": "Does something unspecified",
                 "inputSchema": {"type": "object", "properties": {}}}]}}),
            "tools/call" => {
                let name = req.pointer("/params/name").and_then(Value::as_str).unwrap_or("");
                let args = req.pointer("/params/arguments").cloned().unwrap_or_else(|| json!({}));
                json!({"jsonrpc": "2.0", "id": id, "result": {
                    "content": [{"type": "text", "text": format!("mock {name} ran with {args}")}]}})
            }
            _ => json!({"jsonrpc": "2.0", "id": id, "error": {"code": -32601, "message": "Method not found"}}),
        };
        if path == "/mock/mcp-sse" {
            let body = format!("event: message\ndata: {reply}\n\n");
            respond(&mut s, "200 OK", "text/event-stream", &body, "");
        } else {
            respond_json(&mut s, "200 OK", &reply.to_string());
        }
        return;
    }

    // A mock embeddings endpoint, gated the same way as /mock/chat/completions:
    // lets a test drive the real fn_claim_agent_embedding/fn_claim_outbound ->
    // perform_http (send_json) -> fn_complete_agent_embedding/
    // fn_complete_outbound path through the actual background worker, without
    // a real embedding provider. Deterministic and test-legible rather than a
    // real model's output: each of a small fixed keyword list gets its own
    // dimension, 1.0 if that keyword appears (case-insensitively) anywhere in
    // the request's `input` text, else a small non-zero baseline (so an
    // input matching none of them still embeds to a well-defined, if
    // uninformative, direction instead of the zero vector cosine_similarity
    // treats as undefined). A test can therefore pick exact expected
    // rankings from the keywords it puts in an agent's system_prompt vs. a
    // search query, rather than asserting on an opaque real model's output.
    if path == "/mock/embeddings" {
        if !cfg.mock_enabled {
            respond_json(&mut s, "404 Not Found", "{\"ok\":false,\"error\":\"not_found\"}");
            return;
        }
        const KEYWORDS: [&str; 8] =
            ["alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta"];
        let input = serde_json::from_str::<Value>(&r.body)
            .ok()
            .and_then(|v| v.get("input").and_then(Value::as_str).map(str::to_string))
            .unwrap_or_default()
            .to_ascii_lowercase();
        let embedding: Vec<f64> = KEYWORDS
            .iter()
            .map(|k| if input.contains(k) { 1.0 } else { 0.05 })
            .collect();
        let body = json!({
            "data": [{ "embedding": embedding, "index": 0 }],
            "model": "allgres-mock-embed",
            "object": "list"
        })
        .to_string();
        respond_json(&mut s, "200 OK", &body);
        return;
    }

    // Both pages are static documents behind the same per-response nonce
    // CSP; everything they show comes from /api/v1 after load.
    if path == "/" || path == "/canvas" {
        let n = nonce();
        let page = if path == "/" { DASHBOARD_HTML } else { CANVAS_HTML };
        let html = page.replace("__CSP_NONCE__", &n);
        let csp = format!(
            "Content-Security-Policy: default-src 'none'; \
             script-src 'nonce-{n}'; style-src 'nonce-{n}'; \
             connect-src 'self'; img-src 'self' data:; \
             base-uri 'none'; form-action 'none'; frame-ancestors 'none'\r\n"
        );
        respond(&mut s, "200 OK", "text/html; charset=utf-8", &html, &csp);
        return;
    }

    if !path.starts_with("/api/v1/") {
        respond_json(&mut s, "404 Not Found", "{\"ok\":false,\"error\":\"not_found\"}");
        return;
    }

    if !csrf_ok(&r) {
        respond_json(&mut s, "403 Forbidden", "{\"ok\":false,\"error\":\"cross_origin_request_rejected\"}");
        return;
    }

    // Checked ahead of the real auth comparison, not after it, so a locked-out
    // IP cannot keep spending a thread and a constant-time compare on every
    // attempt -- only the failures that got this far ever counted against it.
    if let Some(ip) = peer_ip {
        if auth_failures_exceeded(ip) {
            respond(&mut s, "429 Too Many Requests", "application/json",
                    "{\"ok\":false,\"error\":\"rate_limited\"}", "Retry-After: 300\r\n");
            return;
        }
    }

    if !authorized(&r, cfg) {
        if let Some(ip) = peer_ip {
            record_auth_failure(ip);
        }
        respond(&mut s, "401 Unauthorized", "application/json",
                "{\"ok\":false,\"error\":\"unauthorized\"}", "WWW-Authenticate: Bearer\r\n");
        return;
    }

    if path == "/api/v1/events/ticket" {
        if r.method != "POST" {
            respond(&mut s, "405 Method Not Allowed", "application/json",
                    "{\"ok\":false,\"error\":\"method_not_allowed\"}", "Allow: POST\r\n");
            return;
        }
        let ticket = mint_sse_ticket(r.header("x-allgres-session").unwrap_or(""));
        let body = json!({"ok": true, "ticket": ticket, "expires_in": SSE_TICKET_TTL.as_secs()}).to_string();
        respond_json(&mut s, "200 OK", &body);
        return;
    }

    if path == "/api/v1/events" {
        let session = query_param(r.query(), "ticket")
            .and_then(|ticket| consume_sse_ticket(&ticket));
        let Some(session) = session else {
            respond_json(&mut s, "401 Unauthorized", "{\"ok\":false,\"error\":\"invalid_ticket\"}");
            return;
        };
        stream_events(&mut s, cfg, &session);
        return;
    }

    match api_route(cfg, &r) {
        Some(v) => {
            let status = if v.get("ok").and_then(Value::as_bool) == Some(false) {
                "400 Bad Request"
            } else {
                "200 OK"
            };
            respond_json(&mut s, status, &v.to_string());
        }
        None => respond_json(&mut s, "404 Not Found", "{\"ok\":false,\"error\":\"not_found\"}"),
    }
}

fn is_loopback_addr(addr: &str) -> bool {
    let host = match addr.rfind(':') {
        Some(i) => &addr[..i],
        None => addr,
    };
    let host = host.trim_start_matches('[').trim_end_matches(']');
    host == "127.0.0.1" || host == "::1" || host == "localhost" || host.starts_with("127.")
}

/// Refuse the combination that turns this into an open agent console: a public
/// bind address with no dashboard token.  Container deployments that publish
/// the port themselves opt in with ALLGRES_ALLOW_INSECURE_HTTP=1.
pub(crate) fn check_exposure(addr: &str, token: &str) -> Result<(), String> {
    if is_loopback_addr(addr) || !token.is_empty() {
        return Ok(());
    }
    if std::env::var("ALLGRES_ALLOW_INSECURE_HTTP").as_deref() == Ok("1") {
        return Ok(());
    }
    Err(format!(
        "refusing to bind {addr} with no ALLGRES_DASHBOARD_TOKEN. \
         Set a token, bind to 127.0.0.1, or set ALLGRES_ALLOW_INSECURE_HTTP=1 if the \
         port is already protected by the surrounding network."
    ))
}

#[unsafe(no_mangle)]
#[pg_guard]
pub extern "C-unwind" fn allgres_web_main(_arg: pg_sys::Datum) {
    BackgroundWorker::attach_signal_handlers(SignalWakeFlags::SIGHUP | SignalWakeFlags::SIGTERM);

    let addr = configured_http_addr();
    let cfg = WebConfig {
        token: std::env::var("ALLGRES_DASHBOARD_TOKEN").unwrap_or_default(),
        socket: rpc_socket_path(),
        mock_enabled: std::env::var("ALLGRES_ENABLE_MOCK").as_deref() == Ok("1"),
    };

    if let Err(msg) = check_exposure(&addr, &cfg.token) {
        pgrx::warning!("Allgres web: {}", msg);
        return;
    }

    let listener = match TcpListener::bind(&addr) {
        Ok(l) => l,
        Err(e) => {
            pgrx::warning!("Allgres web bind {}: {}", addr, e);
            return;
        }
    };
    if let Err(e) = listener.set_nonblocking(true) {
        pgrx::warning!("Allgres web nonblocking: {}", e);
        return;
    }

    let cfg = Arc::new(cfg);

    while BackgroundWorker::wait_latch(Some(Duration::from_millis(50))) {
        loop {
            match listener.accept() {
                Ok((s, _)) => {
                    if WEB_THREADS.load(Ordering::Relaxed) >= MAX_WEB_THREADS {
                        let mut s = s;
                        respond_json(&mut s, "503 Service Unavailable", "{\"ok\":false,\"error\":\"busy\"}");
                        continue;
                    }
                    let _ = s.set_nonblocking(false);
                    WEB_THREADS.fetch_add(1, Ordering::Relaxed);
                    let cfg = Arc::clone(&cfg);
                    let spawned = std::thread::Builder::new()
                        .name("allgres-web-conn".into())
                        .spawn(move || {
                            handle_web_connection(s, &cfg);
                            WEB_THREADS.fetch_sub(1, Ordering::Relaxed);
                        });
                    if spawned.is_err() {
                        WEB_THREADS.fetch_sub(1, Ordering::Relaxed);
                    }
                }
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => break,
                Err(e) => {
                    pgrx::warning!("Allgres web accept: {}", e);
                    break;
                }
            }
        }
    }
}

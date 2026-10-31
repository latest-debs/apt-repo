#!/usr/bin/env bash
# test-gh-get.sh - self-check for lib.sh's gh_get() ETag cache.
#
# Hermetic: talks to a local python http.server that mimics GitHub's
# conditional-request behavior (200 + ETag, then 304 when If-None-Match
# matches). No network, no token, no GitHub. Run it directly; it prints
# "gh-get: OK" and exits 0, or dies on the first failed assertion.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"; [ -n "${SRV_PID:-}" ] && kill "$SRV_PID" 2>/dev/null || true' EXIT

# Fake API: serves {"tag_name":"v1"} with a fixed ETag, and answers 304 when
# the client replays it. Counts 304s to a file so the test can prove the
# conditional request actually happened rather than inferring it from the body.
cat > "$WORK/server.py" <<'PY'
import http.server, sys
ETAG = 'W/"deadbeef"'
BODY = b'{"tag_name":"v1"}'
FLAKY = {'n': 0}
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        # /flaky fails once with a 500, then succeeds - exercises the retry.
        if self.path.startswith('/flaky'):
            FLAKY['n'] += 1
            if FLAKY['n'] == 1:
                self.send_response(500); self.end_headers(); return
            self.send_response(200)
            self.send_header('Content-Length', str(len(BODY)))
            self.end_headers(); self.wfile.write(BODY); return
        if self.path.startswith('/missing'):
            self.send_response(404); self.end_headers(); return
        if self.headers.get('If-None-Match') == ETAG:
            open(sys.argv[2], 'a').write('x')
            self.send_response(304); self.send_header('ETag', ETAG); self.end_headers()
            return
        self.send_response(200)
        self.send_header('ETag', ETAG)
        self.send_header('Content-Length', str(len(BODY)))
        self.end_headers()
        self.wfile.write(BODY)
    def log_message(self, *a): pass
http.server.HTTPServer(('127.0.0.1', int(sys.argv[1])), H).serve_forever()
PY

PORT=8731
HITS="$WORK/304s"
: > "$HITS"
python3 "$WORK/server.py" "$PORT" "$HITS" & SRV_PID=$!
URL="http://127.0.0.1:$PORT/releases/latest"
for _ in $(seq 1 50); do
  curl -fsS -o /dev/null "$URL" 2>/dev/null && break
  sleep 0.1
done

fail() { echo "gh-get: FAIL - $1" >&2; exit 1; }

# 1. Cold cache: real 200, body fetched, cache populated.
export ETAG_DIR="$WORK/etags"
code="$(gh_get "$URL" "$WORK/out1")"
[ "$code" = "200" ] || fail "cold fetch returned $code, want 200"
grep -q 'v1' "$WORK/out1" || fail "cold fetch body missing"
[ -n "$(ls -A "$ETAG_DIR" 2>/dev/null)" ] || fail "cold fetch did not populate \$ETAG_DIR"
[ ! -s "$HITS" ] || fail "cold fetch sent If-None-Match with an empty cache"

# 2. Warm cache: server answers 304, caller still sees 200 + the right body.
code="$(gh_get "$URL" "$WORK/out2")"
[ "$code" = "200" ] || fail "warm fetch returned $code, want 200 (304 must be masked)"
grep -q 'v1' "$WORK/out2" || fail "warm fetch did not restore the cached body"
[ -s "$HITS" ] || fail "warm fetch did not send If-None-Match"

# 3. Evicted body, surviving etag: must NOT revalidate into an empty result.
rm -f "$ETAG_DIR"/*.body
: > "$HITS"
code="$(gh_get "$URL" "$WORK/out3")"
[ "$code" = "200" ] || fail "half-evicted cache returned $code, want 200"
grep -q 'v1' "$WORK/out3" || fail "half-evicted cache produced an empty body"
[ ! -s "$HITS" ] || fail "half-evicted cache sent If-None-Match without a body to restore"

# 4. No $ETAG_DIR: degrades to a plain uncached GET.
unset ETAG_DIR
: > "$HITS"
code="$(gh_get "$URL" "$WORK/out4")"
[ "$code" = "200" ] || fail "uncached fetch returned $code, want 200"
grep -q 'v1' "$WORK/out4" || fail "uncached fetch body missing"
[ ! -s "$HITS" ] || fail "uncached fetch sent If-None-Match"

# 5. Retry: a 500 followed by a 200 must resolve to 200, not surface the 500.
#    (Costs one 5s backoff - the only slow assertion here, and the point of
#    the loop, so it is worth the wall clock.)
code="$(gh_get "http://127.0.0.1:$PORT/flaky" "$WORK/out5")"
[ "$code" = "200" ] || fail "retry did not recover a 500 (got $code)"
grep -q 'v1' "$WORK/out5" || fail "recovered fetch has no body"

# 6. api_json prints the body and succeeds on 200.
out="$(api_json "$URL")" || fail "api_json returned non-zero on 200"
printf '%s' "$out" | grep -q 'v1' || fail "api_json printed no body"

# 7. api_json fails cleanly on 404, printing nothing (and without retrying,
#    which is what keeps a missing record from costing 15s).
if out="$(api_json "http://127.0.0.1:$PORT/missing")"; then
  fail "api_json returned zero on 404"
fi
[ -z "$out" ] || fail "api_json printed a body on 404"

echo "gh-get: OK"

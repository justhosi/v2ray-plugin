#!/usr/bin/env bash
# =============================================================================
# Backend regression tests for bin/omarchy-v2ray.
#
# WHY THIS EXISTS
# ---------------
# The failure paths of this backend cannot be tested with a real tunnel: the
# interesting cases (a server that refuses the REALITY handshake, an engine that
# dies before binding a port, a run that times out without a reply) need a
# *misbehaving* server, which no test machine has on demand.
#
# So the test replaces three external programs with doubles placed FIRST on PATH:
#
#   xray   prints a scripted log and lingers, instead of dialling anything
#   ss     always claims a port is listening            (no sockets are opened —
#                                                        this also makes the tests
#                                                        run in a sandbox)
#   curl   always reports "HTTP 000, exit 35"           (a proxy that never answers)
#
# Everything else — argument parsing, config generation, the report, the JSON
# contract, the `set -u` correctness — is the real code.
#
# HOW TO RUN
# ----------
#     ./tests/test-backend.sh
#
# It touches nothing outside its own temp directory: the backend takes its paths
# from OMARCHY_V2RAY_HOME, which is pointed at a throwaway folder.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND="$HERE/../bin/omarchy-v2ray"

WORK="$(mktemp -d)"
FAKEBIN="$WORK/bin"
mkdir -p "$FAKEBIN" "$WORK/home"

# Never touch the real ~/.config/omarchy-v2ray, and never dial a real host: the
# synthetic link points at 203.0.113.10 (TEST-NET-3), which is guaranteed to be
# unroutable, so the openssl probes fail immediately instead of hanging.
export OMARCHY_V2RAY_HOME="$WORK/home"
export PATH="$FAKEBIN:$PATH"

failures=0
check() {                    # check <description> <condition...>
  local what="$1"; shift
  if "$@" >/dev/null 2>&1; then
    printf '  ok   %s\n' "$what"
  else
    printf '  FAIL %s\n' "$what"
    failures=$((failures + 1))
  fi
}
check_contains() {           # check_contains <description> <haystack> <needle>
  local what="$1" hay="$2" needle="$3"
  if [[ $hay == *"$needle"* ]]; then
    printf '  ok   %s\n' "$what"
  else
    printf '  FAIL %s\n        wanted to find: %s\n        inside: %s\n' "$what" "$needle" "$hay"
    failures=$((failures + 1))
  fi
}

# ---------------------------------------------------------------- doubles ----
cat >"$FAKEBIN/xray" <<'SH'
#!/usr/bin/env bash
# `version` is used to label reports; `run` narrates the scripted scenario.
case "${1:-}" in
  version) echo "Xray 0.0.0-test (test double)"; exit 0 ;;
esac
# FAKE_XRAY_LINES is a file holding the lines to emit. Timestamps and goroutine
# ids are added here so the output is realistic — and so the log-collapsing code
# has to cope with lines that are the same *message* but differ byte-for-byte.
i=0
while IFS= read -r line; do
  i=$((i + 1))
  printf '2026/09/20 20:58:%02d.%06d [Error] [4053804871] %s\n' "$i" "$i" "$line"
done < "${FAKE_XRAY_LINES:-/dev/null}"
sleep 4
SH
cat >"$FAKEBIN/ss" <<'SH'
#!/usr/bin/env bash
# Every port is "listening", so the code under test proceeds to the request step.
echo "LISTEN 0 128 127.0.0.1:11080 0.0.0.0:*"
SH
cat >"$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
# The shape curl produces when the proxy accepted the connection but no reply
# ever came back: HTTP status 000 and its own exit code 35.
echo -n "000 5.000000"
exit 35
SH
chmod +x "$FAKEBIN/xray" "$FAKEBIN/ss" "$FAKEBIN/curl"

# --------------------------------------------------------------- fixture -----
# A profile in the shape the panel sends. The link->config conversion lives in
# Model.js (the QML side), so the backend is handed the finished {id,meta,config}
# object — which is exactly what happens in production too.
#
# The server address is 203.0.113.10 (TEST-NET-3, reserved and unroutable) and the
# sni is example.com, so the openssl probes the debug report runs fail instantly
# instead of dialling a stranger on real hardware.
ID="test-reality"
# The credential this fixture carries. The cases below use it to prove that the
# UUID never reaches a command line, the environment, or any output.
UUID="11111111-2222-3333-4444-555555555555"

cat >"$WORK/payload.json" <<JSON
{
  "id": "$ID",
  "meta": {
    "name": "Test Server",
    "type": "vless",
    "host": "203.0.113.10",
    "port": 443,
    "security": "reality",
    "network": "tcp",
    "socksPort": 10808,
    "httpPort": 10809,
    "link": "vless://11111111-2222-3333-4444-555555555555@203.0.113.10:443?security=reality&sni=example.com"
  },
  "config": {
    "log": { "loglevel": "warning" },
    "inbounds": [
      { "tag": "socks-in", "listen": "127.0.0.1", "port": 10808, "protocol": "socks",
        "settings": { "auth": "noauth", "udp": true } },
      { "tag": "http-in", "listen": "127.0.0.1", "port": 10809, "protocol": "http",
        "settings": {} }
    ],
    "outbounds": [
      { "tag": "proxy", "protocol": "vless",
        "settings": { "vnext": [ { "address": "203.0.113.10", "port": 443,
          "users": [ { "id": "11111111-2222-3333-4444-555555555555",
                       "encryption": "none", "flow": "xtls-rprx-vision" } ] } ] },
        "streamSettings": { "network": "tcp", "security": "reality",
          "realitySettings": { "serverName": "example.com", "fingerprint": "chrome",
            "publicKey": "TESTPUBLICKEYTESTPUBLICKEYTESTPUBLICKEYTESTPUBK",
            "shortId": "1e7772d776f222e5", "spiderX": "/" } } },
      { "tag": "direct", "protocol": "freedom" }
    ]
  }
}
JSON

# The payload goes in on stdin, which is the only channel the backend accepts
# (see cmd_import). The panel does exactly the same through Quickshell's Process.
"$BACKEND" import <"$WORK/payload.json" >/dev/null 2>&1
if ! "$BACKEND" list 2>/dev/null | jq -e --arg id "$ID" 'any(.id == $id)' >/dev/null; then
  echo "could not import the test profile" >&2; exit 1
fi
echo "test profile: $ID"

# =============================================================================
echo
echo "case 0: the credential must not be able to travel in argv or the environment"
# The panel used to hand the payload to the backend as an ARGUMENT:
#   bin/omarchy-v2ray import "$(jq -c . payload.json)"
# That put the profile's UUID in the child's command line, where every user on
# the machine can read it for as long as the process lives (`ps -ww`,
# /proc/<pid>/cmdline need no privileges) — the leak this whole suite guards
# against, and the reason the payload now goes over stdin.
#
# A DIFFERENT id is used here, so that a regression is visible as an extra
# profile rather than as a silent update of the existing one.
argv_payload="$(jq -c '.id = "argv-leak-should-not-exist"' "$WORK/payload.json")"

out="$("$BACKEND" import "$argv_payload" 2>/dev/null)"
check "an argv payload is refused" jq -e '.ok == false' <<<"$out"
check_contains "the refusal points at stdin" "$(jq -r '.error' <<<"$out")" "stdin"
check "the refusal does not echo the credential" test "${out#*$UUID}" = "$out"
check "nothing was written from argv" test -z "$("$BACKEND" list 2>/dev/null \
  | jq -r '.[] | select(.id == "argv-leak-should-not-exist") | .id')"

# The environment was the second convenience path ($OMARCHY_V2RAY_PAYLOAD) and is
# equally readable via /proc/<pid>/environ, so it must be inert now.
out="$(OMARCHY_V2RAY_PAYLOAD="$argv_payload" "$BACKEND" import </dev/null 2>/dev/null)"
check "an environment payload is refused too" jq -e '.ok == false' <<<"$out"
check "nothing was written from the environment" test -z "$("$BACKEND" list 2>/dev/null \
  | jq -r '.[] | select(.id == "argv-leak-should-not-exist") | .id')"

# =============================================================================
echo
echo "case 1: the server refuses the REALITY handshake"
# The engine says the same thing on every retry, with a different timestamp.
printf '%s\n' \
  'transport/internet/reality: REALITY: received real certificate (potential MITM or redirection)' \
  'transport/internet/reality: REALITY: received real certificate (potential MITM or redirection)' \
  'transport/internet/reality: REALITY: received real certificate (potential MITM or redirection)' \
  'transport/internet/reality: REALITY: received real certificate (potential MITM or redirection)' \
  > "$WORK/refused.log"

# THE REGRESSION THIS SUITE WAS BORN FROM: `debug` used to abort here with
# "sni: unbound variable" (a `local` declared too late, and without a `=value`,
# under `set -u`), then print nothing at all.
out="$(FAKE_XRAY_LINES="$WORK/refused.log" "$BACKEND" debug "$ID" 2>"$WORK/err")"
rc=$?
check "debug exits 0 instead of aborting" test "$rc" -eq 0
check "debug printed no shell error" test ! -s "$WORK/err"
report="$(jq -r '.report // ""' <<<"$out")"
check_contains "report names the rejected handshake" "$report" "handshake"
check_contains "report says credentials were rejected" "$report" "rejected our credentials"
check_contains "report names the sni it was pretending to be" "$report" "example.com"
check_contains "network note still compares signing authority" "$report" "network note"

# =============================================================================
echo
echo "case 2: REALITY accepts us, then the reply never arrives"
printf '%s\n' \
  'proxy/vless/outbound: tunneling request to tcp:www.gstatic.com:443 via 203.0.113.10:443' \
  'proxy: XtlsFilterTls found tls client hello! 1575' \
  'proxy: XtlsPadding 1575 23 0' \
  > "$WORK/accepted.log"

out="$(FAKE_XRAY_LINES="$WORK/accepted.log" "$BACKEND" debug "$ID" 2>/dev/null)"
report="$(jq -r '.report // ""' <<<"$out")"
check_contains "report says authentication SUCCEEDED" "$report" "authentication SUCCEEDED"
check_contains "and blames timing, not the link" "$report" "NOT at a bad link"

# =============================================================================
echo
echo "case 3: the latency probe on a refused handshake"
out="$(FAKE_XRAY_LINES="$WORK/refused.log" "$BACKEND" ping "$ID" 2>/dev/null)"
err_text="$(jq -r '.error // ""' <<<"$out")"
detail="$(jq -r '.detail // ""' <<<"$out")"
full="$(jq -r '.detailFull // ""' <<<"$out")"

check "ping still answers with parseable JSON" jq -e '.ok == false' <<<"$out"
check_contains "the reason names the REALITY refusal" "$err_text" "refused the REALITY handshake"
# The popup paints `detail` on one line, so repeats must be collapsed...
check_contains "repeats are collapsed for the popup" "$detail" "[repeated 4 times]"
# ...while the full text is still available for a bug report. Count OCCURRENCES,
# not lines: detailFull is one flattened string, so grep -c would always say 1.
check "detailFull keeps every copy" test "$(grep -o 'received real certificate' <<<"$full" | wc -l)" -eq 4
check "detail is much shorter than detailFull" test "${#detail}" -lt "${#full}"

# =============================================================================
echo
echo "case 4: the signer comparison must not cry wolf"
# Two Google certificates for the SAME domain, signed by different front-ends.
ca() { sed -n "/^ca_of()/,/^}/p" "$BACKEND" > "$WORK/ca.sh"; . "$WORK/ca.sh"; ca_of "$1"; }
we2="subject=CN=www.google.com issuer=C=US, O=Google Trust Services, CN=WE2"
wr2="subject=CN=www.google.com issuer=C=US, O=Google Trust Services, CN=WR2"
evil="subject=CN=www.google.com issuer=C=US, O=Suspicious Interceptor, CN=Proxy-1"

check "WE2 and WR2 count as the same signer" test "$(ca "$we2")" = "$(ca "$wr2")"
check "a different organisation is NOT the same signer" test "$(ca "$we2")" != "$(ca "$evil")"
check "the organisation is what is compared" test "$(ca "$we2")" = "Google Trust Services"

# =============================================================================
echo
echo "case 5: the panel cannot quietly reintroduce the leak"
# The backend refusing an argv payload only helps if the panel stops sending
# one, so assert on the caller too: the payload must be handed to runAction() as
# its third (stdin) argument, and no credential-bearing text may be woven into a
# shell command line.
SERVICE="$HERE/../Service.qml"
check "the panel passes no payload in the import command list" \
  bash -c '! grep -qE "\"import\", *JSON" "$1"' _ "$SERVICE"
check_contains "the panel passes it as runAction()'s stdin argument" "$(cat "$SERVICE")" \
  'runAction(["bash", scriptPath, "import"], String(payload.id), JSON.stringify(payload))'
check "the panel enables stdin for that child" bash -c 'grep -q "stdinEnabled" "$1"' _ "$SERVICE"
# `bash -c "<string built from app data>"` is how a credential reaches argv, so
# the panel must not do it at all (the clipboard used to).
check "the panel never builds a shell command line" \
  bash -c '! grep -qE "\"bash\", *\"-c\"" "$1"' _ "$SERVICE"

# =============================================================================
echo
if (( failures == 0 )); then
  echo "all tests passed"
else
  echo "$failures test(s) FAILED"
fi
rm -rf "$WORK"
exit $(( failures > 0 ))

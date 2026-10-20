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
echo "case 0b: the stdin read is bounded, and must never truncate silently"
# A well-formed payload on stdin is accepted (the preamble already imported one
# to get here; this asserts the JSON contract explicitly).
out="$("$BACKEND" import <"$WORK/payload.json" 2>/dev/null)"
check "a complete stdin payload is accepted" jq -e '.ok == true' <<<"$out"

# Malformed JSON is refused, and the refusal must not quote what it read.
out="$(printf '%s' '{"id":"LEAKMARKER",' | "$BACKEND" import 2>/dev/null)"
check "malformed JSON is refused" jq -e '.ok == false' <<<"$out"
check "the malformed refusal does not echo the input" test "${out#*LEAKMARKER}" = "$out"

# THE BUG THIS CASE WAS BORN FROM. The read used to be `head -c MAX`, so "a
# complete payload of exactly MAX bytes" and "a larger payload cut off at MAX"
# were literally the same byte string — and a cut landing just past a valid JSON
# document imported with its tail silently dropped. Both padding flavours are
# used because the shell strips trailing newlines off a command substitution:
# the newline-padded stream is the one that shrank back under the ceiling and
# slipped through a plain byte count.
max="${OMARCHY_V2RAY_IMPORT_MAX_BYTES:-262144}"

# A complete payload of exactly the ceiling is still ACCEPTED: the guard must
# reject only what is genuinely over it.
jq -c '.id = "at-ceiling-should-exist"' "$WORK/payload.json" >"$WORK/at-ceiling.json"
printf '%*s' "$((max - $(wc -c <"$WORK/at-ceiling.json")))" '' >>"$WORK/at-ceiling.json"
check "the boundary fixture is exactly at the ceiling"   test "$(wc -c <"$WORK/at-ceiling.json")" -eq "$max"
out="$("$BACKEND" import <"$WORK/at-ceiling.json" 2>/dev/null)"
check "a payload of exactly the ceiling is accepted" jq -e '.ok == true' <<<"$out"

# One byte OVER the ceiling must be refused — both when the padding is spaces
# and when it is newlines.
jq -c '.id = "oversized-spaces-should-not-exist"' "$WORK/payload.json" >"$WORK/oversized-spaces.json"
printf '%*s' "$((max + 1 - $(wc -c <"$WORK/oversized-spaces.json")))" '' >>"$WORK/oversized-spaces.json"
jq -c '.id = "oversized-newlines-should-not-exist"' "$WORK/payload.json" >"$WORK/oversized-newlines.json"
printf '%*s' "$((max + 1 - $(wc -c <"$WORK/oversized-newlines.json")))" '' | tr ' ' '\n' >>"$WORK/oversized-newlines.json"
check "the space padding is one byte over the ceiling"   test "$(wc -c <"$WORK/oversized-spaces.json")" -eq "$((max + 1))"
check "the newline padding is one byte over the ceiling"   test "$(wc -c <"$WORK/oversized-newlines.json")" -eq "$((max + 1))"

for bad in "$WORK/oversized-spaces.json" "$WORK/oversized-newlines.json"; do
  out="$("$BACKEND" import <"$bad" 2>/dev/null)"
  check "an over-large payload is refused ($(basename "$bad"))" jq -e '.ok == false' <<<"$out"
  check_contains "the refusal names the ceiling ($(basename "$bad"))" \
    "$(jq -r '.error' <<<"$out")" "too large"
  check "the refusal does not echo the payload ($(basename "$bad"))" \
    test "${out#*$UUID}" = "$out"
done
check "nothing was written from an oversized payload" test -z "$("$BACKEND" list 2>/dev/null \
  | jq -r '.[] | select(.id | startswith("oversized")) | .id')"

# A sender that opens the pipe, says nothing and never closes it must not hang
# the reader: OMARCHY_V2RAY_IMPORT_TIMEOUT puts a bound on the wait.
started=$SECONDS
out="$(OMARCHY_V2RAY_IMPORT_TIMEOUT=1 "$BACKEND" import < <(sleep 8) 2>/dev/null)"
elapsed=$(( SECONDS - started ))
check "a sender that never closes stdin is refused, not waited on" jq -e '.ok == false' <<<"$out"
check_contains "the refusal names the timeout" "$(jq -r '.error' <<<"$out")" "timed out"
check "the read gave up quickly instead of hanging" test "$elapsed" -lt 6

# =============================================================================
echo
echo "case 0c: a LIVE import must not publish the credential through /proc"
# Cases 0 and 5 pin the *contract* — the backend refuses an argv payload, and
# the panel no longer builds a command line. This case pins the *property* those
# rules exist to protect, as the kernel itself reports it: while an import is in
# flight, the profile's UUID must be absent from /proc/<pid>/cmdline and
# /proc/<pid>/environ. Those two files are readable by any user on the machine
# for as long as the process lives, which is the whole reason the payload now
# travels on stdin.
#
# The import is genuinely launched, and it is kept alive deliberately: a real
# one answers in tens of milliseconds, far too fast to sample without racing it.
# Its stdin is a FIFO whose writer hands over the payload and then simply holds
# the pipe open, so the reader blocks waiting for a payload that has not ended
# and the process sits still — with whatever it has in argv and in its
# environment — until we have finished looking. Nothing is weakened to make that
# possible: any real import over a pipe is equally alive while its payload is
# still arriving.
#
# ---- reading /proc (bash and the kernel only: no ps, no pgrep, no ptrace) ----
# proc_children <pid>: the direct children of <pid>. The parent id is read from
# /proc/<pid>/status rather than from field 4 of /proc/<pid>/stat, because the
# command name in field 2 can itself contain spaces and parentheses and would
# throw the field counting off.
proc_children() {
  local parent="$1" f pid key value
  for f in /proc/[0-9]*/status; do
    [[ -r $f ]] || continue
    pid=${f#/proc/}; pid=${pid%/status}
    while IFS=$' \t:' read -r key value; do
      [[ $key == PPid ]] || continue
      [[ $value == "$parent" ]] && printf '%s\n' "$pid"
      break
    done <"$f"
  done
}

# proc_subtree <pid>: <pid> followed by every descendant, parents before children.
proc_subtree() {
  local level=("$1") pid child
  while ((${#level[@]})); do
    local next=()
    for pid in "${level[@]}"; do
      printf '%s\n' "$pid"
      while IFS= read -r child; do
        [[ -n $child ]] || continue
        next+=("$child")
      done < <(proc_children "$pid")
    done
    level=("${next[@]}")
  done
}

# proc_tree_leaks <pid> <needle>: every place the needle is visible in the
# kernel's own view of that process tree, one "where:pid" line per hit, and a
# zero exit status if there was a hit — so a caller can assert "no output" the
# way it would against grep. cmdline and environ are NUL-separated, so NULs
# become newlines first; the search is -F, so the needle is data, never a
# pattern.
proc_tree_leaks() {
  local root="$1" needle="$2" pid found=1
  while IFS= read -r pid; do
    if tr '\0' '\n' <"/proc/$pid/cmdline" 2>/dev/null | grep -qF -- "$needle"; then
      printf 'cmdline:%s\n' "$pid"; found=0
    fi
    if tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null | grep -qF -- "$needle"; then
      printf 'environ:%s\n' "$pid"; found=0
    fi
  done < <(proc_subtree "$root")
  return $found
}

# kill_tree <pid>: the process tree of <pid> is enumerated first (while it still
# has that shape), then the root is killed unignorably and the rest follow,
# deepest first. The root goes first for a reason: it is the only process that
# can still write a profile, and it must not get to take another step — and
# enumerating before the root dies is what keeps its children from being
# reparented out of reach.
kill_tree() {
  local root="$1" pid
  local -a pids=()
  while IFS= read -r pid; do pids+=("$pid"); done < <(proc_subtree "$root")
  ((${#pids[@]})) || return 0                 # already gone: nothing to kill
  kill -KILL "${pids[0]}" 2>/dev/null || true
  for (( i=${#pids[@]} - 1; i >= 1; i-- )); do
    kill "${pids[i]}" 2>/dev/null || true
  done
}

# Everything this case starts. An EXIT trap runs the same cleanup a failing
# check, an early exit or a Ctrl-C would otherwise skip — a stuck import or an
# open FIFO writer must not be able to outlive this case. The order matters: the
# import dies before the writer that was feeding it, so it cannot complete its
# read (and write a profile) in the instant the pipe closes.
SCAN_BACKEND=""
SCAN_WRITER=""
SCAN_FIXTURE=""
SCAN_FIFO=""
scan_cleanup() {
  [[ -n $SCAN_BACKEND ]] && kill_tree "$SCAN_BACKEND"; SCAN_BACKEND=""
  [[ -n $SCAN_WRITER  ]] && kill_tree "$SCAN_WRITER";  SCAN_WRITER=""
  [[ -n $SCAN_FIXTURE ]] && kill_tree "$SCAN_FIXTURE"; SCAN_FIXTURE=""
  [[ -n $SCAN_FIFO    ]] && rm -f "$SCAN_FIFO";        SCAN_FIFO=""
  wait 2>/dev/null || true
  return 0
}
trap scan_cleanup EXIT

# ---- the subject: a real import, driven the way the panel drives it ---------
# A payload of this case's own, so a failure shows up as a new profile instead
# of a silent edit of the fixture imported above.
jq -c '.id = "proc-scan-live-should-not-exist"' "$WORK/payload.json" \
  >"$WORK/proc-scan-payload.json"

# The writer hands the payload over and then holds the pipe open (`sleep`); it
# runs in the background so this shell never blocks on a FIFO that has no reader
# yet. `cat` names the payload *file* in its argv — the credential itself is
# only ever in the pipe.
SCAN_FIFO="$WORK/proc-scan.fifo"
mkfifo "$SCAN_FIFO"
{ cat "$WORK/proc-scan-payload.json"; exec sleep 60; } >"$SCAN_FIFO" &
SCAN_WRITER=$!
# Disowned on purpose: the pid is all we need, and a disowned job produces no
# "Killed"/"Terminated" job-control notice on stderr when cleanup reaps it —
# noise the rest of this suite's output does not deserve.
disown "$SCAN_WRITER"

# The subject itself. Note the shape: the credential arrives on stdin, which is
# also how a human is meant to use it (`omarchy-v2ray import < payload.json`).
OMARCHY_V2RAY_IMPORT_TIMEOUT=60 "$BACKEND" import <"$SCAN_FIFO" >/dev/null 2>&1 &
SCAN_BACKEND=$!
disown "$SCAN_BACKEND"

sleep 0.3
# The two liveness checks bracket the scan: a process that had already finished
# has an empty cmdline, and an empty cmdline would make the leak check below
# pass for the wrong reason.
check "the import is still running while /proc is sampled" kill -0 "$SCAN_BACKEND"
check "the sampled process really is the running import" \
  bash -c 'tr "\0" "\n" <"/proc/$1/cmdline" | grep -qx import' _ "$SCAN_BACKEND"
live_leaks="$(proc_tree_leaks "$SCAN_BACKEND" "$UUID")"
check "no credential in a live import's cmdline or environ" test -z "$live_leaks"
[[ -n $live_leaks ]] && printf '        visible at:\n%s\n' "$live_leaks"
check "the import is still running after the sample" kill -0 "$SCAN_BACKEND"

# Take it down, then prove it never managed to write: it was stopped with the
# payload still unfinished, so a profile here would mean it had completed the
# import behind our back and the scan above was looking at the wrong moment.
scan_cleanup
check "nothing was written by the import that was interrupted" test -z "$("$BACKEND" list 2>/dev/null \
  | jq -r '.[] | select(.id == "proc-scan-live-should-not-exist") | .id')"

# ---- the controls that keep those assertions from being vacuous -------------
# A scan that finds nothing proves nothing: an unreadable /proc, a needle that
# never reached the search, or a process tree that had already gone would all
# look exactly like a pass. So the same scan is aimed at the interface this
# whole change exists to remove — the pre-fix `omarchy-v2ray import "<json>"`,
# whose payload rode in argv (the old caller did precisely that, and commit
# 42b6033's script took it from $1). The credential MUST be found there: if it
# is not, this case could not fail against the old implementation and would be
# worth nothing.
#
# The fixture replays that calling convention with one addition the pre-fix
# script had no reason to have: it lingers, so /proc can be read while it is
# alive. (The real pre-fix process finished in milliseconds; its command line
# carried the UUID for every one of them.)
#
# The sentinel therefore appears in a command line — and, in the second control,
# in an environment — ONLY here, inside processes that exist to impersonate the
# vulnerable interface. The subject above is fed nothing but stdin.
cat >"$WORK/prefix-import-fixture" <<'SH'
#!/usr/bin/env bash
# $1 is the import payload, exactly as the pre-fix cmd_import received it.
: "${1:?payload}"
sleep 30                        # test-only: stay alive long enough to be read
SH
chmod +x "$WORK/prefix-import-fixture"

"$WORK/prefix-import-fixture" "$(jq -c . "$WORK/proc-scan-payload.json")" &
SCAN_FIXTURE=$!
disown "$SCAN_FIXTURE"
sleep 0.3
check_contains "control: the credential IS visible when it rides in argv" \
  "$(proc_tree_leaks "$SCAN_FIXTURE" "$UUID")" "cmdline:"
kill_tree "$SCAN_FIXTURE"; SCAN_FIXTURE=""

# ...and the environment half of the scanner is just as real. A per-command
# assignment delivers the sentinel to this one child only, so it never enters
# this shell's own environment (the subject's included).
SENTINEL_FOR_CONTROL="$(jq -c . "$WORK/proc-scan-payload.json")" \
  bash -c 'exec sleep 30' &
SCAN_FIXTURE=$!
disown "$SCAN_FIXTURE"
sleep 0.3
check_contains "control: the credential IS visible when it rides in the environment" \
  "$(proc_tree_leaks "$SCAN_FIXTURE" "$UUID")" "environ:"
kill_tree "$SCAN_FIXTURE"; SCAN_FIXTURE=""

# =============================================================================
echo
echo "case 0d: the profile tree is private, from the very first run"
# The tree holds the credential in <id>.config.json, and ensure_dirs promises
# "new files 0600, new dirs 0700". A validation pass on a COLD start found the
# promise only half kept: the umask was set *after* the mkdir, so a first-ever
# invocation created CONFIG_DIR, profiles/ and state/ with the user's umask (022
# on a stock shell) — 0755, world-listable. The files inside were still 0600, so
# no UUID ever leaked, but `ls` on the profiles directory published the profile
# ids, i.e. which servers the user has. Two properties are pinned here: a cold
# start creates a private tree, and a tree an older version left open gets
# repaired rather than staying listable for the life of the machine.
#
# PERM_HOME deliberately does not exist yet: that is what makes this the cold
# path, and the cold path is the only one the old code got wrong.
PERM_HOME="$WORK/perm-cold/home"
out="$(OMARCHY_V2RAY_HOME="$PERM_HOME" "$BACKEND" status 2>/dev/null)"
check "a cold start still answers status" jq -e '.ok == true' <<<"$out"
check "the config dir a cold start creates is 0700" test "$(stat -c %a "$PERM_HOME")" = 700
check "its profiles dir is 0700"                    test "$(stat -c %a "$PERM_HOME/profiles")" = 700
check "its state dir is 0700"                       test "$(stat -c %a "$PERM_HOME/state")" = 700

# An import into that same cold tree: the credential-bearing files are 0600.
OMARCHY_V2RAY_HOME="$PERM_HOME" "$BACKEND" import <"$WORK/payload.json" >/dev/null 2>&1
check "the credential-bearing config is written 0600" \
  test "$(stat -c %a "$PERM_HOME/profiles/$ID.config.json")" = 600
check "the link-bearing metadata is written 0600" \
  test "$(stat -c %a "$PERM_HOME/profiles/$ID.meta.json")" = 600

# ...and a tree the older code left wide open is repaired on the next call.
PERM_OLD="$WORK/perm-old/home"
mkdir -p "$PERM_OLD/profiles" "$PERM_OLD/state"
chmod 0777 "$PERM_OLD" "$PERM_OLD/profiles" "$PERM_OLD/state"
OMARCHY_V2RAY_HOME="$PERM_OLD" "$BACKEND" status >/dev/null 2>&1
check "a world-listable config dir is repaired to 0700"   test "$(stat -c %a "$PERM_OLD")" = 700
check "a world-listable profiles dir is repaired to 0700" test "$(stat -c %a "$PERM_OLD/profiles")" = 700
check "a world-listable state dir is repaired to 0700"    test "$(stat -c %a "$PERM_OLD/state")" = 700

# =============================================================================
echo
echo "case 0e: TUN is observed, never started"
# TUN mode is a system-wide tunnel and needs CAP_NET_ADMIN, so the half that
# creates it is privileged and lives in bin/omarchy-v2ray-tun, not here. This
# half only READS the root-written state file and answers "can TUN start here?";
# these cases pin that it is a pure query: always valid JSON, never a crash, and
# always "not active" when the file cannot be trusted.
TUN_STATE="$WORK/tun/state.json"
mkdir -p "$WORK/tun"
tun_status() { OMARCHY_V2RAY_TUN_STATE="$TUN_STATE" "$BACKEND" tun-status 2>/dev/null; }
tun_backend_status() { OMARCHY_V2RAY_TUN_STATE="$TUN_STATE" "$BACKEND" status 2>/dev/null; }

# check_one_json <description> <stdout>: stdout is non-empty and parses as
# exactly ONE JSON document (pretty-printed is fine). The blocker this guards
# against answered with EMPTY stdout and exit 0, so "exit 0" alone is not an
# assertion.
check_one_json() {
  local what="$1" text="$2"
  if [[ -n $text ]] \
     && jq -es 'length == 1 and (.[0] | type) == "object"' >/dev/null 2>&1 <<<"$text"; then
    printf '  ok   %s\n' "$what"
  else
    printf '  FAIL %s\n        stdout was: %s\n' "$what" "${text:-<empty>}"
    failures=$((failures + 1))
  fi
}

# No state file is the normal case on a machine that never started TUN mode.
out="$(tun_status)"
check "tun-status without a state file answers valid JSON" jq -e '.ok == true' <<<"$out"
check "and reports TUN as not active" jq -e '.active == false' <<<"$out"
check "the fake engine is xray, so TUN is available" jq -e '.available == true and .engine == "xray"' <<<"$out"
check "an available core needs no reason" jq -e '.reason == ""' <<<"$out"

# A well-formed file is passed through. $$ is a live pid — the test shell itself —
# which is exactly what the liveness check must accept.
jq -n --arg id "$ID" --arg pid "$$" \
  '{profileId:$id, iface:"tun0", pid:$pid, since:1700000000}' >"$TUN_STATE"
out="$(tun_status)"
check "a live, well-formed state is reported active" jq -e '.active == true' <<<"$out"
check "its profile id is passed through" jq -e --arg id "$ID" '.profileId == $id' <<<"$out"
check "its interface is passed through" jq -e '.iface == "tun0"' <<<"$out"
check "its start time is passed through" jq -e '.since == 1700000000' <<<"$out"
check "its pid is passed through as a string" jq -e --arg pid "$$" '.pid == $pid' <<<"$out"

# A half-written file is not a tunnel. The failure must stay silent on stdout
# (the caller always parses it) and on stderr (a wall of jq errors is not a
# user-facing message).
printf '%s' '{"profileId":' >"$TUN_STATE"
out="$(OMARCHY_V2RAY_TUN_STATE="$TUN_STATE" "$BACKEND" tun-status 2>"$WORK/tun/err")"
check "malformed JSON is not active, and still ok" jq -e '.ok == true and .active == false' <<<"$out"
check "malformed JSON produces no jq noise on stderr" test ! -s "$WORK/tun/err"

# Missing fields degrade instead of failing: no pid means no tunnel to report.
printf '%s' '{"profileId":"half"}' >"$TUN_STATE"
out="$(tun_status)"
check "a state file missing its pid is not active" jq -e '.ok == true and .active == false' <<<"$out"

# A state file holding TWO complete objects used to break both readers: `jq -c`
# emitted one line per document, the resulting multi-line value failed
# `--argjson` on stderr, and stdout was left EMPTY with exit 0. Both commands
# must still answer with exactly one parseable object and report TUN off.
printf '%s\n%s\n' \
  '{"profileId":"a","iface":"tun0","pid":1,"since":1}' \
  '{"profileId":"b","iface":"tun1","pid":1,"since":2}' >"$TUN_STATE"
out="$(tun_status)"; rc=$?
check "a two-document state file exits 0 (tun-status)" test "$rc" -eq 0
check_one_json "a two-document state file emits one JSON object (tun-status)" "$out"
check "and reports TUN off with no stale fields (tun-status)" jq -e \
  '.active == false and .profileId == "" and .iface == "" and .since == 0 and .pid == ""' <<<"$out"

out="$(tun_backend_status)"; rc=$?
check "a two-document state file exits 0 (status)" test "$rc" -eq 0
check_one_json "a two-document state file emits one JSON object (status)" "$out"
check "and reports TUN off with no stale fields (status)" jq -e \
  '.tunActive == false and .tunProfileId == "" and .tunIface == "" and .tunSince == 0' <<<"$out"

# pid 0 is not a process: `kill -0 0` (and /proc/0) refer to the caller's own
# process group, which used to make this look like a live tunnel.
jq -n --arg id "$ID" '{profileId:$id, iface:"tun0", pid:0, since:1700000000}' >"$TUN_STATE"
out="$(tun_status)"; rc=$?
check "pid 0 exits 0 (tun-status)" test "$rc" -eq 0
check_one_json "pid 0 still emits one JSON object (tun-status)" "$out"
check "pid 0 is not a live tunnel (tun-status)" jq -e \
  '.active == false and .pid == "" and .profileId == ""' <<<"$out"
out="$(tun_backend_status)"; rc=$?
check "pid 0 exits 0 (status)" test "$rc" -eq 0
check_one_json "pid 0 still emits one JSON object (status)" "$out"
check "pid 0 is not a live tunnel (status)" jq -e \
  '.tunActive == false and .tunProfileId == "" and .tunIface == "" and .tunSince == 0' <<<"$out"

# An empty or whitespace-only file is not a tunnel, and must not stop either
# command from answering.
for flavour in empty whitespace; do
  if [[ $flavour == empty ]]; then
    : >"$TUN_STATE"
  else
    printf ' \n\t\n' >"$TUN_STATE"
  fi
  out="$(tun_status)"; rc=$?
  check "a $flavour state file exits 0 (tun-status)" test "$rc" -eq 0
  check_one_json "a $flavour state file emits one JSON object (tun-status)" "$out"
  check "a $flavour state file is not active (tun-status)" jq -e '.active == false' <<<"$out"
  out="$(tun_backend_status)"; rc=$?
  check "a $flavour state file exits 0 (status)" test "$rc" -eq 0
  check_one_json "a $flavour state file emits one JSON object (status)" "$out"
  check "a $flavour state file is not active (status)" jq -e '.tunActive == false' <<<"$out"
done

# A pid that has exited is the stale-file case: it must not keep the UI painted
# as connected. It is made dead here (and reaped, so /proc cannot see it)
# rather than guessed. Both commands must agree on the fully-off shape.
( exit 0 ) &
dead_pid=$!
wait "$dead_pid" 2>/dev/null
jq -n --arg id "$ID" --arg pid "$dead_pid" \
  '{profileId:$id, iface:"tun0", pid:$pid, since:1700000000}' >"$TUN_STATE"
out="$(tun_status)"; rc=$?
check "a state file naming a dead pid exits 0 (tun-status)" test "$rc" -eq 0
check_one_json "a state file naming a dead pid emits one JSON object (tun-status)" "$out"
check "a state file naming a dead pid is fully off (tun-status)" jq -e \
  '.ok == true and .active == false and .profileId == "" and .iface == ""
   and .since == 0 and .pid == ""' <<<"$out"
out="$(tun_backend_status)"; rc=$?
check "a state file naming a dead pid exits 0 (status)" test "$rc" -eq 0
check_one_json "a state file naming a dead pid emits one JSON object (status)" "$out"
check "status reports a stale TUN as fully off" jq -e \
  '.tunActive == false and .tunProfileId == "" and .tunIface == "" and .tunSince == 0' <<<"$out"

# A hostile profileId in the root-written file. The id rule lives in
# read_tun_state, so BOTH readers fail closed by construction rather than each
# remembering to check — and neither ever echoes the crafted text or joins it
# into a path.
jq -n --arg pid "$$" '{profileId:"../../etc/passwd", iface:"tun0", pid:$pid, since:1}' \
  >"$TUN_STATE"
out="$(tun_status)"; rc=$?
check "a hostile profileId exits 0 (tun-status)" test "$rc" -eq 0
check "a hostile profileId is not active (tun-status)" jq -e \
  '.ok == true and .active == false and .profileId == ""' <<<"$out"
out="$(tun_backend_status)"; rc=$?
check "a hostile profileId exits 0 (status)" test "$rc" -eq 0
check "a hostile profileId is not active (status)" jq -e \
  '.tunActive == false and .tunProfileId == "" and .activeId == ""' <<<"$out"
check "the hostile text is not echoed anywhere (status)" \
  test "${out#*etc/passwd}" = "$out"

# `status` carries the same information, and must stay one parseable object both
# with and without a state file.
rm -f "$TUN_STATE"
out="$(OMARCHY_V2RAY_TUN_STATE="$TUN_STATE" "$BACKEND" status 2>/dev/null)"
check "status stays valid JSON with no TUN state" jq -e '.ok == true' <<<"$out"
check "status carries every TUN field" jq -e \
  'has("tunActive") and has("tunProfileId") and has("tunIface") and has("tunSince")
   and has("tunCanStart") and has("tunBlockedReason")' <<<"$out"
check "with no state, TUN is off and startable" jq -e \
  '.tunActive == false and .tunProfileId == "" and .tunIface == ""
   and .tunSince == 0 and .tunCanStart == true and .tunBlockedReason == ""' <<<"$out"
check "with nothing running the mode is off" jq -e '.mode == "off"' <<<"$out"
check "the pre-existing status fields are untouched" jq -e \
  '.installed == true and .engine == "xray" and .running == false
   and .pid == "" and .autostartId == ""' <<<"$out"

jq -n --arg id "$ID" --arg pid "$$" \
  '{profileId:$id, iface:"tun0", pid:$pid, since:1700000000}' >"$TUN_STATE"
out="$(OMARCHY_V2RAY_TUN_STATE="$TUN_STATE" "$BACKEND" status 2>/dev/null)"
check "status reports the active TUN tunnel" jq -e --arg id "$ID" \
  '.ok == true and .tunActive == true and .tunProfileId == $id
   and .tunIface == "tun0" and .tunSince == 1700000000' <<<"$out"
check "an active TUN is not startable again" jq -e '.tunCanStart == false' <<<"$out"

# THE SECOND HALF OF THE TUN CONTRACT: while the privileged engine is up it IS
# the connection. The panel derives `connected` from running/listening/activeId,
# and its connect button from the same fields, so a status that only described
# the user-side engine would say "Disconnected" with every packet inside the
# tunnel — and then let a click start a second engine on the same ports.
jq -n --arg id "$ID" --arg pid "$$" --argjson since "$(( $(date +%s) - 100 ))" \
  '{profileId:$id, iface:"omarchy-tun", pid:$pid, since:$since}' >"$TUN_STATE"
out="$(tun_backend_status)"
check "an active TUN is reported as the running connection" jq -e --arg id "$ID" '
  .mode == "tun" and .running == true and .listening == true
  and .activeId == $id and .activeName == "Test Server"
  and .socksPort == 10808 and .httpPort == 10809 and .pid != ""' <<<"$out"
check "its uptime is counted from tunSince, not from the proxy engine" jq -e \
  '.uptimeSec >= 100 and .uptimeSec < 600' <<<"$out"
check "and the TUN fields still describe the tunnel" jq -e --arg id "$ID" \
  '.tunActive == true and .tunProfileId == $id and .tunIface == "omarchy-tun"' <<<"$out"

# Both true at once: TUN wins, and the fields describe the TUN profile — the one
# whose config the privileged engine is actually running.
PROXY_PROFILES="$WORK/home/profiles"
printf '%s' '{"id":"proxy-second","name":"Proxy Second"}' \
  >"$PROXY_PROFILES/proxy-second.meta.json"
printf '%s' '{"inbounds":[{"port":20808},{"port":20809}],"outbounds":[]}' \
  >"$PROXY_PROFILES/proxy-second.config.json"
PROXY_STATE="$WORK/home/state"
echo "$$" >"$PROXY_STATE/engine.pid"
echo "proxy-second" >"$PROXY_STATE/active.id"
date +%s >"$PROXY_STATE/started.epoch"
out="$(OMARCHY_V2RAY_TUN_STATE="$WORK/tun/none.json" "$BACKEND" status 2>/dev/null)"
check "a live proxy engine reports mode proxy" jq -e '
  .mode == "proxy" and .running == true and .activeId == "proxy-second"
  and .activeName == "Proxy Second" and .socksPort == 20808' <<<"$out"
out="$(tun_backend_status)"
check "TUN wins when both would be true" jq -e --arg id "$ID" '
  .mode == "tun" and .activeId == $id and .activeName == "Test Server"
  and .socksPort == 10808 and .httpPort == 10809' <<<"$out"

# Starting the user-side engine underneath a live TUN tunnel would put two
# engines on 10808/10809: one of them dies, and status would then describe a
# connection the machine is not using. Refusing must name the way out.
out="$(OMARCHY_V2RAY_TUN_STATE="$TUN_STATE" "$BACKEND" start "$ID" 2>/dev/null)"
check "start refuses while TUN is on" jq -e '.ok == false' <<<"$out"
check_contains "the start refusal points at the TUN switch" \
  "$(jq -r '.error' <<<"$out")" "TUN switch"
out="$(OMARCHY_V2RAY_TUN_STATE="$TUN_STATE" "$BACKEND" toggle "$ID" 2>/dev/null)"
check "toggle refuses while TUN is on" jq -e '.ok == false' <<<"$out"
check_contains "the toggle refusal points at the TUN switch" \
  "$(jq -r '.error' <<<"$out")" "TUN switch"
rm -f "$PROXY_STATE/engine.pid" "$PROXY_STATE/active.id" "$PROXY_STATE/started.epoch"

# The hand-over order is what makes the port collision go away, and it is
# invisible from outside on a machine without a root-owned helper: assert it
# where it is written. stop_engine must come before the pkexec hand-off, and
# after the helper gate — a missing helper must not stop a working tunnel.
#
# No comment filter here: this is a bash file, where a full-line comment starts
# with `#`, not `//`, so the QML-style filter this used to carry removed
# nothing. The patterns match the real call order either way.
awk '/^cmd_tun_up\(\)/ { inblock = 1 } inblock { print; if (/^}/) exit }' \
  "$BACKEND" >"$WORK/tun-up-code"
check "tun-up stops the user-side engine before launching the helper" \
  bash -c 'code="$(tr -s "[:space:]" " " <"$1")"; [[ $code == *stop_engine*launch_tun_helper* ]]' \
  _ "$WORK/tun-up-code"
check "the helper gate runs before the engine is stopped" \
  bash -c 'code="$(tr -s "[:space:]" " " <"$1")"; [[ $code == *require_tun_helper*stop_engine* ]]' \
  _ "$WORK/tun-up-code"
# ...and a refusal really does leave the proxy engine alone, which is the same
# property observed from the outside rather than read from the source.
rm -f "$TUN_STATE"
echo "$$" >"$PROXY_STATE/engine.pid"
echo "$ID" >"$PROXY_STATE/active.id"
# Both seams pointed into $WORK: without the state seam a live tunnel on this
# machine would read as "already active" and turn a needsHelper case into a
# different refusal; without the helper seam the case would depend on whether
# /usr/local/lib happens to hold an installed helper.
out="$(OMARCHY_V2RAY_TUN_HELPER="$WORK/no-such-helper" OMARCHY_V2RAY_TUN_STATE="$TUN_STATE" \
       "$BACKEND" tun-up "$ID" 2>/dev/null)"
check "tun-up without an installed helper is needsHelper" \
  jq -e '.ok == false and .needsHelper == true' <<<"$out"
check "and it leaves the running proxy engine recorded" \
  test -s "$PROXY_STATE/engine.pid"
check "and it leaves the active profile recorded" \
  test -f "$PROXY_STATE/active.id"
rm -f "$PROXY_STATE/engine.pid" "$PROXY_STATE/active.id"

# v2ray-core has no tun inbound, so TUN must be refused even with a healthy
# engine installed — and the refusal has to name the package, not just say no.
#
# The call is given a MINIMAL PATH on purpose: this machine may well have xray
# installed (that is the normal case for this plugin), and leaving /usr/bin on
# PATH would let the real xray answer for the wrong engine. The tools `status`
# shells out to are linked in and a fake v2ray shadows any real one, so the only
# core visible for these calls is v2ray. FAKEBIN itself is untouched: every other
# case depends on the xray double in it.
V2RAYBIN="$WORK/bin-v2ray"
mkdir -p "$V2RAYBIN"
cat >"$V2RAYBIN/v2ray" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  version) echo "v2ray 0.0.0-test (test double)"; exit 0 ;;
esac
sleep 4
SH
chmod +x "$V2RAYBIN/v2ray"
# Tools `status` shells out to: extend this list rather than delete it when
# status grows another external command, or this case fails for the wrong reason.
for tool in bash env jq tr date tail awk sed grep mkdir chmod rm cat head cut seq sleep; do
  src="$(command -v "$tool" 2>/dev/null)" && ln -sf "$src" "$V2RAYBIN/$tool"
done
cp "$FAKEBIN/ss" "$FAKEBIN/curl" "$V2RAYBIN/"
NOXRAY_PATH="$V2RAYBIN"

out="$(PATH="$NOXRAY_PATH" OMARCHY_V2RAY_TUN_STATE="$WORK/tun/none.json" "$BACKEND" tun-status 2>/dev/null)"
check "with only v2ray installed, TUN is unavailable" jq -e \
  '.ok == true and .available == false and .engine == "v2ray"' <<<"$out"
check_contains "the unavailability names the fix" "$(jq -r '.reason' <<<"$out")" \
  "omarchy pkg aur add xray"

out="$(PATH="$NOXRAY_PATH" OMARCHY_V2RAY_TUN_STATE="$WORK/tun/none.json" "$BACKEND" status 2>/dev/null)"
check "with only v2ray installed, tunCanStart is false" jq -e \
  '.ok == true and .tunCanStart == false and .tunActive == false' <<<"$out"
check_contains "and status names the same fix" "$(jq -r '.tunBlockedReason' <<<"$out")" \
  "omarchy pkg aur add xray"

# The privileged half exists in a later slice, but it is NOT installed by this
# suite (and must not be: that needs pkexec). What matters here is the contract:
# with no root-owned helper installed, tun-down refuses with needsHelper and
# never asks for a password, and a missing id is refused before any of that. A
# recording pkexec double proves the second half.
PKEBIN="$WORK/pkexec-bin"
mkdir -p "$PKEBIN"
cat >"$PKEBIN/pkexec" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$PKEXEC_ARGS"
SH
chmod +x "$PKEBIN/pkexec"

out="$("$BACKEND" tun-up 2>/dev/null)"
check "tun-up without an id is refused" \
  jq -e '.ok == false and (.error | contains("needs a profile id"))' <<<"$out"

# HERMETIC BY CONSTRUCTION: both seams point into $WORK. Without the state seam
# this run would read the machine's real /run state — and the unprivileged stop
# would SIGNAL whatever that file names, including a healthy tunnel's engine.
# Without the helper seam the case depended on whether a helper really is
# installed under /usr/local/lib (it is, on this machine — that is what made
# these two assertions fail). "No state file" models the clean case, so rm it
# explicitly whatever earlier cases left behind.
rm -f "$WORK/pkexec.args" "$TUN_STATE"
PKEXEC_ARGS="$WORK/pkexec.args" PATH="$PKEBIN:$PATH" \
  OMARCHY_V2RAY_TUN_HELPER="$WORK/not-installed-helper" \
  OMARCHY_V2RAY_TUN_STATE="$TUN_STATE" \
  "$BACKEND" tun-down >"$WORK/tun-down.json" 2>/dev/null
check "tun-down asks for the helper install instead of prompting" \
  jq -e '.ok == false and .needsHelper == true and (.error | contains("install-tun"))' <"$WORK/tun-down.json"
check "tun-down did not invoke pkexec without a checked helper" \
  test ! -e "$WORK/pkexec.args"

# =============================================================================
# The unprivileged stop: the TUN engine runs as the INVOKING USER with only
# CAP_NET_ADMIN, so killing it does not need root at all — the helper's root
# supervisor (still in `up`) notices the exit, restores DNS, removes the routes
# and deletes the state file by itself. That is what this models:
#
#   * the stand-in engine is a binary copy of `sleep` named `xray`, so
#     /proc/<pid>/comm reads "xray" exactly as the real engine's does;
#   * the state file at the $WORK seam names that pid;
#   * a watcher removes the state file once the pid is gone — the modelled
#     supervisor (the real one runs as root and can never run inside a test).
#
# `tun-down` must then finish WITHOUT pkexec: ok:true, stopped:true, engine
# gone, state file removed, and the recording pkexec double untouched.
xray_pid=""
if cp /usr/bin/sleep "$WORK/xray" && chmod +x "$WORK/xray"; then
  "$WORK/xray" 120 & xray_pid=$!
  sleep 0.1
  if [[ "$(cat "/proc/$xray_pid/comm" 2>/dev/null)" == "xray" ]]; then
    jq -n --arg pid "$xray_pid" \
      '{profileId:"tun-test", iface:"omarchy-tun", pid:$pid, since:1700000000}' >"$TUN_STATE"
    # -n $(cat comm), not -s on the file: /proc files report st_size == 0, so a
    # size test would be false from birth and the watcher would delete the state
    # file before tun-down ever saw it. An empty read covers both a killed-but-
    # not-yet-reaped zombie (empty comm) and a fully dead pid (read error).
    ( while [[ -n "$(cat -- "/proc/$xray_pid/comm" 2>/dev/null)" ]]; do sleep 0.1; done
      rm -f -- "$TUN_STATE" ) & watcher_pid=$!
    rm -f "$WORK/pkexec.args"
    out="$(PKEXEC_ARGS="$WORK/pkexec.args" PATH="$PKEBIN:$PATH" \
      OMARCHY_V2RAY_TUN_STATE="$TUN_STATE" \
      OMARCHY_V2RAY_TUN_HELPER="$WORK/never-installed-helper" \
      "$BACKEND" tun-down 2>/dev/null)"; down_rc=$?
    check "the unprivileged stop exits 0" test "$down_rc" -eq 0
    check "it reports stopped, and it is not a pkexec launch" \
      jq -e '.ok == true and .stopped == true and (has("launched") | not)' <<<"$out"
    # Reap the stand-in so no zombie /proc entry survives the assertion.
    wait "$xray_pid" 2>/dev/null
    check "the engine process is gone" \
      test ! -d "/proc/$xray_pid"
    check "the modelled supervisor removed the state file" \
      test ! -e "$TUN_STATE"
    check "pkexec was never invoked" \
      test ! -e "$WORK/pkexec.args"
    wait "$watcher_pid" 2>/dev/null
    xray_pid=""
  else
    printf '  SKIP the unprivileged stop (the stand-in does not report comm=xray)\n'
    kill "$xray_pid" 2>/dev/null || true
    xray_pid=""
  fi
fi
[[ -n $xray_pid ]] && kill "$xray_pid" 2>/dev/null || true

# ============================================================================= ====
# The HUNG-engine escalation: an engine that ignores SIGTERM must still stop
# prompt-free. The stand-in is a binary copy of bash named `xray` running
# `trap "" TERM` — its /proc/<pid>/comm is exactly "xray" and it refuses to die
# politely, which is the only shape a userspace test can give a hung engine.
# The backend must spend its ~5s TERM wait, re-identify the pid by comm, then
# SIGKILL it with the same uid — no pkexec anywhere. The lower bound on the
# elapsed time is the proof the TERM wait was actually spent: sleep 0.2 never
# overshoots DOWNward, so 25 rounds are never less than 5s.
if cp /bin/bash "$WORK/xray" 2>/dev/null && chmod +x "$WORK/xray"; then
  "$WORK/xray" -c 'trap "" TERM; while :; do sleep 0.2; done' & xray_pid=$!
  sleep 0.1
  if [[ "$(cat "/proc/$xray_pid/comm" 2>/dev/null)" == "xray" ]]; then
    jq -n --arg pid "$xray_pid" \
      '{profileId:"tun-test", iface:"omarchy-tun", pid:$pid, since:1700000000}' >"$TUN_STATE"
    ( while [[ -n "$(cat -- "/proc/$xray_pid/comm" 2>/dev/null)" ]]; do sleep 0.1; done
      rm -f -- "$TUN_STATE" ) & watcher_pid=$!
    rm -f "$WORK/pkexec.args"
    SECONDS=0
    out="$(PKEXEC_ARGS="$WORK/pkexec.args" PATH="$PKEBIN:$PATH" \
      OMARCHY_V2RAY_TUN_STATE="$TUN_STATE" \
      OMARCHY_V2RAY_TUN_HELPER="$WORK/never-installed-helper" \
      "$BACKEND" tun-down 2>/dev/null)"; down_rc=$?
    hung_elapsed=$SECONDS
    check "a TERM-ignoring engine is stopped via the same-uid SIGKILL" \
      test "$down_rc" -eq 0
    check "the escalation still reports stopped, without a launch" \
      jq -e '.ok == true and .stopped == true and (has("launched") | not)' <<<"$out"
    # Reap so no zombie /proc entry survives the assertion.
    wait "$xray_pid" 2>/dev/null
    check "the hung stand-in is gone" \
      test ! -d "/proc/$xray_pid"
    check "the ~5s TERM wait was spent before the escalation" \
      test "$hung_elapsed" -ge 5
    check "the modelled supervisor's cleanup was awaited" \
      test ! -e "$TUN_STATE"
    check "the escalation never reached pkexec" \
      test ! -e "$WORK/pkexec.args"
    wait "$watcher_pid" 2>/dev/null
    xray_pid=""
  else
    printf '  SKIP the hung-engine escalation (the stand-in does not report comm=xray)\n'
    kill -KILL "$xray_pid" 2>/dev/null || true
    xray_pid=""
  fi
fi
[[ -n $xray_pid ]] && kill -KILL "$xray_pid" 2>/dev/null || true

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
# one, so assert on the caller too. These checks read the panel's text, so they
# are deliberately blind to formatting: full-line comments are dropped and every
# run of whitespace — including newlines — collapses to a single space, which
# means a call is still matched if it is wrapped or re-indented. A source-text
# check can never prove a credential is absent (case 6 launches the real panel
# for that), but it catches a reintroduction even on a machine without
# quickshell.
SERVICE="$HERE/../Service.qml"

# strip_code <file>: drop full-line `//` comments, then collapse all whitespace
# into single spaces. Matching against this instead of raw lines is what keeps
# these assertions independent of how the code happens to be laid out.
strip_code() {
  grep -v '^[[:space:]]*//' "$1" | tr -s '[:space:]' ' '
}
check_match() {             # check_match <description> <extended-regex> <text>
  local what="$1" pattern="$2" text="$3"
  if grep -Eq -- "$pattern" <<<"$text"; then
    printf '  ok   %s\n' "$what"
  else
    printf '  FAIL %s\n        nothing matched: %s\n' "$what" "$pattern"
    failures=$((failures + 1))
  fi
}
check_no_match() {          # check_no_match <description> <extended-regex> <text>
  local what="$1" pattern="$2" text="$3"
  if grep -Eq -- "$pattern" <<<"$text"; then
    printf '  FAIL %s\n        found the forbidden shape: %s\n' "$what" "$pattern"
    failures=$((failures + 1))
  else
    printf '  ok   %s\n' "$what"
  fi
}

CODE="$(strip_code "$SERVICE")"

# The import is driven as a three-part call: the command array names only the
# script and the subcommand, and the JSON payload is the separate third
# argument, which Service.qml hands to the child's stdin.
check_match "the panel calls runAction([bash, script, import], id, JSON.stringify(payload))" \
  'runAction\([[:space:]]*\["bash",[[:space:]]*scriptPath,[[:space:]]*"import"\][[:space:]]*,[[:space:]]*String\([[:space:]]*payload\.id[[:space:]]*\)[[:space:]]*,[[:space:]]*JSON\.stringify\([[:space:]]*payload[[:space:]]*\)[[:space:]]*\)' \
  "$CODE"

# ...and nothing may follow "import" inside a command array. That one rule is
# exactly what the old `["bash", scriptPath, "import", JSON.stringify(payload)]`
# broke, and it stays true however a payload might be spelled.
check_no_match "no payload element is appended to the import command array" \
  '"import"[[:space:]]*,' "$CODE"

# `bash -c "<string built from app data>"` is how a credential reaches argv, so
# the panel must not build a shell command line anywhere (the clipboard used
# to). execDetached is fine for install/reveal, but never with a payload.
check_no_match "the panel never builds a bash -c command line" \
  '"-c"|bash[[:space:]]+-c' "$CODE"
check_no_match "the panel never hands a payload to execDetached" \
  'execDetached\([^)]*(payload|JSON\.stringify)' "$CODE"

# And the Process behind every action really does carry the payload on stdin:
# the channel is opened before the child starts, written in onStarted, and
# closed immediately afterwards.
check_match "the action process enables stdin when there is a payload" \
  'actionProc\.stdinEnabled[[:space:]]*=[[:space:]]*_actionStdin[[:space:]]*!==[[:space:]]*""' "$CODE"
check_match "the payload is written to the child's stdin" \
  'actionProc\.write\([[:space:]]*root\._actionStdin[[:space:]]*\)' "$CODE"
check_match "stdin is closed once the payload has been written" \
  'actionProc\.stdinEnabled[[:space:]]*=[[:space:]]*false' "$CODE"

# The clipboard copies the same secret — a share link carries the UUID — so it
# gets the same shape: a bare `wl-copy` with the text arriving on stdin. The old
# code ran it as `bash -c "printf %s '<link>' | wl-copy"`, which parked the link
# in the shell's argv one process above wl-copy.
check_match "the clipboard is a direct wl-copy process" \
  'command:[[:space:]]*\["wl-copy"\]' "$CODE"
check_no_match "nothing may be appended to the wl-copy command array" \
  '\["wl-copy"[[:space:]]*,' "$CODE"
check_match "wl-copy is given a stdin payload" \
  'clipProc\.stdinEnabled[[:space:]]*=[[:space:]]*true' "$CODE"
check_match "the copied text is written to wl-copy's stdin" \
  'clipProc\.write\([[:space:]]*root\._clipText[[:space:]]*\)' "$CODE"
check_match "wl-copy's stdin is closed so the copy happens" \
  'clipProc\.stdinEnabled[[:space:]]*=[[:space:]]*false' "$CODE"
# (Checked line by line, not against the collapsed text: `execDetached\(.*wl-copy`
# on one long line would happily span every unrelated call between the two.)
check "the clipboard never goes through a detached shell" \
  bash -c '! grep -v "^[[:space:]]*//" "$1" | grep -Eq "execDetached.*wl-copy"' _ "$SERVICE"

# The panel's IPC surface is the other channel where an argument becomes a
# command line: `qs ipc call <target> <function> <arguments…>` delivers each
# argument on the CALLER's cmdline, and Quickshell's IPC has no stdin channel
# (a literal `-` is passed through as text). Panel.qml used to publish
# `importLink(link: string): string` — an import handler whose argument IS the
# credential — so the handler now declares no parameters at all. The runtime
# proof is in tests/test-service-import.sh (it loads the real panel and asks its
# live IPC surface); this is the same rule checked in the source, so a
# reintroduction is caught on machines without quickshell too.
PANEL="$HERE/../Panel.qml"
# The note lives here, not inside the awk program: an apostrophe in a comment
# inside a single-quoted shell string closes the string. Brace counting is used
# rather than "everything up to the first }" because the handler have bodies of
# its own, so the block ends where the brace depth returns to zero.
IPC_CODE="$(awk '
  /IpcHandler[[:space:]]*\{/ { inblock = 1 }
  inblock {
    depth += gsub(/\{/, "{") - gsub(/\}/, "}")
    print
    if (depth <= 0) exit
  }
' "$PANEL" | grep -v '^[[:space:]]*//' | tr -s '[:space:]' ' ')"
check_match "the panel still declares its IpcHandler"   'target:[[:space:]]*root\.ipcTarget' "$IPC_CODE"
check_no_match "no IPC handler declares a parameter (an IPC argument is world-readable argv)" \
  'function[[:space:]]+[A-Za-z0-9_]+[[:space:]]*\([[:space:]]*[A-Za-z_]' "$IPC_CODE"
check_no_match "no IPC handler is named importLink" 'importLink' "$IPC_CODE"

# =============================================================================
echo
echo "case 6: the real panel, driven by quickshell, must send the payload on stdin"
# The checks above read Service.qml; this one runs it. It starts quickshell with
# the real panel, imports a link carrying a sentinel credential, and inspects
# the child process the panel actually spawned. It also loads the real Panel.qml
# and asks its live IPC surface what it publishes, so an import handler cannot
# come back as a public IPC function — with the pre-fix Panel.qml replayed as the
# control. It needs quickshell and a Wayland session and prints SKIP (exit 0)
# without them, so this suite still runs headless (case 5 checks the same IPC
# shape in the source for exactly those machines). See tests/test-service-import.sh
# for how the child is observed and why the controls keep it honest.
panel_out="$("$HERE/test-service-import.sh" 2>&1)"
panel_rc=$?
printf '%s\n' "$panel_out"
panel_failed="$(grep -c '^  FAIL' <<<"$panel_out")" || true
failures=$(( failures + ${panel_failed:-0} ))
if (( panel_rc != 0 && ${panel_failed:-0} == 0 )); then
  printf '  FAIL the panel integration test aborted (exit %d)\n' "$panel_rc"
  failures=$(( failures + 1 ))
fi

# =============================================================================
echo
echo "case 7: the TUN switch's state machine, driven by quickshell"
# Case 6 proves the credential never reaches argv; this one pins the asynchronous
# state around a polkit prompt, where both review blockers lived: connect paths
# that were not gated on `tunArming` (B1) and a stale helper error that cleared
# the arming before authentication (B2). Like case 6 it needs quickshell and
# prints SKIP (exit 0) without it. See tests/test-service-tun.sh.
tun_out="$("$HERE/test-service-tun.sh" 2>&1)"
tun_rc=$?
printf '%s\n' "$tun_out"
tun_failed="$(grep -c '^  FAIL' <<<"$tun_out")" || true
failures=$(( failures + ${tun_failed:-0} ))
if (( tun_rc != 0 && ${tun_failed:-0} == 0 )); then
  printf '  FAIL the TUN state machine test aborted (exit %d)\n' "$tun_rc"
  failures=$(( failures + 1 ))
fi

# =============================================================================
echo
if (( failures == 0 )); then
  echo "all tests passed"
else
  echo "$failures test(s) FAILED"
fi
rm -rf "$WORK"
exit $(( failures > 0 ))

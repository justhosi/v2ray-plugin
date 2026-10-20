#!/usr/bin/env bash
# =============================================================================
# Regression tests for the PRIVILEGED TUN helper, bin/omarchy-v2ray-tun.
#
# WHY THIS EXISTS
# ---------------
# The helper creates a system-wide tun device: it needs CAP_NET_ADMIN and is
# meant to run as root through pkexec. That makes it the security-critical half
# of TUN mode and the one part of this project that cannot be exercised by
# actually starting a tunnel — a test has no business creating tun devices,
# rewriting /etc/resolv.conf or asking polkit for anything.
#
# So the behavioural cases run the helper in DRY-RUN mode
# (OMARCHY_V2RAY_TUN_DRY_RUN=1), which executes the whole validation path and
# prints the exact commands it WOULD run, then exits without touching /run, DNS
# or a process. That is deliberate: the checks below drive the real code, not a
# parallel test-only implementation.
#
# The launcher cases drive bin/omarchy-v2ray with a RECORDING pkexec double on
# PATH. They prove the helper path is validated (root-owned, not a symlink)
# before any prompt, and that a bad path never reaches pkexec at all. No real
# pkexec, sudo or privileged helper is ever executed here.
#
# HOW TO RUN
# ----------
#     ./tests/test-tun-helper.sh
#
# It touches nothing outside its own temp directory: the helper reads
# OMARCHY_V2RAY_TUN_RUN_DIR and (in dry-run only) OMARCHY_V2RAY_HOME.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$HERE/../bin/omarchy-v2ray-tun"
BACKEND="$HERE/../bin/omarchy-v2ray"

WORK="$(mktemp -d)"
FAKEBIN="$WORK/bin"
CONFIG_HOME="$WORK/home"
RUN="$WORK/run"
PROFILES="$CONFIG_HOME/profiles"
mkdir -p "$FAKEBIN" "$PROFILES" "$RUN"

# The helper ignores everything from the environment except its explicit test
# seams; these are the same two the unprivileged backend already uses for tests.
export OMARCHY_V2RAY_TUN_DRY_RUN=1
export OMARCHY_V2RAY_TUN_RUN_DIR="$RUN"
export OMARCHY_V2RAY_HOME="$CONFIG_HOME"
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
check_not_contains() {
  local what="$1" hay="$2" needle="$3"
  if [[ $hay != *"$needle"* ]]; then
    printf '  ok   %s\n' "$what"
  else
    printf '  FAIL %s\n        must NOT contain: %s\n        inside: %s\n' "$what" "$needle" "$hay"
    failures=$((failures + 1))
  fi
}

# The refusal assertions below check that a detached `setsid pkexec … &` never
# happened. The backend returns before such a child would write anything, so
# asserting immediately would race the launch: give it the same window a launch
# would need, and only then conclude it did not occur.
pkexec_quiet() {
  local i
  for i in $(seq 1 40); do
    [[ -e "$WORK/pkexec.args" ]] && return 1
    sleep 0.05
  done
  return 0
}

FAKE_PID=""
cleanup() {
  [[ -n $FAKE_PID ]] && kill "$FAKE_PID" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

# --------------------------------------------------------------- doubles ----
# The one program the backend is allowed to escalate through. Recording only:
# it writes its argv and exits, so a test can prove both "pkexec was asked to
# run X" and "pkexec was never reached".
cat >"$FAKEBIN/pkexec" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$WORK/pkexec.args"
SH
chmod +x "$FAKEBIN/pkexec"

# The terminal launcher, doubled for the same reason: `install-tun` hands its
# command to a visible terminal, and a test must never open one. `install-engine`
# and `install-xray` find this too, but no case here calls them.
cat >"$FAKEBIN/omarchy-launch-floating-terminal-with-presentation" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$WORK/launcher.args"
SH
chmod +x "$FAKEBIN/omarchy-launch-floating-terminal-with-presentation"

# --------------------------------------------------------------- fixtures ----
# A profile in the shape the panel imports: a SOCKS inbound (the readiness probe
# uses its port) plus one outbound. The credential is a sentinel so the cases
# can also prove that no output ever carries it.
ID="tun-test"
UUID="99999999-8888-7777-6666-555555555555"

cat >"$PROFILES/$ID.config.json" <<JSON
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    { "tag": "socks-in", "listen": "127.0.0.1", "port": 10808, "protocol": "socks",
      "settings": { "auth": "noauth", "udp": true } }
  ],
  "outbounds": [
    { "tag": "proxy", "protocol": "vless",
      "settings": { "vnext": [ { "address": "203.0.113.10", "port": 443,
        "users": [ { "id": "$UUID", "encryption": "none" } ] } ] } }
  ]
}
JSON
cat >"$PROFILES/$ID.meta.json" <<JSON
{ "id": "$ID", "name": "TUN Test", "type": "vless", "host": "203.0.113.10", "port": 443 }
JSON
chmod 600 "$PROFILES/$ID.config.json" "$PROFILES/$ID.meta.json"

# Does this machine have an engine the helper's allowlist would accept? The
# helper hard-codes those paths on purpose, so a fake xray on PATH cannot
# satisfy it; when no real xray exists the "up" case exercises the refusal
# instead of the plan. (On Omarchy xray is installed, so the plan runs.)
HAVE_XRAY=false
for candidate in /usr/local/bin/xray /usr/bin/xray; do
  [[ -x $candidate ]] && HAVE_XRAY=true
done

# =============================================================================
echo
echo "case 1: up builds a plan with the tun inbound, the capability and the /1 routes"
if [[ $HAVE_XRAY == true ]]; then
  out="$("$HELPER" up "$ID" 2>/dev/null)"; rc=$?
  check "up exits 0" test "$rc" -eq 0
  check "stdout is one dry-run JSON document" \
    jq -e -s 'length == 1 and .[0].ok == true and .[0].dryRun == true and (.[0].commands | type == "array" and length > 0)' <<<"$out"
  flat="$(jq -r '.commands | join("\n")' <<<"$out")"

  check_contains "engine runs with the ambient net_admin capability" "$flat" "--ambient-caps=+net_admin"
  check_contains "net_admin is also inheritable (ambient requires it)" "$flat" "--inh-caps=+net_admin"
  check_contains "engine drops to the invoking uid" "$flat" "--reuid=$(id -u)"
  check_contains "engine drops to the invoking gid" "$flat" "--regid=$(id -g)"
  check_contains "engine starts detached with setsid" "$flat" "setsid setpriv"
  check_contains "the run dir is traversal-only for the unprivileged panel" "$flat" "chmod 0711"
  check_contains "engine reads the config from the helper's run dir" "$flat" "$RUN/config.json"
  check_contains "the plan names the tun interface" "$flat" "autoOutboundsInterface"
  check_contains "the plan carries the IPv4 upper-half route" "$flat" "0.0.0.0/1"
  check_contains "the plan carries the IPv4 lower-half route" "$flat" "128.0.0.0/1"
  check_contains "the plan carries the IPv6 upper-half route" "$flat" "::/1"
  check_contains "the plan carries the IPv6 lower-half route" "$flat" "8000::/1"

  # S4: the profile transform is the USER's jq, not root's. The plan must show
  # the setpriv argv (the `| cat > config.json` root side is a redirect and is
  # therefore implied, not an argv element).
  JQ_PATH="$(command -v jq)"
  check_contains "the profile is transformed by the invoking user's jq" \
    "$flat" "setpriv --reuid=$(id -u) --regid=$(id -g) --clear-groups -- $JQ_PATH"
  check_contains "the jq argv still carries the tun inbound program" "$flat" "autoSystemRoutingTable"

  # DNS handling depends on the machine, exactly as the helper decides it.
  if command -v resolvectl >/dev/null 2>&1 && systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    check_contains "DNS points into the tunnel through resolvectl" "$flat" "1.1.1.1 9.9.9.9"
    check_contains "the plan reverts the per-link DNS on teardown" "$flat" "resolvectl revert"
  else
    check_contains "the plan snapshots /etc/resolv.conf" "$flat" "$RUN/resolv.conf.orig"
  fi
  check_not_contains "the credential never appears in the plan" "$flat" "$UUID"
  check "the dry run wrote no state file" test ! -e "$RUN/state.json"
  check "the dry run wrote no config" test ! -e "$RUN/config.json"
else
  out="$("$HELPER" up "$ID" 2>/dev/null)"
  check "up refuses without an allowlisted xray" jq -e '.ok == false and (.error | contains("omarchy pkg aur add xray"))' <<<"$out"
fi

# =============================================================================
echo
echo "case 2: a hostile profile id is refused, and the refusal names it"
for bad in ".." "a..b" "../etc/passwd" "a/b" "-rf" ".hidden"; do
  out="$("$HELPER" up "$bad" 2>/dev/null)"; rc=$?
  check "id '$bad' exits 1" test "$rc" -eq 1
  check "id '$bad' is ok:false" jq -e '.ok == false' <<<"$out"
  # Naming the id is what stops this case passing for the wrong reason on a
  # host whose real refusal would be "no xray" or "bad permissions".
  check "id '$bad' is named in the error" jq -e --arg id "$bad" '.error | contains($id)' <<<"$out"
  check "id '$bad' emits no commands" jq -e 'has("commands") | not' <<<"$out"
done
# An empty id is what `tun-up` without an argument passes through.
out="$("$HELPER" up "" 2>/dev/null)"; rc=$?
check "an empty id exits 1" test "$rc" -eq 1
check "an empty id emits no commands" jq -e '.ok == false and (has("commands") | not)' <<<"$out"
check "no refusal created a config in the run dir" test ! -e "$RUN/config.json"

# =============================================================================
echo
echo "case 3: an unsafe profile config is refused"
# 3a. A symlink. -f would happily follow it; the helper must test -L first.
cp "$PROFILES/$ID.config.json" "$PROFILES/real-target.config.json"
ln -s real-target.config.json "$PROFILES/linked.config.json"
out="$("$HELPER" up linked 2>/dev/null)"; rc=$?
check "a symlinked config exits 1" test "$rc" -eq 1
check "a symlinked config is refused as a symlink" \
  jq -e '.ok == false and (.error | contains("symlink"))' <<<"$out"
check "a symlinked config emits no commands" jq -e 'has("commands") | not' <<<"$out"

# 3b. Group- and world-writable configs: another account could swap the bytes
# between the ownership check and the transform.
for mode in 660 664 666; do
  cp "$PROFILES/$ID.config.json" "$PROFILES/writable.config.json"
  chmod "$mode" "$PROFILES/writable.config.json"
  out="$("$HELPER" up writable 2>/dev/null)"; rc=$?
  check "a $mode config exits 1" test "$rc" -eq 1
  check "a $mode config is refused as writable" \
    jq -e '.ok == false and (.error | contains("writable"))' <<<"$out"
done

# 3c. A config owned by somebody else. Only root can create that condition, so
# this case is a documented skip on a normal developer machine.
if [[ $EUID -eq 0 ]]; then
  cp "$PROFILES/$ID.config.json" "$PROFILES/foreign.config.json"
  chown 1:1 "$PROFILES/foreign.config.json"
  chmod 600 "$PROFILES/foreign.config.json"
  out="$("$HELPER" up foreign 2>/dev/null)"; rc=$?
  check "a foreign-owned config exits 1" test "$rc" -eq 1
  check "a foreign-owned config is refused" \
    jq -e '.ok == false and (.error | contains("owned by the invoking user"))' <<<"$out"
else
  printf '  SKIP a foreign-owned config (changing a file owner needs root)\n'
fi

# =============================================================================
echo
echo "case 4: without root and without dry-run, the helper refuses to act"
if [[ $EUID -ne 0 ]]; then
  out="$(env -u OMARCHY_V2RAY_TUN_DRY_RUN "$HELPER" up "$ID" 2>/dev/null)"; rc=$?
  check "an unprivileged real run exits 1" test "$rc" -eq 1
  # The self-check runs BEFORE the "am I root" check, so a repo copy (owned by
  # the user) gets the actionable install message rather than a generic refusal.
  check "the refusal names the installed path" jq -e '.ok == false and (.error | contains("install-tun"))' <<<"$out"
  check "nothing was launched or recorded" test ! -e "$RUN/state.json"
else
  printf '  SKIP the non-root refusal (this suite is running as root)\n'
fi

# =============================================================================
echo
echo "case 5: down with no state is a successful no-op"
rm -f "$RUN/state.json" "$RUN/config.json" "$RUN/resolv.conf.orig"
out="$(OMARCHY_V2RAY_TUN_IFACE=tun-test-none0 "$HELPER" down 2>/dev/null)"; rc=$?
check "down exits 0 with nothing running" test "$rc" -eq 0
check "down reports ok and is still a dry run" jq -e '.ok == true and .dryRun == true' <<<"$out"
check "down emits no destructive command" jq -e '(.commands | length) == 0' <<<"$out"

# =============================================================================
echo
echo "case 6: down with a state file stops the recorded engine and restores DNS"
# A stand-in engine: /proc/<pid>/comm must look like a core, because `down`
# refuses to signal a recycled pid that is not one. A binary copy of `sleep`
# named `xray` gives exactly that /proc entry without opening a socket. (A shell
# SCRIPT would report its interpreter, "bash", in comm.)
cp "$(command -v sleep)" "$WORK/xray"
chmod +x "$WORK/xray"
"$WORK/xray" 120 &
FAKE_PID=$!
sleep 0.1
if [[ "$(cat "/proc/$FAKE_PID/comm" 2>/dev/null)" == "xray" ]]; then
  stand_in_ok=true
else
  stand_in_ok=false
  printf '  FAIL the stand-in does not report comm=xray (got "%s"); case 6/7 cannot run\n' \
    "$(cat "/proc/$FAKE_PID/comm" 2>/dev/null)"
  failures=$((failures + 1))
fi

if [[ $stand_in_ok == true ]]; then
  jq -n --arg pid "$FAKE_PID" --argjson since "$(date +%s)" \
    '{profileId:"tun-test", iface:"omarchy-tun", pid:$pid, since:$since}' >"$RUN/state.json"
  # The presence of a resolv.conf backup is what tells `down` that the file mode
  # was used (the state shape is fixed and has no room for a DNS-mode field).
  printf 'nameserver 192.0.2.53\n' >"$RUN/resolv.conf.orig"

  out="$("$HELPER" down 2>/dev/null)"; rc=$?
  check "down exits 0" test "$rc" -eq 0
  check "down is one JSON document" jq -e -s 'length == 1 and .[0].ok == true' <<<"$out"
  flat="$(jq -r '.commands | join("\n")' <<<"$out")"
  check_contains "down signals the recorded pid" "$flat" "kill -TERM $FAKE_PID"
  check_contains "down restores the backed-up resolv.conf" "$flat" "$RUN/resolv.conf.orig"
  check_contains "down removes the state file" "$flat" "$RUN/state.json"
  check "the dry-run down did NOT actually kill the stand-in" test -d "/proc/$FAKE_PID"

  # The route deletions are conditional on the link existing: a tun's routes are
  # removed with the device. This test has no real interface, so the plan
  # intentionally contains no `ip route del`.
  out="$("$HELPER" down 2>/dev/null)"
  flat="$(jq -r '.commands | join("\n")' <<<"$out")"
  check "the with-state plan is non-empty" jq -e '(.commands | length) > 0' <<<"$out"
  check_not_contains "no route deletion is planned for a missing link" "$flat" "ip route del"
fi

# =============================================================================
echo
echo "case 7: status is a single read-only JSON document"
rm -f "$RUN/state.json"
out="$("$HELPER" status 2>/dev/null)"; rc=$?
check "status exits 0 with no state" test "$rc" -eq 0
check "status is exactly one JSON document" jq -e -s 'length == 1' <<<"$out"
check "status reports inactive with every field cleared" \
  jq -e '.ok == true and .active == false and .profileId == "" and .iface == "" and .pid == "" and .since == 0' <<<"$out"
check "status works with no last-error file" jq -e '.lastError == ""' <<<"$out"

if [[ $stand_in_ok == true ]]; then
  jq -n --arg pid "$FAKE_PID" --argjson since "$(date +%s)" \
    '{profileId:"tun-test", iface:"omarchy-tun", pid:$pid, since:$since}' >"$RUN/state.json"
  out="$("$HELPER" status 2>/dev/null)"
  check "status reports the live tunnel" \
    jq -e --arg pid "$FAKE_PID" '.ok == true and .active == true and .profileId == "tun-test" and .iface == "omarchy-tun" and .pid == $pid and (.since | type == "number")' <<<"$out"
else
  printf '  SKIP the live status read (the case 6 stand-in fixture failed)\n'
fi

# A multi-line last-error must be flattened and clamped, never become a second
# JSON document or break the panel's line.
{ printf 'the engine exited\n'; printf 'x%.0s' $(seq 1 1000); } >"$RUN/last-error"
out="$("$HELPER" status 2>/dev/null)"
check "status stays one document with a long last-error" jq -e -s 'length == 1' <<<"$out"
check "lastError is clamped" jq -e '(.lastError | length) <= 400' <<<"$out"
check_not_contains "lastError has no newline" "$(jq -r '.lastError' <<<"$out")" $'\n'
rm -f "$RUN/last-error"

# A dead pid must not be reported as active, and must not leave stale names.
jq -n '{profileId:"gone", iface:"omarchy-tun", pid:"999999", since:1}' >"$RUN/state.json"
out="$("$HELPER" status 2>/dev/null)"
check "a dead pid reads as inactive" \
  jq -e '.active == false and .profileId == "" and .iface == "" and .pid == ""' <<<"$out"
check "status did not create a config or kill anything" test ! -e "$RUN/config.json"
rm -f "$RUN/state.json"

# =============================================================================
echo
echo "case 8: tun-up <unknown-id> is refused before any helper work"
# The launcher derives the helper from OMARCHY_V2RAY_TUN_HELPER (or the installed
# default). Point it at a recording helper for this case: it must never be
# reached, because the id check comes first.
cat >"$WORK/recording-helper" <<SH
#!/usr/bin/env bash
printf 'invoked %s\n' "\$*" >>"$WORK/helper-invoked"
SH
chmod +x "$WORK/recording-helper"
rm -f "$WORK/helper-invoked" "$WORK/pkexec.args"

out="$(OMARCHY_V2RAY_TUN_HELPER="$WORK/recording-helper" "$BACKEND" tun-up definitely-not-a-profile 2>/dev/null)"; rc=$?
check "tun-up with an unknown id exits 1" test "$rc" -eq 1
check "tun-up with an unknown id is ok:false" jq -e '.ok == false' <<<"$out"
check "the error names the unknown profile" jq -e '.error | contains("unknown profile")' <<<"$out"
check "the helper was never invoked" test ! -e "$WORK/helper-invoked"
check "pkexec was never invoked" pkexec_quiet

# =============================================================================
echo
echo "case 9: the launcher refuses an unsafe helper path before prompting"
# The helper path is a test seam, but the ownership check applies to whatever it
# names — pointing it at a user-owned file can only produce a refusal, never a
# password prompt. All three refusals must leave the pkexec double untouched.
user_helper="$WORK/user-owned-helper"
printf '#!/usr/bin/env bash\nexit 0\n' >"$user_helper"
chmod 755 "$user_helper"
ln -s /usr/bin/true "$WORK/linked-helper"
rm -f "$WORK/pkexec.args"

if [[ $HAVE_XRAY == true ]]; then
  # 9a. Not installed at all.
  rm -f "$WORK/pkexec.args"
  out="$(OMARCHY_V2RAY_TUN_HELPER="$WORK/not-installed" "$BACKEND" tun-up "$ID" 2>/dev/null)"; rc=$?
  check "a missing helper exits 1" test "$rc" -eq 1
  check "a missing helper is needsHelper" jq -e '.ok == false and .needsHelper == true' <<<"$out"
  check "a missing helper names install-tun" jq -e '.error | contains("install-tun")' <<<"$out"
  check "a missing helper never reaches pkexec" pkexec_quiet

  # 9b. A user-owned file (exactly what the plugin tree would provide).
  rm -f "$WORK/pkexec.args"
  out="$(OMARCHY_V2RAY_TUN_HELPER="$user_helper" "$BACKEND" tun-up "$ID" 2>/dev/null)"; rc=$?
  check "a user-owned helper exits 1" test "$rc" -eq 1
  check "a user-owned helper is needsHelper" jq -e '.ok == false and .needsHelper == true' <<<"$out"
  check "a user-owned helper is refused for its owner" \
    jq -e '.error | contains("not owned by root")' <<<"$out"
  check "a user-owned helper never reaches pkexec" pkexec_quiet

  # 9c. A symlink, even to a root-owned file, is refused.
  rm -f "$WORK/pkexec.args"
  out="$(OMARCHY_V2RAY_TUN_HELPER="$WORK/linked-helper" "$BACKEND" tun-up "$ID" 2>/dev/null)"; rc=$?
  check "a symlinked helper exits 1" test "$rc" -eq 1
  check "a symlinked helper is needsHelper" jq -e '.ok == false and .needsHelper == true' <<<"$out"
  check "a symlinked helper is refused as a symlink" jq -e '.error | contains("symlink")' <<<"$out"
  check "a symlinked helper never reaches pkexec" pkexec_quiet

  # 9d. tun-down uses the same gate.
  rm -f "$WORK/pkexec.args"
  out="$(OMARCHY_V2RAY_TUN_HELPER="$user_helper" "$BACKEND" tun-down 2>/dev/null)"; rc=$?
  check "tun-down refuses an unsafe helper" jq -e '.ok == false and .needsHelper == true' <<<"$out"
  check "tun-down never reaches pkexec" pkexec_quiet
else
  printf '  SKIP the launcher cases (no allowlisted xray would pass the engine gate first)\n'
fi

# 9e. The positive launch can only be exercised with a ROOT-OWNED helper, which
# a non-root developer cannot create. The refusals above are the security
# property; this one is a documented skip on an ordinary machine.
if [[ $EUID -eq 0 && $HAVE_XRAY == true ]]; then
  root_helper="$WORK/root-helper"
  cp "$HELPER" "$root_helper"
  chown 0:0 "$root_helper"
  chmod 755 "$root_helper"
  rm -f "$WORK/pkexec.args"

  # A proxy engine the launch has to hand the ports over from. It must be a real,
  # live process the launcher is allowed to signal, so it is a private sleep and
  # not this suite's own pid (which read_pid would happily SIGTERM).
  mkdir -p "$CONFIG_HOME/state"
  sleep 60 & PROXY_PID=$!
  echo "$PROXY_PID" >"$CONFIG_HOME/state/engine.pid"
  echo "$ID" >"$CONFIG_HOME/state/active.id"

  out="$(OMARCHY_V2RAY_TUN_HELPER="$root_helper" "$BACKEND" tun-up "$ID" 2>/dev/null)"; rc=$?
  check "a root-owned helper is launched" \
    jq -e '.ok == true and .launched == true and .needsAuth == true' <<<"$out"
  for _ in $(seq 1 40); do
    [[ -f "$WORK/pkexec.args" ]] && break
    sleep 0.05
  done
  check_contains "pkexec receives the checked helper and the id" \
    "$(cat "$WORK/pkexec.args" 2>/dev/null)" "$root_helper up $ID"
  # The port-collision fix, observed rather than read: the privileged config
  # keeps the profile's SOCKS/HTTP inbounds, so the user-side engine must be gone
  # before the helper starts one that would fight it for 10808.
  check "tun-up stopped the proxy engine it is replacing" \
    test ! -e "$CONFIG_HOME/state/engine.pid"
  check "and forgot the profile the proxy engine was running" \
    test ! -e "$CONFIG_HOME/state/active.id"
  kill "$PROXY_PID" 2>/dev/null || true
else
  printf '  SKIP the positive launch (needs a root-owned helper; run the suite as root)\n'
fi

# =============================================================================
echo
echo "case 10: a user-owned helper copy refuses on its own, without dry-run"
# This is the self-check, not the launcher: a copy of the real helper in a temp
# dir, invoked with the privileged path enabled as a normal user. It must exit 1
# naming install-tun BEFORE resolving an identity or touching the run directory.
helper_copy="$WORK/helper-copy"
cp "$HELPER" "$helper_copy"
chmod 755 "$helper_copy"
untouched_run="$WORK/untouched-run"
out="$(env -u OMARCHY_V2RAY_TUN_DRY_RUN OMARCHY_V2RAY_TUN_RUN_DIR="$untouched_run" "$helper_copy" up "$ID" 2>/dev/null)"; rc=$?
check "a user-owned helper copy exits 1" test "$rc" -eq 1
check "the copy's refusal is ok:false" jq -e '.ok == false' <<<"$out"
check "the copy's refusal names install-tun" jq -e '.error | contains("omarchy-v2ray install-tun")' <<<"$out"
check "the copy touched no run directory" test ! -e "$untouched_run"

# =============================================================================
echo
echo "case 11: install-tun takes its destination from the constant, never the environment"
# Two DIFFERENT authorities share one name in this script, and this case is the
# line between them:
#
#   OMARCHY_V2RAY_TUN_HELPER        a LAUNCH seam — lets the launcher (and these
#                                   tests) point at an already-installed helper.
#   TUN_HELPER_INSTALL_PATH         the INSTALL destination, a constant.
#
# If install-tun read the environment, then
# OMARCHY_V2RAY_TUN_HELPER=/etc/passwd install-tun would ask root to `install`
# the helper over /etc/passwd. So the destination is asserted on the recorded
# launcher argv — the exact command root will see — rather than by trusting the
# JSON field the same code produced.
#
# The terminal launcher is the recording double from above, so no window opens
# and the assertion reads a file, never a timing window.
INSTALL_DEST="/usr/local/lib/omarchy-v2ray/omarchy-v2ray-tun"
# Deliberately under a directory that does not exist. A destination inside an
# existing, user-owned directory would be refused by install-tun's separate
# "the install directory must be root-owned" check, and a regression in the
# destination line would then be caught by THAT check instead of by this case —
# which is the difference between a test that fails and one that quietly skips.
EVIL_DEST="$WORK/no-such-install-dir/attacker-dest"
# What tun_helper_source_path resolves the repo copy to (it uses `pwd -P`, so a
# path spelled with ".." would not compare equal).
HELPER_SRC="$(cd "$HERE/../bin" && pwd -P)/omarchy-v2ray-tun"

rm -f "$WORK/launcher.args"
out="$(OMARCHY_V2RAY_TUN_HELPER="$EVIL_DEST" "$BACKEND" install-tun 2>/dev/null)"
if jq -e '.ok == true' <<<"$out" >/dev/null 2>&1; then
  check "install-tun reports the constant destination, not the override" \
    jq -e --arg dest "$INSTALL_DEST" '.helper == $dest' <<<"$out"
  # The launcher is detached (setsid), so the recording lands a moment after the
  # backend exits. Waiting for a file that MUST appear is not a timing assertion:
  # it cannot turn a broken command into a pass, and once it exists every check
  # below is made against exact bytes.
  for _ in $(seq 1 40); do
    [[ -s "$WORK/launcher.args" ]] && break
    sleep 0.05
  done
  check "the install was handed to the terminal launcher" test -s "$WORK/launcher.args"
  check_contains "the recorded command names the installed path" \
    "$(cat "$WORK/launcher.args")" "$INSTALL_DEST"
  check_not_contains "the recorded command never names the environment override" \
    "$(cat "$WORK/launcher.args")" "$EVIL_DEST"
  check_contains "the install still goes through pkexec" \
    "$(cat "$WORK/launcher.args")" "pkexec /bin/sh -c"
  check_contains "and copies the repo helper as its source" \
    "$(cat "$WORK/launcher.args")" "$HELPER_SRC"
  check_not_contains "the source is not the environment-named file either" \
    "$(cat "$WORK/launcher.args")" "$EVIL_DEST"
else
  # A refusal is only excusable when it is a fact about THIS machine — a
  # destination left behind by a real install that this user may not overwrite.
  # Anything else (notably "refusing to install to an unexpected path") means the
  # destination stopped being the constant, which is exactly what this case
  # exists to catch, so it must FAIL rather than quietly skip.
  refusal="$(jq -r '.error // ""' <<<"$out")"
  if [[ $refusal == *"not owned by root"* || $refusal == *"group- or world-writable"* \
        || $refusal == *"symlink"* || $refusal == *"non-directory"* \
        || $refusal == *"non-regular"* ]]; then
    printf '  SKIP install-tun (%s)\n' "$refusal"
  else
    printf '  FAIL install-tun refused for a reason that is not a local condition: %s\n' "${refusal:-no JSON}"
    failures=$((failures + 1))
  fi
fi

# =============================================================================
echo
if (( failures == 0 )); then
  echo "all tests passed"
else
  echo "$failures test(s) FAILED"
fi
exit $(( failures > 0 ))

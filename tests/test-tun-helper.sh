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
# The TUN_STATE seam is not optional: the backend's unprivileged stop reads a
# state file and may SIGNAL the pid it names. Without the seam every backend
# invocation below would read the machine's real /run state — a live tunnel on
# this machine would be killed by a test run.
export OMARCHY_V2RAY_TUN_DRY_RUN=1
export OMARCHY_V2RAY_TUN_RUN_DIR="$RUN"
export OMARCHY_V2RAY_TUN_STATE="$RUN/state.json"
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

# (No getent stub here: the helper pins PATH to the system directories on
# purpose, so a stub on PATH could never reach it. The hostname fixture below
# uses `localhost`, which the real getent answers offline and deterministically
# — the unit driver in case 1b covers the resolution mechanics with its own
# getent function.)

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
        "users": [ { "id": "$UUID", "encryption": "none" } ] } ] } },
    { "tag": "direct", "protocol": "freedom" }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      { "type": "field", "outboundTag": "direct",
        "ip": [ "127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16",
                "169.254.0.0/16", "::1/128", "fc00::/7", "fe80::/10" ] }
    ]
  }
}
JSON
cat >"$PROFILES/$ID.meta.json" <<JSON
{ "id": "$ID", "name": "TUN Test", "type": "vless", "host": "203.0.113.10", "port": 443 }
JSON

# A second profile whose server is a HOSTNAME: the pin step (resolve once,
# rewrite the proxy outbound's address) only runs for a non-literal address, so
# the plan's pin mirror and the /32 that follows it need this fixture. The
# name is `localhost` on purpose: the helper pins its PATH, so a stub getent
# could never answer it, and the real getent resolves localhost offline and
# deterministically (127.0.0.1).
ID_HOST="tun-test-host"
cat >"$PROFILES/$ID_HOST.config.json" <<JSON
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    { "tag": "socks-in", "listen": "127.0.0.1", "port": 10808, "protocol": "socks",
      "settings": { "auth": "noauth", "udp": true } }
  ],
  "outbounds": [
    { "tag": "proxy", "protocol": "vless",
      "settings": { "vnext": [ { "address": "localhost", "port": 443,
        "users": [ { "id": "$UUID", "encryption": "none" } ] } ] } },
    { "tag": "direct", "protocol": "freedom" }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      { "type": "field", "outboundTag": "direct",
        "ip": [ "127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16",
                "169.254.0.0/16", "::1/128", "fc00::/7", "fe80::/10" ] }
    ]
  }
}
JSON
cat >"$PROFILES/$ID_HOST.meta.json" <<JSON
{ "id": "$ID_HOST", "name": "TUN Host Test", "type": "vless", "host": "localhost", "port": 443 }
JSON
chmod 600 "$PROFILES/$ID.config.json" "$PROFILES/$ID.meta.json" \
         "$PROFILES/$ID_HOST.config.json" "$PROFILES/$ID_HOST.meta.json"

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
  # The routes the HELPER installs (the engine's own tun keys are ignored by
  # xray on Linux, so the plan must show the ip commands that do the work).
  check_contains "the plan sets the tunnel's address" "$flat" "ip addr replace 10.66.0.1/16"
  check_contains "the plan installs the IPv4 upper-half route" "$flat" "ip route replace 0.0.0.0/1 dev"
  check_contains "the plan installs the IPv4 lower-half route" "$flat" "ip route replace 128.0.0.0/1 dev"
  check_contains "the plan carries the IPv4 upper-half route" "$flat" "0.0.0.0/1"
  check_contains "the plan carries the IPv4 lower-half route" "$flat" "128.0.0.0/1"
  check_contains "the plan carries the IPv6 upper-half route" "$flat" "::/1"
  check_contains "the plan carries the IPv6 lower-half route" "$flat" "8000::/1"
  # The server host route depends on a real default route existing, so it is
  # asserted only when this environment can produce one.
  if ip route show default >/dev/null 2>&1; then
    check_contains "the plan exempts the server's own address from the tunnel" \
      "$flat" "203.0.113.10/32"
  fi

  # The direct (freedom) outbound is BOUND to the uplink at the socket level,
  # not routed there: the plan must show the jq rewrite (sockopt.interface)
  # and no direct-range route lines at all. The fixture profile's outbound is
  # literal, so there is no pin step to show — the same no-op the real run
  # performs.
  #
  # The plan must show the ACTUAL bind program, not merely some sockopt
  # mention: the constant is one definition with two call sites (bind and
  # plan), so the planned program literally contains `.streamSettings.sockopt`
  # — the top-level-`.sockopt` shape that once drifted would fail both checks.
  check_contains "the plan binds the direct outbound to the uplink" \
    "$flat" ".streamSettings.sockopt // {}"
  check_not_contains "the planned program is not the drift-prone top-level shape" \
    "$flat" "{sockopt: ((.sockopt"
  check_contains "the bind names the detected uplink device" \
    "$flat" "jq --arg iface "
  check_not_contains "no direct-range route is planned" "$flat" \
    "ip -4 route replace 10.0.0.0/8"
  check_not_contains "no direct-range skip note is planned" "$flat" \
    "skipped: loopback or link-local"
  check_not_contains "no direct-range deletion is planned" "$flat" \
    "route del 127.0.0.0/8"
  check_not_contains "a literal profile shows no pin step" "$flat" "--arg ip "

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
    check_contains "the plan makes this link resolved's default route" "$flat" "resolvectl default-route"
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
echo "case 1c: a hostname profile's plan shows the pin step, and the /32 follows it"
# The pin exists so that xray's dial target IS the address the /32 exemption
# names (see pin_server_address). The plan must show that rewrite happening
# BEFORE the engine line, with the same temp + chown + chmod + mv discipline as
# the build, and the exemption must use the pinned literal.
if [[ $HAVE_XRAY == true ]]; then
  out="$("$HELPER" up "$ID_HOST" 2>/dev/null)"; rc=$?
  check "hostname up exits 0" test "$rc" -eq 0
  flat_host="$(jq -r '.commands | join("\n")' <<<"$out")"
  check_contains "the plan pins the resolved server address" "$flat_host" \
    "--arg ip 127.0.0.1"
  check_contains "the pinned config is handed back to the invoking user" "$flat_host" \
    "chown $(id -u):$(id -g) -- $RUN/.config.json.tmp"
  check_contains "the pin renames its temp into place" "$flat_host" \
    "mv -f -- $RUN/.config.json.tmp $RUN/config.json"
  check_not_contains "the pin step never exposes the profile's credential" \
    "$flat_host" "$UUID"
  if ip route show default >/dev/null 2>&1; then
    check_contains "the plan exempts the pinned address, not the name's other records" \
      "$flat_host" "ip -4 route replace 127.0.0.1/32"
  fi
  check_not_contains "no exemption is planned for the un-pinned name" "$flat_host" \
    "localhost/32"
fi

# The engine must NOT inherit the transition lock's fd: a flock lock belongs to
# the open file description, so the engine's inherited copy of fd 9 kept the
# mutex held for the engine's whole life, and `down` hung for 20s and then
# refused with "another TUN operation is still in progress" while TUN was on.
#
# This is a static check on the start_engine body, not a dry-run assertion,
# and that is deliberate: the plan prints ARGV ONLY (a redirection is applied
# by the shell before exec, never argv — see plan_up's own comment), so a
# printed `9>&-` would not merely be unenforced, it would be a lie — pasted
# back it would reach xray as a literal argument instead of closing fd 9.
# "The lock is released while the engine runs" cannot be observed without a
# privileged engine, so the honest, always-runnable check is the one line of
# the source that carries the fix.
sed -n '/^start_engine() {/,/^}/p' "$HELPER" >"$WORK/start_engine.body"
check "the engine is launched with the transition-lock fd closed (9>&-)" \
  grep -q '9>&-' "$WORK/start_engine.body"
check "the lock-fd close sits on the engine's redirect line, not elsewhere" \
  grep -q '</dev/null 9>&- &' "$WORK/start_engine.body"

# The same static-body discipline one layer earlier: bind_direct_outbound must
# invoke jq with the SHARED $BIND_JQ constant. If the program were re-inlined
# at the run-side call site while the constant stayed put, plan_up would keep
# mirroring the constant and the plan would assert a program the run does not
# execute — the exact opposite of what the plan-for-that-must-match guarantees.
# The dry-run assertions cover the plan side; this greps the EXTRACTED
# function body (same sed range convention as start_engine above), so it is
# always runnable and anchored where the fix lives.
sed -n '/^bind_direct_outbound() {/,/^}/p' "$HELPER" >"$WORK/bind.body"
check "bind_direct_outbound still invokes jq with the shared BIND_JQ constant" \
  grep -q 'jq --arg iface "$UPLINK_DEV" "$BIND_JQ"' "$WORK/bind.body"

# =============================================================================
echo
echo "case 1b: routing internals without root (socket binding, pinning, failure reasons)"
# Several things remain invisible to a dry run and need unit-style driving of
# the extracted routing functions with stubbed `ip`/`getent` (bash functions
# shadow PATH binaries):
#   * an IPv6 default's OWN device — this machine has no v6 default, so the
#     plan can never show a /128 and only the function itself can prove the
#     selection;
#   * the reason a failed routing step leaves behind — the readiness loop's
#     message is deliberately terse because that is what the panel can show,
#     so the kernel's own explanation must land in helper.log;
#   * the routes FILE the server /32s are recorded in and how teardown reads
#     it back (the plan shows commands, never the teardown state's contents);
#   * pin_server_address and bind_direct_outbound — both rewrite the built
#     config between the jq transform and start_engine, so nothing but a
#     direct call can prove them.
{ sed -n '/^route_field_after()/,/^start_engine()/p' "$HELPER" | head -n -1
  sed -n '/^pin_server_address()/,/^route_field_after()/p' "$HELPER" | head -n -1
  sed -n '/^helper_log()/,/^}/p' "$HELPER"
  # The bind program is one constant in the helper; the driver must run the
  # SAME definition (scenario H calls bind_direct_outbound), not a hand copy.
  grep '^BIND_JQ=' "$HELPER"; } >"$WORK/routing-funcs.sh"
cat >"$WORK/routing-unit.sh" <<'SH'
set -uo pipefail
source "$1"

RUN_DIR="$2"
HELPER_LOG="$RUN_DIR/helper.log"
IFACE="omarchy-tun"
CONFIG_FILE="$RUN_DIR/config.json"
ROUTES_FILE="$RUN_DIR/routes"
UPLINK_DEV="" UPLINK_GW="" UPLINK_DEV6="" UPLINK_GW6=""
unset OMARCHY_V2RAY_TUN_DRY_RUN   # the suite exports 1; helper_log must log
INVOKER_UID="$(id -u)" INVOKER_GID="$(id -g)" PROFILE_ID="tun-test"
IPV6_STUB=no
IP_LOG="$RUN_DIR/ip.args"
: >"$IP_LOG"

# Only the shapes these scenarios call. The case key is `family + object`:
# `ip -4 route show default` and `ip -4 route get X` both start `-4 route`,
# and route_dev_for must NOT answer from the default-route stub.
ip() {
  case "$1 $2 $3" in
    "-4 route get") return 2 ;;
    "-4 route show") printf '%s\n' 'default via 10.0.0.1 dev uplink0 metric 100' ;;
    "-6 route get") return 2 ;;
    "-6 route show")
      if [[ $IPV6_STUB == yes ]]; then
        printf '%s\n' 'default via fe80::1 dev wlp2s0 metric 600' \
                       'default via fe80::2 dev enp0s31f6 metric 100'
      fi ;;
    "addr replace "*)
      printf 'RTNETLINK answers: Operation not permitted\n' >&2; return 2 ;;
    *)
      # Every mutation is recorded, so the assertions can check the exact argv
      # (a replace with via+dev, a delete of a recorded prefix).
      printf '%s\n' "$*" >>"$IP_LOG"
      return 0 ;;
  esac
}

# The resolver answers only the pin scenarios' names, and only over v4 — the
# v6 fallback (AAAA when no A exists) has its own scenario below.
getent() {
  if [[ ${1:-} == ahostsv4 && ${2:-} == srv.example.test ]]; then
    printf '%s\n' '203.0.113.99     0  srv.example.test'
    return 0
  fi
  return 2
}

# A: the IPv6 default's own device is captured and the lowest metric wins,
#    whatever stale values the caller carried in.
IPV6_STUB=yes
IPV6_ENABLED=stale UPLINK_DEV6=stale-iface UPLINK_GW6=2001:db8::dead
detect_uplink6
printf 'A dev6=%s gw6=%s ipv6=%s\n' "$UPLINK_DEV6" "$UPLINK_GW6" "$IPV6_ENABLED"

# B: with no v6 default at all, the reset must clear everything — a later call
#    on the same process must not keep v6 enabled on stale state.
IPV6_STUB=no
IPV6_ENABLED=true UPLINK_DEV6=wlp2s0 UPLINK_GW6=fe80::1
detect_uplink6
printf 'B dev6=%s gw6=%s ipv6=%s\n' "$UPLINK_DEV6" "$UPLINK_GW6" "$IPV6_ENABLED"

# C: a failing mutation fails the whole apply AND names the kernel's reason.
#    add_server_routes reads the config itself, so the server address lives in
#    a config file, not in a manual server_ip_list call. apply_routes no
#    longer detects the uplink itself (cmd_up does, before the config is
#    finalised), so the driver performs the same one detect here.
jq -n '{outbounds:[{tag:"proxy",settings:{vnext:[{address:"203.0.113.10"}]}}]}' \
  >"$CONFIG_FILE"
detect_uplink
if apply_routes; then
  printf 'C apply_routes unexpectedly succeeded\n'
else
  printf 'C apply_routes failed as intended\n'
fi
# The recorded route is the FULL prefix — teardown deletes exactly what it
# reads, not a re-derivation. (Scenario D truncates the file again, so this
# check must run on C's state, before D.)
printf 'C routes:\n'; cat "$ROUTES_FILE"

# D: a v6-literal server on a host with no v6 default is refused too — the
#    tunnel could never dial its own server. The v6 address replaces the v4
#    one in the config: add_server_routes reads only from there.
jq -n '{outbounds:[{tag:"proxy",settings:{vnext:[{address:"2001:db8::1234"}]}}]}' \
  >"$CONFIG_FILE"
if apply_routes; then
  printf 'D apply_routes unexpectedly succeeded\n'
else
  printf 'D apply_routes failed as intended\n'
fi

# H: bind_direct_outbound. Only the freedom outbound gains the socket binding;
#    a non-freedom outbound is left untouched; a missing streamSettings and a
#    missing sockopt are both CREATED; mode and owner survive the rewrite; an
#    empty UPLINK_DEV rewrites nothing.
printf '%s' '{"inbounds":[],"outbounds":[{"tag":"proxy","protocol":"vless","settings":{}},{"tag":"direct","protocol":"freedom"}]}' \
  >"$CONFIG_FILE"
UPLINK_DEV=uplink0
bind_direct_outbound && printf 'H bind ok\n' || printf 'H bind failed\n'
printf 'H bound=%s untouched=%s mode=%s owner=%s\n' \
  "$(jq -r '.outbounds[] | select(.protocol == "freedom") | .streamSettings.sockopt.interface' "$CONFIG_FILE")" \
  "$(jq -r '.outbounds[] | select(.protocol == "vless") | has("streamSettings")' "$CONFIG_FILE")" \
  "$(stat -c '%a' "$CONFIG_FILE")" \
  "$(stat -c '%u:%g' "$CONFIG_FILE")"

# An existing sockopt keeps its other keys and only gains the interface.
printf '%s' '{"inbounds":[],"outbounds":[{"tag":"direct","protocol":"freedom","streamSettings":{"sockopt":{"mark":42}}}]}' \
  >"$CONFIG_FILE"
bind_direct_outbound && printf 'H2 bind ok\n' || printf 'H2 bind failed\n'
printf 'H2 sockopt=%s\n' \
  "$(jq -c '.outbounds[0].streamSettings.sockopt' "$CONFIG_FILE")"

# H3: without an uplink there is nothing to bind to — the rewrite must not
#     happen at all.
UPLINK_DEV=""
cp "$CONFIG_FILE" "$RUN_DIR/h3-before.json"
bind_direct_outbound; h_rc=$?
if (( h_rc != 0 )); then
  printf 'H3 bind without an uplink failed as intended\n'
else
  printf 'H3 bind without an uplink unexpectedly succeeded\n'
fi
if cmp -s "$RUN_DIR/h3-before.json" "$CONFIG_FILE"; then
  printf 'H3 config untouched\n'
else
  printf 'H3 config CHANGED\n'
fi
UPLINK_DEV=uplink0

# F: teardown deletes exactly the recorded prefixes — and the file only ever
#    holds the shapes the helper writes: `4 <ip>/32`, `6 <ip>/128`, plus one
#    legacy BARE address (still accepted for files an older build left) that
#    must delete as a /32. A direct range like 10.0.0.0/8 is deliberately NOT
#    here: nothing writes ranges since the direct outbound moved to socket
#    binding.
printf '4 203.0.113.10/32\n6 2001:db8::9/128\n4 198.51.100.7\n' >"$ROUTES_FILE"
remove_server_routes
# The del argv land in the same log the replaces did; printing it here is what
# lets the suite assert the exact teardown commands.
printf 'F ip.args:\n'; cat "$IP_LOG"
printf 'F routes-file-gone=%s\n' "$([[ -e $ROUTES_FILE ]] && echo no || echo yes)"

# G: pin_server_address. A literal address is left byte-identical; a hostname
#    is resolved ONCE and rewritten — only the proxy outbound, SNI untouched —
#    into a 0600 config owned by the invoking user; an unresolvable name fails
#    with a reason and touches nothing. Every fixture carries `inbounds`, so
#    the post-rewrite validity check (the same one build_tun_config applies)
#    passes for the rewritten file.
printf '%s' '{"inbounds":[],"outbounds":[{"tag":"proxy","settings":{"vnext":[{"address":"203.0.113.10"}]}}]}' \
  >"$CONFIG_FILE"
cp "$CONFIG_FILE" "$RUN_DIR/pin-before.json"
pin_server_address && printf 'G1 pin literal ok\n' || printf 'G1 pin literal failed\n'
if cmp -s "$RUN_DIR/pin-before.json" "$CONFIG_FILE"; then
  printf 'G1 literal untouched\n'
else
  printf 'G1 literal CHANGED\n'
fi

printf '%s' '{"inbounds":[],"outbounds":[{"tag":"proxy","protocol":"vless","streamSettings":{"reality":{"serverName":"sn.example.test"}},"settings":{"vnext":[{"address":"srv.example.test","port":443}]}}]}' \
  >"$CONFIG_FILE"
pin_server_address && printf 'G2 pin hostname ok\n' || printf 'G2 pin hostname failed\n'
printf 'G2 address=%s sni=%s mode=%s owner=%s\n' \
  "$(jq -r '.outbounds[0].settings.vnext[0].address' "$CONFIG_FILE")" \
  "$(jq -r '.outbounds[0].streamSettings.reality.serverName' "$CONFIG_FILE")" \
  "$(stat -c '%a' "$CONFIG_FILE")" \
  "$(stat -c '%u:%g' "$CONFIG_FILE")"

printf '%s' '{"inbounds":[],"outbounds":[{"tag":"proxy","settings":{"vnext":[{"address":"gone.example.test"}]}}]}' \
  >"$CONFIG_FILE"
cp "$CONFIG_FILE" "$RUN_DIR/pin-gone-before.json"
if pin_server_address; then
  printf 'G3 pin unresolvable unexpectedly succeeded\n'
else
  printf 'G3 pin unresolvable failed as intended\n'
fi
if cmp -s "$RUN_DIR/pin-gone-before.json" "$CONFIG_FILE"; then
  printf 'G3 config untouched\n'
else
  printf 'G3 config CHANGED\n'
fi
SH
mkdir -p "$WORK/route-run"
drv="$(bash "$WORK/routing-unit.sh" "$WORK/routing-funcs.sh" "$WORK/route-run" 2>&1)"
check_not_contains "the unit driver produced no unexpected success" "$drv" \
  "unexpectedly succeeded"
check_not_contains "the unit driver is free of shell errors" "$drv" "syntax error"
check_not_contains "the unit driver touched no unset variable" "$drv" \
  "unbound variable"
check_contains "the v6 uplink device is captured and the lowest metric wins" "$drv" \
  "A dev6=enp0s31f6 gw6=fe80::2 ipv6=true"
check_contains "a vanished v6 default resets the enable flag and the device" "$drv" \
  "B dev6= gw6= ipv6=false"
check_contains "a failing routing mutation fails apply_routes" "$drv" \
  "C apply_routes failed as intended"
check "the failed step's kernel reason is in helper.log" \
  grep -q 'ip addr replace failed: RTNETLINK answers: Operation not permitted' \
    "$WORK/route-run/helper.log"
check_contains "the v6-literal refusal fails apply_routes" "$drv" \
  "D apply_routes failed as intended"
check "a v6 server IP with no v6 uplink is refused with a reason" \
  grep -q 'no IPv6 default route; the server address 2001:db8::1234 could not be reached' \
    "$WORK/route-run/helper.log"

# C/F/H: the server /32 is recorded as a full prefix and torn down from the
# file; the direct outbound gains its socket binding, nothing else is touched;
# teardown deletes exactly what was recorded.
check_contains "the server /32 is recorded as a full prefix" "$drv" \
  "
4 203.0.113.10/32"
check_contains "the server's replace went through the detected uplink" "$drv" \
  "-4 route replace 203.0.113.10/32 via 10.0.0.1 dev uplink0"
check_contains "only the freedom outbound gains the socket binding" "$drv" \
  "H bound=uplink0 untouched=false"
check_contains "the bound config keeps its mode and owner" "$drv" \
  "mode=600 owner=$(id -u):$(id -g)"
check_contains "a sockopt that already exists keeps its other keys" "$drv" \
  'H2 sockopt={"mark":42,"interface":"uplink0"}'
check_contains "a bind without an uplink fails the start" "$drv" \
  "H3 bind without an uplink failed as intended"
check_contains "the failed bind rewrote nothing" "$drv" \
  "H3 config untouched"
check_not_contains "no direct-pinning leftovers in the driver" "$drv" \
  "unexpectedly succeeded"
check_contains "teardown deletes the recorded v4 /32 exactly" "$drv" \
  "-4 route del 203.0.113.10/32"
check_contains "teardown deletes the recorded v6 /128 exactly" "$drv" \
  "-6 route del 2001:db8::9/128"
check_contains "a bare address from an older build is torn down as a /32" "$drv" \
  "-4 route del 198.51.100.7/32"
check "the routes file is removed once teardown has read it" \
  grep -q 'F routes-file-gone=yes' <<<"$drv"

# G: the pin. The dial target and the /32 must be the same literal, resolved
# while the system's own resolvers still answer.
check_contains "pin_server_address leaves an IP literal untouched" "$drv" \
  "G1 literal untouched"
check_contains "a hostname is resolved once and rewritten, SNI and mode kept" "$drv" \
  "G2 address=203.0.113.99 sni=sn.example.test mode=600 owner=$(id -u):$(id -g)"
check_contains "an unresolvable server name fails the pin without touching the config" \
  "$drv" "G3 config untouched"
check_contains "the unresolvable name fails the start as intended" "$drv" \
  "G3 pin unresolvable failed as intended"
check "the pin refusal names the name it could not resolve" \
  grep -q 'pin: nothing usable resolved for gone.example.test' \
    "$WORK/route-run/helper.log"
check "the pin records the hostname and the address it chose" \
  grep -q 'server address srv.example.test -> 203.0.113.99' \
    "$WORK/route-run/helper.log"

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
  # The iface cannot exist ("abs" keeps it 15 chars — within the kernel's
  # IFNAMSIZ that read_state_iface accepts — and the name matches no device
  # on this or any host): the route deletions in plan_down are gated on
  # /sys/class/net/$iface, and the assertions below must not depend on
  # whether this particular host happens to have a live tunnel running.
  jq -n --arg pid "$FAKE_PID" --argjson since "$(date +%s)" \
    '{profileId:"tun-test", iface:"omarchy-tun-abs", pid:$pid, since:$since}' >"$RUN/state.json"
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

  # The route deletions are conditional on the link existing: a tun's routes
  # are removed with the device. The fixture's iface name matches no real
  # device, so the plan intentionally contains no bare `ip route del`.
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
  # Any other refusal means install-tun stopped doing its job, which is what
  # this case exists to catch, so it must FAIL rather than quietly skip.
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
echo "case 12: the launcher really hands the helper to pkexec"
# THE BUG THIS CATCHES: launch_tun_helper expanded $helper without ever setting
# it, relying on require_tun_helper's `local`. Bash locals are dynamically
# scoped, so it was gone; under `set -u` the expansion failed inside the FORKED
# child of `setsid pkexec … &`, and the parent — which never waits for that
# child — still printed {"ok":true,"launched":true}. Every TUN click stopped the
# proxy engine (cmd_tun_up does that first), launched nothing, and left the
# panel gating connects over a hand-off that could never produce evidence.
#
# No root is needed to see it: the pre-flight only wants a root-owned,
# non-symlink executable, and a recording pkexec on PATH proves whether anything
# was actually launched. /usr/bin/true qualifies on a normal system, and the
# recorder never executes it, so nothing privileged happens either way.
HELPER_BIN=/usr/bin/true
helper_ok=true
[[ -f $HELPER_BIN && -x $HELPER_BIN && ! -L $HELPER_BIN ]] || helper_ok=false
[[ "$(stat -c '%u' "$HELPER_BIN" 2>/dev/null)" == 0 ]] || helper_ok=false
helper_mode="$(stat -c '%a' "$HELPER_BIN" 2>/dev/null)"
[[ -n $helper_mode ]] && (( (8#$helper_mode & 8#022) == 0 )) || helper_ok=false

if [[ $helper_ok != true ]]; then
  # Deliberately not a SKIP: this case must run as an ordinary user, and on a
  # machine where $HELPER_BIN is not root-owned 0755 the premise is broken.
  printf '  FAIL %s is not a root-owned 0755 non-symlink, so this case cannot run as designed\n' "$HELPER_BIN"
  failures=$((failures + 1))
else
  # No TUN state, or tun-up refuses with "already active" before launching.
  rm -f "$RUN/state.json" "$WORK/pkexec.args"

  out="$(OMARCHY_V2RAY_TUN_HELPER="$HELPER_BIN" "$BACKEND" tun-up "$ID" 2>"$WORK/launch.err")"
  # The launch is detached, so wait for the recording to appear; the assertion is
  # on its bytes, never on when it landed.
  for _ in $(seq 1 40); do
    [[ -s "$WORK/pkexec.args" ]] && break
    sleep 0.05
  done
  check "tun-up reports launched" jq -e '.ok == true and .launched == true' <<<"$out"
  check "tun-up printed no shell error" test ! -s "$WORK/launch.err"
  check "tun-up really ran the recording pkexec" test -s "$WORK/pkexec.args"
  check "pkexec received exactly the helper, 'up' and the id" \
    test "$(cat "$WORK/pkexec.args")" = "$HELPER_BIN up $ID"

  rm -f "$WORK/pkexec.args"
  out="$(OMARCHY_V2RAY_TUN_HELPER="$HELPER_BIN" "$BACKEND" tun-down 2>"$WORK/launch.err")"
  for _ in $(seq 1 40); do
    [[ -s "$WORK/pkexec.args" ]] && break
    sleep 0.05
  done
  check "tun-down reports launched" jq -e '.ok == true and .launched == true' <<<"$out"
  check "tun-down printed no shell error" test ! -s "$WORK/launch.err"
  check "tun-down really ran the recording pkexec" test -s "$WORK/pkexec.args"
  check "pkexec received exactly the helper and 'down'" \
    test "$(cat "$WORK/pkexec.args")" = "$HELPER_BIN down"
fi

# =============================================================================
echo
if (( failures == 0 )); then
  echo "all tests passed"
else
  echo "$failures test(s) FAILED"
fi
exit $(( failures > 0 ))

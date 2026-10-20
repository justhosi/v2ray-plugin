#!/usr/bin/env bash
# =============================================================================
# State-machine tests for the TUN side of Service.qml.
#
# WHY THIS EXISTS
# ---------------
# The TUN switch cannot be tested by waiting for a real polkit prompt: the answer
# may never come, and no test may ask for a password. What IS testable is the
# state machine around it, and that is where both review blockers lived:
#
#   B1  the connect paths were not gated on `tunArming`. `busy` tracks the
#       LAUNCHER, which exits in milliseconds, so between the click and the
#       authorisation the panel looked idle — a click on the main switch (or a
#       row, or `t`) started a proxy engine on the ports the TUN engine was
#       about to claim, and the helper was the one that died.
#
#   B2  a stale `tunLastError` cleared arming immediately. The helper deletes
#       `last-error` only after a SUCCESSFUL start, so on a machine with one past
#       failure the file stays non-empty for the whole retry; "non-empty means
#       this attempt failed" ended the arming before authentication and let a
#       second click ask for a second password.
#
# The test drives the REAL Service.qml under the real QML engine and calls
# `applyStatus()` with crafted replies, because that function IS the machine:
# driving it directly removes subprocess timing from every assertion. A fake
# backend sits at bin/omarchy-v2ray only so `runAction()` has something to
# launch — and so `start` can be made slow, which is how the "arm only when the
# launcher really started" case is exercised.
#
# HOW TO RUN
# ----------
#     ./tests/test-service-tun.sh
#
# Needs quickshell (`qs`) and a session it can open; without either it prints
# SKIP and exits 0, the same contract the other quickshell test follows. It
# touches nothing outside its own temp directory and never starts an engine.
# tests/test-backend.sh runs it alongside tests/test-service-import.sh.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
SERVICE="${OMARCHY_V2RAY_SERVICE:-$REPO/Service.qml}"

WORK="$(mktemp -d)"
failures=0

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

if ! command -v qs >/dev/null 2>&1; then
  printf '  SKIP quickshell (qs) is not installed, so the service cannot be driven\n'
  exit 0
fi

# Service.qml imports qs.Commons for the type namespace. omarchy ships it;
# outside an omarchy install a stub with the same module name is enough (nothing
# under test calls into it).
COMMONS_DIR="${OMARCHY_V2RAY_COMMONS:-/usr/share/omarchy/shell/Commons}"
if [[ ! -f $COMMONS_DIR/qmldir ]]; then
  COMMONS_DIR="$WORK/Commons"
  mkdir -p "$COMMONS_DIR"
  cat >"$COMMONS_DIR/qmldir" <<'STUB'
module qs.Commons
singleton Util 1.0 Util.qml
STUB
  cat >"$COMMONS_DIR/Util.qml" <<'STUB'
pragma Singleton
import QtQuick

// Placeholder for qs.Commons.Util so `import qs.Commons` resolves outside an
// omarchy install. Never called here.
QtObject {
  function shellQuote(value) { return "'" + String(value) + "'" }
}
STUB
fi

# ------------------------------------------------------------------ harness --
# build_harness: a throwaway quickshell config holding the real Service.qml, the
# fake backend, and the driver below.
build_harness() {
  local dir="$1"
  rm -rf "$dir"
  mkdir -p "$dir/bin"

  cp "$SERVICE" "$dir/Service.qml"
  ln -s "$REPO/Model.js" "$dir/Model.js"
  ln -s "$COMMONS_DIR" "$dir/Commons"

  # The backend double. `status` DELIBERATELY never answers during the run
  # (sleeps longer than the whole test): every status reply below is applied by
  # hand, and a real one arriving mid-scenario would confirm or refute state the
  # scenario is still pretending is in flight — most visibly a stop, where a
  # fixed "off" reply looks exactly like a successful teardown. `start` sleeps
  # 0.3s so it is still in flight when tunUp() is called in the same step (which
  # is synchronous), and gone by the following ticks.
  #
  # Unquoted heredoc: "$dir" is baked in now, and every "$" the double itself
  # expands is escaped.
  cat >"$dir/bin/omarchy-v2ray" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  status)
    sleep 30
    cat "$dir/status.json" 2>/dev/null \\
      || printf '%s\n' '{"ok":true,"installed":true,"engine":"xray","running":false,"listening":false}'
    ;;
  list)     printf '%s\n' '[]' ;;
  start)    sleep 0.3; printf '%s\n' '{"ok":true,"id":"p1"}' ;;
  tun-up)   printf '%s\n' '{"ok":true,"launched":true,"needsAuth":true}' ;;
  tun-down) printf '%s\n' '{"ok":true,"launched":true}' ;;
  *)        printf '%s\n' '{"ok":true}' ;;
esac
SH
  chmod +x "$dir/bin/omarchy-v2ray"

  printf '%s\n' '{"ok":true,"installed":true,"engine":"xray","running":false,"listening":false}' \
    >"$dir/status.json"

  cat >"$dir/shell.qml" <<'QML'
import QtQuick
import Quickshell

Item {
  id: root

  Service { id: service }

  property int step: 0
  property int failures: 0

  // The stale failure B2 is about: one that is already on disk when the next
  // attempt is armed. It must not end that attempt's arming.
  readonly property string staleError: "the engine exited while the tunnel was starting"

  function check(name, cond) {
    if (cond) {
      console.log("TAP ok " + name)
    } else {
      console.log("TAP FAIL " + name)
      failures = failures + 1
    }
  }

  // A status reply with every field the panel relies on, plus the overrides the
  // scenario needs. Passing it through applyStatus() directly is what makes
  // these assertions independent of process scheduling.
  function reply(extra) {
    var base = {
      ok: true,
      installed: true,
      engine: "xray",
      running: false,
      listening: false,
      autostartId: "",
      activeId: "",
      socksPort: null,
      httpPort: null,
      uptimeSec: 0,
      tunActive: false,
      tunProfileId: "",
      tunIface: "",
      tunSince: 0,
      tunCanStart: true,
      tunBlockedReason: "",
      tunLastError: ""
    }
    for (var key in extra) base[key] = extra[key]
    return JSON.stringify(base)
  }

  function tick() {
    var n = step
    step = step + 1

    if (n === 0) {
      // Baseline: nothing armed, nothing stale.
      service.stopTunArming()
      service.applyStatus(reply({}), 0)
      check("baseline is idle and unarmed", !service.tunArming && !service.tunActive)
      check("baseline has no arming snapshot", service._tunErrorAtArm === "")
    } else if (n === 1) {
      // B2 (first half): a status reply that still says "off" is the normal
      // pre-write answer while the helper authenticates. It is NOT evidence
      // that the attempt failed, so arming must survive it.
      service.tunUp("p1")
      check("tunUp arms for the on state", service.tunArming && service._tunArmTarget === 1)
      service.applyStatus(reply({}), 0)
      check("a pre-write status reply does not clear arming", service.tunArming)
    } else if (n === 2) {
      // Put the stale failure on disk (as a previous attempt would leave it),
      // then arm with it already present.
      service.stopTunArming()
      service.applyStatus(reply({ tunLastError: staleError }), 0)
      check("the stale helper failure is reported", service.tunLastError === staleError)
    } else if (n === 3) {
      service.tunUp("p1")
      check("tunUp arms with a stale failure already on disk",
            service.tunArming && service._tunErrorAtArm === staleError)
    } else if (n === 4) {
      // B2 exactly as the review described it: the SAME error value comes back
      // while the prompt is still up. This used to clear arming on the spot.
      service.applyStatus(reply({ tunLastError: staleError }), 0)
      check("an unchanged stale error does not clear arming", service.tunArming)
    } else if (n === 5) {
      // The other half of the rule: evidence that THIS attempt failed is an
      // error value that was not there when it was armed. Losing that would
      // leave the switch pulsing for 30s after a real failure.
      service.applyStatus(reply({ tunLastError: staleError + " (retry 2)" }), 0)
      check("an error that changed since arming clears it", !service.tunArming)
      // Re-arm with that value already on disk, so the next assertion is about
      // an UNCHANGED error again rather than about the same change twice.
      service.tunUp("p1")
      check("re-armed for the next scenario", service.tunArming)
      service.applyStatus(reply({}), 0)
      check("an empty error does not clear arming", service.tunArming)
    } else if (n === 6) {
      // Evidence about THIS attempt: the state actually moved.
      service.applyStatus(reply({ tunActive: true, tunProfileId: "p1", tunIface: "tun0",
                                  running: true, listening: true, tunCanStart: false }), 0)
      check("the state moving clears arming", !service.tunArming)
      check("the moved state is reflected", service.tunActive && service.mode === "tun")
    } else if (n === 7) {
      // The backstop: a cancelled prompt writes neither state nor error.
      service.tunArmTimeoutMs = 300
      service.stopTunArming()
      service.applyStatus(reply({}), 0)
      service.tunUp("p1")
      check("the timer scenario arms", service.tunArming)
    } else if (n === 8) {
      // One tick of air so the 300ms backstop can fire between ticks.
    } else if (n === 9) {
      // Two ticks later, the backstop must have ended the pulse.
      check("the backstop ends the pulse with no evidence at all", !service.tunArming)
      // ...and says what really happened. cmd_tun_up stops the proxy engine
      // before pkexec, so a never-answered prompt leaves the user disconnected.
      check("and says the proxy connection was stopped",
            service.notice.indexOf("proxy connection was stopped") !== -1)
      // NOT an invitation to reconnect: at 30s the gate is still closed, so
      // "reconnect now" would be a lie. The 120s cap is where that changes.
      check("and that the attempt is still unconfirmed",
            service.notice.indexOf("still unconfirmed") !== -1)
      check("and does not invite a reconnect yet",
            service.notice.indexOf("reconnect") === -1)
      service.tunArmTimeoutMs = 30000
    } else if (n === 10) {
      // B1 setup: armed for a TUN start.
      service.stopTunArming()
      service.applyStatus(reply({}), 0)
      service.tunUp("p1")
      check("B1 scenario arms", service.tunArming)
    } else if (n === 11) {
      // B1: the row click / cursor Enter path. It must refuse with the reason
      // and leave every piece of connection state untouched.
      service.connect("p1")
      check("connect refuses while TUN is starting",
            service.lastError.indexOf("TUN is starting") !== -1)
      check("connect leaves the optimistic state alone", service._pendingRunning === -1)
      check("connect starts no action", !service.busy && service.actionRowId === "")
    } else if (n === 12) {
      // B1: the bar's right-click and the `t` key.
      service.toggleConnection()
      check("toggleConnection refuses while TUN is starting",
            service.lastError.indexOf("TUN is starting") !== -1)
      check("toggleConnection starts no action", !service.busy)
    } else if (n === 13) {
      // disconnect() is not a connect: while TUN is up it must take the
      // privileged route instead of silently stopping nothing.
      service.stopTunArming()
      service.applyStatus(reply({ tunActive: true, tunProfileId: "p1", tunIface: "tun0",
                                  running: true, listening: true, tunCanStart: false }), 0)
      check("the tunnel reads as connected", service.connected)
      service.disconnect()
      check("disconnect routes to tunDown", service.tunArming && service._tunArmTarget === 0)
    } else if (n === 14) {
      // Should-fix 1: runAction refuses while another action is in flight, so
      // nothing was launched — arming must not start a 30s countdown for it.
      service.stopTunArming()
      service.applyStatus(reply({}), 0)
      service.connect("p1")
      check("the slow proxy start really is in flight", service.busy)
      service.tunUp("p1")
      check("tunUp does not arm when runAction refuses", !service.tunArming)
      check("and leaves the running action alone", service.busy)
      check("and says another action is running",
            service.lastError.indexOf("Another action is still running") !== -1)
    } else if (n === 15 || n === 16 || n === 17) {
      // Air: the fake `start` from n===14 sleeps for 0.3s on purpose, and
      // runAction refuses while it is in flight (these ticks are 250ms apart).
    } else if (n === 18) {
      // THE HAND-OFF OUTLIVES THE PULSE. A prompt that takes longer than the
      // 30s pulse must still keep proxy connects off the ports; otherwise B1
      // comes back, just slower. Both windows are shortened so the test does
      // not sit here for minutes.
      service.stopTunArming()
      service.applyStatus(reply({}), 0)
      service.tunArmTimeoutMs = 200
      service.tunHandoffTimeoutMs = 30000
      service.tunUp("p1")
      check("slow-auth scenario starts a hand-off",
            service.tunArming && service.tunHandoffPending)
    } else if (n === 19) {
      // The pulse has given up (200ms) but nothing has confirmed the hand-off.
      check("the pulse gives up at its own timeout", !service.tunArming)
      check("the hand-off gate outlives the pulse", service.tunHandoffPending)
      service.connect("p1")
      check("connect is still refused after the pulse expired",
            service.lastError.indexOf("TUN is starting") !== -1)
      check("no proxy action was started after the pulse expired",
            !service.busy && service._pendingRunning === -1 && service.actionRowId === "")
      service.toggleConnection()
      check("toggleConnection is still refused after the pulse expired",
            service.lastError.indexOf("TUN is starting") !== -1 && !service.busy)
    } else if (n === 20) {
      // The hard cap: short enough to observe, long enough that it is only a
      // backstop for a helper that never reports anything at all.
      service.stopTunArming()
      service.applyStatus(reply({}), 0)
      service.tunArmTimeoutMs = 150
      service.tunHandoffTimeoutMs = 500
      service.tunUp("p1")
      check("cap scenario starts a hand-off", service.tunHandoffPending)
    } else if (n === 21 || n === 22) {
      // Air for the 500ms cap.
    } else if (n === 23) {
      // 750ms after arming: past the 150ms pulse and the 500ms cap.
      check("the cap clears the hand-off gate", !service.tunHandoffPending)
      check("the cap says the hand-off was never confirmed",
            service.notice.indexOf("never confirmed") !== -1
            && service.notice.indexOf("tun-status") !== -1)
      service.tunArmTimeoutMs = 30000
      service.tunHandoffTimeoutMs = 120000
    } else if (n === 24) {
      // A status reply that shows the PROXY engine running again means the
      // user's own explicit action succeeded; the gate must not strand them.
      service.stopTunArming()
      service.applyStatus(reply({}), 0)
      service.tunUp("p1")
      check("proxy-back scenario starts a hand-off", service.tunHandoffPending)
      // First, the reply a status query already in flight when the switch was
      // pressed would produce: the OLD proxy engine. "Again" has not happened.
      service.applyStatus(reply({ running: true, listening: true, mode: "proxy",
                                  activeId: "p1" }), 0)
      check("a stale proxy reply does not drop the gate", service.tunHandoffPending)
      // Then the engine is observed stopped...
      service.applyStatus(reply({}), 0)
      check("the gate survives the proxy engine being stopped", service.tunHandoffPending)
      // ...and only now is a running proxy engine the user's own doing.
      service.applyStatus(reply({ running: true, listening: true, mode: "proxy",
                                  activeId: "p1" }), 0)
      check("a proxy engine running again clears the gate", !service.tunHandoffPending)
    } else if (n === 25) {
      // SHOULD-FIX 3: THE STOP DIRECTION MUST NOT BE STRANDED. TUN is up, the
      // user turns it off, and the prompt is never answered — no state change,
      // no error. The gate must not make the off switch dead for two minutes.
      service.stopTunArming()
      service.applyStatus(reply({ tunActive: true, tunProfileId: "p1", tunIface: "tun0",
                                  running: true, listening: true, tunCanStart: false }), 0)
      service.tunArmTimeoutMs = 30000
      service.tunDown()
      check("a stop hand-off starts",
            service.tunArming && service.tunHandoffPending && service._tunArmTarget === 0)
      check("a stop hand-off is not a start-pending gate", !service.tunStartPending)
    } else if (n === 26) {
      // The launcher has exited by now; the pulse is still up. A second off
      // click must work: the helper's acquire_teardown_lock serialises it.
      service.tunArmTimeoutMs = 150
      service.tunDown()
      check("tunDown still works while the stop pulse is up",
            service.busy && service.tunArming)
    } else if (n === 27) {
      // Past the pulse, still inside the gate: the case the review described.
      check("the stop pulse gave up", !service.tunArming)
      check("the stop gate is still pending", service.tunHandoffPending)
      service.tunDown()
      check("tunDown still works while the stop gate is pending", service.busy)
    } else if (n === 29) {
      // ...and the switch, which routes through tunToggle, must reach the stop
      // path rather than the "waiting for authorisation" refusal.
      service.tunToggle()
      check("tunToggle still routes to a stop while the gate is pending", service.busy)
    } else if (n === 32) {
      console.log("TAP summary failures=" + failures)
      Qt.quit()
    }
  }

  Timer {
    interval: 250
    repeat: true
    running: true
    onTriggered: root.tick()
  }
}
QML
}

# quickshell_can_start — a minimal config whose only job is to prove quickshell
# can open a session here, so "no output" is told apart from "this machine
# cannot run the test".
quickshell_can_start() {
  local dir="$WORK/canary" marker="$WORK/canary/loaded" log="$WORK/canary.log" i pid
  rm -rf "$dir"; mkdir -p "$dir"
  cat >"$dir/shell.qml" <<QML
import QtQuick
import Quickshell
import Quickshell.Io

Item {
  Process { id: probe; command: ["touch", "$marker"]; running: true }
  Timer { interval: 8000; running: true; onTriggered: Qt.quit() }
}
QML
  : >"$log"
  qs -p "$dir" >"$log" 2>&1 </dev/null &
  pid=$!
  for (( i = 0; i < 100; i++ )); do
    [[ -e $marker ]] && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  kill -TERM "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [[ -e $marker ]]
}

# ================================================================ the run ====
echo
echo "TUN service state machine (real Service.qml under quickshell)"
LOG="$WORK/qs.log"
build_harness "$WORK/harness"
: >"$LOG"
qs -p "$WORK/harness" >"$LOG" 2>&1 </dev/null &
QS_PID=$!
for (( i = 0; i < 300; i++ )); do
  grep -q 'TAP summary' "$LOG" 2>/dev/null && break
  kill -0 "$QS_PID" 2>/dev/null || break
  sleep 0.1
done
kill -TERM "$QS_PID" 2>/dev/null || true
wait "$QS_PID" 2>/dev/null || true

OUT="$(sed 's/\x1b\[[0-9;]*m//g' "$LOG" | grep -o 'TAP .*' || true)"

if [[ -z $OUT ]] || ! grep -q 'TAP summary' <<<"$OUT"; then
  if quickshell_can_start; then
    printf '  FAIL the harness never ran (quickshell started, no TAP output)\n'
    printf '        quickshell log: %s\n' "$LOG"
    sed -n '1,12p' "$LOG" | sed 's/^/        /'
    failures=$((failures + 1))
  else
    printf '  SKIP quickshell cannot open a session here, so the state machine test did not run\n'
    exit 0
  fi
else
  printf '%s\n' "$OUT" | grep -v '^TAP summary' | sed 's/^TAP /  /'
  summary="$(grep '^TAP summary' <<<"$OUT" | sed 's/.*failures=//')"
  # The summary is the driver's own count; the FAIL grep is the shell's
  # independent one. Both must agree, or a driver bug could hide a failure.
  fail_lines="$(grep -c '^TAP FAIL' <<<"$OUT" || true)"
  if [[ $summary != "0" || ${fail_lines:-0} != "0" ]]; then
    printf '  FAIL %s check(s) failed (driver says %s)\n' "${fail_lines:-0}" "$summary"
    failures=$((failures + 1))
  fi
fi

# ==================================================================== summary =
echo
if (( failures == 0 )); then
  echo "TUN service test: all checks passed"
else
  echo "TUN service test: $failures check(s) FAILED"
fi
exit $(( failures > 0 ))

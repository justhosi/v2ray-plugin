#!/usr/bin/env bash
# =============================================================================
# Panel-side regression test: `omarchy-v2ray import` must be driven through the
# child's STDIN, never through argv and never through the environment.
#
# WHY THIS EXISTS
# ---------------
# Service.qml used to hand the import payload to the backend as a FOURTH
# argument of the child's command list:
#
#     runAction(["bash", scriptPath, "import", JSON.stringify(payload)], id)
#
# That payload is the profile's credential (the VLESS/Vmess user UUID, or the
# Trojan/Shadowsocks password). A process's command line is world-readable for
# as long as that process lives — `ps -ww` and /proc/<pid>/cmdline need no
# privileges — so every user on the machine could read the secret out of it.
#
# The fix (commit e0b8b3c) sends the JSON down the child's stdin instead, a pipe
# only the panel and the backend hold. This test pins that property AT RUNTIME,
# not by reading the source: it starts quickshell with the real Service.qml,
# asks the panel to import a link whose UUID is a unique sentinel, and then
# inspects the process the panel actually started.
#
# HOW THE OBSERVATION WORKS
# -------------------------
# Quickshell resolves `bin/omarchy-v2ray` relative to Service.qml, so the harness
# places a *recording double* at exactly that path. Before answering the panel,
# the double copies the kernel's own view of itself into a file:
#
#     /proc/$$/cmdline   what the world sees as this process's arguments
#     /proc/$$/environ   what the world sees as its environment
#     its stdin          what the panel actually fed it
#
# That is not a simulation. The double is a real child of a real quickshell,
# spawned by the real Process object inside the real Service.qml, and those two
# files hold the exact bytes an unprivileged `cat /proc/<pid>/cmdline` would
# print. The double reads them while it is still alive, so there is no window in
# which it could exit before being looked at and no race to lose.
#
# Its stdin read is bounded (`timeout 3 cat`), because quickshell hands a child
# whose Process has stdinEnabled=false a pipe it never closes: an unbounded
# `cat` would sit there until quickshell itself died, and the recording would
# never be finished. The bound costs nothing for the case that matters — the
# fixed panel writes the payload and closes the pipe at once, so the read
# returns immediately — and simply records "no stdin" for everything else,
# which is exactly what the pre-fix panel should show.
#
# The sentinel itself is planted only in the pasted share link, which is a QML
# string — not argv, not the environment, and not visible in /proc. Nothing in
# this script hands it to a process: the credential checks feed it to grep from
# a FILE (`grep -f`) precisely so it never lands in a test process's own command
# line, which would undermine the very property under test.
#
# THE CLIPBOARD GETS THE SAME TREATMENT
# -------------------------------------
# The panel's copy button puts the same link on the clipboard, and the same rule
# applies: a share link *is* the credential, so it must reach wl-copy on stdin
# rather than through `bash -c "printf %s '<link>' | wl-copy"`. The harness
# therefore also puts a recording double named `wl-copy` on PATH and asks the
# panel to copy the link. Because the vulnerable shape keeps the secret in the
# *shell's* argv (one process above wl-copy) and not in wl-copy's own, each
# recording also captures its parent's command line — that is what lets the
# clipboard checks fail against the pre-fix panel instead of passing vacuously.
#
# THE CONTROL
# -----------
# A test that only ever finds nothing proves nothing. The same harness is
# therefore run a second time against the PRE-FIX Service.qml (commit 42b6033),
# which must leak the sentinel into /proc/<pid>/cmdline. If the control does not
# leak, the absence checks on the current panel could not fail against the
# vulnerable code and would be worthless — so the control is asserted too.
#
# THE PUBLIC IPC SURFACE GETS THE SAME TREATMENT
# ---------------------------------------------
# `qs ipc call <target> <function> <arguments…>` delivers arguments on the
# CALLER's command line, and Quickshell's IPC has no stdin channel, so a public
# handler taking a share link is an argv leak by construction. Panel.qml used to
# publish `importLink(link: string): string` with a comment advertising exactly
# that usage. The last section loads the real Panel.qml and asks the running
# panel over its own IPC what it publishes, then replays the pre-fix Panel.qml
# as a control — the forbidden signature has to show up there and nowhere else.
#
# RUNNING IT
# ----------
#     ./tests/test-service-import.sh
#
# Needs quickshell (`qs`) and a reachable Wayland session; without either it
# prints SKIP and exits 0 so a headless CI run stays green. It touches nothing
# outside its own temp directory. tests/test-backend.sh runs it as its last case.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

# The panel under test, and the vulnerable revision it must be better than. The
# commit can be overridden for a checkout that has been rebased.
SERVICE="$REPO/Service.qml"
# The panel itself, plus the Omarchy UI module it imports (`qs.Ui`). The
# IPC-surface section below needs both; it skips cleanly when the module is
# missing, the same way the rest of the file skips without quickshell.
PANEL="$REPO/Panel.qml"
UI_DIR="${OMARCHY_V2RAY_UI:-/usr/share/omarchy/shell/Ui}"
PREFIX_COMMIT="${OMARCHY_V2RAY_PREFIX_COMMIT:-42b6033d9170588a00148d3b5d1d340538ef3277}"

# The credential. A UUID no other test in this repo uses, so any match can only
# have come from this import.
SENTINEL="11111111-2222-3333-4444-555555555555"

# A share link that builds a complete REALITY/VLESS config. 203.0.113.10 is
# TEST-NET-3 (reserved and unroutable) and the pbk/sid are throwaways, so
# nothing here can reach a real server.
LINK="vless://${SENTINEL}@203.0.113.10:443?type=tcp&security=reality&sni=example.com&pbk=xLc7RbYq2Yh1HkrRz2Zr9yQ3p1Wq0v8mN4sT6uV9wXa&sid=abcd1234&fp=chrome&flow=xtls-rprx-vision#Regression"

WORK="$(mktemp -d)"
failures=0

# ------------------------------------------------------------------ reporting --
check() {                    # check <description> <condition...>
  local what="$1"; shift
  if "$@" >/dev/null 2>&1; then
    printf '  ok   %s\n' "$what"
  else
    printf '  FAIL %s\n' "$what"
    failures=$((failures + 1))
  fi
}

# check_contains_file <description> <file> <needle> — for needles that are not
# secrets (a subcommand name), so passing them in an argument list is fine.
check_contains_file() {
  local what="$1" file="$2" needle="$3"
  if grep -qF -- "$needle" "$file" 2>/dev/null; then
    printf '  ok   %s\n' "$what"
  else
    printf '  FAIL %s\n        the recording does not mention "%s" at all\n' "$what" "$needle"
    failures=$((failures + 1))
  fi
}

# The two credential checks read the needle from $SENTINEL_FILE. That is not
# fussiness: handing it to grep as an argument would put the sentinel into a
# process's cmdline, exactly the exposure this test exists to rule out.
check_absent_cred() {        # check_absent_cred <description> <file>
  local what="$1" file="$2"
  if grep -qFf "$SENTINEL_FILE" "$file" 2>/dev/null; then
    printf '  FAIL %s\n        the credential WAS visible in the recording\n' "$what"
    failures=$((failures + 1))
  else
    printf '  ok   %s\n' "$what"
  fi
}

check_present_cred() {       # check_present_cred <description> <file>
  local what="$1" file="$2"
  if grep -qFf "$SENTINEL_FILE" "$file" 2>/dev/null; then
    printf '  ok   %s\n' "$what"
  else
    printf '  FAIL %s\n        the credential never appeared where it had to\n' "$what"
    failures=$((failures + 1))
  fi
}

# ------------------------------------------------------- reading a recording --
# capture_section <capture-file> <index> — print the Nth "--- ... ---" section
# of a recording. The double writes them in a fixed order (1 argv, 2 cmdline,
# 3 environ, 4 stdin), and addressing them by position keeps the caller free of
# the double's own "$$" spelling.
capture_section() {
  awk -v want="$2" '
    /^--- / { n++; f = (n == want); next }
    f { print }
  ' "$1"
}

# ---------------------------------------------------------------- the harness --
# build_harness <dir> <path-to-panel-file>
#
# Assembles a throwaway quickshell config directory containing the panel under
# test, everything it imports, and a recording double at the backend path.
build_harness() {
  local dir="$1" panel="$2"
  rm -rf "$dir"
  mkdir -p "$dir/bin" "$dir/capture"

  # The panel, byte for byte. Model.js and qs.Commons sit beside it because
  # Service.qml imports both relative to its own URL, and quickshell resolves
  # qs.Commons out of the running config's directory.
  cp "$panel" "$dir/Service.qml"
  ln -s "$REPO/Model.js" "$dir/Model.js"
  ln -s "$COMMONS_DIR" "$dir/Commons"

  # The recording double. It stands in for BOTH programs the panel shells out
  # to: bin/omarchy-v2ray (the backend) and wl-copy (the clipboard sink, found
  # on PATH). One body serves both because the only thing that differs is how
  # the recording is labelled, and that is derived from the program's own name.
  #
  # This heredoc is deliberately UNQUOTED so "$dir" is baked in now; every "$"
  # the double itself must expand is escaped, and the secret under test only
  # ever arrives on stdin (read by the bounded `cat` below, never named here).
  cat > "$dir/bin/omarchy-v2ray" <<SH
#!/usr/bin/env bash
# Test double: record how we were invoked, then do the job the real program
# would have done.
#
# The label decides the recording's filename: the backend is labelled with the
# subcommand it was given (so the panel's import shows up as import.<pid>),
# while wl-copy has no arguments and is labelled "clipboard".
case "\$(basename "\$0")" in
  wl-copy) label=clipboard ;;
  *)       label="\${1:-none}" ;;
esac
recording="$dir/capture/\$label.\$\$"
partial="$dir/capture/.partial.\$label.\$\$"
{
  printf 'role=%s\n' "\$label"
  printf '%s\n' '--- argv (arguments after \$0) ---'
  for a in "\$@"; do printf '%s\n' "\$a"; done
  printf '%s\n' '--- /proc/\$\$/cmdline ---'
  tr '\0' '\n' < "/proc/\$\$/cmdline"
  printf '%s\n' '--- /proc/\$\$/environ ---'
  tr '\0' '\n' < "/proc/\$\$/environ"
  printf '%s\n' '--- stdin ---'
  # Bounded on purpose: see the note in the header of this file. A child whose
  # stdin the panel never writes to (every non-import call, and every call made
  # by the pre-fix panel) would otherwise hang here until quickshell exits.
  timeout 3 cat
  # The PARENT's command line, which is where the pre-fix panel leaked: it used
  # to run the copy through \`bash -c "printf %s '<link>' | wl-copy"\`, so the
  # credential sat in the shell's argv and not in wl-copy's. Reading it here is
  # what makes the clipboard checks below able to fail against that design.
  # A newline of our own first: the stdin above may not have ended with one
  # (wl-copy is handed the link verbatim, exactly so no stray newline is pasted
  # with it), and a section header only counts when it starts a line.
  printf '\n%s\n' '--- parent (/proc/\$PPID) cmdline ---'
  tr '\0' '\n' < "/proc/\$PPID/cmdline"
} > "\$partial"
# The final name appears only once the recording is complete, so the parent can
# treat a file's existence as "this one is readable".
mv "\$partial" "\$recording"
# wl-copy prints nothing when it succeeds; the backend answers with JSON.
case "\$(basename "\$0")" in
  wl-copy) : ;;
  *)       printf '{"ok":true}\n' ;;
esac
SH
  chmod +x "$dir/bin/omarchy-v2ray"

  # The clipboard sink the panel looks up on PATH. Same recorder, different
  # name; the panel's \`command: ["wl-copy"]\` resolves to it while the harness
  # runs and to the real one in production.
  mkdir -p "$dir/fakebin"
  cp "$dir/bin/omarchy-v2ray" "$dir/fakebin/wl-copy"
  chmod +x "$dir/fakebin/wl-copy"

  # The shell config quickshell runs. `Service` is the implicit type of the
  # Service.qml beside it. The Timers drive the panel's two credential-bearing
  # paths — paste the link (import), then ask for it on the clipboard — after a
  # beat, so the panel's own startup refresh has settled; the last is a backstop
  # exit for the rare case where the parent does not kill quickshell first.
  cat > "$dir/shell.qml" <<QML
import QtQuick
import Quickshell

Item {
  Service { id: service }

  Timer { interval: 600; running: true; onTriggered: service.importLink("$LINK") }
  Timer { interval: 1200; running: true; onTriggered: service.copyToClipboard("$LINK") }
  Timer { interval: 8000; running: true; onTriggered: Qt.quit() }
}
QML
}

# build_panel_harness <dir> <path-to-Panel.qml>
#
# The panel equivalent of build_harness: same throwaway config, same recording
# double for the backend and the clipboard, but the shell instantiates the REAL
# Panel.qml through a Loader instead of Service directly. That is what registers
# the panel's IpcHandler, so `qs ipc show` can be asked — at runtime, from
# outside the process — exactly what the widget publishes to the world.
#
# Panel.qml imports `qs.Ui` (the bar widget types) and uses two QML files beside
# it, so those are linked/copied in too. The Service.qml used here is always the
# working-tree one: the IPC surface is a property of Panel.qml, and the control
# run below switches only that file.
build_panel_harness() {
  local dir="$1" panel="$2"
  build_harness "$dir" "$SERVICE"
  cp "$panel" "$dir/Panel.qml"
  cp "$REPO/V2rayActionButton.qml" "$REPO/V2rayShield.qml" "$dir/"
  ln -s "$UI_DIR" "$dir/Ui"
  cat > "$dir/shell.qml" <<QML
import QtQuick
import Quickshell

Item {
  Loader { source: "Panel.qml" }
  Timer { interval: 20000; running: true; onTriggered: Qt.quit() }
}
QML
}

# wait_for_ipc <dir> — poll `qs ipc show` for the harness in <dir> until its IPC
# target answers, and leave the listing in IPC_SURFACE (empty if it never came
# up). `qs ipc` reaches an instance by its config path, so it can never pick up
# the user's own running shell. The harness must already be started, and the
# CALLER stops it — the listing and the calls below both need it alive.
wait_for_ipc() {
  local dir="$1" i out
  IPC_SURFACE=""
  for (( i = 0; i < 120; i++ )); do
    # Until the instance is up, `qs ipc` HELPfully writes its complaint to
    # STDOUT ("Could not open config file at …") and exits 255 — so "some
    # output arrived" is not the signal to stop polling. The target line is.
    out="$(qs ipc -p "$dir" show 2>/dev/null)"
    if grep -q 'community\.v2ray-client' <<<"$out"; then
      IPC_SURFACE="$out"
      return 0
    fi
    kill -0 "$HARNESS_PID" 2>/dev/null || return 1
    sleep 0.1
  done
  return 1
}

# ------------------------------------------------------------ running a harness --
# start_harness <dir> <logfile> — launch quickshell on the harness in the
# background; its pid is kept in HARNESS_PID. stdin comes from /dev/null so the
# double can never inherit a pipe that would make its `cat` hang. The harness's
# fakebin goes first on PATH so that the panel's `["wl-copy"]` process lands on
# the recording double instead of a clipboard that may not exist on the test
# machine — the same trick the backend suite uses for xray/ss/curl.
start_harness() {
  local dir="$1" log="$2"
  HARNESS_PID=""
  : > "$log"
  PATH="$dir/fakebin:$PATH" qs -p "$dir" >"$log" 2>&1 </dev/null &
  HARNESS_PID=$!
}

# wait_for_recording <dir> <seconds> <glob> — set RECORDING to the first finished
# recording whose name matches <glob> (or ""), waiting up to <seconds>. Each
# recording is named after what the double was asked to do, so a caller waits
# for the specific call it cares about rather than for one of the panel's
# startup status/list queries. The '.partial.' names the doubles write while a
# recording is still being filled in are excluded.
wait_for_recording() {
  local dir="$1" seconds="$2" glob="$3" i
  RECORDING=""
  for (( i = 0; i < seconds * 10; i++ )); do
    RECORDING="$(find "$dir/capture" -name "$glob" -type f ! -name '.partial.*' 2>/dev/null | head -n1)"
    [[ -n $RECORDING ]] && return 0
    kill -0 "$HARNESS_PID" 2>/dev/null || return 1   # quickshell died: stop waiting
    sleep 0.1
  done
  return 1
}

# stop_harness — SIGTERM, then SIGKILL if it will not go. Quickshell reaps the
# children it started and the double exits by itself the moment it has
# recorded, so nothing is left behind either way.
stop_harness() {
  [[ -n ${HARNESS_PID:-} ]] || return 0
  local i
  kill -TERM "$HARNESS_PID" 2>/dev/null || true
  for (( i = 0; i < 25; i++ )); do
    kill -0 "$HARNESS_PID" 2>/dev/null || break
    sleep 0.1
  done
  kill -KILL "$HARNESS_PID" 2>/dev/null || true
  wait "$HARNESS_PID" 2>/dev/null || true
  HARNESS_PID=""
}

cleanup() {
  stop_harness
  rm -rf "$WORK"
}
trap cleanup EXIT

# quickshell_can_start — a minimal config whose only job is to prove quickshell
# can open a session here. Without it, "no recording" could mean either "this
# machine cannot run the panel test" or "the panel test ran and the panel is
# broken"; the two want opposite verdicts (skip vs fail), so they are told
# apart explicitly.
quickshell_can_start() {
  local dir="$WORK/canary" marker="$WORK/canary/loaded" log="$WORK/canary.log" i pid
  rm -rf "$dir"; mkdir -p "$dir"
  cat > "$dir/shell.qml" <<QML
import QtQuick
import Quickshell
import Quickshell.Io

Item {
  Process { id: probe; command: ["touch", "$marker"]; running: true }
  Timer { interval: 8000; running: true; onTriggered: Qt.quit() }
}
QML
  : > "$log"
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

# ================================================================ prerequisites =
if ! command -v qs >/dev/null 2>&1; then
  printf '  SKIP quickshell (qs) is not installed, so the panel cannot be driven\n'
  exit 0
fi

# Service.qml imports qs.Commons. omarchy ships it; outside an omarchy install a
# stub with the same module name is enough, because the panel only imports it
# for the type namespace (the one member the pre-fix panel used, Util.shellQuote,
# is never called by this test).
COMMONS_DIR="${OMARCHY_V2RAY_COMMONS:-/usr/share/omarchy/shell/Commons}"
if [[ ! -f $COMMONS_DIR/qmldir ]]; then
  COMMONS_DIR="$WORK/Commons"
  mkdir -p "$COMMONS_DIR"
  cat > "$COMMONS_DIR/qmldir" <<'STUB'
module qs.Commons
singleton Util 1.0 Util.qml
STUB
  cat > "$COMMONS_DIR/Util.qml" <<'STUB'
pragma Singleton
import QtQuick

// Placeholder for qs.Commons.Util so `import qs.Commons` resolves when this
// checkout is tested outside an omarchy install. Never called here.
QtObject {
  function shellQuote(value) { return "'" + String(value) + "'" }
}
STUB
fi

SENTINEL_FILE="$WORK/sentinel"
printf '%s\n' "$SENTINEL" > "$SENTINEL_FILE"

# ===================================================== the panel under test ====
echo
echo "panel import path: the payload must travel on stdin, never in argv"
build_harness "$WORK/current" "$SERVICE"
start_harness "$WORK/current" "$WORK/current/qs.log"
wait_for_recording "$WORK/current" 25 'import.*'
IMPORT_RECORDING="$RECORDING"
# Only look for the clipboard call if the harness actually got as far as the
# import; otherwise one failure would be reported twice.
[[ -n $IMPORT_RECORDING ]] && wait_for_recording "$WORK/current" 25 'clipboard.*'
CLIP_RECORDING="$RECORDING"
stop_harness

if [[ -z $IMPORT_RECORDING ]]; then
  if quickshell_can_start; then
    printf '  FAIL the panel never reached the backend at all (quickshell started, no import was recorded)\n'
    printf '        quickshell log: %s\n' "$WORK/current/qs.log"
    failures=$((failures + 1))
  else
    printf '  SKIP quickshell cannot open a session here, so the panel integration test did not run\n'
    exit 0
  fi
else
  capture_section "$IMPORT_RECORDING" 1 > "$WORK/argv"
  capture_section "$IMPORT_RECORDING" 2 > "$WORK/cmdline"
  capture_section "$IMPORT_RECORDING" 3 > "$WORK/environ"
  capture_section "$IMPORT_RECORDING" 4 > "$WORK/stdin"

  # First, prove the recording is real: an empty argv section would make every
  # "must not contain" check below pass for the wrong reason.
  check_contains_file "the backend double really received the import subcommand" \
    "$WORK/argv" "import"

  # 1. The command itself carries no JSON payload. Inside a bash script $0 is
  #    the script path, so exactly ONE argument — the subcommand — should reach
  #    the backend. The old code appended the JSON as a second one.
  check "the import command carries exactly one argument, the subcommand" \
    test "$(grep -c . "$WORK/argv")" -eq 1
  check "the full command line is exactly [bash, script, import]" \
    test "$(grep -c . "$WORK/cmdline")" -eq 3

  # 2. The credential is in none of the three world-readable places...
  check_absent_cred "no credential in the import command's arguments" "$WORK/argv"
  check_absent_cred "no credential in /proc/<pid>/cmdline of the live import" "$WORK/cmdline"
  check_absent_cred "no credential in /proc/<pid>/environ of the live import" "$WORK/environ"

  # 3. ...and no shell one-liner was built around it either (a `bash -c "..."`
  #    would put the payload straight back into argv, under a different name).
  check "the import is not wrapped in a shell one-liner (bash -c)" \
    bash -c '! grep -qx -- "-c" "$1"' _ "$WORK/cmdline"

  # 4. The payload did arrive — on stdin, the one channel that is not published
  #    to the rest of the machine.
  check_present_cred "the credential DID travel on the import child's stdin" "$WORK/stdin"
fi

# ============================================================ the clipboard ===
echo
echo "panel clipboard path: the link must travel on wl-copy's stdin, never in a command line"
if [[ -z $IMPORT_RECORDING ]]; then
  :   # the harness could not run at all; already reported above
elif [[ -z $CLIP_RECORDING ]]; then
  printf '  FAIL the panel never ran its clipboard copy (no wl-copy double was started)\n'
  failures=$((failures + 1))
else
  capture_section "$CLIP_RECORDING" 1 > "$WORK/clip-argv"
  capture_section "$CLIP_RECORDING" 2 > "$WORK/clip-cmdline"
  capture_section "$CLIP_RECORDING" 3 > "$WORK/clip-environ"
  capture_section "$CLIP_RECORDING" 4 > "$WORK/clip-stdin"
  capture_section "$CLIP_RECORDING" 5 > "$WORK/clip-parent"

  # Again, non-vacuity first: an empty recording would make the absences pass.
  check_contains_file "the clipboard double really was the program the panel ran" \
    "$WORK/clip-cmdline" "wl-copy"

  # The copy itself is a bare `wl-copy` with no arguments at all...
  check "the copy command carries no arguments, so no link in its argv" \
    test "$(grep -c . "$WORK/clip-argv")" -eq 0

  # ...the credential appears in none of the world-readable places...
  check_absent_cred "no credential in the copy command's arguments" "$WORK/clip-argv"
  check_absent_cred "no credential in /proc/<pid>/cmdline of the live wl-copy" "$WORK/clip-cmdline"
  check_absent_cred "no credential in /proc/<pid>/environ of the live wl-copy" "$WORK/clip-environ"

  # ...no shell was needed to do it. `bash -c "printf %s '<link>' | wl-copy"`
  # parks the link in the *shell's* command line, one process up from wl-copy,
  # so the parent is inspected too: it must be the panel itself, and it must not
  # be carrying the credential.
  check_absent_cred "no credential in the copy's PARENT command line" "$WORK/clip-parent"
  check "the copy's parent is the panel process, not a shell" \
    bash -c '[[ "$(head -n1 "$1")" == qs ]]' _ "$WORK/clip-parent"

  # And the clipboard still works: the link reached wl-copy on stdin, verbatim.
  check_present_cred "the link DID travel on wl-copy's stdin" "$WORK/clip-stdin"
fi

# ================================================================ the control ==
echo
echo "control: the pre-fix panel has to be caught leaking, or the checks above prove nothing"
if git -C "$REPO" cat-file -e "$PREFIX_COMMIT:Service.qml" 2>/dev/null; then
  git -C "$REPO" show "$PREFIX_COMMIT:Service.qml" > "$WORK/Service.prefix.qml"
  build_harness "$WORK/prefix" "$WORK/Service.prefix.qml"
  start_harness "$WORK/prefix" "$WORK/prefix/qs.log"
  wait_for_recording "$WORK/prefix" 25 'import.*'
  PREFIX_IMPORT="$RECORDING"
  [[ -n $PREFIX_IMPORT ]] && wait_for_recording "$WORK/prefix" 25 'clipboard.*'
  PREFIX_CLIP="$RECORDING"
  stop_harness
  if [[ -z $PREFIX_IMPORT ]]; then
    printf '  FAIL control: the pre-fix panel never reached the backend either — the control could not run\n'
    failures=$((failures + 1))
  else
    capture_section "$PREFIX_IMPORT" 2 > "$WORK/prefix-cmdline"
    capture_section "$PREFIX_IMPORT" 4 > "$WORK/prefix-stdin"
    check_present_cred \
      "control: the pre-fix panel DOES leak the credential into /proc/<pid>/cmdline" \
      "$WORK/prefix-cmdline"
    check_absent_cred \
      "control: the pre-fix panel never sent it on stdin" \
      "$WORK/prefix-stdin"
    if [[ -z $PREFIX_CLIP ]]; then
      printf '  FAIL control: the pre-fix panel ran no clipboard copy to compare against\n'
      failures=$((failures + 1))
    else
      capture_section "$PREFIX_CLIP" 5 > "$WORK/prefix-clip-parent"
      check_present_cred \
        "control: the pre-fix panel leaks the link into the copy's PARENT command line" \
        "$WORK/prefix-clip-parent"
      check_contains_file \
        "control: that leak rode in a shell -c command line" \
        "$WORK/prefix-clip-parent" "-c"
    fi
  fi
else
  printf '  SKIP control: commit %s is not in this checkout, so the vulnerable baseline cannot be replayed\n' \
    "${PREFIX_COMMIT:0:7}"
fi

# ======================================================== the panel's IPC surface ==
echo
echo "panel IPC surface: no public handler may take a link, because an IPC argument IS argv"
# Why this is checked at runtime and not by reading Panel.qml: `qs ipc call
# <target> <function> <arguments…>` hands every argument to the CALLER's command
# line, where /proc publishes it to the whole machine — and Quickshell's IPC has
# no stdin channel to hand it over instead (a literal `-` is passed through as
# text). A public handler that takes a share link is therefore an argv leak by
# construction, and the panel used to publish exactly that:
#
#     function importLink(link: string): string
#     // "a shell script can import a link: omarchy-shell … importLink vless://…"
#
# The check below asks the RUNNING panel, over its own IPC, what it publishes.
# No credential is ever passed to `qs ipc` here: the vulnerable call shape must
# not be exercised by the test that forbids it.
if [[ ! -f $UI_DIR/qmldir ]]; then
  printf '  SKIP the Omarchy UI module is not installed (%s), so Panel.qml cannot be loaded here\n' "$UI_DIR"
else
  build_panel_harness "$WORK/ipc" "$PANEL"
  start_harness "$WORK/ipc" "$WORK/ipc/qs.log"
  wait_for_ipc "$WORK/ipc" || true          # leaves the listing in IPC_SURFACE
  printf '%s\n' "$IPC_SURFACE" > "$WORK/ipc-surface"

  if [[ -z $IPC_SURFACE ]]; then
    printf '  FAIL the panel never published its IPC target (see %s)\n' "$WORK/ipc/qs.log"
    sed -n '1,12p' "$WORK/ipc/qs.log" | sed 's/^/        /'
    failures=$((failures + 1))
  else
    # Non-vacuity first: a surface that listed nothing would make every absence
    # check below pass for the wrong reason.
    check_contains_file "the live panel really publishes its IPC target" \
      "$WORK/ipc-surface" "target community.v2ray-client"
    check_contains_file "the surface still lists the ordinary argument-free calls" \
      "$WORK/ipc-surface" "function status(): string"

    # 1. The vulnerable interface must be gone by name...
    check "no public IPC handler is named importLink" \
      bash -c '! grep -q -- "importLink" "$1"' _ "$WORK/ipc-surface"

    # 2. ...and, one rule up, no public handler may take ANY argument. This is
    #    the check that keeps a link-shaped function from coming back under a
    #    different name: an IPC parameter is always a command-line word.
    check "no public IPC handler declares a parameter at all" \
      bash -c '! grep -Eq "function[[:space:]]+[A-Za-z0-9_]+[[:space:]]*\([[:space:]]*[A-Za-z_]" "$1"' _ "$WORK/ipc-surface"

    # 3. The listing is not the whole story: an attempt to call the removed
    #    entry point must be refused. No argument is passed, so this check
    #    itself adds no argv exposure. An ordinary call is made first, to show
    #    that refusals here are about the function and not about IPC being dead.
    qs ipc -p "$WORK/ipc" call community.v2ray-client refresh  > "$WORK/ipc-call-refresh"   2>&1 || true
    qs ipc -p "$WORK/ipc" call community.v2ray-client importLink > "$WORK/ipc-call-gone"    2>&1 || true
    check_contains_file "an ordinary IPC call still works" "$WORK/ipc-call-refresh" "ok"
    check "calling the removed entry point is refused (not found)" \
      bash -c 'grep -qi "not found" "$1" && ! grep -q "^ok$" "$1"' _ "$WORK/ipc-call-gone"
  fi
  stop_harness

  # ---- control: the pre-fix Panel.qml publishes exactly what is forbidden ----
  if git -C "$REPO" cat-file -e "$PREFIX_COMMIT:Panel.qml" 2>/dev/null; then
    git -C "$REPO" show "$PREFIX_COMMIT:Panel.qml" > "$WORK/Panel.prefix.qml"
    build_panel_harness "$WORK/ipc-prefix" "$WORK/Panel.prefix.qml"
    start_harness "$WORK/ipc-prefix" "$WORK/ipc-prefix/qs.log"
    wait_for_ipc "$WORK/ipc-prefix" || true
    PREFIX_SURFACE="$IPC_SURFACE"
    stop_harness
    printf '%s\n' "$PREFIX_SURFACE" > "$WORK/ipc-prefix-surface"
    if [[ -z $PREFIX_SURFACE ]]; then
      printf '  FAIL control: the pre-fix panel never published its IPC target either\n'
      failures=$((failures + 1))
    else
      check_contains_file \
        "control: the pre-fix panel DOES publish the argv-taking import handler" \
        "$WORK/ipc-prefix-surface" "function importLink(link: string): string"
      check "control: and it would trip the no-parameter rule above" \
        bash -c 'grep -Eq "function[[:space:]]+[A-Za-z0-9_]+[[:space:]]*\([[:space:]]*[A-Za-z_]" "$1"' _ "$WORK/ipc-prefix-surface"
    fi
  else
    printf '  SKIP control: commit %s is not in this checkout, so the vulnerable panel cannot be replayed\n' \
      "${PREFIX_COMMIT:0:7}"
  fi

  # ---- the normal (UI) import path must still be wired up --------------------
  # The popup hands the pasted link to Service.importLink(), which is the only
  # importer that still exists. Its runtime proof is the big section above
  # (real Service.qml, credential on the child's stdin); this pins the glue that
  # removal of the IPC handler must not have touched.
  PANEL_CODE="$(grep -v '^[[:space:]]*//' "$PANEL" | tr -s '[:space:]' ' ')"
  check "the popup still routes the pasted link into Service.importLink()" \
    bash -c 'grep -Eq "v2ray\.importLink\([[:space:]]*text[[:space:]]*\)" <<<"$1"' _ "$PANEL_CODE"
fi

# ==================================================================== summary ===
echo
if (( failures == 0 )); then
  echo "panel import test: all checks passed"
else
  echo "panel import test: $failures check(s) FAILED"
fi
exit $(( failures > 0 ))

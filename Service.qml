import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Model.js" as Model

// =============================================================================
// Service — the brain of the v2ray Client plugin.
// =============================================================================
//
// This item owns ALL state and ALL process spawning. Panel.qml only draws what
// is here and calls these functions; it never runs a command itself. That split
// means there is exactly one place to look when something misbehaves.
//
// Everything it knows comes from one backend script, `bin/omarchy-v2ray`, which
// answers every subcommand with JSON. The script is invoked by absolute path
// (resolved from this file's own URL) because a plugin cannot rely on its own
// `bin/` directory being on the shell's PATH.
//
// THREADING / LIFETIME NOTES
// --------------------------
// A Quickshell `Process` is a short-lived child. That is fine for queries
// (`status`, `list`, `ping`) but would be fatal for the engine itself: killing
// the Process would kill the tunnel. So the engine is started by the script
// with `setsid`, fully detached, and this process only ever asks about it.
// See start_profile() in bin/omarchy-v2ray for the details.
//
// SECRETS TRAVEL ON STDIN, NEVER IN argv
// --------------------------------------
// An import payload contains the tunnel's credential: the VLESS/Vmess user UUID,
// or the Trojan/Shadowsocks password. A command line is readable by EVERY user
// on the machine for as long as the process lives — `ps -ww`,
// /proc/<pid>/cmdline and /proc/<pid>/environ need no privileges — so a
// credential must never be an argument, an environment variable, or a line in a
// log. The import payload therefore goes to the backend on the child's stdin,
// which is a pipe only these two processes hold. (The backend refuses an argv
// payload outright — see cmd_import in bin/omarchy-v2ray — and reads nothing
// from the environment, so the leak cannot come back by accident.)
//
// The same rule covers the clipboard: a share link *is* the credential once it
// carries the UUID, so it is written to wl-copy's stdin rather than handed to
// `bash -c "printf %s '…' | wl-copy"`, which would park it in bash's argv.
//
// Closing the write channel is what signals EOF to the reader, so the shape is:
// `stdinEnabled = true` before starting, `write(...)` in onStarted, and then
// `stdinEnabled = false` to close. It is the same pattern the bundled network
// panel uses to hand a Wi-Fi password to nmcli.
// =============================================================================

Item {
  id: root

  // Filled in by the shell from this widget's shell.json entry.
  property var settings: ({})

  // ---- engine / connection state (mirrors `omarchy-v2ray status`) ----------
  property bool installed: false        // is an xray/v2ray core on PATH?
  property string engine: ""            // "xray" or "v2ray"
  property bool running: false          // engine process alive
  property bool listening: false        // local proxy port accepting
  property string activeId: ""          // profile id currently connected
  property string activeName: ""        // its display name
  property int socksPort: 0             // live local SOCKS port
  property int httpPort: 0              // live local HTTP port
  property int uptimeSec: 0             // seconds since the tunnel came up
  property string autostartId: ""       // profile to auto-connect
  property string logTail: ""           // last engine log lines, for errors

  // ---- TUN mode (system-wide; same `status` reply) ------------------------
  // The TUN engine is a separate, privileged process. `status` merges it into
  // running/activeId/socksPort/... when it is up (see cmd_status), so
  // `connected` remains the single answer to "is the tunnel up". These fields
  // say which KIND of tunnel it is and whether the switch may be used at all.
  property bool tunActive: false        // is a TUN tunnel up?
  property string tunProfileId: ""      // profile the TUN engine was started with
  property string tunIface: ""          // the tun device it created
  property int tunSince: 0              // epoch the TUN tunnel came up
  property bool tunCanStart: false      // may the switch offer "on"?
  property string tunBlockedReason: ""  // why not, in words the user can act on
  property string tunLastError: ""      // the helper's last failure, if any
  // "tun" | "proxy" | "off". Kept separate from `connected` because the bar icon
  // has to tell a local proxy apart from a system-wide tunnel: both are "on",
  // and only one of them reroutes everything.
  property string mode: "off"

  // ---- imported profiles (mirrors `omarchy-v2ray list`) -------------------
  property var profiles: []

  // ---- transient UI state -------------------------------------------------
  property bool refreshing: false        // a status/list query is in flight
  property bool busy: false              // an action (start/stop/import) is in flight
  property string lastError: ""          // shown in red; cleared on next action
  // The engine's own words behind `lastError`. Kept SEPARATE because xray debug
  // lines are hundreds of characters long: lastError is short and always fits the
  // popup, this is the untruncated text behind the "copy details" button and is
  // what belongs in a bug report.
  property string lastErrorDetails: ""
  property string notice: ""             // shown dimmed; cleared on next action
  property string actionRowId: ""        // list row that should show a spinner
  // Which row currently has a latency probe running. Same idea as actionRowId
  // but for the ping path, which deliberately does NOT use actionProc (so a
  // probe can never block a connect click). The row renders a pulsing button
  // from this, which is the only feedback a probe has until it answers.
  property string pingingId: ""
  property var pings: ({})               // id -> ms (>=0) | -1 failed | 0 pending

  // Optimistic connection state so the switch reacts the instant you click,
  // instead of after the ~1s engine start. -1 means "just follow the real
  // state"; 0/1 means "a toggle is in flight and this is where we're heading".
  property int _pendingRunning: -1
  property bool _autostartChecked: false

  // True between launching a TUN action and the state actually moving. The
  // helper is detached and authenticates in the background, so the switch
  // pulses instead of flipping optimistically. A prompt that is never answered
  // produces no state change AND no error — and it is not harmless: cmd_tun_up
  // stops the user's proxy engine BEFORE pkexec, so they are left disconnected.
  // This flag is only the PULSE (it times out after 30s); the gate that keeps
  // connects away from the ports is `tunHandoffPending` below.
  property bool tunArming: false
  // A TUN hand-off that has not been confirmed yet. Outlives the pulse on
  // purpose: polkit can take minutes, and the ports must stay off-limits until
  // evidence arrives. proxy connect paths are gated on this, not on tunArming.
  property bool tunHandoffPending: false
  // How long the pulse waits. A property rather than a literal so the
  // state-machine test can drive the timeout in a second instead of waiting
  // half a minute for it.
  property int tunArmTimeoutMs: 30000
  // The hard cap on the gate. Longer than any plausible prompt, short enough
  // that a helper which died silently cannot block connects for the session.
  property int tunHandoffTimeoutMs: 120000
  // Set when the backend answered needsHelper: the privileged helper is missing
  // (or not root-owned), so the panel offers `installTun()` instead of a prompt
  // that cannot work. Not derived from `tunLastError`, because a missing helper
  // never runs, and therefore never writes an error file.
  property bool tunNeedsHelper: false
  property int _tunArmTarget: -1         // 1 = waiting for on, 0 = waiting for off
  // The helper's last failure as it stood when the current attempt was armed.
  // Arming may only end on an error that is NEWER than this: the helper deletes
  // `last-error` only after a SUCCESSFUL start, so on a machine with one past
  // failure the file stays non-empty through the whole retry, and "non-empty
  // means this attempt failed" would end the arming before authentication.
  property string _tunErrorAtArm: ""
  // Set once a status reply has shown something OTHER than the proxy engine as
  // the live connection — the engine stopped ("off") or TUN took over ("tun").
  // That is the wider reading the code uses: "Running again" must mean again, so
  // a status query already in flight when the TUN switch was pressed (still
  // reporting the old proxy engine) cannot drop the gate in the window it exists
  // for. Narrowing this to mode === "off" would also work today, but would make
  // the proxy-back signal dead during a stop hand-off, when "tun" is what the
  // replies actually say.
  property bool _tunSawProxyStopped: false
  // The previous tunCanStart, so "became startable" is a transition rather than
  // a state. The post-refusal status reply already says tunCanStart:true (it
  // talks about the engine, not the helper), and clearing the install offer on
  // every such reply would hide it the instant it appeared.
  property bool _tunCanStartPrev: false
  // The last tunLastError already painted. Keeping it separate is what lets the
  // red line be dismissed without status re-surfacing the same sentence on the
  // next refresh; a DIFFERENT failure still gets through.
  property string _tunErrorSeen: ""

  readonly property bool connected: _pendingRunning === -1 ? (running && listening)
                                                           : (_pendingRunning === 1)

  // A TUN START that has not been confirmed. This — not the generic hand-off
  // flag — is what gates the proxy connect paths. A hung STOP must not lock the
  // off switch for two minutes, and while TUN is up the backend already refuses
  // `start` itself ("TUN mode is on — turn it off from the TUN switch first"), so
  // the stop direction has a backstop the start direction does not.
  readonly property bool tunStartPending:
    (tunArming || tunHandoffPending) && _tunArmTarget === 1

  // Absolute path to the backend script, derived from this QML file's URL so
  // it works no matter where the plugin was installed.
  readonly property string scriptPath: {
    var url = Qt.resolvedUrl("bin/omarchy-v2ray").toString()
    if (url.indexOf("file://") === 0) url = url.substring(7)
    try {
      return decodeURIComponent(url)
    } catch (e) {
      return url
    }
  }

  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 30, 5, 3600)
  readonly property int socksPortSetting: intSetting("socksPort", 10808, 1024, 65535)
  readonly property int httpPortSetting: intSetting("httpPort", 10809, 1024, 65535)
  readonly property bool needsEngine: !installed

  // Set when the backend refused an action because the profile uses REALITY or
  // XHTTP, which only the AUR xray core implements. v2ray-core accepts those
  // settings silently and then just fails to connect, so this flag is what lets
  // the popup show "Install xray" instead of a useless "connection failed".
  property bool needsXray: false

  // Emitted after a successful import/remove so the panel can clear its input
  // field or move its cursor without polling.
  signal profileImported(string id)
  signal profileRemoved(string id)

  // ---------------------------------------------------------------------------
  // Settings helpers
  // ---------------------------------------------------------------------------
  // The shell does NOT merge manifest.json's `barWidget.defaults` into
  // `settings`; that object only seeds Omarchy's plugin settings form. Reading
  // every value through a fallback is therefore mandatory, not defensive.
  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    if (n < min) n = min
    if (n > max) n = max
    return n
  }

  // ---------------------------------------------------------------------------
  // Small helpers
  // ---------------------------------------------------------------------------
  function parseJson(text) {
    var s = String(text || "").trim()
    if (s === "") return null
    try {
      return JSON.parse(s)
    } catch (e) {
      return null
    }
  }

  function profileById(id) {
    for (var i = 0; i < profiles.length; i++) {
      if (String(profiles[i].id) === String(id)) return profiles[i]
    }
    return null
  }

  function pingFor(id) {
    var value = pings ? pings[id] : undefined
    return value === undefined ? null : value
  }

  function setPing(id, value) {
    // QML only re-evaluates bindings when the property identity changes, so a
    // shallow copy is the cheapest way to publish a new pings object.
    var next = {}
    for (var key in pings) next[key] = pings[key]
    next[id] = value
    pings = next
  }

  function proxyAddress() {
    if (!connected || socksPort <= 0) return ""
    return "socks5://127.0.0.1:" + socksPort
  }

  function statusLine() {
    if (!installed) return "No xray/v2ray engine installed"
    if (_pendingRunning === 1 && !connected) return "Connecting…"
    if (_pendingRunning === 0 && connected) return "Disconnecting…"
    // An unconfirmed TUN start is not "Disconnected": the proxy engine was
    // stopped and the tunnel may still come up. Saying so here is what keeps the
    // bar tooltip and the panel header honest while the switch is gated.
    if (tunStartPending && !connected) return "TUN starting — waiting for authorisation"
    if (connected) return "Connected · " + (Model.formatUptime(uptimeSec) || "just now")
    if (running) return "Engine starting…"
    if (profiles.length === 0) return "No servers yet — paste a link below"
    return "Disconnected"
  }

  // ---------------------------------------------------------------------------
  // Transient confirmation ("Copied to clipboard", "Added <server>")
  // ---------------------------------------------------------------------------
  // SEPARATE from `notice`, which is for messages that must stay put until the
  // situation changes (an install running in another window). `toast` is shown
  // INSTEAD of `notice` while it is on screen and then expires by itself, and
  // the panel renders it even when a red error line is also up — which matters,
  // because that is exactly when the user is clicking buttons.
  property string toast: ""

  Timer {
    id: toastTimer
    interval: 2400
    onTriggered: root.toast = ""
  }

  // The end of the PULSE, not of the hand-off. A successful launch is ended by
  // the next status reply, a refused one ends on its own; the case this exists
  // for is a prompt the user never answers — nobody is left to write a state
  // file OR an error, so without a timeout the switch would pulse (and refuse
  // clicks) for the rest of the session.
  //
  // It says what actually happened. cmd_tun_up stops the proxy engine before
  // pkexec, so "TUN did not change" understated it: the user is disconnected.
  Timer {
    id: tunArmTimer
    interval: root.tunArmTimeoutMs
    onTriggered: {
      if (!root.tunArming) return
      var stopping = root._tunArmTarget === 0
      root.endTunPulse()
      root.notice = stopping
        ? "TUN did not stop — check 'omarchy-v2ray tun-status'"
        : "The proxy connection was stopped and TUN is still unconfirmed — wait for it, or check 'omarchy-v2ray tun-status'"
    }
  }

  // The hard cap on the GATE. The pulse above gives up after 30s; a slow polkit
  // prompt can still be open then, and letting a connect through would put the
  // proxy engine back on 10808 exactly as the TUN helper tries to bind it. After
  // this the gate opens anyway, because a helper that never reported anything
  // must not block the panel for the rest of the session — and says so.
  Timer {
    id: tunHandoffTimer
    interval: root.tunHandoffTimeoutMs
    onTriggered: {
      if (!root.tunHandoffPending) return
      var what = root._tunArmTarget === 0 ? "TUN stop" : "TUN start"
      root.stopTunArming()
      root.notice = what + " never confirmed — check 'omarchy-v2ray tun-status'"
    }
  }

  function showToast(message) {
    toast = String(message)
    toastTimer.restart()
  }

  function clearMessages() {
    lastError = ""
    lastErrorDetails = ""
    notice = ""
    // A toast belongs to the interaction that produced it, so a reopened panel
    // must not inherit the last one either.
    toast = ""
    // The "wrong core" hint is about the *last* action; any new action
    // invalidates it, and leaving it on screen would nag after a successful
    // connect to a server that does not need xray at all.
    needsXray = false
    // The install offer belongs to the refusal that produced it. The backend's
    // `tunLastError` is deliberately NOT cleared here: it mirrors a file the
    // helper owns, and wiping it would only make the next refresh paint the
    // same sentence again.
    tunNeedsHelper = false
  }

  // ---------------------------------------------------------------------------
  // Queries
  // ---------------------------------------------------------------------------
  // Both queries are cheap (one bash process each) and run in parallel. A
  // refresh is skipped while one is already in flight so the 30s timer can
  // never pile up processes if the machine is busy.
  function refresh() {
    if (statusProc.running && listProc.running) return
    refreshing = true
    if (!statusProc.running) statusProc.running = true
    if (!listProc.running) listProc.running = true
  }

  function applyStatus(text, exitCode) {
    refreshing = false
    var res = parseJson(text)
    if (!res || res.ok !== true) {
      if (res) {
        lastError = String(res.error || "status failed")
      } else {
        var detail = String(_statusErr || "").trim()
        lastError = "the v2ray helper returned no JSON (exit " + exitCode + ")" +
          (detail === "" ? "" : ": " + detail)
      }
      return
    }
    installed = res.installed === true
    engine = String(res.engine || "")
    running = res.running === true
    listening = res.listening === true
    activeId = String(res.activeId || "")
    activeName = String(res.activeName || "")
    socksPort = res.socksPort ? parseInt(String(res.socksPort), 10) : 0
    httpPort = res.httpPort ? parseInt(String(res.httpPort), 10) : 0
    uptimeSec = parseInt(String(res.uptimeSec || 0), 10) || 0
    autostartId = String(res.autostartId || "")
    logTail = String(res.logTail || "")

    tunActive = res.tunActive === true
    tunProfileId = String(res.tunProfileId || "")
    tunIface = String(res.tunIface || "")
    tunSince = parseInt(String(res.tunSince || 0), 10) || 0
    tunCanStart = res.tunCanStart === true
    tunBlockedReason = String(res.tunBlockedReason || "")
    tunLastError = String(res.tunLastError || "")
    // `mode` is newer than the rest of the contract, so it is derived when an
    // older backend (a shell that has not been restarted since an update)
    // answers without it — the alternative would be painting a live TUN tunnel
    // as "off".
    mode = String(res.mode || (tunActive ? "tun"
                               : ((running && listening) ? "proxy" : "off")))

    // A TUN launch is asynchronous, so the switch waits for the state to move
    // rather than flipping on the click. The attempt ends ONLY on evidence
    // about THIS one: the state arrived, the helper reported something it had
    // not already said when the attempt began, or the proxy engine is running
    // again (the user reconnected explicitly, so the hand-off never happened).
    // A plain "error is non-empty" test is wrong here — see _tunErrorAtArm.
    //
    // The same evidence ends the PULSE and the GATE: the pulse can have timed
    // out while polkit was still open, so the gate cannot be a side effect of
    // the pulse ending.
    var tunMoved = _tunArmTarget !== -1 && tunActive === (_tunArmTarget === 1)
    var tunErrored = tunLastError !== "" && tunLastError !== _tunErrorAtArm
    // "Running AGAIN": only after this attempt has seen the proxy engine stop.
    // See _tunSawProxyStopped for the in-flight status reply this excludes.
    if (tunHandoffPending && mode !== "proxy") _tunSawProxyStopped = true
    var proxyRunning = tunHandoffPending && _tunSawProxyStopped
                        && mode === "proxy" && running
    if ((tunArming || tunHandoffPending) && (tunMoved || tunErrored || proxyRunning)) {
      stopTunArming()
    }

    // The helper's own words are the only account of a failed TUN start (nobody
    // is there to return JSON: it runs detached, as root, minutes later). Paint
    // them the first time they CHANGE, through the same red line — and the same
    // copy-details button — as every other failure.
    if (tunLastError !== "") {
      if (tunLastError !== _tunErrorSeen) {
        _tunErrorSeen = tunLastError
        lastError = tunLastError
        lastErrorDetails = tunLastError
      }
    } else {
      // The helper deletes its error file on a successful start, so an empty
      // value is the reset: the same failure may be reported again later.
      _tunErrorSeen = ""
    }

    // The install offer is about the LAST needsHelper refusal. It is cleared by
    // a new action (clearMessages) and when TUN becomes startable again — at
    // which point either the helper was installed or the tunnel came down, and
    // in both cases the row has served its purpose. The transition matters: the
    // status reply that follows the refusal itself carries tunCanStart:true.
    if (tunCanStart && !_tunCanStartPrev) tunNeedsHelper = false
    _tunCanStartPrev = tunCanStart

    // The real state has caught up with any optimistic guess.
    if (running === (_pendingRunning === 1) && listening === running) _pendingRunning = -1
    maybeAutostart()
  }

  function applyList(text, exitCode) {
    var res = parseJson(text)
    if (!res || !(res instanceof Array)) {
      // A list failure must not wipe what we already showed; the status query
      // is the one that reports errors to the user.
      return
    }
    profiles = res
  }

  // Connect the autostart profile once, on the first successful status read.
  // Doing it here (rather than in Component.onCompleted) means we only act
  // after we know the engine state, so we never double-start a live tunnel.
  function maybeAutostart() {
    if (_autostartChecked) return
    _autostartChecked = true
    // Wait until the install check has actually reported a core on PATH;
    // otherwise a user who removed xray would get a spurious error at login.
    if (!installed) return
    if (running || autostartId === "") return
    connect(autostartId)
  }

  // ---------------------------------------------------------------------------
  // Actions
  // ---------------------------------------------------------------------------
  // runAction(command, rowId, stdinPayload)
  //
  // Runs one backend action. `stdinPayload` is optional, and is written to the
  // child's stdin before that pipe is closed. Only the import path passes one:
  // its payload is a secret, and stdin is the one channel a process does not
  // publish to the rest of the machine.
  //
  // Returns true when the child was started, false when another action is still
  // in flight. Callers that arm something BEFORE waiting for an async answer
  // (the TUN switch) must not arm on false: nothing was launched, so nothing
  // will ever arrive to clear it.
  function runAction(command, rowId, stdinPayload) {
    if (actionProc.running) return false
    clearMessages()
    busy = true
    actionRowId = String(rowId || "")
    // Which backend action this is, kept for onExited: the rows show a spinner
    // from `actionRowId`, but only a profile edit should toast "Updated <row>".
    // A TUN launch passes the profile id as well (so the row does show it is
    // busy) and must not claim the profile was changed.
    _actionVerb = command.length > 2 ? String(command[2]) : ""
    // Park the payload where onStarted can pick it up; it is dropped again the
    // moment it has been written, so the secret is not kept in a property.
    _actionStdin = (stdinPayload === undefined || stdinPayload === null)
      ? ""
      : String(stdinPayload)
    // Decided BEFORE `running`: the flag is what makes the child start with a
    // writable stdin at all. Non-import actions leave it false.
    actionProc.stdinEnabled = _actionStdin !== ""
    actionProc.command = command
    actionProc.running = true
    return true
  }

  // The message every proxy-connect refusal uses while a TUN launch is waiting
  // for polkit. The gate itself sits in connect() and toggleConnection(), which
  // between them are the ONLY ways into `start`: a row click and the cursor's
  // Enter reach connect() directly, the bar's right-click and the `t` key reach
  // toggleConnection(). `busy` cannot stand in for this — it tracks the
  // launcher, which exits in milliseconds — and the backend cannot refuse yet
  // either (tun_is_active is still false), so without the gate a connect click
  // would start a proxy engine on the ports the TUN engine is about to claim.
  function tunStartingMessage() {
    return "TUN is starting — waiting for authorisation"
  }

  function connect(id) {
    if (!id) return
    // The gate outlives the pulse: a slow prompt is exactly when `busy` is false,
    // the switch looks idle and the backend still has nothing to refuse.
    // Only a TUN START is gated — see tunStartPending.
    if (tunStartPending) {
      lastError = tunStartingMessage()
      return
    }
    _pendingRunning = 1
    runAction(["bash", scriptPath, "start", String(id)], String(id))
  }

  function disconnect() {
    // While TUN is up, the thing carrying traffic is not this proxy engine:
    // `stop` would kill nothing, the switch would flip off optimistically and
    // then flip back at the next status refresh. "Disconnect" means the tunnel
    // goes away, so it takes the privileged route when that is what is running.
    if (tunActive) {
      tunDown()
      return
    }
    _pendingRunning = 0
    runAction(["bash", scriptPath, "stop"], "")
  }

  function toggleConnection() {
    // Same window as connect(): the switch looks idle long before polkit has
    // answered, so refuse here too rather than letting the connect path below
    // start an engine that would fight the one TUN is about to start.
    if (tunStartPending) {
      lastError = tunStartingMessage()
      return
    }
    if (connected) {
      disconnect()
      return
    }
    // Reconnect what we were on, else the autostart pick, else the only
    // profile — a single-server setup should need no choices.
    var target = activeId || autostartId
    if (!target && profiles.length === 1) target = profiles[0].id
    if (!target) {
      lastError = "Import a server first"
      return
    }
    connect(target)
  }

  function removeProfile(id) {
    setPing(String(id), null)
    runAction(["bash", scriptPath, "remove", String(id)], String(id))
  }

  function pingProfile(id) {
    if (pingProc.running || !id) return
    setPing(String(id), 0)   // 0 == "measuring", drawn as an ellipsis
    pingProc.command = ["bash", scriptPath, "ping", String(id)]
    pingProc.pingId = String(id)
    pingingId = String(id)
    pingProc.running = true
  }

  function setAutostart(id) {
    runAction(["bash", scriptPath, "autostart", String(id)], String(id))
  }

  // ---------------------------------------------------------------------------
  // TUN mode (system-wide)
  // ---------------------------------------------------------------------------
  // The privileged half runs detached behind a polkit prompt, so these calls
  // return as soon as the launcher has handed over — `runAction`'s `busy` clears
  // on the child's exit, which is milliseconds later, NOT when the password is
  // accepted. Two windows therefore outlive the call:
  //
  //   tunArming          the switch pulses and refuses its own clicks (30s)
  //   tunHandoffPending  proxy connects stay refused (120s)
  //
  // They share one target and one error snapshot, because they are waiting for
  // the same evidence; only their patience differs.
  //
  // The profile id still goes to runAction as the row id: the list row shows its
  // spinner for the moment the hand-off takes, which is the only feedback before
  // polkit paints its own dialog.

  function beginTunHandoff(target) {
    _tunArmTarget = target
    // Snapshot the helper's previous failure BEFORE the attempt starts; see the
    // declaration of _tunErrorAtArm for why an empty test is not enough.
    _tunErrorAtArm = tunLastError
    // Nothing has been observed about this attempt yet.
    _tunSawProxyStopped = false
    tunArming = true
    tunHandoffPending = true
    tunArmTimer.restart()
    tunHandoffTimer.restart()
  }

  // The pulse only: the gate and its evidence stay for the slower window.
  function endTunPulse() {
    tunArming = false
    tunArmTimer.stop()
  }

  // The whole attempt is over — confirmed, refused, or given up on.
  function stopTunArming() {
    endTunPulse()
    tunHandoffPending = false
    _tunArmTarget = -1
    _tunErrorAtArm = ""
    _tunSawProxyStopped = false
    tunHandoffTimer.stop()
  }

  // Another action has the one shared action process. Callers used to return
  // silently here, which looked like a dead button.
  function actionBusyMessage() {
    return "Another action is still running — try again in a moment"
  }

  function tunWaitMessage() {
    return "TUN is still waiting for authorisation — check 'omarchy-v2ray tun-status'"
  }

  function tunUp(id) {
    if (!id) return
    // One authorisation at a time. The gate outlives the pulse, so a prompt that
    // has been open for a minute still blocks a second pkexec (which the
    // helper's own lock would refuse only after another password prompt).
    if (tunHandoffPending) {
      lastError = tunWaitMessage()
      return
    }
    if (tunArming) return
    // Arm only when the launcher really started. runAction refuses while another
    // action is in flight, and arming on a refused call would pulse "Waiting for
    // authorisation…" (and swallow every click) for 30 s after nothing happened.
    if (!runAction(["bash", scriptPath, "tun-up", String(id)], id)) {
      lastError = actionBusyMessage()
      return
    }
    beginTunHandoff(1)
  }

  function tunDown() {
    // Deliberately NOT gated on the pending hand-off: while a stop is
    // unconfirmed, turning the tunnel off again must stay possible. The helper's
    // acquire_teardown_lock serialises a second teardown, so a second click is
    // safe. A START in flight is different — a down then would race it.
    if (tunStartPending) {
      lastError = tunWaitMessage()
      return
    }
    // No `if (tunArming) return` here: during a STOP pulse the switch must keep
    // working, and the launcher has already exited by the time a human can
    // click. A START pulse was caught above.
    // Same rule as tunUp: arm only once the launcher has actually started.
    if (!runAction(["bash", scriptPath, "tun-down"], "")) {
      lastError = actionBusyMessage()
      return
    }
    beginTunHandoff(0)
  }

  // What the panel's TUN switch and the `u` shortcut call. Turning TUN ON needs
  // a profile: the same "last one, else the autostart pick, else the only one"
  // rule the proxy switch uses, so a single-server setup needs no choices.
  function tunToggle() {
    // Off first, and without the pending gate: if TUN is still up (a stop the
    // prompt never answered), the switch must keep working.
    if (tunActive) {
      tunDown()
      return
    }
    if (tunStartPending) {
      lastError = tunWaitMessage()
      return
    }
    if (tunArming) return
    if (tunHandoffPending) {
      // TUN is down but a STOP is still unconfirmed: do not start a second
      // helper on top of it.
      lastError = tunWaitMessage()
      return
    }
    if (!tunCanStart) {
      clearMessages()
      lastError = tunBlockedReason !== ""
        ? tunBlockedReason
        : "TUN mode is not available on this machine"
      return
    }
    var target = activeId || autostartId
    if (!target && profiles.length === 1) target = profiles[0].id
    if (!target) {
      clearMessages()
      lastError = "Import a server first"
      return
    }
    tunUp(target)
  }

  // ---------------------------------------------------------------------------
  // Import — the feature this plugin exists for.
  // ---------------------------------------------------------------------------
  // 1. Parse the pasted link here, in JavaScript, where string handling is
  //    pleasant and mistakes produce a friendly message.
  // 2. Build the complete engine config + metadata.
  // 3. Hand the whole thing to the backend, which only validates and writes.
  //    Over stdin, because the payload is the credential (see the header note).
  //
  // Returns true when the link was accepted (so the panel knows whether to
  // clear the text field).
  function importLink(link) {
    clearMessages()
    var parsed = Model.parseLink(link)
    if (!parsed.ok) {
      lastError = String(parsed.error || "Could not read that link")
      return false
    }

    var socks = socksPortSetting
    var http = httpPortSetting
    if (socks === http) {
      lastError = "The SOCKS and HTTP ports must differ (settings: " + socks + " / " + http + ")"
      return false
    }

    var payload = Model.buildImportPayload(parsed.profile, {
      socksPort: socks,
      httpPort: http,
      // Seconds, matching what `date +%s` writes, so the backend can sort
      // profiles by age without knowing about JavaScript milliseconds.
      now: Math.floor(Date.now() / 1000)
    })
    if (!payload) {
      lastError = "Could not build an engine config for that link"
      return false
    }

    // Note the third argument: the JSON travels on the child's stdin, NOT in
    // its command list. As an argument it would be visible to every user on the
    // machine through /proc for the whole import.
    runAction(["bash", scriptPath, "import"], String(payload.id), JSON.stringify(payload))
    importingId = String(payload.id)
    importingName = String(parsed.profile.name || parsed.profile.host)
    return true
  }

  property string importingId: ""
  property string importingName: ""

  // ---------------------------------------------------------------------------
  // Copy / engine install / reveal
  // ---------------------------------------------------------------------------
  function copyToClipboard(value) {
    var text = String(value || "")
    if (text === "") return
    // The text goes to wl-copy on stdin, never in an argument: what gets copied
    // here is often a profile's share link, which carries the UUID itself, and
    // `bash -c "printf %s '<link>' | wl-copy"` publishes that to every user on
    // the machine through /proc while it runs. wl-copy copies stdin verbatim, so
    // there is also no trailing newline to become part of the next paste.
    if (clipProc.running) clipProc.running = false    // supersede an older copy
    _clipText = text
    clipProc.running = true
    // Tell the user the click landed. wl-copy is silent — no window, no sound —
    // so without this a copy is indistinguishable from a dead button. The row
    // button ALSO swaps its glyph for a check mark; two signals on purpose.
    showToast("Copied to clipboard")
  }

  function copyLink(id) {
    var profile = profileById(id)
    if (!profile) return
    copyToClipboard(String(profile.link || ""))
  }

  function copyProxyAddress() {
    copyToClipboard(proxyAddress())
  }

  // The proxy only covers apps that are told to use it (it is NOT system-wide),
  // which is the single most confusing part of this plugin: the tunnel is up, the
  // bar says ON, and the browser still shows the real IP because it was never
  // pointed at 127.0.0.1. This copies the shell one-liner that turns the proxy on
  // for every programme started from that terminal, so there is something
  // concrete to paste instead of an explanation to follow.
  function copyProxyEnvironment() {
    if (!connected || socksPort <= 0) return
    copyToClipboard("export all_proxy=socks5h://127.0.0.1:" + socksPort)
  }

  // Copy the full, untruncated failure text. Long-pressing the red line is not
  // discoverable, and a truncated line is useless in a bug report.
  function copyErrorDetails() {
    var text = lastErrorDetails !== "" ? lastErrorDetails : lastError
    copyToClipboard(text)
  }

  // Opens a floating terminal that installs the core. pacman needs a password,
  // and the shell process cannot prompt for one, so this is the only correct
  // way to offer the install from inside a bar widget.
  function installEngine() {
    clearMessages()
    Quickshell.execDetached(["bash", scriptPath, "install-engine"])
    notice = "Installing v2ray in a terminal window — the bar icon updates when it finishes"
  }

  // The optional core. Only needed for REALITY/XHTTP servers; on every other
  // profile v2ray is enough. Same floating-terminal trick as installEngine,
  // because an AUR helper needs a password too.
  function installXray() {
    clearMessages()
    Quickshell.execDetached(["bash", scriptPath, "install-xray"])
    notice = "Installing xray in a terminal window — the bar icon updates when it finishes"
  }

  // The privileged TUN helper. Same reason as the two above: `install-tun` runs
  // pkexec from a terminal the user can watch, and the shell process itself can
  // never prompt. Nothing is polled afterwards — the terminal IS the progress
  // report, and the switch works the next time it is pressed.
  function installTun() {
    clearMessages()
    Quickshell.execDetached(["bash", scriptPath, "install-tun"])
    showToast("Installing the TUN helper…")
    notice = "Installing the TUN helper in a terminal window — the TUN switch works once it finishes"
  }

  function revealConfig() {
    Quickshell.execDetached(["bash", scriptPath, "reveal"])
  }

  // ---------------------------------------------------------------------------
  // Processes
  // ---------------------------------------------------------------------------

  // The refresh timer. Triggered on start so the icon is correct on login.
  Timer {
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // ---- status ----
  // Tailscale's first-party plugin stores collector output in a property via
  // onStreamFinished and then reads that property in onExited. We do the same:
  // it removes any doubt about whether `.text` is populated when onExited runs.
  property string _statusOut: ""
  property string _statusErr: ""

  Process {
    id: statusProc
    running: false
    command: ["bash", root.scriptPath, "status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root._statusOut = text
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root._statusErr = text
    }
    onExited: function(exitCode) {
      root.applyStatus(root._statusOut, exitCode)
    }
  }

  // ---- list ----
  Process {
    id: listProc
    running: false
    command: ["bash", root.scriptPath, "list"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root._listOut = text
    }
    onExited: function(exitCode) {
      root.applyList(root._listOut, exitCode)
    }
  }
  property string _listOut: ""

  // ---- action (import / start / stop / remove / autostart) ----
  // One shared process for every mutating call: they are all "run, wait, parse
  // one JSON object, refresh", and serialising them keeps state predictable.
  property string _actionOut: ""
  property string _actionErr: ""
  // Which subcommand this action is (command[2]), so onExited can tell a
  // profile edit from a TUN launch. See runAction().
  property string _actionVerb: ""
  // Import payload waiting to be written to the child's stdin. Empty for every
  // other action, and always cleared once written. See runAction().
  property string _actionStdin: ""

  Process {
    id: actionProc
    running: false
    command: []
    // Off by default (nothing else we run wants stdin); runAction() turns it on
    // for an import only.
    stdinEnabled: false
    onStarted: {
      // The import payload goes over the pipe, never argv — a command line is
      // world-readable while the process runs. Writing first and closing after
      // is the safe order: the queued bytes are flushed before the channel
      // shuts, and closing is what tells the backend that the JSON is complete
      // (it reads until EOF, with its own timeout as a backstop).
      if (root._actionStdin !== "") {
        actionProc.write(root._actionStdin)
        root._actionStdin = ""
      }
      actionProc.stdinEnabled = false
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root._actionOut = text
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root._actionErr = text
    }
    onExited: function(exitCode) {
      var res = root.parseJson(root._actionOut)
      var wasImport = root.importingId !== ""
      var failedRow = root.actionRowId
      var verb = root._actionVerb
      // A TUN launch is asynchronous: a successful one keeps pulsing until
      // status sees the state move, but a refused one has nothing to wait for.
      var wasTun = verb === "tun-up" || verb === "tun-down"

      root.busy = false
      root.actionRowId = ""
      root._pendingRunning = -1
      // Belt and braces: whatever happened, do not keep a copy of the payload
      // in a property or a half-open write channel for the next action to see.
      root._actionStdin = ""
      actionProc.stdinEnabled = false

      if (res && res.ok === true) {
        if (wasImport) {
          root.showToast("Added " + (root.importingName || "server"))
          root.profileImported(root.importingId)
          // The import succeeded — the profile is saved and listed — but the
          // backend already knows the installed core cannot run it. Saying so
          // now is far kinder than a "connection failed" later.
          if (res.needsXray === true) {
            root.needsXray = true
            root.lastError = "That server uses " + String(res.needsXrayReason || "REALITY") +
              ", which v2ray cannot do — install xray from the AUR."
          }
        } else if (failedRow !== "" && !wasTun) {
          // Only profile edits toast here. A TUN launch carries the profile id
          // too (for the row spinner) but changed nothing about that profile.
          root.showToast("Updated " + failedRow)
        }
        root.lastError = ""
      } else if (res && res.ok === false) {
        root.lastError = String(res.error || "The v2ray helper refused that action")
        root.lastErrorDetails = String(res.detailFull || res.detail || res.log || "")
        // A missing engine is actionable, so say what to do about it.
        if (res.needsEngine === true) {
          root.installed = false
          root.lastError = root.lastError + " — use the Install v2ray button below"
        } else if (res.needsXray === true) {
          // The backend already spelled out the fix; we only turn the flag on so
          // the panel can offer a one-click "Install xray" button beside it.
          root.needsXray = true
        } else if (res.needsHelper === true) {
          // No password prompt was attempted at all. The panel turns this into
          // an "install the helper" button rather than failing silently.
          root.tunNeedsHelper = true
        }
      } else {
        var detail = String(root._actionErr || "").trim()
        root.lastError = "The v2ray helper failed (exit " + exitCode + ")" +
          (detail === "" ? "" : ": " + detail)
        root.lastErrorDetails = detail
      }

      // A launched TUN action keeps arming until status sees the state move; a
      // REFUSED one has nothing to wait for, and that includes needsHelper (the
      // helper was never executed, so no state file and no error file will ever
      // arrive for this attempt).
      if (wasTun && !(res && res.ok === true)) root.stopTunArming()

      root.importingId = ""
      root.importingName = ""
      root._actionVerb = ""
      root.refresh()
    }
  }

  // ---- ping ----
  // Separate from actionProc so latency probes never block a connect click.
  property string _pingOut: ""
  property string _pingErr: ""

  Process {
    id: pingProc
    running: false
    command: []
    property string pingId: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root._pingOut = text
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root._pingErr = text
    }
    onExited: function(exitCode) {
      var res = root.parseJson(root._pingOut)
      if (res && res.ok === true && res.ms !== undefined) {
        root.setPing(pingProc.pingId, parseInt(String(res.ms), 10))
      } else {
        // -1 is the panel's "unreachable" marker; the reason lands in the
        // notice line so a failed probe never looks like a successful one.
        root.setPing(pingProc.pingId, -1)
        if (res && res.error) {
          root.lastError = String(res.error) + (res.detail ? " (" + String(res.detail) + ")" : "")
          // `detail` arrives already clamped by the backend; `detailFull` is the
          // whole probe log, which is what "copy details" hands over.
          root.lastErrorDetails = String(res.detailFull || res.detail || "")
        } else {
          var pingDetail = String(root._pingErr || "").trim()
          root.lastError = "The latency probe failed" + (pingDetail === "" ? "" : ": " + pingDetail)
          root.lastErrorDetails = pingDetail
        }
      }
      pingProc.pingId = ""
      root.pingingId = ""
    }
  }

  // ---- clipboard ----
  // The sink behind copyToClipboard(). Text arrives on stdin so that a share
  // link — i.e. a credential — never lands in a command line; this is the whole
  // reason it is a Process here instead of a `bash -c` one-liner.
  property string _clipText: ""

  Process {
    id: clipProc
    running: false
    command: ["wl-copy"]
    stdinEnabled: true
    onStarted: {
      clipProc.write(root._clipText)
      root._clipText = ""
      clipProc.stdinEnabled = false   // EOF: wl-copy takes the clipboard now
    }
    onExited: function(exitCode) {
      root._clipText = ""
      clipProc.stdinEnabled = true    // re-arm for the next copy
    }
  }
}

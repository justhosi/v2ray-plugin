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

  readonly property bool connected: _pendingRunning === -1 ? (running && listening)
                                                           : (_pendingRunning === 1)

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
  function runAction(command, rowId, stdinPayload) {
    if (actionProc.running) return
    clearMessages()
    busy = true
    actionRowId = String(rowId || "")
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
  }

  function connect(id) {
    if (!id) return
    _pendingRunning = 1
    runAction(["bash", scriptPath, "start", String(id)], String(id))
  }

  function disconnect() {
    _pendingRunning = 0
    runAction(["bash", scriptPath, "stop"], "")
  }

  function toggleConnection() {
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
        } else if (failedRow !== "") {
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
        }
      } else {
        var detail = String(root._actionErr || "").trim()
        root.lastError = "The v2ray helper failed (exit " + exitCode + ")" +
          (detail === "" ? "" : ": " + detail)
        root.lastErrorDetails = detail
      }

      root.importingId = ""
      root.importingName = ""
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

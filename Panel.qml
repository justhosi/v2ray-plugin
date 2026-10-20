import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// =============================================================================
// Panel — the bar button plus the popup you paste a server link into.
// =============================================================================
//
// Interaction contract (matches every other Omarchy bar widget, so it feels
// native rather than invented):
//
//   left click on the icon     open the popup
//   right click on the icon    toggle the tunnel
//   middle click on the icon   refresh state
//
//   left click on a row        connect (or disconnect if it is connected)
//   right click on a row       copy that server's original share link
//   the three row buttons      ping · copy link · delete (click twice)
//   the TUN switch             system-wide tunnel (one polkit prompt)
//
//   typing in the field        types; Enter imports the link
//   Escape                     close
//   Tab                        leave the field and drive the list by keyboard
//   Up/Down, Enter             move and activate the row cursor
//   t / u / r / p / c          toggle · TUN · refresh · ping · copy
//
// All state and all process spawning live in Service.qml. This file only draws
// and forwards intent, which is why it has no Process items of its own except
// the tiny clipboard/exec helpers inside Service.
// =============================================================================

Panel {
  id: root

  moduleName: "community.v2ray-client"
  ipcTarget: "community.v2ray-client"
  // The base Panel installs a minimal open/close IpcHandler; we replace it
  // below with one that also exposes refresh and connect. There is deliberately
  // no import entry point — see the note inside IpcHandler.
  manageIpc: false

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // ---- panel-local state ---------------------------------------------------
  property int cursorIndex: 0
  property bool cursorActive: false          // is the list keyboard-driven?
  property string pendingRemoveId: ""        // armed row, awaiting a 2nd click

  // ---- click feedback -------------------------------------------------------
  // A button that does not visibly change when pressed reads as broken, and
  // every action in this panel is either silent (copy) or slow (a latency
  // probe). `flashKey` therefore holds "<action>:<profile id>" for the button
  // that was just pressed, and the button whose key matches swaps its glyph for
  // a check mark until the timer clears the key again. One timer for the whole
  // panel, so a burst of clicks can never stack timers.
  property string flashKey: ""

  Timer {
    id: flashTimer
    interval: 1300
    onTriggered: root.flashKey = ""
  }

  function flash(key) {
    flashKey = String(key)
    flashTimer.restart()
  }

  // ---- theme ---------------------------------------------------------------
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color barIconColor: v2ray.connected ? barForeground : Qt.darker(barForeground, 1.6)
  readonly property color iconColor: v2ray.connected ? foreground : dim
  readonly property color hoverFill: Style.hoverFillFor(foreground, Color.accent)
  readonly property color selectedFill: Style.selectedFillFor(foreground, Color.accent)
  readonly property int rowCount: v2ray.profiles.length

  // ---------------------------------------------------------------------------
  // List cursor
  // ---------------------------------------------------------------------------
  function clampCursor() {
    if (rowCount === 0) {
      cursorIndex = 0
      return
    }
    cursorIndex = Math.max(0, Math.min(cursorIndex, rowCount - 1))
  }

  function moveCursor(delta) {
    if (rowCount === 0) return
    cursorActive = true
    pendingRemoveId = ""
    clampCursor()
    cursorIndex = Math.max(0, Math.min(cursorIndex + delta, rowCount - 1))
    scrollCursorIntoView()
  }

  // Keep the highlighted row inside the visible area. The list is short in
  // practice, but with a dozen servers the cursor would otherwise walk off the
  // bottom of the popup with no visual feedback.
  function scrollCursorIntoView() {
    var item = profileRepeater.itemAt(cursorIndex)
    if (!item) return
    var top = item.y
    var bottom = item.y + item.height
    if (top < panelFlick.contentY) {
      panelFlick.contentY = top
    } else if (bottom > panelFlick.contentY + panelFlick.height) {
      panelFlick.contentY = bottom - panelFlick.height
    }
  }

  function cursorProfile() {
    if (rowCount === 0) return null
    return v2ray.profiles[Math.max(0, Math.min(cursorIndex, rowCount - 1))]
  }

  function activateCursor() {
    var profile = cursorProfile()
    if (!profile) return
    if (v2ray.connected && String(v2ray.activeId) === String(profile.id)) v2ray.disconnect()
    else v2ray.connect(profile.id)
  }

  function pingCursor() {
    var profile = cursorProfile()
    if (profile) v2ray.pingProfile(profile.id)
  }

  function copyCursorLink() {
    var profile = cursorProfile()
    if (profile) v2ray.copyLink(profile.id)
  }

  // ---------------------------------------------------------------------------
  // TUN (system-wide) — the one line under the switch.
  // ---------------------------------------------------------------------------
  // Ordered by what the user can act on: a move in flight beats everything (the
  // switch is pulsing, and this is why), then the live tunnel, then the reason
  // the switch is disabled, then the offer.
  function tunDetail() {
    // `tunArming` is only the 30s pulse. The attempt itself can still be
    // outstanding for up to 120s after that (see tunStartPending), and the panel
    // must not look idle in that window — every connect click is refused.
    if (v2ray.tunArming) return "Waiting for authorisation…"
    if (v2ray.tunHandoffPending) {
      return v2ray.tunStartPending
        ? "Still waiting for authorisation — check 'omarchy-v2ray tun-status'"
        : "Stopping TUN — waiting for authorisation"
    }
    if (v2ray.tunActive) {
      return "All traffic is tunnelled via " + (v2ray.tunIface || "the tun device") +
             ". Turn off to restore normal routing."
    }
    if (!v2ray.tunCanStart) {
      return v2ray.tunBlockedReason !== ""
        ? v2ray.tunBlockedReason
        : "TUN mode is not available on this machine."
    }
    return "Routes all traffic through the tunnel. Needs the privileged helper and the xray core."
  }

  // The backend answers needsHelper when the installed helper is missing or
  // unsafe to run, and never asks for a password in that case. ONLY that answer
  // drives the row: matching "install-tun" inside any helper error made the row
  // sticky, because the error file survives a successful retry's start-up until
  // the helper deletes it.
  readonly property bool tunHelperMissing: v2ray.tunNeedsHelper

  // Delete via the keyboard needs the same two-step guard as the mouse, so a
  // stray Delete keypress cannot silently drop a server.
  function deleteCursor() {
    var profile = cursorProfile()
    if (!profile) return
    if (pendingRemoveId === String(profile.id)) {
      pendingRemoveId = ""
      v2ray.removeProfile(profile.id)
    } else {
      pendingRemoveId = String(profile.id)
      v2ray.notice = "Press Delete again to remove " + String(profile.name || "this server")
    }
  }

  // ---------------------------------------------------------------------------
  // Import
  // ---------------------------------------------------------------------------
  // Service.importLink() parses the link and only returns true if it was
  // accepted, so a bad paste keeps the text in the field for editing.
  function submitLink() {
    var text = String(linkField.text || "")
    if (text === "") {
      v2ray.lastError = "Paste a server link first"
      return
    }
    if (v2ray.importLink(text)) {
      linkField.text = ""
      pendingRemoveId = ""
      clampCursor()
    }
  }

  // ---------------------------------------------------------------------------
  // Service + lifecycle
  // ---------------------------------------------------------------------------
  Service {
    id: v2ray
    settings: root.settings
  }

  Connections {
    target: v2ray
    function onProfilesChanged() { root.clampCursor() }
    function onProfileImported(id) { root.cursorIndex = 0 }
  }

  onOpenedChanged: if (opened) {
    // Every opening is a fresh look: drop the previous error, notice and toast.
    // Without this the red line stayed on screen for the rest of the session —
    // it is only cleared by a *new* action, and closing and reopening the popup
    // is not one.
    v2ray.clearMessages()
    v2ray.refresh()
    root.pendingRemoveId = ""
    root.clampCursor()
    // Focus the field: pasting a link is what this panel is for. Done through
    // callLater so it lands after the layer surface has mapped and the panel
    // has done its own focus priming.
    Qt.callLater(function() { if (root.opened) linkField.forceActiveFocus() })
  }

  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { v2ray.refresh(); return "ok" }
    function connection(): string { v2ray.toggleConnection(); return "ok" }
    function status(): string { return v2ray.statusLine() }

    // THERE IS DELIBERATELY NO IMPORT FUNCTION ON THIS INTERFACE.
    //
    // `qs ipc call <target> <function> <arguments…>` delivers every argument as
    // a positional string on the CALLER's command line; Quickshell's IPC has no
    // stdin channel to hand it over instead (checked against Quickshell 0.3.1:
    // a literal `-` is passed through as text, not read from stdin). A command
    // line is readable by every user on the machine for as long as the process
    // lives (`ps -ww`, /proc/<pid>/cmdline need no privileges) and is kept in
    // the shell history of whoever typed it.
    //
    // An import is the one action whose argument would BE the credential — the
    // share link carries the VLESS/Vmess UUID or the Trojan/Shadowsocks
    // password — so a public import handler could only ever be the argv leak
    // this plugin refuses everywhere else (see cmd_import in bin/omarchy-v2ray
    // and the header of Service.qml). It was removed rather than re-plumbed,
    // because there is no safe channel to re-plumb it through.
    //
    // Every function above is argument-free for the same reason: one rule, "no
    // credential may ride in a command line", covers the whole target. The
    // normal way in is the popup — the pasted link stays a QML string, and
    // Service.importLink() writes the built payload to the backend's stdin.
  }

  // ---------------------------------------------------------------------------
  // The bar button
  // ---------------------------------------------------------------------------
  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: v2ray.statusLine()
    iconComponent: Component {
      Item {
        V2rayShield {
          anchors.centerIn: parent
          iconSize: Style.space(11)
          color: root.barIconColor
          badgeColor: root.urgent
          active: v2ray.connected
          busy: v2ray.busy
          crossed: !v2ray.connected && !v2ray.busy
          warning: !v2ray.installed
          // A local proxy and a system-wide tunnel are both "on", so the bar
          // needs the second, quieter signal to tell them apart.
          mode: v2ray.mode
        }
      }
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) v2ray.toggleConnection()
      else if (buttonCode === Qt.MiddleButton) v2ray.refresh()
      else root.toggle()
    }
  }

  // ---------------------------------------------------------------------------
  // The popup
  // ---------------------------------------------------------------------------
  KeyboardPanel {
    id: panelWindow
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panelWindow.fittedContentWidth(Style.space(400))
    contentHeight: panelWindow.fittedContentHeight(content.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // While the text field has focus every key belongs to it, including
      // Escape and Tab (which the field handles itself below).
      blocked: linkField.activeFocus
      onMoveRequested: function(dx, dy) { root.moveCursor(dy) }
      onActivateRequested: root.activateCursor()
      onCloseRequested: root.close()
      onDeleteRequested: root.deleteCursor()
      onTextKey: function(t) {
        if (t === "t" || t === "T") v2ray.toggleConnection()
        else if (t === "u" || t === "U") v2ray.tunToggle()
        else if (t === "r" || t === "R") v2ray.refresh()
        else if (t === "p" || t === "P") root.pingCursor()
        else if (t === "c" || t === "C") root.copyCursorLink()
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: content.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: content
          width: panelFlick.width
          spacing: Style.space(12)

          // ---- header ------------------------------------------------------
          PanelHero {
            id: hero
            width: parent.width
            title: v2ray.connected ? (v2ray.activeName || "v2ray Client") : "v2ray Client"
            detail: v2ray.installed ? (v2ray.connected ? "ON" : "OFF") : ""
            meta: v2ray.statusLine()
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconOpacity: v2ray.connected ? 1.0 : 0.55
            iconComponent: Component {
              V2rayShield {
                iconSize: Style.font.display
                color: root.iconColor
                badgeColor: root.urgent
                active: v2ray.connected
                busy: v2ray.busy
                crossed: !v2ray.connected && !v2ray.busy
                warning: !v2ray.installed
                mode: v2ray.mode
              }
            }
            trailingControl: Component {
              // NOTE: inside a Component loaded by PanelHero, the id `root`
              // resolves to PanelHero itself, not to this file's root. Reach
              // panel state through ids declared in this file (`hero`, `v2ray`).
              ToggleSwitch {
                checked: v2ray.connected
                busy: v2ray.busy
                interactive: v2ray.installed || v2ray.profiles.length > 0
                foreground: hero.foreground
                accent: Color.accent
                onToggled: v2ray.toggleConnection()
              }
            }
          }

          // ---- engine missing ---------------------------------------------
          Column {
            visible: !v2ray.installed
            width: parent.width
            spacing: Style.space(8)

            Text {
              width: parent.width
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              text: "A v2ray core is required. Install v2ray to start using your servers."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Button {
              text: "Install v2ray"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: v2ray.installEngine()
            }
          }

          // ---- wrong core installed ----------------------------------------
          // Shown only after the backend refused an action with needsXray, i.e.
          // the server uses REALITY or XHTTP and v2ray-core cannot speak either.
          // Silent until then: most users never need this.
          Column {
            visible: v2ray.needsXray
            width: parent.width
            spacing: Style.space(8)

            Text {
              width: parent.width
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              text: "This server uses REALITY, which the v2ray core cannot do. " +
                    "The xray core can — it is in the AUR."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Button {
              text: "Install xray (AUR)"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: v2ray.installXray()
            }
          }

          // ---- paste a link ------------------------------------------------
          RowLayout {
            width: parent.width
            spacing: Style.space(8)

            TextField {
              id: linkField
              Layout.fillWidth: true
              placeholderText: "vless:// vmess:// trojan:// or ss:// link"
              foreground: root.foreground
              font.pixelSize: Style.font.bodySmall
              // Enter imports. Escape closes the panel, because while the field
              // is focused the key catcher is blocked and would otherwise never
              // see the key.
              onAccepted: root.submitLink()
              Keys.onEscapePressed: function(event) {
                root.close()
                event.accepted = true
              }
              // Tab hands the keyboard to the list so the panel stays usable
              // without a mouse.
              Keys.onTabPressed: function(event) {
                root.cursorActive = true
                keyCatcher.forceActiveFocus()
                event.accepted = true
              }
              onTextChanged: {
                // Any edit invalidates a half-armed delete.
                root.pendingRemoveId = ""
              }
            }

            Button {
              text: "Add"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.submitLink()
            }
          }

          // ---- feedback lines ---------------------------------------------
          // Kept to at most three lines. A failed latency probe hands back the
          // engine's own debug output, and printing that verbatim turned this
          // corner of the popup into a wall of text that pushed everything else
          // off screen. The full text is not lost: it is behind "copy details".
          Row {
            visible: v2ray.lastError !== ""
            width: parent.width
            spacing: Style.space(6)

            Text {
              // A hidden button still reports a width, so the invisible
              // "copy details" button must be discounted explicitly.
              width: parent.width - (detailsButton.visible ? detailsButton.width : 0)
                   - dismissButton.width - parent.spacing * 2
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap        // wrap, so long words cannot overflow
              maximumLineCount: 3            // ...but never more than 3 lines
              elide: Text.ElideRight
              text: v2ray.lastError
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            // Only offered when there IS extra text to copy, so the row stays
            // quiet for short, self-explanatory errors.
            V2rayActionButton {
              id: detailsButton
              visible: v2ray.lastErrorDetails !== ""
              iconText: "󰆏"
              tooltipText: "Copy the full error text"
              foreground: root.urgent
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              confirmed: root.flashKey === "error-details"
              onClicked: {
                root.flash("error-details")
                v2ray.copyErrorDetails()
              }
            }

            // Dismissing beats waiting for the popup to be closed and reopened,
            // which is what the error line used to require.
            V2rayActionButton {
              id: dismissButton
              iconText: "\uf0156"
              tooltipText: "Dismiss this message"
              foreground: root.urgent
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              onClicked: {
                root.flash("dismiss")
                v2ray.clearMessages()
              }
            }
          }

          Text {
            // Shown even while a red error line is up: the transient toast wins
            // while it lasts. It used to be hidden whenever lastError was set,
            // which is exactly when the user is clicking buttons.
            visible: text !== ""
            width: parent.width
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            text: v2ray.toast !== "" ? v2ray.toast : v2ray.notice
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          // ---- server list -------------------------------------------------
          Column {
            width: parent.width
            spacing: Style.space(4)

            PanelSectionHeader {
              text: "SERVERS"
              foreground: root.foreground
              fontFamily: root.fontFamily
              visible: v2ray.profiles.length > 0
            }

            Text {
              visible: v2ray.profiles.length === 0
              width: parent.width
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              text: "No servers yet. Paste a share link above and press Add."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Column {
              id: profileColumn
              width: parent.width
              spacing: Style.space(2)

              Repeater {
                id: profileRepeater
                model: v2ray.profiles
                delegate: ProfileRow {
                  width: profileColumn.width
                  rowIndex: index
                  profileData: modelData
                  hasCursor: root.cursorActive && root.cursorIndex === index
                }
              }
            }
          }

          // ---- local proxy details (only while connected) -------------------
          Column {
            visible: v2ray.connected && v2ray.socksPort > 0
            width: parent.width
            spacing: Style.space(4)

            PanelSeparator { foreground: root.foreground }

            PanelSectionHeader {
              text: "LOCAL PROXY"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Row {
              width: parent.width
              spacing: Style.space(6)

              Text {
                textFormat: Text.PlainText
                text: v2ray.proxyAddress()
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }

              V2rayActionButton {
                iconText: "󰆏"
                tooltipText: root.flashKey === "proxy-address" ? "Address copied" : "Copy the proxy address"
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                confirmed: root.flashKey === "proxy-address"
                onClicked: {
                  root.flash("proxy-address")
                  v2ray.copyProxyAddress()
                }
              }
            }

            // This paragraph exists to kill the most common misreading of the
            // whole plugin: the tunnel is ON, yet a browser still reports the
            // real IP, because nothing told the browser to use the proxy.
            // In TUN mode that is no longer true — everything is rerouted — and
            // saying it would be actively wrong. The ports stay bound either
            // way, so the section itself is never hidden.
            Text {
              width: parent.width
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              text: v2ray.mode === "tun"
                ? "TUN mode already routes every app, so nothing has to be pointed here. These ports stay bound for apps that prefer an explicit proxy."
                : "This proxy is NOT system-wide. Only apps you point at it go through the tunnel, so a browser that was never configured still shows your real IP. Either set SOCKS5 127.0.0.1:" + v2ray.socksPort + " in the app's proxy settings, or copy the line below and start the app from a terminal that has it."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            V2rayActionButton {
              iconText: "󰆏"
              tooltipText: root.flashKey === "proxy-env" ? "Export line copied" : "Copy the all_proxy export line for a terminal"
              foreground: root.dim
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              confirmed: root.flashKey === "proxy-env"
              onClicked: {
                root.flash("proxy-env")
                v2ray.copyProxyEnvironment()
              }
            }
          }

          // ---- TUN (system-wide) -------------------------------------------
          // A second kind of tunnel: the privileged helper sends every packet on
          // the machine through the profile, so this is the only switch here
          // that asks for a password. Hidden only when there is no core at all,
          // where the install block above is the whole story.
          Column {
            visible: v2ray.installed || v2ray.tunActive || root.tunHelperMissing
            width: parent.width
            spacing: Style.space(4)

            PanelSeparator { foreground: root.foreground }

            Row {
              width: parent.width
              spacing: Style.space(6)

              PanelSectionHeader {
                text: "TUN (SYSTEM-WIDE)"
                width: parent.width - tunSwitch.width - parent.spacing
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              ToggleSwitch {
                id: tunSwitch
                // Bound to the REAL state, never to the click. The helper has to
                // authenticate first, so a knob that flips immediately and flips
                // back on a cancelled prompt would be a lie.
                //
                // All three "outstanding" signals come from tunStartPending, not
                // from the 30s pulse: after the pulse the attempt can still be
                // unconfirmed for another 90s (every connect refused), and a
                // switch that looks idle then is worse than a slow one. A STOP
                // that is still unconfirmed is deliberately NOT busy — the user
                // must be able to turn the tunnel off again.
                checked: v2ray.tunActive
                busy: v2ray.tunStartPending
                interactive: !v2ray.tunStartPending && (v2ray.tunCanStart || v2ray.tunActive)
                foreground: root.foreground
                accent: Color.accent
                onToggled: v2ray.tunToggle()

                // ToggleSwitch's `busy` only swallows clicks, so the pulse is
                // ours. A SequencedAnimation REPLACES the property while it
                // runs, so onStopped has to put it back — a stopped animation
                // leaves its target halfway (same rule as V2rayActionButton).
                SequentialAnimation on opacity {
                  running: v2ray.tunStartPending
                  loops: Animation.Infinite
                  NumberAnimation { from: 1.0; to: 0.35; duration: 450; easing.type: Easing.InOutQuad }
                  NumberAnimation { from: 0.35; to: 1.0; duration: 450; easing.type: Easing.InOutQuad }
                  onStopped: tunSwitch.opacity = 1.0
                }
              }
            }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              text: root.tunDetail()
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            // Offered instead of a password prompt that cannot work: the
            // backend only answers needsHelper when the installed copy is
            // missing, a symlink, or not root-owned.
            Row {
              visible: root.tunHelperMissing
              width: parent.width
              spacing: Style.space(6)

              V2rayActionButton {
                iconText: "󰇚"
                tooltipText: "Install the TUN helper"
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                confirmed: root.flashKey === "tun-install"
                onClicked: {
                  root.flash("tun-install")
                  v2ray.installTun()
                }
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: "Install the TUN helper"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          // ---- footer ------------------------------------------------------
          Row {
            width: parent.width
            spacing: Style.space(6)

            V2rayActionButton {
              iconText: "󰒓"
              tooltipText: root.flashKey === "reveal" ? "Folder opened" : "Open the profile folder"
              foreground: root.dim
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              confirmed: root.flashKey === "reveal"
              onClicked: {
                root.flash("reveal")
                v2ray.revealConfig()
              }
            }

            V2rayActionButton {
              iconText: "󰑐"
              tooltipText: root.flashKey === "refresh" ? "Refreshed" : "Refresh"
              foreground: root.dim
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              confirmed: root.flashKey === "refresh"
              onClicked: {
                root.flash("refresh")
                v2ray.refresh()
              }
            }
          }
        }
      }
    }
  }

  // ===========================================================================
  // One server in the list.
  // ===========================================================================
  // Inline component so the row markup stays next to the Repeater that uses it
  // instead of living in a separate file that exists only once.
  component ProfileRow: Rectangle {
    id: row

    property var profileData: null
    property int rowIndex: 0
    property bool hasCursor: false

    readonly property string profileId: profileData ? String(profileData.id) : ""
    readonly property bool isActive: v2ray.connected && String(v2ray.activeId) === profileId
    readonly property bool isWorking: v2ray.busy && String(v2ray.actionRowId) === profileId
    readonly property bool pendingRemove: root.pendingRemoveId === profileId
    readonly property bool hot: rowMouse.containsMouse || hasCursor
    // Ping states: null = never measured, 0 = measuring, -1 = unreachable,
    // > 0 = milliseconds.
    readonly property var pingValue: v2ray.pingFor(profileId)

    implicitHeight: Math.max(textColumn.implicitHeight, actions.implicitHeight) + Style.spacing.rowPaddingX
    radius: Style.cornerRadius
    color: pendingRemove ? Style.selectedFillFor(root.urgent, root.urgent)
                        : (isActive ? root.selectedFill
                                    : (hot ? root.hoverFill : "transparent"))

    function subtitle() {
      if (!row.profileData) return ""
      if (row.pendingRemove) return "Click the bin again to delete"
      if (row.isWorking) return "Working…"
      if (row.isActive) return "Connected · " + (Model.formatUptime(v2ray.uptimeSec) || "just now")
      var suffix = ""
      if (row.pingValue === 0) suffix = "  ·  measuring…"
      else if (row.pingValue === -1) suffix = "  ·  unreachable"
      else if (row.pingValue !== null && row.pingValue > 0) suffix = "  ·  " + row.pingValue + " ms"
      return Model.describe(row.profileData) + suffix
    }

    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      onClicked: function(mouse) {
        if (row.pendingRemove) {
          root.pendingRemoveId = ""
          return
        }
        if (mouse.button === Qt.RightButton) {
          v2ray.copyLink(row.profileId)
          return
        }
        // Clicking the connected row disconnects; any other row connects.
        if (row.isActive) v2ray.disconnect()
        else v2ray.connect(row.profileId)
      }
    }

    // The active row gets a small accent dot so "which one is on" is readable
    // at a glance without relying on text.
    Rectangle {
      id: activeDot
      visible: row.isActive
      width: Style.space(6)
      height: width
      radius: width / 2
      color: Color.accent
      anchors.left: parent.left
      anchors.leftMargin: Style.space(4)
      anchors.verticalCenter: parent.verticalCenter
    }

    Column {
      id: textColumn
      anchors.left: activeDot.right
      anchors.leftMargin: Style.space(8)
      anchors.right: actions.left
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(1)

      Text {
        width: parent.width
        textFormat: Text.PlainText
        text: row.profileData ? String(row.profileData.name || "Unnamed") : ""
        color: row.isActive ? Color.accent : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: row.isActive
        elide: Text.ElideRight
      }

      Text {
        width: parent.width
        textFormat: Text.PlainText
        text: row.subtitle()
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }

    Row {
      id: actions
      anchors.right: parent.right
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(2)

      V2rayActionButton {
        iconText: "󰓅"
        tooltipText: v2ray.pingingId === row.profileId ? "Measuring…" : "Measure latency"
        foreground: root.foreground
        fontFamily: root.fontFamily
        fontSize: Style.font.caption
        enabled: v2ray.installed
        visible: v2ray.installed
        // A probe takes seconds, so the button pulses for its whole duration and
        // refuses a second click instead of silently doing nothing.
        busy: v2ray.pingingId === row.profileId
        // ...and answers with a check mark the instant it was pressed.
        confirmed: root.flashKey === "ping:" + row.profileId
        onClicked: {
          root.flash("ping:" + row.profileId)
          v2ray.pingProfile(row.profileId)
        }
      }

      V2rayActionButton {
        iconText: "󰆏"
        tooltipText: root.flashKey === "link:" + row.profileId ? "Link copied" : "Copy share link"
        foreground: root.foreground
        fontFamily: root.fontFamily
        fontSize: Style.font.caption
        confirmed: root.flashKey === "link:" + row.profileId
        onClicked: {
          root.flash("link:" + row.profileId)
          v2ray.copyLink(row.profileId)
        }
      }

      V2rayActionButton {
        iconText: "󰅙"
        tooltipText: row.pendingRemove ? "Click again to delete" : "Delete this server"
        foreground: row.pendingRemove ? root.urgent : root.foreground
        fontFamily: root.fontFamily
        fontSize: Style.font.caption
        confirmed: root.flashKey === "remove:" + row.profileId
        onClicked: {
          root.flash("remove:" + row.profileId)
          if (row.pendingRemove) {
            root.pendingRemoveId = ""
            v2ray.removeProfile(row.profileId)
          } else {
            // Arming the row is its own feedback: the row turns red and its
            // subtitle reads "Click the bin again to delete". The old notice
            // line was invisible whenever an error was on screen, so it added
            // nothing.
            root.pendingRemoveId = row.profileId
          }
        }
      }
    }
  }
}

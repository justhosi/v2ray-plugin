import QtQuick
import qs.Commons
import qs.Ui

// =============================================================================
// V2rayActionButton — the small icon button at the right edge of a server row,
// and everywhere else this plugin needs a one-tap action (copy, refresh…).
// =============================================================================
//
// WHY THIS FILE EXISTS (it is not a copy-paste accident)
// ------------------------------------------------------
// qs.Ui's `PanelActionButton` renders a *hover* state but has no *pressed*
// state at all: the glyph looks byte-for-byte identical before, during and
// after the mouse button goes down. On a control that does something slow or
// silent — copying to the clipboard produces no window, no sound, no toast —
// the user is left thinking the click was swallowed. Omarchy's own qs.Ui
// `Button` does draw a pressed fill, so this component simply gives the row
// actions the same behaviour, using the same Style tokens as the rest of the
// shell, so it still looks native.
//
// THREE KINDS OF FEEDBACK, because one is not enough
// --------------------------------------------------
//   pressed    the fill changes AND the glyph shrinks a hair the moment the
//              mouse goes down — feedback for the *press*, not just the action.
//   busy       the glyph pulses while a slow action runs (a latency probe can
//              take seconds) and further clicks are refused, so a second click
//              cannot queue a second probe.
//   confirmed  the glyph swaps to a check mark for a moment after the action
//              finished. This is the ONLY way a clipboard copy can visibly
//              succeed; the panel arms it via `confirmed` and clears it with a
//              timer, so the component itself stays stateless.
// =============================================================================

BorderSurface {
  id: root

  // ---- content --------------------------------------------------------------
  property string iconText: ""
  property string tooltipText: ""

  // Glyph shown while `confirmed` is set. A check mark is the least surprising
  // "done" symbol at 16px; themes that use a different icon font can override.
  property string confirmedIconText: "\uf00c"   // nf-fa-check

  // ---- state ----------------------------------------------------------------
  property bool busy: false        // a slow action is running for this button
  property bool confirmed: false   // the action just succeeded

  // ---- look -----------------------------------------------------------------
  property color foreground: Color.foreground
  property color hoverColor: foreground
  property string fontFamily: Style.font.family
  property real fontSize: Style.font.icon
  property real size: Math.max(Style.space(22), fontSize + Style.spacing.sm * 2)
  // Keyboard focus defaults to OFF, exactly like the stock action button: the
  // server row owns the keyboard cursor in this panel (t / r / p / c and the
  // arrow keys), so a second, independent focus ring would be noise. Set it to
  // true only for a button outside a row.
  property bool focusable: false
  property bool bordered: false

  // A busy button must refuse a second click; a disabled one must refuse all.
  readonly property bool interactive: enabled && !busy

  signal clicked()
  signal hovered(bool isHovered)

  implicitWidth: size
  implicitHeight: size
  radius: Style.cornerRadius

  // ---- focus / keyboard -----------------------------------------------------
  // Kept so a caller can opt in; see the `focusable` declaration above for why
  // it is off by default.
  activeFocusOnTab: focusable
  Keys.onReturnPressed: if (focusable && interactive) root.clicked()
  Keys.onEnterPressed: if (focusable && interactive) root.clicked()
  Keys.onSpacePressed: if (focusable && interactive) root.clicked()

  readonly property bool _hot: mouse.containsMouse && interactive
  readonly property bool _showFocusRing: focusable && activeFocus

  // Paint priority mirrors qs.Ui's Button: pressed beats focus beats hover.
  color: mouse.pressed && interactive ? Style.pressedFillFor(hoverColor, hoverColor)
    : _showFocusRing ? Style.focusFillFor(hoverColor, hoverColor)
    : _hot ? Style.hoverFillFor(hoverColor, hoverColor)
    : "transparent"
  borderSpec: _showFocusRing
    ? Border.controlSpec("focus", hoverColor, hoverColor)
    : (bordered ? Border.controlSpec("normal", foreground, Color.accent) : Border.none())

  Behavior on color { ColorAnimation { duration: 60 } }

  // The press itself is made visible by shrinking the whole button slightly.
  // 0.88 is big enough to notice at bar size and small enough not to look like
  // a layout jump. The Behavior guarantees it animates back to 1.0 even when
  // the pointer leaves the button while still held down.
  scale: mouse.pressed && interactive ? 0.88 : 1.0
  Behavior on scale { NumberAnimation { duration: 90; easing.type: Easing.OutQuad } }

  // ---- the glyph ------------------------------------------------------------
  Text {
    id: glyph
    anchors.centerIn: parent
    textFormat: Text.PlainText
    text: root.confirmed ? root.confirmedIconText : root.iconText
    color: !root.enabled ? Qt.darker(root.foreground, 2.0)
         : (_hot ? root.hoverColor : root.foreground)
    font.family: root.fontFamily
    font.pixelSize: root.fontSize
    font.bold: root.confirmed
  }

  // Pulse while the action runs. A SequencedAnimation *replaces* the property
  // value while it runs, so `onStopped` has to put the opacity back — a
  // stopped animation leaves its target wherever it was interrupted, which
  // would freeze the glyph at whatever partial transparency it happened to be.
  SequentialAnimation on opacity {
    running: root.busy
    loops: Animation.Infinite
    NumberAnimation { from: 1.0; to: 0.3; duration: 450; easing.type: Easing.InOutQuad }
    NumberAnimation { from: 0.3; to: 1.0; duration: 450; easing.type: Easing.InOutQuad }
    onStopped: glyph.opacity = 1.0
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: root.interactive ? Qt.PointingHandCursor : Qt.ArrowCursor
    enabled: root.interactive
    onContainsMouseChanged: root.hovered(containsMouse)
    onClicked: {
      if (root.focusable) root.forceActiveFocus()
      root.clicked()
    }
  }

  PanelToolTip {
    visible: root.tooltipText !== "" && mouse.containsMouse
    text: root.tooltipText
    fontFamily: root.fontFamily
  }
}

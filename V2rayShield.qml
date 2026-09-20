// PROBE-LINE-SHIFT-TEST
import QtQuick
import QtQuick.Shapes
import qs.Commons
import qs.Ui

// =============================================================================
// V2rayShield — the little shield that lives in the bar.
// =============================================================================
//
// Drawn with QtQuick.Shapes rather than shipped as an SVG for the same reason
// Omarchy's own Tailscale icon is hand-drawn: tiny bar slots render SVG files
// inconsistently (rounding, effects, and stroke scaling all go sideways at
// 16px). Three states, all readable at a glance:
//
//   active    shield outline + check mark, full-strength color
//   idle      shield outline + diagonal slash, dimmed
//   busy      shield outline pulsing while the engine starts or stops
//
// A small "!" badge (like the one on the Tailscale icon) flags a missing
// engine, so the user learns the plugin needs a package instead of wondering
// why nothing happens when they click.
// =============================================================================

Item {
  id: root

  property real iconSize: Style.font.icon
  property color color: Color.foreground
  property color badgeColor: Color.urgent

  property bool active: false      // tunnel is up
  property bool busy: false        // connect/disconnect in flight
  property bool crossed: false     // draw the "off" slash
  property bool warning: false     // no engine installed

  width: iconSize
  height: iconSize
  implicitWidth: iconSize
  implicitHeight: iconSize

  // Stroke weight scales with the slot so the shield keeps its proportions
  // when the user scales the desktop font size up or down.
  readonly property real strokeWidth: Math.max(1, iconSize * 0.085)

  // ---------------------------------------------------------------------------
  // IMPORTANT QML RULE — this is the bug that made the bar icon disappear once.
  // ---------------------------------------------------------------------------
  // `ShapePath` is NOT an Item. It is a plain object describing one contour
  // inside a `Shape`, so it has NO `visible` and NO `opacity` property. Writing
  //     ShapePath { visible: ... }
  // is a HARD QML ERROR ("Cannot assign to non-existent property \"visible\"").
  // The error happens while the file is being *parsed*, so the whole icon type
  // fails to construct; the bar widget then fails with
  //     "Type V2rayShield unavailable"
  // and the net effect is simply: no shield in the bar.
  //
  // The fix — and the pattern Omarchy's own Tailscale icon uses — is to give
  // each conditionally-shown glyph its own `Shape` item (a real Item, which
  // DOES have `visible`) holding exactly one ShapePath.
  // ---------------------------------------------------------------------------

  // One reusable wrapper per glyph. `Glyph` bundles what every glyph needs:
  // it fills the slot, it antialiases, and it takes part in the busy pulse.
  component Glyph: Shape {
    anchors.fill: parent
    antialiasing: true

    // Layer + 4x supersampling smooths the 1–2px strokes at bar size.
    layer.enabled: true
    layer.samples: 4

    // Pulsing while we wait for the engine, steady otherwise. Animating the
    // whole Shape keeps the geometry code below free of state flags.
    opacity: root.busy ? 0.35 : 1.0
    Behavior on opacity {
      NumberAnimation { duration: 160; easing.type: Easing.OutQuad }
    }
  }

  // ---- shield outline (always drawn) ---------------------------------------
  // Traced clockwise from the top centre: right shoulder, right waist,
  // curve to the bottom point, curve back up to the left waist, left
  // shoulder, then closed with an explicit PathLine back to the start
  // (QtQuick.Shapes has no PathClose element).
  Glyph {
    ShapePath {
      strokeColor: root.color
      strokeWidth: root.strokeWidth
      fillColor: "transparent"
      capStyle: ShapePath.RoundCap
      joinStyle: ShapePath.RoundJoin
      PathMove { x: root.width * 0.50; y: root.height * 0.09 }
      PathLine { x: root.width * 0.90; y: root.height * 0.24 }
      PathLine { x: root.width * 0.90; y: root.height * 0.50 }
      PathQuad {
        x: root.width * 0.50; y: root.height * 0.94
        controlX: root.width * 0.86; controlY: root.height * 0.80
      }
      PathQuad {
        x: root.width * 0.10; y: root.height * 0.50
        controlX: root.width * 0.14; controlY: root.height * 0.80
      }
      PathLine { x: root.width * 0.10; y: root.height * 0.24 }
      PathLine { x: root.width * 0.50; y: root.height * 0.09 }
    }
  }

  // ---- check mark (connected) ----------------------------------------------
  // NOTE: `visible` sits on the Glyph item, NEVER on the ShapePath inside it.
  Glyph {
    visible: root.active && !root.crossed
    ShapePath {
      strokeColor: root.color
      strokeWidth: root.strokeWidth
      fillColor: "transparent"
      capStyle: ShapePath.RoundCap
      joinStyle: ShapePath.RoundJoin
      PathMove { x: root.width * 0.32; y: root.height * 0.51 }
      PathLine { x: root.width * 0.45; y: root.height * 0.64 }
      PathLine { x: root.width * 0.71; y: root.height * 0.35 }
    }
  }

  // ---- slash (disconnected) ------------------------------------------------
  Glyph {
    visible: root.crossed
    ShapePath {
      strokeColor: root.color
      strokeWidth: root.strokeWidth
      fillColor: "transparent"
      capStyle: ShapePath.RoundCap
      PathMove { x: root.width * 0.20; y: root.height * 0.84 }
      PathLine { x: root.width * 0.80; y: root.height * 0.17 }
    }
  }

  // ---- "no engine installed" badge --------------------------------------
  BorderSurface {
    visible: root.warning
    width: Math.max(7, parent.width * 0.42)
    height: width
    radius: width / 2
    color: root.badgeColor
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    borderSpec: Border.flat(Color.popups.background, 1)

    Text {
      anchors.centerIn: parent
      text: "!"
      color: Color.background
      font.family: Style.font.family
      font.pixelSize: Math.max(6, parent.height * 0.72)
      font.bold: true
    }
  }
}

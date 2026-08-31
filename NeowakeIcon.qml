import QtQuick
import QtQuick.Shapes
import qs.Commons

// The neowake mark: a disc split by the wave that forms the "N".
// Drawn rather than shipped as an image so it takes the bar's theme colors.
Item {
  id: root

  property real iconSize: Style.font.icon
  property color color: Color.foreground
  // The wave is negative space in the real logo, so it is painted in the
  // colour behind the disc rather than as a stroke on top of it.
  property color cutColor: Color.bar.background

  width: iconSize
  height: iconSize
  implicitWidth: iconSize
  implicitHeight: iconSize

  Shape {
    anchors.fill: parent
    antialiasing: true
    layer.enabled: true
    layer.samples: 4
    preferredRendererType: Shape.CurveRenderer

    ShapePath {
      fillColor: root.color
      strokeWidth: -1
      strokeColor: "transparent"

      PathAngleArc {
        centerX: root.width / 2
        centerY: root.height / 2
        radiusX: root.width / 2
        radiusY: root.height / 2
        startAngle: 0
        sweepAngle: 360
      }
    }

    ShapePath {
      fillColor: "transparent"
      strokeColor: root.cutColor
      strokeWidth: Math.max(1.3, root.width * 0.155)
      capStyle: ShapePath.RoundCap
      joinStyle: ShapePath.RoundJoin

      startX: root.width * 0.08
      startY: root.height * 0.86

      // up to the first crest
      PathCubic {
        control1X: root.width * 0.30; control1Y: root.height * 0.84
        control2X: root.width * 0.34; control2Y: root.height * 0.30
        x: root.width * 0.50;         y: root.height * 0.29
      }
      // over the crest and down into the trough
      PathCubic {
        control1X: root.width * 0.62; control1Y: root.height * 0.28
        control2X: root.width * 0.56; control2Y: root.height * 0.62
        x: root.width * 0.66;         y: root.height * 0.61
      }
      // and up again, leaving through the top right
      PathCubic {
        control1X: root.width * 0.76; control1Y: root.height * 0.60
        control2X: root.width * 0.74; control2Y: root.height * 0.14
        x: root.width * 0.94;         y: root.height * 0.12
      }
    }
  }
}

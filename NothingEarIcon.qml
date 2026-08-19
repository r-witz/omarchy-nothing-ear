import QtQuick
import qs.Commons

// A small, theme-coloured pair of earbud silhouettes. Drawing it in QML keeps
// the bar icon sharp at every scale and avoids another image asset.
Item {
  id: root

  property real iconSize: 16
  property color color: Color.foreground

  implicitWidth: iconSize
  implicitHeight: iconSize

  Row {
    anchors.centerIn: parent
    spacing: root.iconSize * 0.18

    Bud { ink: root.color; flip: false }
    Bud { ink: root.color; flip: true }
  }

  component Bud: Item {
    id: bud
    property color ink: Color.foreground
    property bool flip: false

    width: root.iconSize * 0.37
    height: root.iconSize * 0.82
    scale: flip ? -1 : 1

    Rectangle {
      x: parent.width * 0.05
      y: 0
      width: parent.width * 0.82
      height: parent.width * 0.82
      radius: width / 2
      color: bud.ink
    }

    Rectangle {
      x: parent.width * 0.32
      y: parent.width * 0.56
      width: parent.width * 0.35
      height: root.iconSize * 0.43
      radius: width / 2
      color: bud.ink
    }
  }
}

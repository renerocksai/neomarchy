import QtQuick
import qs.Commons
import qs.Ui

// One session in the favorites or search list.
BorderSurface {
  id: row

  property var item: null
  property int rowIndex: -1
  property string subtitle: ""
  property bool selected: false
  property bool nowPlaying: false
  property bool favorite: false

  property color foreground: Color.foreground
  property color accent: Color.accent
  property string fontFamily: Style.font.family

  signal activated()
  signal hovered()
  signal favoriteToggled()
  signal cacheToggled()

  readonly property bool cached: item && item.cached === true
  readonly property bool headphones: item && item.headphonesRequired === true

  implicitHeight: Style.space(66)
  radius: Style.cornerRadius
  clip: true

  color: selected
    ? Style.selectedFillFor(foreground, accent)
    : (mouse.containsMouse ? Style.hoverFillFor(foreground, accent) : "transparent")
  borderSpec: selected
    ? Border.controlSpec("selected", foreground, accent)
    : Border.none()

  Behavior on color { ColorAnimation { duration: 120 } }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: Qt.LeftButton
    cursorShape: Qt.PointingHandCursor
    onEntered: row.hovered()
    onClicked: row.activated()
    onDoubleClicked: row.activated()
  }

  Item {
    anchors.fill: parent
    anchors.margins: Style.spacing.md

    BorderSurface {
      id: art
      width: parent.height
      height: parent.height
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      radius: Style.cornerRadius
      color: Style.normalFillFor(row.foreground, row.accent)
      borderSpec: Border.controlSpec("normal", row.foreground, row.accent)

      Image {
        id: cover
        anchors.fill: parent
        anchors.margins: Style.space(2)
        source: row.item && row.item.thumb ? row.item.thumb : ""
        sourceSize.width: 108
        sourceSize.height: 108
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        // Delegates get recycled constantly; don't hold every cover forever.
        cache: false
        visible: status === Image.Ready
      }

      Text {
        anchors.centerIn: parent
        visible: cover.status !== Image.Ready
        text: "󰝚"
        color: row.foreground
        font.family: row.fontFamily
        font.pixelSize: Style.font.icon
        opacity: 0.45
      }
    }

    Column {
      anchors.left: art.right
      anchors.leftMargin: Style.spacing.xxl
      anchors.right: actions.left
      anchors.rightMargin: Style.spacing.xl
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.spacing.xxs

      Row {
        width: parent.width
        spacing: Style.spacing.md

        Text {
          text: "󰝚"
          color: row.accent
          font.family: row.fontFamily
          font.pixelSize: Style.font.bodySmall
          visible: row.nowPlaying
          anchors.verticalCenter: parent.verticalCenter
        }

        Text {
          width: parent.width - (row.nowPlaying ? Style.space(18) : 0)
          text: row.item ? String(row.item.title || row.item.id || "") : ""
          color: row.foreground
          font.family: row.fontFamily
          font.pixelSize: Style.font.body
          font.bold: row.selected || row.nowPlaying
          elide: Text.ElideRight
        }
      }

      Text {
        width: parent.width
        text: row.subtitle
        color: row.foreground
        font.family: row.fontFamily
        font.pixelSize: Style.font.caption
        opacity: 0.6
        elide: Text.ElideRight
        maximumLineCount: 1
      }
    }

    Row {
      id: actions
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.spacing.xs

      Text {
        anchors.verticalCenter: parent.verticalCenter
        visible: row.headphones
        text: "󰋋"
        color: row.foreground
        font.family: row.fontFamily
        font.pixelSize: Style.font.iconSmall
        opacity: 0.45
      }

      Button {
        anchors.verticalCenter: parent.verticalCenter
        iconText: row.cached ? "󰇛" : "󰇚"
        foreground: row.foreground
        accent: row.accent
        opacity: row.cached ? 1 : (mouse.containsMouse || row.selected ? 0.75 : 0)
        visible: opacity > 0
        tooltipText: row.cached ? "Remove the offline copy" : "Keep offline"
        onClicked: row.cacheToggled()
        Behavior on opacity { NumberAnimation { duration: 120 } }
      }

      Button {
        anchors.verticalCenter: parent.verticalCenter
        iconText: row.favorite ? "󰋑" : "󰋕"
        foreground: row.favorite ? row.accent : row.foreground
        accent: row.accent
        opacity: row.favorite ? 1 : (mouse.containsMouse || row.selected ? 0.75 : 0)
        visible: opacity > 0
        tooltipText: row.favorite ? "Remove from favorites" : "Add to favorites"
        onClicked: row.favoriteToggled()
        Behavior on opacity { NumberAnimation { duration: 120 } }
      }

      Button {
        anchors.verticalCenter: parent.verticalCenter
        iconText: "󰐊"
        iconSize: Style.font.iconLarge
        foreground: row.foreground
        accent: row.accent
        tooltipText: "Play this session"
        onClicked: row.activated()
      }
    }
  }
}

import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

BarWidget {
  id: root
  moduleName: "org.renerocksai.neomarchy"

  readonly property var service: bar && bar.shell
    ? bar.shell.firstPartyServiceFor("org.renerocksai.neomarchy") : null

  readonly property bool showTitle: setting("showTrackTitle", "On") === "On"
  readonly property real barTextCap: Number(setting("maxBarTextWidth", "220")) || 0
  readonly property real volumeStep: Math.max(1, Number(setting("volumeStep", 5))) / 100

  property bool popupOpen: false

  readonly property bool hasTrack: service && service.hasTrack
  readonly property bool playing: service && service.playing
  readonly property string barText: !showTitle || !hasTrack ? "" : service.trackTitle
  readonly property bool iconOnly: vertical || barText === ""

  // A solid disc reads larger than a glyph's ink at the same nominal size,
  // so the mark is drawn a little under the icon canvas to match its
  // neighbours in the bar.
  readonly property real brandIconSize: Style.bar.iconCanvas * 0.67

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function close() { popupOpen = false }
  function open() { popupOpen = true }
  function toggle() { popupOpen = !popupOpen }

  onPopupOpenChanged: {
    if (!popupOpen || !service)
      return
    service.refreshStatus()
    if (service.loggedIn)
      service.refreshFavorites(false)
    Qt.callLater(function() { favList.revealCurrent() })
  }

  onServiceChanged: if (service) service.cacheOnPlay = setting("cacheOnPlay", "Off") === "On"

  Component.onCompleted: {
    if (service) {
      service.repeat = setting("repeat", "Off") === "On"
      service.cacheOnPlay = setting("cacheOnPlay", "Off") === "On"
    }
  }

  // --------------------------------------------------------------- bar slot

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    active: root.playing
    hasVisualContent: true

    iconComponent: root.iconOnly ? brandIcon : null
    tooltipText: root.hasTrack
      ? (root.service.trackTitle + (root.playing ? "" : " — paused"))
      : "neomarchy"

    readonly property real fittedWidth: Math.ceil(glyph.implicitWidth
      + content.spacing + label.implicitWidth + scaledHorizontalMargin * 2)

    fixedWidth: root.vertical ? root.barSize
      : (root.iconOnly ? Style.bar.iconSlot
        : Math.max(root.barSize, root.barTextCap > 0
          ? Math.min(Style.space(root.barTextCap), fittedWidth)
          : fittedWidth))
    fixedHeight: root.vertical && root.iconOnly ? Style.bar.iconSlot : -1
    clip: true

    onPressed: function(mouseButton) {
      if (mouseButton === Qt.MiddleButton)
        root.service && root.service.togglePlayback()
      else if (mouseButton === Qt.RightButton)
        root.openFullPanel()
      else
        root.toggle()
    }
    onWheelMoved: function(delta) {
      if (!root.service)
        return
      root.service.adjustVolume(delta > 0 ? root.volumeStep : -root.volumeStep)
    }

    Row {
      id: content
      anchors.centerIn: parent
      spacing: root.iconOnly ? 0 : Style.spacing.md
      visible: !root.iconOnly

      NeowakeIcon {
        id: glyph
        anchors.verticalCenter: parent.verticalCenter
        iconSize: root.brandIconSize
        color: root.playing ? button.activeColor : button.foreground
        cutColor: root.bar ? root.bar.background : Color.bar.background
      }

      // Scroll the title only when it genuinely overflows and nothing is
      // covering it — a marquee under an open popup is just noise.
      Item {
        id: scrollClip
        width: Math.max(0, button.width - glyph.implicitWidth
          - content.spacing - button.scaledHorizontalMargin * 2)
        height: glyph.implicitHeight
        anchors.verticalCenter: parent.verticalCenter
        clip: label.needsScroll

        readonly property bool scrolling: label.needsScroll && !root.popupOpen
        readonly property real fadeStop: width > 0
          ? Math.min(0.2, Style.space(24) / width) : 0

        Item {
          anchors.fill: parent
          layer.enabled: scrollClip.scrolling
          layer.smooth: true
          layer.effect: MultiEffect {
            autoPaddingEnabled: false
            maskEnabled: true
            maskSource: fadeMask
            maskThresholdMin: 0.5
            maskSpreadAtMin: 1
          }

          Text {
            id: label
            anchors.verticalCenter: parent.verticalCenter
            text: root.barText
            color: button.foreground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.body
            renderType: Text.NativeRendering

            readonly property bool needsScroll: implicitWidth > scrollClip.width

            XAnimator on x {
              running: scrollClip.scrolling
              loops: Animation.Infinite
              duration: Math.round(Math.max(6000, label.implicitWidth * 25))
              from: scrollClip.width
              to: -label.implicitWidth
              easing.type: Easing.Linear
              onStopped: label.x = 0
            }
          }
        }

        Rectangle {
          id: fadeMask
          anchors.fill: parent
          visible: false
          layer.enabled: scrollClip.scrolling
          gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop { position: 0; color: "transparent" }
            GradientStop { position: scrollClip.fadeStop; color: "white" }
            GradientStop { position: 1 - scrollClip.fadeStop; color: "white" }
            GradientStop { position: 1; color: "transparent" }
          }
        }
      }
    }
  }

  Component {
    id: brandIcon
    Item {
      NeowakeIcon {
        anchors.centerIn: parent
        iconSize: root.brandIconSize
        color: root.playing
          ? (root.bar ? root.bar.urgent : Color.bar.active)
          : (root.bar ? root.bar.barForeground : Color.foreground)
        cutColor: root.bar ? root.bar.background : Color.bar.background
      }
    }
  }

  function openFullPanel() {
    popupOpen = false
    if (bar && bar.shell)
      bar.shell.summon("org.renerocksai.neomarchy", "{}")
  }

  function formatTime(seconds) {
    var total = Math.max(0, Math.floor(Number(seconds) || 0))
    var mins = Math.floor(total / 60)
    var secs = total % 60
    return mins + ":" + (secs < 10 ? "0" : "") + secs
  }

  // ------------------------------------------------------------ mini player

  PopupCard {
    id: popup
    anchorItem: button
    bar: root.bar
    owner: root
    open: root.popupOpen
    contentWidth: popup.fittedContentWidth(Style.space(340))
    contentHeight: popup.fittedContentHeight(column.implicitHeight)

    Column {
      id: column
      anchors.fill: parent
      spacing: Style.spacing.xl

      // -- signed out ------------------------------------------------------

      Column {
        width: parent.width
        spacing: Style.spacing.lg
        visible: root.service && !root.service.loggedIn

        Text {
          width: parent.width
          text: "Not signed in to neowake"
          color: root.bar ? root.bar.foreground : Color.foreground
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.subtitle
          wrapMode: Text.WordWrap
        }

        Button {
          width: parent.width
          text: "Open the panel to sign in"
          foreground: root.bar ? root.bar.foreground : Color.foreground
          bordered: true
          onClicked: root.openFullPanel()
        }
      }

      // -- nothing playing yet --------------------------------------------

      Text {
        width: parent.width
        visible: root.service && root.service.loggedIn && !root.hasTrack
        text: root.service && root.service.favorites.length > 0
          ? "Pick a session to start"
          : "Loading your favorites…"
        color: root.bar ? root.bar.foreground : Color.foreground
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.body
        opacity: 0.7
      }

      // -- now playing -----------------------------------------------------

      Item {
        width: parent.width
        height: Style.space(78)
        visible: root.hasTrack

        BorderSurface {
          id: artFrame
          width: Style.space(78)
          height: width
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          radius: Style.cornerRadius
          color: Style.normalFillFor(root.bar ? root.bar.foreground : Color.foreground, Color.accent)
          borderSpec: Border.controlSpec("normal",
            root.bar ? root.bar.foreground : Color.foreground, Color.accent)

          Image {
            id: art
            anchors.fill: parent
            anchors.margins: Style.space(3)
            source: root.popupOpen && root.service ? root.service.trackArtUrl : ""
            sourceSize.width: 156
            sourceSize.height: 156
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            cache: true
            visible: status === Image.Ready
          }

          Text {
            anchors.centerIn: parent
            visible: art.status !== Image.Ready
            text: "󰝚"
            color: root.bar ? root.bar.foreground : Color.foreground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.displayLarge
            opacity: 0.6
          }
        }

        Column {
          anchors.left: artFrame.right
          anchors.leftMargin: Style.spacing.xxl
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.spacing.sm

          Text {
            width: parent.width
            text: root.service ? root.service.trackTitle : ""
            color: root.bar ? root.bar.foreground : Color.foreground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.subtitle
            elide: Text.ElideRight
            maximumLineCount: 2
            wrapMode: Text.WordWrap
          }

          Text {
            width: parent.width
            text: {
              if (!root.service || !root.service.currentTrack)
                return ""
              var track = root.service.currentTrack
              var cats = track.categories || []
              var parts = []
              if (cats.length > 0)
                parts.push(String(cats[0]).replace(/-/g, " "))
              if (track.cached)
                parts.push("offline")
              return parts.join(" · ")
            }
            color: root.bar ? root.bar.foreground : Color.foreground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
            opacity: 0.6
            elide: Text.ElideRight
          }
        }
      }

      // -- seek ------------------------------------------------------------

      Column {
        width: parent.width
        spacing: Style.spacing.xs
        visible: root.hasTrack

        PanelSlider {
          id: seek
          width: parent.width
          bar: root.bar
          minimum: 0
          maximum: Math.max(1, root.service ? root.service.lengthSeconds : 1)
          value: root.service ? root.service.positionSeconds : 0
          liveValue: dragging ? liveValue : value
          step: 15
          enabled: root.service && root.service.lengthSeconds > 0
          onReleased: function(v) { root.service && root.service.seekSeconds(v) }
        }

        Item {
          width: parent.width
          height: position.implicitHeight

          Text {
            id: position
            anchors.left: parent.left
            text: root.formatTime(root.service ? root.service.positionSeconds : 0)
            color: root.bar ? root.bar.foreground : Color.foreground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
            opacity: 0.6
          }

          Text {
            anchors.right: parent.right
            text: root.formatTime(root.service ? root.service.lengthSeconds : 0)
            color: root.bar ? root.bar.foreground : Color.foreground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
            opacity: 0.6
          }
        }
      }

      // -- transport -------------------------------------------------------

      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: Style.spacing.lg
        visible: root.hasTrack

        Button {
          iconText: root.service && root.service.currentIsFavorite ? "󰋑" : "󰋕"
          foreground: root.bar ? root.bar.foreground : Color.foreground
          tooltipText: root.service && root.service.currentIsFavorite
            ? "Remove from favorites" : "Add to favorites"
          onClicked: root.service && root.service.toggleFavorite(root.service.trackId)
        }

        Button {
          iconText: root.service && root.service.playing ? "󰏤" : "󰐊"
          iconSize: Style.font.iconLarge
          foreground: root.bar ? root.bar.foreground : Color.foreground
          selected: root.service && root.service.playing
          tooltipText: root.service && root.service.playing ? "Pause" : "Play"
          onClicked: root.service && root.service.togglePlayback()
        }

        Button {
          iconText: "󰓛"
          foreground: root.bar ? root.bar.foreground : Color.foreground
          tooltipText: "Stop"
          onClicked: root.service && root.service.stop()
        }

        Button {
          iconText: "󰑖"
          foreground: root.bar ? root.bar.foreground : Color.foreground
          selected: root.service && root.service.repeat
          tooltipText: root.service && root.service.repeat
            ? "Repeat is on" : "Repeat this session"
          onClicked: root.service && root.service.toggleRepeat()
        }
      }

      // -- volume ----------------------------------------------------------

      Item {
        width: parent.width
        height: volume.implicitHeight
        visible: root.hasTrack

        Text {
          id: volumeGlyph
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          text: root.service && root.service.volume <= 0 ? "󰝟" : "󰕾"
          color: root.bar ? root.bar.foreground : Color.foreground
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.icon
          opacity: root.service && root.service.volume <= 0 ? 0.5 : 1
        }

        PanelSlider {
          id: volume
          anchors.left: volumeGlyph.right
          anchors.leftMargin: Style.spacing.xl
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          bar: root.bar
          minimum: 0
          maximum: 1
          step: root.volumeStep
          value: root.service ? root.service.volume : 0
          onMoved: function(v) { root.service && root.service.setVolume(v) }
          onReleased: function(v) { root.service && root.service.setVolume(v) }
        }
      }

      PanelSeparator {
        foreground: root.bar ? root.bar.foreground : Color.foreground
        visible: root.service && root.service.loggedIn
      }

      // -- favorites -------------------------------------------------------

      Item {
        width: parent.width
        height: favHeading.implicitHeight
        visible: root.service && root.service.loggedIn

        Text {
          id: favHeading
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          text: "FAVORITES"
          color: root.bar ? root.bar.foreground : Color.foreground
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
          font.bold: true
          opacity: 0.55
        }

        Text {
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: root.service ? String(root.service.favorites.length) : ""
          color: root.bar ? root.bar.foreground : Color.foreground
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
          opacity: 0.45
        }
      }

      ListView {
        id: favList
        width: parent.width
        // Show about five rows, then scroll — the popup must not outgrow the
        // screen just because someone favorited fifty sessions.
        height: Math.min(contentHeight, Style.space(186))
        visible: root.service && root.service.loggedIn
          && root.service.favorites.length > 0
        model: root.service ? root.service.favorites : []
        clip: true
        spacing: Style.spacing.xxs
        reuseItems: true
        boundsBehavior: Flickable.StopAtBounds

        // Keep the session that is actually playing in view, so opening the
        // popup mid-session shows it rather than the top of the list.
        readonly property int currentFavorite: {
          if (!root.service || root.service.trackId === "")
            return -1
          var favs = root.service.favorites
          for (var i = 0; i < favs.length; i++) {
            if (String(favs[i].id) === root.service.trackId)
              return i
          }
          return -1
        }

        function revealCurrent() {
          if (currentFavorite >= 0)
            positionViewAtIndex(currentFavorite, ListView.Contain)
        }

        onCurrentFavoriteChanged: revealCurrent()
        onCountChanged: Qt.callLater(revealCurrent)

        delegate: Rectangle {
          id: favRow
          required property var modelData
          required property int index

          readonly property bool current: root.service
            && root.service.trackId === String(modelData.id)

          width: favList.width
          height: Style.space(36)
          radius: Style.cornerRadius
          color: favMouse.containsMouse || current
            ? Style.hoverFillFor(root.bar ? root.bar.foreground : Color.foreground, Color.accent)
            : "transparent"

          Behavior on color { ColorAnimation { duration: 120 } }

          MouseArea {
            id: favMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.service && root.service.play(favRow.modelData)
          }

          Image {
            id: favArt
            width: Style.space(26)
            height: width
            anchors.left: parent.left
            anchors.leftMargin: Style.spacing.sm
            anchors.verticalCenter: parent.verticalCenter
            source: favRow.modelData.thumb || ""
            sourceSize.width: 52
            sourceSize.height: 52
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            cache: false
            visible: status === Image.Ready
          }

          Text {
            anchors.fill: favArt
            visible: favArt.status !== Image.Ready
            text: "󰝚"
            color: root.bar ? root.bar.foreground : Color.foreground
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.iconSmall
            opacity: 0.4
          }

          Text {
            anchors.left: favArt.right
            anchors.leftMargin: Style.spacing.lg
            anchors.right: favPlaying.left
            anchors.rightMargin: Style.spacing.md
            anchors.verticalCenter: parent.verticalCenter
            text: String(favRow.modelData.title || favRow.modelData.id || "")
            color: root.bar ? root.bar.foreground : Color.foreground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.bodySmall
            font.bold: favRow.current
            elide: Text.ElideRight
          }

          Text {
            id: favPlaying
            anchors.right: parent.right
            anchors.rightMargin: Style.spacing.md
            anchors.verticalCenter: parent.verticalCenter
            text: favRow.current && root.service && root.service.playing ? "󰝚"
              : (favMouse.containsMouse ? "󰐊" : "")
            color: favRow.current ? Color.accent
              : (root.bar ? root.bar.foreground : Color.foreground)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.iconSmall
            opacity: favRow.current ? 1 : 0.7
          }
        }
      }

      Text {
        width: parent.width
        visible: root.service && root.service.loggedIn
          && root.service.favorites.length === 0
        text: root.service && root.service.favoritesLoading
          ? "Loading your favorites…" : "No favorites yet"
        color: root.bar ? root.bar.foreground : Color.foreground
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.caption
        opacity: 0.5
      }

      PanelSeparator {
        foreground: root.bar ? root.bar.foreground : Color.foreground
        visible: root.service && root.service.loggedIn
      }

      // -- footer ----------------------------------------------------------

      Item {
        width: parent.width
        height: openButton.implicitHeight
        visible: root.service && root.service.loggedIn

        Text {
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          width: parent.width - openButton.width - Style.spacing.xl
          text: root.service
            ? (root.service.lastError !== "" ? root.service.lastError
              : (root.service.statusMessage !== "" ? root.service.statusMessage
                : root.service.favorites.length + " favorites")) : ""
          color: root.service && root.service.lastError !== ""
            ? Color.urgent : (root.bar ? root.bar.foreground : Color.foreground)
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
          opacity: root.service && root.service.lastError !== "" ? 1 : 0.6
          elide: Text.ElideRight
        }

        Button {
          id: openButton
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: "Open"
          foreground: root.bar ? root.bar.foreground : Color.foreground
          bordered: true
          onClicked: root.openFullPanel()
        }
      }
    }
  }

  // Only tick the clock while someone can see it.
  Timer {
    interval: 1000
    repeat: true
    running: root.popupOpen && root.service && root.service.playing
    onTriggered: root.service.refreshPosition()
  }

  IpcHandler {
    target: "org.renerocksai.neomarchy.player"

    function toggle(): string {
      root.service ? root.service.togglePlayback() : null
      return root.service ? "ok" : "unavailable"
    }
    function stop(): string {
      root.service ? root.service.stop() : null
      return root.service ? "ok" : "unavailable"
    }
    function volumeUp(): string {
      root.service ? root.service.adjustVolume(root.volumeStep) : null
      return root.service ? "ok" : "unavailable"
    }
    function volumeDown(): string {
      root.service ? root.service.adjustVolume(-root.volumeStep) : null
      return root.service ? "ok" : "unavailable"
    }
    function miniPlayer(): string {
      root.broadcast("toggle")
      return "ok"
    }
    function playFavorite(index: string): string {
      if (!root.service)
        return "unavailable"
      return root.service.playFavoriteAt(parseInt(index, 10)) ? "ok" : "no such favorite"
    }
    function playSession(id: string): string {
      if (!root.service)
        return "unavailable"
      return root.service.playById(id) ? "ok" : "unavailable"
    }
    function next(): string {
      if (!root.service)
        return "unavailable"
      return root.service.cycleFavorite(1) ? "ok" : "no favorites"
    }
    function previous(): string {
      if (!root.service)
        return "unavailable"
      return root.service.cycleFavorite(-1) ? "ok" : "no favorites"
    }
    function state(): string {
      if (!root.service)
        return "{}"
      return JSON.stringify({
        loggedIn: root.service.loggedIn,
        playing: root.service.playing,
        buffering: root.service.buffering,
        title: root.service.trackTitle,
        id: root.service.trackId,
        position: Math.round(root.service.positionSeconds),
        length: Math.round(root.service.lengthSeconds),
        volume: Math.round(root.service.volume * 100),
        repeat: root.service.repeat,
        favorites: root.service.favorites.length,
        error: root.service.lastError
      })
    }
  }
}

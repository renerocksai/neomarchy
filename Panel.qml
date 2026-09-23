import QtQuick
import QtQuick.Controls
import Quickshell
import qs.Commons
import qs.Ui

Item {
  id: root

  property var shell: null
  property var manifest: null
  property var service: null
  property bool opened: false
  property bool closingFromHost: false

  readonly property string pluginId: "io.github.renerocksai.neomarchy"
  readonly property color foreground: Color.foreground
  readonly property color background: Color.background
  readonly property color accent: Color.accent
  readonly property string fontFamily: Style.font.resolvedFamily || Style.font.family

  readonly property bool loggedIn: service && service.loggedIn
  readonly property bool searching: service && service.searchQuery !== ""
  readonly property var items: !service ? []
    : (searching ? service.searchResults : service.favorites)
  readonly property bool loadingItems: service
    && (searching ? service.searchLoading : service.favoritesLoading)

  property int selectedIndex: -1

  // ------------------------------------------------------------------ host

  function open(payloadJson) {
    opened = true
    if (service) {
      service.artworkSearchActive = true
      service.refreshStatus()
      if (service.loggedIn)
        service.refreshFavorites(false)
    }
    Qt.callLater(focusSearch)
    requestReveal()
  }

  // Land on the session that is playing rather than the top of the list.
  // Returns false while it still has work to do.
  function revealCurrent() {
    if (!service || service.trackId === "" || searching)
      return true
    for (var i = 0; i < items.length; i++) {
      if (String(items[i].id) === service.trackId) {
        selectedIndex = i
        list.positionViewAtIndex(i, ListView.Contain)
        return list.contentHeight > 0
      }
    }
    return false
  }

  function requestReveal() {
    revealAttempts = 0
    revealTimer.restart()
  }

  property int revealAttempts: 0

  // The favorites arrive a beat after the window opens, and the list needs a
  // layout pass before it can position itself — so keep trying briefly.
  Timer {
    id: revealTimer
    interval: 120
    repeat: true
    onTriggered: {
      root.revealAttempts++
      if (root.revealCurrent() || root.revealAttempts >= 10)
        stop()
    }
  }

  function close() {
    closingFromHost = true
    opened = false
    if (service)
      service.artworkSearchActive = false
    Qt.callLater(function() { root.closingFromHost = false })
  }

  function requestClose() {
    if (service)
      service.artworkSearchActive = false
    if (shell && typeof shell.hide === "function")
      shell.hide(pluginId)
    else
      opened = false
  }

  function focusSearch() {
    if (loggedIn)
      searchField.forceActiveFocus()
    else
      userField.forceActiveFocus()
  }

  // --------------------------------------------------------------- helpers

  function formatTime(seconds) {
    var total = Math.max(0, Math.floor(Number(seconds) || 0))
    var mins = Math.floor(total / 60)
    var secs = total % 60
    return mins + ":" + (secs < 10 ? "0" : "") + secs
  }

  function subtitleFor(item) {
    if (!item)
      return ""
    if (item.reason)
      return String(item.reason)
    var parts = []
    var cats = item.categories || []
    if (cats.length > 0)
      parts.push(String(cats[0]).replace(/-/g, " "))
    if (item.duration)
      parts.push(item.duration + " min")
    else if (item.durationHint)
      parts.push(String(item.durationHint))
    if (item.frequencies)
      parts.push(String(item.frequencies))
    if (item.shortDescription && parts.length < 2)
      parts.push(String(item.shortDescription))
    return parts.join(" · ")
  }

  function playIndex(index) {
    if (index < 0 || index >= items.length || !service)
      return
    selectedIndex = index
    service.play(items[index])
  }

  function moveSelection(delta) {
    if (items.length === 0)
      return
    var next = selectedIndex + delta
    if (next < 0)
      next = 0
    if (next >= items.length)
      next = items.length - 1
    selectedIndex = next
    list.positionViewAtIndex(next, ListView.Contain)
  }

  onItemsChanged: {
    if (selectedIndex >= items.length)
      selectedIndex = items.length - 1
    // The favorites usually arrive after the window is already open, so the
    // reveal has to run again once there is actually something to reveal.
    if (opened)
      requestReveal()
  }

  // ------------------------------------------------------------------ view

  FloatingWindow {
    id: window
    visible: root.opened
    title: "neomarchy"
    color: root.background
    implicitWidth: 940
    implicitHeight: 700
    minimumSize: Qt.size(680, 520)

    onVisibleChanged: {
      if (!visible && root.opened && !root.closingFromHost)
        root.requestClose()
    }

    FocusScope {
      id: focusScope
      anchors.fill: parent
      focus: true

      readonly property bool typingInField: !!(window.activeFocusItem
        && ("acceptableInput" in window.activeFocusItem))

      Keys.onEscapePressed: function(event) {
        if (root.service && root.service.searchQuery !== "") {
          searchField.text = ""
          root.service.clearSearch()
        } else {
          root.requestClose()
        }
        event.accepted = true
      }

      Keys.onPressed: function(event) {
        var ctrl = (event.modifiers & Qt.ControlModifier) !== 0

        if (ctrl && event.key === Qt.Key_F) {
          searchField.forceActiveFocus()
          searchField.selectAll()
          event.accepted = true
          return
        }
        if (!focusScope.typingInField && event.text === "/") {
          searchField.forceActiveFocus()
          searchField.selectAll()
          event.accepted = true
          return
        }
        if (focusScope.typingInField)
          return

        if (event.key === Qt.Key_Down || event.key === Qt.Key_J) {
          root.moveSelection(1)
          event.accepted = true
        } else if (event.key === Qt.Key_Up || event.key === Qt.Key_K) {
          root.moveSelection(-1)
          event.accepted = true
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
          root.playIndex(root.selectedIndex)
          event.accepted = true
        } else if (event.key === Qt.Key_Space) {
          if (root.service)
            root.service.togglePlayback()
          event.accepted = true
        } else if (event.key === Qt.Key_Left) {
          if (root.service)
            root.service.seekBy(-15)
          event.accepted = true
        } else if (event.key === Qt.Key_Right) {
          if (root.service)
            root.service.seekBy(15)
          event.accepted = true
        }
      }

      Item {
        anchors.fill: parent
        anchors.margins: Style.space(16)

        // ------------------------------------------------------- header

        Item {
          id: header
          anchors.top: parent.top
          anchors.left: parent.left
          anchors.right: parent.right
          height: Style.space(46)

          Column {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.spacing.xxs

            Text {
              text: "neomarchy"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
              font.bold: true
            }

            Text {
              text: {
                if (!root.service)
                  return ""
                if (!root.service.loggedIn)
                  return "Sign in to your membership"
                var bits = [root.service.catalogCount + " sessions",
                            root.service.favorites.length + " favorites"]
                if (root.service.cachedTracks > 0)
                  bits.push(root.service.cachedTracks + " offline")
                return bits.join(" · ")
              }
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              opacity: 0.6
            }
          }

          Row {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.spacing.md

            Button {
              iconText: "󰑐"
              foreground: root.foreground
              visible: root.loggedIn
              enabled: root.service && !root.service.catalogRefreshing
              tooltipText: root.service && root.service.catalogRefreshing
                ? "Refreshing the catalog…" : "Refresh catalog and favorites"
              onClicked: {
                root.service.refreshCatalog(true)
                root.service.refreshFavorites(true)
              }
            }

            Button {
              iconText: "󰗼"
              foreground: root.foreground
              visible: root.loggedIn
              tooltipText: "Sign out"
              onClicked: root.service.logout(false)
            }

            Button {
              iconText: "󰅖"
              foreground: root.foreground
              tooltipText: "Close"
              onClicked: root.requestClose()
            }
          }
        }

        // ------------------------------------------------------- banner

        BorderSurface {
          id: banner
          anchors.top: header.bottom
          anchors.topMargin: visible ? Style.spacing.lg : 0
          anchors.left: parent.left
          anchors.right: parent.right
          height: visible ? bannerText.implicitHeight + Style.space(14) : 0
          visible: root.service
            && (root.service.lastError !== "" || root.service.statusMessage !== "")
          radius: Style.cornerRadius
          color: root.service && root.service.lastError !== ""
            ? Style.selectedFillFor(root.foreground, Color.urgent)
            : Style.normalFillFor(root.foreground, root.accent)
          borderSpec: Border.controlSpec("normal", root.foreground,
            root.service && root.service.lastError !== "" ? Color.urgent : root.accent)

          Text {
            id: bannerText
            anchors.centerIn: parent
            width: parent.width - Style.space(20)
            // Helper errors can quote server-supplied text; keep it literal.
            textFormat: Text.PlainText
            text: root.service
              ? (root.service.lastError !== ""
                ? root.service.lastError : root.service.statusMessage) : ""
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }
        }

        // ------------------------------------------------------- search

        Item {
          id: searchBar
          anchors.top: banner.bottom
          anchors.topMargin: Style.spacing.xl
          anchors.left: parent.left
          anchors.right: parent.right
          height: root.loggedIn ? Style.space(34) : 0
          visible: root.loggedIn

          ButtonGroup {
            id: modes
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            foreground: root.foreground
            accent: root.accent
            fontFamily: root.fontFamily
            options: [
              { value: "keyword", label: "Keyword", tooltip: "Search the neowake library" },
              { value: "local", label: "Instant", tooltip: "Filter your downloaded catalog" },
              { value: "ai", label: "AI", tooltip: "Describe a goal in a sentence" },
              { value: "frequency", label: "Hz", tooltip: "Search by frequency" }
            ]
            value: root.service ? root.service.searchMode : "keyword"
            onChanged: function(mode) {
              if (!root.service)
                return
              root.service.searchMode = mode
              if (searchField.text.trim() !== "")
                root.service.search(searchField.text, mode)
            }
          }

          TextField {
            id: searchField
            anchors.left: parent.left
            anchors.right: modes.left
            anchors.rightMargin: Style.spacing.xl
            anchors.verticalCenter: parent.verticalCenter
            foreground: root.foreground
            accent: root.accent
            placeholderText: {
              if (!root.service)
                return "Search"
              if (root.service.searchMode === "ai")
                return "Describe what you want to achieve…"
              if (root.service.searchMode === "frequency")
                return "A frequency, e.g. 528 Hz"
              if (root.service.searchMode === "local")
                return "Filter your session catalog"
              return "Search neowake sessions"
            }
            font.family: root.fontFamily
            font.pixelSize: Style.font.body

            onTextEdited: {
              if (text.trim() === "") {
                searchDebounce.stop()
                root.service && root.service.clearSearch()
              } else if (root.service && root.service.searchMode === "local") {
                root.service.search(text, "local") // local filtering is free
              } else {
                searchDebounce.restart()
              }
            }
            onAccepted: {
              searchDebounce.stop()
              if (root.service && text.trim() !== "")
                root.service.search(text, root.service.searchMode)
            }
            Keys.onDownPressed: {
              focusScope.forceActiveFocus()
              root.moveSelection(root.selectedIndex < 0 ? 1 : 1)
            }
          }

          // The AI endpoint costs them money on every call — never fire it
          // mid-word.
          Timer {
            id: searchDebounce
            interval: root.service && root.service.searchMode === "ai" ? 900 : 450
            onTriggered: {
              if (root.service && searchField.text.trim() !== "")
                root.service.search(searchField.text, root.service.searchMode)
            }
          }
        }

        // ------------------------------------------------------- content

        Item {
          id: content
          anchors.top: searchBar.bottom
          anchors.topMargin: root.loggedIn ? Style.spacing.xl : 0
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: footerSeparator.top
          anchors.bottomMargin: Style.spacing.xl

          // -- login ---------------------------------------------------

          Column {
            anchors.centerIn: parent
            width: Math.min(parent.width, Style.space(360))
            spacing: Style.spacing.xl
            visible: root.service && !root.service.loggedIn

            Text {
              width: parent.width
              text: "Sign in to neowake"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
            }

            Text {
              width: parent.width
              text: "Your password goes straight into the system keyring. "
                + "It is never written to a config file."
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              opacity: 0.6
              wrapMode: Text.WordWrap
            }

            TextField {
              id: userField
              width: parent.width
              foreground: root.foreground
              accent: root.accent
              placeholderText: "Username or email"
              font.family: root.fontFamily
              text: root.service ? root.service.username : ""
              onAccepted: passField.forceActiveFocus()
            }

            TextField {
              id: passField
              width: parent.width
              foreground: root.foreground
              accent: root.accent
              placeholderText: "Password"
              password: true
              font.family: root.fontFamily
              onAccepted: root.submitLogin()
            }

            Text {
              width: parent.width
              visible: root.service && root.service.loginError !== ""
              // The login failure reason is lifted out of the site's HTML.
              textFormat: Text.PlainText
              text: root.service ? root.service.loginError : ""
              color: Color.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            Button {
              width: parent.width
              text: root.service && root.service.loginBusy ? "Signing in…" : "Sign in"
              foreground: root.foreground
              accent: root.accent
              bordered: true
              enabled: root.service && !root.service.loginBusy
                && userField.text.trim() !== "" && passField.text !== ""
              onClicked: root.submitLogin()
            }
          }

          // -- list ----------------------------------------------------

          // Say out loud which list this is — an unlabelled list of eleven
          // sessions is not obviously "your favorites".
          Item {
            id: sectionHeader
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            height: root.loggedIn ? sectionLabel.implicitHeight + Style.spacing.lg : 0
            visible: root.loggedIn

            PanelSectionHeader {
              id: sectionLabel
              anchors.left: parent.left
              anchors.top: parent.top
              foreground: root.foreground
              fontFamily: root.fontFamily
              text: root.searching
                ? "RESULTS FOR “" + root.service.searchQuery + "”"
                : "YOUR FAVORITES"
            }

            Text {
              anchors.right: parent.right
              anchors.verticalCenter: sectionLabel.verticalCenter
              text: {
                if (root.loadingItems)
                  return "…"
                if (!root.searching)
                  return root.items.length + " saved on neowake"
                return root.items.length + " found · Esc to go back to favorites"
              }
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              opacity: 0.45
            }
          }

          Text {
            anchors.centerIn: parent
            visible: root.loggedIn && root.items.length === 0
            text: {
              if (root.loadingItems)
                return root.searching ? "Searching…" : "Loading your favorites…"
              if (root.searching)
                return "Nothing matched that."
              return "No favorites yet — search above to find a session."
            }
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            opacity: 0.6
          }

          ListView {
            id: list
            anchors.top: sectionHeader.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            visible: root.loggedIn && root.items.length > 0
            model: root.items
            clip: true
            spacing: Style.spacing.xs
            reuseItems: true
            cacheBuffer: Style.space(180)
            keyNavigationEnabled: false
            currentIndex: root.selectedIndex

            // Resizing the window changes how many rows fit, which can push the
            // playing session out of view — put it back.
            onHeightChanged: if (root.opened) root.requestReveal()
            ScrollBar.vertical: ScrollBar {}

            delegate: SessionRow {
              required property var modelData
              required property int index

              width: list.width
              item: modelData
              artSource: root.opened && root.service
                ? root.service.artUrl(modelData) : ""
              rowIndex: index
              foreground: root.foreground
              accent: root.accent
              fontFamily: root.fontFamily
              selected: index === root.selectedIndex
              nowPlaying: root.service && root.service.trackId === String(modelData.id)
              favorite: root.service && root.service.isFavorite(modelData.id)
              subtitle: root.subtitleFor(modelData)

              onActivated: root.playIndex(index)
              onHovered: root.selectedIndex = index
              onFavoriteToggled: root.service && root.service.toggleFavorite(modelData.id)
              onCacheToggled: {
                if (!root.service)
                  return
                if (modelData.cached)
                  root.service.uncacheTrack(modelData.id)
                else
                  root.service.cacheTrack(modelData.id)
              }
            }
          }
        }

        // ------------------------------------------------------- footer

        PanelSeparator {
          id: footerSeparator
          anchors.bottom: footer.top
          anchors.bottomMargin: Style.spacing.xl
          foreground: root.foreground
          visible: root.service && root.service.hasTrack
        }

        Item {
          id: footer
          anchors.bottom: parent.bottom
          anchors.left: parent.left
          anchors.right: parent.right
          height: root.service && root.service.hasTrack ? Style.space(72) : 0
          visible: height > 0

          BorderSurface {
            id: footerArt
            width: Style.space(58)
            height: width
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            radius: Style.cornerRadius
            color: Style.normalFillFor(root.foreground, root.accent)
            borderSpec: Border.controlSpec("normal", root.foreground, root.accent)

            Image {
              id: footerImage
              anchors.fill: parent
              anchors.margins: Style.space(2)
              source: root.opened && root.service ? root.service.trackArtUrl : ""
              sourceSize.width: 116
              sourceSize.height: 116
              fillMode: Image.PreserveAspectCrop
              asynchronous: true
              cache: true
              visible: status === Image.Ready
            }

            Text {
              anchors.centerIn: parent
              visible: footerImage.status !== Image.Ready
              text: "󰝚"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
              opacity: 0.5
            }
          }

          Column {
            id: footerText
            anchors.left: footerArt.right
            anchors.leftMargin: Style.spacing.xxl
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(200)
            spacing: Style.spacing.xxs

            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: root.service ? root.service.trackTitle : ""
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              elide: Text.ElideRight
            }

            Text {
              width: parent.width
              text: {
                if (!root.service)
                  return ""
                if (root.service.buffering)
                  return "buffering…"
                var track = root.service.currentTrack
                return track && track.cached ? "offline copy" : "streaming"
              }
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              opacity: 0.55
              elide: Text.ElideRight
            }
          }

          Row {
            id: transport
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: parent.top
            anchors.topMargin: Style.spacing.xs
            spacing: Style.spacing.lg

            Button {
              iconText: root.service && root.service.currentIsFavorite ? "󰋑" : "󰋕"
              foreground: root.foreground
              tooltipText: "Favorite"
              onClicked: root.service && root.service.toggleFavorite(root.service.trackId)
            }

            Button {
              iconText: root.service && root.service.playing ? "󰏤" : "󰐊"
              iconSize: Style.font.iconLarge
              foreground: root.foreground
              selected: root.service && root.service.playing
              tooltipText: root.service && root.service.playing ? "Pause (Space)" : "Play (Space)"
              onClicked: root.service && root.service.togglePlayback()
            }

            Button {
              iconText: "󰓛"
              foreground: root.foreground
              tooltipText: "Stop"
              onClicked: root.service && root.service.stop()
            }

            Button {
              iconText: "󰑖"
              foreground: root.foreground
              selected: root.service && root.service.repeat
              tooltipText: "Repeat"
              onClicked: root.service && root.service.toggleRepeat()
            }
          }

          Item {
            anchors.left: transport.left
            anchors.right: transport.right
            anchors.bottom: parent.bottom
            anchors.bottomMargin: Style.spacing.xs
            height: Style.space(20)

            Text {
              id: elapsed
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: root.formatTime(root.service ? root.service.positionSeconds : 0)
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              opacity: 0.6
            }

            Text {
              id: total
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: root.formatTime(root.service ? root.service.lengthSeconds : 0)
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              opacity: 0.6
            }

            PanelSlider {
              anchors.left: elapsed.right
              anchors.right: total.left
              anchors.leftMargin: Style.spacing.lg
              anchors.rightMargin: Style.spacing.lg
              anchors.verticalCenter: parent.verticalCenter
              minimum: 0
              maximum: Math.max(1, root.service ? root.service.lengthSeconds : 1)
              value: root.service ? root.service.positionSeconds : 0
              step: 15
              enabled: root.service && root.service.lengthSeconds > 0
              onReleased: function(v) { root.service && root.service.seekSeconds(v) }
            }
          }

          Item {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(140)
            height: Style.space(24)

            Text {
              id: volumeGlyph
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: root.service && root.service.volume <= 0 ? "󰝟" : "󰕾"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.icon
            }

            PanelSlider {
              anchors.left: volumeGlyph.right
              anchors.leftMargin: Style.spacing.lg
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              minimum: 0
              maximum: 1
              step: 0.05
              value: root.service ? root.service.volume : 0
              onMoved: function(v) { root.service && root.service.setVolume(v) }
              onReleased: function(v) { root.service && root.service.setVolume(v) }
            }
          }
        }
      }
    }
  }

  function submitLogin() {
    if (!service)
      return
    service.login(userField.text.trim(), passField.text)
    passField.text = ""
  }

  Connections {
    target: root.service
    function onTrackIdChanged() {
      if (root.opened)
        root.requestReveal()
    }
  }

  Timer {
    interval: 1000
    repeat: true
    running: root.opened && root.service && root.service.playing
    onTriggered: root.service.refreshPosition()
  }
}

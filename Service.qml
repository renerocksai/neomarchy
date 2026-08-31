import QtQuick
import Quickshell
import Quickshell.Io

// Shared state for the neomarchy plugin: one mpv instance driven over its JSON
// IPC socket, and every piece of catalogue data fetched through bin/neowake.
Item {
  id: root

  property var shell: null
  property var manifest: null

  // ---------------------------------------------------------------- helper

  readonly property string helperPath:
    String(Qt.resolvedUrl("bin/neowake")).replace(/^file:\/\//, "")

  // ---------------------------------------------------------------- account

  property bool loggedIn: false
  property string username: ""
  property bool hasStoredPassword: false
  property int catalogCount: 0
  property int catalogAge: -1
  property int cachedTracks: 0
  property bool statusLoading: false

  property bool loginBusy: false
  property bool loginNeedsOtp: false
  property string loginError: ""

  // ---------------------------------------------------------------- library

  property var favorites: []
  property bool favoritesLoading: false
  property var favoriteIds: ({})

  property var searchResults: []
  property bool searchLoading: false
  property string searchQuery: ""
  property string searchMode: "keyword"

  property bool catalogRefreshing: false

  // ---------------------------------------------------------------- playback

  property var currentTrack: null
  property bool playing: false
  property bool buffering: false
  property real positionSeconds: 0
  property real lengthSeconds: 0
  property real volume: 0.7
  property bool repeat: false
  property bool mpvRunning: false
  // mpvRunning only says the process is alive. At end of file mpv unloads the
  // track and idles, so the controls need to know a file is actually loaded.
  property bool fileLoaded: false

  property string statusMessage: ""
  property string lastError: ""

  readonly property bool hasTrack: currentTrack !== null
  readonly property string trackTitle: currentTrack ? (currentTrack.title || "") : ""
  readonly property string trackArtUrl: currentTrack ? (currentTrack.thumb || "") : ""
  readonly property string trackId: currentTrack ? String(currentTrack.id || "") : ""
  readonly property bool currentIsFavorite: trackId !== "" && isFavorite(trackId)

  readonly property string socketPath:
    (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/omarchy-neomarchy-mpv.sock"

  signal trackStarted(var item)

  // ------------------------------------------------------------------------
  // helper plumbing
  // ------------------------------------------------------------------------

  function parseHelper(raw) {
    try {
      return JSON.parse(String(raw || "").trim())
    } catch (e) {
      return null
    }
  }

  function helperFailed(payload, stderrText, fallback) {
    if (payload && payload.ok === false && payload.error)
      return String(payload.error)
    var text = String(stderrText || "").trim()
    if (text !== "")
      return text.split("\n").pop()
    return fallback
  }

  function note(message) {
    statusMessage = message
    lastError = ""
    statusClear.restart()
  }

  function fail(message) {
    lastError = message
    statusMessage = ""
    statusClear.restart()
  }

  Timer {
    id: statusClear
    interval: 6000
    onTriggered: {
      root.statusMessage = ""
      root.lastError = ""
    }
  }

  // ------------------------------------------------------------------------
  // account
  // ------------------------------------------------------------------------

  function refreshStatus() {
    if (statusProcess.running)
      return
    statusLoading = true
    statusProcess.command = [helperPath, "status"]
    statusProcess.running = true
  }

  function login(user, password, otp) {
    if (loginProcess.running || !user || !password)
      return
    loginBusy = true
    loginError = ""
    loginNeedsOtp = false
    loginPassword = password
    var argv = [helperPath, "login", "--user", String(user), "--password-stdin"]
    if (otp && String(otp) !== "")
      argv = argv.concat(["--otp", String(otp)])
    loginProcess.command = argv
    loginProcess.running = true
  }

  function logout(forget) {
    var argv = [helperPath, "logout"]
    if (forget)
      argv.push("--forget")
    runAction(argv, "Signed out of neowake")
  }

  property string loginPassword: ""

  Process {
    id: statusProcess
    stdout: StdioCollector { id: statusOut; waitForEnd: true }
    onExited: function(exitCode) {
      root.statusLoading = false
      var payload = root.parseHelper(statusOut.text)
      if (exitCode !== 0 || !payload || payload.ok !== true)
        return
      root.loggedIn = payload.loggedIn === true
      root.username = payload.username || ""
      root.hasStoredPassword = payload.hasStoredPassword === true
      root.catalogCount = payload.catalogCount || 0
      root.catalogAge = payload.catalogAge === null ? -1 : payload.catalogAge
      root.cachedTracks = payload.cachedTracks || 0
      if (root.loggedIn && root.favorites.length === 0)
        root.refreshFavorites(false)
    }
  }

  Process {
    id: loginProcess
    stdinEnabled: true
    stdout: StdioCollector { id: loginOut; waitForEnd: true }
    stderr: StdioCollector { id: loginErr; waitForEnd: true }
    onStarted: {
      // The password only ever travels down this pipe.
      write(root.loginPassword + "\n")
      root.loginPassword = ""
    }
    onExited: function(exitCode) {
      root.loginBusy = false
      var payload = root.parseHelper(loginOut.text)
      if (exitCode === 0 && payload && payload.state === "otp-required") {
        root.loginNeedsOtp = true
        root.loginError = "Two-factor code required"
        return
      }
      if (exitCode !== 0 || !payload || payload.ok !== true) {
        root.loginError = root.helperFailed(payload, loginErr.text, "Login failed")
        return
      }
      root.loginNeedsOtp = false
      root.loginError = ""
      root.note("Signed in as " + (payload.username || ""))
      root.refreshStatus()
      root.refreshFavorites(true)
      root.refreshCatalog(false)
    }
  }

  // ------------------------------------------------------------------------
  // favorites
  // ------------------------------------------------------------------------

  function refreshFavorites(force) {
    if (favoritesProcess.running)
      return
    favoritesLoading = true
    var argv = [helperPath, "favorites"]
    if (force)
      argv.push("--refresh")
    favoritesProcess.command = argv
    favoritesProcess.running = true
  }

  function isFavorite(id) {
    return favoriteIds[String(id)] === true
  }

  function toggleFavorite(id) {
    if (!id || favProcess.running)
      return
    var key = String(id)
    // Flip locally first; the helper answers with the authoritative value.
    var next = {}
    for (var existing in favoriteIds)
      next[existing] = favoriteIds[existing]
    next[key] = !isFavorite(key)
    favoriteIds = next

    favProcess.command = [helperPath, "fav", "toggle", key]
    favProcess.running = true
  }

  Process {
    id: favoritesProcess
    stdout: StdioCollector { id: favoritesOut; waitForEnd: true }
    stderr: StdioCollector { id: favoritesErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.favoritesLoading = false
      var payload = root.parseHelper(favoritesOut.text)
      if (exitCode !== 0 || !payload || payload.ok !== true) {
        root.fail(root.helperFailed(payload, favoritesErr.text,
          "Could not load your favorites"))
        return
      }
      root.favorites = payload.favorites || []
      var ids = {}
      for (var i = 0; i < root.favorites.length; i++)
        ids[String(root.favorites[i].id)] = true
      root.favoriteIds = ids
    }
  }

  Process {
    id: favProcess
    stdout: StdioCollector { id: favOut; waitForEnd: true }
    stderr: StdioCollector { id: favErr; waitForEnd: true }
    onExited: function(exitCode) {
      var payload = root.parseHelper(favOut.text)
      if (exitCode !== 0 || !payload || payload.ok !== true) {
        root.fail(root.helperFailed(payload, favErr.text,
          "Could not update your favorites"))
        root.refreshFavorites(true)
        return
      }
      root.note(payload.favorite ? "Added to favorites" : "Removed from favorites")
      root.refreshFavorites(true)
    }
  }

  // ------------------------------------------------------------------------
  // search
  // ------------------------------------------------------------------------

  function search(query, mode) {
    var text = String(query || "").trim()
    searchQuery = text
    if (mode)
      searchMode = mode

    if (text === "") {
      clearSearch()
      return
    }
    if (searchProcess.running)
      searchProcess.running = false

    searchLoading = true
    searchProcess.command = [helperPath, "search", text, "--mode", searchMode]
    searchProcess.running = true
  }

  function clearSearch() {
    if (searchProcess.running)
      searchProcess.running = false
    searchLoading = false
    searchResults = []
    searchQuery = ""
  }

  Process {
    id: searchProcess
    stdout: StdioCollector { id: searchOut; waitForEnd: true }
    stderr: StdioCollector { id: searchErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.searchLoading = false
      var payload = root.parseHelper(searchOut.text)
      if (exitCode !== 0 || !payload || payload.ok !== true) {
        root.searchResults = []
        root.fail(root.helperFailed(payload, searchErr.text, "Search failed"))
        return
      }
      if (payload.query !== root.searchQuery)
        return // a newer query already went out
      root.searchResults = payload.results || []
    }
  }

  // ------------------------------------------------------------------------
  // catalog
  // ------------------------------------------------------------------------

  function refreshCatalog(force) {
    if (catalogProcess.running)
      return
    catalogRefreshing = true
    var argv = [helperPath, "catalog"]
    if (force)
      argv.push("--refresh")
    catalogProcess.command = argv
    catalogProcess.running = true
  }

  Process {
    id: catalogProcess
    stdout: StdioCollector { id: catalogOut; waitForEnd: true }
    onExited: function() {
      root.catalogRefreshing = false
      var payload = root.parseHelper(catalogOut.text)
      if (payload && payload.ok === true)
        root.catalogCount = payload.count || 0
      root.refreshStatus()
    }
  }

  // ------------------------------------------------------------------------
  // one-shot actions (cache, logout, enrich)
  // ------------------------------------------------------------------------

  property string actionSuccessNote: ""

  function runAction(argv, successNote) {
    if (actionProcess.running)
      return
    actionSuccessNote = successNote || ""
    actionProcess.command = argv
    actionProcess.running = true
  }

  function cacheTrack(id) {
    if (!id)
      return
    runAction([helperPath, "cache", "add", String(id)], "Saved for offline use")
  }

  function uncacheTrack(id) {
    if (!id)
      return
    runAction([helperPath, "cache", "remove", String(id)], "Removed the offline copy")
  }

  Process {
    id: actionProcess
    stdout: StdioCollector { id: actionOut; waitForEnd: true }
    stderr: StdioCollector { id: actionErr; waitForEnd: true }
    onExited: function(exitCode) {
      var payload = root.parseHelper(actionOut.text)
      if (exitCode !== 0 || !payload || payload.ok !== true) {
        root.fail(root.helperFailed(payload, actionErr.text, "That did not work"))
      } else if (root.actionSuccessNote !== "") {
        root.note(root.actionSuccessNote)
      }
      root.refreshStatus()
    }
  }

  // ------------------------------------------------------------------------
  // playback
  // ------------------------------------------------------------------------

  property var pendingTrack: null
  property bool cacheOnPlay: false

  function play(item) {
    if (!item)
      return
    var id = String(item.id || "")
    currentTrack = item
    positionSeconds = 0
    lengthSeconds = Number(item.duration || 0) * 60 > 0 ? 0 : 0
    buffering = true
    lastError = ""

    if (item.playUrl) {
      startUrl(item.playUrl)
      return
    }
    // Resolve id -> CDN url (or the offline copy) before handing it to mpv.
    pendingTrack = item
    if (resolveProcess.running)
      resolveProcess.running = false
    resolveProcess.command = [helperPath, "resolve", id]
    resolveProcess.running = true
  }

  function playFavoriteAt(index) {
    if (index < 0 || index >= favorites.length)
      return false
    play(favorites[index])
    return true
  }

  function playById(id) {
    var key = String(id || "")
    if (key === "")
      return false
    for (var i = 0; i < favorites.length; i++) {
      if (String(favorites[i].id) === key) {
        play(favorites[i])
        return true
      }
    }
    // Unknown session: resolve fills in the title and cover a moment later.
    play({ id: key, title: "…" })
    return true
  }

  function cycleFavorite(delta) {
    if (favorites.length === 0)
      return false
    var current = -1
    for (var i = 0; i < favorites.length; i++) {
      if (String(favorites[i].id) === trackId) {
        current = i
        break
      }
    }
    var next = current < 0 ? 0
      : (current + delta + favorites.length) % favorites.length
    return playFavoriteAt(next)
  }

  Process {
    id: resolveProcess
    stdout: StdioCollector { id: resolveOut; waitForEnd: true }
    stderr: StdioCollector { id: resolveErr; waitForEnd: true }
    onExited: function(exitCode) {
      var payload = root.parseHelper(resolveOut.text)
      var wanted = root.pendingTrack
      root.pendingTrack = null
      if (exitCode !== 0 || !payload || payload.ok !== true) {
        root.buffering = false
        root.fail(root.helperFailed(payload, resolveErr.text,
          "Could not open that session"))
        return
      }
      if (!wanted || String(wanted.id) !== String(payload.id))
        return // superseded by a newer pick

      var merged = {}
      for (var key in wanted)
        merged[key] = wanted[key]
      merged.id = payload.id
      merged.slug = payload.slug
      merged.title = payload.title || wanted.title
      merged.thumb = payload.thumb || wanted.thumb
      merged.audio = payload.audio
      merged.playUrl = payload.playUrl
      merged.cached = payload.cached === true
      root.currentTrack = merged
      root.startUrl(payload.playUrl)
    }
  }

  function startUrl(url) {
    if (!url)
      return
    ensureMpv()
    mpvPendingUrl = String(url)
    flushPendingUrl()
  }

  property string mpvPendingUrl: ""

  function flushPendingUrl() {
    if (mpvPendingUrl === "" || !mpvSocket.connected)
      return
    var url = mpvPendingUrl
    mpvPendingUrl = ""
    sendMpv(["set_property", "pause", false])
    sendMpv(["loadfile", url])
    sendMpv(["set_property", "loop-file", repeat ? "inf" : "no"])
    sendMpv(["set_property", "volume", Math.round(volume * 100)])
    if (currentTrack && currentTrack.title)
      sendMpv(["set_property", "force-media-title", String(currentTrack.title)])
    trackStarted(currentTrack)
    if (cacheOnPlay && currentTrack && !currentTrack.cached)
      cacheTrack(currentTrack.id)
  }

  function togglePlayback() {
    if (!hasTrack)
      return
    if (!mpvRunning || !fileLoaded) {
      play(currentTrack)
      return
    }
    sendMpv(["cycle", "pause"])
  }

  function stop() {
    if (!mpvRunning)
      return
    sendMpv(["stop"])
    fileLoaded = false
    playing = false
    buffering = false
    positionSeconds = 0
  }

  function seekSeconds(value) {
    if (!mpvRunning || !fileLoaded || lengthSeconds <= 0)
      return
    // Landing exactly on the duration ends the file, so keep a little headroom
    // at the right edge of the slider.
    var limit = Math.max(0, lengthSeconds - 1)
    var target = Math.max(0, Math.min(limit, value))
    positionSeconds = target
    sendMpv(["seek", target, "absolute"])
  }

  function seekBy(delta) {
    seekSeconds(positionSeconds + delta)
  }

  function setVolume(value) {
    var next = Math.max(0, Math.min(1, value))
    volume = next
    if (mpvRunning)
      sendMpv(["set_property", "volume", Math.round(next * 100)])
  }

  function adjustVolume(delta) {
    setVolume(volume + delta)
  }

  function setRepeat(enabled) {
    repeat = enabled === true
    if (mpvRunning)
      sendMpv(["set_property", "loop-file", repeat ? "inf" : "no"])
  }

  function toggleRepeat() {
    setRepeat(!repeat)
  }

  // ------------------------------------------------------------------------
  // mpv process + IPC
  // ------------------------------------------------------------------------

  function ensureMpv() {
    if (mpvProcess.running)
      return
    mpvProcess.command = [
      "mpv",
      "--idle=yes",
      "--no-video",
      "--no-terminal",
      "--force-window=no",
      "--keep-open=no",
      "--volume=" + Math.round(volume * 100),
      "--cache=yes",
      "--input-ipc-server=" + socketPath
    ]
    mpvProcess.running = true
    socketRetry.restart()
  }

  function sendMpv(command) {
    if (!mpvSocket.connected)
      return false
    mpvSocket.write(JSON.stringify({ command: command }) + "\n")
    mpvSocket.flush()
    return true
  }

  Process {
    id: mpvProcess
    onStarted: root.mpvRunning = true
    onExited: {
      root.mpvRunning = false
      root.fileLoaded = false
      root.playing = false
      root.buffering = false
      mpvSocket.connected = false
      socketRetry.stop()
    }
  }

  // mpv needs a moment to create the socket after it starts.
  Timer {
    id: socketRetry
    interval: 120
    repeat: true
    triggeredOnStart: false
    onTriggered: {
      if (!mpvProcess.running) {
        stop()
        return
      }
      if (mpvSocket.connected) {
        stop()
        return
      }
      mpvSocket.connected = true
    }
  }

  Socket {
    id: mpvSocket
    path: root.socketPath
    parser: SplitParser {
      splitMarker: "\n"
      onRead: function(line) { root.handleMpvLine(line) }
    }
    onConnectionStateChanged: {
      if (!connected)
        return
      socketRetry.stop()
      root.sendMpv(["observe_property", 1, "pause"])
      root.sendMpv(["observe_property", 2, "duration"])
      root.sendMpv(["observe_property", 3, "volume"])
      root.sendMpv(["observe_property", 4, "core-idle"])
      root.flushPendingUrl()
    }
  }

  function handleMpvLine(line) {
    var message = null
    try {
      message = JSON.parse(String(line))
    } catch (e) {
      return
    }
    if (!message)
      return

    if (message.event === "property-change") {
      if (message.name === "pause") {
        playing = fileLoaded && message.data === false
        if (playing)
          buffering = false
      } else if (message.name === "duration") {
        lengthSeconds = Number(message.data) || 0
      } else if (message.name === "volume") {
        var level = Number(message.data)
        if (isFinite(level))
          volume = Math.max(0, Math.min(1, level / 100))
      } else if (message.name === "core-idle") {
        if (message.data === true && playing)
          buffering = true
        else if (message.data === false)
          buffering = false
      }
      return
    }

    if (message.event === "file-loaded") {
      fileLoaded = true
      buffering = false
      playing = true
      return
    }
    if (message.event === "end-file") {
      fileLoaded = false
      playing = false
      buffering = false
      positionSeconds = 0
      if (message.reason === "error")
        fail("Playback failed — the session could not be streamed")
      return
    }

    // Answers to get_property carry a request_id we set when asking.
    if (message.request_id === 100 && message.error === "success") {
      var value = Number(message.data)
      if (isFinite(value))
        positionSeconds = value
    }
  }

  function refreshPosition() {
    if (!mpvSocket.connected)
      return
    mpvSocket.write(JSON.stringify({
      command: ["get_property", "time-pos"],
      request_id: 100
    }) + "\n")
    mpvSocket.flush()
  }

  Component.onCompleted: refreshStatus()

  Component.onDestruction: {
    if (mpvProcess.running)
      mpvProcess.signal(15)
  }
}

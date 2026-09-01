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

  // mpv's control socket, and the directory we put it in.
  //
  // Never under /tmp: XDG_RUNTIME_DIR is the per-user directory the session
  // manager creates mode 0700, so nothing inside it is reachable by another
  // user. If the session has no XDG_RUNTIME_DIR we refuse to start mpv rather
  // than fall back to a shared directory.
  //
  // The socket lives one level down, in a directory claimed with a bare mkdir.
  // That is the part that actually matters: mkdir without -p fails if the name
  // is taken, so the claim is atomic and we only ever hand mpv a path inside a
  // directory this process just created. A random name alone would not be
  // enough — it would only make a collision unlikely, and mpv unlinks whatever
  // already sits at its --input-ipc-server path, so losing that race destroys
  // the file that was there.
  property string socketDir: ""
  property string socketPath: ""
  property int socketAttempts: 0

  function newSocketDir() {
    var base = String(Quickshell.env("XDG_RUNTIME_DIR") || "")
    if (base === "")
      return ""
    var unique = Math.floor(Math.random() * 0x100000000).toString(16)
      + "-" + Date.now().toString(16)
    return base + "/neomarchy-" + unique
  }

  signal trackStarted(var item)

  // ------------------------------------------------------------------------
  // helper plumbing
  // ------------------------------------------------------------------------

  // StdioCollector has no size limit of its own, so the bound is enforced at
  // both ends: bin/neowake caps every response it parses and every collection
  // it emits, and anything that still arrives oversized is refused here rather
  // than handed to JSON.parse.
  //
  // This check is a backstop, not the actual bound. StdioCollector buffers the
  // whole stream before anything here can look at it, so by the time the length
  // is testable the memory has already been spent — the real limit has to live
  // in the helper, and it does: bin/neowake refuses to print more than
  // MAX_OUTPUT_BYTES (2 MiB) and substitutes an error instead. 4 MB here simply
  // catches a helper that is not the one we shipped. Measured real outputs are
  // nowhere near either number: 149 KB for the full catalogue, 16 KB for a
  // 20-result search, 429 bytes for resolve, 162 bytes for status.
  readonly property int maxHelperOutput: 4 * 1024 * 1024

  // A measured catalogue refresh crawls 28 index pages in 33 s, and the helper
  // will follow up to MAX_INDEX_PAGES (40). 300 s is ~9x the measured time,
  // which leaves room for a slow connection without letting a wedged crawl sit
  // there forever. Everything else is sub-second in practice, so 45 s is
  // already generous; sign-in gets 60 s because it can involve a second
  // round trip for a one-time code.
  readonly property int helperTimeoutMs: 45000
  readonly property int catalogTimeoutMs: 300000

  // Keeping a session offline downloads the whole file: a measured session is
  // 216 MB, which the generic 45 s deadline could only ever meet on a ~38 Mbit
  // link — below that the download would be killed every single time, and with
  // cacheOnPlay enabled that is on every play. 30 minutes covers the same file
  // on a ~1 Mbit connection.
  readonly property int downloadTimeoutMs: 1800000

  function parseHelper(raw) {
    var text = String(raw || "")
    if (text.length > maxHelperOutput)
      return null
    try {
      return JSON.parse(text.trim())
    } catch (e) {
      return null
    }
  }

  // Every helper run gets a deadline. Without this a wedged process would hold
  // its StdioCollector, and the operation it belongs to, open forever.
  property var watchedProcs: []

  function guard(proc, label, timeoutMs) {
    // Replace any existing entry for this Process rather than appending. The
    // same Process object is reused every time an operation restarts — the
    // panel re-runs search on a 450 ms debounce, and play() restarts resolve —
    // so appending would leave the previous run's deadline behind, and that
    // stale deadline would fire against whatever newer operation was running.
    var next = []
    for (var i = 0; i < watchedProcs.length; i++) {
      if (watchedProcs[i].proc !== proc)
        next.push(watchedProcs[i])
    }
    next.push({
      proc: proc,
      label: label,
      deadline: Date.now() + (timeoutMs || helperTimeoutMs)
    })
    watchedProcs = next
    watchdog.start()
  }

  Timer {
    id: watchdog
    interval: 1000
    repeat: true
    onTriggered: {
      var now = Date.now()
      var still = []
      for (var i = 0; i < root.watchedProcs.length; i++) {
        var w = root.watchedProcs[i]
        if (!w.proc.running)
          continue
        if (now >= w.deadline) {
          // One SIGTERM and we are done. bin/neowake installs a handler that
          // turns it into a normal unwind, so the `finally` that removes a
          // partly downloaded file runs and the process exits on its own
          // (verified: exit 143, promptly, even mid-download).
          //
          // No SIGKILL escalation on purpose. It would only matter for a helper
          // that ignores SIGTERM, which this one cannot, and the bookkeeping it
          // needed — a grace deadline, a kill flag, a pid check to avoid
          // signalling a successor — was itself the source of worse bugs than
          // the one it prevented.
          //
          // Deliberately NOT `running = false`: on a Process whose child is
          // still alive that does not terminate anything, it cancels the
          // command a newer run has already queued on the same Process — so
          // the user's next search or track would silently never start.
          w.proc.signal(15)
          root.fail(w.label + " timed out")
          continue
        }
        still.push(w)
      }
      root.watchedProcs = still
      if (still.length === 0)
        stop()
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
    root.guard(statusProcess, "Status check")
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
    root.guard(loginProcess, "Sign-in", 60000)
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
    root.guard(favoritesProcess, "Loading favorites")
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
    root.guard(favProcess, "Updating favorite")
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

  // Set when we deliberately kill a helper to make room for a newer run. The
  // killed process still reports exit 143 with empty output a moment later, and
  // without this its onExited takes the failure branch — blanking the results
  // the user is waiting for, or discarding the track they just picked, and
  // showing a red error for something that went exactly as intended.
  property bool searchSuperseded: false
  property bool resolveSuperseded: false

  function search(query, mode) {
    var text = String(query || "").trim()
    searchQuery = text
    if (mode)
      searchMode = mode

    if (text === "") {
      clearSearch()
      return
    }
    if (searchProcess.running) {
      searchSuperseded = true
      searchProcess.running = false
    }

    searchLoading = true
    searchProcess.command = [helperPath, "search", text, "--mode", searchMode]
    searchProcess.running = true
    root.guard(searchProcess, "Search")
  }

  function clearSearch() {
    if (searchProcess.running) {
      searchSuperseded = true
      searchProcess.running = false
    }
    searchLoading = false
    searchResults = []
    searchQuery = ""
  }

  Process {
    id: searchProcess
    stdout: StdioCollector { id: searchOut; waitForEnd: true }
    stderr: StdioCollector { id: searchErr; waitForEnd: true }
    onExited: function(exitCode) {
      if (root.searchSuperseded) {
        // We killed this one; a newer query is already on its way and has
        // set searchLoading itself.
        root.searchSuperseded = false
        return
      }
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
    root.guard(catalogProcess, "Catalog refresh", root.catalogTimeoutMs)
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

  function runAction(argv, successNote, timeoutMs) {
    if (actionProcess.running) {
      note("Still working on the last action")
      return
    }
    actionSuccessNote = successNote || ""
    actionProcess.command = argv
    actionProcess.running = true
    root.guard(actionProcess, "Helper action", timeoutMs)
  }

  function cacheTrack(id) {
    if (!id)
      return
    // Deliberately not runAction(): a download holds its Process for up to
    // downloadTimeoutMs, and actionProcess is shared with sign-out and with
    // removing an offline copy. Routing it through the shared Process left
    // those silently dead — no message, no spinner — for up to half an hour.
    if (downloadProcess.running) {
      note("Already saving a session")
      return
    }
    downloadProcess.command = [helperPath, "cache", "add", String(id)]
    downloadProcess.running = true
    root.guard(downloadProcess, "Saving for offline use", root.downloadTimeoutMs)
  }

  function uncacheTrack(id) {
    if (!id)
      return
    runAction([helperPath, "cache", "remove", String(id)], "Removed the offline copy")
  }

  Process {
    id: downloadProcess
    stdout: StdioCollector { id: downloadOut; waitForEnd: true }
    stderr: StdioCollector { id: downloadErr; waitForEnd: true }
    onExited: function(exitCode) {
      var payload = root.parseHelper(downloadOut.text)
      if (exitCode !== 0 || !payload || payload.ok !== true)
        root.fail(root.helperFailed(payload, downloadErr.text,
          "Could not save that session"))
      else
        root.note("Saved for offline use")
      root.refreshStatus()
    }
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
    if (resolveProcess.running) {
      resolveSuperseded = true
      resolveProcess.running = false
    }
    resolveProcess.command = [helperPath, "resolve", id]
    resolveProcess.running = true
    root.guard(resolveProcess, "Opening session")
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
      if (root.resolveSuperseded) {
        // We killed this one because the user picked something else; the new
        // pick owns pendingTrack now and must not be cleared here.
        root.resolveSuperseded = false
        return
      }
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
    if (mpvPendingUrl === "" || !socketReady())
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
    if (mpvProcess.running || socketDirProcess.running)
      return
    socketAttempts = 0
    claimSocketDir()
  }

  function claimSocketDir() {
    var dir = newSocketDir()
    if (dir === "") {
      buffering = false
      fail("No XDG_RUNTIME_DIR — refusing to put mpv's control socket "
        + "in a shared directory")
      return
    }
    socketDir = dir
    socketDirProcess.command = ["mkdir", "-m", "700", dir]
    socketDirProcess.running = true
  }

  // A non-zero exit means the name was taken (or the directory is unusable);
  // pick another and try again rather than reusing whatever is already there.
  Process {
    id: socketDirProcess
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        // Three attempts, not one: a retry only helps against a name that is
        // already taken, and with a 64-bit-ish random name that is vanishingly
        // unlikely twice running. Any real cause (unwritable XDG_RUNTIME_DIR,
        // full tmpfs) fails all three and surfaces the error rather than
        // looping.
        root.socketAttempts += 1
        if (root.socketAttempts < 3) {
          root.claimSocketDir()
          return
        }
        root.socketDir = ""
        // Nothing is going to load now, so drop the spinner with the message.
        root.buffering = false
        root.fail("Could not create a private directory for mpv's control socket")
        return
      }
      root.socketPath = root.socketDir + "/mpv.sock"
      root.startMpv()
    }
  }

  // ~5 s of retrying at the interval above. Comfortably clear of the slowest
  // socket creation measured (270 ms on a loaded machine) while still giving up
  // in a human amount of time if it is never coming.
  readonly property int socketBudgetMs: 5000
  property int socketConnectAttempts: 0

  function startMpv() {
    socketConnectAttempts = 0
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
    if (!socketReady())
      return false
    socketLoader.item.write(JSON.stringify({ command: command }) + "\n")
    socketLoader.item.flush()
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
      socketLoader.active = false
      socketRetry.stop()
      // mpv does not always unlink its socket; leaving it would strand a dead
      // entry in XDG_RUNTIME_DIR until the session ends.
      //
      // Capture the paths now rather than reading them when the cleanup
      // processes exit. If the user presses play again in the meantime,
      // claimSocketDir() has already replaced socketDir/socketPath with the new
      // cycle's, and a late read would delete the directory the *new* mpv is
      // using and blank the socket path it is connecting to.
      var doomedDir = root.socketDir
      root.socketPath = ""
      root.socketDir = ""
      if (doomedDir !== "")
        root.removeSocketDir(doomedDir)
    }
  }

  // Remove the directory belonging to an mpv that has exited. The path is
  // captured at exit time, so a newly started mpv is never cleaned up from
  // under itself.
  //
  // One command rather than an rm/rmdir pair: the directory is ours by
  // construction — created by our own mkdir, under a random name, inside
  // XDG_RUNTIME_DIR — and it only ever contains mpv's socket. Chaining two
  // Processes needed a queue to stop two closely-spaced exits overwriting each
  // other's paths, which was more moving parts than the job deserves. A second
  // call while one is running does not interrupt it either: Quickshell lets the
  // running child finish and then runs the queued command. Only one mpv exists
  // at a time regardless, so two overlapping exits cannot arise.
  function removeSocketDir(dir) {
    socketCleanup.command = ["rm", "-rf", dir]
    socketCleanup.running = true
  }

  Process { id: socketCleanup }

  // A shell restart or a plugin hot-reload destroys this Service before the
  // removal above can run, so each one strands a directory in
  // XDG_RUNTIME_DIR. Sweep leftovers at startup.
  //
  // The one-hour floor is a tradeoff worth stating precisely. A directory's
  // mtime is the socket-creation time and is never updated afterwards, so it
  // measures the age of the mpv, not how long the directory has been stale.
  // Two consequences: a directory stranded seconds ago is skipped and only
  // collected by some later startup, and an orphaned mpv that has been up for
  // over an hour will have its live socket swept. The second sounds worse than
  // it is — an mpv whose Service is gone is already unreachable, and sweeping
  // everything on sight would instead take out a socket that a still-usable
  // mpv is holding across a plugin hot-reload.
  Process { id: staleSweep }
  Process { id: staleSocket }

  function sweepStaleSocketDirs() {
    var base = String(Quickshell.env("XDG_RUNTIME_DIR") || "")
    if (base === "")
      return
    staleSweep.command = [
      // -mindepth 1 so the search root itself can never match and be removed.
      "find", base, "-mindepth", "1", "-maxdepth", "1", "-type", "d",
      "-name", "neomarchy-*", "-mmin", "+60",
      "-exec", "rm", "-rf", "{}", "+"
    ]
    // Versions before 0.2.0 used one fixed socket path here. -type d above can
    // never match that file, so without this it lingers for the whole session
    // on every upgraded machine.
    staleSocket.command = ["rm", "-f", base + "/omarchy-neomarchy-mpv.sock"]
    staleSocket.running = true
    staleSweep.running = true
  }

  // mpv needs a moment to create the socket after it starts.
  Timer {
    id: socketRetry
    // Short on purpose. This interval is the delay added before playback can
    // begin in the common case — mpv usually has its socket ready in ~55 ms, so
    // we connect on the first tick — and a longer interval would spend that
    // extra time on every single play for nothing. A failed attempt is cheap
    // and silent (measured: it logs nothing), so retrying often costs little.
    interval: 120
    repeat: true
    triggeredOnStart: false
    onTriggered: {
      if (!mpvProcess.running) {
        stop()
        return
      }
      if (root.socketReady()) {
        stop()
        return
      }
      // Bounded, because mpv can be running and yet never produce a socket.
      // Without this the timer would recreate a Socket 8 times a second for the
      // rest of the session while the user stared at a spinner.
      root.socketConnectAttempts += 1
      if (root.socketConnectAttempts * interval > root.socketBudgetMs) {
        stop()
        root.buffering = false
        root.fail("mpv did not open its control socket")
        return
      }
      // A fresh Socket per attempt — see mpvSocketComponent above.
      socketLoader.active = false
      socketLoader.active = true
      if (socketLoader.item)
        socketLoader.item.connected = true
    }
  }

  // mpv's control socket, built fresh for every connection attempt.
  //
  // It has to be a new object each time. A Quickshell Socket that has failed to
  // connect once is permanently unusable: setting connected = true again,
  // toggling it off and on, or repointing path all silently do nothing. The
  // retry timer fires 120 ms after mpv starts, and mpv needs ~55 ms warm but
  // 150-270 ms on a loaded machine, so losing that race is an ordinary event.
  // Reusing the object meant one slow start left the plugin with a permanent
  // spinner that only restarting the shell could clear.
  Component {
    id: mpvSocketComponent

    Socket {
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
  }

  Loader {
    id: socketLoader
    active: false
    sourceComponent: mpvSocketComponent
  }

  function socketReady() {
    return socketLoader.item !== null && socketLoader.item.connected
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
    if (!socketReady())
      return
    socketLoader.item.write(JSON.stringify({
      command: ["get_property", "time-pos"],
      request_id: 100
    }) + "\n")
    socketLoader.item.flush()
  }

  Component.onCompleted: {
    sweepStaleSocketDirs()
    refreshStatus()
  }

  Component.onDestruction: {
    if (mpvProcess.running)
      mpvProcess.signal(15)
  }
}

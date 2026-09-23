import QtQuick
import Quickshell
import Quickshell.Io

// Shared state for the neomarchy plugin: one mpv instance driven over its JSON
// IPC socket, and every piece of catalogue data fetched through bin/neowake.
//
// mpv and Qt never see a remote URL. Audio is streamed by the helper — the
// only process that talks to the network, behind its host allowlist and byte
// caps — into a local file that mpv follows while it grows (appending://).
// Cover art likewise arrives as local files via the helper's `artwork`
// command. The QML layer deals exclusively in ids, local paths, and the
// helper's JSON.
Item {
  id: root

  property var shell: null
  property var manifest: null

  // ---------------------------------------------------------------- helper

  // resolvedUrl percent-encodes, argv wants the bytes: a plugin directory
  // with a space in its path would otherwise yield "bin%20neowake".
  readonly property string helperPath: decodeURIComponent(
    String(Qt.resolvedUrl("bin/neowake")).replace(/^file:\/\//, ""))

  // Every helper invocation carries a --budget a few seconds under the QML
  // deadline for that operation, so the helper unwinds cleanly — running its
  // cleanup `finally` blocks — before the watchdog here ever has to signal
  // it, and --own-process-group so that one group signal from the watchdog
  // takes the helper down together with anything it started (secret-tool,
  // for instance) even if the helper itself is beyond reasoning with.
  function helperArgv(args, timeoutMs) {
    var budget = Math.max(5, Math.round((timeoutMs || helperTimeoutMs) / 1000) - 5)
    return [helperPath, "--budget", String(budget), "--own-process-group"]
      .concat(args)
  }

  // The two id shapes the helper accepts (numeric post id, kebab-case slug).
  // Checked at every QML entry point too — the public IPC methods land here —
  // so nothing else even reaches a helper command line.
  function validSessionKey(key) {
    return /^[0-9]{1,32}$/.test(key) || /^[a-z0-9][a-z0-9-]{0,127}$/.test(key)
  }

  // ---------------------------------------------------------------- account

  property bool loggedIn: false
  property string username: ""
  property bool hasStoredPassword: false
  property int catalogCount: 0
  property int catalogAge: -1
  property int cachedTracks: 0
  property bool statusLoading: false

  property bool loginBusy: false
  property string loginError: ""

  // ---------------------------------------------------------------- library

  property var favorites: []
  property bool favoritesLoading: false
  property var favoriteIds: ({})

  property var searchResults: []
  property bool searchLoading: false
  property string searchQuery: ""
  property string searchMode: "keyword"
  property bool artworkSearchActive: false

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
  readonly property string trackArtUrl: currentTrack ? artUrl(currentTrack) : ""
  readonly property string trackId: currentTrack ? String(currentTrack.id || "") : ""
  readonly property bool currentIsFavorite: trackId !== "" && isFavorite(trackId)

  onCurrentTrackChanged: pruneArtwork()
  onFavoriteIdsChanged: pruneArtwork()
  onSearchResultsChanged: pruneArtwork()
  onArtworkSearchActiveChanged: pruneArtwork()

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

  // Playing an uncached session downloads the whole file (mpv follows the
  // partial while it grows, so playback starts immediately): a measured
  // session is 216 MB, which the generic 45 s deadline could only ever meet
  // on a ~38 Mbit link. 30 minutes covers the same file on a ~1 Mbit
  // connection.
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

  // Every helper run gets a deadline, enforced in three layers: the helper's
  // own --budget (it unwinds first, cleanly), then TERM to its process group,
  // then — after a short grace — KILL to the group. The group signal matters
  // because the helper may itself be blocked on a child such as secret-tool:
  // signalling only the leader could leave that child running unwatched.
  // Reaping is Quickshell's (the direct child) and init's (anything
  // re-parented after a group KILL); nothing lingers as a zombie of ours.
  property var watchedProcs: []
  property var pendingKills: []
  readonly property int killGraceMs: 2000

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

  // Group signalling. Quickshell's Process.signal() only reaches the direct
  // child, so the group signal goes through kill(1) with a negative pid. The
  // direct signal is still sent as well: it covers the instant before the
  // helper has moved into its own group, and any process not started with
  // --own-process-group.
  property var killQueue: []

  function signalGroup(pid, sig) {
    if (!pid)
      return
    killQueue.push({ pid: pid, sig: sig })
    pumpKills()
  }

  function pumpKills() {
    if (killProcess.running || killQueue.length === 0)
      return
    var next = killQueue.shift()
    killProcess.command = ["kill", "-s", next.sig, "--", "-" + next.pid]
    killProcess.running = true
  }

  // Exit status deliberately ignored: a group that is already gone makes
  // kill(1) fail, and that is the outcome we wanted anyway.
  Process { id: killProcess; onExited: root.pumpKills() }

  function terminateTree(proc) {
    var pid = proc.processId
    proc.signal(15)
    signalGroup(pid, "TERM")
  }

  function killTree(proc) {
    var pid = proc.processId
    proc.signal(9)
    signalGroup(pid, "KILL")
  }

  // For a helper we end early on purpose (a superseded search or download):
  // TERM now so it unwinds and cleans up after itself, and an unconditional
  // group KILL a grace later in case it cannot. The KILL is addressed by pid,
  // not Process object, because the Process is reused for the successor run.
  //
  // Addressing a pid that may already be dead is the one residual here: if
  // the number were recycled within the 2 s grace by a new process that also
  // became a group leader, the KILL would hit that instead. Linux hands out
  // pids sequentially up to pid_max (4194304 on this platform), so that
  // takes millions of process creations inside two seconds; and the target
  // could only ever be another process of this same user.
  function supersedeHelper(proc) {
    var pid = proc.processId
    terminateTree(proc)
    if (pid) {
      pendingKills = pendingKills.concat([{ pid: pid, at: Date.now() + killGraceMs }])
      watchdog.start()
    }
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
        if (w.termAt !== undefined) {
          // TERM was sent and it is still here. bin/neowake turns SIGTERM
          // into a normal unwind (verified: exit 143, promptly, even
          // mid-download), so the only way to reach the KILL is a helper
          // wedged somewhere no Python signal handler runs.
          if (now - w.termAt >= root.killGraceMs)
            root.killTree(w.proc)
          else
            still.push(w)
          continue
        }
        if (now >= w.deadline) {
          root.terminateTree(w.proc)
          root.fail(w.label + " timed out")
          w.termAt = now
          still.push(w)
          continue
        }
        still.push(w)
      }
      root.watchedProcs = still

      var kills = []
      for (var k = 0; k < root.pendingKills.length; k++) {
        var pending = root.pendingKills[k]
        if (now >= pending.at)
          root.signalGroup(pending.pid, "KILL")
        else
          kills.push(pending)
      }
      root.pendingKills = kills

      if (still.length === 0 && kills.length === 0)
        stop()
    }
  }

  function helperFailed(payload, stderrText, fallback) {
    if (payload && payload.ok === false && payload.error)
      return String(payload.error)
    // stderr is not capped by the helper the way stdout is (a traceback is
    // whatever size it is), so only the tail is ever looked at.
    var text = String(stderrText || "").slice(-4096).trim()
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
    statusProcess.command = helperArgv(["status"], helperTimeoutMs)
    statusProcess.running = true
    root.guard(statusProcess, "Status check")
  }

  // Username/email and password — the only credentials neowake has. The
  // password never touches the command line: it goes down the helper's
  // stdin (see loginProcess.onStarted).
  function login(user, password) {
    if (loginProcess.running || !user || !password)
      return
    loginBusy = true
    loginError = ""
    loginPassword = password
    var argv = ["login", "--user", String(user), "--password-stdin"]
    loginProcess.command = helperArgv(argv, 60000)
    loginProcess.running = true
    root.guard(loginProcess, "Sign-in", 60000)
  }

  function logout(forget) {
    var argv = ["logout"]
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
      if (exitCode !== 0 || !payload || payload.ok !== true) {
        root.loginError = root.helperFailed(payload, loginErr.text, "Login failed")
        return
      }
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
    var argv = ["favorites"]
    if (force)
      argv.push("--refresh")
    favoritesProcess.command = helperArgv(argv, helperTimeoutMs)
    favoritesProcess.running = true
    root.guard(favoritesProcess, "Loading favorites")
  }

  function isFavorite(id) {
    return favoriteIds[String(id)] === true
  }

  function toggleFavorite(id) {
    var key = String(id || "")
    if (!validSessionKey(key) || favProcess.running)
      return
    // Flip locally first; the helper answers with the authoritative value.
    var next = {}
    for (var existing in favoriteIds)
      next[existing] = favoriteIds[existing]
    next[key] = !isFavorite(key)
    favoriteIds = next

    favProcess.command = helperArgv(["fav", "toggle", key], helperTimeoutMs)
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
  property bool streamSuperseded: false

  // Query length cap, mirrored by MAX_QUERY in the helper. Local mode runs a
  // fuzzy match over the whole catalogue on every keystroke, and its cost
  // grows with the query, so a pasted wall of text is cut before it goes out.
  readonly property int maxQueryLength: 200

  function search(query, mode) {
    var text = String(query || "").trim().slice(0, maxQueryLength)
    searchQuery = text
    if (mode)
      searchMode = mode

    if (text === "") {
      clearSearch()
      return
    }
    // Rows from the previous query must not keep their artwork work queued.
    searchResults = []
    if (searchProcess.running) {
      searchSuperseded = true
      supersedeHelper(searchProcess)
      searchProcess.running = false
    }

    searchLoading = true
    // "--" so that whatever was typed is the query, never an option: "-h"
    // or "--limit 1" in the search box would otherwise be parsed as one.
    searchProcess.command = helperArgv(
      ["search", "--mode", searchMode, "--", text], helperTimeoutMs)
    searchProcess.running = true
    root.guard(searchProcess, "Search")
  }

  function clearSearch() {
    if (searchProcess.running) {
      searchSuperseded = true
      supersedeHelper(searchProcess)
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
    var argv = ["catalog"]
    if (force)
      argv.push("--refresh")
    catalogProcess.command = helperArgv(argv, root.catalogTimeoutMs)
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
  // artwork
  // ------------------------------------------------------------------------

  // Qt's Image element follows HTTP redirects on its own, outside any
  // allowlist, so it is never handed a remote URL. Covers are fetched by the
  // helper — same host allowlist as everything else, 4 MB cap, content
  // sniffed — into ~/.local/state/neowake/artwork/, and the views load those
  // files. artUrl() is what every Image binds through: a known local path,
  // "" while unknown, and a request queued the first time an id shows up.
  property var artworkPaths: ({})     // id -> "file://..." or "" (none/failed)
  property var artworkPending: ({})   // ids queued or in flight this session
  property var artworkQueue: []       // {id, needsResolve, attempts}
  property var artworkBatch: []
  property var artworkFailedAt: ({})  // retry on a later view, for active ids

  function artworkWanted(id) {
    if ((currentTrack && String(currentTrack.id) === id)
        || favoriteIds[id] === true)
      return true
    if (artworkSearchActive && searchQuery !== "") {
      for (var i = 0; i < searchResults.length; i++) {
        if (String(searchResults[i].id) === id)
          return true
      }
    }
    return false
  }

  function pruneArtwork() {
    var keep = {}
    if (currentTrack)
      keep[String(currentTrack.id)] = true
    for (var fav in favoriteIds) {
      if (favoriteIds[fav] === true)
        keep[fav] = true
    }
    if (artworkSearchActive && searchQuery !== "") {
      for (var i = 0; i < searchResults.length; i++)
        keep[String(searchResults[i].id)] = true
    }
    var paths = {}, failed = {}, pending = {}, queue = []
    for (var id in artworkPaths) {
      if (keep[id] === true)
        paths[id] = artworkPaths[id]
    }
    for (var id in artworkFailedAt) {
      if (keep[id] === true)
        failed[id] = artworkFailedAt[id]
    }
    for (var i = 0; i < artworkBatch.length; i++) {
      // A still-running batch may become relevant again before it exits.
      pending[artworkBatch[i].id] = true
    }
    for (var i = 0; i < artworkQueue.length; i++) {
      var entry = artworkQueue[i]
      if (keep[entry.id] === true) {
        queue.push(entry)
        pending[entry.id] = true
      }
    }
    artworkQueue = queue
    artworkPending = pending
    artworkFailedAt = failed
    artworkPaths = paths
  }

  function artUrl(item) {
    if (!item)
      return ""
    var id = String(item.id || "")
    if (!/^[0-9]{1,32}$/.test(id))
      return ""
    var known = artworkPaths[id]
    if (known !== undefined) {
      if (known === "" && Date.now() - (artworkFailedAt[id] || 0) > 60000)
        queueArtwork(id, !item.thumb)
      return known
    }
    // Search results can have a title without a thumb. The helper can obtain
    // that metadata from the playlist endpoint without downloading audio.
    // Defer the request out of this binding.
    queueArtwork(id, !item.thumb)
    return ""
  }

  function queueArtwork(id, needsResolve) {
    if (!artworkWanted(id) || artworkPending[id] === true
        || artworkQueue.length >= 100)
      return
    artworkPending[id] = true
    artworkQueue.push({ id: id, needsResolve: needsResolve, attempts: 0 })
    Qt.callLater(root.pumpArtwork)
  }

  function pumpArtwork() {
    if (artworkProcess.running || artworkQueue.length === 0)
      return
    // Missing thumbs need metadata as well as an image. Keep those calls in
    // small batches so the helper's one absolute deadline covers every id.
    var needsResolve = artworkQueue[0].needsResolve
    var queued = []
    while (artworkQueue.length > 0 && queued.length < (needsResolve ? 4 : 12)
           && artworkQueue[0].needsResolve === needsResolve)
      queued.push(artworkQueue.shift())
    artworkBatch = queued
    var ids = []
    for (var i = 0; i < artworkBatch.length; i++) {
      var id = artworkBatch[i].id
      artworkBatch[i].attempts++
      ids.push(id)
    }
    artworkProcess.command = helperArgv(["artwork"].concat(ids),
      helperTimeoutMs)
    artworkProcess.running = true
    root.guard(artworkProcess, "Artwork fetch")
  }

  Process {
    id: artworkProcess
    stdout: StdioCollector { id: artworkOut; waitForEnd: true }
    onExited: function(exitCode) {
      var payload = root.parseHelper(artworkOut.text)
      var table = payload && payload.ok === true && payload.artwork
        ? payload.artwork : ({})
      var next = {}
      for (var known in root.artworkPaths)
        next[known] = root.artworkPaths[known]
      for (var i = 0; i < root.artworkBatch.length; i++) {
        var entry = root.artworkBatch[i]
        var id = entry.id
        if (!root.artworkWanted(id)) {
          delete root.artworkPending[id]
          continue
        }
        var path = table[id]
        if (typeof path === "string" && path.charAt(0) === "/") {
          next[id] = "file://" + path
          delete root.artworkPending[id]
          delete root.artworkFailedAt[id]
        } else if (entry.attempts < 2
                   && root.artworkQueue.length < 100) {
          // A short-lived network failure should not leave a permanent
          // placeholder. Retry once, behind any other visible rows.
          root.artworkQueue.push(entry)
        } else {
          next[id] = ""
          delete root.artworkPending[id]
          root.artworkFailedAt[id] = Date.now()
        }
      }
      root.artworkPaths = next
      root.artworkBatch = []
      if (root.artworkQueue.length > 0)
        Qt.callLater(root.pumpArtwork)
    }
  }

  // ------------------------------------------------------------------------
  // one-shot actions (cache, logout, enrich)
  // ------------------------------------------------------------------------

  property string actionSuccessNote: ""

  function runAction(args, successNote, timeoutMs) {
    if (actionProcess.running) {
      note("Still working on the last action")
      return
    }
    actionSuccessNote = successNote || ""
    actionProcess.command = helperArgv(args, timeoutMs)
    actionProcess.running = true
    root.guard(actionProcess, "Helper action", timeoutMs)
  }

  function cacheTrack(id) {
    var key = String(id || "")
    if (!validSessionKey(key))
      return
    if (key === transientId || key === streamingId) {
      // This session is (or just was) being fetched for playback anyway —
      // keeping it offline only means not deleting it afterwards.
      transientId = ""
      note("Keeping this session offline")
      refreshStatus()
      return
    }
    // Deliberately not runAction(): a download holds its Process for up to
    // downloadTimeoutMs, and actionProcess is shared with sign-out and with
    // removing an offline copy. Routing it through the shared Process left
    // those silently dead — no message, no spinner — for up to half an hour.
    if (downloadProcess.running) {
      note("Already saving a session")
      return
    }
    downloadProcess.command = helperArgv(["cache", "add", key], downloadTimeoutMs)
    downloadProcess.running = true
    root.guard(downloadProcess, "Saving for offline use", root.downloadTimeoutMs)
  }

  function uncacheTrack(id) {
    var key = String(id || "")
    if (!validSessionKey(key))
      return
    if (key === transientId)
      transientId = ""      // being removed explicitly; nothing left to clean
    dropLocalCopyState(key)
    runAction(["cache", "remove", key], "Removed the offline copy")
  }

  // The file behind `id` is going away. If the current track points at it,
  // drop that playUrl so a replay goes back through resolve instead of
  // handing mpv a path that no longer exists.
  function dropLocalCopyState(id) {
    if (!currentTrack || String(currentTrack.id) !== String(id))
      return
    var merged = {}
    for (var key in currentTrack)
      merged[key] = currentTrack[key]
    merged.cached = false
    merged.playUrl = ""
    currentTrack = merged
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

  // Streaming playback state. An uncached session is downloaded by the helper
  // into audio/partial-<id>.<ext> while mpv follows that growing local file
  // (appending://). When the download completes the partial becomes the
  // cached copy and mpv is switched onto it at the current position.
  property string streamingId: ""      // id whose download is playback-driven
  property int streamRetries: 0        // loadfile attempts before the partial exists
  property string transientId: ""      // downloaded only to play; removed later
  property bool stopRequested: false
  property real pendingSeekSeconds: 0

  function play(item) {
    if (!item)
      return
    var id = String(item.id || "")
    if (!validSessionKey(id))
      return
    stopRequested = false
    pendingSeekSeconds = 0
    cleanupTransient(id)
    currentTrack = item
    positionSeconds = 0
    lengthSeconds = 0
    buffering = true
    lastError = ""

    // Only a verified local copy plays directly; everything else goes back
    // through resolve so the helper decides what is playable right now.
    if (item.playUrl && String(item.playUrl).indexOf("file://") === 0) {
      startUrl(item.playUrl)
      return
    }
    pendingTrack = item
    if (resolveProcess.running) {
      resolveSuperseded = true
      supersedeHelper(resolveProcess)
      resolveProcess.running = false
    }
    resolveProcess.command = helperArgv(["resolve", id], helperTimeoutMs)
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
    if (!validSessionKey(key))
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
      merged.cached = payload.cached === true
      merged.playUrl = payload.playUrl ? String(payload.playUrl) : ""
      merged.streamPath = payload.streamPath ? String(payload.streamPath) : ""
      root.currentTrack = merged

      if (merged.playUrl.indexOf("file://") === 0)
        root.startUrl(merged.playUrl)
      else if (merged.streamPath !== "")
        root.startStream(merged)
      else {
        root.buffering = false
        root.fail("Could not open that session")
      }
    }
  }

  // Download-and-play: the helper streams the audio (allowlist on every
  // redirect hop, 512 MB cap, private partial file) while mpv follows the
  // partial. mpv itself never touches the network.
  function startStream(item) {
    var id = String(item.id || "")
    if (id === "" || !item.streamPath)
      return
    if (streamProcess.running) {
      streamSuperseded = true
      supersedeHelper(streamProcess)
      streamProcess.running = false
    }
    streamingId = id
    streamRetries = 0
    if (!cacheOnPlay && item.cached !== true)
      transientId = id
    streamProcess.command = helperArgv(["cache", "add", id], downloadTimeoutMs)
    streamProcess.running = true
    root.guard(streamProcess, "Fetching the session audio", root.downloadTimeoutMs)
    startUrl("appending://" + String(item.streamPath))
  }

  // A session downloaded only because the user pressed play is removed again
  // when they move on — unless cacheOnPlay is set, they pressed the keep
  // button (cacheTrack clears transientId), or it is the very session being
  // started (exceptId).
  function cleanupTransient(exceptId) {
    if (transientId === "" || transientId === String(exceptId))
      return
    var id = transientId
    transientId = ""
    dropLocalCopyState(id)
    if (streamProcess.running && streamingId === id) {
      // Still downloading: ending the helper discards the partial itself.
      streamSuperseded = true
      supersedeHelper(streamProcess)
      streamProcess.running = false
      streamingId = ""
      return
    }
    runAction(["cache", "remove", id], "")
  }

  function markCurrentCached(path) {
    if (!currentTrack)
      return
    var merged = {}
    for (var key in currentTrack)
      merged[key] = currentTrack[key]
    merged.cached = true
    merged.playUrl = "file://" + path
    merged.streamPath = ""
    currentTrack = merged
  }

  // The download finished: move mpv from the no-longer-growing partial onto
  // the completed file, at the position it had reached. Without this, mpv's
  // appending mode would wait forever for more data that is never coming.
  function switchToCompleted(path) {
    var target = String(path || "")
    if (target.charAt(0) !== "/")
      return
    markCurrentCached(target)
    if (!socketReady() || !fileLoaded) {
      // Playback never latched onto the partial (a very fast download, or a
      // container mpv cannot play while incomplete) — just play the file.
      startUrl("file://" + target)
      return
    }
    pendingSeekSeconds = Math.max(0, positionSeconds - 0.5)
    sendMpv(["loadfile", target])
    sendMpv(["set_property", "pause", false])
  }

  Process {
    id: streamProcess
    stdout: StdioCollector { id: streamOut; waitForEnd: true }
    stderr: StdioCollector { id: streamErr; waitForEnd: true }
    onExited: function(exitCode) {
      if (root.streamSuperseded) {
        root.streamSuperseded = false
        return
      }
      var streamed = root.streamingId
      root.streamingId = ""
      var payload = root.parseHelper(streamOut.text)
      var current = root.currentTrack
        && String(root.currentTrack.id) === streamed
      if (exitCode !== 0 || !payload || payload.ok !== true) {
        if (root.transientId === streamed)
          root.transientId = ""
        if (current) {
          // The partial mpv is following just stopped growing for good (and
          // the helper unlinked it) — stop chasing it.
          root.stop()
          root.fail(root.helperFailed(payload, streamErr.text,
            "Could not fetch that session"))
        }
        root.refreshStatus()
        return
      }
      if (current && !root.stopRequested)
        root.switchToCompleted(payload.path)
      root.refreshStatus()
    }
  }

  // The helper needs a moment to create the partial file after it starts;
  // until then mpv's open fails. Each failed attempt lands in handleMpvLine's
  // end-file/error branch, which re-arms this timer up to streamRetries'
  // bound (~6 s) before giving up for real.
  Timer {
    id: streamRetry
    interval: 400
    onTriggered: {
      if (root.streamingId === "" || !root.currentTrack
          || String(root.currentTrack.id) !== root.streamingId)
        return
      if (!streamProcess.running)
        return // download over; its onExited decided what happens next
      var path = String(root.currentTrack.streamPath || "")
      if (path !== "")
        root.startUrl("appending://" + path)
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
    stopRequested = true
    cleanupTransient("")
    if (mpvRunning)
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

  // mpv is started with the user's own configuration and scripts on purpose,
  // not --no-config: mpv-mpris loads as a script, and it is what makes media
  // keys and other MPRIS clients work (README). Command-line options take
  // precedence over mpv.conf, so nothing in a user's config can switch the
  // two network-related flags below back on.
  function startMpv() {
    socketConnectAttempts = 0
    mpvProcess.command = [
      "mpv",
      "--idle=yes",
      "--no-video",
      "--no-terminal",
      "--force-window=no",
      "--keep-open=no",
      // mpv only ever plays local files this plugin verified; the ytdl hook
      // exists to fetch from the network and stays off.
      "--ytdl=no",
      // ...and a local file must not be able to send mpv to the network on
      // its own either. Without this, a file that turns out to be an
      // m3u/pls playlist makes mpv open the URLs inside it (verified: it
      // connected to the host named in a planted partial-*.mp3), outside
      // every allowlist the helper enforces.
      "--access-references=no",
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
      if (pendingSeekSeconds > 0) {
        // Resuming after the switch from the partial to the completed file.
        positionSeconds = pendingSeekSeconds
        sendMpv(["seek", pendingSeekSeconds, "absolute"])
        pendingSeekSeconds = 0
      }
      return
    }
    if (message.event === "end-file") {
      fileLoaded = false
      playing = false
      buffering = false
      positionSeconds = 0
      if (message.reason === "error") {
        // While a stream download is starting up, the partial file does not
        // exist for the first few hundred milliseconds and mpv's open fails.
        // That is expected — retry briefly before treating it as real.
        if (streamingId !== "" && currentTrack
            && String(currentTrack.id) === streamingId
            && streamRetries < 15) {
          streamRetries += 1
          buffering = true
          streamRetry.restart()
          return
        }
        fail("Playback failed — the session could not be played")
      }
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
    // Best effort: a Process cannot be started during teardown, so no group
    // KILL escalation is possible here. TERM is enough in practice — mpv and
    // the helper both exit on it — and every helper additionally carries its
    // own --budget deadline, so even one that misses this signal ends itself.
    if (mpvProcess.running)
      mpvProcess.signal(15)
    var procs = [statusProcess, loginProcess, favoritesProcess, favProcess,
                 searchProcess, catalogProcess, resolveProcess, streamProcess,
                 downloadProcess, actionProcess, artworkProcess]
    for (var i = 0; i < procs.length; i++) {
      if (procs[i].running)
        procs[i].signal(15)
    }
  }
}

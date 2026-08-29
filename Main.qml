import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Services.UI

/**
 * Aside — state & logic singleton.
 *
 * Talks to the aside daemon through:
 *   - file watchers on ~/.local/state/aside/{status.json,last.json} and the
 *     active conversation JSON (live transcript updates)
 *   - scripts/aside-bridge.py over the daemon unix socket (queries with
 *     text/image, cancel, TTS toggle) and the aside CLI (mic, rm, view)
 */
Item {
  id: root

  property var pluginApi: null

  // ── Paths ─────────────────────────────────────────────────────
  readonly property string homeDir: Quickshell.env("HOME")
  readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || (homeDir + "/.local/state")) + "/aside"
  readonly property string convDir: stateDir + "/conversations"
  readonly property string bridge: (pluginApi?.pluginDir || "") + "/scripts/aside-bridge.py"

  // ── Daemon status (status.json) ───────────────────────────────
  property string asideStatus: "unknown"   // idle | thinking | tool_use | speaking | unknown
  property string toolName: ""
  property string model: ""
  property bool speakEnabled: false
  readonly property bool busy: asideStatus === "thinking" || asideStatus === "tool_use" || asideStatus === "speaking"
  readonly property bool daemonRunning: asideStatus !== "unknown"

  // ── Conversation tracking ─────────────────────────────────────
  property string daemonConvId: ""         // daemon's own last conversation (last.json)
  property bool pinned: false              // user picked a conversation from history
  property string pinnedId: ""
  readonly property string currentConvId: pinned ? pinnedId : daemonConvId
  readonly property string currentConvPath: currentConvId ? convDir + "/" + currentConvId + ".json" : ""

  property var messages: []                // parsed transcript of currentConvId
  property var convList: []                // [{id, mtime, messages, preview}]
  property string pendingImage: ""         // path of image attached to next message
  property bool forceNewChat: false        // next send starts a fresh conversation

  readonly property var settings: pluginApi?.pluginSettings || ({})
  readonly property bool autoStartDaemon: settings.autoStartDaemon !== false
  readonly property bool suppressOverlay: settings.suppressOverlay !== false

  signal transcriptUpdated
  signal listUpdated

  // ── Status file watcher ───────────────────────────────────────
  FileView {
    id: statusFile
    path: root.stateDir + "/status.json"
    watchChanges: true
    onFileChanged: statusFile.reload()
    onLoaded: root.parseStatus()
    onLoadFailed: function (err) {
      // status.json missing -> daemon not running
      root.asideStatus = "unknown"
      root.model = ""
    }
  }

  function parseStatus() {
    var raw = statusFile.text()
    if (!raw)
      return
    try {
      var d = JSON.parse(raw)
      root.asideStatus = d.status || "idle"
      root.toolName = d.tool_name || ""
      root.model = d.model || ""
      root.speakEnabled = !!d.speak_enabled
    } catch (e) {
      Logger.w("Aside", "status.json parse failed:", e)
    }
  }

  // ── last.json watcher (daemon's current conversation) ─────────
  FileView {
    id: lastFile
    path: root.stateDir + "/last.json"
    watchChanges: true
    onFileChanged: lastFile.reload()
    onLoaded: root.parseLast()
    onLoadFailed: function (err) {}
  }

  function parseLast() {
    var raw = lastFile.text()
    if (!raw)
      return
    try {
      var id = JSON.parse(raw).conversation_id || ""
      if (id && id !== root.daemonConvId) {
        root.daemonConvId = id
        root.forceNewChat = false
        if (!root.pinned)
          root.loadTranscript()
        root.refreshList()
      }
    } catch (e) {}
  }

  // ── Transcript watcher ────────────────────────────────────────
  FileView {
    id: convFile
    path: root.currentConvPath
    watchChanges: root.currentConvPath !== ""
    onPathChanged: convFile.reload()
    onFileChanged: convFile.reload()
    onLoaded: root.parseTranscript()
    onLoadFailed: function (err) {
      root.messages = []
      root.transcriptUpdated()
    }
  }

  function loadTranscript() {
    // path assignment triggers onPathChanged -> reload -> parseTranscript
    if (convFile.path !== root.currentConvPath)
      convFile.path = root.currentConvPath
    else if (root.currentConvPath !== "")
      convFile.reload()
  }

  function parseTranscript() {
    var raw = convFile.text()
    if (!raw) {
      root.messages = []
      root.transcriptUpdated()
      return
    }
    try {
      var d = JSON.parse(raw)
      var out = []
      var msgs = d.messages || []
      for (var i = 0; i < msgs.length; i++) {
        var m = msgs[i]
        var text = ""
        var hasImage = false
        var c = m.content
        if (typeof c === "string") {
          text = c
        } else if (Array.isArray(c)) {
          var parts = []
          for (var j = 0; j < c.length; j++) {
            var b = c[j]
            if (b && b.type === "text" && b.text)
              parts.push(b.text)
            else if (b && b.type === "image_url")
              hasImage = true
          }
          text = parts.join("\n\n")
        }
        if (text === "" && !hasImage)
          continue
        out.push({
                   "role": m.role || "user",
                   "text": text,
                   "image": hasImage
                 })
      }
      root.messages = out
      root.transcriptUpdated()
    } catch (e) {
      Logger.w("Aside", "transcript parse failed:", e)
    }
  }

  // ── Message helpers ───────────────────────────────────────────
  function newChat() {
    root.pinned = false
    root.pinnedId = ""
    root.forceNewChat = true
    root.messages = []
    root.transcriptUpdated()
  }

  function selectConversation(id) {
    if (!id)
      return
    root.pinned = true
    root.pinnedId = id
    root.loadTranscript()
  }

  function unpin() {
    root.pinned = false
    root.pinnedId = ""
    root.loadTranscript()
  }

  // ── Conversation list ─────────────────────────────────────────
  function refreshList() {
    listProc.command = [root.pythonBin, root.bridge, "list", root.convDir, "--limit", "25"]
    listProc.running = true
  }

  property string pythonBin: "python3"

  Process {
    id: listProc
    running: false
    command: []
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          root.convList = JSON.parse(text || "[]")
        } catch (e) {
          root.convList = []
        }
        root.listUpdated()
      }
    }
    onExited: function (code) {
      if (code !== 0)
        Logger.w("Aside", "list refresh failed, exit", code)
    }
  }

  // ── Sending ───────────────────────────────────────────────────
  function send(text) {
    var t = (text || "").trim()
    if (root.busy)
      return false
    if (t === "" && root.pendingImage === "")
      return false

    var args = [root.pythonBin, root.bridge, "send", "--text", t]
    if (root.pendingImage !== "") {
      args.push("--image", root.pendingImage)
      args.push("--default-prompt", root.settings.imageDefaultPrompt || "Describe this image.")
    }
    if (root.forceNewChat || (root.pinned && root.currentConvId === "")) {
      args.push("--new")
    } else if (root.pinned && root.pinnedId !== "") {
      args.push("--conversation", root.pinnedId)
    }

    Logger.i("Aside", "send:", t.substring(0, 60), root.pendingImage !== "" ? "+image" : "")
    sendProc.command = args
    sendProc.running = true
    return true
  }

  Process {
    id: sendProc
    running: false
    command: []
    stderr: StdioCollector {
      onStreamFinished: sendProc.lastError = text.trim()
    }
    property string lastError: ""
    onExited: function (code) {
      if (code === 0) {
        sendProc.lastError = ""
        root.sendFinished(true)
      } else {
        var err = sendProc.lastError || "aside bridge failed"
        Logger.w("Aside", "send failed:", err)
        if (code === 2 && root.autoStartDaemon && !root.startingDaemon) {
          root.startDaemon()
          ToastService.showWarning("Aside", "Daemon not running — starting it, try again in a moment", 5000)
        } else {
          ToastService.showError("Aside", err)
        }
      }
    }
  }

  signal pendingImageCleared

  Timer {
    id: reloadSoon
    interval: 700
    onTriggered: {
      root.refreshList()
      root.loadTranscript()
    }
  }

  function sendFinished(ok) {
    if (!ok)
      return
    root.pendingImage = ""
    root.pendingImageCleared()
    // Optimistically switch view: user message lands in the conv file
    if (root.forceNewChat) {
      root.pinned = false
      reloadSoon.restart()
    } else {
      root.loadTranscript()
      reloadSoon.restart()
    }
    // The daemon auto-opens aside's native overlay for every query.
    // Hide it again so only this widget's panel shows the conversation.
    if (root.suppressOverlay) {
      overlayHide1.restart()
      overlayHide2.restart()
    }
  }

  Timer {
    id: overlayHide1
    interval: 600
    onTriggered: root.hideAsideOverlay()
  }

  Timer {
    id: overlayHide2
    interval: 1600
    onTriggered: root.hideAsideOverlay()
  }

  function hideAsideOverlay() {
    var p = [root.pythonBin, root.bridge, "overlay", "hide"]
    if (overlayHideProc.command.join(" ") !== p.join(" "))
      overlayHideProc.command = p
    overlayHideProc.running = true
  }

  Process {
    id: overlayHideProc
    running: false
    command: []
  }

  // ── Voice (one-shot capture, aside STT) ───────────────────────
  function sendVoice() {
    if (root.busy)
      return
    var args
    if (root.pinned && root.pinnedId !== "")
      args = ["aside", "reply", "--mic", root.pinnedId]
    else
      args = ["aside", "query", "--mic"]
    voiceProc.command = args
    voiceProc.running = true
    ToastService.showNotice("Aside", "Voice capture — speak, then pause", "microphone")
  }

  Process {
    id: voiceProc
    running: false
    command: []
    stderr: StdioCollector {
      onStreamFinished: voiceProc.lastError = text.trim()
    }
    property string lastError: ""
    onExited: function (code) {
      if (code !== 0) {
        var err = voiceProc.lastError || "voice capture failed"
        ToastService.showError("Aside", err.includes("not running") ? "Aside daemon not running" : err)
        return
      }
      reloadSoon.restart()
    }
  }

  // ── Cancel / TTS / overlay ────────────────────────────────────
  function cancelQuery() {
    actionProc.command = [root.pythonBin, root.bridge, "action", "cancel"]
    actionProc.running = true
  }

  function toggleTts() {
    actionProc.command = [root.pythonBin, root.bridge, "action", "toggle-tts"]
    actionProc.running = true
    root.speakEnabled = !root.speakEnabled
    ToastService.showNotice("Aside", root.speakEnabled ? "TTS on for next replies" : "TTS off", root.speakEnabled ? "volume-2" : "volume-x")
  }

  function viewInOverlay() {
    var args = ["aside", "view"]
    if (root.currentConvId !== "")
      args.push(root.currentConvId)
    viewProc.command = args
    viewProc.running = true
  }

  function deleteConversation(id) {
    if (!id)
      return
    rmProc.command = ["aside", "rm", id]
    rmProc.running = true
    if (root.pinnedId === id)
      root.unpin()
  }

  Process {
    id: actionProc
    running: false
    command: []
  }

  Process {
    id: viewProc
    running: false
    command: []
    stderr: StdioCollector {
      onStreamFinished: viewProc.lastError = text.trim()
    }
    property string lastError: ""
    onExited: function (code) {
      if (code !== 0)
        ToastService.showError("Aside", "aside overlay not running?")
    }
  }

  Process {
    id: rmProc
    running: false
    command: []
    onExited: function (code) {
      if (code !== 0) {
        ToastService.showError("Aside", "failed to delete conversation")
        return
      }
      root.refreshList()
    }
  }

  // ── Daemon autostart ──────────────────────────────────────────
  property bool startingDaemon: false

  function startDaemon() {
    if (root.startingDaemon)
      return
    root.startingDaemon = true
    Logger.i("Aside", "starting aside daemon")
    try {
      Quickshell.execDetached(["aside", "daemon"])
    } catch (e) {
      Logger.e("Aside", "failed to spawn daemon:", e)
    }
    startDaemonWatch.restart()
  }

  Timer {
    id: startDaemonWatch
    interval: 3000
    repeat: true
    running: false
    onTriggered: {
      root.refreshStatus()
      if (root.daemonRunning) {
        root.startingDaemon = false
        startDaemonWatch.stop()
        root.refreshList()
        root.loadTranscript()
        ToastService.showNotice("Aside", "Daemon started", "circle-check")
      }
    }
  }

  function refreshStatus() {
    statusFile.reload()
  }

  // ── Busy polling (catch new conversations created by the daemon) ──
  Timer {
    id: busyPoll
    interval: 1500
    repeat: true
    running: root.busy
    onTriggered: root.refreshList()
  }

  // React when a new conversation file shows up mid-query
  onConvListChanged: {
    if (!root.busy || root.pinned)
      return
    if (root.convList.length > 0 && root.convList[0].id && root.convList[0].id !== root.currentConvId) {
      root.daemonConvId = root.convList[0].id
      root.forceNewChat = false
      root.loadTranscript()
    }
  }

  // ── Init ──────────────────────────────────────────────────────
  Component.onCompleted: {
    Logger.i("Aside", "plugin loaded, bridge:", root.bridge)
    root.refreshList()
    if (root.asideStatus === "unknown" && root.autoStartDaemon) {
      pingProc.command = [root.pythonBin, root.bridge, "action", "ping"]
      pingProc.running = true
    }
  }

  Process {
    id: pingProc
    running: false
    command: []
    onExited: function (code) {
      // exit 2 == socket unreachable
      if (code !== 0 && root.asideStatus === "unknown" && root.autoStartDaemon)
        root.startDaemon()
    }
  }

  // ── IPC: keybinds / scripting ─────────────────────────────────
  IpcHandler {
    target: "plugin:aside"

    function toggle() {
      if (pluginApi)
        pluginApi.withCurrentScreen(screen => pluginApi.togglePanel(screen))
    }

    function query(text: string) {
      if (pluginApi)
        pluginApi.withCurrentScreen(screen => pluginApi.openPanel(screen))
      root.newChat()
      Qt.callLater(() => root.send(text))
    }

    function voice() {
      root.sendVoice()
    }

    function screenshot() {
      root.captureScreenshot()
    }

    function cancel() {
      root.cancelQuery()
    }
  }

  // ── Screenshot capture (region or fullscreen) ───────────────
  // Closes the panel first so it cannot overlap or steal input from
  // slurp's selection UI, then reopens it with the image attached.
  // NOTE: slurp must get /dev/null on stdin — quickshell's Process
  // pipes stdin, and slurp blocks forever on an open pipe (no UI).
  function captureScreenshot() {
    var out = "/tmp/aside-widget-shot-" + Date.now() + ".png"
    var sel = root.settings.fullscreenScreenshot === true ? "" : "-g \"$(slurp -d </dev/null)\" "
    shotProc.outputPath = out
    shotProc.command = ["sh", "-c", "grim " + sel + "'" + out + "'"]
    if (pluginApi)
      pluginApi.withCurrentScreen(screen => pluginApi.closePanel(screen))
    shotProc.running = true
  }

  function reopenPanel() {
    if (pluginApi)
      Qt.callLater(() => pluginApi.withCurrentScreen(screen => pluginApi.openPanel(screen)))
  }

  Process {
    id: shotProc
    running: false
    command: []
    property string outputPath: ""
    stderr: StdioCollector {
      onStreamFinished: shotProc.lastError = text.trim()
    }
    property string lastError: ""
    onExited: function (code) {
      var err = (shotProc.lastError + "").trim()
      if (code === 0) {
        root.pendingImage = shotProc.outputPath
        root.reopenPanel()
        ToastService.showNotice("Aside", "Screenshot attached — add a prompt & send", "screenshot")
      } else {
        root.reopenPanel()
        Logger.i("Aside", "screenshot failed:", err || ("exit code " + code))
        if (err.indexOf("selection cancelled") !== -1 || err === "") {
          ToastService.showNotice("Aside", "Screenshot cancelled", "screenshot")
        } else {
          ToastService.showError("Aside", "Screenshot failed: " + err)
        }
      }
    }
  }

  // ── Clipboard image attach ────────────────────────────────────
  function attachClipboard() {
    var out = "/tmp/aside-widget-clip-" + Date.now() + ".png"
    clipProc.outputPath = out
    clipProc.command = [root.pythonBin, root.bridge, "attach", "--clipboard", "--output", out]
    clipProc.running = true
  }

  Process {
    id: clipProc
    running: false
    command: []
    property string outputPath: ""
    onExited: function (code) {
      if (code === 0) {
        root.pendingImage = clipProc.outputPath
        ToastService.showNotice("Aside", "Clipboard image attached", "clipboard-copy")
      } else {
        ToastService.showWarning("Aside", "No image in clipboard", 3000)
      }
    }
  }
}

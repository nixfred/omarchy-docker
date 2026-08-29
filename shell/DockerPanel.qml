import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Docker bar widget with an anchored popup panel, following the same pattern
// as erruviel.wwan: all state comes from `bin/docker-panel` — one process
// spawn per refresh — with `docker events` streaming in the background so
// external changes show up without waiting for the next poll. The open panel
// switches to a verbose feed (adds `docker system df`) and samples
// per-container CPU/memory; the closed widget pays for neither.
//
// Everything here runs unprivileged. Container actions go through the docker
// CLI (docker group membership), and the daemon/autostart switches call
// systemctl as the user, which authenticates through the shell's polkit agent.
Panel {
  id: root
  moduleName: "erruviel.docker"
  ipcTarget: "erruviel.docker"

  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color dim: Qt.darker(barForeground, 1.4)
  readonly property color urgent: bar && bar.urgent !== undefined ? bar.urgent : "#cc6666"
  readonly property color faint: Qt.rgba(barForeground.r, barForeground.g, barForeground.b, 0.25)

  // The script's path, resolved relative to this file so the plugin works
  // straight out of `omarchy plugin add` with nothing installed on PATH.
  readonly property string panelScript: Qt.resolvedUrl("../bin/docker-panel").toString().replace(/^file:\/\//, "")

  property var info: ({})
  readonly property bool installed: info.installed === true
  readonly property string daemonState: info.daemon || "stopped"
  readonly property bool daemonRunning: daemonState === "running"
  readonly property bool daemonBusy: daemonProc.running
  readonly property string autostart: info.autostart || ""
  readonly property var dfInfo: info.df || null
  readonly property var storageInfo: info.storage || ({ images: [], volumes: [], buildCache: [] })
  readonly property var toolInfo: info.tools || ({ lazydocker: false, dive: false, trivy: false, scout: false })
  readonly property var contexts: info.contexts || []
  readonly property bool localContext: info.localContext === true
  readonly property string effectiveContext: selectedContext || info.context || ""

  readonly property bool showCount: setting("showCount", false) === true
  readonly property bool notifyUnhealthy: setting("notifyUnhealthy", true) !== false
  readonly property var configuredTasks: setting("tasks", []) || []

  // One action in flight at a time; the affected row dims while it runs.
  property string busyId: ""
  property string actionMessage: ""
  property bool actionFailed: false
  property string actionSuccess: ""
  property string currentView: "containers"
  property var selectedContainer: null
  property string selectedContext: ""
  property string pruneAge: "all"

  // Per-container CPU/memory, sampled only while the panel is open.
  property var stats: ({})

  // ------------------------------------------------------------- grouping ---
  // Containers grouped into compose stacks and standalone, with port-conflict
  // notes attached: an exited container whose published host port is held by
  // a running one gets told exactly who is squatting on it.
  readonly property var grouped: {
    var conts = info.containers || []
    var portOwner = {}
    var i, j, c
    for (i = 0; i < conts.length; i++) {
      c = conts[i]
      if (c.state !== "running") continue
      for (j = 0; j < (c.ports || []).length; j++) portOwner[c.ports[j].host] = c.name
    }

    var byProject = {}
    var alone = []
    for (i = 0; i < conts.length; i++) {
      c = conts[i]
      var entry = {
        id: c.id,
        dockerName: c.name,
        name: c.project ? (c.service || c.name) : c.name,
        image: (c.image || "").replace(/:latest$/, ""),
        imageId: c.imageId || "",
        project: c.project || "",
        service: c.service || "",
        state: c.state,
        health: c.health || "",
        workingDir: c.workingDir || "",
        configFiles: c.configFiles || "",
        platform: c.platform || "",
        created: c.created || "",
        command: c.command || "",
        exitCode: c.exitCode,
        oomKilled: c.oomKilled === true,
        stateError: c.stateError || "",
        startedAt: c.startedAt || "",
        finishedAt: c.finishedAt || "",
        restartCount: c.restartCount || 0,
        restartPolicy: c.restartPolicy || "no",
        healthLog: c.healthLog || [],
        envKeys: c.envKeys || [],
        networks: c.networks || [],
        mounts: c.mounts || [],
        portsList: portEntries(c.ports || []),
        note: ""
      }
      if (c.state !== "running") {
        for (j = 0; j < (c.ports || []).length; j++) {
          var owner = portOwner[c.ports[j].host]
          if (owner && owner !== c.name) {
            entry.note = "port " + c.ports[j].host + " in use by " + owner
            break
          }
        }
      }
      if (c.project) {
        if (!byProject[c.project]) byProject[c.project] = []
        byProject[c.project].push(entry)
      } else {
        alone.push(entry)
      }
    }

    var byName = function(a, b) { return a.name < b.name ? -1 : a.name > b.name ? 1 : 0 }
    var stacks = Object.keys(byProject).sort().map(function(name) {
      return { name: name, containers: byProject[name].sort(byName) }
    })
    return { stacks: stacks, standalone: alone.sort(byName) }
  }
  readonly property var stacks: grouped.stacks
  readonly property var standalone: grouped.standalone

  readonly property int totalCount: (info.containers || []).length
  readonly property int runningCount: {
    var n = 0, all = info.containers || []
    for (var i = 0; i < all.length; i++) if (all[i].state === "running") n++
    return n
  }
  readonly property int unhealthyCount: {
    var n = 0, all = info.containers || []
    for (var i = 0; i < all.length; i++) if (all[i].health === "unhealthy") n++
    return n
  }
  readonly property int unusedVolumeCount: {
    var n = 0, volumes = storageInfo.volumes || []
    for (var i = 0; i < volumes.length; i++) if ((volumes[i].links || 0) === 0) n++
    return n
  }

  readonly property string statusText: {
    if (daemonBusy) return daemonRunning ? "Stopping Docker…" : "Starting Docker…"
    if (daemonState === "noaccess") return "No access to the Docker socket"
    if (!daemonRunning) return "Docker daemon stopped"
    if (totalCount === 0) return "No containers"
    var s = runningCount + " of " + totalCount + " running"
    if (unhealthyCount > 0) s += " · " + unhealthyCount + " unhealthy"
    return s
  }

  // What `docker image prune -a && docker builder prune -a` can get back.
  // `docker system df` reports all images unused by a container, not just
  // dangling images, so the action must use the same scope as this number.
  // Stopped compose containers and volumes remain outside the clean-up.
  readonly property string reclaimText: {
    if (!dfInfo) return ""
    var images = "", cache = ""
    for (var i = 0; i < dfInfo.length; i++) {
      var r = (dfInfo[i].reclaimable || "").split(" (")[0]
      if (dfInfo[i].type === "Images") images = r
      else if (dfInfo[i].type === "Build Cache") cache = r
    }
    if (!images && !cache) return ""
    return "Reclaimable: " + (images || "0B") + " images · " + (cache || "0B") + " build cache"
  }

  function portEntries(ports) {
    var out = []
    for (var i = 0; i < ports.length; i++) {
      var host = ports[i].host
      var cont = ports[i].container || ""
      var udp = cont.indexOf("/udp") >= 0
      cont = cont.split("/")[0]
      out.push({
        label: (host === cont ? host : host + "→" + cont) + (udp ? "/udp" : ""),
        host: host,
        web: !udp
      })
    }
    return out
  }

  function stackRunning(stack) {
    var n = 0
    for (var i = 0; i < stack.containers.length; i++)
      if (stack.containers[i].state === "running") n++
    return n
  }

  // -------------------------------------------------------------- refresh ---
  function contextOptions() {
    return effectiveContext ? ["--context", effectiveContext] : []
  }

  function helperCommand(args) {
    return [panelScript].concat(contextOptions()).concat(args || [])
  }

  function dockerCommand(args) {
    return ["docker"].concat(contextOptions()).concat(args || [])
  }

  function refresh() {
    if (!statusProc.running) {
      statusProc.command = helperCommand([])
      statusProc.running = true
    }
  }

  function refreshDetails() {
    if (!detailsProc.running) {
      detailsProc.command = helperCommand(["--verbose"])
      detailsProc.running = true
    }
  }

  function selectContext(name) {
    if (busyId !== "" || daemonBusy || name === effectiveContext) return
    if (statusProc.running) statusProc.running = false
    if (detailsProc.running) detailsProc.running = false
    if (statsProc.running) statsProc.running = false
    selectedContext = name
    selectedContainer = null
    currentView = "containers"
    info = ({ installed: true, daemon: "stopped", context: name, contexts: contexts, containers: [] })
    stats = ({})
    contextRefreshTimer.restart()
  }

  function showView(name) {
    currentView = name
    if (name !== "details") selectedContainer = null
    scroller.contentY = 0
  }

  function updateInfo(raw) {
    // Keep the last known state across a transient bad read, so the widget
    // never blinks out while docker is briefly unavailable.
    try {
      var next = JSON.parse(raw)
      if (next && typeof next === "object") {
        // A process canceled during a context switch can still flush stdout.
        // Never let that late result replace the state of the displayed context.
        if (effectiveContext && next.context && next.context !== effectiveContext) return
        info = next
        if (selectedContainer) {
          var all = next.containers || []
          var found = false
          for (var i = 0; i < all.length; i++) {
            if (all[i].id === selectedContainer.id) {
              found = true
              inspectContainer(all[i])
              break
            }
          }
          if (!found) {
            selectedContainer = null
            currentView = "containers"
          }
        }
      }
    } catch (e) {}
  }

  function updateStats(raw) {
    var next = {}
    var lines = String(raw || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      if (!lines[i]) continue
      try {
        var s = JSON.parse(lines[i])
        // "29.39MiB / 15.5GiB" → "29MiB": the decimals never matter here.
        if (s.ID) next[s.ID] = { cpu: s.CPUPerc || "", mem: (s.MemUsage || "").split(" /")[0].replace(/\.[0-9]+/, "") }
      } catch (e) {}
    }
    stats = next
  }

  // -------------------------------------------------------------- actions ---
  function runAction(cmd, successText) {
    if (actionProc.running) return
    actionMessage = ""
    actionFailed = false
    actionSuccess = successText || "Action complete."
    actionProc.command = cmd
    actionProc.running = true
  }

  function containerAction(c, action) {
    if (busyId !== "" || daemonBusy || !daemonRunning) return
    busyId = c.id
    if (action === "start" && c.state === "paused") runAction(dockerCommand(["unpause", c.id]))
    else runAction(dockerCommand([action, c.id]))
  }

  // Stack start goes through compose when the labels carry the project
  // location: unlike `docker start`, `compose up -d` recreates removed
  // containers and picks up compose.yml changes. Stop stays plain
  // `docker stop` on purpose — `compose down` would delete the containers.
  function stackAction(stack, start) {
    if (busyId !== "" || daemonBusy || !daemonRunning) return
    var i, c
    if (start) {
      for (i = 0; i < stack.containers.length; i++) {
        c = stack.containers[i]
        if (!c.workingDir) continue
        var cmd = dockerCommand(["compose", "--project-directory", c.workingDir])
        var files = (c.configFiles || "").split(",")
        for (var f = 0; f < files.length; f++) if (files[f]) cmd.push("-f", files[f])
        cmd.push("up", "-d")
        busyId = "stack:" + stack.name
        runAction(cmd)
        return
      }
    }
    var ids = []
    for (i = 0; i < stack.containers.length; i++) {
      c = stack.containers[i]
      if (start !== (c.state === "running")) ids.push(c.id)
    }
    if (ids.length === 0) return
    busyId = "stack:" + stack.name
    runAction(dockerCommand([start ? "start" : "stop"].concat(ids)))
  }

  // Destructive actions share one confirm dialog. Removal is only offered
  // for stopped containers — a running one has to be stopped first, which
  // keeps an accidental click from force-killing a live service.
  property var pendingConfirm: null

  function requestConfirm(message, confirmText, cmd, busyKey, successText) {
    if (busyId !== "" || daemonBusy || !daemonRunning) return
    pendingConfirm = { message: message, confirmText: confirmText, cmd: cmd,
                       busyKey: busyKey, successText: successText || "Action complete." }
  }

  function acceptConfirm() {
    if (!pendingConfirm) return
    busyId = pendingConfirm.busyKey
    runAction(pendingConfirm.cmd, pendingConfirm.successText)
    pendingConfirm = null
  }

  function requestRemove(c) {
    requestConfirm(
      "Remove container " + c.name + "? Its writable layer is deleted; named volumes are kept.",
      "Remove", dockerCommand(["rm", c.id]), c.id, "Container removed.")
  }

  function requestPrune() {
    var age = pruneAge === "all" ? "" : pruneAge
    var scope = age ? " older than " + age : ""
    var cmd = helperCommand(["--prune"])
    if (age) cmd.push("--until", age)
    requestConfirm(
      "Remove every image unused by a container and unused build cache" + scope + "? Images may need to be downloaded or rebuilt later. Stopped containers and volumes are kept.",
      "Clean up", cmd, "prune", "Image and build-cache cleanup complete.")
  }

  function requestVolumePrune() {
    requestConfirm(
      "Permanently delete every volume unused by a container? This can erase databases and other durable application data with no built-in recovery.",
      "Delete volumes", helperCommand(["--prune-volumes"]), "volumes", "Unused volumes deleted.")
  }

  function requestImageRemove(image) {
    if (image.containers > 0) return
    requestConfirm(
      "Remove image " + image.repository + ":" + image.tag + "? It may need to be downloaded or rebuilt later.",
      "Remove image", helperCommand(["--remove-image", "--target", image.id]),
      "image:" + image.id, "Image removed.")
  }

  function requestVolumeRemove(volume) {
    if (volume.links > 0) return
    requestConfirm(
      "Permanently delete volume " + volume.name + " (" + volume.size + ")? Its data has no built-in recovery.",
      "Delete volume", helperCommand(["--remove-volume", "--target", volume.name]),
      "volume:" + volume.name, "Volume deleted.")
  }

  function stackMetadata(stack) {
    for (var i = 0; i < stack.containers.length; i++)
      if (stack.containers[i].workingDir) return stack.containers[i]
    return null
  }

  function requestStackUpdate(stack) {
    var meta = stackMetadata(stack)
    if (!meta) {
      actionMessage = "Compose metadata is unavailable for " + stack.name + "."
      actionFailed = true
      actionMessageTimer.restart()
      return
    }
    requestConfirm(
      "Pull current images and recreate changed services in " + stack.name + "? Running services may restart.",
      "Pull & deploy",
      helperCommand(["--pull-redeploy", "--project-directory", meta.workingDir,
                     "--config-files", meta.configFiles || ""]),
      "stack:" + stack.name, stack.name + " updated and deployed.")
  }

  function validateStack(stack) {
    var meta = stackMetadata(stack)
    if (!meta || busyId !== "") return
    busyId = "validate:" + stack.name
    runAction(helperCommand(["--compose-validate", "--project-directory", meta.workingDir,
                             "--config-files", meta.configFiles || ""]),
              stack.name + " configuration is valid.")
  }

  function findStack(project) {
    for (var i = 0; i < stacks.length; i++) if (stacks[i].name === project) return stacks[i]
    return null
  }

  function requestTask(task) {
    var stack = findStack(task.project || "")
    var meta = stack ? stackMetadata(stack) : null
    var args = task.command || []
    if (typeof args === "string") args = ["sh", "-lc", args]
    if (!meta || !task.service || !args.length) {
      actionMessage = "Task " + (task.name || "") + " needs a visible project, service, and command."
      actionFailed = true
      actionMessageTimer.restart()
      return
    }
    var cmd = helperCommand(["--compose-task", "--project-directory", meta.workingDir,
                             "--config-files", meta.configFiles || "", "--service", task.service, "--"])
                 .concat(args)
    requestConfirm(
      "Run " + task.name + " as a one-off " + task.service + " container in " + task.project + "?",
      "Run task", cmd, "task:" + task.name, task.name + " completed.")
  }

  function inspectContainer(c) {
    // Accept both raw helper records and the display records built by grouped.
    var all = info.containers || []
    for (var i = 0; i < all.length; i++) {
      if (all[i].id === c.id) {
        selectedContainer = all[i]
        currentView = "details"
        return
      }
    }
    selectedContainer = c
    currentView = "details"
  }

  function networkSummary(c) {
    var values = [], networks = c && c.networks || []
    for (var i = 0; i < networks.length; i++)
      values.push(networks[i].name + (networks[i].ip ? " (" + networks[i].ip + ")" : ""))
    return values.length ? values.join("\n") : "None"
  }

  function mountSummary(c) {
    var values = [], mounts = c && c.mounts || []
    for (var i = 0; i < mounts.length; i++)
      values.push(mounts[i].type + ": " + mounts[i].source + " → " + mounts[i].destination
                  + (mounts[i].rw ? " (rw)" : " (ro)"))
    return values.length ? values.join("\n") : "None"
  }

  function healthSummary(c) {
    var values = [], logs = c && c.healthLog || []
    for (var i = 0; i < logs.length; i++)
      values.push("exit " + logs[i].exitCode + ": " + (logs[i].output || "no output"))
    return values.length ? values.join("\n") : (c && c.health ? c.health : "No health check")
  }

  function shortTime(value) {
    if (!value || String(value).indexOf("0001-01-01") === 0) return "—"
    return String(value).replace("T", " ").replace(/\.[0-9]+Z$/, " UTC")
  }

  onOpenedChanged: {
    if (!opened) {
      pendingConfirm = null
      stats = {}
    }
  }

  // Flows that open their own UI (floating terminals, the browser) — the
  // panel gets out of their way first.
  function runDetached(cmd) {
    root.close()
    if (root.bar) root.bar.run(cmd)
  }

  function shellQuote(value) {
    return "'" + String(value).replace(/'/g, "'\"'\"'") + "'"
  }

  function commandString(args) {
    var parts = []
    for (var i = 0; i < args.length; i++) parts.push(shellQuote(args[i]))
    return parts.join(" ")
  }

  function openTerminal(args) {
    runDetached("omarchy-launch-floating-terminal-with-presentation " + shellQuote(commandString(args)))
  }

  function showLogs(c) {
    openTerminal(dockerCommand(["logs", "--tail", "200", "-f", c.id]))
  }

  function openShell(c) {
    openTerminal(dockerCommand(["exec", "-it", c.id, "sh"]))
  }

  function showProcesses(c) {
    openTerminal(dockerCommand(["top", c.id]))
  }

  function showChanges(c) {
    openTerminal(dockerCommand(["diff", c.id]))
  }

  function showInspect(c) {
    openTerminal(dockerCommand(["inspect", c.id]))
  }

  function launchTool(tool, c) {
    var image = c ? (c.image || c.imageId || "") : ""
    var prefix = effectiveContext ? ["env", "DOCKER_CONTEXT=" + effectiveContext] : []
    if (tool === "lazydocker") {
      openTerminal(prefix.concat(["lazydocker"]))
    } else if (tool === "dive" && image) openTerminal(prefix.concat(["dive", image]))
    else if (tool === "trivy" && image) openTerminal(prefix.concat(["trivy", "image", image]))
    else if (tool === "scout" && image) openTerminal(dockerCommand(["scout", "quickview", image]))
  }

  function openPort(host) {
    runDetached("xdg-open " + shellQuote("http://localhost:" + host))
  }

  // The daemon switch: plain systemctl as the user — polkit prompts through
  // the shell's own agent. No rules or privileged helpers shipped.
  function toggleDaemon() {
    if (daemonBusy || busyId !== "" || !localContext) return
    daemonProc.command = daemonRunning
      ? ["systemctl", "stop", "docker.service", "docker.socket"]
      : ["systemctl", "start", "docker.service"]
    daemonProc.running = true
  }

  function toggleAutostart() {
    if (autostartProc.running || !localContext) return
    autostartProc.command = ["systemctl", autostart === "enabled" ? "disable" : "enable", "docker.service"]
    autostartProc.running = true
  }

  visible: installed
  implicitWidth: installed ? button.implicitWidth : 0
  implicitHeight: installed ? button.implicitHeight : 0

  Process {
    id: statusProc
    command: [root.panelScript]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.updateInfo(text) }
  }

  // The verbose feed adds `docker system df` for the clean-up section; only
  // the open panel pays for it.
  Process {
    id: detailsProc
    command: [root.panelScript, "--verbose"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.updateInfo(text) }
  }

  Process {
    id: statsProc
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.updateStats(text) }
  }

  Process {
    id: actionProc
    stdout: StdioCollector { id: actionStdout; waitForEnd: true }
    stderr: StdioCollector { id: actionStderr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.actionMessage = root.actionSuccess || "Action complete."
        root.actionFailed = false
        actionMessageTimer.restart()
      } else if (exitCode !== 0) {
        var detail = String(actionStderr.text || actionStdout.text || "").trim().replace(/\s+/g, " ").slice(0, 320)
        root.actionMessage = detail ? "Action failed: " + detail : "Docker action failed (exit " + exitCode + ")."
        root.actionFailed = true
        actionMessageTimer.restart()
      }
      root.busyId = ""
      root.opened ? root.refreshDetails() : root.refresh()
    }
  }

  Timer {
    id: actionMessageTimer
    interval: 8000
    onTriggered: root.actionMessage = ""
  }

  Timer {
    id: contextRefreshTimer
    interval: 100
    onTriggered: root.refreshDetails()
  }

  Process {
    id: daemonProc
    onExited: root.refresh()
  }

  Process {
    id: autostartProc
    onExited: root.refresh()
  }

  // Push-based refresh: any container event triggers a debounced re-read, so
  // work done in a terminal (compose up, stops, health flips) shows up live.
  // A health flip to unhealthy additionally raises a desktop notification.
  Process {
    id: eventsProc
    running: root.daemonRunning
    command: root.dockerCommand(["events", "--format", "{{json .}}", "--filter", "type=container"])
    stdout: SplitParser {
      onRead: function(data) { root.handleEvent(data) }
    }
    onExited: root.opened ? root.refreshDetails() : root.refresh()
  }

  function handleEvent(line) {
    eventDebounce.restart()
    if (!notifyUnhealthy) return
    try {
      var ev = JSON.parse(line)
      if (ev.Action !== "health_status: unhealthy") return
      var name = ev.Actor && ev.Actor.Attributes && ev.Actor.Attributes.name
        ? ev.Actor.Attributes.name
        : String(ev.Actor && ev.Actor.ID || "").slice(0, 12)
      Quickshell.execDetached(["notify-send", "-u", "critical", "-a", "Docker",
                               "Container unhealthy", name + " is failing its health check"])
    } catch (e) {}
  }

  Timer {
    id: eventDebounce
    interval: 300
    onTriggered: root.opened ? root.refreshDetails() : root.refresh()
  }

  // Background poll as a safety net (daemon flips, group membership, events
  // stream hiccups); the open panel has its own cadence.
  Timer {
    interval: Math.max(2, root.setting("interval", 10)) * 1000
    running: !root.opened
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    interval: 10000
    running: root.opened
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshDetails()
  }

  // `docker stats --no-stream` samples for about a second on its own, so it
  // gets a slower cadence and its own process.
  Timer {
    interval: 3000
    running: root.opened && root.daemonRunning
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      if (!statsProc.running) {
        statsProc.command = root.dockerCommand(["stats", "--no-stream", "--format", "{{json .}}"])
        statsProc.running = true
      }
    }
  }

  // ------------------------------------------------------------------ bar ---
  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.showCount && root.daemonRunning && root.runningCount > 0
      ? "󰡨 " + root.runningCount : "󰡨"
    opacity: root.daemonRunning && root.runningCount > 0 ? 1 : 0.5
    // The optional count needs natural width; the bare glyph keeps the
    // fixed status slot like its first-party neighbours.
    slotSize: root.showCount ? -1 : Style.bar.statusSlot
    // Tooltip suppressed because the panel is the detail view.
    tooltipText: ""
    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.refresh()
      else root.toggle()
    }

    // Unhealthy badge: a small urgent dot in the glyph's corner.
    Rectangle {
      visible: root.unhealthyCount > 0
      width: Style.space(6)
      height: width
      radius: width / 2
      color: root.urgent
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.rightMargin: Style.space(4)
      anchors.topMargin: Style.space(4)
    }
  }

  // ---------------------------------------------------------------- panel ---
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened && root.installed
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(620))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      // The card caps at screen height; anything past that scrolls.
      Flickable {
        id: scroller
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
        id: column
        width: scroller.width
        spacing: Style.space(14)

        // ---------- Hero: whale · status · daemon switch ----------
        PanelHero {
          width: parent.width
          title: "OmiDocker"
          meta: root.statusText + "  ·  " + root.effectiveContext
          foreground: root.barForeground
          fontFamily: root.fontFamily
          iconOpacity: root.daemonRunning ? 1.0 : 0.5
          iconComponent: Component {
            Text {
              text: "󰡨"
              color: root.barForeground
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
            }
          }
          trailingControl: Component {
            ToggleSwitch {
              checked: root.daemonBusy ? !root.daemonRunning : root.daemonRunning
              busy: root.daemonBusy
              enabled: root.localContext
              foreground: root.barForeground
              onToggled: root.toggleDaemon()
            }
          }
        }

        Row {
          visible: root.contexts.length > 1
          width: parent.width
          spacing: Style.space(6)

          Repeater {
            model: root.contexts
            Button {
              required property var modelData
              text: modelData.name
              tooltipText: modelData.endpoint || modelData.description || "Docker context"
              fontSize: Style.font.caption
              bordered: root.effectiveContext === modelData.name
              enabled: root.busyId === "" && !root.daemonBusy
              foreground: root.barForeground
              fontFamily: root.fontFamily
              onClicked: root.selectContext(modelData.name)
            }
          }
        }

        Row {
          visible: root.currentView !== "details"
          width: parent.width
          spacing: Style.space(6)

          Repeater {
            model: [
              { id: "containers", label: "Containers" },
              { id: "storage", label: "Storage" },
              { id: "tasks", label: "Tasks" },
              { id: "tools", label: "Tools" }
            ]
            Button {
              required property var modelData
              text: modelData.label
              fontSize: Style.font.caption
              bordered: root.currentView === modelData.id
              foreground: root.barForeground
              fontFamily: root.fontFamily
              onClicked: root.showView(modelData.id)
            }
          }
        }

        Button {
          visible: root.currentView === "details"
          text: "Back to containers"
          iconText: "󰁍"
          fontSize: Style.font.caption
          bordered: true
          foreground: root.barForeground
          fontFamily: root.fontFamily
          onClicked: root.showView("containers")
        }

        Text {
          visible: root.actionMessage !== ""
          width: parent.width
          wrapMode: Text.WordWrap
          text: root.actionMessage
          color: root.actionFailed ? root.urgent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        // ---------- Stacks ----------
        Repeater {
          model: root.currentView === "containers" ? root.stacks : []

          Column {
            id: stackBlock
            required property var modelData
            readonly property int upCount: root.stackRunning(modelData)
            readonly property bool anyUp: upCount > 0
            readonly property bool stackBusy: root.busyId === "stack:" + modelData.name

            width: parent.width
            spacing: Style.space(8)

            PanelSeparator { foreground: root.barForeground }

            Item {
              width: parent.width
              implicitHeight: Math.max(stackHeader.implicitHeight, stackActions.implicitHeight)

              PanelSectionHeader {
                id: stackHeader
                text: stackBlock.modelData.name.toUpperCase()
                      + "  ·  " + stackBlock.upCount + "/" + stackBlock.modelData.containers.length + " up"
                anchors.left: parent.left
                anchors.right: stackActions.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                foreground: root.barForeground
                fontFamily: root.fontFamily
              }

              Row {
                id: stackActions
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(5)

                Button {
                  iconText: "󰚰"
                  text: "Update"
                  tooltipText: "Pull images and redeploy changed services"
                  fontSize: Style.font.caption
                  bordered: true
                  enabled: root.daemonRunning && !stackBlock.stackBusy && root.busyId === ""
                  foreground: root.barForeground
                  fontFamily: root.fontFamily
                  onClicked: root.requestStackUpdate(stackBlock.modelData)
                }

                Button {
                  id: stackButton
                  iconText: stackBlock.anyUp ? "󰓛" : "󰐊"
                  text: stackBlock.anyUp ? "Stop" : "Start"
                  fontSize: Style.font.caption
                  bordered: true
                  enabled: root.daemonRunning && !stackBlock.stackBusy && root.busyId === ""
                  opacity: stackBlock.stackBusy ? 0.5 : 1
                  foreground: root.barForeground
                  fontFamily: root.fontFamily
                  onClicked: root.stackAction(stackBlock.modelData, !stackBlock.anyUp)
                }
              }
            }

            Repeater {
              model: stackBlock.modelData.containers
              ContainerRow {
                required property var modelData
                width: parent.width
                container: modelData
                groupBusy: stackBlock.stackBusy
              }
            }
          }
        }

        // ---------- Standalone containers ----------
        PanelSeparator {
          visible: root.currentView === "containers" && root.standalone.length > 0
          foreground: root.barForeground
        }

        Column {
          visible: root.currentView === "containers" && root.standalone.length > 0
          width: parent.width
          spacing: Style.space(8)

          PanelSectionHeader {
            text: "CONTAINERS"
            foreground: root.barForeground
            fontFamily: root.fontFamily
          }

          Repeater {
            model: root.standalone
            ContainerRow {
              required property var modelData
              width: parent.width
              container: modelData
              groupBusy: false
            }
          }
        }

        // Down or locked out: say what to do instead of a dead list.
        Text {
          visible: root.currentView === "containers" && !root.daemonRunning && !root.daemonBusy && root.daemonState !== "noaccess"
          width: parent.width
          wrapMode: Text.WordWrap
          text: root.localContext
            ? "Docker daemon is stopped — flip the switch to start it."
            : "Docker context " + root.effectiveContext + " is unreachable. Check its endpoint and remote daemon."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        Text {
          visible: root.currentView === "containers" && root.daemonState === "noaccess"
          width: parent.width
          wrapMode: Text.WordWrap
          text: root.localContext
            ? "The Docker socket refused access. Add yourself to the docker group:\nsudo usermod -aG docker $USER\nthen log out and back in."
            : "Docker context " + root.effectiveContext + " refused access. Check credentials and remote Docker permissions."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        // ---------- Clean up ----------
        PanelSeparator {
          visible: root.currentView === "storage" && root.daemonRunning && root.reclaimText !== ""
          foreground: root.barForeground
        }

        Column {
          visible: root.currentView === "storage" && root.daemonRunning && root.reclaimText !== ""
          width: parent.width
          spacing: Style.space(6)

          Item {
            width: parent.width
            implicitHeight: Math.max(cleanupHeader.implicitHeight, pruneButton.implicitHeight)

            PanelSectionHeader {
              id: cleanupHeader
              text: "CLEAN UP"
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              foreground: root.barForeground
              fontFamily: root.fontFamily
            }

            Button {
              id: pruneButton
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              iconText: "󰃢"
              text: "Prune"
              tooltipText: "Remove unused images and build cache"
              fontSize: Style.font.caption
              bordered: true
              enabled: root.busyId === ""
              opacity: root.busyId === "prune" ? 0.5 : 1
              foreground: root.barForeground
              fontFamily: root.fontFamily
              onClicked: root.requestPrune()
            }
          }

          Text {
            width: parent.width
            text: root.reclaimText
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Row {
            spacing: Style.space(5)

            Repeater {
              model: [
                { id: "24h", label: "24h+" },
                { id: "168h", label: "7d+" },
                { id: "720h", label: "30d+" },
                { id: "all", label: "All" }
              ]
              Button {
                required property var modelData
                text: modelData.label
                tooltipText: "Only clean unused data older than this"
                fontSize: Style.font.caption
                bordered: root.pruneAge === modelData.id
                foreground: root.barForeground
                fontFamily: root.fontFamily
                onClicked: root.pruneAge = modelData.id
              }
            }
          }
        }

        // ---------- Storage inventory ----------
        PanelSeparator {
          visible: root.currentView === "storage" && root.daemonRunning
          foreground: root.barForeground
        }

        Column {
          visible: root.currentView === "storage" && root.daemonRunning
          width: parent.width
          spacing: Style.space(8)

          PanelSectionHeader {
            text: "IMAGES  ·  " + (root.storageInfo.images || []).length
            foreground: root.barForeground
            fontFamily: root.fontFamily
          }

          Repeater {
            model: root.storageInfo.images || []
            Item {
              required property var modelData
              width: parent.width
              implicitHeight: Math.max(imageText.implicitHeight, imageRemove.implicitHeight)

              Column {
                id: imageText
                anchors.left: parent.left
                anchors.right: imageRemove.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter

                Text {
                  width: parent.width
                  elide: Text.ElideMiddle
                  text: modelData.repository + ":" + modelData.tag
                  color: root.barForeground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
                Text {
                  text: modelData.size + "  ·  " + modelData.created + "  ·  "
                        + modelData.containers + " container" + (modelData.containers === 1 ? "" : "s")
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              Button {
                id: imageRemove
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                visible: modelData.containers === 0
                iconText: "󰆴"
                tooltipText: "Remove this unused image"
                bordered: true
                enabled: root.busyId === ""
                foreground: root.barForeground
                fontFamily: root.fontFamily
                onClicked: root.requestImageRemove(modelData)
              }
            }
          }
        }

        PanelSeparator {
          visible: root.currentView === "storage" && root.daemonRunning
          foreground: root.barForeground
        }

        Column {
          visible: root.currentView === "storage" && root.daemonRunning
          width: parent.width
          spacing: Style.space(8)

          Item {
            width: parent.width
            implicitHeight: Math.max(volumeHeader.implicitHeight, volumePrune.implicitHeight)

            PanelSectionHeader {
              id: volumeHeader
              text: "VOLUMES  ·  " + (root.storageInfo.volumes || []).length
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              foreground: root.barForeground
              fontFamily: root.fontFamily
            }

            Button {
              id: volumePrune
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              visible: root.unusedVolumeCount > 0
              text: "Delete unused (" + root.unusedVolumeCount + ")"
              iconText: "󰆴"
              tooltipText: "Permanently delete every unused volume"
              fontSize: Style.font.caption
              bordered: true
              enabled: root.busyId === ""
              foreground: root.urgent
              fontFamily: root.fontFamily
              onClicked: root.requestVolumePrune()
            }
          }

          Repeater {
            model: root.storageInfo.volumes || []
            Item {
              required property var modelData
              width: parent.width
              implicitHeight: Math.max(volumeText.implicitHeight, volumeRemove.implicitHeight)

              Column {
                id: volumeText
                anchors.left: parent.left
                anchors.right: volumeRemove.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter

                Text {
                  width: parent.width
                  elide: Text.ElideMiddle
                  text: modelData.name
                  color: root.barForeground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
                Text {
                  text: modelData.size + "  ·  " + (modelData.links > 0 ? "in use" : "unused")
                        + (modelData.composeProject ? "  ·  " + modelData.composeProject : "")
                  color: modelData.links > 0 ? root.dim : root.urgent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              Button {
                id: volumeRemove
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                visible: modelData.links === 0
                iconText: "󰆴"
                tooltipText: "Permanently delete this unused volume"
                bordered: true
                enabled: root.busyId === ""
                foreground: root.urgent
                fontFamily: root.fontFamily
                onClicked: root.requestVolumeRemove(modelData)
              }
            }
          }

          Text {
            visible: (root.storageInfo.buildCache || []).length > 0
            text: (root.storageInfo.buildCache || []).length + " build-cache record(s)"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        // ---------- Compose tasks ----------
        PanelSeparator {
          visible: root.currentView === "tasks"
          foreground: root.barForeground
        }

        Column {
          visible: root.currentView === "tasks"
          width: parent.width
          spacing: Style.space(8)

          PanelSectionHeader {
            text: "COMPOSE CONFIGURATION"
            foreground: root.barForeground
            fontFamily: root.fontFamily
          }

          Repeater {
            model: root.stacks
            Item {
              required property var modelData
              width: parent.width
              implicitHeight: validateButton.implicitHeight

              Text {
                anchors.left: parent.left
                anchors.right: validateButton.left
                anchors.verticalCenter: parent.verticalCenter
                text: modelData.name
                color: root.barForeground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
              Button {
                id: validateButton
                anchors.right: parent.right
                text: "Validate"
                iconText: "󰅖"
                tooltipText: "Run docker compose config --quiet"
                fontSize: Style.font.caption
                bordered: true
                enabled: root.busyId === ""
                foreground: root.barForeground
                fontFamily: root.fontFamily
                onClicked: root.validateStack(modelData)
              }
            }
          }

          Text {
            visible: root.stacks.length === 0
            width: parent.width
            wrapMode: Text.WordWrap
            text: "No Compose stacks are visible in this context."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          PanelSectionHeader {
            text: "ONE-OFF TASKS"
            foreground: root.barForeground
            fontFamily: root.fontFamily
          }

          Repeater {
            model: root.configuredTasks
            Item {
              required property var modelData
              width: parent.width
              implicitHeight: taskButton.implicitHeight

              Column {
                anchors.left: parent.left
                anchors.right: taskButton.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                Text {
                  text: modelData.name || "Task"
                  color: root.barForeground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
                Text {
                  text: (modelData.project || "project?") + "  ·  " + (modelData.service || "service?")
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
              Button {
                id: taskButton
                anchors.right: parent.right
                text: "Run"
                iconText: "󰐊"
                fontSize: Style.font.caption
                bordered: true
                enabled: root.busyId === ""
                foreground: root.barForeground
                fontFamily: root.fontFamily
                onClicked: root.requestTask(modelData)
              }
            }
          }

          Text {
            visible: root.configuredTasks.length === 0
            width: parent.width
            wrapMode: Text.WordWrap
            text: "Add tasks to this widget's tasks setting. Commands run through docker compose run --rm after confirmation."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }

        // ---------- Container inspector ----------
        Column {
          visible: root.currentView === "details" && root.selectedContainer !== null
          width: parent.width
          spacing: Style.space(9)

          PanelSectionHeader {
            text: root.selectedContainer ? String(root.selectedContainer.name || "CONTAINER").toUpperCase() : "CONTAINER"
            foreground: root.barForeground
            fontFamily: root.fontFamily
          }

          Row {
            spacing: Style.space(5)
            Button { text: "Logs"; iconText: "󰈙"; bordered: true; foreground: root.barForeground; fontFamily: root.fontFamily; onClicked: root.showLogs(root.selectedContainer) }
            Button { text: "Shell"; iconText: "󰆍"; bordered: true; enabled: root.selectedContainer && root.selectedContainer.state === "running"; foreground: root.barForeground; fontFamily: root.fontFamily; onClicked: root.openShell(root.selectedContainer) }
            Button { text: "Top"; iconText: "󰄬"; bordered: true; foreground: root.barForeground; fontFamily: root.fontFamily; onClicked: root.showProcesses(root.selectedContainer) }
            Button { text: "Diff"; iconText: "󰦓"; bordered: true; foreground: root.barForeground; fontFamily: root.fontFamily; onClicked: root.showChanges(root.selectedContainer) }
            Button { text: "JSON"; iconText: "󰘦"; bordered: true; foreground: root.barForeground; fontFamily: root.fontFamily; onClicked: root.showInspect(root.selectedContainer) }
          }

          Repeater {
            model: root.selectedContainer ? [
              { label: "Image", value: root.selectedContainer.image + "  ·  " + root.selectedContainer.imageId, danger: false },
              { label: "State", value: root.selectedContainer.state + "  ·  exit " + root.selectedContainer.exitCode + (root.selectedContainer.oomKilled ? "  ·  OOM killed" : ""), danger: root.selectedContainer.oomKilled || root.selectedContainer.exitCode !== 0 },
              { label: "Command", value: root.selectedContainer.command, danger: false },
              { label: "Restart policy", value: root.selectedContainer.restartPolicy + "  ·  " + root.selectedContainer.restartCount + " restart(s)", danger: false },
              { label: "Started", value: root.shortTime(root.selectedContainer.startedAt), danger: false },
              { label: "Finished", value: root.shortTime(root.selectedContainer.finishedAt), danger: false },
              { label: "Networks", value: root.networkSummary(root.selectedContainer), danger: false },
              { label: "Mounts", value: root.mountSummary(root.selectedContainer), danger: false },
              { label: "Environment keys", value: root.selectedContainer.envKeys.length ? root.selectedContainer.envKeys.join(", ") : "None", danger: false },
              { label: "Health", value: root.healthSummary(root.selectedContainer), danger: root.selectedContainer.health === "unhealthy" }
            ] : []

            Column {
              required property var modelData
              width: parent.width
              spacing: Style.space(2)
              Text {
                text: modelData.label.toUpperCase()
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
              Text {
                width: parent.width
                wrapMode: Text.WrapAnywhere
                text: modelData.value || "—"
                color: modelData.danger ? root.urgent : root.barForeground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
            }
          }

          Row {
            visible: root.toolInfo.dive || root.toolInfo.trivy || root.toolInfo.scout
            spacing: Style.space(5)
            Button { visible: root.toolInfo.dive; text: "Dive"; bordered: true; foreground: root.barForeground; fontFamily: root.fontFamily; onClicked: root.launchTool("dive", root.selectedContainer) }
            Button { visible: root.toolInfo.trivy; text: "Trivy"; bordered: true; foreground: root.barForeground; fontFamily: root.fontFamily; onClicked: root.launchTool("trivy", root.selectedContainer) }
            Button { visible: root.toolInfo.scout; text: "Scout"; bordered: true; foreground: root.barForeground; fontFamily: root.fontFamily; onClicked: root.launchTool("scout", root.selectedContainer) }
          }
        }

        // ---------- Tools and daemon settings ----------
        PanelSeparator {
          visible: root.currentView === "tools"
          foreground: root.barForeground
        }

        Column {
          visible: root.currentView === "tools"
          width: parent.width
          spacing: Style.space(8)

          PanelSectionHeader { text: "OPTIONAL TOOLS"; foreground: root.barForeground; fontFamily: root.fontFamily }

          Item {
            width: parent.width
            implicitHeight: lazydockerButton.implicitHeight
            Text {
              anchors.left: parent.left
              anchors.right: lazydockerButton.left
              anchors.verticalCenter: parent.verticalCenter
              text: "LazyDocker  ·  " + (root.toolInfo.lazydocker ? "installed" : "not installed")
              color: root.toolInfo.lazydocker ? root.barForeground : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
            Button {
              id: lazydockerButton
              anchors.right: parent.right
              visible: root.toolInfo.lazydocker
              text: "Open"
              iconText: "󰆍"
              bordered: true
              foreground: root.barForeground
              fontFamily: root.fontFamily
              onClicked: root.launchTool("lazydocker", null)
            }
          }

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            text: "Image tools: Dive " + (root.toolInfo.dive ? "installed" : "not installed")
                  + "  ·  Trivy " + (root.toolInfo.trivy ? "installed" : "not installed")
                  + "  ·  Scout " + (root.toolInfo.scout ? "installed" : "not installed")
                  + ". Open a container's details to launch an installed image tool."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }

        // ---------- Autostart ----------
        PanelSeparator {
          visible: root.currentView === "tools" && root.localContext
          foreground: root.barForeground
        }

        Toggle {
          visible: root.currentView === "tools" && root.localContext
          width: parent.width
          label: "Start at boot"
          description: "Enable docker.service at system boot"
          checked: root.autostart === "enabled"
          foreground: root.barForeground
          fontFamily: root.fontFamily
          onClicked: root.toggleAutostart()
        }
        }
      }

      ConfirmDialog {
        anchors.fill: parent
        opened: root.pendingConfirm !== null
        message: root.pendingConfirm ? root.pendingConfirm.message : ""
        confirmText: root.pendingConfirm ? root.pendingConfirm.confirmText : "Confirm"
        fontFamily: root.fontFamily
        onConfirmed: root.acceptConfirm()
        onCanceled: root.pendingConfirm = null
      }
    }
  }

  // One container line: status dot · name + image/stats · ports · actions.
  // Ports open in the browser; logs and a shell open detached terminals.
  // A stopped container with a port-conflict note renders it in urgent below.
  component ContainerRow: Column {
    id: row
    property var container: ({})
    property bool groupBusy: false

    readonly property bool running: container.state === "running"
    readonly property bool paused: container.state === "paused"
    readonly property bool unhealthy: container.health === "unhealthy"
    readonly property bool rowBusy: root.busyId === container.id || groupBusy
    readonly property var stat: root.stats[container.id] || null
    readonly property string detail: {
      if (unhealthy) return "unhealthy"
      if (container.health === "starting") return "starting"
      if (paused) return "paused"
      if (container.state === "restarting") return "restarting"
      if (!running) return "exited"
      return ""
    }

    spacing: Style.space(2)
    opacity: rowBusy ? 0.5 : (root.daemonRunning ? 1 : 0.5)

    Item {
      width: parent.width
      implicitHeight: Math.max(nameCol.implicitHeight, actions.implicitHeight)

      Rectangle {
        id: statusDot
        width: Style.space(8)
        height: width
        radius: width / 2
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        color: row.unhealthy ? root.urgent : (row.running ? root.barForeground : "transparent")
        border.width: row.running || row.unhealthy ? 0 : 1
        border.color: root.faint
      }

      Column {
        id: nameCol
        anchors.left: statusDot.right
        anchors.leftMargin: Style.space(10)
        anchors.right: portsRow.left
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        spacing: 0

        Text {
          width: parent.width
          elide: Text.ElideRight
          text: row.container.name || ""
          color: root.barForeground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        Text {
          width: parent.width
          elide: Text.ElideRight
          text: (row.container.image || "")
                + (row.running && row.stat ? "  ·  " + row.stat.cpu + "  ·  " + row.stat.mem : "")
                + (row.detail ? "  ·  " + row.detail : "")
          color: row.unhealthy ? root.urgent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      Row {
        id: portsRow
        anchors.right: actions.left
        anchors.rightMargin: Style.space(10)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(6)

        Repeater {
          model: row.container.portsList || []

          Text {
            id: portText
            required property var modelData
            text: modelData.label
            color: portArea.containsMouse ? root.barForeground : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption

            MouseArea {
              id: portArea
              anchors.fill: parent
              enabled: portText.modelData.web && row.running
              hoverEnabled: true
              cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
              onClicked: root.openPort(portText.modelData.host)
            }
          }
        }
      }

      Row {
        id: actions
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(4)

        Button {
          iconText: "󰋼"
          tooltipText: "Details"
          fontSize: Style.font.caption
          foreground: root.barForeground
          fontFamily: root.fontFamily
          onClicked: root.inspectContainer(row.container)
        }

        // Logs and shell are flat icons: read-only doors, not state changes.
        Button {
          iconText: "󰈙"
          tooltipText: "Logs"
          fontSize: Style.font.caption
          foreground: root.barForeground
          fontFamily: root.fontFamily
          onClicked: root.showLogs(row.container)
        }

        // Invisible but space-keeping on stopped rows, so every row keeps the
        // same action geometry and the ports column lines up across rows.
        Button {
          opacity: row.running ? 1 : 0
          enabled: row.running
          iconText: "󰆍"
          tooltipText: "Shell"
          fontSize: Style.font.caption
          foreground: root.barForeground
          fontFamily: root.fontFamily
          onClicked: root.openShell(row.container)
        }

        Button {
          visible: !row.running
          iconText: "󰩺"
          tooltipText: "Remove"
          fontSize: Style.font.caption
          bordered: true
          enabled: root.daemonRunning && !row.rowBusy && root.busyId === ""
          foreground: root.barForeground
          fontFamily: root.fontFamily
          onClicked: root.requestRemove(row.container)
        }

        Button {
          visible: row.running
          iconText: "󰜉"
          tooltipText: "Restart"
          fontSize: Style.font.caption
          bordered: true
          enabled: root.daemonRunning && !row.rowBusy && root.busyId === ""
          foreground: root.barForeground
          fontFamily: root.fontFamily
          onClicked: root.containerAction(row.container, "restart")
        }

        Button {
          iconText: row.running ? "󰓛" : "󰐊"
          tooltipText: row.running ? "Stop" : (row.paused ? "Unpause" : "Start")
          fontSize: Style.font.caption
          bordered: true
          enabled: root.daemonRunning && !row.rowBusy && root.busyId === ""
          foreground: root.barForeground
          fontFamily: root.fontFamily
          onClicked: root.containerAction(row.container, row.running ? "stop" : "start")
        }
      }
    }

    Text {
      visible: !row.running && !!row.container.note
      x: Style.space(18)
      width: parent.width - x
      wrapMode: Text.WordWrap
      text: "󰀦 " + (row.container.note || "")
      color: root.urgent
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }
}

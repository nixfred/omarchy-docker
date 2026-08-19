import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Docker bar widget with an anchored popup panel, following the same pattern
// as erruviel.wwan: all state comes from `bin/docker-panel` — one process
// spawn per refresh — with `docker events` streaming in the background so
// external changes show up without waiting for the next poll.
//
// Everything here runs unprivileged. Container actions go through the docker
// CLI (docker group membership), and the daemon switch calls systemctl as the
// user, which authenticates through the shell's polkit agent.
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

  // One action in flight at a time; the affected row dims while it runs.
  property string busyId: ""

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
        name: c.project ? (c.service || c.name) : c.name,
        image: c.image || "",
        state: c.state,
        health: c.health || "",
        portsLabel: formatPorts(c.ports || []),
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

  readonly property string statusText: {
    if (daemonBusy) return daemonRunning ? "Stopping Docker…" : "Starting Docker…"
    if (daemonState === "noaccess") return "No access to the Docker socket"
    if (!daemonRunning) return "Docker daemon stopped"
    if (totalCount === 0) return "No containers"
    var s = runningCount + " of " + totalCount + " running"
    if (unhealthyCount > 0) s += " · " + unhealthyCount + " unhealthy"
    return s
  }

  function formatPorts(ports) {
    var out = []
    for (var i = 0; i < ports.length; i++) {
      var host = ports[i].host
      var cont = ports[i].container || ""
      var proto = cont.indexOf("/udp") >= 0 ? "/udp" : ""
      cont = cont.split("/")[0]
      out.push((host === cont ? host : host + "→" + cont) + proto)
    }
    return out.join(" ")
  }

  function stackRunning(stack) {
    var n = 0
    for (var i = 0; i < stack.containers.length; i++)
      if (stack.containers[i].state === "running") n++
    return n
  }

  // -------------------------------------------------------------- refresh ---
  function refresh() {
    if (!statusProc.running) statusProc.running = true
  }

  function updateInfo(raw) {
    // Keep the last known state across a transient bad read, so the widget
    // never blinks out while docker is briefly unavailable.
    try {
      var next = JSON.parse(raw)
      if (next && typeof next === "object") info = next
    } catch (e) {}
  }

  // -------------------------------------------------------------- actions ---
  function runAction(cmd) {
    if (actionProc.running) return
    actionProc.command = cmd
    actionProc.running = true
  }

  function containerAction(c, action) {
    if (busyId !== "" || daemonBusy || !daemonRunning) return
    busyId = c.id
    if (action === "start" && c.state === "paused") runAction(["docker", "unpause", c.id])
    else runAction(["docker", action, c.id])
  }

  function stackAction(stack, start) {
    if (busyId !== "" || daemonBusy || !daemonRunning) return
    var ids = []
    for (var i = 0; i < stack.containers.length; i++) {
      var c = stack.containers[i]
      if (start !== (c.state === "running")) ids.push(c.id)
    }
    if (ids.length === 0) return
    busyId = "stack:" + stack.name
    runAction(["docker", start ? "start" : "stop"].concat(ids))
  }

  // The daemon switch: plain systemctl as the user — polkit prompts through
  // the shell's own agent. No rules or privileged helpers shipped.
  function toggleDaemon() {
    if (daemonBusy || busyId !== "") return
    daemonProc.command = daemonRunning
      ? ["systemctl", "stop", "docker.service", "docker.socket"]
      : ["systemctl", "start", "docker.service"]
    daemonProc.running = true
  }

  visible: installed
  implicitWidth: installed ? button.implicitWidth : 0
  implicitHeight: installed ? button.implicitHeight : 0

  Process {
    id: statusProc
    command: [root.panelScript]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.updateInfo(text) }
  }

  Process {
    id: actionProc
    onExited: { root.busyId = ""; root.refresh() }
  }

  Process {
    id: daemonProc
    onExited: root.refresh()
  }

  // Push-based refresh: any container event triggers a debounced re-read, so
  // work done in a terminal (compose up, stops, health flips) shows up live.
  Process {
    id: eventsProc
    running: root.daemonRunning
    command: ["docker", "events", "--format", "{{.Status}}", "--filter", "type=container"]
    stdout: SplitParser { onRead: eventDebounce.restart() }
    onExited: root.refresh()
  }

  Timer {
    id: eventDebounce
    interval: 300
    onTriggered: root.refresh()
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
    interval: 2000
    running: root.opened
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // ------------------------------------------------------------------ bar ---
  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰡨"
    opacity: root.daemonRunning && root.runningCount > 0 ? 1 : 0.5
    slotSize: Style.bar.statusSlot
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
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(14)

        // ---------- Hero: whale · status · daemon switch ----------
        PanelHero {
          width: parent.width
          title: "Docker"
          meta: root.statusText
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
              foreground: root.barForeground
              onToggled: root.toggleDaemon()
            }
          }
        }

        // ---------- Stacks ----------
        Repeater {
          model: root.stacks

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
              implicitHeight: Math.max(stackHeader.implicitHeight, stackButton.implicitHeight)

              PanelSectionHeader {
                id: stackHeader
                text: stackBlock.modelData.name.toUpperCase()
                      + "  ·  " + stackBlock.upCount + "/" + stackBlock.modelData.containers.length + " up"
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                foreground: root.barForeground
                fontFamily: root.fontFamily
              }

              Button {
                id: stackButton
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
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
          visible: root.standalone.length > 0
          foreground: root.barForeground
        }

        Column {
          visible: root.standalone.length > 0
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
          visible: !root.daemonRunning && !root.daemonBusy && root.daemonState !== "noaccess"
          width: parent.width
          wrapMode: Text.WordWrap
          text: "Docker daemon is stopped — flip the switch to start it."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        Text {
          visible: root.daemonState === "noaccess"
          width: parent.width
          wrapMode: Text.WordWrap
          text: "The Docker socket refused access. Add yourself to the docker group:\nsudo usermod -aG docker $USER\nthen log out and back in."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
      }
    }
  }

  // One container line: status dot · name + image · ports · actions.
  // A stopped container with a port-conflict note renders it in urgent below.
  component ContainerRow: Column {
    id: row
    property var container: ({})
    property bool groupBusy: false

    readonly property bool running: container.state === "running"
    readonly property bool paused: container.state === "paused"
    readonly property bool unhealthy: container.health === "unhealthy"
    readonly property bool rowBusy: root.busyId === container.id || groupBusy
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
        anchors.right: portsText.left
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
          text: (row.container.image || "") + (row.detail ? "  ·  " + row.detail : "")
          color: row.unhealthy ? root.urgent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      Text {
        id: portsText
        anchors.right: actions.left
        anchors.rightMargin: Style.space(10)
        anchors.verticalCenter: parent.verticalCenter
        text: row.container.portsLabel || ""
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      Row {
        id: actions
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(4)

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

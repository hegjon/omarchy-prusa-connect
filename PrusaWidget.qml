import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Bar widget and popup for a Prusa Connect printer fleet.
//
// All network work happens in prusa-connect-fetch, which prints the normalized
// model on stdout and reports failures as {"error":…} rather than dying, so the
// panel can always render a reason. Nothing here ever touches a credential.
Panel {
  id: root

  readonly property string pluginId: "io.github.hegjon.prusa-connect"

  moduleName: pluginId
  ipcTarget: pluginId

  // --- state ------------------------------------------------------------

  property var printers: []
  property var fleet: ({ total: 0, online: 0, printing: 0, attention: 0, finished: 0, offline: 0 })
  property string lastError: ""
  property bool needsLogin: false
  property bool initialized: false
  property bool refreshing: false
  property real lastUpdatedAt: 0

  // Notification bookkeeping, keyed by printer uuid.
  property var lastStateById: ({})
  property var notifiedAt: ({})

  // --- settings ---------------------------------------------------------

  // `omarchy bar set` stores booleans as strings unless given --json, so a
  // boolean setting has to be coerced rather than read straight through.
  function boolSetting(key, fallback) {
    var value = settings ? settings[key] : undefined
    if (value === undefined || value === null) return fallback
    if (typeof value === "string") return value !== "false" && value !== "0" && value !== ""
    return value !== false
  }

  function intSetting(key, fallback, min, max) {
    var value = parseInt(setting(key, fallback), 10)
    if (!isFinite(value)) return fallback
    return Math.max(min, Math.min(max, value))
  }

  readonly property bool showBarSummary: boolSetting("showBarSummary", true)
  readonly property bool hideIdlePrinters: boolSetting("hideIdlePrinters", false)
  readonly property int refreshIntervalMs: intSetting("refreshIntervalSec", 30, 10, 300) * 1000
  readonly property bool watchEnabled: boolSetting("watch", true)
  readonly property int watchIntervalMs: intSetting("watchIntervalSec", 300, 60, 3600) * 1000
  readonly property bool notifyFinished: boolSetting("notifyFinished", true)
  readonly property bool notifyAttention: boolSetting("notifyAttention", true)
  readonly property bool notifyError: boolSetting("notifyError", true)
  readonly property int notifyCooldownMs: intSetting("notifyCooldownMin", 10, 1, 240) * 60000
  readonly property bool celsius: boolSetting("celsius", true)

  // Qt.resolvedUrl yields a file:// URL; Process wants a plain path.
  readonly property string backendPath:
    Qt.resolvedUrl("prusa-connect-fetch").toString().replace(/^file:\/\//, "")

  readonly property string printerGlyph: String.fromCodePoint(0xF042A)   // nf-md-printer

  // --- formatting -------------------------------------------------------

  function stateLabel(state) {
    switch (state) {
      case "PRINTING": return "Printing"
      case "PAUSED": return "Paused"
      case "FINISHED": return "Finished"
      case "ATTENTION": return "Attention"
      case "ERROR": return "Error"
      case "OFFLINE": return "Offline"
      case "IDLE": return "Idle"
      case "READY": return "Ready"
      case "BUSY": return "Busy"
      case "STOPPED": return "Stopped"
      default: return state ? state.charAt(0) + state.slice(1).toLowerCase() : "Unknown"
    }
  }

  function stateColor(state) {
    switch (state) {
      case "ERROR":
      case "ATTENTION": return Color.urgent
      case "PRINTING": return Color.accent
      case "OFFLINE": return Color.muted
      default: return Color.popups.text
    }
  }

  function formatTemp(value) {
    if (value === null || value === undefined) return "--"
    var shown = celsius ? value : value * 9 / 5 + 32
    return Math.round(shown) + "°"
  }

  function formatDuration(seconds) {
    if (seconds === null || seconds === undefined || !isFinite(seconds) || seconds < 0) return ""
    var total = Math.round(seconds)
    var hours = Math.floor(total / 3600)
    var minutes = Math.floor((total % 3600) / 60)
    if (hours > 0) return hours + "h" + (minutes < 10 ? "0" : "") + minutes + "m"
    if (minutes > 0) return minutes + "m"
    return total + "s"
  }

  function formatAgo(epochSeconds) {
    if (!epochSeconds) return "never"
    var deltaSeconds = Date.now() / 1000 - epochSeconds
    if (deltaSeconds < 90) return "just now"
    if (deltaSeconds < 3600) return Math.round(deltaSeconds / 60) + " min ago"
    if (deltaSeconds < 86400) return Math.round(deltaSeconds / 3600) + " h ago"
    return Math.round(deltaSeconds / 86400) + " d ago"
  }

  // Offline printers keep reporting their last known printer_state, which can be
  // months stale, so they are worth hiding on a busy fleet.
  readonly property var visiblePrinters: {
    if (!hideIdlePrinters) return printers
    return printers.filter(function(printer) {
      return printer.state !== "OFFLINE" && printer.state !== "IDLE" && printer.state !== "READY"
    })
  }

  readonly property string barSummary: {
    if (!showBarSummary || !initialized) return ""
    if (fleet.printing > 0) {
      var printing = printers.filter(function(p) { return p.state === "PRINTING" })
      // One printer running is the common case, so show its progress rather
      // than a count that says less.
      if (printing.length === 1 && printing[0].job && printing[0].job.progress !== null)
        return Math.round(printing[0].job.progress) + "%"
      return fleet.printing + " printing"
    }
    if (fleet.attention > 0) return fleet.attention + " attention"
    return ""
  }

  readonly property string tooltipSummary: {
    if (needsLogin) return "Prusa Connect: not signed in"
    if (lastError !== "") return "Prusa Connect: " + lastError
    if (!initialized) return "Prusa Connect: loading…"
    var parts = []
    if (fleet.printing > 0) parts.push(fleet.printing + " printing")
    if (fleet.attention > 0) parts.push(fleet.attention + " needs attention")
    if (fleet.online > 0) parts.push(fleet.online + " online")
    if (parts.length === 0) parts.push(fleet.total + " printers")
    return parts.join(" · ")
  }

  // --- fetching ---------------------------------------------------------

  function refresh() {
    if (fetchProcess.running) return
    refreshing = true
    fetchProcess.command = [backendPath]
    fetchProcess.running = true
  }

  function applyOutput(text) {
    refreshing = false
    initialized = true

    var parsed
    try {
      parsed = JSON.parse(String(text || ""))
    } catch (error) {
      lastError = "The Prusa helper returned something unreadable"
      return
    }

    if (parsed && parsed.error) {
      lastError = String(parsed.error)
      needsLogin = parsed.needsLogin === true
      return
    }

    lastError = ""
    needsLogin = false
    printers = (parsed && parsed.printers) ? parsed.printers : []
    if (parsed && parsed.summary) fleet = parsed.summary
    lastUpdatedAt = Date.now()

    evaluateNotifications()
  }

  // --- notifications ----------------------------------------------------

  function notificationFor(printer, previousState) {
    // Only a transition is worth announcing; a printer sitting in ATTENTION
    // across a dozen polls should notify once, not a dozen times.
    if (previousState === undefined || previousState === printer.state) return null

    if (printer.state === "FINISHED" && notifyFinished)
      return { urgency: "normal", body: "Print finished" }

    if (printer.state === "ERROR" && notifyError)
      return { urgency: "critical", body: "Printer error" }

    if (printer.state === "ATTENTION" && notifyAttention) {
      var detail = printer.attention && printer.attention.title
        ? printer.attention.title : "Needs attention"
      return { urgency: "critical", body: detail }
    }

    return null
  }

  function evaluateNotifications() {
    var states = {}
    var stamps = notifiedAt
    var now = Date.now()

    for (var i = 0; i < printers.length; i++) {
      var printer = printers[i]
      if (!printer.uuid) continue
      states[printer.uuid] = printer.state

      var notification = notificationFor(printer, lastStateById[printer.uuid])
      if (!notification) continue

      var last = stamps[printer.uuid] || 0
      if (now - last < notifyCooldownMs) continue
      stamps[printer.uuid] = now

      notify(printer.name, notification.body, notification.urgency)
    }

    lastStateById = states
    notifiedAt = stamps
  }

  function notify(title, body, urgency) {
    notifyProcess.running = false
    notifyProcess.command = [
      "omarchy-notification-send", "-a", "Prusa Connect",
      "-u", urgency || "normal",
      String(title || "Printer"), String(body || "")
    ]
    notifyProcess.running = true
  }

  // --- processes and timers ---------------------------------------------

  Process {
    id: fetchProcess
    running: false
    command: []

    stdout: StdioCollector { id: fetchStdout; waitForEnd: true }
    stderr: StdioCollector { id: fetchStderr; waitForEnd: true }

    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.applyOutput(fetchStdout.text)
        return
      }
      root.refreshing = false
      root.initialized = true
      var detail = String(fetchStderr.text || "").replace(/\s+/g, " ").trim()
      root.lastError = detail !== ""
        ? detail
        : "The Prusa helper exited with code " + exitCode
    }
  }

  Process {
    id: notifyProcess
    running: false
    command: []
  }

  Timer {
    // Poll faster while the panel is open; fall back to the background cadence
    // so the bar summary and notifications stay live without hammering Connect.
    interval: root.opened ? root.refreshIntervalMs : root.watchIntervalMs
    running: root.opened || root.watchEnabled
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // A newly opened panel should not show data from twenty minutes ago.
  onOpenedChanged: if (opened) refresh()

  // --- bar button -------------------------------------------------------

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.barSummary !== ""
      ? root.printerGlyph + "  " + root.barSummary
      : root.printerGlyph
    dimmed: root.needsLogin || root.lastError !== ""
    active: root.fleet.attention > 0 || root.lastError !== ""
    activeColor: Color.urgent
    tooltipText: root.tooltipSummary
    slotSize: Style.bar.statusSlot

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton) root.refresh()
      else root.toggle()
    }
  }

  // --- popup ------------------------------------------------------------

  KeyboardPanel {
    id: fleetPanel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: fleetPanel.fittedContentWidth(Style.space(420))
    contentHeight: fleetPanel.fittedContentHeight(column.implicitHeight, Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      // One action per press: a held key would otherwise refetch every repeat.
      property string heldKey: ""
      Keys.onReleased: function(event) { if (!event.isAutoRepeat) keyCatcher.heldKey = "" }
      onTextKey: function(text) {
        var key = text.toLowerCase()
        if (heldKey === key) return
        heldKey = key
        if (key === "r") root.refresh()
      }

      Column {
        id: column
        width: parent.width
        spacing: Style.space(10)

        PanelSectionHeader {
          width: parent.width
          text: "Prusa Connect"
        }

        // Sign-in prompt takes over the panel: nothing else can work without it.
        Column {
          width: parent.width
          spacing: Style.space(6)
          visible: root.needsLogin

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            text: root.lastError !== "" ? root.lastError : "Not signed in to Prusa Connect."
            color: Color.urgent
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            text: "Run prusa-connect-login in a terminal to sign in."
            color: Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        Text {
          width: parent.width
          wrapMode: Text.WordWrap
          visible: !root.needsLogin && root.lastError !== ""
          text: root.lastError
          color: Color.urgent
          font.family: Style.font.family
          font.pixelSize: Style.font.body
        }

        Text {
          width: parent.width
          visible: !root.initialized && root.lastError === ""
          text: "Loading…"
          color: Color.muted
          font.family: Style.font.family
          font.pixelSize: Style.font.body
        }

        Text {
          width: parent.width
          visible: root.initialized && root.lastError === "" && root.visiblePrinters.length === 0
          text: root.printers.length === 0
            ? "No printers in this Prusa Connect account."
            : "All printers are idle or offline."
          color: Color.muted
          font.family: Style.font.family
          font.pixelSize: Style.font.body
        }

        Repeater {
          model: root.visiblePrinters

          Column {
            required property var modelData

            width: column.width
            spacing: Style.space(2)

            // Name and state on one line, state colored by severity.
            Row {
              width: parent.width
              spacing: Style.space(8)

              Text {
                width: parent.width - stateText.implicitWidth - Style.space(8)
                elide: Text.ElideRight
                text: modelData.name
                color: Color.popups.text
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                font.bold: true
              }

              Text {
                id: stateText
                text: root.stateLabel(modelData.state)
                  + (modelData.job && modelData.job.progress !== null
                     ? "  " + Math.round(modelData.job.progress) + "%" : "")
                color: root.stateColor(modelData.state)
                font.family: Style.font.family
                font.pixelSize: Style.font.body
              }
            }

            // Current job, when one is running.
            Text {
              width: parent.width
              elide: Text.ElideRight
              visible: modelData.job !== null && modelData.job !== undefined
              text: {
                if (!modelData.job) return ""
                var parts = []
                if (modelData.job.name) parts.push(modelData.job.name)
                var remaining = root.formatDuration(modelData.job.remaining)
                if (remaining !== "") parts.push("ETA " + remaining)
                return parts.join("  ·  ")
              }
              color: Color.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }

            // Why the printer wants attention, straight from Connect's dialog.
            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              visible: modelData.attention !== null && modelData.attention !== undefined
              text: modelData.attention
                ? (modelData.attention.title || modelData.attention.text || "")
                : ""
              color: Color.urgent
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }

            // Temperatures for a live printer, or when it was last seen.
            Text {
              width: parent.width
              elide: Text.ElideRight
              text: {
                if (!modelData.online)
                  return modelData.model + "  ·  last seen " + root.formatAgo(modelData.lastOnline)

                var bits = []
                if (modelData.temps) {
                  var nozzle = root.formatTemp(modelData.temps.nozzle)
                  if (modelData.temps.nozzleTarget > 0)
                    nozzle += "/" + root.formatTemp(modelData.temps.nozzleTarget)
                  var bed = root.formatTemp(modelData.temps.bed)
                  if (modelData.temps.bedTarget > 0)
                    bed += "/" + root.formatTemp(modelData.temps.bedTarget)
                  bits.push("N " + nozzle)
                  bits.push("B " + bed)
                }
                // Only worth naming tools when there is more than one.
                if (modelData.tools && modelData.tools.length > 1)
                  bits.push(modelData.tools.length + " tools")
                else if (modelData.material)
                  bits.push(modelData.material)
                return bits.join("   ")
              }
              color: Color.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }

            PanelSeparator { width: parent.width }
          }
        }

        Text {
          width: parent.width
          text: root.refreshing
            ? "Refreshing…"
            : (root.lastUpdatedAt > 0
               ? "Updated " + root.formatAgo(root.lastUpdatedAt / 1000) + "   ·   R to refresh"
               : "")
          color: Color.muted
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }
    }
  }
}

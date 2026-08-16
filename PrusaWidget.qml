pragma ComponentBehavior: Bound

import QtQuick
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

  // The printer awaiting confirmation of "Set ready", or null when no dialog
  // is open. Holds the whole row so the prompt can name it.
  property var readyCandidate: null
  property string commandError: ""

  // Notification bookkeeping, keyed by printer uuid: what each printer looked
  // like last poll, so only genuine transitions announce themselves.
  property var lastSeenById: ({})
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
  readonly property int watchIntervalMs: intSetting("watchIntervalSec", 60, 60, 3600) * 1000
  readonly property int printingIntervalMs: intSetting("printingIntervalSec", 5, 2, 120) * 1000
  readonly property bool notifyFinished: boolSetting("notifyFinished", true)
  readonly property bool notifyAttention: boolSetting("notifyAttention", true)
  readonly property bool notifyError: boolSetting("notifyError", true)
  readonly property int notifyCooldownMs: intSetting("notifyCooldownMin", 10, 1, 240) * 60000
  readonly property bool celsius: boolSetting("celsius", true)

  // Qt.resolvedUrl yields a file:// URL; Process wants a plain path.
  readonly property string backendPath:
    Qt.resolvedUrl("prusa-connect-fetch").toString().replace(/^file:\/\//, "")

  readonly property string printerGlyph: String.fromCodePoint(0xF042B)   // nf-md-printer_3d

  // --- formatting -------------------------------------------------------

  // Every row in the panel is a printer, so the icon's job is to carry state
  // rather than repeat "printer". Generic status shapes read faster at this size
  // than five near-identical printer silhouettes would. Swapping to the
  // printer-icon family is a matter of changing the codepoints here:
  // printing F18B8 nozzle_heat, finished F1146 printer_check,
  // attention F11C0 nozzle_alert, offline F0E5D printer_off, idle F042B.
  function stateGlyph(state) {
    switch (state) {
      case "PRINTING": return String.fromCodePoint(0xF040A)   // md-play
      case "PAUSED": return String.fromCodePoint(0xF03E4)     // md-pause
      case "FINISHED": return String.fromCodePoint(0xF05E0)   // md-check_circle
      case "ATTENTION": return String.fromCodePoint(0xF0026)  // md-alert
      case "ERROR": return String.fromCodePoint(0xF0028)      // md-alert_circle
      case "OFFLINE": return String.fromCodePoint(0xF0319)    // md-lan_disconnect
      case "STOPPED": return String.fromCodePoint(0xF0028)    // md-alert_circle
      default: return String.fromCodePoint(0xF042B)           // md-printer_3d
    }
  }

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

  // PRINTING covers heating, bed levelling and priming as well as extruding.
  // Saying "Preparing" is vague on purpose: Connect exposes no sub-phase, and
  // temperatures cannot tell heating from levelling, since levelling runs with
  // the nozzle at target. The one true claim is that nothing is printed yet.
  function labelForPrinter(printer) {
    if (printer.preparing) return "Preparing"
    return stateLabel(printer.state)
  }

  // A printer with an unanswered dialog reads as wanting a human even when its
  // state says FINISHED, so the icon and its colour follow needsAttention rather
  // than the state alone — the same rule as the bar badge and the notification.
  function glyphForPrinter(printer) {
    if (printer.needsAttention && printer.state !== "ERROR") return stateGlyph("ATTENTION")
    return stateGlyph(printer.state)
  }

  function colorForPrinter(printer) {
    if (printer.needsAttention) return Color.urgent
    return stateColor(printer.state)
  }

  // Secondary text. The `muted` theme token is not a text colour: a theme is
  // free to set it near the background, and this one does — #333333 on a
  // #121212 panel measured 1.18:1 on screen, against the 4.5:1 body text wants.
  // Dimming the readable popup foreground instead degrades gracefully in any
  // theme, which is what the first-party panels do.
  //
  // They dim to 0.6; this uses 0.75 because these lines are caption-sized, where
  // 0.6 measured 3.43:1 — fine for large text, short for small. 0.75 measures
  // 4.86:1 and still reads as clearly secondary next to the printer names.
  readonly property color detailColor:
    Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.75)

  function stateColor(state) {
    switch (state) {
      case "ERROR":
      case "ATTENTION": return Color.urgent
      case "PRINTING": return Color.accent
      case "OFFLINE": return detailColor
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

  // How often to poll. A running print is what people actually watch and its
  // progress moves continuously, so it wins over every other signal: a print is
  // polled at printingIntervalSec whether or not the panel is open. An idle
  // fleet does not change, so it is polled far more gently.
  //
  // Note the cost. At the 5 s default a print makes roughly 720 requests an
  // hour, and Prusa documents no rate limit. A 429 surfaces as an error in the
  // panel rather than silently; raising printingIntervalSec is the remedy.
  readonly property int pollIntervalMs: {
    if (fleet.printing > 0) return printingIntervalMs
    return opened ? refreshIntervalMs : watchIntervalMs
  }

  // Re-evaluated on a timer: a binding on Date.now() alone would never update,
  // because nothing notifies it that time has passed.
  property real nowMs: 0

  // A failed poll leaves the previous fleet in place, which is right for the
  // panel — stale rows plus "Updated 20 min ago" beat an empty box. The bar
  // summary is different: "61%" is a claim about right now with no room to
  // qualify it, and it went on asserting that long after the print had
  // finished. So once the data is older than three polls, say nothing rather
  // than something wrong. Three, so one missed poll does not blank the bar,
  // and never sooner than 30 s: at the 5 s printing cadence three polls is
  // only 15 s, and one slow response should not make the bar flicker.
  readonly property bool dataIsStale: {
    if (lastUpdatedAt <= 0) return true
    return (nowMs - lastUpdatedAt) > Math.max(pollIntervalMs * 3, 30000)
  }

  // BarIconButton is a fixed one-slot glyph holder — it pins its width to
  // slotSize and hides its label — so anything wider than a glyph paints over
  // the neighbouring widgets. Counts belong in the badge overlay below; this
  // stays short enough to sit inside the slot.
  readonly property string barSummary: {
    if (!showBarSummary || !initialized) return ""
    if (lastError !== "" || dataIsStale) return ""
    if (fleet.printing > 0) {
      var printing = printers.filter(function(p) { return p.state === "PRINTING" })
      // One printer running is the common case, so show its progress rather
      // than a count that says less.
      if (printing.length === 1 && !printing[0].preparing
          && printing[0].job && printing[0].job.progress !== null)
        return Math.round(printing[0].job.progress) + "%"
    }
    return ""
  }

  readonly property string tooltipSummary: {
    if (needsLogin) return "Prusa Connect: not signed in"
    if (dataIsStale && lastUpdatedAt > 0)
      return "Prusa Connect: last updated " + formatAgo(lastUpdatedAt / 1000)
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
      console.warn("prusa-connect: poll failed:", lastError)
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

  // Only a transition is worth announcing; a printer sitting in ATTENTION across
  // a dozen polls should notify once, not a dozen times. `previous` is undefined
  // on the first poll of a session, which deliberately announces nothing — the
  // widget starting up is not an event.
  function notificationFor(printer, previous) {
    if (previous === undefined) return null

    var stateChanged = printer.state !== previous.state

    if (stateChanged && printer.state === "ERROR" && notifyError)
      return { urgency: "critical", body: "Printer error" }

    // Attention keys on needsAttention, the same predicate the bar badge uses,
    // so an unanswered dialog notifies even when the state never changes. It is
    // checked before FINISHED: if a print completes and leaves a dialog on the
    // screen in the same poll, the dialog is the more actionable of the two.
    if (notifyAttention && printer.needsAttention && !previous.needsAttention) {
      var detail = printer.attention && printer.attention.title
        ? printer.attention.title : "Needs attention"
      return { urgency: "critical", body: detail }
    }

    if (stateChanged && printer.state === "FINISHED" && notifyFinished)
      return { urgency: "normal", body: "Print finished" }

    return null
  }

  function evaluateNotifications() {
    var seen = {}
    var stamps = notifiedAt
    var now = Date.now()

    for (var i = 0; i < printers.length; i++) {
      var printer = printers[i]
      if (!printer.uuid) continue
      seen[printer.uuid] = {
        state: printer.state,
        needsAttention: printer.needsAttention === true
      }

      var notification = notificationFor(printer, lastSeenById[printer.uuid])
      if (!notification) continue

      var last = stamps[printer.uuid] || 0
      if (now - last < notifyCooldownMs) continue
      stamps[printer.uuid] = now

      notify(printer.name, notification.body, notification.urgency)
    }

    lastSeenById = seen
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

  // --- commands ---------------------------------------------------------

  // Setting a printer ready is a claim about the physical machine, not just a
  // state change: it tells the fleet this printer can accept another job, and a
  // queued job could then print into whatever is still on the sheet. So it is
  // always confirmed, and the prompt asks about the sheet rather than about the
  // API call.
  function askSetReady(printer) {
    commandError = ""
    readyCandidate = printer
  }

  function sendSetReady() {
    if (!readyCandidate || !readyCandidate.uuid) return
    commandProcess.running = false
    commandProcess.command = [commandPath, "ready", String(readyCandidate.uuid)]
    commandProcess.running = true
    readyCandidate = null
  }

  readonly property string commandPath:
    Qt.resolvedUrl("prusa-connect-command").toString().replace(/^file:\/\//, "")

  Process {
    id: commandProcess
    running: false
    command: []

    stdout: StdioCollector { id: commandStdout; waitForEnd: true }

    onExited: function(exitCode) {
      var parsed = null
      try {
        parsed = JSON.parse(String(commandStdout.text || ""))
      } catch (error) {
        parsed = null
      }
      if (exitCode !== 0 || !parsed) {
        root.commandError = "The command helper failed"
      } else if (parsed.error) {
        root.commandError = String(parsed.error)
        console.warn("prusa-connect: command failed:", root.commandError)
      } else {
        root.commandError = ""
      }
      // Whatever happened, the fleet has probably moved on.
      root.refresh()
    }
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
    interval: root.pollIntervalMs
    running: root.opened || root.watchEnabled
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    // Drives dataIsStale. Cheap, and independent of the poll timer so that a
    // wedged poll cannot also freeze the staleness check that reveals it.
    interval: 10000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.nowMs = Date.now()
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
    text: root.barSummary !== "" ? root.barSummary : root.printerGlyph
    dimmed: root.needsLogin || root.lastError !== ""
    active: root.fleet.attention > 0 || root.lastError !== ""
    activeColor: Color.urgent
    tooltipText: root.tooltipSummary
    slotSize: Style.bar.statusSlot

    // Count of printers wanting a human, drawn in the slot corner so the bar
    // width never changes. Same idiom as the first-party widgets.
    Rectangle {
      id: attentionBadge
      visible: root.fleet.attention > 0 && root.lastError === "" && !root.dataIsStale
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.verticalCenter: parent.verticalCenter
      anchors.horizontalCenterOffset: button.opticalSize / 2 - Style.space(1)
      anchors.verticalCenterOffset: -(button.opticalSize / 2 - Style.space(2))
      height: badgeLabel.implicitHeight + Style.spaceReal(1)
      width: Math.max(height, badgeLabel.implicitWidth + Style.spaceReal(3))
      radius: height / 2
      color: Color.urgent
      border.width: 1
      border.color: Color.bar.background

      Text {
        id: badgeLabel
        anchors.centerIn: parent
        text: String(root.fleet.attention)
        color: Color.bar.background
        font.family: Style.font.family
        font.pixelSize: Math.max(7, Math.round(Style.font.caption * 0.78))
        font.bold: true
      }
    }

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

    // The prompt asks about the machine, not the request. Marking a printer
    // ready lets a queued job start, so the thing worth checking is whether the
    // sheet is actually clear — not whether the user meant to click.
    ConfirmDialog {
      anchors.fill: parent
      z: 10
      opened: root.readyCandidate !== null
      message: root.readyCandidate
        ? "Set " + root.readyCandidate.name + " ready?\n\n"
          + "Is the printer ready? Is the print sheet in place, empty and clean?"
        : ""
      confirmText: "Set ready"
      cancelText: "Cancel"
      background: Color.popups.background
      foreground: Color.popups.text
      fontFamily: Style.font.family

      onConfirmed: root.sendSetReady()
      onCanceled: root.readyCandidate = null
    }

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: {
        // Escape dismisses the prompt before it closes the panel.
        if (root.readyCandidate !== null) root.readyCandidate = null
        else root.close()
      }
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
            color: root.detailColor
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        Text {
          width: parent.width
          wrapMode: Text.WordWrap
          visible: root.commandError !== ""
          text: root.commandError
          color: Color.urgent
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
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
          color: root.detailColor
          font.family: Style.font.family
          font.pixelSize: Style.font.body
        }

        Text {
          width: parent.width
          visible: root.initialized && root.lastError === "" && root.visiblePrinters.length === 0
          text: root.printers.length === 0
            ? "No printers in this Prusa Connect account."
            : "All printers are idle or offline."
          color: root.detailColor
          font.family: Style.font.family
          font.pixelSize: Style.font.body
        }

        Repeater {
          model: root.visiblePrinters

          Column {
            id: printerEntry

            required property var modelData

            width: column.width
            spacing: Style.space(6)

            Row {
              width: parent.width
              spacing: Style.space(10)

              // Prusa's own illustration of this model. Bundled rather than
              // fetched; see assets/printers/NOTICE. An unrecognised model has
              // no file, so fall back to the generic printer rather than a gap.
              Image {
                id: printerArt
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(46)
                height: Style.space(46)
                sourceSize: Qt.size(width * 2, height * 2)
                fillMode: Image.PreserveAspectFit
                smooth: true
                asynchronous: true
                source: Qt.resolvedUrl("assets/printers/"
                  + (printerEntry.modelData.assetKey || "unknown") + ".svg")
                onStatusChanged: {
                  if (status === Image.Error)
                    source = Qt.resolvedUrl("assets/printers/unknown.svg")
                }
              }

              Column {
                width: parent.width - printerArt.width - Style.space(10)
                spacing: Style.space(2)

                Row {
                  width: parent.width
                  spacing: Style.space(8)

                  Text {
                    width: parent.width - stateText.implicitWidth - Style.space(8)
                    elide: Text.ElideRight
                    text: printerEntry.modelData.name
                    color: Color.popups.text
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                    font.bold: true
                  }

                  Text {
                    id: stateText
                    text: root.labelForPrinter(printerEntry.modelData)
                      + (!printerEntry.modelData.preparing
                         && printerEntry.modelData.job
                         && printerEntry.modelData.job.progress !== null
                         ? "  " + Math.round(printerEntry.modelData.job.progress) + "%" : "")
                    // Deliberately the state's own colour, not colorForPrinter: a
                    // finished print is not a problem just because a dialog is also
                    // waiting. The icon and the dialog line carry that urgency.
                    color: root.stateColor(printerEntry.modelData.state)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
              }
            }

            // Current job, when one is running. Filename and ETA are separate
            // items rather than one joined string: sliced names run to 40-odd
            // characters, and as a single elided Text the ETA — the half worth
            // reading — was the part that got cut.
            Row {
              width: parent.width
              spacing: Style.space(6)
              visible: printerEntry.modelData.job !== null && printerEntry.modelData.job !== undefined

              Text {
                width: Math.max(0, parent.width - etaText.implicitWidth
                  - (etaText.text === "" ? 0 : Style.space(6)))
                elide: Text.ElideRight
                text: printerEntry.modelData.job ? (printerEntry.modelData.job.name || "") : ""
                color: root.detailColor
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }

              Text {
                id: etaText
                text: {
                  if (!printerEntry.modelData.job) return ""
                  var remaining = root.formatDuration(printerEntry.modelData.job.remaining)
                  return remaining === "" ? "" : "ETA " + remaining
                }
                color: root.detailColor
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }

            // Why the printer wants attention, straight from Connect's dialog.
            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              visible: printerEntry.modelData.attention !== null && printerEntry.modelData.attention !== undefined
              text: printerEntry.modelData.attention
                ? (printerEntry.modelData.attention.title || printerEntry.modelData.attention.text || "")
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
                if (!printerEntry.modelData.online)
                  return printerEntry.modelData.model + "  ·  last seen " + root.formatAgo(printerEntry.modelData.lastOnline)

                var bits = []
                if (printerEntry.modelData.temps) {
                  var nozzle = root.formatTemp(printerEntry.modelData.temps.nozzle)
                  if (printerEntry.modelData.temps.nozzleTarget > 0)
                    nozzle += "/" + root.formatTemp(printerEntry.modelData.temps.nozzleTarget)
                  var bed = root.formatTemp(printerEntry.modelData.temps.bed)
                  if (printerEntry.modelData.temps.bedTarget > 0)
                    bed += "/" + root.formatTemp(printerEntry.modelData.temps.bedTarget)
                  bits.push("Nozzle " + nozzle)
                  bits.push("Heatbed " + bed)
                }
                // Only worth naming tools when there is more than one.
                if (printerEntry.modelData.tools && printerEntry.modelData.tools.length > 1)
                  bits.push(printerEntry.modelData.tools.length + " tools")
                else if (printerEntry.modelData.material)
                  bits.push(printerEntry.modelData.material)
                return bits.join("   ")
              }
              color: root.detailColor
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }

            // Connect's own "Set ready!", offered only where it applies: a
            // finished job, a reachable printer, and write rights on it.
            Button {
              visible: printerEntry.modelData.state === "FINISHED"
                && printerEntry.modelData.online
                && printerEntry.modelData.canControl === true
              text: "Set ready"
              bordered: true
              fontSize: Style.font.caption
              onClicked: root.askSetReady(printerEntry.modelData)
            }
              }
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
          color: root.detailColor
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }
    }
  }
}

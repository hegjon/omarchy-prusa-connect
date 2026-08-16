pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons
import qs.Ui

// One printer in the fleet list: artwork, name and state, current job, why it
// wants attention, temperatures, and the Set ready button where it applies.
//
// `host` is the widget root, which owns the formatting helpers and the theme
// colours; the row itself keeps no state beyond what it is given.
Column {
  id: row

  required property var printer
  required property var host

  // True while a command for this printer is in flight; see the button below.
  property bool busy: false

  signal setReadyRequested()

  spacing: Style.space(6)

  Row {
    width: parent.width
    spacing: Style.space(10)

    // Prusa's own illustration of this model. Bundled rather than fetched; see
    // assets/printers/NOTICE. An unrecognised model has no file, so fall back
    // to the generic printer rather than a gap.
    Image {
      id: printerArt
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(46)
      height: Style.space(46)
      sourceSize: Qt.size(width * 2, height * 2)
      fillMode: Image.PreserveAspectFit
      smooth: true
      asynchronous: true
      source: Qt.resolvedUrl("../assets/printers/"
        + (row.printer.assetKey || "unknown") + ".svg")
      onStatusChanged: {
        if (status === Image.Error)
          source = Qt.resolvedUrl("../assets/printers/unknown.svg")
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
          text: row.printer.name
          color: Color.popups.text
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          font.bold: true
        }

        Text {
          id: stateText
          text: row.host.labelForPrinter(row.printer)
            + (!row.printer.preparing
               && row.printer.job
               && row.printer.job.progress !== null
               ? "  " + Math.round(row.printer.job.progress) + "%" : "")
          // Deliberately the state's own colour, not colorForPrinter: a
          // finished print is not a problem just because a dialog is also
          // waiting. The icon and the dialog line carry that urgency.
          color: row.host.stateColor(row.printer.state)
          font.family: Style.font.family
          font.pixelSize: Style.font.body
        }
      }

      // Current job, when one is running. Filename and ETA are separate items
      // rather than one joined string: sliced names run to 40-odd characters,
      // and as a single elided Text the ETA — the half worth reading — was the
      // part that got cut.
      Row {
        width: parent.width
        spacing: Style.space(6)
        visible: row.printer.job !== null && row.printer.job !== undefined

        Text {
          width: Math.max(0, parent.width - etaText.implicitWidth
            - (etaText.text === "" ? 0 : Style.space(6)))
          elide: Text.ElideRight
          text: row.printer.job ? (row.printer.job.name || "") : ""
          color: row.host.detailColor
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }

        Text {
          id: etaText
          text: {
            if (!row.printer.job) return ""
            var remaining = row.host.formatDuration(row.printer.job.remaining)
            return remaining === "" ? "" : "ETA " + remaining
          }
          color: row.host.detailColor
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }

      // Why the printer wants attention, straight from Connect's dialog.
      Text {
        width: parent.width
        elide: Text.ElideRight
        visible: row.printer.attention !== null && row.printer.attention !== undefined
        text: row.printer.attention ? row.host.attentionSummary(row.printer) : ""
        color: Color.urgent
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }

      // Temperatures for a live printer, or when it was last seen.
      Text {
        width: parent.width
        elide: Text.ElideRight
        text: {
          if (!row.printer.online)
            return row.printer.model + "  ·  last seen " + row.host.formatAgo(row.printer.lastOnline)

          var bits = []
          if (row.printer.temps) {
            var nozzle = row.host.formatTemp(row.printer.temps.nozzle)
            if (row.printer.temps.nozzleTarget > 0)
              nozzle += "/" + row.host.formatTemp(row.printer.temps.nozzleTarget)
            var bed = row.host.formatTemp(row.printer.temps.bed)
            if (row.printer.temps.bedTarget > 0)
              bed += "/" + row.host.formatTemp(row.printer.temps.bedTarget)
            bits.push("Nozzle " + nozzle)
            bits.push("Heatbed " + bed)
          }
          // Only worth naming tools when there is more than one.
          if (row.printer.tools && row.printer.tools.length > 1)
            bits.push(row.printer.tools.length + " tools")
          else if (row.printer.material)
            bits.push(row.printer.material)
          return bits.join("   ")
        }
        color: row.host.detailColor
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }

      // Connect's own "Set ready!", offered only where it applies: a finished
      // job, a reachable printer, and write rights on it.
      Button {
        id: setReadyButton

        visible: row.printer.state === "FINISHED"
          && row.printer.online
          && row.printer.canControl === true
        // Stays visible while the command is in flight rather than vanishing:
        // the row still says Finished until Connect catches up, and a button
        // that disappears looks like a failure.
        enabled: !row.busy
        text: row.busy ? "Setting ready…" : "Set ready"
        bordered: true
        fontSize: Style.font.caption
        onClicked: row.setReadyRequested()

        opacity: row.busy ? 0.5 : 1.0
        Behavior on opacity { NumberAnimation { duration: 150 } }

        // A slow pulse while waiting, so the wait reads as progress rather
        // than a stuck control.
        SequentialAnimation on scale {
          running: row.busy
          loops: Animation.Infinite
          alwaysRunToEnd: true
          NumberAnimation { to: 0.97; duration: 600; easing.type: Easing.InOutQuad }
          NumberAnimation { to: 1.0; duration: 600; easing.type: Easing.InOutQuad }
        }
      }
    }
  }

  PanelSeparator { width: parent.width }
}

pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons
import qs.Ui

// The confirmation shown over the fleet list before a printer is set ready.
//
// The prompt asks about the machine, not the request. Marking a printer ready
// lets a queued job start, so the thing worth checking is whether the sheet is
// actually clear — not whether the user meant to click.
//
// A checklist rather than one question. Each point is a separate thing to look
// at, and a single "yes" invites skimming all three. Confirm stays disabled
// until every box is ticked, so the list has to be answered rather than
// acknowledged. The checklist lives here and resets whenever a new printer is
// offered, so a previous answer can never carry over to another printer.
Item {
  id: dialog

  // The printer awaiting confirmation, or null when no prompt is open.
  required property var printer
  required property color detailColor

  signal confirmed()
  signal cancelled()

  // The card's content height, for a host that has to grow to contain it.
  readonly property real cardContentHeight: dialogColumn.implicitHeight

  property bool sheetInPlace: false
  property bool sheetEmpty: false
  property bool sheetClean: false
  readonly property bool checklistComplete: sheetInPlace && sheetEmpty && sheetClean

  visible: printer !== null && printer !== undefined

  onPrinterChanged: {
    sheetInPlace = false
    sheetEmpty = false
    sheetClean = false
  }

  function confirm() {
    // Belt and braces: the button is disabled without this, but nothing should
    // be able to confirm with the checklist unanswered.
    if (!checklistComplete) return
    confirmed()
  }

  // Swallow clicks so the panel behind cannot be operated while the prompt is
  // up, and so a stray click outside the card does nothing.
  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    onClicked: {}
  }

  Rectangle {
    anchors.fill: parent
    color: Qt.rgba(Color.popups.background.r, Color.popups.background.g,
                   Color.popups.background.b, 0.85)
  }

  Rectangle {
    anchors.centerIn: parent
    width: Math.min(parent.width - Style.space(16), Style.space(340))
    height: dialogColumn.implicitHeight + Style.space(28)
    color: Color.popups.background
    radius: Style.cornerRadius
    border.width: Math.max(1, Style.space(2))
    border.color: Color.popups.border

    Column {
      id: dialogColumn
      anchors.centerIn: parent
      width: parent.width - Style.space(28)
      spacing: Style.space(8)

      Text {
        width: parent.width
        wrapMode: Text.WordWrap
        text: dialog.printer ? "Set " + dialog.printer.name + " ready?" : ""
        color: Color.popups.text
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        font.bold: true
      }

      Text {
        width: parent.width
        wrapMode: Text.WordWrap
        text: "A ready printer can be given the next job, so anything left "
          + "on the sheet would be printed onto."
        color: dialog.detailColor
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }

      Toggle {
        width: parent.width
        label: "Is the print sheet in place?"
        checked: dialog.sheetInPlace
        onClicked: dialog.sheetInPlace = !dialog.sheetInPlace
      }

      Toggle {
        width: parent.width
        label: "Is the print sheet empty?"
        checked: dialog.sheetEmpty
        onClicked: dialog.sheetEmpty = !dialog.sheetEmpty
      }

      Toggle {
        width: parent.width
        label: "Is the print sheet clean?"
        checked: dialog.sheetClean
        onClicked: dialog.sheetClean = !dialog.sheetClean
      }

      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: Style.space(8)

        Button {
          text: "Cancel"
          bordered: true
          onClicked: dialog.cancelled()
        }

        Button {
          text: "Set ready"
          bordered: true
          enabled: dialog.checklistComplete
          opacity: enabled ? 1.0 : 0.4
          accent: Color.urgent
          onClicked: dialog.confirm()
        }
      }
    }
  }
}

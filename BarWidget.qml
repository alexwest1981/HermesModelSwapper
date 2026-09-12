import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

/**
 * Hermes-modell i toppbaren.
 *
 * Visar Hermes nuvarande standardmodell. Klick öppnar en dropdown med det
 * Hermes faktiskt har tillgång till — katalogen byggs av Hermes eget inventory
 * (providers med giltiga credentials) plus aliasen i config.yaml.
 *
 * Ett val kör Hermes EGEN switch-pipeline (model_switch.switch_model) och
 * persisteras med samma fyra nycklar som `/model … --global` skriver. Skydden
 * för dyr modell/datapolicy körs först: svarar de confirm_required visas
 * bekräftelsen i popupen i stället för att bytet sker tyst.
 *
 * Bytet gäller standardmodellen, dvs nya Hermes-sessioner. En redan pågående
 * session behåller sin modell; det står också i popupens fotnot.
 */
BarWidget {
  id: root
  moduleName: "custom.hermes-model"

  readonly property string helperPath: Quickshell.env("HOME") + "/.config/omarchy/plugins/custom.hermes-model/hermes_models.py"
  readonly property int refreshInterval: 20000
  // Nerd Font-robotens kodpunkt sätts via fromCodePoint så att filen inte
  // innehåller multi-byte-glyfer som kan striptas av redigeringsverktyg.
  readonly property string glyph: String.fromCodePoint(0xF06A9)

  property bool popupOpen: false
  property bool loading: true
  property bool switching: false
  property bool refreshing: false
  property string errorText: ""
  property var current: ({ "model": "", "provider": "", "base_url": "" })
  property var groups: []
  property string source: ""
  property var catalogAge: null
  // Väntande byte som Hermes vill ha bekräftat (dyr modell/datapolicy).
  property var pendingItem: null
  property string pendingMessage: ""

  function close() { popupOpen = false }

  implicitWidth: barRow.implicitWidth + Style.space(14)
  implicitHeight: barSize

  function sourceLabel() {
    if (root.source === "hermes-api") {
      var age = root.catalogAge
      if (age === null || age === undefined) return "Hermes-katalog"
      if (age < 90) return "Hermes-katalog · färsk"
      if (age < 3600) return "Hermes-katalog · " + Math.round(age / 60) + " min"
      return "Hermes-katalog · " + Math.round(age / 3600) + " h"
    }
    return "config.yaml (Hermes-API:t otillgängligt)"
  }

  function barColor() {
    return root.bar ? root.bar.foreground : Color.foreground
  }

  function dimColor(factor) {
    return Qt.darker(root.barColor(), factor)
  }

  function refreshCatalog() {
    if (listProc.running) return
    root.refreshing = true
    listProc.command = ["python3", root.helperPath, "list", "--refresh"]
    listProc.running = true
  }

  function refreshCheap() {
    if (listProc.running) return
    listProc.command = ["python3", root.helperPath, "list"]
    listProc.running = true
  }

  function applyItem(item, confirm) {
    if (!item || root.switching) return
    root.switching = true
    root.errorText = ""
    if (!confirm) {
      root.pendingItem = null
      root.pendingMessage = ""
    }
    var cmd = ["python3", root.helperPath, "set", item.model || "", item.provider || ""]
    if (confirm) cmd.push("--confirm")
    switchProc.command = cmd
    switchProc.running = true
  }

  // ---------------------------------------------------------------------------
  // 1. Läsning
  // ---------------------------------------------------------------------------
  Process {
    id: listProc
    command: ["python3", root.helperPath, "list"]

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.loading = false
        root.refreshing = false
        var raw = text.trim()
        if (raw.length === 0) {
          root.errorText = "tomt svar från hermes_models.py"
          return
        }
        try {
          var data = JSON.parse(raw)
          if (data && data.ok) {
            root.current = data.current || root.current
            root.groups = data.groups || []
            root.source = data.source || ""
            root.catalogAge = (data.catalog_age_s === undefined || data.catalog_age_s === null)
                             ? null : data.catalog_age_s
            root.errorText = ""
          } else {
            root.errorText = (data && data.error) ? data.error : "okänt fel"
          }
        } catch (e) {
          root.errorText = "kunde inte tolka svaret från hermes_models.py"
        }
      }
    }
  }

  // ---------------------------------------------------------------------------
  // 2. Bytet (Hermes egen pipeline)
  // ---------------------------------------------------------------------------
  Process {
    id: switchProc

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.switching = false
        var data = null
        try {
          data = JSON.parse(text.trim())
        } catch (e) {
          data = null
        }
        if (data && data.ok) {
          root.pendingItem = null
          root.pendingMessage = ""
          root.popupOpen = false
          root.errorText = ""
        } else if (data && data.confirm_required) {
          // Inget är ändrat: Hermes vill ha ett uttryckligt ja.
          root.pendingMessage = data.confirm_message || "Hermes vill ha en bekräftelse"
          root.errorText = ""
        } else {
          root.errorText = (data && data.error) ? data.error : "bytet misslyckades"
          root.pendingItem = null
          root.pendingMessage = ""
        }
        root.refreshCheap()
      }
    }
  }

  Timer {
    interval: root.refreshInterval
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: if (!root.popupOpen) root.refreshCheap()
  }

  // ---------------------------------------------------------------------------
  // 3. Baren: ikon + modellnamn
  // ---------------------------------------------------------------------------
  Row {
    id: barRow
    anchors.centerIn: parent
    spacing: Style.space(5)

    Text {
      anchors.verticalCenter: parent.verticalCenter
      color: root.switching ? Color.accent : root.barColor()
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.title
      text: root.glyph

      SequentialAnimation on opacity {
        running: root.switching
        loops: Animation.Infinite
        NumberAnimation { to: 0.35; duration: 380 }
        NumberAnimation { to: 1.0; duration: 380 }
      }
    }

    Text {
      anchors.verticalCenter: parent.verticalCenter
      color: root.barColor()
      font.bold: true
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.bodySmall
      text: root.current.model.length > 0 ? root.current.model : "hermes"
    }
  }

  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    cursorShape: Qt.PointingHandCursor
    hoverEnabled: true

    onEntered: {
      if (root.bar) {
        var line = "Hermes: " + (root.current.model || "?")
        if (root.current.provider) line += " · " + root.current.provider
        if (root.errorText) line += " — " + root.errorText
        else line += "  ·  klick: välj modell"
        root.bar.showTooltip(root, line)
      }
    }
    onExited: if (root.bar) root.bar.hideTooltip(root)

    onClicked: function(mouse) {
      if (mouse.button === Qt.RightButton) {
        root.refreshCatalog()
        return
      }
      root.popupOpen = !root.popupOpen
      if (root.popupOpen) root.refreshCheap()
    }
  }

  // ---------------------------------------------------------------------------
  // 4. Dropdown
  // ---------------------------------------------------------------------------
  PopupCard {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    contentWidth: popup.fittedContentWidth(Style.space(430))
    contentHeight: popup.fittedContentHeight(popCol.implicitHeight)

    Column {
      id: popCol
      anchors.fill: parent
      spacing: Style.space(10)

      // Rubrik
      Row {
        spacing: Style.space(8)
        width: parent.width

        Text {
          anchors.verticalCenter: parent.verticalCenter
          color: Color.accent
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.title
          text: root.glyph
        }

        Column {
          width: parent.width - Style.space(150)
          spacing: Style.space(2)

          Text {
            color: root.barColor()
            font.bold: true
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.subtitle
            text: "Hermes-modell"
          }

          Text {
            color: root.dimColor(1.3)
            elide: Text.ElideRight
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
            text: root.switching
                  ? "Kör Hermes switch …"
                  : ("Aktiv nu: " + (root.current.model || "?")
                     + (root.current.provider ? "  ·  " + root.current.provider : "")
                     + "   —   " + root.sourceLabel())
            width: parent.width
          }
        }

        Row {
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(6)

          WidgetButton {
            bar: root.bar
            fixedHeight: Style.space(30)
            text: "󰑐"
            tooltipText: "Läs om katalogen från Hermes nu"
            onPressed: function() { root.refreshCatalog() }
          }
        }
      }

      // Bekräftelse (dyr modell / datapolicy)
      BorderSurface {
        width: parent.width
        height: confirmCol.implicitHeight + Style.space(16)
        radius: Style.spacing.labelGap
        borderSpec: Border.controlSpec("normal", root.barColor(), Color.accent)
        color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.10)
        visible: root.pendingMessage.length > 0

        Column {
          id: confirmCol
          anchors.left: parent.left
          anchors.leftMargin: Style.space(8)
          anchors.right: parent.right
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(6)

          Text {
            color: root.barColor()
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
            text: root.pendingMessage
            wrapMode: Text.WordWrap
            width: parent.width
          }

          WidgetButton {
            bar: root.bar
            fixedHeight: Style.space(26)
            text: "Bekräfta och byt"
            tooltipText: "Kör bytet med Hermes bekräftelse"
            onPressed: function() {
              if (root.pendingItem) root.applyItem(root.pendingItem, true)
            }
          }
        }
      }

      // Fel
      BorderSurface {
        width: parent.width
        height: Style.space(38)
        radius: Style.spacing.labelGap
        borderSpec: Border.controlSpec("normal", root.barColor(), "#f87171")
        color: Qt.rgba(0.97, 0.44, 0.44, 0.10)
        visible: root.errorText.length > 0

        Text {
          anchors.centerIn: parent
          color: "#f87171"
          elide: Text.ElideRight
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
          text: root.errorText
          width: parent.width - Style.space(16)
        }
      }

      // Laddar
      Text {
        color: root.dimColor(1.4)
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.bodySmall
        text: root.refreshing ? "Hämtar Hermes katalog …" : "Läser Hermes-konfigurationen …"
        visible: (root.loading || root.refreshing) && root.groups.length === 0
      }

      // Modellistan
      Flickable {
        width: parent.width
        height: Math.min(Style.space(420), listCol.implicitHeight)
        contentHeight: listCol.implicitHeight
        contentWidth: width
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        visible: root.groups.length > 0

        Column {
          id: listCol
          width: parent.width
          spacing: Style.space(10)

          Repeater {
            model: root.groups

            delegate: Column {
              id: groupCol
              required property var modelData

              readonly property var groupEntry: modelData

              width: listCol.width
              spacing: Style.space(4)

              Text {
                color: root.dimColor(1.4)
                font.bold: true
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.caption
                text: groupCol.groupEntry.title.toUpperCase()
              }

              Repeater {
                model: groupCol.groupEntry.items

                delegate: BorderSurface {
                  id: itemRow
                  required property var modelData

                  readonly property var item: modelData

                  width: groupCol.width
                  height: Style.space(46)
                  radius: Style.spacing.labelGap
                  color: itemRow.item.is_current
                         ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.10)
                         : (rowHover.hovered
                            ? Qt.rgba(root.barColor().r, root.barColor().g, root.barColor().b, 0.08)
                            : Qt.rgba(root.barColor().r, root.barColor().g, root.barColor().b, 0.03))
                  borderSpec: Border.controlSpec("normal", root.barColor(), itemRow.item.is_current ? Color.accent : Qt.rgba(root.barColor().r, root.barColor().g, root.barColor().b, 0.12))

                  Row {
                    anchors.fill: parent
                    anchors.leftMargin: Style.space(10)
                    anchors.rightMargin: Style.space(10)
                    spacing: Style.space(8)

                    Column {
                      anchors.verticalCenter: parent.verticalCenter
                      spacing: Style.space(1)
                      width: parent.width - Style.space(60)

                      Text {
                        color: itemRow.item.available === false ? root.dimColor(1.6) : root.barColor()
                        elide: Text.ElideRight
                        font.bold: true
                        font.family: root.bar ? root.bar.fontFamily : Style.font.family
                        font.pixelSize: Style.font.bodySmall
                        text: itemRow.item.label
                        width: parent.width
                      }

                      Text {
                        color: (itemRow.item.available === false || itemRow.item.is_current)
                               ? (itemRow.item.available === false ? "#f0b46a" : root.dimColor(1.35))
                               : root.dimColor(1.35)
                        elide: Text.ElideRight
                        font.family: root.bar ? root.bar.fontFamily : Style.font.family
                        font.pixelSize: Style.font.caption
                        text: itemRow.item.is_current
                              ? "används nu"
                              : (itemRow.item.note || itemRow.item.provider || "")
                        width: parent.width
                      }
                    }

                    Rectangle {
                      anchors.verticalCenter: parent.verticalCenter
                      color: Color.accent
                      height: Style.space(16)
                      radius: Style.space(4)
                      visible: itemRow.item.is_current
                      width: Style.space(52)

                      Text {
                        anchors.centerIn: parent
                        color: "#000000"
                        font.bold: true
                        font.family: root.bar ? root.bar.fontFamily : Style.font.family
                        font.pixelSize: Style.font.caption
                        text: "AKTIV"
                      }
                    }
                  }

                  MouseArea {
                    id: rowHover
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    enabled: !root.switching
                    hoverEnabled: true
                    onClicked: {
                      root.pendingItem = itemRow.item
                      root.applyItem(itemRow.item, false)
                    }
                  }
                }
              }
            }
          }
        }
      }

      // Fotnot
      Text {
        color: root.dimColor(1.4)
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.caption
        text: "Bytet kör Hermes egen switch och sätter standardmodellen i config.yaml — nya sessioner. Kör en pågående chatt vidare på sin modell."
        width: parent.width
        wrapMode: Text.WordWrap
      }
    }
  }
}

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

/**
 * Hermes-modell i toppbaren.
 *
 * Visar Hermes nuvarande standardmodell. Klick öppnar en dropdown med allt
 * Hermes har sparat: model_aliases, model.aliases och de provider-kataloger
 * Hermes själv har cachat. Ett val skriver model.default/model.provider (och
 * base_url när målet har en egen endpoint) via `hermes config set` — alltså
 * samma nycklar som `hermes` egen `/model … --global` sätter.
 *
 * Bytet gäller standardmodellen, dvs nya Hermes-sessioner. En redan pågående
 * session behåller sin modell; det står också i popupens fotnot.
 */
BarWidget {
  id: root
  moduleName: "custom.hermes-model"

  readonly property string helperPath: Quickshell.env("HOME") + "/.config/omarchy/plugins/custom.hermes-model/hermes_models.py"
  readonly property int refreshInterval: 15000
  // Nerd Font-robotens kodpunkt sätts via fromCodePoint så att filen inte
  // innehåller multi-byte-glyfer som kan striptas av redigeringsverktyg.
  readonly property string glyph: String.fromCodePoint(0xF06A9)

  property bool popupOpen: false
  property bool loading: true
  property bool switching: false
  property string errorText: ""
  property var current: ({ "model": "", "provider": "", "base_url": "" })
  property var groups: []

  function close() { popupOpen = false }

  implicitWidth: barRow.implicitWidth + Style.space(14)
  implicitHeight: barSize

  function refresh() {
    if (!listProc.running) listProc.running = true
  }

  function applyItem(item) {
    if (!item || root.switching) return
    root.switching = true
    root.errorText = ""
    switchProc.command = [
      "python3", root.helperPath, "set",
      item.model || "", item.provider || "", item.base_url || ""
    ]
    switchProc.running = true
  }

  function barColor() {
    return root.bar ? root.bar.foreground : Color.foreground
  }

  function dimColor(factor) {
    return Qt.darker(root.barColor(), factor)
  }

  // ---------------------------------------------------------------------------
  // 1. Läsning (ingen nätverksåtkomst: config.yaml + Hermes modellcache)
  // ---------------------------------------------------------------------------
  Process {
    id: listProc
    command: ["python3", root.helperPath, "list"]

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.loading = false
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
  // 2. Bytet
  // ---------------------------------------------------------------------------
  Process {
    id: switchProc

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.switching = false
        var raw = text.trim()
        var data = null
        try {
          data = JSON.parse(raw)
        } catch (e) {
          data = null
        }
        if (data && data.ok) {
          root.popupOpen = false
          root.errorText = ""
        } else {
          root.errorText = (data && data.error) ? data.error : "bytet misslyckades"
        }
        root.refresh()
      }
    }
  }

  Timer {
    interval: root.refreshInterval
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // ---------------------------------------------------------------------------
  // 3. Baren: ikon + modellnamn
  // ---------------------------------------------------------------------------
  Row {
    id: barRow
    anchors.centerIn: parent
    spacing: Style.space(5)

    Text {
      id: barGlyph
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
        root.refresh()
        return
      }
      root.popupOpen = !root.popupOpen
      if (root.popupOpen) root.refresh()
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
    contentWidth: popup.fittedContentWidth(Style.space(400))
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
          width: parent.width - Style.space(130)
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
                  ? "Byter …"
                  : ("Aktiv nu: " + (root.current.model || "?")
                     + (root.current.provider ? "  ·  " + root.current.provider : ""))
            width: parent.width
          }
        }

        WidgetButton {
          anchors.verticalCenter: parent.verticalCenter
          bar: root.bar
          fixedHeight: Style.space(30)
          text: "󰑐"
          tooltipText: "Läs om modellistan nu"
          onPressed: function() { root.refresh() }
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
        text: "Läser Hermes-konfigurationen …"
        visible: root.loading && root.groups.length === 0
      }

      // Ingen träff
      Text {
        color: root.dimColor(1.4)
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.bodySmall
        text: "Inga sparade modeller hittades i config.yaml eller Hermes modellcache."
        visible: !root.loading && root.groups.length === 0
        width: parent.width
        wrapMode: Text.WordWrap
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
                        color: root.barColor()
                        elide: Text.ElideRight
                        font.bold: true
                        font.family: root.bar ? root.bar.fontFamily : Style.font.family
                        font.pixelSize: Style.font.bodySmall
                        text: itemRow.item.label
                        width: parent.width
                      }

                      Text {
                        color: root.dimColor(1.35)
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
                    onClicked: root.applyItem(itemRow.item)
                  }
                }
              }
            }
          }
        }
      }

      // Fotnot: vad bytet betyder
      Text {
        color: root.dimColor(1.4)
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.caption
        text: "Sätter Hermes standardmodell (config.yaml) — nya sessioner. Källor: model_aliases, model.aliases, provider_models_cache."
        width: parent.width
        wrapMode: Text.WordWrap
      }
    }
  }
}

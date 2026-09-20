import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "artemisa81.gtasks"

  readonly property var counts: panelLoader.item ? panelLoader.item.counts : ({ open: 0, total: 0 })
  readonly property bool needsAuth: panelLoader.item ? panelLoader.item.authNeeded || !panelLoader.item.hasAccount : false
  readonly property string glyph: "\uf0ae"

  readonly property string displayText: {
    if (root.vertical) return ""
    if (needsAuth) return glyph
    if (counts.total === 0) return glyph
    return glyph + " " + counts.open + "/" + counts.total
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function refreshAll() {
    if (panelLoader.item && panelLoader.item.refreshAll) panelLoader.item.refreshAll()
  }

  // Shape contract for shell.summon/hide/toggle routing.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }

  function togglePanel() {
    if (panelLoader.item) panelLoader.item.toggle()
  }

  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  IpcHandler {
    target: "artemisa81.gtasks"

    function toggle(): void { root.togglePanel() }
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function refresh(): void { root.refreshAll() }
    function state(): void {
      var p = panelLoader.item
      if (p && typeof p.debugDump === "function") p.debugDump()
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.displayText
    labelVisible: !root.vertical
    hasVisualContent: root.vertical || text !== ""
    tooltipText: "Google Tasks"
    fixedHeight: root.vertical ? Style.bar.iconSlot : -1
    horizontalMargin: 8.75
    verticalPadding: 8.75

    onPressed: function(b) {
      if (b === Qt.RightButton) root.refreshAll()
      else root.togglePanel()
    }

    Text {
      visible: root.vertical
      anchors.centerIn: parent
      text: root.glyph
      color: button.foreground
      font.family: Style.font.family
      font.pixelSize: Style.bar.iconFont
    }
  }
}

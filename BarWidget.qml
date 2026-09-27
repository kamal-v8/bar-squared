import QtQuick
import qs.Commons
import qs.Ui

// Bar² Control — lives in the main bar, operates the Bar² second bar.
// Shows a single ◧ glyph, slightly big. Click opens the control panel.
BarWidget {
  id: root
  moduleName: "io.github.kamal-v8.bar-squared"

  // Service-owned open state: this widget (and its panelLoader) is rebuilt
  // on every structural shell.json edit, which would reset
  // PanelController.open and close the panel on every move/resize. The
  // service outlives bar rebuilds, so live state is mirrored there and a
  // fresh Loader item restores it (see restoreIfNeeded). Fresh lookup every
  // call: the service may register after this widget loads, so no cached
  // binding (which would stick at null).
  function panelService() {
    try {
      if (root.bar && root.bar.shell && typeof root.bar.shell.serviceFor === "function")
        return root.bar.shell.serviceFor(root.moduleName)
    } catch (e) {}
    return null
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  function togglePanel() {
    var svc = root.panelService()
    var target = panelLoader.item
    if (target && typeof target.toggle === "function") {
      var willOpen = !(target.opened === true)
      if (svc) svc.panelOpen = willOpen
      target.toggle()
    } else if (svc) {
      // Rebuild gap (no live panel): flip service state; onLoaded restores.
      svc.panelOpen = !(svc.panelOpen === true)
    }
  }

  // Shape contract for shell.summon/hide/toggle routing
  // (Bar.findPanelWidget requires open/close/opened on the bar-widget root).
  // `opened` stays bound to the live panel so isPluginOpen() reports the
  // truth; service.panelOpen is the restore source across rebuilds.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    var svc = root.panelService()
    if (svc) svc.panelOpen = true
    var target = panelLoader.item
    if (target && typeof target.open === "function") {
      target.open()
    } else {
      // Rebuild gap: service already true; retry once the Loader resolves.
      Qt.callLater(root.restoreIfNeeded)
    }
  }

  function close() {
    var svc = root.panelService()
    if (svc) svc.panelOpen = false
    var target = panelLoader.item
    if (target && typeof target.close === "function") target.close()
  }

  // Live panel -> service mirror. Skips the destruction gap (item null):
  // when this widget is rebuilt `opened` falls back to false, which must
  // NOT clear the service state or restore would never fire.
  onOpenedChanged: {
    if (!panelLoader.item) return
    var svc = root.panelService()
    if (!svc) return
    var live = panelLoader.item.opened === true
    if ((svc.panelOpen === true) !== live) svc.panelOpen = live
  }

  // Reopen guard: a fresh Loader item starts closed even though the service
  // says open (user never closed; the widget was rebuilt). Reopen via
  // callLater so injectPanel() has already run (anchor/bar for positioning).
  // Genuine closes set service false first, so this is a no-op for them.
  function restoreIfNeeded() {
    var svc = root.panelService()
    if (!svc || !(svc.panelOpen === true)) return
    var target = panelLoader.item
    if (!target || (target.opened === true)) return
    if (typeof target.open !== "function") return
    root.injectPanel()
    Qt.callLater(function() {
      var s2 = root.panelService()
      var t2 = panelLoader.item
      if (!s2 || !(s2.panelOpen === true)) return
      if (!t2 || (t2.opened === true)) return
      if (typeof t2.open === "function") t2.open()
    })
  }

  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: {
    injectPanel()
    restoreIfNeeded()
  }
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("ControlPanel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
      root.restoreIfNeeded()
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "◧"
    fontSize: 18
    horizontalMargin: 10
    tooltipText: "Bar² control — click to open"

    onPressed: function(b) {
      if (b === Qt.RightButton) {
        if (root.bar) root.bar.run("omarchy-shell io.github.kamal-v8.bar-squared toggleMode")
      } else {
        root.togglePanel()
      }
    }
  }
}

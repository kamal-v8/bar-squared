import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Control popup for Bar². Owned by BarWidget.qml (the ◧ button in the main
// bar); the bar tracks the widget, not this panel, so popout identity and
// panel switching go through hostWidget.
//
// Layout: top header, then drawer | Main list | Second list,
// then footer. Columns are plain ColumnLayouts (no card wrappers) so the
// RowLayout can never collapse or overlap them; dividers are 1px Rectangles.
Panel {
  id: root
  moduleName: "io.github.kamal-v8.bar-squared"
  ipcTarget: "io.github.kamal-v8.bar-squared"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // Service-owned open state (see Service.qml panelOpen + BarWidget
  // restoreIfNeeded): this panel is destroyed whenever the bar rebuilds its
  // widget Loader on a shell.json edit. Mirror every genuine open/close here
  // too, so a close that lands while BarWidget is mid-rebuild (outside-click,
  // Esc, ✕) still clears the service flag and doesn't get wrongly reopened.
  // Fresh lookup every time; bar is null until BarWidget.injectPanel() runs.
  function panelService() {
    try {
      if (root.bar && root.bar.shell && typeof root.bar.shell.serviceFor === "function")
        return root.bar.shell.serviceFor("io.github.kamal-v8.bar-squared")
    } catch (e) {}
    return null
  }
  onOpenedChanged: {
    var svc = root.panelService()
    if (!svc) return
    var live = root.opened === true
    if ((svc.panelOpen === true) !== live) svc.panelOpen = live
  }

  // Settings drawer visibility (gear in the header shows it manually,
  // drawer's ✕ hides it again). Hidden by default so the panel opens
  // compact; the ⚙ + ✕ buttons stay on the header's right side always.
  property bool showBarSettings: false
  property string mainFilter: ""
  property string dupFilter: ""

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  // --- Config reading (same source as Service) ---
  property var fileConfig: ({})
  FileView {
    id: cfgFile
    path: Quickshell.env("HOME") + "/.config/omarchy/shell.json"
    watchChanges: true
    printErrors: false
    onLoaded: {
      try { root.fileConfig = JSON.parse(text() || "{}") } catch(e) { root.fileConfig = {} }
    }
    onLoadFailed: { root.fileConfig = {} }
    onFileChanged: reload()
  }

  // Single-entry (omasot pattern): config lives in the bar.layout entry.
  // Legacy plugins[] entry is the migration fallback (see Service.qml).
  readonly property var barEntry: {
    var cfg = root.fileConfig
    if (!cfg || !cfg.bar || !cfg.bar.layout) return null
    var secs = ["left", "center", "right"]
    for (var s = 0; s < secs.length; s++) {
      var arr = cfg.bar.layout[secs[s]]
      if (!Array.isArray(arr)) continue
      for (var i = 0; i < arr.length; i++) {
        var be = arr[i]
        var bid = (be && typeof be === "object" && be.id) ? String(be.id) : String(be || "")
        if (bid === "io.github.kamal-v8.bar-squared") return (be && typeof be === "object") ? be : { id: "io.github.kamal-v8.bar-squared" }
      }
    }
    return null
  }
  readonly property var pluginEntry: {
    var cfg = root.fileConfig
    if (!cfg || !Array.isArray(cfg.plugins)) return null
    for (var i = 0; i < cfg.plugins.length; i++)
      if (cfg.plugins[i] && String(cfg.plugins[i].id) === "io.github.kamal-v8.bar-squared") return cfg.plugins[i]
    return null
  }
  readonly property var configEntry: {
    var b = root.barEntry
    var p = root.pluginEntry
    if (b && p && typeof b === "object" && typeof p === "object") {
      var bKeys = Object.keys(b)
      var pKeys = Object.keys(p)
      if (bKeys.length <= 1 && pKeys.length > 1) return p
      if (bKeys.length > 1) return b
      return pKeys.length > 1 ? p : b
    }
    return b ? b : p
  }
  readonly property var dupLayout: {
    var e = root.configEntry
    if (e && e.layout && typeof e.layout === "object") {
      return {
        left: Array.isArray(e.layout.left) ? e.layout.left : [],
        center: Array.isArray(e.layout.center) ? e.layout.center : [],
        right: Array.isArray(e.layout.right) ? e.layout.right : []
      }
    }
    return { left: [], center: [], right: [] }
  }
  readonly property string mode: {
    var e = root.configEntry; var m = e ? String(e.mode || "") : ""
    return (m === "floating" || m === "full") ? m : "full"
  }
  readonly property string position: {
    var e = root.configEntry; var p = e ? String(e.position || "") : ""
    return /^(top|bottom|left|right)$/.test(p) ? p : "bottom"
  }
  readonly property int storedWidth: {
    var e = root.configEntry; var w = e ? Number(e.width) : NaN
    return isFinite(w) && w >= 200 && w <= 4000 ? Math.round(w) : 900
  }
  readonly property int storedHeight: {
    var e = root.configEntry; var h = e ? Number(e.height) : NaN
    if (isFinite(h)) return Math.max(20, Math.min(80, Math.round(h)))
    var isVert = root.position === "left" || root.position === "right"
    return isVert ? Style.bar.sizeVertical : Style.bar.sizeHorizontal
  }
  readonly property int storedRadius: {
    var e = root.configEntry; var r = e ? Number(e.radius) : NaN
    if (isFinite(r)) return Math.max(0, Math.min(40, Math.round(r)))
    return root.mode === "floating" ? Style.cornerRadius : 0
  }
  readonly property int storedSpacing: {
    var e = root.configEntry; var s = e ? Number(e.spacing) : NaN
    return isFinite(s) ? Math.max(0, Math.min(32, Math.round(s))) : 0
  }
  readonly property bool transparent: {
    var e = root.configEntry; return e ? e.transparent === true : false
  }
  readonly property bool hasExplicitWidth: {
    var e = root.configEntry; return e ? ("width" in e) : false
  }
  readonly property int countDup: dupLayout.left.length + dupLayout.center.length + dupLayout.right.length

  readonly property var mainLayout: {
    var cfg = root.fileConfig
    if (!cfg || !cfg.bar || !cfg.bar.layout) return { left: [], center: [], right: [] }
    var l = cfg.bar.layout
    return {
      left: Array.isArray(l.left) ? l.left : [],
      center: Array.isArray(l.center) ? l.center : [],
      right: Array.isArray(l.right) ? l.right : []
    }
  }
  readonly property int countMain: mainLayout.left.length + mainLayout.center.length + mainLayout.right.length

  function entryId(e) {
    if (typeof e === "string") return String(e)
    if (e && typeof e === "object" && e.id) return String(e.id)
    return ""
  }

  // Searchable rows: {id, sec} for the main bar, {id, sec, idx, count} for Bar²
  // (idx/count drive the ↑/↓ reorder buttons).
  readonly property var mainRows: {
    var out = []; var secs = ["left", "center", "right"]
    var f = root.mainFilter.trim().toLowerCase()
    for (var s = 0; s < secs.length; s++) {
      var arr = root.mainLayout[secs[s]]
      for (var i = 0; i < arr.length; i++) {
        var id = entryId(arr[i])
        // The Bar² control button itself can't move into Bar² — it would
        // strand the controls for the bar it operates.
        if (id === "io.github.kamal-v8.bar-squared") continue
        if (!f || id.toLowerCase().indexOf(f) !== -1) out.push({ id: id, sec: secs[s] })
      }
    }
    return out
  }
  readonly property var dupRows: {
    var out2 = []; var secs2 = ["left", "center", "right"]
    var f2 = root.dupFilter.trim().toLowerCase()
    for (var s2 = 0; s2 < secs2.length; s2++) {
      var arr2 = root.dupLayout[secs2[s2]]
      for (var i2 = 0; i2 < arr2.length; i2++) {
        var id2 = entryId(arr2[i2])
        if (!f2 || id2.toLowerCase().indexOf(f2) !== -1)
          out2.push({ id: id2, sec: secs2[s2], idx: i2, count: arr2.length })
      }
    }
    return out2
  }

  function barFg() { return root.bar ? root.bar.foreground : Color.foreground }
  function barFont() { return root.bar ? root.bar.fontFamily : Style.font.family }

  Process { id: ipcProc }
  function callBarSquared(args) {
    ipcProc.command = ["omarchy-shell", "io.github.kamal-v8.bar-squared"].concat(args)
    ipcProc.running = true
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(760))
    contentHeight: panel.fittedContentHeight(inner.implicitHeight, Style.space(520))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: inner.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
        Binding {
          target: scrollArea.contentItem
          property: "interactive"
          value: inner.implicitHeight > scrollArea.height
        }

        ColumnLayout {
          id: inner
          width: scrollArea.availableWidth
          spacing: Style.space(6)

          // ---- Header: [icon] Bar² | Settings + live status pill + gear + close.
          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(6)
            BorderSurface {
              Layout.preferredWidth: Style.space(30)
              Layout.preferredHeight: Style.space(30)
              Layout.alignment: Qt.AlignVCenter
              radius: Math.max(Style.cornerRadius, Style.space(7))
              color: Style.selectedFillFor(root.barFg(), Color.accent)
              borderSpec: Border.controlSpec("normal", root.barFg(), Color.accent)
              Text {
                anchors.centerIn: parent
                text: "◧"
                color: root.barFg()
                font.family: root.barFont()
                font.pixelSize: Style.font.title
                font.bold: true
              }
            }
            ColumnLayout {
              Layout.fillWidth: true
              spacing: 0
              Text {
                text: "Bar² | Settings"
                color: root.barFg()
                font.family: root.barFont()
                font.pixelSize: Style.font.heading
                font.bold: true
                elide: Text.ElideRight
              }
              Text {
                text: "Full settings exposed in a compact side drawer."
                color: root.barFg()
                opacity: 0.55
                font.family: root.barFont()
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }
            }
            BorderSurface {
              Layout.alignment: Qt.AlignVCenter
              implicitWidth: statusText.implicitWidth + Style.space(16)
              implicitHeight: statusText.implicitHeight + Style.space(8)
              radius: (statusText.implicitHeight + Style.space(8)) / 2
              color: Style.selectedFillFor(root.barFg(), Color.accent)
              borderSpec: Border.controlSpec("normal", root.barFg(), Color.accent)
              Text {
                id: statusText
                anchors.centerIn: parent
                text: root.mode + "·" + root.position
                color: root.barFg()
                font.family: root.barFont()
                font.pixelSize: Style.font.caption
              }
            }
            Button {
              text: "⚙"
              fontSize: Style.font.heading
              selected: root.showBarSettings
              tooltipText: "Toggle settings drawer"
              Layout.alignment: Qt.AlignVCenter
              onClicked: root.showBarSettings = !root.showBarSettings
            }
            Button {
              text: "✕"
              fontSize: Style.font.body
              tooltipText: "Close"
              Layout.alignment: Qt.AlignVCenter
              onClicked: root.close()
            }
          }

          PanelSeparator {
            foreground: root.barFg()
          }

          // ---- Content: drawer | Main | Second.
          // Plain ColumnLayouts with explicit widths: fixed drawer,
          // two lists share the rest equally. 1px dividers between them.
          RowLayout {
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignTop
            spacing: Style.space(6)

            // ---- Settings drawer (fixed 210px).
            ColumnLayout {
              visible: root.showBarSettings
              Layout.preferredWidth: Style.space(210)
              Layout.maximumWidth: Style.space(210)
              Layout.minimumWidth: Style.space(210)
              Layout.alignment: Qt.AlignTop
              spacing: Style.space(6)

              RowLayout {
                Layout.fillWidth: true
                spacing: Style.space(4)
                Text {
                  text: "Settings"
                  color: root.barFg()
                  font.family: root.barFont()
                  font.pixelSize: Style.font.title
                  font.bold: true
                  Layout.fillWidth: true
                  elide: Text.ElideRight
                }
                Button {
                  text: "✕"
                  fontSize: Style.font.bodySmall
                  tooltipText: "Hide settings drawer"
                  onClicked: root.showBarSettings = false
                }
              }

              PanelSectionHeader {
                text: "APPEARANCE"
                foreground: root.barFg()
                fontFamily: root.barFont()
                Layout.fillWidth: true
              }

              Text {
                text: "Mode"
                color: root.barFg()
                opacity: 0.6
                font.family: root.barFont()
                font.pixelSize: Style.font.caption
              }
              RowLayout {
                Layout.fillWidth: true
                spacing: Style.space(4)
                Button {
                  text: "Full"
                  fontSize: Style.font.bodySmall
                  selected: root.mode === "full"
                  Layout.fillWidth: true
                  onClicked: if (root.mode !== "full") callBarSquared(["setMode", "full"])
                }
                Button {
                  text: "Floating"
                  fontSize: Style.font.bodySmall
                  selected: root.mode === "floating"
                  Layout.fillWidth: true
                  onClicked: if (root.mode !== "floating") callBarSquared(["setMode", "floating"])
                }
              }

              Text {
                text: "Edge"
                color: root.barFg()
                opacity: 0.6
                font.family: root.barFont()
                font.pixelSize: Style.font.caption
              }
              RowLayout {
                Layout.fillWidth: true
                spacing: Style.space(3)
                Repeater {
                  model: ["top", "bottom", "left", "right"]
                  delegate: Button {
                    required property string modelData
                    text: modelData
                    fontSize: Style.font.bodySmall
                    selected: root.position === modelData
                    Layout.fillWidth: true
                    onClicked: callBarSquared(["setPosition", modelData])
                  }
                }
              }

              Text {
                text: "Look"
                color: root.barFg()
                opacity: 0.6
                font.family: root.barFont()
                font.pixelSize: Style.font.caption
              }
              RowLayout {
                Layout.fillWidth: true
                spacing: Style.space(4)
                Button {
                  text: "Transparent"
                  fontSize: Style.font.bodySmall
                  selected: root.transparent
                  Layout.fillWidth: true
                  onClicked: if (!root.transparent) callBarSquared(["setTransparent", "true"])
                }
                Button {
                  text: "Opaque"
                  fontSize: Style.font.bodySmall
                  selected: !root.transparent
                  Layout.fillWidth: true
                  onClicked: if (root.transparent) callBarSquared(["setTransparent", "false"])
                }
              }

              PanelSectionHeader {
                text: "DIMENSIONS"
                foreground: root.barFg()
                fontFamily: root.barFont()
                Layout.fillWidth: true
              }

              RowLayout {
                Layout.fillWidth: true
                spacing: Style.space(4)
                Text {
                  text: "Width"
                  color: root.barFg()
                  opacity: 0.6
                  font.family: root.barFont()
                  font.pixelSize: Style.font.caption
                  Layout.fillWidth: true
                }
                Text {
                  text: root.storedWidth + "px"
                  color: root.barFg()
                  font.family: root.barFont()
                  font.pixelSize: Style.font.caption
                }
              }
              GridLayout {
                Layout.fillWidth: true
                columns: 3
                rowSpacing: Style.space(3)
                columnSpacing: Style.space(3)
                Button {
                  text: "300"
                  fontSize: Style.font.bodySmall
                  selected: root.storedWidth === 300
                  Layout.fillWidth: true
                  onClicked: callBarSquared(["setWidth", "300"])
                }
                Button {
                  text: "400"
                  fontSize: Style.font.bodySmall
                  selected: root.storedWidth === 400
                  Layout.fillWidth: true
                  onClicked: callBarSquared(["setWidth", "400"])
                }
                Button {
                  text: "500"
                  fontSize: Style.font.bodySmall
                  selected: root.storedWidth === 500
                  Layout.fillWidth: true
                  onClicked: callBarSquared(["setWidth", "500"])
                }
                Button {
                  text: "600"
                  fontSize: Style.font.bodySmall
                  selected: root.storedWidth === 600
                  Layout.fillWidth: true
                  onClicked: callBarSquared(["setWidth", "600"])
                }
                Button {
                  text: "Custom"
                  fontSize: Style.font.bodySmall
                  selected: [300, 400, 500, 600].indexOf(root.storedWidth) === -1
                  Layout.fillWidth: true
                  Layout.columnSpan: 2
                  tooltipText: "Any other value via stepper below"
                }
              }
              RowLayout {
                Layout.fillWidth: true
                spacing: Style.space(4)
                Button {
                  text: "-"
                  fontSize: Style.font.body
                  bordered: true
                  tooltipText: "Decrease width by 50"
                  Layout.preferredWidth: Style.space(28)
                  opacity: root.storedWidth > 200 ? 1.0 : 0.35
                  onClicked: callBarSquared(["setWidth", String(Math.max(200, Math.min(4000, root.storedWidth - 50)))])
                }
                Text {
                  text: root.storedWidth + "px"
                  color: root.barFg()
                  font.family: root.barFont()
                  font.pixelSize: Style.font.bodySmall
                  horizontalAlignment: Text.AlignHCenter
                  Layout.fillWidth: true
                }
                Button {
                  text: "+"
                  fontSize: Style.font.body
                  bordered: true
                  tooltipText: "Increase width by 50"
                  Layout.preferredWidth: Style.space(28)
                  opacity: root.storedWidth < 4000 ? 1.0 : 0.35
                  onClicked: callBarSquared(["setWidth", String(Math.max(200, Math.min(4000, root.storedWidth + 50)))])
                }
              }

              RowLayout {
                Layout.fillWidth: true
                spacing: Style.space(4)
                Text {
                  text: "Height"
                  color: root.barFg()
                  opacity: 0.6
                  font.family: root.barFont()
                  font.pixelSize: Style.font.caption
                  Layout.fillWidth: true
                }
                Text {
                  text: root.storedHeight + "px"
                  color: root.barFg()
                  font.family: root.barFont()
                  font.pixelSize: Style.font.caption
                }
              }
              RowLayout {
                Layout.fillWidth: true
                spacing: Style.space(4)
                Button {
                  text: "-"
                  fontSize: Style.font.body
                  bordered: true
                  tooltipText: "Decrease height by 2"
                  Layout.preferredWidth: Style.space(28)
                  opacity: root.storedHeight > 20 ? 1.0 : 0.35
                  onClicked: callBarSquared(["setHeight", String(Math.max(20, Math.min(80, root.storedHeight - 2)))])
                }
                Text {
                  text: root.storedHeight + "px"
                  color: root.barFg()
                  font.family: root.barFont()
                  font.pixelSize: Style.font.bodySmall
                  horizontalAlignment: Text.AlignHCenter
                  Layout.fillWidth: true
                }
                Button {
                  text: "+"
                  fontSize: Style.font.body
                  bordered: true
                  tooltipText: "Increase height by 2"
                  Layout.preferredWidth: Style.space(28)
                  opacity: root.storedHeight < 80 ? 1.0 : 0.35
                  onClicked: callBarSquared(["setHeight", String(Math.max(20, Math.min(80, root.storedHeight + 2)))])
                }
              }

              PanelSectionHeader {
                text: "STYLE"
                foreground: root.barFg()
                fontFamily: root.barFont()
                Layout.fillWidth: true
              }

              RowLayout {
                Layout.fillWidth: true
                spacing: Style.space(4)
                Text {
                  text: "Corners"
                  color: root.barFg()
                  opacity: 0.6
                  font.family: root.barFont()
                  font.pixelSize: Style.font.caption
                  Layout.fillWidth: true
                }
                Text {
                  text: root.storedRadius === 0 ? "square" : root.storedRadius + "px"
                  color: root.barFg()
                  font.family: root.barFont()
                  font.pixelSize: Style.font.caption
                }
              }
              RowLayout {
                Layout.fillWidth: true
                spacing: Style.space(4)
                Button {
                  text: "-"
                  fontSize: Style.font.body
                  bordered: true
                  tooltipText: "Decrease corners by 2"
                  Layout.preferredWidth: Style.space(28)
                  opacity: root.storedRadius > 0 ? 1.0 : 0.35
                  onClicked: callBarSquared(["setRadius", String(Math.max(0, Math.min(40, root.storedRadius - 2)))])
                }
                Text {
                  text: root.storedRadius === 0 ? "square" : root.storedRadius + "px"
                  color: root.barFg()
                  font.family: root.barFont()
                  font.pixelSize: Style.font.bodySmall
                  horizontalAlignment: Text.AlignHCenter
                  Layout.fillWidth: true
                }
                Button {
                  text: "+"
                  fontSize: Style.font.body
                  bordered: true
                  tooltipText: "Increase corners by 2"
                  Layout.preferredWidth: Style.space(28)
                  opacity: root.storedRadius < 40 ? 1.0 : 0.35
                  onClicked: callBarSquared(["setRadius", String(Math.max(0, Math.min(40, root.storedRadius + 2)))])
                }
              }

              RowLayout {
                Layout.fillWidth: true
                spacing: Style.space(4)
                Text {
                  text: "Spacing"
                  color: root.barFg()
                  opacity: 0.6
                  font.family: root.barFont()
                  font.pixelSize: Style.font.caption
                  Layout.fillWidth: true
                }
                Text {
                  text: root.storedSpacing + "px"
                  color: root.barFg()
                  font.family: root.barFont()
                  font.pixelSize: Style.font.caption
                }
              }
              RowLayout {
                Layout.fillWidth: true
                spacing: Style.space(4)
                Button {
                  text: "-"
                  fontSize: Style.font.body
                  bordered: true
                  tooltipText: "Decrease spacing by 1"
                  Layout.preferredWidth: Style.space(28)
                  opacity: root.storedSpacing > 0 ? 1.0 : 0.35
                  onClicked: callBarSquared(["setSpacing", String(Math.max(0, Math.min(32, root.storedSpacing - 1)))])
                }
                Text {
                  text: root.storedSpacing + "px"
                  color: root.barFg()
                  font.family: root.barFont()
                  font.pixelSize: Style.font.bodySmall
                  horizontalAlignment: Text.AlignHCenter
                  Layout.fillWidth: true
                }
                Button {
                  text: "+"
                  fontSize: Style.font.body
                  bordered: true
                  tooltipText: "Increase spacing by 1"
                  Layout.preferredWidth: Style.space(28)
                  opacity: root.storedSpacing < 32 ? 1.0 : 0.35
                  onClicked: callBarSquared(["setSpacing", String(Math.max(0, Math.min(32, root.storedSpacing + 1)))])
                }
              }
              Text {
                text: "Changes save automatically."
                color: root.barFg()
                opacity: 0.5
                font.family: root.barFont()
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
              }
            }

            Rectangle {
              visible: root.showBarSettings
              Layout.fillHeight: true
              Layout.preferredWidth: 1
              color: root.barFg()
              opacity: 0.18
            }

            // ---- Main bar column (shares leftover width equally).
            ColumnLayout {
              Layout.fillWidth: true
              Layout.minimumWidth: Style.space(170)
              Layout.alignment: Qt.AlignTop
              spacing: Style.space(4)
              RowLayout {
                Layout.fillWidth: true
                spacing: Style.space(6)
                Text {
                  text: "Main bar (" + root.countMain + ")"
                  color: root.barFg()
                  font.family: root.barFont()
                  font.pixelSize: Style.font.title
                  font.bold: true
                  Layout.fillWidth: true
                  elide: Text.ElideRight
                }
                BorderSurface {
                  Layout.alignment: Qt.AlignVCenter
                  implicitWidth: mainBadgeText.implicitWidth + Style.space(12)
                  implicitHeight: mainBadgeText.implicitHeight + Style.space(6)
                  radius: (mainBadgeText.implicitHeight + Style.space(6)) / 2
                  color: Style.selectedFillFor(root.barFg(), Color.accent)
                  borderSpec: Border.controlSpec("normal", root.barFg(), Color.accent)
                  Text {
                    id: mainBadgeText
                    anchors.centerIn: parent
                    text: "primary"
                    color: root.barFg()
                    font.family: root.barFont()
                    font.pixelSize: Style.font.caption
                  }
                }
              }
              TextField {
                Layout.fillWidth: true
                placeholderText: "Search widgets..."
                font.pixelSize: Style.font.body
                text: root.mainFilter
                onTextChanged: if (text !== root.mainFilter) root.mainFilter = text
              }
              Column {
                Layout.fillWidth: true
                spacing: 2
                Repeater {
                  model: root.mainRows
                  delegate: RowLayout {
                    required property var modelData
                    width: parent ? parent.width : 0
                    spacing: Style.space(4)
                    Text {
                      text: "≡"
                      color: root.barFg()
                      opacity: 0.35
                      font.family: root.barFont()
                      font.pixelSize: Style.font.body
                    }
                    Text {
                      text: modelData.id
                      color: root.barFg()
                      font.family: root.barFont()
                      font.pixelSize: Style.font.subtitle
                      elide: Text.ElideRight
                      Layout.fillWidth: true
                    }
                    Text {
                      text: modelData.sec
                      color: root.barFg()
                      opacity: 0.45
                      font.family: root.barFont()
                      font.pixelSize: Style.font.caption
                    }
                    Button {
                      text: "→"
                      fontSize: Style.font.heading
                      bordered: true
                      tooltipText: "Move to second bar"
                      Layout.preferredWidth: Style.space(34)
                      onClicked: callBarSquared(["moveFromMain", modelData.id, modelData.sec])
                    }
                  }
                }
              }
              Text {
                visible: root.mainRows.length === 0
                text: root.countMain === 0 ? "Main bar is empty" : "No matches"
                color: root.barFg()
                opacity: 0.5
                font.pixelSize: Style.font.subtitle
              }
            }

            // ---- Second bar column (shares leftover width equally).
            ColumnLayout {
              Layout.fillWidth: true
              Layout.minimumWidth: Style.space(170)
              Layout.alignment: Qt.AlignTop
              spacing: Style.space(4)
              RowLayout {
                Layout.fillWidth: true
                spacing: Style.space(6)
                Text {
                  text: "Second bar (" + root.countDup + ")"
                  color: root.barFg()
                  font.family: root.barFont()
                  font.pixelSize: Style.font.title
                  font.bold: true
                  Layout.fillWidth: true
                  elide: Text.ElideRight
                }
                BorderSurface {
                  Layout.alignment: Qt.AlignVCenter
                  implicitWidth: dupBadgeText.implicitWidth + Style.space(12)
                  implicitHeight: dupBadgeText.implicitHeight + Style.space(6)
                  radius: (dupBadgeText.implicitHeight + Style.space(6)) / 2
                  color: Style.selectedFillFor(root.barFg(), Color.accent)
                  borderSpec: Border.controlSpec("normal", root.barFg(), Color.accent)
                  Text {
                    id: dupBadgeText
                    anchors.centerIn: parent
                    text: "secondary"
                    color: root.barFg()
                    font.family: root.barFont()
                    font.pixelSize: Style.font.caption
                  }
                }
              }
              TextField {
                Layout.fillWidth: true
                placeholderText: "Search widgets..."
                font.pixelSize: Style.font.body
                text: root.dupFilter
                onTextChanged: if (text !== root.dupFilter) root.dupFilter = text
              }
              Column {
                Layout.fillWidth: true
                spacing: 2
                Repeater {
                  model: root.dupRows
                  delegate: RowLayout {
                    required property var modelData
                    width: parent ? parent.width : 0
                    spacing: Style.space(2)
                    Text {
                      text: "≡"
                      color: root.barFg()
                      opacity: 0.35
                      font.family: root.barFont()
                      font.pixelSize: Style.font.body
                    }
                    Text {
                      text: modelData.id
                      color: root.barFg()
                      font.family: root.barFont()
                      font.pixelSize: Style.font.subtitle
                      elide: Text.ElideRight
                      Layout.fillWidth: true
                    }
                    Text {
                      text: modelData.sec
                      color: root.barFg()
                      opacity: 0.45
                      font.family: root.barFont()
                      font.pixelSize: Style.font.caption
                    }
                    Button {
                      text: "↑"
                      fontSize: Style.font.bodySmall
                      bordered: true
                      tooltipText: "Move up"
                      Layout.preferredWidth: Style.space(26)
                      opacity: modelData.idx > 0 ? 1.0 : 0.35
                      onClicked: callBarSquared(["moveWithinDup", modelData.id, "-1"])
                    }
                    Button {
                      text: "↓"
                      fontSize: Style.font.bodySmall
                      bordered: true
                      tooltipText: "Move down"
                      Layout.preferredWidth: Style.space(26)
                      opacity: modelData.idx < modelData.count - 1 ? 1.0 : 0.35
                      onClicked: callBarSquared(["moveWithinDup", modelData.id, "1"])
                    }
                    Button {
                      text: "←"
                      fontSize: Style.font.heading
                      bordered: true
                      tooltipText: "Move back to main bar"
                      Layout.preferredWidth: Style.space(34)
                      onClicked: callBarSquared(["moveToMain", modelData.id, modelData.sec])
                    }
                  }
                }
              }
              Text {
                visible: root.dupRows.length === 0
                text: root.countDup === 0 ? "Empty — use → to add widgets" : "No matches"
                color: root.barFg()
                opacity: 0.5
                font.pixelSize: Style.font.subtitle
              }
            }
          }

          PanelSeparator {
            foreground: root.barFg()
          }

          // ---- Footer: hints left, Clear/Close right.
          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(6)
            Text {
              text: "⚙"
              color: root.barFg()
              opacity: 0.5
              font.family: root.barFont()
              font.pixelSize: Style.font.body
            }
            Text {
              text: "Live preview • Changes save automatically"
              color: root.barFg()
              opacity: 0.5
              font.family: root.barFont()
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
              Layout.fillWidth: true
            }
            Button { text: "Clear"; onClicked: callBarSquared(["clear"]) }
            Button { text: "Close"; onClicked: root.close() }
          }
        }
      }
    }
  }
}

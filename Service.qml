import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

Item {
  id: root
  property var shell: null
  property var manifest: null
  property var barWidgetRegistry: null
  property var pluginRegistry: null
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")

  readonly property string pluginId: "io.github.kamal-v8.bar-squared"

  // Panel lifetime decoupling: BarWidget's Loader (and its ControlPanel with
  // PanelController.open) is rebuilt on every structural shell.json edit, so
  // keeping open state there closes the panel on every move. This bool
  // outlives bar rebuilds; BarWidget mirrors live state here and restores it
  // onLoaded, so rapid edits don't close the panel. summon/hide/toggle keep
  // routing through BarWidget.open/close/opened (which update this).
  property bool panelOpen: false

  property var fileConfig: ({})
  FileView {
    id: configFile
    path: Quickshell.env("HOME") + "/.config/omarchy/shell.json"
    watchChanges: true
    printErrors: false
    onLoaded: {
      try { root.fileConfig = JSON.parse(text() || "{}") } catch(e) { root.fileConfig = {} }
    }
    onLoadFailed: { root.fileConfig = {} }
    onFileChanged: reload()
  }

  // Single-entry (omasot pattern): config lives in the bar.layout entry for
  // this id. plugins[] self-entry is legacy (pre-1.3) and is migrated away on
  // load. All mutations below write to the bar.layout entry.
  readonly property var barEntry: {
    var cfg = root.fileConfig
    if (!cfg || !cfg.bar || !cfg.bar.layout) return null
    var secs = ["left", "center", "right"]
    for (var s = 0; s < secs.length; s++) {
      var arr = cfg.bar.layout[secs[s]]
      if (!Array.isArray(arr)) continue
      for (var i = 0; i < arr.length; i++) {
        var e = arr[i]
        var eid = (e && typeof e === "object" && e.id) ? String(e.id) : String(e || "")
        if (eid === pluginId) return (e && typeof e === "object") ? e : { id: pluginId }
      }
    }
    return null
  }
  readonly property bool controlInMain: root.barEntry !== null
  readonly property var pluginEntry: {
    var cfg = root.fileConfig
    if (!cfg || !Array.isArray(cfg.plugins)) return null
    for (var i = 0; i < cfg.plugins.length; i++) {
      var e = cfg.plugins[i]
      if (e && String(e.id) === pluginId) return e
    }
    return null
  }
  // Effective config: bar entry wins; legacy plugins[] entry is the fallback
  // during migration. Merge so a bare {"id":...} bar entry created by
  // `omarchy plugin enable` still sees legacy settings until migration copies
  // them over (avoids a flicker to defaults).
  readonly property var configEntry: {
    var b = root.barEntry
    var p = root.pluginEntry
    if (b && p && typeof b === "object" && typeof p === "object") {
      var bKeys = Object.keys(b)
      var pKeys = Object.keys(p)
      // Bare bar entry (only id) + rich legacy entry -> use legacy until
      // migration copies it over.
      if (bKeys.length <= 1 && pKeys.length > 1) return p
      if (bKeys.length > 1) return b
      return pKeys.length > 1 ? p : b
    }
    return b ? b : p
  }
  readonly property string mode: {
    var e = root.configEntry
    var m = e ? String(e.mode || "") : ""
    return (m === "floating" || m === "full") ? m : "full"
  }
  readonly property string position: {
    var e = root.configEntry
    var p = e ? String(e.position || "") : ""
    return /^(top|bottom|left|right)$/.test(p) ? p : "bottom"
  }
  readonly property int storedWidth: {
    var e = root.configEntry
    var w = e ? Number(e.width) : NaN
    return isFinite(w) && w >= 200 && w <= 4000 ? Math.round(w) : 900
  }
  readonly property bool hasExplicitWidth: {
    var e = root.configEntry
    return e ? ("width" in e) : false
  }
  // Bar thickness in px. Defaults to the theme's bar size so existing setups
  // look identical until the user adjusts Height in the control panel.
  readonly property int storedHeight: {
    var e = root.configEntry
    var h = e ? Number(e.height) : NaN
    if (isFinite(h)) return Math.max(20, Math.min(80, Math.round(h)))
    return root.vertical ? Style.bar.sizeVertical : Style.bar.sizeHorizontal
  }
  readonly property bool hasExplicitHeight: {
    var e = root.configEntry
    return e ? ("height" in e) : false
  }
  // Corner roundness in px. Defaults preserve the old look (floating follows
  // the theme radius, docked stays square) until the user picks Curves.
  readonly property int storedRadius: {
    var e = root.configEntry
    var r = e ? Number(e.radius) : NaN
    if (isFinite(r)) return Math.max(0, Math.min(40, Math.round(r)))
    return root.mode === "floating" ? Style.cornerRadius : 0
  }
  readonly property bool hasExplicitRadius: {
    var e = root.configEntry
    return e ? ("radius" in e) : false
  }
  // Gap in px between hosted widgets. Default 0 preserves the packed look.
  readonly property int storedSpacing: {
    var e = root.configEntry
    var s = e ? Number(e.spacing) : NaN
    return isFinite(s) ? Math.max(0, Math.min(32, Math.round(s))) : 0
  }
  // Docked-but-shrunk: full mode with an explicit width behaves like a
  // centered dock (reserves space, never overlays windows) with a custom width.
  // This gives "not floating, but shrunk" as requested.
  readonly property bool dockedShrunk: root.mode === "full" && root.hasExplicitWidth && !root.vertical
  readonly property bool isShrunkWidth: root.mode === "floating" || root.dockedShrunk
  readonly property bool transparent: {
    var e = root.configEntry
    return e ? e.transparent === true : false
  }
  readonly property var dupLayout: {
    var e = root.configEntry
    if (e && e.layout && typeof e.layout === "object") {
      var l = e.layout
      return {
        left: Array.isArray(l.left) ? l.left : [],
        center: Array.isArray(l.center) ? l.center : [],
        right: Array.isArray(l.right) ? l.right : []
      }
    }
    return { left: [], center: [], right: [] }
  }
  // Effective hosted layout: nested layout minus anything also sitting in the
  // main bar (main wins). This prevents double-rendering the same widget in
  // both bars after disable→enable cycles, and keeps a single live instance.
  function filteredDup() {
    var dup = root.dupLayout || { left: [], center: [], right: [] }
    var inMain = {}
    try {
      var ml = root.fileConfig && root.fileConfig.bar && root.fileConfig.bar.layout
      var secs = ["left", "center", "right"]
      for (var s = 0; s < secs.length; s++) {
        var arr = ml ? ml[secs[s]] : null
        if (!Array.isArray(arr)) continue
        for (var i = 0; i < arr.length; i++) inMain[root.entryId(arr[i])] = true
      }
    } catch(e) {}
    function keep(list) {
      var out = []
      if (!Array.isArray(list)) return out
      for (var i = 0; i < list.length; i++) {
        if (!inMain[root.entryId(list[i])]) out.push(list[i])
      }
      return out
    }
    return { left: keep(dup.left), center: keep(dup.center), right: keep(dup.right) }
  }
  // Live hosted layout, split per section so an edit in one section only
  // remounts that section's Loaders (a whole-object reassign would rebuild
  // every hosted widget, wiping async state like GPU detection).
  property var liveLeft: []
  property var liveCenter: []
  property var liveRight: []
  // Reassigning a section rebuilds its hosted widgets (wiping async state
  // like GPU detection, which needs seconds to re-poll). Only reassign a
  // section whose effective layout actually changed, so Width/Height/
  // Corners/Transparent/Mode tweaks and unrelated shell.json writes don't
  // destroy live widgets.
  function layoutSig(l) {
    try { return JSON.stringify(l || {}) } catch(e) { return "" }
  }
  function syncLive() {
    var fresh = root.filteredDup()
    if (root.layoutSig(fresh.left) !== root.layoutSig(root.liveLeft)) root.liveLeft = fresh.left
    if (root.layoutSig(fresh.center) !== root.layoutSig(root.liveCenter)) root.liveCenter = fresh.center
    if (root.layoutSig(fresh.right) !== root.layoutSig(root.liveRight)) root.liveRight = fresh.right
  }
  // Remembers the widest settled width per widget id (monotonic per
  // session). Rebuilds — reorder/move edits remount every Loader, whose
  // async widgets restart narrow (~20px) for seconds — immediately reuse the
  // remembered width instead of collapsing and mashing neighbors. Slots for
  // hidden items still collapse to 0.
  property var slotWidths: ({})
  property int slotWidthsRev: 0
  function rememberWidth(id, w) {
    if (!id || !(w > 0)) return
    if (w > (slotWidths[id] || 0)) { slotWidths[id] = w; slotWidthsRev++ }
  }
  function rememberedWidth(id) {
    var rev = root.slotWidthsRev
    return (id && slotWidths[id]) || 0
  }
  onDupLayoutChanged: { root.syncLive(); root.stashDup() }
  onFileConfigChanged: { root.syncLive(); root.trackBarPresence() }
  // One-click lifecycle tracking (single-entry):
  // - At first load with legacy dual state (no bar button + plugins[] self
  //   entry) -> migrate config into the bar.layout entry (restores button).
  // - On bar -> no-bar transition while service still alive (user ran
  //   `omarchy plugin disable`, which drops only the bar entry) -> self-clean:
  //   return hosted widgets to main, delete self plugins[] entry, so the
  //   service unloads and the bar hides in the same click.
  property bool _barInitDone: false
  property bool _hadBar: false
  property bool _migrateBusy: false
  property bool _cleanBusy: false
  // Crash-safe stash of the last hosted layout seen while the control button
  // was present. disableClean passes it to python as a fallback so a rapid
  // double-disable (second core call deletes the mirror before clean runs)
  // still returns widgets to the main bar instead of losing them.
  property string _lastDupJson: "{\"left\":[],\"center\":[],\"right\":[]}"
  function stashDup() {
    if (!root.controlInMain) return
    try { root._lastDupJson = JSON.stringify(root.dupLayout || {left:[],center:[],right:[]}) } catch(e) {}
  }
  // NOTE: called synchronously from onFileConfigChanged, where the barEntry /
  // pluginEntry bindings may still hold the previous config (QML re-evaluates
  // bindings after the handler). Scan root.fileConfig directly — it is fresh.
  function scanPresence(cfg) {
    var hb = false, hp = false
    try {
      var lay = cfg && cfg.bar && cfg.bar.layout
      var secs = ["left", "center", "right"]
      for (var s = 0; s < secs.length && !hb; s++) {
        var arr = lay ? lay[secs[s]] : null
        if (!Array.isArray(arr)) continue
        for (var i = 0; i < arr.length; i++) {
          var e = arr[i]
          var eid = (e && typeof e === "object" && e.id) ? String(e.id) : String(e || "")
          if (eid === pluginId) { hb = true; break }
        }
      }
      var plugs = cfg ? cfg.plugins : null
      if (Array.isArray(plugs)) {
        for (var j = 0; j < plugs.length; j++) {
          if (plugs[j] && String(plugs[j].id) === pluginId) { hp = true; break }
        }
      }
    } catch(e) {}
    return { hasBar: hb, hasPlug: hp }
  }
  function trackBarPresence() {
    var p = root.scanPresence(root.fileConfig)
    var hasBar = p.hasBar
    var hasPlug = p.hasPlug
    console.log("Bar² presence hasBar=" + hasBar + " hasPlug=" + hasPlug + " hadBar=" + root._hadBar + " init=" + root._barInitDone)
    if (!root._barInitDone) {
      root._barInitDone = true
      root._hadBar = hasBar
      if (!hasBar && hasPlug) {
        console.log("Bar² legacy store detected (plugins[] without bar button) — migrating to single-entry")
        root.migrateToBar()
      }
      return
    }
    if (root._hadBar && !hasBar) {
      if (hasPlug && !root._cleanBusy) {
        console.log("Bar² control removed — returning hosted widgets to main and dropping legacy store")
        root.disableClean()
      }
    } else if (!hasBar && hasPlug && !root._hadBar && !root._migrateBusy && !root._cleanBusy) {
      root.migrateToBar()
    }
    root._hadBar = hasBar
  }
  // Window shows iff at least one hosted entry is actually loadable
  // (registered). Disabling the last widget hides the whole bar instead of
  // leaving an empty pill that reserves space.
  readonly property bool hasLiveWidgets: {
    var reg = root.barWidgetRegistry ? root.barWidgetRegistry.widgets : null
    if (!reg) return false
    var lays = [root.liveLeft, root.liveCenter, root.liveRight]
    for (var s = 0; s < lays.length; s++) {
      var arr = lays[s]
      if (!Array.isArray(arr)) continue
      for (var i = 0; i < arr.length; i++) {
        var id = root.entryId(arr[i])
        if (id && reg[id]) return true
      }
    }
    return false
  }
  Component.onCompleted: {
    root.syncLive()
    root.trackBarPresence()
    console.log("Bar² loaded mode=" + root.mode + " pos=" + root.position + " width=" + root.storedWidth + " controlInMain=" + root.controlInMain)
  }

  readonly property bool vertical: position === "left" || position === "right"
  readonly property int barSize: vertical ? Style.bar.sizeVertical : Style.bar.sizeHorizontal
  property color themeBackground: Color.bar.background
  property color themeForeground: Color.bar.text
  property int floatingWidth: storedWidth
  onStoredWidthChanged: floatingWidth = storedWidth

  function persist(updater) {
    if (!shell) return false
    // Single-entry: config lives in the bar.layout entry; updateEntryInline
    // prefers it automatically, so this now targets the right place.
    var cur = root.configEntry
    if (!cur) return false
    var next = {}
    for (var k in cur) next[k] = cur[k]
    updater(next)
    return shell.updateEntryInline(pluginId, next)
  }
  // Primary store: bar.layout entry (omasot pattern). Write-through mirror to
  // the legacy plugins[] self-entry so a one-click `plugin disable` (which
  // synchronously deletes the bar entry and unloads this service before any
  // async clean could run) leaves the hosted layout behind for disableClean
  // to move back to the main bar. Reads prefer the bar entry; the mirror is
  // backup only and is dropped by disableClean.
  Process {
    id: fileSetProc
    stdout: StdioCollector { id: fileSetOut; waitForEnd: true }
    stderr: StdioCollector { id: fileSetErr; waitForEnd: true }
    onExited: function(code){ if(code!==0) console.log("Bar² set failed "+code+" "+fileSetOut.text+" "+fileSetErr.text) }
  }
  function fileSet(key, value) {
    var home = Quickshell.env("HOME")
    // Single-entry: settings live in the bar.layout entry. Fall back to the
    // legacy plugins[] entry only when no bar entry exists (migration window).
    var py = ""
      + "import json,os,sys\n"
      + "p=os.path.expanduser('~/.config/omarchy/shell.json')\n"
      + "k=sys.argv[1]; v=sys.argv[2]\n"
      + "cfg=json.load(open(p))\n"
      + "import json as j\n"
      + "PID='io.github.kamal-v8.bar-squared'\n"
      + "def find_bar(cfg):\n"
      + "  lay=cfg.get('bar',{}).get('layout',{})\n"
      + "  for s in ['left','center','right']:\n"
      + "    arr=lay.get(s,[])\n"
      + "    for i,e in enumerate(arr):\n"
      + "      eid=e.get('id') if isinstance(e,dict) else str(e)\n"
      + "      if eid==PID: return (s,i)\n"
      + "  return (None,None)\n"
      + "def ensure_obj(cfg,s,i):\n"
      + "  e=cfg['bar']['layout'][s][i]\n"
      + "  if not isinstance(e,dict):\n"
      + "    e={'id':PID}; cfg['bar']['layout'][s][i]=e\n"
      + "  return e\n"
      + "def apply_to(e,k,v,cfg):\n"
      + "  ret=[]\n"
      + "  if k=='mode': e['mode']=v\n"
      + "  elif k=='position': e['position']=v\n"
      + "  elif k=='width': e['width']=int(v)\n"
      + "  elif k=='height': e['height']=max(20,min(80,int(float(v))))\n"
      + "  elif k=='radius': e['radius']=max(0,min(40,int(float(v))))\n"
      + "  elif k=='spacing': e['spacing']=max(0,min(32,int(float(v))))\n"
      + "  elif k=='transparent': e['transparent']=(v=='true')\n"
      + "  elif k=='clear':\n"
      + "    dup_e=e\n"
      + "    for s in ['left','center','right']:\n"
      + "      for it in dup_e.get('layout',{}).get(s,[]): ret.append((s,it))\n"
      + "    cfg.setdefault('bar',{}).setdefault('layout',{});\n"
      + "    lay=cfg['bar']['layout']\n"
      + "    for s in ['left','center','right']:\n"
      + "      if s not in lay or not isinstance(lay[s],list): lay[s]=[]\n"
      + "    for (s,it) in ret:\n"
      + "      wid2=it.get('id') if isinstance(it,dict) else str(it)\n"
      + "      lay[s]=[x for x in lay[s] if ((x.get('id') if isinstance(x,dict) else str(x))!=wid2)]\n"
      + "      lay[s].append(it)\n"
      + "      if not wid2.startswith('omarchy.'):\n"
      + "        cfg['plugins']=[x for x in cfg.get('plugins',[]) if not (isinstance(x,dict) and x.get('id')==wid2 and set(x.keys())=={'id'})]\n"
      + "    e['layout']={'left':[],'center':[],'right':[]}\n"
      + "  return ret\n"
      + "def mirror_bar_to_plug(cfg, src):\n"
      + "  me=None\n"
      + "  for e in cfg.get('plugins',[]):\n"
      + "    if isinstance(e,dict) and e.get('id')==PID: me=e; break\n"
      + "  if me is None:\n"
      + "    me={'id':PID}; cfg.setdefault('plugins',[]).append(me)\n"
      + "  for kk in ['mode','position','width','height','radius','spacing','transparent','layout']:\n"
      + "    if kk in src: me[kk]=json.loads(json.dumps(src[kk]))\n"
      + "    elif kk in me and kk!='layout': del me[kk]\n"
      + "  if 'layout' not in src: me['layout']={'left':[],'center':[],'right':[]}\n"
      + "  return me\n"
      + "s,i=find_bar(cfg)\n"
      + "if s is not None:\n"
      + "  e=ensure_obj(cfg,s,i)\n"
      + "  apply_to(e,k,v,cfg)\n"
      + "  mirror_bar_to_plug(cfg,e)\n"
      + "else:\n"
      + "  found=False\n"
      + "  for e in cfg.get('plugins',[]):\n"
      + "    if isinstance(e,dict) and e.get('id')==PID:\n"
      + "      found=True; apply_to(e,k,v,cfg); break\n"
      + "  if not found:\n"
      + "    print('not found'); sys.exit(1)\n"
      + "tmp=p+'.tmp'; j.dump(cfg, open(tmp,'w'), indent=2); os.rename(tmp,p)\n"
      + "print('ok '+k+' '+v)\n"
    fileSetProc.command = ["python3","-c", py, String(key), String(value)]
    fileSetProc.running = true
  }

  function setMode(m) {
    var next = (m === "floating" || m === "full") ? m : (root.mode === "full" ? "floating" : "full")
    fileSet("mode", next)
  }
  function setPosition(p) {
    var np = /^(top|bottom|left|right)$/.test(String(p)) ? String(p) : "bottom"
    fileSet("position", np)
  }
  function setWidth(w) {
    var nw = Math.max(200, Math.min(4000, Math.round(Number(w) || 900)))
    fileSet("width", String(nw))
  }
  function clearLayout() { fileSet("clear","") }

  function canonical(id) { return String(id || "").trim() }
  function entryId(entry) {
    if (typeof entry === "string") return String(entry)
    if (entry && typeof entry === "object" && entry.id) return String(entry.id)
    return ""
  }

  function getMainBarEntry(widgetId) {
    var cfg = root.fileConfig
    if (!cfg || !cfg.bar || !cfg.bar.layout) return null
    var secs = ["left","center","right"]
    for (var s=0;s<secs.length;s++){
      var arr = cfg.bar.layout[secs[s]]
      if (!Array.isArray(arr)) continue
      for (var i=0;i<arr.length;i++) if (entryId(arr[i])===widgetId) return {entry: arr[i], section: secs[s], index:i}
    }
    return null
  }

  // File-based move via python (works for service without bar caps)
  Process {
    id: fileMoveProc
    stdout: StdioCollector { id: fileMoveOut; waitForEnd: true }
    stderr: StdioCollector { id: fileMoveErr; waitForEnd: true }
    onExited: function(code){
      if (code !== 0) console.log("Bar² file move failed code "+code+" out:"+fileMoveOut.text+" err:"+fileMoveErr.text)
      else console.log("Bar² file move ok out:"+fileMoveOut.text)
    }
  }

  // Single-entry moves: the hosted layout lives in the bar.layout entry's
  // nested `layout` (fallback to legacy plugins[] entry during migration).
  function fileMove(widgetId, dir, dstSection) {
    var wid = canonical(widgetId)
    if (!wid) return false
    var dstSec = /^(left|center|right)$/.test(String(dstSection)) ? String(dstSection) : (dir==="toDup" ? "center" : "right")
    var home = Quickshell.env("HOME")
    var path = home + "/.config/omarchy/shell.json"
    var py = ""
      + "import json,os,sys\n"
      + "p=os.path.expanduser('~/.config/omarchy/shell.json')\n"
      + "wid=sys.argv[1]; d=sys.argv[2]; dst=sys.argv[3]\n"
      + "import json as j\n"
      + "PID='io.github.kamal-v8.bar-squared'\n"
      + "cfg=j.load(open(p))\n"
      + "secs=['left','center','right']\n"
      + "def find_bar(cfg):\n"
      + "  lay=cfg.get('bar',{}).get('layout',{})\n"
      + "  for s in secs:\n"
      + "    arr=lay.get(s,[])\n"
      + "    for i,e in enumerate(arr):\n"
      + "      eid=e.get('id') if isinstance(e,dict) else str(e)\n"
      + "      if eid==PID: return (s,i)\n"
      + "  return (None,None)\n"
      + "def bar_obj(cfg):\n"
      + "  s,i=find_bar(cfg)\n"
      + "  if s is None: return None\n"
      + "  e=cfg['bar']['layout'][s][i]\n"
      + "  if not isinstance(e,dict):\n"
      + "    e={'id':PID}; cfg['bar']['layout'][s][i]=e\n"
      + "  return e\n"
      + "def plug_obj(cfg):\n"
      + "  for e in cfg.get('plugins',[]):\n"
      + "    if isinstance(e,dict) and e.get('id')==PID: return e\n"
      + "  return None\n"
      + "def dup_store(cfg, create=False):\n"
      + "  b=bar_obj(cfg)\n"
      + "  if b is not None:\n"
      + "    if 'layout' not in b or not isinstance(b['layout'],dict): b['layout']={'left':[],'center':[],'right':[]}\n"
      + "    for s in secs:\n"
      + "      if s not in b['layout'] or not isinstance(b['layout'][s],list): b['layout'][s]=[]\n"
      + "    return b\n"
      + "  pl=plug_obj(cfg)\n"
      + "  if pl is not None:\n"
      + "    if 'layout' not in pl or not isinstance(pl['layout'],dict): pl['layout']={'left':[],'center':[],'right':[]}\n"
      + "    for s in secs:\n"
      + "      if s not in pl['layout'] or not isinstance(pl['layout'][s],list): pl['layout'][s]=[]\n"
      + "    return pl\n"
      + "  if create:\n"
      + "    cfg.setdefault('bar',{}).setdefault('layout',{}).setdefault('right',[])\n"
      + "    nb={'id':PID,'layout':{'left':[],'center':[],'right':[]}}\n"
      + "    cfg['bar']['layout']['right'].append(nb)\n"
      + "    return nb\n"
      + "  return None\n"
      + "found=None; sec=''; idx=-1\n"
      + "if d=='toDup':\n"
      + "  lay=cfg.get('bar',{}).get('layout', {})\n"
      + "  for s in secs:\n"
      + "    arr=lay.get(s,[])\n"
      + "    for i,e in enumerate(arr):\n"
      + "      eid=e.get('id') if isinstance(e,dict) else str(e)\n"
      + "      if eid==wid:\n"
      + "        found=e; sec=s; idx=i; break\n"
      + "    if found is not None: break\n"
      + "  # Never move the Bar² control button into itself\n"
      + "  if found is not None and ((found.get('id') if isinstance(found,dict) else str(found))==PID):\n"
      + "    print('refuse self-move'); sys.exit(1)\n"
      + "  if found is None:\n"
      + "    print('not found '+wid); sys.exit(1)\n"
      + "  # remove (skip self id already refused)\n"
      + "  cfg['bar']['layout'][sec].pop(idx)\n"
      + "  dup=dup_store(cfg, create=True)\n"
      + "  dup['layout'][dst]=[e for e in dup['layout'][dst] if (e.get('id') if isinstance(e,dict) else str(e))!=wid]\n"
      + "  dup['layout'][dst].append(found)\n"
      + "  # Third-party widgets are only loadable when referenced from the\n"
      + "  # main bar or top-level plugins[]. A move to Bar² alone would unload\n"
      + "  # them (invisible 0-width slots), so keep a stub entry that keeps\n"
      + "  # the component registered while Bar² hosts the visible copy.\n"
      + "  if not wid.startswith('omarchy.'):\n"
      + "    has_stub=any(isinstance(e,dict) and e.get('id')==wid for e in cfg.get('plugins',[]))\n"
      + "    if not has_stub:\n"
      + "      cfg.setdefault('plugins',[]).append({'id':wid})\n"
      + "else:\n"
      + "  # toMain: find in dup (bar entry first, legacy plugins[] fallback)\n"
      + "  dup=dup_store(cfg, create=False)\n"
      + "  if dup is None: print('no dup'); sys.exit(1)\n"
      + "  lay=dup.get('layout', {})\n"
      + "  found=None; sec=''; idx=-1\n"
      + "  for s in secs:\n"
      + "    arr=lay.get(s,[])\n"
      + "    for i,e in enumerate(arr):\n"
      + "      eid=e.get('id') if isinstance(e,dict) else str(e)\n"
      + "      if eid==wid:\n"
      + "        found=e; sec=s; idx=i; break\n"
      + "    if found is not None: break\n"
      + "  if found is None:\n"
      + "    print('not found in dup '+wid); sys.exit(1)\n"
      + "  dup['layout'][sec].pop(idx)\n"
      + "  if 'bar' not in cfg: cfg['bar']={'layout':{'left':[],'center':[],'right':[]}}\n"
      + "  if 'layout' not in cfg['bar']: cfg['bar']['layout']={'left':[],'center':[],'right':[]}\n"
      + "  for s in secs:\n"
      + "    if s not in cfg['bar']['layout'] or not isinstance(cfg['bar']['layout'][s], list): cfg['bar']['layout'][s]=[]\n"
      + "  cfg['bar']['layout'][dst]=[e for e in cfg['bar']['layout'][dst] if (e.get('id') if isinstance(e,dict) else str(e))!=wid]\n"
      + "  cfg['bar']['layout'][dst].append(found)\n"
      + "  # Main-bar entry re-enables third-party widgets on its own; drop the\n"
      + "  # bare Bar² stub if we created one (keep stubs carrying settings).\n"
      + "  if not wid.startswith('omarchy.'):\n"
      + "    cfg['plugins']=[e for e in cfg.get('plugins',[]) if not (isinstance(e,dict) and e.get('id')==wid and set(e.keys())=={'id'})]\n"
      + "# Write-through mirror: bar entry layout -> plugins[] self-entry so a\n"
      + "# later one-click disable (which deletes the bar entry) still leaves\n"
      + "# the hosted layout for disableClean to return to the main bar.\n"
      + "b2=bar_obj(cfg)\n"
      + "if b2 is not None:\n"
      + "  me2=None\n"
      + "  for e in cfg.get('plugins',[]):\n"
      + "    if isinstance(e,dict) and e.get('id')==PID: me2=e; break\n"
      + "  if me2 is None:\n"
      + "    me2={'id':PID}; cfg.setdefault('plugins',[]).append(me2)\n"
      + "  me2['layout']=json.loads(json.dumps(b2.get('layout',{'left':[],'center':[],'right':[]}))) \n"
      + "tmp=p+'.tmp'\n"
      + "j.dump(cfg, open(tmp,'w'), indent=2)\n"
      + "import os as _os; _os.rename(tmp,p)\n"
      + "print('ok '+wid+' '+d+' '+dst)\n"
    fileMoveProc.command = ["python3","-c", py, wid, dir, dstSec]
    fileMoveProc.running = true
    return true
  }

  function moveFromMain(widgetId, targetSection) { return fileMove(widgetId, "toDup", targetSection) }
  function moveToMain(widgetId, targetSection) { return fileMove(widgetId, "toMain", targetSection) }

  // Reorder within the Bar² layout (used by the control panel's ↑/↓).
  // Swaps the entry with its neighbour in the same section; atomic file
  // edit like the other mutations so FileView picks it up.
  Process {
    id: dupOrderProc
    stdout: StdioCollector { id: dupOrderOut; waitForEnd: true }
    stderr: StdioCollector { id: dupOrderErr; waitForEnd: true }
    onExited: function(code){ if(code!==0) console.log("Bar² reorder failed "+code+" "+dupOrderOut.text+" "+dupOrderErr.text) }
  }
  function dupOrder(widgetId, dir) {
    var wid = canonical(widgetId)
    if (!wid) return false
    var d = Number(dir) < 0 ? "-1" : "1"
    var py = ""
      + "import json,os,sys\n"
      + "p=os.path.expanduser('~/.config/omarchy/shell.json')\n"
      + "wid=sys.argv[1]; d=int(sys.argv[2])\n"
      + "PID='io.github.kamal-v8.bar-squared'\n"
      + "cfg=json.load(open(p))\n"
      + "lay=None\n"
      + "bl=cfg.get('bar',{}).get('layout',{})\n"
      + "found_bar=False\n"
      + "for s in ['left','center','right']:\n"
      + "  for e in bl.get(s,[]):\n"
      + "    eid=e.get('id') if isinstance(e,dict) else str(e)\n"
      + "    if eid==PID and isinstance(e,dict) and isinstance(e.get('layout'),dict):\n"
      + "      lay=e.get('layout'); found_bar=True; break\n"
      + "  if found_bar: break\n"
      + "if lay is None:\n"
      + "  for e in cfg.get('plugins',[]):\n"
      + "    if isinstance(e,dict) and e.get('id')==PID:\n"
      + "      lay=e.get('layout',{}); break\n"
      + "if lay is None: print('no '+PID); sys.exit(1)\n"
      + "done=False\n"
      + "for s in ['left','center','right']:\n"
      + "  arr=lay.get(s,[])\n"
      + "  idx=-1\n"
      + "  for i,e in enumerate(arr):\n"
      + "    eid=e.get('id') if isinstance(e,dict) else str(e)\n"
      + "    if eid==wid: idx=i; break\n"
      + "  if idx!=-1:\n"
      + "    j=idx+d\n"
      + "    if 0<=j<len(arr):\n"
      + "      arr[idx],arr[j]=arr[j],arr[idx]\n"
      + "      print('ok '+wid+' '+s)\n"
      + "    else:\n"
      + "      print('edge '+wid+' '+s)\n"
      + "    done=True\n"
      + "    break\n"
      + "if not done: print('not found '+wid); sys.exit(1)\n"
      + "if found_bar:\n"
      + "  me=None\n"
      + "  for e in cfg.get('plugins',[]):\n"
      + "    if isinstance(e,dict) and e.get('id')==PID: me=e; break\n"
      + "  if me is None:\n"
      + "    me={'id':PID}; cfg.setdefault('plugins',[]).append(me)\n"
      + "  me['layout']=json.loads(json.dumps(lay))\n"
      + "tmp=p+'.tmp'; json.dump(cfg, open(tmp,'w'), indent=2); os.rename(tmp,p)\n"
    dupOrderProc.command = ["python3","-c", py, wid, d]
    dupOrderProc.running = true
    return true
  }

  // Cross-section move within the Bar² layout (used by the control panel's
  // section cycler). Pops the entry from its current section and appends it
  // to the destination section; atomic file edit like the other mutations
  // so FileView picks it up.
  Process {
    id: dupSectionProc
    stdout: StdioCollector { id: dupSectionOut; waitForEnd: true }
    stderr: StdioCollector { id: dupSectionErr; waitForEnd: true }
    onExited: function(code){ if(code!==0) console.log("Bar² section move failed "+code+" "+dupSectionOut.text+" "+dupSectionErr.text) }
  }
  function moveDupSection(widgetId, dstSection) {
    var wid = canonical(widgetId)
    if (!wid) return false
    var dst = /^(left|center|right)$/.test(String(dstSection)) ? String(dstSection) : "center"
    var home = Quickshell.env("HOME")
    var path = home + "/.config/omarchy/shell.json"
    var py = ""
      + "import json,os,sys\n"
      + "p=os.path.expanduser('~/.config/omarchy/shell.json')\n"
      + "wid=sys.argv[1]; dst=sys.argv[2] if len(sys.argv)>2 and sys.argv[2] in ['left','center','right'] else 'center'\n"
      + "PID='io.github.kamal-v8.bar-squared'\n"
      + "cfg=json.load(open(p))\n"
      + "secs=['left','center','right']\n"
      + "lay=None\n"
      + "bl=cfg.get('bar',{}).get('layout',{})\n"
      + "found_bar=False\n"
      + "for s in ['left','center','right']:\n"
      + "  for e in bl.get(s,[]):\n"
      + "    eid=e.get('id') if isinstance(e,dict) else str(e)\n"
      + "    if isinstance(e,dict) and eid==PID and isinstance(e.get('layout'),dict):\n"
      + "      lay=e.get('layout'); found_bar=True; break\n"
      + "  if found_bar: break\n"
      + "if lay is None:\n"
      + "  for e in cfg.get('plugins',[]):\n"
      + "    if isinstance(e,dict) and e.get('id')==PID and isinstance(e.get('layout'),dict):\n"
      + "      lay=e.get('layout'); break\n"
      + "if lay is None: print('no dup'); sys.exit(1)\n"
      + "for s in secs:\n"
      + "  if s not in lay or not isinstance(lay[s],list): lay[s]=[]\n"
      + "found=None\n"
      + "for s in secs:\n"
      + "  for i,e in enumerate(lay[s]):\n"
      + "    eid=e.get('id') if isinstance(e,dict) else str(e)\n"
      + "    if eid==wid:\n"
      + "      found=e; lay[s].pop(i); break\n"
      + "  if found is not None: break\n"
      + "if found is None:\n"
      + "  print('not found in dup '+wid); sys.exit(1)\n"
      + "lay[dst]=[e for e in lay[dst] if (e.get('id') if isinstance(e,dict) else str(e))!=wid]\n"
      + "lay[dst].append(found)\n"
      + "b2=None\n"
      + "for s in ['left','center','right']:\n"
      + "  for e in cfg.get('bar',{}).get('layout',{}).get(s,[]):\n"
      + "    eid=e.get('id') if isinstance(e,dict) else str(e)\n"
      + "    if eid==PID: b2=e; break\n"
      + "  if b2 is not None: break\n"
      + "if b2 is not None:\n"
      + "  me2=None\n"
      + "  for e in cfg.get('plugins',[]):\n"
      + "    if isinstance(e,dict) and e.get('id')==PID: me2=e; break\n"
      + "  if me2 is None:\n"
      + "    me2={'id':PID}; cfg.setdefault('plugins',[]).append(me2)\n"
      + "  me2['layout']=json.loads(json.dumps(lay))\n"
      + "tmp=p+'.tmp'; json.dump(cfg, open(tmp,'w'), indent=2); os.rename(tmp,p)\n"
      + "print('ok '+wid+' section '+dst)\n"
    dupSectionProc.command = ["python3","-c", py, wid, dst]
    dupSectionProc.running = true
    return true
  }

  // --- Single-entry lifecycle: migration + disable self-clean ---
  Process {
    id: migrateProc
    stdout: StdioCollector { id: migrateOut; waitForEnd: true }
    stderr: StdioCollector { id: migrateErr; waitForEnd: true }
    onExited: function(code){
      root._migrateBusy = false
      console.log("Bar² migrate exit " + code + " " + migrateOut.text + " " + migrateErr.text)
    }
  }
  // Legacy plugins[] store -> bar.layout entry (one-time). Copies
  // mode/position/width/height/radius/spacing/transparent/layout into a new
  // (or bare existing) bar entry. The plugins[] entry is KEPT as a
  // write-through mirror (see above): a one-click `plugin disable` deletes
  // the bar entry synchronously and would otherwise take the hosted layout
  // with it before this service could return widgets to the main bar.
  // Hosted third-party stubs are left alone.
  function migrateToBar() {
    if (root._migrateBusy) return
    root._migrateBusy = true
    var py = ""
      + "import json,os,sys\n"
      + "p=os.path.expanduser('~/.config/omarchy/shell.json')\n"
      + "PID='io.github.kamal-v8.bar-squared'\n"
      + "cfg=json.load(open(p))\n"
      + "bl=cfg.setdefault('bar',{}).setdefault('layout',{})\n"
      + "for s in ['left','center','right']:\n"
      + "  if s not in bl or not isinstance(bl[s],list): bl[s]=[]\n"
      + "bs,bi=None,None\n"
      + "for s in ['left','center','right']:\n"
      + "  for i,e in enumerate(bl[s]):\n"
      + "    eid=e.get('id') if isinstance(e,dict) else str(e)\n"
      + "    if eid==PID: bs,bi=s,i; break\n"
      + "  if bs is not None: break\n"
      + "pi=-1\n"
      + "for i,e in enumerate(cfg.get('plugins',[])):\n"
      + "  if isinstance(e,dict) and e.get('id')==PID: pi=i; break\n"
      + "print('bar=%s plug=%s' % (bs,pi))\n"
      + "if pi==-1: print('nothing to migrate'); sys.exit(0)\n"
      + "plug=cfg['plugins'][pi]\n"
      + "if bs is None:\n"
      + "  nb={'id':PID}\n"
      + "  for k in ['mode','position','width','height','radius','spacing','transparent','layout']:\n"
      + "    if k in plug: nb[k]=json.loads(json.dumps(plug[k]))\n"
      + "  bl['right'].append(nb)\n"
      + "  print('created bar entry (mirror kept)')\n"
      + "else:\n"
      + "  be=bl[bs][bi]\n"
      + "  if not isinstance(be,dict):\n"
      + "    be={'id':PID}; bl[bs][bi]=be\n"
      + "  if len(be.keys())<=1:\n"
      + "    for k in ['mode','position','width','height','radius','spacing','transparent','layout']:\n"
      + "      if k in plug and k not in be: be[k]=json.loads(json.dumps(plug[k]))\n"
      + "    print('merged into bare bar entry (mirror kept)')\n"
      + "  else:\n"
      + "    if not be.get('layout') and plug.get('layout'): be['layout']=json.loads(json.dumps(plug['layout']))\n"
      + "    print('bar entry already configured (mirror kept)')\n"
      + "tmp=p+'.tmp'; json.dump(cfg, open(tmp,'w'), indent=2); os.rename(tmp,p)\n"
      + "print('migrated')\n"
    migrateProc.command = ["python3","-c", py]
    migrateProc.running = true
  }
  Process {
    id: cleanProc
    stdout: StdioCollector { id: cleanOut; waitForEnd: true }
    stderr: StdioCollector { id: cleanErr; waitForEnd: true }
    onExited: function(code){
      root._cleanBusy = false
      console.log("Bar² disable-clean exit " + code + " " + cleanOut.text + " " + cleanErr.text)
    }
  }
  // `omarchy plugin disable` drops only the bar entry (core removes one
  // location per call). Finish the job: move hosted widgets back to the main
  // bar (same section, deduped), drop their bare stubs, delete the legacy
  // self-entry. Service then unloads (isEnabled=false) and the window hides.
  function disableClean() {
    if (root._cleanBusy) return
    root._cleanBusy = true
    root.stashDup()
    var stash = root._lastDupJson
    var py = ""
      + "import json,os,sys\n"
      + "p=os.path.expanduser('~/.config/omarchy/shell.json')\n"
      + "stash=json.loads(sys.argv[1] if len(sys.argv)>1 else '{\"left\":[],\"center\":[],\"right\":[]}')\n"
      + "PID='io.github.kamal-v8.bar-squared'\n"
      + "cfg=json.load(open(p))\n"
      + "bl=cfg.get('bar',{}).get('layout',{})\n"
      + "has_bar=any(((e.get('id') if isinstance(e,dict) else str(e))==PID) for s in ['left','center','right'] for e in bl.get(s,[]))\n"
      + "if has_bar: print('bar present, abort clean'); sys.exit(0)\n"
      + "pi=-1\n"
      + "for i,e in enumerate(cfg.get('plugins',[])):\n"
      + "  if isinstance(e,dict) and e.get('id')==PID: pi=i; break\n"
      + "lay={'left':[],'center':[],'right':[]}\n"
      + "if pi!=-1:\n"
      + "  plug=cfg['plugins'][pi]\n"
      + "  if isinstance(plug.get('layout'),dict): lay=plug.get('layout')\n"
      + "if not any(lay.get(s) for s in ['left','center','right']):\n"
      + "  lay=stash if isinstance(stash,dict) else lay\n"
      + "if pi==-1 and not any((lay.get(s) or []) for s in ['left','center','right']):\n"
      + "  print('nothing to return'); sys.exit(0)\n"
      + "cfg.setdefault('bar',{}).setdefault('layout',{})\n"
      + "ml=cfg['bar']['layout']\n"
      + "for s in ['left','center','right']:\n"
      + "  if s not in ml or not isinstance(ml[s],list): ml[s]=[]\n"
      + "moved=0\n"
      + "for s in ['left','center','right']:\n"
      + "  for it in lay.get(s,[]):\n"
      + "    wid=it.get('id') if isinstance(it,dict) else str(it)\n"
      + "    if not wid or wid==PID: continue\n"
      + "    ml[s]=[x for x in ml[s] if ((x.get('id') if isinstance(x,dict) else str(x))!=wid)]\n"
      + "    ml[s].append(it); moved+=1\n"
      + "    if not wid.startswith('omarchy.'):\n"
      + "      cfg['plugins']=[x for x in cfg.get('plugins',[]) if not (isinstance(x,dict) and x.get('id')==wid and set(x.keys())=={'id'})]\n"
      + "# Drop the legacy self-entry (comprehension: stub removals above may\n"
      + "# have shifted indices, so no positional pop).\n"
      + "cfg['plugins']=[x for x in cfg.get('plugins',[]) if not (isinstance(x,dict) and x.get('id')==PID)]\n"
      + "tmp=p+'.tmp'; json.dump(cfg, open(tmp,'w'), indent=2); os.rename(tmp,p)\n"
      + "print('cleaned moved=%d' % moved)\n"
    cleanProc.command = ["python3","-c", py, stash]
    cleanProc.running = true
  }

  QtObject {
    id: dupBarApi
    property color foreground: root.themeForeground
    property color barForeground: root.themeForeground
    property color background: root.themeBackground
    property color urgent: Color.urgent
    property string position: root.position
    property bool vertical: root.vertical
    property int barSize: root.storedHeight
    property bool transparent: root.transparent
    property string fontFamily: Style.font.family
    function run(cmd) { if (cmd) Util.execDetached(cmd) }
    // Main-bar API surface that widgets expect (tooltips, panels). Forward to
    // the real bar when available so hosted widgets don't throw TypeErrors.
    function showTooltip(target, text) {
      var b = root.shell && root.shell.bar ? root.shell.bar : null
      if (b && typeof b.showTooltip === "function") b.showTooltip(target, text)
    }
    function hideTooltip(target) {
      var b = root.shell && root.shell.bar ? root.shell.bar : null
      if (b && typeof b.hideTooltip === "function") b.hideTooltip(target)
    }
    function switchPanelFrom(owner, direction) {
      var b = root.shell && root.shell.bar ? root.shell.bar : null
      if (b && typeof b.switchPanelFrom === "function") return b.switchPanelFrom(owner, direction)
      return false
    }
    function moduleWidgets(id) {
      var b = root.shell && root.shell.bar ? root.shell.bar : null
      if (b && typeof b.moduleWidgets === "function") return b.moduleWidgets(id)
      return []
    }
  }

  readonly property var dragSource: shell && shell.bar && ("barDragSource" in shell.bar) ? shell.bar.barDragSource : null
  readonly property string dragSourceId: dragSource ? String(dragSource.moduleName || "") : ""

  IpcHandler {
    target: "io.github.kamal-v8.bar-squared"
    function ping(): string { return "ok" }
    function toggleMode(): string { root.setMode(""); return root.mode }
    function setMode(m: string): string { root.setMode(m); return root.mode }
    function setPosition(p: string): string { root.setPosition(p); return root.position }
    function setWidth(w: string): string { root.setWidth(w); return String(root.storedWidth) }
    function setHeight(h: string): string { root.fileSet("height", String(Math.max(20, Math.min(80, Math.round(Number(h) || 33))))); return String(root.storedHeight) }
    function setRadius(r: string): string { root.fileSet("radius", String(Math.max(0, Math.min(40, Math.round(Number(r) || 0))))); return String(root.storedRadius) }
    function setSpacing(s: string): string { root.fileSet("spacing", String(Math.max(0, Math.min(32, Math.round(Number(s) || 0))))); return String(root.storedSpacing) }
    function setTransparent(v: string): string { root.fileSet("transparent", v === "true" ? "true" : "false"); return v }
    function toggleTransparent(): string { root.fileSet("transparent", root.transparent ? "false" : "true"); return root.transparent ? "false" : "true" }
    function clear(): string { root.clearLayout(); return "ok" }
    function status(): string {
      var reg = root.barWidgetRegistry
      var regKeys = []
      try { if (reg && reg.widgets) regKeys = Object.keys(reg.widgets) } catch(e) {}
      var live = { left: root.liveLeft, center: root.liveCenter, right: root.liveRight }
      function ids(a){ var o=[]; try{ for(var i=0;i<(a||[]).length;i++){ var e=a[i]; o.push(e&&e.id?String(e.id):String(e)) } }catch(e2){} return o }
      return JSON.stringify({ mode: root.mode, position: root.position, width: root.storedWidth, floatingWidth: root.floatingWidth, vertical: root.vertical, barSize: root.barSize, barHeight: root.storedHeight, cornerRadius: root.storedRadius, spacing: root.storedSpacing, transparent: root.transparent, hasExplicitWidth: root.hasExplicitWidth, dockedShrunk: root.dockedShrunk, controlInMain: root.controlInMain, singleEntry: root.pluginEntry === null, layout: root.dupLayout, liveLayout: { left: ids(live.left), center: ids(live.center), right: ids(live.right) }, hasRegistry: !!reg, registryCount: regKeys.length, hasMenu: regKeys.indexOf("omarchy.menu") !== -1, hasShellMutate: shell && typeof shell.mutateShellConfig === "function" })
    }
    function moveFromMain(id: string, section: string): string { var ok=root.moveFromMain(id, section); return ok ? "ok" : "failed" }
    function moveToMain(id: string, section: string): string { var ok=root.moveToMain(id, section); return ok ? "ok" : "failed" }
    function moveWithinDup(id: string, dir: string): string { var ok=root.dupOrder(id, dir); return ok ? "ok" : "failed" }
    function moveDupSection(id: string, section: string): string { var ok=root.moveDupSection(id, section); return ok ? "ok" : "failed" }
  }

  Variants {
    model: Quickshell.screens
    delegate: Component {
      PanelWindow {
        id: win
        required property var modelData
        screen: modelData
        // Always reserve space so windows shrink above/below instead of
        // being hidden underneath. Floating no longer overlays windows.
        exclusionMode: ExclusionMode.Auto
        WlrLayershell.namespace: "bar-squared"
        WlrLayershell.layer: WlrLayer.Top
        // Window stays transparent so the rounded inner surface can actually
        // show curves: an opaque window rect would fill the corners behind
        // barSurface. barSurface below provides the background instead.
        color: "transparent"
        surfaceFormat.opaque: false
        // Hidden while empty, while all hosted entries are disabled, or while
        // the control button is off the main bar (one-click disable): a hidden
        // layer takes no exclusion, so no phantom pill reserves space. Gating
        // on controlInMain hides the second bar instantly on disable, even
        // before the async self-clean (return-to-main + drop legacy store)
        // finishes and unloads the service.
        visible: root.hasLiveWidgets && root.controlInMain
        readonly property bool isVertical: root.vertical
        // Horizontal windows always span the full edge, even when the visible
        // bar is shrunk (floating / docked-shrunk): hosted widgets' popups
        // (KeyboardPanel) derive the card's screen-x from the anchor's
        // position inside this window, so a narrowed window would shift
        // every popup left by the centering offset. The visible bar stays
        // centered via barSurface below; `mask` keeps the transparent
        // margins click-through so they never eat pointer input.
        mask: Region { item: barSurface }
        anchors {
          top: isVertical || root.position === "top" || ((root.mode === "floating" || root.dockedShrunk) && root.position === "top")
          bottom: isVertical || root.position === "bottom" || ((root.mode === "floating" || root.dockedShrunk) && root.position === "bottom")
          left: (isVertical && root.position === "left") || !isVertical
          right: (isVertical && root.position === "right") || !isVertical
        }
        implicitWidth: {
          if ((root.mode === "floating" || root.dockedShrunk) && !isVertical) return root.floatingWidth
          if (isVertical) return root.storedHeight
          return 0
        }
        implicitHeight: {
          if (root.mode === "floating" && isVertical) return root.floatingWidth
          if (!isVertical) return root.storedHeight
          return 0
        }
        Item {
          id: container
          anchors.fill: parent
          readonly property bool isFloating: root.mode === "floating"
          Rectangle {
            id: barSurface
            color: root.transparent ? "transparent" : root.themeBackground
            radius: Math.min(root.storedRadius, Math.min(width, height) / 2)
            border.width: (root.mode === "floating" && !root.transparent) ? 1 : 0
            border.color: (root.mode === "floating" && !root.transparent) ? Color.bar.text : "transparent"
            opacity: root.transparent ? 1.0 : (root.mode === "floating" ? 0.96 : 1.0)
            anchors.verticalCenter: parent.verticalCenter
            anchors.horizontalCenter: parent.horizontalCenter
            width: (root.mode === "floating" || root.dockedShrunk) ? (root.vertical ? root.storedHeight : Math.min(root.floatingWidth, parent.width - Style.gapsOut*2)) : parent.width
            height: root.mode === "floating" ? (root.vertical ? Math.min(root.floatingWidth, parent.height - Style.gapsOut*2) : root.storedHeight) : parent.height
            Item {
              id: contentArea
              anchors.fill: parent
              anchors.margins: root.mode === "floating" ? 1 : 0
              Loader {
                anchors.fill: parent
                sourceComponent: root.vertical ? verticalBar : horizontalBar
              }
              Component {
                id: horizontalBar
                Item {
                  anchors.fill: parent
                  Item {
                    id: hCenter
                    anchors.centerIn: parent
                    // Bound to the space between the side rows so wide center
                    // content truncates (clip) instead of painting over them.
                    width: Math.max(0, Math.min(centerRow.implicitWidth, parent.width - leftRow.width - rightRow.width - Style.space(8) * 2 - root.storedSpacing * 2))
                    height: parent.height
                    clip: true
                    Row {
                      id: centerRow
                      anchors.centerIn: parent
                      spacing: root.storedSpacing
                      Repeater {
                        model: root.liveCenter
                        delegate: DupSlot {
                          required property var modelData
                          entry: modelData
                          region: "center"
                        }
                      }
                    }
                  }
                  Row {
                    id: leftRow
                    anchors.left: parent.left
                    anchors.leftMargin: Style.space(8)
                    anchors.verticalCenter: parent.verticalCenter
                    clip: true
                    spacing: root.storedSpacing
                    Repeater {
                      model: root.liveLeft
                      delegate: DupSlot {
                        required property var modelData
                        entry: modelData
                        region: "left"
                      }
                    }
                  }
                  Row {
                    id: rightRow
                    anchors.right: parent.right
                    anchors.rightMargin: Style.space(8)
                    anchors.verticalCenter: parent.verticalCenter
                    clip: true
                    spacing: root.storedSpacing
                    Repeater {
                      model: root.liveRight
                      delegate: DupSlot {
                        required property var modelData
                        entry: modelData
                        region: "right"
                      }
                    }
                  }
                  // Bar is intentionally empty when no widgets — no hint text or controls (all controls are in the Bar² Control widget in the main bar)
                  Rectangle {
                    visible: root.dragSource !== null && root.dragSourceId !== "" && dropArea.containsDrag
                    anchors.centerIn: parent
                    width: parent.width * 0.5
                    height: parent.height - 6
                    radius: Style.cornerRadius
                    color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.14)
                    border.width: 1
                    border.color: Color.accent
                    opacity: 0.9
                    Text {
                      anchors.centerIn: parent
                      text: "Drop " + root.dragSourceId + " here"
                      color: Color.accent
                      font.family: Style.font.family
                      font.pixelSize: Style.font.bodySmall
                    }
                  }
                }
              }
              Component {
                id: verticalBar
                Item {
                  anchors.fill: parent
                  Column {
                    anchors.centerIn: parent
                    spacing: root.storedSpacing
                    Repeater {
                      model: root.liveCenter
                      delegate: DupSlot {
                        required property var modelData
                        entry: modelData
                        region: "center"
                      }
                    }
                  }
                  Column {
                    anchors.top: parent.top
                    anchors.topMargin: Style.space(8)
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: root.storedSpacing
                    Repeater {
                      model: root.liveLeft
                      delegate: DupSlot {
                        required property var modelData
                        entry: modelData
                        region: "left"
                      }
                    }
                  }
                  Column {
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: Style.space(8)
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: root.storedSpacing
                    Repeater {
                      model: root.liveRight
                      delegate: DupSlot {
                        required property var modelData
                        entry: modelData
                        region: "right"
                      }
                    }
                  }
                  // vertical bar is also empty when no widgets — no hint text or controls
                }
              }
            }
          }
          DropArea {
            id: dropArea
            anchors.fill: parent
            enabled: root.dragSource !== null && root.dragSourceId !== ""
            onEntered: function(drag){ drag.accepted = true }
            onDropped: function(drop){
              if (root.dragSourceId) {
                var wid = root.dragSourceId
                Qt.callLater(function(){ root.moveFromMain(wid, "center") })
              }
            }
          }
    MouseArea {
            anchors.fill: parent
            visible: root.dragSource !== null
            hoverEnabled: true
            propagateComposedEvents: true
            onReleased: {
              if (root.dragSourceId) {
                var wid = root.dragSourceId
                Qt.callLater(function(){ root.moveFromMain(wid, "center") })
              }
            }
            onPressed: function(mouse){ mouse.accepted = false }
            onClicked: function(mouse){ mouse.accepted = false }
          }
        }
      }
    }
  }

  component DupSlot: Item {
    id: slot
    required property var entry
    property string region: ""
    readonly property string moduleName: {
      var e = slot.entry
      if (typeof e === "string") return String(e)
      if (e && e.id) return String(e.id)
      return ""
    }
    readonly property var moduleSettings: {
      var e = slot.entry
      if (!e || typeof e !== "object") return {}
      var out={}
      for (var k in e) if (k!=="id") out[k]=e[k]
      return out
    }
    readonly property var registryEntry: {
      var r = root.barWidgetRegistry ? root.barWidgetRegistry.widgets : {}
      var key = String(slot.moduleName||"")
      return r[key] || null
    }
    readonly property var registryComponent: registryEntry ? registryEntry.component : null
    readonly property bool registered: registryComponent !== null
    // Unregistered (disabled) entries collapse instead of showing placeholder
    // text, so disabling the last widget empties and hides the bar.
    // NOTE: the slot itself must stay visible while registered and collapse
    // only via size (like the main bar's ModuleSlot). Mirroring the hosted
    // item's `visible` here deadlocks widgets that start hidden: QML
    // `visible` reads back *effective* visibility, so a hidden item keeps a
    // mirroring slot invisible, and the invisible slot in turn keeps the
    // item effectively invisible forever (dansmith888.gpu hides until GPU
    // detection finishes and never appeared). Size reads are safe — size
    // doesn't feed back into visibility.
    visible: slot.registered
    // Size from painted extents, not just implicitWidth: several widgets
    // under-report implicitWidth in a hosted context (async state/fonts at
    // load, onThisScreen-style guards, fixedWidth fallback branches), which
    // collapsed slots to ~20px while items painted ~70px wide — every widget
    // mashed together. The Loader's childrenRect measures what actually
    // paints, so floor the slot by it. Hidden items still collapse to 0.
    readonly property bool itemShown: loader.item !== null && loader.item.visible === true
    readonly property real paintedWidth: itemShown ? loader.childrenRect.width : 0
    readonly property real paintedHeight: itemShown ? loader.childrenRect.height : 0
    implicitWidth: !slot.registered ? 0 : (!loader.item ? fallbackText.implicitWidth + 16 : (!itemShown ? 0 : Math.max(loader.item.implicitWidth, paintedWidth, root.rememberedWidth(slot.moduleName))))
    implicitHeight: !slot.registered ? 0 : (!loader.item ? root.storedHeight : (!itemShown ? 0 : Math.max(loader.item.implicitHeight, paintedHeight)))
    width: implicitWidth
    height: implicitHeight
    onWidthChanged: { if (itemShown && width > 0) root.rememberWidth(slot.moduleName, width) }
    Loader {
      id: loader
      active: slot.registered
      sourceComponent: slot.registered ? slot.registryComponent : null
      anchors.centerIn: parent
      onLoaded: {
        var t = item
        console.log("Bar² slot loaded " + slot.moduleName + " iw=" + t.implicitWidth + " ih=" + t.implicitHeight + " vis=" + t.visible)
        if (t && "bar" in t) t.bar = dupBarApi
        if (t && "moduleName" in t) t.moduleName = slot.moduleName
        if (t && "settings" in t) t.settings = slot.moduleSettings
        console.log("Bar² slot injected " + slot.moduleName + " slotW=" + slot.width + " slotH=" + slot.height)
      }
    }
    Text {
      id: fallbackText
      visible: !slot.registered
      anchors.centerIn: parent
      text: slot.moduleName + " (off)"
      color: root.themeForeground
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      opacity: 0.6
    }
    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.RightButton
      hoverEnabled: true
      onClicked: function(mouse){
        if (mouse.button === Qt.RightButton) {
          root.moveToMain(slot.moduleName, "right")
        }
      }
    }
  }
}

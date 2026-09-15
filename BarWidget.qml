import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "LayoutModel.js" as Layout

// Hosts other bar widgets behind a chevron, in a strip that opens off the bar.
//
// The strip spans the bar's own screen edge and is as thick as the bar plus
// itself, because Ui/KeyboardPanel positions a widget's panel from the anchor's
// offset within its own window and that window's thickness. A smaller window
// puts every hosted widget's panel against the screen edge.
//
// Widgets in here must also be listed in shell.json's `plugins[]`, or
// PluginRegistry.isEnabled never builds them. absorb() and eject() maintain it.
BarWidget {
  id: root
  moduleName: "david.macnook"

  // Read `settings` directly, not through the base class's setting(): the host
  // assigns it after construction, and a binding that reaches it through a helper
  // call never re-evaluates when that lands.
  readonly property var itemsSetting: settings ? settings.items : null
  readonly property var entries: Layout.normalizeEntries(itemsSetting, moduleName)
  readonly property string trigger: settings && settings.trigger ? String(settings.trigger) : "hover"
  readonly property int animationDuration: settings && settings.duration !== undefined
    ? Math.max(0, Number(settings.duration)) : 180
  readonly property int hideAfterMs: {
    if (!settings || settings.hideAfter === undefined || settings.hideAfter === null
        || String(settings.hideAfter) === "")
      return 10000
    var n = Number(settings.hideAfter)
    if (!isFinite(n) || n < 0) return 10000
    return Math.round(n)
  }

  // Omarchy 4.0.3 injects a PluginBarApi facade with no widget registry, drag
  // state, or config writes. A first-party sibling still holds the real bar,
  // so take it from there. The host reassigns the facade on any settings or
  // registry change, hence onBarChanged.
  readonly property bool facadeBar: bar !== null && bar !== undefined
    && !("barWidgetRegistry" in bar)

  function findHostBar(item) {
    if (!item) return null
    // typeof first: `in` throws on a truthy non-object `bar` property.
    if ("bar" in item && item.bar && typeof item.bar === "object"
        && "barWidgetRegistry" in item.bar) return item.bar
    var kids = item.children
    for (var i = 0; i < kids.length; i++) {
      var found = findHostBar(kids[i])
      if (found) return found
    }
    return null
  }

  function adoptHostBar() {
    if (!facadeBar) return
    var found = findHostBar(barWindow ? barWindow.contentItem : null)
    if (found) bar = found
  }

  onBarChanged: {
    adoptAttempts = 0
    Qt.callLater(adoptHostBar)
  }

  // Covers siblings that load later; bounded so an all-facade bar is not
  // scanned forever.
  property int adoptAttempts: 0
  Timer {
    interval: 250
    repeat: true
    running: root.facadeBar && root.adoptAttempts < 40
    onTriggered: {
      root.adoptAttempts += 1
      root.adoptHostBar()
    }
  }

  readonly property var widgetRegistry: bar && bar.barWidgetRegistry ? bar.barWidgetRegistry.widgets : ({})
  readonly property var pluginRegistry: bar && bar.shell ? bar.shell.pluginRegistry : null

  readonly property var missingIds: {
    var registry = root.pluginRegistry
    var plugins = []
    for (var i = 0; i < root.entries.length; i++) {
      if (!root.customTypeOf(root.entries[i])) plugins.push(root.entries[i])
    }
    return Layout.missingIds(plugins, registry ? registry.installedPlugins : null,
      root.widgetRegistry, root.moduleName, registry ? registry.scanning : false)
  }

  readonly property var shellConfig: bar && bar.shell ? bar.shell.shellConfig : null

  // A transparent bar picks barForeground to contrast with the wallpaper, not
  // with this card, so the card stays on the theme and hosted widgets are
  // repainted to match it.
  readonly property color cardBackground: bar ? bar.background : Color.background
  readonly property color hostedForeground: bar && bar.themeForeground !== undefined
    ? bar.themeForeground : Color.foreground

  // The bar owns the rules for what counts as a custom module, so ask it.
  function customTypeOf(entry) {
    if (!bar || typeof bar.customModuleType !== "function") return ""
    return String(bar.customModuleType(entry) || "")
  }

  function customSourceOf(entry) {
    if (!bar || typeof bar.customModuleSource !== "function") return ""
    return String(bar.customModuleSource(entry) || "")
  }

  // A plugin that also ships a service reads plugins[] itself.
  function widgetOnly(id) {
    var installed = root.pluginRegistry ? root.pluginRegistry.installedPlugins : null
    var manifest = installed ? installed[id] : null
    var kinds = manifest ? manifest.kinds : null
    if (!kinds || kinds.length !== 1) return false
    return String(kinds[0]) === "bar-widget"
  }

  readonly property var strandedIds: {
    var config = root.shellConfig
    var plugins = null
    try { plugins = JSON.parse(JSON.stringify(config ? config.plugins : null)) } catch (e) { return [] }
    var hosted = []
    for (var i = 0; i < root.entries.length; i++) {
      if (root.widgetOnly(root.entries[i].id)) hosted.push(root.entries[i].id)
    }
    return Layout.strandedIds(plugins, hosted)
  }

  readonly property var ownSlot: {
    var slots = bar && bar.moduleSlots ? bar.moduleSlots : []
    for (var i = 0; i < slots.length; i++) {
      if (slots[i] && slots[i].activeItem === root) return slots[i]
    }
    return null
  }
  readonly property string region: ownSlot ? String(ownSlot.region || "") : ""
  readonly property bool reversed: region === "right"
  readonly property string barPosition: bar ? String(bar.position || "top") : "top"

  readonly property var barWindow: root.QsWindow.window
  readonly property real screenAlong: {
    var screen = barWindow ? barWindow.screen : null
    if (!screen) return 0
    return vertical ? screen.height : screen.width
  }

  property bool pointerInside: false
  property bool latched: false
  // A panel anchors to the widget that opened it, so hold the strip open or the
  // panel loses its anchor.
  property int openChildCount: 0

  readonly property bool pointerOnDrawer: pointerInside || cardHover.hovered
  readonly property bool hoverHeld: trigger === "hover" && !hoverSuppressed && pointerOnDrawer
  // The pointer is over neither while crossing from chevron to strip.
  property bool hoverGrace: false
  // Without this the hover under a closing click reopens it immediately.
  property bool hoverSuppressed: false

  onPointerOnDrawerChanged: if (!pointerOnDrawer) hoverSuppressed = false

  onHoverHeldChanged: {
    if (hoverHeld) {
      hoverGrace = true
      hoverGraceTimer.stop()
    } else {
      hoverGraceTimer.restart()
    }
  }

  Timer {
    id: hoverGraceTimer
    interval: 220
    onTriggered: root.hoverGrace = false
  }

  readonly property bool expanded: latched || openChildCount > 0 || dropHovered
    || draggingChild || hoverHeld || hoverGrace

  // Click-pin stays until hideAfterMs after the pointer leaves, unless a hosted
  // panel is open or a drag is in progress. 0 disables. Hover-open already
  // closes when the pointer leaves.
  readonly property bool autoHideArmed: hideAfterMs > 0 && latched
    && !pointerOnDrawer && openChildCount === 0 && !draggingChild && !dropHovered

  Timer {
    id: autoHideTimer
    interval: Math.max(1, root.hideAfterMs)
    running: root.autoHideArmed
    onTriggered: root.close()
  }

  property real revealProgress: expanded && entries.length > 0 ? 1 : 0
  Behavior on revealProgress {
    NumberAnimation { duration: root.animationDuration; easing.type: Easing.OutCubic }
  }
  readonly property bool revealed: revealProgress > 0.99

  // Keep the layer mapped after the first open. Binding PanelWindow.visible to
  // revealProgress unmaps the surface from the animation timer and reparents
  // hosted widgets onto another window; Qt then SIGSEGVs with
  // "Cannot use same item on different windows at the same time".
  property bool stripMapped: false

  function syncStripMapped() {
    if (root.entries.length === 0) {
      stripMapped = false
      return
    }
    if (root.expanded)
      stripMapped = true
  }

  implicitWidth: chevron.implicitWidth
  implicitHeight: chevron.implicitHeight

  function noteChildOpen(wasOpen, isOpen) {
    if (wasOpen === isOpen) return
    openChildCount = Math.max(0, openChildCount + (isOpen ? 1 : -1))
  }

  // Bar.findPanelWidget only routes `omarchy-shell shell summon/hide/toggle` to a
  // widget that reports all three, so without `opened` those are silent no-ops.
  readonly property bool opened: expanded

  function open() { latched = true }
  function close() { latched = false }
  function toggle() { latched = !latched }

  IpcHandler {
    target: "david.macnook"

    // One bar surface per monitor, so state changes go to every instance. Config
    // writes do not: shell.json is shared and one write is the whole change.
    function open(): void { root.broadcast("open") }
    function close(): void { root.broadcast("close") }
    function toggle(): void { root.broadcast("toggle") }
    function absorb(id: string): void { root.absorb(id, -1) }
    function eject(id: string): void { root.eject(id) }
    function reorder(from: string, to: string): void { root.reorder(Number(from), Number(to)) }

    function status(): string {
      return JSON.stringify({
        trigger: root.trigger,
        hoverHeld: root.hoverHeld,
        latched: root.latched,
        expanded: root.expanded,
        pointerOnDrawer: root.pointerOnDrawer,
        hoverSuppressed: root.hoverSuppressed,
        openChildren: root.openChildCount,
        hideAfter: root.hideAfterMs,
        autoHideArmed: root.autoHideArmed,
        items: root.entries.length,
        overflowing: root.overflowing
      })
    }
  }

  readonly property real stripThickness: barSize + cardPadding * 2
  readonly property real cardPadding: Style.space(4)
  readonly property real cardMargin: Style.gapsOut

  // On a notched Apple panel the bar window is taller than Style.bar.size
  // (see Bar.qml notchFloor). The strip must clear that full window, not the
  // icon row, or the drawer sits inside the camera cutout. Sit flush against
  // the bar — no extra gap.
  readonly property real barThickness: {
    var measured = 0
    if (barWindow)
      measured = vertical ? barWindow.width : barWindow.height
    return Math.max(barSize, measured)
  }

  readonly property real contentExtent: vertical ? itemsFlow.implicitHeight : itemsFlow.implicitWidth
  readonly property real cardExtent: Math.max(chevronExtent,
    Math.min(contentExtent + cardPadding * 2, Math.max(0, screenAlong - cardMargin * 2)))
  readonly property real chevronExtent: vertical ? chevron.implicitHeight : chevron.implicitWidth
  readonly property real stripExtent: cardExtent - cardPadding * 2

  readonly property real maxScroll: Math.max(0, contentExtent - stripExtent)
  readonly property bool overflowing: maxScroll > 0.5
  property real scrollOffset: 0

  onMaxScrollChanged: scrollOffset = Math.max(0, Math.min(scrollOffset, maxScroll))
  onExpandedChanged: {
    if (!expanded) scrollOffset = 0
    root.syncStripMapped()
  }

  function scrollBy(amount) {
    if (!overflowing) return
    scrollOffset = Math.max(0, Math.min(scrollOffset + amount, maxScroll))
  }

  TransformWatcher {
    id: chevronWatcher
    a: root.barWindow ? root.barWindow.contentItem : null
    b: chevron
  }

  // The bar window spans its edge from the corner, so a position in its content
  // space is already a screen position along that axis, which is the space the
  // strip uses too. That is why one number addresses both windows.
  readonly property real chevronAlong: {
    chevronWatcher.transform
    if (!chevron || !barWindow) return 0
    var point = chevron.mapToItem(barWindow.contentItem, 0, 0)
    return vertical ? point.y : point.x
  }

  readonly property real cardAlong: {
    var wanted = reversed ? chevronAlong + chevronExtent - cardExtent : chevronAlong
    var limit = Math.max(cardMargin, screenAlong - cardExtent - cardMargin)
    return Math.round(Math.max(cardMargin, Math.min(wanted, limit)))
  }

  property var cells: []

  onEntriesChanged: {
    cells = []
    root.syncStripMapped()
  }

  function setCell(index, cell) {
    var next = cells.slice()
    while (next.length <= index) next.push(null)
    next[index] = cell
    cells = next
  }

  function clearCell(cell) {
    var next = cells.slice()
    for (var i = 0; i < next.length; i++) {
      if (next[i] === cell) next[i] = null
    }
    cells = next
  }

  // `along` is a screen position on the bar axis, valid in either window.
  function insertionIndexAt(along) {
    for (var i = 0; i < cells.length; i++) {
      var cell = cells[i]
      if (!cell || cell.width <= 0 || cell.height <= 0) continue
      var point = cell.mapToItem(null, 0, 0)
      var start = vertical ? point.y : point.x
      var middle = start + (vertical ? cell.height : cell.width) / 2
      if (along < middle) return i
    }
    return entries.length
  }

  readonly property bool dragActive: bar && "barDragSource" in bar
    && bar.barDragSource !== null
    && bar.barDragSource !== ownSlot && !draggingChild
  // Without this both monitors' drawers would light up.
  readonly property bool dragInThisWindow: dragActive && !!bar.barDragWindow
    && barWindow === bar.barDragWindow
  readonly property point dragPoint: dragInThisWindow
    ? root.mapFromItem(null, bar.barDragSceneX, bar.barDragSceneY) : Qt.point(-1, -1)
  readonly property bool dropOnChevron: dragInThisWindow
    && dragPoint.x >= 0 && dragPoint.x <= width
    && dragPoint.y >= 0 && dragPoint.y <= height
  readonly property bool dropOnCard: dragInThisWindow && revealProgress > 0.01
    && withinCard(bar.barDragSceneX, bar.barDragSceneY)
  readonly property bool dropHovered: dropOnChevron || dropOnCard

  // Across the bar axis, anything past the bar's thickness is over the strip.
  function withinCard(sceneX, sceneY) {
    if (!barWindow) return false
    var along = vertical ? sceneY : sceneX
    var across = vertical ? sceneX : sceneY
    var barThickness = vertical ? barWindow.width : barWindow.height
    var pastBar = barPosition === "top" || barPosition === "left"
      ? across > barThickness
      : across < 0
    return pastBar && along >= cardAlong && along <= cardAlong + cardExtent
  }

  property string armedId: ""
  property int armedIndex: -1

  onDropHoveredChanged: {
    if (!bar) return
    if (dropHovered) {
      armedId = dragSourceId()
    } else if (bar.barDragSource) {
      armedId = ""
      armedIndex = -1
      caretIndex = -1
    }
  }

  // Over the card the pointer has left the bar window, so `barDragTarget` never
  // changes and the handler watching it never fires.
  onDragPointChanged: {
    if (!dropOnCard || !bar) return
    armedIndex = insertionIndexAt(vertical ? bar.barDragSceneY : bar.barDragSceneX)
    caretIndex = armedIndex
  }

  function dragSourceId() {
    var source = bar ? bar.barDragSource : null
    var id = source ? String(source.moduleName || "") : ""
    // Never swallow this drawer, or a second drawer that shares its id.
    if (!id || id === moduleName) return ""
    return id
  }

  Connections {
    target: root.bar && "barDragSource" in root.bar ? root.bar : null

    // Null the bar's target so its release is a no-op. ModuleSlot.onReleased reads
    // it into a local before clearBarDrag(), and the bar's write is synchronous:
    // it reassigns layoutConfig, rebuilding every widget on every monitor, this one
    // included. Watches the target rather than the pointer because Bar.qml sets
    // barDragSceneX first and the target a few lines later.
    // Bar.qml commits its own reorder and knows nothing about drawers, so a drop
    // here would only park the entry beside the chevron.
    function onBarDragTargetChanged() {
      if (!root.dropHovered || !root.bar || root.bar.barDragTarget === null) return
      root.armedIndex = root.dropOnCard
        ? root.insertionIndexAt(root.vertical ? root.bar.barDragSceneY : root.bar.barDragSceneX)
        : -1
      root.caretIndex = root.armedIndex
      root.bar.barDragTarget = null
    }

    // Release and cancel look identical here, so an abandoned drag lands.
    function onBarDragSourceChanged() {
      if (!root.bar || root.bar.barDragSource) return
      var id = root.armedId
      var index = root.armedIndex
      root.armedId = ""
      root.armedIndex = -1
      root.caretIndex = -1
      if (id) root.absorb(id, index)
    }
  }

  property int draggingIndex: -1
  property int caretIndex: -1
  property bool draggingOutside: false

  readonly property bool draggingChild: draggingIndex >= 0

  function beginChildDrag(cell) {
    if (!cell) return
    draggingIndex = cell.index
    caretIndex = -1
    draggingOutside = false
  }

  // The card's edge is flush against the bar, so testing the card's rectangle
  // turned a reorder that drifted a pixel up into an eject. Ejecting means
  // putting the widget back on the bar, so only a deliberate move onto the bar
  // counts. Overshooting the ends is still a reorder: insertionIndexAt clamps.
  // Style.space scales independently of barSize and can outgrow a slim bar,
  // leaving no eject band.
  readonly property real ejectMargin: Math.min(Style.space(10), barSize / 2)

  function draggedOntoBar(scenePoint) {
    var across = vertical ? scenePoint.x : scenePoint.y
    var start = vertical ? cardArea.x : cardArea.y
    var end = start + (vertical ? cardArea.width : cardArea.height)
    return barPosition === "top" || barPosition === "left"
      ? across < start - ejectMargin
      : across > end + ejectMargin
  }

  function updateChildDrag(scenePoint) {
    draggingOutside = draggedOntoBar(scenePoint)
    caretIndex = draggingOutside ? -1 : insertionIndexAt(vertical ? scenePoint.y : scenePoint.x)
  }

  function endChildDrag() {
    var from = draggingIndex
    var caret = caretIndex
    var outside = draggingOutside
    var entry = from >= 0 && from < entries.length ? entries[from] : null

    cancelChildDrag()
    if (!entry) return

    if (outside) eject(entry.id)
    else if (caret >= 0) reorder(from, caret)
  }

  function cancelChildDrag() {
    draggingIndex = -1
    caretIndex = -1
    draggingOutside = false
  }

  function mutate(change) {
    var host = bar && bar.shell ? bar.shell : null
    if (!host || typeof host.mutateShellConfig !== "function") return
    host.mutateShellConfig(function(config) {
      if (!Util.isPlainObject(config.bar) || !Util.isPlainObject(config.bar.layout)) return
      change(config)
    })
  }

  // -1 appends.
  function absorb(id, index) {
    var plugin = !root.customTypeOf(root.entryOnBar(id))
    mutate(function(config) { Layout.absorb(config, root.moduleName, id, index, plugin) })
  }

  function entryOnBar(id) {
    var layout = bar && bar.layoutConfig ? bar.layoutConfig : null
    if (!layout) return null
    var sections = ["left", "center", "right"]
    for (var s = 0; s < sections.length; s++) {
      var list = layout[sections[s]]
      if (!list) continue
      for (var i = 0; i < list.length; i++) {
        if (Layout.entryIdOf(list[i]) === id) return list[i]
      }
    }
    return null
  }

  function eject(id) {
    mutate(function(config) { Layout.eject(config, root.moduleName, id, root.widgetOnly(id)) })
  }

  function reorder(from, to) {
    mutate(function(config) { Layout.reorder(config, root.moduleName, from, to) })
  }

  // Both jobs in one write: config refreshes only after a write.
  function reconcile(gone, stranded) {
    mutate(function(config) { Layout.reconcile(config, root.moduleName, gone, stranded) })
  }

  readonly property bool configWriter: {
    var peers = bar && typeof bar.moduleWidgets === "function" ? bar.moduleWidgets(moduleName) : []
    return peers.length === 0 || peers[0] === root
  }

  // A reload rebuilds the registries in steps. Wait before pruning.
  readonly property int settleDelay: 1500
  property real missingSince: 0

  onMissingIdsChanged: {
    missingSince = missingIds.length === 0 ? 0 : (missingSince || Date.now())
    reconcileTimer.restart()
  }
  onStrandedIdsChanged: if (strandedIds.length > 0) reconcileTimer.restart()
  Component.onCompleted: {
    root.syncStripMapped()
    if (missingIds.length > 0 || strandedIds.length > 0) reconcileTimer.restart()
  }

  Timer {
    id: reconcileTimer
    interval: 250
    onTriggered: {
      if (!root.configWriter) return
      var waiting = root.missingSince > 0
      var ripe = waiting && Date.now() - root.missingSince >= root.settleDelay
      var gone = ripe ? root.missingIds : []
      if (gone.length > 0 || root.strandedIds.length > 0)
        root.reconcile(gone, root.strandedIds)
      if (waiting && !ripe) restart()
    }
  }

  HoverHandler {
    id: drawerHover
    onHoveredChanged: root.pointerInside = hovered
  }

  // Bar.moduleClickTargetAt maps clicks into every registered target's geometry,
  // across windows, and takes the last registered. Re-registering the chevron
  // after the strip's widgets keeps it first in that scan.
  function claimChevronClicks() {
    if (!bar || typeof bar.unregisterClickTarget !== "function") return
    bar.unregisterClickTarget(chevron)
    bar.registerClickTarget(chevron)
  }

  onCellsChanged: Qt.callLater(claimChevronClicks)
  onRevealedChanged: if (revealed) Qt.callLater(claimChevronClicks)

  WidgetButton {
    id: chevron
    anchors.fill: parent
    bar: root.bar
    text: {
      var away = root.barPosition === "top" ? ""
        : root.barPosition === "bottom" ? ""
        : root.barPosition === "left" ? "" : ""
      var back = root.barPosition === "top" ? ""
        : root.barPosition === "bottom" ? ""
        : root.barPosition === "left" ? "" : ""
      return root.expanded ? back : away
    }
    active: root.dropHovered || root.expanded
    activeColor: Color.accent
    // The tooltip bubble renders under the chevron exactly where the open
    // drawer sits, so it overlaps the hosted widgets. It is redundant anyway:
    // opening the tray is what shows what is inside.
    tooltipText: ""
    // Tests `latched`, not `expanded`: hovering already makes it expanded, so
    // branching on that meant a click could only ever close it.
    onPressed: function(button) {
      if (button === Qt.RightButton) return
      if (root.latched) {
        root.latched = false
        root.hoverSuppressed = true
        root.hoverGrace = false
        hoverGraceTimer.stop()
      } else {
        root.latched = true
      }
    }
  }

  PanelWindow {
    id: strip

    screen: root.barWindow ? root.barWindow.screen : null
    visible: root.stripMapped
    color: "transparent"
    surfaceFormat.opaque: false
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "macnook"
    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    anchors {
      top: root.barPosition === "top" || root.vertical
      bottom: root.barPosition === "bottom" || root.vertical
      left: root.barPosition === "left" || !root.vertical
      right: root.barPosition === "right" || !root.vertical
    }

    implicitWidth: root.vertical ? root.barThickness + root.stripThickness : 0
    implicitHeight: root.vertical ? 0 : root.barThickness + root.stripThickness

    // Only the card takes input, or the stretch over the bar would swallow its
    // clicks. Spelled out rather than `Region { item: cardArea }`: the item form
    // snapshots geometry, and the card moves after the window exists.
    // Except while dragging: motion stops at the input region's edge, hiding the
    // move onto the bar that means eject. Closed (revealProgress ~ 0) uses an
    // empty region so the mapped-but-hidden layer does not eat bar clicks.
    mask: Region {
      x: root.draggingChild ? 0 : Math.round(cardArea.x)
      y: root.draggingChild ? 0 : Math.round(cardArea.y)
      width: (root.draggingChild || root.revealProgress > 0.01)
        ? (root.draggingChild ? strip.width : Math.ceil(cardArea.width)) : 0
      height: (root.draggingChild || root.revealProgress > 0.01)
        ? (root.draggingChild ? strip.height : Math.ceil(cardArea.height)) : 0
    }

    Item {
      id: cardArea

      readonly property real acrossOffset: root.barPosition === "top" || root.barPosition === "left"
        ? root.barThickness : 0

      x: root.vertical ? acrossOffset : root.cardAlong
      y: root.vertical ? root.cardAlong : acrossOffset
      width: root.vertical ? root.stripThickness : root.cardExtent
      height: root.vertical ? root.cardExtent : root.stripThickness

      readonly property real hiddenShift: root.barPosition === "top" || root.barPosition === "left"
        ? -root.stripThickness : root.stripThickness
      transform: Translate {
        x: root.vertical ? cardArea.hiddenShift * (1 - root.revealProgress) : 0
        y: root.vertical ? 0 : cardArea.hiddenShift * (1 - root.revealProgress)
      }
      opacity: root.revealProgress

      HoverHandler { id: cardHover }

      WheelHandler {
        enabled: root.overflowing
        target: null
        onWheel: function(event) {
          root.scrollBy(-event.angleDelta.y / 3)
          event.accepted = true
        }
      }

      readonly property int edgeDirection: {
        if (!root.overflowing || !cardHover.hovered) return 0
        var position = root.vertical ? cardHover.point.position.y : cardHover.point.position.x
        var extent = root.vertical ? height : width
        if (extent <= 0) return 0
        var margin = Math.max(Style.space(12), extent * 0.18)
        if (position < margin) return -1
        if (position > extent - margin) return 1
        return 0
      }

      Timer {
        running: cardArea.edgeDirection !== 0
        repeat: true
        interval: 16
        onTriggered: root.scrollBy(cardArea.edgeDirection * Style.space(3))
      }

      BorderSurface {
        anchors.fill: parent
        color: root.cardBackground
        borderSpec: Border.none()
        radius: Style.cornerRadius
      }

      Item {
        id: cardClip
        anchors.fill: parent
        anchors.margins: root.cardPadding
        clip: true

        Row {
          id: itemsRow
          visible: !root.vertical
          spacing: 0
          x: -root.scrollOffset
          anchors.verticalCenter: parent.verticalCenter

          Repeater {
            model: root.vertical ? [] : root.entries
            DrawerItem {
              required property var modelData
              required property int index
              drawer: root
              entry: modelData
              position: index
            }
          }
        }

        Column {
          id: itemsColumn
          visible: root.vertical
          spacing: 0
          y: -root.scrollOffset
          anchors.horizontalCenter: parent.horizontalCenter

          Repeater {
            model: root.vertical ? root.entries : []
            DrawerItem {
              required property var modelData
              required property int index
              drawer: root
              entry: modelData
              position: index
            }
          }
        }

        Rectangle {
          readonly property var target: root.caretIndex >= 0 && root.caretIndex < root.cells.length
            ? root.cells[root.caretIndex] : null
          readonly property var trailing: root.cells.length > 0 ? root.cells[root.cells.length - 1] : null
          readonly property var anchorCell: target ? target : trailing
          readonly property bool atEnd: target === null

          visible: opacity > 0
          opacity: root.caretIndex >= 0 && anchorCell ? 0.9 : 0
          color: Color.accent
          radius: Math.min(width, height) / 2
          width: root.vertical ? (anchorCell ? anchorCell.width : 0) : Style.spacing.xs
          height: root.vertical ? Style.spacing.xs : (anchorCell ? anchorCell.height : 0)
          x: {
            if (!anchorCell) return 0
            var point = anchorCell.mapToItem(parent, 0, 0)
            if (root.vertical) return point.x
            return Math.round(point.x + (atEnd ? anchorCell.width : 0) - width / 2)
          }
          y: {
            if (!anchorCell) return 0
            var point = anchorCell.mapToItem(parent, 0, 0)
            if (!root.vertical) return point.y
            return Math.round(point.y + (atEnd ? anchorCell.height : 0) - height / 2)
          }

          Behavior on x { NumberAnimation { duration: 90; easing.type: Easing.OutCubic } }
          Behavior on y { NumberAnimation { duration: 90; easing.type: Easing.OutCubic } }
          Behavior on opacity { NumberAnimation { duration: 90 } }
        }

        Repeater {
          model: 2

          Rectangle {
            required property int index
            readonly property bool leading: index === 0
            readonly property bool moreThisWay: leading
              ? root.scrollOffset > 0.5
              : root.scrollOffset < root.maxScroll - 0.5
            readonly property real thickness: Style.space(14)
            readonly property color cardBackground: root.cardBackground

            visible: opacity > 0
            opacity: root.overflowing && moreThisWay ? 1 : 0
            z: 40

            width: root.vertical ? parent.width : thickness
            height: root.vertical ? thickness : parent.height
            x: root.vertical ? 0 : (leading ? 0 : parent.width - thickness)
            y: root.vertical ? (leading ? 0 : parent.height - thickness) : 0

            gradient: Gradient {
              orientation: root.vertical ? Gradient.Vertical : Gradient.Horizontal
              GradientStop { position: 0; color: leading ? cardBackground : "transparent" }
              GradientStop { position: 1; color: leading ? "transparent" : cardBackground }
            }

            Behavior on opacity { NumberAnimation { duration: 120 } }
          }
        }
      }
    }
  }

  readonly property var itemsFlow: vertical ? itemsColumn : itemsRow
}

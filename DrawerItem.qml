import QtQuick
import qs.Commons
import qs.Ui

Item {
  id: cell

  required property var drawer
  required property var entry
  required property int position

  // Captured: during teardown `drawer` is gone before these destruction handlers run.
  readonly property var owner: drawer
  readonly property var host: drawer.bar
  readonly property int index: position

  // The Repeater hands entries over as QVariant maps, whose keys a plain for-in
  // does not enumerate. A JSON round-trip makes them ordinary objects again.
  readonly property var plainEntry: entry ? JSON.parse(JSON.stringify(entry)) : ({})
  readonly property string childId: String(plainEntry.id || "")
  readonly property var childSettings: {
    var copy = ({})
    for (var key in plainEntry) {
      if (key !== "id") copy[key] = plainEntry[key]
    }
    return copy
  }
  // "command" for an `exec` entry, "qml" for a `source` one, "" for a plugin.
  readonly property string customType: drawer.customTypeOf(cell.entry)
  readonly property bool custom: customType !== ""

  // Reading `widgetRegistry` is what makes this re-evaluate when a plugin is
  // enabled, disabled, or reloaded from disk.
  readonly property var childComponent: {
    if (cell.customType === "command") return commandModule
    if (cell.customType === "qml") return null
    var widgets = drawer.widgetRegistry
    var registered = widgets && widgets[cell.childId] ? widgets[cell.childId] : null
    return registered ? registered.component : null
  }
  readonly property var childItem: cell.customType === "qml" ? qmlLoader.item : childLoader.item
  readonly property bool dragSource: drawer.draggingIndex === cell.index

  // Uninstalled: take up no room while the removal is written out.
  readonly property bool uninstalled: !cell.custom && drawer.missingIds.indexOf(cell.childId) !== -1

  // Last known "this widget wants to be on the bar" size. Start assuming
  // shown so a failed first measure cannot empty the drawer; the first
  // open corrects widgets that really set visible:false.
  property bool hostedShown: true
  property real hostedExtent: Style.bar.iconSlot

  function hostLoaderVisible() {
    return cell.customType === "qml" ? qmlLoader.visible : childLoader.visible
  }

  function syncHostedMetrics() {
    if (cell.uninstalled) {
      hostedShown = false
      hostedExtent = 0
      return
    }
    var item = cell.childItem
    if (!item) {
      var placeholder = !cell.custom && cell.childComponent === null
      hostedShown = placeholder
      hostedExtent = placeholder ? Style.bar.iconSlot : 0
      return
    }
    // Item.visible is effective visibility. While the loader is hidden
    // (drawer shut) every child reads as false — ignore that.
    if (!cell.hostLoaderVisible())
      return
    if (item.visible === false) {
      hostedShown = false
      hostedExtent = 0
      return
    }
    hostedShown = true
    var natural = drawer.vertical ? item.implicitHeight : item.implicitWidth
    if (natural > 0)
      hostedExtent = natural
  }

  Connections {
    target: cell.childItem
    enabled: cell.hostLoaderVisible()
    function onVisibleChanged() { cell.syncHostedMetrics() }
    function onImplicitWidthChanged() { cell.syncHostedMetrics() }
    function onImplicitHeightChanged() { cell.syncHostedMetrics() }
  }

  onUninstalledChanged: cell.syncHostedMetrics()
  onChildComponentChanged: cell.syncHostedMetrics()

  Timer {
    id: metricsAfterReveal
    interval: 1
    onTriggered: cell.syncHostedMetrics()
  }

  implicitWidth: hostedShown ? (drawer.vertical ? drawer.barSize : hostedExtent) : 0
  implicitHeight: hostedShown ? (drawer.vertical ? hostedExtent : drawer.barSize) : 0
  width: implicitWidth
  height: implicitHeight
  clip: true

  Component.onCompleted: {
    drawer.setCell(cell.index, cell)
    cell.syncHostedMetrics()
  }
  // A reused delegate never runs onCompleted again.
  onPositionChanged: drawer.setCell(cell.index, cell)

  // QML hands back an error object, not null, for a parent that is already gone,
  // so a plain truth test is not enough to know the call is safe.
  Component.onDestruction: {
    if (owner && typeof owner.clearCell === "function") owner.clearCell(cell)
    if (childOpen && owner && typeof owner.noteChildOpen === "function") owner.noteChildOpen(true, false)
    // A cell destroyed mid-drag never reports the drag ending.
    if (owner && typeof owner.cancelChildDrag === "function" && owner.draggingIndex === cell.index)
      owner.cancelChildDrag()
  }

  function inject() {
    var target = childItem
    if (!target) return
    if ("bar" in target) target.bar = cell.host
    if ("entry" in target) target.entry = cell.plainEntry
    if ("moduleName" in target) target.moduleName = cell.childId
    if ("settings" in target) target.settings = cell.childSettings
  }

  // Ui/WidgetButton and the icons it loads take their colour from
  // bar.barForeground. Rebind that to the colour the card is painted
  // against, and only where it is still the bar's colour, so a widget that
  // chose its own is left alone. Qt.binding, not a value, so it still
  // follows the theme. A readonly property cannot be rebound and keeps the
  // bar's colour.
  function paintForTheCard(item) {
    if (!item || !drawer.bar) return
    if (Qt.colorEqual(drawer.bar.barForeground, drawer.hostedForeground)) return
    if ("foreground" in item) {
      try {
        if (Qt.colorEqual(item.foreground, drawer.bar.barForeground))
          item.foreground = Qt.binding(function() { return drawer.hostedForeground })
      } catch (e) {
      }
    }
    var kids = item.children
    for (var i = 0; i < kids.length; i++) cell.paintForTheCard(kids[i])
  }

  onChildSettingsChanged: inject()
  onHostChanged: inject()

  property bool childOpen: childItem && childItem.opened === true
  onChildOpenChanged: drawer.noteChildOpen(!childOpen, childOpen)

  Loader {
    id: qmlLoader
    anchors.fill: parent
    active: cell.customType === "qml"
    source: cell.customType === "qml" ? drawer.customSourceOf(cell.entry) : ""
    visible: drawer.revealProgress > 0.01
    opacity: cell.dragSource ? (drawer.draggingOutside ? 0.12 : 0.3) : 1.0
    onVisibleChanged: if (visible) {
      Qt.callLater(function() { cell.paintForTheCard(cell.childItem) })
      metricsAfterReveal.restart()
    }
    onLoaded: {
      cell.inject()
      Qt.callLater(cell.inject)
      Qt.callLater(function() { cell.paintForTheCard(cell.childItem) })
      Qt.callLater(cell.syncHostedMetrics)
    }
  }

  Loader {
    id: childLoader
    anchors.fill: parent
    active: cell.customType !== "qml"
    sourceComponent: cell.childComponent
    // An icon loaded from a Component does not exist until the strip is
    // drawn, so catch it on the way in as well.
    onVisibleChanged: if (visible) {
      Qt.callLater(function() { cell.paintForTheCard(cell.childItem) })
      metricsAfterReveal.restart()
    }

    // Every WidgetButton here registers in `bar.clickTargets`, which
    // Bar.moduleClickTargetAt scans across windows with no idea the strip is shut.
    // It skips targets whose `visible` is false.
    visible: drawer.revealProgress > 0.01
    opacity: cell.dragSource ? (drawer.draggingOutside ? 0.12 : 0.3) : 1.0
    onLoaded: {
      cell.inject()
      Qt.callLater(cell.inject)
      Qt.callLater(function() { cell.paintForTheCard(cell.childItem) })
      Qt.callLater(cell.syncHostedMetrics)
    }

    Behavior on opacity { NumberAnimation { duration: 90 } }
  }

  Text {
    anchors.centerIn: parent
    visible: !cell.custom && cell.childComponent === null && !cell.uninstalled
      && drawer.revealProgress > 0.01
    text: ""
    font.family: cell.host ? cell.host.fontFamily : Style.font.family
    font.pixelSize: Style.font.body
    color: cell.host ? cell.host.barForeground : Color.foreground
    opacity: 0.4
  }

  // Lets the host's id-to-widget lookups find a child that owns no layout entry.
  Item {
    id: proxySlot
    visible: false
    width: 0
    height: 0

    readonly property var entry: cell.entry
    readonly property string region: drawer.region
    readonly property string moduleName: cell.childId
    readonly property var moduleSettings: cell.childSettings
    readonly property string customType: cell.customType
    readonly property bool qmlCustom: cell.customType === "qml"
    readonly property bool commandCustom: cell.customType === "command"
    readonly property bool registered: true
    readonly property var registryComponent: cell.childComponent
    readonly property var activeItem: cell.childItem
    readonly property bool hovered: false
    readonly property bool dragSource: cell.dragSource
    readonly property bool panelOpen: cell.childOpen
    readonly property real panelIndicatorExtent: 0

    property var registeredWith: null

    function attach() {
      var next = cell.host
      if (next === registeredWith) return
      detach()
      registeredWith = next
      if (registeredWith && registeredWith.registerModuleSlot) registeredWith.registerModuleSlot(proxySlot)
    }

    function detach() {
      if (registeredWith && registeredWith.unregisterModuleSlot) registeredWith.unregisterModuleSlot(proxySlot)
      registeredWith = null
    }

    Component.onCompleted: attach()
    Component.onDestruction: detach()

    Connections {
      target: cell
      function onHostChanged() { proxySlot.attach() }
    }
  }

  Rectangle {
    readonly property int inset: Style.space(2)
    readonly property bool alongBar: !drawer.vertical

    visible: opacity > 0
    opacity: cell.childOpen && !cell.dragSource ? 0.9 : 0
    color: Color.accent
    radius: Math.min(width, height) / 2
    width: alongBar ? Math.max(Style.space(10), Math.round(cell.width * 0.55)) : Style.space(2)
    height: alongBar ? Style.space(2) : Math.max(Style.space(10), Math.round(cell.height * 0.55))
    x: alongBar
      ? Math.round((parent.width - width) / 2)
      : (drawer.barPosition === "left" ? inset : parent.width - width - inset)
    y: alongBar
      ? (drawer.barPosition === "bottom" ? parent.height - height - inset : inset)
      : Math.round((parent.height - height) / 2)
    z: 50

    Behavior on opacity {
      NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
    }
  }

  Component {
    id: commandModule
    CommandButton {}
  }

  // A handler, not a MouseArea: a MouseArea over the cell takes the press before
  // the widget does. DragHandler only claims the gesture past the threshold.
  DragHandler {
    id: cellDrag

    target: null
    acceptedButtons: Qt.LeftButton
    dragThreshold: Style.space(4)
    grabPermissions: PointerHandler.CanTakeOverFromAnything

    onActiveChanged: {
      if (active) drawer.beginChildDrag(cell)
      else drawer.endChildDrag()
    }

    onCentroidChanged: if (active) drawer.updateChildDrag(centroid.scenePosition)
  }
}

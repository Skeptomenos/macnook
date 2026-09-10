import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui

// The bar's exec module is private to Bar.qml, so a drawer that hosts one
// carries its own. Same settings, same waybar-style JSON output.
WidgetButton {
  id: command

  property var entry: null
  readonly property var moduleSettings: Util.isPlainObject(entry) ? entry : ({})
  property string outputText: ""
  property string outputTooltip: ""
  property bool outputActive: false

  function setting(name, fallback) {
    var value = moduleSettings[name]
    return value === undefined || value === null ? fallback : value
  }

  function update(raw) {
    var data = Util.parseModuleJson(raw)
    var klass = data.class || data.alt || ""
    outputText = data.text || String(raw || "").trim()
    outputTooltip = data.tooltip || String(setting("tooltip", ""))
    outputActive = klass === "active" || (Array.isArray(klass) && klass.indexOf("active") !== -1)
  }

  text: outputText || String(setting("text", ""))
  tooltipText: outputTooltip || String(setting("tooltip", ""))
  active: outputActive
  keepSpace: setting("keepSpace", false) === true
  horizontalMargin: Number(setting("horizontalMargin", 7.5))
  verticalPadding: Number(setting("verticalPadding", 6))
  fontSize: Number(setting("fontSize", 12))

  onPressed: function(button) {
    var script = button === Qt.RightButton ? String(setting("onRightClick", ""))
      : button === Qt.MiddleButton ? String(setting("onMiddleClick", ""))
      : String(setting("onClick", ""))
    if (script) Util.execDetached(script)
  }

  Process {
    id: commandProcess
    command: ["bash", "-lc", String(command.setting("exec", ""))]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: command.update(text)
    }
  }

  Timer {
    interval: Math.max(1, Number(command.setting("interval", 5))) * 1000
    running: String(command.setting("exec", "")) !== ""
    repeat: true
    triggeredOnStart: true
    onTriggered: if (!commandProcess.running) commandProcess.running = true
  }
}

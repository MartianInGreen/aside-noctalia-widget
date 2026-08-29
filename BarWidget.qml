import QtQuick
import Quickshell
import qs.Commons
import qs.Widgets
import qs.Services.UI

Item {
  id: root

  property var pluginApi: null
  property ShellScreen screen
  property string widgetId: ""
  property string section: ""
  property int sectionWidgetIndex: -1
  property int sectionWidgetsCount: 0

  readonly property var mainInstance: pluginApi?.mainInstance
  readonly property string asideStatus: mainInstance?.asideStatus ?? "unknown"
  readonly property bool isBusy: mainInstance?.busy ?? false
  readonly property bool speakEnabled: mainInstance?.speakEnabled ?? false
  readonly property bool daemonRunning: mainInstance?.daemonRunning ?? false
  readonly property bool showModel: pluginApi?.pluginSettings?.showModelInBar ?? false

  readonly property string screenName: screen?.name ?? ""
  readonly property string barPosition: Settings.getBarPositionForScreen(screenName)
  readonly property bool isBarVertical: barPosition === "left" || barPosition === "right"
  readonly property real capsuleHeight: Style.getCapsuleHeightForScreen(screenName)
  readonly property real barFontSize: Style.getBarFontSizeForScreen(screenName)

  readonly property string statusIcon: {
    if (!daemonRunning)
      return "plug-off"
    if (asideStatus === "speaking")
      return "volume-2"
    if (asideStatus === "tool_use")
      return "tool"
    return "sparkles"
  }

  readonly property color statusColor: {
    if (!daemonRunning)
      return Color.mOnSurfaceVariant
    if (asideStatus === "thinking")
      return Color.mPrimary
    if (asideStatus === "tool_use")
      return Color.mSecondary
    if (asideStatus === "speaking")
      return Color.mTertiary
    return Color.mOnSurface
  }

  readonly property real contentWidth: {
    var w = capsuleHeight
    if (showModel && !isBarVertical && modelText.visible)
      w = modelText.implicitWidth + Style.marginM * 2 + iconWidget.implicitWidth + Style.marginS
    return w
  }
  readonly property real contentHeight: capsuleHeight

  implicitWidth: contentWidth
  implicitHeight: contentHeight

  Rectangle {
    id: visualCapsule
    x: Style.pixelAlignCenter(parent.width, width)
    y: Style.pixelAlignCenter(parent.height, height)
    width: root.contentWidth
    height: root.contentHeight
    color: mouseArea.containsMouse ? Color.mHover : Style.capsuleColor
    radius: Style.radiusL
    border.color: mouseArea.containsMouse ? Color.mPrimary : Style.capsuleBorderColor
    border.width: Style.capsuleBorderWidth

    Row {
      anchors.centerIn: parent
      spacing: Style.marginS

      NIcon {
        id: iconWidget
        anchors.verticalCenter: parent.verticalCenter
        icon: root.statusIcon
        color: root.statusColor
        pointSize: barFontSize + 2
      }

      NText {
        id: modelText
        anchors.verticalCenter: parent.verticalCenter
        visible: root.showModel && !root.isBarVertical
        text: {
          var m = mainInstance?.model ?? ""
          var slash = m.lastIndexOf("/")
          return slash >= 0 ? m.substring(slash + 1) : m
        }
        pointSize: barFontSize - 1
        color: Color.mOnSurface
        elide: Text.ElideRight
        maximumLineCount: 1
      }
    }

    // busy pulse dot
    Rectangle {
      id: busyDot
      visible: root.isBusy
      width: 6
      height: 6
      radius: 3
      anchors.top: parent.top
      anchors.right: parent.right
      anchors.margins: 4
      color: root.statusColor

      SequentialAnimation on opacity {
        running: root.isBusy
        loops: Animation.Infinite
        NumberAnimation {
          to: 0.15
          duration: 600
          easing.type: Easing.InOutQuad
        }
        NumberAnimation {
          to: 1.0
          duration: 600
          easing.type: Easing.InOutQuad
        }
      }
    }
  }

  MouseArea {
    id: mouseArea
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    acceptedButtons: Qt.LeftButton

    onEntered: {
      TooltipService.show(root, root.tooltipText, BarService.getTooltipDirection(root.screenName))
    }
    onExited: TooltipService.hide()

    onClicked: function (mouse) {
      if (mouse.button !== Qt.LeftButton)
        return
      TooltipService.hide()
      if (pluginApi) {
        pluginApi.togglePanel(root.screen, root)
      }
    }
  }

  readonly property string tooltipText: {
    if (!root.daemonRunning)
      return "Aside — daemon not running"
    var m = mainInstance?.model ?? ""
    var s = root.asideStatus
    var state = s === "idle" ? "Idle" : s === "thinking" ? "Thinking…" : s === "tool_use" ? "Using " + (mainInstance?.toolName ?? "tool") : s === "speaking" ? "Speaking…" : s
    return "Aside — " + state + (m !== "" ? "\n" + m : "")
  }

  Component.onCompleted: {
    Logger.i("Aside", "Bar widget ready")
  }
}

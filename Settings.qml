import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Widgets

ColumnLayout {
  id: root

  property var pluginApi: null

  spacing: Style.marginL

  NToggle {
    Layout.fillWidth: true
    label: "Start daemon automatically"
    description: "Launch the aside daemon when it is not running and you interact with the widget."
    checked: pluginApi?.pluginSettings?.autoStartDaemon !== false
    onToggled: (checked) => {
                 pluginApi.pluginSettings.autoStartDaemon = checked
                 pluginApi.saveSettings()
               }
  }

  NToggle {
    Layout.fillWidth: true
    label: "Hide aside overlay on send"
    description: "Aside's native overlay pops up for every query. When on, it is hidden again after sending from this widget so only the panel shows the reply. Voice capture still uses the overlay."
    checked: pluginApi?.pluginSettings?.suppressOverlay !== false
    onToggled: (checked) => {
                 pluginApi.pluginSettings.suppressOverlay = checked
                 pluginApi.saveSettings()
               }
  }

  NToggle {
    Layout.fillWidth: true
    label: "Fullscreen screenshots"
    description: "Off: select a region with slurp. On: capture the entire screen."
    checked: pluginApi?.pluginSettings?.fullscreenScreenshot === true
    onToggled: (checked) => {
                 pluginApi.pluginSettings.fullscreenScreenshot = checked
                 pluginApi.saveSettings()
               }
  }

  NToggle {
    Layout.fillWidth: true
    label: "Show model name in bar"
    description: "Display the active model next to the icon (horizontal bars only)."
    checked: pluginApi?.pluginSettings?.showModelInBar === true
    onToggled: (checked) => {
                 pluginApi.pluginSettings.showModelInBar = checked
                 pluginApi.saveSettings()
               }
  }

  NTextInput {
    Layout.fillWidth: true
    label: "Default image prompt"
    description: "Used when an image is sent without any text."
    text: pluginApi?.pluginSettings?.imageDefaultPrompt || "Describe this image."
    onEditingFinished: {
      pluginApi.pluginSettings.imageDefaultPrompt = text
      pluginApi.saveSettings()
    }
  }

  Item {
    Layout.fillHeight: true
  }

  NText {
    text: "Requires: aside (daemon + CLI), grim, slurp, wl-clipboard (images), python-pillow (image downscaling).\nVoice input additionally needs aside's STT packages (sudo aside enable-stt)."
    color: Color.mOnSurfaceVariant
    pointSize: Style.fontSizeXS
    wrapMode: Text.WordWrap
    Layout.fillWidth: true
  }
}

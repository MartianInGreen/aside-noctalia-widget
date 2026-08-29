import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import Quickshell
import qs.Commons
import qs.Services.UI
import qs.Widgets

/**
 * Aside conversation panel.
 *
 * Header: status + model, history, new chat, TTS toggle, native overlay view.
 * Body: message transcript (markdown), thinking indicator.
 * Footer: attachment preview + input row with voice / screenshot / clipboard
 *         image attach + send.
 */
Item {
  id: root

  property var pluginApi: null
  readonly property var geometryPlaceholder: panelContainer
  property real contentPreferredWidth: 460 * Style.uiScaleRatio
  property real contentPreferredHeight: 600 * Style.uiScaleRatio
  readonly property bool allowAttach: true

  readonly property var mainInstance: pluginApi?.mainInstance
  readonly property bool isBusy: mainInstance?.busy ?? false
  readonly property string asideStatus: mainInstance?.asideStatus ?? "idle"
  readonly property string toolName: mainInstance?.toolName ?? ""

  anchors.fill: parent

  onVisibleChanged: {
    if (visible) {
      mainInstance?.refreshList()
      mainInstance?.loadTranscript()
      mainInstance?.refreshStatus()
      inputArea.forceActiveFocus()
    }
  }

  // Auto-scroll to the newest message
  function scrollToBottom() {
    Qt.callLater(() => {
                   if (chatList.contentHeight > chatList.height)
                     chatList.contentY = chatList.contentHeight - chatList.height
                 })
  }

  Connections {
    target: mainInstance
    function onTranscriptUpdated() {
      root.scrollToBottom()
    }
  }

  Rectangle {
    id: panelContainer
    anchors.fill: parent
    color: "transparent"

    ColumnLayout {
      anchors.fill: parent
      anchors.margins: Style.marginM
      spacing: Style.marginM

      // ── Header ──────────────────────────────────────────────
      RowLayout {
        Layout.fillWidth: true
        spacing: Style.marginS

        NIcon {
          icon: "sparkles"
          pointSize: Style.fontSizeL
          color: Color.mPrimary
        }

        NText {
          text: "Aside"
          pointSize: Style.fontSizeL
          font.weight: Style.fontWeightBold
          color: Color.mOnSurface
        }

        // status dot + model
        Rectangle {
          Layout.preferredWidth: 8
          Layout.preferredHeight: 8
          radius: 4
          color: {
            if (!mainInstance?.daemonRunning)
              return Color.mError
            if (root.isBusy)
              return Color.mPrimary
            return Color.mOutline
          }
        }

        NText {
          text: {
            if (!mainInstance?.daemonRunning)
              return "daemon not running"
            if (root.isBusy) {
              if (root.asideStatus === "tool_use" && root.toolName)
                return "using " + root.toolName
              if (root.asideStatus === "speaking")
                return "speaking"
              return "thinking…"
            }
            var m = mainInstance?.model ?? ""
            var slash = m.lastIndexOf("/")
            return slash >= 0 ? m.substring(slash + 1) : m
          }
          pointSize: Style.fontSizeS
          color: Color.mOnSurfaceVariant
          elide: Text.ElideRight
          Layout.maximumWidth: 160 * Style.uiScaleRatio
          Layout.fillWidth: false
        }

        Item {
          Layout.fillWidth: true
        }

        NIconButton {
          icon: "history"
          tooltipText: "Conversation history"
          enabled: mainInstance?.convList?.length > 0 || historyList.visible
          onClicked: historyList.visible = !historyList.visible
        }

        NIconButton {
          icon: "plus"
          tooltipText: "New conversation"
          onClicked: {
            mainInstance?.newChat()
            inputArea.forceActiveFocus()
          }
        }

        NIconButton {
          icon: mainInstance?.speakEnabled ? "volume-2" : "volume-x"
          tooltipText: mainInstance?.speakEnabled ? "TTS enabled" : "TTS disabled"
          colorBg: mainInstance?.speakEnabled ? Qt.alpha(Color.mPrimary, 0.2) : Color.mSurfaceVariant
          onClicked: mainInstance?.toggleTts()
        }

        NIconButton {
          icon: "eye"
          tooltipText: "Open in aside overlay"
          onClicked: mainInstance?.viewInOverlay()
        }
      }

      // ── History list ──────────────────────────────────────────
      Rectangle {
        id: historyList
        visible: false
        Layout.fillWidth: true
        Layout.preferredHeight: 190 * Style.uiScaleRatio
        color: Color.mSurfaceVariant
        radius: Style.iRadiusM
        border.color: Color.mOutline
        border.width: Style.borderS

        ColumnLayout {
          anchors.fill: parent
          anchors.margins: Style.marginS
          spacing: 0

          NText {
            text: "Recent conversations"
            pointSize: Style.fontSizeS
            color: Color.mOnSurfaceVariant
            Layout.leftMargin: Style.marginXS
          }

          NListView {
            id: historyListView
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: Style.marginXS
            model: mainInstance?.convList ?? []
            clip: true
            delegate: Item {
              width: historyListView.availableWidth
              height: convRow.implicitHeight + Style.marginXS

              Rectangle {
                anchors.fill: parent
                radius: Style.iRadiusS
                color: convMouse.containsMouse ? Color.mHover : "transparent"
              }

              RowLayout {
                id: convRow
                anchors.fill: parent
                spacing: Style.marginS

                ColumnLayout {
                  Layout.fillWidth: true
                  spacing: 0

                  NText {
                    text: modelData.preview || "(empty)"
                    pointSize: Style.fontSizeS
                    color: Color.mOnSurface
                    elide: Text.ElideRight
                    maximumLineCount: 1
                    Layout.fillWidth: true
                  }

                  NText {
                    text: {
                      var d = new Date(modelData.mtime * 1000)
                      var mins = Math.max(0, Math.floor((Date.now() - d.getTime()) / 60000))
                      if (mins < 1)
                        return "just now"
                      if (mins < 60)
                        return mins + "m ago"
                      var h = Math.floor(mins / 60)
                      if (h < 24)
                        return h + "h ago"
                      return Math.floor(h / 24) + "d ago"
                    }
                    pointSize: Style.fontSizeXS
                    color: Color.mOnSurfaceVariant
                  }
                }

                NIconButton {
                  icon: "trash"
                  baseSize: Style.baseWidgetSize * 0.8
                  colorFg: Color.mError
                  onClicked: mainInstance?.deleteConversation(modelData.id)
                }
              }

              MouseArea {
                id: convMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  mainInstance?.selectConversation(modelData.id)
                  historyList.visible = false
                }
              }
            }
          }
        }
      }

      // ── Transcript ───────────────────────────────────────────
      Item {
        Layout.fillWidth: true
        Layout.fillHeight: true

      NListView {
        id: chatList
        anchors.fill: parent
        spacing: Style.marginM
        clip: true
        model: mainInstance?.displayMessages ?? []
        boundsBehavior: Flickable.StopAtBounds

        delegate: Item {
          width: chatList.availableWidth
          height: bubble.implicitHeight

          RowLayout {
            anchors.fill: parent
            spacing: 0

            Item {
              Layout.fillWidth: modelData.role === "assistant"
              Layout.preferredWidth: 0
            }

            Rectangle {
              id: bubble
              Layout.maximumWidth: parent.width * 0.88
              implicitWidth: Math.min(msgText.implicitWidth + Style.marginM * 2, parent.width * 0.88)
              implicitHeight: msgCol.implicitHeight + Style.marginM * 1.5
              radius: Style.iRadiusM
              color: modelData.role === "user" ? Qt.alpha(Color.mPrimary, 0.15) : Color.mSurfaceVariant
              border.color: modelData.role === "user" ? Qt.alpha(Color.mPrimary, 0.4) : Color.mOutline
              border.width: Style.borderS

              ColumnLayout {
                id: msgCol
                anchors.fill: parent
                anchors.margins: Style.marginS
                spacing: Style.marginXS

                RowLayout {
                  spacing: Style.marginXS
                  visible: modelData.image

                  NIcon {
                    icon: "photo"
                    pointSize: Style.fontSizeS
                    color: Color.mPrimary
                  }

                  NText {
                    text: "image attached"
                    pointSize: Style.fontSizeXS
                    color: Color.mOnSurfaceVariant
                  }
                }

                NText {
                  id: msgText
                  Layout.fillWidth: true
                  text: modelData.text || " "
                  pointSize: Style.fontSizeM
                  color: Color.mOnSurface
                  markdownTextEnabled: modelData.role === "assistant"
                  wrapMode: Text.WordWrap
                }
              }
            }

            Item {
              Layout.fillWidth: modelData.role === "user"
              Layout.preferredWidth: 0
            }
          }
        }
      }

      // ── Empty state ──────────────────────────────────────────
      ColumnLayout {
        visible: (mainInstance?.displayMessages?.length ?? 0) === 0
        anchors.centerIn: parent
        spacing: Style.marginS

        NIcon {
          icon: "sparkles"
          Layout.alignment: Qt.AlignHCenter
          pointSize: Style.fontSizeXXXL
          color: Color.mOutline
        }

        NText {
          text: "Ask anything"
          pointSize: Style.fontSizeM
          color: Color.mOnSurfaceVariant
          Layout.alignment: Qt.AlignHCenter
        }

        NText {
          text: (mainInstance?.daemonRunning) ? "Type below, use the mic, or attach a screenshot" : "Aside daemon not running — starting it for you…"
          pointSize: Style.fontSizeS
          color: Color.mOnSurfaceVariant
          Layout.alignment: Qt.AlignHCenter
        }
      }
      }

      // ── Thinking indicator ─────────────────────────────────────
      RowLayout {
        visible: root.isBusy
        spacing: Style.marginS

        NBusyIndicator {
          running: root.isBusy
          size: Style.baseWidgetSize * 0.7
        }

        NText {
          text: root.asideStatus === "tool_use" && root.toolName ? "Using " + root.toolName + "…" : root.asideStatus === "speaking" ? "Speaking…" : "Thinking…"
          pointSize: Style.fontSizeS
          color: Color.mOnSurfaceVariant
          Layout.fillWidth: true
        }

        NButton {
          text: "Stop"
          icon: "player-stop"
          onClicked: mainInstance?.cancelQuery()
        }
      }

      // ── Pending attachment preview ─────────────────────────────
      RowLayout {
        visible: mainInstance?.pendingImage !== ""
        spacing: Style.marginS

        Rectangle {
          Layout.preferredWidth: 44 * Style.uiScaleRatio
          Layout.preferredHeight: 44 * Style.uiScaleRatio
          radius: Style.iRadiusS
          color: Color.mSurfaceVariant
          border.color: Color.mOutline
          border.width: Style.borderS
          clip: true

          Image {
            anchors.fill: parent
            anchors.margins: 2
            source: mainInstance?.pendingImage ? "file://" + mainInstance.pendingImage : ""
            fillMode: Image.PreserveAspectFit
            asynchronous: true
            cache: false
          }
        }

        NText {
          text: "image attached"
          pointSize: Style.fontSizeS
          color: Color.mOnSurfaceVariant
          Layout.fillWidth: true
        }

        NIconButton {
          icon: "x"
          tooltipText: "Remove attachment"
          onClicked: mainInstance.pendingImage = ""
        }
      }

      // ── Input row ──────────────────────────────────────────────
      RowLayout {
        Layout.fillWidth: true
        spacing: Style.marginS

        NIconButton {
          icon: "microphone"
          tooltipText: "Voice input (one-shot)"
          onClicked: mainInstance?.sendVoice()
        }

        NIconButton {
          icon: "screenshot"
          tooltipText: "Attach screenshot (select region)"
          onClicked: mainInstance?.captureScreenshot()
        }

        NIconButton {
          icon: "clipboard-copy"
          tooltipText: "Attach image from clipboard"
          onClicked: mainInstance?.attachClipboard()
        }

        Rectangle {
          id: inputBox
          Layout.fillWidth: true
          Layout.preferredHeight: Math.min(inputArea.implicitHeight + Style.marginS * 2, 120 * Style.uiScaleRatio)
          radius: Style.iRadiusM
          color: Color.mSurfaceVariant
          border.color: inputArea.activeFocus ? Color.mPrimary : Color.mOutline
          border.width: Style.borderS

          ScrollView {
            anchors.fill: parent
            ScrollBar.vertical: ScrollBar {}
            TextArea {
              id: inputArea
              placeholderText: mainInstance?.pendingImage !== "" ? "Describe the image…" : "Ask aside…"
              wrapMode: TextEdit.Wrap
              color: Color.mOnSurface
              placeholderTextColor: Color.mOnSurfaceVariant
              font.pointSize: Style.fontSizeM
              background: null
              leftPadding: Style.marginS
              rightPadding: Style.marginS
              topPadding: Style.marginS
              bottomPadding: Style.marginS
              selectionColor: Qt.alpha(Color.mPrimary, 0.4)

              Keys.onPressed: function (event) {
                if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && !(event.modifiers & Qt.ShiftModifier)) {
                  if (root.sendInput())
                    event.accepted = true
                }
              }
            }
          }
        }

        NIconButton {
          icon: "send"
          tooltipText: "Send (Enter)"
          enabled: !root.isBusy && (inputArea.text.trim() !== "" || mainInstance?.pendingImage !== "")
          onClicked: root.sendInput()
        }
      }
    }
  }

  function sendInput() {
    if (!mainInstance)
      return false
    var t = inputArea.text
    var ok = mainInstance.send(t)
    if (ok) {
      inputArea.text = ""
      root.scrollToBottom()
    }
    return ok
  }

  Component.onCompleted: {
    // Panel content loads when opened; nothing to do here yet
  }
}

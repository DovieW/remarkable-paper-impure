import QtQuick 2.15
import net.asivery.AppLoad 1.0
import net.asivery.ApploadUtils
import xofm.libs.ghostbuster 1.0

Rectangle {
    id: root
    color: paper
    readonly property color ink: "#171713"
    readonly property color paper: "#ffffff"
    readonly property color muted: "#66645c"
    readonly property color shade: "#dedbd0"
    readonly property real unit: Math.max(0.65, Math.min(stage.width / 1872, stage.height / 1404))
    property var session: null
    property var messages: []
    property int currentIndex: Math.max(0, messages.length - 1)
    readonly property var currentMessage: messages.length ? messages[currentIndex] : ({})
    property var selected: ({})
    property string statusText: "Waiting for an agent session"
    property string toastText: ""
    property bool controlsVisible: false
    property int partialChanges: 0
    property bool dirtySinceFullRefresh: false
    property double lastFullRefreshAt: 0

    function unloading() { endpoint.terminate() }
    function returnToLauncher() { endpoint.terminate() }
    function fullRefresh() {
        partialChanges = 0; dirtySinceFullRefresh = false; lastFullRefreshAt = Date.now()
        ghostBuster.forceClearNow("5-finger gesture")
    }
    function visualChanged(weight) {
        partialChanges += weight || 1; dirtySinceFullRefresh = true
        if (partialChanges >= 7) fullRefresh()
    }
    function toast(text) { toastText = text; toastTimer.restart(); visualChanged(1) }
    function showControls() {
        controlsVisible = true
        chromeTimer.restart()
        visualChanged(1)
    }
    function hideControls() {
        if (!controlsVisible) return
        controlsVisible = false
        chromeTimer.stop()
        visualChanged(1)
    }
    function toggleControls() {
        if (controlsVisible) hideControls()
        else showControls()
    }
    function applySnapshot(text) {
        var snapshot
        try { snapshot = JSON.parse(text) } catch (error) { statusText = "Invalid relay response"; return }
        var previousMessageId = currentMessage.id || ""
        var previousLatestId = messages.length ? (messages[messages.length - 1].id || "") : ""
        var nextMessages = snapshot.messages || (snapshot.session ? (snapshot.session.messages || []) : [])
        var nextLatestId = nextMessages.length ? (nextMessages[nextMessages.length - 1].id || "") : ""
        var nextIndex = Math.max(0, nextMessages.length - 1)
        if (previousMessageId !== "" && previousLatestId === nextLatestId) {
            for (var index = 0; index < nextMessages.length; index++) {
                if (nextMessages[index].id === previousMessageId) { nextIndex = index; break }
            }
        }
        session = snapshot.session
        messages = nextMessages
        currentIndex = nextIndex
        if ((currentMessage.id || "") !== previousMessageId) contentFlick.contentY = 0
        selected = ({})
        statusText = currentMessage.session_title || (session ? session.title : (messages.length ? "Canvas history" : "No Canvas history"))
        visualChanged(2)
    }
    function move(delta) {
        if (!messages.length) return
        currentIndex = Math.max(0, Math.min(messages.length - 1, currentIndex + delta))
        contentFlick.contentY = 0
        selected = ({})
        visualChanged(1)
        toast("Message " + (currentIndex + 1) + " of " + messages.length)
    }
    function submit(action) {
        if (!currentMessage.id || !currentMessage.session_id) return
        var value = action.type === "checklist" ? (selected[action.id] || []) : (action.type === "choice" ? action.id : "confirmed")
        endpoint.sendMessage(8, JSON.stringify({session_id: currentMessage.session_id, message_id: currentMessage.id, action_id: action.id, value: value}))
        toast("Sending response")
    }
    function toggleCheck(action, option) {
        var copy = selected[action.id] ? selected[action.id].slice(0) : []
        var index = copy.indexOf(option.id)
        if (index >= 0) copy.splice(index, 1); else copy.push(option.id)
        var next = {}; for (var key in selected) next[key] = selected[key]
        next[action.id] = copy; selected = next
        visualChanged(1)
    }

    Timer { id: toastTimer; interval: 2000; onTriggered: { root.toastText = ""; root.visualChanged(1) } }
    Timer { id: chromeTimer; interval: 6000; repeat: false; onTriggered: root.hideControls() }
    Timer {
        id: paperboardHandoffTimer
        interval: 60 * 60 * 1000
        repeat: false
        running: true
        onTriggered: {
            AppLoadLauncher.launchApplication("paperboard", [], {}, false)
            canvasExitTimer.start()
        }
    }
    Timer {
        id: canvasExitTimer
        interval: 750
        repeat: false
        onTriggered: root.returnToLauncher()
    }
    Timer {
        interval: 250; repeat: false; running: true
        onTriggered: root.fullRefresh()
    }
    Timer {
        interval: 300000; repeat: true; running: true
        onTriggered: {
            if (root.dirtySinceFullRefresh && Date.now() - root.lastFullRefreshAt >= interval)
                root.fullRefresh()
        }
    }
    AppLoad {
        id: endpoint
        applicationID: "canvas"
        onMessageReceived: (type, contents) => {
            if (type === 105) root.applySnapshot(contents)
            else if (type === 103) root.statusText = contents
            else if (type === 107) root.toast(contents)
        }
    }
    DisplayMethodArea { anchors.fill: parent; displayMethod: DisplayMethodArea.Content }

    Item {
        id: stage
        width: root.width >= root.height ? root.width : root.height
        height: root.width >= root.height ? root.height : root.width
        anchors.centerIn: parent
        rotation: root.width >= root.height ? 0 : 90

        Flickable {
            id: contentFlick
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.topMargin: 56 * root.unit
            anchors.leftMargin: 56 * root.unit
            anchors.rightMargin: 56 * root.unit
            anchors.bottomMargin: 56 * root.unit
            clip: true
            contentWidth: width
            contentHeight: Math.max(height, contentColumn.height)
            flickableDirection: Flickable.VerticalFlick
            boundsBehavior: Flickable.StopAtBounds
            flickDeceleration: 2600 * root.unit
            maximumFlickVelocity: 5200 * root.unit
            onMovementEnded: root.visualChanged(1)

            MouseArea {
                id: messageSwipeArea
                width: contentFlick.width
                height: Math.max(contentFlick.height, contentColumn.height)
                enabled: !root.controlsVisible
                z: -1
                preventStealing: false
                property real startX
                property real startY
                onPressed: { startX = mouse.x; startY = mouse.y }
                onReleased: {
                    var dx = mouse.x - startX
                    var dy = mouse.y - startY
                    if (Math.abs(dx) > 120 * root.unit && Math.abs(dx) > Math.abs(dy) * 1.25)
                        root.move(dx < 0 ? 1 : -1)
                    else if (Math.abs(dx) < 28 * root.unit && Math.abs(dy) < 28 * root.unit)
                        root.toggleControls()
                }
            }

            Column {
                id: contentColumn
                width: contentFlick.width
                height: childrenRect.height + 54 * root.unit
                spacing: 24 * root.unit
                Text {
                    text: currentMessage.title || "Canvas is ready."
                    color: ink; width: parent.width; wrapMode: Text.WordWrap; maximumLineCount: 2; elide: Text.ElideRight
                    font.family: "EB Garamond"; font.pixelSize: 76 * root.unit; font.weight: Font.Medium
                }
                Text {
                    text: currentMessage.body || "An agent can open a session and send an interactive message through the CLI, API, or MCP server."
                    textFormat: Text.MarkdownText; color: ink; width: parent.width; height: implicitHeight
                    wrapMode: Text.WordWrap; font.family: "EB Garamond"; font.pixelSize: 34 * root.unit; lineHeight: 1.18
                }
                Flow {
                    width: parent.width
                    height: childrenRect.height
                    spacing: 12 * root.unit
                    Repeater {
                        model: currentMessage.actions || []
                        Column {
                            id: actionColumn
                            required property var modelData
                            width: modelData.type === "checklist" ? parent.width : Math.min(parent.width, 360 * root.unit)
                            height: childrenRect.height
                            spacing: 8 * root.unit
                            Repeater {
                                model: actionColumn.modelData.type === "checklist" ? actionColumn.modelData.options : [actionColumn.modelData]
                                Rectangle {
                                    id: optionButton
                                    required property var modelData
                                    width: 340 * root.unit; height: 66 * root.unit
                                    property bool checked: actionColumn.modelData.type === "checklist" && (root.selected[actionColumn.modelData.id] || []).indexOf(modelData.id) >= 0
                                    color: checked ? ink : paper; border.width: 2 * root.unit; border.color: ink
                                    Text { anchors.centerIn: parent; text: (optionButton.checked ? "✓ " : "") + (modelData.label || actionColumn.modelData.label); color: optionButton.checked ? paper : ink; font.family: "Noto Mono"; font.pixelSize: 17 * root.unit; font.bold: true }
                                    MouseArea { anchors.fill: parent; onClicked: actionColumn.modelData.type === "checklist" ? root.toggleCheck(actionColumn.modelData, optionButton.modelData) : root.submit(actionColumn.modelData) }
                                }
                            }
                            Rectangle {
                                visible: actionColumn.modelData.type === "checklist"
                                width: 340 * root.unit; height: visible ? 66 * root.unit : 0; color: ink
                                Text { anchors.centerIn: parent; text: actionColumn.modelData.label || "SUBMIT"; color: paper; font.family: "Noto Mono"; font.pixelSize: 17 * root.unit; font.bold: true }
                                MouseArea { anchors.fill: parent; onClicked: root.submit(actionColumn.modelData) }
                            }
                        }
                    }
                }
            }
        }

        Rectangle {
            visible: contentFlick.contentHeight > contentFlick.height + 1
            anchors.right: contentFlick.right
            width: 5 * root.unit
            height: Math.max(42 * root.unit, contentFlick.height * contentFlick.visibleArea.heightRatio)
            y: contentFlick.y + (contentFlick.height - height) * contentFlick.visibleArea.yPosition / Math.max(0.001, 1 - contentFlick.visibleArea.heightRatio)
            color: ink
        }
        MouseArea {
            anchors.fill: parent
            visible: root.controlsVisible
            z: 30
            property real startX
            property real startY
            onPressed: {
                startX = mouse.x
                startY = mouse.y
                mouse.accepted = true
            }
            onReleased: {
                if (Math.abs(mouse.x - startX) < 28 * root.unit &&
                        Math.abs(mouse.y - startY) < 28 * root.unit)
                    root.hideControls()
            }
        }
        Rectangle {
            id: header
            visible: root.controlsVisible
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.topMargin: 34 * root.unit
            anchors.leftMargin: 56 * root.unit
            anchors.rightMargin: 56 * root.unit
            height: 82 * root.unit
            color: paper
            z: 40
            Row {
                anchors.fill: parent
                spacing: 18 * root.unit
                Text { text: "CANVAS"; color: ink; font.family: "Noto Mono"; font.pixelSize: 25 * root.unit; font.bold: true; font.letterSpacing: 3 * root.unit; anchors.verticalCenter: parent.verticalCenter }
                Text { text: statusText.toUpperCase(); color: muted; width: parent.width - 470 * root.unit; elide: Text.ElideRight; font.family: "Noto Mono"; font.pixelSize: 17 * root.unit; font.letterSpacing: 1 * root.unit; anchors.verticalCenter: parent.verticalCenter }
                Text { text: messages.length ? (currentIndex + 1) + " / " + messages.length : "0 / 0"; color: ink; font.family: "Noto Mono"; font.pixelSize: 19 * root.unit; font.bold: true; anchors.verticalCenter: parent.verticalCenter }
            }
        }
        Rectangle {
            id: footer
            visible: root.controlsVisible
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.leftMargin: 56 * root.unit
            anchors.rightMargin: 56 * root.unit
            anchors.bottomMargin: 34 * root.unit
            height: 82 * root.unit
            color: paper
            z: 40
            Row {
                id: controls
                anchors.fill: parent
                spacing: 10 * root.unit
                Repeater {
                    model: ["PREV", "NEXT", "TOP", "REFRESH", "EXIT"]
                    Rectangle {
                        required property string modelData
                        width: (controls.width - controls.spacing * 4) / 5
                        height: controls.height
                        color: paper
                        border.width: 2 * root.unit
                        border.color: ink
                        Text { anchors.centerIn: parent; text: modelData; color: ink; font.family: "Noto Mono"; font.pixelSize: 16 * root.unit; font.bold: true }
                        MouseArea {
                            anchors.fill: parent
                            onPressed: { root.toast(modelData); root.showControls() }
                            onClicked: {
                                if (modelData === "PREV") root.move(-1)
                                else if (modelData === "NEXT") root.move(1)
                                else if (modelData === "TOP") { contentFlick.contentY = 0; root.visualChanged(1) }
                                else if (modelData === "REFRESH") endpoint.sendMessage(1, "refresh")
                                else if (modelData === "EXIT") root.returnToLauncher()
                            }
                        }
                    }
                }
            }
        }
        Rectangle {
            visible: toastText !== ""; z: 60; anchors.horizontalCenter: parent.horizontalCenter; anchors.bottom: parent.bottom; anchors.bottomMargin: (root.controlsVisible ? 138 : 38) * root.unit
            width: toastLabel.implicitWidth + 70 * root.unit; height: 70 * root.unit; color: ink
            Text { id: toastLabel; anchors.centerIn: parent; text: toastText.toUpperCase(); color: paper; font.family: "Noto Mono"; font.pixelSize: 18 * root.unit; font.bold: true }
        }
    }
}

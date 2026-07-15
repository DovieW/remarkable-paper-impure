import QtQuick 2.15
import net.asivery.AppLoad 1.0
import net.asivery.ApploadUtils

Rectangle {
    id: root
    color: paper
    signal requestFullRefresh
    readonly property color ink: "#171713"
    readonly property color paper: "#f1efe6"
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
    property int partialChanges: 0
    property bool dirtySinceFullRefresh: false
    property double lastFullRefreshAt: 0

    function unloading() { endpoint.terminate() }
    function returnToLauncher() { endpoint.terminate() }
    function fullRefresh() {
        partialChanges = 0; dirtySinceFullRefresh = false; lastFullRefreshAt = Date.now()
        requestFullRefresh()
    }
    function visualChanged(weight) {
        partialChanges += weight || 1; dirtySinceFullRefresh = true
        if (partialChanges >= 7) fullRefresh()
    }
    function toast(text) { toastText = text; toastTimer.restart(); visualChanged(1) }
    function applySnapshot(text) {
        var snapshot
        try { snapshot = JSON.parse(text) } catch (error) { statusText = "Invalid relay response"; return }
        session = snapshot.session
        messages = session ? (session.messages || []) : []
        currentIndex = Math.max(0, messages.length - 1)
        selected = ({})
        statusText = session ? session.title : "No open Canvas session"
        visualChanged(2)
    }
    function move(delta) {
        if (!messages.length) return
        currentIndex = Math.max(0, Math.min(messages.length - 1, currentIndex + delta))
        selected = ({})
        visualChanged(1)
        toast("Message " + (currentIndex + 1) + " of " + messages.length)
    }
    function submit(action) {
        if (!session || !currentMessage.id) return
        var value = action.type === "checklist" ? (selected[action.id] || []) : (action.type === "choice" ? action.id : "confirmed")
        endpoint.sendMessage(8, JSON.stringify({session_id: session.id, message_id: currentMessage.id, action_id: action.id, value: value}))
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

        Column {
            anchors.fill: parent
            anchors.margins: 56 * root.unit
            spacing: 20 * root.unit
            Row {
                width: parent.width; height: 62 * root.unit
                Text { text: "CANVAS"; color: ink; font.family: "Noto Mono"; font.pixelSize: 26 * root.unit; font.bold: true; font.letterSpacing: 3 * root.unit }
                Item { width: parent.width - 520 * root.unit; height: 1 }
                Text { text: messages.length ? (currentIndex + 1) + " / " + messages.length : "0 / 0"; color: muted; font.family: "Noto Mono"; font.pixelSize: 19 * root.unit }
            }
            Rectangle { width: parent.width; height: 3 * root.unit; color: ink }
            Text { text: statusText.toUpperCase(); color: muted; width: parent.width; elide: Text.ElideRight; font.family: "Noto Mono"; font.pixelSize: 17 * root.unit; font.letterSpacing: 1 * root.unit }
            Text {
                text: currentMessage.title || "Canvas is ready."
                color: ink; width: parent.width; wrapMode: Text.WordWrap; maximumLineCount: 2; elide: Text.ElideRight
                font.family: "EB Garamond"; font.pixelSize: 76 * root.unit; font.weight: Font.Medium
            }
            Text {
                text: currentMessage.body || "An agent can open a session and send an interactive message through the CLI, API, or MCP server."
                textFormat: Text.MarkdownText; color: ink; width: parent.width; height: 330 * root.unit
                wrapMode: Text.WordWrap; elide: Text.ElideRight; font.family: "EB Garamond"; font.pixelSize: 34 * root.unit; lineHeight: 1.18
            }
            Flow {
                width: parent.width; spacing: 12 * root.unit
                Repeater {
                    model: currentMessage.actions || []
                    Column {
                        id: actionColumn
                        required property var modelData
                        width: modelData.type === "checklist" ? parent.width : Math.min(parent.width, 360 * root.unit)
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
                            width: 340 * root.unit; height: 66 * root.unit; color: ink
                            Text { anchors.centerIn: parent; text: actionColumn.modelData.label || "SUBMIT"; color: paper; font.family: "Noto Mono"; font.pixelSize: 17 * root.unit; font.bold: true }
                            MouseArea { anchors.fill: parent; onClicked: root.submit(actionColumn.modelData) }
                        }
                    }
                }
            }
            Item { width: 1; height: 1 }
        }

        MouseArea {
            anchors.fill: parent; z: -1
            property real startX
            onPressed: startX = mouse.x
            onReleased: { var dx = mouse.x - startX; if (Math.abs(dx) > 120 * root.unit) root.move(dx < 0 ? 1 : -1) }
        }
        Rectangle {
            visible: toastText !== ""; anchors.horizontalCenter: parent.horizontalCenter; anchors.bottom: parent.bottom; anchors.bottomMargin: 38 * root.unit
            width: toastLabel.implicitWidth + 70 * root.unit; height: 70 * root.unit; color: ink
            Text { id: toastLabel; anchors.centerIn: parent; text: toastText.toUpperCase(); color: paper; font.family: "Noto Mono"; font.pixelSize: 18 * root.unit; font.bold: true }
        }
        Rectangle {
            anchors.top: parent.top; anchors.right: parent.right; anchors.margins: 18 * root.unit; width: 140 * root.unit; height: 58 * root.unit; color: paper; border.width: 2 * root.unit; border.color: ink
            Text { anchors.centerIn: parent; text: "RETURN"; color: ink; font.family: "Noto Mono"; font.pixelSize: 16 * root.unit; font.bold: true }
            MouseArea { anchors.fill: parent; onClicked: root.returnToLauncher() }
        }
    }
}

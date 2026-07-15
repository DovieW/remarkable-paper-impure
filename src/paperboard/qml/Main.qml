import QtQuick 2.15
import net.asivery.AppLoad 1.0
import net.asivery.ApploadUtils

Rectangle {
    id: root
    color: paper

    signal close
    signal requestFullRefresh

    function unloading() {
        endpoint.terminate()
    }

    readonly property real unit: Math.max(0.65, Math.min(width / 1404, height / 1872))
    readonly property color ink: "#171713"
    readonly property color paper: "#f1efe6"
    readonly property color muted: "#66645c"
    readonly property color shade: "#dedbd0"
    readonly property color urgent: "#171713"

    property var cards: []
    property int cursor: 0
    property int currentIndex: 0
    readonly property var currentCard: cards.length > 0 ? cards[currentIndex] : ({})
    property string backendState: "CONNECTING"
    property string backendDetail: "Waiting for the private relay"
    property string pendingSnapshot: ""
    property double lastAppliedAt: 0
    property int changedFrames: 0
    property bool legacyCandidate: false

    function applySnapshot(contents) {
        var previousId = currentCard.id || ""
        var snapshot
        try { snapshot = JSON.parse(contents) }
        catch (error) { backendState = "ERROR"; backendDetail = "Relay returned invalid JSON"; return }
        cards = snapshot.cards || []
        cursor = snapshot.cursor || 0
        currentIndex = 0
        for (var index = 0; index < cards.length; index++) {
            if (cards[index].id === previousId) { currentIndex = index; break }
        }
        backendState = cards.length > 0 ? "LIVE" : "CLEAR"
        backendDetail = cards.length > 0 ? cards.length + " queued card" + (cards.length === 1 ? "" : "s") : "No queued output"
        lastAppliedAt = Date.now()
        changedFrames += 1
        if (changedFrames >= 10) { changedFrames = 0; requestFullRefresh() }
    }

    function queueSnapshot(contents) {
        pendingSnapshot = contents
        var remaining = 2000 - (Date.now() - lastAppliedAt)
        if (lastAppliedAt === 0 || remaining <= 0) {
            snapshotTimer.stop()
            applySnapshot(pendingSnapshot)
            pendingSnapshot = ""
        } else {
            snapshotTimer.interval = remaining
            snapshotTimer.restart()
        }
    }

    function move(delta) {
        if (cards.length === 0) return
        currentIndex = (currentIndex + delta + cards.length) % cards.length
    }

    function selectAmbient() {
        for (var index = 0; index < cards.length; index++) {
            if (cards[index].priority === "ambient") { currentIndex = index; return }
        }
        backendDetail = "No ambient provider frame is queued"
    }

    Timer {
        id: snapshotTimer
        repeat: false
        onTriggered: {
            if (root.pendingSnapshot !== "") root.applySnapshot(root.pendingSnapshot)
            root.pendingSnapshot = ""
        }
    }

    AppLoad {
        id: endpoint
        applicationID: "paperboard"
        onMessageReceived: (type, contents) => {
            if (type === 101) {
                root.backendState = contents
                root.backendDetail = contents === "CONNECTED" ? "Private relay connected" : contents
            } else if (type === 102) {
                root.legacyCandidate = true
                legacyImage.source = "file://" + contents + "?candidate=" + Date.now()
            } else if (type === 103) {
                root.backendState = "OFFLINE"
                root.backendDetail = contents
            } else if (type === 104) {
                root.legacyCandidate = false
                root.backendState = "LEGACY"
                root.backendDetail = "Verified last-good dashboard"
                legacyImage.source = "file://" + contents + "?accepted=" + Date.now()
            } else if (type === 105) {
                root.queueSnapshot(contents)
            }
        }
    }

    DisplayMethodArea {
        anchors.fill: parent
        displayMethod: DisplayMethodArea.Content
    }

    Image {
        id: legacyImage
        anchors.fill: parent
        visible: status === Image.Ready && source !== ""
        fillMode: Image.PreserveAspectFit
        asynchronous: true
        cache: false
        z: 20
        onStatusChanged: {
            if (!root.legacyCandidate) return
            if (status === Image.Ready) endpoint.sendMessage(2, "decoded")
            else if (status === Image.Error) endpoint.sendMessage(3, "decode failed")
        }
    }

    Item {
        id: page
        anchors.fill: parent
        anchors.margins: 58 * root.unit

        Row {
            id: masthead
            width: parent.width
            height: 68 * root.unit
            spacing: 18 * root.unit

            Text {
                text: "PAPERBOARD"
                color: ink
                font.family: "Noto Mono"
                font.pixelSize: 25 * root.unit
                font.letterSpacing: 3 * root.unit
                font.weight: Font.Bold
                anchors.verticalCenter: parent.verticalCenter
            }
            Rectangle { width: 9 * root.unit; height: 9 * root.unit; radius: width / 2; color: backendState === "LIVE" ? ink : muted; anchors.verticalCenter: parent.verticalCenter }
            Text {
                text: backendState
                color: muted
                font.family: "Noto Mono"
                font.pixelSize: 18 * root.unit
                font.letterSpacing: 2 * root.unit
                anchors.verticalCenter: parent.verticalCenter
            }
            Item { width: Math.max(0, masthead.width - 640 * root.unit); height: 1 }
            Text {
                text: cards.length > 0 ? (currentIndex + 1) + " / " + cards.length : "0 / 0"
                color: ink
                font.family: "Noto Mono"
                font.pixelSize: 20 * root.unit
                font.weight: Font.Bold
                anchors.verticalCenter: parent.verticalCenter
            }
        }

        Rectangle { id: topRule; anchors.top: masthead.bottom; width: parent.width; height: 3 * root.unit; color: ink }

        Item {
            id: content
            anchors.top: topRule.bottom
            anchors.bottom: statusRule.top
            width: parent.width

            Column {
                anchors.fill: parent
                anchors.topMargin: 64 * root.unit
                anchors.bottomMargin: 45 * root.unit
                visible: cards.length === 0
                spacing: 34 * root.unit

                Text {
                    text: "The board is clear."
                    color: ink
                    font.family: "EB Garamond"
                    font.pixelSize: 106 * root.unit
                    font.weight: Font.Medium
                    width: parent.width
                    wrapMode: Text.WordWrap
                }
                Rectangle { width: 110 * root.unit; height: 8 * root.unit; color: ink }
                Text {
                    text: "OUTPUT ARRIVES HERE WITHOUT INTERRUPTING NOTEBOOKS OR READING.\nOPEN PAPERBOARD WHEN YOU ARE READY TO RECEIVE IT."
                    color: muted
                    font.family: "Noto Mono"
                    font.pixelSize: 24 * root.unit
                    font.letterSpacing: 1 * root.unit
                    lineHeight: 1.45
                    width: parent.width * 0.78
                    wrapMode: Text.WordWrap
                }
            }

            Item {
                anchors.fill: parent
                anchors.topMargin: 48 * root.unit
                anchors.bottomMargin: 32 * root.unit
                visible: cards.length > 0 && currentCard.kind !== "image"

                Text {
                    id: eyebrow
                    anchors.top: parent.top
                    width: parent.width
                    text: (currentCard.priority || "normal").toUpperCase() + "  ·  " + (currentCard.kind || "message").toUpperCase() + (currentCard.pinned ? "  ·  PINNED" : "")
                    color: muted
                    font.family: "Noto Mono"
                    font.pixelSize: 20 * root.unit
                    font.letterSpacing: 2 * root.unit
                    font.weight: Font.Bold
                }
                Text {
                    id: title
                    anchors.top: eyebrow.bottom
                    anchors.topMargin: 34 * root.unit
                    width: parent.width
                    text: currentCard.title || "Untitled"
                    color: ink
                    font.family: "EB Garamond"
                    font.pixelSize: Math.max(66 * root.unit, Math.min(118 * root.unit, 1500 * root.unit / Math.max(12, text.length)))
                    font.weight: Font.Medium
                    wrapMode: Text.WordWrap
                    maximumLineCount: 3
                    elide: Text.ElideRight
                }
                Rectangle {
                    id: progressTrack
                    anchors.top: title.bottom
                    anchors.topMargin: 36 * root.unit
                    width: parent.width
                    height: 30 * root.unit
                    color: shade
                    visible: currentCard.kind === "progress"
                    Rectangle { width: parent.width * Math.max(0, Math.min(100, currentCard.progress || 0)) / 100; height: parent.height; color: ink }
                }
                Text {
                    anchors.top: progressTrack.visible ? progressTrack.bottom : title.bottom
                    anchors.topMargin: 44 * root.unit
                    anchors.bottom: parent.bottom
                    width: parent.width
                    text: currentCard.body || ""
                    textFormat: Text.MarkdownText
                    color: ink
                    font.family: "EB Garamond"
                    font.pixelSize: 38 * root.unit
                    lineHeight: 1.22
                    wrapMode: Text.WordWrap
                    elide: Text.ElideRight
                }
            }

            Rectangle {
                anchors.fill: parent
                visible: cards.length > 0 && currentCard.kind === "image"
                color: paper
            }

            Image {
                id: cardImage
                anchors.fill: parent
                anchors.margins: 18 * root.unit
                visible: cards.length > 0 && currentCard.kind === "image" && currentCard.asset_path !== undefined
                source: visible ? "file://" + currentCard.asset_path + "?cursor=" + cursor : ""
                fillMode: Image.PreserveAspectFit
                asynchronous: true
                cache: false
                smooth: false
                onStatusChanged: {
                    if (status === Image.Ready) root.requestFullRefresh()
                }
            }
        }

        Rectangle { id: statusRule; anchors.bottom: statusBar.top; width: parent.width; height: 2 * root.unit; color: ink }

        Row {
            id: statusBar
            anchors.bottom: controls.top
            width: parent.width
            height: 62 * root.unit
            spacing: 18 * root.unit
            Text {
                text: backendDetail.toUpperCase()
                color: muted
                width: parent.width - 240 * root.unit
                elide: Text.ElideRight
                anchors.verticalCenter: parent.verticalCenter
                font.family: "Noto Mono"
                font.pixelSize: 16 * root.unit
                font.letterSpacing: 1 * root.unit
            }
            Text {
                text: "CURSOR " + cursor
                color: muted
                anchors.verticalCenter: parent.verticalCenter
                font.family: "Noto Mono"
                font.pixelSize: 16 * root.unit
            }
        }

        Row {
            id: controls
            anchors.bottom: parent.bottom
            width: parent.width
            height: 82 * root.unit
            spacing: 9 * root.unit

            Repeater {
                model: ["PREV", "NEXT", "PIN", "DISMISS", "AMBIENT", "REFRESH", "RETURN"]
                Rectangle {
                    required property string modelData
                    width: (controls.width - controls.spacing * 6) / 7
                    height: controls.height
                    color: modelData === "DISMISS" ? ink : paper
                    border.width: 2 * root.unit
                    border.color: ink
                    Text {
                        anchors.centerIn: parent
                        text: modelData
                        color: modelData === "DISMISS" ? paper : ink
                        font.family: "Noto Mono"
                        font.pixelSize: 15 * root.unit
                        font.weight: Font.Bold
                    }
                    MouseArea {
                        anchors.fill: parent
                        onClicked: {
                            if (modelData === "PREV") root.move(-1)
                            else if (modelData === "NEXT") root.move(1)
                            else if (modelData === "PIN" && root.currentCard.id) endpoint.sendMessage(5, root.currentCard.id)
                            else if (modelData === "DISMISS" && root.currentCard.id) endpoint.sendMessage(4, root.currentCard.id)
                            else if (modelData === "AMBIENT") root.selectAmbient()
                            else if (modelData === "REFRESH") endpoint.sendMessage(1, "refresh")
                            else if (modelData === "RETURN") root.close()
                        }
                    }
                }
            }
        }
    }

    Row {
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.margins: 20 * root.unit
        visible: legacyImage.visible
        z: 21
        spacing: 8 * root.unit
        Repeater {
            model: ["REFRESH", "RETURN"]
            Rectangle {
                required property string modelData
                width: 150 * root.unit; height: 64 * root.unit; color: paper; border.width: 2 * root.unit; border.color: ink
                Text { anchors.centerIn: parent; text: modelData; color: ink; font.family: "Noto Mono"; font.pixelSize: 17 * root.unit; font.weight: Font.Bold }
                MouseArea { anchors.fill: parent; onClicked: modelData === "REFRESH" ? endpoint.sendMessage(1, "refresh") : root.close() }
            }
        }
    }
}

import QtQuick 2.15
import net.asivery.AppLoad 1.0
import net.asivery.ApploadUtils
import xofm.libs.ghostbuster 1.0

Rectangle {
    id: root
    color: paper

    signal close
    function unloading() {
        endpoint.terminate()
    }

    function returnToLauncher() {
        // AppLoad's terminate() kills the backend and immediately unloads all
        // frontends. Do not emit close afterward: that races AppLoad's
        // permanent-unload path and can leave a resident frontend that later
        // relaunches the backend.
        endpoint.terminate()
    }

    // Paperboard is deliberately landscape-first. AppLoad may either expose a
    // landscape surface or retain the panel's portrait coordinate space. In
    // the latter case landscapeCanvas rotates the complete UI as one unit.
    readonly property real unit: Math.max(0.65, Math.min(landscapeCanvas.width / 1872, landscapeCanvas.height / 1404))
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
    property int partialChanges: 0
    property bool dirtySinceFullRefresh: false
    property double lastFullRefreshAt: 0
    property bool legacyCandidate: false
    property bool controlsVisible: false
    property bool ambientMode: false
    property string toastText: ""
    property string lastAction: ""
    property string lastResult: ""

    function fullRefresh() {
        partialChanges = 0
        dirtySinceFullRefresh = false
        lastFullRefreshAt = Date.now()
        ghostBuster.forceClearNow("5-finger gesture")
    }

    function visualChanged(weight) {
        partialChanges += weight || 1
        dirtySinceFullRefresh = true
        if (partialChanges >= 7) fullRefresh()
    }

    function showToast(text) {
        toastText = text
        toastTimer.restart()
        visualChanged(1)
    }

    function showControls() {
        if (controlsVisible) { chromeTimer.restart(); return }
        controlsVisible = true
        chromeTimer.restart()
        visualChanged(1)
        reportState()
    }

    function hideControls() {
        if (!controlsVisible) return
        controlsVisible = false
        chromeTimer.stop()
        visualChanged(1)
        reportState()
    }

    function reportState() {
        endpoint.sendMessage(6, JSON.stringify({
            application: "paperboard", foreground: true, rendered_cursor: cursor,
            visible_card_id: currentCard.id || null, visible_index: cards.length ? currentIndex : null,
            card_count: cards.length, ambient_mode: ambientMode, controls_visible: controlsVisible,
            last_action: lastAction, last_result: lastResult
        }))
    }

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
        visualChanged(2)
        if (ambientMode) selectAmbient(false)
        reportState()
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
        ambientMode = false
        currentIndex = (currentIndex + delta + cards.length) % cards.length
        lastAction = delta < 0 ? "previous" : "next"
        lastResult = "Showing card " + (currentIndex + 1) + " of " + cards.length
        visualChanged(1)
        showToast(lastResult)
        reportState()
    }

    function selectAmbient(notify) {
        ambientMode = true
        for (var index = 0; index < cards.length; index++) {
            if (cards[index].priority === "ambient") {
                currentIndex = index
                lastAction = "select_ambient"; lastResult = "Ambient mode on"
                visualChanged(1)
                if (notify !== false) showToast(lastResult)
                reportState(); return true
            }
        }
        ambientMode = false
        lastAction = "select_ambient"; lastResult = "No ambient card is queued"
        if (notify !== false) showToast(lastResult)
        reportState(); return false
    }

    function runCommand(command) {
        var ok = true
        if (command.action === "previous") move(-1)
        else if (command.action === "next") move(1)
        else if (command.action === "select_ambient") ok = selectAmbient(true)
        else if (command.action === "leave_ambient") { ambientMode = false; visualChanged(1); showToast("Ambient mode off"); reportState() }
        else if (command.action === "show_controls") showControls()
        else if (command.action === "hide_controls") hideControls()
        else if (command.action === "refresh") { endpoint.sendMessage(1, "refresh"); showToast("Refreshing") }
        else if (command.action === "return") { endpoint.sendMessage(7, JSON.stringify({id: command.id, status: "completed", detail: "Returning to launcher"})); returnToLauncher(); return }
        else ok = false
        endpoint.sendMessage(7, JSON.stringify({id: command.id, status: ok ? "completed" : "failed", detail: ok ? (lastResult || "Command completed") : "Command could not be completed"}))
    }

    Timer {
        id: snapshotTimer
        repeat: false
        onTriggered: {
            if (root.pendingSnapshot !== "") root.applySnapshot(root.pendingSnapshot)
            root.pendingSnapshot = ""
        }
    }

    Timer { id: heartbeatTimer; interval: 5000; repeat: true; running: true; onTriggered: root.reportState() }
    Timer { id: chromeTimer; interval: 6000; repeat: false; onTriggered: root.hideControls() }
    Timer { id: toastTimer; interval: 2000; repeat: false; onTriggered: { root.toastText = ""; root.visualChanged(1) } }
    Timer {
        id: startupRefreshTimer
        interval: 250
        repeat: false
        running: true
        onTriggered: root.fullRefresh()
    }
    Timer {
        id: cleanupRefreshTimer
        interval: 300000
        repeat: true
        running: true
        onTriggered: {
            if (root.dirtySinceFullRefresh && Date.now() - root.lastFullRefreshAt >= interval)
                root.fullRefresh()
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
            } else if (type === 106) {
                try { root.runCommand(JSON.parse(contents)) }
                catch (error) { root.showToast("Invalid remote command") }
            } else if (type === 107) {
                root.lastAction = contents
                root.lastResult = contents === "pin" ? "Pin changed" : "Card dismissed"
                root.showToast(root.lastResult)
                root.reportState()
            }
        }
    }

    DisplayMethodArea {
        anchors.fill: parent
        displayMethod: DisplayMethodArea.Content
    }

    Item {
        id: landscapeCanvas
        width: root.width >= root.height ? root.width : root.height
        height: root.width >= root.height ? root.height : root.width
        anchors.centerIn: parent
        rotation: root.width >= root.height ? 0 : 90

        Image {
            id: legacyImage
            anchors.fill: parent
            visible: status === Image.Ready && source !== ""
            fillMode: Image.PreserveAspectFit
            asynchronous: true
            cache: false
            z: 20
            onStatusChanged: {
                if (status === Image.Ready) root.fullRefresh()
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
            visible: root.controlsVisible
            z: 10

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

        Rectangle { id: topRule; anchors.top: masthead.bottom; width: parent.width; height: 3 * root.unit; color: ink; visible: root.controlsVisible; z: 10 }

        Item {
            id: content
            anchors.top: parent.top
            anchors.bottom: parent.bottom
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
                    if (status === Image.Ready) root.fullRefresh()
                }
            }
        }

        Rectangle { id: statusRule; anchors.bottom: statusBar.top; width: parent.width; height: 2 * root.unit; color: ink; visible: root.controlsVisible; z: 10 }

        Row {
            id: statusBar
            anchors.bottom: controls.top
            width: parent.width
            height: 62 * root.unit
            spacing: 18 * root.unit
            visible: root.controlsVisible
            z: 10
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
            visible: root.controlsVisible
            z: 10

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
                        onPressed: root.showToast(modelData)
                        onClicked: {
                            if (modelData === "PREV") root.move(-1)
                            else if (modelData === "NEXT") root.move(1)
                            else if (modelData === "PIN" && root.currentCard.id) endpoint.sendMessage(5, root.currentCard.id)
                            else if (modelData === "DISMISS" && root.currentCard.id) endpoint.sendMessage(4, root.currentCard.id)
                            else if (modelData === "AMBIENT") { if (root.ambientMode) { root.ambientMode = false; root.visualChanged(1); root.showToast("Ambient mode off"); root.reportState() } else root.selectAmbient(true) }
                            else if (modelData === "REFRESH") { endpoint.sendMessage(1, "refresh"); root.showToast("Refreshing") }
                            else if (modelData === "RETURN") root.returnToLauncher()
                        }
                    }
                }
            }
        }

        MouseArea {
            id: gestureArea
            anchors.fill: parent
            z: root.controlsVisible ? 5 : 30
            property real startX: 0
            property real startY: 0
            onPressed: { startX = mouse.x; startY = mouse.y }
            onReleased: {
                var dx = mouse.x - startX
                var dy = mouse.y - startY
                if (Math.abs(dx) > 120 * root.unit && Math.abs(dx) > Math.abs(dy) * 1.35) root.move(dx < 0 ? 1 : -1)
                else if (Math.abs(dy) > 90 * root.unit && Math.abs(dy) > Math.abs(dx)) {
                    if ((startY > height * 0.72 && dy < 0) || (startY < height * 0.28 && dy > 0)) root.showControls()
                } else if (!root.controlsVisible) root.showControls()
                else root.hideControls()
            }
        }

        Rectangle {
            visible: root.toastText !== ""
            z: 50
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 42 * root.unit
            width: Math.min(parent.width * 0.72, toastLabel.implicitWidth + 70 * root.unit)
            height: 74 * root.unit
            color: ink
            Text {
                id: toastLabel
                anchors.centerIn: parent
                text: root.toastText.toUpperCase()
                color: paper
                font.family: "Noto Mono"
                font.pixelSize: 19 * root.unit
                font.weight: Font.Bold
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
                    MouseArea { anchors.fill: parent; onClicked: modelData === "REFRESH" ? endpoint.sendMessage(1, "refresh") : root.returnToLauncher() }
                }
            }
        }
    }
}

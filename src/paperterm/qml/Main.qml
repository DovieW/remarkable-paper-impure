import QtQuick 2.15
import net.asivery.AppLoad 1.0
import net.asivery.ApploadUtils
import xofm.libs.ghostbuster 1.0

Rectangle {
    id: root
    color: "#ffffff"
    focus: true

    readonly property color ink: "#11110f"
    readonly property color paper: "#ffffff"
    readonly property color rule: "#c9c8c1"
    readonly property color soft: "#eeeee9"
    readonly property color accent: "#11110f"
    readonly property real unit: Math.max(0.7, Math.min(width / 1872, height / 1404))

    property var profiles: []
    property var macros: []
    property bool profilesLoaded: false
    property string notice: ""
    property string connectionError: ""
    property string statusText: "Starting PaperTerm"
    property string terminalText: ""
    property bool sessionActive: false
    property bool connectionPending: false
    property bool disconnectRequested: false
    property bool hasTerminalFrame: false
    property bool keyboardVisible: true
    property bool ctrlHeld: false
    property bool altHeld: false
    property bool shiftHeld: false
    property bool symbolLayer: false
    property bool followOutput: true
    property int terminalRows: 30
    property int terminalCols: 100
    property int cursorRow: 0
    property int cursorCol: 0
    property bool cursorVisible: false
    property int visualChanges: 0
    property double lastFullRefresh: 0

    signal close
    FontLoader {
        id: terminalFont
        source: "file:///home/root/xovi/exthome/appload/paperterm/fonts/NotoMonoNerdFontMono-Regular.ttf"
    }
    Text {
        id: terminalCellProbe
        visible: false
        text: "M"
        font.family: terminalFont.name.length ? terminalFont.name : "NotoMono Nerd Font Mono"
        font.pixelSize: 22 * root.unit
        font.hintingPreference: Font.PreferNoHinting
        onImplicitWidthChanged: geometryUpdate.restart()
        onImplicitHeightChanged: geometryUpdate.restart()
    }
    function unloading() { endpoint.terminate() }
    function exitApp() { endpoint.terminate() }

    function fullRefresh() {
        visualChanges = 0
        lastFullRefresh = Date.now()
        ghostBuster.forceClearNow("paperterm")
    }

    function changed(weight) {
        visualChanges += weight || 1
        if (visualChanges >= 7) fullRefresh()
    }

    function sendText(value) {
        if (!sessionActive || !value.length) return
        var output = value
        if (shiftHeld && value.length === 1) output = value.toUpperCase()
        if (ctrlHeld && output.length === 1) {
            var code = output.toUpperCase().charCodeAt(0)
            if (code >= 64 && code <= 95) output = String.fromCharCode(code - 64)
        }
        if (altHeld) output = "\u001b" + output
        if (output === "\u000c") {
            followOutput = true
            clearScreenRefresh.restart()
        }
        endpoint.sendMessage(2, JSON.stringify({text: output}))
        ctrlHeld = false
        altHeld = false
        shiftHeld = false
    }

    function sendKey(name) {
        if (!sessionActive) return
        endpoint.sendMessage(3, JSON.stringify({key: name, ctrl: ctrlHeld, alt: altHeld, shift: shiftHeld}))
        ctrlHeld = false
        altHeld = false
        shiftHeld = false
    }

    function sendMacro(macro) {
        if (!sessionActive) return
        endpoint.sendMessage(3, JSON.stringify({
            key: macro.key,
            ctrl: !!macro.ctrl,
            alt: !!macro.alt,
            shift: !!macro.shift
        }))
        if (!!macro.ctrl && String(macro.key).toLowerCase() === "l") {
            followOutput = true
            clearScreenRefresh.restart()
        }
        ctrlHeld = false
        altHeld = false
        shiftHeld = false
    }

    function startProfile(id) {
        connectionError = ""
        disconnectRequested = false
        terminalText = ""
        hasTerminalFrame = false
        connectionPending = true
        sessionActive = true
        followOutput = true
        cursorVisible = false
        statusText = "Connecting"
        endpoint.sendMessage(1, JSON.stringify({id: id}))
        geometryUpdate.restart()
    }

    function disconnectSession() {
        connectionError = ""
        disconnectRequested = true
        sessionActive = false
        connectionPending = false
        hasTerminalFrame = false
        terminalText = ""
        cursorVisible = false
        followOutput = true
        statusText = "Ready"
        endpoint.sendMessage(5, "disconnect")
        changed(2)
    }

    Keys.onPressed: function(event) {
        if (!sessionActive) return
        var special = ""
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) special = "enter"
        else if (event.key === Qt.Key_Backspace) special = "backspace"
        else if (event.key === Qt.Key_Tab) special = "tab"
        else if (event.key === Qt.Key_Escape) special = "escape"
        else if (event.key === Qt.Key_Up) special = "up"
        else if (event.key === Qt.Key_Down) special = "down"
        else if (event.key === Qt.Key_Left) special = "left"
        else if (event.key === Qt.Key_Right) special = "right"
        else if (event.key === Qt.Key_Home) special = "home"
        else if (event.key === Qt.Key_End) special = "end"
        else if (event.key === Qt.Key_PageUp) special = "pageup"
        else if (event.key === Qt.Key_PageDown) special = "pagedown"
        else if (event.key === Qt.Key_Delete) special = "delete"
        else if (event.key === Qt.Key_Space && (event.modifiers & Qt.ControlModifier)) special = "space"
        if (special.length) {
            endpoint.sendMessage(3, JSON.stringify({key: special,
                ctrl: !!(event.modifiers & Qt.ControlModifier),
                alt: !!(event.modifiers & Qt.AltModifier),
                shift: !!(event.modifiers & Qt.ShiftModifier)}))
            event.accepted = true
        } else if (event.text && event.text.length) {
            var output = event.text
            if (event.modifiers & Qt.ControlModifier) {
                var code = output.toUpperCase().charCodeAt(0)
                if (code >= 64 && code <= 95) output = String.fromCharCode(code - 64)
            }
            if (event.modifiers & Qt.AltModifier) output = "\u001b" + output
            if (output === "\u000c") {
                root.followOutput = true
                clearScreenRefresh.restart()
            }
            endpoint.sendMessage(2, JSON.stringify({text: output}))
            event.accepted = true
        }
    }

    AppLoad {
        id: endpoint
        applicationID: "paperterm"
        onMessageReceived: (type, contents) => {
            if (type === 101) {
                try {
                    var payload = JSON.parse(contents)
                    root.profiles = payload.profiles || []
                    root.macros = payload.macros || []
                    root.notice = payload.notice || ""
                    root.profilesLoaded = true
                } catch (error) { root.notice = "Could not read the profile list." }
                root.changed(2)
            } else if (type === 102) {
                try {
                    var snapshot = JSON.parse(contents)
                    var wasFollowing = root.followOutput || terminalFlick.atYEnd ||
                        terminalFlick.contentY >= terminalFlick.contentHeight - terminalFlick.height - 80
                    root.terminalText = (snapshot.lines || []).join("\n")
                    root.sessionActive = !!snapshot.connected
                    root.terminalRows = Number(snapshot.rows) || root.terminalRows
                    root.terminalCols = Number(snapshot.cols) || root.terminalCols
                    root.cursorRow = Math.max(0, Number(snapshot.cursor_row) || 0)
                    root.cursorCol = Math.max(0, Number(snapshot.cursor_col) || 0)
                    root.cursorVisible = !!snapshot.cursor_visible && root.sessionActive
                    var firstFrame = !root.hasTerminalFrame && root.terminalText.trim().length > 0
                    if (root.terminalText.trim().length > 0) {
                        root.hasTerminalFrame = true
                        root.connectionPending = false
                    }
                    if (wasFollowing) {
                        root.followOutput = true
                        scrollToEnd.restart()
                    }
                    if (firstFrame) root.fullRefresh()
                } catch (error) { root.statusText = "Terminal frame was invalid" }
                if (!root.hasTerminalFrame) root.changed(1)
            } else if (type === 103) {
                root.statusText = contents
                root.sessionActive = contents !== "Ready"
                root.changed(1)
            } else if (type === 104) {
                root.statusText = contents
                root.connectionError = contents
                root.connectionPending = false
                root.sessionActive = false
                root.disconnectRequested = false
                root.changed(1)
            } else if (type === 106) {
                var openedShell = root.hasTerminalFrame
                root.sessionActive = false
                root.connectionPending = false
                root.hasTerminalFrame = false
                root.terminalText = ""
                root.cursorVisible = false
                root.followOutput = true
                root.statusText = contents
                root.connectionError = root.disconnectRequested ? "" : (openedShell
                    ? "The remote session ended."
                    : "SSH could not open a shell. Check that the destination is online and allowed by Tailscale or SSH policy.")
                root.disconnectRequested = false
                root.changed(2)
            }
        }
    }

    Timer { interval: 350; running: true; repeat: false; onTriggered: root.fullRefresh() }
    Timer {
        id: requestProfiles
        interval: 250
        running: !root.profilesLoaded
        repeat: true
        onTriggered: endpoint.sendMessage(7, "profiles")
    }
    Timer {
        interval: 300000; running: true; repeat: true
        onTriggered: if (root.visualChanges > 0 && Date.now() - root.lastFullRefresh >= interval) root.fullRefresh()
    }
    Timer {
        id: scrollToEnd; interval: 1; repeat: false
        onTriggered: {
            terminalFlick.contentY = Math.max(0, terminalFlick.contentHeight - terminalFlick.height)
            root.followOutput = true
        }
    }
    Timer {
        id: geometryUpdate
        interval: 80
        repeat: false
        onTriggered: {
            if (!root.sessionActive || terminalFlick.width <= 0 || terminalFlick.height <= 0) return
            var cellWidth = Math.max(1, terminalCellProbe.implicitWidth)
            var cellHeight = Math.max(1, terminalCellProbe.implicitHeight)
            var columns = Math.max(40, Math.min(160, Math.floor(terminalFlick.width / cellWidth)))
            var rows = Math.max(10, Math.min(60, Math.floor(terminalFlick.height / cellHeight)))
            if (rows === root.terminalRows && columns === root.terminalCols) return
            root.terminalRows = rows
            root.terminalCols = columns
            endpoint.sendMessage(4, JSON.stringify({rows: rows, cols: columns}))
            root.followOutput = true
            scrollToEnd.restart()
        }
    }
    Timer {
        id: clearScreenRefresh
        interval: 220
        repeat: false
        onTriggered: root.fullRefresh()
    }

    Rectangle {
        id: header
        anchors.top: parent.top
        width: parent.width
        height: 54 * unit
        color: paper
        border.color: rule
        border.width: 1

        Text {
            anchors.left: parent.left; anchors.leftMargin: 24 * unit
            anchors.verticalCenter: parent.verticalCenter
            text: "PAPER / TERM"
            color: ink
            font.family: "Noto Sans Mono"
            font.pixelSize: 21 * unit
            font.bold: true
            font.letterSpacing: 2 * unit
        }
        Text {
            anchors.centerIn: parent
            text: root.sessionActive ? root.statusText : "CONNECTIONS"
            color: ink
            font.family: "Noto Serif"
            font.pixelSize: 22 * unit
        }
        Row {
            anchors.right: parent.right; anchors.rightMargin: 14 * unit
            anchors.verticalCenter: parent.verticalCenter
            spacing: 8 * unit
            Rectangle {
                visible: root.sessionActive
                width: 132 * unit; height: 42 * unit
                color: soft; border.color: ink; radius: 2 * unit
                Text { anchors.centerIn: parent; text: root.keyboardVisible ? "HIDE KEYS" : "SHOW KEYS"; color: ink; font.pixelSize: 15 * unit; font.bold: true }
                MouseArea {
                    anchors.fill: parent
                    onClicked: {
                        root.keyboardVisible = !root.keyboardVisible
                        root.followOutput = true
                        geometryUpdate.restart()
                        scrollToEnd.restart()
                        root.changed(2)
                    }
                }
            }
            Rectangle {
                width: 82 * unit; height: 42 * unit
                color: ink; radius: 2 * unit
                Text { anchors.centerIn: parent; text: "EXIT"; color: paper; font.pixelSize: 16 * unit; font.bold: true }
                MouseArea { anchors.fill: parent; onClicked: root.exitApp() }
            }
        }
    }

    Item {
        anchors.top: header.bottom
        anchors.bottom: parent.bottom
        width: parent.width

        Flickable {
            id: connectionList
            anchors.fill: parent
            visible: !root.sessionActive
            contentWidth: width
            contentHeight: connectionColumn.height + 100 * unit
            clip: true

            Column {
                id: connectionColumn
                width: Math.min(parent.width - 160 * unit, 1120 * unit)
                anchors.horizontalCenter: parent.horizontalCenter
                topPadding: 40 * unit
                spacing: 22 * unit
                Rectangle {
                    width: connectionColumn.width
                    height: visible ? 96 * unit : 0
                    visible: root.connectionError.length > 0 || root.notice.length > 0
                    color: "#f1f1ec"
                    border.color: ink
                    border.width: 2 * unit
                    radius: 3 * unit
                    Text {
                        anchors.left: parent.left
                        anchors.right: dismissNotice.left
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.leftMargin: 24 * unit
                        anchors.rightMargin: 18 * unit
                        text: root.connectionError.length > 0 ? root.connectionError : root.notice
                        color: ink
                        font.family: "Noto Sans"
                        font.pixelSize: 20 * unit
                        wrapMode: Text.WordWrap
                    }
                    Text {
                        id: dismissNotice
                        anchors.right: parent.right
                        anchors.rightMargin: 24 * unit
                        anchors.verticalCenter: parent.verticalCenter
                        text: "DISMISS"
                        color: ink
                        font.family: "Noto Sans Mono"
                        font.pixelSize: 17 * unit
                        font.bold: true
                    }
                    MouseArea {
                        anchors.fill: parent
                        onClicked: {
                            root.connectionError = ""
                            root.notice = ""
                            root.changed(1)
                        }
                    }
                }
                Repeater {
                    model: root.profiles
                    delegate: Rectangle {
                        required property var modelData
                        width: connectionColumn.width
                        height: 118 * unit
                        color: paper
                        border.color: ink
                        border.width: 2 * unit
                        radius: 3 * unit
                        Row {
                            anchors.fill: parent; anchors.margins: 24 * unit
                            spacing: 28 * unit
                            Rectangle { width: 16 * unit; height: parent.height; color: ink }
                            Column {
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 5 * unit
                                Text { text: modelData.label; color: ink; font.family: "Noto Serif"; font.pixelSize: 32 * unit; font.bold: true }
                                Text { text: modelData.mode === "tailscale-ssh" ? "TAILSCALE SSH" : (modelData.mode === "local" ? "LOCAL ROOT SHELL" : "SSH KEY"); color: "#66665f"; font.family: "Noto Sans Mono"; font.pixelSize: 18 * unit; font.letterSpacing: 2 * unit }
                            }
                        }
                        MouseArea { anchors.fill: parent; onClicked: root.startProfile(modelData.id) }
                    }
                }
                Text {
                    visible: root.profiles.length === 0
                    width: parent.width
                    topPadding: 30 * unit
                    text: "NO CONNECTION PROFILES"
                    color: ink
                    font.family: "Noto Sans Mono"
                    font.pixelSize: 24 * unit
                    font.letterSpacing: 3 * unit
                }
            }
        }

        Column {
            anchors.fill: parent
            visible: root.sessionActive
            spacing: 0

            Rectangle {
                width: parent.width
                height: parent.height - (root.keyboardVisible ? 470 * unit : 0)
                color: paper
                Flickable {
                    id: terminalFlick
                    anchors.fill: parent
                    anchors.margins: 24 * unit
                    contentWidth: width
                    contentHeight: Math.max(height, terminalOutput.paintedHeight,
                        (root.cursorRow + 1) * terminalCellProbe.implicitHeight + 4 * unit)
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    flickableDirection: Flickable.VerticalFlick
                    onWidthChanged: geometryUpdate.restart()
                    onHeightChanged: geometryUpdate.restart()
                    onMovementStarted: root.followOutput = false
                    onMovementEnded: root.followOutput = atYEnd
                    Text {
                        id: terminalOutput
                        width: terminalFlick.width
                        text: root.terminalText
                        color: ink
                        font.family: terminalFont.name.length ? terminalFont.name : "NotoMono Nerd Font Mono"
                        font.pixelSize: 22 * unit
                        font.hintingPreference: Font.PreferNoHinting
                        lineHeightMode: Text.FixedHeight
                        lineHeight: terminalCellProbe.implicitHeight
                        textFormat: Text.PlainText
                        wrapMode: Text.NoWrap
                    }
                    Rectangle {
                        id: terminalCursor
                        visible: root.cursorVisible && root.hasTerminalFrame
                        x: Math.min(terminalFlick.width - width,
                            root.cursorCol * terminalCellProbe.implicitWidth)
                        y: root.cursorRow * terminalCellProbe.implicitHeight
                        width: Math.max(2, 2 * unit)
                        height: Math.max(2 * unit, terminalCellProbe.implicitHeight)
                        color: ink
                        z: 2
                    }
                    Column {
                        visible: root.connectionPending && !root.hasTerminalFrame
                        anchors.centerIn: parent
                        spacing: 12 * unit
                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: "CONNECTING"
                            color: ink
                            font.family: "Noto Sans Mono"
                            font.pixelSize: 30 * unit
                            font.bold: true
                            font.letterSpacing: 3 * unit
                        }
                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: "Waiting for shell output…"
                            color: "#55554f"
                            font.family: "Noto Sans"
                            font.pixelSize: 21 * unit
                        }
                    }
                }
            }

            OnScreenKeyboard {
                id: keyboard
                visible: root.keyboardVisible
                width: parent.width
                height: 470 * unit
                terminalMode: true
                unitScale: root.unit
                macros: root.macros
                ink: root.ink; paper: root.paper; rule: root.rule; soft: root.soft
                onTextRequested: function(value, ctrl, alt) {
                    root.ctrlHeld=ctrl; root.altHeld=alt; root.shiftHeld=false
                    root.sendText(value); root.changed(1)
                }
                onKeyRequested: function(value, ctrl, alt, shift) {
                    root.ctrlHeld=ctrl; root.altHeld=alt; root.shiftHeld=shift
                    root.sendKey(value); root.changed(1)
                }
                onMacroRequested: function(macro) { root.sendMacro(macro); root.changed(1) }
            }
        }

        Rectangle {
            visible: root.sessionActive
            anchors.right: parent.right; anchors.rightMargin: 24 * unit
            anchors.top: parent.top; anchors.topMargin: 18 * unit
            width: 190 * unit; height: 64 * unit
            color: paper; border.color: ink; border.width: 2 * unit; radius: 2 * unit
            Text { anchors.centerIn: parent; text: "DISCONNECT"; color: ink; font.pixelSize: 19 * unit; font.bold: true }
            MouseArea { anchors.fill: parent; onClicked: root.disconnectSession() }
        }
    }
}

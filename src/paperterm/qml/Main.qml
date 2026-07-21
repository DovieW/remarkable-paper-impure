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
    property bool profilesLoaded: false
    property string notice: ""
    property string statusText: "Starting PaperTerm"
    property string terminalText: ""
    property bool sessionActive: false
    property bool connectionPending: false
    property bool hasTerminalFrame: false
    property bool keyboardVisible: true
    property bool ctrlHeld: false
    property bool altHeld: false
    property bool shiftHeld: false
    property bool symbolLayer: false
    property int visualChanges: 0
    property double lastFullRefresh: 0

    signal close
    FontLoader {
        id: terminalFont
        source: "file:///home/root/xovi/exthome/appload/paperterm/fonts/NotoMonoNerdFontMono-Regular.ttf"
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

    function startProfile(id) {
        terminalText = ""
        hasTerminalFrame = false
        connectionPending = true
        sessionActive = true
        statusText = "Connecting"
        endpoint.sendMessage(1, JSON.stringify({id: id}))
    }

    function disconnectSession() {
        sessionActive = false
        connectionPending = false
        hasTerminalFrame = false
        terminalText = ""
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
                    root.notice = payload.notice || ""
                    root.profilesLoaded = true
                } catch (error) { root.notice = "Could not read the profile list." }
                root.changed(2)
            } else if (type === 102) {
                try {
                    var snapshot = JSON.parse(contents)
                    root.terminalText = (snapshot.lines || []).join("\n")
                    root.sessionActive = !!snapshot.connected
                    var firstFrame = !root.hasTerminalFrame && root.terminalText.trim().length > 0
                    if (root.terminalText.trim().length > 0) {
                        root.hasTerminalFrame = true
                        root.connectionPending = false
                    }
                    if (terminalFlick.atYEnd || terminalFlick.contentY >= terminalFlick.contentHeight - terminalFlick.height - 80)
                        scrollToEnd.restart()
                    if (firstFrame) root.fullRefresh()
                } catch (error) { root.statusText = "Terminal frame was invalid" }
                if (!root.hasTerminalFrame) root.changed(1)
            } else if (type === 103) {
                root.statusText = contents
                root.sessionActive = contents !== "Ready"
                root.changed(1)
            } else if (type === 104) {
                root.statusText = contents
                root.connectionPending = false
                root.sessionActive = false
                root.changed(1)
            } else if (type === 106) {
                root.sessionActive = false
                root.connectionPending = false
                root.hasTerminalFrame = false
                root.terminalText = ""
                root.statusText = contents
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
        onTriggered: terminalFlick.contentY = Math.max(0, terminalFlick.contentHeight - terminalFlick.height)
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
                MouseArea { anchors.fill: parent; onClicked: { root.keyboardVisible = !root.keyboardVisible; root.changed(2) } }
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
                    contentHeight: Math.max(height, terminalOutput.paintedHeight + 20 * unit)
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    Text {
                        id: terminalOutput
                        width: terminalFlick.width
                        text: root.terminalText
                        color: ink
                        font.family: terminalFont.name.length ? terminalFont.name : "NotoMono Nerd Font Mono"
                        font.pixelSize: 22 * unit
                        font.hintingPreference: Font.PreferNoHinting
                        textFormat: Text.PlainText
                        wrapMode: Text.NoWrap
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

            Rectangle {
                id: keyboard
                visible: root.keyboardVisible
                width: parent.width
                height: 470 * unit
                color: "#f4f4ef"
                border.color: rule
                border.width: 1

                Column {
                    anchors.fill: parent
                    anchors.margins: 12 * unit
                    spacing: 9 * unit

                    Row {
                        anchors.horizontalCenter: parent.horizontalCenter
                        spacing: 8 * unit
                        Repeater {
                            model: [
                                {label:"HOME", action:"home"}, {label:"PGUP", action:"pageup"},
                                {label:"←", action:"left"}, {label:"↑", action:"up"},
                                {label:"↓", action:"down"}, {label:"→", action:"right"},
                                {label:"PGDN", action:"pagedown"}, {label:"END", action:"end"},
                                {label:"DEL", action:"delete"}
                            ]
                            delegate: Rectangle {
                                required property var modelData
                                width: 116 * unit; height: 58 * unit
                                color: paper; border.color: "#777770"; radius: 2 * unit
                                Text {
                                    anchors.centerIn: parent
                                    text: modelData.label
                                    color: ink
                                    font.family: terminalFont.name.length ? terminalFont.name : "Noto Mono"
                                    font.pixelSize: 18 * unit; font.bold: true
                                }
                                MouseArea { anchors.fill: parent; onClicked: root.sendKey(modelData.action) }
                            }
                        }
                    }

                    Repeater {
                        model: root.symbolLayer
                            ? ["1234567890-+=", "[]{}()<>/\\|", "`~!@#$%^&*_:;"]
                            : ["1234567890", "qwertyuiop", "asdfghjkl", "zxcvbnm,./"]
                        delegate: Row {
                            required property string modelData
                            anchors.horizontalCenter: parent.horizontalCenter
                            spacing: 8 * unit
                            Repeater {
                                model: modelData.split("")
                                delegate: Rectangle {
                                    required property string modelData
                                    width: Math.min(103 * unit, (keyboard.width - 70 * unit) / 14)
                                    height: 68 * unit
                                    color: paper; border.color: "#777770"; radius: 2 * unit
                                    Text { anchors.centerIn: parent; text: root.shiftHeld ? modelData.toUpperCase() : modelData; color: ink; font.family: "Noto Sans Mono"; font.pixelSize: 25 * unit; font.bold: true }
                                    MouseArea { anchors.fill: parent; onClicked: root.sendText(modelData) }
                                }
                            }
                        }
                    }

                    Row {
                        anchors.horizontalCenter: parent.horizontalCenter
                        spacing: 9 * unit
                        Repeater {
                            model: [
                                {label:"ESC", action:"escape", wide:1}, {label:"CTRL", action:"ctrl", wide:1},
                                {label:"ALT", action:"alt", wide:1}, {label:"SHIFT", action:"shift", wide:1},
                                {label:"SYM", action:"symbol", wide:1}, {label:"TAB", action:"tab", wide:1},
                                {label:"SPACE", action:"space", wide:3}, {label:"BKSP", action:"backspace", wide:1},
                                {label:"ENTER", action:"enter", wide:2}
                            ]
                            delegate: Rectangle {
                                required property var modelData
                                width: 83 * unit * modelData.wide
                                height: 68 * unit
                                color: (modelData.action === "ctrl" && root.ctrlHeld) ||
                                       (modelData.action === "alt" && root.altHeld) ||
                                       (modelData.action === "shift" && root.shiftHeld) ||
                                       (modelData.action === "symbol" && root.symbolLayer) ? ink : paper
                                border.color: ink; radius: 2 * unit
                                Text { anchors.centerIn: parent; text: modelData.label; color: parent.color === root.ink ? root.paper : root.ink; font.pixelSize: 18 * unit; font.bold: true }
                                MouseArea {
                                    anchors.fill: parent
                                    onClicked: {
                                        if (modelData.action === "ctrl") root.ctrlHeld = !root.ctrlHeld
                                        else if (modelData.action === "alt") root.altHeld = !root.altHeld
                                        else if (modelData.action === "shift") root.shiftHeld = !root.shiftHeld
                                        else if (modelData.action === "symbol") root.symbolLayer = !root.symbolLayer
                                        else if (modelData.action === "space") root.sendText(" ")
                                        else root.sendKey(modelData.action)
                                        root.changed(1)
                                    }
                                }
                            }
                        }
                    }
                }
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

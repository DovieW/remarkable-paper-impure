import QtQuick 2.15

Rectangle {
    id: keyboard
    property real unitScale: 1
    property bool terminalMode: false
    property var macros: []
    property color ink: "#11110f"
    property color paper: "#ffffff"
    property color rule: "#777770"
    property color soft: "#eeeee9"
    property bool ctrlHeld: false
    property bool altHeld: false
    property bool shiftHeld: false
    property bool symbolLayer: false
    signal textRequested(string value, bool ctrl, bool alt)
    signal keyRequested(string value, bool ctrl, bool alt, bool shift)
    signal macroRequested(var macro)
    signal submitRequested
    signal cancelRequested

    function clearTransientModifiers() { ctrlHeld = false; altHeld = false; shiftHeld = false }
    function emitText(value) {
        var output = shiftHeld && value.length === 1 ? value.toUpperCase() : value
        textRequested(output, ctrlHeld, altHeld)
        clearTransientModifiers()
    }
    function emitKey(value) {
        keyRequested(value, ctrlHeld, altHeld, shiftHeld)
        clearTransientModifiers()
    }

    color: soft
    border.color: rule
    border.width: 1

    Rectangle {
        id: macroRail
        visible: terminalMode && keyboard.macros.length > 0
        anchors.left: parent.left; anchors.top: parent.top; anchors.bottom: parent.bottom
        width: visible ? 132 * unitScale : 0
        color: soft
        Column {
            anchors.fill: parent; anchors.margins: 12 * unitScale; spacing: 8 * unitScale
            Repeater {
                model: keyboard.macros
                Rectangle {
                    required property var modelData
                    width: parent.width
                    height: (macroRail.height - 24 * unitScale - Math.max(0, keyboard.macros.length - 1) * 8 * unitScale) / Math.max(1, keyboard.macros.length)
                    color: macroTap.pressed ? ink : paper; border.color: ink; border.width: 2 * unitScale; radius: 2 * unitScale
                    Text { anchors.fill: parent; anchors.margins: 6 * unitScale; text:modelData.label; color:parent.color===ink?paper:ink; font.family:"Noto Sans Mono"; font.pixelSize:16*unitScale; font.bold:true; elide:Text.ElideRight; horizontalAlignment:Text.AlignHCenter; verticalAlignment:Text.AlignVCenter }
                    MouseArea { id:macroTap; anchors.fill:parent; onClicked:keyboard.macroRequested(modelData) }
                }
            }
        }
    }

    Column {
        id: rows
        anchors.left: macroRail.right; anchors.right: parent.right; anchors.top: parent.top; anchors.bottom: parent.bottom
        anchors.margins: 12 * unitScale; spacing: 9 * unitScale

        Row {
            visible: terminalMode
            anchors.horizontalCenter: parent.horizontalCenter; spacing: 8 * unitScale
            Repeater {
                model: [{label:"HOME",key:"home"},{label:"PGUP",key:"pageup"},{label:"←",key:"left"},{label:"↑",key:"up"},{label:"↓",key:"down"},{label:"→",key:"right"},{label:"PGDN",key:"pagedown"},{label:"END",key:"end"},{label:"DEL",key:"delete"}]
                Rectangle {
                    required property var modelData
                    width:116*unitScale; height:58*unitScale; color:navTap.pressed?ink:paper; border.color:rule; radius:2*unitScale
                    Text { anchors.centerIn:parent; text:modelData.label; color:parent.color===ink?paper:ink; font.family:"Noto Sans Mono"; font.pixelSize:18*unitScale; font.bold:true }
                    MouseArea { id:navTap; anchors.fill:parent; onClicked:keyboard.emitKey(modelData.key) }
                }
            }
        }

        Repeater {
            model: keyboard.symbolLayer
                ? ["1234567890-+=", "[]{}()<>/\\|", "`~!@#$%^&*_:;"]
                : ["1234567890", "qwertyuiop", "asdfghjkl", "zxcvbnm,./"]
            Row {
                required property string modelData
                anchors.horizontalCenter:parent.horizontalCenter; spacing:8*unitScale
                Repeater {
                    model:modelData.split("")
                    Rectangle {
                        required property string modelData
                        width:Math.min(103*unitScale,(rows.width-70*unitScale)/14); height:68*unitScale
                        color:keyTap.pressed?ink:paper; border.color:rule; border.width:1*unitScale; radius:2*unitScale
                        Text { anchors.centerIn:parent; text:keyboard.shiftHeld?modelData.toUpperCase():modelData; color:parent.color===ink?paper:ink; font.family:"Noto Sans Mono"; font.pixelSize:25*unitScale; font.bold:true }
                        MouseArea { id:keyTap; anchors.fill:parent; onClicked:keyboard.emitText(modelData) }
                    }
                }
            }
        }

        Row {
            anchors.horizontalCenter:parent.horizontalCenter; spacing:9*unitScale
            Repeater {
                model: terminalMode
                    ? [{label:"ESC",action:"escape",wide:1},{label:"CTRL",action:"ctrl",wide:1},{label:"ALT",action:"alt",wide:1},{label:"SHIFT",action:"shift",wide:1},{label:"SYM",action:"symbol",wide:1},{label:"TAB",action:"tab",wide:1},{label:"SPACE",action:"space",wide:3},{label:"BKSP",action:"backspace",wide:1},{label:"ENTER",action:"enter",wide:2}]
                    : [{label:"SHIFT",action:"shift",wide:1},{label:"SYM",action:"symbol",wide:1},{label:"SPACE",action:"space",wide:4},{label:"BKSP",action:"backspace",wide:1},{label:"NEWLINE",action:"newline",wide:2},{label:"CANCEL",action:"cancel",wide:2},{label:"SEND",action:"submit",wide:2}]
                Rectangle {
                    required property var modelData
                    width:(terminalMode?83:88)*unitScale*modelData.wide; height:68*unitScale
                    color: actionTap.pressed || (modelData.action==="ctrl"&&keyboard.ctrlHeld) || (modelData.action==="alt"&&keyboard.altHeld) || (modelData.action==="shift"&&keyboard.shiftHeld) || (modelData.action==="symbol"&&keyboard.symbolLayer) || modelData.action==="submit" ? ink : paper
                    border.color:ink; border.width:1*unitScale; radius:2*unitScale
                    Text { anchors.centerIn:parent; text:modelData.label; color:parent.color===ink?paper:ink; font.family:"Noto Sans Mono"; font.pixelSize:17*unitScale; font.bold:true }
                    MouseArea {
                        id:actionTap; anchors.fill:parent
                        onClicked: {
                            if(modelData.action==="ctrl")keyboard.ctrlHeld=!keyboard.ctrlHeld
                            else if(modelData.action==="alt")keyboard.altHeld=!keyboard.altHeld
                            else if(modelData.action==="shift")keyboard.shiftHeld=!keyboard.shiftHeld
                            else if(modelData.action==="symbol")keyboard.symbolLayer=!keyboard.symbolLayer
                            else if(modelData.action==="space"&&keyboard.terminalMode&&keyboard.ctrlHeld)keyboard.emitKey("space")
                            else if(modelData.action==="space")keyboard.emitText(" ")
                            else if(modelData.action==="backspace")keyboard.emitKey("backspace")
                            else if(modelData.action==="newline")keyboard.textRequested("\n",false,false)
                            else if(modelData.action==="cancel")keyboard.cancelRequested()
                            else if(modelData.action==="submit")keyboard.submitRequested()
                            else keyboard.emitKey(modelData.action)
                        }
                    }
                }
            }
        }
    }
}

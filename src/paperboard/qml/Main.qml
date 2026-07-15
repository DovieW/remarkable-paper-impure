import QtQuick 2.15
import net.asivery.AppLoad 1.0
import net.asivery.ApploadUtils

Rectangle {
    id: root

    color: "#f1efe6"

    signal close

    function unloading() {
        console.log("paperboard: frontend unloaded")
        endpoint.terminate()
    }

    readonly property real unit: Math.max(0.65, Math.min(width / 1620, height / 2160))
    readonly property color ink: "#171713"
    readonly property color paper: "#f1efe6"
    readonly property color muted: "#66645c"
    readonly property color rule: "#292923"
    readonly property color shade: "#dedbd0"

    property string clockText: "--:--"
    property string dateText: ""
    property string refreshedText: "NOT YET REFRESHED"
    property int refreshCount: 0
    property string backendState: "OFFLINE"
    property string backendDetail: "No dashboard configured"
    property bool candidatePending: false

    function twoDigits(value) {
        return value < 10 ? "0" + value : value
    }

    function updateClock(markRefresh) {
        const now = new Date()
        clockText = twoDigits(now.getHours()) + ":" + twoDigits(now.getMinutes())
        dateText = Qt.formatDate(now, "dddd, d MMMM yyyy").toUpperCase()
        if (markRefresh) {
            refreshCount += 1
            refreshedText = "LOCAL REFRESH  " + twoDigits(now.getHours()) + ":" + twoDigits(now.getMinutes())
        }
    }

    Component.onCompleted: updateClock(false)

    AppLoad {
        id: endpoint
        applicationID: "paperboard"

        onMessageReceived: (type, contents) => {
            if (type === 101) {
                root.backendState = contents
                root.backendDetail = contents === "FETCHING" ? "HTTPS request in progress" : "No dashboard configured"
            } else if (type === 102) {
                root.candidatePending = true
                dashboardImage.source = "file://" + contents + "?candidate=" + Date.now()
            } else if (type === 103) {
                root.candidatePending = false
                root.backendState = dashboardImage.source !== "" ? "LAST GOOD" : "ERROR"
                root.backendDetail = contents
            } else if (type === 104) {
                root.candidatePending = false
                root.backendState = "DISPLAYING"
                root.backendDetail = "Decoded and atomically cached"
                dashboardImage.source = "file://" + contents + "?accepted=" + Date.now()
            }
        }
    }

    Image {
        id: dashboardImage
        anchors.fill: parent
        visible: status === Image.Ready && source !== ""
        fillMode: Image.PreserveAspectFit
        asynchronous: true
        cache: false
        z: 10

        onStatusChanged: {
            if (!root.candidatePending) return
            if (status === Image.Ready) endpoint.sendMessage(2, "decoded")
            else if (status === Image.Error) endpoint.sendMessage(3, "decode failed")
        }
    }

    Row {
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.margins: 28 * root.unit
        height: 82 * root.unit
        spacing: 12 * root.unit
        visible: dashboardImage.visible
        z: 11

        Repeater {
            model: ["REFRESH", "RETURN"]

            Rectangle {
                required property string modelData
                width: 190 * root.unit
                height: 82 * root.unit
                color: root.paper
                border.width: 3 * root.unit
                border.color: root.ink

                Text {
                    anchors.centerIn: parent
                    text: modelData
                    color: root.ink
                    font.family: "Noto Mono"
                    font.pixelSize: 22 * root.unit
                    font.weight: Font.Bold
                }

                MouseArea {
                    anchors.fill: parent
                    onClicked: {
                        if (modelData === "REFRESH") endpoint.sendMessage(1, "refresh")
                        else root.close()
                    }
                }
            }
        }
    }

    DisplayMethodArea {
        anchors.fill: parent
        displayMethod: DisplayMethodArea.Content
    }

    Item {
        id: page
        anchors.fill: parent
        anchors.margins: 76 * root.unit

        Row {
            id: masthead
            width: parent.width
            height: 82 * root.unit
            spacing: 20 * root.unit

            Text {
                text: "PAPERBOARD"
                color: root.ink
                font.family: "Noto Mono"
                font.pixelSize: 31 * root.unit
                font.letterSpacing: 4 * root.unit
                font.weight: Font.Bold
                anchors.verticalCenter: parent.verticalCenter
            }

            Rectangle {
                width: 12 * root.unit
                height: 12 * root.unit
                radius: width / 2
                color: root.ink
                anchors.verticalCenter: parent.verticalCenter
            }

            Text {
                text: "SECURE IMAGE DISPLAY"
                color: root.muted
                font.family: "Noto Mono"
                font.pixelSize: 22 * root.unit
                font.letterSpacing: 2 * root.unit
                anchors.verticalCenter: parent.verticalCenter
            }
        }

        Rectangle {
            id: topRule
            anchors.top: masthead.bottom
            width: parent.width
            height: 4 * root.unit
            color: root.rule
        }

        Item {
            id: hero
            anchors.top: topRule.bottom
            width: parent.width
            height: 660 * root.unit

            Text {
                id: clock
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.topMargin: 65 * root.unit
                text: root.clockText
                color: root.ink
                font.family: "EB Garamond"
                font.pixelSize: 300 * root.unit
                font.weight: Font.Medium
                font.letterSpacing: -8 * root.unit
            }

            Text {
                anchors.left: parent.left
                anchors.bottom: parent.bottom
                anchors.bottomMargin: 62 * root.unit
                text: root.dateText
                color: root.ink
                font.family: "Noto Mono"
                font.pixelSize: 30 * root.unit
                font.letterSpacing: 2 * root.unit
            }

            Column {
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.bottomMargin: 62 * root.unit
                spacing: 10 * root.unit

                Text {
                    anchors.right: parent.right
                    text: "PAPER PURE"
                    color: root.ink
                    font.family: "Noto Mono"
                    font.pixelSize: 25 * root.unit
                    font.weight: Font.Bold
                }

                Text {
                    anchors.right: parent.right
                    text: Math.round(root.width) + " × " + Math.round(root.height)
                    color: root.muted
                    font.family: "Noto Mono"
                    font.pixelSize: 22 * root.unit
                }
            }
        }

        Rectangle {
            id: heroRule
            anchors.top: hero.bottom
            width: parent.width
            height: 2 * root.unit
            color: root.rule
        }

        Row {
            id: panels
            anchors.top: heroRule.bottom
            anchors.topMargin: 45 * root.unit
            width: parent.width
            height: 610 * root.unit
            spacing: 30 * root.unit

            Repeater {
                model: [
                    {
                        number: "01",
                        title: "DISPLAY",
                        value: "READY",
                        detail: "Qt Quick surface\nAppLoad foreground"
                    },
                    {
                        number: "02",
                        title: "NETWORK",
                        value: root.backendState,
                        detail: root.backendDetail
                    },
                    {
                        number: "03",
                        title: "CACHE",
                        value: "ARMED",
                        detail: "Decode before accept\nAtomic last-good image"
                    }
                ]

                Rectangle {
                    required property var modelData
                    required property int index
                    width: (panels.width - 2 * panels.spacing) / 3
                    height: panels.height
                    color: index === 0 ? root.ink : root.paper
                    border.width: index === 0 ? 0 : 2 * root.unit
                    border.color: root.rule

                    Text {
                        anchors.left: parent.left
                        anchors.top: parent.top
                        anchors.margins: 30 * root.unit
                        text: modelData.number
                        color: index === 0 ? root.paper : root.muted
                        font.family: "Noto Mono"
                        font.pixelSize: 23 * root.unit
                    }

                    Text {
                        anchors.left: parent.left
                        anchors.top: parent.top
                        anchors.topMargin: 165 * root.unit
                        anchors.leftMargin: 30 * root.unit
                        text: modelData.title
                        color: index === 0 ? root.paper : root.ink
                        font.family: "Noto Mono"
                        font.pixelSize: 24 * root.unit
                        font.letterSpacing: 2 * root.unit
                    }

                    Text {
                        anchors.left: parent.left
                        anchors.top: parent.top
                        anchors.topMargin: 220 * root.unit
                        anchors.leftMargin: 30 * root.unit
                        text: modelData.value
                        color: index === 0 ? root.paper : root.ink
                        font.family: "EB Garamond"
                        font.pixelSize: 48 * root.unit
                        font.weight: Font.Bold
                    }

                    Text {
                        anchors.left: parent.left
                        anchors.bottom: parent.bottom
                        anchors.margins: 30 * root.unit
                        text: modelData.detail
                        color: index === 0 ? root.shade : root.muted
                        font.family: "Noto Sans"
                        font.pixelSize: 23 * root.unit
                        lineHeight: 1.35
                    }
                }
            }
        }

        Item {
            id: controls
            anchors.top: panels.bottom
            anchors.topMargin: 70 * root.unit
            width: parent.width
            height: 150 * root.unit

            Rectangle {
                id: refreshButton
                anchors.left: parent.left
                width: 445 * root.unit
                height: parent.height
                color: refreshArea.pressed ? root.shade : root.paper
                border.width: 3 * root.unit
                border.color: root.rule

                Text {
                    anchors.centerIn: parent
                    text: "REFRESH PROOF"
                    color: root.ink
                    font.family: "Noto Mono"
                    font.pixelSize: 25 * root.unit
                    font.weight: Font.Bold
                    font.letterSpacing: 1 * root.unit
                }

                MouseArea {
                    id: refreshArea
                    anchors.fill: parent
                    onClicked: {
                        root.updateClock(true)
                        endpoint.sendMessage(1, "refresh")
                    }
                }
            }

            Text {
                anchors.left: refreshButton.right
                anchors.leftMargin: 35 * root.unit
                anchors.verticalCenter: parent.verticalCenter
                text: root.refreshedText
                color: root.muted
                font.family: "Noto Mono"
                font.pixelSize: 21 * root.unit
            }

            Rectangle {
                anchors.right: parent.right
                width: 285 * root.unit
                height: parent.height
                color: returnArea.pressed ? root.ink : root.paper
                border.width: 3 * root.unit
                border.color: root.rule

                Text {
                    anchors.centerIn: parent
                    text: "RETURN"
                    color: returnArea.pressed ? root.paper : root.ink
                    font.family: "Noto Mono"
                    font.pixelSize: 25 * root.unit
                    font.weight: Font.Bold
                    font.letterSpacing: 2 * root.unit
                }

                MouseArea {
                    id: returnArea
                    anchors.fill: parent
                    onClicked: root.close()
                }
            }
        }

        Text {
            anchors.left: parent.left
            anchors.bottom: parent.bottom
            text: "MILESTONE 02  /  HTTPS FETCH  /  ON-DEMAND BACKEND"
            color: root.muted
            font.family: "Noto Mono"
            font.pixelSize: 19 * root.unit
            font.letterSpacing: 1 * root.unit
        }
    }
}

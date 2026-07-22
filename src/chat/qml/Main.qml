import QtQuick 2.15
import net.asivery.AppLoad 1.0
import net.asivery.ApploadUtils
import xofm.libs.ghostbuster 1.0

Rectangle {
    id: root
    color: "#ffffff"
    signal close
    function unloading() { endpoint.terminate() }
    readonly property color ink: "#171713"
    readonly property color muted: "#68665f"
    readonly property color line: "#d8d5ca"
    readonly property color accent: "#c84c2d"
    readonly property real unit: Math.max(0.65, Math.min(width / 1872, height / 1404))
    property var agents: []
    property var sessions: []
    property var messages: []
    property string selectedSession: ""
    property string selectedTitle: "Chat"
    property string selectedAgent: ""
    property bool conversationOpen: false
    property bool keyboardVisible: false
    property string inputMode: "message"
    property string inputText: ""
    property string searchText: ""
    property string statusText: "Connecting"
    property bool shift: false
    property bool hiddenView: false
    property int refreshWeight: 0

    function uuid() {
        var seed = Date.now().toString(16) + Math.floor(Math.random() * 0x7fffffff).toString(16)
        while (seed.length < 32) seed += Math.floor(Math.random() * 0xffffffff).toString(16)
        return seed.slice(0,8) + "-" + seed.slice(8,12) + "-4" + seed.slice(13,16) + "-a" + seed.slice(17,20) + "-" + seed.slice(20,32)
    }
    function action(value) { endpoint.sendMessage(2, JSON.stringify(value)) }
    function selectSession(item) {
        selectedSession = item.session_key; selectedTitle = item.title; selectedAgent = item.agent_id
        conversationOpen = true; keyboardVisible = false; endpoint.sendMessage(1, selectedSession); action({id:uuid(),kind:"mark_read",session_key:selectedSession,value:true})
        ghostBuster.forceClearNow("chat open")
    }
    function submitInput() {
        var value = inputText.trim(); if (!value.length) return
        if (inputMode === "search") { searchText = value; keyboardVisible = false; ghostBuster.forceClearNow("search"); return }
        if (inputMode === "rename") { action({id:uuid(),kind:"rename",session_key:selectedSession,title:value}); selectedTitle=value; keyboardVisible=false; return }
        if (inputMode === "new") {
            var key = "paperchat:" + uuid(); var agent = selectedAgent || (agents.length ? agents[0].id : "main")
            action({id:uuid(),kind:"create",session_key:key,agent_id:agent,title:value}); selectedSession=key; selectedTitle=value; selectedAgent=agent; conversationOpen=true; keyboardVisible=false; endpoint.sendMessage(1,key); return
        }
        var messageId = uuid(); action({id:uuid(),kind:"send",session_key:selectedSession,message_id:messageId,text:value}); inputText=""; keyboardVisible=false
    }
    function filteredSessions() {
        var result=[]; var needle=searchText.toLowerCase()
        for (var i=0;i<sessions.length;i++) {
            var item=sessions[i]; if (!!item.hidden !== hiddenView) continue
            if (needle.length && String(item.title).toLowerCase().indexOf(needle)<0) continue
            result.push(item)
        }
        return result
    }
    function applySnapshot(text) {
        try {
            var snapshot=JSON.parse(text); agents=snapshot.agents||[]; sessions=snapshot.sessions||[]
            if (snapshot.selected_session_key === selectedSession) messages=snapshot.messages||[]
            statusText = snapshot.bridge && snapshot.bridge.last_error ? "Bridge issue" : "Online"
            refreshWeight++; if (refreshWeight >= 7) { refreshWeight=0; ghostBuster.forceClearNow("chat cadence") }
            if (conversationOpen) Qt.callLater(function(){ messageList.positionViewAtEnd() })
        } catch(e) { statusText="Invalid relay response" }
    }

    AppLoad {
        id: endpoint; applicationID: "chat"
        onMessageReceived: (type, contents) => {
            if (type === 101) root.applySnapshot(contents)
            else if (type === 102) root.statusText = contents === "CONNECTED" ? "Online" : contents
            else if (type === 103) root.statusText = contents
        }
    }

    Rectangle {
        id: topBar; anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
        height: 78 * unit; color: "#ffffff"; border.color: line; border.width: 1
        Text { anchors.left: parent.left; anchors.leftMargin: 30*unit; anchors.verticalCenter: parent.verticalCenter; text: conversationOpen ? selectedTitle : (hiddenView ? "Hidden" : "Conversations"); color: ink; font.family:"Noto Serif"; font.pixelSize:32*unit; font.weight:Font.DemiBold }
        Row {
            anchors.right: parent.right; anchors.rightMargin:20*unit; anchors.verticalCenter:parent.verticalCenter; spacing:10*unit
            Repeater {
                model: conversationOpen ? ["RENAME","PIN","ARCHIVE","HIDE"] : [hiddenView?"INBOX":"HIDDEN","SEARCH","NEW","EXIT"]
                Rectangle {
                    required property string modelData; width: 140*unit; height:54*unit; color:"#ffffff"; border.color:ink; border.width:2*unit
                    Text { anchors.centerIn:parent; text:modelData; font.family:"Noto Mono"; font.pixelSize:15*unit; font.weight:Font.Bold; color:ink }
                    MouseArea { anchors.fill:parent; onClicked: {
                        if(modelData==="EXIT") endpoint.terminate()
                        else if(modelData==="NEW"){inputMode="new";inputText="";keyboardVisible=true}
                        else if(modelData==="SEARCH"){inputMode="search";inputText=searchText;keyboardVisible=true}
                        else if(modelData==="HIDDEN"||modelData==="INBOX"){hiddenView=!hiddenView;searchText="";ghostBuster.forceClearNow("view")}
                        else if(modelData==="RENAME"){inputMode="rename";inputText=selectedTitle;keyboardVisible=true}
                        else if(modelData==="PIN") action({id:uuid(),kind:"pin",session_key:selectedSession,value:true})
                        else if(modelData==="ARCHIVE") action({id:uuid(),kind:"archive",session_key:selectedSession,value:true})
                        else if(modelData==="HIDE"){action({id:uuid(),kind:"hide",session_key:selectedSession,value:true});conversationOpen=false;endpoint.sendMessage(1,"")}
                    }}
                }
            }
        }
    }

    ListView {
        id: sessionList; visible: !conversationOpen && !keyboardVisible
        anchors.top:topBar.bottom; anchors.bottom:bottomBar.top; anchors.left:parent.left; anchors.right:parent.right; clip:true
        model: root.filteredSessions(); spacing:0
        delegate: Rectangle {
            required property var modelData; width:sessionList.width; height:112*unit; color:"#ffffff"; border.color:line; border.width:1
            Text { anchors.left:parent.left; anchors.leftMargin:34*unit; anchors.top:parent.top; anchors.topMargin:18*unit; width:parent.width-300*unit; text:(modelData.pinned?"●  ":"")+modelData.title; elide:Text.ElideRight; color:ink; font.family:"Noto Sans"; font.pixelSize:25*unit; font.weight: modelData.unread ? Font.Bold : Font.Normal }
            Text { anchors.left:parent.left; anchors.leftMargin:34*unit; anchors.bottom:parent.bottom; anchors.bottomMargin:18*unit; text:modelData.channel+"  ·  "+modelData.agent_id+(modelData.run_status==="working"?"  ·  WORKING":""); color:modelData.run_status==="working"?accent:muted; font.family:"Noto Mono"; font.pixelSize:15*unit }
            Text { anchors.right:parent.right; anchors.rightMargin:28*unit; anchors.verticalCenter:parent.verticalCenter; text:"›"; color:ink; font.pixelSize:42*unit }
            MouseArea { anchors.fill:parent; onClicked: root.hiddenView ? root.action({id:root.uuid(),kind:"restore",session_key:modelData.session_key,value:true}) : root.selectSession(modelData) }
        }
        Text { anchors.centerIn:parent; visible:sessionList.count===0; text:hiddenView?"No hidden conversations":"No conversations yet"; color:muted; font.family:"Noto Serif"; font.pixelSize:27*unit }
    }

    ListView {
        id: messageList; visible:conversationOpen && !keyboardVisible
        anchors.top:topBar.bottom; anchors.bottom:composer.top; anchors.left:parent.left; anchors.right:parent.right; anchors.margins:24*unit; clip:true; spacing:18*unit
        model:messages
        delegate: Item {
            required property var modelData; width:messageList.width; height:bubble.height
            Rectangle {
                id:bubble; width:Math.min(parent.width*0.78, messageText.implicitWidth+56*unit); height:Math.max(74*unit,messageText.implicitHeight+40*unit)
                anchors.right:modelData.role==="user"?parent.right:undefined; anchors.left:modelData.role==="user"?undefined:parent.left
                color:modelData.role==="user"?"#f1eee4":"#ffffff"; border.color:modelData.role==="assistant"?line:"#f1eee4"; border.width:1; radius:8*unit
                Text { id:messageText; anchors.fill:parent; anchors.margins:20*unit; text:modelData.body; textFormat:Text.MarkdownText; wrapMode:Text.Wrap; color:ink; font.family:"Noto Sans"; font.pixelSize:22*unit }
                Text { anchors.right:parent.right; anchors.bottom:parent.bottom; anchors.margins:8*unit; visible:modelData.status!=="complete"; text:modelData.status.toUpperCase(); color:accent; font.family:"Noto Mono"; font.pixelSize:11*unit }
            }
        }
    }

    Rectangle {
        id:composer; visible:conversationOpen && !keyboardVisible; anchors.left:parent.left; anchors.right:parent.right; anchors.bottom:bottomBar.top; height:88*unit; color:"#ffffff"; border.color:line; border.width:1
        Rectangle { anchors.left:parent.left; anchors.leftMargin:24*unit; anchors.right:sendButton.left; anchors.rightMargin:12*unit; anchors.verticalCenter:parent.verticalCenter; height:58*unit; border.color:ink; border.width:2*unit; color:"#fff"
            Text { anchors.left:parent.left; anchors.leftMargin:18*unit; anchors.verticalCenter:parent.verticalCenter; text:"Write a message…"; color:muted; font.family:"Noto Sans"; font.pixelSize:21*unit }
            MouseArea { anchors.fill:parent; onClicked:{inputMode="message";inputText="";keyboardVisible=true} }
        }
        Rectangle { id:sendButton; anchors.right:parent.right; anchors.rightMargin:24*unit; anchors.verticalCenter:parent.verticalCenter; width:150*unit; height:58*unit; color:ink
            Text { anchors.centerIn:parent; text:"WRITE"; color:"#fff"; font.family:"Noto Mono"; font.pixelSize:16*unit; font.weight:Font.Bold }
            MouseArea { anchors.fill:parent; onClicked:{inputMode="message";inputText="";keyboardVisible=true} }
        }
    }

    Rectangle {
        id:bottomBar; anchors.left:parent.left; anchors.right:parent.right; anchors.bottom:parent.bottom; height:62*unit; color:"#ffffff"; border.color:line; border.width:1
        Text { anchors.left:parent.left; anchors.leftMargin:24*unit; anchors.verticalCenter:parent.verticalCenter; text:statusText; color:statusText==="Online"?muted:accent; font.family:"Noto Mono"; font.pixelSize:14*unit }
        Row { anchors.right:parent.right; anchors.rightMargin:20*unit; anchors.verticalCenter:parent.verticalCenter; spacing:10*unit
            Repeater { model:conversationOpen?["BACK","STOP","RETRY","EXIT"]:["REFRESH","EXIT"]
                Rectangle { required property string modelData; width:112*unit; height:44*unit; color:"#fff"; border.color:ink; border.width:2*unit
                    Text { anchors.centerIn:parent;text:modelData;color:ink;font.family:"Noto Mono";font.pixelSize:14*unit;font.weight:Font.Bold }
                    MouseArea { anchors.fill:parent; onClicked:{
                        if(modelData==="EXIT")endpoint.terminate(); else if(modelData==="BACK"){conversationOpen=false;endpoint.sendMessage(1,"");ghostBuster.forceClearNow("back")}
                        else if(modelData==="REFRESH")endpoint.sendMessage(1,selectedSession)
                        else if(modelData==="STOP")action({id:uuid(),kind:"abort",session_key:selectedSession})
                        else if(modelData==="RETRY"&&messages.length){var m=messages[messages.length-1];action({id:uuid(),kind:"retry",session_key:selectedSession,message_id:uuid(),text:m.role==="user"?m.body:"Continue"})}
                    }}
                }
            }
        }
    }

    Rectangle {
        visible:keyboardVisible; anchors.top:topBar.bottom; anchors.bottom:bottomBar.top; anchors.left:parent.left; anchors.right:parent.right; color:"#ffffff"; z:20
        Text { anchors.left:parent.left; anchors.right:parent.right; anchors.top:parent.top; anchors.margins:24*unit; height:90*unit; text:inputText.length?inputText:"Type here"; color:inputText.length?ink:muted; wrapMode:Text.Wrap; font.family:"Noto Sans"; font.pixelSize:25*unit }
        Column { anchors.left:parent.left; anchors.right:parent.right; anchors.bottom:keyboardActions.top; anchors.margins:22*unit; spacing:8*unit
            Repeater { model:["1234567890","qwertyuiop","asdfghjkl","zxcvbnm.,?"]
                Row { required property string modelData; anchors.horizontalCenter:parent.horizontalCenter; spacing:8*unit
                    Repeater { model:modelData.split("")
                        Rectangle { required property string modelData; width:108*unit; height:72*unit; color:"#fff"; border.color:line; border.width:2*unit
                            Text { anchors.centerIn:parent; text:shift?modelData.toUpperCase():modelData; color:ink; font.family:"Noto Sans"; font.pixelSize:24*unit }
                            MouseArea { anchors.fill:parent; onClicked:inputText+=(shift?modelData.toUpperCase():modelData) }
                        }
                    }
                }
            }
        }
        Row { id:keyboardActions; anchors.left:parent.left; anchors.right:parent.right; anchors.bottom:parent.bottom; anchors.margins:22*unit; spacing:10*unit
            Repeater { model:["SHIFT","SPACE","⌫","CANCEL","DONE"]
                Rectangle { required property string modelData; width:modelData==="SPACE"?560*unit:220*unit; height:76*unit; color:modelData==="DONE"?ink:"#fff"; border.color:ink; border.width:2*unit
                    Text { anchors.centerIn:parent;text:modelData;color:modelData==="DONE"?"#fff":ink;font.family:"Noto Mono";font.pixelSize:17*unit;font.weight:Font.Bold }
                    MouseArea { anchors.fill:parent; onClicked:{if(modelData==="SHIFT")shift=!shift;else if(modelData==="SPACE")inputText+=" ";else if(modelData==="⌫")inputText=inputText.slice(0,-1);else if(modelData==="CANCEL")keyboardVisible=false;else submitInput()} }
                }
            }
        }
    }
}

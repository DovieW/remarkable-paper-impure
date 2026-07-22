import QtQuick 2.15
import net.asivery.AppLoad 1.0
import net.asivery.ApploadUtils
import xofm.libs.ghostbuster 1.0

Rectangle {
    id: root
    color: "#ffffff"
    focus: true
    signal close
    function unloading() { endpoint.terminate() }

    readonly property color ink: "#171713"
    readonly property color muted: "#68665f"
    readonly property color line: "#d8d5ca"
    readonly property color soft: "#eeeee9"
    readonly property color accent: "#c84c2d"
    readonly property real unit: Math.max(0.65, Math.min(width / 1872, height / 1404))

    property var agents: []
    property var sessions: []
    property var messages: []
    property var actions: []
    property string selectedSession: ""
    property string selectedTitle: "Chat"
    property string selectedAgent: ""
    property bool conversationOpen: false
    property string listMode: "inbox"
    property bool keyboardVisible: false
    property string inputMode: "message"
    property string editorText: ""
    property string draftText: ""
    property string searchText: ""
    property string statusText: "Connecting"
    property string pendingActionId: ""
    property string pendingKind: ""
    property string pendingLabel: ""
    property string pendingMessageId: ""
    property bool pendingAccepted: false
    property string resultText: ""
    property bool resultError: false
    property var undoAction: null
    property int refreshWeight: 0

    function uuid() {
        var seed = Date.now().toString(16) + Math.floor(Math.random() * 0x7fffffff).toString(16)
        while (seed.length < 32) seed += Math.floor(Math.random() * 0xffffffff).toString(16)
        return seed.slice(0,8) + "-" + seed.slice(8,12) + "-4" + seed.slice(13,16) + "-a" + seed.slice(17,20) + "-" + seed.slice(20,32)
    }
    function post(value) { endpoint.sendMessage(2, JSON.stringify(value)) }
    function currentSession() {
        for (var i=0;i<sessions.length;i++) if (sessions[i].session_key===selectedSession) return sessions[i]
        return null
    }
    function queueAction(value, label, undo) {
        if (pendingActionId.length) return false
        pendingActionId=value.id; pendingKind=value.kind; pendingLabel=label; pendingMessageId=value.message_id||""; pendingAccepted=false
        resultText=label+"…"; resultError=false; undoAction=undo||null
        post(value); return true
    }
    function selectSession(item) {
        selectedSession=item.session_key; selectedTitle=item.title; selectedAgent=item.agent_id
        conversationOpen=true; keyboardVisible=false; inputMode="message"; editorText=draftText
        endpoint.sendMessage(1,selectedSession)
        post({id:uuid(),kind:"mark_read",session_key:selectedSession,value:true})
        ghostBuster.forceClearNow("chat open")
    }
    function openEditor(mode, text) { inputMode=mode; editorText=text||""; keyboardVisible=true; forceActiveFocus() }
    function submitInput() {
        var value=editorText.trim(); if(!value.length||pendingActionId.length)return
        if(inputMode==="search"){searchText=value;keyboardVisible=false;ghostBuster.forceClearNow("search");return}
        if(inputMode==="rename"){
            queueAction({id:uuid(),kind:"rename",session_key:selectedSession,title:value},"Renaming",null)
            keyboardVisible=false;return
        }
        if(inputMode==="new"){
            var key="paperchat:"+uuid();var agent=selectedAgent||(agents.length?agents[0].id:"main")
            if(queueAction({id:uuid(),kind:"create",session_key:key,agent_id:agent,title:value},"Creating conversation",null)){
                selectedSession=key;selectedTitle=value;selectedAgent=agent;conversationOpen=true;keyboardVisible=false;endpoint.sendMessage(1,key)
            }
            return
        }
        var messageId=uuid(),actionId=uuid()
        draftText=editorText
        queueAction({id:actionId,kind:"send",session_key:selectedSession,message_id:messageId,text:value},"Sending",null)
    }
    function filteredSessions() {
        var result=[],needle=searchText.toLowerCase()
        for(var i=0;i<sessions.length;i++){
            var item=sessions[i],matches=listMode==="removed"?!!item.hidden:listMode==="archived"?!item.hidden&&!!item.archived:!item.hidden&&!item.archived
            if(!matches)continue
            if(needle.length&&String(item.title).toLowerCase().indexOf(needle)<0)continue
            result.push(item)
        }
        return result
    }
    function lastUserMessage(status) {
        for(var i=messages.length-1;i>=0;i--)if(messages[i].role==="user"&&(!status||messages[i].status===status))return messages[i]
        return null
    }
    function contextualActions() {
        var item=currentSession(),result=[]
        if(!item)return result
        result.push(item.pinned?"UNPIN":"PIN");result.push("RENAME")
        result.push(item.archived?"RESTORE ARCHIVE":"ARCHIVE")
        result.push(item.hidden?"RESTORE":"REMOVE")
        if(item.run_status==="working")result.push("STOP")
        else {
            if(lastUserMessage("failed"))result.push("RETRY")
            if(lastUserMessage("complete"))result.push("REGENERATE")
        }
        return result
    }
    function activateConversationAction(label) {
        var item=currentSession(),id=uuid();if(!item||pendingActionId.length)return
        if(label==="PIN"||label==="UNPIN")queueAction({id:id,kind:"pin",session_key:selectedSession,value:label==="PIN"},label==="PIN"?"Pinning":"Unpinning",{kind:"pin",value:label!=="PIN"})
        else if(label==="RENAME")openEditor("rename",selectedTitle)
        else if(label==="ARCHIVE"||label==="RESTORE ARCHIVE")queueAction({id:id,kind:"archive",session_key:selectedSession,value:label==="ARCHIVE"},label==="ARCHIVE"?"Archiving":"Restoring",{kind:"archive",value:label!=="ARCHIVE"})
        else if(label==="REMOVE")queueAction({id:id,kind:"hide",session_key:selectedSession,value:true},"Removing from Inbox",{kind:"restore",value:true})
        else if(label==="RESTORE")queueAction({id:id,kind:"restore",session_key:selectedSession,value:true},"Restoring",{kind:"hide",value:true})
        else if(label==="STOP")queueAction({id:id,kind:"abort",session_key:selectedSession},"Stopping",null)
        else if(label==="RETRY"){
            var failed=lastUserMessage("failed");if(failed)queueAction({id:id,kind:"retry",session_key:selectedSession,message_id:failed.id,text:failed.body},"Retrying",null)
        } else if(label==="REGENERATE"){
            var latest=lastUserMessage("complete");if(latest)queueAction({id:id,kind:"regenerate",session_key:selectedSession,text:latest.body},"Regenerating",null)
        }
    }
    function undoLast() {
        if(!undoAction||pendingActionId.length)return
        var value={id:uuid(),kind:undoAction.kind,session_key:selectedSession,value:undoAction.value}
        undoAction=null;queueAction(value,"Undoing",null)
    }
    function updatePending() {
        if(!pendingActionId.length)return
        var row=null
        for(var i=0;i<actions.length;i++)if(actions[i].id===pendingActionId){row=actions[i];break}
        if(!row)return
        if(!pendingAccepted&&(row.status==="queued"||row.status==="processing"||row.status==="completed"||row.status==="failed")){
            pendingAccepted=true
            if(pendingKind==="send"){draftText="";editorText=""}
        }
        if(row.status==="queued")resultText=pendingLabel+" · queued"
        else if(row.status==="processing")resultText=pendingLabel+" · working"
        else if(row.status==="completed"){
            resultText=pendingLabel.replace(/ing$/,"ed");resultError=false
            if(pendingKind==="hide"){conversationOpen=false;listMode="removed";endpoint.sendMessage(1,"")}
            pendingActionId="";pendingKind="";pendingLabel="";pendingMessageId=""
        } else if(row.status==="failed"){
            resultText=row.detail&&row.detail.length?row.detail:"Action failed";resultError=true
            pendingActionId="";pendingKind="";pendingLabel="";pendingMessageId="";undoAction=null
        }
    }
    function applySnapshot(text) {
        try {
            var snapshot=JSON.parse(text);agents=snapshot.agents||[];sessions=snapshot.sessions||[];actions=snapshot.actions||[]
            if(snapshot.selected_session_key===selectedSession)messages=snapshot.messages||[]
            var item=currentSession();if(item){selectedTitle=item.title;selectedAgent=item.agent_id}
            statusText=snapshot.bridge&&snapshot.bridge.last_error?"Bridge issue":"Online"
            updatePending()
            refreshWeight++;if(refreshWeight>=7){refreshWeight=0;ghostBuster.forceClearNow("chat cadence")}
            if(conversationOpen)Qt.callLater(function(){messageList.positionViewAtEnd()})
        }catch(e){statusText="Invalid relay response"}
    }
    function appendEditor(value){if(editorText.length+value.length<=16384){editorText+=value;if(inputMode==="message")draftText=editorText}}
    function backspaceEditor(){editorText=editorText.slice(0,-1);if(inputMode==="message")draftText=editorText}

    Keys.onPressed: function(event) {
        if(!keyboardVisible)return
        if(event.key===Qt.Key_Backspace){backspaceEditor();event.accepted=true}
        else if((event.key===Qt.Key_Return||event.key===Qt.Key_Enter)&&(event.modifiers&Qt.ControlModifier)){submitInput();event.accepted=true}
        else if(event.key===Qt.Key_Return||event.key===Qt.Key_Enter){appendEditor("\n");event.accepted=true}
        else if(event.key===Qt.Key_Escape){keyboardVisible=false;event.accepted=true}
        else if(event.text&&event.text.length){appendEditor(event.text);event.accepted=true}
    }

    AppLoad {
        id:endpoint;applicationID:"chat"
        onMessageReceived:(type,contents)=>{
            if(type===101)root.applySnapshot(contents)
            else if(type===102)root.statusText=contents==="CONNECTED"?"Online":contents
            else if(type===103){root.statusText=contents;root.resultText=contents;root.resultError=true}
        }
    }

    Rectangle {
        id:navigationBar;anchors.left:parent.left;anchors.right:parent.right;anchors.top:parent.top;height:68*unit;color:"#ffffff";border.color:line;border.width:1
        Rectangle {
            visible:conversationOpen;anchors.left:parent.left;anchors.leftMargin:18*unit;anchors.verticalCenter:parent.verticalCenter;width:110*unit;height:44*unit;color:backTap.pressed?ink:"#fff";border.color:ink;border.width:2*unit
            Text{anchors.centerIn:parent;text:"BACK";color:parent.color===ink?"#fff":ink;font.family:"Noto Mono";font.pixelSize:14*unit;font.bold:true}
            MouseArea{id:backTap;anchors.fill:parent;onClicked:{conversationOpen=false;keyboardVisible=false;endpoint.sendMessage(1,"");ghostBuster.forceClearNow("chat back")}}
        }
        Text{anchors.left:parent.left;anchors.leftMargin:conversationOpen?150*unit:28*unit;anchors.verticalCenter:parent.verticalCenter;width:parent.width-520*unit;text:conversationOpen?selectedTitle:"Chat";elide:Text.ElideRight;color:ink;font.family:"Noto Serif";font.pixelSize:30*unit;font.weight:Font.DemiBold}
        Text{anchors.right:exitButton.left;anchors.rightMargin:24*unit;anchors.verticalCenter:parent.verticalCenter;text:(currentSession()&&currentSession().run_status==="working")?"WORKING":statusText.toUpperCase();color:(statusText==="Online"&&(!currentSession()||currentSession().run_status!=="working"))?muted:accent;font.family:"Noto Mono";font.pixelSize:14*unit;font.bold:true}
        Rectangle{id:exitButton;anchors.right:parent.right;anchors.rightMargin:18*unit;anchors.verticalCenter:parent.verticalCenter;width:92*unit;height:44*unit;color:exitTap.pressed?"#fff":ink;border.color:ink;border.width:2*unit;Text{anchors.centerIn:parent;text:"EXIT";color:parent.color===ink?"#fff":ink;font.family:"Noto Mono";font.pixelSize:14*unit;font.bold:true}MouseArea{id:exitTap;anchors.fill:parent;onClicked:endpoint.terminate()}}
    }

    Rectangle {
        id:actionBar;anchors.left:parent.left;anchors.right:parent.right;anchors.top:navigationBar.bottom;height:72*unit;color:"#ffffff";border.color:line;border.width:1
        Row {
            anchors.centerIn:parent;spacing:10*unit
            Repeater {
                model:conversationOpen?root.contextualActions():["INBOX","ARCHIVED","REMOVED","SEARCH","NEW"]
                Rectangle {
                    required property string modelData
                    width:Math.max(145*unit,Math.min(235*unit,(actionBar.width-80*unit)/Math.max(5,parent.children.length)-10*unit));height:50*unit
                    color:buttonTap.pressed||(!conversationOpen&&modelData.toLowerCase()===listMode)?ink:"#fff";border.color:ink;border.width:2*unit
                    opacity:pendingActionId.length&&conversationOpen&&modelData!=="RENAME"?0.48:1
                    Text{anchors.centerIn:parent;text:modelData;color:parent.color===ink?"#fff":ink;font.family:"Noto Mono";font.pixelSize:14*unit;font.bold:true}
                    MouseArea {
                        id:buttonTap;anchors.fill:parent;enabled:!(pendingActionId.length&&conversationOpen)
                        onClicked:{
                            if(conversationOpen)root.activateConversationAction(modelData)
                            else if(modelData==="SEARCH")root.openEditor("search",searchText)
                            else if(modelData==="NEW")root.openEditor("new","")
                            else{listMode=modelData.toLowerCase();searchText="";ghostBuster.forceClearNow("chat list")}
                        }
                    }
                }
            }
        }
    }

    Rectangle {
        id:resultStrip;visible:resultText.length>0;anchors.left:parent.left;anchors.right:parent.right;anchors.top:actionBar.bottom;height:62*unit;color:resultError?"#f5ddd7":"#f1f1ec";border.color:resultError?accent:line;border.width:1
        Text{anchors.left:parent.left;anchors.leftMargin:26*unit;anchors.right:resultButtons.left;anchors.rightMargin:12*unit;anchors.verticalCenter:parent.verticalCenter;text:resultText;color:resultError?accent:ink;elide:Text.ElideRight;font.family:"Noto Sans";font.pixelSize:18*unit}
        Row{id:resultButtons;anchors.right:parent.right;anchors.rightMargin:18*unit;anchors.verticalCenter:parent.verticalCenter;spacing:12*unit
            Text{visible:undoAction!==null&&!pendingActionId.length;text:"UNDO";color:ink;font.family:"Noto Mono";font.pixelSize:15*unit;font.bold:true;MouseArea{anchors.fill:parent;anchors.margins:-12*unit;onClicked:root.undoLast()}}
            Text{text:"DISMISS";color:ink;font.family:"Noto Mono";font.pixelSize:15*unit;font.bold:true;MouseArea{anchors.fill:parent;anchors.margins:-12*unit;onClicked:{resultText="";resultError=false;undoAction=null}}}
        }
    }

    ListView {
        id:sessionList;visible:!conversationOpen
        anchors.top:resultStrip.visible?resultStrip.bottom:actionBar.bottom;anchors.bottom:keyboardVisible?editorPanel.top:parent.bottom;anchors.left:parent.left;anchors.right:parent.right;clip:true
        model:root.filteredSessions();spacing:0
        delegate:Rectangle {
            required property var modelData;width:sessionList.width;height:112*unit;color:"#fff";border.color:line;border.width:1
            Text{anchors.left:parent.left;anchors.leftMargin:34*unit;anchors.top:parent.top;anchors.topMargin:18*unit;width:parent.width-340*unit;text:(modelData.pinned?"●  ":"")+modelData.title;elide:Text.ElideRight;color:ink;font.family:"Noto Sans";font.pixelSize:25*unit;font.weight:modelData.unread?Font.Bold:Font.Normal}
            Text{anchors.left:parent.left;anchors.leftMargin:34*unit;anchors.bottom:parent.bottom;anchors.bottomMargin:18*unit;text:modelData.channel+"  ·  "+modelData.agent_id+(modelData.run_status==="working"?"  ·  WORKING":"");color:modelData.run_status==="working"?accent:muted;font.family:"Noto Mono";font.pixelSize:15*unit}
            Rectangle{visible:listMode!=="inbox";anchors.right:parent.right;anchors.rightMargin:24*unit;anchors.verticalCenter:parent.verticalCenter;width:150*unit;height:50*unit;color:restoreTap.pressed?ink:"#fff";border.color:ink;border.width:2*unit;Text{anchors.centerIn:parent;text:"RESTORE";color:parent.color===ink?"#fff":ink;font.family:"Noto Mono";font.pixelSize:14*unit;font.bold:true}MouseArea{id:restoreTap;anchors.fill:parent;onClicked:{selectedSession=modelData.session_key;selectedTitle=modelData.title;selectedAgent=modelData.agent_id;endpoint.sendMessage(1,selectedSession);if(listMode==="removed")root.queueAction({id:root.uuid(),kind:"restore",session_key:modelData.session_key,value:true},"Restoring",null);else root.queueAction({id:root.uuid(),kind:"archive",session_key:modelData.session_key,value:false},"Restoring",null)}}}
            Text{visible:listMode==="inbox";anchors.right:parent.right;anchors.rightMargin:28*unit;anchors.verticalCenter:parent.verticalCenter;text:"›";color:ink;font.pixelSize:42*unit}
            MouseArea{anchors.left:parent.left;anchors.right:listMode==="inbox"?parent.right:parent.right;anchors.rightMargin:listMode==="inbox"?0:200*unit;anchors.top:parent.top;anchors.bottom:parent.bottom;onClicked:root.selectSession(modelData)}
        }
        Text{anchors.centerIn:parent;visible:sessionList.count===0;text:listMode==="removed"?"No removed conversations":listMode==="archived"?"No archived conversations":"No conversations yet";color:muted;font.family:"Noto Serif";font.pixelSize:27*unit}
    }

    ListView {
        id:messageList;visible:conversationOpen
        anchors.top:resultStrip.visible?resultStrip.bottom:actionBar.bottom;anchors.bottom:editorPanel.top;anchors.left:parent.left;anchors.right:parent.right;anchors.margins:24*unit;clip:true;spacing:18*unit
        model:messages
        delegate:Item {
            required property var modelData;width:messageList.width;height:bubble.height
            Rectangle{id:bubble;width:Math.min(parent.width*0.78,messageText.implicitWidth+56*unit);height:Math.max(74*unit,messageText.implicitHeight+40*unit);anchors.right:modelData.role==="user"?parent.right:undefined;anchors.left:modelData.role==="user"?undefined:parent.left;color:modelData.role==="user"?"#f1eee4":"#fff";border.color:modelData.status==="failed"?accent:line;border.width:1;radius:8*unit
                Text{id:messageText;anchors.fill:parent;anchors.margins:20*unit;text:modelData.body;textFormat:Text.MarkdownText;wrapMode:Text.Wrap;color:ink;font.family:"Noto Sans";font.pixelSize:22*unit}
                Text{anchors.right:parent.right;anchors.bottom:parent.bottom;anchors.margins:8*unit;visible:modelData.status!=="complete";text:modelData.status.toUpperCase();color:accent;font.family:"Noto Mono";font.pixelSize:11*unit}
            }
        }
    }

    Rectangle {
        id:editorPanel;visible:conversationOpen||keyboardVisible;anchors.left:parent.left;anchors.right:parent.right;anchors.bottom:keyboardVisible?chatKeyboard.top:parent.bottom;height:keyboardVisible?118*unit:88*unit;color:"#fff";border.color:line;border.width:1
        Text{anchors.left:parent.left;anchors.leftMargin:24*unit;anchors.top:parent.top;anchors.topMargin:12*unit;text:inputMode==="message"?"MESSAGE":inputMode.toUpperCase();color:muted;font.family:"Noto Mono";font.pixelSize:13*unit;font.bold:true}
        Text{anchors.left:parent.left;anchors.leftMargin:24*unit;anchors.right:writeButton.left;anchors.rightMargin:18*unit;anchors.bottom:parent.bottom;anchors.bottomMargin:14*unit;height:keyboardVisible?68*unit:48*unit;text:editorText.length?editorText:(inputMode==="message"?"Write a message…":"Type here…");color:editorText.length?ink:muted;wrapMode:Text.Wrap;elide:Text.ElideRight;font.family:"Noto Sans";font.pixelSize:21*unit;MouseArea{anchors.fill:parent;enabled:conversationOpen&&inputMode==="message";onClicked:root.openEditor("message",draftText)}}
        Rectangle{id:writeButton;visible:!keyboardVisible;anchors.right:parent.right;anchors.rightMargin:24*unit;anchors.verticalCenter:parent.verticalCenter;width:150*unit;height:56*unit;color:writeTap.pressed?"#fff":ink;border.color:ink;border.width:2*unit;Text{anchors.centerIn:parent;text:"WRITE";color:parent.color===ink?"#fff":ink;font.family:"Noto Mono";font.pixelSize:15*unit;font.bold:true}MouseArea{id:writeTap;anchors.fill:parent;onClicked:root.openEditor("message",draftText)}}
    }

    OnScreenKeyboard {
        id:chatKeyboard;visible:keyboardVisible;anchors.left:parent.left;anchors.right:parent.right;anchors.bottom:parent.bottom;height:470*unit;terminalMode:false;unitScale:root.unit;ink:root.ink;paper:"#fff";rule:root.line;soft:root.soft
        onTextRequested:function(value){root.appendEditor(value)}
        onKeyRequested:function(value){if(value==="backspace")root.backspaceEditor()}
        onSubmitRequested:root.submitInput()
        onCancelRequested:{keyboardVisible=false;if(inputMode!=="message")editorText=draftText;inputMode="message"}
    }

    Timer{interval:350;running:true;repeat:false;onTriggered:ghostBuster.forceClearNow("chat initial")}
}

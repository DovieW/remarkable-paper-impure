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
    readonly property color paper: "#ffffff"
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
    property string mode: "dashboard"
    property var screenMessages: []
    property var screenSession: null
    property int screenIndex: Math.max(0, screenMessages.length - 1)
    property string pendingPresentedMessageId: ""
    readonly property var currentScreen: screenMessages.length ? screenMessages[screenIndex] : ({})
    property var selectedValues: ({})
    property double lastInteractionAt: Date.now()
    property string readerTitle: "Web reader"
    property string readerBody: ""
    property string readerUrl: ""
    property var readerLinks: []
    property var readerHistory: []
    property int readerHistoryIndex: -1
    property var readerBookmarks: []
    property bool readerBookmarked: false
    property bool readerLoading: false
    property bool readerKeyboardVisible: false
    property bool readerUppercase: false
    property bool readerBookmarkView: false
    property bool readerHistoryView: false
    property bool readerMenuView: false
    property string readerInput: ""
    property string readerNavigationMode: "push"
    property string toastText: ""
    property string lastAction: ""
    property string lastResult: ""
    property string pendingDismissCardId: ""

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
        // QML readonly bindings are reevaluated after imperative assignments.
        // Read the indexed message directly so a presentation target cannot be
        // acknowledged as the previously visible message in the same event.
        var reportedScreen = screenMessages.length && screenIndex >= 0 && screenIndex < screenMessages.length
            ? screenMessages[screenIndex] : ({})
        endpoint.sendMessage(6, JSON.stringify({
            application: "paperboard", protocol_version: 2, mode: mode,
            foreground: true, rendered_cursor: cursor,
            visible_card_id: currentCard.id || null, visible_index: cards.length ? currentIndex : null,
            card_count: cards.length, ambient_mode: ambientMode, controls_visible: controlsVisible,
            history_index: mode === "screen" && screenMessages.length ? screenIndex : null,
            history_count: screenMessages.length,
            scroll_offset: mode === "screen" ? screenFlick.contentY : (mode === "reader" ? readerFlick.contentY : 0),
            active_session_id: reportedScreen.session_id || null,
            active_message_id: reportedScreen.id || null,
            last_interaction_at: new Date(lastInteractionAt).toISOString(),
            last_action: lastAction, last_result: lastResult
        }))
    }

    function touchActivity() {
        lastInteractionAt = Date.now()
        screenHandoffTimer.restart()
    }

    function cancelPendingDismiss() {
        if (!pendingDismissCardId.length) return
        pendingDismissCardId = ""
        dismissConfirmTimer.stop()
        visualChanged(1)
    }

    function requestDismissCard() {
        if (!currentCard.id) {
            showToast("No card to dismiss")
            return
        }
        if (pendingDismissCardId === currentCard.id) {
            var dismissedCardId = currentCard.id
            pendingDismissCardId = ""
            dismissConfirmTimer.stop()
            endpoint.sendMessage(4, dismissedCardId)
            lastAction = "dismiss"
            lastResult = "Dismiss requested"
            showToast(lastResult)
            reportState()
            return
        }
        pendingDismissCardId = currentCard.id
        dismissConfirmTimer.restart()
        showControls()
        showToast("Tap Confirm Dismiss")
    }

    function setMode(nextMode, notify) {
        if (nextMode !== "dashboard" && nextMode !== "screen" && nextMode !== "reader") return
        cancelPendingDismiss()
        mode = nextMode
        if (mode !== "reader") readerKeyboardVisible = false
        if (mode === "screen" || mode === "reader") screenHandoffTimer.restart()
        else screenHandoffTimer.stop()
        visualChanged(2)
        if (notify !== false) showToast(mode === "screen" ? "Screen" : (mode === "reader" ? "Browser" : "Dashboard"))
        stateReportTimer.restart()
    }

    function applySnapshot(contents) {
        var previousId = currentCard.id || ""
        var snapshot
        try { snapshot = JSON.parse(contents) }
        catch (error) { backendState = "ERROR"; backendDetail = "Relay returned invalid JSON"; return }
        cards = snapshot.cards || []
        var previousScreenId = currentScreen.id || ""
        screenSession = snapshot.screen ? snapshot.screen.session : null
        screenMessages = snapshot.screen ? (snapshot.screen.messages || []) : []
        screenIndex = Math.max(0, screenMessages.length - 1)
        var presentedMessageFound = false
        var durableTarget = snapshot.presentation ? (snapshot.presentation.screen_message_id || "") : ""
        if (durableTarget !== "") pendingPresentedMessageId = durableTarget
        if (pendingPresentedMessageId !== "") {
            var normalizedPresentedId = String(pendingPresentedMessageId)
            for (var presentedCandidate = 0; presentedCandidate < screenMessages.length; presentedCandidate++) {
                if (String(screenMessages[presentedCandidate].id || "") === normalizedPresentedId) {
                    screenIndex = presentedCandidate
                    pendingPresentedMessageId = ""
                    presentedMessageFound = true
                    mode = "screen"
                    lastAction = "presentation_target"
                    lastResult = "Target selected"
                    break
                }
            }
            if (!presentedMessageFound) {
                lastAction = "presentation_target"
                lastResult = "Target pending"
            }
        }
        if (!presentedMessageFound) {
            for (var screenCandidate = 0; screenCandidate < screenMessages.length; screenCandidate++)
                if (screenMessages[screenCandidate].id === previousScreenId) screenIndex = screenCandidate
        }
        if (snapshot.ui_state && snapshot.ui_state.mode && lastAppliedAt === 0)
            mode = ["screen", "reader"].indexOf(snapshot.ui_state.mode) >= 0 ? snapshot.ui_state.mode : "dashboard"
        if (screenMessages.length && (currentScreen.id || "") !== previousScreenId) {
            screenFlick.contentY = 0
            touchActivity()
        }
        cursor = snapshot.cursor || 0
        currentIndex = 0
        for (var index = 0; index < cards.length; index++) {
            if (cards[index].id === previousId) { currentIndex = index; break }
        }
        if (pendingDismissCardId.length && pendingDismissCardId !== (currentCard.id || "")) cancelPendingDismiss()
        backendState = cards.length > 0 ? "LIVE" : "CLEAR"
        backendDetail = cards.length > 0 ? cards.length + " queued card" + (cards.length === 1 ? "" : "s") : "No queued output"
        lastAppliedAt = Date.now()
        visualChanged(2)
        if (ambientMode) selectAmbient(false)
        stateReportTimer.restart()
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
        cancelPendingDismiss()
        ambientMode = false
        currentIndex = (currentIndex + delta + cards.length) % cards.length
        lastAction = delta < 0 ? "previous" : "next"
        lastResult = "Showing card " + (currentIndex + 1) + " of " + cards.length
        visualChanged(1)
        showToast(lastResult)
        reportState()
    }

    function moveScreen(delta) {
        if (!screenMessages.length) return
        cancelPendingDismiss()
        screenIndex = Math.max(0, Math.min(screenMessages.length - 1, screenIndex + delta))
        screenFlick.contentY = 0
        selectedValues = ({})
        touchActivity(); visualChanged(1)
        showToast("Screen " + (screenIndex + 1) + " of " + screenMessages.length)
        reportState()
    }

    function submitScreenAction(action, value) {
        if (!currentScreen.id || !currentScreen.session_id) return
        endpoint.sendMessage(8, JSON.stringify({ session_id: currentScreen.session_id,
            message_id: currentScreen.id, action_id: action.id, value: value }))
        touchActivity(); showToast("Response sent")
    }

    function readerIsSaved(url) {
        for (var index = 0; index < readerBookmarks.length; index++)
            if (readerBookmarks[index].url === url) return true
        return false
    }

    function applyReaderPage(page) {
        var normalized = {
            url: page.url || "", title: page.title || "Web reader",
            body: page.body || "", links: page.links || []
        }
        readerTitle = normalized.title
        readerBody = normalized.body
        readerUrl = normalized.url
        readerInput = normalized.url
        readerLinks = normalized.links
        readerBookmarks = page.bookmarks || readerBookmarks
        readerBookmarked = page.bookmarked === true || readerIsSaved(normalized.url)
        if (readerNavigationMode === "reload" && readerHistoryIndex >= 0) {
            var replaced = readerHistory.slice(0)
            replaced[readerHistoryIndex] = normalized
            readerHistory = replaced
        } else {
            var next = readerHistory.slice(0, readerHistoryIndex + 1)
            next.push(normalized)
            if (next.length > 25) next.shift()
            readerHistory = next
            readerHistoryIndex = next.length - 1
        }
        readerNavigationMode = "push"
        readerLoading = false
        readerBookmarkView = false
        readerHistoryView = false
        readerMenuView = false
        readerFlick.contentY = 0
        setMode("reader", false)
        fullRefresh()
    }

    function readerNavigate(input, behavior) {
        var value = String(input || "").trim()
        if (!value.length) { showToast("Enter an address or search"); return }
        readerNavigationMode = behavior || "push"
        readerKeyboardVisible = false
        readerBookmarkView = false
        readerHistoryView = false
        readerMenuView = false
        readerLoading = true
        readerInput = value
        readerTitle = "Opening…"
        readerBody = "Fetching a simplified, script-free public page."
        readerLinks = []
        setMode("reader", false)
        endpoint.sendMessage(9, JSON.stringify({input: value}))
        showToast("Loading")
    }

    function readerShowHistory(index) {
        if (index < 0 || index >= readerHistory.length) return
        readerHistoryIndex = index
        var page = readerHistory[index]
        readerTitle = page.title; readerBody = page.body; readerUrl = page.url
        readerInput = page.url; readerLinks = page.links || []
        readerBookmarked = readerIsSaved(page.url)
        readerBookmarkView = false; readerHistoryView = false; readerMenuView = false
        readerLoading = false; readerFlick.contentY = 0
        touchActivity(); visualChanged(2); fullRefresh()
    }

    function readerHistoryEntries() {
        var entries = []
        for (var index = readerHistory.length - 1; index >= 0; index--) {
            var page = readerHistory[index]
            entries.push({
                history_index: index,
                title: page.title || page.url || "Untitled page",
                url: page.url || ""
            })
        }
        return entries
    }

    function readerMenuEntries() {
        var entries = [{action: "address", label: "NEW ADDRESS OR SEARCH"}]
        if (readerUrl.length) entries.push({action: "resume", label: "RESUME CURRENT PAGE"})
        entries.push({action: "history", label: "HISTORY · " + readerHistory.length})
        entries.push({action: "bookmarks", label: "BOOKMARKS · " + readerBookmarks.length})
        entries.push({action: "dashboard", label: "RETURN TO DASHBOARD"})
        return entries
    }

    function readerOpenMenu() {
        readerKeyboardVisible = false
        readerBookmarkView = false
        readerHistoryView = false
        readerMenuView = true
        readerFlick.contentY = 0
        setMode("reader", false)
        touchActivity(); visualChanged(2)
    }

    function readerOpenAddress(clearInput) {
        readerMenuView = false
        readerBookmarkView = false
        readerHistoryView = false
        if (clearInput) readerInput = ""
        readerKeyboardVisible = true
        touchActivity(); visualChanged(2)
    }

    function readerMenuSelect(action) {
        if (action === "address") readerOpenAddress(true)
        else if (action === "resume") {
            readerMenuView = false
            readerFlick.contentY = 0
            touchActivity(); visualChanged(2)
        }
        else if (action === "history") {
            readerMenuView = false; readerBookmarkView = false; readerHistoryView = true
            readerFlick.contentY = 0; touchActivity(); visualChanged(2)
        }
        else if (action === "bookmarks") {
            readerMenuView = false; readerHistoryView = false; readerBookmarkView = true
            readerFlick.contentY = 0; touchActivity(); visualChanged(2)
        }
        else if (action === "dashboard") setMode("dashboard", true)
    }

    function readerBack() {
        if (readerKeyboardVisible) { readerKeyboardVisible = false; readerOpenMenu(); return }
        if (readerMenuView || readerHistoryView || readerBookmarkView) { readerOpenMenu(); return }
        if (readerHistoryIndex > 0) readerShowHistory(readerHistoryIndex - 1)
        else setMode("dashboard", true)
    }
    function readerForward() { readerShowHistory(readerHistoryIndex + 1) }
    function readerReload() {
        if (readerUrl.length) readerNavigate(readerUrl, "reload")
        else readerOpenAddress(true)
    }

    function readerToggleBookmark() {
        if (!readerUrl.length) { showToast("Nothing to save"); return }
        endpoint.sendMessage(10, JSON.stringify({url: readerUrl, title: readerTitle || readerUrl}))
        showToast(readerBookmarked ? "Removing bookmark" : "Saving bookmark")
    }

    function readerKey(value) {
        if (value === "BACKSPACE") readerInput = readerInput.slice(0, -1)
        else if (value === "SPACE") readerInput += " "
        else if (value === "CLEAR") readerInput = ""
        else readerInput += value
        touchActivity(); visualChanged(1)
    }

    function openReader(action) {
        submitScreenAction(action, action.url)
        readerNavigate(action.url, "push")
    }

    function toggleScreenValue(action, option) {
        var values = selectedValues[action.id] ? selectedValues[action.id].slice(0) : []
        var position = values.indexOf(option.id)
        if (position >= 0) values.splice(position, 1); else values.push(option.id)
        var next = {}; for (var key in selectedValues) next[key] = selectedValues[key]
        next[action.id] = values; selectedValues = next
        touchActivity(); visualChanged(1)
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
        else if (command.action === "show_dashboard") setMode("dashboard", true)
        else if (command.action === "show_screen") {
            pendingPresentedMessageId = command.target_id || ""
            if (pendingPresentedMessageId !== "") {
                var normalizedCommandTarget = String(pendingPresentedMessageId)
                for (var targetCandidate = 0; targetCandidate < screenMessages.length; targetCandidate++) {
                    if (String(screenMessages[targetCandidate].id || "") === normalizedCommandTarget) {
                        screenIndex = targetCandidate
                        pendingPresentedMessageId = ""
                        lastAction = "presentation_target"
                        lastResult = "Target selected"
                        break
                    }
                }
            } else screenIndex = Math.max(0, screenMessages.length - 1)
            screenFlick.contentY = 0
            setMode("screen", true)
        }
        else if (command.action === "exit") { endpoint.sendMessage(7, JSON.stringify({id: command.id, status: "completed", detail: "Exiting to launcher"})); returnToLauncher(); return }
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
    Timer { id: stateReportTimer; interval: 50; repeat: false; onTriggered: root.reportState() }
    Timer { id: chromeTimer; interval: 6000; repeat: false; onTriggered: root.hideControls() }
    Timer { id: toastTimer; interval: 2000; repeat: false; onTriggered: { root.toastText = ""; root.visualChanged(1) } }
    Timer { id: dismissConfirmTimer; interval: 5000; repeat: false; onTriggered: root.cancelPendingDismiss() }
    Timer { id: screenHandoffTimer; interval: 60 * 60 * 1000; repeat: false; onTriggered: root.setMode("dashboard", true) }
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
                if (root.mode === "reader" && root.readerLoading) {
                    root.readerLoading = false
                    root.readerTitle = "Page unavailable"
                    root.readerBody = contents
                    root.fullRefresh()
                }
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
            } else if (type === 108) {
                try {
                    var page = JSON.parse(contents)
                    root.applyReaderPage(page)
                } catch (error) { root.showToast("Reader response invalid") }
            } else if (type === 109) {
                try {
                    var bookmarkState = JSON.parse(contents)
                    root.readerBookmarks = bookmarkState.bookmarks || []
                    root.readerBookmarked = root.readerIsSaved(root.readerUrl)
                    root.visualChanged(1)
                    if (root.readerUrl.length) root.showToast(root.readerBookmarked ? "Bookmark saved" : "Bookmark removed")
                } catch (error) { root.showToast("Bookmark response invalid") }
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

        Rectangle {
            anchors.top: parent.top
            width: parent.width
            height: masthead.height
            visible: root.controlsVisible
            color: paper
            z: 9
        }

        Column {
            id: masthead
            width: parent.width
            height: 148 * root.unit
            spacing: 8 * root.unit
            visible: root.controlsVisible
            z: 10

            Row {
                id: primaryNavigation
                width: parent.width
                height: 78 * root.unit
                spacing: 12 * root.unit

                Repeater {
                    model: [
                        {label: "DASHBOARD", target: "dashboard"},
                        {label: "SCREEN", target: "screen"},
                        {label: "BROWSE", target: "reader"}
                    ]
                    Rectangle {
                        id: destinationButton
                        required property var modelData
                        width: 230 * root.unit
                        height: primaryNavigation.height
                        property bool active: root.mode === modelData.target
                        color: active ? ink : paper
                        border.width: 2 * root.unit
                        border.color: ink
                        Text {
                            anchors.centerIn: parent
                            text: destinationButton.modelData.label
                            color: destinationButton.active ? paper : ink
                            font.family: "Noto Mono"
                            font.pixelSize: 16 * root.unit
                            font.weight: Font.Bold
                        }
                        MouseArea {
                            anchors.fill: parent
                            onPressed: root.showControls()
                            onClicked: {
                                if (destinationButton.modelData.target === "reader") root.readerOpenMenu()
                                else root.setMode(destinationButton.modelData.target, true)
                            }
                        }
                    }
                }

                Item {
                    width: Math.max(0, primaryNavigation.width - (3 * 230 + 190 + 150 + 5 * 12) * root.unit)
                    height: 1
                }

                Repeater {
                    model: [
                        {label: "REFRESH", action: "refresh", width: 190},
                        {label: "EXIT", action: "exit", width: 150}
                    ]
                    Rectangle {
                        id: globalButton
                        required property var modelData
                        width: modelData.width * root.unit
                        height: primaryNavigation.height
                        color: paper
                        border.width: 2 * root.unit
                        border.color: ink
                        Text {
                            anchors.centerIn: parent
                            text: globalButton.modelData.label
                            color: ink
                            font.family: "Noto Mono"
                            font.pixelSize: 16 * root.unit
                            font.weight: Font.Bold
                        }
                        MouseArea {
                            anchors.fill: parent
                            onPressed: root.showControls()
                            onClicked: {
                                root.cancelPendingDismiss()
                                if (globalButton.modelData.action === "refresh") {
                                    endpoint.sendMessage(1, "refresh")
                                    root.showToast("Refreshing Paperboard")
                                } else root.returnToLauncher()
                            }
                        }
                    }
                }
            }

            Row {
                id: navigationStatus
                width: parent.width
                height: 54 * root.unit
                spacing: 16 * root.unit
                Rectangle { width: 9 * root.unit; height: 9 * root.unit; radius: width / 2; color: backendState === "LIVE" ? ink : muted; anchors.verticalCenter: parent.verticalCenter }
                Text {
                    text: backendState
                    color: muted
                    font.family: "Noto Mono"
                    font.pixelSize: 16 * root.unit
                    font.letterSpacing: 2 * root.unit
                    anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                    text: backendDetail.toUpperCase()
                    color: muted
                    width: Math.max(0, navigationStatus.width - 570 * root.unit)
                    elide: Text.ElideRight
                    font.family: "Noto Mono"
                    font.pixelSize: 14 * root.unit
                    font.letterSpacing: 1 * root.unit
                    anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                    text: root.mode === "screen"
                        ? (screenMessages.length ? (screenIndex + 1) + " / " + screenMessages.length : "0 / 0")
                        : (root.mode === "reader"
                            ? (readerHistory.length ? (readerHistoryIndex + 1) + " / " + readerHistory.length : "0 / 0")
                            : (cards.length ? (currentIndex + 1) + " / " + cards.length : "0 / 0"))
                    color: ink
                    font.family: "Noto Mono"
                    font.pixelSize: 18 * root.unit
                    font.weight: Font.Bold
                    anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                    text: "CURSOR " + cursor
                    color: muted
                    font.family: "Noto Mono"
                    font.pixelSize: 14 * root.unit
                    anchors.verticalCenter: parent.verticalCenter
                }
            }
        }

        Item {
            id: content
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: parent.width

            Column {
                anchors.fill: parent
                anchors.topMargin: 64 * root.unit
                anchors.bottomMargin: 45 * root.unit
                visible: root.mode === "dashboard" && cards.length === 0
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
                visible: root.mode === "dashboard" && cards.length > 0 && currentCard.kind !== "image"

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
                visible: root.mode === "dashboard" && cards.length > 0 && currentCard.kind === "image"
                color: paper
            }

            Image {
                id: cardImage
                anchors.fill: parent
                anchors.margins: 18 * root.unit
                visible: root.mode === "dashboard" && cards.length > 0 && currentCard.kind === "image" && currentCard.asset_path !== undefined
                source: visible ? "file://" + currentCard.asset_path + "?cursor=" + cursor : ""
                fillMode: Image.PreserveAspectFit
                asynchronous: true
                cache: false
                smooth: false
                onStatusChanged: {
                    if (status === Image.Ready) root.fullRefresh()
                }
            }

            Flickable {
                id: screenFlick
                anchors.fill: parent
                anchors.topMargin: 48 * root.unit
                anchors.bottomMargin: 32 * root.unit
                visible: root.mode === "screen"
                clip: true
                contentWidth: width
                contentHeight: Math.max(height, screenColumn.height)
                flickableDirection: Flickable.VerticalFlick
                boundsBehavior: Flickable.StopAtBounds
                flickDeceleration: 2600 * root.unit
                maximumFlickVelocity: 5200 * root.unit
                onMovementStarted: root.touchActivity()
                onMovementEnded: { root.visualChanged(1); root.reportState() }

                MouseArea {
                    width: screenFlick.width
                    height: Math.max(screenFlick.height, screenColumn.height)
                    z: -1
                    preventStealing: false
                    property real startX
                    property real startY
                    onPressed: { startX = mouse.x; startY = mouse.y; root.touchActivity() }
                    onReleased: {
                        var dx = mouse.x - startX; var dy = mouse.y - startY
                        if (Math.abs(dx) > 120 * root.unit && Math.abs(dx) > Math.abs(dy) * 1.35) root.moveScreen(dx < 0 ? 1 : -1)
                        else if (Math.abs(dx) < 28 * root.unit && Math.abs(dy) < 28 * root.unit) root.controlsVisible ? root.hideControls() : root.showControls()
                    }
                }

                Column {
                    id: screenColumn
                    width: screenFlick.width
                    height: childrenRect.height + 60 * root.unit
                    spacing: 24 * root.unit
                    Text {
                        text: root.currentScreen.title || "Screen is ready."
                        width: parent.width; color: ink; wrapMode: Text.WordWrap
                        font.family: "EB Garamond"; font.pixelSize: 76 * root.unit; font.weight: Font.Medium
                    }
                    Image {
                        visible: root.currentScreen.asset_path !== undefined
                        source: visible ? "file://" + root.currentScreen.asset_path + "?cursor=" + root.cursor : ""
                        width: parent.width; height: visible ? 620 * root.unit : 0
                        fillMode: Image.PreserveAspectFit; asynchronous: true; cache: false; smooth: false
                        onStatusChanged: if (status === Image.Ready) root.fullRefresh()
                    }
                    Text {
                        text: root.currentScreen.body || "An agent can present content through the API, CLI, or MCP server."
                        textFormat: Text.MarkdownText; color: ink; width: parent.width; height: implicitHeight
                        wrapMode: Text.WordWrap; font.family: "EB Garamond"; font.pixelSize: 34 * root.unit; lineHeight: 1.18
                    }
                    Flow {
                        width: parent.width; height: childrenRect.height; spacing: 12 * root.unit
                        Repeater {
                            model: root.currentScreen.actions || []
                            Column {
                                id: screenAction
                                required property var modelData
                                width: ["checklist", "multi_select", "handwriting"].indexOf(modelData.type) >= 0 ? parent.width : Math.min(parent.width, 430 * root.unit)
                                height: childrenRect.height; spacing: 8 * root.unit
                                Text { text: screenAction.modelData.label || ""; width: parent.width; color: ink; font.family: "Noto Mono"; font.pixelSize: 17 * root.unit; font.bold: true; wrapMode: Text.WordWrap }
                                Repeater {
                                    model: ["checklist", "multi_select", "single_select"].indexOf(screenAction.modelData.type) >= 0 ? screenAction.modelData.options : []
                                    Rectangle {
                                        id: screenOption
                                        required property var modelData
                                        width: Math.min(screenAction.width, 410 * root.unit); height: 64 * root.unit
                                        property bool checked: (root.selectedValues[screenAction.modelData.id] || []).indexOf(modelData.id) >= 0
                                        color: checked ? ink : paper; border.width: 2 * root.unit; border.color: ink
                                        Text { anchors.centerIn: parent; text: (screenOption.checked ? "✓ " : "") + screenOption.modelData.label; color: screenOption.checked ? paper : ink; font.family: "Noto Mono"; font.pixelSize: 16 * root.unit; font.bold: true }
                                        MouseArea { anchors.fill: parent; onClicked: {
                                            if (screenAction.modelData.type === "single_select") root.submitScreenAction(screenAction.modelData, screenOption.modelData.id)
                                            else root.toggleScreenValue(screenAction.modelData, screenOption.modelData)
                                        } }
                                    }
                                }
                                Row {
                                    visible: screenAction.modelData.type === "confirm"
                                    height: visible ? 66 * root.unit : 0; spacing: 12 * root.unit
                                    Repeater {
                                        model: parent.visible ? [{label: screenAction.modelData.confirm_label || "Confirm", value: "confirm"}, {label: screenAction.modelData.cancel_label || "Cancel", value: "cancel"}] : []
                                        Rectangle {
                                            id: decisionButton
                                            required property var modelData
                                            width: 190 * root.unit; height: 66 * root.unit; color: modelData.value === "confirm" ? ink : paper; border.width: 2 * root.unit; border.color: ink
                                            Text { anchors.centerIn: parent; text: decisionButton.modelData.label; color: decisionButton.modelData.value === "confirm" ? paper : ink; font.family: "Noto Mono"; font.pixelSize: 16 * root.unit; font.bold: true }
                                            MouseArea { anchors.fill: parent; onClicked: root.submitScreenAction(screenAction.modelData, {decision: decisionButton.modelData.value}) }
                                        }
                                    }
                                }
                                Rectangle {
                                    visible: ["choice", "toggle", "link"].indexOf(screenAction.modelData.type) >= 0
                                    width: Math.min(screenAction.width, 410 * root.unit); height: visible ? 66 * root.unit : 0; color: ink
                                    Text { anchors.centerIn: parent; text: screenAction.modelData.type === "link" ? "OPEN" : (screenAction.modelData.label || "SUBMIT"); color: paper; font.family: "Noto Mono"; font.pixelSize: 16 * root.unit; font.bold: true }
                                    MouseArea { anchors.fill: parent; onClicked: screenAction.modelData.type === "link" ? root.openReader(screenAction.modelData) : root.submitScreenAction(screenAction.modelData, screenAction.modelData.type === "toggle" ? !screenAction.modelData.value : screenAction.modelData.id) }
                                }
                                Rectangle {
                                    visible: screenAction.modelData.type === "checklist" || screenAction.modelData.type === "multi_select"
                                    width: 240 * root.unit; height: visible ? 66 * root.unit : 0; color: ink
                                    Text { anchors.centerIn: parent; text: "SUBMIT"; color: paper; font.family: "Noto Mono"; font.pixelSize: 16 * root.unit; font.bold: true }
                                    MouseArea { anchors.fill: parent; onClicked: root.submitScreenAction(screenAction.modelData, root.selectedValues[screenAction.modelData.id] || []) }
                                }
                                Rectangle {
                                    id: sliderTrack
                                    visible: screenAction.modelData.type === "slider"
                                    width: Math.min(screenAction.width, 600 * root.unit); height: visible ? 72 * root.unit : 0
                                    color: shade; border.width: 2 * root.unit; border.color: ink
                                    property real currentValue: root.selectedValues[screenAction.modelData.id] === undefined ? (screenAction.modelData.value || 0) : root.selectedValues[screenAction.modelData.id]
                                    Rectangle { width: parent.width * Math.max(0, Math.min(1, (sliderTrack.currentValue - screenAction.modelData.minimum) / (screenAction.modelData.maximum - screenAction.modelData.minimum))); height: parent.height; color: ink }
                                    Text { anchors.centerIn: parent; text: sliderTrack.currentValue; color: sliderTrack.currentValue > (screenAction.modelData.minimum + screenAction.modelData.maximum) / 2 ? paper : ink; font.family: "Noto Mono"; font.pixelSize: 17 * root.unit; font.bold: true }
                                    MouseArea { anchors.fill: parent
                                        function updateValue(x) { var raw = screenAction.modelData.minimum + Math.max(0, Math.min(1, x / width)) * (screenAction.modelData.maximum - screenAction.modelData.minimum); var stepped = Math.round(raw / screenAction.modelData.step) * screenAction.modelData.step; var next = {}; for (var key in root.selectedValues) next[key] = root.selectedValues[key]; next[screenAction.modelData.id] = stepped; root.selectedValues = next; root.touchActivity(); root.visualChanged(1) }
                                        onPressed: updateValue(mouse.x); onPositionChanged: updateValue(mouse.x); onReleased: root.submitScreenAction(screenAction.modelData, sliderTrack.currentValue)
                                    }
                                }
                                Rectangle {
                                    id: penSurface
                                    visible: screenAction.modelData.type === "handwriting"
                                    width: screenAction.width; height: visible ? (screenAction.modelData.height || 360) * root.unit : 0
                                    color: paper; border.width: 2 * root.unit; border.color: ink
                                    property var points: []
                                    Canvas { id: penInk; anchors.fill: parent; onPaint: {
                                        var context = getContext("2d"); context.clearRect(0, 0, width, height); context.strokeStyle = root.ink; context.lineWidth = 3 * root.unit
                                        if (penSurface.points.length > 1) { context.beginPath(); context.moveTo(penSurface.points[0].x * width, penSurface.points[0].y * height); for (var p = 1; p < penSurface.points.length; p++) context.lineTo(penSurface.points[p].x * width, penSurface.points[p].y * height); context.stroke() }
                                    } }
                                    MouseArea { anchors.fill: parent; property double beganAt: 0
                                        onPressed: { beganAt = Date.now(); penSurface.points = [{x: mouse.x / width, y: mouse.y / height, pressure: 0.5, t_ms: 0}]; root.touchActivity() }
                                        onPositionChanged: { var copy = penSurface.points.slice(0); copy.push({x: Math.max(0, Math.min(1, mouse.x / width)), y: Math.max(0, Math.min(1, mouse.y / height)), pressure: 0.5, t_ms: Date.now() - beganAt}); penSurface.points = copy; penInk.requestPaint() }
                                        onReleased: root.submitScreenAction(screenAction.modelData, {strokes: [{id: screenAction.modelData.id, tool: "pen", points: penSurface.points}]})
                                    }
                                }
                            }
                        }
                    }
                }
            }

            Flickable {
                id: readerFlick
                anchors.fill: parent; anchors.topMargin: 48 * root.unit; anchors.bottomMargin: 32 * root.unit
                visible: root.mode === "reader"; clip: true; contentWidth: width; contentHeight: Math.max(height, readerColumn.height)
                flickableDirection: Flickable.VerticalFlick; boundsBehavior: Flickable.StopAtBounds
                flickDeceleration: 2600 * root.unit; maximumFlickVelocity: 5200 * root.unit
                onMovementStarted: root.touchActivity(); onMovementEnded: root.visualChanged(1)
                MouseArea {
                    width: readerFlick.width; height: Math.max(readerFlick.height, readerColumn.height); z: -1; preventStealing: false
                    property real startX; property real startY
                    onPressed: { startX = mouse.x; startY = mouse.y; root.touchActivity() }
                    onReleased: if (Math.abs(mouse.x - startX) < 28 * root.unit && Math.abs(mouse.y - startY) < 28 * root.unit) root.controlsVisible ? root.hideControls() : root.showControls()
                }
                Column {
                    id: readerColumn; width: readerFlick.width; height: childrenRect.height + 50 * root.unit; spacing: 22 * root.unit
                    Text {
                        text: root.readerMenuView ? "BROWSER MENU" : (root.readerHistoryView ? "RECENT PAGES" : (root.readerBookmarkView ? "SAVED PAGES" : (root.readerLoading ? "FETCHING PUBLIC HTTPS" : "PAPER WEB")))
                        width: parent.width; color: root.accent; font.family: "Noto Mono"; font.pixelSize: 15 * root.unit
                        font.bold: true; font.letterSpacing: 2 * root.unit
                    }
                    Text {
                        text: root.readerMenuView ? "Browse" : (root.readerHistoryView ? "History" : (root.readerBookmarkView ? "Saved for later" : root.readerTitle))
                        width: parent.width; wrapMode: Text.WordWrap; color: ink; font.family: "EB Garamond"
                        font.pixelSize: 70 * root.unit; font.weight: Font.Medium
                    }
                    Text {
                        visible: !root.readerMenuView && !root.readerHistoryView && !root.readerBookmarkView
                        height: visible ? implicitHeight : 0
                        text: root.readerUrl; width: parent.width; elide: Text.ElideMiddle; color: muted
                        font.family: "Noto Mono"; font.pixelSize: 15 * root.unit
                    }
                    Text {
                        visible: !root.readerMenuView && !root.readerHistoryView && !root.readerBookmarkView
                        height: visible ? implicitHeight : 0
                        text: root.readerBody; width: parent.width; wrapMode: Text.WordWrap; color: ink
                        font.family: "EB Garamond"; font.pixelSize: 32 * root.unit; lineHeight: 1.18
                    }
                    Text {
                        visible: !root.readerMenuView && !root.readerHistoryView && !root.readerBookmarkView && root.readerLinks.length > 0
                        height: visible ? implicitHeight : 0; text: "CONTINUE READING"; width: parent.width
                        color: root.accent; font.family: "Noto Mono"; font.pixelSize: 15 * root.unit
                        font.bold: true; font.letterSpacing: 2 * root.unit
                    }
                    Repeater {
                        model: root.readerMenuView ? root.readerMenuEntries() : (root.readerHistoryView ? root.readerHistoryEntries() : (root.readerBookmarkView ? root.readerBookmarks : root.readerLinks))
                        Rectangle {
                            id: readerLinkButton
                            required property var modelData
                            width: readerColumn.width; height: 78 * root.unit; color: paper
                            border.width: 2 * root.unit; border.color: ink
                            Text {
                                anchors.left: parent.left; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                                anchors.margins: 22 * root.unit
                                text: readerLinkButton.modelData.label || readerLinkButton.modelData.title || readerLinkButton.modelData.url
                                color: ink; elide: Text.ElideRight; font.family: "EB Garamond"; font.pixelSize: 27 * root.unit
                            }
                            MouseArea { anchors.fill: parent; onClicked: {
                                if (root.readerMenuView) root.readerMenuSelect(readerLinkButton.modelData.action)
                                else if (root.readerHistoryView) root.readerShowHistory(readerLinkButton.modelData.history_index)
                                else root.readerNavigate(readerLinkButton.modelData.url, "push")
                            } }
                        }
                    }
                    Text {
                        visible: root.readerBookmarkView && root.readerBookmarks.length === 0
                        text: "No saved pages yet. Open a page, then choose SAVE."
                        width: parent.width; wrapMode: Text.WordWrap; color: muted
                        font.family: "EB Garamond"; font.pixelSize: 32 * root.unit
                    }
                    Text {
                        visible: root.readerHistoryView && root.readerHistory.length === 0
                        text: "No pages have been opened in this browser session."
                        width: parent.width; wrapMode: Text.WordWrap; color: muted
                        font.family: "EB Garamond"; font.pixelSize: 32 * root.unit
                    }
                }
            }

            Rectangle {
                id: readerKeyboard
                anchors.fill: parent; visible: root.mode === "reader" && root.readerKeyboardVisible
                color: paper; border.width: 3 * root.unit; border.color: ink; z: 40
                Column {
                    anchors.fill: parent; anchors.margins: 42 * root.unit; spacing: 18 * root.unit
                    Row {
                        width: parent.width; height: 62 * root.unit; spacing: 18 * root.unit
                        Text { text: "FIND A PAGE"; width: parent.width - closeKeyboard.width - parent.spacing; anchors.verticalCenter: parent.verticalCenter; color: root.accent; font.family: "Noto Mono"; font.pixelSize: 16 * root.unit; font.bold: true; font.letterSpacing: 2 * root.unit }
                        Rectangle {
                            id: closeKeyboard; width: 190 * root.unit; height: parent.height; color: paper
                            border.width: 3 * root.unit; border.color: ink
                            Text { anchors.centerIn: parent; text: "CLOSE"; color: ink; font.family: "Noto Mono"; font.pixelSize: 16 * root.unit; font.bold: true }
                            MouseArea { anchors.fill: parent; onClicked: root.readerOpenMenu() }
                        }
                    }
                    Text { text: "Enter a public HTTPS address or search the web"; color: ink; font.family: "EB Garamond"; font.pixelSize: 46 * root.unit }
                    Rectangle {
                        width: parent.width; height: 92 * root.unit; color: "white"; border.width: 3 * root.unit; border.color: ink
                        Text { anchors.fill: parent; anchors.margins: 20 * root.unit; text: root.readerInput.length ? root.readerInput : "Type with the keys below"; color: root.readerInput.length ? ink : muted; elide: Text.ElideLeft; verticalAlignment: Text.AlignVCenter; font.family: "Noto Mono"; font.pixelSize: 25 * root.unit }
                    }
                    Grid {
                        id: readerKeys; width: parent.width; columns: 10; spacing: 8 * root.unit
                        Repeater {
                            model: ["1","2","3","4","5","6","7","8","9","0","q","w","e","r","t","y","u","i","o","p","a","s","d","f","g","h","j","k","l",".","z","x","c","v","b","n","m","-","/","?"]
                            Rectangle {
                                required property string modelData
                                width: (readerKeys.width - readerKeys.spacing * 9) / 10; height: 62 * root.unit
                                color: "white"; border.width: 2 * root.unit; border.color: ink
                                Text { anchors.centerIn: parent; text: root.readerUppercase ? modelData.toUpperCase() : modelData; color: ink; font.family: "Noto Mono"; font.pixelSize: 20 * root.unit; font.bold: true }
                                MouseArea { anchors.fill: parent; onClicked: root.readerKey(root.readerUppercase ? modelData.toUpperCase() : modelData) }
                            }
                        }
                    }
                    Row {
                        width: parent.width; height: 70 * root.unit; spacing: 9 * root.unit
                        Repeater {
                            model: ["SHIFT", "CLEAR", "BACKSPACE", "SPACE", "GO", "CLOSE"]
                            Rectangle {
                                required property string modelData
                                width: (parent.width - parent.spacing * 5) / 6; height: parent.height
                                color: modelData === "GO" ? ink : "white"; border.width: 2 * root.unit; border.color: ink
                                Text { anchors.centerIn: parent; text: modelData; color: modelData === "GO" ? paper : ink; font.family: "Noto Mono"; font.pixelSize: 15 * root.unit; font.bold: true }
                                MouseArea { anchors.fill: parent; onClicked: {
                                    if (modelData === "GO") root.readerNavigate(root.readerInput, "push")
                                    else if (modelData === "CLOSE") root.readerOpenMenu()
                                    else if (modelData === "SHIFT") { root.readerUppercase = !root.readerUppercase; root.visualChanged(1) }
                                    else root.readerKey(modelData)
                                } }
                            }
                        }
                    }
                }
            }
        }

        Rectangle {
            anchors.bottom: parent.bottom
            width: parent.width
            height: controls.height
            visible: root.controlsVisible
            color: paper
            z: 9
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
                model: root.mode === "reader"
                    ? ["BACK", "FORWARD", "MENU", "ADDRESS", "RELOAD", root.readerBookmarked ? "UNSAVE" : "SAVE", "TOP"]
                    : (root.mode === "screen"
                        ? ["PREV", "NEXT", "TOP"]
                        : ["PREV", "NEXT", "PIN", root.pendingDismissCardId === (root.currentCard.id || "") && root.pendingDismissCardId.length ? "CONFIRM DISMISS" : "DISMISS CARD", "AMBIENT"])
                Rectangle {
                    required property string modelData
                    width: (controls.width - controls.spacing * (controls.children.length - 1)) / controls.children.length
                    height: controls.height
                    color: paper
                    border.width: 2 * root.unit
                    border.color: ink
                    Text {
                        anchors.centerIn: parent
                        text: modelData
                        color: ink
                        font.family: "Noto Mono"
                        font.pixelSize: (modelData === "CONFIRM DISMISS" ? 13 : 15) * root.unit
                        font.weight: Font.Bold
                    }
                    MouseArea {
                        anchors.fill: parent
                        onPressed: root.showControls()
                        onClicked: {
                            if (modelData !== "DISMISS CARD" && modelData !== "CONFIRM DISMISS") root.cancelPendingDismiss()
                            if (modelData === "PREV") root.mode === "screen" ? root.moveScreen(-1) : root.move(-1)
                            else if (modelData === "NEXT") root.mode === "screen" ? root.moveScreen(1) : root.move(1)
                            else if (modelData === "TOP") { if (root.mode === "reader") readerFlick.contentY = 0; else screenFlick.contentY = 0; root.touchActivity(); root.visualChanged(1) }
                            else if (modelData === "BACK") root.readerBack()
                            else if (modelData === "FORWARD") root.readerForward()
                            else if (modelData === "MENU") root.readerOpenMenu()
                            else if (modelData === "ADDRESS") { root.readerInput = root.readerUrl; root.readerOpenAddress(false) }
                            else if (modelData === "RELOAD") root.readerReload()
                            else if (modelData === "SAVE" || modelData === "UNSAVE") root.readerToggleBookmark()
                            else if (modelData === "PIN" && root.currentCard.id) endpoint.sendMessage(5, root.currentCard.id)
                            else if (modelData === "DISMISS CARD" || modelData === "CONFIRM DISMISS") root.requestDismissCard()
                            else if (modelData === "AMBIENT") { if (root.ambientMode) { root.ambientMode = false; root.visualChanged(1); root.showToast("Ambient mode off"); root.reportState() } else root.selectAmbient(true) }
                        }
                    }
                }
            }
        }

        MouseArea {
            id: gestureArea
            anchors.fill: parent
            enabled: root.mode === "dashboard"
            z: root.controlsVisible ? 5 : 30
            property real startX: 0
            property real startY: 0
            onPressed: { startX = mouse.x; startY = mouse.y; root.touchActivity() }
            onReleased: {
                var dx = mouse.x - startX
                var dy = mouse.y - startY
                if (Math.abs(dx) > 120 * root.unit && Math.abs(dx) > Math.abs(dy) * 1.35) root.mode === "screen" ? root.moveScreen(dx < 0 ? 1 : -1) : root.move(dx < 0 ? 1 : -1)
                else if (Math.abs(dx) < 28 * root.unit && Math.abs(dy) < 28 * root.unit) {
                    if (!root.controlsVisible) root.showControls()
                    else root.hideControls()
                }
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
                model: ["REFRESH", "EXIT"]
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

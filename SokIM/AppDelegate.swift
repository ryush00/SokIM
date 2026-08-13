import Cocoa
import InputMethodKit
import UserNotifications

private(set) var sokAppDelegate: AppDelegate?

func appDelegate() -> AppDelegate? {
    return (NSApp.delegate as? AppDelegate) ?? sokAppDelegate
}

@main
class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    override init() {
        super.init()
        sokAppDelegate = self
    }
    // swiftlint:disable force_cast
    private var server: IMKServer = IMKServer.init(
        name: (Bundle.main.infoDictionary!["InputMethodConnectionName"] as! String),
        bundleIdentifier: Bundle.main.bundleIdentifier
    )
    // swiftlint:enable force_cast

    let statusBar = StatusBar()
    let inputMonitor = InputMonitor()
    let clickMonitor = ClickMonitor()
    let hotKeyMonitor = HotKeyMonitor()

    private var state = State()
    private var sender: IMKTextInput?
    private(set) var isIMEActive = false
    private(set) var isIMESettling = false
    private var imeSettleWork: DispatchWorkItem?
    private var needsMarkedTextPrime = false
    private var clientUsesRawMarkedText = false
    private var lastInputSourceID = ""
    private var lastMouseLocation = NSEvent.mouseLocation
    private var mouseStuckSamples = 0
    private var cursorWatch: Timer?
    private var recoverWork: DispatchWorkItem?
    var inputEngine: Engine.Type = TwoSetEngine.self {
        didSet {
            if oldValue.name != inputEngine.name {
                statusBar.setEngine(inputEngine)
                notice("inputEngine \(oldValue.name) → \(inputEngine.name)")
            }
        }
    }

    func rememberClient(_ sender: IMKTextInput) {
        let attrs = markedTextAttributes(for: sender)
        let raw = usesRawMarkedText(sender)
        if raw != clientUsesRawMarkedText {
            notice("rememberClient raw=\(raw) attrs=\(attrs) bundle=\(sender.bundleIdentifier() ?? "")")
        }
        clientUsesRawMarkedText = raw
    }

    /** GLFW처럼 marked text 속성이 없으면 IME on/off 기본 확정을 하지 않는다 */
    func shouldDeferIMECommit(client: Any? = nil) -> Bool {
        if let input = client as? IMKTextInput {
            rememberClient(input)
        }
        return clientUsesRawMarkedText
    }

    func shouldSkipCommitComposition() -> Bool {
        clientUsesRawMarkedText && isIMESettling
    }

    func setIMEActive(_ active: Bool, client: Any? = nil) {
        debug("\(active)")
        if let input = client as? IMKTextInput {
            sender = input
            rememberClient(input)
        }

        if active {
            imeSettleWork?.cancel()
            imeSettleWork = nil
            isIMESettling = false
            isIMEActive = true
            if clientUsesRawMarkedText {
                // GLFW 채팅은 속의 영문 엔진(A)이나 ABC에 머물면 라틴만 넣는다.
                // 트레이에 속이 보여도 게임은 영어 IME 경로를 탄다.
                if inputEngine.name != state.engines.한.name {
                    state.engine = state.engines.한
                    statusBar.setEngine(state.engines.한)
                    notice("raw client activate → 한글")
                }
                _ = selectSokIMInputSource()
                if state.composed.isEmpty && state.composing.isEmpty {
                    needsMarkedTextPrime = true
                    if let sender {
                        primeMarkedText(sender)
                    }
                } else {
                    needsMarkedTextPrime = false
                    notice("skip prime while composing")
                }
            } else {
                needsMarkedTextPrime = false
            }
        } else {
            isIMEActive = false
            resetCapsLockTapDown()
            if Preferences.rotateShortcuts.contains(.capsLock) {
                setKeyboardCapsLock(enabled: false)
            }
            if clientUsesRawMarkedText {
                scheduleIMESettle()
            } else {
                isIMESettling = false
            }
        }
    }

    /** marked text 세션이 없는 클라이언트에 빈 조합을 한 번 넣어 첫 글자가 확정되지 않게 한다 */
    func primeMarkedText(_ sender: IMKTextInput) {
        guard state.composed.isEmpty && state.composing.isEmpty else {
            needsMarkedTextPrime = false
            return
        }
        let empty = NSAttributedString(string: "")
        sender.setMarkedText(empty, selectionRange: NSRange(location: 0, length: 0), replacementRange: defaultRange)
        needsMarkedTextPrime = false
        notice("primeMarkedText attrsEmpty=\(clientUsesRawMarkedText)")
    }

    /** TIS 깜빡임으로 조합 중인 글자를 insertText하면 ㅎㅏㄴ으로 풀린다. 로컬 상태만 버린다. */
    private func dropComposingWithoutInsert() {
        notice("drop composing without insert '\(state.composing)'")
        sender = nil
        state.clear(composed: true, composing: true)
        inputMonitor.flush()
        InputContext.commit()
    }

    /** 채팅 오픈 직후 TIS/IME 깜빡임이 잦아든 뒤에만 조합을 버린다 */
    private func scheduleIMESettle() {
        isIMESettling = true
        imeSettleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.isIMESettling = false
            self.imeSettleWork = nil
            if self.isIMEActive || isSokIMCurrentInputSource() {
                notice("IME settle keep composing")
                return
            }
            if self.clientUsesRawMarkedText {
                // 조합을 버리면 다음 키가 ㅏ/ㄴ부터 새로 시작해 ㅎㅏㄴ이 된다.
                notice("IME settle keep composing for raw client")
                return
            }
            notice("IME settle commit")
            self.commit()
        }
        imeSettleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(800), execute: work)
    }

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        debug()

        registerSokIMInputSource()
        if Preferences.rotateShortcuts.contains(.capsLock) {
            setKeyboardCapsLock(enabled: false)
        }
        startCheckingUpdate()
        startMonitorsInitially()
        startCursorWatch()

        // 사용자가 입력기를 변경하는 시점에 대부분 버림
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clearExceptEngine),
            name: NSTextInputContext.keyboardSelectionDidChangeNotification,
            object: nil
        )

        // 입력기가 변경되는 시점에 ABC 입력기 제한 로직 실행
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(suppressABC),
            name: NSTextInputContext.keyboardSelectionDidChangeNotification,
            object: nil
        )

        // GLFW IME on이 애플 두벌식을 고르면 속으로 되돌린다. ABC(IME off)는 건드리지 않는다.
        // Caps Lock 한/A는 ABC에서도 속을 직접 고른다.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(claimKoreanIMEIfNeeded),
            name: NSTextInputContext.keyboardSelectionDidChangeNotification,
            object: nil
        )

        // 입력기가 변경되는 시점에 보안 입력 상태인 경우 모두 버리고 영문 소문자 입력으로 변경
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(abcOnSecureInput),
            name: NSTextInputContext.keyboardSelectionDidChangeNotification,
            object: nil
        )

        // 잠자기 상태에서 깨어나는 경우 InputMonitor 재시작
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(restartMonitors),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(restartMonitors),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        debug()

        stopMonitors()

        // applicationDidFinishLaunching에서 추가한 observer 제거
        NotificationCenter.default.removeObserver(
            self,
            name: NSTextInputContext.keyboardSelectionDidChangeNotification,
            object: nil
        )

        NotificationCenter.default.removeObserver(
            self,
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        NotificationCenter.default.removeObserver(
            self,
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )
    }

    private func startCheckingUpdate() {
        debug()

        let center = UNUserNotificationCenter.current()
        center.delegate = self

        Task {
            var deliveredName = ""

            while true {
                debug()

                let config = URLSessionConfiguration.ephemeral
                config.timeoutIntervalForResource = 15
                let url = URL(string: "https://api.github.com/repos/kiding/SokIM/releases/latest")!

                if let data = try? await URLSession(configuration: config).data(from: url).0,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let name = json["name"] as? String,
                   let latestString = name.wholeMatch(of: /v[\d.]+ \((\d+)\)/)?.1,
                   let latest = Int(latestString),
                   let currentString = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
                   let current = Int(currentString) {
                    debug("current: \(current), latest: \(latest)")

                    if current < latest {
                        debug("새로운 업데이트: \(latest)")

                        await MainActor.run {
                            statusBar.setStatus("📥")
                            statusBar.setNotice("📥 새로운 업데이트가 있습니다.")
                        }

                        if deliveredName == name {
                            debug("이미 알림 전송함")
                        } else {
                            debug("알림 전송")

                            let content = UNMutableNotificationContent()
                            content.title = "속 입력기"
                            content.body = "\(name) 업데이트가 있습니다."
                            let request = UNNotificationRequest(identifier: name, content: content, trigger: nil)

                            do {
                                try await center.requestAuthorization(options: [.alert, .sound])
                                try await center.add(request)
                                deliveredName = name
                            } catch {
                                warning("\(error)")
                            }
                        }
                    } else {
                        debug("현재 최신 버전")
                    }
                } else {
                    warning("업데이트 확인 실패: \(url)")
                }

                _ = try? await Task.sleep(for: .seconds(86400 * 2))
            }
        }
    }

    internal func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        debug()

        statusBar.checkUpdate(sender: nil)
    }

    private func startMonitorsInitially() {
        debug()
        startMonitors(retryOnError: true)
    }

    @objc func restartMonitors(_ aNotification: Notification?) {
        debug("aNotification: \(String(describing: aNotification))")

        inputMonitor.stop()
        clickMonitor.stop()
        hotKeyMonitor.stop()
        startMonitors(retryOnError: true)
    }

    func hasEventTap() -> Bool {
        hotKeyMonitor.isTapEnabled
    }

    private func startMonitors(retryOnError: Bool) {
        var errors: [Error] = []

        do { try inputMonitor.start() } catch {
            warning("inputMonitor: \(error)")
            errors.append(error)
        }
        do { try clickMonitor.start() } catch {
            warning("clickMonitor: \(error)")
            errors.append(error)
        }
        do { try hotKeyMonitor.start() } catch {
            warning("hotKeyMonitor: \(error)")
            errors.append(error)
        }

        statusBar.setStatus(state.engine.name)
        if errors.isEmpty {
            statusBar.setError(nil)
        } else {
            statusBar.setError("⚠️ \(errors[0])")
            if retryOnError {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                    self?.startMonitors(retryOnError: true)
                }
            }
        }
    }

    private func stopMonitors() {
        debug()

        inputMonitor.stop()
        clickMonitor.stop()
        hotKeyMonitor.stop()
    }

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        debug("\(String(describing: event)) \(String(describing: sender))")

        // 처리할 event 또는 sender가 없음, OS가 대신 처리
        guard let event = event,
              let sender = sender as? IMKTextInput
        else {
            return false
        }
        self.sender = sender
        rememberClient(sender)
        if needsMarkedTextPrime && clientUsesRawMarkedText {
            primeMarkedText(sender)
        }
        let strategy = strategy(for: sender)

        let secure = IsSecureEventInputEnabled()
        notice("handle secure=\(secure) engine=\(inputEngine.name) key=\(event.keyCode)")

        // 암호 필드는 영문 엔진일 때만 OS에 맡긴다.
        // Secure Event Input이 새어 있으면 모든 필드가 암호로 보여 한글이 영문으로 빠진다.
        if secure && inputEngine.name == "A" {
            return false
        }

        // 별도 처리: 한영키 한자키 英数키 かな/カナ키 입력 시 OS 처리 무시
        if event.keyCode == kVK_JIS_Eisu || event.keyCode == kVK_JIS_Kana {
            return true
        }

        // inputs 처리 시작
        var inputs = inputMonitor.flush()
        filterInputs(&inputs, event: event)

        // 기존 state 보존
        debug("이전 state: \(state)")
        defer { debug("이후 state: \(state)") }
        let oldState = state

        // inputs 입력, 반복 입력인 경우 down 한번 더 입력
        inputs.forEach { state.next($0) }
        if event.isARepeat, let down = state.down { state.next(down) }

        notice("handle engine=\(state.engine.name) composed='\(state.composed)' composing='\(state.composing)' chars='\(event.characters ?? "")'")

        notice("hangulStrategy=MarkedStrategy bundle=\(sender.bundleIdentifier() ?? "") raw=\(clientUsesRawMarkedText) attrs=\(markedTextAttributes(for: sender))")

        // modifier 없는 백스페이스 키인 경우
        if event.keyCode == kVK_Delete && event.modifierFlags.subtracting(.capsLock).isEmpty {
            state.backspaceComposing()
            let used = state.engine == state.engines.한 ? MarkedStrategy.self : strategy
            let handled = used.backspace(from: state, to: sender, with: oldState.composing)
            state.clear(composed: true, composing: !handled)
            return handled
        }

        let tuple = state.engine.eventToTuple(event)

        // 영문 엔진인데 NSEvent에 한글 자모가 실리면 OS로 넘기지 않는다.
        // IME on/off 직후 event.characters가 ㄹ인데 composed는 f인 경우가 있다.
        if state.engine == state.engines.A && containsHangul(event.characters) {
            if state.composed == oldState.composed && state.composing == oldState.composing, let tuple {
                state.next(tuple)
            }
            if !state.composed.isEmpty || !state.composing.isEmpty {
                _ = strategy.next(from: state, to: sender, with: oldState.composing)
                state.clear(composed: true, composing: false)
            }
            notice("handle latin despite hangul chars")
            return true
        }

        // 한글은 항상 marked text로 조합한다. DirectStrategy는 첫 자모를 확정해 ㅎ에서 멈춘다.
        if state.engine == state.engines.한 {
            // Enter·화살표 등 매핑 없는 키는 조합을 확정한 뒤 OS에 넘긴다.
            // 여기서 true를 반환하면 밑줄만 남고 엔터가 먹통이 된다.
            if tuple == nil {
                MarkedStrategy.commit(from: state, to: sender)
                state.clear(composed: true, composing: true)
                notice("handle hangul commit passthrough key=\(event.keyCode)")
                return false
            }

            // HID 큐에 이전 글쇠가 남아 있으면 ㅎ 다음에 ㅏ가 붙지 않고
            // ㅎ/ㅏ/ㄴ이 각각 새 조합으로 시작된다. 이번 NSEvent만 적용한다.
            state = oldState
            state.next(tuple!)
            if !state.composed.isEmpty || !state.composing.isEmpty {
                _ = MarkedStrategy.next(from: state, to: sender, with: oldState.composing)
                state.clear(composed: true, composing: false)
                notice("handle hangul inserted")
                return true
            }
            notice("handle hangul consumed")
            return true
        }

        if state.composed == oldState.composed && state.composing == oldState.composing, let tuple {
            state.next(tuple)
        }

        if (
            // event가 engine이 처리할 수 없는 글자인 경우 (예: Cmd + 방향 키 등)
            tuple == nil
        ) || (
            // event가 state가 입력할 문자열과 완전히 동일한 경우
            state.composed == event.characters
            && state.composing == ""
            // `만 제외
            && event.characters != "`"
        ) {
            // sender에 oldState 그대로 조합 종료 반영
            strategy.commit(from: oldState, to: sender)

            // state 새로운 완성/조합 버림
            state.clear(composed: true, composing: true)

            // OS가 대신 처리하도록 반환
            return false
        }

        if state.composed.count == 0 && state.composing.count == 0 {
            inputMonitor.restartIfIdle()
            return true
        }

        // sender에 state 새로운 완성/조합 진행 반영
        if !strategy.next(from: state, to: sender, with: oldState.composing) {
            // 입력 실패한 경우 tuple만 입력
            state.clear(composed: true, composing: true)
            if let tuple { state.next(tuple) }
            _ = strategy.next(from: state, to: sender, with: "")
        }

        // state 새로운 완성 버림
        state.clear(composed: true, composing: false)

        // 처리 완료
        return true
    }

    /** HID 단축키로 한/A를 즉시 전환하고, 이후 handle()의 중복 전환을 막는다 */
    func rotateFromShortcut() {
        debug()
        commit()
        state.rotateFromShortcut()
    }

    /** ABC 등 다른 소스에서 Caps Lock 한/A를 누르면 속을 한글 엔진으로 고른다. */
    func selectSokIMHangulFromShortcut() {
        debug()
        commit()
        state.engine = state.engines.한
        statusBar.setEngine(state.engines.한)
        let status = selectSokIMInputSource()
        notice("selectSokIMHangulFromShortcut \(status) now=\(currentInputSourceIDs().joined(separator: ", "))")
        setKeyboardCapsLock(enabled: false)
    }

    /** GLFW 채팅처럼 marked text가 빈약한 클라이언트가 열려 있으면 속을 한글로 되돌린다. */
    func recoverRawKoreanIMEIfNeeded() {
        guard clientUsesRawMarkedText else { return }
        if isSokIMCurrentInputSource() && inputEngine.name == state.engines.한.name {
            return
        }
        selectSokIMHangulFromShortcut()
    }

    /** 채팅 키 이름 없이, ABC에 남은 뒤 첫 키에서 속을 되돌린다. */
    func scheduleRawKoreanIMERecover() {
        guard looksLikeFrontmostRawGame() else { return }
        guard recoverWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.recoverWork = nil
            guard self.looksLikeFrontmostRawGame() else { return }
            if isSokIMCurrentInputSource() && self.inputEngine.name == self.state.engines.한.name {
                return
            }
            notice("key while ABC → 속 한글")
            self.selectSokIMHangulFromShortcut()
        }
        recoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50), execute: work)
    }

    /**
     GLFW 게임은 플레이 중 커서를 화면 중심에 잠그고, 채팅에서 다시 움직이게 한다.
     T·/ 키 이름 없이, 잠김→이동 전환만으로 속을 한글에 붙인다.
     */
    private func startCursorWatch() {
        lastMouseLocation = NSEvent.mouseLocation
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.checkCursorForRawKoreanIME()
        }
        RunLoop.main.add(timer, forMode: .common)
        cursorWatch = timer
    }

    private func checkCursorForRawKoreanIME() {
        let now = NSEvent.mouseLocation
        let distance = hypot(now.x - lastMouseLocation.x, now.y - lastMouseLocation.y)
        lastMouseLocation = now
        if distance <= 2 {
            mouseStuckSamples = min(mouseStuckSamples + 1, 40)
            return
        }
        let wasLocked = mouseStuckSamples >= 8
        mouseStuckSamples = 0
        guard wasLocked else { return }
        guard looksLikeFrontmostRawGame() else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(80)) { [weak self] in
            guard let self else { return }
            if isSokIMCurrentInputSource() {
                if self.inputEngine.name != self.state.engines.한.name {
                    self.state.engine = self.state.engines.한
                    self.statusBar.setEngine(self.state.engines.한)
                    notice("cursor unlocked → 한글 엔진")
                }
                return
            }
            notice("cursor unlocked → 속 한글")
            self.selectSokIMHangulFromShortcut()
        }
    }

    /** 800ms Caps Lock 홀드 시 영문 엔진으로 고정 */
    func forceEnglishEngine() {
        debug()

        state.engine = state.engines.A
        statusBar.setEngine(state.engines.A)
    }

    /** 지금까지의 입력 전체 state와 sender에 조합 종료 반영 */
    func commit() {
        debug()

        debug("이전 state: \(state)")
        defer { debug("이후 state: \(state)") }

        if let sender = sender {
            if inputEngine.name == "가" {
                MarkedStrategy.commit(from: state, to: sender)
            } else {
                strategy(for: sender).commit(from: state, to: sender)
            }
            self.sender = nil
        }
        state.clear(composed: true, composing: true)
    }

    /** 전처리: 입력 정리 */
    private func filterInputs(_ inputs: inout [Input], event: NSEvent?) {
        debug("inputs: \(inputs)")

        var flags = Array(repeating: false, count: inputs.count)

        // 전체 input 중에 마지막과 동일한 context만 남김
        guard let last = inputs.last else { return }
        for (idx, input) in inputs.enumerated() where input.context == last.context {
            flags[idx] = true
        }

        // 남아있는 input 중에 event와 usage가 같은 것 이전은 버림
        if let event = event, let usage = keyCodeToUsage[Int(event.keyCode)] {
            var endIndex = -1

            for (idx, input) in inputs.enumerated() {
                // 남아있지 않거나 keyDown이 아닌 경우 넘어감
                guard flags[idx], input.type == .keyDown else {
                    continue
                }

                // usage가 같으면 기억 (반복되는 경우 가장 마지막 위치를 기억함)
                if input.usage == usage {
                    endIndex = idx
                }
                // usage가 다르고 기억이 있으면 중단 (앞쪽에 있는 첫번째 군집만 찾음)
                else if endIndex >= 0 {
                    break
                }
            }

            if endIndex >= 0 {
                for idx in 0..<endIndex {
                    flags[idx] = false
                }
            }
        }

        // 전체 input 중에 modifier와 modifier+space는 언제나 남김 // TODO: #15
        for (idx, input) in inputs.enumerated() {
            if let modifier = ModifierUsage(rawValue: input.usage) {
                flags[idx] = true

                // modifier의 keyDown–keyUp 사이에 있는 모든 space는 언제나 남김
                if input.type == .keyDown {
                    for (jdx, input) in inputs[idx..<inputs.endIndex].enumerated() {
                        if SpecialUsage(rawValue: input.usage) == .space {
                            flags[idx + jdx] = true
                        } else if ModifierUsage(rawValue: input.usage) == modifier && input.type == .keyUp {
                            break
                        }
                    }
                }
            }
        }

        debug("flags: \(flags)")

        inputs = inputs.indices.filter { flags[$0] }.map { inputs[$0] }
    }

    /** engine 선택 외 모든 상태 버림 */
    @objc func clearExceptEngine(_ aNotification: Notification?) {
        debug("\(String(describing: aNotification))")

        if isSokIMCurrentInputSource() || isIMEActive || (clientUsesRawMarkedText && isIMESettling) {
            notice("clearExceptEngine skipped")
            return
        }

        if clientUsesRawMarkedText {
            scheduleIMESettle()
            return
        }

        commit()
        inputMonitor.flush()
        state = State(engine: state.engine)
        sender = nil
        InputContext.commit()
        setKeyboardCapsLock(enabled: false)
    }

    /** 교체 설치 후 TIS에 속 입력기가 빠지면 handle()이 호출되지 않고 영문만 입력된다 */
    private func registerSokIMInputSource() {
        let url = URL(fileURLWithPath: "/Library/Input Methods/SokIM.app") as CFURL
        let status = TISRegisterInputSource(url)
        notice("TISRegisterInputSource \(status)")

        guard let list = TISCreateInputSourceList([
            kTISPropertyBundleID: "com.kiding.inputmethod.sok" as CFString
        ] as CFDictionary, true)?.takeRetainedValue() as? [TISInputSource] else {
            warning("속 입력기 TIS 소스 없음")
            return
        }

        notice("속 입력기 TIS 소스 \(list.count)개")
        for source in list {
            let enable = TISEnableInputSource(source)
            notice("TISEnableInputSource \(enable)")
        }
        persistSokIMEnabledSource()
    }

    /** 선택 가능한 속 모드를 고른다. 메서드 본체는 selectCapable가 아니다. */
    private func sokIMSelectableSource() -> TISInputSource? {
        guard let list = TISCreateInputSourceList([
            kTISPropertyBundleID: "com.kiding.inputmethod.sok" as CFString
        ] as CFDictionary, true)?.takeRetainedValue() as? [TISInputSource] else {
            return nil
        }
        for source in list {
            guard let typeOpaque = TISGetInputSourceProperty(source, kTISPropertyInputSourceType) else {
                continue
            }
            let type = Unmanaged<CFString>.fromOpaque(typeOpaque).takeUnretainedValue() as String
            if type == (kTISTypeKeyboardInputMode as String) {
                return source
            }
        }
        return list.first
    }

    @discardableResult
    private func selectSokIMInputSource() -> OSStatus {
        guard let sok = sokIMSelectableSource() else {
            warning("속 입력기 선택 소스 없음")
            return OSStatus(paramErr)
        }
        return TISSelectInputSource(sok)
    }

    /** GLFW TISCopyInputSourceForLanguage(ko)가 속을 찾도록 서드파티 활성 목록에 남긴다. */
    private func persistSokIMEnabledSource() {
        let entry: [String: Any] = [
            "Bundle ID": "com.kiding.inputmethod.sok",
            "Input Mode": "com.kiding.inputmethod.sok.mode",
            "InputSourceKind": "Input Mode"
        ]
        let key = "AppleEnabledThirdPartyInputSources" as CFString
        let app = "com.apple.HIToolbox" as CFString
        let existing = (CFPreferencesCopyAppValue(key, app) as? [[String: Any]]) ?? []
        if existing.contains(where: { $0["Bundle ID"] as? String == "com.kiding.inputmethod.sok" }) {
            return
        }
        var next = existing
        next.append(entry)
        CFPreferencesSetAppValue(key, next as CFArray, app)
        CFPreferencesAppSynchronize(app)
        notice("AppleEnabledThirdPartyInputSources에 속 추가")
    }

    private func looksLikeFrontmostRawGame() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        let bundle = app.bundleIdentifier ?? ""
        let name = (app.localizedName ?? "").lowercased()
        return bundle.isEmpty || bundle.contains("minecraft") || name.contains("java")
    }

    /** ASCII 키보드에서 애플 한글 IME로 바뀌면 앱이 한국어 IME를 켠 것이다. 속을 고른다. */
    @objc private func claimKoreanIMEIfNeeded(_ aNotification: Notification) {
        guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let idOpaque = TISGetInputSourceProperty(current, kTISPropertyInputSourceID)
        else { return }
        let currentID = Unmanaged<CFString>.fromOpaque(idOpaque).takeUnretainedValue() as String
        let previousID = lastInputSourceID
        lastInputSourceID = currentID

        let appleKorean = currentID.contains("com.apple.inputmethod.Korean")
        let stolenToABC = currentID.contains("keylayout")
            && looksLikeFrontmostRawGame()
            && mouseStuckSamples < 8
        guard appleKorean || stolenToABC else { return }

        imeSettleWork?.cancel()
        isIMESettling = false
        needsMarkedTextPrime = true
        if stolenToABC {
            state.engine = state.engines.한
            statusBar.setEngine(state.engines.한)
        }
        let status = selectSokIMInputSource()
        notice("claimKoreanIME \(previousID) → \(currentID) → sok \(status)")
        if let sender, clientUsesRawMarkedText {
            primeMarkedText(sender)
        }
    }

    /** 암호 입력 필드를 위한 ABC 입력기 제한 기능 */
    @objc private func suppressABC(_ aNotification: Notification) {
        debug("\(String(describing: aNotification))")

        guard Preferences.suppressABC == true else { return }

        guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            warning("TISCopyCurrentKeyboardInputSource 실패")
            return
        }

        guard let currentIDOpaque = TISGetInputSourceProperty(current, kTISPropertyInputSourceID) else {
            warning("TISGetInputSourceProperty 실패")
            return
        }
        let currentID = Unmanaged<CFString>.fromOpaque(currentIDOpaque).takeUnretainedValue() as String

        guard currentID == "com.apple.keylayout.ABC" || currentID == "com.apple.keylayout.US" else {
            debug("현재 입력기 ABC 아님: \(currentID)")
            return
        }

        guard let sokArray = TISCreateInputSourceList([
            kTISPropertyBundleID: "com.kiding.inputmethod.sok" as CFString
        ] as CFDictionary, true)?.takeRetainedValue() as? [TISInputSource],
              let sok = sokArray.first else {
            warning("TISCreateInputSourceList 실패")
            return
        }
        _ = TISEnableInputSource(sok)

        // "시스템 설정 > 암호" 필드에서는 무한 루프에 빠질 수 있음
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) {
            guard TISSelectInputSource(sok) == 0 else {
                warning("TISSelectInputSource 실패")
                return
            }

            debug("ABC 입력기 제한 성공")
        }
    }

    @objc private func abcOnSecureInput(_ aNotification: Notification) {
        debug("\(String(describing: aNotification))")

        guard IsSecureEventInputEnabled() else { return }
        notice("abcOnSecureInput: secure 입력이지만 한/A 엔진은 유지")
    }
}

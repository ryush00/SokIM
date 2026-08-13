import QuartzCore
import Carbon.HIToolbox

/** CGEvent 탭 콜백은 self를 못 쓰므로, Caps Lock down/up 쌍을 여기 둔다. */
private var capsLockTapDown = false

func resetCapsLockTapDown() {
    capsLockTapDown = false
}

enum HotKeyMonitorError: Error, CustomStringConvertible {
    case axProcessNotTrusted
    case failedToCreateTap
    case failedToEnableTap
    case failedToCreateSource
    case failedToInstall(OSStatus)
    case failedToRegister(OSStatus)

    var description: String {
        switch self {
        case .axProcessNotTrusted:
            "손쉬운 사용 권한을 허용해 주세요."
        case .failedToCreateTap:
            "알 수 없는 오류가 발생했습니다. (tapCreate)"
        case .failedToEnableTap:
            "알 수 없는 오류가 발생했습니다. (tapEnable)"
        case .failedToCreateSource:
            "알 수 없는 오류가 발생했습니다. (source)"
        case .failedToInstall(let err):
            "알 수 없는 오류가 발생했습니다. (install, \(err))"
        case .failedToRegister(let err):
            "알 수 없는 오류가 발생했습니다. (register, \(err))"
        }
    }
}

/**
 단축키 모니터링 및 사용자의 한/A 전환키 조합을 시스템에 등록
 - ``ClickMonitor``
 */
class HotKeyMonitor {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    var isTapEnabled: Bool {
        guard let tap else { return false }
        return CGEvent.tapIsEnabled(tap: tap)
    }

    private var eventHandlerRef: EventHandlerRef?
    private var eventHotKeyRefs: [EventHotKeyRef] = []

    func start() throws {
        debug()

        try startCGEvent()
        try startCarbonEvent()
    }

    private func startCGEvent() throws {
        debug()

        if tap != nil || source != nil {
            warning("초기화된 tap 또는 source가 이미 있음")
            return
        }

        let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(
                1 << CGEventType.keyDown.rawValue
                | 1 << CGEventType.flagsChanged.rawValue
            ),
            callback: { _, type, event, _ in
                debug("\(type) \(event.flags)")
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    appDelegate()?.restartMonitors(nil)
                    return Unmanaged.passUnretained(event)
                }

                let keycode = event.getIntegerValueField(.keyboardEventKeycode)
                if Preferences.rotateShortcuts.contains(.capsLock)
                    && keycode == Int64(kVK_CapsLock)
                    && isSokIMCurrentInputSource() {
                    // Caps Lock down/up이 쌍으로 온다. 한/A는 down에서만 전환하고, OS 대소문자는 흡수한다.
                    if !capsLockTapDown {
                        capsLockTapDown = true
                        notice("Caps Lock down → 한/A")
                        appDelegate()?.rotateFromShortcut()
                    } else {
                        capsLockTapDown = false
                        notice("Caps Lock up")
                        appDelegate()?.inputMonitor.cancelCapsLockHoldTimer()
                    }
                    setKeyboardCapsLock(enabled: false)
                    return nil
                }

                let flags = Int32(event.flags.rawValue)
                let isRightCommand = (flags & NX_COMMANDMASK != 0) && (flags & NX_DEVICERCMDKEYMASK != 0)
                let isRightOption = (flags & NX_ALTERNATEMASK != 0) && (flags & NX_DEVICERALTKEYMASK != 0)
                debug("isRightCommand: \(isRightCommand), isRightOption: \(isRightOption)")

                // 한/A키로 오른쪽 커맨드, 오른쪽 옵션 사용시 단축키 무시
                if Preferences.rotateShortcuts.contains(.rightCommand) && isRightCommand
                    || Preferences.rotateShortcuts.contains(.rightOption) && isRightOption {
                    debug("단축키 무시")
                    return nil
                } else {
                    return Unmanaged.passUnretained(event)
                }
            },
            userInfo: nil
        )
        guard let tap else {
            warning("CGEvent.tapCreate 실패")
            if AXIsProcessTrusted() {
                throw HotKeyMonitorError.failedToCreateTap
            } else {
                throw HotKeyMonitorError.axProcessNotTrusted
            }
        }
        self.tap = tap

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        guard let source else {
            warning("CFMachPortCreateRunLoopSource 실패")
            throw HotKeyMonitorError.failedToCreateSource
        }
        self.source = source

        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        CGEvent.tapEnable(tap: tap, enable: true)

        if !CGEvent.tapIsEnabled(tap: tap) {
            warning("CGEvent.tapEnable 실패")
            throw HotKeyMonitorError.failedToEnableTap
        }

        debug("CGEvent.tapEnable 성공")
    }

    private func startCarbonEvent() throws {
        debug()

        if eventHandlerRef != nil || eventHotKeyRefs.count > 0 {
            warning("초기화된 eventHandlerRef 또는 eventHotKeyRef가 이미 있음")
            return
        }

        /** eventHandlerRef */

        var eventHandlerRef: EventHandlerRef?
        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let err1 = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, _ in
                debug()
                return noErr
            },
            1,
            &eventSpec,
            nil,
            &eventHandlerRef
        )
        debug("InstallEventHandler 성공")
        if err1 != 0 {
            warning("InstallEventHandler 실패: \(err1)")
            throw HotKeyMonitorError.failedToInstall(err1)
        }
        self.eventHandlerRef = eventHandlerRef

        /** eventHotKeyRef */

        try Preferences.rotateShortcuts.forEach {
            var eventHotKeyRef: EventHotKeyRef?
            let code: UInt32
            let modifiers: UInt32

            switch $0 {
            case .capsLock:
                debug("HotKey 해당 없음")
                return
            case .rightCommand:
                debug("HotKey 해당 없음")
                return
            case .rightOption:
                debug("HotKey 해당 없음")
                return
            case .commandSpace:
                code = UInt32(kVK_Space)
                modifiers = UInt32(cmdKey)
            case .shiftSpace:
                code = UInt32(kVK_Space)
                modifiers = UInt32(shiftKey)
            case .controlSpace:
                code = UInt32(kVK_Space)
                modifiers = UInt32(controlKey)
            }

            let err2 = RegisterEventHotKey(
                code,
                modifiers,
                EventHotKeyID(signature: 0, id: 0),
                GetApplicationEventTarget(),
                0,
                &eventHotKeyRef
            )
            debug("RegisterEventHotKey 성공: \($0)")
            if err2 != 0 {
                warning("RegisterEventHotKey 실패: \(err2)")
                throw HotKeyMonitorError.failedToRegister(err2)
            }
            eventHotKeyRefs.append(eventHotKeyRef!)
        }
    }

    func stop() {
        stopCGEvent()
        stopCarbonEvent()
    }

    private func stopCGEvent() {
        debug()

        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            self.tap = nil
        } else {
            notice("초기화된 tap이 없음")
        }

        if let source {
            CFRunLoopSourceInvalidate(source)
            self.source = nil
        } else {
            notice("초기화된 source가 없음")
        }
    }

    private func stopCarbonEvent() {
        debug()

        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            debug("RemoveEventHandler 성공")
            self.eventHandlerRef = nil
        } else {
            notice("초기화된 eventHandlerRef가 없음")
        }

        if eventHotKeyRefs.count > 0 {
            eventHotKeyRefs.forEach {
                UnregisterEventHotKey($0)
                debug("UnregisterEventHotKey 성공")
            }
            eventHotKeyRefs = []
        } else {
            notice("초기화된 eventHotKeyRef가 없음")
        }
    }
}

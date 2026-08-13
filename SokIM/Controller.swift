import InputMethodKit

/**
 See `Info.plist`.
 */
@objc(Controller)
class Controller: IMKInputController {
    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        appDelegate()?.setIMEActive(true, client: sender)
    }

    override func deactivateServer(_ sender: Any!) {
        let deferCommit = appDelegate()?.shouldDeferIMECommit(client: sender) == true
        appDelegate()?.setIMEActive(false, client: sender)
        // marked text 속성이 없는 클라이언트는 IME on/off 때 기본 확정이
        // 자모를 하나씩 커밋한다. 그 외 앱은 IMK 기본 동작을 유지한다.
        if !deferCommit {
            super.deactivateServer(sender)
        }
    }

    override func commitComposition(_ sender: Any!) {
        if appDelegate()?.shouldSkipCommitComposition() == true {
            notice("commitComposition skipped during IME settle")
            return
        }
        appDelegate()?.commit()
    }

    override func recognizedEvents(_ sender: Any!) -> Int {
        Int(NSEvent.EventTypeMask.keyDown.rawValue)
    }

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        notice("Controller.handle key=\(event?.keyCode ?? 999) delegate=\(appDelegate() != nil)")
        return appDelegate()?.handle(event, client: sender) ?? false
    }
}

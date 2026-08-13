import InputMethodKit

/**
 See `Info.plist`.
 */
@objc(Controller)
class Controller: IMKInputController {
    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        appDelegate()?.setIMEActive(true)
    }

    override func deactivateServer(_ sender: Any!) {
        super.deactivateServer(sender)
        appDelegate()?.setIMEActive(false)
    }

    override func recognizedEvents(_ sender: Any!) -> Int {
        Int(NSEvent.EventTypeMask.keyDown.rawValue)
    }

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        notice("Controller.handle key=\(event?.keyCode ?? 999) delegate=\(appDelegate() != nil)")
        return appDelegate()?.handle(event, client: sender) ?? false
    }
}

import Cocoa
import Foundation

let defaultRange = NSRange(location: NSNotFound, length: 0)

/** 입력 상태 및 변화 */
struct State: CustomStringConvertible {
    init() {}

    // MARK: - Input

    /** modifier 키 눌림 상태 (InputMonitor와 유사) */
    var modifier: [ModifierUsage: InputType] = [:]

    /** Input 처리에서 도출된 Caps Lock 키 활성화 상태 */
    private var isCapsLockOn = false

    /** 한/A 전환이 Caps Lock인 경우 Caps Lock이 활성화/비활성화 되는 과정에서 한/A 전환이 진행될 수 있는지 여부를 판단하는 플래그 (InputMonitor와 유사) */
    private var canCapsLockRotate = true

    /** InputMonitor가 이미 한/A 전환을 반영한 경우 handle()의 중복 rotate를 건너뛴다 */
    private var skipNextRotate = false

    /** 마지막으로 keyDown이었던 Caps Lock Input */
    private var lastCapsLockDownInput: Input?

    /** 현재 눌려있는 Input, 반복 입력 시 사용 */
    private(set) var down: Input?

    /** 새로운 Input 입력 처리 */
    mutating func next(_ input: Input) {
        debug("\(input)")

        let (usage, type) = (input.usage, input.type)

        // usage가 modifier인 경우
        if let key = ModifierUsage(rawValue: usage) {
            modifier[key] = type

            // 한/A 전환은 단축키 경로(탭/HID)에서만 한다.
            // 여기서 다시 rotate하면 다음 글자의 handle()이 Caps Lock keyDown을
            // 한 번 더 보고 한글에서 영문으로 되돌린다.
            if (type, key) == (.keyDown, .capsLock) {
                if Preferences.rotateShortcuts.contains(.capsLock) {
                    isCapsLockOn = false
                    lastCapsLockDownInput = input
                    skipNextRotate = false
                } else {
                    isCapsLockOn.toggle()
                }
            }

            // Caps Lock keyUp: 800ms 홀드는 InputMonitor 타이머가 StatusBar와 함께 처리한다.
            // HID timestamp로 여기서 engine만 A로 바꾸면 트레이와 입력이 어긋난다.
            if (type, key) == (.keyUp, .capsLock)
                && Preferences.rotateShortcuts.contains(.capsLock) {
                lastCapsLockDownInput = nil
            }
        }
        // 그 외 경우 중 keyDown인 경우
        else if type == .keyDown {
            // 눌린 키를 down에 기록
            down = input

            // Command, Shift, Option, Control
            let isCommandDown = modifier[.leftCommand] == .keyDown || modifier[.rightCommand] == .keyDown
            let isShiftDown = modifier[.leftShift] == .keyDown || modifier[.rightShift] == .keyDown
            let isOptionDown = modifier[.leftOption] == .keyDown || modifier[.rightOption] == .keyDown
            let isControlDown = modifier[.leftControl] == .keyDown || modifier[.rightControl] == .keyDown

            // Command/Shift/Control + Space: keyDown인 경우 한/A 전환 // TODO: #15
            if (
                isCommandDown
                && usage == SpecialUsage.space.rawValue
                && Preferences.rotateShortcuts.contains(.commandSpace)
            ) || (
                isShiftDown
                && usage == SpecialUsage.space.rawValue
                && Preferences.rotateShortcuts.contains(.shiftSpace)
            ) || (
                isControlDown
                && usage == SpecialUsage.space.rawValue
                && Preferences.rotateShortcuts.contains(.controlSpace)
            ) {
                if skipNextRotate {
                    skipNextRotate = false
                } else {
                    rotate()
                }
                return
            }

            // Control, Command: keyDown 상태인 경우 키 무시
            if isControlDown || isCommandDown {
                debug("Input ignored: \(input) \(modifier)")

                return
            }

            // engine으로 현재 input을 tuple로 변환 가능하면
            if var tuple = engine.usageToTuple(usage, isOptionDown, isShiftDown, isCapsLockOn) {
                // "₩ 대신 ` 입력" 처리
                if tuple.char == "₩" && Preferences.graveOverWon {
                    tuple.char = "`"
                }

                // 입력 진행
                next(tuple)
            }
            // 그 외 모든 경우
            else {
                debug("Input ignored: \(input)")
            }
        }
        // 그 외 경우 중 keyUp인 경우
        else if type == .keyUp {
            // 같은 키면 down 삭제
            if down?.usage == input.usage {
                down = nil
            }
        }
        // 그 외 경우
        else {
            debug("Input ignored: \(input)")
        }
    }

    // MARK: - KeyboardEngine

    var engine: Engine.Type {
        get { appDelegate()?.inputEngine ?? TwoSetEngine.self }
        set {
            if appDelegate()?.inputEngine.name != newValue.name {
                appDelegate()?.inputEngine = newValue
            }
        }
    }

    init(engine: Engine.Type) {
        debug("\(engine)")
        self.engine = engine
    }
    let engines = (한: TwoSetEngine.self, A: QwertyEngine.self) // TODO: #24

    /** HID 단축키에서 즉시 전환하고, 이어지는 handle()의 rotate()는 건너뛴다 */
    mutating func rotateFromShortcut() {
        debug()

        engine = engine == engines.한 ? engines.A : engines.한
        skipNextRotate = true
        appDelegate()?.statusBar.setEngine(engine)
    }

    /** 사용 가능한 다음 engine으로 변경 */
    mutating func rotate() {
        debug()

        if skipNextRotate {
            skipNextRotate = false
            debug("단축키 전환이 이미 반영됨")
            appDelegate()?.statusBar.setEngine(engine)
            return
        }

        engine = engine == engines.한 ? engines.A : engines.한

        appDelegate()?.statusBar.setEngine(engine)
    }

    // MARK: - CharTuple

    /** 완성 */
    private(set) var composed: String = ""  // å / å  / åé  |   /
    /** 조합 */
    private(set) var composing: String = "" //   / ´  /     | ㄱ / 가

    // TODO: 세벌식 모아치기 (두 글자 이상 조합) 지원
    // TODO: combineChars(String, Character)?
    /** 새로운 CharTuple 입력 처리 */
    mutating func next(_ tuple: CharTuple) {
        debug("\(tuple)")

        let (inputChar, inputMarked) = tuple
        let markedChar = composing.last
        var nextText: String

        // 조합 중인 마지막 글자가 있으면 새로 입력된 글자와 합치기
        if markedChar != nil {
            nextText = engine.combineChars(markedChar!, inputChar)
        }
        // 없으면 새로 입력된 글자 그대로 사용
        else {
            nextText = "\(inputChar)"
        }

        // 새로 입력된 글자가 이후 조합을 허용하면 조합으로 저장
        if inputMarked {
            composing = "\(nextText.popLast() ?? "?")"
        }
        // 아니면 조합 비움
        else {
            composing = ""
        }

        // 완성 갱신
        composed += nextText
    }

    /** 완성/조합 버림 */
    mutating func clear(composed includeComposed: Bool, composing includeComposing: Bool) {
        debug("composed: \(includeComposed), composing: \(includeComposing)")

        if includeComposed {
            composed = ""
        }

        if includeComposing {
            composing = ""
        }
    }

    mutating func backspaceComposing() {
        debug()

        // 조합에서 마지막 글자를 꺼냈을 때, 글자가 있다면
        if let oldLast = composing.popLast() {
            debug("oldLast: \(oldLast)")

            // engine을 통해 뒤로 삭제, 이후에도 글자가 남아있으면
            if let newLast = engine.backspaceComposing(oldLast) {
                debug("newLast: \(newLast)")

                // 다시 조합에 붙임
                composing += "\(newLast)"
            }
        }
    }

    // MARK: - CustomStringConvertible

    var description: String { "\(engine) '\(composed)' [\(composing)] \(modifier)" }
}

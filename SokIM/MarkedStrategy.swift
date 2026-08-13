import InputMethodKit

struct MarkedStrategy: Strategy {
    private static func markedString(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.backgroundColor: NSColor.clear])
    }

    static func backspace(from state: State, to sender: IMKTextInput, with composing: String) -> Bool {
        debug("\(composing) -> \(state)")

        // composing이 변경된 경우
        if composing != state.composing {
            sender.setMarkedText(markedString(state.composing), selectionRange: defaultRange, replacementRange: defaultRange)

            // OS가 추가 처리 하지 않음
            return true
        } else {
            // OS가 추가 처리함
            return false
        }
    }

    static func next(from state: State, to sender: IMKTextInput, with composing: String) -> Bool {
        debug("\(composing) -> \(state)")

        // composed -> insertText
        if state.composed.count > 0 {
            /*
             블록 선택 상태일 때 미리 setMarkedText를 하지 않으면 오작동하는 상황 처리
             예시: "asdf" -> ⌘A -> "asdf" 입력 -> "sdf" (Safari에서 작동하는 구글 문서 등)
             */
            let selectedRange = sender.selectedRange()
            if 0 < selectedRange.length && selectedRange.length < NSNotFound {
                sender.setMarkedText(markedString(state.composed), selectionRange: defaultRange, replacementRange: selectedRange)
            }

            // GLFW는 조합 중인 NFD preedit를 insertText로 커밋한다. 먼저 비운다.
            if usesRawMarkedText(sender) {
                sender.setMarkedText(NSAttributedString(string: ""), selectionRange: NSRange(location: 0, length: 0), replacementRange: defaultRange)
            }

            sender.insertText(state.composed, replacementRange: defaultRange)
        }

        // composing -> setMarkedText
        if state.composing.count > 0 {
            sender.setMarkedText(markedString(state.composing), selectionRange: defaultRange, replacementRange: defaultRange)
        }

        return true
    }

    static func commit(from state: State, to sender: IMKTextInput) {
        debug("\(state)")

        if usesRawMarkedText(sender) && (!state.composed.isEmpty || !state.composing.isEmpty) {
            sender.setMarkedText(NSAttributedString(string: ""), selectionRange: NSRange(location: 0, length: 0), replacementRange: defaultRange)
        }

        // composed -> insertText
        if state.composed.count > 0 {
            sender.insertText(state.composed, replacementRange: defaultRange)
        }

        // composing -> insertText
        if state.composing.count > 0 {
            sender.insertText(state.composing, replacementRange: defaultRange)
        }
    }
}

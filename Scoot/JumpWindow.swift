import Cocoa

class JumpWindow: TransparentWindow {

    override func awakeFromNib() {
        super.awakeFromNib()

        level = .floating
    }

    // Display-only overlay: never take key/main from `KeyboardInputWindow`, or
    // keystrokes land here and beep until Scoot is re-invoked.
    override var canBecomeKey: Bool {
        return false
    }

    override var canBecomeMain: Bool {
        return false
    }

}

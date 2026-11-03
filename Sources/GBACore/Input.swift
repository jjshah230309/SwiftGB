import Foundation

/// Everything a key or controller button can be bound to.
public enum InputAction: String, CaseIterable, Codable, Sendable {
    case a, b, l, r, start, select, up, down, left, right
    case fastForward, rewind

    public var title: String {
        switch self {
        case .a: "A"; case .b: "B"; case .l: "L"; case .r: "R"; case .start: "Start"; case .select: "Select"
        case .up: "Up"; case .down: "Down"; case .left: "Left"; case .right: "Right"
        case .fastForward: "Fast-forward (hold)"; case .rewind: "Rewind (hold)"
        }
    }

    /// The console button this drives, or nil for emulator hotkeys.
    public var gbaKey: GBAKeys? {
        switch self {
        case .a: .a; case .b: .b; case .l: .l; case .r: .r; case .start: .start; case .select: .select
        case .up: .up; case .down: .down; case .left: .left; case .right: .right
        case .fastForward, .rewind: nil
        }
    }
}

/// Controller elements, named after GameController's extended gamepad (`buttonA` is the bottom face button).
public enum PadButton: String, CaseIterable, Codable, Sendable {
    case buttonA, buttonB, buttonX, buttonY
    case leftShoulder, rightShoulder, leftTrigger, rightTrigger
    case buttonMenu, buttonOptions
    case dpadUp, dpadDown, dpadLeft, dpadRight          // the d-pad and the left stick both report these

    public var title: String {
        switch self {
        case .buttonA: "Ⓐ South"; case .buttonB: "Ⓑ East"; case .buttonX: "Ⓧ West"; case .buttonY: "Ⓨ North"
        case .leftShoulder: "L1"; case .rightShoulder: "R1"; case .leftTrigger: "L2"; case .rightTrigger: "R2"
        case .buttonMenu: "Menu"; case .buttonOptions: "Options"
        case .dpadUp: "D-pad ↑"; case .dpadDown: "D-pad ↓"; case .dpadLeft: "D-pad ←"; case .dpadRight: "D-pad →"
        }
    }
}

/// Which keys and controller buttons trigger which actions. A value type so the mapping logic can be tested without a UI.
public struct InputBindings: Codable, Equatable, Sendable {
    public var keyboard: [InputAction: [UInt16]]
    public var pad: [InputAction: [PadButton]]

    public init(keyboard: [InputAction: [UInt16]], pad: [InputAction: [PadButton]]) {
        self.keyboard = keyboard; self.pad = pad
    }

    /// Z/X for A/B (so the right hand rests on the arrows), A/S for the shoulders; physical Ⓑ(east)=A and Ⓐ(south)=B like the console's layout.
    public static let defaults = InputBindings(
        keyboard: [
            .a: [6], .b: [7], .l: [0], .r: [1], .start: [36, 76], .select: [51, 60],
            .up: [126], .down: [125], .left: [123], .right: [124],
            .fastForward: [48], .rewind: [13],
        ],
        pad: [
            .a: [.buttonB], .b: [.buttonA], .l: [.leftShoulder], .r: [.rightShoulder],
            .start: [.buttonMenu], .select: [.buttonOptions],
            .up: [.dpadUp], .down: [.dpadDown], .left: [.dpadLeft], .right: [.dpadRight],
            .fastForward: [.rightTrigger], .rewind: [.leftTrigger],
        ])

    /// Actions currently held, given the keys and controller buttons that are down.
    public func actions(keys: Set<UInt16>, pad buttons: Set<PadButton>) -> Set<InputAction> {
        var result = Set<InputAction>()
        for action in InputAction.allCases {
            if (keyboard[action] ?? []).contains(where: keys.contains) || (pad[action] ?? []).contains(where: buttons.contains) { result.insert(action) }
        }
        return result
    }

    /// The console buttons held for a set of actions.
    public static func gbaKeys(for actions: Set<InputAction>) -> GBAKeys {
        actions.reduce(into: GBAKeys()) { if let k = $1.gbaKey { $0.insert(k) } }
    }

    /// Bind a key to an action, taking it away from whatever else used it so one key never does two things.
    public mutating func bind(key: UInt16, to action: InputAction, replacing old: UInt16? = nil) {
        for a in InputAction.allCases { keyboard[a]?.removeAll { $0 == key } }
        var list = keyboard[action] ?? []
        if let old, let i = list.firstIndex(of: old) { list[i] = key } else { list.append(key) }
        keyboard[action] = list
    }

    public mutating func bind(button: PadButton, to action: InputAction, replacing old: PadButton? = nil) {
        for a in InputAction.allCases { pad[a]?.removeAll { $0 == button } }
        var list = pad[action] ?? []
        if let old, let i = list.firstIndex(of: old) { list[i] = button } else { list.append(button) }
        pad[action] = list
    }

    public mutating func clearKeys(for action: InputAction) { keyboard[action] = [] }
    public mutating func clearButtons(for action: InputAction) { pad[action] = [] }

    // MARK: persistence
    public func encoded() -> Data? { try? JSONEncoder().encode(self) }
    public static func decode(_ data: Data?) -> InputBindings? { data.flatMap { try? JSONDecoder().decode(InputBindings.self, from: $0) } }
}

/// Names for macOS virtual key codes (ANSI layout), for showing what a key is bound to.
public enum KeyNames {
    private static let table: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
        30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "Return", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\",
        43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 48: "Tab", 49: "Space", 50: "`", 51: "Delete", 53: "Esc",
        54: "Right ⌘", 55: "Left ⌘", 56: "Left ⇧", 57: "Caps Lock", 58: "Left ⌥", 59: "Left ⌃", 60: "Right ⇧", 61: "Right ⌥", 62: "Right ⌃",
        65: "Keypad .", 67: "Keypad *", 69: "Keypad +", 75: "Keypad /", 76: "Enter", 78: "Keypad -", 81: "Keypad =",
        82: "Keypad 0", 83: "Keypad 1", 84: "Keypad 2", 85: "Keypad 3", 86: "Keypad 4", 87: "Keypad 5", 88: "Keypad 6", 89: "Keypad 7", 91: "Keypad 8", 92: "Keypad 9",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11", 105: "F13", 109: "F10", 111: "F12", 113: "F15",
        115: "Home", 116: "Page Up", 117: "Forward Delete", 118: "F4", 119: "End", 120: "F2", 121: "Page Down", 122: "F1",
        123: "←", 124: "→", 125: "↓", 126: "↑",
    ]
    public static func name(_ code: UInt16) -> String { table[code] ?? "Key \(code)" }
}

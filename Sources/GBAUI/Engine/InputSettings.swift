import Combine
import Foundation
import GameController
import GBACore

/// The user's key and controller bindings, persisted.
@MainActor
public final class InputSettings: ObservableObject {
    private static let key = "inputBindings.v1"
    @Published public var bindings: InputBindings {
        didSet { if let data = bindings.encoded() { UserDefaults.standard.set(data, forKey: Self.key) } }
    }

    public init() {
        bindings = InputBindings.decode(UserDefaults.standard.data(forKey: Self.key)) ?? .defaults
    }

    public func resetToDefaults() { bindings = .defaults }
}

/// Game controllers through GameController.framework. Reports which `PadButton`s are held across all connected controllers.
@MainActor
public final class GamepadInput: ObservableObject {
    @Published public private(set) var controllerNames: [String] = []
    /// Called with the full set of held buttons whenever it changes.
    public var onChange: ((Set<PadButton>) -> Void)?
    /// One-shot: the next button pressed is delivered here instead of the usual path (used while rebinding).
    public var capture: ((PadButton) -> Void)?

    private var held: [ObjectIdentifier: Set<PadButton>] = [:]
    private var started = false

    public init() {}

    public func start() {
        guard !started else { return }
        started = true
        let nc = NotificationCenter.default
        nc.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated { if let c = n.object as? GCController { self?.attach(c) } }
        }
        nc.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated { if let c = n.object as? GCController { self?.detach(c) } }
        }
        GCController.controllers().forEach(attach)
        GCController.startWirelessControllerDiscovery {}
    }

    private func attach(_ controller: GCController) {
        guard let pad = controller.extendedGamepad else { return }
        pad.valueChangedHandler = { [weak self, weak controller] pad, _ in
            guard let controller else { return }
            MainActor.assumeIsolated { self?.update(controller, GamepadInput.pressed(pad)) }
        }
        refreshNames()
    }

    private func detach(_ controller: GCController) {
        held[ObjectIdentifier(controller)] = nil
        refreshNames()
        onChange?(union())
    }

    private func refreshNames() { controllerNames = GCController.controllers().compactMap { $0.extendedGamepad != nil ? ($0.vendorName ?? "Controller") : nil } }
    private func union() -> Set<PadButton> { held.values.reduce(into: Set()) { $0.formUnion($1) } }

    private func update(_ controller: GCController, _ now: Set<PadButton>) {
        let id = ObjectIdentifier(controller)
        let before = held[id] ?? []
        held[id] = now
        if let capture, let first = now.subtracting(before).sorted(by: { $0.rawValue < $1.rawValue }).first {
            self.capture = nil
            capture(first)
            return                                       // a rebinding press must not also drive the game
        }
        onChange?(union())
    }

    /// Which elements of one controller are held. The left stick counts as the d-pad.
    static func pressed(_ pad: GCExtendedGamepad) -> Set<PadButton> {
        var s = Set<PadButton>()
        func add(_ b: PadButton, _ on: Bool) { if on { s.insert(b) } }
        add(.buttonA, pad.buttonA.isPressed); add(.buttonB, pad.buttonB.isPressed)
        add(.buttonX, pad.buttonX.isPressed); add(.buttonY, pad.buttonY.isPressed)
        add(.leftShoulder, pad.leftShoulder.isPressed); add(.rightShoulder, pad.rightShoulder.isPressed)
        add(.leftTrigger, pad.leftTrigger.isPressed); add(.rightTrigger, pad.rightTrigger.isPressed)
        add(.buttonMenu, pad.buttonMenu.isPressed); add(.buttonOptions, pad.buttonOptions?.isPressed ?? false)
        let x = pad.leftThumbstick.xAxis.value, y = pad.leftThumbstick.yAxis.value
        add(.dpadUp, pad.dpad.up.isPressed || y > 0.5); add(.dpadDown, pad.dpad.down.isPressed || y < -0.5)
        add(.dpadLeft, pad.dpad.left.isPressed || x < -0.5); add(.dpadRight, pad.dpad.right.isPressed || x > 0.5)
        return s
    }
}

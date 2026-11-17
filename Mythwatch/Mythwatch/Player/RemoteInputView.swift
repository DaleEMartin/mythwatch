import SwiftUI
import UIKit

/// What the remote did, as the player screen understands it (SPEC 7 "Player controls"). The
/// screen maps each to a `TransportModel` intent; nothing here decides what an input means.
struct RemoteInput {
    var select: () -> Void = {}
    var playPause: () -> Void = {}
    var left: () -> Void = {}
    var right: () -> Void = {}
    var menu: () -> Void = {}
    /// A horizontal swipe on the touch surface, in full swipes (1 = across the whole surface).
    var swipe: (Double) -> Void = { _ in }
    var swipeDown: () -> Void = {}
    /// A finger on the touch surface (a tap, or the start of a swipe), without a click.
    var touch: () -> Void = {}
}

/// A full-screen, focusable UIKit view that receives the remote's presses and touch-surface
/// swipes. SwiftUI cannot tell a swipe from a click or report how far a swipe went, so this one
/// piece is UIKit. It must be the only focusable thing on the player while the panel is closed.
struct RemoteInputView: UIViewRepresentable {
    let input: RemoteInput

    func makeUIView(context: Context) -> RemoteInputUIView {
        let view = RemoteInputUIView()
        view.input = input
        return view
    }

    func updateUIView(_ view: RemoteInputUIView, context: Context) {
        view.input = input
    }
}

final class RemoteInputUIView: UIView {
    var input = RemoteInput()

    /// How the current swipe is being read, decided once it has moved far enough.
    private enum SwipeKind { case undecided, horizontal, down, ignored }
    private var swipeKind = SwipeKind.undecided
    private var lastX: CGFloat = 0
    /// Sideways movement before a swipe is read as a scrub.
    private let decideDistance: CGFloat = 40
    /// A swipe down opens the panel only once it has gone this share of the surface's height,
    /// mostly straight down, so a resting finger or a drift does not open it (owner, 2026-11-16).
    private let downShare: CGFloat = 0.3

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        addGestureRecognizer(pan)
        accessibilityIdentifier = "player.input"
    }

    required init?(coder: NSCoder) { fatalError("not used from a storyboard") }

    override var canBecomeFocused: Bool { true }

    // MARK: Presses

    private static let handled: Set<UIPress.PressType> = [.select, .playPause, .leftArrow, .rightArrow, .menu]

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let others = presses.filter { !Self.handled.contains($0.type) }
        if !others.isEmpty { super.pressesBegan(others, with: event) }
    }

    /// Acted on when the press ends, as UIKit buttons do. Menu is not passed on, so the system
    /// does not close the screen behind the model's back.
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var others = Set<UIPress>()
        for press in presses {
            switch press.type {
            case .select: input.select()
            case .playPause: input.playPause()
            case .leftArrow: input.left()
            case .rightArrow: input.right()
            case .menu: input.menu()
            default: others.insert(press)
            }
        }
        if !others.isEmpty { super.pressesEnded(others, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let others = presses.filter { !Self.handled.contains($0.type) }
        if !others.isEmpty { super.pressesCancelled(others, with: event) }
    }

    // MARK: Touches

    /// Any touch on the touch surface, before it is known to be a swipe or a click.
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if touches.contains(where: { $0.type == .indirect }) { input.touch() }
        super.touchesBegan(touches, with: event)
    }

    // MARK: Swipes

    @objc private func panned(_ pan: UIPanGestureRecognizer) {
        let t = pan.translation(in: self)
        switch pan.state {
        case .began:
            swipeKind = .undecided
            lastX = 0
        case .changed:
            if swipeKind == .undecided {
                if t.y >= bounds.height * downShare, t.y > 2 * abs(t.x) {
                    swipeKind = .down
                    input.swipeDown()
                } else if abs(t.x) >= decideDistance, abs(t.x) >= abs(t.y) {
                    swipeKind = .horizontal
                    lastX = 0  // count the deciding movement too
                } else if -t.y >= decideDistance, -t.y > abs(t.x) {
                    swipeKind = .ignored
                }
            }
            if swipeKind == .horizontal, bounds.width > 0 {
                input.swipe(Double((t.x - lastX) / bounds.width))
                lastX = t.x
            }
        default:
            swipeKind = .undecided
        }
    }
}

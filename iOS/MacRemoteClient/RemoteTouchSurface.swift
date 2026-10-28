import SwiftUI
import UIKit

struct RemoteTouchSurface: UIViewRepresentable {
    var onAction: (TouchSurfaceState.Action) -> Void

    func makeUIView(context: Context) -> TouchInputView { TouchInputView() }
    func updateUIView(_ view: TouchInputView, context: Context) {
        view.onAction = onAction
        view.isUserInteractionEnabled = context.environment.isEnabled
    }
    static func dismantleUIView(_ view: TouchInputView, coordinator: ()) {
        view.cancelTouch()
        view.onAction = nil
    }
}

final class TouchInputView: UIView {
    var onAction: ((TouchSurfaceState.Action) -> Void)?
    private var interaction = TouchSurfaceState()
    private var holdTimer: Timer?
    private var resignObserver: NSObjectProtocol?

    init() {
        super.init(frame: .zero)
        backgroundColor = .black
        isMultipleTouchEnabled = false
        resignObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.cancelTouch() }
    }
    required init?(coder: NSCoder) { return nil }
    override var isUserInteractionEnabled: Bool {
        didSet { if !isUserInteractionEnabled { cancelTouch() } }
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { cancelTouch() }
    }
    private func emit(_ actions: [TouchSurfaceState.Action]) {
        for action in actions { onAction?(action) }
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        holdTimer?.invalidate()
        emit(interaction.begin(at: touch.location(in: self), now: touch.timestamp))
        let timer = Timer(timeInterval: TouchSurfaceState.holdDuration, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.emit(self.interaction.advance(now: ProcessInfo.processInfo.systemUptime))
        }
        holdTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        emit(interaction.move(to: touch.location(in: self), now: touch.timestamp))
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        holdTimer?.invalidate(); holdTimer = nil
        guard let touch = touches.first else { cancelTouch(); return }
        emit(interaction.end(at: touch.location(in: self), now: touch.timestamp))
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { cancelTouch() }
    func cancelTouch() {
        holdTimer?.invalidate(); holdTimer = nil
        emit(interaction.cancel())
    }
    deinit {
        holdTimer?.invalidate()
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
    }
}

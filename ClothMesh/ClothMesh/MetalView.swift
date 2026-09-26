import MetalKit
import SwiftUI

struct MetalView: NSViewRepresentable {
    let model: AppModel

    final class Coordinator {
        var renderer: Renderer?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ClothMTKView {
        let view = ClothMTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        guard let renderer = Renderer(view: view, model: model) else {
            fatalError("Metal is not available on this Mac")
        }
        context.coordinator.renderer = renderer
        view.delegate = renderer
        view.renderer = renderer
        model.renderer = renderer
        return view
    }

    func updateNSView(_ nsView: ClothMTKView, context: Context) {}
}

/// MTKView that routes AppKit mouse, trackpad and keyboard input to the renderer.
/// Left button always belongs to the cloth when it hits; misses fall back to orbiting.
final class ClothMTKView: MTKView {
    weak var renderer: Renderer?

    private enum LeftDrag { case none, grab, orbit, pan }
    private var leftDrag = LeftDrag.none
    private var keyMonitor: Any?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        guard let window else { return }
        window.makeFirstResponder(self)
        // A local monitor so shortcuts work even when a HUD control has focus.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window,
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  let key = event.charactersIgnoringModifiers?.lowercased(),
                  let renderer = self.renderer else { return event }
            return renderer.handleKey(key) ? nil : event
        }
    }

    private func location(of event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    // MARK: Left button / trackpad click-drag

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let renderer else { return }
        if event.modifierFlags.contains(.option) {
            leftDrag = .pan
        } else if renderer.beginGrab(at: location(of: event), viewSize: bounds.size) {
            leftDrag = .grab
            NSCursor.closedHand.set()
        } else {
            leftDrag = .orbit
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let renderer else { return }
        switch leftDrag {
        case .grab: renderer.dragGrab(to: location(of: event), viewSize: bounds.size)
        case .orbit: renderer.orbit(dx: event.deltaX, dy: event.deltaY)
        case .pan: renderer.pan(dx: event.deltaX, dy: -event.deltaY, viewHeight: bounds.height)
        case .none: break
        }
    }

    override func mouseUp(with event: NSEvent) {
        if leftDrag == .grab {
            renderer?.endGrab()
            NSCursor.arrow.set()
        }
        leftDrag = .none
    }

    // MARK: Right / middle buttons

    override func rightMouseDragged(with event: NSEvent) {
        renderer?.orbit(dx: event.deltaX, dy: event.deltaY)
    }

    override func otherMouseDragged(with event: NSEvent) {
        renderer?.pan(dx: event.deltaX, dy: -event.deltaY, viewHeight: bounds.height)
    }

    // MARK: Scroll / pinch

    override func scrollWheel(with event: NSEvent) {
        guard let renderer else { return }
        let isGesture = !event.phase.isEmpty || !event.momentumPhase.isEmpty
        if isGesture {
            // Trackpad two-finger scroll: orbit.
            renderer.orbit(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY)
        } else {
            // Mouse wheel: dolly.
            let scale: Float = event.hasPreciseScrollingDeltas ? 0.01 : 0.1
            renderer.dolly(by: exp(-Float(event.scrollingDeltaY) * scale))
        }
    }

    override func magnify(with event: NSEvent) {
        renderer?.dolly(by: 1 / max(0.2, 1 + Float(event.magnification)))
    }
}

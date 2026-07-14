import HexaKeyboardCore
import SwiftUI
import UIKit

let minimumKeyboardScale: CGFloat = 0.84
let maximumKeyboardScale: CGFloat = 3.0

// Compatibility aliases for the Android viewport constants.
let MIN_KEYBOARD_SCALE = minimumKeyboardScale
let MAX_KEYBOARD_SCALE = maximumKeyboardScale

private let keyboardEdgeMargin: CGFloat = 24
private let keyboardFitTolerance: CGFloat = 0.5

func toolbarDragToKeyboardPan(_ drag: CGPoint) -> CGPoint {
    CGPoint(x: drag.x, y: drag.y == 0 ? 0 : -drag.y)
}

func toolbarDragToKeyboardPan(_ drag: CGSize) -> CGSize {
    CGSize(width: drag.width, height: drag.height == 0 ? 0 : -drag.height)
}

func constrainKeyboardPan(
    requestedPan: CGPoint,
    contentSize: CGSize,
    viewportSize: CGSize,
    edgeMargin: CGFloat = keyboardEdgeMargin
) -> CGPoint {
    CGPoint(
        x: constrainKeyboardPanAxis(
            requested: requestedPan.x,
            content: contentSize.width,
            viewport: viewportSize.width,
            edgeMargin: edgeMargin
        ),
        y: constrainKeyboardPanAxis(
            requested: requestedPan.y,
            content: contentSize.height,
            viewport: viewportSize.height,
            edgeMargin: edgeMargin
        )
    )
}

private func constrainKeyboardPanAxis(
    requested: CGFloat,
    content: CGFloat,
    viewport: CGFloat,
    edgeMargin: CGFloat
) -> CGFloat {
    guard requested.isFinite, content.isFinite, viewport.isFinite else { return 0 }
    guard content > viewport + keyboardFitTolerance else { return 0 }

    let overflowFromCenter = (content - viewport) / 2
    let limit = overflowFromCenter + max(0, edgeMargin)
    return min(max(requested, -limit), limit)
}

private struct KeyboardModelBounds: Equatable {
    let minX: CGFloat
    let maxX: CGFloat
    let minY: CGFloat
    let maxY: CGFloat

    var width: CGFloat { maxX - minX }
    var height: CGFloat { maxY - minY }
}

private struct KeyboardViewportTransform: Equatable {
    let scale: CGFloat
    let offsetX: CGFloat
    let offsetY: CGFloat
    let viewportPan: CGPoint

    static let identity = KeyboardViewportTransform(
        scale: 1,
        offsetX: 0,
        offsetY: 0,
        viewportPan: .zero
    )

    func point(_ point: HexPoint) -> CGPoint {
        CGPoint(
            x: CGFloat(point.x) * scale + offsetX,
            y: CGFloat(point.y) * scale + offsetY
        )
    }

    func model(_ point: CGPoint) -> HexPoint {
        let safeScale = max(0.000_001, scale)
        return HexPoint(
            x: Double((point.x - offsetX) / safeScale),
            y: Double((point.y - offsetY) / safeScale)
        )
    }
}

private enum KeyboardViewport {
    static func modelBounds(for layout: HexaKeyboardLayout) -> KeyboardModelBounds {
        guard !layout.cells.isEmpty else {
            return KeyboardModelBounds(minX: -1, maxX: 1, minY: -1, maxY: 1)
        }

        let outline = layout.windowOutline.bounds
        let keys = layout.keyBounds
        return KeyboardModelBounds(
            minX: CGFloat(min(keys.minX, outline.minX)),
            maxX: CGFloat(max(keys.maxX, outline.maxX)),
            minY: CGFloat(min(keys.minY, outline.minY)),
            maxY: CGFloat(max(keys.maxY, outline.maxY))
        )
    }

    static func transform(
        layout: HexaKeyboardLayout,
        viewportSize: CGSize,
        scaleMultiplier: CGFloat,
        requestedPan: CGPoint
    ) -> KeyboardViewportTransform {
        let bounds = modelBounds(for: layout)
        let fittedScale = min(
            max(1, viewportSize.width) / max(1, bounds.width),
            max(1, viewportSize.height) / max(1, bounds.height)
        )
        let scale = fittedScale
            * min(max(scaleMultiplier, minimumKeyboardScale), maximumKeyboardScale)
        let contentSize = CGSize(
            width: bounds.width * scale,
            height: bounds.height * scale
        )
        let viewportPan = constrainKeyboardPan(
            requestedPan: requestedPan,
            contentSize: contentSize,
            viewportSize: viewportSize,
            edgeMargin: keyboardEdgeMargin
        )

        return KeyboardViewportTransform(
            scale: scale,
            offsetX: (viewportSize.width - contentSize.width) / 2
                - bounds.minX * scale
                + viewportPan.x,
            offsetY: (viewportSize.height - contentSize.height) / 2
                - bounds.minY * scale
                + viewportPan.y,
            viewportPan: viewportPan
        )
    }
}

struct HexKeyboardSurface: UIViewRepresentable {
    let layout: HexaKeyboardLayout
    let scale: CGFloat
    let pan: CGPoint
    let touchSensitivity: Double
    let pseudoPressureEnabled: Bool
    let selectedCoordinates: Set<AxialCoordinate>
    let selectionAnchorCoordinate: AxialCoordinate?
    let playbackTimeline: KeyboardPlaybackTimeline?
    let playbackPositionSeconds: Double
    let activePlaybackNoteIndices: Set<Int>
    let onConstrainedPan: @MainActor (CGPoint) -> Void
    let onKeyDown: @MainActor (Int, HexKey, Int, Int64) -> Void
    let onKeyPressure: @MainActor (Int, Int) -> Void
    let onKeyUp: @MainActor (Int, Int64, Bool) -> Void

    init(
        layout: HexaKeyboardLayout,
        scale: CGFloat = 1,
        pan: CGPoint = .zero,
        touchSensitivity: Double = 1.2,
        pseudoPressureEnabled: Bool = true,
        selectedCoordinates: Set<AxialCoordinate> = [],
        selectionAnchorCoordinate: AxialCoordinate? = nil,
        playbackTimeline: KeyboardPlaybackTimeline? = nil,
        playbackPositionSeconds: Double = 0,
        activePlaybackNoteIndices: Set<Int> = [],
        onConstrainedPan: @escaping @MainActor (CGPoint) -> Void = { _ in },
        onKeyDown: @escaping @MainActor (Int, HexKey, Int, Int64) -> Void,
        onKeyPressure: @escaping @MainActor (Int, Int) -> Void = { _, _ in },
        onKeyUp: @escaping @MainActor (Int, Int64, Bool) -> Void
    ) {
        self.layout = layout
        self.scale = scale
        self.pan = pan
        self.touchSensitivity = touchSensitivity
        self.pseudoPressureEnabled = pseudoPressureEnabled
        self.selectedCoordinates = selectedCoordinates
        self.selectionAnchorCoordinate = selectionAnchorCoordinate
        self.playbackTimeline = playbackTimeline
        self.playbackPositionSeconds = playbackPositionSeconds
        self.activePlaybackNoteIndices = activePlaybackNoteIndices
        self.onConstrainedPan = onConstrainedPan
        self.onKeyDown = onKeyDown
        self.onKeyPressure = onKeyPressure
        self.onKeyUp = onKeyUp
    }

    func makeUIView(context: Context) -> HexKeyboardCanvasView {
        let view = HexKeyboardCanvasView()
        update(view)
        return view
    }

    func updateUIView(_ uiView: HexKeyboardCanvasView, context: Context) {
        update(uiView)
    }

    static func dismantleUIView(_ uiView: HexKeyboardCanvasView, coordinator: ()) {
        uiView.releaseAllTouches()
    }

    private func update(_ view: HexKeyboardCanvasView) {
        view.configure(
            layout: layout,
            scale: scale,
            pan: pan,
            touchSensitivity: touchSensitivity,
            pseudoPressureEnabled: pseudoPressureEnabled,
            selectedCoordinates: selectedCoordinates,
            selectionAnchorCoordinate: selectionAnchorCoordinate,
            playbackTimeline: playbackTimeline,
            playbackPositionSeconds: playbackPositionSeconds,
            activePlaybackNoteIndices: activePlaybackNoteIndices,
            onConstrainedPan: onConstrainedPan,
            onKeyDown: onKeyDown,
            onKeyPressure: onKeyPressure,
            onKeyUp: onKeyUp
        )
    }
}

@MainActor
final class HexKeyboardCanvasView: UIControl {
    private var keyboardLayout = HexaKeyboardLayoutEngine.build()
    private var viewportTransform = KeyboardViewportTransform.identity
    private var requestedScale: CGFloat = 1
    private var requestedPan: CGPoint = .zero
    private var touchSensitivity = 1.2
    private var pseudoPressureEnabled = true
    private var selectedCoordinates: Set<AxialCoordinate> = []
    private var selectionAnchorCoordinate: AxialCoordinate?
    private var playbackTimeline: KeyboardPlaybackTimeline?
    private var playbackPositionSeconds = 0.0
    private var activePlaybackNoteIndices: Set<Int> = []

    private var onConstrainedPan: (@MainActor (CGPoint) -> Void)?
    private var onKeyDown: (@MainActor (Int, HexKey, Int, Int64) -> Void)?
    private var onKeyPressure: (@MainActor (Int, Int) -> Void)?
    private var onKeyUp: (@MainActor (Int, Int64, Bool) -> Void)?

    private var touchCoordinates: [ObjectIdentifier: AxialCoordinate] = [:]
    private var touchForces: [ObjectIdentifier: Double] = [:]
    private var forceTrackers: [ObjectIdentifier: PseudoPressureTracker] = [:]
    private var lastExpressions: [ObjectIdentifier: Int] = [:]
    private var keyByCoordinate: [AxialCoordinate: HexKey] = [:]
    private var keyAccessibilityElements: [HexKeyAccessibilityElement] = []
    private var lastViewportSize: CGSize = .zero
    private var lastReportedConstrainedPan: CGPoint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        isExclusiveTouch = false
        isOpaque = true
        backgroundColor = AppPalette.uiBackground
        contentMode = .redraw
        isAccessibilityElement = false
        accessibilityLabel = "六边形微分音键盘"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()

        // SwiftUI's outer ScrollView must not delay or steal instrument touches.
        var ancestor = superview
        while let view = ancestor {
            if let scrollView = view as? UIScrollView {
                scrollView.delaysContentTouches = false
                scrollView.canCancelContentTouches = false
            }
            ancestor = view.superview
        }
    }

    func configure(
        layout: HexaKeyboardLayout,
        scale: CGFloat,
        pan: CGPoint,
        touchSensitivity: Double,
        pseudoPressureEnabled: Bool,
        selectedCoordinates: Set<AxialCoordinate>,
        selectionAnchorCoordinate: AxialCoordinate?,
        playbackTimeline: KeyboardPlaybackTimeline?,
        playbackPositionSeconds: Double,
        activePlaybackNoteIndices: Set<Int>,
        onConstrainedPan: @escaping @MainActor (CGPoint) -> Void,
        onKeyDown: @escaping @MainActor (Int, HexKey, Int, Int64) -> Void,
        onKeyPressure: @escaping @MainActor (Int, Int) -> Void,
        onKeyUp: @escaping @MainActor (Int, Int64, Bool) -> Void
    ) {
        let safeScale = min(max(scale.isFinite ? scale : 1, minimumKeyboardScale), maximumKeyboardScale)
        let safeSensitivity = min(max(touchSensitivity.isFinite ? touchSensitivity : 1.2, 1), 1.5)
        let safePan = CGPoint(
            x: pan.x.isFinite ? pan.x : 0,
            y: pan.y.isFinite ? pan.y : 0
        )
        let inputChanged = keyboardLayout != layout
            || requestedScale != safeScale
            || requestedPan != safePan
            || self.touchSensitivity != safeSensitivity
            || self.pseudoPressureEnabled != pseudoPressureEnabled

        self.onConstrainedPan = onConstrainedPan
        self.onKeyDown = onKeyDown
        self.onKeyPressure = onKeyPressure
        self.onKeyUp = onKeyUp

        if inputChanged, !touchCoordinates.isEmpty {
            releaseAllTouches()
        }

        let layoutChanged = keyboardLayout != layout
        keyboardLayout = layout
        requestedScale = safeScale
        requestedPan = safePan
        self.touchSensitivity = safeSensitivity
        self.pseudoPressureEnabled = pseudoPressureEnabled
        self.selectedCoordinates = selectedCoordinates
        self.selectionAnchorCoordinate = selectionAnchorCoordinate
        self.playbackTimeline = playbackTimeline
        self.playbackPositionSeconds = playbackPositionSeconds.isFinite
            ? max(0, playbackPositionSeconds)
            : 0
        self.activePlaybackNoteIndices = activePlaybackNoteIndices

        if layoutChanged || keyByCoordinate.isEmpty {
            keyByCoordinate = Dictionary(
                uniqueKeysWithValues: layout.cells.map { ($0.coordinate, $0) }
            )
            rebuildAccessibilityElements()
        }

        updateViewportTransform(notifyConstraint: true)
        setNeedsDisplay()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if lastViewportSize != bounds.size, !touchCoordinates.isEmpty {
            releaseAllTouches()
        }
        lastViewportSize = bounds.size
        updateViewportTransform(notifyConstraint: true)
        setNeedsDisplay()
    }

    func releaseAllTouches() {
        let eventTime = currentUptimeMilliseconds()
        for identifier in touchCoordinates.keys {
            onKeyUp?(touchID(for: identifier), eventTime, false)
        }
        touchCoordinates.removeAll()
        touchForces.removeAll()
        forceTrackers.removeAll()
        lastExpressions.removeAll()
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.setFillColor(AppPalette.uiBackground.cgColor)
        context.fill(bounds)

        let activeForces = activeForceByCoordinate()
        let playbackMode = playbackTimeline != nil
        let playbackFrame = playbackVisualFrame()
        let displayedSelections = playbackMode
            ? Set(activeForces.keys)
            : selectedCoordinates.union(activeForces.keys)

        drawOrigin(in: context)
        drawKeys(
            in: context,
            activeForces: activeForces,
            playbackMode: playbackMode,
            playbackFrame: playbackFrame
        )
        if playbackMode {
            drawPlaybackEffects(in: context, frame: playbackFrame)
        }
        drawSelectionOutlines(
            in: context,
            selectedCoordinates: displayedSelections,
            activeForces: activeForces
        )
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        window?.endEditing(true)
        for touch in touches {
            processCoalescedSamples(for: touch, event: event, includeCurrent: true)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            processCoalescedSamples(for: touch, event: event, includeCurrent: true)
        }
    }

    override func touchesEstimatedPropertiesUpdated(_ touches: Set<UITouch>) {
        for touch in touches where touch.phase != .ended && touch.phase != .cancelled {
            processSample(
                touch,
                identifier: ObjectIdentifier(touch),
                pressed: true
            )
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            processCoalescedSamples(for: touch, event: event, includeCurrent: false)
            processSample(
                touch,
                identifier: ObjectIdentifier(touch),
                pressed: false
            )
            clearTracker(for: touch)
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            cancel(touch)
        }
    }

    override var accessibilityElements: [Any]? {
        get { keyAccessibilityElements }
        set { }
    }

    private func updateViewportTransform(notifyConstraint: Bool) {
        viewportTransform = KeyboardViewport.transform(
            layout: keyboardLayout,
            viewportSize: bounds.size,
            scaleMultiplier: requestedScale,
            requestedPan: requestedPan
        )
        updateAccessibilityFrames()

        guard notifyConstraint, bounds.width > 0, bounds.height > 0 else { return }
        let constrainedPan = viewportTransform.viewportPan
        if constrainedPan != requestedPan {
            guard lastReportedConstrainedPan != constrainedPan else { return }
            lastReportedConstrainedPan = constrainedPan
            let callback = onConstrainedPan
            DispatchQueue.main.async {
                callback?(constrainedPan)
            }
        } else {
            lastReportedConstrainedPan = nil
        }
    }

    private func processCoalescedSamples(
        for touch: UITouch,
        event: UIEvent?,
        includeCurrent: Bool
    ) {
        let identifier = ObjectIdentifier(touch)
        var processedCurrent = false
        for sample in event?.coalescedTouches(for: touch) ?? [] {
            if sample === touch {
                processedCurrent = true
                if !includeCurrent { continue }
            }
            processSample(sample, identifier: identifier, pressed: true)
        }
        if includeCurrent, !processedCurrent {
            processSample(touch, identifier: identifier, pressed: true)
        }
    }

    private func processSample(
        _ touch: UITouch,
        identifier: ObjectIdentifier,
        pressed: Bool
    ) {
        let pointer = touchID(for: identifier)
        let eventTime = milliseconds(for: touch)
        let modelPoint = viewportTransform.model(touch.location(in: self))
        let previousCoordinate = touchCoordinates[identifier]
        let nextKey = pressed
            ? HexTouchHitTester.key(
                at: modelPoint,
                in: keyboardLayout,
                previousCoordinate: previousCoordinate,
                sensitivity: touchSensitivity
            )
            : nil
        let force: TouchForce? = nextKey.map { key in
            if pseudoPressureEnabled {
                let tracker = forceTrackers[identifier] ?? PseudoPressureTracker()
                forceTrackers[identifier] = tracker
                return tracker.sample(
                    rawPressure: normalizedPressure(for: touch),
                    uptimeMilliseconds: eventTime,
                    point: modelPoint,
                    keyCenter: key.center,
                    keyRadius: Double(keyboardLayout.configuration.radius),
                    hardwarePressureHint: touch.type == .pencil
                )
            }
            return .fixed
        }

        let nextCoordinate = nextKey?.coordinate
        let keyChanged = previousCoordinate != nextCoordinate
        if keyChanged {
            if previousCoordinate != nil {
                touchCoordinates.removeValue(forKey: identifier)
                touchForces.removeValue(forKey: identifier)
                lastExpressions.removeValue(forKey: identifier)
                onKeyUp?(pointer, eventTime, !pressed)
            }
            if let nextKey, let force {
                touchCoordinates[identifier] = nextKey.coordinate
                onKeyDown?(pointer, nextKey, force.velocity, eventTime)
            }
        }

        if nextKey != nil, let force {
            touchForces[identifier] = force.normalized
            let previousExpression = lastExpressions[identifier]
            if keyChanged
                || previousExpression == nil
                || abs(force.expression - (previousExpression ?? force.expression)) >= 2
            {
                lastExpressions[identifier] = force.expression
                onKeyPressure?(pointer, force.expression)
            }
        } else {
            touchForces.removeValue(forKey: identifier)
            lastExpressions.removeValue(forKey: identifier)
        }
        setNeedsDisplay()
    }

    private func cancel(_ touch: UITouch) {
        let identifier = ObjectIdentifier(touch)
        if touchCoordinates.removeValue(forKey: identifier) != nil {
            onKeyUp?(touchID(for: identifier), milliseconds(for: touch), false)
        }
        touchForces.removeValue(forKey: identifier)
        lastExpressions.removeValue(forKey: identifier)
        forceTrackers.removeValue(forKey: identifier)
        setNeedsDisplay()
    }

    private func clearTracker(for touch: UITouch) {
        let identifier = ObjectIdentifier(touch)
        forceTrackers.removeValue(forKey: identifier)
    }

    private func normalizedPressure(for touch: UITouch) -> Double {
        let maximum = touch.maximumPossibleForce
        guard maximum.isFinite, maximum > 0, touch.force.isFinite else { return 1 }
        return Double(touch.force / maximum)
    }

    private func milliseconds(for touch: UITouch) -> Int64 {
        let timestamp = touch.timestamp.isFinite
            ? max(0, touch.timestamp)
            : ProcessInfo.processInfo.systemUptime
        return Int64((timestamp * 1_000).rounded())
    }

    private func currentUptimeMilliseconds() -> Int64 {
        Int64((ProcessInfo.processInfo.systemUptime * 1_000).rounded())
    }

    private func touchID(for identifier: ObjectIdentifier) -> Int {
        Int(bitPattern: identifier)
    }

    private func activeForceByCoordinate() -> [AxialCoordinate: Double] {
        var result: [AxialCoordinate: Double] = [:]
        for (identifier, coordinate) in touchCoordinates {
            let force = touchForces[identifier] ?? TouchForce.fixed.normalized
            result[coordinate] = max(result[coordinate] ?? 0, force)
        }
        return result
    }

    /// The playback-core dependency is intentionally concentrated here so the
    /// surface stays easy to adapt if the timeline API evolves.
    private func playbackVisualFrame() -> PlaybackVisualFrame {
        playbackTimeline?.visualFrame(
            at: playbackPositionSeconds,
            activeScoreIndices: activePlaybackNoteIndices
        ) ?? .empty
    }

    private func drawOrigin(in context: CGContext) {
        let origin = viewportTransform.point(HexPoint(x: 0, y: 0))
        let arm: CGFloat = 8
        context.saveGState()
        context.setStrokeColor(AppPalette.uiAccent.withAlphaComponent(0.72).cgColor)
        context.setFillColor(AppPalette.uiAccent.cgColor)
        context.setLineWidth(1.4)
        context.move(to: CGPoint(x: origin.x - arm, y: origin.y))
        context.addLine(to: CGPoint(x: origin.x + arm, y: origin.y))
        context.move(to: CGPoint(x: origin.x, y: origin.y - arm))
        context.addLine(to: CGPoint(x: origin.x, y: origin.y + arm))
        context.strokePath()
        context.fillEllipse(in: CGRect(x: origin.x - 2.5, y: origin.y - 2.5, width: 5, height: 5))
        context.restoreGState()
    }

    private func drawKeys(
        in context: CGContext,
        activeForces: [AxialCoordinate: Double],
        playbackMode: Bool,
        playbackFrame: PlaybackVisualFrame
    ) {
        let radius = (CGFloat(keyboardLayout.configuration.radius) - 1.5)
            * viewportTransform.scale
        let rotation = CGFloat(keyboardLayout.configuration.rotationDegrees)

        for key in keyboardLayout.cells {
            let center = viewportTransform.point(key.center)
            let path = hexagonPath(center: center, radius: radius, rotationDegrees: rotation)
            let tone = playbackTone(for: key)

            context.saveGState()
            context.addPath(path)
            context.setFillColor(
                (playbackMode ? tone.dimColor : pitchColor(for: key)).cgColor
            )
            context.fillPath()

            if playbackMode, let visual = playbackFrame.keys[key.coordinate] {
                drawPlaybackFill(
                    in: context,
                    path: path,
                    center: center,
                    radius: radius,
                    tone: tone,
                    visual: visual
                )
            }
            if let activeForce = activeForces[key.coordinate] {
                context.addPath(path)
                context.setFillColor(
                    AppPalette.uiSelection
                        .withAlphaComponent(0.08 + CGFloat(activeForce) * 0.20)
                        .cgColor
                )
                context.fillPath()
            }

            context.addPath(path)
            context.setStrokeColor(AppPalette.uiLine.cgColor)
            context.setLineWidth(max(1, radius * 0.045))
            context.strokePath()
            context.restoreGState()

            drawPitchLabel(for: key, at: center, radius: radius)
        }
    }

    private struct PlaybackKeyTone {
        let hue: CGFloat
        let saturation: CGFloat

        func color(brightness: CGFloat, alpha: CGFloat = 1) -> UIColor {
            UIColor(
                hue: positiveUnit(hue),
                saturation: min(max(saturation, 0), 1),
                brightness: min(max(brightness, 0), 1),
                alpha: min(max(alpha, 0), 1)
            )
        }

        var dimColor: UIColor { color(brightness: 0.22) }
    }

    private func playbackTone(for key: HexKey) -> PlaybackKeyTone {
        PlaybackKeyTone(
            hue: toneHue(
                index: key.pitchClass,
                count: max(1, keyboardLayout.configuration.period)
            ),
            saturation: 0.62
        )
    }

    private func drawPlaybackFill(
        in context: CGContext,
        path: CGPath,
        center: CGPoint,
        radius: CGFloat,
        tone: PlaybackKeyTone,
        visual: PlaybackKeyVisual
    ) {
        let flash = min(max(CGFloat(visual.flash), 0), 1)
        if visual.isActive {
            context.addPath(path)
            context.setFillColor(
                tone.color(brightness: 0.88 + flash * 0.26).cgColor
            )
            context.fillPath()
            return
        }

        if let upcoming = visual.upcoming {
            let progress = min(max(CGFloat(upcoming.progress), 0), 1)
            let sweep = progress * 360
            if sweep > 0.1 {
                let arcRadius = radius * 1.08
                let outerBrightness = 0.22 + (0.76 - 0.22) * progress
                let middleBrightness = 0.22 + (outerBrightness - 0.22) * 0.58
                let colors = [
                    tone.color(brightness: 0.22).cgColor,
                    tone.color(brightness: middleBrightness).cgColor,
                    tone.color(brightness: outerBrightness).cgColor,
                ] as CFArray
                if let gradient = CGGradient(
                    colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                    colors: colors,
                    locations: [0, 0.58, 1]
                ) {
                    let startAngle = (-90 - sweep / 2) * .pi / 180
                    let endAngle = startAngle + sweep * .pi / 180
                    context.saveGState()
                    context.addPath(path)
                    context.clip()
                    context.move(to: center)
                    context.addArc(
                        center: center,
                        radius: arcRadius,
                        startAngle: startAngle,
                        endAngle: endAngle,
                        clockwise: false
                    )
                    context.closePath()
                    context.clip()
                    context.drawRadialGradient(
                        gradient,
                        startCenter: center,
                        startRadius: 0,
                        endCenter: center,
                        endRadius: arcRadius,
                        options: []
                    )
                    context.restoreGState()
                }
            }
        }

        if flash > 0.01 {
            context.addPath(path)
            context.setFillColor(
                tone.color(
                    brightness: 0.88 + flash * 0.26,
                    alpha: flash * 0.34
                ).cgColor
            )
            context.fillPath()
        }
    }

    private func drawPlaybackEffects(in context: CGContext, frame: PlaybackVisualFrame) {
        let radius = (CGFloat(keyboardLayout.configuration.radius) - 1.5)
            * viewportTransform.scale
        let rotation = CGFloat(keyboardLayout.configuration.rotationDegrees)

        for (coordinate, visual) in frame.keys {
            guard let key = keyByCoordinate[coordinate] else { continue }
            let center = viewportTransform.point(key.center)
            let tone = playbackTone(for: key)
            if visual.isActive {
                drawPlaybackTrackOutlines(
                    in: context,
                    center: center,
                    radius: radius,
                    rotationDegrees: rotation,
                    tracks: visual.activeTracks,
                    flash: CGFloat(visual.flash)
                )
                drawActivePlaybackParticles(
                    in: context,
                    center: center,
                    radius: radius,
                    tone: tone,
                    visual: visual
                )
            }
            if !visual.completedNotes.isEmpty {
                drawCompletedPlaybackParticles(
                    in: context,
                    center: center,
                    radius: radius,
                    tone: tone,
                    visual: visual
                )
            }
        }
    }

    private func drawPlaybackTrackOutlines(
        in context: CGContext,
        center: CGPoint,
        radius: CGFloat,
        rotationDegrees: CGFloat,
        tracks: [Int],
        flash: CGFloat
    ) {
        guard !tracks.isEmpty else { return }
        let safeFlash = min(max(flash, 0), 1)
        let strokeWidth = max(1.35, radius * 0.052)
        let layerSpacing = max(strokeWidth * 1.62, radius * 0.068)

        for (index, track) in tracks.prefix(Self.maxPlaybackTrackLayers).enumerated() {
            let layerRadius = max(radius * 0.42, radius * 1.01 - CGFloat(index) * layerSpacing)
            let path = hexagonPath(
                center: center,
                radius: layerRadius,
                rotationDegrees: rotationDegrees
            )
            let color = trackColor(track)

            context.saveGState()
            context.addPath(path)
            context.setStrokeColor(
                color.withAlphaComponent(0.20 + safeFlash * 0.18).cgColor
            )
            context.setLineWidth(strokeWidth * 2.45)
            context.strokePath()
            context.addPath(path)
            context.setStrokeColor(
                color.withAlphaComponent(min(1, 0.86 + safeFlash * 0.14)).cgColor
            )
            context.setLineWidth(strokeWidth)
            context.strokePath()
            context.restoreGState()
        }
    }

    private func drawActivePlaybackParticles(
        in context: CGContext,
        center: CGPoint,
        radius: CGFloat,
        tone: PlaybackKeyTone,
        visual: PlaybackKeyVisual
    ) {
        let flash = min(max(CGFloat(visual.flash), 0), 1)
        for note in visual.activeNotes.prefix(Self.maxActiveParticleNotes) {
            let emphasized = note.repeatedHit || flash >= 0.34
            let particleCount = emphasized ? 6 : 2
            let elapsed = max(0, playbackPositionSeconds - note.start)
            let velocityRatio = CGFloat(min(max(note.velocity, 1), 127)) / 127

            for particleIndex in 0..<particleCount {
                let seed = playbackParticleSeed(
                    note: note,
                    particleIndex: particleIndex,
                    salt: Self.activeParticleSalt
                )
                let phaseSeed = deterministicUnit(seed)
                let rate = 0.50 + deterministicUnit(seed ^ 0x1357_9BDF) * 0.38
                let phase = CGFloat(
                    (elapsed * Double(rate) + Double(phaseSeed))
                        .truncatingRemainder(dividingBy: 1)
                )
                let spread = (deterministicUnit(seed ^ 0x0246_8ACE) - 0.5)
                    * .pi
                    * 0.92
                let flutter = sin((phase + phaseSeed) * .pi * 2) * 0.10
                let angle = -CGFloat.pi / 2 + spread + flutter
                let distance = radius * (0.10 + phase * 0.72)
                let position = CGPoint(
                    x: center.x + cos(angle) * distance,
                    y: center.y + sin(angle) * distance - radius * phase * 0.08
                )
                let alpha = (1 - phase)
                    * (0.24 + velocityRatio * 0.24 + flash * 0.38)
                let particleRadius = max(
                    0.85,
                    radius
                        * (0.022 + deterministicUnit(seed ^ 0x0102_0304) * 0.030)
                        * (1 - phase * 0.42)
                )
                drawParticle(
                    in: context,
                    center: position,
                    radius: particleRadius,
                    color: tone.color(
                        brightness: 0.82 + flash * 0.16,
                        alpha: alpha
                    )
                )
            }
        }
    }

    private func drawCompletedPlaybackParticles(
        in context: CGContext,
        center: CGPoint,
        radius: CGFloat,
        tone: PlaybackKeyTone,
        visual: PlaybackKeyVisual
    ) {
        for completed in visual.completedNotes {
            let note = completed.note
            let progress = min(max(CGFloat(completed.progress), 0), 1)
            let fade = (1 - progress) * (1 - progress)
            let expansion = progress * (2 - progress)
            let particleCount = note.repeatedHit || visual.flash >= 0.34 ? 18 : 10
            let velocityRatio = CGFloat(min(max(note.velocity, 1), 127)) / 127

            for particleIndex in 0..<particleCount {
                let seed = playbackParticleSeed(
                    note: note,
                    particleIndex: particleIndex,
                    salt: Self.completedParticleSalt
                )
                let direction = deterministicUnit(seed) * .pi * 2
                let speed = 0.68 + deterministicUnit(seed ^ 0x0314_1592) * 0.62
                let distance = radius * (0.12 + expansion * speed)
                let gravity = radius
                    * progress
                    * progress
                    * (0.06 + deterministicUnit(seed ^ 0x0271_8281) * 0.20)
                let position = CGPoint(
                    x: center.x + cos(direction) * distance,
                    y: center.y + sin(direction) * distance + gravity
                )
                let particleRadius = max(
                    0.75,
                    radius
                        * (0.025 + deterministicUnit(seed ^ 0x055A_A55A) * 0.045)
                        * (1 - progress * 0.48)
                )
                drawParticle(
                    in: context,
                    center: position,
                    radius: particleRadius,
                    color: tone.color(
                        brightness: 0.84 + velocityRatio * 0.14,
                        alpha: fade * (0.58 + velocityRatio * 0.34)
                    )
                )
            }
        }
    }

    private func drawParticle(
        in context: CGContext,
        center: CGPoint,
        radius: CGFloat,
        color: UIColor
    ) {
        guard radius > 0 else { return }
        context.saveGState()
        context.setFillColor(color.cgColor)
        context.fillEllipse(
            in: CGRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            )
        )
        context.restoreGState()
    }

    private func drawSelectionOutlines(
        in context: CGContext,
        selectedCoordinates: Set<AxialCoordinate>,
        activeForces: [AxialCoordinate: Double]
    ) {
        let radius = (CGFloat(keyboardLayout.configuration.radius) - 1.5)
            * viewportTransform.scale
        let rotation = CGFloat(keyboardLayout.configuration.rotationDegrees)

        for coordinate in selectedCoordinates {
            guard let key = keyByCoordinate[coordinate] else { continue }
            let activeForce = activeForces[coordinate]
            let strokeWidth = max(
                2.4,
                radius * (activeForce.map { 0.12 + CGFloat($0) * 0.08 } ?? 0.12)
            )
            let path = hexagonPath(
                center: viewportTransform.point(key.center),
                radius: radius,
                rotationDegrees: rotation
            )

            context.saveGState()
            context.addPath(path)
            context.setStrokeColor(
                AppPalette.uiSelection.withAlphaComponent(0.32).cgColor
            )
            context.setLineWidth(strokeWidth + 2)
            context.strokePath()
            context.addPath(path)
            context.setStrokeColor(AppPalette.uiSelection.cgColor)
            context.setLineWidth(strokeWidth)
            context.strokePath()
            context.restoreGState()
        }
    }

    private func pitchColor(for key: HexKey) -> UIColor {
        UIColor(
            hue: toneHue(
                index: key.pitchClass,
                count: max(1, keyboardLayout.configuration.period)
            ),
            saturation: 0.62,
            brightness: 0.43,
            alpha: 1
        )
    }

    private func toneHue(index: Int, count: Int) -> CGFloat {
        let safeCount = max(1, count)
        let normalizedIndex = ((index % safeCount) + safeCount) % safeCount
        return CGFloat(normalizedIndex) / CGFloat(safeCount)
    }

    private func trackColor(_ track: Int) -> UIColor {
        let hueDegrees: CGFloat
        if Self.playbackTrackHues.indices.contains(track) {
            hueDegrees = Self.playbackTrackHues[track]
        } else {
            hueDegrees = positiveDegrees(
                Self.playbackTrackHues[0] + CGFloat(track) * Self.playbackTrackGoldenAngle
            )
        }
        return UIColor(hue: hueDegrees / 360, saturation: 0.86, brightness: 0.98, alpha: 1)
    }

    private func drawPitchLabel(for key: HexKey, at center: CGPoint, radius: CGFloat) {
        guard radius >= 5 else { return }
        let text = String(key.pitchClass) as NSString
        let font = UIFont.monospacedSystemFont(ofSize: max(7, radius * 0.43), weight: .bold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: AppPalette.uiPrimaryText,
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2),
            withAttributes: attributes
        )
    }

    private func hexagonPath(
        center: CGPoint,
        radius: CGFloat,
        rotationDegrees: CGFloat
    ) -> CGPath {
        let path = CGMutablePath()
        for index in 0..<6 {
            let angle = (CGFloat(index) * 60 + rotationDegrees) * .pi / 180
            let point = CGPoint(
                x: center.x + radius * cos(angle),
                y: center.y + radius * sin(angle)
            )
            index == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        path.closeSubpath()
        return path
    }

    private func playbackParticleSeed(
        note: KeyboardPlaybackNote,
        particleIndex: Int,
        salt: UInt32
    ) -> UInt32 {
        var seed = UInt32(bitPattern: Int32(truncatingIfNeeded: note.scoreIndex)) &* 73_856_093
        seed ^= UInt32(bitPattern: Int32(truncatingIfNeeded: note.track)) &* 19_349_663
        seed ^= UInt32(bitPattern: Int32(truncatingIfNeeded: note.coordinate.q)) &* 83_492_791
        seed ^= UInt32(bitPattern: Int32(truncatingIfNeeded: note.coordinate.r)) &* 49_979_687
        seed ^= UInt32(bitPattern: Int32(truncatingIfNeeded: particleIndex)) &* 961_748_927
        seed ^= salt
        return seed
    }

    private func deterministicUnit(_ seed: UInt32) -> CGFloat {
        var value = seed
        value ^= value >> 16
        value &*= UInt32(bitPattern: Int32(-2_048_144_789))
        value ^= value >> 13
        value &*= UInt32(bitPattern: Int32(-1_028_477_387))
        value ^= value >> 16
        return CGFloat((value >> 8) & 0x00FF_FFFF) / 16_777_215
    }

    private func rebuildAccessibilityElements() {
        keyAccessibilityElements = keyboardLayout.cells.enumerated().map { index, key in
            let element = HexKeyAccessibilityElement(accessibilityContainer: self)
            element.accessibilityLabel = "音级 \(key.pitchClass)"
            element.accessibilityValue = String(format: "%.3f 赫兹", key.audioPitch.frequency)
            element.accessibilityTraits = .button
            element.coordinate = key.coordinate
            element.activation = { [weak self] in
                guard let self else { return false }
                let pointer = -10_000 - index
                let eventTime = self.currentUptimeMilliseconds()
                self.onKeyDown?(pointer, key, TouchForce.fixed.velocity, eventTime)
                self.onKeyPressure?(pointer, TouchForce.fixed.expression)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { [weak self] in
                    guard let self else { return }
                    self.onKeyUp?(pointer, self.currentUptimeMilliseconds(), true)
                }
                return true
            }
            return element
        }
        updateAccessibilityFrames()
    }

    private func updateAccessibilityFrames() {
        let radius = CGFloat(keyboardLayout.configuration.radius) * viewportTransform.scale
        for element in keyAccessibilityElements {
            guard let coordinate = element.coordinate,
                  let key = keyByCoordinate[coordinate] else { continue }
            let center = viewportTransform.point(key.center)
            element.accessibilityFrameInContainerSpace = CGRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            )
        }
    }

    private static let playbackTrackHues: [CGFloat] = [190, 28, 132, 48, 264, 158, 330, 88]
    private static let playbackTrackGoldenAngle: CGFloat = 137.508
    private static let maxPlaybackTrackLayers = 8
    private static let maxActiveParticleNotes = 3
    private static let activeParticleSalt: UInt32 = 0x1A2B_3C4D
    private static let completedParticleSalt: UInt32 = 0x4D3C_2B1A
}

private func positiveUnit(_ value: CGFloat) -> CGFloat {
    let remainder = value.truncatingRemainder(dividingBy: 1)
    return remainder >= 0 ? remainder : remainder + 1
}

private func positiveDegrees(_ value: CGFloat) -> CGFloat {
    let remainder = value.truncatingRemainder(dividingBy: 360)
    return remainder >= 0 ? remainder : remainder + 360
}

@MainActor
private final class HexKeyAccessibilityElement: UIAccessibilityElement {
    var coordinate: AxialCoordinate?
    var activation: (() -> Bool)?

    override func accessibilityActivate() -> Bool {
        activation?() ?? false
    }
}

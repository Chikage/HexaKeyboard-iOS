import HexaKeyboardCore
import SwiftUI
import UIKit

struct KeyboardCanvasGeometry: Equatable {
    let size: CGSize
    let offset: CGPoint

    init(layout: HexaKeyboardLayout) {
        let radius = CGFloat(layout.configuration.radius)
        let outlineBounds = layout.windowOutline.bounds
        let keyBounds = layout.keyBounds
        let minX = CGFloat(min(outlineBounds.minX, keyBounds.minX))
        let maxX = CGFloat(max(outlineBounds.maxX, keyBounds.maxX))
        let minY = CGFloat(min(outlineBounds.minY, keyBounds.minY))
        let maxY = CGFloat(max(outlineBounds.maxY, keyBounds.maxY))
        let padding = radius + 18

        offset = CGPoint(x: padding - minX, y: padding - minY)
        size = CGSize(
            width: maxX - minX + padding * 2,
            height: maxY - minY + padding * 2
        )
    }
}

struct HexKeyboardSurface: UIViewRepresentable {
    let layout: HexaKeyboardLayout
    let displayMode: KeyboardDisplayMode
    let selectedCoordinate: AxialCoordinate?
    let onKeyDown: @MainActor (Int, HexKey) -> Void
    let onKeyUp: @MainActor (Int) -> Void

    func makeUIView(context: Context) -> HexKeyboardScrollView {
        let view = HexKeyboardScrollView()
        update(view)
        return view
    }

    func updateUIView(_ uiView: HexKeyboardScrollView, context: Context) {
        update(uiView)
    }

    static func dismantleUIView(_ uiView: HexKeyboardScrollView, coordinator: ()) {
        uiView.canvas.releaseAllTouches()
    }

    private func update(_ view: HexKeyboardScrollView) {
        view.configure(
            layout: layout,
            displayMode: displayMode,
            selectedCoordinate: selectedCoordinate,
            onKeyDown: onKeyDown,
            onKeyUp: onKeyUp
        )
    }
}

@MainActor
final class HexKeyboardScrollView: UIScrollView {
    let canvas = HexKeyboardCanvasView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = AppPalette.uiBackground
        isOpaque = true
        showsHorizontalScrollIndicator = true
        showsVerticalScrollIndicator = false
        indicatorStyle = .white
        alwaysBounceHorizontal = true
        alwaysBounceVertical = false
        isDirectionalLockEnabled = true
        delaysContentTouches = false
        canCancelContentTouches = true
        panGestureRecognizer.minimumNumberOfTouches = 2
        panGestureRecognizer.maximumNumberOfTouches = 2
        addSubview(canvas)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()

        // SwiftUI's outer vertical ScrollView otherwise delays the first key touch.
        var ancestor = superview
        while let view = ancestor {
            if let scrollView = view as? UIScrollView {
                scrollView.delaysContentTouches = false
            }
            ancestor = view.superview
        }
    }

    override func touchesShouldCancel(in view: UIView) -> Bool {
        view === canvas || super.touchesShouldCancel(in: view)
    }

    func configure(
        layout: HexaKeyboardLayout,
        displayMode: KeyboardDisplayMode,
        selectedCoordinate: AxialCoordinate?,
        onKeyDown: @escaping (Int, HexKey) -> Void,
        onKeyUp: @escaping (Int) -> Void
    ) {
        let geometry = KeyboardCanvasGeometry(layout: layout)
        contentSize = geometry.size
        canvas.frame = CGRect(origin: .zero, size: geometry.size)
        canvas.configure(
            layout: layout,
            displayMode: displayMode,
            selectedCoordinate: selectedCoordinate,
            onKeyDown: onKeyDown,
            onKeyUp: onKeyUp
        )

        let maximumOffset = max(0, geometry.size.width - bounds.width)
        if contentOffset.x > maximumOffset {
            contentOffset.x = maximumOffset
        }
    }
}

@MainActor
final class HexKeyboardCanvasView: UIControl {
    private var keyboardLayout = HexaKeyboardLayoutEngine.build()
    private var canvasGeometry = KeyboardCanvasGeometry(
        layout: HexaKeyboardLayoutEngine.build()
    )
    private var displayMode: KeyboardDisplayMode = .pitch
    private var selectedCoordinate: AxialCoordinate?
    private var onKeyDown: ((Int, HexKey) -> Void)?
    private var onKeyUp: ((Int) -> Void)?
    private var touchCoordinates: [ObjectIdentifier: AxialCoordinate] = [:]
    private var keyByCoordinate: [AxialCoordinate: HexKey] = [:]
    private var keyAccessibilityElements: [HexKeyAccessibilityElement] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        isOpaque = true
        backgroundColor = AppPalette.uiBackground
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        layout: HexaKeyboardLayout,
        displayMode: KeyboardDisplayMode,
        selectedCoordinate: AxialCoordinate?,
        onKeyDown: @escaping (Int, HexKey) -> Void,
        onKeyUp: @escaping (Int) -> Void
    ) {
        let geometry = KeyboardCanvasGeometry(layout: layout)
        let layoutChanged = keyboardLayout != layout
        self.keyboardLayout = layout
        canvasGeometry = geometry
        self.displayMode = displayMode
        self.selectedCoordinate = selectedCoordinate
        self.onKeyDown = onKeyDown
        self.onKeyUp = onKeyUp
        keyByCoordinate = Dictionary(
            uniqueKeysWithValues: layout.cells.map { ($0.coordinate, $0) }
        )

        if layoutChanged || keyAccessibilityElements.isEmpty {
            releaseAllTouches()
            rebuildAccessibilityElements()
        }
        setNeedsDisplay()
    }

    func releaseAllTouches() {
        for identifier in touchCoordinates.keys {
            onKeyUp?(touchID(for: identifier))
        }
        touchCoordinates.removeAll()
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.setFillColor(AppPalette.uiBackground.cgColor)
        context.fill(bounds)

        drawWindowOutline(in: context)
        drawOrigin(in: context)
        drawKeys(in: context)
        drawPeriodVectors(in: context)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            transition(touch, to: key(at: touch.location(in: self)))
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            transition(touch, to: key(at: touch.location(in: self)))
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        end(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        end(touches)
    }

    override var accessibilityElements: [Any]? {
        get { keyAccessibilityElements }
        set { }
    }

    private func transition(_ touch: UITouch, to nextKey: HexKey?) {
        let identifier = ObjectIdentifier(touch)
        let previous = touchCoordinates[identifier]
        guard previous != nextKey?.coordinate else { return }
        let touchID = touchID(for: identifier)

        if previous != nil {
            onKeyUp?(touchID)
            touchCoordinates.removeValue(forKey: identifier)
        }
        if let nextKey {
            touchCoordinates[identifier] = nextKey.coordinate
            onKeyDown?(touchID, nextKey)
        }
        setNeedsDisplay()
    }

    private func end(_ touches: Set<UITouch>) {
        for touch in touches {
            let identifier = ObjectIdentifier(touch)
            guard touchCoordinates.removeValue(forKey: identifier) != nil else { continue }
            onKeyUp?(touchID(for: identifier))
        }
        setNeedsDisplay()
    }

    private func touchID(for identifier: ObjectIdentifier) -> Int {
        Int(bitPattern: identifier)
    }

    private func key(at point: CGPoint) -> HexKey? {
        let radius = CGFloat(keyboardLayout.configuration.radius) - 1.5
        let rotation = CGFloat(keyboardLayout.configuration.rotationDegrees)
        return keyboardLayout.cells.reversed().first { key in
            let path = hexagonPath(
                center: canvasPoint(key.center),
                radius: radius,
                rotationDegrees: rotation
            )
            return path.contains(point)
        }
    }

    private func drawWindowOutline(in context: CGContext) {
        let points = keyboardLayout.windowOutline.points.map(canvasPoint)
        guard let first = points.first else { return }
        context.saveGState()
        context.beginPath()
        context.move(to: first)
        for point in points.dropFirst() {
            context.addLine(to: point)
        }
        context.closePath()
        context.setStrokeColor(AppPalette.uiOutline.cgColor)
        context.setLineWidth(1.4)
        context.setLineDash(phase: 0, lengths: [8, 7])
        context.strokePath()
        context.restoreGState()
    }

    private func drawOrigin(in context: CGContext) {
        let origin = canvasPoint(HexPoint(x: 0, y: 0))
        context.saveGState()
        context.setStrokeColor(AppPalette.uiAccent.withAlphaComponent(0.72).cgColor)
        context.setFillColor(AppPalette.uiAccent.cgColor)
        context.setLineWidth(1.2)
        context.move(to: CGPoint(x: origin.x - 9, y: origin.y))
        context.addLine(to: CGPoint(x: origin.x + 9, y: origin.y))
        context.move(to: CGPoint(x: origin.x, y: origin.y - 9))
        context.addLine(to: CGPoint(x: origin.x, y: origin.y + 9))
        context.strokePath()
        context.fillEllipse(in: CGRect(x: origin.x - 2.5, y: origin.y - 2.5, width: 5, height: 5))
        context.restoreGState()
    }

    private func drawKeys(in context: CGContext) {
        let radius = CGFloat(keyboardLayout.configuration.radius) - 1.5
        let rotation = CGFloat(keyboardLayout.configuration.rotationDegrees)
        let activeCoordinates = Set(touchCoordinates.values)
        let selectedPitch = selectedCoordinate.flatMap { keyByCoordinate[$0]?.pitchClass }

        for key in keyboardLayout.cells {
            let center = canvasPoint(key.center)
            let path = hexagonPath(
                center: center,
                radius: radius,
                rotationDegrees: rotation
            )
            let isSelected = key.coordinate == selectedCoordinate
            let isActive = activeCoordinates.contains(key.coordinate)
            let isSamePeriod = displayMode == .period && key.pitchClass == selectedPitch

            context.saveGState()
            context.addPath(path)
            context.setFillColor(fillColor(for: key, samePeriod: isSamePeriod).cgColor)
            context.fillPath()
            context.addPath(path)
            context.setStrokeColor(
                (isActive ? AppPalette.uiAccent : isSelected ? AppPalette.uiSelection : AppPalette.uiLine).cgColor
            )
            context.setLineWidth(isActive || isSelected ? 2.6 : 1.0)
            context.strokePath()
            context.restoreGState()

            drawLabel(for: key, at: center)
        }
    }

    private func drawPeriodVectors(in context: CGContext) {
        guard displayMode == .period,
              let selectedCoordinate,
              let selected = keyByCoordinate[selectedCoordinate]
        else { return }

        let start = canvasPoint(selected.center)
        for (index, vector) in keyboardLayout.periodVectors.enumerated() {
            let targetCoordinate = AxialCoordinate(
                q: selected.q + vector.dq,
                r: selected.r + vector.dr
            )
            guard let target = keyByCoordinate[targetCoordinate] else { continue }
            let end = canvasPoint(target.center)

            context.saveGState()
            context.setStrokeColor(AppPalette.uiSelection.withAlphaComponent(0.92).cgColor)
            context.setLineWidth(2)
            context.move(to: start)
            context.addLine(to: end)
            context.strokePath()
            drawArrowHead(in: context, from: start, to: end)
            context.restoreGState()

            let labelPoint = CGPoint(
                x: start.x * 0.45 + end.x * 0.55,
                y: start.y * 0.45 + end.y * 0.55 - 13
            )
            drawCentered(
                "P\(index + 1)",
                at: labelPoint,
                font: .monospacedSystemFont(ofSize: 10, weight: .bold),
                color: AppPalette.uiSelection
            )
        }
    }

    private func drawArrowHead(in context: CGContext, from start: CGPoint, to end: CGPoint) {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let length: CGFloat = 8
        let spread: CGFloat = .pi / 6
        context.move(to: end)
        context.addLine(to: CGPoint(
            x: end.x - length * cos(angle - spread),
            y: end.y - length * sin(angle - spread)
        ))
        context.move(to: end)
        context.addLine(to: CGPoint(
            x: end.x - length * cos(angle + spread),
            y: end.y - length * sin(angle + spread)
        ))
        context.strokePath()
    }

    private func drawLabel(for key: HexKey, at center: CGPoint) {
        let radius = CGFloat(keyboardLayout.configuration.radius)
        let primary: String
        let secondary: String

        switch displayMode {
        case .coordinates:
            primary = "\(key.q),\(key.r)"
            secondary = key.coordinate == .origin ? "C4 / s=0" : "s=\(key.s)"
        case .pitch:
            primary = String(key.pitchClass)
            secondary = "\(key.q),\(key.r)"
        case .period:
            primary = String(key.pitchClass)
            let selectedPitch = selectedCoordinate.flatMap { keyByCoordinate[$0]?.pitchClass }
            secondary = key.pitchClass == selectedPitch ? "\(key.q),\(key.r)" : ""
        }

        drawCentered(
            primary,
            at: CGPoint(x: center.x, y: center.y - radius * 0.16),
            font: .monospacedSystemFont(ofSize: max(9, radius * 0.43), weight: .bold),
            color: AppPalette.uiPrimaryText
        )
        if !secondary.isEmpty {
            drawCentered(
                secondary,
                at: CGPoint(x: center.x, y: center.y + radius * 0.24),
                font: .monospacedSystemFont(ofSize: max(6.5, radius * 0.24), weight: .regular),
                color: AppPalette.uiSecondaryText
            )
        }
    }

    private func drawCentered(_ text: String, at point: CGPoint, font: UIFont, color: UIColor) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(
            at: CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2),
            withAttributes: attributes
        )
    }

    private func fillColor(for key: HexKey, samePeriod: Bool) -> UIColor {
        switch displayMode {
        case .coordinates:
            let index = ((key.q * 2 + key.r * 3) % 9 + 9) % 9
            return toneColor(index: index, count: 9, saturation: 0.38, brightness: 0.34)
        case .pitch:
            return toneColor(
                index: key.pitchClass,
                count: max(1, keyboardLayout.configuration.period),
                saturation: 0.62,
                brightness: 0.43
            )
        case .period:
            return toneColor(
                index: key.pitchClass,
                count: max(1, keyboardLayout.configuration.period),
                saturation: samePeriod ? 0.70 : 0.32,
                brightness: samePeriod ? 0.48 : 0.27
            )
        }
    }

    private func toneColor(
        index: Int,
        count: Int,
        saturation: CGFloat,
        brightness: CGFloat
    ) -> UIColor {
        let hue = CGFloat(((index % count) + count) % count) / CGFloat(count)
        return UIColor(hue: hue, saturation: saturation, brightness: brightness, alpha: 1)
    }

    private func canvasPoint(_ point: HexPoint) -> CGPoint {
        CGPoint(
            x: CGFloat(point.x) + canvasGeometry.offset.x,
            y: CGFloat(point.y) + canvasGeometry.offset.y
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

    private func rebuildAccessibilityElements() {
        keyAccessibilityElements = keyboardLayout.cells.enumerated().map { index, key in
            let element = HexKeyAccessibilityElement(accessibilityContainer: self)
            let center = canvasPoint(key.center)
            let radius = CGFloat(keyboardLayout.configuration.radius)
            element.accessibilityLabel = "音级 \(key.pitchClass)，坐标 \(key.q)，\(key.r)"
            element.accessibilityValue = String(format: "%.3f 赫兹", key.audioPitch.frequency)
            element.accessibilityTraits = .button
            element.accessibilityFrameInContainerSpace = CGRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            )
            element.activation = { [weak self] in
                guard let self else { return false }
                let touchID = -10_000 - index
                self.onKeyDown?(touchID, key)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { [weak self] in
                    self?.onKeyUp?(touchID)
                }
                return true
            }
            return element
        }
    }
}

@MainActor
private final class HexKeyAccessibilityElement: UIAccessibilityElement {
    var activation: (() -> Bool)?

    override func accessibilityActivate() -> Bool {
        activation?() ?? false
    }
}

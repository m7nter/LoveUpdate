import SwiftUI
import CoreImage

enum DrawingTool { case arrow, oval, text, blur }

struct DrawnShape: Identifiable {
    let id = UUID()
    var tool: DrawingTool
    // All coordinates are normalized to the image, independent of viewport and zoom.
    var start: CGPoint
    var end: CGPoint
    var color: Color
    var text: String = ""
    var points: [CGPoint] = []
    var width: CGFloat = 0.012
    var textSize: CGFloat = 0.045
}

enum AnnotationRenderer {
    static let context = CIContext()
    static func blurred(_ image: UIImage) -> UIImage? {
        guard let input = CIImage(image: image) else { return nil }
        let output = input.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: image.size.width * 0.025]).cropped(to: input.extent)
        guard let cg = context.createCGImage(output, from: input.extent) else { return nil }
        return UIImage(cgImage: cg, scale: image.scale, orientation: .up)
    }
    static func render(image: UIImage, shapes: [DrawnShape]) -> UIImage {
        let blur = shapes.contains { $0.tool == .blur } ? blurred(image) : nil
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: image.size, format: format).image { ctx in
            draw(image: image, blurred: blur, shapes: shapes, in: ctx.cgContext, size: image.size)
        }
    }
    static func draw(image: UIImage, blurred: UIImage?, shapes: [DrawnShape], in ctx: CGContext, size: CGSize) {
        let bounds = CGRect(origin: .zero, size: size)
        image.draw(in: bounds)
        func point(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * size.width, y: p.y * size.height) }
        for shape in shapes {
            ctx.saveGState()
            let start = point(shape.start), end = point(shape.end)
            ctx.setStrokeColor(UIColor(shape.color).cgColor)
            ctx.setLineWidth(max(1, size.width * shape.width))
            ctx.setLineCap(.round); ctx.setLineJoin(.round)
            switch shape.tool {
            case .arrow:
                let angle = atan2(end.y - start.y, end.x - start.x)
                let length = size.width * shape.width * 5
                ctx.move(to: start); ctx.addLine(to: end)
                ctx.move(to: end)
                ctx.addLine(to: CGPoint(x: end.x - length * cos(angle - .pi / 6), y: end.y - length * sin(angle - .pi / 6)))
                ctx.move(to: end)
                ctx.addLine(to: CGPoint(x: end.x - length * cos(angle + .pi / 6), y: end.y - length * sin(angle + .pi / 6)))
                ctx.strokePath()
            case .oval:
                ctx.strokeEllipse(in: CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y)))
            case .text:
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: size.width * shape.textSize, weight: .bold),
                    .foregroundColor: UIColor(shape.color),
                    .strokeColor: UIColor.black, .strokeWidth: -2
                ]
                (shape.text as NSString).draw(in: CGRect(x: start.x, y: start.y, width: max(1, size.width - start.x), height: max(1, size.height - start.y)), withAttributes: attributes)
            case .blur:
                guard let blurred = blurred else { ctx.restoreGState(); continue }
                let path = CGMutablePath()
                let points = shape.points.isEmpty ? [shape.start, shape.end] : shape.points
                path.move(to: point(points[0]))
                for p in points.dropFirst() { path.addLine(to: point(p)) }
                if points.count == 1 { path.addLine(to: CGPoint(x: start.x + 0.01, y: start.y)) }
                ctx.addPath(path.copy(strokingWithWidth: size.width * shape.width, lineCap: .round, lineJoin: .round, miterLimit: 10))
                ctx.clip()
                blurred.draw(in: bounds)
            }
            ctx.restoreGState()
        }
    }
}

private final class AnnotationImageView: UIView {
    var image: UIImage?
    var blurredImage: UIImage?
    var shapes: [DrawnShape] = []
    override func draw(_ rect: CGRect) {
        guard let image = image, let ctx = UIGraphicsGetCurrentContext() else { return }
        AnnotationRenderer.draw(image: image, blurred: blurredImage, shapes: shapes, in: ctx, size: bounds.size)
    }
}

final class ZoomScrollView: UIScrollView {
    var onLayout: (() -> Void)?
    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}

struct ZoomAnnotationCanvas: UIViewRepresentable {
    let image: UIImage
    @Binding var shapes: [DrawnShape]
    var tool: DrawingTool
    var color: Color
    var text: String
    var brushWidth: CGFloat
    var textSize: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> ZoomScrollView {
        let scroll = ZoomScrollView()
        scroll.backgroundColor = .black
        scroll.delegate = context.coordinator
        scroll.onLayout = { [weak coordinator = context.coordinator] in coordinator?.fitIfNeeded() }
        scroll.panGestureRecognizer.minimumNumberOfTouches = 2
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.bouncesZoom = false
        scroll.delaysContentTouches = false
        let canvas = context.coordinator.canvas
        let original = image
        let ratio = min(1, 1600 / max(original.size.width, original.size.height))
        let size = CGSize(width: original.size.width * ratio, height: original.size.height * ratio)
        canvas.backgroundColor = .black
        canvas.frame = CGRect(origin: .zero, size: size)
        canvas.contentScaleFactor = 1
        canvas.isMultipleTouchEnabled = true
        scroll.addSubview(canvas)
        scroll.contentSize = size
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.drawGesture(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = context.coordinator
        canvas.addGestureRecognizer(pan)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.textGesture(_:)))
        tap.delegate = context.coordinator
        canvas.addGestureRecognizer(tap)
        context.coordinator.scroll = scroll
        let coordinator = context.coordinator
        DispatchQueue.global(qos: .userInitiated).async { [weak canvas, weak coordinator] in
            guard canvas != nil else { return }
            let preview = original.preparingThumbnail(ofSize: size) ?? {
                let format = UIGraphicsImageRendererFormat(); format.scale = 1
                return UIGraphicsImageRenderer(size: size, format: format).image { _ in
                    original.draw(in: CGRect(origin: .zero, size: size))
                }
            }()
            DispatchQueue.main.async { [weak canvas, weak coordinator] in
                guard let canvas = canvas else { return }
                canvas.image = preview
                canvas.setNeedsDisplay()
                coordinator?.prepareBlurIfNeeded()
            }
        }
        return scroll
    }
    func updateUIView(_ scroll: ZoomScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.canvas.shapes = shapes
        coordinator.canvas.setNeedsDisplay()
        coordinator.prepareBlurIfNeeded()
        coordinator.fitIfNeeded()
    }
    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        var parent: ZoomAnnotationCanvas
        fileprivate let canvas = AnnotationImageView()
        weak var scroll: UIScrollView?
        private var viewport = CGSize.zero
        private var draft: DrawnShape?
        var blurInProgress = false
        init(_ parent: ZoomAnnotationCanvas) { self.parent = parent }
        func prepareBlurIfNeeded() {
            guard parent.tool == .blur, let preview = canvas.image,
                  canvas.blurredImage == nil, !blurInProgress else { return }
            blurInProgress = true
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let blurred = AnnotationRenderer.blurred(preview)
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.blurInProgress = false
                    guard self.scroll != nil else { return }
                    self.canvas.blurredImage = blurred
                    self.canvas.setNeedsDisplay()
                }
            }
        }
        func fitIfNeeded() {
            guard let scroll = scroll, scroll.bounds.width > 0, scroll.bounds.height > 0,
                  canvas.bounds.width > 0, canvas.bounds.height > 0,
                  viewport != scroll.bounds.size else { return }
            let previousRatio = scroll.minimumZoomScale > 0 ? scroll.zoomScale / scroll.minimumZoomScale : 1
            let fit = min(scroll.bounds.width / canvas.bounds.width, scroll.bounds.height / canvas.bounds.height)
            viewport = scroll.bounds.size
            scroll.minimumZoomScale = fit; scroll.maximumZoomScale = fit * 8
            scroll.setZoomScale(min(fit * 8, max(fit, fit * previousRatio)), animated: false)
            center()
        }
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { canvas }
        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            center()
        }
        private func center() {
            guard let scroll = scroll else { return }
            let x = max(0, (scroll.bounds.width - canvas.frame.width) / 2)
            let y = max(0, (scroll.bounds.height - canvas.frame.height) / 2)
            scroll.contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
        }
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            if gestureRecognizer is UITapGestureRecognizer { return parent.tool == .text && !parent.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            return parent.tool != .text
        }
        private func point(_ recognizer: UIGestureRecognizer) -> CGPoint {
            let p = recognizer.location(in: canvas)
            return CGPoint(x: min(1, max(0, p.x / canvas.bounds.width)), y: min(1, max(0, p.y / canvas.bounds.height)))
        }
        @objc func textGesture(_ recognizer: UITapGestureRecognizer) {
            let p = point(recognizer)
            parent.shapes.append(DrawnShape(tool: .text, start: p, end: p, color: parent.color, text: parent.text, textSize: parent.textSize))
        }
        @objc func drawGesture(_ recognizer: UIPanGestureRecognizer) {
            let p = point(recognizer)
            switch recognizer.state {
            case .began:
                draft = DrawnShape(tool: parent.tool, start: p, end: p, color: parent.color, points: [p], width: parent.tool == .blur ? parent.brushWidth : 0.006)
            case .changed:
                draft?.end = p; draft?.points.append(p)
            case .ended:
                draft?.end = p; draft?.points.append(p)
                if let shape = draft { parent.shapes.append(shape) }
                draft = nil
            default: draft = nil
            }
            canvas.shapes = parent.shapes + (draft.map { [$0] } ?? [])
            canvas.setNeedsDisplay()
        }
    }
}

import SwiftUI
import AppKit

/// Displays the actual Cue icon (Caret.icns) bundled with the app.
/// Falls back to a vector mark only if the resource can't be loaded.
struct CaretLogo: View {
    var size: CGFloat = 14
    var opacity: Double = 1.0

    var body: some View {
        Group {
            if let nsImage = Self.bundledIcon {
                Image(nsImage: nsImage)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .aspectRatio(contentMode: .fit)
            } else {
                CaretMark()
            }
        }
        .frame(width: size, height: size)
        .opacity(opacity)
    }

    /// Cached NSImage loaded from the bundled Caret.icns.
    /// Looks in Bundle.main (the .app's Contents/Resources/) — where release.sh + build.sh
    /// both place Caret.icns. We deliberately do NOT use Bundle.module because that
    /// generates an SPM resource-bundle accessor that fatals at runtime when the
    /// SPM bundle isn't sitting next to the binary (always true in a packaged .app).
    private static let bundledIcon: NSImage? = {
        let bundle = Bundle.main
        let candidates = ["Caret", "CaretIcon", "Cue"]
        let extensions = ["icns", "png", "pdf"]
        for name in candidates {
            for ext in extensions {
                if let url = bundle.url(forResource: name, withExtension: ext),
                   let img = NSImage(contentsOf: url) {
                    // Pin to a high-resolution size so downscaling looks clean.
                    img.size = NSSize(width: 256, height: 256)
                    NSLog("[Cue] icon loaded from \(bundle.bundlePath)/\(name).\(ext)")
                    return img
                }
            }
        }
        NSLog("[Cue] WARNING: no bundled icon found — using vector fallback")
        return nil
    }()
}

/// Vector fallback. Used only if the bundled icon can't be loaded.
/// Also drawn as the menubar template (where multi-color images can't be used).
struct CaretMark: View {
    var color: Color = .primary

    var body: some View {
        Canvas { ctx, size in
            let w = size.width
            let cx = w / 2
            let cy = size.height * 0.58
            let stroke = w * 0.10
            let style = StrokeStyle(lineWidth: stroke, lineCap: .round)
            let shading = GraphicsContext.Shading.color(self.color)

            var outer = Path()
            outer.addArc(center: CGPoint(x: cx, y: cy), radius: w * 0.42,
                         startAngle: .degrees(210), endAngle: .degrees(330), clockwise: false)
            ctx.stroke(outer, with: shading, style: style)

            var inner = Path()
            inner.addArc(center: CGPoint(x: cx, y: cy), radius: w * 0.28,
                         startAngle: .degrees(210), endAngle: .degrees(330), clockwise: false)
            ctx.stroke(inner, with: shading, style: style)

            var ring = Path()
            ring.addArc(center: CGPoint(x: cx, y: cy), radius: w * 0.20,
                        startAngle: .degrees(30), endAngle: .degrees(150), clockwise: true)
            ctx.stroke(ring, with: shading, style: style)

            let dotR = w * 0.05
            ctx.fill(
                Path(ellipseIn: CGRect(x: cx - dotR, y: cy - dotR, width: dotR * 2, height: dotR * 2)),
                with: shading
            )
        }
    }
}

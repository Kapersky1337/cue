#!/bin/bash
# Generate Caret.icns from a simple caret symbol
set -euo pipefail

cd "$(dirname "$0")"
ICONSET="Caret.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"

# Create a simple caret icon using Swift (works without external deps)
swift - << 'SWIFT'
import Cocoa

func createCaretImage(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    // Background - dark with subtle gradient
    let bg = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: size, height: size),
                          xRadius: size * 0.22, yRadius: size * 0.22)
    let gradient = NSGradient(starting: NSColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1),
                              ending: NSColor(red: 0.08, green: 0.08, blue: 0.1, alpha: 1))!
    gradient.draw(in: bg, angle: -90)

    // Caret symbol - golden
    let caretPath = NSBezierPath()
    let centerX = size / 2
    let centerY = size / 2
    let caretSize = size * 0.35
    let strokeWidth = size * 0.08

    // Draw a text caret (blinking cursor shape)
    caretPath.move(to: NSPoint(x: centerX, y: centerY - caretSize))
    caretPath.line(to: NSPoint(x: centerX, y: centerY + caretSize))

    // Small horizontal bars at top and bottom
    let barWidth = size * 0.12
    caretPath.move(to: NSPoint(x: centerX - barWidth, y: centerY + caretSize))
    caretPath.line(to: NSPoint(x: centerX + barWidth, y: centerY + caretSize))
    caretPath.move(to: NSPoint(x: centerX - barWidth, y: centerY - caretSize))
    caretPath.line(to: NSPoint(x: centerX + barWidth, y: centerY - caretSize))

    NSColor(red: 0.98, green: 0.75, blue: 0.15, alpha: 1).setStroke() // Golden
    caretPath.lineWidth = strokeWidth
    caretPath.lineCapStyle = .round
    caretPath.stroke()

    image.unlockFocus()
    return image
}

let sizes: [(String, CGFloat)] = [
    ("icon_16x16", 16),
    ("icon_16x16@2x", 32),
    ("icon_32x32", 32),
    ("icon_32x32@2x", 64),
    ("icon_128x128", 128),
    ("icon_128x128@2x", 256),
    ("icon_256x256", 256),
    ("icon_256x256@2x", 512),
    ("icon_512x512", 512),
    ("icon_512x512@2x", 1024)
]

let iconsetPath = "Caret.iconset"

for (name, size) in sizes {
    let image = createCaretImage(size: size)
    if let tiff = image.tiffRepresentation,
       let bitmap = NSBitmapImageRep(data: tiff),
       let png = bitmap.representation(using: .png, properties: [:]) {
        let url = URL(fileURLWithPath: "\(iconsetPath)/\(name).png")
        try? png.write(to: url)
        print("Created \(name).png")
    }
}
print("Done generating iconset")
SWIFT

# Convert to .icns
iconutil -c icns "$ICONSET" -o "Sources/Caret/Resources/Caret.icns"
rm -rf "$ICONSET"
echo "✓ Created Sources/Caret/Resources/Caret.icns"

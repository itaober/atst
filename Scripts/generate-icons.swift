import AppKit
import Foundation

let rootURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let resourcesURL = rootURL.appendingPathComponent("Resources", isDirectory: true)
let iconsetURL = resourcesURL.appendingPathComponent("AppIcon.iconset", isDirectory: true)
let sourceURL = resourcesURL.appendingPathComponent("AppIconSource.png")

try? FileManager.default.removeItem(at: iconsetURL)
try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: resourcesURL, withIntermediateDirectories: true)

guard let sourceImage = NSImage(contentsOf: sourceURL) else {
    throw NSError(domain: "atst.icon", code: 2, userInfo: [
        NSLocalizedDescriptionKey: "Couldn't load source image at \(sourceURL.path)"
    ])
}

// macOS app icons sit inside a rounded square. The standard mask radius
// is roughly 22.37% of the icon edge per Apple's templates.
let cornerRatio: CGFloat = 0.2237
// Source image fills the squircle edge-to-edge. The source PNG is expected
// to bake in its own padding / visual hierarchy. Previously this was 0.74
// (Apple's "centred artwork inside white squircle" template), but that
// double-padded full-bleed source images and made them feel small in the
// Dock. The full-bleed source is now the source of truth — the squircle
// just clips its corners.
let contentRatio: CGFloat = 1.0

func makeBitmap(width: Int, height: Int, draw: (NSRect) -> Void) -> NSImage {
    let image = NSImage(size: NSSize(width: width, height: height))
    image.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    draw(NSRect(x: 0, y: 0, width: width, height: height))
    image.unlockFocus()
    return image
}

func writePNG(_ image: NSImage, to url: URL) throws {
    guard
        let tiff = image.tiffRepresentation,
        let bitmap = NSBitmapImageRep(data: tiff),
        let data = bitmap.representation(using: .png, properties: [:])
    else {
        throw NSError(domain: "atst.icon", code: 1)
    }
    try data.write(to: url)
}

func drawAppIcon(in rect: NSRect) {
    NSColor.clear.setFill()
    rect.fill()

    let edge = rect.width
    let radius = edge * cornerRatio
    let tile = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    // Source image fills the squircle edge-to-edge — no white background
    // layer behind it. The source PNG provides its own background colour
    // (e.g. cream / paper) which then becomes the icon's actual base.
    // The squircle path is only used as a clip mask so the source's
    // square corners get rounded into the macOS icon shape.
    NSGraphicsContext.saveGraphicsState()
    tile.addClip()
    let contentEdge = edge * contentRatio
    let contentRect = NSRect(
        x: (edge - contentEdge) / 2,
        y: (edge - contentEdge) / 2,
        width: contentEdge,
        height: contentEdge
    )
    sourceImage.draw(in: contentRect, from: .zero, operation: .sourceOver, fraction: 1.0)
    NSGraphicsContext.restoreGraphicsState()

    // Hairline edge stroke for a touch of definition against light Docks
    // and Finder backgrounds. Drawn AFTER the clip so it sits on top.
    NSColor(calibratedWhite: 0, alpha: 0.06).setStroke()
    tile.lineWidth = max(1, edge * 0.004)
    tile.stroke()
}

func drawMenuBarIcon(in rect: NSRect) {
    // Template image: black artwork on transparent background; macOS tints
    // it to match the menu bar appearance (light, dark, hover, etc).
    // A single bold "字" character — universally readable as "text /
    // translation", no chat-bubble = no IM-app feel.
    NSColor.clear.setFill()
    rect.fill()

    let edge = min(rect.width, rect.height)
    let pointSize = edge * 0.78
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: pointSize, weight: .bold),
        .foregroundColor: NSColor.black
    ]
    let glyph = NSAttributedString(string: "字", attributes: attrs)
    let glyphSize = glyph.size()
    let origin = NSPoint(
        x: (rect.width - glyphSize.width) / 2,
        y: (rect.height - glyphSize.height) / 2 - edge * 0.02
    )
    glyph.draw(at: origin)
}

let iconSizes: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for (name, size) in iconSizes {
    let image = makeBitmap(width: size, height: size, draw: drawAppIcon)
    try writePNG(image, to: iconsetURL.appendingPathComponent(name))
}

let menuIcon = makeBitmap(width: 36, height: 36, draw: drawMenuBarIcon)
try writePNG(menuIcon, to: resourcesURL.appendingPathComponent("MenuBarIcon.png"))

let previewIcon = makeBitmap(width: 1024, height: 1024, draw: drawAppIcon)
try writePNG(previewIcon, to: resourcesURL.appendingPathComponent("AppIcon-preview.png"))

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = [
    "-c",
    "icns",
    iconsetURL.path,
    "-o",
    resourcesURL.appendingPathComponent("AppIcon.icns").path
]
try process.run()
process.waitUntilExit()

guard process.terminationStatus == 0 else {
    throw NSError(domain: "atst.iconutil", code: Int(process.terminationStatus))
}

print(resourcesURL.appendingPathComponent("AppIcon.icns").path)
print(resourcesURL.appendingPathComponent("MenuBarIcon.png").path)

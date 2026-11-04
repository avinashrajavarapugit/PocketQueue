import AppKit
import ImageIO
import UniformTypeIdentifiers

let size = NSSize(width: 1024, height: 1024)
guard let canvas = CGContext(
    data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 4096,
    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
) else {
    fatalError("Could not create icon canvas")
}
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: canvas, flipped: false)
NSColor(red: 0.22, green: 0.20, blue: 0.65, alpha: 1).setFill()
NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
NSColor(red: 0.97, green: 0.96, blue: 0.91, alpha: 1).setFill()
let paper = NSBezierPath(roundedRect: NSRect(x: 230, y: 210, width: 564, height: 630), xRadius: 65, yRadius: 65)
paper.fill()
NSColor(red: 0.22, green: 0.20, blue: 0.65, alpha: 1).setFill()
for (y, width) in [(640.0, 330.0), (540.0, 265.0), (440.0, 195.0)] {
    NSBezierPath(roundedRect: NSRect(x: 320, y: y, width: width, height: 36), xRadius: 18, yRadius: 18).fill()
}
NSColor(red: 0.99, green: 0.72, blue: 0.29, alpha: 1).setFill()
let ribbon = NSBezierPath()
ribbon.move(to: NSPoint(x: 580, y: 390))
ribbon.line(to: NSPoint(x: 730, y: 390))
ribbon.line(to: NSPoint(x: 730, y: 130))
ribbon.line(to: NSPoint(x: 655, y: 190))
ribbon.line(to: NSPoint(x: 580, y: 130))
ribbon.close()
ribbon.fill()
NSGraphicsContext.restoreGraphicsState()
let output = URL(fileURLWithPath: "Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
guard let rendered = canvas.makeImage(),
      let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fatalError("Could not render app icon")
}
CGImageDestinationAddImage(destination, rendered, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("Could not write app icon") }

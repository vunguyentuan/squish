// Renders the Squish app icon (1024×1024 PNG). Usage: swift make-icon.swift out.png
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// Squircle body with the brand gradient.
let inset: CGFloat = 100
let body = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let squircle = NSBezierPath(roundedRect: body, xRadius: 186, yRadius: 186)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 40, color: NSColor.black.withAlphaComponent(0.35).cgColor)
NSColor.black.setFill()
squircle.fill()
ctx.restoreGState()

squircle.addClip()
let gradient = NSGradient(colors: [
    NSColor(red: 0.36, green: 0.42, blue: 1.0, alpha: 1),
    NSColor(red: 0.73, green: 0.33, blue: 0.98, alpha: 1),
    NSColor(red: 1.0, green: 0.42, blue: 0.62, alpha: 1),
])!
gradient.draw(in: body, angle: -50)

// Soft top highlight for depth.
let shine = NSGradient(colors: [NSColor.white.withAlphaComponent(0.35), NSColor.white.withAlphaComponent(0)])!
shine.draw(in: CGRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)

// Three stacked "photos" being squeezed together.
func card(_ rect: CGRect, rotation: CGFloat, alpha: CGFloat) {
    ctx.saveGState()
    ctx.translateBy(x: rect.midX, y: rect.midY)
    ctx.rotate(by: rotation * .pi / 180)
    let r = CGRect(x: -rect.width / 2, y: -rect.height / 2, width: rect.width, height: rect.height)
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor.black.withAlphaComponent(0.25).cgColor)
    NSColor.white.withAlphaComponent(alpha).setFill()
    NSBezierPath(roundedRect: r, xRadius: 44, yRadius: 44).fill()
    ctx.restoreGState()
}
let cardSize = CGSize(width: 330, height: 400)
let center = CGPoint(x: size / 2, y: size / 2 + 20)
card(CGRect(origin: CGPoint(x: center.x - cardSize.width / 2 - 120, y: center.y - cardSize.height / 2), size: cardSize), rotation: 12, alpha: 0.55)
card(CGRect(origin: CGPoint(x: center.x - cardSize.width / 2 + 120, y: center.y - cardSize.height / 2), size: cardSize), rotation: -12, alpha: 0.55)
card(CGRect(origin: CGPoint(x: center.x - cardSize.width / 2, y: center.y - cardSize.height / 2 + 10), size: cardSize), rotation: 0, alpha: 1)

// Glyph on the front card.
let config = NSImage.SymbolConfiguration(pointSize: 250, weight: .bold)
    .applying(.init(paletteColors: [NSColor(red: 0.55, green: 0.36, blue: 0.99, alpha: 1)]))
if let glyph = NSImage(systemSymbolName: "arrow.down.right.and.arrow.up.left", accessibilityDescription: nil)?
    .withSymbolConfiguration(config) {
    let g = glyph.size
    glyph.draw(in: CGRect(x: center.x - g.width / 2, y: center.y - g.height / 2 + 10, width: g.width, height: g.height))
}
image.unlockFocus()

let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))

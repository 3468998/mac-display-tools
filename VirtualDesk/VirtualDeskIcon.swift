import AppKit

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let canvas = CGFloat(pixels)
        let background = NSRect(x: canvas * 0.06, y: canvas * 0.06, width: canvas * 0.88, height: canvas * 0.88)
        NSColor(calibratedRed: 0.10, green: 0.39, blue: 0.83, alpha: 1).setFill()
        NSBezierPath(roundedRect: background, xRadius: canvas * 0.19, yRadius: canvas * 0.19).fill()
        let configuration = NSImage.SymbolConfiguration(pointSize: canvas * 0.52, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        if let symbol = NSImage(systemSymbolName: "display.2", accessibilityDescription: nil)?.withSymbolConfiguration(configuration) {
            let width = canvas * 0.68
            let height = width * symbol.size.height / symbol.size.width
            symbol.draw(in: NSRect(x: (canvas - width) / 2, y: (canvas - height) / 2,
                                   width: width, height: height))
        }
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            fatalError("Unable to render icon")
        }
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try png.write(to: directory.appendingPathComponent(name))
    }
}

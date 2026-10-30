import AppKit
import Foundation

// The smoke app starts in its default ink theme. Check the native bottom edge,
// outside the home indicator, to catch WKWebView inset gaps that browser tests miss.
guard CommandLine.arguments.count == 2,
      let data = try? Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])),
      let image = NSBitmapImageRep(data: data) else {
    fatalError("Usage: check-ios-frame.swift simulator-first-screen.png")
}
for x in [10, image.pixelsWide - 11] {
    guard let color = image.colorAt(x: x, y: image.pixelsHigh - 10)?.usingColorSpace(NSColorSpace.deviceRGB) else {
        fatalError("Cannot read simulator screenshot pixel")
    }
    let rgb = [color.redComponent, color.greenComponent, color.blueComponent]
    print("Bottom edge at \(x): \(rgb)")
    guard rgb.allSatisfy({ $0 < 0.2 }) else {
        fputs("FAIL: the ink app does not fill the native bottom edge; check WKWebView safe-area adjustment.\n", stderr)
        exit(1)
    }
}
print("PASS: app fills the native bottom edge")

import Foundation

/// Writes the `.iconset` that `iconutil` turns into the app's `.icns`.
///
/// Compiled against the app's own `AppIcon.swift` rather than reimplementing the artwork, so the
/// Mac icon cannot drift away from the one the phone and the browser get. It is a separate tool
/// rather than a flag on the app because the app is a screen recorder, and a screen recorder that
/// grows command-line modes is a screen recorder with more ways to be invoked than anyone audited.

let arguments = CommandLine.arguments
guard arguments.count > 1 else {
    FileHandle.standardError.write(Data("usage: iconset <output.iconset>\n".utf8))
    exit(2)
}

let directory = URL(fileURLWithPath: arguments[1])
try? FileManager.default.removeItem(at: directory)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

// The names are fixed: iconutil rejects anything it does not recognise.
let wanted: [(name: String, size: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for (name, size) in wanted {
    guard let png = AppIcon.macPNG(size: size) else {
        FileHandle.standardError.write(Data("could not render \(name)\n".utf8))
        exit(1)
    }
    try png.write(to: directory.appendingPathComponent("\(name).png"))
}

print("wrote \(wanted.count) sizes to \(directory.path)")

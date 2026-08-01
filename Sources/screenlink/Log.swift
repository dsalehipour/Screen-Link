import Foundation

enum Log {
    private static let start = Date()
    private static let lock = NSLock()
    private static var handle: FileHandle?

    /// Launching through `open` gives the app its own TCC identity but detaches stdout,
    /// so a log file is the only way to see output in that mode.
    static func setFile(_ path: String) {
        FileManager.default.createFile(atPath: path, contents: nil)
        handle = FileHandle(forWritingAtPath: path)
    }

    private static func emit(_ level: String, _ message: String) {
        let t = String(format: "%7.3f", Date().timeIntervalSince(start))
        let line = "[\(t)] \(level) \(message)"
        lock.lock()
        defer { lock.unlock() }
        print(line)
        fflush(stdout)
        if let handle, let data = (line + "\n").data(using: .utf8) {
            try? handle.write(contentsOf: data)
        }
    }

    static func info(_ m: String) { emit("INFO", m) }
    static func warn(_ m: String) { emit("WARN", m) }
    static func error(_ m: String) { emit("ERR ", m) }
}

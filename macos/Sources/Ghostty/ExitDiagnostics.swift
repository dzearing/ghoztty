import Foundation

enum ExitDiagnostics {
    private static let logPath: String = {
        NSTemporaryDirectory().appending("ghoztty-exit.log")
    }()

    static func log(_ message: String) {
        let line = message + "\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = FileHandle(forWritingAtPath: logPath) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            FileManager.default.createFile(atPath: logPath, contents: data)
        }
    }
}

import Foundation

enum PipDebug {
    static let logURL = URL(fileURLWithPath: "/tmp/pip-debug.log")
    static let queue = DispatchQueue(label: "pip.debug")

    static func log(_ msg: String) {
        queue.async {
            let line = "\(Date().timeIntervalSince1970) \(msg)\n"
            if let data = line.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: logURL.path) {
                    if let fh = try? FileHandle(forWritingTo: logURL) {
                        fh.seekToEndOfFile()
                        fh.write(data)
                        try? fh.close()
                    }
                } else {
                    try? data.write(to: logURL)
                }
            }
        }
    }
}

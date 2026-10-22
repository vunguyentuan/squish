import AppKit

/// The app binary is also the `squish` CLI when run under that name (see main.swift);
/// installing it is a symlink onto the PATH.
enum CommandLineTool {
    static let linkURL = URL(fileURLWithPath: "/usr/local/bin/squish")

    static var bundledURL: URL {
        Bundle.main.executableURL ?? Bundle.main.bundleURL.appending(path: "Contents/MacOS/Squish")
    }

    /// True when /usr/local/bin/squish points at this copy of the app.
    static var isInstalled: Bool {
        let target = try? FileManager.default.destinationOfSymbolicLink(atPath: linkURL.path)
        return target == bundledURL.path
    }

    /// Links the tool, asking for an administrator password only if /usr/local/bin isn't writable.
    static func install() throws {
        let fm = FileManager.default
        let directory = linkURL.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try? fm.removeItem(at: linkURL)
            try fm.createSymbolicLink(at: linkURL, withDestinationURL: bundledURL)
            return
        } catch {
            // Fall through to the privileged path.
        }
        let command = "mkdir -p \(quoted(directory.path)) && ln -sf \(quoted(bundledURL.path)) \(quoted(linkURL.path))"
        let script = "do shell script \"\(command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let error, (error[NSAppleScript.errorNumber] as? Int) != -128 {
            throw CocoaError(.fileWriteNoPermission, userInfo: [
                NSLocalizedDescriptionKey: error[NSAppleScript.errorMessage] as? String ?? String(localized: "Couldn't install the command-line tool."),
            ])
        }
    }

    private static func quoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

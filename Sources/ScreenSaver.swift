import AppKit

enum ScreenSaverSupport {
    static var installedURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Screen Savers/MotionWall.saver", isDirectory: true)
    }

    static var isInstalled: Bool {
        let infoURL = installedURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        else { return false }
        return info["CFBundleIdentifier"] as? String == "app.motionwall.screensaver"
    }

    static func install(movieURL: URL, fill: Bool, respectLowPower: Bool) async throws {
        guard let template = Bundle.main.url(forResource: "MotionWall", withExtension: "saver"),
              let helper = Bundle.main.url(forResource: "install_saver", withExtension: "py") else {
            throw WallError.message("Не найден модуль заставки. Установи обновлённый MotionWall через Install.command.")
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let process = Process()
                    let output = Pipe()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
                    process.arguments = [helper.path, template.path, movieURL.path,
                                         "--fill", fill ? "true" : "false",
                                         "--respect-low-power", respectLowPower ? "true" : "false"]
                    process.standardInput = FileHandle.nullDevice
                    process.standardOutput = output
                    process.standardError = output
                    try process.run()
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    guard process.terminationStatus == 0 else {
                        let detail = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        throw WallError.message(detail.isEmpty ? "Не удалось установить видеозаставку." : detail)
                    }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}

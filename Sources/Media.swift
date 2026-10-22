import Foundation
import AVFoundation

struct Movie: Codable, Equatable {
    let filename: String
    let title: String
    let seconds: Double
}

struct Preferences: Codable {
    var movie: Movie? = nil
    var enabled = false
    var paused = false
    var fill = true
    var allScreens = true
    var respectLowPower = true
}

enum WallError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

enum Storage {
    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MotionWall", isDirectory: true)
    }
    static var media: URL { root.appendingPathComponent("Media", isDirectory: true) }
    static var preferences: URL { root.appendingPathComponent("settings.json") }
    static func prepare() throws {
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
    }
    static func url(for movie: Movie) -> URL { media.appendingPathComponent(movie.filename) }
    static func read() throws -> Preferences {
        guard FileManager.default.fileExists(atPath: preferences.path) else { return Preferences() }
        return try JSONDecoder().decode(Preferences.self, from: Data(contentsOf: preferences))
    }
    static func write(_ value: Preferences) throws {
        try prepare()
        try JSONEncoder().encode(value).write(to: preferences, options: .atomic)
    }
}

struct ConversionRecipe: Decodable {
    let beforeInput: [String]
    let afterInput: [String]
}

// Runs off the main thread. Only cancellation and the Process reference are shared.
final class ConversionJob: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var process: Process?

    func cancel() {
        lock.lock()
        cancelled = true
        if let process = process, process.isRunning { process.terminate() }
        lock.unlock()
    }

    private func checkCancellation() throws {
        lock.lock(); let flag = cancelled; lock.unlock()
        if flag { throw CancellationError() }
    }

    func convert(source: URL, destination: URL, progress: @escaping (String) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try self.run(source: source, destination: destination, progress: progress)
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func run(source: URL, destination: URL, progress: @escaping (String) -> Void) throws {
        try checkCancellation()
        guard let executable = Bundle.main.url(forResource: "ffmpeg", withExtension: nil),
              FileManager.default.isExecutableFile(atPath: executable.path),
              let recipeURL = Bundle.main.url(forResource: "conversion", withExtension: "json") else {
            throw WallError.message("Не найден видеоконвертер. Повторно запусти Install.command из архива приложения.")
        }
        let recipe = try JSONDecoder().decode(ConversionRecipe.self, from: Data(contentsOf: recipeURL))
        let logURL = destination.deletingPathExtension().appendingPathExtension("log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        defer { try? log.close(); try? FileManager.default.removeItem(at: logURL) }
        let pipe = Pipe()
        let child = Process()
        child.executableURL = executable
        child.arguments = recipe.beforeInput + ["-i", source.path] + recipe.afterInput + [destination.path]
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = pipe
        child.standardError = log

        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        process = child
        do { try child.run(); lock.unlock() }
        catch { process = nil; lock.unlock(); throw error }
        // The parent must close its writer; otherwise a cancelled process could leave a read waiting for EOF.
        try? pipe.fileHandleForWriting.close()
        defer {
            try? pipe.fileHandleForReading.close()
            lock.lock(); process = nil; lock.unlock()
        }
        var buffer = ""
        while true {
            let bytes = pipe.fileHandleForReading.availableData
            if bytes.isEmpty { break }
            buffer += String(decoding: bytes, as: UTF8.self)
            while let newline = buffer.firstIndex(of: "\n") {
                let line = String(buffer[..<newline])
                buffer.removeSubrange(...newline)
                if line.hasPrefix("out_time=") {
                    progress(String(line.dropFirst(9)).components(separatedBy: ".")[0])
                }
            }
        }
        child.waitUntilExit()
        try checkCancellation()
        guard child.terminationStatus == 0 else {
            var detail = ""
            if let reader = try? FileHandle(forReadingFrom: logURL) {
                let end = (try? reader.seekToEnd()) ?? 0
                try? reader.seek(toOffset: end > 2400 ? end - 2400 : 0)
                if let data = try? reader.readToEnd() { detail = String(decoding: data, as: UTF8.self) }
                try? reader.close()
            }
            throw WallError.message("Не удалось прочитать видео. Файл может быть повреждён, защищён или иметь неподдерживаемый кодек.\n\n" + detail)
        }
    }
}

func validateMovie(at url: URL) async throws -> Double {
    let asset = AVURLAsset(url: url)
    let playable = try await asset.load(.isPlayable)
    let tracks = try await asset.loadTracks(withMediaType: .video)
    let duration = try await asset.load(.duration)
    guard playable, !tracks.isEmpty, duration.seconds.isFinite, duration.seconds > 0 else {
        throw WallError.message("В этом файле нет воспроизводимого видео.")
    }
    return duration.seconds
}

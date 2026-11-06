import CryptoKit
import Foundation

public enum DownloadError: Error {
    case corrupted
}

/// Fetches a model file and only keeps it if its hash matches.
public final class ModelDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let progress: @Sendable (Double) -> Void
    private let part: URL
    private var continuation: CheckedContinuation<Void, Error>?
    private var task: URLSessionDownloadTask?

    private init(part: URL, progress: @escaping @Sendable (Double) -> Void) {
        self.part = part
        self.progress = progress
    }

    public static func run(_ model: ModelFile, progress: @escaping @Sendable (Double) -> Void) async throws {
        let manager = FileManager.default
        try manager.createDirectory(at: AppPaths.models, withIntermediateDirectories: true)
        let part = model.path.appendingPathExtension("part")
        try? manager.removeItem(at: part)

        let download = ModelDownload(part: part, progress: progress)
        do {
            try await download.fetch(model.source)
            guard try hash(of: part) == model.sha256.lowercased() else {
                throw DownloadError.corrupted
            }

            try? manager.removeItem(at: model.path)
            try manager.moveItem(at: part, to: model.path)
        } catch {
            // A cancelled or broken download shouldn't leave gigabytes behind.
            try? manager.removeItem(at: part)
            throw error
        }
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 {
            progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        }
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The system deletes this file as soon as this method returns.
        do {
            if let response = downloadTask.response as? HTTPURLResponse, response.statusCode >= 400 {
                throw URLError(.badServerResponse)
            }

            try FileManager.default.moveItem(at: location, to: part)
            finish(nil)
        } catch {
            finish(error)
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(error)
        }
    }

    private static func hash(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }

        var hash = SHA256()
        while let piece = try handle.read(upToCount: 1 << 20), !piece.isEmpty {
            hash.update(data: piece)
        }

        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func fetch(_ source: URL) async throws {
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                self.continuation = continuation
                let task = session.downloadTask(with: source)
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            lock.lock()
            let task = self.task
            lock.unlock()
            task?.cancel()
        }
    }

    private func finish(_ error: Error?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()

        if let error {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume()
        }
    }
}

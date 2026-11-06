import Darwin
import Foundation
import TalkTypeCore

/// A rewrite that didn't work out. The message is written for the person dictating.
struct RewriteError: Error {
    let message: String
}

/// Translates and condenses on this Mac. The model runs in llama.cpp's server as its own process,
/// so the menu bar app stays small, and nothing is loaded until these features are used.
actor Rewriter {
    private static let contextTokens = 8192

    // The server drops the model on its own after this long, which frees the memory.
    private static let sleepAfterSeconds = 300
    private static let quitAfter: UInt64 = 30 * 60 * 1_000_000_000
    private static let startLimit: TimeInterval = 180
    private static let answerLimit: TimeInterval = 300

    // About as long as a dictation, so the first real one doesn't pay for setting things up.
    private static let primingText = String(repeating: "Ich wollte nur kurz sagen, dass wir das Meeting verschieben sollten. ", count: 16)

    private var server: Process?
    private var running: ModelFile?
    private var endpoint: URL?
    private var key = ""
    private var quit: Task<Void, Never>?

    private var serverPath: String? {
        Bundle.main.resourceURL?.appendingPathComponent("rewriter/llama-server").path
    }

    /// Gets the model loading in the background, while someone is still talking.
    func warmUp(_ model: ModelFile) async {
        guard model.isInstalled else {
            return
        }

        do {
            try await start(model)
        } catch {
            Log.write("Language model warm-up failed: \(error)")
        }
    }

    func rewrite(_ text: String, rewrite: Rewrite, language: DictationLanguage, terms: [String], model: ModelFile) async throws -> String {
        let started = Date()
        try await start(model)
        let ready = Date()
        defer { scheduleQuit() }

        do {
            // Room for a translation somewhat longer than the text, and no more: a small model
            // that starts repeating itself would otherwise go on until the context runs out.
            let mostTokens = min(Rewriter.contextTokens / 2, 200 + text.count)
            let prompt = Prompts.forRewrite(rewrite, language: language, terms: terms)
            let (answer, ranOut) = try await ask(prompt, text, mostTokens: mostTokens, limit: Rewriter.answerLimit)
            Log.write("Rewrote \(text.count) characters: \(Int(ready.timeIntervalSince(started) * 1000)) ms to start, \(Int(Date().timeIntervalSince(ready) * 1000)) ms to write.")

            guard let accepted = Prompts.accept(answer, ranOut: ranOut, original: text) else {
                throw RewriteError(message: "Das Umschreiben ist schiefgegangen, hier ist der normale Text.")
            }

            return accepted
        } catch let error as RewriteError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Log.write("Language model request failed: \(error.localizedDescription)")
            throw RewriteError(message: "Das Sprachmodell hat nicht geantwortet, hier ist der normale Text.")
        }
    }

    func stop() {
        quit?.cancel()
        server?.terminate()
        server = nil
        running = nil
        try? FileManager.default.removeItem(at: AppPaths.helperPid)
    }

    /// A crash can leave the helper behind, holding gigabytes for nobody.
    func cleanUpAfterCrash() {
        guard let text = try? String(contentsOf: AppPaths.helperPid, encoding: .utf8), let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return
        }

        // Process numbers get reused, so only stop it if it really is our helper.
        let check = Process()
        let output = Pipe()
        check.executableURL = URL(fileURLWithPath: "/bin/ps")
        check.arguments = ["-p", String(pid), "-o", "comm="]
        check.standardOutput = output
        check.standardError = FileHandle.nullDevice
        if (try? check.run()) != nil {
            check.waitUntilExit()
            let name = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if name.contains("llama-server") {
                kill(pid, SIGTERM)
                Log.write("Stopped a helper left behind by an earlier run.")
            }
        }

        try? FileManager.default.removeItem(at: AppPaths.helperPid)
    }

    private func start(_ model: ModelFile) async throws {
        if let server, server.isRunning, running == model {
            return
        }

        stop()
        guard let path = serverPath, FileManager.default.isExecutableFile(atPath: path) else {
            throw RewriteError(message: "Dem Sprachmodell fehlt ein Teil. Bitte installiere TalkType neu.")
        }

        let started = Date()
        let port = try freePort()
        key = UUID().uuidString
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.currentDirectoryURL = URL(fileURLWithPath: path).deletingLastPathComponent()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.arguments = [
            "--model", model.path.path,
            "--host", "127.0.0.1",
            "--port", String(port),
            "--api-key", key,
            "--ctx-size", String(Rewriter.contextTokens),
            "--gpu-layers", "99",
            "--parallel", "1",
            "--reasoning", "off",
            "--cache-ram", "0",
            "--sleep-idle-seconds", String(Rewriter.sleepAfterSeconds),
            "--no-webui",
            "--no-slots",
            "--log-disable",
        ]

        do {
            try process.run()
        } catch {
            Log.write("The language model could not start: \(error.localizedDescription)")
            throw RewriteError(message: "Das Sprachmodell ließ sich nicht starten, hier ist der normale Text.")
        }

        server = process
        running = model
        endpoint = URL(string: "http://127.0.0.1:\(port)/")
        try? String(process.processIdentifier).write(to: AppPaths.helperPid, atomically: true, encoding: .utf8)

        do {
            try await waitUntilReady()
            _ = try await ask("Repeat the first word.", Rewriter.primingText, mostTokens: 1, limit: Rewriter.startLimit)
            Log.write("Language model ready in \(Int(Date().timeIntervalSince(started) * 1000)) ms.")
            scheduleQuit()
        } catch {
            stop()
            throw error
        }
    }

    private func waitUntilReady() async throws {
        let deadline = Date().addingTimeInterval(Rewriter.startLimit)
        guard let endpoint else {
            throw RewriteError(message: "Das Sprachmodell ließ sich nicht starten, hier ist der normale Text.")
        }

        while Date() < deadline {
            try Task.checkCancellation()
            if server?.isRunning != true {
                Log.write("The language model server stopped during start-up.")
                throw RewriteError(message: "Das Sprachmodell ließ sich nicht starten, hier ist der normale Text.")
            }

            var request = URLRequest(url: endpoint.appendingPathComponent("health"))
            request.timeoutInterval = 2
            if let (_, response) = try? await URLSession.shared.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200 {
                return
            }

            try await Task.sleep(nanoseconds: 100_000_000)
        }

        throw RewriteError(message: "Das Sprachmodell braucht zu lange, hier ist der normale Text.")
    }

    private func ask(_ instructions: String, _ text: String, mostTokens: Int, limit: TimeInterval) async throws -> (String, Bool) {
        guard let endpoint else {
            throw RewriteError(message: "Das Sprachmodell läuft nicht, hier ist der normale Text.")
        }

        var request = URLRequest(url: endpoint.appendingPathComponent("v1/chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = limit
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "messages": [["role": "system", "content": instructions], ["role": "user", "content": text]],
            "temperature": 0,
            "max_tokens": mostTokens,
            "chat_template_kwargs": ["enable_thinking": false],
        ] as [String: Any])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choice = (reply["choices"] as? [[String: Any]])?.first,
              let message = choice["message"] as? [String: Any] else {
            throw URLError(.badServerResponse)
        }

        return (message["content"] as? String ?? "", choice["finish_reason"] as? String == "length")
    }

    private func scheduleQuit() {
        quit?.cancel()
        quit = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Rewriter.quitAfter)
            if !Task.isCancelled {
                await self?.stop()
            }
        }
    }

    private func freePort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw URLError(.cannotConnectToHost)
        }

        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0

        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, length) }
        }

        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }

        guard bound == 0, named == 0 else {
            throw URLError(.cannotConnectToHost)
        }

        return UInt16(bigEndian: address.sin_port)
    }
}

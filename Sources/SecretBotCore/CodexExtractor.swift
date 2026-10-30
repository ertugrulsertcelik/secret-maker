import Foundation

/// Maili bu Mac'te kurulu OpenAI Codex CLI ile okur (`codex exec`). Kullanıcının `codex login`
/// ile bağladığı ChatGPT hesabını (veya Codex'e girilmiş API anahtarını) kullanır.
/// Salt okunur sandbox'ta, oturum kaydetmeden çalışır; mail maskelenmiş olarak stdin'den gider.
public enum CodexExtractor {
    /// Kurulu `codex` komutunu bulur. SECRETBOT_CODEX_PATH ile elle de verilebilir.
    public static func findCLI() -> String? {
        let fm = FileManager.default
        if let p = ProcessInfo.processInfo.environment["SECRETBOT_CODEX_PATH"], fm.isExecutableFile(atPath: p) { return p }
        let home = fm.homeDirectoryForCurrentUser.path
        let candidates = ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", "\(home)/.local/bin/codex",
                          "\(home)/.npm-global/bin/codex", "\(home)/.volta/bin/codex", "\(home)/.bun/bin/codex"]
        if let hit = candidates.first(where: { fm.isExecutableFile(atPath: $0) }) { return hit }
        // Son çare: kullanıcının login kabuğundaki PATH (nvm vb. kurulumlar için).
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        p.arguments = ["-l", "-c", "command -v codex"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let path = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return fm.isExecutableFile(atPath: path) ? path : nil
    }

    static var workDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SecretBot/codex-run", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static func extract(masked: MaskResult, model: String, prompt: AIPromptConfig) async throws -> AIResult {
        guard let cli = findCLI() else {
            throw AIError("Codex CLI bulunamadı. Kurulum: `brew install codex` veya `npm install -g @openai/codex`, sonra `codex login`.")
        }
        let dir = workDir
        let id = UUID().uuidString
        let schemaURL = dir.appendingPathComponent("schema-\(id).json")
        let outURL = dir.appendingPathComponent("out-\(id).json")
        defer {
            try? FileManager.default.removeItem(at: schemaURL)
            try? FileManager.default.removeItem(at: outURL)
        }
        try Data(AIExtractor.schemaJSON(prompt).utf8).write(to: schemaURL)

        // Talimat argüman olarak, maskelenmiş mail stdin'den (Codex bunu ek bağlam olarak okur).
        let instruction = AIExtractor.systemPrompt(prompt) + """


        Görev: stdin'den gelen maili oku ve sonucu yalnızca verilen JSON şemasına uyan tek bir JSON nesnesi olarak döndür.
        Hiçbir komut çalıştırma, dosya okuma veya yazma; sadece metni analiz et.
        """
        var args = ["exec", "--skip-git-repo-check", "--sandbox", "read-only", "--ephemeral",
                    "--output-schema", schemaURL.path, "--output-last-message", outURL.path]
        if !model.isEmpty { args += ["--model", model] }
        args.append(instruction)
        let input = "Mail:\n\n" + masked.text

        let (out, err, code) = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(Data, String, Int32), Error>) in
            DispatchQueue.global().async {
                do { cont.resume(returning: try run(cli, args: args, input: input, cwd: dir, timeout: 300)) }
                catch { cont.resume(throwing: error) }
            }
        }

        let final = (try? Data(contentsOf: outURL)).flatMap { $0.isEmpty ? nil : $0 } ?? out
        if code != 0 || final.isEmpty {
            let msg = err.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = msg.lowercased()
            if lower.contains("login") || lower.contains("401") || lower.contains("unauthorized") || lower.contains("not logged in") {
                throw AIError("Codex'te oturum açık değil. Terminalde `codex login` ile ChatGPT hesabınızla giriş yapın.")
            }
            if lower.contains("usage limit") || lower.contains("rate limit") {
                throw AIError("ChatGPT/Codex kullanım limiti dolmuş: \(msg.suffix(200))")
            }
            throw AIError("Codex hata verdi (kod \(code)): \(msg.suffix(300))")
        }
        return try AIExtractor.decode(final, masked: masked)
    }

    private static func run(_ path: String, args: [String], input: String, cwd: URL, timeout: TimeInterval) throws -> (Data, String, Int32) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.currentDirectoryURL = cwd
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        p.environment = env
        let inP = Pipe(), outP = Pipe(), errP = Pipe()
        p.standardInput = inP; p.standardOutput = outP; p.standardError = errP
        try p.run()

        var outData = Data(), errData = Data()
        let g = DispatchGroup()
        g.enter(); DispatchQueue.global().async { outData = outP.fileHandleForReading.readDataToEndOfFile(); g.leave() }
        g.enter(); DispatchQueue.global().async { errData = errP.fileHandleForReading.readDataToEndOfFile(); g.leave() }
        inP.fileHandleForWriting.write(Data(input.utf8))
        try? inP.fileHandleForWriting.close()

        if g.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            throw AIError("Codex \(Int(timeout)) saniyede yanıt vermedi.")
        }
        p.waitUntilExit()
        return (outData, String(decoding: errData, as: UTF8.self), p.terminationStatus)
    }
}

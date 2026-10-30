import Foundation

/// Maili bu Mac'te kurulu Claude Code CLI ile okur (`claude -p`). Kullanıcının Claude aboneliğini
/// (Pro/Max) kullanır; API anahtarı gerekmez. Araçlar kapalıdır, oturum diske yazılmaz.
public enum ClaudeCodeExtractor {
    public static func findCLI() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["/opt/homebrew/bin/claude", "/usr/local/bin/claude",
                          "\(home)/.local/bin/claude", "\(home)/.claude/local/claude"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Boş bir çalışma klasörü: proje dosyaları/CLAUDE.md okunmasın.
    static var workDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SecretBot/claude-run", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Son okumada gerçekten kullanılan model (bilgi amaçlı).
    nonisolated(unsafe) public static var lastModel = ""

    public static func extract(masked: MaskResult, model: String, prompt: AIPromptConfig) async throws -> AIResult {
        do {
            return try await extract(masked: masked, model: model, prompt: prompt, once: true)
        } catch let e as AIError where model.hasPrefix("claude-opus") &&
                    (e.message.contains("claude_code_version_too_old") || e.message.contains("does not support this model")) {
            // Eski Claude Code yeni modeli tanımıyor: sürümün desteklediği en yeni Opus'a düş.
            return try await extract(masked: masked, model: "opus", prompt: prompt, once: true)
        }
    }

    static func extract(masked: MaskResult, model: String, prompt: AIPromptConfig, once: Bool) async throws -> AIResult {
        guard let cli = findCLI() else { throw AIError("Claude Code (claude komutu) bulunamadı.") }
        let args = ["-p", "--output-format", "json", "--tools", "", "--no-session-persistence",
                    "--model", model, "--fallback-model", "sonnet",
                    "--json-schema", AIExtractor.schemaJSON(prompt),
                    "--system-prompt", AIExtractor.systemPrompt(prompt)]
        let input = "Mail:\n\n" + masked.text

        let (out, err, code) = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(Data, String, Int32), Error>) in
            DispatchQueue.global().async {
                do { cont.resume(returning: try run(cli, args: args, input: input, timeout: 180)) }
                catch { cont.resume(throwing: error) }
            }
        }

        guard let obj = try? JSONSerialization.jsonObject(with: out) as? [String: Any] else {
            let msg = err.trimmingCharacters(in: .whitespacesAndNewlines)
            throw AIError("Claude Code yanıtı okunamadı (kod \(code)). \(msg.prefix(300))")
        }
        if obj["is_error"] as? Bool == true || obj["structured_output"] == nil || obj["structured_output"] is NSNull {
            let result = obj["result"] as? String ?? ""
            if result.contains("authenticate") || result.contains("401") || result.contains("/login") {
                throw AIError("Claude Code oturumu açık değil veya süresi dolmuş. Terminalde `claude` yazıp /login ile giriş yapın.")
            }
            if result.lowercased().contains("limit") {
                throw AIError("Claude aboneliğinin kullanım limiti dolmuş: \(result.prefix(200))")
            }
            throw AIError("Claude Code hata verdi: \(result.prefix(300))")
        }
        lastModel = (obj["modelUsage"] as? [String: Any])?.keys.sorted().joined(separator: ", ") ?? model
        let structured = try JSONSerialization.data(withJSONObject: obj["structured_output"]!)
        return try AIExtractor.decode(structured, masked: masked)
    }

    private static func run(_ path: String, args: [String], input: String, timeout: TimeInterval) throws -> (Data, String, Int32) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.currentDirectoryURL = workDir
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
            throw AIError("Claude Code \(Int(timeout)) saniyede yanıt vermedi.")
        }
        p.waitUntilExit()
        return (outData, String(decoding: errData, as: UTF8.self), p.terminationStatus)
    }
}

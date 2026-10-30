import Foundation

/// Maili ayarlardaki yapay zekâ ile okur; olmazsa basit okuyucuya düşer.
public enum MailReader {
    public struct Outcome {
        public var result: AIResult
        public var readBy: String
        public var masked: MaskResult
        public var usedAI: Bool
    }

    /// Ayarlara göre kullanılacak somut sağlayıcı (yoksa nil = basit okuyucu).
    public static func resolve(_ cfg: AppConfig) -> AIProvider? {
        let hasCLI = ClaudeCodeExtractor.findCLI() != nil
        let hasCodex = { CodexExtractor.findCLI() != nil }
        let hasAnthropic = APIKeyStore.read(APIKeyStore.anthropic) != nil
        let hasOpenAI = !cfg.openaiBaseURL.isEmpty && !cfg.openaiModel.isEmpty
        switch cfg.aiProvider {
        case .off: return nil
        case .claudeCode: return hasCLI ? .claudeCode : nil
        case .codex: return hasCodex() ? .codex : nil
        case .anthropic: return hasAnthropic ? .anthropic : nil
        case .openai: return hasOpenAI ? .openai : nil
        case .auto:
            if hasCLI { return .claudeCode }
            if hasCodex() { return .codex }
            if hasAnthropic { return .anthropic }
            if hasOpenAI { return .openai }
            return nil
        }
    }

    /// Arayüzde gösterilecek kısa durum metni.
    public static func statusText(_ cfg: AppConfig) -> String {
        switch resolve(cfg) {
        case .claudeCode: return "Claude Code (abonelik)"
        case .codex: return "Codex CLI (ChatGPT)\(cfg.codexModel.isEmpty ? "" : " · " + cfg.codexModel)"
        case .anthropic: return "Anthropic API · \(cfg.anthropicModel)"
        case .openai: return "\(cfg.openaiModel) · \(URL(string: cfg.openaiBaseURL)?.host ?? cfg.openaiBaseURL)"
        default: return cfg.aiProvider == .off ? "Yapay zekâ kapalı, basit okuyucu" : "Yapay zekâ bağlı değil, basit okuyucu"
        }
    }

    public static func read(_ text: String, cfg: AppConfig) async -> Outcome {
        let masked = Masker.mask(text)
        let prompt = cfg.aiPrompt

        func local(_ note: String) -> Outcome {
            let p = MailParser.parse(text, namespacePrefixes: cfg.namespacePrefixes)
            return Outcome(result: AIResult(context: "unknown", namespaces: p.namespaces, entries: p.entries,
                                            notes: [note] + p.warnings),
                           readBy: "Basit okuyucu", masked: masked, usedAI: false)
        }

        guard let provider = resolve(cfg) else {
            return local(cfg.aiProvider == .off
                         ? "Yapay zekâ kapalı, basit okuyucu kullanıldı."
                         : "Seçilen yapay zekâ kullanılamıyor (Ayarlar → Yapay zekâ), basit okuyucu kullanıldı.")
        }
        do {
            switch provider {
            case .claudeCode:
                let r = try await ClaudeCodeExtractor.extract(masked: masked, model: cfg.claudeCodeModel, prompt: prompt)
                return Outcome(result: r, readBy: "Claude Code · \(ClaudeCodeExtractor.lastModel)", masked: masked, usedAI: true)
            case .codex:
                let r = try await CodexExtractor.extract(masked: masked, model: cfg.codexModel, prompt: prompt)
                return Outcome(result: r, readBy: "Codex CLI\(cfg.codexModel.isEmpty ? "" : " · " + cfg.codexModel)", masked: masked, usedAI: true)
            case .anthropic:
                let key = APIKeyStore.read(APIKeyStore.anthropic) ?? ""
                let r = try await AIExtractor.extract(masked: masked, apiKey: key, model: cfg.anthropicModel, prompt: prompt)
                return Outcome(result: r, readBy: "Anthropic API · \(cfg.anthropicModel)", masked: masked, usedAI: true)
            case .openai:
                let r = try await OpenAIExtractor.extract(masked: masked, baseURL: cfg.openaiBaseURL, model: cfg.openaiModel,
                                                          apiKey: APIKeyStore.read(APIKeyStore.openai), prompt: prompt)
                return Outcome(result: r, readBy: cfg.openaiModel, masked: masked, usedAI: true)
            default:
                return local("Basit okuyucu kullanıldı.")
            }
        } catch {
            return local("Yapay zekâ ile okunamadı: \(error.localizedDescription) Basit okuyucu kullanıldı.")
        }
    }
}

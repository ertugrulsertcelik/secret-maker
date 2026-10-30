import Foundation

public enum AIProvider: String, CaseIterable, Identifiable {
    case auto
    case claudeCode = "claude-code"
    case anthropic
    case openai
    case off
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .auto: return "Otomatik"
        case .claudeCode: return "Claude Code (abonelik)"
        case .anthropic: return "Anthropic API"
        case .openai: return "OpenAI uyumlu uç nokta"
        case .off: return "Kapalı (basit okuyucu)"
        }
    }
}

/// Kullanıcı ayarları. Uygulama ve test aracı aynı UserDefaults alanını okur.
/// Kişiye/şirkete özgü hiçbir değer burada sabit değildir; hepsi Ayarlar'dan girilir.
public struct AppConfig {
    public static let bundleID = "dev.secretbot.SecretBot"

    public enum Key {
        public static let connMode = "connMode"
        public static let sshUser = "sshUser"
        public static let sshHost = "sshHost"
        public static let contexts = "contexts"
        public static let envDescription = "envDescription"
        public static let namespacePrefixes = "namespacePrefixes"
        public static let aiProvider = "aiProvider"
        public static let anthropicModel = "anthropicModel"
        public static let claudeCodeModel = "claudeCodeModel"
        public static let openaiBaseURL = "openaiBaseURL"
        public static let openaiModel = "openaiModel"
    }

    public static let defaultModel = "claude-opus-5-5"
    public static let defaultEnvDescription = """
    Secret'lar Kubernetes Opaque secret'ıdır. Key adları küçük harf ve tirelidir (ör. app-token). \
    Uygulamalar secret'ları env değişkenine secretKeyRef ile bağlar.
    """

    public var connMode: ConnectionMode
    public var sshUser: String
    public var sshHost: String
    public var contexts: [String]
    public var envDescription: String
    public var namespacePrefixes: [String]
    public var aiProvider: AIProvider
    public var anthropicModel: String
    public var claudeCodeModel: String
    public var openaiBaseURL: String
    public var openaiModel: String

    public static func load(_ d: UserDefaults = .standard) -> AppConfig {
        func s(_ k: String) -> String { (d.string(forKey: k) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        func list(_ k: String) -> [String] {
            var out = [String]()
            for p in s(k).split(whereSeparator: { $0 == "," || $0.isNewline || $0 == " " }) {
                let v = String(p).trimmingCharacters(in: .whitespaces)
                if !v.isEmpty && !out.contains(v) { out.append(v) }
            }
            return out
        }
        return AppConfig(
            connMode: ConnectionMode(rawValue: s(Key.connMode)) ?? .local,
            sshUser: s(Key.sshUser),
            sshHost: s(Key.sshHost),
            contexts: list(Key.contexts),
            envDescription: s(Key.envDescription).isEmpty ? defaultEnvDescription : s(Key.envDescription),
            namespacePrefixes: list(Key.namespacePrefixes),
            aiProvider: AIProvider(rawValue: s(Key.aiProvider)) ?? .auto,
            anthropicModel: s(Key.anthropicModel).isEmpty ? defaultModel : s(Key.anthropicModel),
            claudeCodeModel: s(Key.claudeCodeModel).isEmpty ? defaultModel : s(Key.claudeCodeModel),
            openaiBaseURL: s(Key.openaiBaseURL),
            openaiModel: s(Key.openaiModel)
        )
    }

    public var remote: RemoteConfig { RemoteConfig(mode: connMode, user: sshUser, host: sshHost) }

    /// Kubernetes tarafı kullanıma hazır mı (ilk açılışta kurulum uyarısı için).
    public var isConfigured: Bool {
        !contexts.isEmpty && (connMode == .local || (!sshUser.isEmpty && !sshHost.isEmpty))
    }

    public var aiPrompt: AIPromptConfig { AIPromptConfig(contexts: contexts, envDescription: envDescription) }
}

/// Yapay zekâya ortamı anlatmak için gereken bilgiler.
public struct AIPromptConfig {
    public var contexts: [String]
    public var envDescription: String
    public init(contexts: [String], envDescription: String) {
        self.contexts = contexts; self.envDescription = envDescription
    }
}

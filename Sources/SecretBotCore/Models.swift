import Foundation
import CryptoKit

public struct KeyEntry: Identifiable, Hashable {
    public let id: UUID
    public var secretName: String
    public var key: String
    public var envName: String
    public var value: String

    public init(id: UUID = UUID(), secretName: String, key: String, envName: String = "", value: String = "") {
        self.id = id
        self.secretName = secretName
        self.key = key
        self.envName = envName
        self.value = value
    }
}

public struct ParsedMail {
    public var namespaces: [String]
    public var entries: [KeyEntry]
    public var warnings: [String]
}

/// Bir namespace'teki secret'ın durumu. Değerler değil, sadece SHA-256 hash'leri tutulur.
public enum TargetState: Equatable {
    case nsMissing
    case secretMissing
    case exists([String: String], resourceVersion: String) // key -> sha256(değer)
    case error(String)
}

public struct TargetResult {
    public let secretName: String
    public let namespace: String
    public let state: TargetState

    public init(secretName: String, namespace: String, state: TargetState) {
        self.secretName = secretName
        self.namespace = namespace
        self.state = state
    }
}

public enum KeyStatus { case missing, same, different }

public struct KeyChange: Hashable {
    public let key: String
    public let status: KeyStatus
}

/// Çakışmayı önlemek için varsayılan olarak sadece **olmayan** secret oluşturulur.
/// Var olan secret ancak kullanıcı tek tek seçip onaylarsa güncellenir (bkz. Remote.apply `updates`).
public enum PlannedAction: Equatable {
    case create
    case exists
    case skip(String)

    public var mutates: Bool { self == .create }
}

public struct PlanItem: Identifiable {
    public var id: String { "\(secretName)/\(namespace)" }
    public let secretName: String
    public let namespace: String
    public let action: PlannedAction
    public let changes: [KeyChange]
    /// Var olan secret'ın kontrol anındaki sürümü; güncellemede çakışma kilidi olarak kullanılır.
    public var resourceVersion: String = ""

    /// Var olan ama maildekinden farklı/eksik key'i olan secret: kullanıcı onaylarsa güncellenebilir.
    public var canUpdate: Bool { action == .exists && !matchesMail }

    /// Secret zaten var ve tüm key'leri maildeki değerlerle aynı.
    public var matchesMail: Bool { action == .exists && changes.allSatisfy { $0.status == .same } }
}

public func sha256Hex(_ s: String) -> String {
    SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
}

public enum Validate {
    private static func matches(_ s: String, _ pattern: String) -> Bool {
        s.range(of: pattern, options: .regularExpression) != nil
    }

    public static func isName(_ s: String) -> Bool {
        s.count <= 253 && matches(s, "^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$")
    }

    public static func isKey(_ s: String) -> Bool {
        s.count <= 253 && matches(s, "^[-._a-zA-Z0-9]+$")
    }

    public static func isSSHUser(_ s: String) -> Bool { matches(s, "^[a-z_][a-z0-9_.-]*$") }
    public static func isSSHHost(_ s: String) -> Bool { matches(s, "^[A-Za-z0-9.-]+$") }
    /// kubeconfig context adı (ör. dev, arn:aws:eks:…/cluster, user@cluster).
    public static func isContextName(_ s: String) -> Bool { s.count <= 253 && matches(s, "^[A-Za-z0-9._@:/-]+$") }

    /// Sunucuya gitmeden önce girdileri kontrol eder. Boş liste = sorun yok.
    public static func problems(context: String, contexts: [String], namespaces: [String], entries: [KeyEntry]) -> [String] {
        var p = [String]()
        if contexts.isEmpty { p.append("Ayarlar'da (⌘,) en az bir cluster context'i tanımlayın.") }
        else if !contexts.contains(context) || !isContextName(context) { p.append("Geçersiz ortam: \(context)") }
        if namespaces.isEmpty { p.append("En az bir namespace gerekli.") }
        for ns in namespaces where !isName(ns) { p.append("Geçersiz namespace adı: \(ns)") }
        if entries.isEmpty { p.append("En az bir key gerekli.") }
        var seen = [String: String]()
        for e in entries {
            if !isName(e.secretName) { p.append("Geçersiz secret adı: '\(e.secretName)'") }
            if !isKey(e.key) { p.append("Geçersiz key adı: '\(e.key)'") }
            if e.value.isEmpty { p.append("Değer boş: \(e.secretName) / \(e.key)") }
            let id = "\(e.secretName)/\(e.key)"
            if let prev = seen[id], prev != e.value { p.append("Aynı key iki farklı değerle girilmiş: \(id)") }
            seen[id] = e.value
        }
        return p
    }
}

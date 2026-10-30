import Foundation

/// Maskeleme sonucu: gönderilecek metin + etiket → gerçek değer eşlemesi (yerelde kalır).
public struct MaskResult {
    public let text: String
    public let map: [String: String]

    /// Metindeki tüm etiketleri gerçek değerleriyle değiştirir.
    public func restore(_ s: String) -> String {
        var out = s
        for (tag, value) in map { out = out.replacingOccurrences(of: tag, with: value) }
        return out
    }
}

/// Mail yapay zekâya gitmeden önce değer olabilecek her şeyi `<<S1>>` gibi etiketlerle değiştirir.
/// Fazla maskelemek zararsızdır (yapay zekâ etiketi aynen döndürür, yerelde geri konur);
/// az maskelemek değer sızdırır. Bu yüzden kurallar bilerek geniş tutuldu.
public enum Masker {
    /// `key: value` satırlarında değeri maskelenmeyecek yapı alanları.
    static let structuralKeys: Set<String> = [
        "name", "key", "namespace", "namespaces", "ns", "secretname", "secretkeyref", "valuefrom",
        "apiversion", "kind", "type", "metadata", "context", "ortam", "cluster", "env",
    ]

    /// Bu kelimelerden sonra gelen ilk kelime her durumda maskelenir.
    /// ("secret", "token" gibi kelimeler isimlerin önünde de geçtiği için burada değil;
    /// onlardan sonra gelen gerçek değerler zaten looksSecret ile yakalanır.)
    static let secretWords: Set<String> = [
        "şifre", "şifresi", "sifre", "sifresi", "parola", "parolası", "password", "pass", "pwd",
    ]

    public static func mask(_ text: String) -> MaskResult {
        var map = [String: String]()
        var reverse = [String: String]()
        func tag(_ v: String) -> String {
            if let t = reverse[v] { return t }
            let t = "<<S\(map.count + 1)>>"
            map[t] = v
            reverse[v] = t
            return t
        }

        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        let masked = lines.map { maskLine($0, tag) }
        return MaskResult(text: masked.joined(separator: "\n"), map: map)
    }

    private static let kvRegex = try! NSRegularExpression(
        pattern: #"^(\s*-?\s*)("?)([A-Za-z_][A-Za-z0-9_.-]*)("?\s*[:=]\s*)("?)([^"\s]+)("?)(\s*,?\s*)$"#)

    private static func maskLine(_ line: String, _ tag: (String) -> String) -> String {
        // 1) Tek değerli `key: value` / `"key": "value"` / `KEY=value` satırları
        let ns = line as NSString
        if let m = kvRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
            let g = { (i: Int) in ns.substring(with: m.range(at: i)) }
            let key = g(3)
            let normKey = key.lowercased().filter { $0.isLetter || $0.isNumber }
            if structuralKeys.contains(normKey) { return line }
            return g(1) + g(2) + key + g(4) + g(5) + tag(g(6)) + g(7) + g(8)
        }

        // 2) Serbest metin: kelime kelime bak
        var out = ""
        var prevWord = ""
        var token = ""
        func flush() {
            guard !token.isEmpty else { return }
            let (lead, core, trail) = split(token)
            let isKeyword = secretWords.contains(core.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ":=")))
            let forced = secretWords.contains(prevWord) && !isKeyword
            if !core.isEmpty && (forced || looksSecret(core)) {
                out += lead + tag(core) + trail
            } else {
                out += token
            }
            prevWord = core.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ":="))
            token = ""
        }
        for ch in line {
            if ch == " " || ch == "\t" { flush(); out.append(ch) } else { token.append(ch) }
        }
        flush()
        return out
    }

    /// Baştaki/sondaki tırnak, virgül, parantez gibi işaretleri ayırır.
    private static func split(_ t: String) -> (String, String, String) {
        let edge = CharacterSet(charactersIn: "\"'`,;:()[]{}<>?")
        var s = Substring(t)
        var lead = "", trail = ""
        while let f = s.first, f.unicodeScalars.allSatisfy({ edge.contains($0) }) { lead.append(f); s = s.dropFirst() }
        while let l = s.last, l.unicodeScalars.allSatisfy({ edge.contains($0) }) { trail = String(l) + trail; s = s.dropLast() }
        return (lead, String(s), trail)
    }

    static func looksSecret(_ t: String) -> Bool {
        if t.hasPrefix("<<S") { return false }
        guard t.count >= 6 else { return false }
        if isSafeName(t) { return false }
        let hasDigit = t.contains { $0.isNumber }
        let hasLetter = t.contains { $0.isLetter }
        let hasSpecial = t.contains { "!@#$%^&*+=?~|\\/".contains($0) }
        return (hasDigit && hasLetter) || t.count >= 24 || hasSpecial
    }

    /// Namespace/secret adı (team-test02-api) veya env adı (APP_API_TOKEN) gibi açıkça isim olan şeyler.
    static func isSafeName(_ t: String) -> Bool {
        if t.range(of: #"^[a-z][a-z0-9]*(-[a-z0-9]+)+$"#, options: .regularExpression) != nil {
            // Rakam içeren uzun parçalar (UUID, hex) isim değildir.
            return t.split(separator: "-").allSatisfy { seg in !seg.contains(where: \.isNumber) || seg.count <= 6 }
        }
        if t.range(of: #"^[A-Z][A-Z0-9]*(_[A-Z0-9]+)+$"#, options: .regularExpression) != nil {
            return t.split(separator: "_").allSatisfy { seg in !seg.contains(where: \.isNumber) || seg.count <= 6 }
        }
        return false
    }
}

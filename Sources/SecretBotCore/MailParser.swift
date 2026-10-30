import Foundation

/// Secret talep maillerini okur:
/// - namespace'ler: tek başına satırda duran k8s adları (veya virgüllü listeleri), "namespace: x",
///   ve Ayarlar'da tanımlı öneklerle başlayan adlar (ör. "team-")
/// - `secretKeyRef` blokları (env adı, secret adı, key)
/// - değerler (`"appToken": "..."` veya `app-token: ...` satırları), key adına göre eşleştirilir
/// Yapay zekâ kullanılamadığında yedek olarak çalışır.
public enum MailParser {
    public static func parse(_ text: String, namespacePrefixes: [String] = []) -> ParsedMail {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var warnings = [String]()

        // 1) secretKeyRef blokları
        var entries = [KeyEntry]()
        var env = ""
        var inRef = false
        var refName: String?
        var refKey: String?
        for raw in lines {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if let v = field(t, "- name:") { env = v; inRef = false; continue }
            if t.hasPrefix("secretKeyRef:") { inRef = true; refName = nil; refKey = nil; continue }
            guard inRef else { continue }
            if let v = field(t, "name:") { refName = v }
            else if let v = field(t, "key:") { refKey = v }
            else if t.isEmpty || t.hasPrefix("optional:") { continue }
            else { inRef = false; continue }
            if let n = refName, let k = refKey {
                if let i = entries.firstIndex(where: { $0.secretName == n && $0.key == k }) {
                    if entries[i].envName.isEmpty { entries[i].envName = env }
                } else {
                    entries.append(KeyEntry(secretName: n, key: k, envName: env))
                }
                inRef = false
            }
        }
        let secretNames = Set(entries.map(\.secretName))

        // 2) namespace'ler
        var namespaces = [String]()
        func addNS(_ s: String) {
            if !namespaces.contains(s) && !secretNames.contains(s) { namespaces.append(s) }
        }
        let prefixes = namespacePrefixes.filter { !$0.isEmpty }
            .map { NSRegularExpression.escapedPattern(for: $0) }
        let prefixPattern = prefixes.isEmpty ? nil
            : #"(?<![A-Za-z0-9._-])((?:"# + prefixes.joined(separator: "|") + #")[a-z0-9]*(?:-[a-z0-9]+)*)(?![A-Za-z0-9._-])"#
        for raw in lines {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("name:") || t.hasPrefix("key:") || t.hasPrefix("- name:") { continue }
            // Satırda sadece k8s adları varsa (tek tek veya virgüllü liste) hepsi namespace adayıdır.
            let tokens = t.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == " " || $0 == "\t" }).map(String.init)
            if !tokens.isEmpty && tokens.allSatisfy({ $0.contains("-") && Validate.isName($0) && !$0.contains(".") }) {
                tokens.forEach(addNS)
            }
            if let prefixPattern { for m in captures(prefixPattern, in: t) { addNS(m[0]) } }
            for m in captures(#"namespace\s*[:=]\s*"?([a-z0-9][a-z0-9-]*[a-z0-9])"?"#, in: t) { addNS(m[0]) }
        }

        // 3) değerler
        let quoted = captures(#""([^"\n]+)"\s*:\s*"([^"\n]*)""#, in: text).map { ($0[0], $0[1]) }
        let plain = captures(#"(?m)^[ \t]*([A-Za-z_][A-Za-z0-9_.-]*)[ \t]*[:=][ \t]*"?([^"\s,]+)"?[ \t]*,?[ \t]*$"#, in: text).map { ($0[0], $0[1]) }
        let pairs = quoted + plain
        var used = Set<String>()
        for i in entries.indices {
            let k = norm(entries[i].key)
            let e = norm(entries[i].envName)
            let hit = pairs.first(where: { norm($0.0) == k })
                ?? pairs.first(where: { !e.isEmpty && norm($0.0) == e })
                ?? pairs.first(where: { let n = norm($0.0); return n.count >= 4 && !e.isEmpty && e.hasSuffix(n) })
            if let hit {
                entries[i].value = hit.1
                used.insert(hit.0)
            } else {
                warnings.append("Değer bulunamadı: \(entries[i].secretName) / \(entries[i].key). Elle girin.")
            }
        }
        for (k, _) in quoted where !used.contains(k) {
            warnings.append("Mailde hiçbir key ile eşleşmeyen değer var: \"\(k)\"")
        }

        if entries.isEmpty { warnings.append("Mailde secretKeyRef bloğu bulunamadı. Secret adı ve key'leri elle ekleyin.") }
        if namespaces.isEmpty { warnings.append("Namespace bulunamadı. Elle ekleyin.") }
        return ParsedMail(namespaces: namespaces, entries: entries, warnings: warnings)
    }

    private static func field(_ t: String, _ prefix: String) -> String? {
        guard t.hasPrefix(prefix) else { return nil }
        let v = t.dropFirst(prefix.count).trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"'")))
        return v.isEmpty ? nil : v
    }

    private static func norm(_ s: String) -> String {
        String(s.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    private static func captures(_ pattern: String, in s: String) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { m in
            (1..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
        }
    }
}

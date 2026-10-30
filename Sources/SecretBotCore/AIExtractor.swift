import Foundation

public struct AIResult {
    public var context: String
    public var namespaces: [String]
    public var entries: [KeyEntry]
    public var notes: [String]
}

public struct AIError: LocalizedError {
    public let message: String
    public init(_ m: String) { message = m }
    public var errorDescription: String? { message }
}

/// Maskelenmiş maili Claude API'ye gönderip yapılandırılmış talebi çıkarır.
/// Swift için resmi SDK olmadığından doğrudan HTTP kullanılır.
public enum AIExtractor {
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    /// Sunucu taraflı "fallbacks: default" kabul eden modeller.
    static let fallbackModels: Set<String> = ["claude-opus-5-5", "claude-opus-5", "claude-fable-5-1", "claude-sonnet-5-5"]

    /// Ortak sistem talimatı; ortama özgü kısım kullanıcının Ayarlar'daki açıklamasından gelir.
    public static func systemPrompt(_ cfg: AIPromptConfig) -> String {
        let ctxList = cfg.contexts.map { "\"\($0)\"" }.joined(separator: ", ")
        return """
        Kubernetes secret tanımlama taleplerini içeren maillerden yapılandırılmış veri çıkarıyorsun.

        Ortam bilgisi (kullanıcının tarifi):
        \(cfg.envDescription)

        Tanımlı cluster context'leri: \(ctxList.isEmpty ? "(yok)" : ctxList).

        Maskeleme:
        - Metindeki <<S1>>, <<S2>> gibi etiketler gizlenmiş gerçek metinlerdir (çoğu secret değeri, bazıları isim olabilir).
        - Bir alana bu metin gelecekse etiketi AYNEN yaz. Etiketi asla değiştirme, birleştirme veya tahmin etme.

        Çıkarılacaklar:
        - namespaces: talebin uygulanacağı namespace'ler. Mailde açıkça yoksa boş bırak ve notes'a yaz; uydurma.
        - entries: her (secret_name, key) için bir kayıt.
          - secretKeyRef verilmişse secret_name = name, key = key, env_name = env değişkeninin adı.
          - value: o key'in mailde verilen değeri. Değerler farklı adlarla verilebilir (ör. "appToken" → app-token key'i, \
        PAYMENT_API_KEY env'i → api-key). Eşleşmeyi bulamazsan value boş string olsun ve notes'a yaz.
          - Secret adı veya key mailde açıkça yoksa ortamdaki isimlendirmeye uyan bir öneri yap ve notes'ta bunun öneri olduğunu belirt.
        - context: namespace'lerin bulunduğu cluster context'i (yukarıdaki listeden); emin değilsen "unknown".
        - notes: kullanıcıya kısa Türkçe uyarılar (eksik bilgi, belirsizlik, öneri, mailin secret talebi olmaması vb.). Yoksa boş liste.
        """
    }

    public static func schema(_ cfg: AIPromptConfig) -> [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "required": ["context", "namespaces", "entries", "notes"],
            "properties": [
                "context": ["type": "string", "enum": cfg.contexts + ["unknown"]],
                "namespaces": ["type": "array", "items": ["type": "string"]],
                "entries": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "additionalProperties": false,
                        "required": ["secret_name", "key", "env_name", "value"],
                        "properties": [
                            "secret_name": ["type": "string"],
                            "key": ["type": "string"],
                            "env_name": ["type": "string"],
                            "value": ["type": "string"],
                        ],
                    ],
                ],
                "notes": ["type": "array", "items": ["type": "string"]],
            ],
        ]
    }

    static func schemaJSON(_ cfg: AIPromptConfig) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: schema(cfg), options: [.sortedKeys])) ?? Data(), as: UTF8.self)
    }

    private struct Output: Decodable {
        struct Entry: Decodable { let secret_name, key, env_name, value: String }
        let context: String
        let namespaces: [String]
        let entries: [Entry]
        let notes: [String]
    }

    public static func extract(masked: MaskResult, apiKey: String, model: String, prompt: AIPromptConfig) async throws -> AIResult {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": 16000,
            "system": systemPrompt(prompt),
            "output_config": ["format": ["type": "json_schema", "schema": schema(prompt)]],
            "messages": [["role": "user", "content": "Mail:\n\n" + masked.text]],
        ]
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 180
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        if fallbackModels.contains(model) {
            body["fallbacks"] = "default"
            req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data = try await send(req)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIError("API yanıtı okunamadı.")
        }
        switch obj["stop_reason"] as? String {
        case "refusal": throw AIError("Yapay zekâ bu maili işlemeyi reddetti.")
        case "max_tokens": throw AIError("Yapay zekâ yanıtı yarıda kesildi.")
        default: break
        }
        let text = (obj["content"] as? [[String: Any]] ?? [])
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
        return try decode(Data(text.utf8), masked: masked)
    }

    /// Şemaya uygun JSON'u çözer ve etiketleri gerçek değerlerle değiştirir.
    /// (Bazı modeller JSON'u ``` blokları içinde döndürür; o durumda ilk { … son } arası alınır.)
    static func decode(_ json: Data, masked: MaskResult) throws -> AIResult {
        var data = json
        if (try? JSONDecoder().decode(Output.self, from: data)) == nil,
           let s = String(data: json, encoding: .utf8),
           let a = s.firstIndex(of: "{"), let b = s.lastIndex(of: "}"), a < b {
            data = Data(s[a...b].utf8)
        }
        guard let out = try? JSONDecoder().decode(Output.self, from: data) else {
            throw AIError("Yapay zekâ yanıtı beklenen biçimde değil.")
        }

        // Etiketleri gerçek değerlerle değiştir (yerelde).
        let r = { (s: String) in masked.restore(s).trimmingCharacters(in: .whitespacesAndNewlines) }
        var nss = [String]()
        for n in out.namespaces.map(r) where !n.isEmpty && !nss.contains(n) { nss.append(n) }
        let entries = out.entries.map {
            KeyEntry(secretName: r($0.secret_name), key: r($0.key), envName: r($0.env_name), value: r($0.value))
        }
        return AIResult(context: out.context, namespaces: nss, entries: entries, notes: out.notes.map(r))
    }

    /// İsteği gönderir; 429/5xx/bağlantı hatalarında iki kez tekrar dener.
    static func send(_ req: URLRequest, service: String = "Claude API") async throws -> Data {
        var attempt = 0
        while true {
            attempt += 1
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if code == 200 { return data }
                let apiMsg = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any])?["message"] as? String ?? ""
                let retryable = code == 429 || code >= 500
                if retryable && attempt < 3 {
                    try await Task.sleep(nanoseconds: UInt64(attempt) * 2_000_000_000)
                    continue
                }
                switch code {
                case 401: throw AIError("API anahtarı geçersiz (401).")
                case 403: throw AIError("API anahtarının bu işleme yetkisi yok (403). \(apiMsg)")
                case 429: throw AIError("API kullanım limiti doldu (429). Biraz sonra tekrar deneyin.")
                case 500...: throw AIError("\(service) şu an yanıt vermiyor (\(code)).")
                default: throw AIError("API hatası (\(code)): \(apiMsg)")
                }
            } catch let e as AIError {
                throw e
            } catch {
                if attempt < 3 { try await Task.sleep(nanoseconds: UInt64(attempt) * 2_000_000_000); continue }
                throw AIError("\(service) bağlantısı kurulamadı: \(error.localizedDescription)")
            }
        }
    }
}

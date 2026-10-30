import Foundation

/// OpenAI uyumlu `/chat/completions` uç noktası ile okuma: OpenAI, Azure/şirket gateway'leri,
/// yerel modeller (Ollama: http://localhost:11434/v1, LM Studio: http://localhost:1234/v1) vb.
/// Mail burada da maskelenmiş olarak gider.
public enum OpenAIExtractor {
    public static func extract(masked: MaskResult, baseURL: String, model: String, apiKey: String?,
                               prompt: AIPromptConfig) async throws -> AIResult {
        let trimmed = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let url = URL(string: trimmed + "/chat/completions"), url.scheme == "https" || url.scheme == "http" else {
            throw AIError("OpenAI uyumlu uç nokta adresi geçersiz: \(baseURL)")
        }
        guard !model.isEmpty else { throw AIError("OpenAI uyumlu uç nokta için model adı girilmedi.") }

        let messages: [[String: Any]] = [
            ["role": "system", "content": AIExtractor.systemPrompt(prompt)
                + "\n\nYanıtı yalnızca şu JSON şemasına uyan tek bir JSON nesnesi olarak ver:\n" + AIExtractor.schemaJSON(prompt)],
            ["role": "user", "content": "Mail:\n\n" + masked.text],
        ]
        let strict: [String: Any] = ["type": "json_schema",
                                     "json_schema": ["name": "secret_request", "strict": true, "schema": AIExtractor.schema(prompt)]]

        func request(_ format: [String: Any]) throws -> URLRequest {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = 300
            req.setValue("application/json", forHTTPHeaderField: "content-type")
            if let apiKey, !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization") }
            req.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "messages": messages, "response_format": format])
            return req
        }

        let data: Data
        do {
            data = try await AIExtractor.send(try request(strict), service: "OpenAI uyumlu uç nokta")
        } catch let e as AIError where e.message.contains("(400)") || e.message.contains("(422)") {
            // json_schema desteklemeyen sunucular için daha basit JSON modu.
            data = try await AIExtractor.send(try request(["type": "json_object"]), service: "OpenAI uyumlu uç nokta")
        }

        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choice = (obj["choices"] as? [[String: Any]])?.first,
              let message = choice["message"] as? [String: Any] else {
            throw AIError("OpenAI uyumlu uç noktanın yanıtı okunamadı.")
        }
        if choice["finish_reason"] as? String == "length" { throw AIError("Yapay zekâ yanıtı yarıda kesildi.") }
        if let refusal = message["refusal"] as? String, !refusal.isEmpty { throw AIError("Yapay zekâ reddetti: \(refusal)") }
        let text = message["content"] as? String ?? ""
        return try AIExtractor.decode(Data(text.utf8), masked: masked)
    }
}

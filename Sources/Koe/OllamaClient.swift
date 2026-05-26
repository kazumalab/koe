import Foundation

// ローカルの Ollama（http://localhost:11434）へ文字起こし結果を送り、整形済みテキストを得る。
// Ollama 未起動・タイムアウト・空応答などの失敗時は、入力（生の文字起こし）をそのまま返す。
struct OllamaClient {
    let baseURL: URL
    let model: String
    var domainHint: String = ""     // 同音異義語の判別を寄せる文脈ヒント（Whisper 語彙ヒントを流用）
    var mode: RefineMode = .strict  // 整形の強さ（strict / natural / custom）
    var customSystemPrompt: String = ""  // mode == .custom 時のみ参照
    var timeout: TimeInterval = 30
    var temperature: Double = 0     // 0 で最も決定的（余計な書き換えを抑える）

    func refine(_ raw: String) async -> RefineOutcome {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return RefineOutcome(finalText: raw, proposed: nil, accepted: false, reason: "empty_input")
        }

        do {
            let url = baseURL.appendingPathComponent("api/chat")
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = timeout
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let messages = RefineCore.buildMessages(
                userText: trimmed,
                domainHint: domainHint,
                mode: mode,
                customSystemPrompt: customSystemPrompt
            ).map { ChatRequest.Message(role: $0.role, content: $0.content) }
            req.httpBody = try JSONEncoder().encode(ChatRequest(
                model: model,
                stream: false,
                messages: messages,
                options: .init(temperature: temperature)
            ))

            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                log("整形スキップ（Ollama 応答エラー）: 生テキストを使用")
                return RefineOutcome(finalText: trimmed, proposed: nil, accepted: false, reason: "http_error")
            }
            let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
            let refined = decoded.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return RefineCore.evaluate(trimmed: trimmed, proposed: refined, mode: mode)
        } catch {
            log("整形スキップ（Ollama 接続失敗: \(error.localizedDescription)）: 生テキストを使用")
            return RefineOutcome(finalText: trimmed, proposed: nil, accepted: false, reason: "unreachable")
        }
    }

    // 整形を行う前の簡易疎通確認（任意）。
    func isReachable() async -> Bool {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        req.timeoutInterval = 3
        guard let (_, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else { return false }
        return http.statusCode == 200
    }

    // MARK: JSON モデル

    private struct ChatRequest: Encodable {
        let model: String
        let stream: Bool
        let messages: [Message]
        let options: Options
        struct Message: Encodable { let role: String; let content: String }
        struct Options: Encodable { let temperature: Double }
    }

    private struct ChatResponse: Decodable {
        let message: Message
        struct Message: Decodable { let role: String; let content: String }
    }
}

import Foundation

// DeepSeek API（OpenAI 互換の /chat/completions）へ文字起こし結果を送り、整形済みテキストを得る。
// API キー未設定・非200・通信失敗・空応答などの失敗時は、入力（生の文字起こし）をそのまま返す。
// 注意: ローカル Ollama と違い、テキストは外部（DeepSeek サーバ）へ送信される（完全オフラインではない）。
struct DeepSeekClient {
    let apiKey: String
    let model: String                       // 例: "deepseek-chat"
    var baseURL: URL = URL(string: "https://api.deepseek.com")!
    var domainHint: String = ""             // 同音異義語の判別を寄せる文脈ヒント
    var mode: RefineMode = .strict          // 整形の強さ（strict / natural / custom）
    var customSystemPrompt: String = ""     // mode == .custom 時のみ参照
    var timeout: TimeInterval = 30
    var temperature: Double = 0             // 0 で最も決定的（余計な書き換えを抑える）

    func refine(_ raw: String) async -> RefineOutcome {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return RefineOutcome(finalText: raw, proposed: nil, accepted: false, reason: "empty_input")
        }
        guard !apiKey.isEmpty else {
            log("整形スキップ（DeepSeek API キー未設定）: 生テキストを使用")
            return RefineOutcome(finalText: trimmed, proposed: nil, accepted: false, reason: "no_api_key")
        }

        do {
            let url = baseURL.appendingPathComponent("chat/completions")
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = timeout
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            let messages = RefineCore.buildMessages(
                userText: trimmed,
                domainHint: domainHint,
                mode: mode,
                customSystemPrompt: customSystemPrompt
            ).map { ChatRequest.Message(role: $0.role, content: $0.content) }
            req.httpBody = try JSONEncoder().encode(ChatRequest(
                model: model,
                stream: false,
                temperature: temperature,
                messages: messages
            ))

            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                log("整形スキップ（DeepSeek 応答エラー status=\(code)）: 生テキストを使用")
                return RefineOutcome(finalText: trimmed, proposed: nil, accepted: false, reason: "http_error")
            }
            let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
            let refined = (decoded.choices.first?.message.content ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return RefineCore.evaluate(trimmed: trimmed, proposed: refined, mode: mode)
        } catch {
            log("整形スキップ（DeepSeek 接続失敗: \(error.localizedDescription)）: 生テキストを使用")
            return RefineOutcome(finalText: trimmed, proposed: nil, accepted: false, reason: "unreachable")
        }
    }

    // MARK: JSON モデル（OpenAI 互換）

    private struct ChatRequest: Encodable {
        let model: String
        let stream: Bool
        let temperature: Double
        let messages: [Message]
        struct Message: Encodable { let role: String; let content: String }
    }

    private struct ChatResponse: Decodable {
        let choices: [Choice]
        struct Choice: Decodable { let message: Message }
        struct Message: Decodable { let role: String?; let content: String }
    }
}

import Foundation

// Google Gemini API（generateContent）へ文字起こし結果を送り、整形済みテキストを得る。
// API キー未設定・非200・通信失敗・空応答などの失敗時は、入力（生の文字起こし）をそのまま返す。
// 注意: ローカル Ollama と違い、テキストは外部（Google サーバ）へ送信される（完全オフラインではない）。
//
// Gemini は OpenAI 互換ではなく、systemInstruction + contents（role は "user"/"model"）という独自形式。
// RefineCore.buildMessages が返す共通メッセージ列を、ここで Gemini 形式へ写像する。
struct GeminiClient {
    let apiKey: String
    let model: String                       // 例: "gemini-2.5-flash"
    var baseURL: URL = URL(string: "https://generativelanguage.googleapis.com")!
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
            log("整形スキップ（Gemini API キー未設定）: 生テキストを使用")
            return RefineOutcome(finalText: trimmed, proposed: nil, accepted: false, reason: "no_api_key")
        }

        do {
            let url = baseURL
                .appendingPathComponent("v1beta")
                .appendingPathComponent("models")
                .appendingPathComponent("\(model):generateContent")
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = timeout
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            // URL に ?key= を付けるとアクセスログ・ProxyのURL履歴に残りやすい。ヘッダで渡す。
            req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")

            let messages = RefineCore.buildMessages(
                userText: trimmed,
                domainHint: domainHint,
                mode: mode,
                customSystemPrompt: customSystemPrompt
            )
            let (systemInstruction, contents) = Self.toGeminiPayload(messages)
            req.httpBody = try JSONEncoder().encode(GenerateRequest(
                systemInstruction: systemInstruction,
                contents: contents,
                generationConfig: .init(temperature: temperature)
            ))

            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                log("整形スキップ（Gemini 応答エラー status=\(code)）: 生テキストを使用")
                return RefineOutcome(finalText: trimmed, proposed: nil, accepted: false, reason: "http_error")
            }
            let decoded = try JSONDecoder().decode(GenerateResponse.self, from: data)
            let refined = (decoded.candidates?.first?.content?.parts ?? [])
                .compactMap { $0.text }
                .joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return RefineCore.evaluate(trimmed: trimmed, proposed: refined, mode: mode)
        } catch {
            log("整形スキップ（Gemini 接続失敗: \(error.localizedDescription)）: 生テキストを使用")
            return RefineOutcome(finalText: trimmed, proposed: nil, accepted: false, reason: "unreachable")
        }
    }

    // RefineMessage 配列 → (systemInstruction, contents) への写像。
    // - role=="system" は全て systemInstruction に集約（複数なら改行結合）。
    // - role=="assistant" は role="model" に置換（Gemini 仕様）。
    // - role=="user" はそのまま。
    private static func toGeminiPayload(_ messages: [RefineMessage])
        -> (GenerateRequest.SystemInstruction?, [GenerateRequest.Content])
    {
        var systemTexts: [String] = []
        var contents: [GenerateRequest.Content] = []
        for m in messages {
            switch m.role {
            case "system":
                systemTexts.append(m.content)
            case "assistant":
                contents.append(.init(role: "model", parts: [.init(text: m.content)]))
            default: // "user" など
                contents.append(.init(role: "user", parts: [.init(text: m.content)]))
            }
        }
        let sys: GenerateRequest.SystemInstruction? = systemTexts.isEmpty
            ? nil
            : .init(parts: [.init(text: systemTexts.joined(separator: "\n\n"))])
        return (sys, contents)
    }

    // MARK: JSON モデル（Gemini generateContent）

    private struct GenerateRequest: Encodable {
        let systemInstruction: SystemInstruction?
        let contents: [Content]
        let generationConfig: GenerationConfig
        struct SystemInstruction: Encodable { let parts: [Part] }
        struct Content: Encodable { let role: String; let parts: [Part] }
        struct Part: Encodable { let text: String }
        struct GenerationConfig: Encodable { let temperature: Double }
    }

    private struct GenerateResponse: Decodable {
        let candidates: [Candidate]?
        struct Candidate: Decodable { let content: Content? }
        struct Content: Decodable { let parts: [Part]? }
        struct Part: Decodable { let text: String? }
    }
}

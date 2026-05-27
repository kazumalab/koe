import Foundation

// ユーザー設定（UserDefaults 永続化）。SwiftUI 側は @AppStorage で同じキーを束縛する。
enum SettingsKey {
    static let refineEnabled  = "koe.refineEnabled"
    static let refineProvider = "koe.refineProvider"   // "ollama"（ローカル） / "deepseek"（API）
    static let refineMode     = "koe.refineMode"       // "strict"（漢字のみ） / "natural"（カタカナ→英字も）
    static let ollamaModel    = "koe.ollamaModel"
    static let ollamaBaseURL  = "koe.ollamaBaseURL"
    static let deepseekModel  = "koe.deepseekModel"
    static let deepseekBaseURL = "koe.deepseekBaseURL"
    static let whisperModel   = "koe.whisperModel"
    static let hotkey         = "koe.hotkey"
    static let restoreClipboard = "koe.restoreClipboard"
    static let language       = "koe.language"
    static let initialPrompt  = "koe.initialPrompt"
}

// 整形バックエンド。ローカル(Ollama)か、クラウドAPI(DeepSeek)か。
enum RefineProvider: String {
    case ollama
    case deepseek
}

// Keychain 上の DeepSeek API キーのアカウント名。
let deepseekKeyAccount = "deepseek-api-key"

// Whisper の語彙ヒント（initial_prompt）の既定値。専門用語の認識精度を上げる“辞書”。
// 設定の「認識」タブで自由に語を追加できる。
let defaultInitialPrompt = "以下はソフトウェア開発に関する日本語の発話です。次の専門用語が正しく表記されます: " + [
    "コミット", "プッシュ", "プル", "プルリクエスト", "マージ", "リベース", "ブランチ",
    "コンフリクト", "ステージング", "デプロイ", "リリース", "ロールバック",
    "ビルド", "テスト", "デバッグ", "リファクタリング", "レビュー", "プレビュー",
    "リポジトリ", "コンポーネント", "ライブラリ", "フレームワーク", "モジュール",
    "エンドポイント", "API", "データベース", "クエリ", "キャッシュ", "サーバー",
    "クライアント", "フロントエンド", "バックエンド", "認証", "トークン", "セッション",
    "TypeScript", "JavaScript", "Swift", "SwiftUI", "Xcode", "GitHub", "Ollama", "Whisper"
].joined(separator: "、") + "。"

enum Settings {
    private static var d: UserDefaults { .standard }

    static func registerDefaults() {
        d.register(defaults: [
            SettingsKey.refineEnabled: true,    // 漢字の取り違えだけを補正（言い換えはしない）
            SettingsKey.refineProvider: RefineProvider.ollama.rawValue,
            SettingsKey.refineMode: RefineMode.strict.rawValue,
            SettingsKey.ollamaModel: "qwen2.5:3b",
            SettingsKey.ollamaBaseURL: "http://localhost:11434",
            SettingsKey.deepseekModel: "deepseek-chat",
            SettingsKey.deepseekBaseURL: "https://api.deepseek.com",
            SettingsKey.whisperModel: WhisperModelKind.largeV3Turbo.rawValue,
            SettingsKey.hotkey: HotkeyKind.rightOption.rawValue,
            SettingsKey.restoreClipboard: true,
            SettingsKey.language: "ja",
            SettingsKey.initialPrompt: defaultInitialPrompt
        ])
    }

    static var refineEnabled: Bool { d.bool(forKey: SettingsKey.refineEnabled) }

    static var refineProvider: RefineProvider {
        // 環境変数による上書きを許可（テスト用）。
        if let env = ProcessInfo.processInfo.environment["KOE_REFINE_PROVIDER"],
           let p = RefineProvider(rawValue: env) {
            return p
        }
        return RefineProvider(rawValue: d.string(forKey: SettingsKey.refineProvider) ?? "") ?? .ollama
    }

    static var refineMode: RefineMode {
        // 環境変数による上書きを許可（テスト用）。
        if let env = ProcessInfo.processInfo.environment["KOE_REFINE_MODE"],
           let m = RefineMode(rawValue: env) {
            return m
        }
        return RefineMode(rawValue: d.string(forKey: SettingsKey.refineMode) ?? "") ?? .strict
    }

    static var ollamaModel: String { d.string(forKey: SettingsKey.ollamaModel) ?? "qwen2.5:3b" }

    static var ollamaBaseURL: URL {
        // 環境変数による上書きを許可（テスト用）。
        if let env = ProcessInfo.processInfo.environment["KOE_OLLAMA_URL"], let u = URL(string: env) {
            return u
        }
        let s = d.string(forKey: SettingsKey.ollamaBaseURL) ?? "http://localhost:11434"
        return URL(string: s) ?? URL(string: "http://localhost:11434")!
    }

    static var deepseekModel: String { d.string(forKey: SettingsKey.deepseekModel) ?? "deepseek-chat" }

    static var deepseekBaseURL: URL {
        let s = d.string(forKey: SettingsKey.deepseekBaseURL) ?? "https://api.deepseek.com"
        return URL(string: s) ?? URL(string: "https://api.deepseek.com")!
    }

    // API キーは Keychain 保管。環境変数 KOE_DEEPSEEK_KEY による上書きを許可（テスト用）。
    static var deepseekAPIKey: String {
        if let env = ProcessInfo.processInfo.environment["KOE_DEEPSEEK_KEY"], !env.isEmpty {
            return env
        }
        return Keychain.get(account: deepseekKeyAccount) ?? ""
    }

    static var whisperModel: WhisperModelKind {
        WhisperModelKind(rawValue: d.string(forKey: SettingsKey.whisperModel) ?? "") ?? .largeV3Turbo
    }

    // 実発話とみなす最小 RMS（音量）。これ未満の入力は無音・極小音量とみなし、
    // 文字起こし自体を行わない。無音時に Whisper が「ご視聴ありがとうございました」等の
    // 定型句を幻覚（学習データ由来の作文）する問題への対策。
    // 閾値は実ログ分析に基づく（正常発話の rms 下限 ≈ 0.004、幻覚は rms ≤ 0.003）。
    // 環境変数 KOE_MIN_RMS で上書き可能（マイクのゲインや環境ノイズに応じて調整）。
    static var minSpeechRMS: Float {
        if let s = ProcessInfo.processInfo.environment["KOE_MIN_RMS"], let v = Float(s) { return v }
        return 0.0035
    }

    static var initialPrompt: String {
        d.string(forKey: SettingsKey.initialPrompt) ?? defaultInitialPrompt
    }

    static var hotkey: HotkeyKind {
        HotkeyKind(rawValue: d.string(forKey: SettingsKey.hotkey) ?? "") ?? .rightOption
    }

    static var restoreClipboard: Bool { d.bool(forKey: SettingsKey.restoreClipboard) }
    static var language: String { d.string(forKey: SettingsKey.language) ?? "ja" }
}

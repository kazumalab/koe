import SwiftUI

// 設定画面。@AppStorage で UserDefaults を直接束縛する（Settings 列挙と同じキー）。
struct SettingsView: View {
    @EnvironmentObject var controller: AppController

    @AppStorage(SettingsKey.whisperModel) private var whisperModel = WhisperModelKind.small.rawValue
    @AppStorage(SettingsKey.refineEnabled) private var refineEnabled = true
    @AppStorage(SettingsKey.refineProvider) private var refineProvider = RefineProvider.ollama.rawValue
    @AppStorage(SettingsKey.refineMode) private var refineMode = RefineMode.strict.rawValue
    @AppStorage(SettingsKey.ollamaModel) private var ollamaModel = "qwen2.5:3b"
    @AppStorage(SettingsKey.ollamaBaseURL) private var ollamaBaseURL = "http://localhost:11434"
    @AppStorage(SettingsKey.deepseekModel) private var deepseekModel = "deepseek-chat"
    @AppStorage(SettingsKey.deepseekBaseURL) private var deepseekBaseURL = "https://api.deepseek.com"
    @AppStorage(SettingsKey.geminiModel) private var geminiModel = "gemini-2.5-flash"
    @AppStorage(SettingsKey.geminiBaseURL) private var geminiBaseURL = "https://generativelanguage.googleapis.com"
    @AppStorage(SettingsKey.refineCustomSystemPrompt) private var refineCustomSystemPrompt = defaultCustomSystemPrompt
    @AppStorage(SettingsKey.hotkey) private var hotkey = HotkeyKind.rightOption.rawValue
    @AppStorage(SettingsKey.restoreClipboard) private var restoreClipboard = true
    @AppStorage(SettingsKey.initialPrompt) private var initialPrompt = defaultInitialPrompt

    // API キーは Keychain 保管（UserDefaults に置かない）。画面では State で扱い、変更時に Keychain へ書く。
    @State private var deepseekAPIKey = ""
    @State private var geminiAPIKey = ""

    var body: some View {
        TabView {
            recognitionTab.tabItem { Label("認識", systemImage: "waveform") }
            refineTab.tabItem { Label("整形", systemImage: "sparkles") }
            generalTab.tabItem { Label("操作", systemImage: "keyboard") }
            permissionsTab.tabItem { Label("権限", systemImage: "lock.shield") }
        }
        .frame(width: 480, height: 480)
        .padding()
    }

    // MARK: 認識（Whisper）

    private var recognitionTab: some View {
        Form {
            Picker("Whisper モデル", selection: $whisperModel) {
                ForEach(WhisperModelKind.allCases) { m in
                    Text(m.displayName).tag(m.rawValue)
                }
            }
            .onChange(of: whisperModel) { _, _ in
                controller.ensureModelAvailable()
            }

            if let p = controller.downloadProgress {
                ProgressView(value: p) { Text("モデルをダウンロード中… \(Int(p * 100))%") }
            } else {
                HStack {
                    Image(systemName: controller.modelReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(controller.modelReady ? .green : .orange)
                    Text(controller.modelReady ? "モデルは利用可能です" : "モデル未取得（自動でダウンロードします）")
                    Spacer()
                    Button("再確認") { controller.ensureModelAvailable() }
                }
            }
            Text("モデルの変更はアプリの再起動後に反映されます。").font(.caption).foregroundStyle(.secondary)

            Divider()

            Text("語彙ヒント（専門用語の認識を補助）").font(.subheadline)
            TextEditor(text: $initialPrompt)
                .font(.system(size: 12))
                .frame(height: 70)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.secondary.opacity(0.3)))
            HStack {
                Spacer()
                Button("既定に戻す") { initialPrompt = defaultInitialPrompt }
            }
            Text("よく使う固有名詞・専門用語を列挙すると、その語に認識が寄ります。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding()
    }

    // MARK: 整形（Ollama / DeepSeek / Gemini）

    private var refineTab: some View {
        Form {
            Toggle("漢字の取り違えだけ補正する（言い換えはしない）", isOn: $refineEnabled)

            // プロバイダ・モードはともに 3 択になったので menu スタイルに統一（segmented は窮屈）。
            Picker("補正エンジン", selection: $refineProvider) {
                Text("Ollama（ローカル・オフライン）").tag(RefineProvider.ollama.rawValue)
                Text("DeepSeek（API・高精度）").tag(RefineProvider.deepseek.rawValue)
                Text("Gemini（API・軽量低コスト）").tag(RefineProvider.gemini.rawValue)
            }
            .pickerStyle(.menu)
            .disabled(!refineEnabled)

            Picker("補正の強さ", selection: $refineMode) {
                Text("厳密（漢字のみ）").tag(RefineMode.strict.rawValue)
                Text("自然化（カタカナ→英字）").tag(RefineMode.natural.rawValue)
                Text("カスタム（自由プロンプト）").tag(RefineMode.custom.rawValue)
            }
            .pickerStyle(.menu)
            .disabled(!refineEnabled)

            if refineMode == RefineMode.natural.rawValue {
                Text("自然化: 「ディープシーク→DeepSeek」のように、確立した英語の固有名詞・製品名・略語をカタカナから英字表記に直します。言い換え・要約はしません（読みガードは外れ、長さガードで暴走を抑えます）。")
                    .font(.caption).foregroundStyle(.secondary)
            } else if refineMode == RefineMode.custom.rawValue {
                Text("カスタム: 下のシステムプロンプトをそのまま LLM に渡します。few-shot・語彙ヒント・読みガード・長さガードは適用しません。「入力をそのまま返す」プロンプトを書けば校正なし運用にもできます。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("厳密: 同音異義語の漢字ミス（例: 保管→補完）だけを直します。読みが変わる修正は破棄します（最も安全）。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Divider()

            if refineMode == RefineMode.custom.rawValue {
                Text("システムプロンプト（カスタムモード）").font(.subheadline)
                TextEditor(text: $refineCustomSystemPrompt)
                    .font(.system(size: 12))
                    .frame(height: 90)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.secondary.opacity(0.3)))
                HStack {
                    Spacer()
                    Button("既定に戻す") { refineCustomSystemPrompt = defaultCustomSystemPrompt }
                }
                Text("例:「入力テキストをそのまま返してください。」と書けば、文字起こし結果をそのまま挿入します。「箇条書きに変換してください」のような自由な指示も可能です。")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
            }

            if refineProvider == RefineProvider.deepseek.rawValue {
                deepseekFields
            } else if refineProvider == RefineProvider.gemini.rawValue {
                geminiFields
            } else {
                ollamaFields
            }
        }
        .padding()
        .onAppear {
            deepseekAPIKey = Keychain.get(account: deepseekKeyAccount) ?? ""
            geminiAPIKey   = Keychain.get(account: geminiKeyAccount) ?? ""
        }
    }

    private var ollamaFields: some View {
        Group {
            TextField("Ollama モデル名", text: $ollamaModel)
                .textFieldStyle(.roundedBorder)
            TextField("Ollama サーバ URL", text: $ollamaBaseURL)
                .textFieldStyle(.roundedBorder)
            Text("Ollama が未起動・接続失敗のときは、補正せず文字起こし結果をそのまま使います。")
                .font(.caption).foregroundStyle(.secondary)
            Text("導入例: brew install ollama → ollama serve → ollama pull \(ollamaModel)")
                .font(.caption).foregroundStyle(.secondary)
        }
        .disabled(!refineEnabled)
    }

    private var deepseekFields: some View {
        Group {
            SecureField("DeepSeek API キー", text: $deepseekAPIKey)
                .textFieldStyle(.roundedBorder)
                .onChange(of: deepseekAPIKey) { _, new in
                    Keychain.set(new.trimmingCharacters(in: .whitespacesAndNewlines),
                                 account: deepseekKeyAccount)
                }
            TextField("DeepSeek モデル名", text: $deepseekModel)
                .textFieldStyle(.roundedBorder)
            TextField("DeepSeek API URL", text: $deepseekBaseURL)
                .textFieldStyle(.roundedBorder)
            Label("DeepSeek 選択時は、文字起こしテキストが外部（DeepSeek サーバ）へ送信されます。完全オフラインではありません。",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
            Text("API キーは macOS Keychain に保存します。キーは https://platform.deepseek.com で取得できます。")
                .font(.caption).foregroundStyle(.secondary)
            Text("キー未設定・接続失敗のときは、補正せず文字起こし結果をそのまま使います。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .disabled(!refineEnabled)
    }

    private var geminiFields: some View {
        Group {
            SecureField("Gemini API キー", text: $geminiAPIKey)
                .textFieldStyle(.roundedBorder)
                .onChange(of: geminiAPIKey) { _, new in
                    Keychain.set(new.trimmingCharacters(in: .whitespacesAndNewlines),
                                 account: geminiKeyAccount)
                }
            TextField("Gemini モデル名", text: $geminiModel)
                .textFieldStyle(.roundedBorder)
            TextField("Gemini API URL", text: $geminiBaseURL)
                .textFieldStyle(.roundedBorder)
            Label("Gemini 選択時は、文字起こしテキストが外部（Google サーバ）へ送信されます。完全オフラインではありません。",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
            Text("API キーは macOS Keychain に保存します。キーは https://aistudio.google.com/app/apikey で取得できます。\"gemini-2.5-flash\" は低コスト・高速モデルです。")
                .font(.caption).foregroundStyle(.secondary)
            Text("キー未設定・接続失敗のときは、補正せず文字起こし結果をそのまま使います。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .disabled(!refineEnabled)
    }

    // MARK: 操作（ホットキー）

    private var generalTab: some View {
        Form {
            Picker("録音ホットキー（押している間だけ録音）", selection: $hotkey) {
                ForEach(HotkeyKind.allCases) { k in
                    Text(k.displayName).tag(k.rawValue)
                }
            }
            .onChange(of: hotkey) { _, _ in
                controller.reloadHotkey()
            }
            Toggle("貼り付け後にクリップボードを復元する", isOn: $restoreClipboard)
            Text("ホットキーを押している間に話し、離すと整形済みテキストが現在の入力欄に挿入されます。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding()
    }

    // MARK: 権限

    private var permissionsTab: some View {
        Form {
            permissionRow("マイク", granted: controller.micGranted) {
                Permissions.openPrivacyPane(.microphone)
            }
            permissionRow("入力監視（ホットキー）", granted: controller.inputMonitoringGranted) {
                Permissions.openPrivacyPane(.inputMonitoring)
            }
            permissionRow("アクセシビリティ（貼り付け）", granted: controller.accessibilityGranted) {
                Permissions.openPrivacyPane(.accessibility)
            }
            Button("すべての許可をまとめて要求") { controller.requestAllPermissions() }
            Text("入力監視を新しく許可した場合は、アプリの再起動が必要なことがあります。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding()
    }

    private func permissionRow(_ title: String, granted: Bool, open: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(granted ? .green : .red)
            Text(title)
            Spacer()
            Button(granted ? "設定を開く" : "許可する") { open() }
        }
    }
}

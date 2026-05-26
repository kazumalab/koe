import Foundation
import AppKit
import SwiftUI

// アプリの状態。メニューバーアイコンや挙動の分岐に使う。
enum AppState: Equatable {
    case idle              // 待機
    case recording         // 録音中
    case transcribing      // 文字起こし中
    case refining          // LLM 整形中
    case error(String)     // エラー
}

// 各部品を束ねる中心。状態を持ち、録音→文字起こし→整形→挿入の一本道を駆動する。
@MainActor
final class AppController: ObservableObject {
    @Published var state: AppState = .idle
    @Published var lastResult: String = ""
    @Published var downloadProgress: Double? = nil   // nil=非DL中, 0..1=進捗
    private var lastLoggedPct = -1

    // 権限状態（メニュー/設定の表示用。読むたびに最新を返す）
    var micGranted: Bool { Permissions.microphoneGranted }
    var inputMonitoringGranted: Bool { Permissions.inputMonitoringGranted }
    var accessibilityGranted: Bool { Permissions.accessibilityGranted }
    var modelReady: Bool { ModelDownloader.isAvailable(model) }

    private let recorder = AudioRecorder()
    private let hotkey = HotkeyManager(kind: .rightOption)
    private var transcriber: WhisperTranscriber?
    private var model: WhisperModelKind { Settings.whisperModel }

    private let overlay = OverlayController()
    private var levelTimer: Timer?
    private var recordStart: Date?

    // 状態遷移を一元化し、オーバーレイHUDの表示も連動させる。
    private func transition(_ newState: AppState) {
        state = newState
        switch newState {
        case .idle:
            overlay.hide()
        case .recording:
            overlay.show(state: .recording)
        case .transcribing, .refining, .error:
            overlay.update(state: newState)
        }
    }

    var menuBarSymbol: String {
        switch state {
        case .idle:          return "mic"
        case .recording:     return "mic.fill"
        case .transcribing:  return "waveform"
        case .refining:      return "sparkles"
        case .error:         return "exclamationmark.triangle"
        }
    }

    var statusText: String {
        switch state {
        case .idle:          return "待機中"
        case .recording:     return "録音中…"
        case .transcribing:  return "文字起こし中…"
        case .refining:      return "整形中…"
        case .error(let m):  return "エラー: \(m)"
        }
    }

    func start() {
        // 1) マイク許可を要求
        Permissions.requestMicrophone { granted in
            log(granted ? "マイク許可: OK"
                        : "マイク許可: 未許可。システム設定 > プライバシー > マイク で Koe を許可してください")
        }

        // 2) 入力監視許可（ホットキー用）
        if !Permissions.inputMonitoringGranted {
            log("入力監視が未許可です。許可ダイアログを表示します")
            Permissions.requestInputMonitoring()
        }

        // 3) ホットキー配線（設定のキー種別を反映）
        hotkey.updateKind(Settings.hotkey)
        hotkey.onPressStart = { [weak self] in
            MainActor.assumeIsolated { self?.beginRecording() }
        }
        hotkey.onPressEnd = { [weak self] in
            MainActor.assumeIsolated { self?.endRecording() }
        }
        if !hotkey.startMonitoring() {
            log("ホットキーを開始できませんでした。システム設定 > プライバシー > 入力監視 で Koe を許可後、再起動してください")
            Permissions.openPrivacyPane(.inputMonitoring)
        }

        // 4) モデルの存在確認（無ければダウンロード）
        ensureModelAvailable()

        // 診断用セルフテスト
        runSelfTestsIfRequested()
    }

    func shutdown() {
        hotkey.stopMonitoring()
        log("終了")
    }

    // MARK: モデル

    func ensureModelAvailable() {
        let target = model
        if ModelDownloader.isAvailable(target) {
            log("モデル確認: \(target.rawValue) は利用可能")
            return
        }
        guard downloadProgress == nil else { return }   // 二重DL防止
        log("モデル未検出。\(target.displayName) をダウンロードします…")
        downloadProgress = 0
        lastLoggedPct = -1
        ModelDownloader.ensureAvailable(target, progress: { p in
            Task { @MainActor in
                self.downloadProgress = p
                let pct = Int(p * 100)
                if pct / 10 != self.lastLoggedPct / 10 {
                    self.lastLoggedPct = pct
                    log(String(format: "モデルDL: %d%%", pct))
                }
            }
        }, completion: { result in
            Task { @MainActor in self.downloadProgress = nil }
            switch result {
            case .success(let url): log("モデルDL完了: \(url.path)")
            case .failure(let e):   log("モデルDL失敗: \(e)")
            }
        })
    }

    // 設定変更後にホットキー監視を再構成する。
    func reloadHotkey() {
        hotkey.updateKind(Settings.hotkey)
        log("ホットキーを再設定: \(Settings.hotkey.displayName)")
    }

    // 全権限の要求（設定UIのボタンから）
    func requestAllPermissions() {
        Permissions.requestMicrophone { _ in }
        Permissions.requestInputMonitoring()
        Permissions.requestAccessibility(prompt: true)
    }

    // モデルが読み込み済みの WhisperTranscriber を返す（初回はここで読み込む）。
    private func transcriberIfReady() -> WhisperTranscriber? {
        if let transcriber { return transcriber }
        guard ModelDownloader.isAvailable(model) else {
            log("文字起こし不可: モデル未取得（\(model.rawValue)）")
            return nil
        }
        do {
            let t = try WhisperTranscriber(modelPath: ModelDownloader.localURL(for: model).path)
            transcriber = t
            log("モデル読み込み完了: \(model.rawValue)")
            return t
        } catch {
            log("モデル読み込み失敗: \(error)")
            return nil
        }
    }

    // MARK: 録音 → 文字起こしフロー

    private func beginRecording() {
        guard state == .idle else { return }
        guard Permissions.microphoneGranted else {
            log("録音不可: マイク未許可"); showErrorBriefly("マイク未許可"); return
        }
        do {
            try recorder.start()
            recordStart = Date()
            transition(.recording)
            startLevelTimer()
            log("録音開始")
        } catch {
            log("録音開始失敗: \(error)"); showErrorBriefly("\(error)")
        }
    }

    private func endRecording() {
        guard state == .recording else { return }
        stopLevelTimer()
        let samples = recorder.stop()
        let seconds = Double(samples.count) / AudioRecorder.targetSampleRate
        // 診断: 実際に録音された音声のレベル（peak/rms）を出し、WAV も保存する。
        let peak = samples.reduce(Float(0)) { Swift.max($0, abs($1)) }
        let rms = (samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(Swift.max(1, samples.count))).squareRoot()
        log(String(format: "録音停止: %d サンプル (約 %.1f 秒) peak=%.3f rms=%.3f",
                   samples.count, seconds, peak, rms))
        if ProcessInfo.processInfo.environment["KOE_DUMP_AUDIO"] == "1" {
            WavWriter.write(samples, to: URL(fileURLWithPath: "/tmp/koe_last.wav"))
            log("録音音声を /tmp/koe_last.wav に保存しました")
        }
        guard samples.count > 1600 else {   // 0.1 秒未満は無視
            log("音声が短すぎます。スキップします"); transition(.idle); return
        }
        process(samples: samples, peak: peak, rms: rms, seconds: seconds)
    }

    // 録音中、波形と経過時間を定期更新する（メインのランループ上で発火）。
    private func startLevelTimer() {
        levelTimer?.invalidate()
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.overlay.pushLevel(self.recorder.currentLevel)
                if let s = self.recordStart { self.overlay.setElapsed(Date().timeIntervalSince(s)) }
            }
        }
    }

    private func stopLevelTimer() {
        levelTimer?.invalidate()
        levelTimer = nil
    }

    // エラーを一瞬HUDに出してから消す。
    private func showErrorBriefly(_ message: String) {
        transition(.error(message))
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if case .error = self.state { self.transition(.idle) }
            }
        }
    }

    // 文字起こし → LLM 整形 → 挿入 →（検証用に JSONL ログ記録）
    private func process(samples: [Float], peak: Float, rms: Float, seconds: Double) {
        guard let t = transcriberIfReady() else { transition(.idle); return }
        transition(.transcribing)
        Task { [weak self] in
            guard let self else { return }
            do {
                let raw = try await t.transcribe(samples: samples,
                                                 language: Settings.language,
                                                 initialPrompt: Settings.initialPrompt)
                log("文字起こし: \(raw)")
                guard !raw.isEmpty else { self.transition(.idle); return }

                let outcome = await self.refineIfEnabled(raw)
                let finalText = outcome.finalText
                log("最終テキスト: \(finalText)")
                self.lastResult = finalText

                let injectResult = TextInjector.insert(finalText, restoreClipboard: Settings.restoreClipboard)
                let injectStr: String
                switch injectResult {
                case .pasted:     injectStr = "pasted"; log("挿入完了")
                case .copiedOnly: injectStr = "copied";  log("クリップボードにコピー（貼り付けにはアクセシビリティ許可が必要）")
                }

                SessionLogger.record([
                    "durationSec": (seconds * 10).rounded() / 10,
                    "samples": samples.count,
                    "peak": (Double(peak) * 1000).rounded() / 1000,
                    "rms": (Double(rms) * 1000).rounded() / 1000,
                    "whisperModel": self.model.rawValue,
                    "refineEnabled": Settings.refineEnabled,
                    "refineProvider": Settings.refineProvider.rawValue,
                    "refineMode": Settings.refineMode.rawValue,
                    "ollamaModel": Settings.ollamaModel,
                    "deepseekModel": Settings.deepseekModel,
                    "geminiModel": Settings.geminiModel,
                    "raw": raw,
                    "proposed": outcome.proposed ?? NSNull(),
                    "accepted": outcome.accepted,
                    "reason": outcome.reason,
                    "final": finalText,
                    "changed": (finalText != raw),
                    "inject": injectStr
                ])
                self.transition(.idle)
            } catch {
                log("文字起こし失敗: \(error)")
                self.showErrorBriefly("\(error)")
            }
        }
    }

    // 設定が有効なら整形する（Ollama / DeepSeek / Gemini）。無効・失敗時は生テキストを返す。
    private func refineIfEnabled(_ raw: String) async -> RefineOutcome {
        guard Settings.refineEnabled else {
            log("整形は無効。生の文字起こしを使用")
            return RefineOutcome(finalText: raw, proposed: nil, accepted: false, reason: "disabled")
        }
        transition(.refining)
        let mode = Settings.refineMode
        // 同音異義語の判別を分野に寄せるため、Whisper 用の語彙ヒントを整形にも渡す。
        // ただし custom モードはユーザーが書いた system prompt をそのまま使う前提なので渡さない（プロンプトを汚さない）。
        let hint = (mode == .custom) ? "" : Settings.initialPrompt
        let customPrompt = Settings.refineCustomSystemPrompt
        let outcome: RefineOutcome
        switch Settings.refineProvider {
        case .deepseek:
            log("整形開始（DeepSeek: \(Settings.deepseekModel) / \(mode.rawValue)）")
            let client = DeepSeekClient(apiKey: Settings.deepseekAPIKey,
                                        model: Settings.deepseekModel,
                                        baseURL: Settings.deepseekBaseURL,
                                        domainHint: hint,
                                        mode: mode,
                                        customSystemPrompt: customPrompt)
            outcome = await client.refine(raw)
        case .gemini:
            log("整形開始（Gemini: \(Settings.geminiModel) / \(mode.rawValue)）")
            let client = GeminiClient(apiKey: Settings.geminiAPIKey,
                                      model: Settings.geminiModel,
                                      baseURL: Settings.geminiBaseURL,
                                      domainHint: hint,
                                      mode: mode,
                                      customSystemPrompt: customPrompt)
            outcome = await client.refine(raw)
        case .ollama:
            log("整形開始（Ollama: \(Settings.ollamaModel) / \(mode.rawValue)）")
            let client = OllamaClient(baseURL: Settings.ollamaBaseURL,
                                      model: Settings.ollamaModel,
                                      domainHint: hint,
                                      mode: mode,
                                      customSystemPrompt: customPrompt)
            outcome = await client.refine(raw)
        }
        if outcome.accepted { log("整形前: \(raw)") }
        return outcome
    }

    // MARK: 診断用セルフテスト

    private func runSelfTestsIfRequested() {
        let env = ProcessInfo.processInfo.environment
        if env["KOE_RENDER_OVERLAY"] == "1" {
            renderOverlayImages()
            return
        }
        if let which = env["KOE_OVERLAY_TEST"] {
            runOverlayTest(which)
            return
        }
        if let text = env["KOE_INSERT_TEST"] {
            log("挿入テスト: クリップボード設定を確認します")
            _ = TextInjector.insert(text, restoreClipboard: false)
            let got = NSPasteboard.general.string(forType: .string) ?? "(nil)"
            log("クリップボード内容: \(got)")
            log(got == text ? "挿入テスト: クリップボード一致 OK" : "挿入テスト: 不一致")
            terminateIfSelfTest()
            return
        }
        if let path = env["KOE_TRANSCRIBE_FILE"] {
            runTranscribeFileTest(path: path)
        } else if env["KOE_SELFTEST"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                MainActor.assumeIsolated { self?.runRecordTest() }
            }
        }
    }

    // 入力監視・キー操作に依存せず録音パイプラインを検証する。
    private func runRecordTest() {
        log("セルフテスト: 3秒間録音してサンプル数を確認します")
        beginRecording()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            MainActor.assumeIsolated {
                self?.endRecording()
                if ProcessInfo.processInfo.environment["KOE_SELFTEST_EXIT"] == "1" {
                    // 文字起こしの完了を待ってから終了する余地を持たせる
                    DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                        NSApplication.shared.terminate(nil)
                    }
                }
            }
        }
    }

    // 指定した音声ファイルを文字起こしして結果をログ出力する。
    private func runTranscribeFileTest(path: String) {
        log("ファイル文字起こしテスト: \(path)")
        Task { [weak self] in
            guard let self else { return }
            do {
                let samples = try AudioFileLoader.loadSamples16kMono(url: URL(fileURLWithPath: path))
                log(String(format: "読み込み: %d サンプル (約 %.1f 秒)",
                           samples.count, Double(samples.count) / 16_000))
                guard let t = self.transcriberIfReady() else {
                    self.terminateIfSelfTest(); return
                }
                let raw = try await t.transcribe(samples: samples,
                                                 language: Settings.language,
                                                 initialPrompt: Settings.initialPrompt)
                log("文字起こし結果: \(raw)")
                let finalText = await self.refineIfEnabled(raw).finalText
                log("最終テキスト: \(finalText)")
                self.lastResult = finalText
            } catch {
                log("テスト失敗: \(error)")
            }
            self.terminateIfSelfTest()
        }
    }

    // オーバーレイHUDをオフスクリーンで画像化して保存する（画面収録権限が不要な見た目確認）。
    private func renderOverlayImages() {
        let dir = "/tmp/koe_overlay"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let cases: [(String, AppState, [CGFloat])] = [
            ("recording", .recording, Self.sampleLevels()),
            ("transcribing", .transcribing, []),
            ("refining", .refining, [])
        ]
        for (name, st, levels) in cases {
            let m = OverlayModel()
            m.state = st
            if !levels.isEmpty { m.levels = levels; m.elapsed = 3 }

            // 画面（壁紙の上）に出た見え方に近づけるため、灰色の背景に重ねて描画する。
            let content = ZStack {
                Color(white: 0.28)
                OverlayView().environmentObject(m).frame(width: 300, height: 64)
            }
            .frame(width: 340, height: 108)

            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            if let img = renderer.nsImage,
               let tiff = img.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
                log("レンダリング: \(dir)/\(name).png")
            } else {
                log("レンダリング失敗: \(name)")
            }
        }
        terminateIfSelfTest()
    }

    // 波形プレビュー用のサンプル音量パターン。
    private static func sampleLevels() -> [CGFloat] {
        (0..<OverlayModel.barCount).map { i in
            let x = Double(i) / Double(OverlayModel.barCount)
            let v = 0.35 + 0.5 * abs(sin(x * .pi * 3)) * (0.5 + 0.5 * sin(x * .pi * 7))
            return CGFloat(min(1, max(0.08, v)))
        }
    }

    // オーバーレイHUDの見た目を確認するための表示テスト（録音/文字起こし/整形）。
    private var testPhase = 0.0
    private func runOverlayTest(_ which: String) {
        let s: AppState
        switch which {
        case "transcribing": s = .transcribing
        case "refining":     s = .refining
        default:             s = .recording
        }
        log("オーバーレイ表示テスト: \(which)")
        overlay.show(state: s)
        if case .recording = s {
            recordStart = Date()
            levelTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.testPhase += 0.35
                    let base = 0.55 + 0.4 * sin(self.testPhase)
                    let v = Float(base) * Float.random(in: 0.55...1.0)
                    self.overlay.pushLevel(v)
                    if let st = self.recordStart { self.overlay.setElapsed(Date().timeIntervalSince(st)) }
                }
            }
        }
    }

    private func terminateIfSelfTest() {
        if ProcessInfo.processInfo.environment["KOE_SELFTEST_EXIT"] == "1" {
            NSApplication.shared.terminate(nil)
        }
    }
}

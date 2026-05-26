# Koe — LLM補完つきオフライン音声入力（macOS）

「Typeless」のような、どこでも使える音声入力ツール。グローバルなホットキーを押している間だけ録音し、離すと **ローカルの Whisper** で文字起こし、**LLM** で誤認識補正・整形を行い、整形済みテキストを **いま入力中のアプリのカーソル位置に自動挿入** します。整形バックエンドは **ローカルの Ollama（既定・完全オフライン）**、**DeepSeek API（高精度・要 API キー）**、**Gemini API（軽量低コスト・要 API キー）** から選べます。

> 既定（Ollama）では音声・テキストを一切外部送信しません（完全オフライン。整形は Ollama 未導入時は自動でスキップ）。**DeepSeek または Gemini を選んだ場合のみ、文字起こしテキストが外部 API へ送信されます**（音声は送信しません）。

- 音声認識: whisper.cpp（v1.7.6 を静的リンク、Apple Silicon / Metal）
- 整形（いずれか）: Ollama（`http://localhost:11434`、ローカル・既定）/ DeepSeek（`https://api.deepseek.com`、API・高精度）/ Gemini（`https://generativelanguage.googleapis.com`、API・軽量低コスト）
- 形態: メニューバー常駐 + push-to-talk（既定は右Option 長押し）

## 必要環境

- Apple Silicon Mac（arm64）、macOS 14 以降
- Xcode（Swift 6 系）

## ビルド

初回のみ whisper.cpp の静的ライブラリを用意します（cmake は `./scripts/build-whisper.sh` が `.tools/` のローカル版を使用、ソースは `third_party/whisper.cpp`）。

    cd koe
    ./scripts/build-whisper.sh     # 数分。Vendor/whisper/lib に .a を生成
    make                           # build/Koe.app を生成（ad-hoc 署名）
    open build/Koe.app             # 起動（ログを見るなら make run）

## セットアップ

1. メニューバーのアイコン → 各権限を許可：
   - マイク（録音）
   - 入力監視（ホットキー検知）※許可後はアプリを再起動
   - アクセシビリティ（⌘V 貼り付け）
2. Whisper モデルは初回起動時に `ggml-small.bin`（約466MB）を自動ダウンロード（`~/Library/Application Support/Koe/models/`）。手動なら `./scripts/download-model.sh small`。
3. 整形（推奨）：設定の「整形」タブで補正エンジンを選びます。

   - **Ollama（ローカル・既定）**: 完全オフライン。導入・起動してモデルを取得。

         brew install ollama
         ollama serve            # 別ターミナルで常駐
         ollama pull qwen2.5:3b  # 設定の「整形」タブのモデル名と合わせる

   - **DeepSeek（API・高精度）**: 同音異義語の判別が高精度。[platform.deepseek.com](https://platform.deepseek.com) で API キーを取得し、「整形」タブの「DeepSeek」を選んでキーを入力（macOS Keychain に保存）。既定モデルは `deepseek-chat`。**文字起こしテキストが外部送信される**点に注意。

   - **Gemini（API・軽量低コスト）**: [Google AI Studio](https://aistudio.google.com/app/apikey) で API キーを取得し、「整形」タブの「Gemini」を選んでキーを入力（macOS Keychain に保存）。既定モデルは `gemini-2.5-flash`。**文字起こしテキストが外部送信される**点に注意。

4. 補正の強さは「厳密（漢字のみ）」「自然化（カタカナ→英字）」「カスタム（自由プロンプト）」から選べます。カスタムでは設定画面のシステムプロンプトをそのまま LLM に渡し、few-shot・語彙ヒント・読みガード・長さガードは適用しません。

## 使い方

テキスト入力欄にカーソルを置き、**右Option を押しながら話して離す**。数秒後、整形済みテキストが挿入されます。設定（メニュー → 設定…）でモデル・ホットキー・整形ON/OFF・補正エンジン・API 接続先を変更できます。

## 動作の仕組み

`HotkeyManager`(CGEvent) → `AudioRecorder`(16kHz/mono) → `WhisperTranscriber`(whisper.cpp) → `OllamaClient`/`DeepSeekClient`/`GeminiClient` → `TextInjector`(クリップボード＋⌘V)。詳細と設計判断は [`plans/2026-05-25-voice-input-mac-app/ExecPlan.md`](plans/2026-05-25-voice-input-mac-app/ExecPlan.md) を参照。

## 自己テスト（headless）

    KOE_SELFTEST=1 KOE_SELFTEST_EXIT=1 ./build/Koe.app/Contents/MacOS/Koe          # 3秒録音→サンプル数
    say -v Kyoko -o /tmp/t.aiff "今日はいい天気です"
    KOE_TRANSCRIBE_FILE=/tmp/t.aiff KOE_SELFTEST_EXIT=1 ./build/Koe.app/Contents/MacOS/Koe  # 文字起こし＋整形
    KOE_INSERT_TEST="テスト" KOE_SELFTEST_EXIT=1 ./build/Koe.app/Contents/MacOS/Koe          # クリップボード挿入

## コントリビュート

不具合報告・機能提案・プルリクエストを歓迎します。大きな変更を行う場合は、先に Issue で相談いただけると円滑です。設計の背景は `plans/2026-05-25-voice-input-mac-app/ExecPlan.md` を参照してください。

## ライセンス

[MIT License](LICENSE) で配布します。Copyright (c) 2026 kazumalab。

## 謝辞・サードパーティ

本アプリは [whisper.cpp](https://github.com/ggml-org/whisper.cpp)（MIT）と [ggml](https://github.com/ggml-org/ggml)（MIT）を静的リンクし、ローカル整形に [Ollama](https://github.com/ollama/ollama)（MIT、任意・実行時）を利用します。Whisper のモデル重みは OpenAI 由来（MIT）です。各依存の詳細は [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) を参照してください。

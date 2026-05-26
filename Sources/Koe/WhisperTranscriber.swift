import Foundation
import CWhisper

// whisper.cpp を使い、16kHz・モノラルの PCM サンプルを日本語テキストへ変換する。
// actor にすることで、重い推論をメインスレッド外で直列に実行でき、
// 非 Sendable な whisper_context ポインタも安全に保持できる。
actor WhisperTranscriber {
    // deinit（非分離）から解放できるよう nonisolated(unsafe) で保持する。
    // ポインタは init 後は不変で、transcribe は actor が直列化するため安全。
    private nonisolated(unsafe) let ctx: OpaquePointer

    enum TranscribeError: Error, CustomStringConvertible {
        case initFailed(String)
        case inferenceFailed(Int32)
        var description: String {
            switch self {
            case .initFailed(let p):      return "Whisper モデルを読み込めませんでした: \(p)"
            case .inferenceFailed(let c): return "Whisper 推論に失敗しました (code=\(c))"
            }
        }
    }

    init(modelPath: String, flashAttn: Bool = true) throws {
        var cparams = whisper_context_default_params()
        cparams.use_gpu = true          // Metal を使う
        cparams.flash_attn = flashAttn  // Flash Attention（GPU 推論の高速化・省メモリ）
        guard let c = whisper_init_from_file_with_params(modelPath, cparams) else {
            throw TranscribeError.initFailed(modelPath)
        }
        ctx = c
    }

    deinit {
        whisper_free(ctx)
    }

    func transcribe(samples: [Float], language: String = "ja", initialPrompt: String = "") throws -> String {
        guard !samples.isEmpty else { return "" }

        whisper_reset_timings(ctx)   // 直前の計測値を消し、この発話の encode/decode 内訳だけを得る

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_realtime = false
        params.print_progress = false
        params.print_timestamps = false
        params.print_special = false
        params.translate = false
        params.no_context = true
        params.single_segment = false
        params.no_timestamps = true
        params.detect_language = false
        params.n_threads = Int32(max(1, ProcessInfo.processInfo.activeProcessorCount - 1))

        // language / initial_prompt ポインタは whisper_full 呼び出し中だけ有効であればよい。
        // 語彙ヒント（initial_prompt）はデコーダを専門用語へバイアスさせ、誤認識を減らす。
        let status: Int32 = language.withCString { langPtr -> Int32 in
            params.language = langPtr
            if initialPrompt.isEmpty {
                return samples.withUnsafeBufferPointer { buf in
                    whisper_full(ctx, params, buf.baseAddress, Int32(buf.count))
                }
            } else {
                return initialPrompt.withCString { promptPtr -> Int32 in
                    params.initial_prompt = promptPtr
                    return samples.withUnsafeBufferPointer { buf in
                        whisper_full(ctx, params, buf.baseAddress, Int32(buf.count))
                    }
                }
            }
        }
        guard status == 0 else { throw TranscribeError.inferenceFailed(status) }

        // encode/decode/sample の内訳を標準エラーへ出力（M2/M4 のボトルネック比較用）。
        whisper_print_timings(ctx)

        let n = whisper_full_n_segments(ctx)
        var text = ""
        for i in 0..<n {
            if let cstr = whisper_full_get_segment_text(ctx, i) {
                text += String(cString: cstr)
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

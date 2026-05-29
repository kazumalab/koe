import Foundation
import ApplicationServices

// 現在フォーカスされている UI 要素（テキスト入力欄など）の、
// カーソル位置の前後にある既存テキストを表す。
struct SurroundingContext {
    let prefix: String   // カーソル直前のテキスト（必要なら末尾 N 文字に切り詰め）
    let suffix: String   // カーソル直後のテキスト（必要なら先頭 N 文字に切り詰め）

    var isEmpty: Bool { prefix.isEmpty && suffix.isEmpty }
}

// アクセシビリティ API を使い、フォーカス中の入力欄から
// カーソル位置の前後テキストを取り出す。
// 取れない（フォーカス無し / テキスト型でない / 権限不足）場合は nil を返す。
enum ContextReader {

    // - maxPrefix: prefix の最大文字数。長い文章のときは末尾だけを採用する。
    // - maxSuffix: suffix の最大文字数。先頭だけを採用する。
    static func read(maxPrefix: Int = 200, maxSuffix: Int = 100) -> SurroundingContext? {
        guard Permissions.accessibilityGranted else { return nil }

        let systemElement = AXUIElementCreateSystemWide()

        // フォーカス中の UI 要素を取得。
        var focusedRef: CFTypeRef?
        let focusedErr = AXUIElementCopyAttributeValue(
            systemElement, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        guard focusedErr == .success, let focusedCF = focusedRef else { return nil }
        let focused = focusedCF as! AXUIElement

        // 要素のテキスト値（kAXValueAttribute）。テキスト入力欄なら String が返る。
        var valueRef: CFTypeRef?
        let valueErr = AXUIElementCopyAttributeValue(
            focused, kAXValueAttribute as CFString, &valueRef)
        guard valueErr == .success, let text = valueRef as? String else { return nil }

        // 選択範囲（カーソル位置）。range.location が caret 位置（UTF-16 単位）。
        // 取得できなかった場合は「全部 prefix（末尾にカーソル）」として扱う。
        let nsText = text as NSString
        var caret = nsText.length
        var rangeRef: CFTypeRef?
        let rangeErr = AXUIElementCopyAttributeValue(
            focused, kAXSelectedTextRangeAttribute as CFString, &rangeRef)
        if rangeErr == .success, let rangeCF = rangeRef {
            let axValue = rangeCF as! AXValue
            var cfRange = CFRange()
            if AXValueGetType(axValue) == .cfRange,
               AXValueGetValue(axValue, .cfRange, &cfRange) {
                caret = cfRange.location
            }
        }
        // AX の range は UTF-16 単位。NSString.length に対して clamp。
        let safeCaret = max(0, min(caret, nsText.length))
        let beforeNS = nsText.substring(to: safeCaret)
        let afterNS  = nsText.substring(from: safeCaret)

        // grapheme cluster 単位で末尾/先頭 N 文字に切り詰め（絵文字や合字を割らない）。
        let prefix = beforeNS.count > maxPrefix ? String(beforeNS.suffix(maxPrefix)) : beforeNS
        let suffix = afterNS.count  > maxSuffix ? String(afterNS.prefix(maxSuffix))  : afterNS

        return SurroundingContext(prefix: prefix, suffix: suffix)
    }
}

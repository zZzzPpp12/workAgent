import AppKit

enum AppClipboard {
    /// 使用同一个剪贴板实例完成写入，并把系统返回结果交给界面反馈。
    @MainActor
    static func write(_ text: String, to pasteboard: NSPasteboard = .general) -> Bool {
        guard !text.isEmpty else { return false }
        pasteboard.clearContents()
        return pasteboard.writeObjects([text as NSString])
    }
}

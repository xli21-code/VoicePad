import Foundation

/// How the text should be shaped for the app it is going into.
///
/// This is deliberately separate from `Branch` style. Tone is a preference and stays
/// hand-configured; shape is a property of the app — a terminal is a terminal for
/// everyone — so it is inferred, and a dictation into an unknown app gets the strict
/// default rather than a guess.
enum OutputContract: String, CaseIterable {
    /// Chat boxes: one thought, no structure, no markdown.
    case chat
    /// Notes and word processors: paragraphs are welcome, headings are not.
    case document
    /// Editors, terminals, commit messages: identifiers are sacred.
    case code
    /// Mail: complete sentences, no lists invented, no greeting invented.
    case email
    /// Anything unknown: the most conservative of the four.
    case neutral

    static func forApp(bundleID: String?) -> OutputContract {
        guard let id = bundleID?.lowercased() else { return .neutral }

        // Terminals and editors. Prefixes cover the families that ship many bundle ids.
        for prefix in ["com.apple.dt.xcode", "com.jetbrains.", "com.microsoft.vscode",
                       "com.apple.terminal", "com.googlecode.iterm2", "dev.warp.",
                       "com.sublimetext.", "com.microsoft.vscodeinsiders"] where id.hasPrefix(prefix) {
            return .code
        }
        // Chat.
        for prefix in ["com.tencent.xinwechat", "com.apple.mobilesms", "com.hnc.discord",
                       "com.tinyspeck.slackmacgap", "com.microsoft.teams", "com.bytedance.lark",
                       "ru.keepcoder.telegram", "org.telegram.", "com.facebook.archon"] where id.hasPrefix(prefix) {
            return .chat
        }
        // Mail.
        for prefix in ["com.apple.mail", "com.microsoft.outlook", "com.readdle.smartemail"] where id.hasPrefix(prefix) {
            return .email
        }
        // Documents.
        for prefix in ["com.apple.notes", "com.apple.textedit", "com.microsoft.word",
                       "com.apple.pages", "md.obsidian", "notion.id", "com.evernote."] where id.hasPrefix(prefix) {
            return .document
        }
        return .neutral
    }

    /// The output-contract block of the system prompt for this shape.
    var promptSection: String {
        switch self {
        case .code:
            """
            ## 输出契约
            - 直接输出整理后的文本，不要任何前缀（如"好的""以下是"）、后缀或解释
            - 标识符、路径、命令、参数、代码片段一律原样保留：大小写、下划线、连字符、括号都不改
            - 不要补句号、不要给命令加标点、不要把命令改写成自然语言
            - 纯文本：不加 Markdown 代码块、不加标题、不加列表符号
            - 不要输出 JSON 或字段名
            """
        case .document:
            """
            ## 输出契约
            - 直接输出整理后的文本，不要任何前缀（如"好的""以下是"）、后缀或解释
            - 可以分段：一个意思一段，段与段之间用空行；不要写小标题
            - 不要加列表符号、编号或加粗，除非说话人自己在分点表达
            - 不要用引号或代码块把整段结果包起来
            - 不要输出 JSON 或字段名
            """
        case .email:
            """
            ## 输出契约
            - 直接输出整理后的文本，不要任何前缀（如"好的""以下是"）、后缀或解释
            - 写完整的句子；说话人说的称呼和落款保留原样，没说的不要自己补
            - 不要主动分点、编号或加小标题
            - 不要用引号或代码块把整段结果包起来
            - 不要输出 JSON 或字段名
            """
        case .chat, .neutral:
            """
            ## 输出契约
            - 直接输出整理后的文本，不要任何前缀（如"好的""以下是"）、后缀或解释
            - 纯文本：不加标题、列表符号、加粗或 Markdown
            - 不要用引号或代码块把整段结果包起来
            - 不要输出 JSON 或字段名
            """
        }
    }
}

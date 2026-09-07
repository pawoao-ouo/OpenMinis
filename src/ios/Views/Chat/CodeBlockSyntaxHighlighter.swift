import UIKit

/// 代码块语法高亮。
///
/// 单遍字符扫描（不用正则，流式每帧一把过）：行注释 / 块注释 / 字符串 / 数字 / 关键字 / 类型名。
/// 语言按「词法族」归一——写什么语言都落到最接近的那族，错了不丑，只少几个颜色。
/// 超长直接放弃高亮退回单色，保流式帧率。
enum CodeBlockSyntaxHighlighter {

    private static let maxHighlightLength = 120_000

    // MARK: 配色（代码块底色恒深，颜色按深底调）

    private struct Palette {
        let plain = UIColor(white: 0.92, alpha: 1)
        let comment = UIColor(white: 0.55, alpha: 1)
        let string = UIColor(red: 0.62, green: 0.86, blue: 0.55, alpha: 1)
        let number = UIColor(red: 0.96, green: 0.72, blue: 0.44, alpha: 1)
        let keyword = UIColor(red: 0.93, green: 0.51, blue: 0.72, alpha: 1)
        let typeName = UIColor(red: 0.52, green: 0.80, blue: 0.92, alpha: 1)
        let preprocessor = UIColor(red: 0.82, green: 0.63, blue: 0.95, alpha: 1)
    }

    // MARK: 词法族

    private struct Profile {
        var lineComments: [String] = []
        var blockStart: String?
        var blockEnd: String?
        var strings: [unichar] = [34, 39]          // " '
        var backtickString = false
        var keywords: Set<String> = []
        var capitalizedIsType = false
        var hashIsPreprocessor = false             // c 系：行首 # 是预处理不是注释
    }

    private static func kw(_ s: String) -> Set<String> {
        s.isEmpty ? [] : Set(s.split(separator: " ").map(String.init))
    }

    private static func profile(for language: String?) -> Profile {
        let lang = (language ?? "").lowercased().trimmingCharacters(in: .whitespaces)
        var p = Profile()

        switch lang {
        case "swift":
            p.lineComments = ["//"]; p.blockStart = "/*"; p.blockEnd = "*/"
            p.capitalizedIsType = true
            p.keywords = kw("class struct enum protocol extension func var let if else guard return switch case default for while repeat do try catch throw throws async await actor associatedtype typealias import init deinit self Self nil true false in is as public private internal fileprivate open static final lazy weak unowned override mutating nonmutating convenience required some any inout where break continue fallthrough defer operator precedencegroup nonisolated")

        case "py", "python", "pyw":
            p.lineComments = ["#"]
            p.keywords = kw("def class return if elif else for while try except finally with as import from pass break continue raise lambda yield global nonlocal assert del is in not and or True False None self cls async await match case print")

        case "rb", "ruby":
            p.lineComments = ["#"]
            p.keywords = kw("def class module return if elsif else unless for while do begin end rescue ensure raise yield lambda require require_relative self nil true false and or not in then super")

        case "js", "jsx", "ts", "tsx", "javascript", "typescript", "vue", "svelte", "coffee", "mjs", "cjs":
            p.lineComments = ["//"]; p.blockStart = "/*"; p.blockEnd = "*/"
            p.backtickString = true; p.capitalizedIsType = true
            p.keywords = kw("const let var function class extends super new delete typeof instanceof in of if else return switch case default for while do try catch finally throw async await yield import export from as this null undefined true false void get set static public private protected readonly abstract interface type enum namespace declare implements")

        case "c", "h", "cpp", "c++", "cxx", "hpp", "cc", "objc", "m", "mm", "cs", "csharp", "java", "kotlin", "kt", "scala", "go", "rust", "rs", "dart", "php", "groovy":
            p.lineComments = ["//"]; p.blockStart = "/*"; p.blockEnd = "*/"
            p.capitalizedIsType = true
            p.hashIsPreprocessor = ["c", "h", "cpp", "c++", "cxx", "hpp", "cc", "objc", "m", "mm"].contains(lang)
            p.keywords = kw("class struct enum interface trait fn func fun var let val const mut if else return switch case default match for while loop do try catch finally throw throws async await package import using namespace typedef impl mod pub crate self Self super this null nullptr nil true false new delete sizeof typeof instanceof extends implements final static abstract virtual override public private protected internal inline constexpr when object companion suspend sealed data unsafe extern void int long short char float double bool string unsigned signed auto")

        case "sh", "bash", "zsh", "fish", "shell", "console":
            p.lineComments = ["#"]
            p.keywords = kw("if then else elif fi for while do done case esac function return exit break continue local export readonly declare echo cd source in shift select until trap")

        case "json":
            p.strings = [34]
            p.keywords = kw("true false null")

        case "yaml", "yml", "toml", "ini", "conf", "cfg", "properties", "env":
            p.lineComments = ["#"]
            p.keywords = kw("true false yes no on off null nil True False")

        case "sql", "mysql", "pgsql", "sqlite", "plsql":
            p.lineComments = ["--"]
            p.blockStart = "/*"; p.blockEnd = "*/"
            let base = "select insert update delete from where and or not in like between is null join inner outer left right full on group by order having limit offset distinct as union all create table index view drop alter add column primary key foreign references constraint unique default into values set begin commit rollback transaction grant revoke truncate exists case when then else end desc asc count sum avg min max cast coalesce if returning"
            p.keywords = Set(base.split(separator: " ").map(String.init))
                .union(Set(base.uppercased().split(separator: " ").map(String.init)))

        case "html", "xml", "xhtml", "svg", "plist", "storyboard":
            p.blockStart = "<!--"; p.blockEnd = "-->"

        case "css", "scss", "sass", "less":
            p.blockStart = "/*"; p.blockEnd = "*/"
            p.keywords = kw("import media supports keyframes font-face charset important root")

        case "lua":
            p.lineComments = ["--"]
            p.blockStart = "--[["; p.blockEnd = "]]"
            p.keywords = kw("local function return if then else elseif end for while do repeat until break require module ipairs pairs print self nil true false and or not in")

        case "r":
            p.lineComments = ["#"]
            p.keywords = kw("function if else repeat while for in next break return library require source TRUE FALSE NULL NA NaN Inf")

        default:
            // 未知语言：只给字符串和数字上色，不猜注释符，猜错反而糊一片。
            p.lineComments = []
        }
        return p
    }

    // MARK: 公开入口

    static func highlight(code: String, language: String?, font: UIFont,
                          paragraphStyle: NSParagraphStyle) -> NSAttributedString {
        let palette = Palette()
        let attr = NSMutableAttributedString(string: code, attributes: [
            .font: font,
            .foregroundColor: palette.plain,
            .paragraphStyle: paragraphStyle,
        ])
        guard !code.isEmpty, code.count <= maxHighlightLength else { return attr }

        let profile = profile(for: language)
        scan(code, profile: profile, palette: palette).forEach { token in
            attr.addAttribute(.foregroundColor, value: token.color, range: token.range)
        }
        return attr
    }

    // MARK: 扫描

    private struct ColorToken {
        let range: NSRange
        let color: UIColor
    }

    private static func scan(_ code: String, profile: Profile, palette: Palette) -> [ColorToken] {
        var tokens: [ColorToken] = []
        let ns = code as NSString
        let len = ns.length
        var i = 0

        func has(_ s: String, at pos: Int) -> Bool {
            guard pos + s.count <= len else { return false }
            return ns.substring(with: NSRange(location: pos, length: s.count)) == s
        }
        func isDigit(_ c: unichar) -> Bool { c >= 48 && c <= 57 }
        func isIdentStart(_ c: unichar) -> Bool {
            (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c == 36
        }
        func isIdentPart(_ c: unichar) -> Bool { isIdentStart(c) || isDigit(c) }

        var isLineStart = true

        while i < len {
            let c = ns.character(at: i)

            if c == 10 { isLineStart = true; i += 1; continue }
            if c == 32 || c == 9 { i += 1; continue } // 行首空白不换行首判定

            // 预处理（c 系行首 #）
            if profile.hashIsPreprocessor, c == 35, isLineStart {
                var end = i + 1
                while end < len, ns.character(at: end) != 10 { end += 1 }
                tokens.append(ColorToken(range: NSRange(location: i, length: end - i),
                                         color: palette.preprocessor))
                i = end
                continue
            }

            // 行注释
            if let prefix = profile.lineComments.first(where: { has($0, at: i) }) {
                var end = i + prefix.count
                while end < len, ns.character(at: end) != 10 { end += 1 }
                tokens.append(ColorToken(range: NSRange(location: i, length: end - i),
                                         color: palette.comment))
                i = end
                continue
            }

            // 块注释
            if let start = profile.blockStart, let endMark = profile.blockEnd, has(start, at: i) {
                var end = i + start.count
                var closed = false
                while end + endMark.count <= len {
                    if has(endMark, at: end) { end += endMark.count; closed = true; break }
                    end += 1
                }
                if !closed { end = len }
                tokens.append(ColorToken(range: NSRange(location: i, length: end - i),
                                         color: palette.comment))
                i = end
                continue
            }

            // 字符串（含反斜杠转义、反引号模板串可跨行，单双引号到行尾收）
            let isStringQuote = profile.strings.contains(c) || (profile.backtickString && c == 96)
            if isStringQuote {
                let quote = c
                let multiline = (quote == 96)
                var end = i + 1
                var closed = false
                while end < len {
                    let cc = ns.character(at: end)
                    if cc == 92 { end += 2; continue }
                    if cc == quote { end += 1; closed = true; break }
                    if !multiline, cc == 10 { break }
                    end += 1
                }
                if end > len { end = len }
                tokens.append(ColorToken(range: NSRange(location: i, length: end - i),
                                         color: palette.string))
                if closed || !multiline { isLineStart = false }
                i = end
                continue
            }

            // 数字：十进制 / 0x 十六进制 / 小数 / 下划线分隔
            if isDigit(c), i == 0 || !isIdentPart(ns.character(at: i - 1)) {
                var end = i
                let hex = (c == 48) && (i + 1 < len) && {
                    let n = ns.character(at: i + 1)
                    return n == 120 || n == 88
                }()
                if hex {
                    end = i + 2
                    while end < len {
                        let cc = ns.character(at: end)
                        let isHex = isDigit(cc) || (cc >= 65 && cc <= 70) || (cc >= 97 && cc <= 102) || cc == 95
                        if !isHex { break }
                        end += 1
                    }
                } else {
                    end = i
                    var seenDot = false
                    while end < len {
                        let cc = ns.character(at: end)
                        if isDigit(cc) || cc == 95 { end += 1; continue }
                        if cc == 46, !seenDot { seenDot = true; end += 1; continue }
                        break
                    }
                }
                tokens.append(ColorToken(range: NSRange(location: i, length: end - i),
                                         color: palette.number))
                isLineStart = false
                i = end
                continue
            }

            // 标识符 → 关键字 / 大写开头当类型名
            if isIdentStart(c) {
                var end = i + 1
                while end < len, isIdentPart(ns.character(at: end)) { end += 1 }
                let range = NSRange(location: i, length: end - i)
                let word = ns.substring(with: range)
                if profile.keywords.contains(word) {
                    tokens.append(ColorToken(range: range, color: palette.keyword))
                } else if profile.capitalizedIsType,
                          word.count > 1,
                          let first = word.unicodeScalars.first,
                          CharacterSet.uppercaseLetters.contains(first) {
                    tokens.append(ColorToken(range: range, color: palette.typeName))
                }
                isLineStart = false
                i = end
                continue
            }

            // 其它字符（标点等）不上色，但破坏「行首」状态
            if c != 13 { isLineStart = false }
            i += 1
        }

        return tokens
    }
}

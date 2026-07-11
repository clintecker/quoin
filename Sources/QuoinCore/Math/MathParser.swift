import Foundation

/// A parsed LaTeX math expression. The node tree is deliberately close to
/// TeX's own model — rows of atoms with spacing classes — so the layout
/// engine can apply real inter-atom spacing rules instead of guessing.
public indirect enum MathNode: Hashable, Sendable {
    /// A single glyph run (variable, digit, symbol) with its TeX atom class.
    case symbol(String, MathAtomClass, style: MathSymbolStyle = .italic)
    /// Horizontal sequence.
    case row([MathNode])
    case fraction(numerator: MathNode, denominator: MathNode)
    case radical(degree: MathNode?, radicand: MathNode)
    case scripts(base: MathNode, subscript: MathNode?, superscript: MathNode?)
    /// Auto-sized fences around a body: ( ) [ ] { } | ‖.
    case delimited(left: String, body: MathNode, right: String)
    /// A grid of cells from a `\begin{…}…\end{…}` environment — matrices,
    /// `cases`, `aligned`. `left`/`right` are the enclosing fences (empty for
    /// none); `style` selects column alignment.
    case matrix(rows: [[MathNode]], left: String, right: String, style: MathMatrixStyle)
    /// Upright function name (sin, log …).
    case functionName(String)
    /// Explicit spacing (multiples of an em quad).
    case space(Double)
    /// An accent over (or rule under) a base: \hat \vec \bar \overline …
    case accent(base: MathNode, accent: MathAccent)
    /// Generalized fraction: numerator over denominator with an optional
    /// rule and optional enclosing fences. `\frac` is rule-yes/no-fence;
    /// `\binom` is rule-no/paren-fence.
    case genfrac(top: MathNode, bottom: MathNode, hasRule: Bool, left: String, right: String)
    /// Material set over and/or under a base: \overset \underset \stackrel
    /// (plain), \overbrace \underbrace (a drawn brace), \xrightarrow
    /// \xleftarrow (a stretchy arrow). `over`/`under` are the annotations.
    case overUnder(base: MathNode, over: MathNode?, under: MathNode?, kind: MathOverUnder)
    /// A box/spacing decoration: \boxed (framed) or the \phantom family
    /// (reserve space, draw nothing).
    case decorated(base: MathNode, decoration: MathDecoration)
    /// A recolored subexpression: \color / \textcolor. The color is a name
    /// ("red", "teal") or "#rrggbb"; the renderer resolves it.
    case styled(base: MathNode, color: String)
    /// Something we don't understand — rendered as literal marked source
    /// (the PRD rule: unknown input degrades, never errors).
    case unsupported(String)
}

/// A `.decorated` treatment: a frame or reserved (invisible) space.
public enum MathDecoration: Hashable, Sendable {
    case boxed        // \boxed — stroked frame with padding
    case phantom      // reserve full box, draw nothing
    case hphantom     // reserve width only
    case vphantom     // reserve height only
}

/// How an `.overUnder` decoration is drawn between base and annotations.
public enum MathOverUnder: Hashable, Sendable {
    case plain        // \overset / \underset / \stackrel — bare stacking
    case overbrace    // ⏞ drawn above the base
    case underbrace   // ⏟ drawn below the base
    case rightarrow   // stretchy → with the annotation(s) over/under it
    case leftarrow    // stretchy ←
}

/// An accent decoration placed over (or, for rules, over/under) a base.
public enum MathAccent: Hashable, Sendable {
    case hat, check, tilde, bar, vec, dot, ddot, breve, mathring, acute, grave
    case widehat, widetilde   // stretchy variants
    case overline, underline  // drawn rules, not glyphs

    /// The glyph drawn above the base (nil for the rule accents).
    public var glyph: String? {
        switch self {
        case .hat, .widehat: return "^"
        case .check: return "ˇ"
        case .tilde, .widetilde: return "~"
        case .bar: return "‾"
        case .vec: return "⃗"
        case .dot: return "˙"
        case .ddot: return "¨"
        case .breve: return "˘"
        case .mathring: return "˚"
        case .acute: return "´"
        case .grave: return "`"
        case .overline, .underline: return nil
        }
    }

    public var isStretchy: Bool { self == .widehat || self == .widetilde }

    public init?(command: String) {
        switch command {
        case "hat": self = .hat
        case "check": self = .check
        case "tilde": self = .tilde
        case "bar": self = .bar
        case "vec": self = .vec
        case "dot": self = .dot
        case "ddot": self = .ddot
        case "breve": self = .breve
        case "mathring": self = .mathring
        case "acute": self = .acute
        case "grave": self = .grave
        case "widehat": self = .widehat
        case "widetilde": self = .widetilde
        case "overline": self = .overline
        case "underline": self = .underline
        default: return nil
        }
    }
}

/// TeX atom classes drive inter-atom spacing (thin/medium/thick).
public enum MathAtomClass: Hashable, Sendable {
    case ordinary      // x, 1, α
    case largeOperator // ∑ ∫
    case binary        // + − ×
    case relation      // = ≤ →
    case opening       // ( [
    case closing       // ) ]
    case punctuation   // , ;
}

public enum MathSymbolStyle: Hashable, Sendable {
    case italic   // variables
    case roman    // digits, function names, operators
    case bold     // \mathbf — upright bold
}

/// Column alignment for a `.matrix` grid.
public enum MathMatrixStyle: Hashable, Sendable {
    case centered   // matrix / pmatrix / bmatrix …
    case cases      // left-aligned columns (a `cases` list)
    case aligned    // alternating right/left, meeting at the `&` (aligned/align)
    case substack   // tight centered stack at script size (\substack)
}

public enum MathParser {

    /// Parser recursion depth tracks brace / environment nesting; adversarial
    /// input ("{{{{…" ×10k) would otherwise overflow the stack. Past this
    /// bound the whole expression degrades to styled source (PRD rule:
    /// unknown input degrades, never crashes).
    static let maxNestingDepth = 64

    /// Parses a LaTeX math string. Unknown commands become `.unsupported`
    /// leaves; the parse itself never fails.
    public static func parse(_ latex: String) -> MathNode {
        // Linear pre-scan bounds recursion before it starts: parse recursion
        // depth ≤ max brace nesting + \begin count.
        var depth = 0, maxDepth = 0
        for ch in latex {
            if ch == "{" { depth += 1; maxDepth = max(maxDepth, depth) }
            if ch == "}" { depth = max(0, depth - 1) }
        }
        let begins = latex.components(separatedBy: "\\begin").count - 1
        guard maxDepth <= maxNestingDepth, begins <= maxNestingDepth else {
            return .unsupported(latex)
        }

        var tokens = Tokenizer(latex).tokenize()[...]
        let nodes = parseRow(&tokens, until: nil)
        return nodes.count == 1 ? nodes[0] : .row(nodes)
    }

    // MARK: - Tokens

    enum Token: Equatable {
        case command(String)   // \frac, \alpha
        case character(Character)
        case groupOpen         // {
        case groupClose        // }
        case superscriptMark   // ^
        case subscriptMark     // _
    }

    struct Tokenizer {
        let input: [Character]
        init(_ s: String) { input = Array(s) }

        func tokenize() -> [Token] {
            var tokens: [Token] = []
            var i = 0
            while i < input.count {
                let ch = input[i]
                switch ch {
                case "\\":
                    var name = ""
                    var j = i + 1
                    while j < input.count, input[j].isLetter {
                        name.append(input[j])
                        j += 1
                    }
                    if name.isEmpty, j < input.count {
                        // Escaped single char: \{ \} \, \$ etc.
                        name = String(input[j])
                        j += 1
                    }
                    tokens.append(.command(name))
                    i = j
                case "{": tokens.append(.groupOpen); i += 1
                case "}": tokens.append(.groupClose); i += 1
                case "^": tokens.append(.superscriptMark); i += 1
                case "_": tokens.append(.subscriptMark); i += 1
                case " ", "\n", "\t": i += 1 // math mode ignores whitespace
                default:
                    tokens.append(.character(ch)); i += 1
                }
            }
            return tokens
        }
    }

    // MARK: - Parser

    private static func parseRow(_ tokens: inout ArraySlice<Token>, until terminator: Token?) -> [MathNode] {
        var nodes: [MathNode] = []
        while let token = tokens.first {
            if let terminator, token == terminator {
                tokens.removeFirst()
                break
            }
            guard var node = parseAtom(&tokens) else { continue }

            // Attach any ^/_ scripts to the atom just parsed.
            var sub: MathNode?
            var sup: MathNode?
            while let mark = tokens.first, mark == .superscriptMark || mark == .subscriptMark {
                tokens.removeFirst()
                let script = parseAtom(&tokens) ?? .row([])
                if mark == .superscriptMark { sup = script } else { sub = script }
            }
            if sub != nil || sup != nil {
                node = .scripts(base: node, subscript: sub, superscript: sup)
            }
            nodes.append(node)
        }
        return nodes
    }

    /// One atom: a group, a command, or a single character.
    private static func parseAtom(_ tokens: inout ArraySlice<Token>) -> MathNode? {
        guard let token = tokens.first else { return nil }
        tokens.removeFirst()

        switch token {
        case .groupOpen:
            let nodes = parseRow(&tokens, until: .groupClose)
            return nodes.count == 1 ? nodes[0] : .row(nodes)

        case .groupClose:
            return nil // stray brace: ignore

        case .superscriptMark, .subscriptMark:
            return nil // handled by caller; stray marks ignored

        case .character(let ch):
            return characterNode(ch)

        case .command(let name):
            return commandNode(name, &tokens)
        }
    }

    private static func characterNode(_ ch: Character) -> MathNode {
        if ch.isNumber || ch == "." {
            return .symbol(String(ch), .ordinary, style: .roman)
        }
        // ASCII letters are italic variables; other letters (Greek α typed
        // directly, etc.) keep the class the symbol table assigns their
        // glyph so `α` matches `\alpha` and stays italic ordinary.
        if ch.isLetter {
            if ch.isASCII {
                return .symbol(String(ch), .ordinary, style: .italic)
            }
            let cls = glyphAtomClass[String(ch)] ?? .ordinary
            return .symbol(String(ch), cls, style: .italic)
        }
        switch ch {
        case "+", "−": return .symbol(String(ch), .binary, style: .roman)
        case "-": return .symbol("−", .binary, style: .roman) // proper minus
        case "*": return .symbol("∗", .binary, style: .roman)
        case "/": return .symbol("/", .ordinary, style: .roman)
        case "=": return .symbol("=", .relation, style: .roman)
        case "<": return .symbol("<", .relation, style: .roman)
        case ">": return .symbol(">", .relation, style: .roman)
        case "(", "[": return .symbol(String(ch), .opening, style: .roman)
        case ")", "]": return .symbol(String(ch), .closing, style: .roman)
        case ",", ";": return .symbol(String(ch), .punctuation, style: .roman)
        case "!", "?", "'", "|", ":": return .symbol(String(ch), .ordinary, style: .roman)
        default:
            // A directly-typed math glyph (∫ ∑ ≤ →): give it the atom class
            // its `\command` form would, so spacing and (for operators)
            // stacked limits work. `∫x` typed raw now behaves like `\int x`.
            if let cls = glyphAtomClass[String(ch)] {
                return .symbol(String(ch), cls, style: .roman)
            }
            return .symbol(String(ch), .ordinary, style: .roman)
        }
    }

    /// Reverse of `symbolTable`: glyph → atom class, so a directly-typed
    /// Unicode math character is classed like its command spelling.
    static let glyphAtomClass: [String: MathAtomClass] = {
        var map: [String: MathAtomClass] = [:]
        for (_, value) in symbolTable {
            // First writer wins; classes for a given glyph are consistent
            // in the table (all arrows relation, all operators binary, …).
            if map[value.0] == nil { map[value.0] = value.1 }
        }
        return map
    }()

    private static func commandNode(_ name: String, _ tokens: inout ArraySlice<Token>) -> MathNode {
        // Structural commands.
        switch name {
        case "frac", "tfrac", "dfrac", "cfrac":
            let numerator = parseAtom(&tokens) ?? .row([])
            let denominator = parseAtom(&tokens) ?? .row([])
            return .fraction(numerator: numerator, denominator: denominator)

        case "binom", "dbinom", "tbinom":
            let top = parseAtom(&tokens) ?? .row([])
            let bottom = parseAtom(&tokens) ?? .row([])
            return .genfrac(top: top, bottom: bottom, hasRule: false, left: "(", right: ")")

        case "sqrt":
            // Optional degree: \sqrt[3]{x}
            var degree: MathNode?
            if tokens.first == .character("[") {
                tokens.removeFirst()
                var nodes: [MathNode] = []
                while let t = tokens.first, t != .character("]") {
                    if let atom = parseAtom(&tokens) { nodes.append(atom) }
                }
                if tokens.first == .character("]") { tokens.removeFirst() }
                degree = nodes.count == 1 ? nodes[0] : .row(nodes)
            }
            let radicand = parseAtom(&tokens) ?? .row([])
            return .radical(degree: degree, radicand: radicand)

        case "left":
            let leftDelim = takeDelimiter(&tokens) ?? "("
            var body: [MathNode] = []
            var rightDelim = ")"
            while let t = tokens.first {
                if case .command("right") = t {
                    tokens.removeFirst()
                    rightDelim = takeDelimiter(&tokens) ?? ")"
                    break
                }
                if let atom = parseAtomWithScripts(&tokens) { body.append(atom) }
            }
            return .delimited(left: leftDelim, body: body.count == 1 ? body[0] : .row(body), right: rightDelim)

        case "text", "mathrm", "operatorname", "textrm":
            if tokens.first == .groupOpen {
                tokens.removeFirst()
                var text = ""
                while let t = tokens.first, t != .groupClose {
                    tokens.removeFirst()
                    if case .character(let ch) = t { text.append(ch) }
                    if case .command(let c) = t, c == " " { text.append(" ") }
                }
                if tokens.first == .groupClose { tokens.removeFirst() }
                return .functionName(text)
            }
            return .row([])

        case "mathbb", "mathcal", "mathscr", "mathfrak", "mathsf",
             "mathtt", "mathbf", "boldsymbol", "bm":
            let inner = parseAtom(&tokens) ?? .row([])
            return styledLetters(inner, command: name)

        case "begin":
            return parseEnvironment(&tokens)

        case "hat", "check", "tilde", "bar", "vec", "dot", "ddot", "breve",
             "mathring", "acute", "grave", "widehat", "widetilde",
             "overline", "underline":
            let base = parseAtom(&tokens) ?? .row([])
            return .accent(base: base, accent: MathAccent(command: name)!)

        case "overset", "stackrel":
            // \overset{over}{base}; \stackrel is the same with a relation base.
            let over = parseAtom(&tokens) ?? .row([])
            let base = parseAtom(&tokens) ?? .row([])
            return .overUnder(base: base, over: over, under: nil, kind: .plain)

        case "underset":
            let under = parseAtom(&tokens) ?? .row([])
            let base = parseAtom(&tokens) ?? .row([])
            return .overUnder(base: base, over: nil, under: under, kind: .plain)

        case "overbrace":
            let body = parseAtom(&tokens) ?? .row([])
            var label: MathNode?
            if tokens.first == .superscriptMark {
                tokens.removeFirst()
                label = parseAtom(&tokens)
            }
            return .overUnder(base: body, over: label, under: nil, kind: .overbrace)

        case "underbrace":
            let body = parseAtom(&tokens) ?? .row([])
            var label: MathNode?
            if tokens.first == .subscriptMark {
                tokens.removeFirst()
                label = parseAtom(&tokens)
            }
            return .overUnder(base: body, over: nil, under: label, kind: .underbrace)

        case "xrightarrow", "xleftarrow":
            // \xrightarrow[under]{over} — optional [under], then {over}.
            var under: MathNode?
            if tokens.first == .character("[") {
                tokens.removeFirst()
                var nodes: [MathNode] = []
                while let t = tokens.first, t != .character("]") {
                    if let atom = parseAtom(&tokens) { nodes.append(atom) }
                }
                if tokens.first == .character("]") { tokens.removeFirst() }
                under = nodes.count == 1 ? nodes[0] : .row(nodes)
            }
            let over = parseAtom(&tokens) ?? .row([])
            return .overUnder(base: .row([]), over: over, under: under,
                              kind: name == "xrightarrow" ? .rightarrow : .leftarrow)

        case "substack":
            return parseSubstack(&tokens)

        case "boxed":
            return .decorated(base: parseAtom(&tokens) ?? .row([]), decoration: .boxed)
        case "phantom":
            return .decorated(base: parseAtom(&tokens) ?? .row([]), decoration: .phantom)
        case "hphantom":
            return .decorated(base: parseAtom(&tokens) ?? .row([]), decoration: .hphantom)
        case "vphantom":
            return .decorated(base: parseAtom(&tokens) ?? .row([]), decoration: .vphantom)

        case "color", "textcolor":
            // \color{name}{body} and \textcolor{name}{body} both take the
            // color as a brace name then the body (we don't support the
            // stateful \color{name}-applies-to-rest form).
            let color = readBraceName(&tokens)
            let body = parseAtom(&tokens) ?? .row([])
            return .styled(base: body, color: color)

        // Spacing.
        case ",": return .space(3.0 / 18.0)
        case ":": return .space(4.0 / 18.0)
        case ";": return .space(5.0 / 18.0)
        case "!": return .space(-3.0 / 18.0)   // negative thin space
        case "quad": return .space(1.0)
        case "qquad": return .space(2.0)
        case " ": return .space(6.0 / 18.0)

        // Manual delimiter sizing: we don't yet enlarge the fence, but the
        // size prefix must be transparent — parse the delimiter that
        // follows at normal size rather than degrading the whole
        // expression (\big( used to become a source card).
        case "big", "Big", "bigg", "Bigg",
             "bigl", "Bigl", "biggl", "Biggl",
             "bigr", "Bigr", "biggr", "Biggr",
             "bigm", "Bigm", "biggm", "Biggm":
            return parseAtom(&tokens) ?? .row([])

        default:
            if let (glyph, atomClass) = symbolTable[name] {
                return .symbol(glyph, atomClass, style: .roman)
            }
            if functionNames.contains(name) {
                return .functionName(name)
            }
            return .unsupported("\\" + name)
        }
    }

    /// An atom plus any attached scripts — needed inside \left…\right.
    private static func parseAtomWithScripts(_ tokens: inout ArraySlice<Token>) -> MathNode? {
        guard var node = parseAtom(&tokens) else { return nil }
        var sub: MathNode?
        var sup: MathNode?
        while let mark = tokens.first, mark == .superscriptMark || mark == .subscriptMark {
            tokens.removeFirst()
            let script = parseAtom(&tokens) ?? .row([])
            if mark == .superscriptMark { sup = script } else { sub = script }
        }
        if sub != nil || sup != nil {
            node = .scripts(base: node, subscript: sub, superscript: sup)
        }
        return node
    }

    /// Reads a brace-delimited literal name like `{pmatrix}` or `{3}`.
    private static func readBraceName(_ tokens: inout ArraySlice<Token>) -> String {
        guard tokens.first == .groupOpen else { return "" }
        tokens.removeFirst()
        var name = ""
        while let t = tokens.first, t != .groupClose {
            tokens.removeFirst()
            if case .character(let ch) = t { name.append(ch) }
        }
        if tokens.first == .groupClose { tokens.removeFirst() }
        return name
    }

    /// Parses the body of `\begin{env} … \end{env}` into a `.matrix`. Cells
    /// are split on `&`, rows on `\\`; unknown environments still lay out as a
    /// bare centered grid so the content survives.
    private static func parseEnvironment(_ tokens: inout ArraySlice<Token>) -> MathNode {
        let env = readBraceName(&tokens)
        let base = env.hasSuffix("*") ? String(env.dropLast()) : env

        // `array` and `alignedat` carry a column-spec / count argument.
        if base == "array" || base == "alignedat" { _ = readBraceName(&tokens) }

        let (left, right, style): (String, String, MathMatrixStyle)
        switch base {
        case "pmatrix": (left, right, style) = ("(", ")", .centered)
        case "bmatrix": (left, right, style) = ("[", "]", .centered)
        case "Bmatrix": (left, right, style) = ("{", "}", .centered)
        case "vmatrix": (left, right, style) = ("|", "|", .centered)
        case "Vmatrix": (left, right, style) = ("‖", "‖", .centered)
        case "cases":   (left, right, style) = ("{", "", .cases)
        case "aligned", "align", "alignedat", "alignat", "split", "gather":
            (left, right, style) = ("", "", .aligned)
        default:        (left, right, style) = ("", "", .centered)   // matrix, array, …
        }

        var rows: [[MathNode]] = []
        var row: [MathNode] = []
        var cell: [MathNode] = []
        func endCell() {
            row.append(cell.count == 1 ? cell[0] : .row(cell))
            cell = []
        }
        func endRow() {
            endCell()
            rows.append(row)
            row = []
        }

        while let token = tokens.first {
            if case .command("end") = token {
                tokens.removeFirst()
                _ = readBraceName(&tokens)          // consume {env}
                break
            }
            if case .command("\\") = token { tokens.removeFirst(); endRow(); continue }
            if case .character("&") = token { tokens.removeFirst(); endCell(); continue }
            // Row rules: consume rather than let them degrade the whole grid
            // (\hline used to become an .unsupported leaf inside a cell,
            // flipping the entire array to a source card). \cline{a-b} also
            // carries a brace argument to drop.
            if case .command(let c) = token, c == "hline" || c == "hdashline" || c == "cline" {
                tokens.removeFirst()
                if c == "cline" { _ = readBraceName(&tokens) }
                continue
            }
            if let atom = parseAtomWithScripts(&tokens) {
                cell.append(atom)
            } else if tokens.first != nil {
                tokens.removeFirst()                // never spin on an unconsumable token
            }
        }
        // Flush a trailing partial row (no closing `\\`).
        if !cell.isEmpty || !row.isEmpty { endRow() }

        return .matrix(rows: rows, left: left, right: right, style: style)
    }

    /// `\substack{ line1 \\ line2 }` — a tight vertical stack, one cell per
    /// line, used under summation limits. Lowered to a single-column matrix
    /// with the `.substack` style so it reuses the grid layout.
    private static func parseSubstack(_ tokens: inout ArraySlice<Token>) -> MathNode {
        guard tokens.first == .groupOpen else { return .row([]) }
        tokens.removeFirst()
        var rows: [[MathNode]] = []
        var line: [MathNode] = []
        func endLine() { rows.append([line.count == 1 ? line[0] : .row(line)]); line = [] }
        while let token = tokens.first {
            if token == .groupClose { tokens.removeFirst(); break }
            if case .command("\\") = token { tokens.removeFirst(); endLine(); continue }
            if let atom = parseAtomWithScripts(&tokens) {
                line.append(atom)
            } else if tokens.first != nil {
                tokens.removeFirst()
            }
        }
        if !line.isEmpty { endLine() }
        return .matrix(rows: rows, left: "", right: "", style: .substack)
    }

    private static func takeDelimiter(_ tokens: inout ArraySlice<Token>) -> String? {
        guard let token = tokens.first else { return nil }
        tokens.removeFirst()
        switch token {
        case .character(let ch):
            return ch == "." ? "" : String(ch)
        case .command(let name):
            switch name {
            case "{": return "{"
            case "}": return "}"
            case "langle": return "⟨"
            case "rangle": return "⟩"
            case "lvert", "rvert", "vert": return "|"
            case "lVert", "rVert", "Vert": return "‖"
            default: return nil
            }
        default:
            return nil
        }
    }

    /// Math font commands. `\mathbf` stays a system-font bold style;
    /// `\boldsymbol`/`\bm` are bold-italic; the rest map each letter/digit
    /// to its Mathematical-Alphanumeric-Symbols codepoint (𝔸 𝒜 𝔞 𝗔 𝚊 …),
    /// which CoreText resolves through STIX/Apple Symbols. The mapped glyph
    /// already encodes the styling, so it carries `.roman` to avoid a
    /// synthetic italic slant on top of it.
    private static func styledLetters(_ node: MathNode, command: String) -> MathNode {
        // `\mathbf` is the one command we render with a real bold system
        // font rather than a codepoint (matches long-standing behavior).
        if command == "mathbf" {
            switch node {
            case .symbol(let s, let cls, _):
                return .symbol(s, cls, style: .bold)
            case .row(let children):
                return .row(children.map { styledLetters($0, command: command) })
            default:
                return node
            }
        }
        guard let alphabet = MathAlphabet(command: command) else { return node }
        switch node {
        case .symbol(let s, let cls, _):
            let mapped = s.count == 1 ? (alphabet.glyph(for: s.first!) ?? s) : s
            return .symbol(mapped, cls, style: .roman)
        case .row(let children):
            return .row(children.map { styledLetters($0, command: command) })
        default:
            return node
        }
    }

    // MARK: - Symbol tables

    static let functionNames: Set<String> = [
        "sin", "cos", "tan", "cot", "sec", "csc", "arcsin", "arccos", "arctan",
        "sinh", "cosh", "tanh", "log", "ln", "lg", "exp", "min", "max", "sup",
        "inf", "lim", "det", "dim", "ker", "arg", "gcd", "deg", "mod",
        "Pr", "hom", "argmin", "argmax", "limsup", "liminf",
        "coth", "sech", "csch",
    ]

    static let symbolTable: [String: (String, MathAtomClass)] = [
        // Greek lowercase.
        "alpha": ("α", .ordinary), "beta": ("β", .ordinary), "gamma": ("γ", .ordinary),
        "delta": ("δ", .ordinary), "epsilon": ("ε", .ordinary), "varepsilon": ("ε", .ordinary),
        "zeta": ("ζ", .ordinary), "eta": ("η", .ordinary), "theta": ("θ", .ordinary),
        "vartheta": ("ϑ", .ordinary), "iota": ("ι", .ordinary), "kappa": ("κ", .ordinary),
        "lambda": ("λ", .ordinary), "mu": ("μ", .ordinary), "nu": ("ν", .ordinary),
        "xi": ("ξ", .ordinary), "pi": ("π", .ordinary), "varpi": ("ϖ", .ordinary),
        "rho": ("ρ", .ordinary), "sigma": ("σ", .ordinary), "varsigma": ("ς", .ordinary),
        "tau": ("τ", .ordinary), "upsilon": ("υ", .ordinary), "phi": ("φ", .ordinary),
        "varphi": ("φ", .ordinary), "chi": ("χ", .ordinary), "psi": ("ψ", .ordinary),
        "omega": ("ω", .ordinary),
        // Greek uppercase.
        "Gamma": ("Γ", .ordinary), "Delta": ("Δ", .ordinary), "Theta": ("Θ", .ordinary),
        "Lambda": ("Λ", .ordinary), "Xi": ("Ξ", .ordinary), "Pi": ("Π", .ordinary),
        "Sigma": ("Σ", .ordinary), "Upsilon": ("Υ", .ordinary), "Phi": ("Φ", .ordinary),
        "Psi": ("Ψ", .ordinary), "Omega": ("Ω", .ordinary),
        // Large operators.
        "sum": ("∑", .largeOperator), "prod": ("∏", .largeOperator),
        "int": ("∫", .largeOperator), "iint": ("∬", .largeOperator),
        "oint": ("∮", .largeOperator), "bigcup": ("⋃", .largeOperator),
        "bigcap": ("⋂", .largeOperator),
        // Binary operators.
        "pm": ("±", .binary), "mp": ("∓", .binary), "times": ("×", .binary),
        "div": ("÷", .binary), "cdot": ("⋅", .binary), "ast": ("∗", .binary),
        "cup": ("∪", .binary), "cap": ("∩", .binary), "setminus": ("∖", .binary),
        "oplus": ("⊕", .binary), "otimes": ("⊗", .binary), "wedge": ("∧", .binary),
        "vee": ("∨", .binary), "circ": ("∘", .binary),
        // Relations.
        "leq": ("≤", .relation), "le": ("≤", .relation), "geq": ("≥", .relation),
        "ge": ("≥", .relation), "neq": ("≠", .relation), "ne": ("≠", .relation),
        "equiv": ("≡", .relation), "approx": ("≈", .relation), "sim": ("∼", .relation),
        "simeq": ("≃", .relation), "cong": ("≅", .relation), "propto": ("∝", .relation),
        "subset": ("⊂", .relation), "supset": ("⊃", .relation),
        "subseteq": ("⊆", .relation), "supseteq": ("⊇", .relation),
        "in": ("∈", .relation), "ni": ("∋", .relation), "notin": ("∉", .relation),
        "to": ("→", .relation), "rightarrow": ("→", .relation),
        "leftarrow": ("←", .relation), "Rightarrow": ("⇒", .relation),
        "Leftarrow": ("⇐", .relation), "leftrightarrow": ("↔", .relation),
        "Leftrightarrow": ("⇔", .relation), "mapsto": ("↦", .relation),
        "ll": ("≪", .relation), "gg": ("≫", .relation),
        "perp": ("⊥", .relation), "parallel": ("∥", .relation),
        "mid": ("∣", .relation),
        // Ordinary symbols.
        "infty": ("∞", .ordinary), "partial": ("∂", .ordinary),
        "nabla": ("∇", .ordinary), "forall": ("∀", .ordinary),
        "exists": ("∃", .ordinary), "nexists": ("∄", .ordinary),
        "emptyset": ("∅", .ordinary), "varnothing": ("∅", .ordinary),
        "hbar": ("ℏ", .ordinary), "ell": ("ℓ", .ordinary),
        "Re": ("ℜ", .ordinary), "Im": ("ℑ", .ordinary),
        "aleph": ("ℵ", .ordinary), "prime": ("′", .ordinary),
        "angle": ("∠", .ordinary), "degree": ("°", .ordinary),
        "neg": ("¬", .ordinary), "lnot": ("¬", .ordinary),
        "dots": ("…", .ordinary), "ldots": ("…", .ordinary),
        "cdots": ("⋯", .ordinary), "vdots": ("⋮", .ordinary), "ddots": ("⋱", .ordinary),
        "therefore": ("∴", .relation), "because": ("∵", .relation),
        // Escaped literals.
        "{": ("{", .opening), "}": ("}", .closing),
        "$": ("$", .ordinary), "%": ("%", .ordinary), "&": ("&", .ordinary),
        "#": ("#", .ordinary),
    ]

    /// True when the parse tree contains no `.unsupported` leaves — the
    /// renderer uses this to decide native rendering vs. styled fallback.
    public static func isFullySupported(_ node: MathNode) -> Bool {
        switch node {
        case .unsupported:
            return false
        case .symbol, .space, .functionName:
            return true
        case .row(let children):
            return children.allSatisfy(isFullySupported)
        case .fraction(let n, let d):
            return isFullySupported(n) && isFullySupported(d)
        case .radical(let degree, let radicand):
            return (degree.map(isFullySupported) ?? true) && isFullySupported(radicand)
        case .scripts(let base, let sub, let sup):
            return isFullySupported(base)
                && (sub.map(isFullySupported) ?? true)
                && (sup.map(isFullySupported) ?? true)
        case .delimited(_, let body, _):
            return isFullySupported(body)
        case .matrix(let rows, _, _, _):
            return rows.allSatisfy { $0.allSatisfy(isFullySupported) }
        case .accent(let base, _):
            return isFullySupported(base)
        case .genfrac(let top, let bottom, _, _, _):
            return isFullySupported(top) && isFullySupported(bottom)
        case .overUnder(let base, let over, let under, _):
            return isFullySupported(base)
                && (over.map(isFullySupported) ?? true)
                && (under.map(isFullySupported) ?? true)
        case .decorated(let base, _):
            return isFullySupported(base)
        case .styled(let base, _):
            return isFullySupported(base)
        }
    }

    /// The distinct commands that degraded this expression to source
    /// fallback, in first-seen order (deduped, capped). `isFullySupported`
    /// answers "did it degrade"; this answers "on WHAT" so the fallback
    /// card can name the culprit instead of a generic apology.
    public static func unsupportedCommands(in node: MathNode, limit: Int = 4) -> [String] {
        var seen: Set<String> = []
        var ordered: [String] = []
        func walk(_ node: MathNode) {
            switch node {
            case .unsupported(let raw):
                // The payload is the raw token ("\\foo" or a stray char).
                // Only surface real letter-commands (`\word`) — structural
                // noise like a stray `\\` row separator isn't a nameable
                // culprit and would just confuse the caption.
                let name = raw.hasPrefix("\\") ? raw : "\\" + raw
                let body = name.dropFirst()
                guard !body.isEmpty, body.allSatisfy(\.isLetter) else { break }
                if seen.insert(name).inserted { ordered.append(name) }
            case .symbol, .space, .functionName:
                break
            case .row(let children):
                children.forEach(walk)
            case .fraction(let n, let d):
                walk(n); walk(d)
            case .radical(let degree, let radicand):
                degree.map(walk); walk(radicand)
            case .scripts(let base, let sub, let sup):
                walk(base); sub.map(walk); sup.map(walk)
            case .delimited(_, let body, _):
                walk(body)
            case .matrix(let rows, _, _, _):
                rows.forEach { $0.forEach(walk) }
            case .accent(let base, _):
                walk(base)
            case .genfrac(let top, let bottom, _, _, _):
                walk(top); walk(bottom)
            case .overUnder(let base, let over, let under, _):
                walk(base); over.map(walk); under.map(walk)
            case .decorated(let base, _):
                walk(base)
            case .styled(let base, _):
                walk(base)
            }
        }
        walk(node)
        return Array(ordered.prefix(limit))
    }
}

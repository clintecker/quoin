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
    /// Something we don't understand — rendered as literal marked source
    /// (the PRD rule: unknown input degrades, never errors).
    case unsupported(String)
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
}

/// Column alignment for a `.matrix` grid.
public enum MathMatrixStyle: Hashable, Sendable {
    case centered   // matrix / pmatrix / bmatrix …
    case cases      // left-aligned columns (a `cases` list)
    case aligned    // alternating right/left, meeting at the `&` (aligned/align)
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
        if ch.isLetter {
            return .symbol(String(ch), .ordinary, style: .italic)
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
            return .symbol(String(ch), .ordinary, style: .roman)
        }
    }

    private static func commandNode(_ name: String, _ tokens: inout ArraySlice<Token>) -> MathNode {
        // Structural commands.
        switch name {
        case "frac", "tfrac", "dfrac":
            let numerator = parseAtom(&tokens) ?? .row([])
            let denominator = parseAtom(&tokens) ?? .row([])
            return .fraction(numerator: numerator, denominator: denominator)

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

        case "mathbb", "mathcal", "mathbf":
            let inner = parseAtom(&tokens) ?? .row([])
            return styledLetters(inner, command: name)

        case "begin":
            return parseEnvironment(&tokens)

        // Spacing.
        case ",": return .space(3.0 / 18.0)
        case ":": return .space(4.0 / 18.0)
        case ";": return .space(5.0 / 18.0)
        case "quad": return .space(1.0)
        case "qquad": return .space(2.0)
        case " ": return .space(6.0 / 18.0)

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

    /// Blackboard/calligraphic letter mapping (ℝ, 𝒞 …).
    private static func styledLetters(_ node: MathNode, command: String) -> MathNode {
        func map(_ s: String) -> String {
            guard command == "mathbb" else { return s }
            let bb: [Character: String] = [
                "C": "ℂ", "H": "ℍ", "N": "ℕ", "P": "ℙ", "Q": "ℚ", "R": "ℝ", "Z": "ℤ",
            ]
            return s.count == 1 ? (bb[s.first!] ?? s) : s
        }
        switch node {
        case .symbol(let s, let cls, _):
            return .symbol(map(s), cls, style: command == "mathbf" ? .roman : .roman)
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
        }
    }
}

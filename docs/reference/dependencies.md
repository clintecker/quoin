# Dependencies

Quoin's policy (CLAUDE.md / TRD): **one third-party code dependency**
(swift-markdown). First-party engine packages (MermaidKit, Vinculum) are
exempt. Anything else requires written justification here BEFORE it lands,
plus an allowlist entry in `scripts/check-dependency-policy.sh` (which
enforces this against both `Package.swift` and `Package.resolved`).

The resolved graph today:

| Package | Kind | Pin | Role |
| :--- | :--- | :--- | :--- |
| [swift-markdown](https://github.com/swiftlang/swift-markdown) | third-party (approved) | `from: 0.8.0` | The cmark-gfm parser; the entire AST |
| swift-cmark | transitive (under swift-markdown) | — | cmark-gfm itself |
| [MermaidKit](https://github.com/clintecker/MermaidKit) | first-party | `from: 0.10.0` | Native Mermaid diagram engine |
| [Vinculum](https://github.com/clintecker/Vinculum) | first-party | `from: 0.23.0` | Native LaTeX math engine |

## swift-markdown (third-party — approved, shipping)

The cmark-gfm wrapper. The entire product is built on its AST; writing a
CommonMark+GFM parser is a multi-year project with an enormous
compatibility surface. Apache 2.0, Apple-maintained. Pulls swift-cmark
transitively (the same lineage). Attribution ships in
About ▸ Acknowledgements.

## MermaidKit (first-party — shipping)

Quoin's own published package (github.com/clintecker/MermaidKit) — exempt
from the third-party policy; allowlisted in the policy script. Consumed
from GitHub exactly as any host app would, so the engine is developed and
tested (its own CI) independently of Quoin. Layout/render split behind a
`DiagramTheme` seam; `QuoinCore` re-exports `MermaidLayout` (parse +
layout, platform-free) and `QuoinRender` uses `MermaidRender`.

**Linux backend note (v0.11.0+):** MermaidKit's Linux rasterization uses
PureSwift/Silica (Cairo/FreeType). Because a version-pinned package may not
transitively depend on an unstable ref, and because Quoin's macOS build
should not drag in Cairo, this backend must be OPT-IN (a package trait) so
the default MermaidKit graph Quoin consumes stays Silica-free on Apple
platforms. Quoin is pinned to `0.10.0` until MermaidKit ships that
gating; the bump follows. (Silica evaluation: `road-to-1.0.md` #84.)

## Vinculum (first-party — shipping)

Quoin's own published package (github.com/clintecker/Vinculum) — the LaTeX
math engine, extracted from the in-repo typesetter (see
[../history/math-extraction.md](../history/math-extraction.md) and
[adr/0003](adr/0003-first-party-engines.md)). Same policy exemption and
allowlist entry as MermaidKit. Layout/render split behind a `MathTheme`
seam; `QuoinCore` re-exports `VinculumLayout` (parse + typesetting
geometry → device-independent `MathScene`, platform-free) and
`QuoinRender` uses `VinculumRender` (CoreText/CoreGraphics). ~400 commands;
the exhaustive matrix lives in Vinculum's own `docs/COVERAGE.md` /
`docs/COMMANDS.md`, not here (duplicated matrices drift — the 23-vs-30
lesson in [adr/0003](adr/0003-first-party-engines.md)).

## Sparkle 2.x (JUSTIFIED 2026-07-10, not yet wired — road-to-1.0 #87)

**Decision context:** direct distribution (no App Store). A direct-distro
app without an updater strands every shipped bug forever — users will not
re-download DMGs. Update delivery is a launch requirement.

**Why not build it:** a safe self-updater is security-critical
infrastructure (EdDSA-signed appcasts, delta application, atomic app
replacement, rollback, sandbox-safe XPC install). Sparkle 2.x is the Mac
standard, actively maintained, MIT, with a documented threat model. A
hand-rolled updater would be *less* safe — the policy's intent (minimize
risk) argues FOR Sparkle here.

**Privacy interaction:** the update check is Quoin's ONLY network traffic.
Privacy copy must say exactly that, and the check must be user-disableable
(default on with a first-run disclosure).

**Scope:** App target ONLY (App/macOS project) — QuoinCore/QuoinRender stay
dependency-clean and Linux-buildable. The policy script gains `sparkle` in
`approved_identities` in the same commit that adds the package.

**Prerequisites (see road-to-1.0 Phase D):** an Apple Developer ID +
notarization (the app is ad-hoc signed today), an appcast host, an EdDSA
key pair (private key in the keychain, NEVER the repo), and a notarize
script feeding the appcast. Design doc: `docs/design/distribution.md`
(to be written before wiring).

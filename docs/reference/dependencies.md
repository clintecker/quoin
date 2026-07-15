# Dependency justifications

Quoin's policy (CLAUDE.md / TRD): ONE third-party code dependency
(swift-markdown); MermaidKit is first-party. Anything new requires written
justification here BEFORE it lands, and an allowlist entry in
`scripts/check-dependency-policy.sh`.

## swift-markdown (approved, shipping)

The cmark-gfm wrapper. The entire product is built on its AST; writing a
CommonMark+GFM parser is a multi-year project with an enormous
compatibility surface. Apache 2.0, Apple-maintained. Attribution ships in
About ▸ Acknowledgements.

## MermaidKit (first-party, shipping)

Quoin's own published package (github.com/clintecker/MermaidKit) — exempt
from the third-party policy; allowlisted in the policy script.

## Sparkle 2.x (JUSTIFIED 2026-07-10, not yet wired)

**Decision context:** Clint chose DIRECT distribution (no App Store).
A direct-distro app without an updater strands every shipped bug forever —
users will not re-download DMGs. Update delivery is therefore a launch
requirement, not a convenience.

**Why not build it:** a safe self-updater is security-critical
infrastructure: EdDSA-signed appcasts, binary delta application, atomic
app replacement, rollback on failure, sandbox-safe installation via XPC.
Sparkle 2.x is the industry standard (used by transmission of trust for a
decade of Mac apps), actively maintained, MIT-licensed, and its threat
model is documented and audited. A hand-rolled updater would be *less*
safe than the dependency — the policy's intent (minimize risk and bloat)
argues FOR Sparkle here.

**Privacy interaction:** the update check is Quoin's ONLY network traffic.
Privacy copy must say exactly that, and the check must be user-disableable
(Settings toggle, default on with a first-run disclosure).

**Scope of integration:** App target only (App/macOS/project.yml
packages) — QuoinCore/QuoinRender stay dependency-free and Linux-clean.
The policy script must gain `sparkle` in `approved_identities` in the same
commit that adds the package.

**Prerequisites before wiring:** an appcast host (static file on
clintecker.com or GitHub Pages), an EdDSA key pair (generate with
Sparkle's `generate_keys`, store the private key in the keychain, NEVER in
the repo), and `scripts/notarize.sh` output feeding the appcast.

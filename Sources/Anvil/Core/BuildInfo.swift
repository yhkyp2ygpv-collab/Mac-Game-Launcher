/// Facts about how this copy was built. scripts/build_editions.sh replaces this file with
/// a generated one for each edition; this checked-in copy is what an ordinary
/// `swift build` or build_app.sh uses — the private edition.
enum BuildInfo {
    /// "private" — Jay's own copy, nothing locked — or "public", the one in the .dmg.
    static let edition = "private"
    /// The Apple Developer team the public edition is signed by, when it is; nil for an
    /// ad-hoc signature.
    static let signingTeam: String? = nil
}

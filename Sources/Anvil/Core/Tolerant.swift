import Foundation

/// Decoding that survives the app gaining a setting.
///
/// Swift's synthesised `Decodable` treats a missing key as a hard failure even when
/// the property has a default. `Migration` layers stored JSON over an encoded
/// default to work around that, but it can only fill in keys the template contains —
/// and a template cannot contain the inside of an optional it left `nil`.
///
/// That gap emptied real libraries. A stored `upscalerOverride` written before
/// `flowDivisor` existed could not be repaired, because the `Game` template used for
/// repair had no `upscalerOverride` at all. The whole file then failed to decode and
/// was set aside, which reads as "Anvil lost my games".
///
/// So the nested configuration types decode key by key here, taking their own
/// default for anything absent. A file written by an earlier build stays readable,
/// and one written by a *later* build stays readable too.

/// A coding key built from a plain string, so these initialisers don't depend on the
/// private `CodingKeys` the compiler synthesises inside each type.
struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ s: String) { stringValue = s }
    init?(stringValue s: String) { stringValue = s }
    init?(intValue: Int) { nil }
}

extension KeyedDecodingContainer where Key == AnyKey {
    /// The stored value, or the supplied default when the key is missing, null, or
    /// of a shape this build no longer understands.
    func value<T: Decodable>(_ name: String, _ fallback: T) -> T {
        // `try?` flattens the optional decodeIfPresent returns, so this single guard
        // covers all three cases that must fall back: key absent, value null, and a
        // value of a shape this build no longer understands.
        guard let decoded = try? decodeIfPresent(T.self, forKey: AnyKey(name)) else { return fallback }
        return decoded
    }

    func optional<T: Decodable>(_ name: String) -> T? {
        (try? decodeIfPresent(T.self, forKey: AnyKey(name))) ?? nil
    }
}

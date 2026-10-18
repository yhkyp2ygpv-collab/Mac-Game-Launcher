import Foundation
import Security
import CryptoKit

/// Who signed a Windows program, checked the way Windows checks it (Authenticode), before
/// Anvil runs an installer it didn't build: the program's own digest, the signature over it,
/// and the certificates up to an authority this Mac trusts.
///
/// Apple's CMS decoder turns Authenticode's PKCS #7 away (errSecUnknownFormat: its content is
/// a SEQUENCE where CMS wants an OCTET STRING), so the few fields needed are read here.
enum Authenticode {
    struct Signature: Equatable {
        /// The signing certificate's subject, e.g. "Microsoft Corporation".
        var signer: String
        /// Its organisation (O=), when it names one.
        var organization: String?
        /// The program's digest matched the one that was signed.
        var digestMatches: Bool
        /// The signature over the signed digest checked out with the signer's key.
        var signatureValid: Bool
        /// The certificates lead to an authority this Mac trusts.
        var trusted: Bool
        var trustDetail: String?

        var isValid: Bool { digestMatches && signatureValid && trusted }
    }

    enum Failure: Error, Equatable { case notAProgram, unsigned, unreadable(String) }

    static func check(_ url: URL) -> Result<Signature, Failure> {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return .failure(.unreadable("can't be read")) }
        return check(data)
    }

    static func check(_ d: Data) -> Result<Signature, Failure> {
        let bytes = [UInt8](d)
        func u16(_ o: Int) -> Int { o + 1 < bytes.count ? Int(bytes[o]) | Int(bytes[o + 1]) << 8 : 0 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        guard bytes.count > 0x200, bytes[0] == 0x4D, bytes[1] == 0x5A else { return .failure(.notAProgram) }
        let pe = u32(0x3C)
        guard pe > 0, pe + 0x100 < bytes.count, bytes[pe] == 0x50, bytes[pe + 1] == 0x45 else { return .failure(.notAProgram) }
        let optional = pe + 24
        let magic = u16(optional)
        guard magic == 0x10B || magic == 0x20B else { return .failure(.notAProgram) }
        let checksum = optional + 64
        let securityEntry = optional + (magic == 0x20B ? 112 : 96) + 4 * 8
        let certOffset = u32(securityEntry), certSize = u32(securityEntry + 4)
        guard certSize > 8, certOffset > securityEntry, certOffset + certSize <= bytes.count else { return .failure(.unsigned) }
        let length = u32(certOffset)
        guard u16(certOffset + 6) == 2, length > 8, certOffset + length <= bytes.count else { return .failure(.unsigned) }
        let pkcs7 = Array(bytes[(certOffset + 8)..<(certOffset + length)])

        guard let parts = SignedData(pkcs7) else { return .failure(.unreadable("its signature isn't in a form Anvil reads")) }

        // The program's digest, as Authenticode takes it: everything but the checksum, the pointer
        // to the signature and the signature itself.
        func digest(_ ranges: [Range<Int>]) -> [UInt8] {
            switch parts.contentDigestAlgorithm {
            case .sha256:
                var h = SHA256(); for r in ranges where !r.isEmpty { h.update(data: d[r]) }; return Array(h.finalize())
            case .sha1:
                var h = Insecure.SHA1(); for r in ranges where !r.isEmpty { h.update(data: d[r]) }; return Array(h.finalize())
            }
        }
        let programRanges = [0..<checksum, (checksum + 4)..<securityEntry, (securityEntry + 8)..<certOffset,
                             min(certOffset + certSize, bytes.count)..<bytes.count]
        let digestMatches = digest(programRanges) == parts.programDigest

        // The signed attributes carry the digest of the signed content; the signature is over them.
        let contentDigest: [UInt8]
        switch parts.signerDigestAlgorithm {
        case .sha256: contentDigest = Array(SHA256.hash(data: Data(parts.contentValue)))
        case .sha1: contentDigest = Array(Insecure.SHA1.hash(data: Data(parts.contentValue)))
        }
        let certificates = parts.certificates.compactMap { SecCertificateCreateWithData(nil, Data($0) as CFData) }
        let signerCert = certificates.first { cert in
            guard let serial = SecCertificateCopySerialNumberData(cert, nil) as Data? else { return false }
            return Array(serial).drop { $0 == 0 } == parts.signerSerial.drop { $0 == 0 }
        }
        var signatureValid = false
        if let signerCert, parts.messageDigest == contentDigest, let key = SecCertificateCopyKey(signerCert) {
            let algorithm: SecKeyAlgorithm = parts.signerDigestAlgorithm == .sha256 ? .rsaSignatureMessagePKCS1v15SHA256 : .rsaSignatureMessagePKCS1v15SHA1
            signatureValid = SecKeyVerifySignature(key, algorithm, Data(parts.signedAttributes) as CFData, Data(parts.signature) as CFData, nil)
        }

        var trusted = false
        var trustDetail: String?
        if let signerCert {
            let others = certificates.filter { $0 != signerCert }
            func evaluate(anchors: [SecCertificate]?) -> (Bool, String?) {
                var trust: SecTrust?
                guard SecTrustCreateWithCertificates(([signerCert] + others) as CFArray, SecPolicyCreateBasicX509(), &trust) == errSecSuccess,
                      let trust else { return (false, "its certificates couldn't be read") }
                if let anchors {
                    SecTrustSetAnchorCertificates(trust, anchors as CFArray)
                    SecTrustSetAnchorCertificatesOnly(trust, true)
                }
                // A signature made while its certificate was current stays good; Windows says the same
                // once the signature carries a timestamp, which every Microsoft redistributable does.
                if let issued = signingTime(parts) { SecTrustSetVerifyDate(trust, issued as CFDate) }
                SecTrustSetNetworkFetchAllowed(trust, false)
                var error: CFError?
                let ok = SecTrustEvaluateWithError(trust, &error)
                return (ok, error.map { CFErrorCopyDescription($0) as String })
            }
            (trusted, trustDetail) = evaluate(anchors: nil)
            // macOS doesn't carry Microsoft's code-signing root, so its Code Signing PCA is pinned
            // here: when the signature brings that very certificate, the signer's must chain to it.
            if !trusted, let pinned = others.first(where: { cert in
                Self.pinnedAuthorities.contains(Array(SHA256.hash(data: SecCertificateCopyData(cert) as Data)))
            }) {
                let (ok, why) = evaluate(anchors: [pinned])
                trusted = ok
                trustDetail = ok ? "issued by \(SecCertificateCopySubjectSummary(pinned) as String? ?? "a pinned authority"), which Anvil knows by its fingerprint" : why
            }
        }
        let summary = signerCert.flatMap { SecCertificateCopySubjectSummary($0) as String? } ?? "unknown"
        var organization: String?
        if let signerCert, let values = SecCertificateCopyValues(signerCert, [kSecOIDX509V1SubjectName] as CFArray, nil) as? [CFString: Any],
           let subject = values[kSecOIDX509V1SubjectName] as? [CFString: Any],
           let fields = subject[kSecPropertyKeyValue] as? [[CFString: Any]] {
            organization = fields.first { ($0[kSecPropertyKeyLabel] as? String) == (kSecOIDOrganizationName as String) }?[kSecPropertyKeyValue] as? String
        }
        return .success(Signature(signer: summary, organization: organization, digestMatches: digestMatches,
                                  signatureValid: signatureValid, trusted: trusted, trustDetail: trustDetail))
    }

    /// Certificate authorities trusted by their SHA-256 fingerprint, for publishers whose root
    /// macOS doesn't carry. Microsoft Code Signing PCA 2011 (SHA-1 thumbprint
    /// f252e794fe438e35ace6e53762c0a234a2c52135, as Microsoft publishes it), which signs the
    /// Visual C++ Redistributable: taken from the copy Epic delivered with Cat Quest II.
    static let pinnedAuthorities: Set<[UInt8]> = [
        hex("56da8722afd94066ffe1e4595473a4854892b843a0827d53fb7d8f4aeed1e18b"),
    ]

    static func hex(_ s: String) -> [UInt8] {
        var out: [UInt8] = []
        var i = s.startIndex
        while i < s.endIndex, let j = s.index(i, offsetBy: 2, limitedBy: s.endIndex), let v = UInt8(s[i..<j], radix: 16) {
            out.append(v); i = j
        }
        return out
    }

    /// When the signature was made: the timestamp's signing time, else the signer's own.
    private static func signingTime(_ parts: SignedData) -> Date? { parts.signingTime }

    // MARK: - The PKCS #7 fields Authenticode uses

    enum Hash { case sha1, sha256 }

    struct SignedData {
        var contentDigestAlgorithm: Hash
        var programDigest: [UInt8]
        /// SpcIndirectDataContent's value, without its own tag and length: what messageDigest covers.
        var contentValue: [UInt8]
        var certificates: [[UInt8]]
        var signerSerial: [UInt8]
        var signerDigestAlgorithm: Hash
        /// The signed attributes as signed: re-tagged as a SET.
        var signedAttributes: [UInt8]
        var messageDigest: [UInt8]
        var signature: [UInt8]
        var signingTime: Date?

        init?(_ b: [UInt8]) {
            guard let contentInfo = DER(b, 0), contentInfo.tag == 0x30,
                  let oid = contentInfo.children(b).first, oid.tag == 0x06,
                  let explicit = contentInfo.children(b).dropFirst().first, explicit.tag == 0xA0,
                  let signedData = explicit.children(b).first, signedData.tag == 0x30 else { return nil }
            let fields = signedData.children(b)
            guard fields.count >= 4, let inner = fields.first(where: { $0.tag == 0x30 }),
                  let innerParts = Optional(inner.children(b)), innerParts.count >= 2,
                  innerParts[1].tag == 0xA0, let spc = innerParts[1].children(b).first, spc.tag == 0x30 else { return nil }
            contentValue = Array(b[spc.valueStart..<spc.end])
            // SpcIndirectDataContent ::= SEQUENCE { data, messageDigest DigestInfo }
            guard let digestInfo = spc.children(b).last, digestInfo.tag == 0x30,
                  let algorithm = digestInfo.children(b).first, let algOID = algorithm.children(b).first,
                  let value = digestInfo.children(b).last, value.tag == 0x04,
                  let hash = Self.hash(Array(b[algOID.valueStart..<algOID.end])) else { return nil }
            contentDigestAlgorithm = hash
            programDigest = Array(b[value.valueStart..<value.end])
            certificates = fields.first { $0.tag == 0xA0 }?.children(b).map { Array(b[$0.start..<$0.end]) } ?? []
            guard let signerInfos = fields.last, signerInfos.tag == 0x31,
                  let signer = signerInfos.children(b).first else { return nil }
            let s = signer.children(b)
            guard s.count >= 5, let issuerSerial = Optional(s[1].children(b)), issuerSerial.count == 2,
                  let signerAlg = s[2].children(b).first, let signerHash = Self.hash(Array(b[signerAlg.valueStart..<signerAlg.end])),
                  let attrs = s.first(where: { $0.tag == 0xA0 }),
                  let sig = s.first(where: { $0.tag == 0x04 }) else { return nil }
            signerSerial = Array(b[issuerSerial[1].valueStart..<issuerSerial[1].end])
            signerDigestAlgorithm = signerHash
            var set = Array(b[attrs.start..<attrs.end]); set[0] = 0x31
            signedAttributes = set
            signature = Array(b[sig.valueStart..<sig.end])
            var digest: [UInt8] = []
            for attribute in attrs.children(b) {
                let a = attribute.children(b)
                guard a.count == 2, a[0].tag == 0x06 else { continue }
                let id = Array(b[a[0].valueStart..<a[0].end])
                if id == [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x09, 0x04], let v = a[1].children(b).first, v.tag == 0x04 {
                    digest = Array(b[v.valueStart..<v.end])
                }
            }
            messageDigest = digest
            // The countersignature's time, from the unsigned attributes, is when it was signed.
            signingTime = Self.firstTime(in: b, from: signer.start, to: signer.end)
        }

        static func hash(_ oid: [UInt8]) -> Hash? {
            if oid == [0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01] { return .sha256 }
            if oid == [0x2B, 0x0E, 0x03, 0x02, 0x1A] { return .sha1 }
            return nil
        }

        /// When it was signed: the RFC 3161 timestamp's genTime (TSTInfo, in the unsigned attributes —
        /// how Microsoft timestamps), else the signer's own signingTime attribute.
        static func firstTime(in b: [UInt8], from: Int, to: Int) -> Date? {
            let tstInfo: [UInt8] = [0x06, 0x0B, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x09, 0x10, 0x01, 0x04]
            let signingTime: [UInt8] = [0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x09, 0x05]
            for (oid, reach) in [(tstInfo, 400), (signingTime, 40)] {
                var i = from
                while i + oid.count < to {
                    if b[i] == oid[0], Array(b[i..<(i + oid.count)]) == oid {
                        var j = i + oid.count
                        while j < min(to, i + reach) {
                            if b[j] == 0x17 || b[j] == 0x18, let t = DER(b, j), t.end - t.valueStart >= 13, t.end - t.valueStart <= 24,
                               let date = time(b[t.valueStart..<t.end], generalized: b[j] == 0x18) {
                                return date
                            }
                            j += 1
                        }
                    }
                    i += 1
                }
            }
            return nil
        }

        /// "yyMMddHHmmssZ" (UTCTime) or "yyyyMMddHHmmss[.fff]Z" (GeneralizedTime).
        static func time(_ bytes: ArraySlice<UInt8>, generalized: Bool) -> Date? {
            var text = String(decoding: bytes, as: UTF8.self)
            guard text.hasSuffix("Z"), text.allSatisfy({ $0.isNumber || $0 == "Z" || $0 == "." }) else { return nil }
            if let dot = text.firstIndex(of: ".") { text = String(text[..<dot]) + "Z" }
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = generalized ? "yyyyMMddHHmmss'Z'" : "yyMMddHHmmss'Z'"
            return f.date(from: text)
        }
    }

    /// One DER element: where it starts, its value, where it ends.
    struct DER {
        var tag: UInt8
        var start: Int
        var valueStart: Int
        var end: Int

        init?(_ b: [UInt8], _ at: Int) {
            guard at + 2 <= b.count else { return nil }
            tag = b[at]
            start = at
            var length = Int(b[at + 1])
            var header = 2
            if length & 0x80 != 0 {
                let n = length & 0x7F
                guard n > 0, n <= 4, at + 2 + n <= b.count else { return nil }
                length = 0
                for k in 0..<n { length = length << 8 | Int(b[at + 2 + k]) }
                header += n
            }
            valueStart = at + header
            end = valueStart + length
            guard end <= b.count else { return nil }
        }

        /// The elements inside a constructed one.
        func children(_ b: [UInt8]) -> [DER] {
            guard tag & 0x20 != 0 else { return [] }
            var out: [DER] = []
            var i = valueStart
            while i < end, let child = DER(b, i) {
                out.append(child)
                i = child.end
            }
            return out
        }
    }
}

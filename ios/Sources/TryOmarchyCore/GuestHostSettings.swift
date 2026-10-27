import Foundation

/// Host settings the guest reads from the `tryomarchy.host` credential.
///
/// The iOS shell does not claim a VirGL display. Omarchy's text console is
/// what the framebuffer shows; the Mac-only cursor and display-sync profile
/// stays off.
public enum GuestHostSettings {
    public static func locale(preferredLanguages: [String]) -> String {
        let language = Locale.Language(identifier: preferredLanguages.first ?? "en")
        if language.languageCode?.identifier == "ko" { return "ko_KR.UTF-8" }
        if language.languageCode?.identifier == "ja" { return "ja_JP.UTF-8" }
        guard language.languageCode?.identifier == "zh" else { return "en_US.UTF-8" }
        return language.script?.identifier == "Hant" ? "zh_TW.UTF-8" : "zh_CN.UTF-8"
    }

    /// `nil` when the zone name cannot travel in a single credential token.
    public static func line(locale: String, timeZone: String) -> String? {
        let tokens = [
            "tryomarchy.keyboard=ansi",
            "tryomarchy.locale=\(locale)",
            "tryomarchy.timezone=\(timeZone)",
        ]
        let line = tokens.joined(separator: " ")
        guard line.allSatisfy({ !$0.isNewline }), !line.contains(",") else { return nil }
        guard locale.hasSuffix(".UTF-8"), timeZone.allSatisfy({ $0.isLetter || $0.isNumber || "/_+-".contains($0) }) else {
            return nil
        }
        return line
    }

    public static func credentialValue(_ line: String) -> String {
        let encoded = Data(line.utf8).base64EncodedString()
        return "io.systemd.credential.binary:tryomarchy.host=\(encoded)"
    }
}

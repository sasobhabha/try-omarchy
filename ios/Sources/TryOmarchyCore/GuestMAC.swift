import CryptoKit
import Foundation

/// A stable locally administered unicast address for the guest NIC.
enum GuestMAC {
    static func address(seed: String) -> String {
        let digest = Array(SHA256.hash(data: Data(seed.utf8)))
        let first = (digest[0] & 0xFC) | 0x02
        return ([first] + digest[1...5]).map { String(format: "%02x", $0) }.joined(separator: ":")
    }
}

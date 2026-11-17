import Foundation
import CryptoKit

/// Two device-native channels. Lead names follow the interoperability evidence
/// credited in README; amplitude and polarity have not been independently calibrated.
struct Sample {
    let i: Int16
    let ii: Int16
    var leads: [Double] {
        // Promote before deriving leads: II - I can exceed the range of Int16.
        // Order is shared by the trace labels and the CSV header.
        let a = Double(i), b = Double(ii)
        return [a, b, b-a, -(a+b)/2, a-b/2, b-a/2]
    }
}

enum KardiaProtocol {
    static let service = "AC060001-328C-A28F-9846-5A8AA212661B"
    static let command = "AC060002-328C-A28F-9846-5A8AA212661B"
    static let ecg = "AC060003-328C-A28F-9846-5A8AA212661B"
    /// Build the observed M2 compatibility command from the advertised local name.
    /// This is a protocol value, not a replacement for normal macOS BLE bonding.
    static func startCommand(name: String) -> Data {
        let digest = SHA256.hash(data: Data(("Triangle" + name).utf8))
        let token = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return Data(("M2 K" + token).utf8)
    }
    /// Accept only the observed M2 frame: nine interleaved I/II pairs, 4 bytes each.
    /// A matching length does not prove the requested mode, signal quality or no loss.
    static func decode(_ data: Data) -> [Sample]? {
        guard data.count == 36 else { return nil }
        let bytes = Array(data)
        var samples: [Sample] = []
        for n in stride(from: 0, to: 36, by: 4) {
            // Decode explicit little-endian words rather than assuming host alignment.
            let first = UInt16(bytes[n]) | (UInt16(bytes[n+1]) << 8)
            let second = UInt16(bytes[n+2]) | (UInt16(bytes[n+3]) << 8)
            samples.append(Sample(i: Int16(bitPattern: first), ii: Int16(bitPattern: second)))
        }
        return samples
    }
}

/// Original notification bytes with host wall-clock and monotonic elapsed time.
/// Neither time is a device-supplied sample timestamp.
struct Packet {
    let received: Date
    let elapsed: Double
    let characteristic: String
    let data: Data
}

enum CaptureExport {
    /// Export valid ECG frames only; packet indices still refer to the full raw list.
    static func csv(_ packets: [Packet]) -> String {
        var text = "# Kardia Reader experimental M2 capture; uncalibrated raw counts; no diagnostic use\n"
        text += "# Sample rate is assumed 300 Hz from third-party firmware 3.0.1 observations, not negotiated.\n"
        text += "# Packet timestamps are host receive times; sample offsets within a packet are inferred.\n"
        text += "packet,received_unix_s,received_elapsed_s,sample_in_packet,I_raw,II_raw,III_raw,aVR_raw,aVL_raw,aVF_raw\n"
        for (index, packet) in packets.enumerated() where packet.characteristic == KardiaProtocol.ecg {
            guard let samples = KardiaProtocol.decode(packet.data) else { continue }
            for (n, sample) in samples.enumerated() {
                // Fix the decimal separator so a Norwegian locale cannot corrupt CSV.
                let values = sample.leads.map { String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), $0) }.joined(separator: ",")
                text += "\(index),\(packet.received.timeIntervalSince1970),\(packet.elapsed),\(n),\(values)\n"
            }
        }
        return text
    }
    /// Preserve every captured vendor notification, including command replies and
    /// unknown ECG payloads, so decoding can be audited independently later.
    static func rawCSV(_ packets: [Packet]) -> String {
        var text = "# Kardia Reader raw notifications; requested_mode=M2; firmware-specific experimental protocol\n"
        text += "received_unix_s,received_elapsed_s,characteristic_uuid,payload_hex\n"
        for p in packets {
            text += "\(p.received.timeIntervalSince1970),\(p.elapsed),\(p.characteristic),\(p.data.map { String(format: "%02x", $0) }.joined())\n"
        }
        return text
    }
}

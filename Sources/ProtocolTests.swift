import Foundation

@main struct ProtocolTests {
    static func main() {
        // Synthetic signed extremes catch byte order, sign extension and arithmetic overflow.
        let pairs: [(Int16, Int16)] = [(.min, .max), (-2000, 2000), (-3, 3), (-2, 2), (-1, 1), (0, 0), (1, -1), (2, -2), (3, -3)]
        var packet = Data()
        for (a, b) in pairs {
            for value in [a, b] {
                let bits = UInt16(bitPattern: value)
                packet.append(UInt8(bits & 255)); packet.append(UInt8(bits >> 8))
            }
        }
        guard let samples = KardiaProtocol.decode(packet) else { fatalError("Valid packet rejected") }
        precondition(samples.count == 9)
        for (sample, expected) in zip(samples, pairs) {
            precondition(sample.i == expected.0 && sample.ii == expected.1, "Signed little-endian decode")
            let leads = sample.leads
            precondition(leads[2] == Double(expected.1)-Double(expected.0))
            precondition(abs(leads[3]+leads[4]+leads[5]) < 0.001, "Augmented lead sum")
        }
        precondition(samples[0].leads[2] == 65535, "Derived leads must not overflow Int16")
        for count in [0, 1, 35, 37, 72] {
            precondition(KardiaProtocol.decode(Data(repeating: 0, count: count)) == nil)
        }
        // Generic public test name, not an individual device's advertised identifier.
        precondition(String(data: KardiaProtocol.startCommand(name: "Kardia6L"), encoding: .utf8) == "M2 Kd8a179a137775575")
        let packets = [
            Packet(received: Date(timeIntervalSince1970: 1234.5), elapsed: 0.5, characteristic: KardiaProtocol.command, data: Data([1])),
            Packet(received: Date(timeIntervalSince1970: 1234.6), elapsed: 0.6, characteristic: KardiaProtocol.ecg, data: packet),
            Packet(received: Date(timeIntervalSince1970: 1234.7), elapsed: 0.7, characteristic: KardiaProtocol.ecg, data: Data([0]))
        ]
        let csv = CaptureExport.csv(packets)
        let rows = csv.split(separator: "\n").filter { !$0.hasPrefix("#") }
        precondition(rows.count == 10, "Only nine valid samples should be exported")
        let fields = rows[1].split(separator: ",")
        precondition(fields.count == 10)
        precondition(fields[0] == "1" && fields[3] == "0")
        precondition(abs(Double(fields[1])! - 1234.6) < 0.00001, "Wall-clock Date precision")
        precondition(fields[4] == "-32768.0" && fields[5] == "32767.0" && fields[6] == "65535.0")
        // Derived CSV rejects the malformed frame, while raw CSV must keep it.
        let raw = CaptureExport.rawCSV(packets).split(separator: "\n").filter { !$0.hasPrefix("#") }
        precondition(raw.count == 4, "Preserve all packets including command and malformed ECG")
        precondition(raw[3].hasSuffix(",00"))
        precondition(CaptureExport.csv([]).split(separator: "\n").filter { !$0.hasPrefix("#") }.count == 1)
        print("PASS: signed M2 decode, length rejection, six-lead arithmetic, command vector, raw packet preservation, CSV integrity, empty export")
    }
}

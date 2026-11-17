import SwiftUI
import AppKit
import CoreBluetooth
import UniformTypeIdentifiers

struct NearbyDevice: Identifiable {
    let id: UUID
    let name: String
    let rssi: Int
}

/// Owns one scan/connection/capture at a time. CoreBluetooth delegates run on the
/// main queue (see search), keeping published UI state and packet buffers serialized.
final class Reader: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published var status = "Klar til å søke"
    @Published var detail = "Lukk Kardia-appen på mobilen. Hold fingrene på de to øverste elektrodene for å vekke 6L."
    @Published var devices: [NearbyDevice] = []
    @Published var busy = false
    @Published var scanning = false
    @Published var active = false
    @Published var battery = "—"
    @Published var firmware = "—"
    @Published var packetCount = 0
    @Published var sampleCount = 0
    @Published var malformedCount = 0
    @Published var seconds = 0.0
    @Published var traces: [[Double]] = Array(repeating: [], count: 6)
    @Published var events: [String] = []
    @Published var hasUnsaved = false
    private var central: CBCentralManager?
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var names: [UUID: String] = [:]
    private var peripheral: CBPeripheral?
    private var command: CBCharacteristic?
    private var ecg: CBCharacteristic?
    private var timeout: Timer?
    private var ticker: Timer?
    private var firstPacketTime: TimeInterval?
    private var lastPacketTime: TimeInterval?
    private var sessionOrigin = ProcessInfo.processInfo.systemUptime
    private var packets: [Packet] = []
    private var pendingServices = 0
    private var commandSent = false
    private var lastUI = 0.0
    private var buffers: [[Double]] = Array(repeating: [], count: 6)
    private let statusURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Kardia Reader/status.json")

    func note(_ message: String) {
        events.append(message)
        if events.count > 100 { events.removeFirst() }
        persistStatus()
    }
    /// A bounded troubleshooting snapshot, deliberately separate from ECG storage.
    /// Do not add payloads, device identifiers or command values to these events.
    func persistStatus() {
        let state: [String: Any] = ["updated": ISO8601DateFormatter().string(from: Date()),
            "status": status, "detail": detail, "busy": busy, "scanning": scanning,
            "active": active, "devices_found": devices.count, "ecg_packets": packetCount,
            "sample_pairs": sampleCount, "malformed_packets": malformedCount,
            "elapsed_seconds": seconds, "events": events]
        do {
            try FileManager.default.createDirectory(at: statusURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: statusURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: statusURL.path)
        } catch { /* Runtime diagnostics must never interrupt acquisition. */ }
    }
    func armTimeout(_ interval: TimeInterval, _ message: String) {
        timeout?.invalidate()
        timeout = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            self?.stop(message)
        }
    }
    func search() {
        guard !busy else { return }
        devices = []; peripherals = [:]; names = [:]
        busy = true
        if central == nil {
            status = "Ber om Bluetooth-tilgang"
            detail = "Godkjenn Bluetooth for Kardia Reader hvis macOS spør."
            central = CBCentralManager(delegate: self, queue: .main)
        } else { beginScan() }
    }
    private func beginScan() {
        guard let central, central.state == .poweredOn else {
            if let central { centralManagerDidUpdateState(central) }
            return
        }
        scanning = true; busy = true
        status = "Søker etter KardiaMobile 6L"
        detail = "Hold fingrene på de øverste elektrodene. Søket varer i 45 sekunder."
        // Unfiltered scan: some firmware omits the service from the initial advertisement.
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        note("Bluetooth-søk startet.")
        armTimeout(45, devices.isEmpty ? "Søket er ferdig. Velg en funnet enhet, eller prøv igjen." : "Søket er ferdig.")
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: if busy && !active && peripheral == nil { beginScan() }
        case .unauthorized:
            stop("Bluetooth-tilgang mangler. Åpne Systeminnstillinger → Personvern og sikkerhet → Bluetooth, og tillat Kardia Reader.")
        case .poweredOff: stop("Bluetooth er avslått. Slå det på i Systeminnstillinger og søk igjen.")
        case .unsupported: stop("Denne Mac-en har ikke tilgjengelig Bluetooth LE.")
        case .resetting: stop("Bluetooth starter på nytt. Prøv igjen om litt.")
        default: status = "Venter på Bluetooth"; persistStatus()
        }
    }
    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard scanning else { return }
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? p.name ?? ""
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [])
            + (advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? [])
        guard name.lowercased().contains("kardia") || services.contains(CBUUID(string: KardiaProtocol.service)) else { return }
        peripherals[p.identifier] = p
        if !name.isEmpty { names[p.identifier] = name }
        let device = NearbyDevice(id: p.identifier, name: name.isEmpty ? "Kardia 6L" : name, rssi: RSSI.intValue)
        if let index = devices.firstIndex(where: { $0.id == p.identifier }) { devices[index] = device }
        else { devices.append(device); note("Fant en Kardia-kandidat. Velg den for å koble til.") }
    }
    func connect(_ id: UUID) {
        guard peripheral == nil, let p = peripherals[id], let central else { return }
        central.stopScan(); timeout?.invalidate(); scanning = false
        // The view confirms discarding an unsaved session before reaching this reset.
        packets = []; buffers = Array(repeating: [], count: 6); traces = buffers
        packetCount = 0; sampleCount = 0; malformedCount = 0; seconds = 0
        battery = "—"; firmware = "—"; hasUnsaved = false
        firstPacketTime = nil; lastPacketTime = nil; commandSent = false
        command = nil; ecg = nil
        sessionOrigin = ProcessInfo.processInfo.systemUptime
        peripheral = p; p.delegate = self; busy = true
        status = "Kobler til 6L"
        detail = "Godkjenn eventuell Bluetooth-paring fra macOS. Hold kontakten med elektrodene."
        note("Tilkobling startet.")
        central.connect(p, options: nil)
        armTimeout(60, "Tilkoblingen tok for lang tid. Vekk 6L og prøv igjen.")
    }
    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        guard p === peripheral else { return }
        status = "Leser enhetens tjenester"
        note("Bluetooth-forbindelsen er opprettet.")
        p.discoverServices([CBUUID(string: KardiaProtocol.service), CBUUID(string: "180A"), CBUUID(string: "180F")])
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        guard p === peripheral else { return }
        stop("Kunne ikke koble til: \(error?.localizedDescription ?? "ukjent feil")")
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        guard p === peripheral else { return }
        stop("Forbindelsen ble brutt\(error.map { ": " + $0.localizedDescription } ?? "."). Opptaket er bevart i minnet.")
    }
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard p === peripheral else { return }
        if let error { stop("Kunne ikke lese tjenester: \(error.localizedDescription)"); return }
        guard let services = p.services, services.contains(where: { $0.uuid == CBUUID(string: KardiaProtocol.service) }) else {
            stop("Denne enheten tilbyr ikke det forventede 6L-grensesnittet."); return
        }
        pendingServices = services.count
        for s in services { p.discoverCharacteristics(nil, for: s) }
    }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard p === peripheral else { return }
        if let error { stop("Kunne ikke lese egenskaper: \(error.localizedDescription)"); return }
        for c in service.characteristics ?? [] {
            switch c.uuid {
            case CBUUID(string: KardiaProtocol.command): command = c
            case CBUUID(string: KardiaProtocol.ecg): ecg = c
            case CBUUID(string: "2A19"), CBUUID(string: "2A26"):
                if c.properties.contains(.read) { p.readValue(for: c) }
            default: break
            }
        }
        // Discovery callbacks may arrive in any service order. Start only after all
        // requested services have completed and the required properties are known.
        pendingServices -= 1
        if pendingServices == 0 {
            guard let command, let ecg,
                  command.properties.contains(.write), command.properties.contains(.indicate),
                  ecg.properties.contains(.notify) else {
                stop("Enhetens egenskaper samsvarer ikke med den kjente 6L-protokollen."); return
            }
            status = "Klargjør datastrøm"
            note("6L-grensesnitt funnet. Aktiverer kommandosvar.")
            p.setNotifyValue(true, for: command)
            armTimeout(45, "Ingen datastrøm. Godkjenn eventuell paring og kontroller elektrodekontakten. Mobilappen må være lukket.")
        }
    }
    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        guard p === peripheral else { return }
        if let error { stop("Kunne ikke aktivere varsling: \(error.localizedDescription)"); return }
        // Startup order: command indications -> M2 write -> ECG notifications.
        // commandSent prevents a repeated notification-state callback sending twice.
        if c.uuid == CBUUID(string: KardiaProtocol.command), c.isNotifying, !commandSent {
            guard let name = names[p.identifier], !name.isEmpty else {
                stop("Enheten annonserte ikke et navn. Kan ikke starte den kjente 6L-protokollen."); return
            }
            commandSent = true
            note("Kommandosvar aktivert. Ber om M2-opptak.")
            p.writeValue(KardiaProtocol.startCommand(name: name), for: c, type: .withResponse)
        } else if c.uuid == CBUUID(string: KardiaProtocol.ecg), c.isNotifying {
            status = "Venter på signal"
            detail = "Hold fingrene på toppen og nederste elektrode mot bar hud på venstre kne for seks avledninger."
            note("Signalvarsling aktivert. Venter på første pakke.")
        }
    }
    func peripheral(_ p: CBPeripheral, didWriteValueFor c: CBCharacteristic, error: Error?) {
        guard p === peripheral else { return }
        if let error { stop("6L avviste opptaksstart: \(error.localizedDescription)"); return }
        if c.uuid == CBUUID(string: KardiaProtocol.command), let ecg {
            // The write callback confirms transport completion, not the reply's meaning.
            // Reply bytes are preserved below; validating their value is still open work.
            note("M2-kommando sendt. Aktiverer signalvarsling.")
            p.setNotifyValue(true, for: ecg)
        }
    }
    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard p === peripheral else { return }
        if let error { stop("Lesefeil: \(error.localizedDescription)"); return }
        guard let data = c.value else { return }
        if c.uuid == CBUUID(string: "2A19") { battery = data.first.map { "\($0) %" } ?? "—"; return }
        if c.uuid == CBUUID(string: "2A26") { firmware = String(data: data, encoding: .utf8) ?? "ukjent"; return }
        let now = ProcessInfo.processInfo.systemUptime
        let uuid = c.uuid.uuidString
        // Preserve bytes before interpretation, including the first malformed frame.
        packets.append(Packet(received: Date(), elapsed: now-sessionOrigin, characteristic: uuid, data: data))
        hasUnsaved = true
        guard c.uuid == CBUUID(string: KardiaProtocol.ecg) else {
            note("Kommandosvar mottatt (\(data.count) byte).")
            return
        }
        packetCount += 1
        guard let frame = KardiaProtocol.decode(data) else {
            malformedCount += 1
            stop("Uventet signalpakke på \(data.count) byte. Opptaket er stoppet uten å tolke ukjent format. Råpakken kan lagres.")
            return
        }
        // The capture duration begins with the first valid ECG frame, excluding setup.
        if firstPacketTime == nil {
            firstPacketTime = now; active = true; timeout?.invalidate()
            status = "Mottar signal"
            detail = "30 sekunders opptak. Visningen bruker rå enheter og automatisk skala."
            note("Første M2-pakke mottatt.")
            ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        }
        lastPacketTime = now
        sampleCount += frame.count
        for s in frame {
            let leads = s.leads
            for n in 0..<6 { buffers[n].append(leads[n]) }
        }
        // Keep every packet in `packets`, but publish only the latest ~5 seconds
        // of display samples at ~10 Hz to reduce SwiftUI redraw work.
        if now-lastUI >= 0.1 {
            for n in 0..<6 { if buffers[n].count > 1500 { buffers[n].removeFirst(buffers[n].count-1500) } }
            traces = buffers; lastUI = now
        }
    }
    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        seconds = now - (firstPacketTime ?? now)
        if seconds >= 30 { stop("Opptaket er ferdig. Du kan lagre råpakker og dekodet CSV.") }
        else if let lastPacketTime, now-lastPacketTime > 3 {
            stop("Ingen nye pakker på tre sekunder. Opptaket er stoppet; mottatte data kan lagres.")
        } else if Int(seconds*10) % 10 == 0 { persistStatus() }
    }
    func stop(_ message: String = "Stoppet. Mottatte data kan lagres.") {
        timeout?.invalidate(); ticker?.invalidate(); timeout = nil; ticker = nil
        central?.stopScan()
        // Clear identity before requesting disconnect so late callbacks from the old
        // peripheral fail their identity guards instead of changing the stopped session.
        let old = peripheral; peripheral = nil
        if let old { central?.cancelPeripheralConnection(old) }
        active = false; scanning = false; busy = false
        traces = buffers.map { Array($0.suffix(1500)) }
        status = packetCount > 0 ? "Opptak stoppet" : "Klar"
        detail = message; note(message)
    }
    func save() {
        guard !busy, !packets.isEmpty else { return }
        let panel = NSSavePanel()
        panel.title = "Lagre opptak lokalt"
        panel.nameFieldStringValue = "Kardia-\(ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-"))"
        panel.prompt = "Lagre mappe"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        do {
            // Fail if an existing folder is selected; never mix sessions or overwrite data.
            guard !FileManager.default.fileExists(atPath: directory.path) else {
                throw NSError(domain: "KardiaReader", code: 1, userInfo: [NSLocalizedDescriptionKey: "Navnet finnes allerede. Velg et nytt navn."])
            }
            // Restrict directory access to its owner. Individual files are atomic,
            // but the three-file export is not a transactional folder write: a failed
            // save can leave a partial folder. The in-memory capture remains available.
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try CaptureExport.rawCSV(packets).write(to: directory.appendingPathComponent("raw-packets.csv"), atomically: true, encoding: .utf8)
            try CaptureExport.csv(packets).write(to: directory.appendingPathComponent("samples.csv"), atomically: true, encoding: .utf8)
            let metadata: [String: Any] = ["app": "Kardia Reader 0.1", "experimental": true,
                "requested_mode": "M2", "assumed_sample_rate_hz": 300, "firmware": firmware,
                "units": "uncalibrated raw counts", "polarity_validated": false,
                "ecg_packets": packetCount, "malformed_packets": malformedCount, "sample_pairs": sampleCount,
                "host_elapsed_seconds": seconds, "diagnostic_use": false,
                "third_party_protocol_reference": "https://github.com/ShaneBreazeale/kardia-rs"]
            try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("metadata.json"), options: .atomic)
            hasUnsaved = false; note("Opptaket ble lagret lokalt.")
            NSWorkspace.shared.activateFileViewerSelecting([directory])
        } catch { detail = "Kunne ikke lagre hele opptaket: \(error.localizedDescription). Dataene er fortsatt i minnet."; note(detail) }
    }
}

struct TraceView: View {
    let name: String
    let points: [Double]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(name).font(.system(.headline, design: .monospaced)).foregroundStyle(.mint)
                Spacer()
                Text("Rå enheter · autoskala").font(.caption).foregroundStyle(.secondary)
            }
            Canvas { context, size in
                var grid = Path()
                for x in stride(from: 0.0, through: size.width, by: 24) { grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height)) }
                for y in stride(from: 0.0, through: size.height, by: 20) { grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y)) }
                context.stroke(grid, with: .color(.white.opacity(0.06)), lineWidth: 0.5)
                guard points.count > 1 else { return }
                // Independent per-trace autoscaling is for visual inspection only.
                // These grid lines have no calibrated time/voltage paper dimensions.
                let low = points.min() ?? 0, high = points.max() ?? 1
                let span = max(200, high-low), center = (low+high)/2
                var path = Path()
                for (n, value) in points.enumerated() {
                    let point = CGPoint(x: Double(n)/1500*size.width, y: size.height/2-(value-center)/span*size.height*0.8)
                    if n == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
                context.stroke(path, with: .color(.mint), lineWidth: 1.2)
            }.frame(height: 100)
        }.padding(14).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct ContentView: View {
    @ObservedObject var reader: Reader
    @State private var pendingDevice: UUID?
    @State private var confirmDiscard = false
    let names = ["I", "II", "III = II − I", "aVR", "aVL", "aVF"]
    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Kardia Reader").font(.system(size: 30, weight: .semibold))
                    Text("KARDIAMOBILE 6L  /  BLUETOOTH LE").font(.system(size: 10, weight: .medium, design: .monospaced)).tracking(2).foregroundStyle(.secondary)
                }
                Spacer()
                Text("EKSPERIMENTELL").font(.system(size: 10, weight: .semibold)).padding(9)
                    .foregroundStyle(.orange).background(.orange.opacity(0.12), in: Capsule())
            }
            HStack(spacing: 10) {
                Circle().fill(reader.active ? .mint : .gray).frame(width: 8, height: 8)
                Text(reader.status).font(.headline)
                Spacer()
                Text("Batteri \(reader.battery)  ·  Firmware \(reader.firmware)").font(.caption).foregroundStyle(.secondary)
            }
            Text(reader.detail).font(.callout).foregroundStyle(.secondary).frame(minHeight: 36, alignment: .topLeading)
            HStack(spacing: 12) {
                Button("Søk etter 6L", systemImage: "antenna.radiowaves.left.and.right") { reader.search() }
                    .buttonStyle(.borderedProminent).tint(.mint).foregroundStyle(.black).disabled(reader.busy)
                if reader.busy { Button("Stopp") { reader.stop() } }
                Button("Lagre opptak…", systemImage: "square.and.arrow.down") { reader.save() }
                    .disabled(reader.busy || !reader.hasUnsaved)
                Spacer()
                Text(String(format: "%.1f / 30 s", reader.seconds)).monospacedDigit().foregroundStyle(.secondary)
            }
            if !reader.devices.isEmpty && (reader.scanning || !reader.busy) {
                VStack(spacing: 8) {
                    ForEach(reader.devices) { device in
                        HStack {
                            Image(systemName: "waveform.path.ecg").foregroundStyle(.mint)
                            Text(device.name)
                            Spacer()
                            Text("\(device.rssi) dBm").font(.caption).foregroundStyle(.secondary)
                            Button("Koble til og ta opp") {
                                if reader.hasUnsaved { pendingDevice = device.id; confirmDiscard = true }
                                else { reader.connect(device.id) }
                            }
                        }
                    }
                }.padding(12).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            }
            HStack(spacing: 24) {
                metric("PAKKER", "\(reader.packetCount)")
                metric("PRØVEPAR", "\(reader.sampleCount)")
                metric("FORMATFEIL", "\(reader.malformedCount)")
                Spacer()
                Text("Viser siste ≈5 s ved antatt 300 Hz").font(.caption).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(0..<6, id: \.self) { n in TraceView(name: names[n], points: reader.traces[n]) }
            }
            DisclosureGroup("Tilkoblingslogg") {
                ScrollView {
                    Text(reader.events.suffix(15).joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }.frame(height: 90)
            }.font(.caption).foregroundStyle(.secondary)
            Text("Uavhengig prototype. Amplitude, polaritet og signalintegritet er ikke medisinsk validert. Ingen diagnose eller pulsberegning. Bruk Kardia-appen til medisinske opptak. Data blir på Mac-en og lagres bare når du velger det.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(28)
        }.frame(minWidth: 780, idealWidth: 900, minHeight: 620, idealHeight: 780)
            .background(Color(red: 0.035, green: 0.055, blue: 0.07)).preferredColorScheme(.dark)
            .alert("Erstatt ulagret opptak?", isPresented: $confirmDiscard) {
                Button("Avbryt", role: .cancel) { pendingDevice = nil }
                Button("Forkast og start", role: .destructive) { if let id = pendingDevice { reader.connect(id) }; pendingDevice = nil }
            } message: { Text("Lagre opptaket først hvis du vil beholde det.") }
    }
    func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 9, weight: .medium)).tracking(1).foregroundStyle(.secondary)
            Text(value).font(.system(size: 21, weight: .medium, design: .monospaced)).monospacedDigit()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var reader: Reader?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // A clean quit can be cancelled; a crash/force-quit still loses unsaved data.
        if reader?.hasUnsaved == true {
            let alert = NSAlert()
            alert.messageText = "Avslutte uten å lagre opptaket?"
            alert.informativeText = "Opptaket finnes bare i minnet. Velg Avbryt og lagre for å beholde det."
            alert.addButton(withTitle: "Avbryt"); alert.addButton(withTitle: "Avslutt uten å lagre")
            if alert.runModal() == .alertFirstButtonReturn { return .terminateCancel }
        }
        reader?.stop("Appen er avsluttet.")
        return .terminateNow
    }
}

@main struct KardiaReaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var reader = Reader()
    var body: some Scene {
        Window("Kardia Reader", id: "main") {
            ContentView(reader: reader).onAppear { delegate.reader = reader; reader.persistStatus() }
        }.defaultSize(width: 900, height: 780)
    }
}

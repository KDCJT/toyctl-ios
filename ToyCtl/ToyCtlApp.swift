// ToyCtl iOS — 通过蓝牙直连 ESP32 的原生控制端
// 需要 Mac + Xcode (iOS 16+) 编译运行; 通讯协议与网页版完全一致(JSON over BLE)。
//
// 连接方式: 扫描名为 "ToyCtl" 的设备 → 连接 → 订阅 OUT 特征 → 写 CMD 特征。
// OUT 数据采用分帧协议: [0x01][seqId][seqIdx][seqTotal][payload...] (应对 MTU 分片)。

import SwiftUI
import CoreBluetooth

let SVC_UUID = CBUUID(string: "B0B0C0DE-F00D-4A11-B1E5-5EED00000001")
let CMD_UUID = CBUUID(string: "B0B0C0DE-F00D-4A11-B1E5-5EED00000002")
let OUT_UUID = CBUUID(string: "B0B0C0DE-F00D-4A11-B1E5-5EED00000003")

struct Toy: Identifiable {
    let addr: String; let name: String; let proto: Int; let vib: Int; let rot: Int
    var id: String { addr }
}

final class BT: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published var ready = false
    @Published var connected = false
    @Published var scanning = false
    @Published var toys: [Toy] = []
    @Published var museLevel = 0
    @Published var museCh = 0
    @Published var fam = "muse"
    @Published var logs: [String] = []

    private var central: CBCentralManager!
    private var peri: CBPeripheral?
    private var cmdChar: CBCharacteristic?
    private var outChar: CBCharacteristic?
    private var frag: [UInt8: [Int: Data]] = [:]

    override init() { super.init(); central = CBCentralManager(delegate: self, queue: nil) }

    // MARK: 对外操作
    func startScan() {
        guard central.state == .poweredOn else { return }
        scanning = true
        central.scanForPeripherals(withServices: nil)
    }
    func stopScan() { central.stopScan(); scanning = false }
    func disconnect() { if let p = peri { central.cancelPeripheralConnection(p) } }
    func send(_ cmd: [String: Any]) {
        guard let ch = cmdChar, connected, let d = try? JSONSerialization.data(withJSONObject: cmd) else { return }
        peri?.writeValue(d, for: ch, type: .withResponse)
    }

    // MARK: CBCentralManagerDelegate
    func centralManagerDidUpdateState(_ c: CBCentralManager) { ready = (c.state == .poweredOn) }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = p.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        guard name.contains("ToyCtl") else { return }
        stopScan()
        peri = p; p.delegate = self
        c.connect(p, options: nil)
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        p.discoverServices([SVC_UUID])
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        pushLog("连接失败: \(error?.localizedDescription ?? "?")")
    }

    // MARK: CBPeripheralDelegate
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let s = p.services?.first(where: { $0.uuid == SVC_UUID }) else { return }
        p.discoverCharacteristics([CMD_UUID, OUT_UUID], for: s)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for ch in s.characteristics ?? [] {
            if ch.uuid == CMD_UUID { cmdChar = ch }
            if ch.uuid == OUT_UUID { outChar = ch; p.setNotifyValue(true, for: ch) }
        }
        connected = true
        send(["t": "hello"])
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor ch: CBCharacteristic, error: Error?) {}

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard ch.uuid == OUT_UUID, let d = ch.value, d.count >= 4, d[0] == 1 else { return }
        let seq = d[1], idx = Int(d[2]), total = Int(d[3])
        frag[seq, default: [:]][idx] = d.subdata(in: 4..<d.count)
        guard let parts = frag[seq], parts.count == total,
              parts.keys.sorted() == Array(0..<total) else { return }
        frag[seq] = nil
        let full = parts.sorted { $0.key < $1.key }.reduce(Data()) { $0 + $1.value }
        handle(full)
    }

    // MARK: 消息处理
    private func pushLog(_ s: String) {
        DispatchQueue.main.async {
            self.logs.insert(s, at: 0)
            if self.logs.count > 80 { self.logs.removeLast(self.logs.count - 80) }
        }
    }

    private func handle(_ d: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
        DispatchQueue.main.async { self.apply(obj) }
    }

    private func apply(_ m: [String: Any]) {
        switch m["t"] as? String {
        case "status":
            if let list = m["toys"] as? [[String: Any]] {
                toys = list.map {
                    Toy(addr: $0["addr"] as? String ?? "",
                        name: $0["name"] as? String ?? "",
                        proto: $0["proto"] as? Int ?? 0,
                        vib: $0["vib"] as? Int ?? 0,
                        rot: $0["rot"] as? Int ?? 0)
                }
            }
            if let mu = m["muse"] as? [String: Any] {
                museLevel = mu["level"] as? Int ?? 0
                museCh = mu["ch"] as? Int ?? 0
                fam = mu["family"] as? String ?? "muse"
            }
        case "log":
            pushLog("· " + (m["msg"] as? String ?? ""))
        default:
            break
        }
    }
}

// MARK: - 界面

@main
struct ToyCtlApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}

struct ContentView: View {
    @StateObject private var bt = BT()

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 12) { connCard; bcastCard; toysCard; logCard }
                    .padding(.horizontal)
            }
            .navigationTitle("ToyCtl")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear { if bt.ready && !bt.connected && !bt.scanning { bt.startScan() } }
    }

    private var connCard: some View {
        VStack(spacing: 8) {
            HStack {
                Circle().fill(bt.connected ? Color.green : Color.red).frame(width: 10, height: 10)
                Text(bt.connected ? "已连接 ToyCtl" : (bt.ready ? "未连接" : "蓝牙未就绪"))
                    .font(.subheadline)
                Spacer()
                if bt.connected {
                    Button("断开") { bt.disconnect() }.font(.footnote)
                } else {
                    Button(bt.scanning ? "扫描中…" : "扫描连接") { bt.startScan() }
                        .font(.footnote).disabled(bt.scanning)
                }
            }
            Button(action: { bt.send(["t": "stopall"]) }) {
                Text("⏹ 全部停止").font(.headline).foregroundColor(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .background(Color.red).cornerRadius(10)
        }
        .padding().background(Color(.secondarySystemBackground)).cornerRadius(12)
    }

    private var bcastCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("📡 广播控制").font(.headline)
            Picker("家族", selection: $bt.fam) {
                Text("暮瑟").tag("muse")
                Text("SiYu(姬欲)").tag("siyu")
                Text("大广播").tag("omni")
            }
            .pickerStyle(.segmented)
            .onChange(of: bt.fam) { f in bt.send(["t": "bcast_fam", "fam": f]) }

            if bt.fam != "siyu" {
                Picker("通道", selection: $bt.museCh) {
                    Text("全通道").tag(0); Text("通道1").tag(1); Text("通道2").tag(2)
                }
                .pickerStyle(.segmented)
                .onChange(of: bt.museCh) { ch in bt.send(["t": "muse", "level": bt.museLevel, "ch": ch]) }
                HStack {
                    Slider(value: Binding(get: { Double(bt.museLevel) },
                                          set: { v in bt.museLevel = Int(v) }),
                           onEditingChanged: { e in if !e { bt.send(["t": "muse", "level": bt.museLevel, "ch": bt.museCh]) } },
                           in: 0...9, step: 1)
                    Text(bt.museLevel == 0 ? "停" : "\(bt.museLevel)")
                        .frame(width: 28).foregroundColor(.pink)
                }
                Button("MuSe 停止广播") { bt.send(["t": "muse", "level": 0, "ch": bt.museCh]) }
                    .font(.footnote)
            }

            if bt.fam == "siyu" || bt.fam == "omni" {
                Text("SiYu 控制在网页版更完整; App 端快控:").font(.caption).foregroundColor(.gray)
                HStack {
                    Button("SiYu 停") { bt.send(["t": "siyu", "motor": 1, "dir": 0, "speed": 0]) }
                        .font(.footnote)
                    Spacer()
                    ForEach(1...3, id: \.self) { v in
                        Button("速\(v)") { bt.send(["t": "siyu", "motor": 1, "dir": 1, "speed": v]) }
                            .font(.footnote)
                    }
                }
            }
        }
        .padding().background(Color(.secondarySystemBackground)).cornerRadius(12)
    }

    private var toysCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("🛰 已连接玩具").font(.headline)
            if bt.toys.isEmpty {
                Text("(无 — 在 ESP32 网页端开启雷达或手动连接)").font(.caption).foregroundColor(.gray)
            }
            ForEach(bt.toys) { t in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(t.name.isEmpty ? t.addr : t.name).font(.subheadline)
                        Spacer()
                        Button("停") { bt.send(["t": "cmd", "addr": t.addr, "vib": 0, "rot": 0]) }
                            .font(.caption)
                    }
                    Slider(value: Binding(get: { Double(t.vib) },
                                          set: { v in
                                              let i = Int(v)
                                              bt.toys = bt.toys.map { $0.addr == t.addr ? Toy(addr: t.addr, name: t.name, proto: t.proto, vib: i, rot: t.rot) : $0 }
                                          }),
                           onEditingChanged: { e in
                               if !e {
                                   let cur = bt.toys.first { $0.addr == t.addr }?.vib ?? 0
                                   bt.send(["t": "cmd", "addr": t.addr, "vib": cur, "rot": -1])
                               }
                           },
                           in: 0...100)
                    if t.proto == 1 || t.proto == 4 || t.proto == 10 {
                        Slider(value: Binding(get: { Double(t.rot) },
                                              set: { v in
                                                  let i = Int(v)
                                                  bt.toys = bt.toys.map { $0.addr == t.addr ? Toy(addr: t.addr, name: t.name, proto: t.proto, vib: t.vib, rot: i) : $0 }
                                              }),
                               onEditingChanged: { e in
                                   if !e {
                                       let cur = bt.toys.first { $0.addr == t.addr }?.rot ?? 0
                                       bt.send(["t": "cmd", "addr": t.addr, "vib": -1, "rot": cur])
                                   }
                               },
                               in: 0...100)
                    }
                }
                .padding(8).background(Color(.tertiarySystemBackground)).cornerRadius(8)
            }
        }
        .padding().background(Color(.secondarySystemBackground)).cornerRadius(12)
    }

    private var logCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("📜 日志").font(.headline)
            ForEach(bt.logs.prefix(20), id: \.self) {
                Text($0).font(.caption2).foregroundColor(.gray)
            }
        }
        .padding().background(Color(.secondarySystemBackground)).cornerRadius(12)
    }
}

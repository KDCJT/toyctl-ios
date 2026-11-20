// ToyCtl iOS — 功能对齐版(与网页控制台能力一致)
// JSON over BLE, 分帧协议: [0x01][seqId][seqIdx][seqTotal][payload...]

import SwiftUI
import CoreBluetooth
import WebKit

let SVC_UUID = CBUUID(string: "B0B0C0DE-F00D-4A11-B1E5-5EED00000001")
let CMD_UUID = CBUUID(string: "B0B0C0DE-F00D-4A11-B1E5-5EED00000002")
let OUT_UUID = CBUUID(string: "B0B0C0DE-F00D-4A11-B1E5-5EED00000003")

struct Toy: Identifiable {
    let addr: String; let name: String; let proto: Int; let vib: Int; let rot: Int
    var id: String { addr }
}

struct ScanItem: Identifiable {
    let addr: String; let name: String; let rssi: Int; let proto: Int; let mfg: String
    var id: String { addr }
}

struct SvcItem: Identifiable {
    let s: String; let u: String; let w: Int; let n: Int
    var id: String { s + u }
}

func protoName(_ p: Int) -> String {
    let names = ["未知", "Lovense", "通用", "MuSe连接型", "SiYu连接型", "Galaku", "Wetoy",
                 "MonsterPub", "Pretty Love", "TryFun", "Magic Motion", "MizzZee", "Youcups",
                 "Meese", "喜宝", "Ankni", "Svakom", "Hgod", "JoyHub", "Patoo"]
    if p >= 0 && p < names.count { return names[p] }
    return "?"
}

final class BT: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published var ready = false
    @Published var connected = false
    @Published var scanning = false
    @Published var toys: [Toy] = []
    @Published var scanResults: [ScanItem] = []
    @Published var services: [SvcItem] = []
    @Published var museLevel = 0
    @Published var museCh = 0
    @Published var fam = "muse"
    @Published var prefixText = ""
    @Published var radarOn = false
    @Published var radarAc = false
    @Published var rfEnabled = false
    @Published var rfCapturing = false
    @Published var rfHasFrame = false
    @Published var rfEdges = 0
    @Published var logs: [String] = []

    private var central: CBCentralManager!
    private var peri: CBPeripheral?
    private var cmdChar: CBCharacteristic?
    private var outChar: CBCharacteristic?
    private var frag: [UInt8: [Int: Data]] = [:]

    override init() { super.init(); central = CBCentralManager(delegate: self, queue: nil) }

    // MARK: 操作
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

    func updateToy(_ addr: String, vib: Int? = nil, rot: Int? = nil) {
        toys = toys.map { t in
            Toy(addr: t.addr, name: t.name, proto: t.proto, vib: vib ?? t.vib, rot: rot ?? t.rot)
        }
    }

    func sendToyVib(_ addr: String) {
        let cur = toys.first { $0.addr == addr }?.vib ?? 0
        send(["t": "cmd", "addr": addr, "vib": cur, "rot": -1])
    }

    func sendToyRot(_ addr: String) {
        let cur = toys.first { $0.addr == addr }?.rot ?? 0
        send(["t": "cmd", "addr": addr, "vib": -1, "rot": cur])
    }

    func savePrefixes(_ list: [String]) { send(["t": "muse_prefixes", "list": list]) }
    func museRaw(_ prefix: String, _ cmd: String) { send(["t": "muse_raw", "prefix": prefix, "cmd": cmd]) }
    func setRadar(_ on: Bool, _ ac: Bool) { send(["t": "radar", "on": on, "autoconnect": ac]) }
    func rf(_ action: String) { send(["t": "rf433", "a": action]) }
    func requestServices(_ addr: String) { send(["t": "services", "addr": addr]) }
    func rawWrite(_ addr: String, _ cuuid: String, _ hex: String, _ wresp: Bool) {
        send(["t": "raw", "addr": addr, "cuuid": cuuid, "hex": hex, "wresp": wresp])
    }
    func saveWifi(_ ssid: String, _ pass: String) { send(["t": "wifi", "ssid": ssid, "pass": pass]) }
    func connectDevice(_ addr: String) { send(["t": "connect", "addr": addr]) }
    func disconnectDevice(_ addr: String) { send(["t": "disconnect", "addr": addr]) }

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
                if let pl = mu["prefixes"] as? [String] { prefixText = pl.joined(separator: "\n") }
            }
            if let rd = m["radar"] as? [String: Any] {
                radarOn = (rd["on"] as? Bool) ?? false
                radarAc = (rd["ac"] as? Bool) ?? false
            }
            if let rf = m["rf433"] as? [String: Any] {
                rfEnabled = (rf["enabled"] as? Bool) ?? false
                rfCapturing = (rf["capturing"] as? Bool) ?? false
                rfHasFrame = (rf["hasFrame"] as? Bool) ?? false
                rfEdges = rf["edges"] as? Int ?? 0
            }
        case "scandone":
            if let list = m["list"] as? [[String: Any]] {
                scanResults = list.map {
                    ScanItem(addr: $0["addr"] as? String ?? "",
                             name: $0["name"] as? String ?? "",
                             rssi: $0["rssi"] as? Int ?? 0,
                             proto: $0["proto"] as? Int ?? 0,
                             mfg: $0["mfg"] as? String ?? "")
                }
                pushLog("扫描完成: \(scanResults.count) 台设备")
            }
        case "services":
            if let list = m["list"] as? [[String: Any]] {
                services = list.map {
                    SvcItem(s: $0["s"] as? String ?? "", u: $0["u"] as? String ?? "",
                            w: $0["w"] as? Int ?? 0, n: $0["n"] as? Int ?? 0)
                }
                pushLog("读取到 \(services.count) 个特征")
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
                VStack(spacing: 12) {
                    ConnCard(bt: bt)
                    BcastCard(bt: bt)
                    RadarCard(bt: bt)
                    ScanCard(bt: bt)
                    ToysCard(bt: bt)
                    RawCard(bt: bt)
                    RfCard(bt: bt)
                    WebConsoleCard()
                    WifiCard(bt: bt)
                    LogCard(bt: bt)
                }
                .padding(.horizontal)
            }
            .navigationTitle("ToyCtl")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear { if bt.ready && !bt.connected && !bt.scanning { bt.startScan() } }
    }
}

private func cardBg() -> some View { Color(.secondarySystemBackground) }

struct ConnCard: View {
    @ObservedObject var bt: BT
    var body: some View {
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
        .padding().background(cardBg()).cornerRadius(12)
    }
}

struct BcastCard: View {
    @ObservedObject var bt: BT
    @State private var rawPrefix = ""
    @State private var rawCmd = ""
    @State private var siyuMotor = 1
    @State private var siyuDir = 1
    @State private var siyuLevel = 0

    private func sendSiyu() {
        bt.send(["t": "siyu", "motor": siyuMotor, "dir": siyuDir, "speed": siyuLevel])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("📡 广播控制(无连接 · 一对多)").font(.headline)
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
                           in: 0...9, step: 1,
                           onEditingChanged: { e in if !e { bt.send(["t": "muse", "level": bt.museLevel, "ch": bt.museCh]) } })
                    Text(bt.museLevel == 0 ? "停" : "\(bt.museLevel)")
                        .frame(width: 28).foregroundColor(.pink)
                }
                Button("MuSe 停止广播") { bt.send(["t": "muse", "level": 0, "ch": bt.museCh]) }
                    .font(.footnote)
                Text("前缀(每行一个):").font(.caption).foregroundColor(.gray)
                TextEditor(text: $bt.prefixText)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(height: 60)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.4)))
                Button("保存前缀") {
                    let list = bt.prefixText
                        .components(separatedBy: CharacterSet.newlines.union(.whitespaces))
                        .filter { $0.count == 16 }
                    bt.savePrefixes(list)
                }
                .font(.footnote)
                HStack {
                    TextField("前缀", text: $rawPrefix)
                        .font(.system(.footnote, design: .monospaced))
                    TextField("命令", text: $rawCmd)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(width: 70)
                    Button("发送") { bt.museRaw(rawPrefix, rawCmd) }.font(.footnote)
                }
            }

            if bt.fam == "siyu" || bt.fam == "omni" {
                HStack {
                    Picker("马达", selection: $siyuMotor) {
                        Text("马达1").tag(1); Text("马达2").tag(2)
                    }
                    .pickerStyle(.segmented).frame(width: 150)
                    .onChange(of: siyuMotor) { _ in sendSiyu() }
                    Picker("方向", selection: $siyuDir) {
                        Text("停").tag(0); Text("正转").tag(1); Text("反向").tag(2)
                    }
                    .pickerStyle(.segmented).frame(width: 170)
                    .onChange(of: siyuDir) { _ in sendSiyu() }
                }
                HStack {
                    Slider(value: Binding(get: { Double(siyuLevel) },
                                          set: { v in siyuLevel = Int(v) }),
                           in: 0...10, step: 1,
                           onEditingChanged: { e in if !e { sendSiyu() } })
                    Text(siyuLevel == 0 ? "停" : "速\(siyuLevel)")
                        .frame(width: 34).foregroundColor(.pink)
                }
                Text("马达映射因型号而异(1=振动/旋转, 2=吸吮等), 两个都试试。").font(.caption2).foregroundColor(.gray)
            }
        }
        .padding().background(cardBg()).cornerRadius(12)
    }
}

struct SiyuQuick: View {
    @ObservedObject var bt: BT
    var body: some View {
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

struct RadarCard: View {
    @ObservedObject var bt: BT
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("🎯 玩具雷达").font(.headline)
            Toggle("雷达模式(周期扫描)", isOn: Binding(
                get: { bt.radarOn },
                set: { v in bt.radarOn = v; bt.setRadar(v, bt.radarAc) }))
            Toggle("自动连接已知玩具", isOn: Binding(
                get: { bt.radarAc },
                set: { v in bt.radarAc = v; bt.setRadar(bt.radarOn, v) }))
            Text("GATT 型玩具自动发现; 纯广播型只听不发射, 用广播面板控制。").font(.caption).foregroundColor(.gray)
        }
        .padding().background(cardBg()).cornerRadius(12)
    }
}

struct ScanCard: View {
    @ObservedObject var bt: BT
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("🛰 BLE 设备").font(.headline)
                Spacer()
                Button("扫描") { bt.send(["t": "scan"]) }.font(.footnote)
            }
            ForEach(bt.scanResults) { e in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.name.isEmpty ? "(未命名)" : e.name).font(.subheadline)
                        Text("\(e.addr) · \(e.rssi)dBm").font(.caption2).foregroundColor(.gray)
                    }
                    Spacer()
                    Text(protoName(e.proto)).font(.caption2).foregroundColor(.blue)
                    Button("连接") { bt.connectDevice(e.addr) }.font(.caption2)
                }
                .padding(.vertical, 2)
            }
        }
        .padding().background(cardBg()).cornerRadius(12)
    }
}

struct ToysCard: View {
    @ObservedObject var bt: BT
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("🔗 已连接玩具").font(.headline)
            if bt.toys.isEmpty {
                Text("(无)").font(.caption).foregroundColor(.gray)
            }
            ForEach(bt.toys) { t in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(t.name.isEmpty ? t.addr : t.name).font(.subheadline)
                        Text(protoName(t.proto)).font(.caption2).foregroundColor(.blue)
                        Spacer()
                        Button("断开") { bt.disconnectDevice(t.addr) }.font(.caption2)
                        Button("停") { bt.send(["t": "cmd", "addr": t.addr, "vib": 0, "rot": 0]) }
                            .font(.caption2)
                    }
                    Slider(value: Binding(get: { Double(t.vib) },
                                          set: { v in bt.updateToy(t.addr, vib: Int(v)) }),
                           in: 0...100,
                           onEditingChanged: { e in if !e { bt.sendToyVib(t.addr) } })
                    if t.proto == 1 || t.proto == 4 || t.proto == 10 {
                        Slider(value: Binding(get: { Double(t.rot) },
                                              set: { v in bt.updateToy(t.addr, rot: Int(v)) }),
                               in: 0...100,
                               onEditingChanged: { e in if !e { bt.sendToyRot(t.addr) } })
                    }
                }
                .padding(8).background(Color(.tertiarySystemBackground)).cornerRadius(8)
            }
        }
        .padding().background(cardBg()).cornerRadius(12)
    }
}

struct RawCard: View {
    @ObservedObject var bt: BT
    @State private var hex = ""
    @State private var wresp = false
    @State private var selAddr = ""
    @State private var selChar = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("🧪 原始 GATT 测试器").font(.headline)
            Picker("设备", selection: $selAddr) {
                if bt.toys.isEmpty { Text("(无)").tag("") }
                ForEach(bt.toys) { t in
                    Text(t.name.isEmpty ? t.addr : t.name).tag(t.addr)
                }
            }
            .frame(maxWidth: .infinity)
            Button("读取服务") { bt.requestServices(selAddr) }.font(.footnote)
            Picker("特征", selection: $selChar) {
                if bt.services.isEmpty { Text("(未读取)").tag("") }
                ForEach(bt.services) { s in
                    Text("\(String(s.s.prefix(8))) → \(s.u) [\((s.w == 1 ? "可写" : "") + (s.n == 1 ? "通知" : ""))]")
                        .tag(s.u)
                }
            }
            .frame(maxWidth: .infinity)
            HStack {
                TextField("HEX 如 AA55", text: $hex)
                    .font(.system(.footnote, design: .monospaced))
                Toggle("带响应", isOn: $wresp).font(.caption)
                Button("写入") { bt.rawWrite(selAddr, selChar, hex, wresp) }.font(.footnote)
            }
            Text("未知玩具: 连接 → 读取服务 → 选可写特征 → 试 00-FF / AA55 等字节").font(.caption2).foregroundColor(.gray)
        }
        .padding().background(cardBg()).cornerRadius(12)
    }
}

struct RfCard: View {
    @ObservedObject var bt: BT
    var body: some View {
        if bt.rfEnabled {
            VStack(alignment: .leading, spacing: 8) {
                Text("📻 433MHz 抓取/重放").font(.headline)
                HStack {
                    Button("捕获") { bt.rf("cap") }.font(.footnote)
                    Button("重放×3") { bt.rf("send") }.font(.footnote)
                    Button("清除") { bt.rf("clear") }.font(.footnote)
                }
                Text("状态: \(bt.rfCapturing ? "捕获中…" : "空闲") · 抓到帧: \(bt.rfHasFrame ? "是" : "否") · 边沿: \(bt.rfEdges)")
                    .font(.caption).foregroundColor(.gray)
            }
            .padding().background(cardBg()).cornerRadius(12)
        }
    }
}

struct WebConsoleCard: View {
    @State private var urlText = "http://192.168.4.1"
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("🌐 网页控制台(全功能)").font(.headline)
            Text("需手机连上 ESP32 热点 ToyCtl-xxx 或同一路由器; 蓝牙直连模式下网页不可达。")
                .font(.caption).foregroundColor(.gray)
            HStack {
                TextField("URL", text: $urlText)
                    .font(.system(.footnote, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                Button(open ? "收起" : "打开") { open.toggle() }.font(.footnote)
            }
            if open {
                WebView(url: URL(string: urlText) ?? URL(string: "http://192.168.4.1")!)
                    .frame(height: 460)
                    .border(Color.gray.opacity(0.3))
            }
        }
        .padding().background(cardBg()).cornerRadius(12)
    }
}

struct WebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let wv = WKWebView()
        wv.load(URLRequest(url: url))
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct WifiCard: View {
    @ObservedObject var bt: BT
    @State private var ssid = ""
    @State private var pass = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("📶 WiFi(可选)").font(.headline)
            HStack {
                TextField("SSID", text: $ssid)
                SecureField("密码", text: $pass)
                Button("保存") { bt.saveWifi(ssid, pass) }.font(.footnote)
            }
        }
        .padding().background(cardBg()).cornerRadius(12)
    }
}

struct LogCard: View {
    @ObservedObject var bt: BT
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("📜 日志").font(.headline)
            ForEach(bt.logs.prefix(20), id: \.self) {
                Text($0).font(.caption2).foregroundColor(.gray)
            }
        }
        .padding().background(cardBg()).cornerRadius(12)
    }
}

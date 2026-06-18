import Cocoa

// ── 配色阈值（剩余% ≥40 绿 / 20–40 黄 / <20 红）────────────────────────────────
let WARN = 40.0
let CRIT = 20.0
func levelColor(_ remaining: Double) -> NSColor {
    if remaining >= WARN { return .systemGreen }
    if remaining >= CRIT { return .systemYellow }
    return .systemRed
}

let DEFAULT_PROXY = "http://127.0.0.1:7890"
let AGENT_LABEL = "net.cnpanda.quota-card"

// ── 数据模型 ──────────────────────────────────────────────────────────────────
struct Quota {
    var left5h: Int?
    var left7d: Int?
    var reset5h: Date?
    var reset7d: Date?
    var note5h: String?
    var note7d: String?
    var plan: String?
    var error: String?
    var stale: String?
}
struct Snapshot {
    var claude: Quota?
    var codex: Quota?
    var cachedAt: Date?
}

private func parseResetAny(_ v: Any?) -> Date? {
    if let s = v as? String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
    if let n = v as? NSNumber { return Date(timeIntervalSince1970: n.doubleValue) }
    return nil
}

private func parseQuota(_ d: [String: Any]?) -> Quota? {
    guard let d = d else { return nil }
    return Quota(
        left5h: (d["5h_left"] as? NSNumber)?.intValue,
        left7d: (d["7d_left"] as? NSNumber)?.intValue,
        reset5h: parseResetAny(d["5h_reset"]),
        reset7d: parseResetAny(d["7d_reset"]),
        note5h: d["5h_note"] as? String,
        note7d: d["7d_note"] as? String,
        plan: d["plan"] as? String,
        error: d["error"] as? String,
        stale: d["stale"] as? String
    )
}

func currentProxy() -> String {
    UserDefaults.standard.object(forKey: "proxy") as? String ?? ""   // 默认直连
}

// 数据源：调用自带的独立 Python 抓取脚本（fetch.py），完全不依赖 ai-limit。
func loadSnapshot() -> Snapshot? {
    guard let script = Bundle.main.path(forResource: "fetch", ofType: "py") else { return nil }
    let venvPy = NSHomeDirectory() + "/Library/Application Support/QuotaCard/venv/bin/python3"
    let py = FileManager.default.isExecutableFile(atPath: venvPy) ? venvPy : "/usr/bin/python3"
    let task = Process()
    task.executableURL = URL(fileURLWithPath: py)
    task.arguments = [script]
    var env = ProcessInfo.processInfo.environment
    env["AI_LIMIT_PROXY"] = currentProxy()          // 把代理传给抓取脚本
    task.environment = env
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = Pipe()
    do { try task.run() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    guard let obj = try? JSONSerialization.jsonObject(with: data),
          let d = obj as? [String: Any] else { return nil }
    let fetchedAt = (d["fetched_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
    return Snapshot(claude: parseQuota(d["claude"] as? [String: Any]),
                    codex: parseQuota(d["codex"] as? [String: Any]),
                    cachedAt: fetchedAt)
}

func fmtReset(_ date: Date?) -> String {
    guard let d = date else { return "" }
    let cal = Calendar.current
    let f = DateFormatter()
    f.locale = .current
    if cal.isDateInToday(d) { f.dateFormat = "'今天' HH:mm" }
    else if cal.isDateInTomorrow(d) { f.dateFormat = "'明天' HH:mm" }
    else { f.dateFormat = "M/d HH:mm" }
    return f.string(from: d)
}

// ── 动态油量表（270° 圆弧 + 指针）─────────────────────────────────────────────
final class GaugeView: NSView {
    var fraction: Double = 0
    var color: NSColor = .systemGreen
    override func draw(_ dirtyRect: NSRect) {
        let c = NSPoint(x: bounds.midX, y: bounds.midY)
        let radius = min(bounds.width, bounds.height) / 2 - bounds.width * 0.12
        let lw = max(2, bounds.width * 0.12)
        let startA: CGFloat = 225
        let total: CGFloat = 270
        let bg = NSBezierPath()
        bg.appendArc(withCenter: c, radius: radius, startAngle: startA, endAngle: startA - total, clockwise: true)
        bg.lineWidth = lw; bg.lineCapStyle = .round
        NSColor.white.withAlphaComponent(0.22).setStroke(); bg.stroke()
        let frac = CGFloat(max(0, min(1, fraction)))
        if frac > 0 {
            let fg = NSBezierPath()
            fg.appendArc(withCenter: c, radius: radius, startAngle: startA, endAngle: startA - total * frac, clockwise: true)
            fg.lineWidth = lw; fg.lineCapStyle = .round
            color.setStroke(); fg.stroke()
        }
        let needleA = (startA - total * frac) * .pi / 180
        let tip = NSPoint(x: c.x + cos(needleA) * radius, y: c.y + sin(needleA) * radius)
        let needle = NSBezierPath(); needle.move(to: c); needle.line(to: tip)
        needle.lineWidth = max(1, bounds.width * 0.05); needle.lineCapStyle = .round
        color.setStroke(); needle.stroke()
        let dotR = bounds.width * 0.06
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: c.x - dotR, y: c.y - dotR, width: dotR * 2, height: dotR * 2)).fill()
    }
}

// ── 卡片视图：自己处理拖动移动 + 右下角手柄缩放（桌面层级下系统拖拽失效，故自实现）──
final class CardView: NSView {
    let minW: CGFloat = 180, minH: CGFloat = 118
    let maxW: CGFloat = 760, maxH: CGFloat = 520
    private var moving = false
    private var resizing = false
    private var edge = 0            // 位掩码：1 左 / 2 右 / 4 下 / 8 上
    private var startMouse = NSPoint.zero
    private var startFrame = NSRect.zero

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.13, alpha: 0.93).cgColor
        layer?.cornerRadius = 16
        layer?.masksToBounds = true
    }
    required init?(coder: NSCoder) { fatalError() }

    // 捕获所有鼠标事件（子视图纯展示），保证任意位置都能拖
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }

    private func edgeAt(_ p: NSPoint) -> Int {
        let m: CGFloat = 9            // 边缘 9pt 内视为拉伸，其余区域拖动移动
        var e = 0
        if p.x < m { e |= 1 }
        if p.x > bounds.width - m { e |= 2 }
        if p.y < m { e |= 4 }
        if p.y > bounds.height - m { e |= 8 }
        return e
    }

    override func mouseDown(with event: NSEvent) {
        guard let w = window else { return }
        startMouse = NSEvent.mouseLocation
        startFrame = w.frame
        edge = edgeAt(convert(event.locationInWindow, from: nil))
        resizing = edge != 0
        moving = !resizing
    }

    override func mouseDragged(with event: NSEvent) {
        guard let w = window else { return }
        let cur = NSEvent.mouseLocation
        let dx = cur.x - startMouse.x
        let dy = cur.y - startMouse.y
        if moving {
            w.setFrameOrigin(NSPoint(x: startFrame.origin.x + dx, y: startFrame.origin.y + dy))
            return
        }
        guard resizing else { return }
        var f = startFrame
        if edge & 2 != 0 { f.size.width = startFrame.width + dx }                                  // 右边
        if edge & 1 != 0 { f.size.width = startFrame.width - dx; f.origin.x = startFrame.origin.x + dx } // 左边
        if edge & 8 != 0 { f.size.height = startFrame.height + dy }                                 // 上边
        if edge & 4 != 0 { f.size.height = startFrame.height - dy; f.origin.y = startFrame.origin.y + dy } // 下边
        if f.size.width < minW { if edge & 1 != 0 { f.origin.x = startFrame.maxX - minW }; f.size.width = minW }
        if f.size.width > maxW { if edge & 1 != 0 { f.origin.x = startFrame.maxX - maxW }; f.size.width = maxW }
        if f.size.height < minH { if edge & 4 != 0 { f.origin.y = startFrame.maxY - minH }; f.size.height = minH }
        if f.size.height > maxH { if edge & 4 != 0 { f.origin.y = startFrame.maxY - maxH }; f.size.height = maxH }
        w.setFrame(f, display: true)
    }

    override func mouseUp(with event: NSEvent) { moving = false; resizing = false }

    // 右下角斜线提示（实际任意边/角都能拉伸）
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.white.withAlphaComponent(0.28).setStroke()
        for off in stride(from: CGFloat(4), through: 13, by: 4.5) {
            let p = NSBezierPath()
            p.move(to: NSPoint(x: bounds.maxX - off, y: 4))
            p.line(to: NSPoint(x: bounds.maxX - 4, y: off))
            p.lineWidth = 1.5
            p.stroke()
        }
    }
}

// ── App ───────────────────────────────────────────────────────────────────────
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let design = NSSize(width: 236, height: 156)
    var panel: NSPanel!
    var card: CardView!
    var outerStack: NSStackView!
    var columnsRow: NSStackView!
    var cacheLabel: NSTextField!
    var cWidth: NSLayoutConstraint!
    let sharedMenu = NSMenu()
    var timer: Timer?
    var lastSnapshot: Snapshot?

    // 等比适配：取宽/高较小比例，内容居中缩放（拉宽/拉高都不变形、不裁切，只改留白）
    var scale: CGFloat {
        guard let f = panel?.frame else { return 1 }
        return max(0.6, min(3.0, min(f.width / design.width, f.height / design.height)))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()

        let p = NSPanel(contentRect: NSRect(origin: .zero, size: design),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.collectionBehavior = []   // 默认：绑定启动时的桌面 Space，不跟进全屏 app、不乱贴别的界面
        p.hidesOnDeactivate = false
        p.delegate = self
        p.appearance = NSAppearance(named: .darkAqua)

        let c = CardView()
        c.autoresizingMask = [.width, .height]
        c.menu = sharedMenu
        self.card = c

        columnsRow = NSStackView()
        columnsRow.orientation = .horizontal
        columnsRow.distribution = .fillEqually
        columnsRow.alignment = .top
        cacheLabel = mkLabel("", 10, .tertiaryLabelColor)
        outerStack = NSStackView(views: [columnsRow, cacheLabel])
        outerStack.orientation = .vertical
        outerStack.alignment = .centerX
        outerStack.spacing = 6
        outerStack.translatesAutoresizingMaskIntoConstraints = false
        c.addSubview(outerStack)
        cWidth = columnsRow.widthAnchor.constraint(equalToConstant: 208)
        NSLayoutConstraint.activate([
            outerStack.centerXAnchor.constraint(equalTo: c.centerXAnchor),   // 整体水平+垂直居中
            outerStack.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            cWidth,
        ])
        p.contentView = c
        self.panel = p
        applyLevel()

        if let str = UserDefaults.standard.string(forKey: "cardFrame") {
            p.setFrame(NSRectFromString(str), display: true)
        } else if let scr = NSScreen.main {
            let vf = scr.visibleFrame
            p.setFrameOrigin(NSPoint(x: vf.maxX - design.width - 20, y: vf.maxY - design.height - 20))
        }
        p.orderFrontRegardless()

        cacheLabel.stringValue = "加载中…"
        refresh()
        restartTimer()

        // 切到任何别的 app 时，把卡片压到窗口堆最底 → 永不遮挡前台（置顶模式除外）
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(otherAppActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
    }

    @objc func otherAppActivated(_ n: Notification) {
        guard !UserDefaults.standard.bool(forKey: "ontop") else { return }
        panel.orderBack(nil)
    }

    // ── 定时刷新 ──────────────────────────────────────────────────────────────
    // 窗口层级：不置顶=普通层（可拖、切走即沉、基本不挡）；置顶=floating（始终可见）
    func applyLevel() {
        let ontop = UserDefaults.standard.bool(forKey: "ontop")
        panel.level = ontop ? .floating : .normal
        panel.isFloatingPanel = ontop   // 不置顶时关闭浮动 → 切到别的 app 会正常沉到后面，不遮挡
    }
    @objc func toggleOnTop() {
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: "ontop"), forKey: "ontop")
        applyLevel()
        updateMenuStates()
    }

    var refreshHours: Int { UserDefaults.standard.object(forKey: "refreshHours") as? Int ?? 4 }
    func restartTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Double(refreshHours) * 3600, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func windowDidMove(_ notification: Notification) { saveFrame() }
    func windowDidResize(_ notification: Notification) {
        saveFrame()
        render(lastSnapshot)   // 尺寸变了 → 按新 scale 重渲染内容
    }
    func saveFrame() {
        guard let p = panel else { return }
        UserDefaults.standard.set(NSStringFromRect(p.frame), forKey: "cardFrame")
    }

    @objc func quit() { NSApp.terminate(nil) }

    @objc func resetFrame() {
        UserDefaults.standard.removeObject(forKey: "cardFrame")
        if let scr = NSScreen.main {
            let vf = scr.visibleFrame
            panel.setFrame(NSRect(x: vf.maxX - design.width - 20, y: vf.maxY - design.height - 20,
                                  width: design.width, height: design.height), display: true)
        }
        render(lastSnapshot)
    }

    @objc func refresh() {
        cacheLabel.stringValue = "刷新中…"
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let snap = loadSnapshot()
            DispatchQueue.main.async {
                self?.lastSnapshot = snap
                self?.render(snap)
            }
        }
    }

    // ── 右键菜单 ──────────────────────────────────────────────────────────────
    func buildMenu() {
        sharedMenu.autoenablesItems = false
        sharedMenu.removeAllItems()

        sharedMenu.addItem(NSMenuItem(title: "立即刷新", action: #selector(refresh), keyEquivalent: ""))

        let rate = NSMenu()
        for h in [1, 2, 4] {
            let it = NSMenuItem(title: "\(h) 小时", action: #selector(setRefreshHours(_:)), keyEquivalent: "")
            it.tag = h; it.target = self
            rate.addItem(it)
        }
        let rateItem = NSMenuItem(title: "刷新间隔", action: nil, keyEquivalent: "")
        rateItem.submenu = rate
        sharedMenu.addItem(rateItem)

        let proxy = NSMenu()
        for (tag, title) in [(0, "关闭（直连）"), (1, "127.0.0.1:7890"), (2, "自定义…")] {
            let it = NSMenuItem(title: title, action: #selector(setProxyMode(_:)), keyEquivalent: "")
            it.tag = tag; it.target = self
            proxy.addItem(it)
        }
        let proxyItem = NSMenuItem(title: "代理", action: nil, keyEquivalent: "")
        proxyItem.submenu = proxy
        sharedMenu.addItem(proxyItem)

        sharedMenu.addItem(NSMenuItem(title: "开机自启", action: #selector(toggleLogin), keyEquivalent: ""))
        sharedMenu.addItem(NSMenuItem(title: "窗口置顶", action: #selector(toggleOnTop), keyEquivalent: ""))
        sharedMenu.addItem(NSMenuItem(title: "重置大小/位置", action: #selector(resetFrame), keyEquivalent: ""))
        sharedMenu.addItem(.separator())
        sharedMenu.addItem(NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q"))
        for it in sharedMenu.items { it.target = self; it.isEnabled = true }
        updateMenuStates()
    }

    func updateMenuStates() {
        if let rate = sharedMenu.item(withTitle: "刷新间隔")?.submenu {
            for it in rate.items { it.state = (it.tag == refreshHours) ? .on : .off }
        }
        let proxy = currentProxy()
        if let pm = sharedMenu.item(withTitle: "代理")?.submenu, pm.items.count >= 3 {
            pm.items[0].state = proxy.isEmpty ? .on : .off
            pm.items[1].state = (proxy == DEFAULT_PROXY) ? .on : .off
            let custom = !proxy.isEmpty && proxy != DEFAULT_PROXY
            pm.items[2].state = custom ? .on : .off
            pm.items[2].title = custom ? "自定义：" + proxyDisplay(proxy) : "自定义…"
        }
        sharedMenu.item(withTitle: "开机自启")?.state = loginEnabled() ? .on : .off
        sharedMenu.item(withTitle: "窗口置顶")?.state = UserDefaults.standard.bool(forKey: "ontop") ? .on : .off
    }

    @objc func setRefreshHours(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.tag, forKey: "refreshHours")
        restartTimer()
        updateMenuStates()
    }

    @objc func setProxyMode(_ sender: NSMenuItem) {
        switch sender.tag {
        case 0: applyProxy("")
        case 1: applyProxy(DEFAULT_PROXY)
        default:
            NSApp.activate(ignoringOtherApps: true)
            let a = NSAlert()
            a.messageText = "设置代理"
            a.informativeText = "输入代理地址（留空 = 直连）\n例：127.0.0.1:7890 或 socks5://127.0.0.1:1080"
            a.addButton(withTitle: "确定")
            a.addButton(withTitle: "取消")
            let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
            tf.stringValue = currentProxy()
            a.accessoryView = tf
            if a.runModal() == .alertFirstButtonReturn { applyProxy(normalizeProxy(tf.stringValue)) }
        }
    }
    func applyProxy(_ p: String) {
        UserDefaults.standard.set(p, forKey: "proxy")
        updateMenuStates()
        refresh()
    }
    func normalizeProxy(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return "" }
        return t.contains("://") ? t : "http://" + t
    }
    func proxyDisplay(_ p: String) -> String { p.components(separatedBy: "://").last ?? p }

    // ── 开机自启（QuotaCard 自己的 LaunchAgent）──────────────────────────────
    var agentPlist: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(AGENT_LABEL).plist")
    }
    func loginEnabled() -> Bool { FileManager.default.fileExists(atPath: agentPlist.path) }
    @objc func toggleLogin() {
        if loginEnabled() {
            try? FileManager.default.removeItem(at: agentPlist)
        } else {
            let exe = Bundle.main.executablePath ?? ""
            let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
              <key>Label</key><string>\(AGENT_LABEL)</string>
              <key>ProgramArguments</key><array><string>\(exe)</string></array>
              <key>RunAtLoad</key><true/>
            </dict></plist>
            """
            try? FileManager.default.createDirectory(at: agentPlist.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? xml.write(to: agentPlist, atomically: true, encoding: .utf8)
        }
        updateMenuStates()
    }

    // ── 视图工厂（尺寸按 scale 缩放）─────────────────────────────────────────
    func mkLabel(_ text: String, _ size: CGFloat, _ color: NSColor, bold: Bool = false) -> NSTextField {
        let t = NSTextField(labelWithString: text)
        let sz = size * scale
        t.font = bold ? .systemFont(ofSize: sz, weight: .semibold) : .systemFont(ofSize: sz)
        t.textColor = color
        return t
    }

    func iconView(_ symbol: String, _ color: NSColor, _ size: CGFloat) -> NSView {
        let iv = NSImageView()
        let cfg = NSImage.SymbolConfiguration(pointSize: size * scale, weight: .semibold)
        iv.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
        iv.contentTintColor = color
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.widthAnchor.constraint(equalToConstant: (size + 3) * scale).isActive = true
        iv.heightAnchor.constraint(equalToConstant: (size + 3) * scale).isActive = true
        return iv
    }

    func makeItem(symbol: String, iconColor: NSColor, left: Int?, reset: Date?, note: String?) -> NSView {
        let remaining = Double(left ?? 0)
        let col = left == nil ? NSColor.secondaryLabelColor : levelColor(remaining)
        let icon = iconView(symbol, iconColor, 12)
        let gauge = GaugeView()
        gauge.fraction = remaining / 100; gauge.color = col
        gauge.translatesAutoresizingMaskIntoConstraints = false
        gauge.widthAnchor.constraint(equalToConstant: 24 * scale).isActive = true
        gauge.heightAnchor.constraint(equalToConstant: 24 * scale).isActive = true
        let pct = mkLabel(left == nil ? "?" : "\(left!)%", 15, col, bold: true)
        let top = NSStackView(views: [icon, gauge, pct])
        top.orientation = .horizontal; top.spacing = 5 * scale; top.alignment = .centerY
        let v = NSStackView()
        v.orientation = .vertical; v.alignment = .leading; v.spacing = 1 * scale
        v.addArrangedSubview(top)
        // 窗口已重置（推断）则显示「已重置」，否则显示重置时间
        let rs = (note?.isEmpty == false) ? note! : fmtReset(reset)
        if !rs.isEmpty { v.addArrangedSubview(mkLabel("↻ " + rs, 11, .tertiaryLabelColor)) }
        return v
    }

    func makeColumn(_ name: String, _ q: Quota?, staleColor: NSColor) -> NSView {
        let col = NSStackView()
        col.orientation = .vertical; col.alignment = .leading; col.spacing = 7 * scale
        var planStr = ""
        if let pl = q?.plan, !pl.isEmpty { planStr = " · " + pl.capitalized }
        col.addArrangedSubview(mkLabel(name + planStr, 13, .labelColor, bold: true))
        if let q = q {
            if let err = q.error {
                col.addArrangedSubview(mkLabel("⚠️ " + err, 10, .secondaryLabelColor))
            } else {
                // 来源/时效行：两列都有（Claude 实时则显示「实时」），保证 5h/7d 行对齐
                let live = (q.stale?.isEmpty != false)
                col.addArrangedSubview(mkLabel(live ? "实时" : q.stale!, 9,
                                               live ? .tertiaryLabelColor : staleColor))
                col.addArrangedSubview(makeItem(symbol: "clock.fill", iconColor: .systemTeal,
                                                left: q.left5h, reset: q.reset5h, note: q.note5h))
                col.addArrangedSubview(makeItem(symbol: "calendar", iconColor: .systemPurple,
                                                left: q.left7d, reset: q.reset7d, note: q.note7d))
            }
        } else {
            col.addArrangedSubview(mkLabel("—", 11, .tertiaryLabelColor))
        }
        return col
    }

    func render(_ snap: Snapshot?) {
        let s = scale
        cWidth.constant = 208 * s
        columnsRow.spacing = 12 * s
        outerStack.spacing = 6 * s
        for v in columnsRow.arrangedSubviews { v.removeFromSuperview() }
        columnsRow.addArrangedSubview(makeColumn("Claude", snap?.claude, staleColor: .systemOrange))
        columnsRow.addArrangedSubview(makeColumn("Codex", snap?.codex, staleColor: .tertiaryLabelColor))
        if let ca = snap?.cachedAt {
            let mins = Int(Date().timeIntervalSince(ca) / 60)
            let age = mins < 1 ? "刚刚" : (mins < 60 ? "\(mins) 分钟前" : "\(mins / 60) 小时前")
            cacheLabel.stringValue = "更新 · " + age
        } else {
            cacheLabel.stringValue = snap == nil ? "抓取失败" : ""
        }
        cacheLabel.font = .systemFont(ofSize: 10 * s)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()

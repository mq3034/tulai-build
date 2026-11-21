import SwiftUI
import Photos
import UIKit

/// AI 生图页：手机出提示词，电脑（同一 Wi-Fi）用显卡出图。
///
/// 为什么不是纯手机功能：
///   手机跑不动扩散模型（要 3GB 显存）。所以这一页本质是**遥控器**，
///   真正的算力在电脑上（RTX 3070，512²/4 步实测 0.6~0.7 秒）。
///
/// 三条必须让用户知道的事（写在页面上，不藏）：
///   1. 提示词只认**英文**（CLIP 文本编码器，中文等于噪声）
///   2. 电脑上的服务要开着，手机电脑同一个 Wi-Fi
///   3. 这个模型**不支持"排除某个东西"**（turbo 关闭了 CFG），所以不做负向词
///
/// 2026-11-15 加"输出尺寸（放大）"：
///   用户嫌 768×768 太小。SDXL 原生只到 1024，所以分两段解决：
///   - 底图尺寸档：512 / 768 / 1024² / 1024×1536 竖 / 1536²（1536 是 8GB 卡实测上限）
///   - 放大档：ESRGAN x4plus 分块超分，长边 2048/4096/8192/14336（实测秒数标在旁边）
///   服务端 /hires 一次请求同时出底图 + 放大，App 用 /progress 轮询真实阶段。
struct 生图页: View {
    var 关闭: () -> Void

    @State private var 提示词 = ""
    /// 提示词库页点「填入」后留下的一次性内容（读走即清）
    @State private var 待填提示词 = ""
    @State private var 预设: 生图预设? = nil
    @State private var 宽 = 1024
    @State private var 高 = 1024
    @State private var 步数 = 4
    /// sdxl = 画质好；turbo = 极快但细节弱；illustrious = 最好（常驻）
    @State private var 模型 = "illustrious"
    /// 原生尺寸档（含实测秒数）
    @State private var 尺寸档 = 生图尺寸档.全部[2]
    /// 放大档（长边目标，0=不放大）
    @State private var 放大档 = 生图放大档.全部[0]
    @State private var 固定种子 = false
    @State private var 种子 = 42

    @State private var 生成中 = false
    @State private var 结果: UIImage?
    /// 高清出图的原始数据（超大图不能解成 UIImage，存相册用它）
    @State private var 结果数据: Data?
    @State private var 实际尺寸 = ""
    @State private var 结果字节 = 0
    @State private var 秒耗: Double = 0
    @State private var 用种子 = 0
    @State private var 状态 = "点「生成」出图"
    @State private var 失败说明: String?
    /// 8192 及以上要二次确认（可能跑几分钟，电脑不能休眠）
    @State private var 待确认 = false

    @State private var 显示设置 = false
    @State private var 健康: 生图健康?
    @State private var 探活中 = false
    @State private var 存图 = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    服务器条
                    提示词区
                    预设区
                    参数区
                    生成按钮
                    结果区
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("AI 生图")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { 关闭() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { 显示设置 = true } label: { Image(systemName: "gearshape") }
                }
            }
            .sheet(isPresented: $显示设置) {
                生图设置页 { 显示设置 = false }
            }
            .alert("出错了", isPresented: Binding(
                get: { 失败说明 != nil },
                set: { if !$0 { 失败说明 = nil } })) {
                Button("知道了") { 失败说明 = nil }
            } message: { Text(失败说明 ?? "") }
            .alert("确认出超大图", isPresented: $待确认) {
                Button("取消", role: .cancel) {}
                Button("继续") { Task { await 真正生成() } }
            } message: {
                Text("这张要跑约 \(预计分钟) 分钟。电脑不能休眠、手机别锁屏，保持在这个页面。")
            }
            .task { await 探活() }
            .onAppear {
                // 提示词库页「填入 AI 生图」写在这里的；读一次就清掉，
                // 免得下次进来又被覆盖（用户可能自己想改词）。
                let 待 = UserDefaults.standard.string(forKey: "生图.待填提示词") ?? ""
                if !待.isEmpty {
                    提示词 = 待
                    UserDefaults.standard.removeObject(forKey: "生图.待填提示词")
                    状态 = "已从提示词库填入"
                }
            }
        }
    }

    // MARK: - 服务器条

    private var 服务器条: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(健康?.ready == true ? Color.green : (健康 == nil ? Color.orange : Color.red))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(健康?.model ?? "未连接")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(生图配置.地址.replacingOccurrences(of: "http://", with: ""))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                Task { await 探活() }
            } label: {
                Text(探活中 ? "探测中…" : "测试")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(Color(.secondarySystemBackground)))
            }
            .disabled(探活中)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(.systemBackground)))
    }

    // MARK: - 提示词

    private var 提示词区: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("提示词（英文）").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            TextEditor(text: $提示词)
                .font(.system(size: 14))
                .frame(height: 74)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(.systemBackground)))
                .overlay(alignment: .topLeading) {
                    if 提示词.isEmpty {
                        Text("白发的动漫少女，雨夜街道，电影感光线")
                            .font(.system(size: 14))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 13).padding(.vertical, 16)
                            .allowsHitTesting(false)
                    }
                }
            Text("中文可以：服务端会自动翻译成英文 tag（纯英文则原样使用）")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Text("极速≈1 秒（512）· 高清≈30 秒 · 精细≈22 秒（1024²，手部/五官最稳）")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
    }

    // MARK: - 预设

    private var 预设区: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("预设（点一下自动填英文）").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(生图预设.全部) { p in
                    Button {
                        预设 = p
                        提示词 = p.提示词
                        宽 = p.宽
                        高 = p.高
                        if let 档 = 生图尺寸档.找(宽: p.宽, 高: p.高) { 尺寸档 = 档 }
                    } label: {
                        Text(p.名)
                            .font(.system(size: 13, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(RoundedRectangle(cornerRadius: 9)
                                .fill(预设?.名 == p.名 ? Color(red: 0.86, green: 0.93, blue: 0.80)
                                                        : Color(.systemBackground)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - 参数

    private var 参数区: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("模型").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $模型) {
                    Text("极速").tag("turbo")
                    Text("高清").tag("sdxl")
                    Text("精细").tag("illustrious")
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            }
            HStack {
                Text("尺寸").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Text("原生约 \(Int(尺寸档.秒.rounded())) 秒")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                Spacer()
                Picker("", selection: $尺寸档) {
                    ForEach(生图尺寸档.全部) { d in
                        Text("\(d.名)（\(Int(d.秒.rounded()))s）").tag(d)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: 尺寸档) { 新 in
                    宽 = 新.宽
                    高 = 新.高
                }
            }
            HStack {
                Text("输出尺寸").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Text(放大说明).font(.system(size: 10)).foregroundStyle(.tertiary)
                Spacer()
                Picker("", selection: $放大档) {
                    ForEach(生图放大档.全部) { d in
                        Text(放大标签(d)).tag(d)
                    }
                }
                .pickerStyle(.menu)
            }
            if 放大档.长边 > 0 {
                Text("ESRGAN 4× 分块超分：补细节、不改构图；底图 1024 及以上效果最好。"
                     + "这一档约 \(预计分钟) 分钟。")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            HStack {
                Text("步数").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("SDXL 档自动 20 步；这里的 1/2/4 只对「极速」生效").font(.system(size: 10)).foregroundStyle(.tertiary)
                Picker("", selection: $步数) {
                    Text("1（最快）").tag(1)
                    Text("2").tag(2)
                    Text("4（推荐）").tag(4)
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            }
            Toggle(isOn: $固定种子) {
                Text("固定种子（复现同一张）").font(.system(size: 12))
            }
            .font(.system(size: 12))
            if 固定种子 {
                HStack {
                    Text("种子").font(.system(size: 12)).foregroundStyle(.secondary)
                    TextField("42", value: $种子, format: .number)
                        .keyboardType(.numberPad)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(.systemBackground)))
    }

    // MARK: - 预估耗时（用服务端实测数字，不拍脑袋）

    /// 预估耗时 = 底图实测秒 + 放大实测秒（按底图长边面积等比放大，
    /// 因为 ESRGAN 的时间基本跟着输入像素走）。
    private var 预计秒: Double {
        let 基准底 = 21.7
        guard 放大档.长边 > 0 else { return 尺寸档.秒 }
        let 放大部分 = max(1.0, 放大档.秒 - 基准底)
        let 系数 = pow(Double(max(宽, 高)) / 1024.0, 2.0)
        return 尺寸档.秒 + 放大部分 * 系数
    }

    private var 预计文字: String {
        let s = Int(预计秒.rounded())
        if 放大档.长边 > 0 {
            return "预计约 \(s) 秒（按实测基准估算）"
        }
        return "预计约 \(s) 秒（实测）"
    }

    private var 预计分钟: Int {
        max(1, Int((预计秒 / 60.0).rounded(.up)))
    }

    private var 放大说明: String {
        放大档.长边 == 0 ? "不放大" : "放大后长边"
    }

    /// 返回 String 再交给 Text，避免 Text 三元里 LocalizedStringKey/String 推断歧义
    private func 放大标签(_ d: 生图放大档) -> String {
        if d.长边 == 0 { return "原图" }
        return d.名 + "（" + String(Int(d.秒.rounded())) + "s）"
    }

    private var 结果说明: String {
        var s = String(format: "%.1f 秒", 秒耗)
        if !实际尺寸.isEmpty { s += " · \(实际尺寸)" }
        if 结果字节 > 0 { s += " · \(String(format: "%.1f", Double(结果字节) / 1_048_576))MB" }
        s += " · 种子 \(用种子)"
        return s
    }

    // MARK: - 生成

    private var 生成按钮: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(预计文字).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                if 放大档.超大 {
                    Text("超大图 · 会二次确认")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.red)
                }
            }
            Button {
                if 放大档.超大 {
                    待确认 = true
                } else {
                    Task { await 真正生成() }
                }
            } label: {
                HStack(spacing: 8) {
                    if 生成中 { ProgressView().tint(.white) }
                    Text(生成中 ? "生成中…" : (放大档.长边 > 0 ? "生成并放大" : "生成"))
                        .font(.system(size: 15, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(RoundedRectangle(cornerRadius: 12)
                    .fill(生成中 ? Color.gray : Color(red: 0.98, green: 0.55, blue: 0.30)))
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(生成中 || 提示词.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if 生成中 {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.7)
                    Text(状态).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
    }

    // MARK: - 结果

    private var 结果区: some View {
        VStack(spacing: 10) {
            if let 结果 {
                Image(uiImage: 结果)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 340)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                HStack(spacing: 6) {
                    Text(结果说明)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer()
                    Button {
                        存到相册(结果)
                    } label: {
                        Text(存图 ? "已存" : "存相册")
                            .font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(Capsule().fill(Color(red: 0.86, green: 0.93, blue: 0.80)))
                    }
                    .disabled(存图)
                }
            } else {
                Text(状态).font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 24)
            }
        }
    }

    // MARK: - 动作

    private func 探活() async {
        探活中 = true
        defer { 探活中 = false }
        do {
            let h = try await 生图客户端.健康检查()
            健康 = h
            if h.ready != true { 状态 = "服务在，但模型还没加载完" }
        } catch {
            健康 = nil
            失败说明 = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func 真正生成() async {
        生成中 = true
        存图 = false
        结果数据 = nil
        实际尺寸 = ""
        结果字节 = 0
        状态 = 放大档.长边 > 0 ? "正在让电脑出高清图…（会显示阶段进度）" : "正在让电脑出图…"
        defer { 生成中 = false }
        let 提示 = 提示词.trimmingCharacters(in: .whitespacesAndNewlines)
        let 号 = 固定种子 ? 种子 : Int.random(in: 0...2_000_000_000)
        let 轮询 = Task { await 轮询进度() }
        defer { 轮询.cancel() }
        do {
            if 放大档.长边 > 0 {
                // turbo 是 512 原生模型，服务端不支持放大；这里自动切到精细模型
                let 用模型 = (模型 == "turbo") ? "illustrious" : 模型
                // 步数选择器是给 turbo 用的（1/2/4）；SDXL 模型统一 20 步，
                // 否则 4 步的 SDXL 会出一团糊（服务端 /gen 也会这么兜底）。
                let 实际步数 = (用模型 == "turbo") ? 步数 : 20
                let r = try await 生图客户端.高清生成(
                    提示词: 提示, 宽: 宽, 高: 高, 步数: 实际步数, 种子: 号,
                    模型: 用模型, 放大到长边: 放大档.长边)
                结果 = r.缩略图
                结果数据 = r.数据
                秒耗 = r.秒
                用种子 = r.号
                实际尺寸 = r.实际尺寸
                结果字节 = r.数据.count
                状态 = "出图完成（\(r.实际尺寸)）"
            } else {
                // 同一套规则：turbo 尊重用户选的 1/2/4；SDXL 强制 20+
                // （之前这里直接传 步数=4 给 SDXL，出来是一团糊 —— 用户真机踩过）
                let 非放大步数 = (模型 == "turbo") ? 步数 : max(20, 步数)
                let (图, 秒, 用号) = try await 生图客户端.生成(
                    提示词: 提示, 宽: 宽, 高: 高, 步数: 非放大步数, 种子: 号, 模型: 模型)
                结果 = 图
                秒耗 = 秒
                用种子 = 用号
                实际尺寸 = "\(宽)×\(高)"
                状态 = "出图完成"
            }
        } catch {
            失败说明 = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            状态 = "生成失败"
        }
    }

    /// 每 1.5 秒拉一次 /progress，把"第 2/2 轮 · 37/64 块"这类真实阶段显示出来
    private func 轮询进度() async {
        while !Task.isCancelled {
            if let p = await 生图客户端.进度(), p.active == true {
                状态 = p.人话
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
    }

    private func 存到相册(_ 图: UIImage) {
        let 原数据 = 结果数据
        Task {
            let 权 = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard 权 == .authorized || 权 == .limited else {
                失败说明 = "没拿到相册权限：设置 → 图来 → 照片 → 添加照片"
                return
            }
            // 超大图直接存服务端给的原始字节（JPEG 几十 MB）；
            // 先解成位图再压需要 1GB+ 内存，手机扛不住。
            let 数据: Data
            let 类型: String
            if let 原数据 {
                数据 = 原数据
                类型 = (原数据.first == 0xFF) ? "public.jpeg" : "public.png"
            } else if let j = 图.jpegData(compressionQuality: 0.95) {
                数据 = j
                类型 = "public.jpeg"
            } else {
                return
            }
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    let r = PHAssetCreationRequest.forAsset()
                    let o = PHAssetResourceCreationOptions()
                    o.uniformTypeIdentifier = 类型
                    r.addResource(with: .photo, data: 数据, options: o)
                }
                存图 = true
            } catch {
                失败说明 = "保存失败：\(error.localizedDescription)"
            }
        }
    }
}

/// 设置页：服务器地址、令牌、连通性
struct 生图设置页: View {
    var 关闭: () -> Void

    @State private var 地址 = 生图配置.地址
    @State private var 令牌 = 生图配置.令牌
    @State private var 结论: String?
    @State private var 测试中 = false

    var body: some View {
        NavigationStack {
            Form {
                Section("电脑地址") {
                    TextField("http://192.168.1.12:8790", text: $地址)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Text("在电脑上跑 `start.ps1` 后，用 `ipconfig` 看 IPv4 地址；手机和电脑要在同一个 Wi-Fi。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Section("令牌") {
                    TextField("tulai-dev", text: $令牌)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                Section {
                    Button {
                        Task { await 测试() }
                    } label: {
                        HStack {
                            if 测试中 { ProgressView() }
                            Text(测试中 ? "测试中…" : "保存并测试连接")
                        }
                    }
                    .disabled(测试中)
                    if let 结论 {
                        Text(结论).font(.system(size: 12))
                            .foregroundStyle(结论.contains("成功") ? .green : .red)
                    }
                }
            }
            .navigationTitle("服务器设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        生图配置.地址 = 地址
                        生图配置.令牌 = 令牌
                        关闭()
                    }
                }
            }
        }
    }

    private func 测试() async {
        测试中 = true
        生图配置.地址 = 地址
        生图配置.令牌 = 令牌
        defer { 测试中 = false }
        do {
            let h = try await 生图客户端.健康检查()
            let 显存 = h.vram_mb.map { " · 显存 \($0)MB" } ?? ""
            let 就绪 = h.ready == true ? "已就绪" : "模型加载中"
            结论 = "连接成功：\(h.model ?? "未知模型") · \(就绪)\(显存)"
        } catch {
            结论 = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

//
//  去水印页.swift
//  图来
//
//  去水印：解析和下载全在手机上完成，不连电脑、不走 Wi-Fi 也行（用流量）。
//  - 抖音 / 快手 / 小红书：隐藏 WKWebView 打开分享页，钩子截 JSON 或抓 <video> 直链
//  - B站：官方 API
//  - 存视频/图集到相册
//  底部仍留一个「电脑网页版」入口：老电脑上的 vdl 网页（链接解析更皮实，能兜底）。
//

import SwiftUI
import WebKit
import Photos
import AVKit

// MARK: - 主页面

struct 去水印页: View {
    var 关: () -> Void

    @State private var 输入 = ""
    @State private var 忙 = false
    @State private var 结果: 解析结果?
    @State private var 提示: String?
    @State private var 错: String?
    @State private var 存过: Set<String> = []
    @State private var 正在下 = ""
    @State private var 存进度 = ""
    @State private var 全存中 = false
    /// 只留一个 sheet：SwiftUI 同一层挂多个 .sheet 时只有最后一个能弹出来
    @State private var 弹: 弹层?
    /// 取法：本机（手机自己解析）/ 电脑（同一 Wi-Fi）/ 远程（外网地址，隧道或域名都行）
    @AppStorage("去水印.取法") private var 取法 = "本机"
    /// 开发者选项：控制「取法 / 电脑地址 / 远程地址」这些只在自用场景下才有意义的控件。
    /// 商用版默认关闭，客户看不到这些；在「我的」页手动打开。
    @AppStorage("去水印.高级") private var 高级 = false
    @AppStorage("电脑修复.地址") private var 电脑地址 = 电脑修复.缺省地址
    @AppStorage("去水印.远程地址") private var 远程地址 = "http://100.76.116.65:8770"
    /// 存相册时放大几倍（抖音给的只有它转码那一档，放大是重采样不是原图）
    @AppStorage("去水印.放大倍") private var 放大倍 = 2
    /// 用 HEIF 存：同画质体积约为 JPEG 的一半
    @AppStorage("去水印.存HEIF") private var 存HEIF = false
    @State private var 批量中 = false
    @State private var 放大提示 = ""
    @State private var 放大进度: Double = 0
    @State private var 改地址 = false
    @State private var 地址草稿 = ""
    @State private var 测中 = false

    private enum 弹层: Identifiable {
        case 网页, 视频(URL), 图片(String)

        var id: String {
            switch self {
            case .网页: return "网页"
            case .视频(let u): return "视频 " + u.absoluteString
            case .图片(let s): return "图片 " + s
            }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    输入区
                    if let 错 {
                        错误条(错)
                    }
                    if let r = 结果 {
                        结果区(r)
                    } else if !忙 {
                        说明
                    }
                }
                .padding(16)
                .contentShape(Rectangle())
                .onTapGesture { 收键盘() }
            }
            .background(Color(white: 0.96))
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("去水印")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { 关() }
                }
                ToolbarItem(placement: .keyboard) {
                    HStack {
                        Spacer()
                        Button("完成") { 收键盘() }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        弹 = .网页
                    } label: {
                        Label("网页版", systemImage: "desktopcomputer")
                            .labelStyle(.iconOnly)
                    }
                }
            }
            .sheet(item: $弹) { 项 in
                switch 项 {
                case .网页:
                    电脑网页版(关: { 弹 = nil },
                         地址: 取法 == "远程" ? $远程地址 : $电脑地址,
                         台名: 取法 == "远程" ? "远程" : "电脑")
                case .视频(let u):
                    视频预览(址: u, 引用: 去水印页.引用(结果?.平台 ?? ""),
                         关: { 弹 = nil },
                         存: {
                             if let c = 结果?.视频.first(where: { $0.地址 == u.absoluteString }) {
                                 弹 = nil
                                 存视频(c, 平台: 结果?.平台 ?? "抖音")
                             }
                         })
                case .图片(let s):
                    图片预览(址: s, 关: { 弹 = nil }) { await 存一张等(s) }
                }
            }
            .alert("提示", isPresented: Binding(get: { 提示 != nil }, set: { if !$0 { 提示 = nil } })) {
                Button("好") { 提示 = nil }
            } message: {
                Text(提示 ?? "")
            }
            .overlay {
                if 忙 { 转圈 }
                if !放大提示.isEmpty {
                    VStack {
                        Spacer()
                        VStack(spacing: 6) {
                            Text(放大提示)
                            if 放大进度 > 0 { ProgressView(value: 放大进度).frame(width: 160) }
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
                        .padding(.bottom, 28)
                    }
                }
                if !存进度.isEmpty {
                    VStack {
                        Spacer()
                        Text(存进度)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(Color.black.opacity(0.7), in: Capsule())
                            .padding(.bottom, 28)
                    }
                }
            }
            .onAppear { 网页抓取.共享.预热() }
        }
    }

    // MARK: 输入

    private func 收键盘() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
    }

    private var 输入区: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("分享链接")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    if let s = UIPasteboard.general.string { 输入 = s; 错 = nil }
                } label: {
                    Label("粘贴", systemImage: "doc.on.clipboard")
                        .font(.system(size: 12, weight: .semibold))
                }
            }

            TextField("把抖音 / B站 / 快手 / 小红书的分享链接粘到这里", text: $输入, axis: .vertical)
                .lineLimit(2...5)
                .font(.system(size: 14))
                .padding(12)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)

            // 「本机 / 电脑 / 远程」和地址填写属于**开发者选项**：
            // 客户没有那台跑 vdl 的电脑，摆在主界面上只会增加困惑。
            // 默认隐藏，在「我的」页开启「开发者选项」后出现。
            if 高级 { 引擎行 }

            Button {
                解析点()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "wand.and.stars")
                    Text(忙 ? "解析中…" : "解析")
                }
                .font(.system(size: 15, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color(red: 0.20, green: 0.55, blue: 0.95), in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(.white)
            }
            .disabled(忙 || 输入.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .opacity((忙 || 输入.isEmpty) ? 0.55 : 1)
        }
        .padding(14)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 16))
    }

    /// 本机 / 电脑（同一 Wi-Fi）/ 远程（外网地址）三种取法
    private var 引擎行: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Picker("", selection: $取法) {
                    Text("本机").tag("本机")
                    Text("电脑").tag("电脑")
                    Text("远程").tag("远程")
                }
                .pickerStyle(.segmented)
                .frame(width: 196)

                if 取法 != "本机" {
                    Button {
                        地址草稿 = 当前地址
                        改地址 = true
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: 取法 == "远程" ? "globe" : "wifi.router")
                            Text(当前地址.isEmpty ? "填地址" : 显示主机)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(当前地址.isEmpty ? Color.orange : Color.secondary)
                    }
                    .buttonStyle(.plain)

                    // 点一下问电脑要 /api/health：能立刻分清「地址错 / 服务没开 / 不同 Wi-Fi」
                    Button {
                        测通()
                    } label: {
                        if 测中 {
                            ProgressView().scaleEffect(0.6).frame(width: 18)
                        } else {
                            Text("测").font(.system(size: 11, weight: .semibold))
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color(red: 0.20, green: 0.55, blue: 0.95))
                    .disabled(测中 || 当前地址.isEmpty)
                }
                Spacer()
            }
            Text(副标题)
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
        // 改地址的 alert 挂在这里而不是整页上：同一层只留一个 alert（「提示」那个），
        // 否则两个 .alert 会互相顶掉，点「填地址」没反应
        .alert(取法 == "远程" ? "远程地址" : "电脑地址", isPresented: $改地址) {
            TextField(取法 == "远程" ? "https://xxxx.trycloudflare.com" : "192.168.1.12:8770", text: $地址草稿)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("取消", role: .cancel) { }
            Button("存") {
                var s = 地址草稿.trimmingCharacters(in: .whitespacesAndNewlines)
                while s.hasSuffix("/") { s.removeLast() }
                if !s.isEmpty {
                    if 取法 == "远程" {
                        远程地址 = s
                    } else {
                        电脑地址 = 电脑修复.规范(s)
                    }
                }
            }
        } message: {
            Text(取法 == "远程"
                 ? "填外网能访问的地址（整套 http:// 或 https:// 一起填），比如 Cloudflare 隧道、frp 域名、Tailscale 的 100.x 地址。"
                 : "填电脑的局域网地址，端口默认 8770。电脑上要把「去水印」服务开着。")
        }
    }

    private var 当前地址: String { 取法 == "远程" ? 远程地址 : 电脑地址 }

    /// 问一下电脑在不在（GET /api/health），结果直接弹提示
    private func 测通() {
        let 址 = 当前地址.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !址.isEmpty else { 提示 = "先点左边填地址"; return }
        测中 = true
        Task {
            defer { 测中 = false }
            do { 提示 = try await 解析.探活(址) }
            catch { 提示 = "连不上 \(址)：\(解析.中文错(error))" }
        }
    }

    private var 显示主机: String {
        当前地址
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
    }

    private var 副标题: String {
        switch 取法 {
        case "电脑": return "电脑上嗅探作品详情接口，图集能拿全（100 张 vs 手机 25~32 张）；要同一个 Wi-Fi"
        case "远程": return "走外网地址（隧道或域名），在外面也能用电脑解析；电脑和服务要开着"
        default: return "在手机上解析，不用电脑；图集只会有页面加载出来的那些"
        }
    }

    private var 转圈: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text(取法 == "本机" ? "正在抓地址…（一般 3~6 秒）" : "交给\(取法 == "远程" ? "远程" : "电脑")解析…（10~30 秒，图集要抓全量）")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var 说明: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("怎么用").font(.system(size: 13, weight: .semibold))
            Text("在抖音里点分享 → 复制链接，回来粘上就行。\n· 视频存原画（无水印）\n· 图集一条条存\n· B站支持 BV 号或链接\n· 取法可切「本机 / 电脑 / 远程」：电脑和远程能拿到全部图集（远程要填外网地址，在外面也能用）\n如果某个平台抓不到，右上角「网页版」连电脑兜底。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineSpacing(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 16))
    }

    private func 错误条(_ s: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(s).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(12)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: 结果

    private func 结果区(_ r: 解析结果) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                if let u = URL(string: r.封面), !r.封面.isEmpty {
                    AsyncImage(url: u) { 图 in
                        图.resizable().scaledToFill()
                    } placeholder: {
                        ZStack { Color(white: 0.9); Image(systemName: "photo").foregroundStyle(.secondary) }
                    }
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(r.平台).font(.system(size: 11, weight: .bold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color(red: 0.20, green: 0.55, blue: 0.95).opacity(0.12),
                                    in: Capsule())
                        .foregroundStyle(Color(red: 0.15, green: 0.45, blue: 0.85))
                    Text(r.标题.isEmpty ? "（没标题）" : r.标题)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(3)
                    if !r.页址.isEmpty {
                        Text(r.页址)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if !r.作者.isEmpty {
                        Text("@" + r.作者).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            }

            if !r.视频.isEmpty {
                Divider()
                ForEach(Array(r.视频.indices), id: \.self) { i in
                    let c = r.视频[i]
                    HStack(spacing: 10) {
                        Image(systemName: "video.fill")
                            .foregroundStyle(Color(red: 0.20, green: 0.55, blue: 0.95))
                        Text(c.名称).font(.system(size: 13))
                        Spacer()
                        Button {
                            if let u = URL(string: c.地址) { 弹 = .视频(u) }
                        } label: {
                            Text("播放")
                                .font(.system(size: 13, weight: .semibold))
                                .padding(.horizontal, 10).padding(.vertical, 7)
                                .background(Color(white: 0.93), in: Capsule())
                                .foregroundStyle(.secondary)
                        }
                        Button {
                            存视频(c, 平台: r.平台)
                        } label: {
                            Text(存过.contains(c.地址) ? "已存" : (正在下 == c.地址 ? "保存中…" : "存相册"))
                                .font(.system(size: 13, weight: .semibold))
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(Color(red: 0.20, green: 0.55, blue: 0.95).opacity(存过.contains(c.地址) ? 0.12 : 0.16),
                                            in: Capsule())
                                .foregroundStyle(Color(red: 0.15, green: 0.45, blue: 0.85))
                        }
                        .disabled(正在下 == c.地址)
                    }
                    .padding(.vertical, 2)
                }
            }

            if !r.图集.isEmpty {
                Divider()
                HStack {
                    Text("图集 \(r.图集.count) 张").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Menu {
                        // 商用版：按「意图」排序，不按算法排序。
                        // 用户要的是"变清楚"，不是"选模型"，所以第一项永远是推荐路径。
                        if 超分.有人脸增强() {
                            Button(放大倍 == -1 ? "✓ 一键增强（推荐）" : "一键增强（推荐）") { 放大倍 = -1 }
                        } else if 超分.有模型() {
                            Button(放大倍 == 0 ? "✓ 一键增强（推荐）" : "一键增强（推荐）") { 放大倍 = 0 }
                        }
                        Divider()
                        // 高级：想自己控制的人再往下选
                        if 超分.有模型() {
                            Button(放大倍 == 0 ? "✓ AI 4×（只放大，不修脸）" : "AI 4×（只放大，不修脸）") { 放大倍 = 0 }
                        }
                        ForEach([1, 2, 3, 4], id: \.self) { k in
                            Button(k == 1 ? "不放大（原样）" : "插值放大 \(k)×（不猜细节）") { 放大倍 = k }
                        }
                        Divider()
                        Toggle("用 HEIF 存（同画质更小）", isOn: $存HEIF)
                    } label: {
                        Text(放大倍 == -1 ? "一键增强" : (放大倍 == 0 ? "AI 4×" : (放大倍 <= 1 ? "不放大" : "放大\(放大倍)×")))
                            .font(.system(size: 12, weight: .semibold))
                    }
                    Button("全部保存") { 图集全存(r.图集) }
                        .font(.system(size: 13, weight: .semibold))
                        .disabled(全存中)
                }
                if r.源宽 > 0 {
                    Text(放大说明(r))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 8)], spacing: 8) {
                    ForEach(Array(r.图集.enumerated()), id: \.offset) { i, u in
                        ZStack(alignment: .bottomTrailing) {
                            AsyncImage(url: URL(string: u)) { 图 in
                                图.resizable().scaledToFill()
                            } placeholder: {
                                ZStack { Color(white: 0.9); ProgressView() }
                            }
                            .frame(height: 100)
                            .clipped()
                            .contentShape(Rectangle())
                            .onTapGesture { 弹 = .图片(u) }
                            .contextMenu {
                                Button {
                                    UIPasteboard.general.string = u
                                    提示 = "图片地址已复制"
                                } label: { Label("复制图片地址", systemImage: "doc.on.doc") }
                            }

                            Button {
                                存一张(u)
                            } label: {
                                HStack(spacing: 3) {
                                    Image(systemName: 存过.contains(u) ? "checkmark" : (正在下 == u ? "arrow.down" : "arrow.down.to.line"))
                                        .font(.system(size: 10, weight: .bold))
                                    Text(存过.contains(u) ? "已存" : (正在下 == u ? "保存中" : "存这"))
                                        .font(.system(size: 11, weight: .semibold))
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Color.black.opacity(0.55), in: Capsule())
                                .padding(5)
                            }
                            .disabled(正在下 == u)
                        }
                        .frame(height: 100)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(alignment: .topLeading) {
                            Text("\(i + 1)")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(4)
                                .background(Color.black.opacity(0.45), in: Circle())
                                .padding(4)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: 动作

    private func 解析点() {
        let 文本 = 输入
        错 = nil
        结果 = nil
        忙 = true
        Task {
            do {
                let r: 解析结果
                if 取法 == "本机" {
                    r = try await 解析.解析一下(文本)
                } else {
                    let 本 = 电脑地址.trimmingCharacters(in: .whitespacesAndNewlines)
                    let 远 = 远程地址.trimmingCharacters(in: .whitespacesAndNewlines)
                    // 主选在前、备选在后：局域网不通就自动试 Tailscale，反过来也一样
                    let 候选: [(地址: String, 台: String)] = 取法 == "远程"
                        ? [(地址: 远, 台: "远程"), (地址: 本, 台: "电脑")]
                        : [(地址: 本, 台: "电脑"), (地址: 远, 台: "远程")]
                    guard 候选.contains(where: { !$0.地址.isEmpty }) else {
                        throw 解析错.平台("先点右边「填地址」，填电脑的局域网地址（或外网地址）")
                    }
                    r = try await 解析.电脑解析(文本, 候选: 候选)
                }
                结果 = r
                存过 = []
                // 抖音偶尔只给「分享回流出图」，图上直接烧了「抖音号：xxx」，换一次通常就好
                if r.图集.contains(where: { $0.contains("-water") }) {
                    let 站 = r.页址.contains("m.douyin.com") ? "手机站的" : ""
                    提示 = "这组图抖音只给了\(站)带抖音号的版本，再点一次解析试试"
                }
            } catch {
                错 = 解析.中文错(error)
            }
            忙 = false
        }
    }

    private func 存视频(_ c: 清晰度, 平台: String) {
        guard let u = URL(string: c.地址) else { return }
        正在下 = c.地址
        Task {
            defer { 正在下 = ""; 存进度 = "" }
            do {
                var 请 = URLRequest(url: u)
                请.timeoutInterval = 300
                请.setValue(解析.网页UA, forHTTPHeaderField: "User-Agent")
                请.setValue(去水印页.引用(平台), forHTTPHeaderField: "Referer")
                存进度 = "下载中…"
                // 用 download(for:)：直接落临时文件，不把整条视频读进内存
                // （以前逐字节 append 到 Data，几百兆的视频会把手机撑爆，而且慢）
                let (临时, 应) = try await URLSession.shared.download(for: 请)
                let 码 = (应 as? HTTPURLResponse)?.statusCode ?? 0
                guard 码 == 200 || 码 == 206 else {
                    throw 解析错.平台("下载失败（HTTP \(码)）")
                }
                let 名 = "去水印-\(Int(Date().timeIntervalSince1970)).mp4"
                let 到 = FileManager.default.temporaryDirectory.appendingPathComponent(名)
                try? FileManager.default.removeItem(at: 到)
                try FileManager.default.moveItem(at: 临时, to: 到)
                存进度 = "存相册…"
                try await 存相册视频(到)
                try? FileManager.default.removeItem(at: 到)
                存过.insert(c.地址)
                提示 = "已存到相册"
            } catch {
                提示 = 解析.中文错(error)
            }
        }
    }

    private func 存一张(_ 址: String) {
        正在下 = 址
        Task {
            defer { 正在下 = "" }
            _ = await 存一张等(址)
        }
    }

    /// 真正干活的版本：预览页里直接 await，好在按钮上显示「存…」/「已存到相册」
    private func 存一张等(_ 址: String) async -> Bool {
        do {
            let 数据 = try await 去水印页.下数据(址, 平台: 结果?.平台 ?? "抖音")
            guard let 图 = UIImage(data: 数据) else { throw 解析错.平台("这张图下不下来") }
            try await 存相册图(图)
            存过.insert(址)
            // 不弹 alert：预览页还开着，alert 会被压住（按钮上已经显示「已存到相册」）
            return true
        } catch {
            提示 = 解析.中文错(error)
            return false
        }
    }

    /// 图集/图片统一走这里：带上 UA 和 Referer（抖音图床没 Referer 会 403）。
    /// 注：不再试「去掉 ~tplv 模板拿原图」——模板在 x-signature 里，改了就 403，
    /// 每张图白跑一次请求；页面/详情接口给的那档就是抖音的最高档。
    private static func 下数据(_ 址: String, 平台: String) async throws -> Data {
        guard let u = URL(string: 址) else { throw 解析错.平台("图片地址不对") }
        return try await 取一次(u, 平台: 平台)
    }

    private static func 取一次(_ u: URL, 平台: String) async throws -> Data {
        var 请 = URLRequest(url: u)
        请.timeoutInterval = 40
        请.setValue(解析.网页UA, forHTTPHeaderField: "User-Agent")
        请.setValue(去水印页.引用(平台), forHTTPHeaderField: "Referer")
        let (数据, 应) = try await URLSession.shared.data(for: 请)
        let 码 = (应 as? HTTPURLResponse)?.statusCode ?? 0
        guard 码 == 200 || 码 == 206 else {
            throw 解析错.平台("图下不下来（HTTP \(码)）")
        }
        return 数据
    }

    /// 批量存：4 张一组并发下载，再按顺序串行写相册（PHPhotoLibrary 并发写会互相排队报错）。
    /// 以前是一张一张串行，100 张要等一分钟；现在四并行，快三四倍。
    private func 图集全存(_ 址们: [String]) {
        guard !全存中 else { return }
        let 要存 = 址们.filter { !存过.contains($0) }
        guard !要存.isEmpty else { 提示 = "都存过了"; return }
        全存中 = true
        批量中 = true
        defer { 批量中 = false }
        let 平台名 = 结果?.平台 ?? "抖音"
        Task {
            var 成功 = 0, 失败 = 0
            var 起 = 0
            while 起 < 要存.count {
                let 止 = min(起 + 4, 要存.count)
                let 段 = Array(要存[起..<止])
                存进度 = "下载中 \(起 + 1)-\(止)/\(要存.count)"
                var 到手: [(String, Data?)] = []
                await withTaskGroup(of: (String, Data?).self) { 组 in
                    for 址 in 段 {
                        组.addTask {
                            do { return (址, try await 去水印页.下数据(址, 平台: 平台名)) }
                            catch { return (址, nil) }
                        }
                    }
                    for await 条 in 组 { 到手.append(条) }
                }
                for (址, 数据) in 到手 {
                    存进度 = "存相册 \(成功 + 失败 + 1)/\(要存.count)"
                    guard let 数据, let 图 = UIImage(data: 数据) else { 失败 += 1; continue }
                    do {
                        try await 存相册图(图)
                        存过.insert(址)
                        成功 += 1
                    } catch {
                        失败 += 1
                    }
                }
                起 = 止
            }
            存进度 = ""
            全存中 = false
            提示 = 失败 == 0 ? "存了 \(成功) 张" : "存了 \(成功) 张，\(失败) 张没下来"
        }
    }

    private static func 引用(_ 平台: String) -> String {
        switch 平台 {
        case "抖音": return "https://m.douyin.com/"
        case "B站": return "https://www.bilibili.com/"
        case "快手": return "https://www.kuaishou.com/"
        case "小红书": return "https://www.xiaohongshu.com/"
        default: return "https://www.douyin.com/"
        }
    }

    private func 存相册视频(_ 址: URL) async throws {
        try await 要相册权限()
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: 址)
            }
        } catch let e {
            throw 解析错.平台(相册错说明(e))
        }
    }

    /// 存图：先统一转成 JPEG 数据再写相册。
    /// 抖音的图是 webp，`creationRequestForAsset(from: UIImage)` 遇到 webp 常报
    /// PHPhotosErrorDomain 3302（资源类型不接受），转 JPEG 后一般就没这个问题。
    private func 存相册图(_ 原图: UIImage) async throws {
        try await 要相册权限()
        // 抖音给的只有它转码后那一档，宽度一般 1023~1440；存的时候放大 2 倍
        // （Lanczos + 轻锐化，插值重建，不是作者原图），看着清楚不少
        var 图 = 原图
        var 大图: CGImage?
        // 批量保存时不用 AI（25 张 × 十几秒顶不住），只做插值放大
        // 放大倍 == -1 是「AI 4×（人脸）」那档（v108 新增）；它也受同一个像素上限约束，
        // 由 `人脸增强.跑` 内部的 `定倍率` 处理，这里不必再降
        let 当前倍 = (放大倍 < 0 && 批量中) ? 1 : 放大倍
        if 当前倍 == -1, let cg = 原图.cgImage, 超分.有人脸增强() {
            // AI 4×（人脸）：Real-ESRGAN 打底 + GFPGAN 逐张修脸（v108 新增）
            // 批量里不给用（GFPGAN 一张脸就是几秒，几十张顶不住），所以走到这里都是单张
            let 原 = cg
            放大提示 = "AI 放大修脸中…"
            let 放大后 = await Task.detached(priority: .userInitiated) {
                超分.跑人脸(原) { p in
                    Task { @MainActor in 放大进度 = p }
                }
            }.value
            放大提示 = ""
            放大进度 = 0
            if let 放大后 {
                // 修脸后补一点对比/锐度：GFPGAN 倾向把皮肤修平滑，
                // 不补这一下，成品出来会"发闷、像蜡像"。
                // 只调观感，不产生新细节；调色失败就原样用，不影响保存。
                let 上色 = await Task.detached(priority: .userInitiated) {
                    调色.轻修(放大后) ?? 放大后
                }.value
                大图 = 上色
                图 = UIImage(cgImage: 上色)
            }
        } else if 当前倍 == 0, let cg = 原图.cgImage, 超分.有模型() {
            // AI 4×：Real-ESRGAN 分块推理，一张 1440 宽的图大概十几秒
            let 原 = cg
            放大提示 = "AI 放大中…"
            let 放大后 = await Task.detached(priority: .userInitiated) {
                超分.跑(原) { p in
                    Task { @MainActor in 放大进度 = p }
                }
            }.value
            放大提示 = ""
            放大进度 = 0
            if let 放大后 {
                大图 = 放大后
                图 = UIImage(cgImage: 放大后)
            }
        } else if 当前倍 > 1, let cg = 原图.cgImage {
            // 4 倍时 1440 宽的图会变成 5760×12000，解码就 200MB 以上，直接爆内存。
            // 卡一个总像素上限，超了自动降倍率
            let 源像素 = Double(cg.width * cg.height)
            let 上限像素 = 42_000_000.0
            var 倍 = CGFloat(当前倍)
            if 源像素 > 0, 源像素 * Double(倍 * 倍) > 上限像素 {
                倍 = CGFloat(max(1, Int((上限像素 / 源像素).squareRoot())))
            }
            if 倍 > 1 {
                let 原 = cg
                let 放大后 = await Task.detached(priority: .userInitiated) {
                    修图.放大(原, 倍: 倍)
                }.value
                if let 放大后 { 大图 = 放大后; 图 = UIImage(cgImage: 放大后) }
            }
        }
        let 数据: Data
        if 存HEIF, let 大图, let 压 = 修图.编码HEIF(大图) {
            数据 = 压
        } else if let j = 图.jpegData(compressionQuality: 0.95) {
            数据 = j
        } else {
            throw 解析错.平台("这张图存不下来（转码失败）")
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let 建 = PHAssetCreationRequest.forAsset()
                建.addResource(with: .photo, data: 数据, options: nil)
            }
        } catch {
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAsset(from: 图)
                }
            } catch let 二 {
                throw 解析错.平台(相册错说明(二))
            }
        }
    }

    /// 图集标题下面那行说明：来源像素 + 存的时候会变成多少
    private func 放大说明(_ r: 解析结果) -> String {
        let 源 = "抖音给的最高 \(r.源宽)×\(r.源高)（它的转码上限，作者原图不公开）"
        if r.源宽 <= 0 { return "" }
        if 放大倍 == 0 {
            return 源 + "，存相册时 AI 放大 4× → \(r.源宽 * 4)×\(r.源高 * 4)（每张十几秒）"
        }
        if 放大倍 == -1 {
            return 源 + "，存相册时 AI 放大 4× + 人脸修复 → \(r.源宽 * 4)×\(r.源高 * 4)（比纯 AI 4× 再慢几秒）"
        }
        if 放大倍 > 1 {
            return 源 + "，存相册时放大 \(放大倍)× → \(r.源宽 * 放大倍)×\(r.源高 * 放大倍)"
        }
        return 源
    }

    private func 相册错说明(_ e: Error) -> String {
        let n = e as NSError
        if n.domain == "PHPhotosErrorDomain" {
            switch n.code {
            case 3302: return "系统不让写相册（PHPhotos 3302）：设置 → 图来 → 照片，选「添加照片」再试"
            case 3072: return "存相册被取消了"
            default: return "存相册失败（PHPhotos \(n.code)）"
            }
        }
        return 解析.中文错(e)
    }

    private func 要相册权限() async throws {
        let 权 = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if 权 == .authorized || 权 == .limited { return }
        let 新 = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        if 新 != .authorized && 新 != .limited {
            throw 解析错.平台("没给相册权限：设置 → 图来 → 照片 → 选「添加照片」")
        }
    }
}

// MARK: - 预览

/// 存之前先看一眼，确认没水印
struct 视频预览: View {
    let 址: URL
    /// 有些直链（尤其抖音 m 站的）不带 Referer 就播不了
    var 引用: String = "https://www.douyin.com/"
    var 关: () -> Void
    /// 预览时就能直接存相册（不必关掉再点结果行上的按钮）
    var 存: () -> Void = {}

    @State private var 播放器: AVPlayer?
    @State private var 错 = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let 播放器 {
                    VideoPlayer(player: 播放器).ignoresSafeArea()
                } else {
                    ProgressView().tint(.white)
                }
                if 错 {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("这条地址播不了，直接存相册试试").font(.system(size: 13)).foregroundStyle(.white)
                    }
                }
            }
            .navigationTitle("预览")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { 播放器?.pause(); 关() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("存相册") { 播放器?.pause(); 存() }
                }
            }
            .onAppear {
                let 资产 = AVURLAsset(url: 址, options: [
                    "AVURLAssetHTTPHeaderFieldsKey": ["Referer": 引用,
                                                      "User-Agent": 解析.网页UA]
                ])
                let 项 = AVPlayerItem(asset: 资产)
                let p = AVPlayer(playerItem: 项)
                播放器 = p
                p.play()
            }
            .onDisappear { 播放器?.pause() }
            .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime)) { _ in
                错 = true
            }
        }
    }
}

struct 图片预览: View {
    let 址: String
    var 关: () -> Void
    /// 返回 true 表示已存进相册
    var 存: () async -> Bool

    @State private var 存着 = false
    @State private var 已存 = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                // 预览用页面给的压缩图（秒开），存相册时才取原图
                AsyncImage(url: URL(string: 址)) { 图 in
                    图.resizable().scaledToFit()
                } placeholder: {
                    ProgressView().tint(.white)
                }
            }
            .navigationTitle("预览")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { 关() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task {
                            存着 = true
                            let 好 = await 存()
                            存着 = false
                            已存 = 好
                        }
                    } label: {
                        if 存着 {
                            HStack(spacing: 6) { ProgressView(); Text("存…") }
                        } else {
                            Text(已存 ? "已存到相册" : "存相册")
                        }
                    }
                    .disabled(存着 || 已存)
                }
            }
        }
    }
}

// MARK: - 电脑网页版（兜底，连同一 Wi-Fi 上的 vdl）

/// 网页加载状态：只有出错时才弹卡片，正常时页面自己长什么样就是什么样
final class 网页态: ObservableObject {
    @Published var 错: String?
}

struct 电脑网页版: View {
    var 关: () -> Void
    @Binding var 地址: String
    var 台名: String = "电脑"

    @StateObject private var 态 = 网页态()
    @State private var 重载 = UUID()
    @State private var 改地址 = false
    @State private var 草稿 = ""

    private var 网址: String {
        let s = 地址.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return "about:blank" }
        if s.contains("://") { return s.hasSuffix("/") ? s : s + "/" }
        return "http://" + 电脑修复.规范(s) + "/"
    }

    var body: some View {
        ZStack {
            网页(url: 网址, 重载: 重载, 态: 态)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    圆钮("xmark") { 关() }
                    Spacer()
                    if 态.错 != nil {
                        圆钮("arrow.clockwise") { 重载 = UUID(); 态.错 = nil }
                    }
                    圆钮(台名 == "远程" ? "globe" : "wifi.router") { 草稿 = 地址; 改地址 = true }
                }
                .padding(.horizontal, 12)
                .padding(.top, 6)
                Spacer()
            }

            if let 错 = 态.错 {
                卡片(错)
            }
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
        .alert(台名 == "远程" ? "远程地址" : "电脑地址", isPresented: $改地址) {
            TextField(台名 == "远程" ? "https://xxxx.trycloudflare.com" : "192.168.1.12:8770", text: $草稿)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            Button("取消", role: .cancel) {}
            Button("保存") {
                var s = 草稿.trimmingCharacters(in: .whitespacesAndNewlines)
                while s.hasSuffix("/") { s.removeLast() }
                if s.contains("://") { 地址 = s } else { 地址 = 电脑修复.规范(s) }
                态.错 = nil
                重载 = UUID()
            }
        } message: {
            Text(台名 == "远程"
                 ? "填外网能访问的完整地址（含 http:// 或 https://）"
                 : "填电脑上那个黑窗口里打印的地址，手机和电脑要同一个 Wi-Fi")
        }
    }

    private func 圆钮(_ 图标: String, _ 点: @escaping () -> Void) -> some View {
        Button(action: 点) {
            Image(systemName: 图标)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.black.opacity(0.45)))
        }
    }

    private func 卡片(_ 错: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 30)).foregroundStyle(.orange)
            Text("连不上去水印").font(.system(size: 17, weight: .bold))
            Text(错)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text(网址)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2).truncationMode(.middle)
            HStack(spacing: 10) {
                Button("重试") { 态.错 = nil; 重载 = UUID() }
                    .buttonStyle(.borderedProminent)
                Button("改地址") { 草稿 = 地址; 改地址 = true }
                    .buttonStyle(.bordered)
            }
            .font(.system(size: 14, weight: .semibold))
            Text(台名 == "远程"
                 ? "远程那边要开着去水印服务，隧道/域名要通"
                 : "电脑那边要开着去水印服务，手机和电脑同一个 Wi-Fi")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(20)
        .frame(maxWidth: 300)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
    }
}

/// 网页壳：只在地址或重载令牌变了才重新加载，避免每次刷新视图都刷网页
struct 网页: UIViewRepresentable {
    let url: String
    let 重载: UUID
    let 态: 网页态

    func makeCoordinator() -> 协调 { 协调(态: 态) }

    func makeUIView(context: Context) -> WKWebView {
        let 配 = WKWebViewConfiguration()
        配.allowsInlineMediaPlayback = true
        配.mediaTypesRequiringUserActionForPlayback = .all
        let 网 = WKWebView(frame: .zero, configuration: 配)
        网.navigationDelegate = context.coordinator
        网.allowsBackForwardNavigationGestures = true
        网.isOpaque = false
        网.backgroundColor = .black
        网.scrollView.backgroundColor = .black
        context.coordinator.装(网, url, 重载)
        return 网
    }

    func updateUIView(_ 网: WKWebView, context: Context) {
        context.coordinator.装(网, url, 重载)
    }

    final class 协调: NSObject, WKNavigationDelegate {
        let 态: 网页态
        private var 上次 = ""

        init(态: 网页态) { self.态 = 态 }

        func 装(_ 网: WKWebView, _ 址: String, _ 令牌: UUID) {
            let 键 = 址 + "|" + 令牌.uuidString
            guard 键 != 上次 else { return }
            上次 = 键
            guard let u = URL(string: 址) else {
                态.错 = "地址格式不对"
                return
            }
            var 请 = URLRequest(url: u)
            请.timeoutInterval = 15
            网.load(请)
        }

        func webView(_ 网: WKWebView, didFinish navigation: WKNavigation!) {
            态.错 = nil
        }

        func webView(_ 网: WKWebView, didFail navigation: WKNavigation!, withError e: Error) {
            态.错 = 说(e)
        }

        func webView(_ 网: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError e: Error) {
            态.错 = 说(e)
        }

        private func 说(_ e: Error) -> String {
            let 码 = (e as NSError).code
            if 码 == NSURLErrorCannotConnectToHost || 码 == NSURLErrorTimedOut
                || 码 == NSURLErrorCannotFindHost || 码 == NSURLErrorNetworkConnectionLost {
                return "连不上电脑，看看电脑上的去水印服务还开着没、是不是同一个 Wi-Fi"
            }
            return e.localizedDescription
        }
    }
}


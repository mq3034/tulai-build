//
//  解析.swift
//  图来
//
//  短视频去水印的核心：**全部在手机上算**，不连电脑。
//  - 抖音：网页里拿到 video_id，再向 aweme.snssdk.com 要「不带 logo 的 play 流」
//          （playwm = 带水印，play = 无水印，同一个 video_id）。实测 2026-11 仍有效。
//  - B站：走官方 open API，纯 URLSession。
//  - 快手 / 小红书：打开分享页，抓 <video> 的 src 或图集。
//

import Foundation
import UIKit
import WebKit

struct 清晰度 {
    var 地址: String
    var 名称: String
}

struct 解析结果 {
    var 平台: String
    var 标题: String = ""
    var 作者: String = ""
    var 封面: String = ""
    var 视频: [清晰度] = []
    var 图集: [String] = []
    /// 实际抓到东西的那个页面地址（排查用：能看出走的是桌面站还是 m 站）
    var 页址: String = ""
    /// 来源图集里最大那张的像素（抖音给的转码上限，用来提示「原图多大」）
    var 源宽: Int = 0
    var 源高: Int = 0

    var 是图集: Bool { 视频.isEmpty && !图集.isEmpty }
}

enum 解析错: LocalizedError {
    case 没链接, 没认出来, 平台(String), 空结果, 抖音要验证

    var errorDescription: String? {
        switch self {
        case .没链接: return "先粘贴一条分享链接"
        case .没认出来: return "这个链接没认出来，支持抖音 / B站 / 快手 / 小红书"
        case .平台(let s): return s
        case .空结果: return "没抓到地址，再点一次解析；还不行就把链接粘到电脑网页版"
        case .抖音要验证: return "抖音这次要求验证，过一会儿再试，或点右上角「网页版」连电脑"
        }
    }
}

/// 只拿到响应头就取消：判断直链能不能下，**不把视频读进内存/不占流量**
private final class 头探: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private var 续: CheckedContinuation<Int, Never>?
    private var 码 = 0
    private var 会: URLSession?
    /// 跟完重定向后落到的地址（短链展开用）
    private(set) var 终址 = ""

    func 探(_ 请: URLRequest) async -> Int {
        await withCheckedContinuation { (c: CheckedContinuation<Int, Never>) in
            续 = c
            let s = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
            // 得把会话留住：URLSession 一旦被释放，请求会直接被取消
            会 = s
            s.dataTask(with: 请).resume()
        }
    }

    func urlSession(_ 会话: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        码 = (response as? HTTPURLResponse)?.statusCode ?? 0
        if let u = response.url?.absoluteString, !u.isEmpty { 终址 = u }
        completionHandler(.cancel)
    }

    func urlSession(_ 会话: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        会?.invalidateAndCancel()
        会 = nil
        guard let c = 续 else { return }
        续 = nil
        c.resume(returning: 码)
    }
}

enum 解析 {

    // MARK: - 平台识别

    static func 平台(_ 文本: String) -> String {
        let t = 文本.lowercased()
        if t.contains("douyin.com") || t.contains("iesdouyin") { return "抖音" }
        if t.contains("bilibili.com") || t.contains("b23.tv") { return "B站" }
        if t.contains("kuaishou.com") || t.contains("v.kuaishou") || t.contains("chenzhongtech") { return "快手" }
        if t.contains("xiaohongshu.com") || t.contains("xhslink.com") { return "小红书" }
        return "网页"
    }

    static func 找链接(_ 文本: String) -> String? {
        guard let r = 文本.range(of: "https?://[^\\s\\u4e00-\\u9fff，。；、\"'<>（）()【】]+",
                            options: .regularExpression) else { return nil }
        return String(文本[r]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?)]}"))
    }

    static func 抖音号(_ 文本: String) -> String? {
        if let r = 文本.range(of: "/(?:video|note)/(\\d{15,20})", options: .regularExpression) {
            return String(文本[r]).components(separatedBy: "/").last
        }
        if let r = 文本.range(of: "(?<!\\d)\\d{19}(?!\\d)", options: .regularExpression) {
            return String(文本[r])
        }
        return nil
    }

    static func B站号(_ 文本: String) -> String? {
        if let r = 文本.range(of: "BV[0-9A-Za-z]{10}", options: .regularExpression) {
            return String(文本[r])
        }
        return nil
    }

    // MARK: - 入口

    @MainActor
    static func 解析一下(_ 文本: String) async throws -> 解析结果 {
        guard let 链接0 = 找链接(文本) else { throw 解析错.没链接 }
        let 台 = 平台(文本)
        switch 台 {
        case "B站":
            return try await B站(链接0, 文本)
        case "抖音":
            let 展开后 = await 展开短链(链接0)
            guard let 号 = 抖音号(文本) ?? 抖音号(展开后) ?? 抖音号(链接0) else {
                throw 解析错.平台("没找到视频 ID，把完整分享链接粘进来")
            }
            // 关键：短链本身不含 /note/，必须用展开后的地址判断图文，否则又会走手机站（带水印那档）
            return try await 抖音(号: 号, 原链接: 展开后.isEmpty ? 链接0 : 展开后)
        case "快手", "小红书", "网页":
            return try await 抓网页(链接: 链接0, 台: 台)
        default:
            throw 解析错.没认出来
        }
    }

    /// v.douyin.com 短链 → 拿到真正的 /video/{id} 地址
    /// 只看到响应头就收工，不把跳转页（几十上百 KB）下载下来
    static func 展开短链(_ 址: String) async -> String {
        guard 址.contains("v.douyin.com") || 址.contains("xhslink") || 址.contains("b23.tv"),
              let u = URL(string: 址) else { return 址 }
        var 请 = URLRequest(url: u)
        请.timeoutInterval = 12
        请.setValue(网页UA, forHTTPHeaderField: "User-Agent")
        let 探 = 头探()
        _ = await 探.探(请)
        return 探.终址.isEmpty ? 址 : 探.终址
    }

    // MARK: - B站

    static func B站(_ 链接: String, _ 文本: String) async throws -> 解析结果 {
        // b23.tv 短链本身不带 BV 号，先展开再找
        var bv = B站号(文本) ?? B站号(链接)
        if bv == nil {
            bv = B站号(await 展开短链(链接))
        }
        guard let bv else { throw 解析错.平台("没找到 BV 号，把完整链接或 BV 号粘进来") }
        func 取(_ u: String) async throws -> [String: Any] {
            guard let url = URL(string: u) else { throw 解析错.平台("地址不对") }
            var 请 = URLRequest(url: url)
            请.timeoutInterval = 15
            请.setValue(网页UA, forHTTPHeaderField: "User-Agent")
            请.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
            let (d, _) = try await URLSession.shared.data(for: 请)
            guard let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
                throw 解析错.平台("B站回的看不懂")
            }
            if let c = j["code"] as? Int, c != 0 {
                throw 解析错.平台("B站报错：" + ((j["message"] as? String) ?? "\(c)"))
            }
            return (j["data"] as? [String: Any]) ?? j
        }

        let 详情 = try await 取("https://api.bilibili.com/x/web-interface/view?bvid=\(bv)")
        let 标题 = (详情["title"] as? String) ?? ""
        let 作者 = ((详情["owner"] as? [String: Any])?["name"] as? String) ?? ""
        let 封面 = (详情["pic"] as? String) ?? ""
        let 分P = (详情["pages"] as? [[String: Any]]) ?? []
        let cid = (分P.first?["cid"] as? Int) ?? 0

        let 播放 = try await 取("https://api.bilibili.com/x/player/playurl?bvid=\(bv)&cid=\(cid)&qn=80&fnval=0&fnver=0&fourk=1")
        let durl = (播放["durl"] as? [[String: Any]]) ?? []
        var 视频: [清晰度] = []
        for (i, seg) in durl.enumerated() {
            if let u = seg["url"] as? String {
                视频.append(清晰度(地址: u, 名称: durl.count == 1 ? "完整视频" : "分段 \(i + 1)"))
            }
        }
        guard !视频.isEmpty else { throw 解析错.平台("B站没给可下载地址（可能要登录）") }
        return 解析结果(平台: "B站", 标题: 标题, 作者: 作者, 封面: 封面, 视频: 视频)
    }

    // MARK: - 抖音

    /// 同一个视频在本次运行里再解析，直接秒回（10 分钟内有效，CDN 地址会过期）
    @MainActor private static var 缓存: [String: (解析结果, Date)] = [:]

    @MainActor
    static func 抖音(号: String, 原链接: String) async throws -> 解析结果 {
        if let (旧, 时) = 缓存[号], Date().timeIntervalSince(时) < 600 { return 旧 }
        let 抓 = 网页抓取.共享
        let 页 = try await 抓.抖音(号, 是图文: 原链接.contains("/note/"))

        var 结果 = 解析结果(平台: "抖音")
        结果.标题 = 页.标题
        结果.封面 = 页.封面
        结果.图集 = 页.图集
        结果.页址 = 页.页址
        结果.源宽 = 页.源宽
        结果.源高 = 页.源高

        if let 视号 = 页.视频号 {
            // playwm 带水印 / play 无水印，同一个 video_id；720p 最稳，先试它
            let 候选 = ["720p", "1080p"].map { 档 in
                ("https://aweme.snssdk.com/aweme/v1/play/?video_id=\(视号)&ratio=\(档)&line=0", 档)
            }
            for (u, 档) in 候选 {
                if await 址能下(u) {
                    结果.视频 = [清晰度(地址: u, 名称: "无水印 \(档)")]
                    break
                }
            }
            if 结果.视频.isEmpty {
                // 兜底：直接给网页里那条带水印的，至少能用
                if let 原 = 页.原文地址 {
                    结果.视频 = [清晰度(地址: 原, 名称: "带水印（原画）")]
                }
            }
        }
        if 结果.视频.isEmpty && 结果.图集.isEmpty {
            throw 解析错.空结果
        }
        缓存[号] = (结果, Date())
        return 结果
    }

    /// 只看响应头判断这条地址真能下：拿到 status 立刻 cancel，**不把视频读进内存**
    /// （早年用 data(for:) + Range，服务器不认 Range 时会把几百兆视频整个吞下来）
    static func 址能下(_ 址: String) async -> Bool {
        guard let u = URL(string: 址) else { return false }
        var 请 = URLRequest(url: u)
        请.timeoutInterval = 12
        请.setValue("bytes=0-1024", forHTTPHeaderField: "Range")
        请.setValue(网页UA, forHTTPHeaderField: "User-Agent")
        请.setValue("https://m.douyin.com/", forHTTPHeaderField: "Referer")
        let 码 = await 头探().探(请)
        return 码 == 200 || 码 == 206
    }

    // MARK: - 电脑解析（把链接交给同一 Wi-Fi 上的 vdl，拿全量图集）

    /// 电脑版（vdl）靠嗅探抖音自己的 `aweme/detail` 响应，`image_post_info.images` 是**全部**
    /// 100 张；手机页面只渲染出滑到跟前的 25~32 张。所以图集要多，就把活交给电脑。
    /// 返回的仍是 `~tplv-dy-aweme-images:q75` 那一档（和手机同画质，电脑也拿不到 origin_url）。
    /// 多个地址依次试（局域网不通就试 Tailscale，反过来也行），全失败才报错
    /// 单个地址干活的那个：把链接丢给 vdl 的 /api/parse
    static func 电脑解析(_ 文本: String, 地址: String, 台名: String = "电脑",
                     超时: TimeInterval = 90) async throws -> 解析结果 {
        let 根 = 地址.contains("://") ? 地址 : "http://" + 地址
        let 尾 = 根.hasSuffix("/") ? "api/parse" : "/api/parse"
        guard let u = URL(string: 根 + 尾) else { throw 解析错.平台("\(台名)地址写得不对") }
        var 请 = URLRequest(url: u)
        请.httpMethod = "POST"
        请.timeoutInterval = 超时
        请.setValue("application/json", forHTTPHeaderField: "Content-Type")
        请.httpBody = try? JSONSerialization.data(withJSONObject: ["text": 文本])
        let 数据: Data
        do {
            数据 = try await URLSession.shared.data(for: 请).0
        } catch {
             throw 解析错.平台(台名 == "远程"
                ? "连不上远程（\(地址)）：电脑要开着、去水印服务要跑着，隧道/域名要通；手机开 5G 也行"
                : "连不上电脑（\(地址)）：确认手机和电脑同一个 Wi-Fi，电脑上的去水印服务开着")
        }
        guard let j = try? JSONSerialization.jsonObject(with: 数据) as? [String: Any] else {
            throw 解析错.平台("\(台名)回的不是 JSON，检查地址是不是去水印那个服务")
        }
        if let ok = j["ok"] as? Bool, !ok {
            throw 解析错.平台((j["error"] as? String) ?? "\(台名)那边解析失败")
        }
        var 果 = 解析结果(平台: 中文台名((j["platform"] as? String) ?? ""))
        果.标题 = (j["title"] as? String) ?? ""
        果.作者 = (j["author"] as? String) ?? ""
        果.封面 = (j["cover"] as? String) ?? ""
        果.页址 = 台名 + " " + 地址
        if let 图 = j["images"] as? [String], !图.isEmpty { 果.图集 = 图 }
        if let 清 = j["qualities"] as? [[String: Any]] {
            var 见过: Set<String> = []
            果.视频 = 清.compactMap { (q: [String: Any]) -> 清晰度? in
                guard let a = q["url"] as? String, !a.isEmpty, !见过.contains(a) else { return nil }
                见过.insert(a)
                return 清晰度(地址: a, 名称: (q["label"] as? String) ?? "默认")
            }
        }
        if 果.图集.isEmpty && 果.视频.isEmpty { throw 解析错.空结果 }
        return 果
    }

    /// 多个地址依次试（局域网不通就试 Tailscale，反过来也行），全失败才报错
    static func 电脑解析(_ 文本: String, 候选: [(地址: String, 台: String)],
                     超时: TimeInterval = 90) async throws -> 解析结果 {
        var 错们: [String] = []
        for 项 in 候选 {
            let 址 = 项.地址.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !址.isEmpty else { continue }
            do {
                return try await 电脑解析(文本, 地址: 址, 台名: 项.台, 超时: 超时)
            } catch {
                错们.append("\(项.台)：\(解析.中文错(error))")
            }
        }
        if 错们.isEmpty { throw 解析错.平台("先点右边填地址") }
        throw 解析错.平台(错们.joined(separator: "\n"))
    }

    /// 探活：问一下电脑上的服务在不在，返回一句能直接显示的话
    static func 探活(_ 地址: String) async throws -> String {
        let 根 = 地址.contains("://") ? 地址 : "http://" + 地址
        let 尾 = 根.hasSuffix("/") ? "api/health" : "/api/health"
        guard let u = URL(string: 根 + 尾) else { throw 解析错.平台("地址写得不对") }
        var 请 = URLRequest(url: u)
        请.timeoutInterval = 8
        let (数据, 应) = try await URLSession.shared.data(for: 请)
        let 码 = (应 as? HTTPURLResponse)?.statusCode ?? 0
        guard 码 == 200 else { throw 解析错.平台("服务回了 HTTP \(码)") }
        let j = (try? JSONSerialization.jsonObject(with: 数据)) as? [String: Any]
        guard (j?["ok"] as? Bool) ?? false else {
            throw 解析错.平台("服务在，但自己说没准备好")
        }
        let 数 = (j?["urls"] as? [[String: Any]])?.count ?? 0
        return "通着：\(地址)" + (数 > 0 ? "（服务报了 \(数) 个地址）" : "")
    }

    /// vdl 回的是英文平台名（douyin / kuaishou / xiaohongshu / bilibili），
    /// 界面和 Referer 表用的是中文，这里翻译一下
    private static func 中文台名(_ 名: String) -> String {
        switch 名.lowercased() {
        case "douyin": return "抖音"
        case "kuaishou": return "快手"
        case "xiaohongshu", "xhs": return "小红书"
        case "bilibili", "b站": return "B站"
        default: return 名.isEmpty ? "电脑" : 名
        }
    }

    // MARK: - 网页抓（快手 / 小红书）

    @MainActor
    static func 抓网页(链接: String, 台: String) async throws -> 解析结果 {
        // 复用共享网页壳：新建一个 WKWebView 要多花 200~500ms，而且旧的还会挂在内存里
        let 原始 = try await 网页抓取.共享.打开(链接)
        var 结果 = 解析结果(平台: 台)
        结果.标题 = 原始.标题
        结果.作者 = 原始.作者
        结果.封面 = 原始.封面
        结果.视频 = 原始.视频
        结果.图集 = 原始.图集
        结果.页址 = 原始.页址
        if 结果.视频.isEmpty && 结果.图集.isEmpty { throw 解析错.空结果 }
        return 结果
    }

    static let 网页UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"

    /// 桌面 Safari 的 UA：抖音图文用它会走桌面版页面，图片是 `~tplv-dy-aweme-images`（不带
    /// 「抖音号：xxx」）；iPhone UA 会被甩到 m 站，那档是 `~tplv-dy-lqen-new`（带号）。
    static let 桌面UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    /// 图片对象键：同一张图的不同档（缩略图 / 正图 / 带水印版）路径主体相同
    static func 图键(_ 址: String) -> String {
        var s = 址
        if let q = s.firstIndex(of: "?") { s = String(s[..<q]) }
        if let t = s.range(of: "~tplv") { s = String(s[..<t.lowerBound]) }
        return s
    }

    /// 抖音图床的 `~tplv-...` 是压缩模板（缩到 1000px 左右、q75），去掉它一般就是原图
    static func 原图候选(_ 址: String) -> String? {
        guard 址.contains("douyinpic.com"), let r = 址.range(of: "~tplv") else { return nil }
        let 头 = String(址[..<r.lowerBound])
        let 尾 = String(址[r.lowerBound...])
        if let q = 尾.firstIndex(of: "?") { return 头 + 尾[q...] }
        return 头
    }

    /// 系统报错是英文的（手机语言可能是英文），统一换成中文
    static func 中文错(_ e: Error) -> String {
        let n = e as NSError
        if n.domain == NSURLErrorDomain {
            switch n.code {
            case NSURLErrorTimedOut: return "网络超时，再试一次"
            case NSURLErrorNotConnectedToInternet: return "现在没网"
            case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost:
                return "连不上服务器，过一会儿再试"
            case NSURLErrorNetworkConnectionLost: return "网络断了，重试一下"
            case NSURLErrorAppTransportSecurityRequiresSecureConnection:
                return "系统拦了这次请求"
            case NSURLErrorCancelled: return "取消了"
            default: return "网络出错（代码 \(n.code)）"
            }
        }
        return e.localizedDescription
    }
}

// MARK: - 隐藏网页

struct 抓到 {
    var 标题 = ""
    var 作者 = ""
    var 封面 = ""
    var 视频: [清晰度] = []
    var 图集: [String] = []
    var 视频号: String?
    var 原文地址: String?
    var 页址: String = ""
    var 源宽: Int = 0
    var 源高: Int = 0
}

@MainActor
final class 网页抓取 {

    private var 网: WKWebView?

    /// 解析器共用一个网页壳：省掉每次新建 WKWebView 的进程启动（约 200~500ms）
    static let 共享 = 网页抓取()

    private func 建网(_ ua: String = 解析.网页UA) -> WKWebView {
        if let 旧 = 网 {
            旧.customUserAgent = ua
            return 旧
        }
        let 配 = WKWebViewConfiguration()
        配.allowsInlineMediaPlayback = true
        配.mediaTypesRequiringUserActionForPlayback = []
        配.suppressesIncrementalRendering = false
        // iOS 的 WKWebView 把 navigator.platform 报成 "iPhone"，跟桌面 UA 对不上，
        // 抖音风控一看就走「验证码中间页」。这里在页面脚本之前把指纹补成 Mac。
        配.userContentController.addUserScript(WKUserScript(
            source: """
            try {
              Object.defineProperty(navigator, 'platform', { get: function(){ return 'MacIntel' } });
              Object.defineProperty(navigator, 'vendor', { get: function(){ return 'Apple Computer, Inc.' } });
              Object.defineProperty(navigator, 'maxTouchPoints', { get: function(){ return 0 } });
              if (navigator.userAgentData) {
                Object.defineProperty(navigator, 'userAgentData', { get: function(){ return undefined } });
              }
            } catch (e) {}
            """,
            injectionTime: .atDocumentStart, forMainFrameOnly: false))
        let 窗 = WKWebView(frame: CGRect(x: 0, y: 0, width: 420, height: 900), configuration: 配)
        窗.customUserAgent = ua
        网 = 窗
        return 窗
    }

    /// 提前把网页壳建好暖起来（进页面时调一次，省掉第一次解析的冷启动）
    func 预热() { _ = 建网() }

    /// 页面自检：视频地址、video_id、图集、标题
    /// 注意：这里**不能**去读 documentElement.innerHTML——每 120ms 把整页 HTML
    /// 序列化过 JS 桥，页面会被拖到十几秒才渲染完（实测直接导致图文掉到 m 站兜底）。
    private let 侦查 = """
    (function(){
      var v = document.querySelector('video');
      var src = v ? (v.currentSrc || v.src || '') : '';
      var vid = '';
      if (src) { var m3 = src.match(/video_id=([0-9a-zA-Z_-]{8,})/); if (m3) vid = m3[1]; }
      if (!vid && v && v.getAttribute) {
        var d = v.getAttribute('data-e2e-vid') || v.getAttribute('data-vid') || '';
        if (d) vid = d;
      }
      var imgs = [];
      try {
        // 排除站内 UI 资源：抖音 PC 页会在图片中间穿插 douyinstatic 的横幅/二维码（1208×680）
        // 以前只按宽度过滤，结果第一张常常是那张横幅
        var bad = /avatar|icon|logo|emoji|head|aweme-avatar|douyinstatic|static-resource|\\/obj\\/douyin-pc-web\\//i;
        var all = document.querySelectorAll('img');
        for (var i=0;i<all.length;i++){ var s = all[i].currentSrc || all[i].src || '';
          var w = all[i].naturalWidth || 0, h = all[i].naturalHeight || 0;
          if (/^https?:/.test(s) && !bad.test(s) && w >= 300) imgs.push([s, w, h]); }
      } catch(e){}
      var og = document.querySelector('meta[property="og:image"]');
      var ot = document.querySelector('meta[property="og:title"]');
      return JSON.stringify({
        src: src, vid: vid, imgs: imgs.slice(0, 60),
        title: (ot && ot.content) || document.title || '',
        cover: (og && og.content) || '',
        body: (document.body ? document.body.innerText.slice(0, 120) : '')
      });
    })();
    """

    private struct 探测 {
        var 页 = ""
        var 地址 = ""
        var 视频号 = ""
        var 图片: [(String, Int, Int)] = []
        var 标题 = ""
        var 封面 = ""
        var 正文 = ""
    }

    private func 探(_ 窗: WKWebView) async -> 探测 {
        let 原 = try? await 窗.evaluateJavaScript(侦查)
        guard let s = 原 as? String, let d = s.data(using: .utf8),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            return 探测()
        }
        var p = 探测()
        p.页 = 窗.url?.absoluteString ?? ""
        p.地址 = (j["src"] as? String) ?? ""
        p.视频号 = (j["vid"] as? String) ?? ""
        p.图片 = (j["imgs"] as? [[Any]] ?? []).compactMap { a in
            guard a.count >= 2, let u = a[0] as? String else { return nil }
            let 宽 = (a[1] as? NSNumber)?.intValue ?? 0
            let 高 = a.count >= 3 ? ((a[2] as? NSNumber)?.intValue ?? 0) : 0
            return (u, 宽, 高)
        }
        p.标题 = (j["title"] as? String) ?? ""
        p.封面 = (j["cover"] as? String) ?? ""
        p.正文 = (j["body"] as? String) ?? ""
        return p
    }

    // MARK: 抖音

    func 抖音(_ 号: String, 是图文: Bool = false) async throws -> 抓到 {
        var 出 = 抓到()
        var 见到验证 = false
        // 实测（2026-11，WebKit + iPhone UA）：www 的 /video/{id} 能直接渲染出
        // video，src 里带 playwm?...video_id=xxx；m 站分享页反而要登录。
        let 形 = 是图文 ? "note" : "video"
        // 图文：桌面版页面给的是 ~tplv-dy-aweme-images（干净），m 站给的是
        // ~tplv-dy-lqen-new 那档（带「抖音号：xxx」）。所以图文用桌面 UA 开 www，
        // 拿不到再退回 m 站。
        let 址们 = ["https://www.douyin.com/\(形)/\(号)",
                  "https://m.douyin.com/share/\(形)/\(号)"]
        for (i, 址) in 址们.enumerated() {
            let ua = (是图文 && i == 0) ? 解析.桌面UA : 解析.网页UA
            let 半 = await 摸一次(址, 秒: i == 0 ? 15 : 8, ua: ua, 图够: 是图文 ? 40 : 3, 只图: 是图文)
            if 出.页址.isEmpty { 出.页址 = 半.0.页址 }
            if 出.标题.isEmpty { 出.标题 = 半.0.标题 }
            if 出.封面.isEmpty { 出.封面 = 半.0.封面 }
            if 出.图集.isEmpty {
                出.图集 = 半.0.图集
                出.源宽 = 半.0.源宽
                出.源高 = 半.0.源高
            }
            if let v = 半.0.视频号 {
                出.视频号 = v
                出.原文地址 = 半.0.原文地址
                break
            }
            // 图文在桌面站已经拿到图就收工：再去 m 站只会拿到带「抖音号」的那档，白白多等 8 秒
            if !出.图集.isEmpty { break }
            if 半.1.contains("验证") || 半.1.contains("滑块") { 见到验证 = true }
        }
        if 出.视频号 == nil && 出.图集.isEmpty {
            throw 见到验证 ? 解析错.抖音要验证 : 解析错.空结果
        }
        return 出
    }

    /// 打开一个页面，最多盯 N 秒，返回（抓到的东西, 最后看到的正文）
    /// - 只图: 图文作品只收图集，不去认 <video>（图文页偶尔挂了个音乐预览视频，
    ///   认了就会误判成「视频作品」，把图集丢掉）
    private func 摸一次(_ 址: String, 秒: TimeInterval,
                       ua: String = 解析.网页UA, 图够: Int = 3,
                       只图: Bool = false) async -> (抓到, String) {
        guard let u = URL(string: 址) else { return (抓到(), "") }
        let 窗 = 建网(ua)
        窗.stopLoading()

        var 请 = URLRequest(url: u)
        请.timeoutInterval = 20
        请.setValue(ua, forHTTPHeaderField: "User-Agent")
        窗.load(请)

        var 出 = 抓到()
        var 正文 = ""
        var 验证次 = 0
        // 图池：同一张图的不同档（330 宽缩略图 / 正图 / 带水印版）路径主体相同，留最宽的那份
        var 池: [String: String] = [:]
        var 池宽: [String: Int] = [:]
        var 池高: [String: Int] = [:]
        /// 首次在页面上出现的顺序：挑图时按页面顺序给，别按宽度排
        /// （按宽度排会把后面的宽横幅/长图顶到第一张）
        var 序: [String] = []
        /// 图池里挑：优先不要带「-water」的，再优先 700 宽以上的，顺序照页面来
        func 挑图() -> [String] {
            var 键们 = 序.filter { !(池[$0] ?? "").contains("-water") }
            if 键们.isEmpty { 键们 = 序 }
            let 大 = 键们.filter { (池宽[$0] ?? 0) >= 700 }
            if !大.isEmpty { 键们 = 大 }
            return 键们.compactMap { 池[$0] }
        }
        /// 记下这组图里最大那张的像素（抖音转码上限，界面上用来提示画质）
        func 记源() {
            let 键们 = 出.图集.map { 解析.图键($0) }
            guard let 最 = 键们.max(by: { (池宽[$0] ?? 0) < (池宽[$1] ?? 0) }) else { return }
            出.源宽 = 池宽[最] ?? 0
            出.源高 = 池高[最] ?? 0
        }
        let 起 = Date()
        let 期限 = 起.addingTimeInterval(秒)
        // 图池「不再变多」的时间点：页面一次只渲染几张时，别死等到超时
        var 上次数 = 0
        var 上次动 = 起
        while Date() < 期限 {
            // 前 3 秒 120ms 一探（页面刚出来就是最快的时候），之后 250ms
            let 间: UInt64 = Date().timeIntervalSince(起) < 3 ? 120_000_000 : 250_000_000
            try? await Task.sleep(nanoseconds: 间)
            let p = await 探(窗)
            正文 = p.正文
            // 抖音风控偶尔先给一张「验证码中间页」，隔一下重载通常就放行
            if 出.图集.isEmpty, 出.视频号 == nil, 验证次 < 2,
               Date().timeIntervalSince(起) > 1.2,
               (正文.contains("验证码") || 正文.contains("中间页") || 正文.contains("滑块")) {
                验证次 += 1
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                窗.load(请)
                continue
            }
            if 出.页址.isEmpty { 出.页址 = p.页 }
            if 出.标题.isEmpty { 出.标题 = 净标题(p.标题, p.正文) }
            if 出.封面.isEmpty { 出.封面 = p.封面 }
            if !只图 {
                if let 号 = 空(p.视频号) {
                    出.视频号 = 号
                    出.原文地址 = 空(p.地址)
                    break
                }
                if let s = 空(p.地址), s.contains("video_id=") {
                    let 尾 = s.components(separatedBy: "video_id=").last ?? ""
                    let 视号 = 尾.components(separatedBy: "&").first ?? ""
                    if !视号.isEmpty {
                        出.视频号 = 视号
                        出.原文地址 = s
                        break
                    }
                }
            }
            // 同一个对象可能先给缩略图（330 宽）再给正图，按对象键留最宽的那份
            for (址, 宽, 高) in p.图片 {
                let 键 = 解析.图键(址)
                if !序.contains(键) { 序.append(键) }
                if (池宽[键] ?? 0) < 宽 { 池宽[键] = 宽; 池高[键] = 高; 池[键] = 址 }
            }
            if 出.图集.isEmpty, 池.count >= 图够 {
                let 选 = 挑图()
                let 够大 = 选.filter { u in (池宽[解析.图键(u)] ?? 0) >= 700 }.count
                // 数量凑够但全是小的（抖音常见的 330/540 瓦片）就再等等，正图晚一两秒才来
                if 选.count >= 图够 && (够大 >= 图够 || Date().timeIntervalSince(起) > 秒 * 0.7) {
                    出.图集 = 选
                    if 出.封面.isEmpty, let 头 = 出.图集.first { 出.封面 = 头 }
                    break
                }
            }
            // 图池停止长大的兜底：页面上就这几张（或只有首屏那几张），等 2.5 秒不再变就收工。
            // 只数 700 宽以上的——330 宽缩略图一直在偷偷加载，会把「还在长大」判错
            let 好数 = 序.filter { (池宽[$0] ?? 0) >= 700 }.count
            if 好数 != 上次数 {
                上次数 = 好数
                上次动 = Date()
            }
            if 出.图集.isEmpty, 好数 > 0, 好数 < 图够,
               Date().timeIntervalSince(上次动) > 2.5 {
                出.图集 = 挑图()
                if 出.封面.isEmpty, let 头 = 出.图集.first { 出.封面 = 头 }
                break
            }
            // 碰上登录墙就别干等了，立刻换下一个地址试
            if 出.视频号 == nil, 出.图集.isEmpty,
               (正文.contains("请先登录") || 正文.contains("登录后")),
               Date().timeIntervalSince(期限.addingTimeInterval(-秒)) > 3 {
                break
            }
        }
        // 到点了还没凑够：有几张给几张（别为了等数量把整条解析拖死）
        if 出.图集.isEmpty, !池.isEmpty {
            出.图集 = 挑图()
            if 出.封面.isEmpty, let 头 = 出.图集.first { 出.封面 = 头 }
        }
        记源()
        return (出, 正文)
    }

    // MARK: 快手 / 小红书 / 普通网页

    func 打开(_ 链接: String) async throws -> 抓到 {
        guard let u = URL(string: 链接) else { throw 解析错.平台("链接格式不对") }
        let 窗 = 建网()
        // 只停加载、不把窗口扔掉：共享壳留着，下一次解析省掉 WKWebView 启动
        defer { 窗.stopLoading() }

        var 请 = URLRequest(url: u)
        请.timeoutInterval = 20
        请.setValue(解析.网页UA, forHTTPHeaderField: "User-Agent")
        窗.load(请)

        var 出 = 抓到()
        let 期限 = Date().addingTimeInterval(14)
        var 空转 = 0
        while Date() < 期限 {
            try await Task.sleep(nanoseconds: 400_000_000)
            let p = await 探(窗)
            if 出.页址.isEmpty { 出.页址 = p.页 }
            if 出.标题.isEmpty { 出.标题 = 净标题(p.标题, p.正文) }
            if 出.封面.isEmpty { 出.封面 = p.封面 }
            if 出.视频.isEmpty, let s = 空(p.地址), s.hasPrefix("http"), !s.hasPrefix("blob:") {
                出.视频 = [清晰度(地址: s, 名称: "原画")]
            }
            if 出.图集.isEmpty, !p.图片.isEmpty {
                var 池: [String: String] = [:]
                var 池宽: [String: Int] = [:]
                var 池高: [String: Int] = [:]
                var 序: [String] = []
                for (址, 宽, 高) in p.图片 {
                    let 键 = 解析.图键(址)
                    if !序.contains(键) { 序.append(键) }
                    if (池宽[键] ?? 0) < 宽 { 池宽[键] = 宽; 池高[键] = 高; 池[键] = 址 }
                }
                // 带「-water」的是抖音的分享回流出图（图上烧了「抖音号：xxx」），有干净的就用干净的
                var 键们 = 序.filter { !(池[$0] ?? "").contains("-water") }
                if 键们.isEmpty { 键们 = 序 }
                let 大 = 键们.filter { (池宽[$0] ?? 0) >= 700 }
                if !大.isEmpty { 键们 = 大 }
                let 选 = 键们.compactMap { 池[$0] }
                // 只有 1~2 张的笔记也得收（这里以前要求 ≥3 张，单图笔记会误报「没抓到」）
                if !选.isEmpty { 出.图集 = 选 }
                if 出.封面.isEmpty, !选.isEmpty { 出.封面 = 选[0] }
                if let 最 = 键们.max(by: { (池宽[$0] ?? 0) < (池宽[$1] ?? 0) }) {
                    出.源宽 = 池宽[最] ?? 0
                    出.源高 = 池高[最] ?? 0
                }
            }
            if !出.视频.isEmpty { break }
            空转 += 1
            if 空转 > 25 { break }
        }
        if 出.视频.isEmpty && 出.图集.isEmpty { throw 解析错.空结果 }
        return 出
    }

    // MARK: 小工具

    private func 空(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// 抖音标题常是「描述 - 抖音」，去掉尾巴
    private func 净标题(_ 标题: String, _ 正文: String) -> String {
        var t = 标题
        for 尾 in [" - 抖音", "- 抖音", "_抖音", " - 快手", " - 小红书"] {
            if t.hasSuffix(尾) { t = String(t.dropLast(尾.count)) }
        }
        if t.isEmpty || t == "抖音" || t == "快手" { t = 正文 }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}




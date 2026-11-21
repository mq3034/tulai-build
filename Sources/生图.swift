import Foundation
import ImageIO
import UIKit

/// 负向词：sd-turbo 会忽略它，SDXL 才生效。
/// 主要是压"手/手指"这类最常见的崩坏（用户实测出过"手嵌在脸上"）。
let 生图负向词 = "lowres, bad anatomy, bad hands, extra fingers, fewer fingers, fused fingers, "
    + "deformed hands, missing fingers, extra limbs, text, watermark, signature, "
    + "worst quality, low quality, jpeg artifacts"

/// 生图服务的配置（服务器地址、令牌）。
///
/// 为什么放 UserDefaults 而不是写死：
///   这台电脑的局域网 IP 会变（DHCP），将来还要能切成云端地址。
///   用户选的是"先本地、将来可切云端"，所以地址必须可改、可清空。
enum 生图配置 {
    private static let 地址键 = "生图.服务器"
    private static let 令牌键 = "生图.令牌"

    /// 首次使用的预填值（用户可改）。改这里不影响已保存的设置。
    static let 预填地址 = "http://192.168.1.12:8790"
    static let 预填令牌 = "tulai-dev"

    static var 地址: String {
        get {
            let v = UserDefaults.standard.string(forKey: 地址键)
            return (v?.isEmpty == false) ? v! : 预填地址
        }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: 地址键) }
    }

    static var 令牌: String {
        get {
            let v = UserDefaults.standard.string(forKey: 令牌键)
            return (v?.isEmpty == false) ? v! : 预填令牌
        }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: 令牌键) }
    }

    static var 已配置: Bool {
        guard let u = URL(string: 地址), u.host != nil else { return false }
        return true
    }
}

/// /health 的返回
struct 生图健康: Decodable {
    let ok: Bool
    let ready: Bool?
    let model: String?
    let vram_mb: Int?
    let capabilities: [String]?
    let load_seconds: Double?
    let error: String?
}

/// 服务端统一错误体：{"error": "...", "code": "..."}
struct 生图错误体: Decodable {
    let error: String?
    let code: String?
}

/// 原生尺寸档。
///
/// 为什么不是"随便填个尺寸"：
///   SDXL（sdxl / illustrious）是 1024 原生模型，放太大结构会崩。1536 是 RTX 3070 8GB
///   实测还能出的上限（1536×1536 峰值显存 5.7GB，没 OOM）。
///   秒数是 3070 上 illustrious 20 步的实测值（不是估的），见服务端 README 实测表。
struct 生图尺寸档: Identifiable, Hashable {
    let id = UUID()
    let 名: String
    let 宽: Int
    let 高: Int
    let 秒: Double
    let 说明: String

    static let 全部: [生图尺寸档] = [
        生图尺寸档(名: "512×512", 宽: 512, 高: 512, 秒: 15.1, 说明: "最快，细节少"),
        生图尺寸档(名: "768×768", 宽: 768, 高: 768, 秒: 14.2, 说明: "快，日常够用"),
        生图尺寸档(名: "1024×1024", 宽: 1024, 高: 1024, 秒: 23.0, 说明: "SDXL 原生，推荐"),
        生图尺寸档(名: "1024×1536 竖", 宽: 1024, 高: 1536, 秒: 32.1, 说明: "竖图/手机壁纸"),
        生图尺寸档(名: "1536×1536", 宽: 1536, 高: 1536, 秒: 48.8, 说明: "最大原生，显存吃紧"),
    ]

    /// 从宽高找回档位（预设按钮改了尺寸时用于同步下拉框）
    static func 找(宽 w: Int, 高 h: Int) -> 生图尺寸档? {
        全部.first { $0.宽 == w && $0.高 == h }
    }
}

/// 放大档：目标长边（ESRGAN x4plus 分块超分）。
///
/// 秒数是"1024² 底图 + 超分"的 3070 实测总秒数（不是估的，见服务端 README 实测表）：
///   2048/4096 ≈ 32 秒，8192 ≈ 129 秒，14336 ≈ 136 秒。
/// 14336 长边在 1024×1536 竖底图上 = 9557×14336（137MP，约 13MB JPEG）。
/// 用户要的 14336×21504（308MP）服务端也支持（target 21504，实测 186 秒，22MB JPEG），
/// 但 App 不给这一档：手机上单张 300MP 相册/预览都很吃力。
struct 生图放大档: Identifiable, Hashable {
    let id = UUID()
    let 长边: Int       // 0 = 不放大
    let 名: String
    let 秒: Double

    static let 全部: [生图放大档] = [
        生图放大档(长边: 0, 名: "原图", 秒: 0),
        生图放大档(长边: 2048, 名: "2048", 秒: 33),
        生图放大档(长边: 4096, 名: "4096", 秒: 32),
        生图放大档(长边: 8192, 名: "8192", 秒: 129),
        生图放大档(长边: 14336, 名: "14336", 秒: 136),
    ]

    var 超大: Bool { 长边 >= 8192 }
}

/// /progress 的返回：生成/放大过程中的阶段进度（App 每 1.5 秒轮询一次）。
struct 生图进度: Decodable {
    let active: Bool?
    let phase: String?
    let pass: Int?
    let passes: Int?
    let tile: Int?
    let tiles: Int?
    let elapsed: Double?
    let eta: Double?
    let detail: String?
    let size: String?
    let error: String?

    /// 翻成用户能看懂的一句话
    var 人话: String {
        if let e = error, !e.isEmpty { return "出错：\(e)" }
        if active != true {
            return 完成说明
        }
        if let d = detail, !d.isEmpty {
            if let e = eta, e > 1 { return d + " · 约剩 \(Int(e.rounded())) 秒" }
            return d
        }
        if let p = pass, let n = passes, n > 0 {
            var s = "第 \(p)/\(n) 轮"
            if let t = tile, let tt = tiles, tt > 0 { s += " · \(t)/\(tt) 块" }
            return s
        }
        return "处理中…"
    }

    var 完成说明: String {
        if let s = size, !s.isEmpty { return "处理完成（\(s)）" }
        return "处理完成"
    }
}

struct 生图失败: LocalizedError {
    let 码: String
    let 说明: String
    var errorDescription: String? { 说明 }

    /// 把服务端 code 翻成人话 —— 用户看到的不该是 "unauthorized"
    static func 从(码: String?, 说明: String?) -> 生图失败 {
        switch 码 {
        case "unauthorized":
            return 生图失败(码: "unauthorized", 说明: "令牌不对：去设置里核对令牌（默认 tulai-dev）")
        case "model_not_ready":
            return 生图失败(码: "model_not_ready", 说明: "电脑上的模型还在加载，等几秒再试")
        case "invalid_steps":
            return 生图失败(码: "invalid_steps", 说明: "步数超范围：turbo 模型 1~4 步最合适")
        case "invalid_size":
            return 生图失败(码: "invalid_size", 说明: "尺寸必须是 8 的倍数（SDXL 最大 1536）")
        case "out_of_memory":
            return 生图失败(码: "out_of_memory", 说明: "电脑显存不足：降一档尺寸再试")
        case "esrgan_missing":
            return 生图失败(码: "esrgan_missing", 说明: "电脑上缺超分模型权重（RealESRGAN_x4plus.pth）")
        case "invalid_target":
            return 生图失败(码: "invalid_target", 说明: "放大目标尺寸不合法（长边 1024~21504）")
        case "unsupported_model":
            return 生图失败(码: "unsupported_model", 说明: "极速(turbo)模型不支持放大，请选高清/精细")
        case "hires_failed", "upscale_failed":
            return 生图失败(码: 码 ?? "hires_failed", 说明: "放大失败了：" + (说明 ?? "未知原因"))
        case "no_image", "bad_image":
            return 生图失败(码: 码 ?? "bad_image", 说明: "图片数据不对：" + (说明 ?? ""))
        default:
            return 生图失败(码: 码 ?? "unknown", 说明: 说明 ?? "生成失败，请重试")
        }
    }
}

/// 服务端实际送进模型的英文提示词（中文输入时由服务端翻译，用于界面回显）
nonisolated(unsafe) var 上次实际提示词: String = ""

enum 生图客户端 {
    /// 普通出图超时：连接 5 秒、整体 90 秒（1536² 在 3070 上约 45 秒，留余量）
    private static var 会话: URLSession {
        let 配 = URLSessionConfiguration.ephemeral
        配.timeoutIntervalForRequest = 90
        配.timeoutIntervalForResource = 120
        配.waitsForConnectivity = false
        return URLSession(configuration: 配)
    }

    /// /hires 超时：底图 30~45 秒 + 超分 10~90 秒，14336 档整单可能 2 分钟，
    /// 所以 request 超时放到 600 秒、整单 3600 秒（长请求期间服务端不出字节，普通 90 秒会误杀）。
    private static var 长会话: URLSession {
        let 配 = URLSessionConfiguration.ephemeral
        配.timeoutIntervalForRequest = 600
        配.timeoutIntervalForResource = 3600
        配.waitsForConnectivity = false
        return URLSession(configuration: 配)
    }

    private static func 拼(_ 路径: String) throws -> URL {
        let 基 = 生图配置.地址.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !基.isEmpty, let u = URL(string: 基 + 路径) else {
            throw 生图失败(码: "bad_url", 说明: "服务器地址没填对：设置里填 http://电脑IP:8790")
        }
        return u
    }

    private static func 网络错误(_ e: Error) -> 生图失败 {
        let n = e as NSError
        if n.domain == NSURLErrorDomain {
            switch n.code {
            case NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost, NSURLErrorNetworkConnectionLost:
                return 生图失败(码: "offline", 说明: "连不上电脑：确认手机和电脑在同一个 Wi-Fi、电脑上的服务在跑")
            case NSURLErrorTimedOut:
                return 生图失败(码: "timeout", 说明: "等太久了：电脑可能卡住，或图片太大")
            case NSURLErrorNotConnectedToInternet:
                return 生图失败(码: "offline", 说明: "手机没联网")
            default:
                break
            }
        }
        return 生图失败(码: "network", 说明: "网络错误：" + e.localizedDescription)
    }

    /// 探测服务是否可用
    static func 健康检查() async throws -> 生图健康 {
        let u = try 拼("/health")
        do {
            let (数据, 回) = try await 会话.data(from: u)
            guard let http = 回 as? HTTPURLResponse, http.statusCode == 200 else {
                throw 生图失败.从(码: nil, 说明: "服务返回异常（HTTP \((回 as? HTTPURLResponse)?.statusCode ?? -1)）")
            }
            return try JSONDecoder().decode(生图健康.self, from: 数据)
        } catch let e as 生图失败 {
            throw e
        } catch {
            throw 网络错误(error)
        }
    }

    /// 生成一张图：返回 (图片, 服务端耗时秒, 种子)
    static func 生成(提示词: String, 宽: Int, 高: Int, 步数: Int, 种子: Int?,
                    模型: String = "illustrious") async throws -> (UIImage, Double, Int) {
        let u = try 拼("/gen")
        var 请求 = URLRequest(url: u)
        请求.httpMethod = "POST"
        请求.setValue("application/json", forHTTPHeaderField: "Content-Type")
        请求.setValue(生图配置.令牌, forHTTPHeaderField: "X-Token")

        var 体: [String: Any] = [
            "prompt": 提示词,
            "negative": 生图负向词,
            "steps": 步数,
            "width": 宽,
            "height": 高,
            "model": 模型,
        ]
        if let 种子 { 体["seed"] = 种子 }
        请求.httpBody = try JSONSerialization.data(withJSONObject: 体)

        do {
            let (数据, 回) = try await 会话.data(for: 请求)
            guard let http = 回 as? HTTPURLResponse else {
                throw 生图失败(码: "bad_response", 说明: "服务没回响应")
            }
            guard http.statusCode == 200 else {
                // 错误体是 JSON；解不出来就退回状态码
                if let e = try? JSONDecoder().decode(生图错误体.self, from: 数据) {
                    throw 生图失败.从(码: e.code, 说明: e.error)
                }
                throw 生图失败(码: "http_\(http.statusCode)", 说明: "服务返回 HTTP \(http.statusCode)")
            }
            guard let 图 = UIImage(data: 数据) else {
                throw 生图失败(码: "bad_image", 说明: "返回的数据不是图片")
            }
            let 秒 = Double(http.value(forHTTPHeaderField: "X-Seconds") ?? "") ?? 0
            // 服务端可能把中文翻译成英文再送模型，把实际用的提示词带回来方便核对
            上次实际提示词 = http.value(forHTTPHeaderField: "X-Prompt-Used")
                .flatMap { $0.removingPercentEncoding } ?? ""
            let 号 = Int(http.value(forHTTPHeaderField: "X-Seed") ?? "") ?? 0
            return (图, 秒, 号)
        } catch let e as 生图失败 {
            throw e
        } catch {
            throw 网络错误(error)
        }
    }

    /// 高清出图：POST /hires（底图 + ESRGAN 超分），一次请求拿到最终大图。
    ///
    /// 为什么返回 Data + 缩略图，而不是 UIImage：
    ///   14336 长边整张解成位图要 1GB 以上内存，手机会被系统直接杀掉。
    ///   所以显示只用 ImageIO 缩出来的 2048 缩略图，原图数据直接写进相册。
    static func 高清生成(提示词: String, 宽: Int, 高: Int, 步数: Int, 种子: Int?,
                       模型: String, 放大到长边: Int) async throws
        -> (数据: Data, 缩略图: UIImage, 秒: Double, 号: Int, 实际尺寸: String) {
        let u = try 拼("/hires")
        var 请求 = URLRequest(url: u)
        请求.httpMethod = "POST"
        请求.setValue("application/json", forHTTPHeaderField: "Content-Type")
        请求.setValue(生图配置.令牌, forHTTPHeaderField: "X-Token")
        let 号 = 种子 ?? Int.random(in: 0...2_000_000_000)
        let 体: [String: Any] = [
            "prompt": 提示词,
            "negative": 生图负向词,
            "steps": 步数,
            "base_width": 宽,
            "base_height": 高,
            "target_long_edge": 放大到长边,
            "model": 模型,
            "seed": 号,
            "mode": "esrgan",
        ]
        请求.httpBody = try JSONSerialization.data(withJSONObject: 体)

        do {
            let (数据, 回) = try await 长会话.data(for: 请求)
            guard let http = 回 as? HTTPURLResponse else {
                throw 生图失败(码: "bad_response", 说明: "服务没回响应")
            }
            guard http.statusCode == 200 else {
                if let e = try? JSONDecoder().decode(生图错误体.self, from: 数据) {
                    throw 生图失败.从(码: e.code, 说明: e.error)
                }
                throw 生图失败(码: "http_\(http.statusCode)", 说明: "服务返回 HTTP \(http.statusCode)")
            }
            guard let 缩略 = 缩略图(数据) else {
                throw 生图失败(码: "bad_image", 说明: "返回的数据不是图片")
            }
            上次实际提示词 = http.value(forHTTPHeaderField: "X-Prompt-Used")
                .flatMap { $0.removingPercentEncoding } ?? ""
            let 秒 = Double(http.value(forHTTPHeaderField: "X-Seconds") ?? "") ?? 0
            let 尺寸 = http.value(forHTTPHeaderField: "X-Size") ?? "\(宽)×\(高)"
            return (数据, 缩略, 秒, 号, 尺寸)
        } catch let e as 生图失败 {
            throw e
        } catch {
            throw 网络错误(error)
        }
    }

    /// 轮询 /progress：生成中显示"第 2/2 轮 · 37/64 块"这类真实阶段。
    /// 失败一律返回 nil（进度拿不到不该打断出图）。
    static func 进度() async -> 生图进度? {
        guard let u = try? 拼("/progress") else { return nil }
        var 请求 = URLRequest(url: u)
        请求.setValue(生图配置.令牌, forHTTPHeaderField: "X-Token")
        请求.timeoutInterval = 6
        guard let (数据, 回) = try? await 会话.data(for: 请求),
              (回 as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(生图进度.self, from: 数据)
    }

    /// 大图缩略图：ImageIO 只解到 2048 像素，避免超大位图吃爆手机内存。
    private static func 缩略图(_ 数据: Data, 最大边: CGFloat = 2048) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(数据 as CFData, nil) else { return nil }
        let 选项: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 最大边,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, 选项 as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cg)
    }
}

/// 提示词预设。
/// 为什么必须有：sd-turbo 的文本编码器只认英文，中文提示词等于噪声。
/// 预设给的是英文，用户点一下就有结果，不用自己翻译。
struct 生图预设: Identifiable {
    let id = UUID()
    let 名: String
    let 提示词: String
    let 宽: Int
    let 高: Int

    static let 全部: [生图预设] = [
        生图预设(名: "动漫少女", 提示词: "anime girl, silver hair, detailed eyes, soft lighting, illustration, high quality",
                 宽: 1024, 高: 1536),
        生图预设(名: "写实人像", 提示词: "portrait photo of a young woman, natural light, sharp focus, 85mm lens, bokeh",
                 宽: 1024, 高: 1536),
        生图预设(名: "电商产品", 提示词: "product photo of a cosmetic bottle on white background, studio lighting, clean, minimal",
                 宽: 1024, 高: 1024),
        生图预设(名: "风景", 提示词: "mountain lake at sunrise, mist, cinematic, ultra detailed landscape photography",
                 宽: 1024, 高: 1024),
    ]
}

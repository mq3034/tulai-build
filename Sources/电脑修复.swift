//
//  电脑修复.swift
//  图来
//
//  把电脑上「短视频去水印 · 本机版」(vdl, 默认 127.0.0.1:8770) 的图片修复引擎
//  接进 App：涂好的图 + 黑白蒙版一起 POST 到 /api/inpaint，拿回修好的整图。
//  引擎在电脑上跑 LaMa(ONNX)，手机只负责涂和传，所以效果比本机「平滑填补」干净。
//
//  接口（见 vdl/app.py）：
//    POST /api/inpaint  {"image":"data:image/png;base64,...","mask":"...","engine":"auto"}
//    → {"ok":true,"url":"/outputs/fix_xxx.png","engine":"lama","ms":3120}
//    蒙版：白(>100) = 要修掉的区域。
//

import Foundation
import UIKit

enum 电脑修复 {
    /// 电脑上 vdl 起的服务地址（同一 Wi-Fi，端口 8770）
    static let 缺省地址 = "192.168.1.12:8770"
    static let 地址键 = "电脑修复.地址"

    static var 地址: String {
        get {
            let s = UserDefaults.standard.string(forKey: 地址键) ?? ""
            return s.isEmpty ? 缺省地址 : s
        }
        set { UserDefaults.standard.set(规范(newValue), forKey: 地址键) }
    }

    /// "http://192.168.1.12:8770/" → "192.168.1.12:8770"
    static func 规范(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("http://") { t.removeFirst(7) }
        if t.hasPrefix("https://") { t.removeFirst(8) }
        while t.hasSuffix("/") { t.removeLast() }
        if !t.contains(":") { t += ":8770" }
        return t.isEmpty ? 缺省地址 : t
    }

    enum 错: LocalizedError {
        case 无图, 无选区, 连不上(String), 服务器(String), 回包坏了

        var errorDescription: String? {
            switch self {
            case .无图: return "没有图"
            case .无选区: return "先涂一下要修的地方"
            case .连不上(let s): return "连不上电脑（\(s)），检查同一 Wi-Fi 和电脑上的 start.bat"
            case .服务器(let s): return "电脑那边报错：\(s)"
            case .回包坏了: return "电脑回的数据看不懂"
            }
        }
    }

    // MARK: - 蒙版

    /// 按涂的笔迹画一张黑白蒙版（白 = 要修）。缓冲第 0 行就是图的最上面一行，
    /// 和 修图.平滑填补 的 [Bool] 掩码同一朝向，不用再翻。
    static func 笔迹掩码(宽 w: Int, 高 h: Int, 点们: [CGPoint], 笔: Double) -> CGImage? {
        guard w > 0, h > 0 else { return nil }
        var 缓冲 = [UInt8](repeating: 0, count: w * h)
        let 半径 = max(3.0, Double(min(w, h)) * 笔 / 900)
        let 半径2 = 半径 * 半径
        for p in 点们 {
            let cx = p.x * Double(w), cy = p.y * Double(h)
            let x0 = max(0, Int(cx - 半径)), x1 = min(w - 1, Int(cx + 半径))
            let y0 = max(0, Int(cy - 半径)), y1 = min(h - 1, Int(cy + 半径))
            guard x0 <= x1, y0 <= y1 else { continue }
            for y in y0...y1 {
                for x in x0...x1 {
                    let dx = Double(x) - cx, dy = Double(y) - cy
                    if dx * dx + dy * dy <= 半径2 { 缓冲[y * w + x] = 255 }
                }
            }
        }
        return 出灰度图(缓冲, w, h)
    }

    /// 一键圈住右下角（和电脑版「圈右下角」同口径：34% × 14%）
    static func 右下角掩码(宽 w: Int, 高 h: Int) -> CGImage? {
        guard w > 0, h > 0 else { return nil }
        var 缓冲 = [UInt8](repeating: 0, count: w * h)
        let x0 = Int(Double(w) * 0.66), y0 = Int(Double(h) * 0.86)
        guard x0 < w, y0 < h else { return nil }
        for y in y0..<h {
            for x in x0..<w { 缓冲[y * w + x] = 255 }
        }
        return 出灰度图(缓冲, w, h)
    }

    private static func 出灰度图(_ 缓冲: [UInt8], _ w: Int, _ h: Int) -> CGImage? {
        guard let 供 = CGDataProvider(data: Data(缓冲) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8,
                       bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: 供, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)
    }

    // MARK: - 传输

    /// 传到电脑修，返回修好的整图（尺寸和原图一致）
    static func 修(_ cg: CGImage, 掩: CGImage, 地址 原地址: String = 电脑修复.地址,
                   超时: TimeInterval = 120) async throws -> CGImage {
        guard let 图数据 = UIImage(cgImage: cg).pngData() else { throw 错.无图 }
        guard let 掩数据 = UIImage(cgImage: 掩).pngData() else { throw 错.无选区 }
        let 主机 = 规范(原地址)
        guard let 基 = URL(string: "http://\(主机)") else { throw 错.连不上(主机) }

        let 体: [String: Any] = [
            "image": "data:image/png;base64," + 图数据.base64EncodedString(),
            "mask": "data:image/png;base64," + 掩数据.base64EncodedString(),
            "engine": "auto"
        ]
        var 请 = URLRequest(url: 基.appendingPathComponent("api/inpaint"))
        请.httpMethod = "POST"
        请.timeoutInterval = 超时
        请.setValue("application/json", forHTTPHeaderField: "Content-Type")
        请.httpBody = try JSONSerialization.data(withJSONObject: 体)

        let 配置 = URLSessionConfiguration.default
        配置.timeoutIntervalForRequest = 超时
        配置.timeoutIntervalForResource = 超时
        配置.waitsForConnectivity = false
        let 会 = URLSession(configuration: 配置)
        defer { 会.finishTasksAndInvalidate() }

        let (回, 应) = try await 传(会, 请, 主机)
        guard let http = 应 as? HTTPURLResponse, http.statusCode == 200 else {
            throw 错.连不上(主机)
        }
        guard let json = (try? JSONSerialization.jsonObject(with: 回)) as? [String: Any] else {
            throw 错.回包坏了
        }
        if let ok = json["ok"] as? Bool, ok, let 相对 = json["url"] as? String,
           let 图址 = URL(string: "http://\(主机)" + 相对) {
            let (图回, 图应) = try await 传(会, URLRequest(url: 图址), 主机)
            guard (图应 as? HTTPURLResponse)?.statusCode == 200, let ui = UIImage(data: 图回),
                  let 出 = ui.cgImage else { throw 错.回包坏了 }
            return 出
        }
        throw 错.服务器((json["error"] as? String) ?? "未知错误")
    }

    /// 让电脑做**精确抠像**，返回前景遮罩（白=人物）。
    ///
    /// 为什么需要（2026-11-16 用户反馈）：App 本地用的是 Vision 显著性，
    /// 出来是"模糊热力图"——边缘一圈蓝边、发丝贴不住，拖人时人层和背景永远对不齐。
    /// 电脑上跑的是动漫专用分割模型（isnetis，1 秒），边缘能贴到发丝，
    /// 这才是醒图那种贴合度。
    ///
    /// 遮罩语义：白(255)=前景（人物），和 /api/inpaint 的 mask 一致。
    static func 分割(_ cg: CGImage, 地址 原地址: String = 电脑修复.地址,
                   超时: TimeInterval = 30) async throws -> CGImage {
        guard let 图数据 = UIImage(cgImage: cg).pngData() else { throw 错.无图 }
        let 主机 = 规范(原地址)
        guard let 基 = URL(string: "http://\(主机)") else { throw 错.连不上(主机) }

        let 体: [String: Any] = ["image": "data:image/png;base64," + 图数据.base64EncodedString()]
        var 请 = URLRequest(url: 基.appendingPathComponent("api/segment"))
        请.httpMethod = "POST"
        请.timeoutInterval = 超时
        请.setValue("application/json", forHTTPHeaderField: "Content-Type")
        请.httpBody = try JSONSerialization.data(withJSONObject: 体)

        let 配置 = URLSessionConfiguration.default
        配置.timeoutIntervalForRequest = 超时
        配置.timeoutIntervalForResource = 超时
        配置.waitsForConnectivity = false
        let 会 = URLSession(configuration: 配置)
        defer { 会.finishTasksAndInvalidate() }

        let (回, 应) = try await 传(会, 请, 主机)
        guard let http = 应 as? HTTPURLResponse, http.statusCode == 200 else { throw 错.连不上(主机) }
        guard let json = (try? JSONSerialization.jsonObject(with: 回)) as? [String: Any] else { throw 错.回包坏了 }
        if let ok = json["ok"] as? Bool, ok, let 相对 = json["url"] as? String,
           let 图址 = URL(string: "http://\(主机)" + 相对) {
            let (图回, 图应) = try await 传(会, URLRequest(url: 图址), 主机)
            guard (图应 as? HTTPURLResponse)?.statusCode == 200, let ui = UIImage(data: 图回),
                  let 出 = ui.cgImage else { throw 错.回包坏了 }
            return 出
        }
        throw 错.服务器((json["error"] as? String) ?? "未知错误")
    }

    /// 探一下电脑在不在（设置页/首次用时给个明确的提示）
    static func 在不在(_ 原地址: String = 电脑修复.地址, 超时: TimeInterval = 4) async -> Bool {
        let 主机 = 规范(原地址)
        guard let u = URL(string: "http://\(主机)/api/health") else { return false }
        var 请 = URLRequest(url: u)
        请.timeoutInterval = 超时
        let 配置 = URLSessionConfiguration.ephemeral
        配置.timeoutIntervalForRequest = 超时
        let 会 = URLSession(configuration: 配置)
        defer { 会.finishTasksAndInvalidate() }
        guard let 回包 = try? await 会.data(for: 请) else { return false }
        return (回包.1 as? HTTPURLResponse)?.statusCode == 200
    }

    /// 把 URLError 换成看得懂的话
    private static func 传(_ 会: URLSession, _ 请: URLRequest,
                          _ 主机: String) async throws -> (Data, URLResponse) {
        do {
            return try await 会.data(for: 请)
        } catch let e as URLError {
            switch e.code {
            case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost,
                 .timedOut, .notConnectedToInternet, .secureConnectionFailed:
                throw 错.连不上(主机)
            default:
                throw 错.连不上(主机)
            }
        }
    }
}

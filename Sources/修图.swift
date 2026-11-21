import UIKit
import UniformTypeIdentifiers
import Vision
import CoreImage
import CoreImage.CIFilterBuiltins

/// 修图设置（跟着任务一起存，断点续做也一致）
struct 修图设置: Codable {
    var 比例: String = "原比例"      // 原比例 / 1:1 / 3:4 / 4:3
    var 调色: String = "原色"        // 原色 / 清爽 / 暖调 / 鲜明
    var 增高: Double = 0             // 0~0.25（下半身拉长比例）
    var 瘦腿: Double = 0             // 0~1（局部收缩强度）
    var 擦除角: String = "不擦"      // 不擦 / 左上 / 右上 / 左下 / 右下
}

enum 修图 {

    // ---------- 调色 ----------
    static func 调色(_ cg: CGImage, 预设: String) -> CGImage? {
        guard 预设 != "原色" else { return cg }
        let 源 = CIImage(cgImage: cg)
        var 出 = 源
        let 控 = CIFilter.colorControls()
        控.inputImage = 出
        switch 预设 {
        case "清爽":
            控.saturation = 1.12; 控.brightness = 0.03; 控.contrast = 1.06
        case "暖调":
            控.saturation = 1.08; 控.brightness = 0.02; 控.contrast = 1.04
        case "鲜明":
            控.saturation = 1.25; 控.brightness = 0.01; 控.contrast = 1.12
        default:
            return cg
        }
        控.inputImage = 出
        if let a = 控.outputImage { 出 = a }
        if 预设 == "暖调" {
            let 温 = CIFilter.temperatureAndTint()
            温.inputImage = 出
            温.neutral = CIVector(x: 5600, y: 0)
            温.targetNeutral = CIVector(x: 4700, y: 0)
            if let a = 温.outputImage { 出 = a }
        }
        let 上 = CIContext(options: [.useSoftwareRenderer: false])
        return 上.createCGImage(出, from: 源.extent)
    }

    // ---------- 裁剪比例 ----------
    static func 裁比例(_ cg: CGImage, 比例: String) -> CGImage {
        var 比: CGFloat = 0
        switch 比例 {
        case "1:1": 比 = 1
        case "3:4": 比 = 3.0 / 4.0
        case "4:3": 比 = 4.0 / 3.0
        default: return cg
        }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let 现 = w / h
        var 框 = CGRect(x: 0, y: 0, width: w, height: h)
        if 现 > 比 {                     // 太宽 → 裁左右
            let 新宽 = h * 比
            框 = CGRect(x: (w - 新宽) / 2, y: 0, width: 新宽, height: h)
        } else if 现 < 比 {              // 太高 → 裁上下
            let 新高 = w / 比
            框 = CGRect(x: 0, y: (h - 新高) / 2, width: w, height: 新高)
        }
        return cg.cropping(to: 框) ?? cg
    }

    // ---------- 增高：下半身纵向拉长 ----------
    static func 增高(_ cg: CGImage, 强度: Double) -> CGImage? {
        guard 强度 > 0.01 else { return cg }
        let w = cg.width, h = cg.height
        let 分界 = Int(Double(h) * 0.42)         // 42% 以下算下半身
        let 拉 = 1.0 + 强度
        guard let 上 = CGContext(data: nil, width: w, height: h,
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return cg }
        上.interpolationQuality = .high
        // 上半身原样
        if let 头 = cg.cropping(to: CGRect(x: 0, y: 0, width: w, height: 分界)) {
            上.draw(头, in: CGRect(x: 0, y: CGFloat(h - 分界),
                                  width: CGFloat(w), height: CGFloat(分界)))
        }
        // 下半身拉长（超出部分裁掉，脚留在底部）
        if let 腿 = cg.cropping(to: CGRect(x: 0, y: 分界,
                                          width: w, height: h - 分界)) {
            let 高 = CGFloat(h - 分界) * CGFloat(拉)
            上.draw(腿, in: CGRect(x: 0, y: 0, width: CGFloat(w), height: 高))
        }
        return 上.makeImage()
    }

    // ---------- 瘦腿：下半身逐行横向收缩 ----------
    static func 瘦腿(_ cg: CGImage, 强度: Double) -> CGImage? {
        guard 强度 > 0.01 else { return cg }
        let w = cg.width, h = cg.height
        let 分界 = Int(Double(h) * 0.40)
        let 带高 = h - 分界
        guard 带高 > 10 else { return cg }

        guard let 腿 = cg.cropping(to: CGRect(x: 0, y: 分界, width: w, height: 带高))
        else { return cg }
        guard let 上 = CGContext(data: nil, width: w, height: h,
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return cg }
        上.interpolationQuality = .high

        // 上半身不动（CoreGraphics 原点在左下）
        if let 头 = cg.cropping(to: CGRect(x: 0, y: 0, width: w, height: 分界)) {
            上.draw(头, in: CGRect(x: 0, y: CGFloat(h - 分界),
                                  width: CGFloat(w), height: CGFloat(分界)))
        }

        // 下半身：按行切 240 条，每条横向收缩（越靠下越强）
        let 条数 = 240
        let 条高 = max(1, 带高 / 条数)
        var y = 0
        while y < 带高 {
            let 高 = min(条高, 带高 - y)
            if let 条 = 腿.cropping(to: CGRect(x: 0, y: y, width: w, height: 高)) {
                let t = Double(y) / Double(带高)                 // 0 上 → 1 下
                let 收 = 1.0 - 强度 * 0.35 * (0.4 + 0.6 * t)     // 最多收 35%
                let 宽 = CGFloat(w) * CGFloat(收)
                let x = (CGFloat(w) - 宽) / 2
                上.draw(条, in: CGRect(x: x, y: CGFloat(带高 - y - 高),
                                     width: 宽, height: CGFloat(高)))
            }
            y += 条高
        }
        return 上.makeImage()
    }

    // ---------- 擦除：角上一块用附近内容填补 ----------
    static func 擦除角(_ cg: CGImage, 角: String) -> CGImage? {
        guard 角 != "不擦" else { return cg }
        let w = cg.width, h = cg.height
        let 块宽 = Int(Double(w) * 0.30), 块高 = Int(Double(h) * 0.12)
        var x = 0, yC = 0
        switch 角 {
        case "左上": x = 0; yC = 0
        case "右上": x = w - 块宽; yC = 0
        case "左下": x = 0; yC = h - 块高
        default: x = w - 块宽; yC = h - 块高
        }
        guard let 上 = CGContext(data: nil, width: w, height: h,
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return cg }
        上.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        上.interpolationQuality = .high

        // 取这块正上方/正下方一条，拉伸后盖住
        let 源y = (yC + 块高 < h) ? yC + 块高 : max(0, yC - 块高)
        let 源高 = min(块高, h - 源y)
        if 源高 > 2, let 补 = cg.cropping(to: CGRect(x: x, y: 源y, width: 块宽, height: 源高)) {
            上.draw(补, in: CGRect(x: x, y: h - yC - 块高,
                                width: 块宽, height: 块高))
        }
        return 上.makeImage()
    }

    // ---------- 一条龙 ----------
    static func 走一遍(_ cg: CGImage, 设置: 修图设置) -> CGImage? {
        var 图 = cg
        图 = 裁比例(图, 比例: 设置.比例)
        if let a = 擦除角(图, 角: 设置.擦除角) { 图 = a }
        if let a = 增高(图, 强度: 设置.增高) { 图 = a }
        if let a = 瘦腿(图, 强度: 设置.瘦腿) { 图 = a }
        if let a = 调色(图, 预设: 设置.调色) { 图 = a }
        return 图
    }
}

// MARK: - 16 项精调（照醒图「调节」那套，网页版验过的算法）

struct 调节参数: Equatable, Codable {
    var 亮度: Double = 0
    var 对比: Double = 0
    var 饱和: Double = 0
    var 自然饱和: Double = 0
    var 色温: Double = 0
    var 色调: Double = 0
    var 曝光: Double = 0
    var 高光: Double = 0
    var 阴影: Double = 0
    var 清晰度: Double = 0
    var 锐化: Double = 0
    var 纹理: Double = 0
    var 颗粒: Double = 0
    var 褪色: Double = 0
    var 光感: Double = 0
    var 磨皮: Double = 0
    var 美白: Double = 0
    var 瘦脸: Double = 0

    var 有内容: Bool {
        亮度 != 0 || 对比 != 0 || 饱和 != 0 || 自然饱和 != 0 || 色温 != 0 || 色调 != 0 ||
        曝光 != 0 || 高光 != 0 || 阴影 != 0 || 清晰度 != 0 || 锐化 != 0 || 纹理 != 0 ||
        颗粒 != 0 || 褪色 != 0 || 光感 != 0 || 磨皮 != 0 || 美白 != 0 || 瘦脸 != 0
    }
}

extension 修图 {

    /// 可分离方框模糊（灰度各通道一起）
    static func 模糊(_ 源: [UInt8], _ w: Int, _ h: Int, _ r: Int) -> [UInt8] {
        var 横 = [UInt8](repeating: 0, count: 源.count)
        var 出 = [UInt8](repeating: 0, count: 源.count)
        if r <= 0 { return 源 }
        for y in 0..<h {
            for x in 0..<w {
                let a = max(0, x - r), b = min(w - 1, x + r)
                var s0 = 0, s1 = 0, s2 = 0
                for k in a...b {
                    let i = (y * w + k) * 4
                    s0 += Int(源[i]); s1 += Int(源[i + 1]); s2 += Int(源[i + 2])
                }
                let n = b - a + 1, j = (y * w + x) * 4
                横[j] = UInt8(s0 / n); 横[j + 1] = UInt8(s1 / n); 横[j + 2] = UInt8(s2 / n)
                横[j + 3] = 源[j + 3]
            }
        }
        for y in 0..<h {
            for x in 0..<w {
                let a = max(0, y - r), b = min(h - 1, y + r)
                var s0 = 0, s1 = 0, s2 = 0
                for k in a...b {
                    let i = (k * w + x) * 4
                    s0 += Int(横[i]); s1 += Int(横[i + 1]); s2 += Int(横[i + 2])
                }
                let n = b - a + 1, j = (y * w + x) * 4
                出[j] = UInt8(s0 / n); 出[j + 1] = UInt8(s1 / n); 出[j + 2] = UInt8(s2 / n)
                出[j + 3] = 横[j + 3]
            }
        }
        return 出
    }

    /// 反锐化：清晰度(大半径) / 纹理(中半径) / 锐化(小半径)
    static func 反锐化(_ 源: inout [UInt8], _ w: Int, _ h: Int, _ 半径: Int, _ 量: Double) {
        guard 量 != 0 else { return }
        let 糊 = 模糊(源, w, h, 半径)
        let k = 量 / 100
        for i in stride(from: 0, to: 源.count, by: 4) {
            for c in 0..<3 {
                let v = Double(源[i + c]) + (Double(源[i + c]) - Double(糊[i + c])) * k
                源[i + c] = UInt8(max(0, min(255, v)))
            }
        }
    }

    /// 瘦脸：中部按椭圆曲线横向收
    static func 瘦脸(_ cg: CGImage, _ 强: Double) -> CGImage {
        guard 强 > 0.01 else { return cg }
        let w = cg.width, h = cg.height
        let k = 强 / 100 * 0.20
        guard let 上 = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return cg }
        上.interpolationQuality = .high
        let 顶 = Double(h) * 0.18, 底 = Double(h) * 0.82
        for y in 0..<h {
            let t = (Double(y) - 顶) / (底 - 顶)
            let 收 = (t > 0 && t < 1) ? sin(Double.pi * t) : 0
            let 宽Cg: CGFloat = CGFloat(Double(w) * (1 - k * 收))
            let 源框 = CGRect(x: 0, y: CGFloat(y), width: CGFloat(w), height: 1)
            let 目标框 = CGRect(x: (CGFloat(w) - 宽Cg) / 2,
                             y: CGFloat(h - y - 1),
                             width: 宽Cg, height: 1)
            if let 条 = cg.cropping(to: 源框) {
                上.draw(条, in: 目标框)
            }
        }
        return 上.makeImage() ?? cg
    }

    /// 一条龙：瘦脸 → 16 项精调
    static func 精调(_ cg: CGImage, _ p: 调节参数) -> CGImage? {
        var 图 = cg
        if p.瘦脸 > 0 { 图 = 瘦脸(图, p.瘦脸) }
        guard p.有内容 else { return 图 }

        let w = 图.width, h = 图.height
        var 源 = [UInt8](repeating: 0, count: w * h * 4)
        guard let 上下文 = CGContext(data: &源, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 图 }
        上下文.draw(图, in: CGRect(x: 0, y: 0, width: w, height: h))

        // 磨皮：模糊一层按强度混回去
        if p.磨皮 > 0 {
            let 糊 = 模糊(源, w, h, 4)
            let k = min(0.75, p.磨皮 / 100 * 0.8)
            for i in stride(from: 0, to: 源.count, by: 4) {
                for c in 0..<3 {
                    源[i + c] = UInt8(Double(源[i + c]) * (1 - k) + Double(糊[i + c]) * k)
                }
            }
        }

        let 亮 = p.亮度 / 100 * 62
        let 乘 = 1 + p.对比 / 100
        let 饱 = 1 + p.饱和 / 100
        let 自饱 = 1 + p.自然饱和 / 100 * 0.8
        let 温加 = p.色温 / 100 * 26
        let 调加 = p.色调 / 100 * 22
        let 曝乘 = pow(2.0, p.曝光 / 100 * 1.2)
        let 高k = p.高光 / 100 * 0.7
        let 阴k = p.阴影 / 100 * 0.9
        let 褪k = p.褪色 / 100
        let 光k = p.光感 / 100 * 0.5
        let 白k = p.美白 / 100 * 0.30
        let 颗 = p.颗粒 / 100

        for i in stride(from: 0, to: 源.count, by: 4) {
            var r = Double(源[i]), g = Double(源[i + 1]), b = Double(源[i + 2])

            if p.曝光 != 0 { r *= 曝乘; g *= 曝乘; b *= 曝乘 }
            if 亮 != 0 { r += 亮; g += 亮; b += 亮 }

            if 光k != 0 {
                let l = (0.299 * r + 0.587 * g + 0.114 * b) / 255
                let 加 = 255 * 光k * l * l
                r += 加; g += 加; b += 加
            }
            if 高k != 0 || 阴k != 0 {
                let l = (0.299 * r + 0.587 * g + 0.114 * b) / 255
                if 高k != 0 && l > 0.45 {
                    let t = (l - 0.45) / 0.55, f = 1 + 高k * t * t
                    r *= f; g *= f; b *= f
                }
                if 阴k != 0 && l < 0.55 {
                    let t = (0.55 - l) / 0.55, f = 1 + 阴k * t * t
                    r *= f; g *= f; b *= f
                }
            }
            if 乘 != 1 {
                r = (r - 128) * 乘 + 128; g = (g - 128) * 乘 + 128; b = (b - 128) * 乘 + 128
            }
            if 饱 != 1 || 自饱 != 1 {
                let 灰 = 0.299 * r + 0.587 * g + 0.114 * b
                r = 灰 + (r - 灰) * 饱; g = 灰 + (g - 灰) * 饱; b = 灰 + (b - 灰) * 饱
                if 自饱 != 1 {
                    let 现 = max(r, max(g, b)) - min(r, min(g, b))
                    let 少 = 1 - min(1, 现 / 160)
                    let kk = 1 + (自饱 - 1) * 少
                    r = 灰 + (r - 灰) * kk; g = 灰 + (g - 灰) * kk; b = 灰 + (b - 灰) * kk
                }
            }
            if 温加 != 0 || 调加 != 0 {
                r += 温加 + 调加 * 0.5; g -= 调加; b -= 温加 - 调加 * 0.5
            }
            if 褪k != 0 {
                let 灰 = 0.299 * r + 0.587 * g + 0.114 * b
                r = (灰 + (r - 灰) * (1 - 褪k * 0.55)) * (1 - 褪k * 0.08) + 255 * 褪k * 0.14
                g = (灰 + (g - 灰) * (1 - 褪k * 0.55)) * (1 - 褪k * 0.08) + 250 * 褪k * 0.13
                b = (灰 + (b - 灰) * (1 - 褪k * 0.55)) * (1 - 褪k * 0.08) + 240 * 褪k * 0.11
            }
            if 白k != 0 {
                r = r * (1 - 白k) + 255 * 白k
                g = g * (1 - 白k) + 255 * 白k
                b = b * (1 - 白k) + 255 * 白k
            }
            if 颗 != 0 {
                let px = (i / 4) % w, py = (i / 4) / w
                let n = Double((px &* 374761393 &+ py &* 668265263) >> 13 & 255)
                let 噪 = (n - 127) * 颗 * 0.45
                r += 噪; g += 噪; b += 噪
            }

            源[i] = UInt8(max(0, min(255, r)))
            源[i + 1] = UInt8(max(0, min(255, g)))
            源[i + 2] = UInt8(max(0, min(255, b)))
        }

        if p.清晰度 > 0 { 反锐化(&源, w, h, 12, p.清晰度 * 0.9) }
        if p.纹理 > 0 { 反锐化(&源, w, h, 4, p.纹理 * 0.8) }
        if p.锐化 > 0 { 反锐化(&源, w, h, 1, p.锐化 * 0.7) }

        let 数据 = Data(源)
        guard let 提供 = CGDataProvider(data: 数据 as CFData) else { return 图 }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: 提供, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

// MARK: - 消除（照网页版那套：从外圈一层层往里推颜色）

extension 修图 {

    /// 掩码 = 每个像素要不要擦（true = 擦）
    static func 平滑填补(_ cg: CGImage, _ 掩: [Bool], _ 圈数上限: Int = 0) -> CGImage? {
        let w = cg.width, h = cg.height
        var 源 = [UInt8](repeating: 0, count: w * h * 4)
        guard let 上下文 = CGContext(data: &源, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return cg }
        上下文.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        var 已 = [Bool](repeating: false, count: w * h)
        var 待: [Int] = []
        待.reserveCapacity(w * h / 8)
        for i in 0..<(w * h) {
            if 掩[i] { 待.append(i) } else { 已[i] = true }
        }
        if 待.isEmpty { return cg }

        var 圈 = 0
        let 上限 = 圈数上限 > 0 ? 圈数上限 : (w + h)
        while !待.isEmpty && 圈 < 上限 {
            圈 += 1
            var 下一: [Int] = []
            var 结果: [(Int, Double, Double, Double)] = []
            结果.reserveCapacity(待.count)
            for p in 待 {
                let px = p % w, py = p / w
                var r = 0.0, g = 0.0, b = 0.0, n = 0.0
                for dy in -1...1 {
                    for dx in -1...1 {
                        if dx == 0 && dy == 0 { continue }
                        let nx = px + dx, ny = py + dy
                        if nx < 0 || ny < 0 || nx >= w || ny >= h { continue }
                        let np = ny * w + nx
                        if !已[np] { continue }
                        let 权 = (dx != 0 && dy != 0) ? 0.7071 : 1.0
                        let i = np * 4
                        r += Double(源[i]) * 权
                        g += Double(源[i + 1]) * 权
                        b += Double(源[i + 2]) * 权
                        n += 权
                    }
                }
                if n > 0 { 结果.append((p, r / n, g / n, b / n)) } else { 下一.append(p) }
            }
            if 结果.isEmpty { break }
            for (p, r, g, b) in 结果 {
                let i = p * 4
                源[i] = UInt8(max(0, min(255, r)))
                源[i + 1] = UInt8(max(0, min(255, g)))
                源[i + 2] = UInt8(max(0, min(255, b)))
                已[p] = true
            }
            待 = 下一
        }

        // 掩码内抹两遍，去接缝
        var 掩真 = [Bool](repeating: false, count: w * h)
        for i in 0..<(w * h) where 掩[i] { 掩真[i] = true }
        for _ in 0..<2 {
            var 拷贝 = 源
            for p in 0..<(w * h) where 掩真[p] {
                let px = p % w, py = p / w
                var r = 0, g = 0, b = 0, n = 0
                for dy in -1...1 {
                    for dx in -1...1 {
                        let nx = px + dx, ny = py + dy
                        if nx < 0 || ny < 0 || nx >= w || ny >= h { continue }
                        let i = (ny * w + nx) * 4
                        r += Int(拷贝[i]); g += Int(拷贝[i + 1]); b += Int(拷贝[i + 2]); n += 1
                    }
                }
                let i = p * 4
                源[i] = UInt8(r / n); 源[i + 1] = UInt8(g / n); 源[i + 2] = UInt8(b / n)
            }
        }

        let 数据 = Data(源)
        guard let 提供 = CGDataProvider(data: 数据 as CFData) else { return cg }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: 提供, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

// MARK: - 高质量 JPEG（先 q=1.0，超上限才往下退）

extension 修图 {
    static func 编码JPEG(_ cg: CGImage, 质量: Double) -> Data? {
        let 数据 = NSMutableData()
        guard let 目 = CGImageDestinationCreateWithData(数据, "public.jpeg" as CFString, 1, nil) else { return nil }
        let 选项: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 质量]
        CGImageDestinationAddImage(目, cg, 选项 as CFDictionary)
        guard CGImageDestinationFinalize(目) else { return nil }
        return 数据 as Data
    }

    /// 尽量保住画质：从 1.0 开始，只在上限内往下退
    static func 存最好(_ cg: CGImage, 到 出: URL, 上限字节: Int) -> Int? {
        var 质 = 1.0
        while 质 >= 0.50 {
            if let d = 编码JPEG(cg, 质量: 质) {
                if d.count <= 上限字节 {
                    try? d.write(to: 出, options: .atomic)
                    return d.count
                }
            }
            质 -= 0.05
        }
        if let d = 编码JPEG(cg, 质量: 0.50) {
            try? d.write(to: 出, options: .atomic)
            return d.count
        }
        return nil
    }

    /// 放大（Lanczos）+ 轻锐化。
    /// 抖音图文给的就是它转码后的那一档（比如 1023×1537），作者原图不公开，
    /// 所以「更高画质」只能靠重建：这里用 Core Image 的 Lanczos 重采样 + 一点 USM，
    /// 插画放大后边缘会干净不少，但这是插值出来的，不等于原图。
    static func 放大(_ cg: CGImage, 倍: CGFloat, 锐化: Bool = true) -> CGImage? {
        guard 倍 > 1.01 else { return cg }
        let 入 = CIImage(cgImage: cg)
        let 缩 = CIFilter.lanczosScaleTransform()
        缩.inputImage = 入
        缩.scale = Float(倍)
        缩.aspectRatio = 1
        guard var 图 = 缩.outputImage else { return nil }
        if 锐化 {
            let 锐 = CIFilter.unsharpMask()
            锐.inputImage = 图
            锐.radius = 1.6
            锐.intensity = 0.45
            if let 出 = 锐.outputImage { 图 = 出 }
        }
        let 场 = CIContext(options: [.useSoftwareRenderer: false])
        return 场.createCGImage(图, from: 图.extent)
    }

    /// 编码成 HEIF（同画质比 JPEG 小一半左右；相册和「照片」都认）
    static func 编码HEIF(_ cg: CGImage, 质量: CGFloat = 0.80) -> Data? {
        let 桶 = NSMutableData()
        guard let 出 = CGImageDestinationCreateWithData(
            桶, UTType.heic.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(出, cg,
            [kCGImageDestinationLossyCompressionQuality: 质量] as CFDictionary)
        guard CGImageDestinationFinalize(出) else { return nil }
        return 桶 as Data
    }
}

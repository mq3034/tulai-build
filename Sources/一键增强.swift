import Foundation
import UIKit
import CoreGraphics

/// 「一键增强」公共入口：给任何流程（相册选图、批量、去水印）复用同一条增强链。
///
/// 为什么单独抽一层：
///   现在 `超分.跑` / `超分.跑人脸` 只被 `去水印页` 调用，客户从相册选自己的照片
///   根本走不到 AI 增强。把顺序、倍率、调色、方向处理收在一个函数里，UI 侧只要
///   一行调用，商业版接新入口时不用重复实现这些坑。
///
/// 固定顺序（换顺序会直接掉画质）：
///   ① 归正 EXIF 方向（相册照片经常带方向，不归正会拍竖变横）
///   ② 有脸 → 人脸链（RealESRGAN 打底 + GFPGAN 逐张修）；没脸 → 纯 4×；没模型 → 插值 2×
///   ③ 轻度调色（补 GFPGAN 的平滑感）
///
/// 内存约束：真实相机照动辄 12 MP，4× 后是 192 MP（约 768 MB RGB 缓冲），
/// 所以**倍率不由这里硬编码**，交给 `人脸增强.定倍率` / `超分` 内部的像素上限决定。
enum 一键增强 {

    /// 处理入口。同步执行，调用方放到后台线程。
    /// - Parameters:
    ///   - 图: 原始图（相册或下载得到）
    ///   - 修脸: 是否尝试人脸修复（没有模型或没检测到脸时自动退化为纯放大）
    ///   - 进度: 0~1 进度回调（在后台线程调用）
    /// - Returns: 处理后的图；失败返回 nil
    static func 处理(_ 图: UIImage,
                    修脸: Bool = true,
                    进度: ((Double) -> Void)? = nil) -> UIImage? {
        guard let 正 = 归正方向(图), let cg = 正.cgImage else { return nil }

        var 放大图: CGImage?
        if 修脸, 超分.有人脸增强() {
            放大图 = 超分.跑人脸(cg, 进度: 进度)
        } else if 超分.有模型() {
            放大图 = 超分.跑(cg, 进度: 进度)
        } else {
            // 模型没打进包时的兜底：插值 2×，保证「点了有变化」，不做假承诺
            放大图 = 修图.放大(cg, 倍: 2)
        }
        guard let 放大 = 放大图 else { return nil }

        // 调色只调观感，失败就用原图，绝不让整条链失败
        let 成品 = 调色.轻修(放大) ?? 放大
        return UIImage(cgImage: 成品)
    }

    // MARK: - 自检（不依赖相册/不依赖真脸）

    /// 跑一遍整条 AI 超清链路，用合成图检查"有没有崩、倍率对不对、有没有被 GFPGAN 糊掉"。
    ///
    /// 为什么需要：用户 2026-11-15 反馈"AI 超清把脸糊成白条"，
    /// 而自签名安装拿不到崩溃/异常日志 —— 只能靠这种在线自检快速定位。
    /// 合成图里**没有脸**，所以同时验证了"判不出真脸就跳过 GFPGAN"这条兜底。
    static func 自检() -> String {
        var 行: [String] = []
        guard let 原 = 造测试图(边: 240) else { return "✗ 造测试图失败" }
        let 图 = UIImage(cgImage: 原)

        let t0 = Date()
        guard let 出 = 处理(图) else { return "✗ 处理返回 nil（模型/链路有问题）" }
        let 秒 = Date().timeIntervalSince(t0)
        guard let 出cg = 出.cgImage else { return "✗ 输出没有 cgImage" }

        let 倍 = Double(出cg.width) / Double(原.width)
        行.append(String(format: "① 输出尺寸 %.0f×%.0f（倍率 %.2f）", Double(出cg.width), Double(出cg.height), 倍))
        行.append(倍 >= 1.0 ? "② 倍率正常 ✔" : "② 倍率异常 ✗")

        // 和纯插值的结果比：GFPGAN 若在瞎编，差异会很大
        if let 参考 = 修图.放大(原, 倍: CGFloat(max(1, 倍.rounded()))), 参考.width == 出cg.width {
            let 差 = 均差(参考, 出cg)
            行.append(String(format: "③ 与纯插值差异 %.1f/255 %@", 差,
                            (差 < 26 ? "✔（没被乱修）" : "✗（模型在乱改）")))
        } else {
            行.append("③ 参考图生成失败（跳过对比）")
        }
        行.append(String(format: "④ 耗时 %.2f 秒", 秒))
        行.append("⑤ 真脸判定：" + (人脸增强.像真脸公开(原) ? "判定为真脸（会过 GFPGAN）" : "非真脸 → 跳过 GFPGAN ✔"))
        return 行.joined(separator: "\n")
    }

    /// 60×60 缩略后求平均绝对差（0~255）
    private static func 均差(_ a: CGImage, _ b: CGImage) -> Double {
        let n = 60
        var 甲 = [UInt8](repeating: 0, count: n * n * 4)
        var 乙 = [UInt8](repeating: 0, count: n * n * 4)
        func 画(_ 图: CGImage, _ 到: inout [UInt8]) {
            到.withUnsafeMutableBytes { raw in
                guard let 布 = CGContext(data: raw.baseAddress, width: n, height: n,
                                        bitsPerComponent: 8, bytesPerRow: n * 4,
                                        space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
                布.interpolationQuality = .low
                布.draw(图, in: CGRect(x: 0, y: 0, width: n, height: n))
            }
        }
        画(a, &甲); 画(b, &乙)
        var 和 = 0.0
        for i in stride(from: 0, to: n * n * 4, by: 4) {
            for c in 0..<3 { 和 += Double(abs(Int(甲[i+c]) - Int(乙[i+c]))) }
        }
        return 和 / Double(n * n * 3)
    }

    /// 造一张有渐变 + 圆 + 直线的测试图（刻意不含人脸）
    static func 造测试图(边: Int) -> CGImage? {
        guard let 布 = CGContext(data: nil, width: 边, height: 边, bitsPerComponent: 8,
                                bytesPerRow: 边 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let 空 = CGColorSpaceCreateDeviceRGB()
        if let 渐 = CGGradient(colorsSpace: 空,
                              colors: [CGColor(red: 0.1, green: 0.2, blue: 0.4, alpha: 1),
                                       CGColor(red: 0.9, green: 0.7, blue: 0.4, alpha: 1)] as CFArray,
                              locations: [0, 1]) {
            布.drawLinearGradient(渐, start: .zero, end: CGPoint(x: 边, y: 边), options: [])
        }
        布.setFillColor(CGColor(red: 0.95, green: 0.4, blue: 0.3, alpha: 1))
        布.fillEllipse(in: CGRect(x: 边/4, y: 边/4, width: 边/2, height: 边/2))
        布.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        布.setLineWidth(3)
        布.move(to: CGPoint(x: 0, y: 边/2)); 布.addLine(to: CGPoint(x: 边, y: 边/2)); 布.strokePath()
        return 布.makeImage()
    }

    /// 把 UIKit 方向烘进像素。
    ///
    /// 相册取回的 `UIImage` 常带 `.right` / `.left` 等方向标记，`cgImage` 拿到的
    /// 是**未旋转**的像素；直接送模型会得到横竖颠倒的结果。
    /// - Parameter 图: 任意方向的图
    /// - Returns: 方向已归正（`.up`）的图；已是 `.up` 时原样返回，不做无谓重绘
    static func 归正方向(_ 图: UIImage) -> UIImage? {
        if 图.imageOrientation == .up { return 图 }
        let 格式 = UIGraphicsImageRendererFormat.default()
        格式.scale = 1
        格式.opaque = false
        let 渲染 = UIGraphicsImageRenderer(size: 图.size, format: 格式)
        return 渲染.image { _ in
            图.draw(in: CGRect(origin: .zero, size: 图.size))
        }
    }

    // MARK: - 三档导出（归档 / 屏幕 / 放大）

    /// 归档版 JPEG 质量。
    ///
    /// 2026-11-15 实测：19MP 只给 4.17MB（222 KB/MP）时，放大 400% 会看到 8×8 方块。
    /// 提到 0.98 后体积约翻倍，但块度明显下降——**块是压缩造成的，不是分辨率不够**。
    static let 归档质量: CGFloat = 0.98

    /// 屏幕版的目标宽度。
    ///
    /// 为什么是 2160：
    ///   主流手机屏幕 1179~1290 宽，2160 已经是 1.7~1.8 倍，够锐且不过剩。
    ///   实测：把 4× 结果降到 2160 再缩到屏幕尺寸，锐度和 308MP 直缩差 <2%，
    ///   逐像素差 1/255 —— 肉眼无差别，但文件从 28.6MB 降到约 1MB。
    static let 屏幕版宽 = 2160

    /// 高清放大版的宽度。
    ///
    /// 解决的是「放大看有方块」而不是「细节不够」：
    ///   归档版 3584~4312 宽，手机放到最大时会被拉伸 1.5 倍以上 → 露出 JPEG 块。
    ///   先把画布做大到 7168（远超任何手机的最大放大），再让屏幕自己缩，
    ///   观感就和 308MP 那张一样干净，体积只有它的 1/3。
    ///   代价：约 77MP，内存峰值 ~300MB，只在用户主动勾选时才做。
    static let 放大版宽 = 7168

    /// 生成屏幕版：等比缩到 `屏幕版宽` 以内。
    ///
    /// 只做缩放，**不做降噪**。实测对 4× 结果做中值滤波会把锐度从 407 打到 207，
    /// 得不偿失 —— 缩小本身已经起到平均降噪的作用。
    static func 屏幕版(_ cg: CGImage) -> CGImage? {
        等比缩(cg, 到宽: 屏幕版宽)
    }

    /// 生成高清放大版：等比放大到 `放大版宽`。
    ///
    /// 用的是**高质量插值**（CGContext 的 .high，等价于 Lanczos 级），不是 AI。
    /// 目的不是造细节，而是把 JPEG 方块"摊平"——这正是 308MP 那张看着干净的原因。
    static func 高清放大版(_ cg: CGImage) -> CGImage? {
        guard cg.width < 放大版宽 else { return cg }
        return 等比缩(cg, 到宽: 放大版宽)
    }

    /// 等比缩放（放大或缩小都用它）。
    private static func 等比缩(_ cg: CGImage, 到宽 目标宽: Int) -> CGImage? {
        guard 目标宽 > 0, cg.width != 目标宽 else { return cg }
        let 高 = max(1, Int((Double(cg.height) * Double(目标宽) / Double(cg.width)).rounded()))
        guard let 布 = CGContext(data: nil, width: 目标宽, height: 高,
                                bitsPerComponent: 8, bytesPerRow: 目标宽 * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        布.interpolationQuality = .high
        布.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        布.fill(CGRect(x: 0, y: 0, width: 目标宽, height: 高))
        布.draw(cg, in: CGRect(x: 0, y: 0, width: 目标宽, height: 高))
        return 布.makeImage()
    }
}

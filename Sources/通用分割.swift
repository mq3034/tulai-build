import Foundation
import Vision
import CoreVideo
import CoreGraphics
import UIKit

/// 通用主体分割（不靠外部模型，用系统自带的「显著物体」检测）。
///
/// 为什么不用 u2netp：
///   试过把 u2netp.onnx（4.4MB）转 Core ML，**coremltools 9.0 已经删掉 ONNX 前端**
///   （只接受 tensorflow / pytorch / milinternal）。要转就得退回 Python 3.9 +
///   coremltools 5.x，或者用 PyTorch 重写 U2Net 再 trace —— 都不划算。
///
/// 为什么这个方案更好：
///   Vision 自带两类显著性请求，**不占包体、不用下载、iOS 13+ 就能用**：
///     · `VNGenerateObjectnessBasedSaliencyImageRequest` —— 找"像物体"的区域，前景物体/角色
///     · `VNGenerateAttentionBasedSaliencyImageRequest` —— 找"人眼会看"的区域
///   把两者相乘（都得高分才算主体）比单用一个稳，也能压掉"高对比背景"的误检。
///
/// 局限（必须知道）：
///   显著性不是精确分割，边界比 U2Net 粗。对"主体和背景对比明确"的图够用；
///   主体和背景颜色接近时会漏。所以它只是**兜底**：先用 Vision 人像分割（准），
///   分不到人才走这里。
enum 通用分割 {

    /// 是否可用。
    ///
    /// ⚠️ 这里**不能**用"拿一张黑图跑一遍看能不能成功"来判断：
    ///    纯黑图没有显著物体，Vision 的显著性请求会返回空结果 →
    ///    可用() 被永久缓存成 false → 通用分割在整台设备上再也不会启用。
    ///    （这是 2026-11-15 审代码时发现的坑：一次探测失败会把功能永久关掉。）
    ///
    /// 显著性 API 从 iOS 13 开始就有，本工程 deploymentTarget 是 16，必然存在，
    /// 所以直接返回 true；真跑失败由 `跑()` 返回 nil，调用方照样会退回人像分割。
    static func 可用() -> Bool {
        true
    }

    /// 返回与输入同尺寸的主体概率图（0~1）。同步执行，调用方放后台线程。
    static func 跑(_ cg: CGImage) -> [Float]? {
        let 宽 = cg.width, 高 = cg.height
        guard 宽 > 0, 高 > 0 else { return nil }

        let 物体请求 = VNGenerateObjectnessBasedSaliencyImageRequest()
        let 注意请求 = VNGenerateAttentionBasedSaliencyImageRequest()
        let 处理 = VNImageRequestHandler(cgImage: cg, options: [:])
        guard (try? 处理.perform([物体请求, 注意请求])) != nil else { return nil }

        let 物体图 = 读显著图(物体请求.results?.first as? VNSaliencyImageObservation)
        let 注意图 = 读显著图(注意请求.results?.first as? VNSaliencyImageObservation)

        // 取最大的一处显著区域做二次加权：避免"整张图都稍微显著"导致 mask 过大
        let 框 = (物体请求.results?.first as? VNSaliencyImageObservation)?.salientObjects?.max(by: {
            $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height
        })?.boundingBox

        var 出 = [Float](repeating: 0, count: 宽 * 高)
        for y in 0..<高 {
            let v = Float(y) / Float(max(1, 高 - 1))
            for x in 0..<宽 {
                let u = Float(x) / Float(max(1, 宽 - 1))
                let a = 采样(物体图, u, v) ?? 0
                let b = 采样(注意图, u, v) ?? 0
                var 值 = a * (0.65 + 0.35 * b)      // 物体为主，注意力做加权

                // 只看最大显著框内（外扩 15%）：压掉零散误检
                if let 框 {
                    let 扩: CGFloat = 0.15
                    let 内 = CGRect(x: 框.minX - 框.width * 扩,
                                   y: 框.minY - 框.height * 扩,
                                   width: 框.width * (1 + 2 * 扩),
                                   height: 框.height * (1 + 2 * 扩))
                    // Vision 的 y 轴原点在左下，这里翻转
                    let 点 = CGPoint(x: CGFloat(u), y: 1 - CGFloat(v))
                    if !内.contains(点) { 值 *= 0.25 }
                }
                出[y * 宽 + x] = min(1, max(0, 值))
            }
        }

        // 【归一化】显著性图整体偏小且稀疏（峰值常常只有 0.2~0.4），
        //   如果直接拿原值当遮罩，`推脸.有人像` 要求"覆盖 1% 且权重 > 0.5"
        //   会永远不满足 → 背景保护被静默禁用。
        //   所以这里把峰值拉到 1，再做一次 gamma 提升，让 mask 真的可用。
        //   （2026-11-15 审代码发现；不归一化的话"能不能推"取决于模型的绝对分值，很脆。）
        var 峰: Float = 0
        for v in 出 where v > 峰 { 峰 = v }
        if 峰 > 0.0001 {
            let k = 1 / 峰
            for i in 出.indices {
                let 归一 = min(1, max(0, 出[i] * k))
                出[i] = pow(归一, 0.65)     // 0.65 次幂：抬中间、压两侧
            }
        }

        // 【内芯饱和】显著性图是"软"的：主体中心可能只有 0.5~0.7。
        //   推脸的位移会乘遮罩、合成时又按遮罩混合 —— 两层衰减叠加后
        //   实际位移只剩三成，表现就是"人物推不动"（2026-11-15 真机反馈）。
        //   这里做一次平滑阶跃：> 0.55 判为主体（饱和到 1），< 0.15 判为背景（压到 0），
        //   中间线性过渡，保证"主体内部位移足额、边界仍然平滑"。
        for i in 出.indices {
            let v = 出[i]
            if v >= 0.55 {
                出[i] = 1
            } else if v <= 0.15 {
                出[i] = 0
            } else {
                出[i] = (v - 0.15) / 0.40
            }
        }
        return 出
    }

    // MARK: - 显著图读取

    /// 把 VNSaliencyImageObservation 的像素缓冲读成 [Float]（0~1），统一按"左下原点"存，
    /// 采样时用归一化坐标，避免和 CGImage 的坐标方向搞混。
    private static func 读显著图(_ 观: VNSaliencyImageObservation?) -> (宽: Int, 高: Int, 数据: [Float])? {
        guard let 观 else { return nil }
        let pb = 观.pixelBuffer
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        guard w > 0, h > 0, let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let 行 = CVPixelBufferGetBytesPerRow(pb)
        let 格式 = CVPixelBufferGetPixelFormatType(pb)
        var 数据 = [Float](repeating: 0, count: w * h)

        if 格式 == kCVPixelFormatType_OneComponent32Float {
            for y in 0..<h {
                let 行首 = base.advanced(by: y * 行).assumingMemoryBound(to: Float.self)
                for x in 0..<w { 数据[y * w + x] = 行首[x] }
            }
        } else {
            // 兜底：当 8-bit 处理
            for y in 0..<h {
                let 行首 = base.advanced(by: y * 行).assumingMemoryBound(to: UInt8.self)
                for x in 0..<w { 数据[y * w + x] = Float(行首[x]) / 255 }
            }
        }
        return (w, h, 数据)
    }

    /// 归一化坐标双线性采样（v 以左下为原点）
    private static func 采样(_ 图: (宽: Int, 高: Int, 数据: [Float])?, _ u: Float, _ v: Float) -> Float? {
        guard let 图, 图.宽 > 0, 图.高 > 0 else { return nil }
        let fx = min(max(u, 0), 1) * Float(图.宽 - 1)
        let fy = min(max(v, 0), 1) * Float(图.高 - 1)
        let x0 = Int(fx), y0 = Int(fy)
        let x1 = min(x0 + 1, 图.宽 - 1), y1 = min(y0 + 1, 图.高 - 1)
        let dx = fx - Float(x0), dy = fy - Float(y0)
        let a = 图.数据[y0 * 图.宽 + x0] * (1 - dx) + 图.数据[y0 * 图.宽 + x1] * dx
        let b = 图.数据[y1 * 图.宽 + x0] * (1 - dx) + 图.数据[y1 * 图.宽 + x1] * dx
        return a * (1 - dy) + b * dy
    }
}

import Foundation
import Metal
import CoreGraphics
import UIKit

// ============================================================
//  推脸分层合成 —— Metal 实现（2026-11-16）
//
//  为什么上 Metal：
//    1200 长边（900×1200）纯 CPU 每帧约 92ms（≈11fps），拖动明显发涩。
//    同一套数学搬到 GPU 后是 1~3ms（60fps 封顶），手感才跟得上醒图。
//
//  数学与 CPU 版 `推脸.渲染` 完全一致（见 推脸着色.metal）：
//     s = clamp(p - D);  a = 遮罩[s];  out = 人[s]*a + 背景[p]*(1-a)
//
//  关键实现注意（都是踩过的坑，别改）：
//    1. iOS 的 MTLTexture 只能用 .shared / .private；**不能用 .managed**（那是 macOS）。
//    2. 纹理用 .rgba8Unorm 而不是 .bgra8Unorm —— 我们读出来的像素是 RGBA 顺序，
//       用 bgra 会红蓝互换。
//    3. **绝对不能**把局部数组的裸指针交给 CGContext/CGImage（那会悬垂 → 闪退）。
//       这里用 CGDataProvider(CFData)，CGImage 会自己持有数据。
// ============================================================

final class 推脸渲染器 {

    // 分层合成的着色器源码（运行时编译，见 init 里的说明）
    static let 着色源码 = """
    #include <metal_stdlib>
    using namespace metal;

    struct 顶点输出 { float4 位置 [[position]]; float2 uv; };

    vertex 顶点输出 推脸顶点(uint 序号 [[vertex_id]]) {
        float2 角[4] = { float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,1) };
        float2 纹[4] = { float2(0,1), float2(1,1), float2(0,0), float2(1,0) };
        顶点输出 出;
        出.位置 = float4(角[序号], 0.0, 1.0);
        出.uv = 纹[序号];
        return 出;
    }

    fragment float4 推脸片元(顶点输出 入 [[stage_in]],
                            texture2d<float, access::sample> 人 [[texture(0)]],
                            texture2d<float, access::sample> 背景 [[texture(1)]],
                            texture2d<float, access::sample> 遮罩 [[texture(2)]],
                            texture2d<float, access::sample> 位移 [[texture(3)]]) {
        constexpr sampler 采(coord::normalized, filter::linear,
                            mip_filter::none, address::clamp_to_edge);
        float2 位 = 位移.sample(采, 入.uv).rg;
        float2 源点 = clamp(入.uv - 位, float2(0.0), float2(1.0));
        float a = 遮罩.sample(采, 源点).r;
        float4 人色 = 人.sample(采, 源点);
        float4 背色 = 背景.sample(采, 入.uv);
        float4 出 = mix(背色, 人色, a);
        出.a = 1.0;
        return 出;
    }
    """

    static let 共享 = 推脸渲染器()

    private let 设备: MTLDevice
    private let 队列: MTLCommandQueue
    private let 管线: MTLRenderPipelineState

    // 按尺寸缓存纹理：拖动时每帧复用，不重建（重建会掉帧）
    private var 人纹理: MTLTexture?
    private var 背纹理: MTLTexture?
    private var 掩纹理: MTLTexture?
    private var 位纹理: MTLTexture?
    private var 出纹理: MTLTexture?
    private var 缓存宽 = 0
    private var 缓存高 = 0

    /// 记录最近一帧耗时（毫秒），给诊断/状态栏用
    private(set) var 最近毫秒: Double = 0

    private init?() {
        guard let 设备 = MTLCreateSystemDefaultDevice(),
              let 队列 = 设备.makeCommandQueue() else { return nil }
        self.设备 = 设备
        self.队列 = 队列

        // ⚠️ 为什么用「运行时编译」而不是工程里的 .metal 文件：
        //   2026-11-16 实测 Codemagic 的 Xcode 没装 Metal Toolchain，
        //   编译 .metal 会直接报 `cannot execute tool 'metal'` 把整个构建打挂。
        //   iOS 支持 device.makeLibrary(source:) 在运行时编译 MSL —— 多花约 50ms 启动，
        //   但换掉一个"构建环境依赖"，值得。
        guard let 库 = try? 设备.makeLibrary(source: 推脸渲染器.着色源码, options: nil),
              let 顶点 = 库.makeFunction(name: "推脸顶点"),
              let 片元 = 库.makeFunction(name: "推脸片元") else { return nil }

        let 描述 = MTLRenderPipelineDescriptor()
        描述.vertexFunction = 顶点
        描述.fragmentFunction = 片元
        描述.colorAttachments[0].pixelFormat = .rgba8Unorm

        guard let 管线 = try? 设备.makeRenderPipelineState(descriptor: 描述) else { return nil }
        self.管线 = 管线
    }

    /// 合成一帧：全部输入都是已经缩到 宽×高 的像素数据（RGBA8 / Float）。
    func 合成(人: [UInt8], 背景: [UInt8], 遮罩: [Float],
             dx: [Float], dy: [Float], 宽: Int, 高: Int) -> CGImage? {
        let 像素数 = 宽 * 高
        guard 宽 > 0, 高 > 0,
              人.count >= 像素数 * 4, 背景.count >= 像素数 * 4,
              遮罩.count >= 像素数, dx.count >= 像素数, dy.count >= 像素数 else { return nil }
        guard 准备纹理(宽: 宽, 高: 高),
              let 人纹理, let 背纹理, let 掩纹理, let 位纹理, let 出纹理 else { return nil }

        let t0 = CACurrentMediaTime()

        // ---- 上传（RGBA8）----
        人.withUnsafeBytes { raw in
            人纹理.replace(region: MTLRegionMake2D(0, 0, 宽, 高), mipmapLevel: 0,
                         withBytes: raw.baseAddress!, bytesPerRow: 宽 * 4)
        }
        背景.withUnsafeBytes { raw in
            背纹理.replace(region: MTLRegionMake2D(0, 0, 宽, 高), mipmapLevel: 0,
                         withBytes: raw.baseAddress!, bytesPerRow: 宽 * 4)
        }
        遮罩.withUnsafeBytes { raw in
            掩纹理.replace(region: MTLRegionMake2D(0, 0, 宽, 高), mipmapLevel: 0,
                         withBytes: raw.baseAddress!, bytesPerRow: 宽 * 4)
        }

        // ---- 位移归一化上传（RG32Float）----
        var 位 = [Float](repeating: 0, count: 像素数 * 2)
        let 倒数宽 = 1.0 / Float(宽), 倒数高 = 1.0 / Float(高)
        for i in 0..<像素数 {
            位[i * 2] = dx[i] * 倒数宽
            位[i * 2 + 1] = dy[i] * 倒数高
        }
        位.withUnsafeBytes { raw in
            位纹理.replace(region: MTLRegionMake2D(0, 0, 宽, 高), mipmapLevel: 0,
                         withBytes: raw.baseAddress!, bytesPerRow: 宽 * 8)
        }

        // ---- 渲染 ----
        let 通道 = MTLRenderPassDescriptor()
        通道.colorAttachments[0].texture = 出纹理
        通道.colorAttachments[0].loadAction = .dontCare
        通道.colorAttachments[0].storeAction = .store

        guard let 命令 = 队列.makeCommandBuffer(),
              let 编码 = 命令.makeRenderCommandEncoder(descriptor: 通道) else { return nil }
        编码.setRenderPipelineState(管线)
        编码.setFragmentTexture(人纹理, index: 0)
        编码.setFragmentTexture(背纹理, index: 1)
        编码.setFragmentTexture(掩纹理, index: 2)
        编码.setFragmentTexture(位纹理, index: 3)
        编码.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        编码.endEncoding()
        命令.commit()
        命令.waitUntilCompleted()

        // ---- 读回 ----
        var 像素 = [UInt8](repeating: 0, count: 像素数 * 4)
        像素.withUnsafeMutableBytes { raw in
            出纹理.getBytes(raw.baseAddress!, bytesPerRow: 宽 * 4,
                          from: MTLRegionMake2D(0, 0, 宽, 高), mipmapLevel: 0)
        }
        最近毫秒 = (CACurrentMediaTime() - t0) * 1000
        return 像素转CGImage(像素, 宽: 宽, 高: 高)
    }

    // MARK: - 内部

    private func 准备纹理(宽: Int, 高: Int) -> Bool {
        if 缓存宽 == 宽, 缓存高 == 高, 出纹理 != nil { return true }

        func 造(_ 格式: MTLPixelFormat, _ 用途: MTLTextureUsage) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: 格式, width: 宽, height: 高,
                                                            mipmapped: false)
            d.usage = 用途
            d.storageMode = .shared          // iOS 只有 shared / private
            return 设备.makeTexture(descriptor: d)
        }

        人纹理 = 造(.rgba8Unorm, .shaderRead)
        背纹理 = 造(.rgba8Unorm, .shaderRead)
        掩纹理 = 造(.r32Float, .shaderRead)
        位纹理 = 造(.rg32Float, .shaderRead)
        出纹理 = 造(.rgba8Unorm, [.renderTarget, .shaderRead])
        缓存宽 = 宽; 缓存高 = 高
        return 人纹理 != nil && 背纹理 != nil && 掩纹理 != nil && 位纹理 != nil && 出纹理 != nil
    }

    /// RGBA8 字节 → CGImage。
    /// 用 CGDataProvider 而不是 CGContext(data:)：后者不拷贝，数组一释放就是悬垂指针。
    private func 像素转CGImage(_ 像素: [UInt8], 宽: Int, 高: Int) -> CGImage? {
        guard let 空间 = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        guard let 提供 = CGDataProvider(data: Data(像素) as CFData) else { return nil }
        let 信息 = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue
                                | CGBitmapInfo.byteOrder32Big.rawValue)
        return CGImage(width: 宽, height: 高,
                       bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 宽 * 4,
                       space: 空间, bitmapInfo: 信息, provider: 提供,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

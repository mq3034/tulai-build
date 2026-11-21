import SwiftUI
import Photos
import UIKit

/// AI 超清的结果对比页：左「修复前」/ 右「修复后」，可拖动分割线，可调强度，最后保存。
///
/// 为什么要这一页（用户 2026-11-15 明确要求，对标竞品）：
///   · 直接存相册，用户看不到"修复了什么"，也不敢确认效果
///   · 强度可调，是因为超清有时会把皮肤/头发处理得太"硬"，用户要能往回退一点
///   · 保存放右上角，和竞品一致，肌肉记忆不用重新学
struct 对比页: View {
    var 原图: UIImage
    var 结果: UIImage
    var 关闭: () -> Void

    /// 0 = 完全原图，1 = 完全修复后
    @State private var 强度: Double = 1.0
    /// 分割线位置（0~1）
    @State private var 分割: CGFloat = 0.5
    @State private var 保存中 = false
    @State private var 已存 = false
    @State private var 失败说明: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                画布
                    .frame(maxHeight: .infinity)
                    .background(Color.black)

                控制区
            }
            .navigationTitle("画质修复 · AI 超清")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { 关闭() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(已存 ? "已保存" : "保存") { 保存() }
                        .fontWeight(.semibold)
                        .disabled(保存中 || 已存)
                }
            }
            .alert("保存失败", isPresented: Binding(
                get: { 失败说明 != nil },
                set: { if !$0 { 失败说明 = nil } })) {
                Button("知道了") { 失败说明 = nil }
            } message: { Text(失败说明 ?? "") }
        }
    }

    // MARK: - 画布

    private var 画布: some View {
        GeometryReader { 几何 in
            ZStack {
                // 底层：修复后（按强度控制不透明度，0 强度时完全看不到）
                Image(uiImage: 结果)
                    .resizable()
                    .scaledToFit()
                    .opacity(强度)

                // 上层：原图，只显示分割线左边那部分 → 拖动分割线就"揭开"修复后
                Image(uiImage: 原图)
                    .resizable()
                    .scaledToFit()
                    .mask(alignment: .leading) {
                        Rectangle()
                            .frame(width: 几何.size.width * 分割)
                    }

                // 分割线 + 手柄
                分割线(高: 几何.size.height)
                    .position(x: 几何.size.width * 分割, y: 几何.size.height / 2)

                // 标签
                HStack {
                    Text("修复前")
                    Spacer()
                    Text("修复后")
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .frame(maxHeight: .infinity, alignment: .top)

                // 拖动区
                Rectangle()
                    .fill(Color.white.opacity(0.001))
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { 值 in
                                let k = 值.location.x / max(1, 几何.size.width)
                                分割 = min(1, max(0, k))
                            }
                    )
            }
        }
    }

    private func 分割线(高: CGFloat) -> some View {
        ZStack {
            Rectangle().fill(Color.white).frame(width: 2)
            Circle()
                .fill(Color.white)
                .frame(width: 34, height: 34)
                .overlay {
                    Image(systemName: "arrow.left.and.right")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.black)
                }
                .shadow(radius: 4)
        }
        .frame(height: 高)
    }

    // MARK: - 控制区

    private var 控制区: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                Text("强度").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Slider(value: $强度, in: 0...1)
                Text("\(Int(强度 * 100))%")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 42, alignment: .trailing)
            }
            Text("拖中间的圆点左右滑动，可以看修复前后；「强度」调低会让效果更自然")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial)
    }

    // MARK: - 保存

    private func 保存() {
        guard let 合成 = 合成图() else {
            失败说明 = "合成失败"
            return
        }
        保存中 = true
        Task {
            defer { 保存中 = false }
            let 权 = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard 权 == .authorized || 权 == .limited else {
                失败说明 = "没拿到相册权限：设置 → 图来 → 照片 → 添加照片"
                return
            }
            guard let 数据 = 合成.jpegData(compressionQuality: 0.98) else {
                失败说明 = "编码失败"
                return
            }
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    let r = PHAssetCreationRequest.forAsset()
                    let o = PHAssetResourceCreationOptions()
                    o.uniformTypeIdentifier = "public.jpeg"
                    r.addResource(with: .photo, data: 数据, options: o)
                }
                已存 = true
            } catch {
                失败说明 = error.localizedDescription
            }
        }
    }

    /// 按当前强度把原图和结果合成一张（在结果的分辨率上画，避免掉清晰度）
    private func 合成图() -> UIImage? {
        let 尺寸 = 结果.size
        guard 尺寸.width > 1, 尺寸.height > 1 else { return nil }
        let 格式 = UIGraphicsImageRendererFormat.default()
        格式.scale = 1
        格式.opaque = true
        return UIGraphicsImageRenderer(size: 尺寸, format: 格式).image { _ in
            原图.draw(in: CGRect(origin: .zero, size: 尺寸))
            if 强度 > 0.001 {
                结果.draw(in: CGRect(origin: .zero, size: 尺寸),
                       blendMode: .normal, alpha: 强度)
            }
        }
    }
}

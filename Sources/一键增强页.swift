import SwiftUI
import PhotosUI
import Photos
import UIKit

/// 「一键增强」入口格子。
///
/// 为什么长这样：
///   宿主的 `功能格` 是 `private func`，外部结构体调不到它。
///   为了和旁边的格子**像素级对齐**（圆角 16、高 56、spacing 6、caption2），
///   这里把同样的结构复制一份，配色由调用方传入。
///   代价是以后 `功能格` 样式改了这个文件要跟着改——但换来的是宿主只加一行。
///
/// 为什么自带选图：
///   宿主的相册流程（`相册2` → `批量引擎` → `处理器`）是给「白底/白边」出图用的，
///   那条链里没有 AI 放大也没有人脸修复。要在不碰那 3000 行的情况下把增强接进来，
///   最省事、最不容易编坏的办法是：**这个文件自己选图、自己处理、自己存相册**。
///
/// 行为：
///   选图（可多选）→ 逐张「RealESRGAN 打底 + GFPGAN 修脸 + 轻度调色」→ 直接存相册
struct 一键增强格: View {
    var 底色: Color
    var 字色: Color
    @State private var 开 = false

    var body: some View {
        Button { 开 = true } label: {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(底色.opacity(0.25))
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(字色)
                }
                .frame(height: 56)
                Text("AI 超清")
                    .font(.caption2)
                    .foregroundStyle(字色)
            }
        }
        .buttonStyle(.plain)
        .disabled(!超分.有模型() && !超分.有人脸增强())
        .sheet(isPresented: $开) {
            一键增强页 { 开 = false }
        }
    }
}

/// 增强页本体：选图 → 处理 → 存相册。
struct 一键增强页: View {
    var 关闭: () -> Void

    @State private var 选 = false
    @State private var 跑着 = false
    @State private var 已停 = false
    @State private var 总数 = 0
    @State private var 完成数 = 0
    @State private var 存好数 = 0
    /// 三档导出（可多选，测试用，默认只开归档+屏幕）
    @State private var 存归档 = true
    @State private var 存屏幕 = true
    @State private var 存放大 = false
    /// 处理完后用来做「对比调节」：原图 + 结果（只留最后一张，够用且省内存）
    @State private var 对比原图: UIImage?
    @State private var 对比结果: UIImage?
    @State private var 显示对比 = false
    @State private var 自检中 = false
    @State private var 自检结果: String?
    @State private var 状态 = "选几张照片，直接出增强版"
    @State private var 失败说明: String?

    private var 进度: Double { 总数 > 0 ? Double(完成数) / Double(总数) : 0 }

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(Color(red: 0.98, green: 0.55, blue: 0.30))
                    .padding(.top, 30)

                Text(状态)
                    .font(.system(size: 15, weight: .medium))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)

                if 总数 > 0 {
                    VStack(spacing: 8) {
                        ProgressView(value: 进度)
                            .tint(Color(red: 0.98, green: 0.55, blue: 0.30))
                        Text("\(完成数)/\(总数)　已存相册 \(存好数) 张")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 30)
                }

                Text("· 每张大约十几秒，图越大越慢\n· 有脸的图会额外修五官（真人效果最好）\n· 处理完直接存进相册，不占 App 空间")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 30)

                VStack(alignment: .leading, spacing: 8) {
                    Text("导出哪些版本")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Toggle(isOn: $存归档) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("归档版 · 4× 原尺寸").font(.system(size: 13, weight: .medium))
                            Text("约 8~10MB，质量 0.98。要裁切、要细节就用它")
                                .font(.system(size: 11)).foregroundStyle(.tertiary)
                        }
                    }
                    Toggle(isOn: $存屏幕) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("屏幕版 · 2160 宽").font(.system(size: 13, weight: .medium))
                            Text("约 1MB。发朋友圈 / 当壁纸，手机上看着和归档版一样")
                                .font(.system(size: 11)).foregroundStyle(.tertiary)
                        }
                    }
                    Toggle(isOn: $存放大) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("高清放大版 · 7168 宽").font(.system(size: 13, weight: .medium))
                            Text("约 12MB。专门解决「放大看有方块」，观感接近 308MP 那张")
                                .font(.system(size: 11)).foregroundStyle(.tertiary)
                        }
                    }
                }
                .tint(Color(red: 0.98, green: 0.55, blue: 0.30))
                .padding(.horizontal, 30)
                .disabled(跑着)

                Spacer()

                VStack(spacing: 10) {
                    if 跑着 {
                        Button("停止（做完当前这张就停）") { 已停 = true }
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.red)
                    } else {
                        Button {
                            选 = true
                        } label: {
                            Text("选照片开始")
                                .font(.system(size: 16, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Color(red: 0.98, green: 0.55, blue: 0.30), in: Capsule())
                                .foregroundStyle(.white)
                        }
                        .padding(.horizontal, 30)
                    }
                }
                .padding(.bottom, 30)
            }
            .navigationTitle("AI 超清")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { 关闭() }.disabled(跑着)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // 自检：不用相册、不用真脸，跑一遍链路看有没有被 GFPGAN 糊掉
                    Button {
                        自检中 = true
                        Task {
                            let 果 = await Task.detached(priority: .userInitiated) {
                                一键增强.自检()
                            }.value
                            自检结果 = 果
                            自检中 = false
                        }
                    } label: {
                        Text(自检中 ? "自检中…" : "自检")
                            .font(.system(size: 13))
                    }
                    .disabled(自检中 || 跑着)
                }
            }
            .sheet(isPresented: $选) {
                一键选图器 { 图们 in
                    选 = false
                    guard !图们.isEmpty else { return }
                    开始(图们)
                } 取消: { 选 = false }
            }
            .fullScreenCover(isPresented: $显示对比) {
                if let 对比原图, let 对比结果 {
                    对比页(原图: 对比原图, 结果: 对比结果) { 显示对比 = false }
                }
            }
            .alert("AI 超清自检", isPresented: Binding(
                get: { 自检结果 != nil },
                set: { if !$0 { 自检结果 = nil } })) {
                Button("知道了") { 自检结果 = nil }
            } message: { Text(自检结果 ?? "") }
            .alert("出错了", isPresented: Binding(
                get: { 失败说明 != nil },
                set: { if !$0 { 失败说明 = nil } })) {
                Button("知道了") { 失败说明 = nil }
            } message: {
                Text(失败说明 ?? "")
            }
        }
    }

    /// 逐张处理：处理完立刻写相册，然后丢掉引用。
    /// 不并发：GFPGAN + RealESRGAN 同时跑几张会把内存打爆（4GB 机型直接被杀）。
    private func 开始(_ 图们: [UIImage]) {
        总数 = 图们.count
        完成数 = 0
        存好数 = 0
        已停 = false
        跑着 = true
        状态 = "正在增强…"
        let 要归档 = 存归档, 要屏幕 = 存屏幕, 要放大 = 存放大

        Task {
            for (i, 图) in 图们.enumerated() {
                if 已停 { break }
                状态 = "第 \(i + 1)/\(图们.count) 张处理中…"

                // 重活放后台线程；`一键增强.处理` 内部已经处理了方向、倍率、调色
                诊断.记("超清：第 \(i + 1) 张开始处理（\(Int(图.size.width))×\(Int(图.size.height))）")
                let 成品 = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                    autoreleasepool { 一键增强.处理(图) }
                }.value
                诊断.记("超清：第 \(i + 1) 张处理完成（\(成品 == nil ? "nil" : "ok")）")

                guard let 成品, let cg = 成品.cgImage else {
                    完成数 = i + 1
                    continue
                }
                // 留一张原图+结果做对比调节（用户要能看着调强度再存）
                对比原图 = 图
                对比结果 = 成品

                // ① 归档版：4× 原尺寸，质量 0.98
                诊断.记("超清：编码归档版")
                if 要归档, let 数据 = 成品.jpegData(compressionQuality: 一键增强.归档质量) {
                    if await 存(数据) { 存好数 += 1 }
                }

                // ② 屏幕版：2160 宽
                if 要屏幕 {
                    let 屏 = await Task.detached(priority: .userInitiated) {
                        一键增强.屏幕版(cg)
                    }.value
                    if let 屏, let 数据 = UIImage(cgImage: 屏).jpegData(compressionQuality: 0.92) {
                        if await 存(数据) { 存好数 += 1 }
                    }
                }

                // ③ 高清放大版：7168 宽（内存峰值约 300MB，所以单独一步、用完即放）
                if 要放大 {
                    let 大 = await Task.detached(priority: .userInitiated) {
                        一键增强.高清放大版(cg)
                    }.value
                    if let 大, let 数据 = UIImage(cgImage: 大).jpegData(compressionQuality: 0.96) {
                        if await 存(数据) { 存好数 += 1 }
                    }
                }

                完成数 = i + 1
            }

            跑着 = false
            状态 = 已停
                ? "已停止：完成 \(完成数) 张，存入相册 \(存好数) 个文件"
                : "完成 \(完成数) 张，已存入相册 \(存好数) 个文件"
            if 对比结果 != nil { 显示对比 = true }
        }
    }

    /// 写一张 JPEG 进相册。失败不打断整体流程，只计数。
    private func 存(_ 数据: Data) async -> Bool {
        let 权 = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard 权 == .authorized || 权 == .limited else {
            失败说明 = "没拿到相册权限：设置 → 图来 → 照片 → 选「添加照片」"
            return false
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let 请求 = PHAssetCreationRequest.forAsset()
                let 选项 = PHAssetResourceCreationOptions()
                选项.uniformTypeIdentifier = "public.jpeg"
                请求.addResource(with: .photo, data: 数据, options: 选项)
            }
            return true
        } catch {
            失败说明 = "存相册失败：\(error.localizedDescription)"
            return false
        }
    }
}

/// 极简多选相册：只取 UIImage，不碰宿主的相册模型。
struct 一键选图器: UIViewControllerRepresentable {
    var 完成: ([UIImage]) -> Void
    var 取消: () -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var 配 = PHPickerConfiguration(photoLibrary: .shared())
        配.filter = .images
        配.selectionLimit = 0        // 0 = 不限张数
        配.preferredAssetRepresentationMode = .current
        let vc = PHPickerViewController(configuration: 配)
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> 协调器 { 协调器(self) }

    final class 协调器: NSObject, PHPickerViewControllerDelegate {
        private let 主: 一键选图器
        init(_ 主: 一键选图器) { self.主 = 主 }

        func picker(_ picker: PHPickerViewController, didFinishPicking 结果们: [PHPickerResult]) {
            // 不要在这里 dismiss：父视图的 sheet 绑定会关掉它，
            // 两处同时关会触发"presenting while dismissing"，偶发崩溃。
            guard !结果们.isEmpty else {
                DispatchQueue.main.async { self.主.取消() }
                return
            }
            let 项们 = 结果们.map { $0.itemProvider }.filter { $0.canLoadObject(ofClass: UIImage.self) }
            顺序取(项们, 序号: 0, 已收: [])
        }

        /// 真正"顺序"加载：一张读完再读下一张。
        ///
        /// ⚠️ 2026-11-15 的闪退就是这里：早先版本用 DispatchGroup 并发加载，
        ///    又让每个回调往**同一个数组**里 append —— 多个后台线程写同一个
        ///    Swift Array 会破坏堆，表现为"选完图点确认就闪退"，而且偶发。
        ///    现在改为递归串行：每次回调拿到的是上一轮的副本，写完再交给下一轮。
        ///    顺带也压住了多选时的内存峰值。
        private func 顺序取(_ 项们: [NSItemProvider], 序号 i: Int, 已收: [UIImage]) {
            guard i < 项们.count else {
                DispatchQueue.main.async { self.主.完成(已收) }
                return
            }
            项们[i].loadObject(ofClass: UIImage.self) { 对像, _ in
                var 新 = 已收
                if let 图 = 对像 as? UIImage { 新.append(图) }
                self.顺序取(项们, 序号: i + 1, 已收: 新)
            }
        }
    }
}

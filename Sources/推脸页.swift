import SwiftUI
import Photos
import UIKit

/// 「推脸」入口格子（和「一键增强」同一套样式）。
///
/// 为什么单独一个结构体：宿主 `功能格` 是 private，外部调不到；
/// 复制同样的视觉结构、配色由调用方传入，宿主只加一行。
struct 推脸格: View {
    var 底色: Color
    var 字色: Color
    @State private var 开 = false

    var body: some View {
        Button { 开 = true } label: {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16).fill(底色.opacity(0.25))
                    Image(systemName: "hand.draw.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(字色)
                }
                .frame(height: 56)
                Text("推脸瘦身")
                    .font(.caption2)
                    .foregroundStyle(字色)
            }
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $开) {
            推脸页 { 开 = false }
        }
    }
}

/// 推脸编辑页：拖动人像局部变形，背景保持不动。
struct 推脸页: View {
    var 关闭: () -> Void

    @State private var 选 = false
    @State private var 加载中 = false
    /// 遮罩可视化：排查"为什么推不动"时打开，红色=可变形区域
    @State private var 看遮罩 = false
    @State private var 遮罩预览: UIImage?
    @State private var 会话: 推脸.会话?
    @State private var 预览: UIImage?
    @State private var 原图: UIImage?
    @State private var 背景保护 = true
    @State private var 大小: Double = 1.0
    @State private var 强度: Double = 0.8
    @State private var 有人像 = false
    @State private var 状态 = "选一张人像照片开始"
    @State private var 失败说明: String?

    // 拖动状态
    @State private var 上次点: CGPoint?
    /// 画布缩放与平移（放大后能推得更精细，缩回来能看全局）
    @State private var 缩放: CGFloat = 1
    @State private var 缩放基准: CGFloat = 1
    @State private var 偏移: CGSize = .zero
    /// 当前工具：推脸 / 拖人 / 移动画布 / 涂抹(锁死) / 擦除(解锁)
    // 2026-11-16 按用户反馈改成和醒图一致的语义：
//   · 涂抹 = 涂上的地方**锁死不动**（原来的"保护"）
//   · 擦除 = 擦掉涂抹，恢复可动（原来的"放开"）
enum 工具: String, CaseIterable { case 推脸 = "推脸", 拖人 = "拖人", 移动 = "画布", 加保护 = "涂抹", 放开 = "擦除" }
    @State private var 当前工具: 工具 = .推脸
    @State private var 上次平移: CGSize = .zero
    // 渲染节流
    @State private var 渲染中 = false
    @State private var 待渲染 = false
    /// 撤销栈：每笔/每次拖动前存一份（遮罩 + 位移），UInt8 压缩，单份约 1MB
    @State private var 撤销栈: [(遮罩: [UInt8], dx: [Float], dy: [Float])] = []
    private let 撤销上限 = 12

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                画布
                    .frame(maxHeight: .infinity)

                控制区
            }
            .navigationTitle("推脸瘦身")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { 关闭() }
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button("选图") { 选 = true }
                    Spacer()
                    Button("复原") {
                        会话?.清空位移()
                        请求渲染()
                    }
                    .disabled(会话 == nil)
                    Button {
                        撤销一步()
                    } label: {
                        Text("撤销").font(.system(size: 13))
                    }
                    .disabled(撤销栈.isEmpty)
                    Button(看遮罩 ? "看效果" : "看遮罩") {
                        看遮罩.toggle()
                        if 看遮罩, let s = 会话 {
                            // ⚠️ 画遮罩图要进后台线程，先把遮罩在主线程取成快照。
                            //    直接传 s.遮罩 会在用户同时涂抹时和主线程写数组竞争
                            //    （数组重新分配 → 后台读到悬垂缓冲 → 闪退）。
                            let 遮快照 = s.遮罩快照()
                            Task.detached(priority: .userInitiated) {
                                let m = 推脸.遮罩图(s, 遮罩: 遮快照)
                                await MainActor.run { 遮罩预览 = m }
                            }
                        }
                    }
                    .disabled(会话 == nil)
                    Spacer()
                    Button("保存") { 保存() }
                        .disabled(预览 == nil || 加载中)
                        .fontWeight(.semibold)
                }
            }
            .sheet(isPresented: $选) {
                一键选图器 { 图们 in
                    选 = false
                    if let 图 = 图们.first { 载入(图) }
                } 取消: { 选 = false }
            }
            .alert("出错了", isPresented: Binding(
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
                Color.black
                if let 预览 {
                    let 展示 = 看遮罩 ? (遮罩预览 ?? 预览) : 预览
                    let 尺寸 = 适应尺寸(展示.size, 在: 几何.size)
                    Image(uiImage: 展示)
                        .resizable()
                        .frame(width: 尺寸.width, height: 尺寸.height)
                        .scaleEffect(缩放)
                        .offset(偏移)
                        .position(x: 几何.size.width / 2, y: 几何.size.height / 2)
                        .gesture(拖动手势(显示尺寸: 尺寸, 框: 几何.size))
                        .simultaneousGesture(
                            // 双指捏合缩放：放大后可以推得更细，再缩回来
                            MagnificationGesture()
                                .onChanged { v in
                                    let 新 = min(6, max(1, 缩放基准 * v))
                                    缩放 = 新
                                    if 新 <= 1.01 { 偏移 = .zero }
                                }
                                .onEnded { _ in 缩放基准 = 缩放 }
                        )
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "hand.draw")
                            .font(.system(size: 40, weight: .light))
                            .foregroundStyle(.white.opacity(0.5))
                        Text(加载中 ? "正在识别人像…" : 状态)
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                if 加载中 {
                    ProgressView().tint(.white)
                        .scaleEffect(1.3)
                }
            }
        }
    }

    private func 适应尺寸(_ 图: CGSize, 在 框: CGSize) -> CGSize {
        guard 图.width > 0, 图.height > 0 else { return .zero }
        let k = min(框.width / 图.width, 框.height / 图.height)
        return CGSize(width: 图.width * k, height: 图.height * k)
    }

    /// 屏幕坐标 → 图片坐标。
    ///
    /// 必须带上 缩放/偏移 的逆变换，否则放大后推脸的位置会整体偏移
    /// （手指点的是放大后的位置，却按原始坐标去变形）。
    private func 图片坐标(_ p: CGPoint, 显示尺寸: CGSize, 框: CGSize, 图宽: Int) -> CGPoint {
        let 中 = CGPoint(x: 框.width / 2, y: 框.height / 2)
        let 显示X = (p.x - 中.x - 偏移.width) / 缩放 + 显示尺寸.width / 2
        let 显示Y = (p.y - 中.y - 偏移.height) / 缩放 + 显示尺寸.height / 2
        let k = CGFloat(图宽) / max(1, 显示尺寸.width)
        return CGPoint(x: 显示X * k, y: 显示Y * k)
    }

    private func 拖动手势(显示尺寸: CGSize, 框: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { 值 in
                guard let s = 会话, 显示尺寸.width > 0 else { return }

                // 移动画布：放大后必须能挪到画面边缘
                if 当前工具 == .移动 {
                    let d = CGSize(width: 值.translation.width - 上次平移.width,
                                   height: 值.translation.height - 上次平移.height)
                    偏移 = CGSize(width: 偏移.width + d.width, height: 偏移.height + d.height)
                    上次平移 = 值.translation
                    return
                }

                let 当前 = 图片坐标(值.location, 显示尺寸: 显示尺寸, 框: 框, 图宽: s.宽)

                // 涂遮罩：涂抹（涂上的锁死）或擦除（擦掉，恢复可动）
                if 当前工具 == .加保护 || 当前工具 == .放开 {
                    let 半径 = max(6, Int(Float(min(s.宽, s.高)) * 0.03 * Float(大小)))
                    // 笔迹平滑：手指采样点之间有间隔，直接逐个点画会呈"珠子串"。
                    // 这里在第一笔时存撤销快照，并在相邻两点之间按 半径/3 的步长插值，
                    // 让涂出来的边缘是连续的（相当于做了一次线性贝塞尔）。
                    if 撤销栈.isEmpty || 上次点 == nil { 存撤销() }
                    if let 上 = 上次点 {
                        let 起 = 图片坐标(上, 显示尺寸: 显示尺寸, 框: 框, 图宽: s.宽)
                        let dxp = 当前.x - 起.x, dyp = 当前.y - 起.y
                        let 距离 = max(abs(dxp), abs(dyp))
                        let 步长 = max(1.0, Double(半径) / 3.0)
                        let 段数 = min(64, max(1, Int(距离 / 步长)))
                        for i in 1...段数 {
                            let t = Double(i) / Double(段数)
                            s.涂(Int(起.x + dxp * t), Int(起.y + dyp * t),
                                 半径: 半径, 加保护: 当前工具 == .加保护)
                        }
                    } else {
                        s.涂(Int(当前.x), Int(当前.y), 半径: 半径, 加保护: 当前工具 == .加保护)
                    }
                    上次点 = 值.location
                    // 涂的时候**实时**把遮罩叠到预览上（这就是"边涂边看"）
                    s.应用涂改()
                    看遮罩 = true
                    if let m = 推脸.遮罩图(s, 遮罩: s.遮罩) { 遮罩预览 = m }
                    return
                }
                defer { 上次点 = 值.location }
                guard let 上 = 上次点 else { return }
                let 起 = 图片坐标(上, 显示尺寸: 显示尺寸, 框: 框, 图宽: s.宽)
                let vx = Float(当前.x - 起.x)
                let vy = Float(当前.y - 起.y)
                if abs(vx) < 0.01 && abs(vy) < 0.01 { return }

                if 上次点 == nil { 存撤销() }
                推脸.施加(s, 中心: Float(当前.x), Float(当前.y),
                        向量: vx, vy,
                        半径系数: Float(大小), 强度: Float(强度),
                        背景保护: 背景保护,
                        整体: 当前工具 == .拖人)
                请求渲染()
            }
            .onEnded { _ in
                上次点 = nil
                上次平移 = .zero
                if 当前工具 == .推脸 || 当前工具 == .拖人 { 请求渲染() }
                if 当前工具 == .加保护 || 当前工具 == .放开 { 请求渲染() }
            }
    }

    // MARK: - 撤销

    /// 存一份快照（遮罩压成 UInt8，位移保持 Float）。
    /// 为什么不用"指令回放"：涂抹里的"擦除"是减法，回放需要知道原值；
    /// 快照虽然占内存（约 1MB/份），但 12 份也就 12MB，换来靠谱的撤销。
    private func 存撤销() {
        guard let s = 会话 else { return }
        let 压 = s.遮罩.map { UInt8(max(0, min(255, Int(($0 * 255).rounded())))) }
        撤销栈.append((遮罩: 压, dx: s.dx, dy: s.dy))
        if 撤销栈.count > 撤销上限 { 撤销栈.removeFirst(撤销栈.count - 撤销上限) }
    }

    private func 撤销一步() {
        guard let s = 会话, let 上 = 撤销栈.popLast() else { return }
        s.遮罩 = 上.遮罩.map { Float($0) / 255.0 }
        s.dx = 上.dx
        s.dy = 上.dy
        s.应用涂改()
        if let m = 推脸.遮罩图(s, 遮罩: s.遮罩) { 遮罩预览 = m }
        请求渲染()
        状态 = "已撤销（还可退 \(撤销栈.count) 步）"
    }

    // MARK: - 控制区

    private var 控制区: some View {
        VStack(spacing: 12) {
            HStack {
                Text("大小").font(.system(size: 12)).foregroundStyle(.secondary)
                Slider(value: $大小, in: 0.5...2.0)
                Text("强度").font(.system(size: 12)).foregroundStyle(.secondary)
                Slider(value: $强度, in: 0.3...1.0)
            }
            // 缩放 / 平移条：放大能推得更细，缩回来能看全局
            // 工具条：推脸 / 移动 / 保护 / 放开（和醒图的"涂抹-擦除"对应）
            HStack(spacing: 6) {
                ForEach(工具.allCases, id: \.self) { 项 in
                    Button {
                        当前工具 = 项
                        上次平移 = .zero
                        if 项 == .加保护 || 项 == .放开 { 看遮罩 = true }
                    } label: {
                        Text(项.rawValue)
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 9).padding(.vertical, 6)
                            .background(Capsule().fill(当前工具 == 项
                                ? Color(red: 0.98, green: 0.55, blue: 0.30)
                                : Color(.secondarySystemBackground)))
                            .foregroundStyle(当前工具 == 项 ? Color.white : Color.primary)
                    }
                }
                Spacer()
                Button { 缩放 = max(1, 缩放 - 0.5); 缩放基准 = 缩放; if 缩放 <= 1.01 { 偏移 = .zero } } label: {
                    Image(systemName: "minus.magnifyingglass").font(.system(size: 16))
                }
                Text("\(Int(缩放 * 100))%")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 46)
                Button { 缩放 = min(6, 缩放 + 0.5); 缩放基准 = 缩放 } label: {
                    Image(systemName: "plus.magnifyingglass").font(.system(size: 16))
                }
                Button {
                    缩放 = 1; 缩放基准 = 1; 偏移 = .zero; 当前工具 = .推脸
                } label: {
                    Text("适应").font(.system(size: 12))
                }
            }
            .buttonStyle(.plain)
            .disabled(会话 == nil)

            // 遮罩编辑：反选 / 重置（只在涂抹时出现，平时不占地方）
            if 当前工具 == .加保护 || 当前工具 == .放开 {
                HStack(spacing: 8) {
                    Text("涂绿色=加保护，涂回原色=放开").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button("反选") {
                        guard let s = 会话 else { return }
                        s.反选()
                        if let m = 推脸.遮罩图(s, 遮罩: s.遮罩) { 遮罩预览 = m }
                        请求渲染()
                    }
                    .font(.system(size: 12, weight: .semibold))
                    Button("重置") {
                        guard let s = 会话 else { return }
                        s.重置遮罩()
                        if let m = 推脸.遮罩图(s, 遮罩: s.遮罩) { 遮罩预览 = m }
                        请求渲染()
                    }
                    .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
            }

            Toggle(isOn: $背景保护) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("背景保护").font(.system(size: 13, weight: .medium))
                    Text(有人像 ? "绿色＝锁死不动（「涂抹」涂上去）" : "⚠️ 没检测到主体：整张图都能动")
                        .font(.system(size: 11))
                        .foregroundStyle(有人像 ? Color.secondary : Color.orange)
                }
            }
            .tint(Color(red: 0.98, green: 0.55, blue: 0.30))
            .disabled(!有人像)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    // MARK: - 载入与渲染

    private func 载入(_ 图: UIImage) {
        诊断.记("推脸：开始准备（尺寸 \(Int(图.size.width))×\(Int(图.size.height))）")
        加载中 = true
        状态 = "正在识别人像…"
        Task {
            // 准备现在是 async（可能要调电脑 LaMa 补背景），不能再塞进 autoreleasepool
            加载中 = true
            状态 = "正在补全背景…（电脑在的话会用 LaMa，质量更好）"
            let 会话新 = await Task.detached(priority: .userInitiated) { () -> 推脸.会话? in
                await 推脸.准备(图, 补全背景: false)   // 纯形变不需要干净背景，省掉补全耗时
            }.value
            诊断.记("推脸：准备完成（会话 = \(会话新 == nil ? "nil" : "ok")）")

            guard let 会话新 else {
                加载中 = false
                失败说明 = "这张图处理失败（可能太大或格式不支持）"
                return
            }
            let 有 = 推脸.有人像(会话新)
            // 覆盖太低（<3%）说明分割只抓到一小块，强行开背景保护会"推不动"。
            // 这种情况老实降级：关掉保护、告诉用户，而不是让他对着屏幕怀疑人生。
            var 覆盖: Float = 0
            for v in 会话新.遮罩 where v > 0.5 { 覆盖 += 1 }
            let 占比 = 覆盖 / Float(会话新.宽 * 会话新.高)
            let 太窄 = 占比 < 0.03
            诊断.记("推脸：渲染首帧")
            let 首帧 = await Task.detached(priority: .userInitiated) {
                推脸.渲染(会话新, 遮罩: 会话新.遮罩, dx: 会话新.dx, dy: 会话新.dy, 背景保护: 有)
            }.value
            诊断.记("推脸：首帧完成（\(首帧 == nil ? "nil" : "ok")）")

            会话 = 会话新
            原图 = 首帧
            预览 = 首帧
            有人像 = 有
            if 太窄 { 背景保护 = false }
            加载中 = false
            let 来源说明: String
            switch 会话新.遮罩来源 {
            case "端侧-MODNet蒸馏": 来源说明 = "端侧抠像·MODNet \(会话新.遮罩毫秒)ms"
            case "端侧-isnetis": 来源说明 = "端侧抠像 \(会话新.遮罩毫秒)ms"
            case "电脑-精确抠像": 来源说明 = "电脑抠像 \(会话新.遮罩毫秒)ms"
            case "vision-person": 来源说明 = "人像分割"
            case "u2netp-general": 来源说明 = "通用主体分割"
            default: 来源说明 = "未分割"
            }
            状态 = 太窄
                ? "只识别到 \(Int(占比 * 100))% 的画面，已关掉背景保护（可点「看遮罩」确认）"
                : (有 ? "在主体上拖动即可变形（\(来源说明)）"
                     : "没分到主体：整张图可推，但背景会跟着动")
        }
    }

    /// 渲染节流：同一时刻只跑一个渲染任务，期间来的请求合并成一次。
    private func 请求渲染() {
        待渲染 = true
        guard !渲染中, let 会话 else { return }
        渲染中 = true
        let 保护 = 背景保护
        // 推脸=液化：不做遮罩合成（见 推脸.渲染 的 纯形变 说明）。
        // 给 Metal 传「背景=原图、遮罩全 1」，等价于纯形变，不用改 shader。
        let 纯形变 = 当前工具 == .推脸
        Task {
            while 待渲染 {
                待渲染 = false
                // 在主线程取快照，再交给后台线程渲染：
                // 后台直接读 会话.dx/dy 会和手势写入竞争，数组重分配时裸指针悬垂 → 闪退。
                诊断.记("推脸：拖动渲染")
                let (位移X, 位移Y) = 会话.位移快照()
                let 遮快照 = 会话.遮罩快照()
                let 图 = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                    // ① 优先 Metal（GPU 合成，60fps 级别）
                    if let 器 = 推脸渲染器.共享 {
                        let 用掩 = (保护 && !纯形变) ? 遮快照 : [Float](repeating: 1, count: 会话.宽 * 会话.高)
                        let 底图 = 纯形变 ? 会话.源 : 会话.背景
                        if let cg = 器.合成(人: 会话.源, 背景: 底图,
                                          遮罩: 用掩, dx: 位移X, dy: 位移Y,
                                          宽: 会话.宽, 高: 会话.高) {
                            return UIImage(cgImage: cg)
                        }
                    }
                    // ② Metal 不可用（老设备/初始化失败）→ 回退 CPU
                    诊断.记("推脸：Metal 不可用，回退 CPU 渲染")
                    return 推脸.渲染(会话, 遮罩: 遮快照, dx: 位移X, dy: 位移Y, 背景保护: 保护, 纯形变: 纯形变)
                }.value
                if let 图 { 预览 = 图 }
            }
            渲染中 = false
        }
    }

    private func 保存() {
        guard let 图 = 预览 else { return }
        Task {
            let 权 = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard 权 == .authorized || 权 == .limited else {
                失败说明 = "没拿到相册权限：设置 → 图来 → 照片 → 选「添加照片」"
                return
            }
            guard let 数据 = 图.jpegData(compressionQuality: 0.95) else { return }
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    let 请求 = PHAssetCreationRequest.forAsset()
                    let 选项 = PHAssetResourceCreationOptions()
                    选项.uniformTypeIdentifier = "public.jpeg"
                    请求.addResource(with: .photo, data: 数据, options: 选项)
                }
                关闭()
            } catch {
                失败说明 = "保存失败：\(error.localizedDescription)"
            }
        }
    }
}

import SwiftUI

// ============================================================
//  提示词库（2026-11-16 新增）
//
//  为什么单独一页：
//    「生图」页要放参数（模型/尺寸/放大），再塞 500 个词条会挤爆；
//    所以词库独立成页，选完把 tags 填回生图页。
//
//  数据来源：GET {生图服务}/prompts
//    （服务端每次请求现读 提示词库.json，改词库不用改 App、不用重启）
// ============================================================

// MARK: - 数据模型

struct 词条: Decodable, Hashable, Identifiable {
    let 中: String
    let en: String
    var id: String { en }
}

struct 词库模板: Decodable, Hashable, Identifiable {
    let 名: String
    let 中文: String
    let tags: String
    var id: String { 名 }
}

struct 词库数据: Decodable {
    let 版本: String?
    let 分类: [String: [词条]]
    let 组合模板: [词库模板]?
    let 负向词: [String: String]?
}

// MARK: - 页面

struct 提示词库页: View {
    var 关闭: () -> Void

    @State private var 库: 词库数据?
    @State private var 载入中 = true
    @State private var 出错: String?
    @State private var 当前类 = ""
    @State private var 已选: [String] = []          // 有序，保证拼出来的顺序稳定
    @State private var 搜索 = ""

    private var 类们: [String] {
        库.map { Array($0.分类.keys).sorted { 序($0) < 序($1) } } ?? []
    }

    /// 分类固定顺序（服务端 JSON 里字典无序，这里给一个人味儿的排序）
    private func 序(_ s: String) -> Int {
        let 表 = ["人物", "体型", "发型", "发色", "眼睛", "表情情绪", "姿势动作",
                 "服装", "配饰", "萌点特征", "场景", "天气时间", "光线氛围",
                 "视角镜头", "构图镜头", "画风", "特效", "质感细节", "多人互动", "职业身份", "奇幻元素"]
        if let i = 表.firstIndex(of: s) { return i }
        return 999
    }

    /// 当前类里、命中搜索的词条
    private var 可见词条: [词条] {
        guard let 库, let 全 = 库.分类[当前类] else { return [] }
        let k = 搜索.trimmingCharacters(in: .whitespaces)
        guard !k.isEmpty else { return 全 }
        return 全.filter { $0.中.contains(k) || $0.en.localizedCaseInsensitiveContains(k) }
    }

    private var 拼好的: String {
        已选.joined(separator: ", ")
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if 载入中 {
                    Spacer(); ProgressView("正在从电脑拉词库…").font(.system(size: 14)); Spacer()
                } else if let 出错 {
                    错误区(出错)
                } else {
                    分类条
                    模板区
                    词条区
                }
                底栏
            }
            .background(Color.white)
            .navigationTitle("提示词库")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { 关闭() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("清空") { 已选.removeAll() }.disabled(已选.isEmpty)
                }
            }
        }
        .task { await 载入() }
    }

    // MARK: 分类横条

    private var 分类条: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(类们, id: \.self) { k in
                    let 选中 = (k == 当前类)
                    let 数 = 库?.分类[k]?.count ?? 0
                    Button {
                        当前类 = k
                    } label: {
                        VStack(spacing: 2) {
                            Text(k).font(.system(size: 13, weight: 选中 ? .bold : .medium))
                            Text("\(数)").font(.system(size: 9)).opacity(0.7)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 9)
                            .fill(选中 ? 图来色.绿 : Color(red: 0.95, green: 0.96, blue: 0.95)))
                        .foregroundStyle(选中 ? Color.white : 图来色.字)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
    }

    // MARK: 模板

    private var 模板区: some View {
        Group {
            if let 模 = 库?.组合模板, !模.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("成品模板 · 点一下整套填入").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(图来色.次字).padding(.horizontal, 14)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(模) { t in
                                Button {
                                    已选 = t.tags.split(separator: ",").map {
                                        $0.trimmingCharacters(in: .whitespaces)
                                    }.filter { !$0.isEmpty }
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(t.名).font(.system(size: 12, weight: .semibold))
                                        Text(t.中文).font(.system(size: 9.5)).lineLimit(1).opacity(0.75)
                                    }
                                    .padding(.horizontal, 10).padding(.vertical, 7)
                                    .frame(width: 150, alignment: .leading)
                                    .background(RoundedRectangle(cornerRadius: 9)
                                        .fill(Color(red: 0.94, green: 0.96, blue: 0.99)))
                                    .foregroundStyle(图来色.字)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 14)
                    }
                }
                .padding(.bottom, 8)
            }
        }
    }

    // MARK: 词条

    private var 词条区: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(图来色.次字)
                TextField("搜中文或英文 tag", text: $搜索)
                    .font(.system(size: 13)).autocorrectionDisabled().textInputAutocapitalization(.never)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color(red: 0.96, green: 0.96, blue: 0.96)))
            .padding(.horizontal, 14)

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 7)], spacing: 7) {
                    ForEach(可见词条) { c in
                        let 选中 = 已选.contains(c.en)
                        Button {
                            if let i = 已选.firstIndex(of: c.en) { 已选.remove(at: i) } else { 已选.append(c.en) }
                        } label: {
                            VStack(spacing: 1) {
                                Text(c.中).font(.system(size: 11.5, weight: 选中 ? .semibold : .regular))
                                    .lineLimit(1)
                                Text(c.en).font(.system(size: 8.5)).lineLimit(1).opacity(0.65)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6).padding(.horizontal, 4)
                            .background(RoundedRectangle(cornerRadius: 8)
                                .fill(选中 ? 图来色.绿.opacity(0.22) : Color(red: 0.97, green: 0.97, blue: 0.97)))
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .stroke(选中 ? 图来色.绿 : Color.clear, lineWidth: 1.2))
                            .foregroundStyle(图来色.字)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
            }
        }
    }

    // MARK: 底栏

    private var 底栏: some View {
        VStack(spacing: 8) {
            HStack {
                Text("已选 \(已选.count) 个").font(.system(size: 12, weight: .semibold))
                Spacer()
                if !已选.isEmpty {
                    Button("还原") { 已选.removeLast() }.font(.system(size: 12))
                }
            }
            if !已选.isEmpty {
                Text(拼好的).font(.system(size: 10)).foregroundStyle(图来色.次字)
                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            }
            Button {
                // 交给生图页：写进 UserDefaults，生图页 onAppear 会读走并清掉
                UserDefaults.standard.set(拼好的, forKey: "生图.待填提示词")
                关闭()
            } label: {
                Text("填入 AI 生图").font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 11).fill(图来色.绿))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(已选.isEmpty)
            .opacity(已选.isEmpty ? 0.45 : 1)
        }
        .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 10)
        .background(Color.white.overlay(Rectangle().fill(Color.black.opacity(0.06)).frame(height: 1), alignment: .top))
    }

    private func 错误区(_ 说明: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "wifi.exclamationmark").font(.system(size: 34)).foregroundStyle(.orange)
            Text("词库拉不下来").font(.system(size: 15, weight: .semibold))
            Text(说明).font(.system(size: 12)).foregroundStyle(图来色.次字)
                .multilineTextAlignment(.center).padding(.horizontal, 30)
            Button("重试") { Task { await 载入() } }
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 18).padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 9).fill(图来色.绿)).foregroundStyle(.white)
            Spacer()
        }
    }

    // MARK: 网络

    private func 载入() async {
        载入中 = true; 出错 = nil
        defer { 载入中 = false }
        guard let u = URL(string: 生图配置.地址.trimmingCharacters(in: .whitespaces) + "/prompts") else {
            出错 = "服务器地址不对，先去 AI 生图 → 齿轮里设置"
            return
        }
        var r = URLRequest(url: u)
        r.timeoutInterval = 20
        r.setValue(生图配置.令牌, forHTTPHeaderField: "X-Token")
        do {
            let (数据, 响应) = try await URLSession.shared.data(for: r)
            guard let 码 = (响应 as? HTTPURLResponse)?.statusCode, 码 == 200 else {
                出错 = "服务返回 \((响应 as? HTTPURLResponse)?.statusCode ?? 0)，检查电脑上的服务"
                return
            }
            let 解析 = try JSONDecoder().decode(词库数据.self, from: 数据)
            库 = 解析
            if 当前类.isEmpty { 当前类 = 类们.first ?? "" }
        } catch {
            出错 = "连不上电脑：确认同一 Wi-Fi、电脑上的服务在跑\n(\(error.localizedDescription))"
        }
    }
}

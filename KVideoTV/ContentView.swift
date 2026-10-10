//
//  ContentView.swift
//  KVideoTV
//
//  Apple TV (tvOS) 原生客户端。
//
//  ⚠️ 为什么不用 WebView：
//  tvOS 平台不提供 WebKit.framework。Apple 官方对 WKWebView 的可用性声明是
//  「iOS 8.0+ / iPadOS 8.0+ / Mac Catalyst 13.1+ / macOS 10.10+ / visionOS 1.0+」，
//  唯独没有 tvOS。所以 `import WebKit` 在 tvOS 上会直接报
//  "no such module 'WebKit'"，网页版 KVideo 无法用 WebView 壳套进 Apple TV。
//
//  本实现改为：直接对接 KVideo 所使用的苹果CMS(MacCMS)采集源，
//  用原生 SwiftUI 做界面、用 AVPlayer 播放 HLS，遥控器天然可操作。
//
//  数据链路：
//    1. 搜索/列表  →  <采集站>/api.php/provide/vod?ac=videolist&wd=关键词  (JSON)
//    2. 取分集     →  vod_play_url 形如 "第01集$https://...#第02集$https://..."
//    3. 解析播放址 →  若为 /share/xxx 播放页，抓页面正则提取 m3u8
//    4. 播放       →  SwiftUI VideoPlayer（tvOS 内部即系统 AVPlayerViewController）
//

import SwiftUI
import AVKit

// MARK: - 采集源

struct VideoSource: Identifiable, Hashable {
    let id: String
    let name: String
    let baseUrl: String

    /// 内置源（对应 KVideo 站点 /api/config 里 subscriptionSources 订阅的采集站）。
    /// 想增删源，直接改这个数组即可。
    ///
    /// 下面 4 个是实测跑通过完整链路的（搜索 → 分集 → 解析出 m3u8 且能播）。
    static let builtIn: [VideoSource] = [
        VideoSource(id: "feifan", name: "非凡资源", baseUrl: "http://ffzy5.tv/api.php/provide/vod"),
        VideoSource(id: "zuida", name: "最大资源", baseUrl: "https://api.zuidapi.com/api.php/provide/vod"),
        VideoSource(id: "baofeng", name: "暴风资源", baseUrl: "https://bfzyapi.com/api.php/provide/vod"),
        VideoSource(id: "jisu", name: "极速资源", baseUrl: "https://jszyapi.com/api.php/provide/vod"),
    ]

    /// 备用源。实测当前不可用，留在这里方便你换网络环境后重新试：
    /// - 天涯资源：本机连不上（超时）
    /// - 卧龙资源：接口返回的是反爬 HTML 页面，不是 JSON
    /// - 百度云资源：本机连不上（超时）
    static let spare: [VideoSource] = [
        VideoSource(id: "tianya", name: "天涯资源", baseUrl: "https://tyyszy.com/api.php/provide/vod"),
        VideoSource(id: "wolong", name: "卧龙资源", baseUrl: "https://wolongzyw.com/api.php/provide/vod"),
        VideoSource(id: "baiduyun", name: "百度云资源", baseUrl: "https://api.apibdzy.com/api.php/provide/vod"),
    ]
}

// MARK: - 影片与分集

struct VodItem: Identifiable, Hashable {
    let key: String
    let vodID: String
    let sourceID: String
    let sourceName: String
    let name: String
    let pic: String
    let remarks: String
    let typeName: String
    let year: String
    let area: String
    let actor: String
    let director: String
    let content: String
    let playURL: String

    var id: String { key }

    var cleanContent: String {
        content
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var episodes: [Episode] { Episode.parse(playURL) }
}

struct Episode: Identifiable, Hashable {
    let index: Int
    let name: String
    let url: String

    var id: Int { index }

    /// 解析 vod_play_url。
    /// 可能形如：`第01集$https://a.m3u8#第02集$https://b.m3u8`
    /// 也可能有多个播放组，用 `$$$` 分隔，这里取第一组。
    static func parse(_ raw: String) -> [Episode] {
        guard !raw.isEmpty else { return [] }

        let firstGroup = raw.components(separatedBy: "$$$").first ?? raw
        var result: [Episode] = []

        for chunk in firstGroup.components(separatedBy: "#") {
            let piece = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !piece.isEmpty else { continue }

            if let dollar = piece.firstIndex(of: "$") {
                let label = String(piece[piece.startIndex..<dollar])
                    .trimmingCharacters(in: .whitespaces)
                let link = String(piece[piece.index(after: dollar)...])
                    .trimmingCharacters(in: .whitespaces)
                guard link.hasPrefix("http"), let url = URL(string: link) else { continue }
                _ = url
                result.append(Episode(
                    index: result.count,
                    name: label.isEmpty ? "第\(result.count + 1)集" : label,
                    url: link
                ))
            } else if piece.hasPrefix("http") {
                result.append(Episode(
                    index: result.count,
                    name: "第\(result.count + 1)集",
                    url: piece
                ))
            }
        }
        return result
    }
}

// MARK: - 响应模型

/// MacCMS 的 JSON 里同一个字段在不同源上可能是字符串也可能是数字，统一成字符串处理。
struct FlexibleString: Decodable {
    let value: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            value = string
        } else if let int = try? container.decode(Int.self) {
            value = String(int)
        } else if let double = try? container.decode(Double.self) {
            value = String(Int(double))
        } else {
            value = ""
        }
    }
}

struct MacCMSResponse: Decodable {
    let list: [MacCMSVod]?
}

struct MacCMSVod: Decodable {
    let vod_id: FlexibleString?
    let vod_name: FlexibleString?
    let vod_pic: FlexibleString?
    let vod_remarks: FlexibleString?
    let vod_year: FlexibleString?
    let vod_area: FlexibleString?
    let type_name: FlexibleString?
    let vod_actor: FlexibleString?
    let vod_director: FlexibleString?
    let vod_content: FlexibleString?
    let vod_play_url: FlexibleString?
}

// MARK: - 网络层

enum MacCMSError: LocalizedError {
    case badURL
    case badStatus(Int)
    case noPlayableURL

    var errorDescription: String? {
        switch self {
        case .badURL:            return "地址不合法"
        case .badStatus(let c):  return "服务返回 HTTP \(c)"
        case .noPlayableURL:     return "没有解析到可播放的地址"
        }
    }
}

enum MacCMS {

    static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        // 采集站质量参差，超时压到 8 秒，避免某个死源把整轮搜索拖住
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 20
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpAdditionalHeaders = ["User-Agent": userAgent]
        return URLSession(configuration: config)
    }()

    // MARK: 列表 / 搜索

    static func search(_ keyword: String, source: VideoSource) async throws -> [VodItem] {
        try await list(source: source, params: ["ac": "videolist", "wd": keyword, "pg": "1"])
    }

    /// 最近更新（h=48 表示最近 48 小时），用于首页填充，不依赖输入。
    static func latest(source: VideoSource) async throws -> [VodItem] {
        try await list(source: source, params: ["ac": "videolist", "h": "48", "pg": "1"])
    }

    static func list(source: VideoSource, params: [String: String]) async throws -> [VodItem] {
        guard var components = URLComponents(string: source.baseUrl) else {
            throw MacCMSError.badURL
        }

        var queryItems = components.queryItems ?? []
        for (key, value) in params.sorted(by: { $0.key < $1.key }) {
            queryItems.append(URLQueryItem(name: key, value: value))
        }
        components.queryItems = queryItems

        guard let url = components.url else { throw MacCMSError.badURL }

        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw MacCMSError.badStatus(http.statusCode)
        }

        let decoded = try JSONDecoder().decode(MacCMSResponse.self, from: data)
        let rawList = decoded.list ?? []

        return rawList.compactMap { raw in
            let name = raw.vod_name?.value ?? ""
            guard !name.isEmpty else { return nil }
            let vodID = raw.vod_id?.value ?? ""

            return VodItem(
                key: "\(source.id)-\(vodID)-\(name)",
                vodID: vodID,
                sourceID: source.id,
                sourceName: source.name,
                name: name,
                pic: raw.vod_pic?.value ?? "",
                remarks: raw.vod_remarks?.value ?? "",
                typeName: raw.type_name?.value ?? "",
                year: raw.vod_year?.value ?? "",
                area: raw.vod_area?.value ?? "",
                actor: raw.vod_actor?.value ?? "",
                director: raw.vod_director?.value ?? "",
                content: raw.vod_content?.value ?? "",
                playURL: raw.vod_play_url?.value ?? ""
            )
        }
    }

    // MARK: 播放地址解析

    /// 把某一集的地址变成 AVPlayer 能直接吃的 m3u8 URL。
    ///
    /// 两种常见形态：
    ///   a) 直接就是 `https://xxx/index.m3u8`（直链）
    ///   b) 是 `https://<host>/share/<hash>` 播放页，页内 JS 里写着真正的 m3u8
    ///
    /// ffzy 这类源属于 b，页面里是：
    ///     const url = "/20250420/49523_116b8961/index.m3u8?sign=...";
    /// 相对路径需要用页面 URL 做 base 补全。
    static func resolvePlaybackURL(_ raw: String) async throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MacCMSError.badURL }

        // a) 直链
        if trimmed.lowercased().contains(".m3u8"), !trimmed.contains("/share/") {
            guard let url = URL(string: trimmed) else { throw MacCMSError.badURL }
            return url
        }

        guard let pageURL = URL(string: trimmed) else { throw MacCMSError.badURL }

        // b) 抓播放页再提取
        let (data, _) = try await session.data(from: pageURL)
        let html = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""

        for pattern in playbackPatterns {
            if let found = firstMatch(pattern, in: html) {
                if let url = URL(string: found, relativeTo: pageURL)?.absoluteURL {
                    return url
                }
            }
        }

        throw MacCMSError.noPlayableURL
    }

    /// 依次尝试，命中即用。第一条覆盖 ffzy 的 `const url = "..."`
    private static let playbackPatterns = [
        #"const\s+url\s*=\s*["']([^"']+)["']"#,
        #"["']url["']\s*:\s*["']([^"']*\.m3u8[^"']*)["']"#,
        #"source\s*[:=]\s*["']([^"']*\.m3u8[^"']*)["']"#,
        #"["'](https?://[^"']*\.m3u8[^"']*)["']"#,
        #"(https?://[^\s"'<>]*\.m3u8[^\s"'<>]*)"#,
    ]

    static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: fullRange) else {
            return nil
        }
        for index in 1..<match.numberOfRanges {
            let range = match.range(at: index)
            guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else { continue }
            let value = String(text[swiftRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        return nil
    }
}

// MARK: - 聚合器

@MainActor
final class Aggregator: ObservableObject {
    @Published var items: [VodItem] = []
    @Published var isBusy = false
    @Published var message: String?

    let sources = VideoSource.builtIn

    /// SwiftUI 在 View 的属性初始化器里创建本对象时处于 nonisolated 上下文，
    /// 显式声明 nonisolated init 才能被 `@StateObject private var x = Aggregator()` 使用。
    nonisolated init() {}

    func search(_ keyword: String) async {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            message = "先输入片名再搜"
            return
        }

        isBusy = true
        message = nil
        items = []

        var collected: [VodItem] = []
        await withTaskGroup(of: [VodItem].self) { group in
            for source in sources {
                group.addTask {
                    (try? await MacCMS.search(trimmed, source: source)) ?? []
                }
            }
            for await batch in group {
                collected.append(contentsOf: batch)
                items = collected
            }
        }

        items = deduplicate(collected)
        isBusy = false

        if items.isEmpty {
            message = "没搜到「\(trimmed)」，换个关键词或换个片名试试"
        }
    }

    func loadLatest() async {
        guard items.isEmpty, !isBusy else { return }

        isBusy = true
        message = nil

        var collected: [VodItem] = []
        await withTaskGroup(of: [VodItem].self) { group in
            // 首页只打前 4 个源，避免一上来就并发太猛
            for source in sources.prefix(4) {
                group.addTask {
                    (try? await MacCMS.latest(source: source)) ?? []
                }
            }
            for await batch in group {
                collected.append(contentsOf: batch)
                items = collected
            }
        }

        items = deduplicate(collected)
        isBusy = false

        if items.isEmpty {
            message = "暂时没取到内容，可以直接搜索片名"
        }
    }

    private func deduplicate(_ list: [VodItem]) -> [VodItem] {
        var seen = Set<String>()
        return list.filter { item in
            let key = "\(item.sourceID)|\(item.name)"
            if seen.contains(key) { return false }
            seen.insert(key)
            return true
        }
    }
}

// MARK: - 播放数据

/// 需要能作为 NavigationStack 的 path 元素，故必须 Hashable。
struct Playing: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let episodes: [Episode]
    let startIndex: Int
}

// MARK: - 首页

struct ContentView: View {
    @StateObject private var aggregator = Aggregator()
    @State private var keyword = ""
    @State private var path = NavigationPath()

    private let columns = Array(
        repeating: GridItem(.fixed(300), spacing: 40),
        count: 5
    )

    // 播放页用 NavigationStack 推入，而不是 fullScreenCover：
    // fullScreenCover 在 tvOS 上不可用（编译期直接报 unavailable），
    // 而 push 进导航栈在 tvOS 上是原生行为，遥控器 Menu 键会自动返回。
    var body: some View {
        NavigationStack(path: $path) {
            home
                .navigationDestination(for: VodItem.self) { item in
                    DetailView(item: item) { episodes, startIndex in
                        path.append(
                            Playing(
                                title: item.name,
                                episodes: episodes,
                                startIndex: startIndex
                            )
                        )
                    }
                }
                .navigationDestination(for: Playing.self) { session in
                    PlayerScreen(playing: session)
                }
        }
        .task {
            await aggregator.loadLatest()
        }
    }

    private var home: some View {
        VStack(alignment: .leading, spacing: 36) {
            header

            if aggregator.isBusy {
                HStack(spacing: 18) {
                    ProgressView()
                    Text("正在向 \(aggregator.sources.count) 个源检索…")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 60)
            }

            if let message = aggregator.message, !aggregator.isBusy {
                Text(message)
                    .font(.system(size: 26))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 60)
            }

            ScrollView {
                LazyVGrid(columns: columns, spacing: 48) {
                    ForEach(aggregator.items) { item in
                        NavigationLink(value: item) {
                            PosterCard(item: item)
                        }
                    }
                }
                .padding(.horizontal, 60)
                .padding(.bottom, 80)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 36) {
            Text("KVideo")
                .font(.system(size: 52, weight: .bold))

            TextField("搜索片名", text: $keyword)
                .textFieldStyle(.plain)
                .font(.system(size: 28))
                .frame(width: 520)
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.12))
                )
                .onSubmit {
                    Task { await aggregator.search(keyword) }
                }

            Button {
                Task { await aggregator.search(keyword) }
            } label: {
                Text("搜索")
                    .font(.system(size: 26, weight: .semibold))
                    .padding(.horizontal, 30)
                    .padding(.vertical, 14)
            }

            Spacer()
        }
        .padding(.horizontal, 60)
        .padding(.top, 60)
    }
}

// MARK: - 海报卡片

struct PosterCard: View {
    let item: VodItem

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.08))

                AsyncImage(url: URL(string: item.pic)) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    case .failure:
                        Image(systemName: "film")
                            .font(.system(size: 52))
                            .foregroundStyle(.secondary)
                    case .empty:
                        ProgressView()
                    @unknown default:
                        EmptyView()
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .frame(width: 300, height: 420)

            Text(item.name)
                .font(.system(size: 26, weight: .medium))
                .lineLimit(1)

            Text("\(item.sourceName) · \(item.remarks)")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: 300, alignment: .leading)
    }
}

// MARK: - 详情

struct DetailView: View {
    let item: VodItem
    let onPlay: ([Episode], Int) -> Void

    private var episodes: [Episode] { item.episodes }

    private let episodeColumns = Array(
        repeating: GridItem(.fixed(190), spacing: 20),
        count: 6
    )

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 44) {
                HStack(alignment: .top, spacing: 48) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                        AsyncImage(url: URL(string: item.pic)) { phase in
                            switch phase {
                            case .success(let image):
                                image.resizable().aspectRatio(contentMode: .fill)
                            case .failure:
                                Image(systemName: "film")
                                    .font(.system(size: 60))
                                    .foregroundStyle(.secondary)
                            case .empty:
                                ProgressView()
                            @unknown default:
                                EmptyView()
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .frame(width: 360, height: 504)

                    VStack(alignment: .leading, spacing: 18) {
                        Text(item.name)
                            .font(.system(size: 46, weight: .bold))
                            .lineLimit(2)

                        Text(metaLine)
                            .font(.system(size: 24))
                            .foregroundStyle(.secondary)

                        if !item.actor.isEmpty {
                            Text("主演：\(item.actor)")
                                .font(.system(size: 22))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }

                        if !item.director.isEmpty {
                            Text("导演：\(item.director)")
                                .font(.system(size: 22))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        if !item.cleanContent.isEmpty {
                            Text(item.cleanContent)
                                .font(.system(size: 22))
                                .foregroundStyle(.secondary)
                                .lineLimit(7)
                        }
                    }

                    Spacer()
                }

                if episodes.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("这个源没有可直接播放的地址")
                            .font(.system(size: 28, weight: .semibold))
                        Text("返回上一级，换一个来源的同一部片再试。")
                            .font(.system(size: 22))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("选集 · 共 \(episodes.count) 集")
                        .font(.system(size: 32, weight: .semibold))

                    LazyVGrid(columns: episodeColumns, spacing: 22) {
                        ForEach(episodes) { episode in
                            Button {
                                onPlay(episodes, episode.index)
                            } label: {
                                Text(episode.name)
                                    .font(.system(size: 22))
                                    .lineLimit(1)
                                    .frame(width: 190, height: 64)
                            }
                        }
                    }
                }
            }
            .padding(60)
        }
    }

    private var metaLine: String {
        [item.sourceName, item.typeName, item.year, item.area]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}

// MARK: - 播放器

struct PlayerScreen: View {
    let playing: Playing

    @Environment(\.dismiss) private var dismiss
    @State private var index: Int
    @State private var player: AVPlayer?
    @State private var isLoading = true
    @State private var errorText: String?

    private var currentEpisode: Episode? {
        guard playing.episodes.indices.contains(index) else { return nil }
        return playing.episodes[index]
    }

    init(playing: Playing) {
        self.playing = playing
        _index = State(initialValue: playing.startIndex)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            }

            if isLoading {
                VStack(spacing: 22) {
                    ProgressView()
                        .scaleEffect(2)
                    Text("正在解析播放地址…")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                }
            }

            if let errorText {
                VStack(spacing: 26) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 60))
                        .foregroundStyle(.yellow)

                    Text("播不了这一集")
                        .font(.system(size: 34, weight: .semibold))

                    Text(errorText)
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 900)

                    Button("返回") { dismiss() }
                }
                .padding(60)
            }
        }
        .task(id: index) {
            await loadCurrent()
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }

    private func loadCurrent() async {
        isLoading = true
        errorText = nil
        player?.pause()
        player = nil

        guard let episode = currentEpisode else {
            isLoading = false
            errorText = "没有这一集"
            return
        }

        do {
            let url = try await MacCMS.resolvePlaybackURL(episode.url)
            let item = AVPlayerItem(url: url)
            let newPlayer = AVPlayer(playerItem: item)
            newPlayer.allowsExternalPlayback = true
            player = newPlayer
            isLoading = false
            newPlayer.play()
        } catch {
            isLoading = false
            errorText = "\(error.localizedDescription)\n\n\(episode.url)"
        }
    }
}

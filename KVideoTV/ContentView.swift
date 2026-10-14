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
//    1. 分类表    →  <采集站>/api.php/provide/vod?ac=list      (JSON 顶层 class 字段)
//    2. 分类列表  →  ...?ac=detail&t=<type_id>&pg=<页码>        (默认按更新时间倒序 = 「最新」)
//    3. 搜索      →  ...?ac=videolist&wd=关键词
//    4. 取分集    →  vod_play_url 形如 "第01集$https://...#第02集$https://..."
//    5. 解析播放址 →  若为 /share/xxx 播放页，抓页面正则提取 m3u8
//    6. 播放      →  SwiftUI VideoPlayer（tvOS 内部即系统 AVPlayerViewController）
//    7. 评分      →  movie.douban.com/j/subject_abstract?subject_id=<豆瓣ID>（「高分」排序用）
//
//  ⚠️ 关于「最热」：采集源不提供热度数据 —— 实测 vod_hits / vod_hits_day 恒为 0，
//  且 by=hits / by=score / order=hits 这些排序参数全部无效（返回结果与默认完全一致）。
//  所以「最热」在本 App 里改为「高分」：取候选池后按豆瓣评分倒序。
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

    /// 「分类浏览」的默认源（bootstrap 时若它失联会自动切到其他源）。
    /// 分类 ID 是各个采集站自己的一套编号，跨源不可通用；这里挑分类最全、
    /// 片量最大的非凡资源（实测 9.8 万条 / 30 个分类）作为首选，
    /// 失联时降级到 https 的最大资源（无 type_pid，靠编号区段推断归属）。
    static let catalogSource: VideoSource = builtIn[0]

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

// MARK: - 分类

/// 苹果CMS 的分类，对应接口返回的顶层 `class` 数组。
/// `pid == 0` 的是顶级分类（电影 / 电视剧 / 综艺 / 动漫），其余挂在它下面。
struct Category: Identifiable, Hashable {
    let id: Int        // type_id
    let pid: Int       // type_pid
    let name: String   // type_name（已归一化，见 displayName）

    // MARK: 顶级导航的名字跟网站叫法走

    static func displayName(_ raw: String) -> String {
        switch raw {
        case "电影片": return "电影"
        case "连续剧": return "电视剧"
        case "综艺片": return "综艺"
        case "动漫片": return "动漫"
        default:       return raw
        }
    }

    // MARK: 客厅场景不放的分类

    static let blockedKeywords: [String] = ["伦理", "三级", "两性", "写真"]

    static func isBlocked(_ name: String) -> Bool {
        blockedKeywords.contains { name.contains($0) }
    }

    // MARK: pid 缺失时的归属推断

    /// MacCMS 传统分类编号区段（非凡/最大等主流源基本都遵守）。
    /// 有的源（如最大资源）的 class 里**不返回 type_pid**，只能按编号 + 名字推断归属。
    static func inferredPid(id: Int, rawName: String) -> Int {
        switch id {
        case 1...4:   return 0
        case 6...12:  return 1          // 动作片…战争片 → 电影
        case 13...24: return 2          // 国产剧…泰国剧 → 电视剧
        case 25...28: return 3          // 大陆综艺…欧美综艺 → 综艺
        case 29...33: return 4          // 国产动漫…海外动漫 → 动漫
        default:
            if isBlocked(rawName) { return -1 }
            if rawName.contains("演唱") || rawName.contains("体育")
                || rawName.contains("篮球") || rawName.contains("足球")
                || rawName.contains("斯诺克") { return 3 }
            if rawName.contains("动漫") || rawName.contains("动画") { return 4 }
            if rawName.contains("剧") { return 2 }
            return 1
        }
    }

    // MARK: 兜底分类表

    /// 所有源的分类表都拉不到时用的固定结构（非凡资源的编号体系，实测 2026-10）。
    /// 分类表接口偶发失败时 UI 不至于塌掉；列表请求仍走非凡。
    static let fallback: [Category] = [
        Category(id: 1,  pid: 0, name: "电影"),
        Category(id: 2,  pid: 0, name: "电视剧"),
        Category(id: 3,  pid: 0, name: "综艺"),
        Category(id: 4,  pid: 0, name: "动漫"),

        Category(id: 6,  pid: 1, name: "动作片"),
        Category(id: 7,  pid: 1, name: "喜剧片"),
        Category(id: 8,  pid: 1, name: "爱情片"),
        Category(id: 9,  pid: 1, name: "科幻片"),
        Category(id: 10, pid: 1, name: "恐怖片"),
        Category(id: 11, pid: 1, name: "剧情片"),
        Category(id: 12, pid: 1, name: "战争片"),
        Category(id: 20, pid: 1, name: "记录片"),

        Category(id: 13, pid: 2, name: "国产剧"),
        Category(id: 14, pid: 2, name: "香港剧"),
        Category(id: 15, pid: 2, name: "韩国剧"),
        Category(id: 16, pid: 2, name: "欧美剧"),
        Category(id: 21, pid: 2, name: "台湾剧"),
        Category(id: 22, pid: 2, name: "日本剧"),
        Category(id: 23, pid: 2, name: "海外剧"),
        Category(id: 24, pid: 2, name: "泰国剧"),
        Category(id: 36, pid: 2, name: "短剧"),

        Category(id: 25, pid: 3, name: "大陆综艺"),
        Category(id: 26, pid: 3, name: "港台综艺"),
        Category(id: 27, pid: 3, name: "日韩综艺"),
        Category(id: 28, pid: 3, name: "欧美综艺"),

        Category(id: 29, pid: 4, name: "国产动漫"),
        Category(id: 30, pid: 4, name: "日韩动漫"),
        Category(id: 31, pid: 4, name: "欧美动漫"),
        Category(id: 32, pid: 4, name: "港台动漫"),
        Category(id: 33, pid: 4, name: "海外动漫"),
    ]
}

/// 分类页的排序方式。
/// - `latest`  = 采集站默认顺序（按更新时间倒序），也就是网站的「最新」
/// - `topRated` = 拉候选池后按豆瓣评分倒序，等价于网站的「最热」位置
enum CatalogSort: String, CaseIterable, Identifiable {
    case latest   = "最新"
    case topRated = "高分"

    var id: String { rawValue }
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

    /// 豆瓣数据。`doubanScore` 是采集源自己带的评分（很多是 0），
    /// 拿不到时由 Douban 服务按 `doubanID` 现查。
    let doubanID: String
    let doubanScore: Double

    var id: String { key }

    /// Hashable 只按 key 算 —— VodItem 要作为 NavigationStack 的 path 元素，
    /// 而评分是「后补」的（不同时刻可能不同），不能让评分参与相等性判断。
    static func == (lhs: VodItem, rhs: VodItem) -> Bool { lhs.key == rhs.key }
    func hash(into hasher: inout Hasher) { hasher.combine(key) }

    var cleanContent: String {
        content
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var episodes: [Episode] { Episode.parse(playURL) }

    /// 卡片上显示的评分文案，0 分表示豆瓣还没开分。
    func scoreText(ratings: [String: Double]) -> String? {
        let value = ratings[key] ?? doubanScore
        guard value > 0 else { return nil }
        return String(format: "%.1f", value)
    }
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

/// 评分类字段得单独处理：用 FlexibleString 会把 8.8 截成 8，丢精度。
struct FlexibleDouble: Decodable {
    let value: Double

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let double = try? container.decode(Double.self) {
            value = double
        } else if let int = try? container.decode(Int.self) {
            value = Double(int)
        } else if let string = try? container.decode(String.self) {
            value = Double(string) ?? 0
        } else {
            value = 0
        }
    }
}

struct MacCMSResponse: Decodable {
    let list: [MacCMSVod]?
    /// 接口顶层字段就叫 `class`，是 Swift 关键字，映射成 categories。
    let categories: [MacCMSCategory]?

    enum CodingKeys: String, CodingKey {
        case list
        case categories = "class"
    }
}

struct MacCMSCategory: Decodable {
    let type_id: Int?
    let type_pid: Int?
    let type_name: String?
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
    let vod_douban_id: FlexibleString?
    let vod_douban_score: FlexibleDouble?
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

    /// 按分类取列表。默认顺序即「按更新时间倒序」。
    static func catalog(source: VideoSource, typeID: Int, page: Int) async throws -> [VodItem] {
        try await list(source: source, params: [
            "ac": "detail",
            "t": String(typeID),
            "pg": String(page),
        ])
    }

    /// 分类表。`ac=list` 不带 t 时会返回顶层 `class` 字段。
    ///
    /// 两个兼容坑（实测）：
    /// - 非凡资源带 `type_pid`；**最大资源不返回 type_pid** → 用编号区段 + 名字推断归属
    /// - 顶级叫法不一（电影片 / 电影），统一走 `Category.displayName` 归一化
    static func categories(source: VideoSource) async throws -> [Category] {
        let response = try await raw(source: source, params: ["ac": "list"])
        return (response.categories ?? []).compactMap { raw in
            guard let id = raw.type_id, let name = raw.type_name, !name.isEmpty else { return nil }
            let pid = raw.type_pid ?? Category.inferredPid(id: id, rawName: name)
            return Category(id: id, pid: pid, name: Category.displayName(name))
        }
    }

    // MARK: 底层请求

    static func list(source: VideoSource, params: [String: String]) async throws -> [VodItem] {
        let response = try await raw(source: source, params: params)
        let rawList = response.list ?? []

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
                playURL: raw.vod_play_url?.value ?? "",
                doubanID: raw.vod_douban_id?.value ?? "",
                doubanScore: raw.vod_douban_score?.value ?? 0
            )
        }
    }

    private static func raw(source: VideoSource, params: [String: String]) async throws -> MacCMSResponse {
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

        return try JSONDecoder().decode(MacCMSResponse.self, from: data)
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

// MARK: - 豆瓣评分

/// 只用豆瓣的轻量接口拿评分：
///   https://movie.douban.com/j/subject_abstract?subject_id=<id>
/// 实测 8 并发跑 40 次请求约 1.7 秒，无风控；评分字段是 subject.rate（字符串 "5.5"）。
/// 注意：豆瓣只对「已上映且评价数够」的片子有分，很多新片/短剧查出来是空的，
/// 这种情况返回 nil，UI 上不显示角标（排序时排到最后）。
enum Douban {

    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 15
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpAdditionalHeaders = ["User-Agent": MacCMS.userAgent]
        return URLSession(configuration: config)
    }()

    static func rate(subjectID: String) async -> Double? {
        let trimmed = subjectID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "0" else { return nil }

        guard var components = URLComponents(string: "https://movie.douban.com/j/subject_abstract") else {
            return nil
        }
        components.queryItems = [URLQueryItem(name: "subject_id", value: trimmed)]
        guard let url = components.url else { return nil }

        do {
            let (data, _) = try await session.data(from: url)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let subject = root["subject"] as? [String: Any] else { return nil }

            if let text = subject["rate"] as? String, let value = Double(text), value > 0 {
                return value
            }
            if let value = subject["rate"] as? Double, value > 0 {
                return value
            }
            return nil
        } catch {
            return nil
        }
    }

    /// 给一批影片补评分，返回 [VodItem.key: 豆瓣评分]。
    /// 优先用采集源自带的 vod_douban_score（省一次请求），没有再查豆瓣。
    /// 分批（默认每批 8 个）是为了别把豆瓣打急。
    static func enrich(
        _ items: [VodItem],
        existing: [String: Double] = [:],
        concurrency: Int = 8
    ) async -> [String: Double] {
        var result = existing
        var pending: [VodItem] = []

        for item in items {
            if result[item.key] != nil { continue }
            if item.doubanScore > 0 {
                result[item.key] = item.doubanScore
            } else if !item.doubanID.isEmpty, item.doubanID != "0" {
                pending.append(item)
            }
        }

        for batch in pending.chunked(into: concurrency) {
            await withTaskGroup(of: (String, Double?).self) { group in
                for item in batch {
                    group.addTask { (item.key, await rate(subjectID: item.doubanID)) }
                }
                for await (key, value) in group {
                    if let value { result[key] = value }
                }
            }
        }

        return result
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0, !isEmpty else { return isEmpty ? [] : [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

// MARK: - 聚合器（首页 / 搜索）

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

// MARK: - 分类浏览

@MainActor
final class CatalogStore: ObservableObject {
    /// 分类浏览当前用的源。bootstrap 时按「谁响应就用谁」动态选定
    /// （非凡优先，但它是 http 明文，电视网络环境下可能失联 → 切到 https 的最大资源）。
    private var workingSource = VideoSource.catalogSource

    @Published var tops: [Category] = []          // 顶级分类（电影 / 电视剧 / 综艺 / 动漫）
    @Published var subs: [Category] = []          // 当前顶级下的子分类
    @Published var activeTop: Category?
    @Published var activeSub: Category?           // nil = 「全部」
    @Published var sort: CatalogSort = .latest
    @Published var items: [VodItem] = []
    @Published var ratings: [String: Double] = [:]
    @Published var isBusy = false
    @Published var isLoadingMore = false
    @Published var message: String?
    /// 是否还有下一页（只对「最新」排序有意义）。到底后滚到底会自动续上。
    @Published var hasMore = true

    private var all: [Category] = []
    private var page = 1

    /// 「高分」模式一次性拉几页做候选池（每页 20 条）。
    private let rankingPages = 3

    nonisolated init() {}

    // MARK: 载入分类表

    func bootstrap() async {
        guard tops.isEmpty, !isBusy else { return }

        isBusy = true
        message = nil

        // 双源并发拉分类表：非凡（http，分类最准）优先；
        // 电视网络下拉不到就用最大资源（https，更稳，但没有 type_pid → 靠区段推断）。
        let primary = VideoSource.builtIn[0]
        let secondary = VideoSource.builtIn[1]
        async let primaryCats = MacCMS.categories(source: primary)
        async let secondaryCats = MacCMS.categories(source: secondary)

        var fetched: [Category] = []
        if let cats = try? await primaryCats, cats.count >= 5 {
            fetched = cats
            workingSource = primary
        } else if let cats = try? await secondaryCats, cats.count >= 5 {
            fetched = cats
            workingSource = secondary
        }

        if fetched.isEmpty {
            // 分类表全挂：用固定结构兜底，列表仍走非凡（编号体系一致）。
            // 列表接口和分类表接口是两条路，多半还能用。
            all = Category.fallback
            workingSource = VideoSource.catalogSource
        } else {
            all = fetched
        }

        tops = all
            .filter { $0.pid == 0 && !Category.isBlocked($0.name) }
            .sorted { $0.id < $1.id }

        isBusy = false

        if tops.isEmpty {
            message = "分类没取到，稍后再试或者用搜索"
            return
        }
        if activeTop == nil, let first = tops.first {
            await selectTop(first)
        }
    }

    func selectTop(_ top: Category) async {
        activeTop = top
        subs = all
            .filter { $0.pid == top.id && !Category.isBlocked($0.name) }
            .sorted { $0.id < $1.id }
        activeSub = nil
        await reload()
    }

    func selectSub(_ sub: Category?) async {
        guard activeSub != sub else { return }
        activeSub = sub
        await reload()
    }

    func setSort(_ newSort: CatalogSort) async {
        guard sort != newSort else { return }
        sort = newSort
        await reload()
    }

    // MARK: 拉数据

    func reload() async {
        guard activeTop != nil else { return }

        isBusy = true
        message = nil
        items = []
        ratings = [:]
        page = 1
        hasMore = true

        switch sort {
        case .latest:
            let batch = deduplicate(await fetchPage(1))
            items = batch
            hasMore = batch.count >= 15
            if batch.isEmpty {
                message = "这个分类暂时没取到内容，可以换个分类或用搜索"
            }

        case .topRated:
            var pool: [VodItem] = []
            for index in 1...rankingPages {
                pool.append(contentsOf: await fetchPage(index))
            }
            let unique = deduplicate(pool)
            if unique.isEmpty {
                message = "这个分类暂时没取到内容"
            } else {
                // 先把界面放出来，评分到了再补上（角标会逐个出现）
                items = unique
                isBusy = false
                ratings = await Douban.enrich(unique)
            }
        }

        isBusy = false
    }

    func loadMore() async {
        guard sort == .latest, hasMore, !hasMore == false, !isLoadingMore, !isBusy else { return }
        guard hasMore else { return }

        isLoadingMore = true
        page += 1

        let existing = Set(items.map { $0.key })
        let fresh = deduplicate(await fetchPage(page)).filter { !existing.contains($0.key) }

        if fresh.isEmpty {
            hasMore = false
        } else {
            items.append(contentsOf: fresh)
        }

        isLoadingMore = false
    }

    func score(of item: VodItem) -> Double {
        ratings[item.key] ?? item.doubanScore
    }

    private func fetchPage(_ index: Int) async -> [VodItem] {
        guard activeTop != nil else { return [] }

        // 取成局部常量再进并发闭包：self.workingSource 是 actor-isolated 的，
        // 直接在 group.addTask 里引用会要求显式 self 且跨隔离有问题。
        let src = workingSource

        if let sub = activeSub {
            return (try? await MacCMS.catalog(source: src, typeID: sub.id, page: index)) ?? []
        }

        // 「全部」= 并发取该顶级下所有子分类的同一页，合并成一批
        let subList = subs
        var collected: [VodItem] = []
        await withTaskGroup(of: [VodItem].self) { group in
            for sub in subList {
                group.addTask {
                    (try? await MacCMS.catalog(source: src, typeID: sub.id, page: index)) ?? []
                }
            }
            for await batch in group {
                collected.append(contentsOf: batch)
            }
        }
        return collected
    }

    private func deduplicate(_ list: [VodItem]) -> [VodItem] {
        var seen = Set<String>()
        return list.filter { item in
            if seen.contains(item.key) { return false }
            seen.insert(item.key)
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

/// 顶部导航的位置。
enum HomeTab: Hashable {
    case home
    case catalog(Int)
    case search
}

struct ContentView: View {
    @StateObject private var aggregator = Aggregator()
    @StateObject private var catalog = CatalogStore()
    @State private var keyword = ""
    @State private var path = NavigationPath()
    @State private var tab: HomeTab = .home

    var body: some View {
        NavigationStack(path: $path) {
            root
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
            await catalog.bootstrap()
        }
    }

    private var root: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            tabBar
            content
        }
    }

    // MARK: 顶部：标题 + 搜索

    private var header: some View {
        HStack(spacing: 36) {
            Text("KVideo")
                .font(.system(size: 48, weight: .bold))

            TextField("搜索片名", text: $keyword)
                .textFieldStyle(.plain)
                .font(.system(size: 26))
                .frame(width: 460)
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.12))
                )
                .onSubmit { runSearch() }

            Button {
                runSearch()
            } label: {
                Text("搜索")
                    .font(.system(size: 24, weight: .semibold))
                    .padding(.horizontal, 28)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)

            Spacer()
        }
        .padding(.horizontal, 60)
        .padding(.top, 48)
        .padding(.bottom, 24)
    }

    private func runSearch() {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        tab = .search
        Task { await aggregator.search(trimmed) }
    }

    // MARK: 模式 Tab：推荐 / 电影 / 连续剧 / 综艺 / 动漫

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                tabPill(title: "推荐", isActive: tab == .home) {
                    tab = .home
                }

                ForEach(catalog.tops) { top in
                    tabPill(title: top.name, isActive: tab == .catalog(top.id)) {
                        tab = .catalog(top.id)
                        Task { await catalog.selectTop(top) }
                    }
                }

                if tab == .search {
                    tabPill(title: "搜索结果", isActive: true) { }
                }
            }
            .padding(.horizontal, 60)
            .padding(.vertical, 6)
        }
        .padding(.bottom, 12)
    }

    private func tabPill(title: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 24, weight: isActive ? .bold : .regular))
                .padding(.horizontal, 28)
                .padding(.vertical, 12)
        }
        .buttonStyle(.borderedProminent)
        .tint(isActive ? Color.white : Color.white.opacity(0.16))
        .foregroundStyle(isActive ? Color.black : Color.white)
    }

    // MARK: 内容区

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .home:
            posterGrid(
                items: aggregator.items,
                ratings: [:],
                isBusy: aggregator.isBusy,
                message: aggregator.message,
                busyText: "正在向 \(aggregator.sources.count) 个源检索…"
            )

        case .search:
            posterGrid(
                items: aggregator.items,
                ratings: [:],
                isBusy: aggregator.isBusy,
                message: aggregator.message,
                busyText: "正在向 \(aggregator.sources.count) 个源检索…"
            )

        case .catalog:
            CatalogBrowser(store: catalog)
        }
    }

    @ViewBuilder
    private func posterGrid(
        items: [VodItem],
        ratings: [String: Double],
        isBusy: Bool,
        message: String?,
        busyText: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            if isBusy && items.isEmpty {
                HStack(spacing: 18) {
                    ProgressView()
                    Text(busyText)
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 60)
            }

            if let message, !isBusy, items.isEmpty {
                Text(message)
                    .font(.system(size: 26))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 60)
            }

            ScrollView {
                LazyVGrid(columns: Grid.columns, spacing: 48) {
                    ForEach(items) { item in
                        NavigationLink(value: item) {
                            PosterCard(item: item, score: item.scoreText(ratings: ratings))
                        }
                    }
                }
                .padding(.horizontal, 60)
                .padding(.bottom, 80)
            }
        }
    }
}

// MARK: - 分类浏览页

struct CatalogBrowser: View {
    @ObservedObject var store: CatalogStore

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            toolbar

            if store.isBusy && store.items.isEmpty {
                HStack(spacing: 18) {
                    ProgressView()
                    Text(store.sort == .topRated ? "正在抓豆瓣评分并排序…" : "正在取片…")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 60)
                .padding(.top, 20)
            }

            if let message = store.message, !store.isBusy, store.items.isEmpty {
                Text(message)
                    .font(.system(size: 26))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 60)
                    .padding(.top, 20)
            }

            ScrollView {
                LazyVGrid(columns: Grid.columns, spacing: 48) {
                    ForEach(store.items) { item in
                        NavigationLink(value: item) {
                            PosterCard(item: item, score: item.scoreText(ratings: store.ratings))
                        }
                    }
                }
                .padding(.horizontal, 60)
                .padding(.bottom, 40)

                if store.sort == .latest && store.hasMore && !store.items.isEmpty {
                    loadMoreFooter
                }
            }
        }
    }

    // MARK: 子分类 chips + 排序

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 18) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    subChip(title: "全部", isActive: store.activeSub == nil) {
                        Task { await store.selectSub(nil) }
                    }

                    ForEach(store.subs) { sub in
                        subChip(title: sub.name, isActive: store.activeSub?.id == sub.id) {
                            Task { await store.selectSub(sub) }
                        }
                    }
                }
                .padding(.horizontal, 60)
            }

            HStack(spacing: 14) {
                ForEach(CatalogSort.allCases) { option in
                    subChip(
                        title: option.rawValue,
                        isActive: store.sort == option,
                        emphasized: true
                    ) {
                        Task { await store.setSort(option) }
                    }
                }

                if store.sort == .topRated {
                    Text("按豆瓣评分排序 · 未开分的排在最后")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 12)
                }

                Spacer()
            }
            .padding(.horizontal, 60)
        }
    }

    private func subChip(
        title: String,
        isActive: Bool,
        emphasized: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: emphasized ? 23 : 21, weight: isActive ? .bold : .regular))
                .padding(.horizontal, emphasized ? 26 : 22)
                .padding(.vertical, 10)
        }
        .buttonStyle(.borderedProminent)
        .tint(isActive ? Color.white : Color.white.opacity(0.14))
        .foregroundStyle(isActive ? Color.black : Color.white)
    }

    // MARK: 加载更多

    /// tvOS 上用遥控器滚到底就自动续下一页，不需要额外点按钮。
    /// 这里放一个 1pt 高的哨兵：它被 LazyVStack 真正渲染出来时，说明已经滚到底了。
    private var loadMoreFooter: some View {
        LazyVStack {
            if store.isLoadingMore {
                ProgressView()
                    .padding(.vertical, 44)
                    .padding(.bottom, 30)
            } else {
                Color.clear
                    .frame(height: 1)
                    .onAppear {
                        Task { await store.loadMore() }
                    }
            }
        }
    }
}

// MARK: - 网格参数

private enum Grid {
    static let columns = Array(
        repeating: GridItem(.fixed(300), spacing: 40),
        count: 5
    )
}

// MARK: - 海报卡片

struct PosterCard: View {
    let item: VodItem
    var score: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ZStack(alignment: .topTrailing) {
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

                if let score {
                    Text(score)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Color.black)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color(red: 1.0, green: 0.76, blue: 0.2))
                                .shadow(radius: 4)
                        )
                        .padding(10)
                }
            }

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

                        if item.doubanScore > 0 {
                            Text("豆瓣 \(String(format: "%.1f", item.doubanScore))")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(.orange)
                        }

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

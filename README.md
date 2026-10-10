# KVideoTV — KVideo 的 Apple TV (tvOS) 客户端

在 Apple TV 上看 KVideo 的**原生客户端**：SwiftUI 界面 + 系统播放器，遥控器直接操作。

---

## ⚠️ 先讲清楚：tvOS 上没有 WebView

「套个网页壳」这个思路在 Apple TV 上走不通，而且不是配置问题，是平台硬限制。

Apple 官方对 `WKWebView` 的可用性声明原文是：

```
iOS 8.0+  iPadOS 8.0+  Mac Catalyst 13.1+  macOS 10.10+  visionOS 1.0+
```

**唯独没有 tvOS。** tvOS 平台不提供 `WebKit.framework`，
所以 `import WebKit` 会直接编译失败：

```
ContentView.swift:11:8: error: no such module 'WebKit'
```

（顺带一提，这也是 App Store 上没有真正的 Apple TV 浏览器的原因。）

因此本项目**不是网页壳**，而是直接对接 KVideo 所使用的那套
**苹果CMS(MacCMS) 采集源**，用原生 SwiftUI 做界面、`AVPlayer` 播 HLS。
功能上等价于 KVideo，而且因为绕开了网页层，遥控器操作体验更好。

---

## 工作原理

```
① 搜索 / 列表
     <采集站>/api.php/provide/vod?ac=videolist&wd=关键词     → JSON
                                                                  │
② 取分集                                                          ▼
     vod_play_url = "第01集$https://.../share/xxx#第02集$..."   （# 分集，$$$ 分播放组）
                                                                  │
③ 解析播放地址                                                    ▼
     · 已是 .m3u8 直链 → 直接用
     · 是 /share/xxx 播放页 → 抓页面，正则提取 JS 里的 m3u8 地址
       页内形如：const url = "/20250420/49523_116b8961/index.m3u8?sign=..."
       （相对路径，需用页面 URL 补全）
                                                                  │
④ 播放                                                            ▼
     AVPlayerViewController 播放 m3u8
```

四个步骤都在 `KVideoTV/ContentView.swift` 里，按 `// MARK:` 分段，很好找。

---

## 采集源配置

改 `ContentView.swift` 顶部的 `VideoSource.builtIn` 即可增删源。默认 4 个：

| 源 | 接口 | 实测 |
| --- | --- | --- |
| 非凡资源 | `http://ffzy5.tv/api.php/provide/vod` | ✅ 分享页模式 |
| 最大资源 | `https://api.zuidapi.com/api.php/provide/vod` | ✅ 直链模式 |
| 暴风资源 | `https://bfzyapi.com/api.php/provide/vod` | ✅ |
| 极速资源 | `https://jszyapi.com/api.php/provide/vod` | ✅（content-type 标成 html，但内容是 JSON） |

另有 `VideoSource.spare` 存了 3 个当前实测不可用的源（天涯连不上、卧龙返回反爬 HTML、
百度云连不上）。**换到别的网络环境（比如电视所在的家庭网络）时可以再试**，
把可用的挪进 `builtIn` 即可。

> 想跟 KVideo 站点保持同步的话，源清单在它自己的 `/api/config` 里：
> `subscriptionSources` 指向一个包含 `baseUrl` 列表的 JSON。

---

## 环境要求

- macOS（路线 A 需要完整版 Xcode 15+；路线 B 不需要）
- Apple Developer 账号（免费 Apple ID 即可侧载到自己的 Apple TV，签名 7 天有效）
- Apple TV 与 Mac 在同一局域网（无线部署），或用 tvOS Simulator

## 三条路线怎么选

| 路线 | 本机要装 Xcode | 适用 |
| --- | --- | --- |
| A. Xcode 直接跑 / `install-to-appletv.sh` | 要（约 25GB） | 磁盘够，最省事最稳 |
| B. GitHub Actions 云编译 + Sideloadly | **不要** | 磁盘不够，或不想装 Xcode |
| C. AirPlay 投屏 | 不要 | 只想马上看，不介意没有 App 图标 |

---

## 路线 A：Xcode / 命令行脚本

**用 Xcode**：双击 `KVideoTV.xcodeproj` → Signing & Capabilities 里选 Team、
把 Bundle ID 从 `com.example.KVideoTV` 改成唯一的 → 顶部选好设备 → `Cmd + R`。

**用脚本**：

```bash
cd KVideoTV
./install-to-appletv.sh                 # 自动找已配对的电视（在线优先）
./install-to-appletv.sh <设备ID>        # 有多台电视时指定
TEAM_ID=XXXXXXXXXX ./install-to-appletv.sh
```

它会依次做：检查是否装了完整 Xcode → 检查 Bundle ID 是否还是 `com.example.*` →
从钥匙串找签名证书并取出 Team ID → 列出已配对的 Apple TV → 编译 Release →
通过局域网安装到电视。**7 天到期后重新跑这一条即可续签**，不用开 Xcode。

### 装到真机前的准备

1. **Xcode 登录 Apple ID**：`Cmd + ,` → Accounts → 左下 `+` → Apple ID。
   出现 **Personal Team** 就够了，不用买 99 美元的账号。
2. **电视打开配对开关**：设置 → 遥控器与设备 → **远程 App 与设备** → 打开。
   （注意：**tvOS 上没有「开发者模式」开关**，那是 iOS 的东西，别在电视里找。）
3. **无线配对**：Mac 上 Xcode → Window → Devices and Simulators → Devices，
   等电视出现在列表里，选中 → 电视上会显示 4 位码 → 填进 Xcode。
   配对后可右键勾 `Connect via network`，以后不用重配。
4. **首次打开被拦**：电视上提示「不受信任的开发者」→
   设置 → 通用 → 设备管理 → 选中你的 Apple ID → 信任。

---

## 路线 B：云编译 + Sideloadly（本机不装 Xcode）

思路：云端（GitHub Actions 的 macOS 机器）编译出**未签名**的 ipa，
本机用 Sideloadly 拿你自己的 Apple ID 给它签名，再无线装到 Apple TV。

### 先纠正一个常见误解：侧载 ≠ 免签名

Sideloadly 这类工具省掉的是「装 Xcode」，**不是「签名」**——
它照样要用你的 Apple ID 去申请证书，免费账号同样 7 天过期。
用别人共享的证书去签属于违反 Apple 开发者协议，这条路不走。

tvOS 上能用的侧载工具其实很少：

| 工具 | Apple TV | 说明 |
| --- | --- | --- |
| Sideloadly | ✅ | 无数据口的 Apple TV 4K 只能在 **macOS** 上无线侧载（Windows 需 USB 口） |
| AltStore | ❌ | 只支持 iOS / iPadOS |
| TrollStore | ❌ | 依赖 CoreTrust 漏洞，只覆盖很老的 tvOS |
| Apple Configurator | ⚠️ | 能无线装 ipa，但要求 ipa 已经签好名，绕不开证书 |

### 进度：已打通 ✅

- ✅ 代码已推送 → https://github.com/ruisen-ui/KVideoTV （public 仓库）
- ✅ 云端编译通过 → [Actions run 38008585972](https://github.com/ruisen-ui/KVideoTV/actions/runs/38008585972)
- ✅ 未签名 ipa 已生成 → Artifacts 名 `KVideoTV-unsigned-ipa`，约 0.12 MB，保留 30 天
- ⬜ 待你做：下载 ipa → Sideloadly 用自己 Apple ID 签名 → 装到 Apple TV

### 下载 ipa

打开 https://github.com/ruisen-ui/KVideoTV/actions → 进最新那次绿色的
`Build tvOS IPA (unsigned)` → 页面底部 **Artifacts** → 点 `KVideoTV-unsigned-ipa`
下载 zip，解压得到 `KVideoTV-unsigned.ipa`。

> GitHub 的 Artifacts **必须登录账号**才能下载（匿名请求返回 401）。
> 另外本机实测直连 github.com 网页会超时，**浏览器需要挂代理**（git over SSH 反而不需要）。

以后代码一改、推上去，Actions 就自动重新编译。想手动触发：
仓库 Actions 页面 → 左侧 `Build tvOS IPA (unsigned)` → Run workflow。

### 侧载到电视

1. 本机装 [Sideloadly](https://sideloadly.io)（几十 MB，**不需要 Xcode**）
2. 打开 Sideloadly → ipa 拖进去 → Apple ID 填自己的 → 设备选你的 Apple TV → Start
3. 电视上首次打开提示「不受信任的开发者」→ 设置 → 通用 → 设备管理 → 信任
4. 回 Sideloadly 打开 **Auto refresh**，Mac 在同一网络时会自动续签

**搜不到电视时**：先在电视上打开 设置 → 遥控器与设备 → 远程 App 与设备；
再把 Mac 上的代理（v2rayN / Clash Verge）关掉——它会吃掉 Bonjour/mDNS 发现。

**额度**：public 仓库的 Actions 免费不限量；private 仓库 macOS runner 消耗 10 倍倍率，
每月 2000 分钟免费额度 ≈ 200 分钟 macOS，编译这个小 app 每次两三分钟，够用。

---

## 常见问题

| 现象 | 原因 / 处理 |
| --- | --- |
| 编译报 `no such module 'WebKit'` | tvOS 没有 WebKit，属于平台限制；本工程已改为原生实现，不应再出现 |
| 搜索转很久才出结果 | 某个采集源慢或挂掉。把 `VideoSource.builtIn` 里不通的源注释掉；单请求超时已压到 8 秒 |
| 搜索没结果 | 换个片名或换成更通用的关键词；也可以先把源切到「非凡资源」单独试 |
| 详情页提示「这个源没有可直接播放的地址」 | 该源的 `vod_play_url` 为空，返回上一级换另一个来源的同一部片 |
| 点开播不了、报错里有地址 | 播放页结构变了或源需要防盗链 Referer。错误浮层会把原始地址显示出来，方便对照 |
| 真机运行提示签名错误 | Bundle ID 没改，或 Team 没选 |
| 电视在 Xcode 里不出现 | 关掉 Mac 上的代理 / VPN（会吃掉 Bonjour 发现）；确认同一 Wi-Fi |
| 过几天 App 打不开了 | 免费账号签的包 7 天过期，重跑一次安装即可续上 |
| 只能装几个 App | 免费账号最多同时 3 个自签 App |
| push 报 `Author identity unknown` | 没配 git 身份 |
| push 报 `src refspec main does not match any` | 还没有任何 commit（通常是身份报错导致 commit 没成） |
| push 报 `Permission denied (publickey)` | 公钥没加到 GitHub：`pbcopy < ~/.ssh/id_ed25519.pub` 后去 github.com/settings/keys 粘贴 |
| 报 `could not lock config file: File exists` | 家目录残留 `~/.gitconfig.lock`，删掉：`rm -f ~/.gitconfig.lock` |

---

## 已知的坑 / 注意事项

- **tvOS 没有 WebKit**：`import WebKit` 在 tvOS 上直接报 `no such module`。
  这是平台限制（Apple 官方从未给 tvOS 提供 WebKit.framework），任何「网页壳」思路在
  Apple TV 上都不成立，必须走原生。
- **tvOS 没有 `fullScreenCover`**：SwiftUI 的 `fullScreenCover` 在 tvOS 上标记为
  **unavailable**，写了会编译失败。本工程的播放页改用 `NavigationStack` + `NavigationPath`
  推入（播放数据 `Playing` 因此必须 `Hashable`），遥控器 **Menu 键会自动 pop 返回**，
  比模态更符合 Apple TV 习惯。
- **播放器用 SwiftUI 的 `VideoPlayer`**：不要自己用 `UIViewControllerRepresentable`
  去包 `AVPlayerViewController`——在 SwiftUI 视图树里嵌 UIKit 播放器不是官方推荐做法，
  容易出现遥控器焦点/控制条异常。`VideoPlayer` 在 tvOS 上内部就是系统那套播放器。
- **App Icon 有 actool 警告**：构建日志里会出现
  `The app icon set "AppIcon" has 3 unassigned children.`。这是 Xcode 新版对 tvOS
  AppIcon 槽位的规范差异，**不影响构建和安装**；若电视桌面显示成白图标，用 Xcode
  打开工程双击 `Assets.xcassets` 让它自动规范化一次即可。
- **海报和部分源是 http**：工程的 `Info.plist` 里已放开 ATS（`NSAllowsArbitraryLoads`），
  否则 iOS/tvOS 会直接拦掉明文 http 请求。全站 https 后可以删掉这段。
- **`HEAD` 请求会 502**：部分采集站的 m3u8 服务器不支持 HEAD，但 `GET` 正常。
  AVPlayer 发的是带 Range 的 GET，所以不受影响。
- **tag 里的 m3u8 是相对路径**：形如 `2000k/hls/mixed.m3u8`，
  AVPlayer 会相对 master playlist 自动补全，不用管。
- **部署目标**：工程设的是 tvOS 16.0。如果以后要上更花哨的界面特效，可以提到 17.0。

## 可选增强（按需加）

- **多播放组**：`vod_play_url` 里 `$$$` 分隔的是不同播放线路，目前只取第一组，
  可以做成线路切换。
- **收藏 / 观看记录**：存 `UserDefaults` 即可，纯本地。
- **Top Shelf**：需要 `brandassets`（App Icon & Top Shelf Image），
  目前用的是扁平图标，不影响安装运行。

# KVideoTV — KVideo 的 Apple TV (tvOS) 客户端

一个轻量的 tvOS WebView 壳，加载你的 KVideo 实例。视频播放交给系统播放器，
遥控器可以直接播放 / 暂停 / 拖进度条。

## 环境要求

- macOS（路线 A 还需要完整版 Xcode 15+；路线 B 不需要）
- Apple Developer 账号（免费 Apple ID 即可侧载到自己的 Apple TV，签名 7 天有效）
- Apple TV 与 Mac 在同一局域网（无线部署），或用 tvOS Simulator

## 使用

1. 双击打开 `KVideoTV.xcodeproj`（工程已配好，无需再手动建项目）
2. Xcode 左侧选中项目 → Signing & Capabilities：
   - Team 选你的 Apple ID（Personal Team 即可）
   - Bundle Identifier 改成唯一的，例如 `com.你的名字.KVideoTV`（默认 `com.example.KVideoTV` 会在真机上签名失败）
3. 顶部设备选择想跑的地方：tvOS Simulator，或下面「真机」章节配对好的 Apple TV
4. `Cmd + R` 运行

## 装到真机 Apple TV（无线部署）

Apple TV 4K 没有数据口，没有 USB 调试这回事，只能走网络配对。
另外 **tvOS 上不存在「开发者模式」开关**（那是 iOS 才有的），配对完成即可安装。

**0. 前置条件**

- Apple TV 第 4 代（HD）或更新，tvOS 16 及以上
- Mac 与 Apple TV 连同一个路由器（别用访客网络，会隔离设备）
- Mac 上装完整版 Xcode（App Store 搜索 Xcode），免费 Apple ID 足够

**1. Xcode 登录 Apple ID**

Xcode → Settings（`Cmd + ,`）→ Accounts → 左下 `+` → Apple ID → 登录。
列表里出现 **Personal Team** 就行，不需要 99 美元的开发者账号。

**2. 配置签名**

打开工程 → 左侧选中 `KVideoTV` 项目 → TARGETS: KVideoTV → Signing & Capabilities：

- 勾选 Automatically manage signing
- Team 选你的 Personal Team
- Bundle Identifier 换个唯一的，例如 `cc.cd.oott.KVideoTV`（用自己域名的反写最省事）

**3. 在电视上打开配对开关**

Apple TV：设置 → 遥控器与设备 → 远程 App 与设备 → 打开

**4. 无线配对**

Mac：Xcode → Window → Devices and Simulators → Devices 标签页。
电视上那个界面等一会儿会列出你的 Mac，选中它 → 电视屏幕出现 4 位配对码 → 填进 Xcode。
配对成功后 Apple TV 会出现在左侧设备列表，第一次可能显示
「Preparing device for development」，等几分钟。可以在设备上右键勾选
`Connect via network`，之后不用重配。

**5. 运行**

Xcode 顶部设备选择你的 Apple TV → `Cmd + R`。
装好后在电视上首次打开会提示「不受信任的开发者」，去：

设置 → 通用 → 设备管理（部分版本叫「管理设备」）→ 选中你的 Apple ID → 信任

然后再打开 App 即可。

**排错**

| 现象 | 处理 |
| --- | --- |
| 电视在 Xcode 里不出现 | 先关掉 Mac 上的代理 / VPN（v2rayN、Clash Verge 的 TUN 或系统代理会吃掉 Bonjour/mDNS 发现）；确认同一 Wi-Fi；重启 Xcode 与 Apple TV |
| 报 Apple TV is not available | tvOS 版本低于工程部署目标 16.0，升级电视或把 `TVOS_DEPLOYMENT_TARGET` 调低 |
| 提示 Failed to register bundle identifier | Bundle ID 被占用，换一个 |
| 过几天 App 打不开了 | 免费账号签的包有效期 7 天，回 Xcode 再 `Cmd + R` 一次即可续上 |
| 只能装几个 App | 免费账号最多同时 3 个自签 App |

**不想折腾真机**：Xcode 顶部直接选 Apple TV 4K Simulator，`Cmd + R` 就能看效果，不需要配对也不需要签名。

## 路线 A：命令行一键构建 + 安装

不想每次都开 Xcode 点 Run 的话，用工程根目录的脚本：

```bash
cd KVideoTV
./install-to-appletv.sh                 # 自动找已配对的电视（在线优先）
./install-to-appletv.sh <设备ID>        # 有多台电视时指定
TEAM_ID=XXXXXXXXXX ./install-to-appletv.sh
```

它会依次做：检查是否装了完整 Xcode → 检查 Bundle ID 是否还是 `com.example.*` →
从钥匙串找签名证书并取出 Team ID → 列出已配对的 Apple TV → 编译 Release →
通过局域网安装到电视。

**7 天到期后重新跑这一条命令即可续签**，不需要打开 Xcode。

首次运行前必须完成：Xcode 已登录 Apple ID、Bundle ID 已改、电视已与 Xcode 配对。
缺哪一步脚本会直接告诉你。

## 三条路线怎么选

| 路线 | 本机要装 Xcode | 适用 |
| --- | --- | --- |
| A. Xcode 直接跑 / `install-to-appletv.sh` | 要（约 25GB） | 磁盘够，最省事最稳 |
| B. GitHub Actions 云编译 + Sideloadly | **不要** | 磁盘不够，或不想装 Xcode |
| C. AirPlay 投屏 | 不要 | 只想马上看，不介意没有 App 图标 |

## 路线 B：云编译 + Sideloadly（本机不装 Xcode）

思路：云端（GitHub Actions 的 macOS 机器）编译出**未签名**的 ipa，
本机用 Sideloadly 拿你自己的 Apple ID 给它签名，再无线装到 Apple TV。

### 先纠正一个常见误解：侧载 ≠ 免签名

Sideloadly 这类工具省掉的是「装 Xcode」，**不是「签名」**——
它照样要用你的 Apple ID 去申请证书，免费账号同样 7 天过期。
用别人共享的证书去签属于违反 Apple 开发者协议，这条路不走。

另外 tvOS 上能用的侧载工具其实很少：

| 工具 | Apple TV | 说明 |
| --- | --- | --- |
| Sideloadly | ✅ | 无数据口的 Apple TV 4K 只能在 **macOS** 上无线侧载（Windows 侧载必须有 USB 口） |
| AltStore | ❌ | 只支持 iOS / iPadOS |
| TrollStore | ❌ | 依赖 CoreTrust 漏洞，只覆盖很老的 tvOS 版本，现在对不上 |
| Apple Configurator | ⚠️ | 能无线装 ipa，但要求 ipa **已经签好名**，绕不开证书 |

### 步骤

```bash
cd /Users/xyyq/WorkBuddy/2026-10-09-22-00-35/KVideoTV
git init && git add . && git commit -m "KVideoTV: tvOS WebView wrapper"
gh repo create KVideoTV --private --source=. --push
```

没有 `gh` 就在 GitHub 网页上建个仓库，然后：

```bash
git remote add origin git@github.com:<你的用户名>/KVideoTV.git
git push -u origin main
```

（把 `KVideoTV` 这个目录本身当仓库根推上去，`.github/workflows/` 和 `.gitignore` 都已经放在里面了。）

1. 仓库 Actions 页面 → 左侧 `Build tvOS IPA (unsigned)` → Run workflow
2. 跑完（约 2-3 分钟）在该次运行的 Artifacts 里下载 `KVideoTV-unsigned-ipa`
3. 本机装 [Sideloadly](https://sideloadly.io)（几十 MB，**不需要 Xcode**）
4. 打开 Sideloadly → 把 ipa 拖进去 → Apple ID 填自己的 → 设备选你的 Apple TV → Start
5. 电视上首次打开提示「不受信任的开发者」→ 设置 → 通用 → 设备管理 → 信任
6. 回 Sideloadly 打开 **Auto refresh**，Mac 在同一网络时会自动帮你续签，不用手动重装

**搜不到电视时**：先在电视上打开 设置 → 遥控器与设备 → 远程 App 与设备；
再把 Mac 上的代理（v2rayN / Clash Verge）关掉——它会吃掉 Bonjour/mDNS 发现。

**额度**：public 仓库的 Actions 免费不限量；private 仓库 macOS runner 消耗 10 倍倍率，
每月 2000 分钟免费额度 = 大约 200 分钟 macOS，编译这个小 app 每次两三分钟，够用。



改 KVideo 地址：`KVideoTV/ContentView.swift` 顶部

```swift
private let kvideoURL = "https://video.oott.cc.cd/"
```

## 已内置的行为

- 自动播放已放开（`mediaTypesRequiringUserActionForPlayback = []`），tvOS 15.4+ 默认会拦截 autoplay
- ATS 已放开（`NSAllowsArbitraryLoads`），http 媒体源 / CDN 证书链不标准也能播；全 https 可自行删掉
- Cookie / localStorage 默认持久化，登录一次后重启应用仍保持登录
- 加载失败会显示错误浮层 + 「重新加载」按钮（遥控器可聚焦）
- 顶部 URL 显示在错误浮层里，方便排查

## 常见问题

| 现象 | 原因 / 处理 |
| --- | --- |
| 真机运行提示签名错误 | Bundle ID 没改，或 Team 没选 |
| TV 上首次启动提示「不受信任的开发者」 | TV 设置 → 通用 → VPN 与设备管理 → 信任你的开发者证书 |
| 视频黑屏、只有声音或直接失败 | 播放器走 MSE（fMP4 分片）时需要 **tvOS 17.1+** 的 ManagedMediaSource；部署目标建议提到 17.4（改 `TVOS_DEPLOYMENT_TARGET`） |
| 页面布局不对（要求桌面版） | 打开 `ContentView.swift` 里 `customUserAgent` 那段注释，伪装成桌面 Safari |
| 想强制刷新页面 | 退出 App 重新进；或临时把 URL 加个 `?t=` 参数 |

## 可选增强（按需加）

- **Cookie 登录**：如果 TV 上没法输密码，可在别的设备登录后把 cookie 注入
  （`WKUserScript` + `HTTPCookie`，在 `webView.load` 之前设置 `configuration.userContentController`）
- **自动重试**：在 `didFailProvisionalNavigation` 里延时 3 秒自动 `load()`
- **Top Shelf**：需要 `brandassets`（App Icon & Top Shelf Image），目前用的是扁平图标，不影响安装运行

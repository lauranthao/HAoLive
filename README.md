# HAo Live

HAo Live — 直播应用，参照 Pure Live 的**功能**，界面与实现均为 HAo 自己所写。

- 参照：[Pure Live](https://github.com/wzgrx/PureLive)（AGPL-3.0；2026-11-28 起以 wzgrx 仓库为准，liuchuancong/pure_live 3.x 线作废）
- 许可说明：只学习它的功能设计（平台适配、画质线路、弹幕、关注/历史/多画面），**不复制代码、不复制界面**。本仓库代码为 HAo 原创；若未来引用 Pure Live 代码，须按 AGPL-3.0 开源。
- 平台：iOS 17+，Swift 6，SwiftUI，mpv 单一播放器（MPVKit 1.1.0-n9.0.2，FLV 走 mpv session 内拼接；无系统播放器兜底、无内核切换）
- 无强制登录；收藏与历史只存本机
- 无启动动画：进应用直接到主界面
- 当前版本：0.1.0 build 19（2026-11-28）

## 版本历史

- **0.1.0 build 19（2026-11-28）：** ① 全屏退出黑屏修了：内联和全屏共用一个视频容器，全屏一关容器就没了父视图，画面黑掉——现在每个挂载点用自己的容器壳，进出全屏重新挂接；② 抖音看不了修了：抖音房间走 web_rid 时取流用的是 enter 接口的地址，实测那条地址在手机上打不开——现在有内部房间号时改取 reflow 接口的流（同一房间实测 FLV/HLS 都通，15 万人在线）；③ 斗鱼弹幕修了：旧的 TCP 弹幕服务器（openbarrage:8601）已经死了，登录就被踢——改走 Pure Live 的 WebSocket 弹幕（danmuproxy.douyu.com:8506，心跳改 mrkl）；④ 工具箱修了：粘贴抖音分享文案能直接打开（从文案里抽链接、跟短链跳转到 reflow 地址），复制直链也一样走这条解析；⑤ 分区和热门的站点换成各站自己的 logo（34 个站的原版图标打进包里，热门 chips 和分区分栏都显示）；⑥ 关于页做成 Music 那种：大图标+版本/构建号/开发者+更新检查+ GitHub 链接+免责声明，Pure Live 致谢链接改成 wzgrx 的仓库；⑦ 显示数据加了开关（设置 → 播放器 → 显示数据），关掉就不显示画面上的诊断 tag。

- **0.1.0 build 18（2026-11-28）：** 丢帧修了：build 17 的 tag 终于把数看全了——`mpv (GL) · videotoolbox · 自动安全 · 缓5s · ↓0.7MB/s · 丢帧527`。解码是硬解、缓冲是满的、下载也跟得上，丢的全是渲染器这边掉的帧（mpv 的 frame-drop-count）。根因找到：渲染驱动里有个合并开关，有新帧来的时候如果上一帧还在等播出时间，就把这次更新直接丢掉——那几帧永远没人渲，mpv 就记成丢帧。Pure Live（media_kit）那边是从不丢更新的，每个更新都排队渲，每一帧都等到自己的播出时间再出。这一版把那个合并开关拆了，照它的做法来。

- **0.1.0 build 17（2026-11-28）：** tag 的问题修了：① 它之前藏在播放器控制条里，控制条一收 tag 就没了，还被截成 140pt 宽，后面的数字全看不见——现在直接贴在画面上一直显示，竖屏全屏都有，全文不截断；② tag 里加上硬件解码的开关状态（自动安全/自动/关闭），一眼就能分清“设置关了硬解”还是“播放器没走上硬解”；③ 修了个 tag 显示旧的 bug：解码器变化（比如从软解切到硬解）以前不刷新 tag，播着播着数字可能是旧的，现在解码器一变就刷新。chen 已确认设置是“自动安全”，所以 build 16 截图上的“软解”要么是 tag 显示旧了，要么是播放器真没走上硬解——这一版的 tag 能直接看出来。

- **0.1.0 build 16（2026-11-28）：** 按 Pure Live 的送屏方式改（chen 让看 Pure Live 的写法，逐项对完）：media_kit iOS 不排队显示——纹理只留最新一帧，Flutter 引擎每个 vsync 只取最新一帧，中间的帧无声跳过；HAoLive 之前是每渲一帧就包上 PTS=now 全排进显示层，网络一抖追赶出几帧就得连放几帧再顿一下。这一版 enqueue 前先 flush 掉还没显示的旧帧，只留最新一帧，同样“最新帧胜出”。同时把 build 14 自己改的缓冲（12 秒/64MB）改回 Pure Live 的 6 秒/32MB，不留自己的改法。tag 上的下载速度和丢帧数保留（那是 Pure Live 自己的诊断）。

- **0.1.0 build 15（2026-11-28）：** 按 Pure Live 的写法，把它自己的卡顿诊断（buffering_probe.dart / playback_stats.dart）做到 tag 上：下载速度（cache-speed，蓝光 30M 需要 3.75 MB/s 持续）和丢帧数（frame-drop-count，渲染丢的；没有时看 decoder-frame-drop-count，解码丢的）。tag 刷新最多一秒一次，等缓冲翻转立刻显示。这一版只加诊断，不改播放——下次卡，那行字直接写明是网跟不上还是帧在丢。

- **0.1.0 build 14（2026-11-28）：** build 13 没解决卡——chen 真机截图证明 tag 已是 `mpv (GL) · videotoolbox`，渲染和硬解都没问题，方向找错了。这一版改查缓冲那层：播放器 tag 加上缓冲状态（等缓冲时打头显示，平时显示缓冲秒数）；mpv 缓冲从 wzgrx 的 6 秒/32MB 加到 12 秒/64MB（蓝光 30M 下 6 秒只够 22.5MB，网速一抖就断流）。mpv 其他选项仍与 wzgrx 一致（对照 mpv_options.dart 核过，media_kit 不另加缓冲设置）。

- **0.1.0 build 13（2026-11-28）：** 卡的根因修了——`MpvGLRenderer.createRenderContext` 建渲染上下文前没把 EAGL context 设成 current，`mpv_render_context_create` 每次都失败，全退到软渲染；照 media_kit 的写法补上（创建与释放都设 current），不走 Metal（libmpv 没有 Metal 渲染 API）。热门/全部改轮询合并（之前平台顺序合并，前五家 248 间房盖住了后面的平台；轮询后前 40 间覆盖 26 个平台，总数 867 不变）。抖音修了——enter 取数少写了一层 `data`（`json["data"][0]` 恒 null，主路由全死），改 `data.data[0]`，离线主播取 `data.user`、无 status 时看 `room_status`、19 位 id 分流改纯数字 17+、搜索加分区兜底（匿名搜被 2483 拒）、播放 UA 改回 Chrome/134。

- **0.1.0 build 12（2026-11-28）：** 14 个平台逐行对着 PureLive 重审取流与图片（Bigo 补 376 字节 HLS 解掩码中继、LiveMe 列表房可播、CHZZK/17LIVE/JD/Bigo 播放仍被服务端挡、YouTube/TikTok 大陆打不开是网络限制）；图片 Referer 全站补齐（之前除五家外全拿 Bilibili Referer）；收藏页隐式 VStack 居中 bug 修掉（状态 chips 行与状态文本回左对齐）；卡的根因查完——播放器画面上直接显示走 GL 还是 SW + 实际解码器（mpv (GL) · videotoolbox / 软解），mpv 选项再对齐（demuxer-lavf-o、scaler/seek 默认、每开播设 hwdec/UA/headers）。
- **0.1.0 build 11（2026-11-28）：** 播放完全按 wzgrx/PureLive 对齐（删 HLS→系统播放器分流，AVPlayerEngine 删除，mpv 单引擎；FLV 租约拼接不断流；斗鱼按实际档位标画质、顺序请求；默认清晰度原画）；34 个平台全接进来（除 IPTV）；全 app 视觉对齐（unslop + impeccable 走查）；交互学 HAoMusic（Toast、搜索历史、按压态）；虎牙 http 封面升级 https、封面加载重试 + 磁盘缓存。
- **0.1.0 build 10（2026-11-28）：** mpv GPU 渲染路径（OpenGL FBO 进显示层），抖音取流修复，斗鱼固定 did + 租约刷新。
- **0.1.0 build 9 及更早：** 见 git 历史。

## v1 骨架（0.1.0）范围

- 底栏五页签：收藏（关注房间网格）、热门（跨平台推荐）、分区（按平台+分类浏览）、搜索、历史（录制已删，改为历史）
- 直播间：竖屏进入、16:9 播放器、画质+线路切换、弹幕浮层+设置、收藏按钮、进房记历史
- 跨平台搜索：一次搜遍多站，按平台顺序合并、按主播+标题去重
- 本地收藏与观看历史（UserDefaults）
- 设置：主题、播放器、弹幕、缓存、关于
- 34 站真实适配器已接通（见下节；IPTV 未加，是一条独立的腿）

## 真实平台适配器（0.1.0 build 13）

34 站全部接通真实协议（匿名，无登录），顺序按 wzgrx 注册表：Bilibili、斗鱼、虎牙、抖音、快手、网易CC、Twitch、SOOP、YY、AcFun、Picarto、TwitCasting、Missevan、Inke、Kilakila、小红书（仅链接）、niconico、微博、SHOWROOM、CHZZK、Kick、LiveMe、TikTok（仅链接）、YouTube（仅链接）、Bigo、PandaLive、FC2、Steam、JD、Kugou、百度（仅详情）、SixRoom、LOOK、17LIVE。

首批五站详情：

| 平台 | 列表/分类/详情 | 取流 | 弹幕 |
|---|---|---|---|
| Bilibili | ✅ 全部验证 | ✅ HLS，匿名降档（要 10000 得 250 超清），只报服务器实际给的档位 | ✅ WS + zlib 解压，实测帧解析 |
| Douyu | ✅ 开放 API（列表/分类/详情） | ⚠️ getH5Play 从本 VM 恒返回 -9（时间戳错误），需国内网络设备确认 | ✅ TCP STT 协议（fixture 验证；本 VM 出站 TCP 被拦） |
| Huya | ✅ 列表/分类/房间页 | ✅ HLS 多 CDN 线路（阿里/腾讯/…），自适应码率 | ❌ 未实现（WS + TAF/JCE 二进制协议，需实采帧） |
| Douyin | ✅ 房间页（分类+详情）；推荐/搜索走 webcast API，本 VM 被拒 | ✅ HLS（原画/超清/高清/标清） | ✅ WS + protobuf（fixture 验证；需真机联调） |
| Kuaishou | ⚠️ 页面结构已解析；本 VM 被限流（"请求过快"），列表与流均为空 | ⚠️ 解析已写（playUrls / hlsPlayUrl），需国内网络确认 | ❌ 未实现（protobuf 布局未验证，需实采帧） |

直播间已接真实弹幕流：有真实通道的平台走 `danmakuStream`，没有的才回落到示例弹幕（仅 STUB 时代的占位）；离房时弹幕任务取消（修了原来不取消的泄漏）。

播放规则沿用 Pure Live 的“实际有效画质”：只提供平台实际返回的档位与线路，不虚构画质；FLV/RTMP 一律不提供（AVPlayer 播不了）。

### 验证（2026-11-26，Linux VM）

- `swiftc -parse`：40 个 Swift 文件 0 错误（无 Xcode，仅语法级）
- harness `~/workspace/.tmp/haolive-adapters-harness/`：**103/103 通过**（87 个 fixture 解析/编解码断言 + 16 个真实网络断言；fixture 为本机实采的请求/响应）
- harness 修出的真 bug：Douyu STT 分帧器在 `removeFirst` 后用 0 基 `subdata` 越界崩溃（Data 切片下标不从 0 起）；JSON 数字 0/1 在 Linux 上被 `as Bool` 误判成布尔（live_status、error 码、分类 id 全错）；Bilibili 列表项无 `live_status` 字段，isLive 应默认 true；抖音房间页嵌了两份 roomStore（空的初始 store + 真实的），须取有数据的那份；空字符串会挡住 `??`  fallback（如封面 user_cover 为空时取不到 keyframe）

## 结构

```
Sources/HAoLive/
  App/            入口 + 底栏导航（无启动动画）
  Core/
    Models/       LiveRoom / LivePlatform / LiveCategory / DanmakuItem / PlayQuality
    Sites/        LiveSite 协议 + 五站真实适配器 + 注册表 + 合并搜索
    Network/      JSONValue（宽容解析）/ HTTPClient / ZlibInflate / BinaryCoding（protobuf 读器）
    Danmaku/      传输层（WS/TCP）+ Bilibili/Douyu/Douyin 弹幕编解码
    Player/       AVPlayer 播放服务 + 弹幕过滤引擎
    Storage/      收藏 / 历史 / 设置（本机）
  Features/       收藏 / 热门 / 分区 / 录制 / 直播间 / 搜索 / 设置
  DesignSystem/   HAo 自己的设计 token
  Resources/      Info.plist + Assets（含 chen 选定的黑方块图标）
HAoLive.xcodeproj/  Xcode 工程（生成脚本见下方）
```

## HAo 自己的设计（与 Pure Live 的不同）

- 界面：大标题 + 16:9 卡片 + 红色 LIVE 角标 + 平台色小徽标；分区页是平台横轨 + 分类 chips
- 合并搜索：多站并行搜、平台顺序合并、去重（Pure Live 的搜索也是聚合，但合并规则与呈现是我们自己的）
- 弹幕浮层：底部气泡叠加、可调字号/透明度、关键词屏蔽
- 播放规则：画质线路只报平台实际提供的档位，不虚构；进房自动记历史

## 构建

需要 macOS + Xcode 26+：

```
open HAoLive.xcodeproj
```

首次构建需在 Xcode 里选自己的 Team 签名。本机 Linux VM 无 Xcode，无法验证 Xcode 构建（见“未验证”）。

工程文件手写维护，**不要重跑 `~/workspace/.tmp/gen_haolive_pbx.py`**（生成器没有 SPM 支持，重跑会丢掉手加的 MPVKit 引用）。

## 未验证（build 13，待真机确认）

- 播放器画面上的渲染标记是否变成 `mpv (GL) · videotoolbox`、原画还卡不卡；抖音任意一间房能不能播（enter 修完的根因确认）；热门/全部第一屏是不是各平台都有
- 斗鱼画面；抖音画面；GL 渲染比例/填充；虎牙 125s 租约断线瞬间的拼接切换
- 新平台在设备上的播放（CHZZK、17LIVE、JD 详情、Bigo token、niconico/FC2 会话存活期、Twitch integrity）
- 新平台弹幕（Missevan/AcFun/Kugou/JD/LOOK 未做；其余 WS join 未联调）；抖音 WebP 解码；快手分区图标
- 已知缺口（不是漏报）：虎牙原生 WUP token 未移植；LiveMe 直连房取流失败（列表房可播）；YouTube/TikTok 大陆基本打不开；IPTV 未加；无代理设置

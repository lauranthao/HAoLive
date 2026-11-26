# HAo Live

HAo Live — 直播应用，参照 Pure Live 的**功能**，界面与实现均为 HAo 自己所写。

- 参照：[Pure Live](https://github.com/liuchuancong/pure_live)（AGPL-3.0）
- 许可说明：只学习它的功能设计（平台适配、画质线路、弹幕、关注/历史/多画面），**不复制代码、不复制界面**。本仓库代码为 HAo 原创；若未来引用 Pure Live 代码，须按 AGPL-3.0 开源。
- 平台：iOS 17+，Swift 6，SwiftUI，原生 AVPlayer（MPV/IJK 以后按需接入）
- 无强制登录；收藏与历史只存本机
- 无启动动画：进应用直接到主界面

## v1 骨架（0.1.0）范围

- 底栏四页签：收藏（关注房间网格）、热门（跨平台推荐）、分区（按平台+分类浏览）、录制中心（占位壳）
- 直播间：竖屏进入、16:9 播放器、画质+线路切换、弹幕浮层+设置、收藏按钮、进房记历史
- 跨平台搜索：一次搜遍五站，按平台顺序合并、按主播+标题去重
- 本地收藏与观看历史（UserDefaults）
- 设置：主题、播放器、弹幕、缓存、关于
- 五站适配器均为 **STUB**（无真实网络请求），下一腿接真实平台

## 结构

```
Sources/HAoLive/
  App/            入口 + 底栏导航（无启动动画）
  Core/
    Models/       LiveRoom / LivePlatform / LiveCategory / DanmakuItem / PlayQuality
    Sites/        LiveSite 协议 + 五站 STUB + 注册表 + 合并搜索
    Player/       AVPlayer 播放服务 + 弹幕过滤引擎
    Storage/      收藏 / 历史 / 设置（本机）
  Features/       收藏 / 热门 / 分区 / 录制 / 直播间 / 搜索 / 设置
  DesignSystem/   HAo 自己的设计 token
  Resources/      Info.plist + Assets（含 chen 选定的黑方块图标）
HAoLive.xcodeproj/  Xcode 工程（生成脚本见下方）
```

## HAo 自己的设计（与 Pure Live 的不同）

- 界面：大标题 + 16:9 卡片 + 红色 LIVE 角标 + 平台色小徽标；分区页是平台横轨 + 分类 chips
- 合并搜索：五站并行搜、平台顺序合并、去重（Pure Live 的搜索也是聚合，但合并规则与呈现是我们自己的）
- 弹幕浮层：底部气泡叠加、可调字号/透明度、关键词屏蔽
- 播放规则：画质线路只报平台实际提供的档位，不虚构；进房自动记历史

## 构建

需要 macOS + Xcode 26+：

```
open HAoLive.xcodeproj
```

首次构建需在 Xcode 里选自己的 Team 签名。本机 Linux VM 无 Xcode，无法验证 Xcode 构建（见“未验证”）。

工程文件由 `~/workspace/.tmp/gen_haolive_pbx.py` 生成（确定性 ID，改文件清单后重跑）。

## 未验证

- Xcode 构建未验（本机无 Xcode，需 Mac/CI 跑 `xcodebuild`）
- 五站真实取流、真实弹幕通道未验（STUB，未接网）
- 真机播放未验

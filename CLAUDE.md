# CLAUDE.md

本文件为在此仓库工作的 AI/开发者提供指引。

## 项目与兼容性边界

OldPlayer 是面向 iOS 6.0–9.x、32 位 armv7 设备的远程媒体播放器。代码使用 ARC 的 Objective-C 和 Theos；编译目标固定为 `iphone:clang:9.3:6.0`。不要引入较新 iOS API：

- 网络层只用 `NSURLConnection` / `NSStream` / POSIX socket，不能使用 `NSURLSession`。
- UI 用纯代码和手动 `frame` / `UITableView`；不要引入 Storyboard、XIB、Auto Layout 或 `UICollectionView`。
- 视频播放使用 `MPMoviePlayerViewController`，不可改为 `AVPlayerViewController`。
- 后台音频使用 `AVAudioSessionCategoryPlayback`、`MPNowPlayingInfoCenter` 与 `remoteControlReceivedWithEvent:`；不要使用 `MPRemoteCommandCenter`。
- 9.3 SDK 会为 iOS 6 不存在的 re-export 生成错误 dyld 绑定。CI 中的 `tools/fix_ios6_bindings.py` 和其后的 `ldid -S` 是启动兼容性所必需的，不能删除或跳过。
- 产物不得携带 entitlements；侧载工具需要能以个人证书重新签名。

## 构建与验证

本仓库没有本地测试框架、lint 任务。Windows 开发环境只编辑源码；**不要在本地执行 `make`**。唯一受支持的构建验证是在 GitHub Actions 的 **OldPlayer Build** workflow 中完成。

## 架构

- `Sources/AppDelegate.m` 创建窗口与根导航，并配置 `AVAudioSessionCategoryPlayback` 后台音频。
- `Sources/Models/` 领域与持久化模型：`OPServer`（协议枚举 + 凭据）、`OPServerStore`（NSUserDefaults 持久化）、`OPFileItem`（远程文件项）。
- `Sources/Services/` 协议客户端：
  - `OPFileSource` 抽象 + `OPFileSourceFactory` 工厂。
  - `OPWebDAVClient` / `OPWebDAVParser`：NSURLConnection PROPFIND/GET，Basic/Digest，自签名信任。
  - `OPSocket`（POSIX TCP）+ `OPFTPClient`（被动模式、MLSD/LIST 解析）。
  - `OPNTLM`（NTLMv2）+ `OPSMBSession`（SMB2.0.2/2.1 协议）+ `OPSMBClient`。
  - `OPMediaCache`：下载到 `Caches/OPMediaCache`。
- `Sources/Controllers/` UIKit 展示与导航：服务器列表、增删改表单、目录浏览、下载进度浮层。
- 播放优先流式：WebDAV 用 `streamURLForItem:` 直链；FTP/SMB 走 `OPLocalHTTPProxy`（127.0.0.1，把 Range 翻译成 `OPFTPSeekStream` 的 REST+RETR / `OPSMBSeekStream` 的偏移 READ）。首帧前流失败则回退到“先下载后播放”（`OPTransferViewController` + `OPMediaCache` + `MPMoviePlayerViewController`）。
- 软解（`Sources/SoftDecode/`）：`OPFileItem.isSoftDecodedFormat` 按扩展名分流；`OPSoftDecoder` 用 FFmpeg（CI 由 `tools/build_ffmpeg.sh` 编出 armv7 decode-only 静态库，经 `FFMPEG_PREFIX`/`HAS_FFMPEG` 接入）解码，视频 YUV420P 经 `OPSoftVideoView`（OpenGL ES 2.0）显示，音频重采样到 44.1k 立体声 S16 经 AudioQueue（音频时钟主同步）播放；UI 是 `OPSoftPlayerViewController`。软播同样吃 HTTP 直链/本地代理做流式 seek，HTTPS 先下载后播。
- `OPFTPConnection` 是 FTP 控制连接的共享实现（`OPFTPClient` 与流共用）；`OPSMBSession` 另暴露 `openFile` / `readFileId` / `closeFileId` 给流使用。

## 打包链路

`.github/workflows/build.yml` 是构建行为的权威来源。它先修补 Theos SDK stub，再构建 armv7 app，对二进制运行 `tools/fix_ios6_bindings.py` 并重签，然后组装 IPA。更改构建/SDK/打包文件时须保留这些顺序依赖。

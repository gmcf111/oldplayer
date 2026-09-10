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

- `Sources/AppDelegate.m` 创建窗口与根导航。
- `Sources/Models/` 领域与持久化模型（服务器配置、远程文件项）。
- `Sources/Services/` 协议客户端：`OPFileSource` 抽象 + WebDAV/FTP/SMB 实现 + 下载管理。
- `Sources/Controllers/` UIKit 展示与导航（服务器列表、浏览、播放）。
- `Sources/Views/` 可复用单元与主题。

## 打包链路

`.github/workflows/build.yml` 是构建行为的权威来源。它先修补 Theos SDK stub，再构建 armv7 app，对二进制运行 `tools/fix_ios6_bindings.py` 并重签，然后组装 IPA。更改构建/SDK/打包文件时须保留这些顺序依赖。

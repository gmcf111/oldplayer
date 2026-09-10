# OldPlayer — iOS 6-9 32位远程媒体播放器 (armv7)

> **目标**: 在 iOS 6.0 ~ 9.x 的 32 位设备 (iPhone 4S/5, iPad 2/3) 上运行的远程媒体播放器。内置 WebDAV / FTP / SMB 协议，可直接浏览并播放远程服务器上的音视频文件。纯 Objective-C + Theos 构建，全部编译在 GitHub Actions 完成，无需 macOS。

## 构建

所有编译在 **ubuntu-latest** 上完成，`workflow_dispatch` 手动触发。

```bash
gh workflow run build.yml
gh run list --workflow build.yml
gh run watch <run-id>
```

构建产物 Artifact 名为 `OldPlayer-<sha>-armv7`，含 `.ipa` 与 `.deb`，保留 14 天。IPA 可用 AltStore / Sideloadly / 爱思助手 侧载（iOS 6-9, armv7）。

## 许可证

源代码采用 **GNU GPL v3**（见根目录 `LICENSE`）。

`iPhoneOS SDK` 归 Apple 所有；CI 构建时动态获取的第三方 SDK/工具链归其原作者所有。

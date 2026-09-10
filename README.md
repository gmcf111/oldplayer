# OldPlayer — iOS 6–9 32位远程媒体播放器 (armv7)

> **目标**：在 iOS 6.0 ~ 9.x 的 32 位设备（iPhone 4S/5、iPad 2/3 等）上运行的远程媒体播放器。内置 **WebDAV / FTP / SMB** 三种协议，可浏览远程服务器目录并直接播放其中的音频与视频。纯 Objective-C + Theos 构建，**全部编译在 GitHub Actions 云端完成**，开发机无需 macOS。

## 功能

- **多协议服务器管理**：保存多个服务器配置（协议、主机、端口、用户名/密码、起始路径），全部持久化到 `NSUserDefaults`。
- **WebDAV**：`PROPFIND`（Depth:1）列目录 + `GET` 下载；支持 HTTP Basic / Digest 认证、自签名 HTTPS。
- **FTP**：自实现控制/数据连接（`USER/PASS/TYPE I/CWD/PASV/EPSV/LIST/MLSD/RETR/SIZE`），支持 MLSD、Unix `ls -l` 与 DOS 三种列目录格式。
- **SMB2**（SMB 2.0.2 / 2.1）：自实现 `NEGOTIATE / SESSION_SETUP / TREE_CONNECT / CREATE / QUERY_DIRECTORY / READ / CLOSE`，使用 **NTLMv2** 认证（MD4 + HMAC-MD5，CommonCrypto）。
- **目录浏览**：原生 `UITableViewController` + `UITableViewCell`，逐级 push 导航，支持下拉刷新与删除服务器。
- **真流式播放 + 随意 seek**：WebDAV 直接把 HTTP(S) URL 交给 `MPMoviePlayerViewController`；FTP/SMB 走 App 内 `127.0.0.1` 本地代理，把播放器的 `Range` 请求翻译成 FTP `REST+RETR` / SMB 按偏移 `READ`，即点即播、进度条可拖。流失败（认证、Range、协议问题）且尚未播出首帧时自动回退到下载后播放。
- **软解（FFmpeg）**：系统播不了的 mkv/avi/rmvb/rm/flv/wmv/asf/mpg/ts/vob/webm/ogg/flac/ape/wv/tta/dts/ac3/wma 等走 CPU 软解——FFmpeg 解复用解码，视频经 OpenGL ES 2.0 的 YUV shader 显示，音频经 AudioQueue 播放，同样支持流式 seek（复用本地代理/HTTP 直链），HTTPS 与无 TLS 的情况自动先下载后软播。字幕轨暂不渲染。
- **下载后播放（回退）**：流不可用时把远程媒体下载到本地缓存再播放；下载过程使用原生 `UIProgressView` 显示进度并可取消。
- **原生控件**：全部界面使用系统控件（`UINavigationController` / `UITableViewController` / `UIAlertView` / `UISegmentedControl` / `UISwitch` / `UIBarButtonItem` 等），手动 `frame` 布局，无 Storyboard/XIB/AutoLayout/自绘控件。

## 目录结构

```
oldplayer/
├── Makefile                      # Theos application, ARCHS=armv7, TARGET=iphone:clang:9.3:6.0
├── control                       # Debian control (越狱包元信息)
├── Resources/
│   ├── Info.plist                # MinimumOSVersion 6.0, CFBundleIconFiles, UIBackgroundModes audio
│   └── icon.svg                  # 图标源文件（蓝底白色播放三角），CI 渲染为各尺寸 PNG
├── tools/
│   ├── fix_ios6_bindings.py      # Mach-O bind 表修补（iOS 6 dyld 符号归属）
│   ├── patch_sdk_tbd.py          # 修补 theos/sdks 的 .tbd 导出缺口
│   └── gen_icons.py              # icon.svg -> 各尺寸 PNG (Pillow)
├── Sources/
│   ├── main.m                    # 全局异常处理器 + UIApplicationMain
│   ├── AppDelegate.h/m           # UIWindow + 根导航，配置后台音频
│   ├── Constants.h               # NSUserDefaults keys / 通知名
│   ├── Models/
│   │   ├── OPServer.h/m          # 服务器配置（协议枚举 + 持久化字典）
│   │   ├── OPServerStore.h/m     # 服务器列表持久化（NSUserDefaults）
│   │   └── OPFileItem.h/m        # 远程文件项（名称/路径/目录/大小/时间）
│   ├── Services/
│   │   ├── OPFileSource.h        # 协议抽象：列目录 / 下载 / 取消
│   │   ├── OPFileSourceFactory.h/m
│   │   ├── OPHTTPTask.h/m        # NSURLConnection 封装（Basic/Digest、自签名信任、流式落盘）
│   │   ├── OPWebDAVClient.h/m    # WebDAV 实现
│   │   ├── OPWebDAVParser.h/m    # PROPFIND multistatus 解析
│   │   ├── OPSocket.h/m          # POSIX 阻塞 TCP（超时控制、行/定长读取、accept 封装）
│   │   ├── OPFTPConnection.h/m   # FTP 控制连接（登录/PASV/命令应答，列表与流共享）
│   │   ├── OPFTPClient.h/m       # FTP 实现 + 列表解析
│   │   ├── OPSeekableStream.h    # 可 seek 字节流抽象（代理用）
│   │   ├── OPFTPSeekStream.h/m   # FTP 随机读（REST+RETR 分段，会话保持）
│   │   ├── OPSMBSeekStream.h/m   # SMB2 随机读（偏移 READ，会话/句柄保持）
│   │   ├── OPLocalHTTPProxy.h/m  # 127.0.0.1 本地代理（Range → FTP/SMB，206/200/416）
│   │   ├── OPSoftDecoder.h/m     # FFmpeg 软解：解复用/解码/音画同步/PCM 环/AudioQueue
│   │   ├── OPSoftVideoView.h/m   # OpenGL ES 2.0 YUV420P 显示（BT.601，等比适配）
│   │   ├── OPSoftPlayerViewController.h/m  # 软播 UI（Done/播放暂停/时间/拖动条）
│   │   ├── OPBytes.h             # 小端读写内联工具
│   │   ├── OPNTLM.h/m            # NTLMv2 (NTLMSSP)
│   │   ├── OPSMBSession.h/m      # SMB2 会话与文件操作
│   │   ├── OPSMBClient.h/m       # SMB 的 OPFileSource 封装
│   │   └── OPMediaCache.h/m      # 本地下载缓存目录
│   └── Controllers/
│       ├── OPServerListViewController.h/m   # 服务器列表（+ / 删除 / 进入）
│       ├── OPServerEditViewController.h/m   # 新增/编辑服务器表单（分组表格）
│       ├── OPFileBrowserViewController.h/m  # 目录浏览 / 触发播放
│       └── OPTransferViewController.h/m     # 下载进度浮层
├── .github/workflows/build.yml   # 云端构建（workflow_dispatch）
└── Docs/
```

## 使用说明

### 添加服务器

点右上角 **+**，填写：

| 字段 | 说明 |
|------|------|
| 名称 | 显示名，可留空则用主机名 |
| 协议 | WebDAV / FTP / SMB |
| 主机 | IP 或域名 |
| 端口 | WebDAV 默认 80/443，FTP 21，SMB 445 |
| 路径 | 起始目录（见下方格式） |
| 用户名/密码 | 可留空（WebDAV/FTP 匿名、SMB 来宾） |

**路径格式**：

- WebDAV：服务器上的绝对路径，例如 `/dav/files/user/Media`
- FTP：登录后的目录，例如 `/media`
- **SMB：第一段必须是共享名**，例如 `/Media`（共享 `Media` 的根）或 `/Media/Movies`（共享内的子目录）

### 播放

在浏览页点任意音频/视频文件，应用按扩展名分流，优先**流式播放**：

- **系统格式**（mp4/mov/m4v/3gp/mp3/m4a/wav 等）：`MPMoviePlayerViewController` 硬解。WebDAV 直接给 HTTP(S) URL（Basic 认证信息嵌在 URL 中）；FTP/SMB 通过本机 `127.0.0.1` 代理播放，进度条可随意拖动。
- **软解格式**（mkv/avi/rmvb/flv/wmv/webm/ogg/flac/ape/dts 等）：`OPSoftPlayerViewController` + FFmpeg CPU 解码。HTTP 直链与 FTP/SMB 代理同样即点即播、可拖动；WebDAV HTTPS（软解栈无 TLS）自动先下载后软播。

若流在播出首帧前失败（如 Digest 认证、自签名 HTTPS、不支持 `REST` 的 FTP 服务器），会自动回退到**下载后播放**：先把文件下载到本地缓存（`Caches/OPMediaCache`，可取消），完成后用系统播放器打开。已缓存的文件再次播放会直接使用本地副本。

支持的播放扩展名：`mp4 m4v mov 3gp 3g2 mp3 m4a aac wav aif aiff caf m4b`。

## 构建（GitHub Actions）

所有编译在 **ubuntu-latest** 上完成，`workflow_dispatch` 手动触发：

```bash
# 触发构建
gh workflow run build.yml

# 查看运行
gh run list --workflow build.yml
gh run watch <run-id>
```

Workflow 步骤（`.github/workflows/build.yml`）：

1. **iOS 6 API 门禁**：扫描源码，禁止 `NSURLSession` / `AVPlayerViewController` / `MPRemoteCommandCenter`，并要求 iOS 7+ API 带 `respondsToSelector:` 守卫。
2. **安装依赖 + ldid**（Procursus 预编译）。
3. **克隆 Theos** 与 **iOS 工具链**（clang for linux → iphone）。
4. **获取 iPhoneOS 9.3 SDK**（优先 `Secrets.SDK_URL`，否则公开 `theos/sdks`，失败回退 `xybp888/iOS-SDKs`），并用 `tools/patch_sdk_tbd.py` 修补 `liblaunch.tbd` 与 `libsystem_platform.tbd` 导出缺口。
5. **生成图标** -> `make package`（`ARCHS=armv7 TARGET=iphone:clang:9.3:6.0`）。
6. **修补 iOS 6 dyld 绑定**：`tools/fix_ios6_bindings.py` 把被 9.3 SDK re-export 到 CFNetwork/CoreFoundation 的 ObjC 类重新绑定到 Foundation，再 `ldid -S` 重签。
7. **组装 IPA**：校验 Mach-O、无 entitlements、`Info.plist` 必需键与图标，打成 `OldPlayer-<version>-<sha>-armv7.ipa`。

产物 Artifact 名为 `OldPlayer-<sha>-armv7`，含 `.ipa` 与 `.deb`，保留 14 天。IPA 可用 AltStore / Sideloadly / 爱思助手侧载（iOS 6–9, armv7）。

> **注意**：本仓库**不在本地编译**。Windows 开发环境只编辑源码，推送后在 Actions 触发构建验证。

## 兼容性保证

- **网络**：`NSURLConnection` / `NSStream` / POSIX socket，无 `NSURLSession`。
- **UI**：纯代码、手动 `frame`、`UITableView`，无 Storyboard/XIB/AutoLayout/`UICollectionView`。
- **播放**：`MPMoviePlayerViewController`（iOS 2.0+），非 `AVPlayerViewController`（iOS 8+）。
- **音频后台**：`AVAudioSessionCategoryPlayback` + `UIBackgroundModes: audio`，非 `MPRemoteCommandCenter`（iOS 7.1+）。
- **dyld 绑定**：CI 构建后用 `tools/fix_ios6_bindings.py` 修补 Mach-O bind 表，解决 iOS 6 启动时 `Symbol not found: _OBJC_CLASS_$_NSMutableURLRequest` 闪退。
- **签名**：产物不带 entitlements，便于以个人证书重新签名侧载。

## 已知限制

- SMB 仅支持 SMB 2.0.2 / 2.1；**服务器若强制要求 SMB 签名（signing required）则无法连接**。多数家用 NAS 默认不强制。
- WebDAV 直链要求服务器接受 URL userinfo 中的 Basic 认证；Digest、自签名 HTTPS 会回退到下载播放。
- FTP 流要求服务器支持 `REST`（断点续传）；极少数不支持的服务器会自动回退到下载播放。
- 软解是纯 CPU 解码（带 NEON 汇编优化）：标清/720p H.264 在 A5 及以上设备基本流畅，老设备播高码率/HEVC 会掉帧；字幕轨暂不显示；IPA 会比纯硬解版大十几 MB（静态链接的解码器子集）。
- 构建时 workflow 会先用 `tools/build_ffmpeg.sh` 交叉编译 FFmpeg 6.1（decode-only，armv7，产物缓存，缺缓存时约 10 分钟），再编 App；`FFMPEG_PREFIX` 不存在时软解文件编译为桩并回退系统播放。
- SMB 不在 `/` 根处枚举共享列表，必须在路径中写明共享名。
- WebDAV 的 Digest 认证依赖系统挑战处理；代理/重定向等场景未做特殊处理。

## 许可证

本项目源代码采用 **GNU GPL v3**（见根目录 `LICENSE`）。

`iPhoneOS SDK` 归 Apple 所有；CI 构建时动态获取的第三方 SDK/工具链归其原作者所有，受其各自许可证约束。

## 致谢

- [theos/theos](https://github.com/theos/theos) & [theos/sdks](https://github.com/theos/sdks)
- [xybp888/iOS-SDKs](https://github.com/xybp888/iOS-SDKs)

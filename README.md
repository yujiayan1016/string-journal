# 绳上手帐

挂在屏幕顶端的手帐风便签。一根红白面包师绳，用小木夹和纸胶带挂着几张便签，左端挂着收集已完成便签的漂流瓶；取下来、挂回去、甩出去，都按真实物理计算。

原生 macOS 菜单栏应用，Swift + AppKit + SwiftUI 编写，不需要账号，数据只存在本机。

## 怎么用

| 想做的事 | 操作 |
| --- | --- |
| 新建便签 | 点绳子右端的 **＋** 牛皮纸标签，或菜单栏图标 → 新便签（⌘N） |
| 编辑 | 双击便签。第一行是标题，Esc 取消，⌘↩ 保存，点别处也会保存 |
| 挂文件、文件夹 | 从访达或桌面把文件拖到绳子附近，出现虚线空位时松手；绳子被窗口挡住时，拖到菜单栏的应用图标上，或用菜单「挂上文件…」（⌘O）。一次最多 8 个 |
| 打开挂着的文件 | 双击；右键还有「在访达中显示」 |
| 取下来 | 按住便签往下拖，松手后它会落在桌面上 |
| 挂回去 | 把便签拖到绳子附近，出现虚线空位时松手，两边的便签会让位 |
| 完成 | 勾选便签右下角的小方框盖章；或拖进绳子左端的漂流瓶；或用力甩出屏幕 |
| 撤销完成 | 完成后左上方会出现「撤销」，4.5 秒内有效 |
| 找回已完成的 | 点漂流瓶，在列表里点「挂回」。漂流瓶第二天或重启应用后会自动清空 |

菜单栏图标里还有：

- **显示绳子**：关掉后绳子、漂流瓶和 ＋ 一起隐藏，挂着的便签轻轻落到桌面上，可以随意摆放；新便签用 ⌘N 或菜单新建。重新打开时，原来挂在绳子上的便签会回到各自的位置。
- **打开数据文件夹**：便签数据在 `~/Library/Application Support/StringJournal/notes.json`，旁边有一份上次的备份 `notes.bak.json`。

挂上去的文件和文件夹只是**快捷方式**：原文件留在原处不动，移动或改名后也能找到；取下、丢进漂流瓶都不会影响原文件。图片显示为拍立得，文件夹是牛皮纸档案袋，其他文件显示快速预览缩略图。

便签始终待在桌面这一层：在壁纸和桌面图标之上、所有打开的软件之下，不会遮挡任何窗口。便签之外的空白区域，点击会直接穿透到桌面。

## 构建

需要 macOS 13 或更新版本，以及 Xcode 命令行工具（不需要完整的 Xcode）：

```bash
xcode-select --install     # 只需安装一次
./build.sh                 # 为当前这台 Mac 构建
open "build/绳上手帐.app"
```

想同时支持 Apple 芯片和 Intel：`UNIVERSAL=1 ./build.sh`。

把 `build/绳上手帐.app` 拖进「应用程序」文件夹即可长期使用。本机构建的应用带有临时签名，可以直接打开。

推送到 GitHub 后，`.github/workflows/build.yml` 会在 macOS 上自动构建，并把打包好的 `StringJournal.zip` 作为构建产物提供下载。从网上下载的版本第一次打开时，需要在 Finder 里右键 → 打开。

## 调整手感

所有手感参数都在 `Sources/Tuning.swift`，改完重新运行 `./build.sh` 即可。现在的数值来自浏览器原型里调好的那一套：

| 参数 | 值 | 含义 |
| --- | --- | --- |
| slack | 0 | 绳子松弛度，0 表示绷直 |
| stiff | 0.96 | 绳子刚度，越低越像橡皮筋 |
| ropeDamp | 0.06 | 绳子晃动消失的快慢 |
| gravity | 400 | 影响摆动快慢 |
| cardMass | 1.5 | 便签相对绳子的重量 |
| swingDamp | 4.7 | 便签停下来的快慢 |
| coupling | 0.18 | 便签摆动对绳子的牵连 |
| follow | 24 | 拖拽跟手程度，越低越有滞后感 |
| brush / brushCap | 0.1 / 0.12 | 鼠标扫过便签时的推力和上限，保持轻微 |
| nudge | 0.5 | 点一下、新建、盖章时便签的晃动 |
| friction | 4 | 便签在桌面上滑行的摩擦 |

## 目录

```
Sources/
  main.swift      菜单栏图标与菜单
  Overlay.swift   透明浮层窗口、点击穿透、主循环、保存
  World.swift     绳子与便签的物理、拖拽、挂回、三种完成方式、漂流瓶
  Render.swift    手帐风绘制：纸张、纸胶带、木夹、印章、漂流瓶
  Panels.swift    编辑框与「已完成」列表
  Files.swift     文件快捷方式：分类、书签、缩略图、打开
  Model.swift     便签样式、数据存储
  Tuning.swift    手感参数
Resources/Fonts/  霞鹜文楷 TC、站酷快乐体（已裁剪为常用字）
Resources/AppIcon.svg       应用图标源文件
Resources/AppIcon.iconset/  构建时由 iconutil 生成 AppIcon.icns
```

## 致谢

- 绳子挂便签的创意来自 [String Notes](https://github.com/TD21forever/string-notes)（MIT），本项目的代码为独立实现。
- 字体：[霞鹜文楷 TC](https://github.com/lxgw/LxgwWenkaiTC)、[站酷快乐体](https://fonts.google.com/specimen/ZCOOL+KuaiLe)，均为 SIL Open Font License，许可证见 `Resources/Fonts/`。为减小体积，字体已裁剪为 GB2312 字符集加常用标点。

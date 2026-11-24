# SideStoreTranslator 汉化动态库工程

本工程完整还原 `SideStoreTranslator.dylib` 的架构与内置简体中文词库（共 **2,045 条** SideStore 完整界面翻译）。

## 目录结构

- `Sources/SideStoreTranslator.mm`：Objective-C++ 核心注入模块，拦截 `NSBundle`、`UILabel`、`UIButton`、`UIBarButtonItem`、`UINavigationItem`、`UISegmentedControl`、`UIViewController` 视图树，并支持 LiveContainer 经典模式自动预加载。
- `Sources/SwiftUITextBridge.swift`：SwiftUI 文本桥接模块，确保 SwiftUI 界面正常翻译。
- `Resources/zh-Hans.json`：完整格式化简体中文词典（支持运行时热更新）。
- `Resources/zh-Hans.min.json`：压缩后的单行词典，在链接阶段直接内嵌进 `SideStoreTranslator.dylib` 的 `__TEXT,__st_json` 段中。
- `build.sh`：macOS 本地一键编译与签名脚本。
- `.github/workflows/build.yml`：GitHub Actions 云端自动编译配置（无需 Mac 即可免费生成 `.dylib`）。

---

## 编译方式

### 方式一：在 macOS 本地编译
确保已安装 Xcode Command Line Tools（可选 `brew install ldid`），在项目根目录运行：
```bash
chmod +x build.sh
./build.sh
```
编译完成后的成品位于 `build/SideStoreTranslator.dylib`。

### 方式二：无 Mac 电脑（使用 GitHub Actions 云端编译）
1. 在 GitHub 新建一个仓库（公开或私有均可），将本压缩包内的所有文件上传到仓库根目录（注意保留 `.github/workflows/build.yml` 路径）。
2. 进入仓库顶部的 **Actions** 标签页，选择 **Build SideStoreTranslator.dylib** 并点击 **Run workflow**。
3. 等待约 1 分钟编译完成后，在页面底部的 **Artifacts** 中下载 `SideStoreTranslator-dylib` 即可获得已签名的 `SideStoreTranslator.dylib`。

---

## 使用与词库热更新方法

1. **注入使用**：
   - **LiveContainer 用户**：将 `SideStoreTranslator.dylib` 放入 LiveContainer 的 `Documents/Tweaks/` 目录，或在 SideStore 应用设置中启用该 Tweak 注入。
   - **自签 IPA 注入用户**：使用 Sideloadly / ESign / Feather 等工具签名 SideStore IPA 时，在“注入动态库（Inject Dylibs）”中添加 `SideStoreTranslator.dylib`。
2. **不重新编译直接修改翻译（热更新）**：
   - 将 `Resources/zh-Hans.json` 放入 SideStore 沙盒的 `Documents/SideStoreTranslator/zh-Hans.json` 路径下并修改内容，重启 SideStore 即可立即生效。
   - 插件每次启动后会在 `Documents/SideStoreTranslator/status.json` 生成运行状态日志，便于排查词库加载情况。

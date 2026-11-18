# Ayatsuri

[![Build Release](https://github.com/lagrange-a1/ayatsuri/actions/workflows/build-release.yml/badge.svg)](https://github.com/lagrange-a1/ayatsuri/actions/workflows/build-release.yml)
[![pre-commit](https://github.com/lagrange-a1/ayatsuri/actions/workflows/pre-commit.yml/badge.svg)](https://github.com/lagrange-a1/ayatsuri/actions/workflows/pre-commit.yml)
![version](https://img.shields.io/badge/version-0.1.8-blue)
![Dart](https://img.shields.io/badge/Dart-3.10.7%2B-blue)
![Flutter](https://img.shields.io/badge/Flutter-3.38.7-blueviolet)

基于 Flutter 的 Mihomo（Clash.Meta）控制器客户端。节点按国家聚合在地球上，点选国家后从候选中选择；另有延迟探测、运行信息面板和控制器 REST 调试控制台。

## 功能

- **选节点**：点选国家，从候选中选择并写入控制器。
- **延迟探测**：定时测速、保留历史统计，给出选路建议但不自动切换节点。
- **信息面板**：汇总九个控制器端点；诊断项折叠，原始 JSON 分页显示。
- **调试控制台**：预设命令与自定义请求共用认证客户端，curl 预览不填充 secret。
- **设置**：主题、背景、文字缩放、语言（中/英）等保存在本地，配置损坏时回退默认值。

Android、iOS、Linux、macOS、Windows、Web 均有构建配置；目前只有 Android 接入 CI 发布。

## 环境要求

- Flutter 3.38.7 stable、Dart SDK `^3.10.7`
- Android 构建需要 Java 17 与 Android SDK（含 `apksigner`）
- Rust 工具链（可选，运行 `cargo test` 时需要）
- 启用了 external-controller 的 Mihomo 内核（默认 `http://localhost:9091`）

## 本地运行

在项目根目录创建 gitignored 的 `.env`（仓库不含示例文件）：

```dotenv
host=127.0.0.1
port=9091
secret=<your-controller-secret>
```

`.env` 只用于开发，不会打包进 release。也可以在设置页填写，或用 dart-define 覆盖：

```bash
flutter pub get
flutter run \
  --dart-define=MIHOMO_HOST=127.0.0.1 \
  --dart-define=MIHOMO_PORT=9091 \
  --dart-define=MIHOMO_SECRET=<your-controller-secret>
```

secret 优先级：设置页 > dart-define > `.env`。空值或 `***` 视为未配置，此时不发送 `Authorization` 头。

修改 ARB 或模型定义后需要重新生成代码：

```bash
flutter gen-l10n
dart run build_runner build --delete-conflicting-outputs
```

## 构建

```bash
flutter build apk --release --split-per-abi
```

产物在 `build/app/outputs/flutter-apk/`。release 签名需要 `KEYSTORE_BASE64`、`KEY_ALIAS`、`KEY_STORE_PASSWORD`、`KEY_PASSWORD`；本地缺少时使用 debug 签名。

## 测试

```bash
flutter analyze
flutter test
cd rust/scheduler && cargo test
```

当前 `flutter analyze` 无问题，`flutter test` 全部通过。`test/candidates_test.dart` 需要本机 Mihomo，内核不可达时跳过。

## 目录结构

```
lib/
  main.dart / app.dart      入口与应用外壳
  data/                     MihomoAPI、控制台预设
  proxies/                  代理模型、探测历史、选路、国家映射
  globe/                    地球页面与候选面板
  info/                     信息页与分区模型
  settings/                 设置、控制台、背景图存储
  l10n/                     en/zh 及生成代码
  scheduler/                flutter_rust_bridge 生成的绑定
rust/scheduler/             Rust 调度器
test/                       单元与 widget 测试
.github/workflows/          CI 工作流
```

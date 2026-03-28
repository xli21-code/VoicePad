# VoicePad

macOS 原生语音转文字菜单栏应用。按住热键说话，松开后文字自动粘贴到光标位置。

离线 ASR（SenseVoice），可选 LLM 润色/翻译（Claude API）。

## 部署步骤（全新机器）

### 前置要求

- macOS 14.0+，Apple Silicon (arm64)
- Xcode Command Line Tools：`xcode-select --install`
- CMake：`brew install cmake`

### 1. Clone 并编译 sherpa-onnx（首次）

```bash
git clone https://github.com/xli21-code/VoicePad.git
cd VoicePad
./scripts/build_sherpa.sh
```

这一步从 GitHub clone sherpa-onnx 源码并编译 dylib 到 `Frameworks/sherpa-onnx/`，耗时约 5-10 分钟。

### 2. 创建签名证书

VoicePad 使用自签名证书保持 TCC（麦克风/辅助功能）权限跨构建持久：

打开 Keychain Access → Certificate Assistant → Create a Certificate：
- Name: `VoicePad Dev`
- Identity Type: Self-Signed Root
- Certificate Type: Code Signing

如果不想创建证书，把 `scripts/build_app.sh` 中 `codesign --force --sign "VoicePad Dev"` 改为 `codesign --force --sign -`（ad-hoc 签名，每次重编译后需重新授权系统权限）。

### 3. 编译并安装

```bash
./scripts/build_app.sh
cp -R dist/VoicePad.app /Applications/
open /Applications/VoicePad.app
```

### 4. 授权系统权限

首次启动后在 **系统设置 → 隐私与安全性** 中授权：

| 权限 | 用途 |
|------|------|
| 麦克风 | 录音 |
| 辅助功能 | 全局热键捕获 + 模拟粘贴 |

### 5. ASR 模型

首次启动时自动从 GitHub 下载 SenseVoice 模型（~200MB）到 `~/.voicepad/models/`。app 会自动读取系统代理设置。

### 6. LLM 润色（可选）

点击菜单栏图标 → Settings → API tab，配置：
- API Key（支持 Anthropic API 或兼容中转站）
- Base URL（默认 `https://api.anthropic.com`）
- Model（默认 `claude-sonnet-4-20250514`）

或者直接编辑 `~/.voicepad/config.json`：
```json
{
  "anthropic_api_key": "sk-...",
  "api_base_url": "https://api.anthropic.com",
  "model": "claude-sonnet-4-20250514"
}
```

## 使用

- **按住 Left Control** → 录音（红色浮窗）
- **松开** → 转录 → 润色（如开启）→ 粘贴到当前应用
- 菜单栏可切换 Smart Polish / Translation 开关
- 30 分钟无操作自动休眠，下次录音时自动唤醒

## 更新部署

```bash
cd VoicePad
git pull
./scripts/build_app.sh
pkill -f VoicePad.app; sleep 1
cp -R dist/VoicePad.app /Applications/
open /Applications/VoicePad.app
```

## 项目结构

```
VoicePad/
├── Sources/VoicePad/
│   ├── AppState.swift            # 核心状态机
│   ├── Audio/AudioEngine.swift   # 录音引擎（AVAudioEngine + pre-roll buffer）
│   ├── Input/HotkeyMonitor.swift # 全局热键（keyCode 检测 + chord rejection）
│   ├── Models/ModelManager.swift # ASR 模型下载管理
│   ├── Util/
│   │   ├── LLMPolisher.swift     # Claude API 润色/翻译
│   │   ├── TextProcessor.swift   # 文本后处理 + 纠错
│   │   ├── VocabularyStore.swift # 用户词典
│   │   └── CorrectionLearner.swift # 自动纠错学习
│   └── UI/                       # 菜单栏、浮窗、设置界面
├── scripts/
│   ├── build_sherpa.sh           # 编译 sherpa-onnx（首次）
│   └── build_app.sh              # 编译 + 签名 + 打包 .app
├── Frameworks/sherpa-onnx/       # 编译产物（gitignored）
└── Package.swift
```

## 运行时配置

`~/.voicepad/` 目录：

| 文件 | 内容 |
|------|------|
| `config.json` | API key、base URL、model |
| `vocabulary.json` | 用户词典 |
| `app_branches.json` | App Branch 上下文配置 |
| `models/` | ASR 模型文件 |
| `voicepad.log` | 运行日志 |

## 技术栈

| 层 | 技术 |
|----|------|
| 语言 | Swift 5.9 |
| UI | AppKit（NSPanel + NSStatusBar） |
| ASR | SenseVoice via sherpa-onnx（C bridge） |
| LLM | Claude API（可选） |
| 存储 | GRDB / SQLite（FTS5 全文搜索） |
| 音频 | AVAudioEngine（16kHz mono Float32） |

## License

MIT

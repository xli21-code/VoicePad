# VoicePad

macOS 原生语音转文字菜单栏应用。按住热键说话，松开后文字自动粘贴到光标位置。

离线 ASR（Whisper turbo 主 / SenseVoice 备），可选 LLM 润色/翻译（任何 OpenAI 或 Anthropic 兼容端点，默认指向本机网关）。

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

首次启动时自动下载两套 ASR 模型：Whisper large-v3-turbo（WhisperKit，~1.5GB，主力）与 SenseVoice（~200MB，兜底）。app 会自动读取系统代理设置。

另需一个语音活动检测模型（Silero VAD，629KB），放在 `~/.voicepad/models/silero-vad/silero_vad.onnx`：

```bash
mkdir -p ~/.voicepad/models/silero-vad
curl -L -o ~/.voicepad/models/silero-vad/silero_vad.onnx \
  https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx
```

它的作用：遥控器按键本身会送进一段到达满量程的低频撞击（松开即静音），Whisper 会把它误听成「我」「好」「I.」这类一个字的输出。电平判据看不出这种“有能量但没人说话”的录音，Silero 能。模型缺失时该判据自动跳过，只保留电平判据。

### 6. LLM 润色（可选）

点击菜单栏图标 → Settings → API tab，配置：
- Base URL（默认 `http://127.0.0.1:3425`，本机网关；任意 OpenAI / Anthropic 兼容端点都行）
- API Key（本地网关可留空）
- Model（从网关的 `/v1/models` 列表里选，不预置任何模型名）

或者直接编辑 `~/.voicepad/config.json`（v2 结构，润色 / 翻译 / 词表导入可各用一个模型）：
```json
{
  "provider": { "base_url": "http://127.0.0.1:3425", "api_key": "" },
  "models": {
    "polish": "ollama-cloud/gemma4:31b",
    "translate": "ollama-cloud/deepseek-v4.1-flash:1017",
    "import": "ollama-cloud/gemma4:31b"
  }
}
```
旧的 `anthropic_api_key` / `api_base_url` / `model` 三个键仍然能读，用来接 Anthropic 官方 API。

## 使用

- **按住 Left Control** → 录音（红色浮窗）
- **松开** → 转录 → 润色（如开启）→ 粘贴到当前应用
- 菜单栏可切换 Smart Polish / Translation 开关
- 30 分钟无操作自动休眠，下次录音时自动唤醒

## 回归评测（改 prompt / 换模型之后必跑）

```bash
swift build && ./scripts/build_app.sh        # 让被测的二进制是最新的
python3 scripts/regress.py                   # 跑一遍，任何 gate FAIL 就退出码 1
python3 scripts/regress.py --limit 15        # 快速版
python3 scripts/regress.py --update-baseline # 确认改进之后才更新基线
```

它把 App 自己的 system prompt dump 出来（`VoicePad --dump-polish-prompt`），所以测的一定是线上
在用的那份 prompt，不会和代码漂移。指标：失败率、疑似掉内容（已排除自我纠正）、压缩率（中位/均值，
以及“砍掉一半”的单条）、术语保留率、残留填充词、是否擅自加结构化、p50/p90、单次成本。
基线在 `~/.voicepad/eval/regress_baseline.json`。

压缩率是这一版的主指标：改写层以前几乎原样返回（中位 -4%），现在要求比原话短 10%–30%，
门槛是**中位 ≥ 10%**，同时不许单条砍掉一半（>70%）——那是摘要，不是整理。

成本口径：网关 `/v1/models` 给该模型报的单价 × 本次响应的 `usage` token（cache-read 按缓存价折扣），
本地 ASR 边际成本计 0。网关不报价的模型只输出 token 数、不开成本 gate，也不会被当成免费。

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
│   │   ├── LLMPolisher.swift     # LLM 润色/翻译（OpenAI / Anthropic 两种线上格式）
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
| ASR | Whisper turbo via WhisperKit（主）/ SenseVoice via sherpa-onnx（备） |
| LLM | OpenAI 兼容 / Anthropic 兼容端点（可选） |
| 存储 | GRDB / SQLite（FTS5 全文搜索） |
| 音频 | AVAudioEngine（16kHz mono Float32） |

## License

MIT

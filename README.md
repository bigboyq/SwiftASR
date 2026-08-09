# SwiftASR

[English](#english) · [中文帮助](docs/HELP.zh-CN.md) · [English help](docs/HELP.en.md)

SwiftASR 是面向 macOS 的本地音频转写与说话人识别应用。音频解码、语音活动检测、
转写、标点恢复、说话人嵌入与聚类均在本机完成；可选的 Gemini 润色会把待处理文本
发送到 Google Gemini API。

> 当前版本为早期公开预览版，仅支持 Apple Silicon 和 macOS 14 或更高版本。
> GitHub Release 中的应用采用 ad-hoc 签名、尚未经过 Apple 公证。

## 功能

- 导入常见音频格式并排队转写
- SeACo-Paraformer 中文转写与热词提示
- FSMN-VAD 语音活动检测和 CT-Transformer 标点恢复
- ERes2NetV2 说话人识别、说话人命名与本地声纹库
- 以 `result.json` 保存结构化结果，支持逐段人工修订
- 可选 Gemini 润色，导出内容严格跟随当前预览
- 全部任务数据、设置与日志默认保存在本机

## 性能与识别效果

在 M1 Pro 的项目实测中，一段 10 分钟音频完成 VAD、ASR、标点恢复和说话人处理的
端到端耗时为 `14.97 秒`（RTF `0.0249`，约 40 倍实时）；按相同负载线性折算，
1 小时音频约需 `90 秒`。实际速度会随录音长度、说话人数、音质、温度、后台负载和
系统版本变化。

在收音清晰、以普通话为主且领域匹配的项目样本中，人工抽查的文字正确率多数可达
90% 以上。这个数字是项目场景中的经验值，不是公开测试集上的统一 CER/WER，也不代表
所有口音、噪声、重叠说话或专业术语场景。配置 Gemini API Key 后，可在结果页调用
Gemini 自动精修转写文本；只有文本、说话人标签和术语提示会发送给 Gemini，不会上传音频。

## 安装

1. 从 [Releases](https://github.com/bigboyq/SwiftASR/releases) 下载最新 DMG。
2. 打开 DMG，把 `SwiftASR.app` 拖入“应用程序”。
3. 首次启动如被 Gatekeeper 阻止，请在 Finder 中右键应用并选择“打开”；如果仍被
   阻止，前往“系统设置 → 隐私与安全性”选择“仍要打开”。

完整的安装、使用、数据位置、Gemini 隐私说明和故障排查见
[中文帮助](docs/HELP.zh-CN.md)。

## 从源码构建

需要 Xcode 26、Swift 6.3、Apple Silicon Mac，以及放在 `Resources/Models/` 下的
四组模型文件。模型清单与许可证见 [MODEL_LICENSES.md](MODEL_LICENSES.md)，详细步骤见
[BUILDING.md](docs/BUILDING.md)。

```bash
swift test --filter SwiftASRTests
./scripts/release.sh 0.1.0 1
```

构建产物位于 `build/`。模型文件不会提交到 Git；Release DMG 中包含的是从上游模型
转换得到的运行时文件。

## 隐私

本地转写不会上传音频。只有在用户主动启动 Gemini 润色时，相关文本才会发送到
Google Gemini API。Gemini API Key 当前保存在本机 `settings.json` 中，并通过
owner-only 文件权限保护；它未存入 Keychain。请仅在受信任且启用磁盘加密的 Mac 上使用。

## 开源、致谢与引用

SwiftASR 源码采用 [Apache License 2.0](LICENSE)。模型权重、转换模型和第三方组件不因
本项目许可证而重新授权；它们继续遵循各自的上游条款。请阅读：

- [模型来源与许可证](MODEL_LICENSES.md)
- [第三方软件声明](THIRD_PARTY_NOTICES.md)
- [致谢与论文引用](ACKNOWLEDGEMENTS.md)

特别感谢 [FunASR](https://github.com/modelscope/FunASR)、
[ModelScope](https://modelscope.cn/)、[3D-Speaker](https://github.com/modelscope/3D-Speaker)
和 [ONNX Runtime](https://github.com/microsoft/onnxruntime)。

## 开发

```bash
swift build
swift test --filter SwiftASRTests
```

重型模型测试需要本地模型和可选测试素材：

```bash
swift test --filter SwiftASRModelTests
```

安全问题请按 [SECURITY.md](SECURITY.md) 私下报告。一般问题与功能建议请使用
[GitHub Issues](https://github.com/bigboyq/SwiftASR/issues)。

---

## English

SwiftASR is a native macOS app for local audio transcription and speaker
diarization. Audio decoding, VAD, ASR, punctuation restoration, speaker
embedding, and clustering run on the Mac. Optional Gemini cleanup sends only
the text being processed to the Google Gemini API.

The current release is an early public preview for Apple Silicon on macOS 14
or later. Release builds are ad-hoc signed and are not yet notarized by Apple.

### Highlights

- Queued transcription of common audio formats
- Chinese ASR with SeACo-Paraformer and hotword hints
- FSMN-VAD, CT-Transformer punctuation, and ERes2NetV2 diarization
- Structured `result.json`, manual segment editing, and speaker naming
- Optional Gemini cleanup and preview-faithful text export
- Local-first storage for jobs, settings, speaker profiles, and logs

### Performance and recognition quality

In a project benchmark on an M1 Pro, the complete VAD, ASR, punctuation, and
speaker pipeline processed a 10-minute recording in `14.97 seconds` (RTF
`0.0249`, about 40× real time). At the same sustained rate, one hour of audio
would take roughly `90 seconds`. Actual speed varies with duration, speaker
count, recording quality, thermals, background load, and OS version.

For clear, primarily Mandarin recordings that match the model domain, manual
reviews of project samples have usually found more than 90% of the text correct.
This is an observed project figure, not a standardized benchmark-set CER/WER or
a guarantee for every accent, noisy recording, overlap, or specialist vocabulary.
After a Gemini API key is configured, Results can invoke Gemini to automatically
polish the transcript. Text, speaker labels, and glossary hints are sent; audio
remains local.

Download the latest DMG from [Releases](https://github.com/bigboyq/SwiftASR/releases).
See the [English help](docs/HELP.en.md) for installation, usage, privacy, and
troubleshooting, or [BUILDING.md](docs/BUILDING.md) to build from source.

SwiftASR source code is licensed under [Apache-2.0](LICENSE). Bundled models
and third-party components retain their upstream licenses; see
[MODEL_LICENSES.md](MODEL_LICENSES.md), [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md),
and [ACKNOWLEDGEMENTS.md](ACKNOWLEDGEMENTS.md).

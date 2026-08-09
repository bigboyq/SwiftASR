# SwiftASR 0.1.0

首个公开预览版。SwiftASR 提供 Apple Silicon macOS 上的本地中文音频转写、标点恢复、
说话人识别、结构化结果编辑、可选 Gemini 润色和按预览导出。

## 系统要求

- Apple Silicon Mac
- macOS 14 或更高版本

## 安装提示

此版本为 ad-hoc 签名且尚未经过 Apple 公证。首次启动请在 Finder 中右键应用选择
“打开”，或在“系统设置 → 隐私与安全性”中选择“仍要打开”。详细步骤见仓库中的
中英文帮助文档。

## 模型与许可证

DMG 包含 SeACo-Paraformer、FSMN-VAD、CT-Transformer 和 ERes2NetV2 的转换运行时
模型。应用源码采用 Apache-2.0；模型继续遵循上游模型卡与 FunASR 模型协议，完整
归属和引用随应用与仓库分发。

## 校验

下载后可运行：

```bash
shasum -a 256 -c SwiftASR-0.1.0-1.dmg.sha256
```

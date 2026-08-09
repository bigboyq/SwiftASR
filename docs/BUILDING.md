# Building and releasing SwiftASR

## Requirements

- Apple Silicon Mac running macOS 14 or later
- Xcode 26 with Swift 6.3
- `rsync`, `codesign`, `hdiutil`, and `shasum` from macOS
- The production model files described in [MODEL_LICENSES.md](../MODEL_LICENSES.md)

The source repository intentionally excludes model weights and compiled models.
Place them under this layout:

```text
Resources/Models/
├── vad/
│   ├── model_quant.onnx
│   └── am.mvn
├── seaco_paraformer/
│   ├── model_quant.onnx
│   ├── model_eb_quant.onnx
│   ├── tokens.json
│   └── am.mvn
├── punc/
│   ├── model_quant.onnx
│   └── tokens.json
└── speaker/
    └── model_batch16.mlmodelc/
```

`SWIFTASR_DEV_MODELS_ROOT` may point to the same layout elsewhere.
The files must match [MODEL_ARTIFACTS.sha256](../MODEL_ARTIFACTS.sha256); this
prevents a release from silently packaging a different same-named model.

## Test and build

```bash
swift test --filter SwiftASRTests
./scripts/build_app.sh 0.1.0 1
./scripts/build_dmg.sh
```

Or run the complete release helper:

```bash
./scripts/release.sh 0.1.0 1
```

It runs the lightweight tests, builds the app and DMG, verifies both, and writes
a SHA-256 checksum beside the DMG.

## Signing

The default is ad-hoc signing:

```bash
SIGNING_IDENTITY=- ./scripts/release.sh 0.1.0 1
```

For public distribution without Gatekeeper warnings, use a Developer ID
Application certificate and notarize the DMG. For example:

```bash
SIGNING_IDENTITY='Developer ID Application: Example (TEAMID)' \
  ./scripts/release.sh 0.1.0 1

xcrun notarytool submit build/SwiftASR-0.1.0-1.dmg \
  --keychain-profile swiftasr-notary --wait
xcrun stapler staple build/SwiftASR-0.1.0-1.dmg
```

Never commit signing certificates, API keys, App Store Connect credentials, or
notary profiles.

## 中文说明

源码仓库不包含模型文件。按上面的固定目录准备四组模型后，运行
`./scripts/release.sh <版本> <构建号>` 即可生成应用、DMG 和 SHA-256 校验文件。
默认使用 ad-hoc 签名；面向普通用户免警告分发需要 Developer ID Application 证书并
完成 Apple 公证。模型的再分发义务必须随每个 Release 一并保留。

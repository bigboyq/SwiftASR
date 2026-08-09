# SwiftASR 帮助

## 系统要求

- Apple Silicon Mac（M1 或更新）
- macOS 14 Sonoma 或更高版本
- 首次安装约需 1 GB 可用空间；长音频转写需要额外工作空间
- Gemini 润色是可选功能，需要网络连接和用户自己的 Gemini API Key

Intel Mac 当前不受支持。

## 安装与首次打开

1. 从 GitHub Releases 下载 `SwiftASR-<版本>-<构建号>.dmg`。
2. 双击 DMG，把 `SwiftASR.app` 拖到“应用程序”。
3. 当前公开构建尚未经过 Apple 公证。首次打开时，在 Finder 中右键
   `SwiftASR.app`，选择“打开”，然后再次确认。
4. 如果系统仍阻止启动，请打开“系统设置 → 隐私与安全性”，在安全提示旁选择
   “仍要打开”。

若下载后系统提示应用损坏，请先确认下载页和 SHA-256 校验值来自本项目的官方
GitHub Release。确认无误后可在终端执行：

```bash
xattr -dr com.apple.quarantine /Applications/SwiftASR.app
```

这条命令会移除该应用的下载隔离标记，只应对已核验来源和校验值的应用使用。

## 快速开始

1. 打开“文件”，导入音频。
2. 在“转写”中检查队列并启动任务。
3. 完成后进入“结果”：
   - “逐句原文”查看自动转写；
   - “合并原文”按说话人合并；
   - “润色稿”查看 Gemini 或人工修订后的内容。
4. 点击说话人名称可命名、调整归属或同步到本地说话人库。
5. 导出时，文本会严格按照结果页当前预览生成。

## 结果与编辑

每个任务以一个结构化 `result.json` 为工作副本。原始文本、时间戳、自动说话人标签
和声纹证据不会被人工编辑覆盖。人工修订和 Gemini 润色写入清理后的文本字段，因此
可以保留原始识别结果并随时对照。

多来源合并行不能直接编辑时，请先恢复或确认它的来源段说话人，再进行修改。

## Gemini 润色与隐私

本地转写流程不会上传音频。只有用户主动启动 Gemini 润色时，当前处理批次的文本、
说话人标签和用户配置的术语提示才会发送到 Google Gemini API。请同时遵守 Google
Gemini API 的服务条款和数据政策。

Gemini API Key 当前保存在：

```text
~/Library/Application Support/SwiftASR/settings.json
```

文件权限会收紧为仅当前用户可读写，但 Key 未存入 macOS Keychain。建议启用 FileVault，
不要在多人共用或不受信任的系统账户中保存 Key。

## 数据位置

SwiftASR 的默认数据目录为：

```text
~/Library/Application Support/SwiftASR/
```

其中包含设置、SwiftData 数据库、任务 `result.json`、日志和说话人资料。卸载应用不会
自动删除该目录。删除前请先备份需要保留的结果。

## 模型与离线能力

Release 应用包含以下本地推理模型：

- FSMN-VAD：语音活动检测
- SeACo-Paraformer：中文语音识别和热词提示
- CT-Transformer：中英文标点恢复
- ERes2NetV2：说话人嵌入

模型的来源、版本、许可证和论文引用见
[MODEL_LICENSES.md](../MODEL_LICENSES.md) 与
[ACKNOWLEDGEMENTS.md](../ACKNOWLEDGEMENTS.md)。

## 常见问题

### 应用打不开

确认系统为 macOS 14+ 且 Mac 使用 Apple Silicon。然后按“安装与首次打开”的步骤处理
未公证应用提示。

### 提示模型缺失或损坏

从官方 Release 重新下载 DMG，并对照 Release 页的 `.sha256` 文件校验。不要单独移动
应用包里的 `Contents/Resources/Models`。

### 转写很慢或内存占用高

长音频需要保留 PCM、声学特征和说话人聚类中间数据。关闭其他高内存应用，保证足够
磁盘空间，并优先把特别长的录音分成较小文件。任务可暂停或取消。

### 说话人分配不准确

重叠说话、短插话、背景噪声和远场录音都会降低说话人效果。可在结果页手工调整归属，
并用清晰、持续时间足够的样本维护本地说话人库。

### Gemini 失败

检查 API Key、网络代理、账户配额和 Gemini 服务可用性。本地转写与 Gemini 相互独立；
Gemini 失败不会删除原始转写。

## 获取支持

提交公开问题前，请移除音频内容、API Key、个人路径和 `result.json` 中的敏感文本。
一般问题请提交 GitHub Issue；安全问题请按 [SECURITY.md](../SECURITY.md) 私下报告。

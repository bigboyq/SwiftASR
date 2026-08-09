# Model sources and licenses

SwiftASR source code and model artifacts are separate works. The project's
Apache-2.0 license does **not** relicense any model weight, vocabulary, CMVN
file, ONNX export, Core ML conversion, or other derived model artifact.

The v0.1.0 release bundles the following production model set:

| Role | Upstream model | Release artifact | Upstream license shown by model card |
| --- | --- | --- | --- |
| ASR | [iic/speech_seaco_paraformer_large_asr_nat-zh-cn-16k-common-vocab8404-pytorch](https://modelscope.cn/models/iic/speech_seaco_paraformer_large_asr_nat-zh-cn-16k-common-vocab8404-pytorch) | quantized ONNX graph, bias-encoder graph, vocabulary, CMVN | Apache License 2.0 |
| VAD | [iic/speech_fsmn_vad_zh-cn-16k-common-pytorch](https://modelscope.cn/models/iic/speech_fsmn_vad_zh-cn-16k-common-pytorch) | quantized ONNX graph, CMVN | Apache License 2.0 |
| Punctuation | [iic/punc_ct-transformer_cn-en-common-vocab471067-large](https://modelscope.cn/models/iic/punc_ct-transformer_cn-en-common-vocab471067-large) | quantized ONNX graph, vocabulary | Apache License 2.0 |
| Speaker embedding | [iic/speech_eres2netv2_sv_zh-cn_16k-common](https://modelscope.cn/models/iic/speech_eres2netv2_sv_zh-cn_16k-common) | batch-16 Core ML conversion | Apache License 2.0 |

The ModelScope cards identify the models as FunASR/Alibaba or ERes2NetV2
models. The ERes2NetV2 architecture and recipes are also published by the
[3D-Speaker project](https://github.com/modelscope/3D-Speaker), licensed under
Apache-2.0.

FunASR also publishes a separate
[FunASR Model Open Source License Agreement v1.1](https://github.com/modelscope/FunASR/blob/main/MODEL_LICENSE).
It permits use, copying, modification, and sharing, while requiring source and
author attribution and retention of the relevant model names. Release builds
retain all four model names and provide their source links here and in the
application bundle.

## Conversion and redistribution

- [MODEL_ARTIFACTS.sha256](MODEL_ARTIFACTS.sha256) fixes the exact runtime files
  accepted by the v0.1.0 build. The release script refuses a same-named but
  different model artifact.
- ONNX quantization/export and the ERes2NetV2 Core ML conversion change runtime
  format; they do not change model ownership or upstream license obligations.
- `model_batch16.mlmodelc` is derived from the ERes2NetV2 checkpoint and remains
  governed by the upstream model terms.
- Model files are not stored in this Git repository. A release maintainer must
  verify the applicable upstream card and agreement again before publishing a
  new binary, because upstream terms and model revisions can change.
- Downstream redistributors must preserve this file, `ACKNOWLEDGEMENTS.md`, and
  the relevant upstream license text or link with the model artifacts.

This inventory records the evidence reviewed for the release; it is not legal
advice and does not replace the upstream terms.

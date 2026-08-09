# Acknowledgements and citations

SwiftASR exists because the speech and open-source communities published both
production-grade models and inspectable reference implementations.

We gratefully acknowledge:

- [FunASR](https://github.com/modelscope/FunASR) and the Alibaba/ModelScope
  speech teams for the model ecosystem, frontend and inference references.
- [ModelScope](https://modelscope.cn/) for hosting the model cards and artifacts.
- [3D-Speaker](https://github.com/modelscope/3D-Speaker) for ERes2NetV2 and
  speaker verification/diarization recipes.
- [ONNX Runtime](https://github.com/microsoft/onnxruntime) for native model
  inference and its Swift package.
- Apple for Swift, SwiftUI, SwiftData, AVFoundation, Accelerate, and Core ML.
- Google Gemini for the optional text-cleanup API.

The Swift implementation is independent code, but several algorithms and
behavioral contracts were translated or validated against FunASR. See
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for license notices and
[MODEL_LICENSES.md](MODEL_LICENSES.md) for model-specific terms.

## Model papers

If you use SwiftASR in research, please cite the applicable upstream work.

### SeACo-Paraformer

```bibtex
@article{shi2023seaco,
  title={SeACo-Paraformer: A Non-Autoregressive ASR System with Flexible and Effective Hotword Customization Ability},
  author={Shi, Xian and Yang, Yexin and Li, Zerui and Zhang, Shiliang},
  journal={arXiv preprint arXiv:2308.03266},
  year={2023}
}
```

### FSMN

```bibtex
@inproceedings{zhang2018deep,
  title={Deep-FSMN for Large Vocabulary Continuous Speech Recognition},
  author={Zhang, Shiliang and Lei, Ming and Yan, Zhijie and Dai, Lirong},
  booktitle={2018 IEEE International Conference on Acoustics, Speech and Signal Processing (ICASSP)},
  pages={5869--5873},
  year={2018}
}
```

### CT-Transformer punctuation

```bibtex
@inproceedings{chen2020controllable,
  title={Controllable Time-Delay Transformer for Real-Time Punctuation Prediction and Disfluency Detection},
  author={Chen, Qian and Chen, Mengzhe and Li, Bo and Wang, Wen},
  booktitle={2020 IEEE International Conference on Acoustics, Speech and Signal Processing (ICASSP)},
  pages={8069--8073},
  year={2020}
}
```

### 3D-Speaker / ERes2NetV2 ecosystem

```bibtex
@article{chen20243dspeaker,
  title={3D-Speaker-Toolkit: An Open Source Toolkit for Multi-modal Speaker Verification and Diarization},
  author={Chen, Yafeng and Zheng, Siqi and Wang, Hui and Cheng, Luyao and others},
  booktitle={ICASSP},
  year={2025}
}
```

Model cards can add or revise recommended citations. Consult the linked
upstream cards before preparing an academic publication.

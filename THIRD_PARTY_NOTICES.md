# Third-party notices

SwiftASR is an independent project and is not affiliated with or endorsed by
the organizations named below.

## FunASR

SwiftASR's native frontend, VAD endpointing, decoding, pipeline behavior, and
data compatibility work were implemented with reference to and parity testing
against [FunASR](https://github.com/modelscope/FunASR). FunASR source code is
available under the MIT License.

> MIT License
>
> Copyright (c) 2025 FunASR
>
> Permission is hereby granted, free of charge, to any person obtaining a copy
> of this software and associated documentation files (the "Software"), to deal
> in the Software without restriction, including without limitation the rights
> to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
> copies of the Software, and to permit persons to whom the Software is
> furnished to do so, subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in
> all copies or substantial portions of the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
> IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
> FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
> AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
> LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
> OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
> SOFTWARE.

## ONNX Runtime and its Swift package

SwiftASR links the
[ONNX Runtime Swift Package Manager package](https://github.com/microsoft/onnxruntime-swift-package-manager),
which distributes [Microsoft ONNX Runtime](https://github.com/microsoft/onnxruntime).
Both repositories identify their license as MIT.

> MIT License
>
> Copyright (c) Microsoft Corporation
>
> Permission is hereby granted, free of charge, to any person obtaining a copy
> of this software and associated documentation files (the "Software"), to deal
> in the Software without restriction, including without limitation the rights
> to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
> copies of the Software, and to permit persons to whom the Software is
> furnished to do so, subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in all
> copies or substantial portions of the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
> IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
> FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
> AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
> LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
> OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
> SOFTWARE.

## 3D-Speaker

The ERes2NetV2 model architecture and training/inference recipes are provided by
[3D-Speaker](https://github.com/modelscope/3D-Speaker) under Apache License 2.0.
The full Apache-2.0 terms are included in this distribution's `LICENSE` file.

## Apple frameworks

SwiftASR uses system frameworks supplied by Apple, including SwiftUI, SwiftData,
AVFoundation, Accelerate, Core ML, CryptoKit, and Uniform Type Identifiers.
They are not redistributed as open-source components by this repository and
remain subject to Apple's terms.

## Google Gemini API

Gemini cleanup calls Google's HTTP API directly through Foundation URLSession;
no Google SDK source is vendored. Use of Gemini is optional and subject to the
applicable Google API terms and privacy policies.

## Build-only tools

The optional model conversion scripts use Python, PyTorch, NumPy, FunASR,
ONNX Runtime, and coremltools from the maintainer's environment. Those packages
are not vendored in this repository and are not part of the SwiftASR executable.

import Foundation
import AVFoundation

public enum AudioConverterError: Error, LocalizedError, Sendable, Equatable {
    case cancelled
    case failedToCreateTargetFormat
    case failedToInitializeConverter
    case failedToAllocateBuffers
    /// AVAudioConverter returned `.error`. R4-P2-6：现在携带底层 AVAudioConverter
    /// error 作为 debug metadata（旧实现直接 `throw err` 让裸 NSError 冒泡，
    /// 调用方无法稳定区分解码 / 格式转换 / 输出写入失败）。nil 表示 AVAudioConverter
    /// 未填充 out-error slot。
    case conversionError(underlying: NSError?)

    public var errorDescription: String? {
        switch self {
        case .cancelled:
            return "音频解码已取消。"
        case .failedToCreateTargetFormat:
            return "Failed to create target AVAudioFormat."
        case .failedToInitializeConverter:
            return "Failed to initialize AVAudioConverter."
        case .failedToAllocateBuffers:
            return "Failed to allocate audio buffers."
        case .conversionError:
            return "Conversion error."
        }
    }
}

/// AVAudioConverter requests the input block synchronously, but its API marks
/// the block as Sendable. This wrapper owns the non-Sendable AVAudioPCMBuffer
/// for the duration of one conversion call and supplies it at most once.
private final class ConverterInputProvider: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private var hasSuppliedBuffer = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func takeBuffer() -> AVAudioPCMBuffer? {
        guard !hasSuppliedBuffer else { return nil }
        hasSuppliedBuffer = true
        return buffer
    }
}

public extension AudioConverter {
    /// 读取音频文件 duration（秒）不进行 pcm 解码。cheap（只读文件 header）。
    /// 用于 preflight 在分配大数组前估算内存需求。
    /// - Returns: 时长（秒）；失败返回 nil
    static func probeDuration(path: String) -> Double? {
        let fileURL = URL(fileURLWithPath: path)
        guard let audioFile = try? AVAudioFile(forReading: fileURL) else { return nil }
        let sampleRate = audioFile.processingFormat.sampleRate
        guard sampleRate > 0 else { return nil }
        return Double(audioFile.length) / sampleRate
    }
}

public final class AudioConverter {
    public init() {}
    
    /// 将任意常见音频文件解码并重采样到 16kHz, 单声道, Float32 的 PCM 格式
    /// - Parameter path: 音频文件的绝对路径
    /// - Returns: 一维 Float 数组，代表 PCM 采样数据
    public func loadAndResample(
        path: String,
        shouldCancel: @Sendable @escaping () -> Bool = { false }
    ) throws -> [Float] {
        if shouldCancel() { throw AudioConverterError.cancelled }
        let fileURL = URL(fileURLWithPath: path)
        let audioFile = try AVAudioFile(forReading: fileURL)
        
        // 1. 定义我们期望的目标格式：16kHz, 1通道 (单声道), 32位浮点 PCM
        let targetSampleRate = Double(AudioTimebase.standard.sampleRate)
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioConverterError.failedToCreateTargetFormat
        }

        // 2. 构造转换器 (AVAudioConverter)
        guard let converter = AVAudioConverter(from: audioFile.processingFormat, to: targetFormat) else {
            throw AudioConverterError.failedToInitializeConverter
        }
        
        // 3. 计算目标缓冲区的帧长度
        // 目标帧数 = (原始总帧数 * 目标采样率) / 原始采样率
        let originalTotalFrames = audioFile.length
        let originalSampleRate = audioFile.processingFormat.sampleRate
        // 4. 用来存放最终 Float 的容器
        var pcmData = [Float]()
        let rawTargetFrames = Double(originalTotalFrames) * targetSampleRate / originalSampleRate
        if rawTargetFrames > 0 && rawTargetFrames <= Double(Int.max) {
            pcmData.reserveCapacity(Int(rawTargetFrames))
        }
        // 5. 循环从源文件读取并转换。
        //
        // `AVAudioConverter` 的 input block 可能被一次 convert 调用多次。它每次
        // 只能得到当前这个 source buffer 一次；若重复返回同一个 buffer，48kHz ->
        // 16kHz 会把一块输入重复消费约三次，导致 PCM 长度和所有后续时间戳膨胀三倍。
        // 每次读取 4096 帧进行分块转换，以节省内存。
        let bufferSize: AVAudioFrameCount = 4096
        let outputBufferSize = AVAudioFrameCount(
            max(1, ceil(Double(bufferSize) * targetSampleRate / originalSampleRate) + 32)
        )
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: bufferSize),
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputBufferSize) else {
            throw AudioConverterError.failedToAllocateBuffers
        }

        var error: NSError?
        while audioFile.framePosition < originalTotalFrames {
            if shouldCancel() { throw AudioConverterError.cancelled }
            let remainingFrames = originalTotalFrames - audioFile.framePosition
            let framesToRead = AVAudioFrameCount(min(Int64(bufferSize), remainingFrames))
            if framesToRead == 0 { break }
            
            try audioFile.read(into: inputBuffer, frameCount: framesToRead)
            if shouldCancel() { throw AudioConverterError.cancelled }
            let inputProvider = ConverterInputProvider(buffer: inputBuffer)
            let status = converter.convert(to: outputBuffer, error: &error) { inNumPackets, outStatus in
                guard let buffer = inputProvider.takeBuffer() else {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                outStatus.pointee = .haveData
                return buffer
            }
            
            if status == .error {
                // R4-P2-6：把 AVAudioConverter 的底层 error 包成 typed case，
                // 不让裸 NSError 冒泡。
                throw AudioConverterError.conversionError(underlying: error)
            }

            if shouldCancel() { throw AudioConverterError.cancelled }
            
            // 提取输出的 float 值。用 `append(contentsOf:)` 走底层 memcpy，
            // 跟项目里 `SpeakerProfile.swift` / `FbankExtractor.swift` / `CoreML/*`
            // 的 UnsafeBufferPointer 拷贝惯例保持一致，避免逐元素 append 拖慢热路径。
            if let floatChannelData = outputBuffer.floatChannelData {
                let pointer = floatChannelData[0]
                let frameCount = Int(outputBuffer.frameLength)
                pcmData.append(contentsOf: UnsafeBufferPointer(start: pointer, count: frameCount))
            }
            
            // 重置 buffer 状态以便下次写入
            inputBuffer.frameLength = 0
            outputBuffer.frameLength = 0
        }
        
        return pcmData
    }
}

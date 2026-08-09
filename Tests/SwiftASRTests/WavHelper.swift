import Foundation

func writeWav(path: String, pcm: [Float], sampleRate: Int) throws {
    // 写 16-bit PCM WAV
    var data = Data()
    let numSamples = pcm.count
    let bytesPerSample = 2
    let dataSize = numSamples * bytesPerSample
    let totalSize = 36 + dataSize

    // RIFF
    data.append("RIFF".data(using: .ascii)!)
    data.append(UInt32(totalSize).littleEndianData)
    data.append("WAVE".data(using: .ascii)!)

    // fmt chunk
    data.append("fmt ".data(using: .ascii)!)
    data.append(UInt32(16).littleEndianData)
    data.append(UInt16(1).littleEndianData)  // PCM
    data.append(UInt16(1).littleEndianData)  // mono
    data.append(UInt32(sampleRate).littleEndianData)
    data.append(UInt32(sampleRate * bytesPerSample).littleEndianData)
    data.append(UInt16(bytesPerSample).littleEndianData)
    data.append(UInt16(16).littleEndianData)

    // data chunk
    data.append("data".data(using: .ascii)!)
    data.append(UInt32(dataSize).littleEndianData)
    for s in pcm {
        let clipped = max(-1.0, min(1.0, s))
        let i16 = Int16(clipped * 32767)
        data.append(UInt16(bitPattern: i16).littleEndianData)
    }

    try data.write(to: URL(fileURLWithPath: path))
}

extension UInt16 {
    var littleEndianData: Data {
        var value = self.littleEndian
        return Data(bytes: &value, count: MemoryLayout<UInt16>.size)
    }
}

extension UInt32 {
    var littleEndianData: Data {
        var value = self.littleEndian
        return Data(bytes: &value, count: MemoryLayout<UInt32>.size)
    }
}

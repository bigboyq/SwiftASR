import Testing
import Foundation
@testable import SwiftASR

@Test func mvnParseVAD() throws {
    let path = TestSupport.projectPath("Resources/Models/vad/am.mvn")
    guard FileManager.default.fileExists(atPath: path) else { return }
    let text = try String(contentsOfFile: path, encoding: .utf8)
    let (addShift, rescale) = try FbankExtractor.parseMvn(text: text)
    #expect(addShift.count == 400)
    #expect(rescale.count == 400)
    // rescale 应该全 > 0（是 1/sqrt(var)）
    #expect(rescale.allSatisfy { $0 > 0 })
    // addShift 头几个值应该跟 raw 文件一致
    #expect(abs(addShift[0] - -8.311879) < 0.001)
}

@Test func mvnParseParaformer() throws {
    let path = TestSupport.projectPath("Resources/Models/seaco_paraformer/am.mvn")
    guard FileManager.default.fileExists(atPath: path) else { return }
    let text = try String(contentsOfFile: path, encoding: .utf8)
    let (addShift, rescale) = try FbankExtractor.parseMvn(text: text)
    #expect(addShift.count == 560)
    #expect(rescale.count == 560)
}

@Test func shortAudioUsesSingleAdaptiveFbankWorker() {
    let pcm = [Float](repeating: 0, count: 5 * AudioTimebase.standard.sampleRate)
    #expect(FbankExtractor().effectiveWorkerCount(pcmData: pcm) == 1)
}

import Testing
import OnnxRuntimeBindings
@testable import SwiftASR

@Test func seacoEmbeddingModelExposesHotwordEmbeddingContract() throws {
    let path = ModelTestPaths.modelsRoot
        .appendingPathComponent("seaco_paraformer/model_eb_quant.onnx").path
    let env = try ORTEnv(loggingLevel: .warning)
    let options = try ORTSessionOptions()
    let session = try ORTSession(env: env, modelPath: path, sessionOptions: options)

    let inputs = try session.inputNames()
    let outputs = try session.outputNames()
    print("SeACo embedding model: inputs=\(inputs) outputs=\(outputs)")

    #expect(inputs.contains("hotword"))
    #expect(outputs.contains("hw_embed"))
}

@Test func seacoEmbeddingModelEncodesOfficialNoBiasToken() throws {
    let path = ModelTestPaths.modelsRoot
        .appendingPathComponent("seaco_paraformer/model_eb_quant.onnx").path
    let env = try ORTEnv(loggingLevel: .warning)
    let options = try ORTSessionOptions()
    let session = try ORTSession(env: env, modelPath: path, sessionOptions: options)
    var tokens = ASRONNXEngine.noBiasHotwordTokens()
    let data = Data(bytes: &tokens, count: tokens.count * MemoryLayout<Int32>.size)
    let hotword = try ORTValue(
        tensorData: NSMutableData(data: data),
        elementType: .int32,
        shape: [1, 10]
    )

    let result = try session.run(
        withInputs: ["hotword": hotword],
        outputNames: ["hw_embed"],
        runOptions: nil
    )
    let output = try result["hw_embed"]!.tensorData() as Data
    let values = output.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    print("SeACo NO_BIAS embedding values=\(values.count)")
    #expect(values.count == 10 * 512)
    #expect(values.prefix(512).contains { $0 != 0 })
}

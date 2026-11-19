import Foundation
import LazySendScan
import OnnxRuntimeBindings
import os

private let modelLog = Logger(subsystem: "LazySend", category: "CornerModel")

/// Why the corner model did not run.
public enum CornerModelError: Error, Equatable {
    /// The model's file is not in this build (scripts/fetch_docaligner.sh was not run).
    case missing
    /// This build of ONNX Runtime has no Core ML.
    case noCoreML
    /// The input or the model's answer is not of the shape expected.
    case unreadable
}

/// DocAligner's FastViT-T8 corner model (DocsaidLab/DocAligner 1.1.1, Apache-2.0, see Models/DocAligner-LICENSE.txt) on
/// ONNX Runtime: the page finder of the scan mode. Its file is fetched into this target's Models folder by
/// scripts/fetch_docaligner.sh; without it `isAvailable` is false and `heatmaps` answers nil.
///
/// The session is made on the first run and kept, with all graph optimizations and, when `coreML`, Core ML in front (the
/// Neural Engine where there is one). When Core ML cannot take the model, or fails to run it, the CPU runs it alone from
/// then on; why is kept in `coreMLProblem` and logged once. One run at a time.
public final class FastViTCornerModel: CornerModel, @unchecked Sendable {
    public static let shared = FastViTCornerModel()
    static let fileName = "fastvit_t8_h_e_bifpn_256_fp32"

    /// The model's file; nil when it was not fetched.
    public static let url: URL? = Bundle.module.url(forResource: fileName, withExtension: "onnx", subdirectory: "Models")

    public static var isAvailable: Bool { url != nil }

    /// Core ML is tried in front of the CPU.
    public let coreML: Bool
    private let lock = NSLock()
    private var env: ORTEnv?
    private var session: ORTSession?
    private var onCoreML = false
    private var problem: String?

    public init(coreML: Bool = true) {
        self.coreML = coreML
    }

    /// Why Core ML is not used though it was asked for; nil when it is, or before the first run.
    public var coreMLProblem: String? {
        lock.lock()
        defer { lock.unlock() }
        return problem
    }

    public func heatmaps(_ input: [Float]) -> CornerHeatmaps? {
        do {
            return try run(input)
        } catch {
            modelLog.error("Corner model did not run: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// The heatmaps for `input` (`CornerModelInput.make`).
    public func run(_ input: [Float]) throws -> CornerHeatmaps {
        let side = CornerModelInput.side
        guard input.count == 3 * side * side else { throw CornerModelError.unreadable }
        lock.lock()
        defer { lock.unlock() }
        let loaded = try loadedSession()
        let data = NSMutableData(length: input.count * MemoryLayout<Float>.size) ?? NSMutableData()
        input.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            if let base = bytes.baseAddress {
                data.replaceBytes(in: NSRange(location: 0, length: bytes.count), withBytes: base)
            }
        }
        let shape: [NSNumber] = [1, 3, NSNumber(value: side), NSNumber(value: side)]
        let value = try ORTValue(tensorData: data, elementType: .float, shape: shape)
        let outputs: [String: ORTValue]
        do {
            outputs = try loaded.run(withInputs: ["img": value], outputNames: ["heatmap"], runOptions: nil)
        } catch where onCoreML {
            let cpu = try cpuSession(after: error)
            outputs = try cpu.run(withInputs: ["img": value], outputNames: ["heatmap"], runOptions: nil)
        }
        guard let heatmap = outputs["heatmap"] else { throw CornerModelError.unreadable }
        let dims = try heatmap.tensorTypeAndShapeInfo().shape
        guard dims.count == 4, dims[1].intValue == 4 else { throw CornerModelError.unreadable }
        let height = dims[2].intValue
        let width = dims[3].intValue
        let count = 4 * width * height
        let answer = try heatmap.tensorData()
        guard width > 0, height > 0, answer.length >= count * MemoryLayout<Float>.size else {
            throw CornerModelError.unreadable
        }
        var values = [Float](repeating: 0, count: count)
        values.withUnsafeMutableBytes { (target: UnsafeMutableRawBufferPointer) in
            target.copyMemory(from: UnsafeRawBufferPointer(start: answer.bytes, count: count * MemoryLayout<Float>.size))
        }
        return CornerHeatmaps(values: values, width: width, height: height)
    }

    private func loadedSession() throws -> ORTSession {
        if let kept = session {
            return kept
        }
        guard let url = FastViTCornerModel.url else { throw CornerModelError.missing }
        let environment: ORTEnv
        if let made = env {
            environment = made
        } else {
            environment = try ORTEnv(loggingLevel: .warning)
            env = environment
        }
        if coreML {
            do {
                let made = try FastViTCornerModel.makeSession(url.path, env: environment, coreML: true)
                session = made
                onCoreML = true
                return made
            } catch {
                return try cpuSession(after: error)
            }
        }
        let made = try FastViTCornerModel.makeSession(url.path, env: environment, coreML: false)
        session = made
        return made
    }

    /// The CPU's session in place of Core ML's, which failed with `error`.
    private func cpuSession(after error: Error) throws -> ORTSession {
        guard let url = FastViTCornerModel.url, let environment = env else { throw CornerModelError.missing }
        let made = try FastViTCornerModel.makeSession(url.path, env: environment, coreML: false)
        session = made
        onCoreML = false
        problem = error.localizedDescription
        modelLog.notice("Corner model runs on the CPU, Core ML failed: \(error.localizedDescription, privacy: .public)")
        return made
    }

    private static func makeSession(_ path: String, env: ORTEnv, coreML: Bool) throws -> ORTSession {
        let options = try ORTSessionOptions()
        try options.setGraphOptimizationLevel(.all)
        try options.setIntraOpNumThreads(2)
        if coreML {
            guard ORTIsCoreMLExecutionProviderAvailable() else { throw CornerModelError.noCoreML }
            let coreMLOptions = ORTCoreMLExecutionProviderOptions()
            coreMLOptions.createMLProgram = true
            try options.appendCoreMLExecutionProvider(with: coreMLOptions)
        }
        return try ORTSession(env: env, modelPath: path, sessionOptions: options)
    }
}

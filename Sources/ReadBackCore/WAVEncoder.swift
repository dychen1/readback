import Foundation

public enum WAVEncoder {
    public static func encodeFloat32PCM(samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * MemoryLayout<Float>.size)
        for sample in samples {
            let finiteSample = sample.isFinite ? sample : 0
            data.appendLittleEndian(finiteSample.clamped(to: -1...1).bitPattern)
        }
        return data
    }

    public static func encodeFloat32Mono(samples: [Float], sampleRate: Int) -> Data {
        precondition(sampleRate > 0)
        let bytesPerSample = MemoryLayout<Float>.size
        let payloadSize = samples.count * bytesPerSample

        var data = Data(capacity: 44 + payloadSize)
        data.append(contentsOf: "RIFF".utf8)
        data.appendLittleEndian(UInt32(36 + payloadSize))
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(3))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt32(sampleRate))
        data.appendLittleEndian(UInt32(sampleRate * bytesPerSample))
        data.appendLittleEndian(UInt16(bytesPerSample))
        data.appendLittleEndian(UInt16(bytesPerSample * 8))
        data.append(contentsOf: "data".utf8)
        data.appendLittleEndian(UInt32(payloadSize))

        data.append(encodeFloat32PCM(samples: samples))
        return data
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

private extension Data {
    mutating func appendLittleEndian<Value: FixedWidthInteger>(_ value: Value) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}

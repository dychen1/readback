import Foundation
import ReadBackCore

func wavEncoderTests() -> [TestCase] {
    [
        TestCase(name: "WAV encoder writes float mono samples") {
            let data = WAVEncoder.encodeFloat32Mono(
                samples: [-1, 0, 0.5, 1],
                sampleRate: 24_000
            )

            try expectEqual(String(decoding: data[0..<4], as: UTF8.self), "RIFF", "RIFF tag")
            try expectEqual(String(decoding: data[8..<12], as: UTF8.self), "WAVE", "WAVE tag")
            try expectEqual(data.littleEndianUInt16(at: 20), 3, "IEEE float format")
            try expectEqual(data.littleEndianUInt16(at: 22), 1, "channel count")
            try expectEqual(data.littleEndianUInt32(at: 24), 24_000, "sample rate")
            try expectEqual(data.littleEndianUInt16(at: 34), 32, "bits per sample")
            try expectEqual(data.littleEndianUInt32(at: 40), 16, "payload byte count")
            try expectEqual(data.count, 60, "WAV byte count")
            try expectEqual(data.littleEndianFloat32(at: 44), -1, "first sample")
            try expectEqual(data.littleEndianFloat32(at: 52), 0.5, "third sample")
        },
        TestCase(name: "WAV encoder clamps non-finite and out-of-range samples") {
            let data = WAVEncoder.encodeFloat32Mono(
                samples: [-2, .nan, .infinity, 2],
                sampleRate: 24_000
            )

            try expectEqual(data.littleEndianFloat32(at: 44), -1, "low clamp")
            try expectEqual(data.littleEndianFloat32(at: 48), 0, "NaN replacement")
            try expectEqual(data.littleEndianFloat32(at: 52), 0, "infinity replacement")
            try expectEqual(data.littleEndianFloat32(at: 56), 1, "high clamp")
        },
        TestCase(name: "PCM encoder emits raw little-endian float samples") {
            let data = WAVEncoder.encodeFloat32PCM(samples: [0.5, -0.5])
            try expectEqual(data.count, 8, "PCM byte count")
            try expectEqual(data.littleEndianFloat32(at: 0), 0.5, "first PCM sample")
            try expectEqual(data.littleEndianFloat32(at: 4), -0.5, "second PCM sample")
        },
    ]
}

private extension Data {
    func littleEndianUInt16(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }

    func littleEndianUInt32(at offset: Int) -> UInt32 {
        UInt32(self[offset])
            | UInt32(self[offset + 1]) << 8
            | UInt32(self[offset + 2]) << 16
            | UInt32(self[offset + 3]) << 24
    }

    func littleEndianFloat32(at offset: Int) -> Float {
        Float(bitPattern: littleEndianUInt32(at: offset))
    }
}

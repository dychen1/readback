import Foundation
import ReadBackCore

func audioPlayerTests() -> [TestCase] {
    [
        TestCase(name: "audio player keeps a selected playback rate for the next clip") {
            let player = await AVFoundationAudioPlayer()

            await player.setPlaybackRate(1.75)

            let rate = await player.playbackRate
            try expectEqual(rate, 1.75, "selected playback rate")
        },
        TestCase(name: "audio player clamps playback rate to AVAudioPlayer limits") {
            let player = await AVFoundationAudioPlayer()

            await player.setPlaybackRate(3.0)
            let highRate = await player.playbackRate
            await player.setPlaybackRate(0.25)
            let lowRate = await player.playbackRate

            try expectEqual(highRate, 2.0, "maximum playback rate")
            try expectEqual(lowRate, 0.5, "minimum playback rate")
        },
        TestCase(name: "audio player changes the rate of an active clip") {
            let player = await AVFoundationAudioPlayer()
            let clip = AudioClip(data: silentWAV(duration: 2.0), format: .wav)
            let playback = Task { try await player.play(clip) }

            try await wait(for: .milliseconds(200))
            await player.setPlaybackRate(2.0)
            let activeRate = await player.activePlaybackRate
            await player.stop()
            _ = try? await playback.value

            try expectEqual(activeRate, 2.0, "active playback rate")
        },
        TestCase(name: "audio player applies the selected rate to a later clip") {
            let player = await AVFoundationAudioPlayer()
            let clip = AudioClip(data: silentWAV(duration: 1.5), format: .wav)
            await player.setPlaybackRate(2.0)
            let clock = ContinuousClock()
            let started = clock.now

            try await player.play(clip)

            let elapsed = started.duration(to: clock.now)
            try expect(
                elapsed < .milliseconds(1_200),
                "next clip should use the selected rate; elapsed \(elapsed)"
            )
        },
    ]
}

private func silentWAV(duration: Double, sampleRate: Int = 8_000) -> Data {
    let channelCount: UInt16 = 1
    let bitsPerSample: UInt16 = 16
    let sampleCount = Int(duration * Double(sampleRate))
    let bytesPerSample = Int(bitsPerSample / 8)
    let dataSize = sampleCount * Int(channelCount) * bytesPerSample
    let byteRate = UInt32(sampleRate) * UInt32(channelCount) * UInt32(bytesPerSample)
    let blockAlign = channelCount * UInt16(bytesPerSample)

    var data = Data()
    data.append(contentsOf: "RIFF".utf8)
    data.appendLittleEndian(UInt32(36 + dataSize))
    data.append(contentsOf: "WAVE".utf8)
    data.append(contentsOf: "fmt ".utf8)
    data.appendLittleEndian(UInt32(16))
    data.appendLittleEndian(UInt16(1))
    data.appendLittleEndian(channelCount)
    data.appendLittleEndian(UInt32(sampleRate))
    data.appendLittleEndian(byteRate)
    data.appendLittleEndian(blockAlign)
    data.appendLittleEndian(bitsPerSample)
    data.append(contentsOf: "data".utf8)
    data.appendLittleEndian(UInt32(dataSize))
    data.append(Data(repeating: 0, count: dataSize))
    return data
}

private extension Data {
    mutating func appendLittleEndian<Value: FixedWidthInteger>(_ value: Value) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}

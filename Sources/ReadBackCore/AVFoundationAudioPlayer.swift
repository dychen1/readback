import AVFoundation
import Foundation

public enum AudioPlayerError: Error, Equatable, Sendable {
    case unsupportedFormat(AudioFormat)
    case playbackDidNotStart
}

@MainActor
public final class AVFoundationAudioPlayer: NSObject, AudioPlaying, AVAudioPlayerDelegate, @unchecked Sendable {
    private var audioPlayer: AVAudioPlayer?
    private var completion: CheckedContinuation<Void, any Error>?
    private var playbackGeneration = 0
    public private(set) var playbackRate = PlaybackRate.default

    public override init() {}

    public func play(_ clip: AudioClip) async throws {
        guard clip.format == .wav else {
            throw AudioPlayerError.unsupportedFormat(clip.format)
        }
        try Task.checkCancellation()
        playbackGeneration += 1
        let generation = playbackGeneration

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                do {
                    finishPlayback(throwing: CancellationError())
                    let player = try AVAudioPlayer(data: clip.data)
                    player.delegate = self
                    player.enableRate = true
                    player.rate = Float(playbackRate)
                    player.prepareToPlay()
                    audioPlayer = player
                    completion = continuation
                    guard player.play() else {
                        finishPlayback(throwing: AudioPlayerError.playbackDidNotStart)
                        return
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.stopPlayback(generation: generation)
            }
        }
    }

    public func stop() async {
        stopCurrentPlayback()
    }

    public func pause() async {
        audioPlayer?.pause()
    }

    public func resume() async {
        guard let audioPlayer, !audioPlayer.isPlaying else { return }
        if !audioPlayer.play() {
            finishPlayback(
                for: ObjectIdentifier(audioPlayer),
                throwing: AudioPlayerError.playbackDidNotStart
            )
        }
    }

    public func setPlaybackRate(_ rate: Double) {
        playbackRate = PlaybackRate.clamped(rate)
        audioPlayer?.rate = Float(playbackRate)
    }

    public nonisolated func audioPlayerDidFinishPlaying(
        _ player: AVAudioPlayer,
        successfully flag: Bool
    ) {
        let playerID = ObjectIdentifier(player)
        Task { @MainActor in
            if flag {
                finishPlayback(for: playerID)
            } else {
                finishPlayback(
                    for: playerID,
                    throwing: AudioPlayerError.playbackDidNotStart
                )
            }
        }
    }

    public nonisolated func audioPlayerDecodeErrorDidOccur(
        _ player: AVAudioPlayer,
        error: (any Error)?
    ) {
        let playerID = ObjectIdentifier(player)
        Task { @MainActor in
            finishPlayback(
                for: playerID,
                throwing: error ?? AudioPlayerError.playbackDidNotStart
            )
        }
    }

    private func stopCurrentPlayback() {
        audioPlayer?.stop()
        finishPlayback(throwing: CancellationError())
    }

    private func stopPlayback(generation: Int) {
        guard playbackGeneration == generation else { return }
        stopCurrentPlayback()
    }

    private func finishPlayback(
        for expectedPlayerID: ObjectIdentifier? = nil,
        throwing error: (any Error)? = nil
    ) {
        if let expectedPlayerID,
           audioPlayer.map(ObjectIdentifier.init) != expectedPlayerID
        {
            return
        }
        guard let completion else {
            audioPlayer = nil
            return
        }
        self.completion = nil
        audioPlayer = nil
        if let error {
            completion.resume(throwing: error)
        } else {
            completion.resume()
        }
    }
}

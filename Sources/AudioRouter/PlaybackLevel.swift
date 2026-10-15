/// Validated replacement-PCM policy, independent of hardware volume and input
/// metering. A mute retains the user's gain for unmute.
struct PlaybackLevel: Equatable, Sendable {
    let gain: Float
    let muted: Bool
    static let unity = PlaybackLevel(gain: 1, muted: false)!

    init?(gain: Float, muted: Bool) {
        guard gain.isFinite, (0...1).contains(gain) else { return nil }
        self.gain = gain
        self.muted = muted
    }

    var effectiveGain: Float { muted ? 0 : gain }
}

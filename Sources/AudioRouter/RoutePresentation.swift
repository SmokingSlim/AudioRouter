/// UI interpretation of lifecycle facts supplied by one route's audio owner.
/// Suppression confirmation is a property request, never measured audibility.
struct RoutePresentation: Equatable {
    let title: String
    let detail: String

    init(hasResources: Bool, isRunning: Bool, isStopping: Bool,
         restorationPending: Bool, suppressionRequested: Bool,
         hasDestination: Bool, canSuppressOriginal: Bool, exclusiveOutputPending: Bool = false) {
        if !hasResources {
            title = "No active route"
            detail = "Original playback is unchanged. Choose a hardware output on an application row to start."
        } else if restorationPending {
            title = "Original playback restoration pending"
            detail = "This route's audio resources are retained. Choose Original output to retry restoration/cleanup; other routes are independent."
        } else if isStopping || !isRunning {
            title = "Audio cleanup pending"
            detail = "This route's remaining audio resources are retained. Choose Original output to retry cleanup before replacing this route."
        } else if !hasDestination {
            title = "Monitoring"
            detail = "Capture only. No replacement output or original-output suppression."
        } else if suppressionRequested {
            title = ""
            detail = "macOS confirmed the suppression property. This is not a measurement of audible output."
        } else if exclusiveOutputPending {
            title = "Starting…"
            detail = "Original playback stays unmuted during startup. Suppression will be requested automatically once replacement PCM is ready."
        } else if canSuppressOriginal {
            title = "Also playing on original output"
            detail = "Audio is duplicated. Choose Original output to stop, then select hardware to restart exclusive routing."
        } else {
            title = "Starting…"
            detail = "Original playback stays unmuted while waiting for stable replacement PCM."
        }
    }
}

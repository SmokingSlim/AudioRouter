/// UI interpretation of lifecycle facts supplied by one route's audio owner.
/// Suppression confirmation is a property request, never measured audibility.
struct RoutePresentation: Equatable {
    let title: String
    let detail: String
    let suppressionTitle: String
    let suppressionEnabled: Bool
    let stopTitle: String

    init(hasResources: Bool, isRunning: Bool, isStopping: Bool,
         restorationPending: Bool, suppressionRequested: Bool,
         hasDestination: Bool, canSuppressOriginal: Bool, exclusiveOutputPending: Bool = false) {
        suppressionTitle = suppressionRequested || restorationPending ?
            "Restore original (keep mirror)" : "Use exclusively"
        suppressionEnabled = hasResources && isRunning && !isStopping &&
            !restorationPending && !exclusiveOutputPending && hasDestination && (suppressionRequested || canSuppressOriginal)
        stopTitle = isStopping || restorationPending || (hasResources && !isRunning) ?
            "Retry restore / cleanup" : "Stop & restore original"
        if !hasResources {
            title = "No active route"
            detail = "Original playback is unchanged. Choose a hardware output on an application row to start."
        } else if restorationPending {
            title = "Original playback restoration pending"
            detail = "This route's audio resources are retained. Retry restore / cleanup; other routes are independent."
        } else if isStopping || !isRunning {
            title = "Audio cleanup pending"
            detail = "This route's remaining audio resources are retained. Retry cleanup before replacing this route."
        } else if !hasDestination {
            title = "Monitoring · original playback unchanged"
            detail = "Capture only. No replacement output or original-output suppression."
        } else if suppressionRequested {
            title = "Exclusive output · suppression requested"
            detail = "macOS confirmed the suppression property. This is not a measurement of audible output."
        } else if exclusiveOutputPending {
            title = "Routing · waiting for stable playback"
            detail = "Original playback stays unmuted during startup. Suppression will be requested automatically once replacement PCM is ready."
        } else if canSuppressOriginal {
            title = "Mirror ready · original playback unchanged"
            detail = "Audio is duplicated. Use exclusively to suppress original playback again."
        } else {
            title = "Mirror · waiting for stable playback"
            detail = "Original playback stays unmuted. Exclusive output becomes available when replacement PCM is ready."
        }
    }
}

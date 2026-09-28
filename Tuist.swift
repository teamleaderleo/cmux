import ProjectDescription

// Tuist spike configuration. No fullHandle: the spike never connects to a Tuist
// server, so no cache or analytics leave the build machine.
let tuist = Tuist(
    project: .tuist(
        compatibleXcodeVersions: .upToNextMajor("26.0")
    )
)

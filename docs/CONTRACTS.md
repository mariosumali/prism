# PRISM — Internal API Contracts

This document pins the public API of every component so they can be authored
independently and compile together. **If you are implementing a component,
conform to these signatures exactly.** Supporting value types already exist
in the repo — read them before writing code:

- `PRISMShared/SharedTypes.h`, `PRISMShared/RingBuffer.h` — audio SHM ring (C)
- `PRISMShared/PixelFormats.swift` — `VideoFormat`, pixel-buffer attributes
- `PRISM/Pipeline/EffectStage.swift` — `StageID`, `StageCost`, `LatencyPolicy`,
  `EffectStage`, `LatencyReport`, `PipelineError`
- `PRISM/Pipeline/StageSettings.swift` — per-stage Codable settings,
  `PipelineConfiguration`, `Preset`, `HotkeyCombo`. `PipelineConfiguration`
  writes its stage table in **two shapes** (§5.5): `stageFlags`, an object
  keyed by the stage's raw name, decoded one entry at a time so an unknown
  stage costs its own switch and not the table, and the legacy `flags`
  alternating array, restricted to `legacyFlagStages` — the stages a build
  that predates `stageFlags` can name — so an exported preset still switches
  effects on over there. A stage added from here on travels in `stageFlags`
  only. Includes `StyleLayer` and
  `StyleSettings`, the persisted struct with **two live shapes** (§5.29):
  `layers` wins whenever the key is present at all, even as an empty array,
  and the flat `effect` / `intensity` / `audioReactive` triple builds slot 0
  only when it is absent — and is still *written*, mirroring slot 0, so a
  preset exported here still loads its primary effect in a build that
  predates the stack. `renderableLayers` is what the stage runs: no `Normal`,
  no zero intensity, at most two, at most one motion effect
- `PRISM/Pipeline/Settings/GestureSettings.swift` — `HandPose`,
  `GestureAction`, `GestureBinding`, `GestureSettings` (§5.31); `isActive` is
  the demand gate for the recogniser, and `dwellSeconds(for:)` floors panic
  at 1.5 s whatever the hold slider says
- `PRISM/AppStateTypes.swift` — `CameraDeviceInfo`, `AudioDeviceInfo`,
  `CameraClient`, `MenuBarState`, `PermissionState`, `ExtensionStatus`,
  `SetupStatus`, `WarningMessage`, `NoticeMessage`,
  `CapturePhase`, `CaptureResult`, `PresenceState`, `VideoSourceKind`,
  `VideoSourceSelection`, `ScreenSourceInfo`, `GestureEvent`, `ClipState`,
  `StageStatus`, `PopoverSection`, `ReplayTransportClaim`, `PanicHold`;
  the last two are the "who is on air, and does the UI agree" bookkeeping —
  `ReplayTransportClaim.claimed(by:)` derives the away/lagging/catching-up
  flags from whoever claimed the one §5.9 transport (so no claimant can leave
  another's flag standing) and `connectionMayClaimTransport` keeps §5.14 off
  a transport something is already substituting on, while `PanicHold` records
  what the §5.11 chord engaged so the release undoes only that
- `PRISM/Pipeline/Settings/AppRuleSettings.swift` — `AppAccess`, `AppRule`,
  `AppRulesSettings`, `AppRuleMatch`, `AppRuleResolver`, `AccessPolicy` (§5.18)
- `PRISM/Pipeline/Settings/PresenceSettings.swift` — `PresenceAction`,
  `PresenceSettings` (§5.28); `isActive` is the demand gate for the detector
- `PRISM/System/Hotkeys.swift` — `ShortcutAction`, `Hotkeys`
- `PRISM/System/HotkeyBindings.swift` — `HotkeyBindings`, `ShortcutConflict` (§5.19)
- `PRISM/System/SessionLog.swift` — `SessionEvent`, `SessionLog` (§5.21).
  Rows may name devices and applications; they may not name the contents of
  anything, and specifically not a shared window's title — an export is a
  file the user attaches to a support thread. `ScreenSourceInfo.logName` is
  the redaction, and it is applied at the call site rather than by the log
- `PRISM/Capture/AudioDelayLine.swift` — `AudioDelayLine`, the §5.12
  circular PCM line. RT-safe, and `reset()` is the one that matters: it is
  what makes going off air a complete forgetting
- `PRISMKernels/KernelTypes.h` — kernel parameter structs (bridged to Swift)

Language: Swift 5.9, macOS 13.0 deployment target. No Swift 6 concurrency
annotations (`@MainActor` on UI-facing classes is fine; no `Sendable`
churn).

**One third-party dependency**: `argmaxinc/argmax-oss-swift` (MIT), product
`WhisperKit`, pinned to an exact version rather than a range — its manifest
declares `.macOS(.v13)` while its README says macOS 14, and a minor release
that quietly raised the floor would orphan every Ventura user of the camera
extension. It may be imported only from `PRISM/AI/Engines/`, which
`project.yml` excludes from `PRISMTests`; everything above that directory
talks to `SpeechRecognizing`, and `AppState` reaches the real engine through
`SpeechEngineRegistry` so the test bundle compiles with nothing resolved.

**No network access PRISM did not ask you about** (§7). No analytics, no
telemetry, no crash reporting, no update check — unchanged. Two
user-initiated exceptions (§5.32, §5.33) are confined to
`PRISM/AI/LLM/LLMTransport.swift`, which CI verifies is the only file in the
tree naming a networking API. A stock build, with no AI provider configured,
opens no sockets at all.

---

## Fixed identifiers (all components)

```
App bundle ID:            horse.prism.PRISM
Extension bundle ID:      horse.prism.PRISM.camera
Audio plug-in bundle ID:  horse.prism.PRISM.audio
App group:                TEAMID.horse.prism.PRISM

Camera device name:       "PRISM Camera"
Camera device UID:        "horse.prism.PRISM.camera.device"
Camera model UID:         "PRISM Virtual Camera"
Source stream UID:        "horse.prism.PRISM.camera.stream.source"
Sink stream UID:          "horse.prism.PRISM.camera.stream.sink"

Audio device name:        "PRISM Microphone"
Audio device UID:         "horse.prism.PRISM.audio.device"
SHM name:                 PRISM_SHM_NAME ("/horse.prism.audio.v1")
```

### CMIO custom properties (extension ↔ app control channel)

App Groups do not cross the user/root boundary (§3.1), so the extension and
app talk through CMIO custom properties on the **device** object. FourCC
selectors:

| Selector | Name | Type | Direction | Meaning |
|---|---|---|---|---|
| `'pfmt'` | format list | UTF-8 JSON data | app → extension | published format set: `[{"width":1920,"height":1080,"frameRate":30},…]`. Extension re-publishes both streams and persists the list in its own container. |
| `'clnt'` | clients | UTF-8 JSON data | extension → app | array of streaming client signing IDs, e.g. `["us.zoom.xos"]`. Updated on start/stop stream. |
| `'hoff'` | handoff ms | Float64 (8 bytes) | extension → app | rolling mean sink-receive → source-emit, milliseconds. |
| `'afmt'` | active format | UTF-8 JSON data | extension → app | the single format a client most recently negotiated on the source stream; empty until one has. |
| `'polc'` | access policy | UTF-8 JSON data | app → extension | §5.18 per-app policy: `{"version":1,"defaultAccess":"allow","blocked":[…],"allowed":[…]}`. Extension persists it and enforces it in `authorizedToStartStream`. Write-only in practice — reads serve empty data. |
| `'blkd'` | blocked clients | UTF-8 JSON data | extension → app | signing IDs refused by policy in the last 30 s, e.g. `["us.zoom.xos"]`. Lets the app explain a dark tile. |

CMIOExtension side declares these as
`CMIOExtensionProperty(rawValue: "4cc_pfmt_glob_0000")` (same pattern for
`clnt`, `hoff`, `afmt`, `polc`, `blkd`) in `availableProperties` of the
**device** source, handles them in `deviceProperties(forProperties:)` /
`setDeviceProperties(_:)`.
App side reads/writes them with the CMIO C API
(`CMIOObjectGetPropertyData` / `CMIOObjectSetPropertyData`) using
`CMIOObjectPropertyAddress(mSelector: fourCC, mScope:
kCMIOObjectPropertyScopeGlobal, mElement: kCMIOObjectPropertyElementMain)`
on the PRISM Camera device object.

The extension defines its own tiny Codable mirror of the format entry
(`struct ExtFormat: Codable { var width: Int; var height: Int; var
frameRate: Int }`) — it must not link app sources. JSON keys must match
`VideoFormat`'s (`width`, `height`, `frameRate`).

It mirrors `AccessPolicy` the same way as `ExtAccessPolicy`, with **every
field optional**. Signing IDs travel case-folded, and the extension folds
before comparing, so its set test agrees with `AppRule.matches` on the app
side. `'polc'` is the one payload whose failure mode is a camera
that will not start, so the extension fails open on all of: no policy ever
received, an unreadable file, a `version` above what it understands, and a
signing ID the policy does not mention under `defaultAccess: "allow"`. A
corrupt policy file is deleted rather than left to fail open forever in
silence. The policy is persisted (`policy.json`, beside `formats.json` in the
extension container) because CMIO extensions are launched on demand: an
in-memory policy would be cleared by quitting and reopening the very app the
user blocked.

---

## Metal kernel contract (PRISMKernels ↔ Stages)

All kernels are **compute** kernels (`kernel void`), guarded against
out-of-bounds gid. Textures are `access::sample` / `access::write`,
`float4` BGRA handled as RGBA in-shader (BGRA swizzle is handled by the
texture format, not the shader). Include `KernelTypes.h` for param structs.

| Function | File | Signature (textures / buffers) |
|---|---|---|
| `prism_copy` | Composite.metal | src `[[texture(0)]]`, dst `[[texture(1)]]` |
| `prism_adjust` | Adjust.metal | src t0, dst t1, `constant PRISMAdjustParams&` b0 |
| `prism_lut` | LUT.metal | src t0, dst t1, lut `texture3d<float>` t2, `constant PRISMLUTParams&` b0 |
| `prism_geometry` | Geometry.metal | src t0, dst t1, `constant PRISMGeometryParams&` b0 — applies `uvTransform` (output UV → input UV, 3×3, bottom row 0 0 1); bilinear sample when `useLanczos == 0`, 4-tap-per-axis Lanczos-2 when 1; out-of-range UV → opaque black |
| `prism_blur` | Blur.metal | src t0, dst t1, `constant PRISMBlurParams&` b0 — separable Gaussian along `direction`, sigma = radius/2, clamped ≤ 31 taps |
| `prism_retouch_blur` | Retouch.metal | src t0, dst t1, `constant PRISMRetouchBlurParams&` b0 — one direction of a separable **bilateral**: sigma = radius/2, taps clamped ≤ 21, each tap weighted by `exp(−i²/2σ² − Δluma²/2·rangeSigma²)`. The centre tap weighs 1, so the weight sum can never reach zero |
| `prism_retouch_combine` | Retouch.metal | src t0, smoothed t1, mask t2 (single channel, person = 1), dst t3, `constant PRISMRetouchParams&` b0 — `smoothed` may be lower-resolution and is sampled linearly; gate = Rec.601 skin-chroma membership, × mask when `useMask != 0`; result = `mix(src, smoothed + (src − smoothed)·detail, amount·gate)`, source alpha preserved. `amount == 0` or `detail == 1` reproduces the source exactly |
| `prism_composite` | Composite.metal | sharp t0, blurred t1, mask `texture2d<float>` t2 (single channel, person = 1), dst t3, `constant PRISMCompositeParams&` b0 |
| `prism_output_fit` | Composite.metal | src t0, dst t1, `constant PRISMFitParams&` b0 — scale/offset content, bars are opaque black |
| `prism_crossfade` | Composite.metal | a t0, b t1, dst t2, `constant PRISMCrossfadeParams&` b0 |
| `prism_sharpness` | Composite.metal | src t0, `device float*` b0 (result), `constant PRISMSharpnessParams&` b1 — dispatched as **one** threadgroup of 256 threads; each thread strides a 128×72 sample grid of src, computes 3×3 Laplacian of luma, threadgroup-reduces the variance, thread 0 writes `result[slot]` |
| `prism_thumbnail` | Composite.metal | src t0, `device float*` b0 (result), `constant PRISMThumbnailParams&` b1 — dispatched over the 32×18 thumbnail grid itself (linear filtering does the box-averaging); writes luma into `result[slot·w·h …]` |
| `prism_gaze` | Gaze.metal | src t0, dst t1, `constant PRISMGazeParams&` b0 — per-eye inverse warp: rigid across the iris disc, pinned at the lid ellipse, sclera stretches between. Eyes with `valid == 0` contribute nothing; outside both lid ellipses the output is an exact copy |
| `prism_background_replace` | Layers.metal | src t0, bg t1, mask t2, dst t3, `constant PRISMBackgroundParams&` b0 — mask hardened by `maskContrast` and feathered by `edgeSoftness`; `lightWrap` bleeds background into the rim (peaks at mask 0.5); `useTexture == 0` uses `flatColor` |
| `prism_overlay` | Layers.metal | base t0, layer t1, mask t2, dst t3, `constant PRISMOverlayParams&` b0 — `uvTransform` maps output UV → layer UV (bottom row 0 0 1); outside [0,1] writes base unchanged; chroma/luma key in YCbCr with hue-agnostic despill; `placement == 1` multiplies alpha by `1 − mask` |
| `prism_style_<case>` | Style.metal | one kernel per `StyleEffect` case (23: every case except `normal`), named from the case's raw value. Stateless effects: src t0, dst t1, `constant PRISMStyleParams&` b0. Motion effects (`isTemporal`): src t0, history t1, dst t2, b0 — history holds the previous styled output (the stage blits dst → history each frame); `hasHistory == 0` means undefined history and the output must equal the source exactly (seeds the feedback). Shared contract: intensity 0 reproduces the source exactly (color looks `mix`, warps scale displacement, discrete remaps crossfade, motion effects scale trails); `time` animates VHS/Wave/Underwater/Glitch/Strobe; `aspect` keeps radial and horizontal motion true on screen |

---

## PRISM.app components

### MetalContext (in `PRISM/Pipeline/VideoPipeline.swift`)

```swift
public final class MetalContext {
    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue
    public let library: MTLLibrary            // default library
    public let textureCache: CVMetalTextureCache
    public init() throws
    /// BGRA8 texture view of an IOSurface-backed pixel buffer. Keeps the
    /// CVMetalTexture alive for the frame via the returned wrapper.
    public func makeTexture(from pixelBuffer: CVPixelBuffer) throws -> MTLTexture
    public func makeIntermediate(width: Int, height: Int) throws -> MTLTexture
    public func computePipeline(function: String) throws -> MTLComputePipelineState
}
```

### VideoPipeline (`PRISM/Pipeline/VideoPipeline.swift`)

Owns the stage array (fixed order §3.3), intermediate textures, output
CVPixelBufferPool, FrameRing, crossfade state. Runs entirely on the capture
queue; one MTLCommandBuffer per frame; one commit; one completed-handler.

```swift
public final class VideoPipeline {
    public let metal: MetalContext
    public private(set) var stages: [EffectStage]      // chain order
    public let clipStage: ClipStage
    public let replayStage: ReplayStage
    public let freezeStage: FreezeStage
    public let gazeStage: GazeStage
    public let geometryStage: GeometryStage
    public let adjustStage: AdjustStage
    public let lutStage: LUTStage
    public let blurStage: BlurStage
    public let backgroundStage: BackgroundStage
    public let overlayStage: OverlayStage
    public let styleStage: StyleStage
    public let connectionStage: ConnectionStage
    public let outputFitStage: OutputFitStage

    /// Shared by blur, virtual background, behind-placed overlay layers and
    /// auto-framing. Driven once per frame by the pipeline (§3.3).
    public let segmenter: PersonSegmenter
    /// Shared by eye contact, retouch and face-anchored overlay layers.
    /// Likewise driven once per frame by the pipeline (§3.3).
    public let faceTracker: FaceTracker
    public let replayBuffer: ReplayBuffer
    public let replayPlayer: ReplayPlayer
    /// A few finished frames, scored, so a still can be the sharpest of
    /// them (§5.16). Armed by `applyStudio` from `capture.prefersSharp`;
    /// disarmed it holds nothing.
    public let stillRing: StillRing
    /// Whichever of the camera and the screen is not driving the chain, for
    /// `.live` overlay layers (§5.25). Held while a substituting stage is
    /// engaged.
    let liveFeeds: LiveFeeds
    /// The stages that replace the picture wholesale, and therefore the ones
    /// that hold the live feeds: [.clip, .replay, .freeze]. Every member runs
    /// before `.overlay`; ChainRegistrationTests proves both.
    static let substitutingStages: Set<StageID>
    /// §5.24 — an SCStream is running, so §5.23 charges its queue.
    public func setScreenSourceActive(_ active: Bool)
    /// §5.31 — the gesture recogniser's demand gate, separate from `apply`
    /// for the reason `setPresenceWatching` is: a preset switch must never
    /// be able to start a Vision request.
    public func setGestureWatching(_ watching: Bool)
    /// §5.31 — what shape the hand is in. Like presence, run against
    /// `source` rather than at a position in the chain.
    public let handTracker: HandTracker

    /// Post-effects output: IOSurface-backed buffer ready for the sink,
    /// plus the final texture for the preview. Called on the capture queue.
    public var onOutput: ((CVPixelBuffer, CMTime, MTLTexture) -> Void)?
    /// Per-frame timings for LatencyMonitor. Called on an arbitrary queue.
    public var onTimings: ((StageTimings) -> Void)?
    /// Fires only when the memory plan actually changes (§5.23).
    public var onResourcePlan: ((ResourcePlan) -> Void)?

    /// One request per modality per frame, one modality per frame, and the
    /// seam a new recogniser registers through (§5.23).
    public let vision: VisionCoordinator
    /// What ResourceGovernor granted at the current format; the ring depths
    /// are already following it.
    public private(set) var resourcePlan: ResourcePlan

    public init(metal: MetalContext) throws
    public func configure(outputFormat: VideoFormat)
    /// Live camera frame. Also drives clip/freeze substitution.
    public func submitCameraFrame(_ buffer: CVPixelBuffer, at time: CMTime)
    /// Heartbeat when no camera is available (timer-driven at output fps)
    /// so clip playback and freeze keep producing frames. A freeze deferred
    /// for want of a frame to hold takes hold here too — its placeholder is
    /// what is on air, and a freeze that never engages leaves the §5.25 live
    /// layers moving under a frozen UI.
    public func tickWithoutCamera(at time: CMTime)
    /// The one way to start ReplayPlayer's transport (§5.9–§5.14). Arms
    /// ReplayStage's bridge frame from the freeze ring BEFORE `start` runs —
    /// `begin()` clears the player's frames synchronously, and a frame
    /// processed in the gap would find the transport active with nothing to
    /// show and pass live video through. A refused start releases it.
    @discardableResult
    public func startReplayTransport(_ start: (ReplayPlayer) -> Bool) -> Bool
    public func setFrozen(_ frozen: Bool)              // §5.2 sharpest-frame
    public var isFrozen: Bool { get }
    public func apply(_ config: PipelineConfiguration)
    /// Arms/disarms the rolling buffer. Separate from `apply` because it is
    /// behaviour, not a look — a preset switch must not start recording.
    public func applyStudio(_ settings: StudioSettings)
    /// Forwards the demand gate to every stage owning a media clock, so an
    /// idle PRISM neither decodes nor fast-forwards on wake.
    public func setDemandActive(_ active: Bool)
    /// 200ms output crossfade (preset switch, clip → live return).
    public func beginCrossfade(durationMs: Double)
    /// §5.16 — the frame a still is written from: the sharpest of the last
    /// 0.5 s when the still ring is armed, otherwise the last frame that
    /// reached the sink. Post-effects either way, and a pool buffer, so the
    /// caller copies the pixels out rather than holding it.
    public func stillFrame() -> CVPixelBuffer?
    /// Preview texture retention: false tears the preview path down (§8.3).
    public var previewEnabled: Bool { get set }
}

public struct StageTimings {
    public var captureToTextureMs: Double
    public var stageMs: [StageID: Double]   // estimated per-stage GPU ms
    public var totalGpuMs: Double
    public var wallMs: Double               // capture callback → push handoff
    public var dropped: Bool
    public init(captureToTextureMs: Double, stageMs: [StageID: Double],
                totalGpuMs: Double, wallMs: Double, dropped: Bool)
}
```

Per-stage GPU ms: measure the whole command buffer via
`gpuStartTime`/`gpuEndTime` and attribute to stages proportionally to a
static weight table, except when a stage is toggled — then use delta
sampling. Simpler alternative (acceptable): encode one command buffer but
also read `MTLCommandBufferDescriptor`-less per-encoder timing is
unavailable, so keep the proportional model. Keep it deterministic and
documented in code.

The weight a stage contributes is `stageWeights[id] × stage.weightMultiplier`,
collected as the chain is walked rather than looked up afterwards — a pass
count is a property of the frame, and by the completed handler the next frame
may have changed it. `weightMultiplier` defaults to 1 for every stage whose
pass count is fixed; Style returns its live pass count (§5.29), so a stacked
pair is charged for two passes rather than averaged into a number that is
wrong for both configurations.

```swift
public protocol EffectStage: AnyObject {
    // …
    var weightMultiplier: Double { get }        // default 1; read after encode()
}
static func attribute(totalGpuMs: Double, to encoded: [StageID],
                      weights: [Double]) -> [StageID: Double]
```

### FrameRing (`PRISM/Pipeline/FrameRing.swift`)

Depth is `ResourceGovernor`'s, not this file's (§5.23): half a second of raw
1080p60 measured 237.9 MB against a 250 MB ceiling. The ring clamps whatever
it is handed to at least `ResourceGovernor.minimumFreezeDepth`, because a
ring with nothing to choose between is a broken freeze rather than a cheap
one.

```swift
public final class FrameRing {
    public private(set) var capacity: Int         // granted depth
    public let sharpnessBuffer: MTLBuffer         // maximumFreezeDepth × Float
    public init(metal: MetalContext, width: Int, height: Int,
                depth: Int) throws
    /// Copy (GPU blit, IOSurface pool) the frame into the ring; returns slot.
    public func record(_ buffer: CVPixelBuffer, at time: CMTime,
                       encoder commandBuffer: MTLCommandBuffer) -> Int
    public func publish(slot: Int)
    /// Sharpest stored frame within [now − windowMs, now] (§5.2:
    /// windowMs 300). Reads sharpnessBuffer CPU-side.
    public func sharpestFrame(nowTime: CMTime, windowMs: Double) -> CVPixelBuffer?
    public func reconfigure(width: Int, height: Int, depth: Int) throws
}
```

### ResourceGovernor (`PRISM/Pipeline/ResourceGovernor.swift`)

The one place that decides how much memory each elastic allocation gets
(§5.23, §7). Pure arithmetic on a format and a ceiling — no Metal, no
allocation — which is what makes `ResourceGovernorTests` able to check the
sum the shipped constants never added up to.

```swift
public struct ResourceDemand: Equatable {
    public var format: VideoFormat                // negotiated output
    public var sourceWidth: Int                   // 0 → not known yet
    public var sourceHeight: Int                  // §3.2 physical size
    public var stillsWantSharpest: Bool           // §5.16 setting armed
    public var screenSourceActive: Bool           // §5.24 SCStream running
    public var replayArmed: Bool                  // §5.9 rolling buffer
    public var replaySeconds: Double
    public var replayMaxHeight: Int
    public var draftChainActive: Bool             // §5.5 preview second chain
}

public enum ResourceTier: String { case full, reduced, minimum, exceeded }

public struct ResourcePlan: Equatable {
    public var format: VideoFormat
    public var freezeDepth: Int                   // FrameRing slots
    public var freezeStride: Int                  // record 1 camera frame in N
    public var stillDepth: Int                    // 0 → stills use last frame
    public var screenDepth: Int                   // SCStream queue, 0 when idle
    public var plannedMB: Double
    public var ceilingMB: Double
    public var tier: ResourceTier
    public var stillsSummary: String?
    public var freezeSpanSeconds: Double { get }  // depth × stride ÷ fps
    public var headroomMB: Double { get }
    public var summary: String { get }            // one sentence, names the number
}

public enum ResourceGovernor {
    public static let ceilingMB: Double = 250     // §7
    public static let minimumFreezeDepth = 6      // slots — a choice, not a frame
    public static let minimumFreezeSeconds = 0.2  // wider than a blink
    public static let preferredFreezeSeconds = 0.5
    public static let maximumFreezeDepth = 64
    public static func preferredDepth(for: VideoFormat) -> Int
    public static func stride(depth: Int, frameRate: Int) -> Int
    public static func frameMB(for: VideoFormat) -> Double
    /// One frame at the size the chain works in: the source's where known,
    /// the output's before the first camera frame lands.
    public static func workingFrameMB(for demand: ResourceDemand) -> Double
    public static func replayMB(for demand: ResourceDemand) -> Double
    public static func draftMB(for demand: ResourceDemand) -> Double
    public static func plan(for demand: ResourceDemand) -> ResourcePlan
}
```

Order of service, fixed and deterministic: freeze's floor, then the still
ring if armed, then whatever is left widening the freeze window toward
`preferredFreezeSeconds`. The floor is taken before the ceiling is weighed —
where it does not fit the tier is `exceeded` and the plan names the figure.

`screenDepth` is `ScreenCapture.queueDepth` while a screen session runs and
joins the *structural* frames rather than the order of service: PRISM cannot
make ScreenCaptureKit's queue smaller, so it is spent before anything elastic
is handed out.

`stageWorkingFrames` (4.5) joins them too — StyleStage's motion history and
stack scratch (§5.29), OverlayStage's layer ping-pong pair (§5.26) and
RetouchStage's two half-resolution scratches (§5.22, a quarter of a frame
each) — and is counted whether or not the stage is on. Costing them on demand
would make the freeze window change length when the user picked an effect, and
a window that reaches back four tenths of a second on Tuesday and three on
Wednesday is worse to reason about than one permanently a few slots shorter.

`replayMB` and `draftMB` join them for the reason `screenDepth` does: the
governor cannot shrink an armed §5.9 buffer or a §5.5 preview, so both are
spent before anything elastic is handed out. Replay is priced as it is
allocated — `ReplayBuffer.recordPoolDepth` raw slots at
`ReplayBuffer.recordSize`, the compressed ring at `ReplayBuffer.bitRate` for
the whole window, and one 32×18 luma thumbnail per recorded frame. The draft
is priced as a second chain: two intermediates, the same
`stageWorkingFrames`, `DraftRenderer.outputPoolDepth` output slots and
`draftVisionMB` for the second segmenter and face tracker.

**Sizes are not interchangeable.** `frameMB` (the negotiated output) prices
the output pool, the fit scratch and the still ring. `workingFrameMB` (the
source, per §3.2 — a 4:3 sensor serving a 16:9 call is strictly larger) prices
`FrameRing`, the two intermediates and every stage-private texture. Pricing
the second group at the first understated the ring by a third.

### VisionCoordinator (`PRISM/Pipeline/VisionCoordinator.swift`)

Decides which Vision request runs on this frame (§5.23). Frame-queue-confined,
no locks. Two hard-coded parities stayed out of each other's way for exactly
as long as there were two of them.

```swift
public final class VisionCoordinator {
    /// Declaration order is the tie-break.
    public enum Modality: Int, CaseIterable, Comparable {
        case face, person, hands, presence
    }

    public struct Decision: Equatable {
        public var demanded: Set<Modality>
        public var running: Modality?             // at most one per frame
        public var ended: Set<Modality>           // demand went to zero → invalidate
    }

    public init()
    /// Registering is what makes a modality eligible; an unregistered one is
    /// inert however loudly it is demanded, which is the seam a new
    /// recogniser arrives through.
    public func register(_ modality: Modality, cadence: Int)
    /// Evaluated once per frame — never cached, because a stage's enabled
    /// flag has six writers.
    public func addConsumer(of modality: Modality, demand: @escaping () -> Bool)
    public func beginFrame() -> Decision           // once, at the top of the frame
    public func reset()
}
```

Pick: among demanded, registered modalities at or past their cadence, the
one with the highest `waited ÷ cadence`, ties to the earlier-declared. With
`face` and `person` both at cadence 2 this reproduces the previous even/odd
alternation exactly, which is what keeps eye contact's smoothing unchanged.
`PersonSegmenter.update` and `FaceTracker.update` take `capture:` from the
decision and run their per-frame work regardless — the smoothing has to
resolve at frame rate, not at detection rate.

Registered cadences: `face` 2, `person` 2, `hands` 3 (§5.31), `presence` 15.
Presence is declared last and cadenced slowest on purpose (§5.28) — it loses
every tie it enters and still runs about once a second, against a threshold
measured in seconds, so it cannot take frames off the eye-contact warp. Hands
sit between: a gesture is held for the better part of a second and only has to
be seen several times, and even at one frame in five under full contention
that is six sightings inside the shortest hold §5.31 allows.

### PresenceDetector (`PRISM/Pipeline/Stages/PresenceDetector.swift`)

Is anyone in front of the camera (§5.28). Same shape and threading as
PersonSegmenter and FaceTracker: `update` on the frame queue, Vision on a
private serial queue, two rotating downsample slots. Runs against the
pipeline's `source` texture rather than at a position in the chain — it asks
whether a person is in front of the camera, not whether one survived the crop,
the backdrop and the layers.

```swift
public final class PresenceDetector {
    public struct Sample: Equatable {
        public var coverage: Double        // largest detected person / frame
        public var date: Date
        public var sequence: UInt64        // consumers must not integrate one twice
    }
    public var isDemanded: Bool            // set per frame from the decision
    /// Fires once per completed detection, on the Vision queue. Pushed rather
    /// than polled: the watcher integrates the gap between consecutive
    /// observations, so a poll slower than the detector halves the rate its
    /// clock advances at.
    public var onSample: ((Sample) -> Void)?
    public var latestSample: Sample? { get }               // thread-safe
    public init(metal: MetalContext) throws
    public func update(commandBuffer: MTLCommandBuffer, input: MTLTexture,
                       capture: Bool)
    public func invalidate()                               // demand went to zero
    static let minimumConfidence: Float = 0.35
    static func coverage(of observations: [VNHumanObservation]) -> Double
}
```

`VNDetectHumanRectanglesRequest` with `upperBodyOnly = true`, capped at
640×360 — a quarter of the pixels segmentation and landmarks are given,
because the answer is a box area compared against a few percent. Largest
observation wins, as it does for faces. A request that threw publishes
nothing: a failure cannot support the claim that the room is empty.

### HandTracker (`PRISM/Pipeline/Stages/HandTracker.swift`)

What shape the hand is in (§5.31). Same shape and threading as
PresenceDetector: `update` on the frame queue, Vision on a private serial
queue, two rotating downsample slots. Runs against the pipeline's `source`
texture — a virtual background erases the hand, a crop can put it outside the
frame, and a freeze would hold a gesture on screen forever.

```swift
public final class HandTracker {
    public struct Sample: Equatable {
        public var pose: HandPose?         // nil = ran, recognised nothing
        public var confidence: Double      // weakest required landmark's
        public var date: Date
        public var sequence: UInt64        // consumers must not integrate one twice
    }
    public var isDemanded: Bool
    public var onSample: ((Sample) -> Void)?               // Vision queue
    public var latestSample: Sample? { get }               // thread-safe
    public init(metal: MetalContext) throws
    public func update(commandBuffer: MTLCommandBuffer, input: MTLTexture,
                       capture: Bool)
    public func invalidate()                               // demand went to zero
    static let minimumJointConfidence: Float = 0.5
    static func bestPose(in: [VNHumanHandPoseObservation]) -> (HandPose?, Double)
}
```

`VNDetectHumanHandPoseRequest`, `maximumHandCount = 2`, capped at 960×540 —
more lines than presence's 640×360 because this has to separate a ring finger
from a little finger. Nine landmarks are required (wrist plus tip and PIP of
four fingers) and the reading's confidence is the WEAKEST of them: averaging
lets three clean fingers carry one invented one over the floor. Most confident
recognised pose wins across hands — the one held up deliberately is the one
Vision is sure about; the one holding a coffee is not. A request that threw
publishes nothing: ending a dwell on the strength of a failure is not an
observation.

### GestureWatch (`PRISM/Pipeline/GestureWatch.swift`)

The §5.31 pose geometry and the four false-positive rules, as pure logic — no
Vision, no frame path, no AppState. The joints arrive as plain points because
`VNRecognizedPoint` cannot be constructed outside the framework, which is what
makes the classifier testable.

```swift
public enum HandJoint: String, CaseIterable, Hashable {
    case wrist
    case indexTip, indexPIP, middleTip, middlePIP
    case ringTip, ringPIP, littleTip, littlePIP
}

public enum HandPoseClassifier {
    /// nil for everything that is not one of the three poses — which is most
    /// of the time, and is the point.
    public static func classify(joints: [HandJoint: CGPoint]) -> HandPose?
    static let extensionRatio: CGFloat = 1.15   // tip past PIP, measured from the wrist
    static let foldRatio: CGFloat = 0.95        // tip inside PIP; between the two, unread
}

public final class GestureWatch {
    public private(set) var holding: HandPose?
    /// Feeds ONE real observation. "The request did not run this frame" is
    /// not a sighting of an empty desk and must not be passed as one.
    @discardableResult
    public func observe(pose: HandPose?, confidence: Double,
                        settings: GestureSettings, at now: Date) -> HandPose?
    public func reset()
    static let maximumStepSeconds: Double = 0.25
}
```

Order inside `observe`: below `clampedConfidence` is no observation at all;
anything that is not the latched pose releases the debounce latch; a changed
or absent pose zeroes the dwell rather than decaying it; the cooldown is
checked BEFORE the dwell, so a pose held straight through it does not fire the
instant it lapses; then `settings.dwellSeconds(for:)`, which floors panic at
1.5 s whatever the slider says. Radial finger test, so the poses survive any
roll; a partly seen hand is not a pose.

### PresenceWatcher (`PRISM/Pipeline/PresenceWatcher.swift`)

The §5.28 hysteresis, as pure logic — no Vision, no frame path, no AppState.
Takes a coverage number and a date, answers with an edge.

```swift
public final class PresenceWatcher {
    public enum Transition: Equatable { case none, left, returned }
    public private(set) var state: PresenceState           // unknown ≠ absent
    public init()
    /// Call only for real measurements. "The detector did not run" is not an
    /// observation of an empty room.
    @discardableResult
    public func observe(coverage: Double, settings: PresenceSettings,
                        at now: Date) -> Transition
    public func reset()
    static let maximumStepSeconds: Double = 2              // one sample's cap
    static let releaseRatio: Double = 0.75                 // the lower threshold
}
```

Edges, not levels: `left` fires once per departure, which is what makes the
manual escape stick. Time advances only on observations and only by
`maximumStepSeconds` each, so a gap becomes a delayed trigger rather than a
false one. Between `coverage × releaseRatio` and `coverage` neither clock
runs and the state holds.

### StillRing (`PRISM/Pipeline/StillRing.swift`)

The output-side counterpart of FrameRing (§5.16): FrameRing holds the
camera, which is what freeze needs and the wrong picture entirely for a
still. Takes references to the pipeline's own pool buffers rather than
copying, so the per-frame cost is one `prism_sharpness` threadgroup inside
the frame's existing command buffer.

```swift
public final class StillRing {
    public static let maximumDepth = 6            // measured 47.6 MB at 1080p, §7
    public static let minimumDepth = 4            // 133 ms at 30 fps — still a choice
    public let sharpnessBuffer: MTLBuffer         // maximumDepth × Float
    public init(metal: MetalContext) throws
    public var isArmed: Bool { get }              // armed AND depth > 0
    /// Disarming releases every held frame immediately.
    public func setArmed(_ armed: Bool)
    /// ResourceGovernor's grant (§5.23); 0 disables the ring without
    /// disarming the setting, and `sharpest` returns nil so `stillFrame()`
    /// falls back to the last frame. Shrinking clears held frames — they
    /// would otherwise sit in slots the cursor no longer reaches.
    public func setDepth(_ depth: Int)
    /// Retains the finished frame; returns the slot to score, or -1.
    public func record(_ buffer: CVPixelBuffer, at hostSeconds: Double) -> Int
    /// Called from the frame's completed handler — the pixels are not final
    /// and the score is not written until the GPU says so.
    public func publish(slot: Int)
    public func sharpest(now: Double, windowSeconds: Double) -> CVPixelBuffer?
}
```

### Export (`PRISM/Export/*.swift`)

Frames onto disk (§5.15, §5.16). One destination layer serves both
features; neither touches the GPU or the frame path.

```swift
public enum CaptureError: LocalizedError, Equatable {
    case folderUnavailable(String), nothingBuffered, noPicture
    case encodingFailed(String)
    // errorDescription is a whole line of UI copy, not an error code (§8.4).
}

public enum CaptureDestination {
    public enum Kind { case still, clip }         // "PRISM" / "PRISM Clip"
    public static func fileName(kind: Kind, date: Date,
                                fileExtension: String) -> String
    public static func uniqueURL(in folder: URL, fileName: String,
                                 exists: (URL) -> Bool) -> URL
    /// Creates and proves writable BEFORE anything is encoded.
    public static func prepare(_ folder: URL) throws -> URL
}

/// The pure half of §5.15: trim to the first keyframe, rebase to zero, and
/// synthesise per-sample durations the ring's `.invalid` ones cannot supply.
public struct ClipPlan: Equatable {
    public struct Frame: Equatable {
        public let index: Int
        public let presentationSeconds: Double
        public let durationSeconds: Double
    }
    public let frames: [ClipPlan.Frame]
    public var durationSeconds: Double { get }
}

public enum ClipPlanner {
    public static func plan(times: [Double], keyframes: [Bool]) -> ClipPlan?
}

public enum ClipExporter {
    /// AVAssetWriter with `outputSettings: nil` — a remux, never a
    /// re-encode. Cancels and deletes the partial file on any failure.
    /// Blocking; call on a background queue.
    @discardableResult
    public static func write(samples: [ReplayBuffer.RecordedFrame],
                             formatDescription: CMFormatDescription,
                             to url: URL) throws -> ClipPlan
}

/// What a saved clip would reveal that the call does not (§5.15).
public enum ClipDisclosure {
    public static func concealments(in config: PipelineConfiguration,
                                    isPanicked: Bool) -> [String]
    public static func phrase(_ names: [String]) -> String
    public static let alwaysTrue: String
}

public enum StillExporter {
    /// CGImageDestination, never CIContext. Copies the pixels out first —
    /// the pipeline reuses that pool buffer. Blocking; background queue.
    public static func write(_ pixelBuffer: CVPixelBuffer,
                             format: StillFormat, to url: URL) throws
}
```

### ReplayBuffer (`PRISM/Pipeline/ReplayBuffer.swift`)

Rolling last-N-seconds store behind instant replay and the away loop (§5.9,
§5.10). Frames are hardware-encoded, not stored raw — see §5.9 for why.
`prepare` runs on the frame queue and only encodes GPU work; `commit` runs
from the command buffer's completed handler, where the pixels are finished
and safe to hand to the encoder.

```swift
public final class ReplayBuffer {
    public struct RecordedFrame {
        public let sample: CMSampleBuffer
        public let seconds: Double          // host clock, monotonic
        public let isKeyframe: Bool
        public let thumbnailSlot: Int
    }
    public struct PendingRecord { /* opaque; prepare → commit */ }

    public static let thumbnailWidth = 32
    public static let thumbnailHeight = 18

    public init(metal: MetalContext) throws
    public private(set) var isArmed: Bool
    public var span: (start: Double, end: Double)? { get }
    public var bufferedSeconds: Double { get }
    public func configure(armed: Bool, bufferSeconds: Double,
                          maxHeight: Int, frameRate: Int)
    public func reset()
    public func prepare(commandBuffer: MTLCommandBuffer, source: MTLTexture,
                        hostSeconds: Double) -> PendingRecord?
    public func commit(_ record: PendingRecord)
    public var sampleFormatDescription: CMFormatDescription? { get }
    public func snapshot() -> [RecordedFrame]                  // oldest first
    public func thumbnails(for: [RecordedFrame]) -> [[Float]]
    public func selectAwayRange(loopSeconds: Double) -> (start: Int, end: Int)?

    /// Pure, testable: seam cost × 3 + mean motion, minimised. Excludes the
    /// most recent second (§5.10).
    static func selectLoop(thumbnails: [[Float]], times: [Double],
                           loopSeconds: Double) -> (start: Int, end: Int)?
    static func meanAbsoluteDifference(_ a: [Float], _ b: [Float]) -> Double
    static func bitRate(width: Int, height: Int) -> Int
    static func isKeyframe(_ sample: CMSampleBuffer) -> Bool
}
```

The ring always begins on a keyframe: `trim` drops back only to a keyframe,
and a non-keyframe arriving into an empty ring is discarded. Without that,
a prefix of the ring would be undecodable.

### ReplayPlayer (`PRISM/Pipeline/ReplayPlayer.swift`)

```swift
public enum ReplayMode: Equatable { case idle, replay, away, lag }

public final class ReplayPlayer {
    public struct Frame {
        public let texture: MTLTexture
        public let blendTexture: MTLTexture?    // loop-seam crossfade target
        public let mix: Float                   // 0 = texture, 1 = blendTexture
    }
    public init(metal: MetalContext, buffer: ReplayBuffer)
    public var mode: ReplayMode { get }
    public var isActive: Bool { get }
    public var positionSeconds: Double { get }
    public var durationSeconds: Double { get }
    public var onReplayFinished: (() -> Void)?          // main thread
    @discardableResult public func startReplay(rate: Double) -> Bool
    @discardableResult public func startAway(loopSeconds: Double,
                                             crossfadeMs: Double) -> Bool
    /// §5.12. Holds the current live frame for `delaySeconds`, then resumes
    /// at 1× permanently that far behind — a delay line, not a rewind.
    @discardableResult public func startLag(delaySeconds: Double) -> Bool
    /// §5.12. Retargets an engaged delay live: deepening holds the current
    /// frame until the difference is absorbed (never rewinds); shortening
    /// drops exactly the difference in backlog. No-op during a catch-up and
    /// for changes under 10 ms. The rebase arithmetic is the pure static
    /// `retarget(base:elapsed:newest:target:)`, exposed for tests.
    public func adjustLag(toSeconds target: Double)
    /// Consumes the lag backlog at `rate` until it reaches live, then fires
    /// `onReplayFinished`. `stop()` is the snap-back path.
    public func beginCatchUp(rate: Double)
    /// Delay currently applied, for LatencyMonitor.setDeliberateDelayMs.
    public var appliedDelaySeconds: Double { get }
    public func stop()
    public func seek(toSeconds: Double)      // replay/away only
    /// Frame queue only.
    public func currentFrame(at hostTime: CMTime) -> Frame?
}
```

Lag mode re-reads the ring on every pump, because it trails a buffer that is
both growing at the back and trimming at the front. Indices are therefore not
stable across snapshots, and both the range base and the feed position are
carried as absolute host-clock times (`baseSeconds`, `lastFedSeconds`) rather
than as indices.

Decode backpressure is mandatory: VideoToolbox may decode asynchronously, so
the feed stops on `fifo.count + inFlight`, never on `fifo.count` alone.
Feeding until the FIFO looks full would race the callbacks and decode an
entire loop before the first frame returned — a gigabyte of 1080p frames.

### LayerSource (`PRISM/Media/LayerSource.swift`)

One layer's pixels as a Metal texture, per frame — a still loaded once, a
video decoded on a loop, or a string rasterised by Core Text (§5.26). Backs
both the virtual background and every overlay layer. Deliberately not
ClipPlayer: no transport, no audio, and a 4-frame decode-ahead rather than
30, because a scene can hold a background plus three overlay layers and
resident memory is the binding constraint (§7).

```swift
final class LayerSource {
    init(metal: MetalContext, label: String)
    // main thread; keyed on (url, kind), and the style is forwarded to the
    // rasteriser, which keys on it the same way
    func configure(url: URL?, kind: LayerSourceKind, style: OverlayTextStyle = .init())
    func setDemandActive(_ active: Bool)
    // frame queue only; frameSize is what a `.text` layer rasterises against
    // and is ignored by every other kind
    func currentTexture(at hostTime: CMTime, frameSize: CGSize = .zero) -> MTLTexture?
    var contentSize: CGSize? { get }
}
```

Reloading is keyed on `(url, kind)` so re-applying an unchanged
configuration — which happens on every slider drag — never restarts a
running video layer.

Text arrives through this door rather than beside it: the overlay stage
already keeps one source per layer id, reconciles them on settings changes
and releases them on removal, and a caption with its own parallel lifetime
would be a second copy of all of that.

### TextRasterizer (`PRISM/Media/TextRasterizer.swift`)

A string as a Metal texture (§5.26): Core Text lays out, a
`CGBitmapContext` draws, and `prism_overlay` composites the result like any
other layer. The kernel is unmodified and does not know text exists.

```swift
final class TextRasterizer {
    static let referenceHeight: CGFloat            // 1080 — where fontSize is quoted
    static let maxWidthFraction: CGFloat           // 0.94 of the frame
    static let maxHeightFraction: CGFloat          // 0.94 of the frame
    init(metal: MetalContext, label: String)
    func configure(_ style: OverlayTextStyle)              // main thread; drops no-ops
    func texture(frameSize: CGSize) -> MTLTexture?         // frame queue only; never blocks
    var contentSize: CGSize? { get }
    struct Layout { canvas, padding, cornerRadius, haloRadius, text, textRect,
                    haloColor, haloAlpha, fringe }
    static func layout(style: OverlayTextStyle, frameSize: CGSize) -> Layout
    static func render(style: OverlayTextStyle, frameSize: CGSize,
                       device: MTLDevice) -> MTLTexture?   // nil for empty text or a zero frame
}
```

`texture(frameSize:)` returns whatever is currently drawn and schedules a
redraw on a private queue when the string, the style or the pixel size has
changed — it never rasterises on the frame queue, because a paragraph costs
milliseconds against a §3.4 budget measured in single digits, and PRISM does
not drop frames to preserve an effect. A brand-new caption is therefore
invisible for a frame or two, and one being retyped keeps its previous
spelling rather than blinking per keystroke.

The bitmap is un-premultiplied before upload, because the kernel mixes RGB
into the base by alpha exactly as it does for a PNG; fully transparent pixels
are coloured rather than cleared, so bilinear sampling has no black to bleed
into the glyph edges.

### FormatManager (`PRISM/Pipeline/FormatManager.swift`)

```swift
@MainActor
public final class FormatManager: ObservableObject {
    @Published public private(set) var publishedFormats: [VideoFormat]
    @Published public var activeFormat: VideoFormat
    public init()                                  // loads persisted set or defaultSet
    /// Smallest native ≥ output in both dims; nil → largest available (§3.2).
    public static func physicalFormat(for device: AVCaptureDevice,
                                      output: VideoFormat) -> AVCaptureDevice.Format?
    /// Push the set to the extension via 'pfmt'. Caller has already shown
    /// the reconnect confirmation when clients are streaming.
    public func publish(_ formats: [VideoFormat], via sink: CMIOSink)
    public func persist()
}
```

### LatencyMonitor (`PRISM/Pipeline/LatencyMonitor.swift`)

```swift
public final class LatencyMonitor: ObservableObject {
    @Published public private(set) var report: LatencyReport   // main thread, 4Hz
    /// Degradation callbacks (§3.4), called on main thread.
    public var onAutoDisable: ((StageID) -> Void)?
    public var onAutoReenable: ((StageID) -> Void)?
    public var onPolicyPressure: (() -> Void)?     // pinned chain over budget
    /// The monitor needs to know what it may disable.
    public var stageQuery: (() -> [(id: StageID, cost: StageCost,
                                    enabled: Bool, pinned: Bool)])?
    public init()
    public func setPolicy(_ policy: LatencyPolicy, frameIntervalMs: Double)
    public func record(_ timings: StageTimings)    // any queue; 60-frame rolling mean
    public func recordHandoffMs(_ ms: Double)      // polled from 'hoff'
    public func setAudioAddedMs(_ ms: Double)
    public func noteDroppedFrame()
}
```

Degradation engine, exact semantics: when 60-frame mean total GPU ms >
budget → among enabled, unpinned stages pick highest cost, tie → later
`chainIndex`; fire `onAutoDisable(stage)` once; monitor marks it internally.
Re-enable when mean < 60% budget for 120 consecutive frames (most recently
auto-disabled first). If over budget and everything left is pinned →
`onPolicyPressure()` at most once per 5s.

Two filters sit on top of that pick, and they compose in one fixed order.
A restored stage is **held** for 30s and cannot be sacrificed again inside it
(without the hold, a chain over budget with a look on and under 60% with it
off flickers that look on and off forever). The stage whose `isLastResort` is
true — the virtual background — is considered only when **no ordinary look is
enabled at all**, which is deliberately not the same test as "no ordinary look
is available this round": a look inside its restore hold is still on air, and
reading its absence from the round's candidates as an empty pool made the
virtual background the victim while an ordinary look kept running, revealing
the room to protect a style from flicker (§5.7). When every ordinary look is
merely held, the round has nothing to give and raises `onPolicyPressure()`
instead — which is what the hold was for. The exemption is not a veto: with no
ordinary look left, the last-resort stage is the candidate and does go.

### PresetStore (`PRISM/Pipeline/PresetStore.swift`)

```swift
@MainActor
public final class PresetStore: ObservableObject {
    @Published public private(set) var presets: [Preset]   // built-ins first
    public init()                                  // loads built-ins + user file
    public static let builtIns: [Preset]           // Natural, Meeting, Studio, Low latency (§5.5)
    public func add(_ preset: Preset)
    public func duplicate(_ id: UUID) -> Preset?
    public func rename(_ id: UUID, to name: String)   // no-op for built-ins
    public func delete(_ id: UUID)                    // no-op for built-ins
    public func move(fromOffsets: IndexSet, toOffset: Int)
    public func update(_ id: UUID, configuration: PipelineConfiguration)
    public func setHotkey(_ id: UUID, hotkey: HotkeyCombo?)
    public func exportJSON(_ id: UUID) -> Data?
    public func importJSON(_ data: Data) throws -> Preset
    public func save()
}
```

User presets persist at
`~/Library/Application Support/PRISM/presets.json`.

### CameraCapture (`PRISM/Capture/CameraCapture.swift`)

```swift
public final class CameraCapture: NSObject {
    /// Called on the dedicated .userInteractive capture queue.
    public var onFrame: ((CVPixelBuffer, CMTime) -> Void)?
    public var onRuntimeError: ((String) -> Void)?
    public private(set) var currentDeviceName: String?
    public override init()
    /// Selects the device (nil = default), picks physical format via
    /// FormatManager.physicalFormat, configures per §3.3, starts.
    public func start(deviceID: String?, outputFormat: VideoFormat)
    public func stop()
    public var isRunning: Bool { get }
    /// §7 sleep/wake: tear down and rebuild the session.
    public func restart()
}
```

Excludes PRISM's own virtual camera when resolving `nil`/fallback devices.

### ScreenCapture (`PRISM/Capture/ScreenCapture.swift`)

```swift
public final class ScreenCapture: NSObject {
    /// Called on the dedicated .userInteractive capture queue, exactly like
    /// CameraCapture.onFrame — and fed to the same pipeline entry point.
    public var onFrame: ((CVPixelBuffer, CMTime) -> Void)?
    /// The source went away, or the stream could not be built. Main thread.
    /// Carries two sentences: `message`, which the user may be shown
    /// verbatim and names the source, and `logMessage`, the same sentence
    /// with a window's title replaced by its application — the §5.21 log is
    /// exported to a file and a title is a document name.
    public var onStopped: ((ScreenCaptureStop) -> Void)?
    public private(set) var currentSourceName: String?
    public private(set) var currentSourceLogName: String?
    public var isRunning: Bool { get }

    /// Empty without the Screen Recording grant — enumerating would raise
    /// the system prompt, and a prompt nobody asked for is not a picker.
    public static func shareableSources() async -> [ScreenSourceInfo]
    public func start(selection: VideoSourceSelection, outputFormat: VideoFormat)
    public func stop()
    public func restart()                          // §7 sleep/wake

    static let queueDepth = 3                      // SCStream's floor (§5.23)
    public static func sourceID(display: CGDirectDisplayID) -> String
    public static func sourceID(window: CGWindowID) -> String
    public static func displayID(from: String?) -> CGDirectDisplayID?
    public static func windowID(from: String?) -> CGWindowID?
    /// Fitted into the format with the source's aspect preserved, even
    /// dimensions, never scaled up.
    public static func captureSize(source: CGSize,
                                   within: VideoFormat) -> (width: Int, height: Int)
    /// Which applications a display filter excludes: everything running
    /// under `bundleID`, found in the content's application list or as the
    /// owner of one of its windows. Generic over `ScreenCaptureApplication`
    /// so the rule can be tested without a live SCK session.
    static func ownApplications<App: ScreenCaptureApplication>(
        applications: [App], windowOwners: [App?], bundleID: String?) -> [App]
}

public protocol ScreenCaptureApplication {
    var bundleIdentifier: String { get }
    var processID: pid_t { get }
}

public struct ScreenCaptureStop: Equatable {
    public let message: String                     // shown to the user
    public let logMessage: String                  // safe for an exported log
    public init(message: String, logMessage: String? = nil)
}
```

Source ids are namespaced (`"display:1"`, `"window:1"`) because the window
server numbers the two separately and they collide. PRISM is excluded from a
display capture **by application** — the `excludingApplications:` filter,
never `excludingWindows:` — because the content is a snapshot taken when the
stream is built and the filter is never rebuilt, so a window list excludes
only the windows that existed then. PRISM
makes its windows lazily (the main window on first open, the prompter pane
inside it, the popover's window on demand), and every one of them would
otherwise be composited into the outgoing camera. A build that cannot find
PRISM in the content at all fails the stream rather than starting one with no
exclusion. Frames the stream reports as anything but `.complete` are skipped
and the last real frame is re-sent at the configured rate — a still screen is
still a screen, and a virtual camera with no frames is a placeholder (§3.2).

### LiveFeeds (`PRISM/Media/LiveFeeds.swift`)

Whichever capture is not driving the chain, as a texture a `.live` overlay
layer composites (§5.25). Owned by `VideoPipeline`, published into from the
capture queues, read from the frame queue.

```swift
final class LiveFeeds {
    init(metal: MetalContext)
    func publish(_ buffer: CVPixelBuffer, feed: LiveLayerFeed)   // capture queues
    func clear(_ feed: LiveLayerFeed)                            // any thread
    func setHeld(_ wanted: Bool)                                 // frame queue
    private(set) var isHeld: Bool                                // frame queue
    func texture(for feed: LiveLayerFeed) -> MTLTexture?         // frame queue
}
```

`setHeld(true)` snapshots each feed's current texture into a private copy and
drops everything published behind it; `setHeld(false)` returns to live. A feed
with nothing on screen when the hold engages reports nil until it is released.
The pipeline engages it whenever a `substitutingStages` member encoded this
frame — the one thing standing between a picture-in-picture and a face that
keeps talking under a frozen frame.

### AudioCapture (`PRISM/Capture/AudioCapture.swift`)

```swift
public final class AudioCapture {
    public var sink: AudioSink?                    // written on RT thread — set before start
    /// Mute writes silence into the ring (mic muted ≠ ring stalled).
    public var isMuted: Bool { get set }           // atomic flag
    /// While clip audio owns the ring, live capture stands down.
    public var isSuppressed: Bool { get set }      // atomic flag
    public private(set) var effectiveBufferFrames: Int   // 256 requested (§4.4)
    /// §5.12 deliberate delay, 0–10 s. Setting it to 0 does not merely stop
    /// delaying: it empties the line, so a later engage starts from the
    /// stall rather than from the previous session's audio.
    public var delaySeconds: Double { get set }
    public static let maxDelaySeconds: Double      // 10
    public var addedLatencyMs: Double { get }      // buffer/48k*1000 + ring estimate
                                                   // + voiceChanger.reportedLatencyMs
                                                   // + voiceCleanup.reportedLatencyMs (0)
    /// §5.17 cleanup: noise expander / compressor / EQ, ahead of the voice
    /// effects in the chain and independent of them.
    public let voiceCleanup: VoiceCleanup
    /// §5.13 voice changer: parameters from the main thread via apply();
    /// processing on the RT callback between conversion and the ring write.
    public let voiceChanger: VoiceChanger
    /// §5.17 input level: RMS published from the RT callback into a
    /// lock-free mailbox. Demand-gated — nothing is measured unarmed.
    public func setInputLevelArmed(_ armed: Bool)
    public var inputLevelReading: (rms: Double, sequence: UInt32) { get }
    /// §5.13 mic check tap: a passive, armed-on-demand copy of the
    /// post-effect mono signal. Arm from the main thread; read at leisure.
    public func setMicTapArmed(_ armed: Bool)
    public var micTapCursor: UInt64 { get }
    public func readMicTap(from cursor: UInt64,
                           into buffer: UnsafeMutablePointer<Float>,
                           maxFrames: Int) -> (cursor: UInt64, frames: Int)
    /// §5.32 transcription tap. A SECOND, independent passive copy, taken
    /// at the opposite end of the chain from the mic-check tap above:
    /// after 48 kHz conversion but BEFORE §5.17 cleanup and §5.13 effects,
    /// because a transcript must not change when somebody picks a voice
    /// effect. Its ring is deeper (1<<19, ~10.9 s) because the reader
    /// hitches on model loads and main-thread stalls.
    ///
    /// Separate from the mic-check tap rather than shared: arming is a
    /// plain Bool, not a refcount, and MicCheck disarms unconditionally.
    ///
    /// A returned cursor greater than `cursor + frames` means the ring
    /// lapped; the caller must record a gap, never stitch across it.
    public func setASRTapArmed(_ armed: Bool)
    public var asrTapCursor: UInt64 { get }
    public func readASRTap(from cursor: UInt64,
                           into buffer: UnsafeMutablePointer<Float>,
                           maxFrames: Int) -> (cursor: UInt64, frames: Int)
    public init()
    public func start(deviceUID: String?)          // nil = default input
    public func stop()
    public func restart()                          // sleep/wake
}
```

Render callback: pull from HALOutput input scope, meter the raw slice
(§5.17, ahead of mute so the level stays true while muted), convert to 48kHz
stereo float interleaved (AudioConverter when needed), process through
cleanup then the voice changer (§5.17 before §5.13; mono duplicated after),
then through the §5.12 delay line, then `sink.write(...)`. **The callback
body must be free of ObjC/Swift allocation; preallocate all conversion
buffers in `start`.**

Going off air empties every buffer holding audio that has not been sent.
Mute and clip suppression both take an early return, and the first slice
back clears the voice chains' delay lines *and* resets `AudioDelayLine`
(`PRISM/Capture/AudioDelayLine.swift`) — a line holding up to ten seconds of
speech would otherwise put the seconds immediately before the mute on air at
the unmute, which is the opposite of what muting means.

### VoiceChanger (`PRISM/Capture/VoiceChanger.swift`)

```swift
public enum VoiceEffect: String, Codable, CaseIterable, Identifiable {
    case off, chipmunk, helium, deep, giant, alien, robot, autotune,
         telephone, cave, underwater
    public var displayName: String { get }
    public var blurb: String { get }               // one line, §8.4 voice
}

public final class VoiceChanger {
    public init()
    /// Main thread. Builds the DSP program for the settings and publishes it
    /// to the RT path through a trylock mailbox; never blocks the RT thread.
    public func apply(_ settings: VoiceSettings)
    /// ~21 ms while a pitched effect is engaged, else 0 (§5.13). Folded into
    /// AudioCapture.addedLatencyMs.
    public private(set) var reportedLatencyMs: Double
    /// Capture setup path only, RT unit stopped: sizes the mixdown scratch
    /// and clears all DSP state.
    public func prepare(maxFrames: Int)
    public func reset()
    // RT-only, in-place 48 kHz processing (internal):
    // processMono(_:frameCount:), processStereoInterleaved(_:frameCount:)
    // clearDSPState() — RT-safe state clear (bounded memsets); the RT path
    // runs it on resume from mute/suppression and on off→on transitions so
    // a delay line never replays audio from before the interruption.
}
```

`VoiceSettings` lives in `StudioSettings` (behaviour, not look — a preset
switch must not change what you sound like). Pure, testable pieces:
`detectFrequency` (normalised autocorrelation over a caller-supplied
scratch), `chromaticTarget`, and the static `program(for:amount:)` table.

### MeetingSession (`PRISM/AI/Meeting/MeetingSession.swift`)

The §5.32 live transcript. Every dependency is a closure or a protocol, so
the whole state machine is drivable headless — no microphone, no permission,
no model, no meeting. That is the point of the shape, not a side effect:
a mute mid-sentence, a lapped ring and a stop during an in-flight decode are
all things worth a test and none of them are worth reproducing by hand.

```swift
public enum MeetingPhase: Equatable {
    case idle, preparing(Double), listening, stopping, failed(String)
    public var isRunning: Bool
    public var isListening: Bool
}
public enum NotesPhase: Equatable { case none, writing, ready, failed(String) }

@MainActor
public final class MeetingSession: ObservableObject {
    @Published public private(set) var phase: MeetingPhase
    @Published public private(set) var lines: [TranscriptLine]
    @Published public private(set) var hypothesis: String     // still settling
    @Published public private(set) var notesPhase: NotesPhase
    @Published public private(set) var record: MeetingRecord?
    @Published public private(set) var farEndHeard: Bool      // audible, not merely started
    @Published public private(set) var notice: String?
    @Published public var userNotes: String

    /// Installed by AppState after construction — an owner cannot form a
    /// closure over itself before it exists. While true the ASR tap
    /// receives nothing at all, and the session records a gap.
    public var micIsOffAir: () -> Bool

    public init(engineFactory: @escaping (SpeechModel) -> SpeechRecognizing,
                armMicTap: @escaping (Bool) -> Void,
                micTapCursor: @escaping () -> UInt64,
                readMicTap: @escaping (UInt64, UnsafeMutablePointer<Float>, Int)
                                        -> (cursor: UInt64, frames: Int),
                farEnd: (any SystemAudioCapturing)?,
                store: TranscriptStore? = nil,
                micIsOffAir: @escaping () -> Bool = { false },
                now: @escaping () -> Date = Date.init)

    public func apply(_ settings: MeetingSettings)
    public func start()
    public func stop()
    public func transcriptTail(turns: Int) -> String
    public var labelledTranscript: String { get }
    public var elapsed: TimeInterval { get }
    public var wordCount: Int { get }
    public func dismissNotice()
    public func applyNotes(markdown: String, title: String?, items: [MeetingActionItem])
    public func setNotesPhase(_ phase: NotesPhase)
}
```

Drain is one 10 Hz main-thread timer added in `.common` mode — the default
mode stops firing while a menu is open, and a transcript with holes in it at
exactly the moments somebody opened the popover is worse than no transcript.
Decodes never overlap.

### AssistantSession (`PRISM/AI/Meeting/AssistantSession.swift`)

```swift
@MainActor
public final class AssistantSession: ObservableObject {
    @Published public private(set) var answer: String
    @Published public private(set) var isStreaming: Bool
    /// Set by the detector; lights a control. NEVER causes a request.
    @Published public private(set) var detectedQuestion: String?
    @Published public private(set) var lastError: String?
    @Published public private(set) var lastAsked: String?

    public func apply(_ settings: AssistantSettings)
    public func observeTranscript(_ tail: String)
    public func clearDetectedQuestion()
    /// `text == nil` answers the detected question. The two paths build
    /// deliberately different prompts — see §5.33.
    public func ask(_ text: String?, provider: LLMProvider,
                    transcriptTail: @autoclosure () -> String)
    public func cancel()
    public func clear()
}
```

Carries a stall watchdog rearmed on every token. A provider that stops
mid-stream without closing otherwise leaves `isStreaming` true forever and
wedges every later question until the app is relaunched.

### SpeechRecognizing (`PRISM/AI/Speech/SpeechRecognizing.swift`)

The seam that keeps the one third-party dependency inside one directory.

```swift
public protocol SpeechRecognizing: AnyObject {
    var supportsWordTimestamps: Bool { get async }
    func load(progress: @escaping (SpeechModelState) -> Void) async throws
    func unload() async
    func transcribe(_ request: SpeechRequest,
                    channel: ChannelProfile) async throws -> SpeechHypothesis
}

/// `PRISM/AI/Engines/` is excluded from PRISMTests, and AppState is in both
/// targets — so AppState must not name `WhisperKitEngine`. The app installs
/// the real factory at launch; a test gets `UnavailableSpeechEngine`, which
/// fails honestly rather than returning nothing and making a broken
/// pipeline look like a quiet room.
public enum SpeechEngineRegistry {
    public static var factory: ((SpeechModel) -> SpeechRecognizing)?
    public static func make(_ model: SpeechModel) -> SpeechRecognizing
}
```

### LLMProvider and LLMTransport (`PRISM/AI/LLM/`)

```swift
public protocol LLMProvider: AnyObject {
    var id: String { get }
    var displayName: String { get }
    /// Decides map-reduce vs one pass in `TranscriptChunker`.
    var contextBudget: Int { get }
    func isAvailable() async -> Bool
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error>
}
public typealias LLMEvent = LLMStreamEvent   // defined by SSEParser
```

Three conformers: `AnthropicProvider`, `OllamaProvider`,
`OpenAICompatibleProvider`. They build request bodies and decode frames via
`SSEParser`, which opens no sockets and is therefore testable from string
fixtures.

`LLMTransport` is **the only file in the repository that opens a network
connection** (§7). CI allowlists exactly that path, asserts it names no
endpoint outside `api.anthropic.com` and localhost, and greps the whole tree
for telemetry-shaped symbols. It also enforces the host allowlist at runtime,
because CI can check literals but not a URL assembled from a settings field.

### TranscriptStore (`PRISM/AI/Transcript/TranscriptStore.swift`)

```swift
@MainActor
public final class TranscriptStore {
    /// Injected in tests so the suite never writes to the real
    /// Application Support folder (LUTStore's idiom).
    public static var directoryOverride: URL?
    public static var directory: URL { get }
    @discardableResult public func save(_ record: MeetingRecord) throws -> URL
    @discardableResult public func saveNotes(_ markdown: String,
                                             for record: MeetingRecord) throws -> URL
    public func load(id: String) -> MeetingRecord?
    public func all() -> [MeetingRecord]
    public func delete(id: String) throws
    public func deleteAll() throws
    public func bytesOnDisk() -> Int64
}
```

Transcripts and notes only. There is no method here that writes audio, and
no caller that could ask for one.

### Keychain (`PRISM/System/Keychain.swift`)

The one secret PRISM holds (§5.33). `kSecUseDataProtectionKeychain: true` on
every query is load-bearing: without it the item lands in the legacy login
keychain and the user is prompted on every launch. Read once at launch and
cached in memory — all four `SecItem` calls block the calling thread, and a
keychain read per request would sit on the path of a live answer.

### MicCheck (`PRISM/Capture/MicCheck.swift`)

```swift
@MainActor
public final class MicCheck: ObservableObject {          // §5.13 mic check
    public enum Phase: Equatable { case idle, recording, playing }
    @Published public private(set) var phase: Phase
    @Published public private(set) var level: Double          // 0…1 meter
    @Published public private(set) var recordedSeconds: Double
    @Published public private(set) var heardNothing: Bool     // silent take
    public var hasTake: Bool { get }
    public static let maxSeconds: Double                      // 5
    public func toggle()      // idle → record; recording → stop-and-play; playing → stop
    public func replay()
    public func cancel()      // hard stop, used on quit
}
```

Internals kept testable: `MicTapRing` (SPSC tap ring — the RT writer
release-stores its head through the `PRISMAtomicU64StoreRelease` shim in
RingBuffer.h, the main-thread reader acquire-loads it, so a head snapshot
at arm time is an exact start-of-take marker), the `MicCheckPlaying`
playback seam (AVAudioEngine in production, fakes in tests), and the static
`displayLevel(of:)` meter scaling. Recording ends on the frame cap or a
wall-clock deadline, whichever first — a starved tap can never strand the
phase. Owned by AppState as a directly observable sub-object (`public let
micCheck`), alongside `AppState.micCheckInhibition: String?` — the reason
recording is refused (muted / no mic permission / clip owns the ring), nil
when it may run. AppState cancels an in-flight recording when an inhibition
appears mid-take (mute, clip audio, capture demand dropping), so a take the
app itself silenced is never misdiagnosed as a dead microphone.

### VoiceCleanup (`PRISM/Capture/VoiceCleanup.swift`)

`VoiceCleanupMode`, `VoiceCleanupSettings` and `MicWatchSettings` live with
every other persisted struct in
`PRISM/Pipeline/Settings/VoiceCleanupSettings.swift`; this file owns only
what the modes mean in samples.

```swift
public final class VoiceCleanup {
    public init()
    /// Main thread. Builds the chain for the settings and publishes it to
    /// the RT path through a trylock mailbox; never blocks the RT thread.
    public func apply(_ settings: VoiceCleanupSettings)
    /// Always 0 (§5.17): nothing in the chain looks ahead, and the §6 audio
    /// budget has no room for anything that would. Reported anyway, so a
    /// stage that ever did buy lookahead could not be added silently.
    public let reportedLatencyMs: Double
    /// Clears filters, envelopes and the learned noise floor.
    public func reset()
    // RT-only, in-place 48 kHz processing (internal):
    // processMono(_:frameCount:), processStereoInterleaved(_:frameCount:)
    // clearDSPState() — RT-safe state clear; the RT path runs it on resume
    // from mute/suppression and on off→on, because a floor learned before
    // an interruption describes a room that may no longer be there.
}
```

Chain, in order: 80Hz high-pass → two-band downward expander (complementary
split at 1.2kHz, so the bands reconstruct the input exactly when neither is
gating) → feed-forward compressor with a smoothed knee → corrective EQ
(Studio only). Filters run per channel; the dynamics are detected on the
channel mean and applied to both, so a stereo microphone keeps its image
rather than being folded to mono the way the voice effects deliberately are.
`.off` returns before touching a sample — bit-exact pass-through, asserted
by test. `VoiceCleanupSettings.amount` scales the expander's floor gains as
an exponent, so it scales the removal depth *in dB* and leaves the
compressor and the EQ alone. Pure, testable pieces: `program(for:amount:)`
(amount defaults to 1 so the mode table can be read at full depth),
`rate(ms:)`, `linear(db:)`, and `peakGainAtFullScale(_:)` — the headroom
bound the tests use to prove no mode relies on the output clamp.

### InputLevel (`PRISM/Capture/InputLevel.swift`)

```swift
final class InputLevelMailbox {                     // §5.17
    static let windowFrames: Int                    // 1024, ~21 ms @ 48 kHz
    /// RT: accumulate one interleaved slice; publishes per full window.
    func accumulate(_ samples: UnsafePointer<Float>, frameCount: Int,
                    channels: Int)
    func publish(rms: Float)
    func resetAccumulator()                         // unit stopped only
    /// Main thread. An unchanged `sequence` means no audio arrived.
    var reading: (rms: Double, sequence: UInt32) { get }
}

struct AudioReactiveLevel {                         // §5.30
    static let freshFor: Double                     // 0.1 s — ~5 windows
    /// Frame queue. `now` is a monotonic clock in seconds. Returns 0 when
    /// the counter has not moved for `freshFor`, and 0 while off air.
    mutating func level(rms: Double, sequence: UInt32, offAir: Bool,
                        at now: Double) -> Double
}

final class MicWatch {                              // §5.17
    private(set) var isTalking: Bool
    /// Main thread. Adopts thresholdDB (converted to linear RMS here, once,
    /// so the hot path stays a compare), sustainSeconds and
    /// reminderIntervalSeconds from the user's settings.
    func apply(_ settings: MicWatchSettings)
    @discardableResult
    func update(rms: Double, offAir: Bool, at now: Date) -> Bool
    func reset(keepingHistory: Bool = false)
}
```

The mailbox packs the value and a publish counter into one `UInt64` and
moves it with the `PRISMAtomicU64StoreRelease` / `LoadAcquire` shims in
RingBuffer.h, so a reader can never pair a fresh counter with a stale
level. RMS rather than peak: both consumers are asking how much *voice*
is arriving, and a peak meter would let a keyboard click read as speech.

`AudioReactiveLevel` is the §5.30 bridge from that mailbox to the frame
path, pure for the same reason. Both of its rules resolve to silence rather
than to a hold: a counter that stopped moving is not a level (the mailbox
never decays, so a stopped capture would otherwise pin the effect at the
last loudness heard, on camera), and a microphone that is off air must not
drive the picture (the meter is deliberately read ahead of the mute, and an
effect pulsing to a muted user's speech broadcasts exactly what the mute
withholds). Freshness is tracked before the off-air gate, so unmuting
answers on the next frame.

`MicWatch` is pure logic so the debounce can be tested against a clock.
Rules, all of them about not nagging: sustained speech only (accumulated,
with short gaps not counted, so a cough cannot reach the threshold); one
alert per mute, re-armed only by going back on air; a holdoff floor across
mutes; and the signal clears when the talking stops. A gap between samples
counts as one step, never as elapsed silence.

### DeviceMonitor (`PRISM/Capture/DeviceMonitor.swift`)

```swift
public final class DeviceMonitor {
    public var onCamerasChanged: (([CameraDeviceInfo]) -> Void)?      // main thread
    public var onMicrophonesChanged: (([AudioDeviceInfo]) -> Void)?   // main thread
    /// Fired when the *selected* device vanished; name for the warning row.
    public var onWake: (() -> Void)?                                  // §7
    /// Some process is recording from "PRISM Microphone"
    /// (kAudioDevicePropertyDeviceIsRunningSomewhere on the virtual device).
    /// Audio-only capture demand: keeps the mic ring fed with every window
    /// closed, without turning the camera on. Primed on start(); re-resolved
    /// on device-list changes (coreaudiod restart = new AudioObjectID).
    public var onVirtualMicInUseChanged: ((Bool) -> Void)?            // main thread
    public init()
    public func start()
    public func stop()
    public static func cameras() -> [CameraDeviceInfo]       // excludes "PRISM Camera"
    public static func microphones() -> [AudioDeviceInfo]    // excludes "PRISM Microphone"
}
```

### CMIOSink (`PRISM/Sinks/CMIOSink.swift`)

```swift
public final class CMIOSink {
    public private(set) var isConnected: Bool
    /// Clients decoded from 'clnt': the signing ID the extension reported
    /// (what §5.18 rules match on) plus the name a human is shown.
    public var onClientsChanged: (([CameraClient]) -> Void)? // main thread
    /// Clients refused by the §5.18 policy, decoded from 'blkd'.
    public var onBlockedClientsChanged: (([CameraClient]) -> Void)? // main thread
    /// Gates the 1 Hz 'blkd' read; set false while nothing can be refused.
    public var isPolicyEnforcing: Bool
    public init()
    /// Finds the PRISM Camera device + sink stream via the CMIO C API,
    /// copies the buffer queue, starts the stream. Retries internally at
    /// 1s cadence until found (extension may not be approved yet).
    public func connect()
    public func disconnect()
    /// Real-time path: wraps the pixel buffer in a CMSampleBuffer and
    /// enqueues. Drops (and counts) if the queue is full. Any queue.
    public func send(_ buffer: CVPixelBuffer, at time: CMTime)
    /// Custom-property helpers (§CMIO custom properties above).
    public func writeFormatList(_ json: Data) -> Bool
    public func readHandoffMs() -> Double?
    public func readClients() -> [String]?
    public func writeAccessPolicy(_ json: Data) -> Bool     // 'polc', §5.18
    public func readBlockedClients() -> [String]?           // 'blkd', §5.18
    /// Maps signing IDs to friendly names ("us.zoom.xos" → "Zoom").
    public static func displayName(forSigningID: String) -> String
}
```

### AudioSink (`PRISM/Sinks/AudioSink.swift`)

```swift
public final class AudioSink {
    public init?()                                 // PRISMRingBufferCreateProducer
    /// Interleaved stereo 48kHz floats. RT-safe (calls the C ring API only).
    public func write(_ samples: UnsafePointer<Float>, frameCount: Int)
    public func writeSilence(frameCount: Int)
    public var underruns: UInt32 { get }
    public var overruns: UInt32 { get }
    public static var isPlugInInstalled: Bool { get }   // /Library/Audio/Plug-Ins/HAL/PRISM.driver exists
    public func close()
}
```

### ClipPlayer (`PRISM/Clip/ClipPlayer.swift`)

```swift
public final class ClipPlayer: ObservableObject {
    @Published public private(set) var state: ClipState    // main thread
    @Published public private(set) var durationSeconds: Double
    @Published public private(set) var positionSeconds: Double
    public var loops: Bool                                  // default true (§5.3)
    public var useClipAudio: Bool                           // default true
    public var fillMode: ClipFillMode                       // .letterbox default
    public var audioSink: AudioSink?
    /// Loop-off end-of-clip: AppState begins the 200ms crossfade to live.
    public var onEnded: (() -> Void)?
    public init(metal: MetalContext)
    public func load(url: URL) throws                       // 30-frame decode-ahead
    public func play()
    public func pause()
    public func stop()                                      // unload
    public func seek(toSeconds: Double)
    /// Latest decoded frame retimed to the output cadence; called on the
    /// capture queue by ClipStage. Returns nil when not loaded.
    public func currentTexture(at hostTime: CMTime) -> MTLTexture?
    /// Freeze-while-clip pauses on current frame (§5.3).
    public func holdCurrentFrame(_ hold: Bool)
}

public enum ClipFillMode: String, Codable, CaseIterable { case letterbox, fill }
```

Clip audio: while playing with `useClipAudio`, decode the audio track,
convert to 48k stereo, and push to `audioSink` paced by a timer ~100
frames ahead of real time.

### Stages (`PRISM/Pipeline/Stages/*.swift`)

All conform to `EffectStage`. Constructor pattern:
`init(metal: MetalContext) throws` (compiles pipeline states up front).
Settings are `var` properties matching `StageSettings.swift` types.

```swift
public final class ClipStage: EffectStage {        // id .clip, cost .cheap
    public var player: ClipPlayer?                 // substitutes when playing/paused-with-frame
}
public final class FreezeStage: EffectStage {      // id .freeze, cost .cheap
    public func freeze(texture: MTLTexture)        // set by pipeline from FrameRing pick
    public func unfreeze()
    public var isFrozen: Bool { get }
}
public final class GeometryStage: EffectStage {    // id .geometry, cost .cheap
    public var settings: GeometrySettings
    /// Auto-framing (§5.4): smoothed target from AutoFramer; identity when off.
    public var autoFrameOffset: (zoom: Double, panX: Double, panY: Double)
    public func buildUVTransform(inputSize: CGSize) -> simd_float3x3  // exposed for tests
    /// buildUVTransform, or identity when the stage declines to encode.
    /// Anything anchored to a pre-Geometry measurement composes with THIS.
    public func appliedUVTransform(inputSize: CGSize) -> simd_float3x3
}
public final class AdjustStage: EffectStage {      // id .adjust, cost .cheap
    public var settings: AdjustSettings
}
public final class LUTStage: EffectStage {         // id .lut, cost .moderate
    public var settings: LUTSettings { get set }   // setting lutName loads texture via LUTStore
}
public final class RetouchStage: EffectStage {      // id .retouch, cost .expensive
    /// §5.22. Four passes: half-res downsample → bilateral H → bilateral V →
    /// full-res combine. The person mask is read if one exists and NEVER
    /// demanded — retouch is deliberately absent from the pipeline's
    /// maskConsumers, because switching it on must not start a Vision
    /// segmentation request. The gate it does own is skin chroma.
    /// Declines to encode at amount 0, which is the shipping default.
    public init(metal: MetalContext, segmenter: PersonSegmenter) throws
    public var settings: RetouchSettings
    public let segmenter: PersonSegmenter
}
public final class BlurStage: EffectStage {        // id .blur, cost .expensive
    public var settings: BlurSettings
    /// Person mask via VNGeneratePersonSegmentationRequest, computed
    /// asynchronously every N frames on a serial queue; encode uses the
    /// latest mask. Also exposed for auto-framing:
    public var latestSubjectBox: CGRect? { get }   // normalized, nil = none
    /// Segmentation runs when blur enabled OR auto-frame needs it:
    public var maskOnlyMode: Bool { get set }
}
public final class StyleStage: EffectStage {       // id .style, cost .moderate
    /// Setting new settings rebuilds the pass plan off the frame path
    /// (MetalContext caches compiled pipelines); declines to encode when no
    /// slot is renderable. UP TO TWO PASSES (§5.29): slot 0 into a
    /// stage-private scratch, slot 1 into `output`, both on the frame's one
    /// command buffer. Motion effects (StyleEffect.isTemporal) feed on a
    /// stage-owned history texture, refreshed by a blit from THAT pass's
    /// destination — there is one history, hence at most one motion effect
    /// in a stack. Stale ghosts never replay: history is dropped (texture
    /// released) whenever the set of effects being run changes, on disable
    /// and size change, and ages out across any encoding gap > 0.5s — the
    /// same gap that resets the level envelope. Plan, depth, history and
    /// scratch change together under one lock; encode() snapshots them once
    /// and re-validates before publishing history, so a mid-encode switch
    /// can never pair one effect's kernel with another's texture bindings.
    public var settings: StyleSettings { get set }
    /// §5.30 — normalised 0…1 microphone loudness, sampled ONCE PER FRAME
    /// ON THE FRAME QUEUE. Whatever is installed must not block, allocate or
    /// take a lock the audio thread holds; the shipped one is a single
    /// acquire-load out of InputLevelMailbox, through AudioReactiveLevel.
    /// nil reads as silence, and so do the two cases that mailbox cannot
    /// signal for itself: a publish counter that has not moved for 100 ms,
    /// and a microphone that is off air.
    public var audioLevelSource: (() -> Double)?
    /// 1 or 2 — the live pass count (§3.4).
    public var weightMultiplier: Double { get }
}
/// §5.30's attack/decay follower, pure so it can be tested without a
/// microphone. Attack 60 ms, release 350 ms, one frame may advance it by at
/// most 100 ms so a nap cannot saturate it.
public struct StyleLevelEnvelope: Equatable {
    public private(set) var value: Double         // 0…1
    @discardableResult
    public mutating func step(level: Double, elapsed: Double) -> Double
    public mutating func reset()
}
public final class ConnectionStage: EffectStage {  // id .connection, cost .cheap
    public var settings: ConnectionSettings        // pushed by applyStudio
    /// Engage/release (§5.14 intent, like freeze — never preset-driven).
    /// Releasing drops the held frame and throttle anchor.
    public func setEngaged(_ engaged: Bool)
}
/// ConnectionStage's frame-rate throttle, pure and Metal-free for tests:
/// first call refreshes, a backwards clock re-anchors, reset() re-opens.
/// Intervals are jittered around the mean (0.35–1.05× nominal, ~10% stalls
/// of 3–7×) from a seeded xorshift — deterministic per seed, `fps` is the
/// honest mean of the cadence.
public struct ConnectionFrameGate {
    public init(seed: UInt64 = ...)                // default fixed seed
    public mutating func shouldRefresh(at now: Double, fps: Double) -> Bool
    public mutating func reset()
}
public final class OutputFitStage: EffectStage {   // id .outputFit, cost .cheap, always enabled
    public var outputSize: CGSize
    public var contentMode: ClipFillMode           // letterbox default
}

public final class GazeStage: EffectStage {         // id .gaze, cost .expensive
    /// Measures nothing itself: the shared tracker is driven once per frame
    /// by the pipeline at this stage's chain position, and read here.
    public init(metal: MetalContext, faceTracker: FaceTracker) throws
    public typealias EyeMeasurement = FaceTracker.EyeMeasurement
    public var settings: GazeSettings
    public var isTracking: Bool { get }             // a face with usable eye landmarks
    public func reset()                             // clears tracking state
    /// The whole correction in one pure function, free of Metal/Vision types.
    static func shift(for eye: EyeMeasurement, settings: GazeSettings,
                      confidence: Float) -> SIMD2<Float>
}
public final class BackgroundStage: EffectStage {   // id .background, cost .expensive
    public var settings: BackgroundSettings
    public let segmenter: PersonSegmenter
    public var needsPersonMask: Bool { get }
    public func setDemandActive(_ active: Bool)
    static func fit(contentSize: CGSize, outputSize: CGSize,
                    mode: ClipFillMode) -> (scale: SIMD2<Float>, offset: SIMD2<Float>)
}
public final class OverlayStage: EffectStage {      // id .overlay, cost .moderate
    public init(metal: MetalContext, segmenter: PersonSegmenter,
                faceTracker: FaceTracker) throws
    public var settings: OverlaySettings            // caps: maxLayers total, maxVideoLayers video
    public let segmenter: PersonSegmenter
    public let faceTracker: FaceTracker
    public var needsPersonMask: Bool { get }        // true when any layer is .behind
    public var needsFaceTracker: Bool { get }       // true when any layer is .face-anchored
    /// §5.25. Set by the pipeline; nil in DraftRenderer, which previews a
    /// look off camera frames and runs no capture of its own. A `.live`
    /// layer takes its texture from here rather than from a LayerSource —
    /// no decoder, and no `maxVideoLayers` slot.
    var liveFeeds: LiveFeeds?
    /// Output UV → pre-Geometry input UV, pushed once per frame by the
    /// pipeline (GeometryStage.appliedUVTransform). Face-anchored placement
    /// is built in the tracker's space and composed with this, so a prop
    /// survives zoom, pan, rotation, mirror and auto-framing exactly.
    public var faceSpaceTransform: simd_float3x3
    /// §5.26. The picture about to be composited into, in pixels, pushed once
    /// per frame beside the transform above. Read in wantsEncode(), before
    /// any destination texture exists, because a caption quoted in points has
    /// to be rasterised against the frame it will land in.
    public var frameSize: CGSize
    public func setDemandActive(_ active: Bool)
    /// Fitted, aspect preserved, at scale 1 — except for `.text`, which is
    /// placed at its own pixel size (the rasteriser already sized it for this
    /// frame) and whose `alignment` pins an edge rather than the centre, so a
    /// name banner grows sideways instead of sliding (§5.26).
    static func placement(layer: OverlayLayer, contentSize: CGSize,
                          outputSize: CGSize) -> simd_float3x3
    /// §5.8. Span is the face box width × scale (size 1 = as wide as the
    /// face); offsets are in face widths and rotate with the layer; roll is
    /// negated into this y-down space and applied only when followsRoll.
    /// Returns identity for a degenerate face rather than centring on the
    /// frame. Tracking loss is handled in wantsEncode/encode: below a
    /// confidence of 0.01 the layer is skipped, above it the layer's opacity
    /// is scaled by the tracker's ramp, so the prop fades rather than
    /// freezing in mid-air or flashing with detection flicker.
    static func facePlacement(layer: OverlayLayer, contentSize: CGSize,
                              frameSize: CGSize, face: FaceTracker.FaceSample,
                              geometry: simd_float3x3) -> simd_float3x3
    /// Where a layer's centre lands, in the tracker's input UV. Fractions of
    /// the face box height from its centre, rotated by `roll`; the measured
    /// eye midpoint wins for .eyes when both eyes are landmarked.
    static func anchorPoint(face: FaceTracker.FaceSample, point: FaceAnchorPoint,
                            roll: Float, frameAspect: Float) -> SIMD2<Float>
}
/// What ReplayStage needs from the transport. ReplayPlayer is the only
/// implementation; the protocol is what lets the start-up window — a claimed
/// transport with no decoded frame yet — be exercised without a decoder.
public protocol ReplayFrameSource: AnyObject {
    var isActive: Bool { get }
    func currentFrame(at hostTime: CMTime) -> ReplayPlayer.Frame?
}

public final class ReplayStage: EffectStage {       // id .replay, cost .cheap
    public var player: ReplayFrameSource?           // substitutes while active
    /// §5.9 — the picture held while the transport decodes its first frame,
    /// armed by `VideoPipeline.startReplayTransport`. Released by the first
    /// delivered frame, and never allowed to outlive its transport: the
    /// stage clears it whenever the player is not active.
    public var bridgeFrame: MTLTexture?
}

/// One mask, four consumers (§3.3). The pipeline calls `update` once per
/// frame at the first mask-consuming stage's chain position; stages only
/// read. Whether that call carries a capture is VisionCoordinator's answer
/// (§5.23) — the segmenter asks for every 2nd frame and takes what it gets.
public final class PersonSegmenter {
    public init(metal: MetalContext) throws
    public var quality: BlurQuality
    public var isDemanded: Bool
    public var latestMask: MTLTexture? { get }      // thread-safe
    public var latestSubjectBox: CGRect? { get }    // thread-safe, top-left origin
    public func update(commandBuffer: MTLCommandBuffer, input: MTLTexture,
                       capture: Bool)               // capture: from the coordinator
    public func invalidate()                        // demand went to zero
}

/// One face, several consumers (§3.3), same contract: the pipeline calls
/// `update` once per frame at the first face-consuming stage's chain
/// position — pre-geometry, the space eye contact warps in — and stages only
/// read. Owns the 76-point landmark request, its detection texture ring, the
/// per-frame smoothing and the ramps. The cadence is VisionCoordinator's
/// (§5.23); the smoothing runs on every frame either way, which is why eye
/// contact survives being measured less often than it is drawn.
public final class FaceTracker {
    public init(metal: MetalContext) throws
    public struct EyeMeasurement: Equatable {       // input UV, top-left origin
        public var lidCenter, lidRadii, irisCenter, irisRadii: SIMD2<Float>
    }
    public struct FaceSample: Equatable {
        public var box: CGRect                      // normalized, top-left origin
        public var roll: Float                      // radians, 0 when unreported
        public var left, right: EyeMeasurement?
        public var hasEyes: Bool { get }
    }
    public struct Confidence: Equatable {           // acquisition/loss ramps
        public var face, left, right: Float
    }
    public var smoothing: Double                    // pushed from GazeSettings
    public var isDemanded: Bool
    public var latestFace: FaceSample? { get }      // thread-safe, raw
    public var smoothedFace: FaceSample? { get }    // thread-safe, smoothed
    public var confidence: Confidence { get }       // thread-safe
    public var isTracking: Bool { get }             // a face at all
    public var hasEyes: Bool { get }                // with usable eye landmarks
    public func update(commandBuffer: MTLCommandBuffer, input: MTLTexture,
                       capture: Bool)               // capture: from the coordinator
    public func invalidate()                        // demand went to zero
    public func reset()                             // invalidate + the ramps
}

public final class LUTStore {
    public static let shared: LUTStore
    public var availableLUTs: [String] { get }     // bundled 5 + imported
    public func texture(named: String, device: MTLDevice) -> MTLTexture?  // parses .cube
    public func importLUT(from url: URL) throws -> String
}

public final class AutoFramer {
    public init()
    /// Critically damped toward the subject box, 1.5s time constant (§5.4).
    public func update(subjectBox: CGRect?, dt: Double)
                 -> (zoom: Double, panX: Double, panY: Double)
    public func reset()
}
```

### System (`PRISM/System/*.swift`)

```swift
@MainActor
public final class ExtensionInstaller: NSObject, ObservableObject {
    @Published public private(set) var status: ExtensionStatus
    public func install()          // OSSystemExtensionManager activation request
    public func checkStatus()      // properties request
}

public enum LoginItem {
    public static var isEnabled: Bool { get }
    public static func setEnabled(_ enabled: Bool)
    public static func registerIfFirstLaunch()     // default ON (§7)
}

/// Every global chord PRISM owns, as one table: the binding is data, so
/// matching is a lookup and rebinding is possible at all.
public enum ShortcutAction: String, Codable, CaseIterable, Identifiable {
    case freeze, mute, freezeAndMute       // ⌥⌘F, ⌥⌘M, ⌥⌘⇧F
    case replay, away, panic               // ⌥⌘R, ⌥⌘A, ⌥⌘P
    case eyeContact, lag, badConnection    // ⌥⌘E, ⌥⌘L, ⌥⌘B
    case voice                             // ⌃⌥⌘V (§5.13)
    case saveClip, snapshot                // ⌥⌘S, ⌥⌘⇧S
    case screenSource, prompter            // ⌥⌘D, ⌃⌥⌘T
    /// Defaults, not constants — §5.19 lets the user rebind every one.
    public var defaultCombo: HotkeyCombo { get }
    public var displayName: String { get }
    public var isMomentary: Bool { get }             // .lag only
}

public final class Hotkeys {
    /// A bound chord went down (§5.19). Hotkeys knows nothing about meaning.
    public var onAction: ((ShortcutAction) -> Void)?
    /// Fires only for `isMomentary` actions — §5.12's lag switch, the one
    /// chord whose key release is observed. Matched on the *bound* keycode.
    public var onActionRelease: ((ShortcutAction) -> Void)?
    public var onPreset: ((UUID) -> Void)?
    /// Taken as given: an action the user unbound is absent, and it stays
    /// absent — no back-filling with defaults (§5.19).
    public func setBindings(_ bindings: [ShortcutAction: HotkeyCombo])
    public func setPresetBindings(_ bindings: [(UUID, HotkeyCombo)])
    public func start()   // CGEventTap listen-only; NSEvent global monitor fallback
    public func stop()
}

/// The user's deviations from those defaults (§5.19), persisted whole under
/// `PRISM.hotkeys`. String-keyed so an action a build has never heard of
/// survives a downgrade instead of being deleted on the next save.
public struct HotkeyBindings: Codable, Equatable {
    public func combo(for action: ShortcutAction) -> HotkeyCombo?   // nil = unbound
    public func isDefault(_ action: ShortcutAction) -> Bool
    public var isDefaultEverywhere: Bool { get }
    public var resolved: [ShortcutAction: HotkeyCombo] { get }
    public mutating func set(_ combo: HotkeyCombo?, for action: ShortcutAction)
    public mutating func reset(_ action: ShortcutAction)
    public mutating func resetAll()
    public func conflict(for combo: HotkeyCombo,
                         excluding action: ShortcutAction?) -> ShortcutAction?
    /// ⌥ or ⌃ required; bare function keys allowed; modifier keys never.
    public static func isBindable(_ combo: HotkeyCombo) -> Bool
}

/// Which existing binding a candidate chord would take (§5.19). Presets are
/// in the same namespace — they go through the same tap.
public enum ShortcutConflict: Equatable {
    case action(ShortcutAction)
    case preset(id: UUID, name: String)
    public var ownerName: String { get }
}

public enum KeyCodeNames {
    /// Layout-aware (§5.19): UCKeyTranslate against the current keyboard
    /// layout, a fixed table for layout-independent keys, ANSI as last resort.
    public static func name(for keyCode: UInt16) -> String
    public static func isFunctionKey(_ keyCode: UInt16) -> Bool
    public static func isModifier(_ keyCode: UInt16) -> Bool
}

/// §5.21 — in memory, bounded, never written unless the user exports.
@MainActor
public final class SessionLog: ObservableObject {
    public static let capacity: Int                       // 300
    @Published public private(set) var events: [SessionEvent]
    @Published public private(set) var peakAddedMs: Double
    @Published public private(set) var peakStageMs: [StageID: Double]
    @Published public private(set) var droppedFrames: Int
    public let startedAt: Date
    public func record(_ kind: SessionEvent.Kind, _ text: String, at: Date = Date())
    public func observe(_ report: LatencyReport, at: Date = Date())
    public func clear()
    public func exportText(now: Date = Date()) -> String
    public static func duration(from: Date, to: Date) -> String
}

@MainActor
public final class Permissions: ObservableObject {
    @Published public private(set) var camera: PermissionState
    @Published public private(set) var microphone: PermissionState
    /// §5.24 — the conditional fourth grant. CGPreflightScreenCaptureAccess
    /// answers "granted?" and nothing else, so "never asked" and "said no"
    /// are told apart by a flag written when the prompt is first raised.
    @Published public private(set) var screenRecording: PermissionState
    public func refresh()
    public func requestCamera() async -> Bool
    public func requestMicrophone() async -> Bool
    /// Raises the system prompt, which only ever offers to open System
    /// Settings; the grant applies at the next launch. Never called from
    /// launch — only from an intent that asked for a screen.
    @discardableResult public func requestScreenRecording() -> Bool
}
```

App Intents (`PRISM/System/PrismIntents.swift`, §5.20) — `FreezeIntent`,
`MuteIntent`, `PanicIntent`, `AwayLoopIntent`, `InstantReplayIntent`,
`EyeContactIntent`, `VoiceChangerIntent`, `BackgroundBlurIntent`, each taking
a `PrismSwitchAction` (on/off/toggle), plus `ApplyPresetIntent` (preset by
name). Every `perform` resolves `AppState.current`, refuses while
`externalControlEnabled` is false, and returns confirmation only — no intent
returns video, audio, frames, buffer contents, or the session log. There is
no `AppShortcutsProvider` and no URL scheme; see §5.20 for why.

Default key codes (ANSI): F = 3, M = 46, R = 15, A = 0, P = 35, E = 14,
L = 37, B = 11, V = 9, S = 1, D = 2, T = 17. Matching is exact over
{⌥, ⌘, ⇧, ⌃}, so ⌥⌘F and ⌥⌘⇧F — and ⌥⌘S and ⌥⌘⇧S — are distinct chords.
They are defaults, not constants: `ShortcutAction.defaultCombo` owns them
and the user may rebind any of them (§5.19).

### AppState (`PRISM/AppState.swift`) — written in the integration phase

Single source of truth, `@MainActor final class AppState: ObservableObject`.
UI codes against exactly this surface:

```swift
@MainActor
public final class AppState: ObservableObject {
    // Status
    @Published public var latency: LatencyReport
    /// §5.23 — what the memory ceiling is currently paying for. Published
    /// because a freeze window that quietly halves at 60 fps is otherwise
    /// something the user cannot find out about.
    @Published public private(set) var resources: ResourcePlan
    @Published public var clients: [CameraClient]         // signing ID + name
    public var clientsInUse: [String] { get }             // names, projected
    @Published public var blockedClients: [CameraClient]  // §5.18, refused now
    @Published public var warning: WarningMessage?
    /// A second slot, never the warning's: a notice must never evict a fact.
    /// Events (§5.15, §5.16) expire on a timer; conditions (§5.17) are
    /// cleared by whoever posted them.
    @Published public var notice: NoticeMessage?
    @Published public var capturePhase: CapturePhase      // §5.16 shutter
    @Published public var menuBarState: MenuBarState
    @Published public var setup: SetupStatus
    // Controls
    @Published public var isFrozen: Bool
    @Published public var isMuted: Bool
    /// §5.17 — 0…1, scaled by MicCheck.displayLevel so the always-on meter
    /// and the mic check's meter read the same signal the same way. Zero
    /// unless something is watching.
    @Published public private(set) var inputLevel: Double
    /// §5.17 — sustained speech into a microphone nobody is hearing.
    @Published public private(set) var mutedTalking: Bool
    // Studio behaviour (§5.9–§5.11) — persisted separately from presets
    @Published public var studio: StudioSettings
    @Published public var replayMode: ReplayMode
    @Published public var replayPosition: Double
    @Published public var replayDuration: Double
    @Published public var bufferedSeconds: Double
    @Published public var isAway: Bool
    @Published public var isPanicked: Bool
    @Published public var isLagging: Bool
    @Published public var isCatchingUp: Bool
    @Published public var isBadConnection: Bool        // §5.14, never persisted
    @Published public var mutedTalking: Bool           // muted, and talking anyway
    /// Derived from `videoSource`; read-only, because a surface that could
    /// set it would move the label without moving the picture.
    @Published public private(set) var isSharingScreen: Bool
    @Published public var eyeContactTracking: Bool
    /// §5.28 — whether anybody is in front of the camera. `.unknown` whenever
    /// presence is not being watched, which is most of the time.
    @Published public private(set) var presence: PresenceState
    /// §5.28 — presence automation put something on air and is holding it
    /// there. The bit every surface needs: the user pressed nothing for this.
    @Published public private(set) var presenceEngaged: Bool
    /// §5.31 — the last gesture that fired, so a surface can say what PRISM
    /// saw. A gesture that acts without saying so is indistinguishable from
    /// a misfire, and gestures misfire.
    @Published public private(set) var lastGesture: GestureEvent?
    // Clip
    @Published public var clipState: ClipState
    @Published public var clipDuration: Double
    @Published public var clipPosition: Double
    @Published public var clipLoops: Bool
    @Published public var clipUsesClipAudio: Bool
    // Pipeline / format
    @Published public var config: PipelineConfiguration
    @Published public var stageStatus: [StageID: StageStatus]
    @Published public var publishedFormats: [VideoFormat]
    // Devices
    /// §5.24. Written only through `selectVideoSource`, which is what starts
    /// and stops the capture behind it.
    @Published public private(set) var videoSource: VideoSourceSelection  // camera by default
    /// Which screen a picture-in-picture shows while the camera is the
    /// source (§5.25). Never `.camera`.
    @Published public private(set) var screenFeed: VideoSourceSelection
    /// Empty without the Screen Recording grant; refreshed when a picker
    /// is drawn.
    @Published public private(set) var screenSources: [ScreenSourceInfo]
    @Published public var cameras: [CameraDeviceInfo]
    @Published public var microphones: [AudioDeviceInfo]
    // Presets
    @Published public var presets: [Preset]
    @Published public var activePresetID: UUID?
    // Per-app rules (§5.18) — behaviour, so they ride in `studio`, not in a
    // preset. `appRules` is a read/write projection of `studio.apps`; there
    // is one stored copy and one persisted home.
    public var appRules: AppRulesSettings { get set }
    @Published public private(set) var activeAppRule: AppRuleMatch?
    // Sections
    @Published public var expandedSections: Set<PopoverSection>
    // Popover / preview
    @Published public var popoverOpen: Bool               // gates preview path
    public var previewTextureProvider: (() -> MTLTexture?)  // for PreviewView

    // Sub-objects the UI may observe directly
    public let permissions: Permissions
    public let extensionInstaller: ExtensionInstaller
    public let presetStore: PresetStore

    public init()                                          // wires everything
    public func start()                                    // called once at launch

    // Intents (all main thread)
    public func toggleFreeze()
    public func toggleMute()
    public func freezeAndMute()
    public func loadClip(url: URL)
    public func toggleClipPlayback()
    public func stopClip()
    public func scrubClip(to seconds: Double)
    public func setStageEnabled(_ id: StageID, _ enabled: Bool)
    public func setStagePinned(_ id: StageID, _ pinned: Bool)
    // Background: blur and replacement are one question, one control (§8.7)
    public var backgroundMode: BackgroundMode { get }
    public func setBackgroundMode(_ mode: BackgroundMode)   // keeps both stages consistent
    public func setBackgroundAsset(_ url: URL?)
    // Screen source and picture-in-picture (§5.24, §5.25)
    public func selectVideoSource(_ selection: VideoSourceSelection)
    public func toggleScreenSource()                   // ⌥⌘D, camera ⇄ last screen
    public func selectScreenFeed(_ selection: VideoSourceSelection)
    public func addPictureInPicture()                  // the feed that is not on air
    public func refreshScreenSources()                 // no-op without the grant
    public func requestScreenRecordingAccess()         // asks, and nothing else
    public var videoSourceName: String { get }
    // Overlay layers (§5.8)
    public func addOverlayLayer(url: URL)
    public func updateOverlayLayer(_ id: UUID, _ mutate: (inout OverlayLayer) -> Void)
    public func removeOverlayLayer(_ id: UUID)
    public func moveOverlayLayers(fromOffsets: IndexSet, toOffset: Int)
    // Text layers (§5.26)
    public func addTextLayer()                         // a caption, seeded so it draws
    public func addLowerThird()                        // the name banner, as two fields
    public func updateOverlayText(_ id: UUID, _ mutate: (inout OverlayTextStyle) -> Void)
    // Moments (§5.9–§5.11)
    public func startReplay()
    public func stopReplay()
    public func toggleReplay()
    public func scrubReplay(to seconds: Double)
    public func setBufferArmed(_ armed: Bool)
    public func toggleAway()
    public func togglePanic()
    public func toggleEyeContact()
    // Voice changer (§5.13)
    public var isVoiceActive: Bool { get }
    public func setVoiceEffect(_ effect: VoiceEffect)  // .off = same intent as off
    public func setVoiceAmount(_ amount: Double)
    public func toggleVoice()                          // ⌃⌥⌘V, recalls last effect
    // Cleanup and the mic watch (§5.17)
    public func setVoiceCleanupMode(_ mode: VoiceCleanupMode)
    public func setVoiceCleanupAmount(_ amount: Double)
    public var isVoiceCleanupActive: Bool { get }
    public func setMicWatchEnabled(_ enabled: Bool)     // the banner is opt-in
    // Presence automation (§5.28). Watching is gated on an action or the
    // nudge being on AND the camera being the source, and that gate is the
    // whole demand for the Vision request behind it.
    /// Choosing `.loop` arms the rolling buffer, because that is where the
    /// loop comes from; both surfaces say so beside the control.
    public func setPresenceAction(_ action: PresenceAction)
    public func setPresenceAwaySeconds(_ seconds: Double)
    public func setPresenceReturnSeconds(_ seconds: Double)
    public func setPresenceCoverage(_ coverage: Double)
    public func setPresenceNotifies(_ notifies: Bool)
    /// The manual escape, behind the notice row's button, the popover's row
    /// and the pane's. Releases whatever presence engaged whether or not the
    /// detector agrees the user is back yet, and never touches a freeze or a
    /// mute the user engaged themselves.
    public func comeBack()
    // Gesture triggers (§5.31). Watching is gated on the switch being on AND
    // a pose being bound to something AND the camera being the source — the
    // same shape as presence, and likewise the whole demand for a Vision
    // request. Every firing is announced: a hand in the air has no click.
    public func setGesturesEnabled(_ enabled: Bool)
    /// Binding a pose enables it; binding it to `.none` disables it. Any
    /// other pairing leaves a row whose switch and menu disagree.
    public func setGestureAction(_ action: GestureAction, for pose: HandPose)
    public func setGestureBindingEnabled(_ enabled: Bool, for pose: HandPose)
    public func setGestureHoldSeconds(_ seconds: Double)
    public func setGestureCooldownSeconds(_ seconds: Double)
    public func setGestureConfidence(_ confidence: Double)
    // Lag switch (§5.12)
    public func engageLag()
    public func releaseLag()
    public func toggleLag()
    /// Hotkey edge: `true` on keyDown, `false` on keyUp. A press while
    /// already lagging releases, so a missed key release cannot strand it on.
    public func handleLagKey(pressed: Bool)
    // Bad connection (§5.14): visual degrade always engages; the delay half
    // rides the §5.12 transport and is skipped (with a warning) when the
    // rolling buffer cannot carry it, and skipped outright when something is
    // already substituting — taking the one transport from an away loop would
    // put delayed LIVE camera on air with nobody there to see it. Release
    // snaps a self-engaged delay back to live and never touches one the user
    // engaged separately.
    public func engageBadConnection()
    public func releaseBadConnection()
    public func toggleBadConnection()                  // ⌥⌘B
    public func updateConfig(_ mutate: (inout PipelineConfiguration) -> Void)
    public func setActiveFormat(_ format: VideoFormat)     // free within published set
    public func requestPublishedFormatsChange(_ formats: [VideoFormat])  // reconnect confirm if clients live
    public func setLatencyPolicy(_ policy: LatencyPolicy)
    public func selectCamera(_ id: String?)
    public func selectMicrophone(_ id: String?)
    public func selectPreset(_ id: UUID)                   // 200ms crossfade, §5.5
    public func saveCurrentAsPreset(named: String)
    // §5.18 — every mutation republishes 'polc' and re-resolves the look
    public func setAppRulesEnabled(_ on: Bool)
    public func setAppRulesDefaultAccess(_ access: AppAccess)
    public func setAppRulesAnnounce(_ on: Bool)
    public func addAppRule(signingID: String, access: AppAccess, presetID: UUID?)
    public func updateAppRule(_ id: UUID, _ mutate: (inout AppRule) -> Void)
    public func removeAppRule(_ id: UUID)
    public func moveAppRules(fromOffsets: IndexSet, toOffset: Int)
    public func clearAllBlocks()                           // the escape hatch
    public func isStreamingNow(_ signingID: String) -> Bool
    public func importLUT(from url: URL)
    // Style (§5.4, §5.29, §5.30). Slot 0 is "the style"; slot 1 stacks over
    // it. Enablement follows the whole stack, not the slot just edited —
    // clearing the first of two effects is not "switch Style off".
    public func setStyleEffect(_ effect: StyleEffect)      // slot 0; .normal = same intent as off
    public func setStyleEffect(_ effect: StyleEffect, inSlot slot: Int)
    public func setStyleIntensity(_ intensity: Double, inSlot slot: Int)
    /// Arms the level mailbox on the spot rather than at the next 1 Hz
    /// reconciliation: the whole visible consequence of this switch is that
    /// the picture starts moving.
    public func setStyleAudioReactive(_ reactive: Bool, inSlot slot: Int)
    public func setStyleAudioDepth(_ depth: Double)        // one depth for the stack
    public func raiseBudgetOneStep()                       // policy pressure action
    public func toggleSection(_ s: PopoverSection)
    // Capture (§5.15, §5.16)
    /// Effects on air a saved clip would strip away, exposing what they
    /// hide. Both surfaces read this, so the standing caption and the
    /// confirmation cannot disagree.
    public var clipConcealments: [String] { get }
    /// ⌥⌘S. Modal confirmation first whenever `clipConcealments` is
    /// non-empty — the buffer is the raw camera, and this writes it.
    public func saveLastSeconds()
    public func takeSnapshot()                             // ⌥⌘⇧S; press again cancels
    public func cancelCountdown()
    public func setCaptureFolder(_ url: URL?)              // nil = ~/Movies/PRISM
    public func dismissNotice()
    public func toggleScreenSource()                       // ⌥⌘D
    // Teleprompter (§5.27). Nothing here reaches a stage: the script is a
    // floating panel over the user's own desktop, never a layer.
    /// Installed by the app delegate, which owns the panel — AppState may not
    /// reference the UI layer (PRISMTests excludes UI/**).
    public var prompterPanelHandler: ((Bool) -> Void)?
    @Published public private(set) var prompterRunning: Bool      // transient
    @Published public private(set) var prompterResetToken: Int    // bumped → back to line one
    /// ⌃⌥⌘T. Opens the panel if closed, otherwise runs or holds the scroll:
    /// the chord you reach for mid-sentence is "stop", never "dismiss".
    public func togglePrompter()
    public func setPrompterEnabled(_ enabled: Bool)        // the one show/hide path
    public func startPrompter()                            // no-op without a script
    public func stopPrompter()
    public func resetPrompter()
    public func setPrompterScript(_ script: String)        // editing returns to the top
    public func setPrompterSpeed(_ linesPerMinute: Double)
    public func setPrompterFontSize(_ points: Double)
    public func setPrompterOpacity(_ opacity: Double)
    public func setPrompterMirrored(_ mirrored: Bool)
    public func setPrompterAnchor(_ anchor: PrompterAnchor)
    // Meetings (§5.32). AppState supplies the taps and the demand signal;
    // MeetingSession owns the rest. Nothing here reaches a stage.
    public let meeting: MeetingSession
    /// ⌃⌥⌘M. Starts transcribing, or stops and files the transcript.
    /// Pressing it with transcription never switched on switches it on
    /// (§8.7) rather than doing nothing and explaining why.
    public func toggleMeeting()
    public func startMeeting()
    public func stopMeeting()
    public func setMeetingTranscribes(_ on: Bool)
    public func setMeetingModel(_ shortName: String)
    public func setMeetingLanguage(_ language: String)
    public func setMeetingFarEnd(_ source: FarEndSource)
    public func setMeetingFarEndApp(_ bundleID: String?)
    public func setMeetingFarEndLabel(_ label: String)
    public func setMeetingSilenceRMS(_ value: Double)
    public func setMeetingSavesTranscript(_ saves: Bool)
    public func setMeetingTemplate(_ name: String)
    /// The one place §5.32 reaches the network, and only on a press.
    public func writeMeetingNotes()
    public func cancelMeetingNotes()
    // Assistant (§5.33)
    public let assistant: AssistantSession
    /// Installed by the app delegate, which owns the panel — AppState may
    /// not reference the UI layer (PRISMTests excludes UI/**).
    public var assistantPanelHandler: ((Bool) -> Void)?
    /// True when a key is in the Keychain. The key itself never reaches a
    /// view, and is never written to StudioSettings.
    @Published public private(set) var hasAnthropicKey: Bool
    public func setAssistantEnabled(_ enabled: Bool)
    /// ⌃⌥⌘A. Opens the panel if closed, otherwise asks. Never dismisses.
    public func askAssistant(_ text: String? = nil)
    public func setAssistantProvider(_ kind: LLMProviderKind)
    public func setAssistantModel(_ model: String)
    public func setAssistantBaseURL(_ url: String)
    public func setAssistantOpacity(_ value: Double)
    public func setAssistantAnchor(_ anchor: AssistantAnchor)
    public func setAssistantContextTurns(_ turns: Int)
    public func setAssistantHighlightsQuestions(_ on: Bool)
    public func setAssistantAboutMe(_ text: String)
    @discardableResult public func setAnthropicKey(_ key: String) -> Bool
    // Control surface (§5.19, §5.20)
    @Published public var hotkeyBindings: HotkeyBindings
    @Published public var externalControlEnabled: Bool      // default off
    public let sessionLog: SessionLog                        // §5.21
    /// The one place a bindable action becomes behaviour — the tap and the
    /// App Intents both come through here, exhaustively.
    public func perform(_ action: ShortcutAction)
    public func shortcut(for action: ShortcutAction) -> HotkeyCombo?
    public func shortcutConflict(for combo: HotkeyCombo,
                                 excluding action: ShortcutAction?) -> ShortcutConflict?
    /// Assigns, taking the chord from whoever had it and saying so.
    public func setShortcut(_ combo: HotkeyCombo?, for action: ShortcutAction)
    public func setPresetShortcut(_ combo: HotkeyCombo?, for presetID: UUID)
    public func resetShortcut(_ action: ShortcutAction)
    public func resetAllShortcuts()
    /// Stops/starts the tap around recording, so binding a key to Panic does
    /// not also panic.
    public func beginShortcutRecording()
    public func endShortcutRecording()
    /// The running instance, for App Intents — which the system constructs
    /// and so cannot be handed a reference.
    @MainActor public private(set) static weak var current: AppState?
    public func quit()
}
```

Demand gating extends to the microphone meter (§5.17): the RT accumulation
is armed, and the 10 Hz sampling timer runs, only while a preview surface is
open *or* the microphone is off air (muted, or standing down for clip
audio) — the two situations where somebody is actually reading the level.
Idle in the menu bar and unmuted, nothing is measured, nothing is
published, and no timer runs. Suppression is acknowledged on the RT thread,
so the 1 Hz poll reconciles the gate as a backstop against a change no
intent announced.

### UI (`PRISM/UI/*.swift`)

- `DesignSystem.swift` — `enum Metrics` exactly as §8.1; helper view
  modifiers (`prismCard()`), animation constants gated on reduce-motion.
- `PopoverView.swift` — full layout §8.3; `@EnvironmentObject var state:
  AppState`. Drag-and-drop of `.cube` onto the popover calls
  `state.importLUT`. Bottom bar: gear opens the main PRISM window (there is
  no separate Settings window — see PRISMApp below), ✕ quits. The
  notice row sits under the warning row and carries `Show` when the event
  produced a file — a saved file the user cannot find was not saved.
- `CaptureSection.swift` / `MainWindow/CapturePane.swift` — §5.15/§5.16
  tiles and settings. The "raw camera, no effects, no sound" caption is
  standing rather than conditional; see §8.3.
- `PreviewView.swift` — `NSViewRepresentable` MTKView; draws
  `state.previewTextureProvider()`; `isPaused = true` + released textures
  whenever `state.popoverOpen == false`. 288×162, `cardRadius`.
- `ControlTile.swift` — §8.3 tiles (Freeze `pause.fill`, Mute
  `mic.slash.fill`, Clip `film`), accessibility per §8.5.
- `LatencyMeter.swift` — §8.6 exactly (4pt bar, thresholds, 1s smoothing,
  hover breakdown popover, click → expand Format section, a11y variants).
- `PresetBar.swift`, `EffectsSection.swift`, `FormatSection.swift`,
  `FramingSection.swift`, `VoiceSection.swift` (§5.13 effect picker + on-air
  honesty caption, §5.17 cleanup picker, and `InputLevelMeter` — the shared
  always-on meter view both the popover and the main window's Voice pane
  render, so the two can never disagree about how loud you are),
  `OnboardingView.swift` (three-step state machine
  §9 + persistent setup banner).
- `HotkeyRecorder.swift` — `HotkeyRecorderField` (§5.19; records a real key-down;
  ⎋ cancels, ⌫ clears) and `ShortcutsList`, used by the main window's
  Shortcuts pane — one list, so nothing can disagree about what is bound.
- `MainWindow/ShortcutsPane.swift`, `MainWindow/DiagnosticsPane.swift` —
  §5.19/§5.20 and §5.21 respectively.
- `PrompterSection.swift` / `MainWindow/PrompterPane.swift` — §5.27. The
  dropdown carries show / start / top, which are the controls you want while
  you are talking; the pane carries the script, speed, size, opacity, the
  mirrored mode and the standing sentence that nobody else can see any of it.
- `PrompterPanel.swift` — `PrompterPanelController` (an `NSPanel`, owned by
  the app delegate and created on first use so it remembers where it was
  dragged) plus `PrompterPanelView`. Non-activating, floating, on all spaces,
  chrome-free, controls only under the pointer. `sharingType = .none` is the
  load-bearing line: the window server refuses these pixels to every screen
  recorder, including other apps' screen shares and PRISM's own screen source
  (§5.24 already excludes PRISM-owned windows as well). Closing the panel
  calls `setPrompterEnabled(false)`, so the panel and the switch cannot
  disagree.
- `MenuBarIcon.swift` — maps `MenuBarState` → glyph. Uses asset PDFs
  `PrismGlyph` / `PrismGlyphFilled` (template) with overlay badges; falls
  back to SF Symbols if assets missing.

### PRISMApp (`PRISM/PRISMApp.swift`) — integration phase

`@main struct PRISMApp: App` — `MenuBarExtra` (`.window` style) hosting
`PopoverView`, plus an app delegate adaptor for lifecycle (start AppState,
register login item, hotkeys). There is deliberately **no** `Settings`
scene: it held a smaller, drifting copy of the framing, adjust, format, LUT
and shortcut controls, so the main window is the single settings surface and
`CommandGroup(replacing: .appSettings)` points ⌘, at it. The
delegate also owns the two AppKit windows AppState can only reach through a
closure: `MainWindowController` (`openMainWindowHandler`) and
`PrompterPanelController` (`prompterPanelHandler`, §5.27) and `AssistantPanelController` (`assistantPanelHandler`, §5.33). It also installs the real speech engine into `SpeechEngineRegistry` at launch — the app target is the only one that may name `WhisperKitEngine`.

---

## Camera extension (PRISMCameraExtension)

Standalone — links only CoreMediaIO/CoreVideo/AppKit-safe frameworks
(no AppKit UI; use CoreGraphics/CoreText for the placeholder card).
`main.swift` calls `CMIOExtensionProvider.startService(provider:)`.

- `ExtensionProvider.swift` — `PRISMExtensionProviderSource:
  CMIOExtensionProviderSource`; one device.
- `DeviceSource.swift` — `PRISMDeviceSource: CMIOExtensionDeviceSource`;
  device name "PRISM Camera", UID above; owns both streams; declares and
  handles the six custom properties; persists the published format list and
  the §5.18 access policy to its sandbox container (`formats.json` and
  `policy.json` under `~/Library/Application Support/PRISM/` inside the
  extension container); on 'pfmt' set → update both stream format arrays and
  notify clients; on 'polc' set → replace and persist the access policy.
  `PRISMAccessPolicy` owns the fail-open evaluation and the bounded list of
  recent refusals served on 'blkd'.
- `StreamSource.swift` — `PRISMStreamSource` (source) and
  `PRISMSinkStreamSource` (sink), both `CMIOExtensionStreamSource`.
  Sink: on client start, repeatedly `stream.consumeSampleBuffer(from:)`;
  each received buffer → stamp receive time → `sourceStream.send(...)` →
  record handoff ms rolling mean; notifyScheduledOutputChanged after send.
  Source: on start with no sink data for 1000ms → placeholder timer at 1fps;
  `authorizedToStartStream` consults the §5.18 policy and returns false for a
  refused client — one source stream fans out to every consumer, so a
  per-client placeholder card is not expressible.
- `PlaceholderRenderer.swift` — draws the card (§3.2: system background
  color — use a neutral dark gray #1E1E1E equivalent via CGColor, PRISM
  wordmark centered via CoreText, `PRISM is not running` 32pt 60% white
  below) into a CVPixelBuffer pool at the active format's size.

The device reports `CMIOExtensionProperty.deviceTransportType` =
`kIOAudioDeviceTransportTypeVirtual` and linkedCoreAudioDeviceUID unset.

---

## Audio plug-in (PRISMAudioPlugIn) — C++

Files: `PRISM_PlugIn.h` (shared decls), `PRISM_PlugIn.cpp` (factory,
AudioServerPlugInDriverInterface vtable, plug-in object properties),
`PRISM_Device.cpp` (device object properties + IO), `PRISM_Stream.cpp`
(stream + format properties). Based on the NullAudio architecture
(original code, Apache-2.0 header).

Object IDs: plug-in 1, device 2, input stream 3. Device per §4.2 exactly:
UID "horse.prism.PRISM.audio.device", name "PRISM Microphone", 48k only,
2ch float32 **interleaved** (8 bytes per frame — `ioMainBuffer` is a raw
sample block, never an `AudioBufferList`; see SPEC §4.2), safety
offset 512, ZTS period 4096, `kAudioDeviceTransportTypeVirtual`, input
only, no controls. `Initialize` maps the ring via
`PRISMRingBufferOpenConsumer` (never fails hard — device still publishes
and emits silence if mapping fails). IO:

- `StartIO` → anchor timestamps (`mach_absolute_time`), rate-scalar 1.0,
  and anchor device sample time 0 to the ring's write index.
- `GetZeroTimeStamp` → advance every 4096 frames.
- `DoIOOperation(kAudioServerPlugInIOOperationReadInput)` → idempotent
  sample-time-indexed read straight out of the mapped ring (no cursor, no
  scratch): the cycle's input time maps to ring positions via the StartIO
  anchor, so N simultaneous clients get the same audio. The anchor
  **self-heals**: when a requested window ends ahead of the write head
  (producer started after StartIO, app restarted) or more than
  `kPRISM_MaxCushionFrames` behind it (clock drift), it slides so the
  window lands `kPRISM_ReanchorCushionFrames` (1024, ~21ms) behind the
  write head — one splice instead of permanent silence. De-interleave into
  the two ABL buffers; silence when `PRISMRingBufferProducerIsAlive` is
  false. No locks/allocation/logging on the IO path.
- `WillDoIOOperation` → true only for ReadInput.

---

## Tools

- `Tools/build_pkg.sh` — builds Release, produces `dist/PRISM.dmg`
  (hdiutil) and `dist/PRISM-Audio.pkg` (pkgbuild, component plist, scripts
  dir with `postinstall` that installs to /Library/Audio/Plug-Ins/HAL and
  `killall coreaudiod` — actually `launchctl kickstart -k
  system/com.apple.audio.coreaudiod`).
- `Tools/notarize.sh` — `xcrun notarytool submit --keychain-profile
  "PRISM_NOTARY" --wait` + staple, for both artifacts.
- `Tools/driver_smoke/` — `main.cpp` + `run.sh`: links the driver sources
  directly and asserts §4.2 properties plus IO against the real SHM ring,
  including anchor self-healing. Calls the driver's entry points itself, so
  it can only prove the driver agrees with the *test's* model of the HAL
  contract — pair it with `mic_probe` before believing the device works.
- `Tools/mic_probe/` — `main.c` + `run.sh`: records from the installed
  "PRISM Microphone" through the real HAL and fails on silence, printing
  ring counters beside the delivered audio so a failure is attributable to
  the driver (ring advancing, output silent) or the app (ring frozen).
  `--control` records the built-in mic to prove the probe holds microphone
  permission. This is the only test that catches a driver which satisfies
  `driver_smoke` yet publishes silence to every client.
- `Tools/latency_harness/` — `harness.swift` + `run.sh`: builds a CLI that
  measures (a) ring-buffer traversal latency self-test, (b) virtual camera
  glass-to-glass estimate by timestamping a generated test pattern pushed
  through the sink and read back via AVCaptureSession on PRISM Camera.
  Prints a LatencyReport-shaped summary. Compiled ad hoc with swiftc, not
  part of the Xcode project.

## README.md

Top: Team ID / signing friction warning (§10). Then: what PRISM is,
architecture diagram (ASCII), build instructions (xcodegen + Xcode),
installation order (§9), operational hazards (§9), latency model (§6),
license (Apache-2.0), and a "no network access" trust note (§7).

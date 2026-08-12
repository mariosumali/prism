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
  `PipelineConfiguration`, `Preset`, `HotkeyCombo`
- `PRISM/AppStateTypes.swift` — `CameraDeviceInfo`, `AudioDeviceInfo`,
  `MenuBarState`, `PermissionState`, `ExtensionStatus`, `SetupStatus`,
  `WarningMessage`, `ClipState`, `StageStatus`, `PopoverSection`
- `PRISMKernels/KernelTypes.h` — kernel parameter structs (bridged to Swift)

Language: Swift 5.9, macOS 13.0 deployment target. No Swift 6 concurrency
annotations (`@MainActor` on UI-facing classes is fine; no `Sendable`
churn). No third-party dependencies. No network access anywhere.

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

CMIOExtension side declares these as
`CMIOExtensionProperty(rawValue: "4cc_pfmt_glob_0000")` (same pattern for
`clnt`, `hoff`) in `availableProperties` of the **device** source, handles
them in `deviceProperties(forProperties:)` / `setDeviceProperties(_:)`.
App side reads/writes them with the CMIO C API
(`CMIOObjectGetPropertyData` / `CMIOObjectSetPropertyData`) using
`CMIOObjectPropertyAddress(mSelector: fourCC, mScope:
kCMIOObjectPropertyScopeGlobal, mElement: kCMIOObjectPropertyElementMain)`
on the PRISM Camera device object.

The extension defines its own tiny Codable mirror of the format entry
(`struct ExtFormat: Codable { var width: Int; var height: Int; var
frameRate: Int }`) — it must not link app sources. JSON keys must match
`VideoFormat`'s (`width`, `height`, `frameRate`).

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
| `prism_composite` | Composite.metal | sharp t0, blurred t1, mask `texture2d<float>` t2 (single channel, person = 1), dst t3, `constant PRISMCompositeParams&` b0 |
| `prism_output_fit` | Composite.metal | src t0, dst t1, `constant PRISMFitParams&` b0 — scale/offset content, bars are opaque black |
| `prism_crossfade` | Composite.metal | a t0, b t1, dst t2, `constant PRISMCrossfadeParams&` b0 |
| `prism_sharpness` | Composite.metal | src t0, `device float*` b0 (result), `constant PRISMSharpnessParams&` b1 — dispatched as **one** threadgroup of 256 threads; each thread strides a 128×72 sample grid of src, computes 3×3 Laplacian of luma, threadgroup-reduces the variance, thread 0 writes `result[slot]` |

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
    public var clipStage: ClipStage { get }
    public var freezeStage: FreezeStage { get }
    public var geometryStage: GeometryStage { get }
    public var adjustStage: AdjustStage { get }
    public var lutStage: LUTStage { get }
    public var blurStage: BlurStage { get }

    /// Post-effects output: IOSurface-backed buffer ready for the sink,
    /// plus the final texture for the preview. Called on the capture queue.
    public var onOutput: ((CVPixelBuffer, CMTime, MTLTexture) -> Void)?
    /// Per-frame timings for LatencyMonitor. Called on an arbitrary queue.
    public var onTimings: ((StageTimings) -> Void)?

    public init(metal: MetalContext) throws
    public func configure(outputFormat: VideoFormat)
    /// Live camera frame. Also drives clip/freeze substitution.
    public func submitCameraFrame(_ buffer: CVPixelBuffer, at time: CMTime)
    /// Heartbeat when no camera is available (timer-driven at output fps)
    /// so clip playback and freeze keep producing frames.
    public func tickWithoutCamera(at time: CMTime)
    public func setFrozen(_ frozen: Bool)              // §5.2 sharpest-frame
    public var isFrozen: Bool { get }
    public func apply(_ config: PipelineConfiguration)
    /// 200ms output crossfade (preset switch, clip → live return).
    public func beginCrossfade(durationMs: Double)
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

### FrameRing (`PRISM/Pipeline/FrameRing.swift`)

```swift
public final class FrameRing {
    public let capacity: Int                      // 15
    public let sharpnessBuffer: MTLBuffer         // capacity × Float
    public init(metal: MetalContext, width: Int, height: Int) throws
    /// Copy (GPU blit, IOSurface pool) the frame into the ring; returns slot.
    public func record(_ buffer: CVPixelBuffer, at time: CMTime,
                       encoder commandBuffer: MTLCommandBuffer) -> Int
    /// Sharpest stored frame within [now − windowMs, now − skipMs] (§5.2:
    /// windowMs 300, skipMs 0). Reads sharpnessBuffer CPU-side.
    public func sharpestFrame(nowTime: CMTime, windowMs: Double) -> CVPixelBuffer?
    public func reconfigure(width: Int, height: Int) throws
}
```

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

### AudioCapture (`PRISM/Capture/AudioCapture.swift`)

```swift
public final class AudioCapture {
    public var sink: AudioSink?                    // written on RT thread — set before start
    /// Mute writes silence into the ring (mic muted ≠ ring stalled).
    public var isMuted: Bool { get set }           // atomic flag
    /// While clip audio owns the ring, live capture stands down.
    public var isSuppressed: Bool { get set }      // atomic flag
    public private(set) var effectiveBufferFrames: Int   // 256 requested (§4.4)
    public var addedLatencyMs: Double { get }      // buffer/48k*1000 + ring estimate
    public init()
    public func start(deviceUID: String?)          // nil = default input
    public func stop()
    public func restart()                          // sleep/wake
}
```

Render callback: pull from HALOutput input scope, convert to 48kHz stereo
float interleaved (AudioConverter when needed, mono duplicated), then
`sink.write(...)`. **The callback body must be free of ObjC/Swift
allocation; preallocate all conversion buffers in `start`.**

### DeviceMonitor (`PRISM/Capture/DeviceMonitor.swift`)

```swift
public final class DeviceMonitor {
    public var onCamerasChanged: (([CameraDeviceInfo]) -> Void)?      // main thread
    public var onMicrophonesChanged: (([AudioDeviceInfo]) -> Void)?   // main thread
    /// Fired when the *selected* device vanished; name for the warning row.
    public var onWake: (() -> Void)?                                  // §7
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
    /// Client signing IDs decoded from 'clnt', mapped to display names.
    public var onClientsChanged: (([String]) -> Void)?       // main thread
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
}
public final class AdjustStage: EffectStage {      // id .adjust, cost .cheap
    public var settings: AdjustSettings
}
public final class LUTStage: EffectStage {         // id .lut, cost .moderate
    public var settings: LUTSettings { get set }   // setting lutName loads texture via LUTStore
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
public final class OutputFitStage: EffectStage {   // id .outputFit, cost .cheap, always enabled
    public var outputSize: CGSize
    public var contentMode: ClipFillMode           // letterbox default
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

public final class Hotkeys {
    public var onFreeze: (() -> Void)?             // ⌥⌘F
    public var onMute: (() -> Void)?               // ⌥⌘M
    public var onFreezeAndMute: (() -> Void)?      // ⌥⌘⇧F
    public var onPreset: ((UUID) -> Void)?
    public func setPresetBindings(_ bindings: [(UUID, HotkeyCombo)])
    public func start()   // CGEventTap listen-only; NSEvent global monitor fallback
    public func stop()
}

@MainActor
public final class Permissions: ObservableObject {
    @Published public private(set) var camera: PermissionState
    @Published public private(set) var microphone: PermissionState
    public func refresh()
    public func requestCamera() async -> Bool
    public func requestMicrophone() async -> Bool
}
```

Key codes: F = 3, M = 46 (ANSI).

### AppState (`PRISM/AppState.swift`) — written in the integration phase

Single source of truth, `@MainActor final class AppState: ObservableObject`.
UI codes against exactly this surface:

```swift
@MainActor
public final class AppState: ObservableObject {
    // Status
    @Published public var latency: LatencyReport
    @Published public var clientsInUse: [String]          // display names
    @Published public var warning: WarningMessage?
    @Published public var menuBarState: MenuBarState
    @Published public var setup: SetupStatus
    // Controls
    @Published public var isFrozen: Bool
    @Published public var isMuted: Bool
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
    @Published public var cameras: [CameraDeviceInfo]
    @Published public var microphones: [AudioDeviceInfo]
    // Presets
    @Published public var presets: [Preset]
    @Published public var activePresetID: UUID?
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
    public func updateConfig(_ mutate: (inout PipelineConfiguration) -> Void)
    public func setActiveFormat(_ format: VideoFormat)     // free within published set
    public func requestPublishedFormatsChange(_ formats: [VideoFormat])  // reconnect confirm if clients live
    public func setLatencyPolicy(_ policy: LatencyPolicy)
    public func selectCamera(_ id: String?)
    public func selectMicrophone(_ id: String?)
    public func selectPreset(_ id: UUID)                   // 200ms crossfade, §5.5
    public func saveCurrentAsPreset(named: String)
    public func importLUT(from url: URL)
    public func raiseBudgetOneStep()                       // policy pressure action
    public func toggleSection(_ s: PopoverSection)
    public func quit()
}
```

### UI (`PRISM/UI/*.swift`)

- `DesignSystem.swift` — `enum Metrics` exactly as §8.1; helper view
  modifiers (`prismCard()`), animation constants gated on reduce-motion.
- `PopoverView.swift` — full layout §8.3; `@EnvironmentObject var state:
  AppState`. Drag-and-drop of `.cube` onto the popover calls
  `state.importLUT`. Bottom bar: gear opens Settings window, ✕ quits.
- `PreviewView.swift` — `NSViewRepresentable` MTKView; draws
  `state.previewTextureProvider()`; `isPaused = true` + released textures
  whenever `state.popoverOpen == false`. 288×162, `cardRadius`.
- `ControlTile.swift` — §8.3 tiles (Freeze `pause.fill`, Mute
  `mic.slash.fill`, Clip `film`), accessibility per §8.5.
- `LatencyMeter.swift` — §8.6 exactly (4pt bar, thresholds, 1s smoothing,
  hover breakdown popover, click → expand Format section, a11y variants).
- `PresetBar.swift`, `EffectsSection.swift`, `FormatSection.swift`,
  `FramingSection.swift`, `OnboardingView.swift` (three-step state machine
  §9 + persistent setup banner), `SettingsView.swift` (deeper controls:
  pan, crop aspect, orientation, per-adjustment sliders, published format
  set editor, hotkey list, login item toggle, LUT management).
- `MenuBarIcon.swift` — maps `MenuBarState` → glyph. Uses asset PDFs
  `PrismOutline` / `PrismFilled` (template) with overlay badges; falls back
  to SF Symbols if assets missing.

### PRISMApp (`PRISM/PRISMApp.swift`) — integration phase

`@main struct PRISMApp: App` — `MenuBarExtra` (`.window` style) hosting
`PopoverView`, `Settings` scene hosting `SettingsView`, app delegate
adaptor for lifecycle (start AppState, register login item, hotkeys).

---

## Camera extension (PRISMCameraExtension)

Standalone — links only CoreMediaIO/CoreVideo/AppKit-safe frameworks
(no AppKit UI; use CoreGraphics/CoreText for the placeholder card).
`main.swift` calls `CMIOExtensionProvider.startService(provider:)`.

- `ExtensionProvider.swift` — `PRISMExtensionProviderSource:
  CMIOExtensionProviderSource`; one device.
- `DeviceSource.swift` — `PRISMDeviceSource: CMIOExtensionDeviceSource`;
  device name "PRISM Camera", UID above; owns both streams; declares and
  handles the three custom properties; persists the published format list to
  its sandbox container (`~/Library/Application Support/PRISM/formats.json`
  inside the extension container); on 'pfmt' set → update both stream
  format arrays and notify clients.
- `StreamSource.swift` — `PRISMStreamSource` (source) and
  `PRISMSinkStreamSource` (sink), both `CMIOExtensionStreamSource`.
  Sink: on client start, repeatedly `stream.consumeSampleBuffer(from:)`;
  each received buffer → stamp receive time → `sourceStream.send(...)` →
  record handoff ms rolling mean; notifyScheduledOutputChanged after send.
  Source: on start with no sink data for 1000ms → placeholder timer at 1fps.
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
2ch float32 **non-interleaved** (two AudioBuffers in the ABL), safety
offset 512, ZTS period 4096, `kAudioDeviceTransportTypeVirtual`, input
only, no controls. `Initialize` maps the ring via
`PRISMRingBufferOpenConsumer` (never fails hard — device still publishes
and emits silence if mapping fails). IO:

- `StartIO` → anchor timestamps (`mach_absolute_time`), rate-scalar 1.0.
- `GetZeroTimeStamp` → advance every 4096 frames.
- `DoIOOperation(kAudioServerPlugInIOOperationReadInput)` → read
  interleaved from ring via `PRISMRingBufferRead` into a preallocated
  scratch, de-interleave into the two ABL buffers; silence when
  `PRISMRingBufferProducerIsAlive` is false. No locks/allocation/logging
  on the IO path (a static scratch sized for 4096 frames is fine).
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

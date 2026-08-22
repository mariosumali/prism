# PRISM — Implementation Specification

**Target** macOS 13.0+ (Ventura), Apple Silicon primary, Intel supported at reduced effects tier
**Language** Swift 5.9+ (app, camera extension), C/C++ (audio plug-in), Metal Shading Language (kernels)
**License** Apache-2.0
**Version** 1.0

This document is written to be implemented directly. Where a value could reasonably be debated, a value has been chosen. Implement what is written; do not substitute alternatives.

---

## 1. What PRISM is

PRISM is a resident macOS menu bar agent that sits between physical capture hardware and every application that consumes camera and microphone input. It publishes two synthetic devices:

- `PRISM Camera` — a CoreMediaIO Camera Extension, selectable in any app including FaceTime, Photo Booth, QuickTime, Zoom, Safari, Meet, Discord.
- `PRISM Microphone` — an AudioServerPlugIn, selectable as a system input device.

Default behavior is transparent pass-through. On top of that PRISM provides freeze-frame, clip substitution, and a GPU effects chain, applied without the client application's knowledge and without perceptible added latency.

PRISM has no Dock icon and no main window. `LSUIElement` is `true`.

---

## 2. Component map

Three separately-signed components.

| Component | Bundle ID | Type | Runs as | Installed to |
|---|---|---|---|---|
| PRISM.app | `horse.prism.PRISM` | Menu bar agent | User | `/Applications` |
| Camera Extension | `horse.prism.PRISM.camera` | CMIOExtension (System Extension) | Root, sandboxed | `/Library/SystemExtensions/` (by macOS) |
| Audio Plug-In | `horse.prism.PRISM.audio` | AudioServerPlugIn | Hosted in `coreaudiod` | `/Library/Audio/Plug-Ins/HAL/PRISM.driver` |

Replace `horse.prism` with your own reverse-DNS prefix and `TEAMID` with your Apple Developer Team ID throughout. These strings appear in entitlements, `Info.plist`, Mach service names, and the shared memory path, and must match exactly across all three targets.

### 2.1 Repository layout

```
PRISM/
├── PRISM.xcodeproj                 # generated; project.yml is the source
├── project.yml                     # XcodeGen: targets, sources, entitlements
├── PRISM/                          # Menu bar agent
│   ├── PRISMApp.swift              # @main, MenuBarExtra
│   ├── AppState.swift              # ObservableObject, single source of truth
│   ├── AppStateTypes.swift         # the state vocabulary every surface reads
│   ├── Capture/
│   │   ├── CameraCapture.swift     # AVCaptureSession wrapper
│   │   ├── ScreenCapture.swift     # ScreenCaptureKit source, §5.24
│   │   ├── AudioCapture.swift      # HAL input AudioUnit wrapper
│   │   ├── AudioDelayLine.swift    # the deliberate delay, §5.12
│   │   ├── VoiceChanger.swift      # pitch/formant effects, §5.13
│   │   ├── VoiceCleanup.swift      # gate, de-esser, ducking, §5.17
│   │   ├── MicCheck.swift          # listen back to yourself, §5.13
│   │   ├── InputLevel.swift        # RT → UI level mailbox, §5.17
│   │   ├── SystemAudioCapture.swift # the far end, audio-only SCStream, §5.32
│   │   └── DeviceMonitor.swift     # hot-plug, default-device changes
│   ├── AI/                         # §5.32 transcript, §5.33 assistant
│   │   ├── Speech/
│   │   │   ├── SpeechRecognizing.swift    # the seam + engine registry
│   │   │   ├── SpeechModelCatalog.swift   # models, sizes, where they live
│   │   │   ├── SpeechResampler.swift      # 48k → 16k, anti-aliased
│   │   │   ├── SpeechVAD.swift            # energy VAD + chunk policy
│   │   │   ├── RollingSpeechBuffer.swift  # the decode window, absolute times
│   │   │   └── LocalAgreement.swift       # confirm rule for live hypotheses
│   │   ├── Engines/                # the ONLY directory importing WhisperKit
│   │   │   └── WhisperKitEngine.swift
│   │   ├── Transcript/
│   │   │   ├── TranscriptTypes.swift        # word, delta, line, channel
│   │   │   ├── TranscriptChannelState.swift # watermark dedup + stitching
│   │   │   ├── TranscriptRenderer.swift     # the two-stream merge
│   │   │   ├── TranscriptSanitizer.swift    # hallucination filters
│   │   │   └── TranscriptStore.swift        # transcripts on disk, never audio
│   │   ├── LLM/
│   │   │   ├── LLMProvider.swift            # protocol + request/event types
│   │   │   ├── LLMTransport.swift           # the ONLY networking file, §7
│   │   │   ├── SSEParser.swift              # three wire formats, no sockets
│   │   │   ├── AnthropicProvider.swift
│   │   │   ├── OllamaProvider.swift
│   │   │   ├── OpenAICompatibleProvider.swift
│   │   │   ├── TranscriptChunker.swift      # map-reduce routing
│   │   │   ├── NoteTemplate.swift           # note structure as data
│   │   │   └── Prompts.swift                # every prompt string, cited
│   │   └── Meeting/
│   │       ├── MeetingSession.swift         # the live transcript machine
│   │       ├── AssistantSession.swift       # push-to-ask + stall watchdog
│   │       ├── MeetingNoteWriter.swift      # notes, one pass or map-reduce
│   │       └── QuestionDetector.swift       # lights a control, never sends
│   ├── Pipeline/
│   │   ├── VideoPipeline.swift     # frame graph orchestration
│   │   ├── DraftRenderer.swift     # second chain previewing a staged edit
│   │   ├── EffectStage.swift       # protocol, StageID, chain order
│   │   ├── Stages/                 # one file per stage in the §3.3 chain
│   │   ├── StageSettings.swift     # per-stage settings, PipelineConfiguration
│   │   ├── StudioSettings.swift    # replay, away, panic, lag, voice, connection
│   │   ├── Settings/               # behaviour settings a preset must not carry
│   │   │                           #   (incl. AppRuleSettings: §5.18 rules + resolver)
│   │   ├── FrameRing.swift         # sharpest-frame buffer (camera side)
│   │   ├── StillRing.swift         # a few finished frames, scored, for stills
│   │   ├── ReplayBuffer.swift      # rolling compressed seconds, §5.9
│   │   ├── ReplayPlayer.swift      # the one replay / away / lag transport
│   │   ├── PresenceWatcher.swift   # are you still there, §5.28
│   │   ├── GestureWatch.swift      # hand poses as triggers, §5.31
│   │   ├── ResourceGovernor.swift  # who gets the memory ceiling (§5.23, §7)
│   │   ├── VisionCoordinator.swift # which Vision request runs this frame
│   │   ├── FormatManager.swift     # advertised format set, negotiation
│   │   ├── PresetStore.swift       # named user configurations
│   │   └── LatencyMonitor.swift    # per-stage timing, budget enforcement
│   ├── Media/                      # everything on air that is not the camera
│   │   ├── LayerSource.swift       # image / video decode for a layer, §5.8
│   │   ├── LiveFeeds.swift         # a camera or screen as a layer, §5.25
│   │   └── TextRasterizer.swift    # Core Text → MTLTexture, §5.26
│   ├── Sinks/
│   │   ├── CMIOSink.swift          # push frames to camera extension
│   │   └── AudioSink.swift         # write PCM to shared ring buffer
│   ├── Clip/
│   │   └── ClipPlayer.swift        # AVAssetReader-based decode
│   ├── Export/                     # §5.15, §5.16 — frames onto disk
│   │   ├── CaptureDestination.swift  # folder, screenshot-convention names
│   │   ├── ClipPlan.swift            # trim / rebase / duration synthesis
│   │   ├── ClipExporter.swift        # AVAssetWriter passthrough remux
│   │   ├── ClipDisclosure.swift      # what a saved clip would reveal
│   │   └── StillExporter.swift       # CGImageDestination PNG / HEIC
│   ├── UI/
│   │   ├── PopoverView.swift       # the menu bar surface, §8.3
│   │   ├── *Section.swift          # one collapsible section per area
│   │   ├── MainWindow/             # the full window; one pane per area
│   │   │   ├── MainWindowController.swift
│   │   │   ├── MainWindowView.swift
│   │   │   └── *Pane.swift         # the same areas with room to breathe
│   │   ├── PreviewView.swift       # MTKView wrapper
│   │   ├── PanePreview.swift       # the preview a pane hosts
│   │   ├── ControlTile.swift
│   │   ├── MenuBarIcon.swift       # MenuBarState → glyph, §8.2
│   │   ├── LatencyMeter.swift      # live readout + per-stage breakdown
│   │   ├── PresetBar.swift
│   │   ├── HotkeyRecorder.swift    # chord recorder + shared list, §5.19
│   │   ├── PrompterPanel.swift     # the always-on-top script, §5.27
│   │   ├── OnboardingView.swift
│   │   └── DesignSystem.swift      # tokens, §8.1
│   ├── System/
│   │   ├── ExtensionInstaller.swift  # OSSystemExtensionManager
│   │   ├── LoginItem.swift           # SMAppService
│   │   ├── Hotkeys.swift             # CGEventTap, ShortcutAction + defaults
│   │   ├── HotkeyBindings.swift      # the user's rebindings, §5.19
│   │   ├── KeyCodeNames.swift        # keycode → glyph via the active layout
│   │   ├── PrismIntents.swift        # App Intents, §5.20
│   │   ├── SessionLog.swift          # in-memory session history, §5.21
│   │   ├── Keychain.swift            # the one secret PRISM holds, §5.33
│   │   └── Permissions.swift         # AVCaptureDevice authorization
│   └── Resources/
│       ├── Assets.xcassets
│       └── LUTs/                   # bundled .cube files
├── PRISMCameraExtension/
│   ├── main.swift
│   ├── ExtensionProvider.swift     # CMIOExtensionProviderSource
│   ├── DeviceSource.swift          # CMIOExtensionDeviceSource, access policy
│   ├── StreamSource.swift          # source + sink CMIOExtensionStreamSource
│   └── PlaceholderRenderer.swift   # "PRISM not running" card
├── PRISMAudioPlugIn/
│   ├── PRISM_PlugIn.cpp / .h       # AudioServerPlugInDriverInterface
│   ├── PRISM_Device.cpp
│   ├── PRISM_Stream.cpp
│   └── Info.plist
├── PRISMShared/                    # compiled into app, tests and plug-in
│   ├── RingBuffer.h / .c           # lock-free SPSC, shared by app + plug-in
│   ├── SharedTypes.h               # SHM name, control block layout
│   └── PixelFormats.swift
├── PRISMKernels/
│   ├── KernelTypes.h               # the param structs Swift and Metal share
│   ├── Adjust.metal
│   ├── Blur.metal
│   ├── Composite.metal
│   ├── Gaze.metal
│   ├── Geometry.metal
│   ├── Layers.metal
│   ├── LUT.metal
│   ├── Retouch.metal
│   └── Style.metal
├── PRISMTests/                     # one suite per contract in CONTRACTS.md
├── docs/
│   ├── SPEC.md
│   └── CONTRACTS.md                # moves in lockstep with behaviour
└── Tools/
    ├── latency_harness/            # measures end-to-end added latency
    ├── driver_smoke/               # the audio plug-in without the app
    ├── mic_probe/                  # what the HAL actually hands us
    ├── build_pkg.sh
    ├── install_audio.sh
    ├── rebuild.sh
    ├── run_local.sh
    ├── make_icon.swift
    └── notarize.sh
```

---

## 3. Video path

### 3.1 Architecture rule

The camera extension is a dumb relay. It exposes a **sink stream** that PRISM.app writes into and a **source stream** that client apps read from, and forwards sink → source. All processing lives in PRISM.app.

The one decision the extension makes for itself is whether a client may start streaming at all (§5.18) — it has to, because that decision has to hold when PRISM is not running. It is a set-membership test against a policy the app ships it, it fails open on every unclear path, and it touches no pixels.

This is not a style preference. System extensions run as root while the app runs as the user; App Groups do not cross that boundary and direct app-to-extension XPC is unavailable. The CMIO sink stream is therefore the IPC channel — do not build a second one. Keeping the extension thin also means effects changes never require reloading the system extension, which frequently demands a reboot.

### 3.2 Extension specification

`CMIOExtensionProviderSource` publishes one device, `PRISM Camera`, with two streams.

**Source stream (`.source` direction)** — advertises a *set* of formats, exactly as a physical webcam does. Clients negotiate and pick one. `CMIOExtensionStreamSource.formats` returns an array of `CMIOExtensionStreamFormat`.

Default published set:

| Dimensions | Frame rates |
|---|---|
| 3840 × 2160 | 30 |
| 1920 × 1080 | 24, 30, 60 |
| 1280 × 720 | 24, 30, 60 |
| 960 × 540 | 30 |
| 640 × 480 | 30 |

Pixel format `kCVPixelFormatType_32BGRA`, sRGB, for all entries.

The user edits this set in Settings — any subset, plus custom entries. Two reasons to expose it rather than always publishing everything: some client apps default to the highest advertised resolution and will pin PRISM at 4K when the user wanted 720p, and a shorter list makes the picker in Zoom navigable.

**Mutating the published set is a reconnect boundary.** Clients handle a mid-session change to the format list badly. Rules:

- The set may be changed freely while no client is streaming; it applies immediately.
- If one or more clients are streaming, PRISM shows a confirmation naming them: `Zoom and FaceTime will need to reselect PRISM Camera. Change anyway?`
- On confirm, the extension republishes and PRISM posts a notification telling the user to reselect the camera in those apps.
- Never republish silently.

Switching the *active* format within the already-published set is free and requires no reconnect — that's ordinary client negotiation.

**Sink stream (`.sink` direction)** — publishes the same format set. PRISM.app consumes it via the CoreMediaIO C API (`CMIOObjectGetPropertyData` to enumerate, `CMIOStreamCopyBufferQueue` to enqueue). `FormatManager` keeps sink and source sets identical at all times; a mismatch is a hard error and must assert in debug builds.

**Source-to-output resolution.** The physical camera's native format and the negotiated output format are independent. `FormatManager` selects the physical capture format as the smallest native format greater than or equal to the negotiated output in both dimensions, to avoid upscaling. If no native format is large enough, use the largest available and upscale with Lanczos in the Geometry stage.

**Access.** `authorizedToStartStream` on the source stream enforces the §5.18 per-app policy, shipped over the `'polc'` custom property. Refusal is per-client, but the picture is not: one source stream fans out to every consumer, so a refused client is refused rather than shown a card.

**Placeholder state.** When the sink has not received a frame in 1000ms, the source stream emits a placeholder card at 1 fps: system background color, PRISM wordmark centered, and the text `PRISM is not running` below it in 32pt system font at 60% opacity. Never emit a black frame — a black frame reads as broken hardware and generates support noise.

Entitlements required on the extension target:

```xml
<key>com.apple.security.app-sandbox</key><true/>
<key>com.apple.security.application-groups</key>
<array><string>TEAMID.horse.prism.PRISM</string></array>
```

### 3.3 Frame pipeline

`CameraCapture` runs an `AVCaptureSession` with an `AVCaptureVideoDataOutput`. Configure:

- `alwaysDiscardsLateVideoFrames = true`
- `videoSettings = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA]`
- Delegate queue: dedicated serial `DispatchQueue` at `.userInteractive` QoS
- `CVPixelBufferPool` with `kCVPixelBufferMetalCompatibilityKey: true` and `kCVPixelBufferIOSurfacePropertiesKey: [:]`

Every buffer stays `IOSurface`-backed from capture to sink push. No CPU readback, no `memcpy`. Wrap `CVPixelBuffer` as `MTLTexture` via `CVMetalTextureCache`.

`VideoPipeline` executes an ordered array of `EffectStage`. Each stage:

```swift
protocol EffectStage {
    var id: StageID { get }
    var isEnabled: Bool { get set }
    var cost: StageCost { get }        // .cheap, .moderate, .expensive
    func encode(commandBuffer: MTLCommandBuffer,
                input: MTLTexture,
                output: MTLTexture) throws
}
```

All stages encode into a **single** `MTLCommandBuffer` per frame. One commit, one `addCompletedHandler`. Do not create a command buffer per stage.

Stage order is fixed:

```
Clip → Replay → Freeze → Eye contact → Geometry → Skin retouch → Adjust →
LUT → Background blur → Virtual background → Overlay → Style →
Bad connection → Output fit → Push
```

The three substituting stages come first because they replace the source; everything downstream applies to whatever the source ends up being. They are ordered by escalating authority: a replay overrides a playing clip, and a freeze overrides a replay — each is a more deliberate "stop showing me live" than the one before it. Since every substituting stage writes the whole frame, chain position *is* precedence.

Eye contact precedes Geometry so the warp happens in the same space Vision measured its landmarks in; putting it after zoom and rotation would mean transforming every landmark through the geometry matrix just to stay aligned. Geometry precedes color so that crop and zoom do not change how a LUT reads.

Skin retouch (§5.22) sits between Geometry and Adjust, and that is the only place it can sit. Its gate is skin chroma, not a face rectangle: Geometry above it only moves pixels around and leaves the gate reading exactly what the camera reported, while any colour stage above it — an exposure lift, a warmer temperature, a LUT — would detune the gate, so the smoothing would drift off the face precisely when the user warms the picture.

Background blur, Virtual background and Overlay all consume the same person mask and composite over the finished look, so they run last. Blur and Virtual background are mutually exclusive — they answer the same question — and the UI presents them as one control (§8.7). Overlay follows Virtual background so a foreground layer sits above a replaced background.

Style (§5.4) is the last composing stage: a preset look applies to the finished scene — backdrop and overlays included — exactly as Photo Booth styles a finished photo, not the raw camera under it.

Bad connection (§5.14) runs after everything the user composes, because a struggling network degrades the finished picture — backdrop, overlays, effects and styled look included. A crisp overlay on a pixelated face would give the game away instantly. Like the substituting stages it is engaged by intent, never by a preset.

Output fit is not a user stage — it is the final scale/letterbox into the negotiated format and always runs.

**One face measurement per frame.** The same rule, one model along: eye contact (§5.6) and face-anchored overlay layers (§5.8) want the same 76-point landmark constellation, so a shared `FaceTracker` owns the request and the pipeline drives it **once**, at the first face-consuming stage's position in the chain — pre-Geometry, which is the space eye contact warps in and the space face-anchored placement is built in. Detection is demand-gated: no consumer, no Vision request, and the measurement is dropped when the last one goes away so a re-enabled feature never anchors to a stale face. Demand is per-layer, not per-stage — a frame-anchored overlay layer raises none of it. Skin retouch (§5.22) is deliberately not a consumer: its gate is skin chroma, so switching it on buys no Vision request of either kind.

**One segmentation per frame.** Four features need the person mask: background blur (§5.4), virtual backgrounds (§5.7), overlay layers placed behind the subject (§5.8), and auto-framing (§5.4). Segmentation is the single most expensive thing in the pipeline, so it runs **once**, driven by the pipeline at the first mask-consuming stage's position in the chain, and every consumer shares the result. Running two of these features together must cost one segmentation, not two. The mask is captured post-Geometry so it aligns with everything that samples it, and so auto-framing remains the closed-loop servo it is specified to be.

### 3.4 Latency budget and degradation

`LatencyMonitor` records GPU time per stage using `MTLCommandBuffer.gpuStartTime`/`gpuEndTime`, maintaining a 60-frame rolling mean per stage and in total. It also measures capture-to-push wall time and the sink-to-source hop, so the app can report **total added latency** rather than only GPU time.

The GPU budget is not a constant. It derives from the negotiated frame rate and a user-selected policy:

```swift
enum LatencyPolicy: String, CaseIterable {
    case lowest    // budget = 20% of frame interval
    case balanced  // budget = 40% of frame interval   (default)
    case quality   // budget = 70% of frame interval
}
```

| Policy | 60fps (16.7ms) | 30fps (33.3ms) | 24fps (41.7ms) |
|---|---|---|---|
| Lowest latency | 3.3ms | 6.7ms | 8.3ms |
| Balanced | 6.7ms | 13.3ms | 16.7ms |
| Maximum quality | 11.7ms | 23.3ms | 29.2ms |

**Degradation.** When the 60-frame mean total GPU time exceeds the budget, disable the most expensive stage the engine is allowed to give up (`.expensive` before `.moderate` before `.cheap`; ties broken by later position in the chain), post a UI warning naming the disabled stage, and mark it `autoDisabled`. Re-enable automatically when the mean drops below 60% of budget for 120 consecutive frames, most recently disabled first.

**What it is allowed to give up is a look, and only a look.** The substituting stages (clip, replay, freeze) and Bad connection are engaged by intent, never by a preset, and auto-disabling one of them would put the live camera back on air behind the user's back — the one failure this app must never produce. Output fit is structural. Everything else is a candidate, and three filters sit on top of the pick, composing in a fixed order.

A **pinned** stage is exempt outright (below). A stage the engine has just **restored** is held for 30 seconds and cannot be sacrificed again inside that window: without the hold, a chain that is over budget with a look on and under 60% of budget with it off disables it, waits out the 120-frame quiet streak, restores it, and disables it again — a look flickering on and off forever, which reads as a bug and is worse than either steady state.

The **last-resort** stage — the virtual background, `StageID.isLastResort` — is weighed only when no ordinary look is *enabled at all*. Cost-first with a later-position tie-break would otherwise pick it first among the expensive stages, which is precisely backwards: §5.7 requires every degraded path to err toward covering the room the user chose to hide, and switching the backdrop off reveals it. "No ordinary look left" deliberately means none is **enabled**, which is not the same test as none being **available this round**: a look inside its restore hold is still on air, and reading its absence from the round's candidates as an empty pool would hand the room back to the call in order to protect a style from flicker. When every ordinary look is merely held, the round has nothing to give and raises policy pressure instead, which is what the hold was always for. The exemption is a delay, not a veto: once no ordinary look is left, the backdrop is the candidate and does go.

The user can pin any stage as **required**, which exempts it from automatic disabling. If a pinned chain cannot meet budget, PRISM degrades the *policy* instead — surfacing `Effects are exceeding your latency budget` with a one-tap action to raise it — rather than dropping frames.

Frames are never dropped to preserve an effect. A stutter is far more noticeable to a viewer than a filter switching off.

---

## 4. Audio path

### 4.1 Why AudioServerPlugIn and not AudioDriverKit

Apple's guidance is that DriverKit entitlements are not granted for purely virtual audio devices and that the audio server plug-in model should continue to be used for them. Developers have shipped working AudioDriverKit virtual drivers and only then discovered the entitlement is unobtainable. Use `AudioServerPlugIn`.

Consequences to accept: the plug-in installs to `/Library/Audio/Plug-Ins/HAL/`, requires a `.pkg` whose postinstall script restarts `coreaudiod`, cannot ship in the Mac App Store, and cannot be debugged with SIP enabled. Budget a SIP-disabled development machine or VM.

**Licensing constraint:** do not copy code from BlackHole or BackgroundMusic. Both are GPL and copying would force PRISM to GPL. Start from Apple's `NullAudio` sample. Read the others for technique only.

### 4.2 Device specification

`PRISM Microphone` is **input-only**. Do not publish a paired output device — a loopback cable is a different product with worse UX.

```
Sample rate:       48000 Hz (only)
Channels:          2 (stereo)
Format:            32-bit float, interleaved (8 bytes per frame)
Transport type:    kAudioDeviceTransportTypeVirtual
Safety offset:     512 frames
Zero timestamp period: 4096 frames
```

**Interleaved, not planar.** `DoIOOperation`'s `ioMainBuffer` is one raw block of sample data — `AudioServerPlugIn.h` calls it "the primary buffer for the data for the operation", and `NullAudio` copies frames straight into it. It is *not* an `AudioBufferList`, so a stream has nowhere to put a second per-channel plane. Publishing a non-interleaved format (as v1 did) and reading the buffer as an ABL makes the first sample masquerade as `mNumberBuffers`; against a HAL-zeroed buffer that reads 0, the driver writes nothing, and the device emits silence to every client while the ring underneath carries perfectly good audio. The ring is interleaved too, so ReadInput is a straight copy.

Mono physical sources are duplicated to both channels in PRISM.app before the ring write.

### 4.3 Shared ring buffer

The app is the producer, `coreaudiod` is the consumer. Single-producer/single-consumer, wait-free on both sides.

```c
// PRISMShared/SharedTypes.h
#define PRISM_SHM_NAME       "/horse.prism.audio.v1"
#define PRISM_RING_CAPACITY  32768        // frames, power of two
#define PRISM_CHANNELS       2
#define PRISM_SAMPLE_RATE    48000.0

typedef struct {
    _Atomic uint64_t writeIndex;          // monotonic, frames
    _Atomic uint64_t readIndex;           // monotonic, frames
    _Atomic uint64_t producerHeartbeat;   // mach_absolute_time of last write
    _Atomic uint32_t underrunCount;
    _Atomic uint32_t overrunCount;
    _Atomic uint32_t producerAlive;       // 1 = app running
    uint32_t         _pad;
    float            data[PRISM_RING_CAPACITY * PRISM_CHANNELS];
} PRISMRingBuffer;
```

Rules, all mandatory:

- Producer writes `data`, then `atomic_store_explicit(&writeIndex, …, memory_order_release)`.
- Consumer reads `writeIndex` with `memory_order_acquire` before touching `data`.
- **No locks, no allocation, no logging, no Objective-C messaging, no Swift ARC traffic inside either IO callback.**
- Underrun (consumer outruns producer): output silence, increment `underrunCount`, never block.
- Overrun (producer outruns consumer): advance `readIndex`, drop oldest, increment `overrunCount`, never block.
- `producerAlive == 0` or `producerHeartbeat` older than 500ms: the plug-in outputs silence. It must remain functional and must never take down `coreaudiod`.

Capacity of 32768 frames is ~683ms at 48kHz — roughly 4× the largest realistic client buffer, so a late client does not underrun.

### 4.4 Capture side

`AudioCapture` uses an HAL input `AudioUnit` (`kAudioUnitSubType_HALOutput`, input scope enabled, output scope disabled) bound to the selected physical device. Requested IO buffer size: **256 frames**. If the device rejects 256, accept the nearest supported value and surface the resulting latency in the UI.

Sample-rate conversion to 48kHz, when required, uses `AudioConverterRef` in the capture callback. Audio processing is pass-through plus mute, the input level meter and the cleanup chain (§5.17), the voice changer (§5.13) and the deliberate delay line (§5.12), in that order. Everything runs inside the capture callback under the §4.3 rules, and every stage is skipped when it is off, so a default install still costs one comparison apiece.

Cleanup is opt-in and defaults to off. Nothing in it looks ahead: the §6 budget allows 12ms of added audio and the HAL buffer plus ring traversal already spend ~10.7ms, which leaves no room to buy lookahead. That rules out a spectral denoiser, and is the reason the chain is entirely recursive filters and instantaneous gains.

---

## 5. Features

### 5.1 Pass-through

The default state, active ~95% of the time. It must be boring and bulletproof.

- Camera and microphone source pickers in the popover.
- Selections persist across launches in `UserDefaults`.
- If a selected source disappears, fall back to the system default device, post a `UNUserNotification`, and show a warning row in the popover. Never go black or silent.
- `DeviceMonitor` observes `AVCaptureDeviceWasDisconnectedNotification` and `kAudioHardwarePropertyDevices`.

### 5.2 Freeze frame

Holds a still image on the video output; clients see a frozen picture.

| Property | Specification |
|---|---|
| Trigger | Popover tile, plus global hotkey ⌥⌘F |
| Frame selected | **Not** the frame at click time. `FrameRing` retains as much of the recent past as §5.23 can afford — half a second where there is room, never less than 200ms; on freeze, select the sharpest frame within the preceding 300ms, scored by Laplacian variance computed on a 128×72 downsample. |
| Audio | Continues live. Mute is a separate control with a separate hotkey (⌥⌘M). |
| Combined | ⌥⌘⇧F freezes and mutes together. |
| Response time | Freeze and unfreeze take effect within one frame interval (33.3ms) of the trigger. |
| Indicator | Menu bar glyph changes state. Mandatory — accidentally remaining frozen is the most damaging failure this app can produce. |

Audio continuing by default is deliberate: people freeze because something visual happened, not because they stopped talking.

**A freeze with nothing to hold defers to the next frame, and the no-camera heartbeat counts as one.** With an empty ring — the camera has not delivered since launch, or a format change has just reallocated it — freeze holds the first frame that arrives instead of nothing. The heartbeat's neutral placeholder (§5.1) is such a frame: it is what is on air, so it is what gets held. Waiting for a *camera* frame there would leave `FreezeStage` out of the substituting set indefinitely, which means the §5.25 live layers are never held and a picture-in-picture keeps moving over the placeholder while every surface says the picture is frozen.

`FrameRing` holds `ResourceGovernor`'s granted depth in a preallocated `CVPixelBufferPool`, at the *source's* size rather than the output's — 15 frames at 720p30, and the six-slot floor at 1080p and at 4K. Sharpness scoring runs on the GPU as part of the normal command buffer, writing a single float per frame into a small `MTLBuffer` — never as a separate synchronous pass.

### 5.3 Clip playback

Substitutes a video file for the live feed.

- Decode with `AVAssetReader` and `AVAssetReaderTrackOutput`, output `kCVPixelFormatType_32BGRA`, `IOSurface`-backed.
- Formats: anything AVFoundation decodes — H.264, HEVC, ProRes in MP4/MOV.
- Clip audio routes to `PRISM Microphone`, replacing the live mic. Independently overridable: clip video with live audio is a valid combination and must be selectable.
- Controls: play, pause, loop, scrub. **Loop defaults to on.**
- Decode-ahead of 30 frames so the first frame after load is instant.
- Aspect mismatch: letterbox by default, fill as an option. Never stretch.
- Frame rate mismatch: retime to 30fps output by frame repetition or drop. The advertised camera format does not change.
- Clip end with loop off: return to live with a 200ms crossfade.
- Freeze while a clip is playing pauses the clip on its current frame.

### 5.4 Effects chain

All GPU, all Metal. Do not use `CIContext` on the hot path — its render scheduling is less predictable than a hand-written pipeline.

**Adjust** (`Adjust.metal`, `.cheap`) — one fragment shader, one pass: exposure (−2…+2 EV), contrast (0…2), saturation (0…2), temperature (−100…+100), vignette (0…1).

**LUT** (`LUT.metal`, `.moderate`) — load `.cube` files into a 3D `MTLTexture`, trilinear sample. Ship 5 defaults: `Neutral`, `Warm`, `Cool`, `Film`, `Mono`. User import via drag-and-drop onto the popover.

**Background blur** (`Blur.metal` + `Composite.metal`, `.expensive`) — `VNGeneratePersonSegmentationRequest` for the mask, separable Gaussian for the blur, single composite pass. Quality tiers map directly to `VNGeneratePersonSegmentationRequest.QualityLevel`: fast / balanced / accurate. Segmentation dominates the frame budget; on Intel, force `.fast` and cap at 720p input to the request.

**Geometry** (`Geometry.metal`, `.cheap`) — one pass, one affine transform plus sampling. This is the stage that does most of the work of "change my camera":

| Control | Range | Default |
|---|---|---|
| Zoom | 1.0…4.0× | 1.0 |
| Pan X / Y | −1…1 (fraction of the croppable margin) | 0, 0 |
| Rotation | −180°…+180°, continuous | 0° |
| Orientation | 0° / 90° / 180° / 270° | 0° |
| Mirror | horizontal, vertical, both, none | none |
| Crop aspect | free, 16:9, 4:3, 1:1, 9:16 | free |

Sampling is bilinear below 2× zoom and Lanczos at or above it. Zoom, pan, and rotation compose into a single 3×3 matrix and cost one pass regardless of how many are active.

**Mirror deserves an explicit note:** most video apps mirror your self-view but send an unmirrored image to everyone else. PRISM sits upstream of that, so a mirror applied here flips what *others* see. Label the control `Flip output` and add the caption `Others will see this flipped` so nobody discovers it mid-interview.

**Auto-framing** is a v1 control, not a separate stage: reuse the `VNGeneratePersonSegmentationRequest` mask already computed for blur to derive a subject bounding box, and drive Geometry's zoom and pan toward keeping it centered. Motion is critically damped with a 1.5s time constant — a camera that snaps is worse than one that doesn't move. Auto-framing requires the segmentation request, so enabling it without blur incurs blur's cost; state that in the UI. Disabled by default.

**Skin retouch** (`Retouch.metal`, `.expensive`) — an edge-preserving smooth over skin only, one knob, off by default. Specified in full at §5.22.

**Style** (`Style.metal`, `.moderate`) — preset visual effects over the finished, composed scene: pick an effect from a catalogue, one intensity slider, nothing else to configure. Two of them can stack (§5.29), and either can be driven by the microphone (§5.30); both are off by default, and everything below describes a single effect because that is still what "a style" means. Each effect is its own single-pass compute kernel, selected by name (`prism_style_<case>`), so the catalogue grows by adding a kernel and an enum case. The catalogue is curated toward what plays on a live call — warps, glitches and motion trails, plus a few gadget-camera looks — not color filters. 23 effects in three groups:

| Distortions | Motion | Looks |
|---|---|---|
| Bulge, Dent, Twirl, Squeeze, Fish Eye, Stretch, Mirror, Light Tunnel, Kaleidoscope, Wave (animated), Underwater (animated), Glitch (animated), Tiny Planet, RGB Split | Afterimage, Echo, Long Exposure, Strobe | Thermal Camera, X-Ray, Night Vision, VHS (animated), Pixelate |

`Normal` is the unstyled picture — the LUT/Neutral rule applied to a second catalogue: picking `Normal` is the same intent as switching the stage off, every surface treats the two states as one, and the stage declines to encode for it. The kernel contract is that intensity 0 reproduces the source exactly: color looks mix toward the styled picture, warps scale their displacement to zero, discrete remaps (Mirror, Kaleidoscope, Tiny Planet) crossfade, and motion effects scale their trails away.

**Motion effects are the one stateful family.** They feed on their own output: the stage keeps a history texture holding the previous styled frame and blits each frame's result into it inside the same command buffer (one extra blit — no second command buffer, §3.3). The first frame after any seed loss outputs the source untouched and seeds the feedback. Ghosts recorded before a gap never replay: the history (texture included) is dropped on effect change, stage disable, zero intensity, and size change, and — because flag-based invalidation cannot see every gap class (degradation disables, app naps) — trails additionally age out across any encoding gap longer than half a second, measured on the frame path. Undefined history contents must never reach the picture — `hasHistory` gates every read.

Style runs after Overlay and before Bad connection (§3.3): the effect applies to everything the user composed, and a simulated bad connection degrades the styled picture rather than being painted over by it. There is exactly one history texture, which is why exactly one motion effect may be in a stack (§5.29).

Each stage is individually bypassable and individually pinnable (§3.4). Chain order is fixed as specified in §3.3.

### 5.5 Presets

Customizability without presets is a settings panel nobody returns to. `PresetStore` persists named configurations capturing the full pipeline state: format selection, latency policy, all stage parameters, enabled/pinned flags, source device selections.

- Ship 4 built-ins: `Natural` (pass-through), `Meeting` (mild adjust + balanced blur + auto-frame), `Studio` (LUT + adjust, no blur, quality policy), `Low latency` (geometry only, lowest policy).
- Users create, rename, reorder, delete, duplicate. Built-ins can be duplicated but not edited.
- Presets bind to optional global hotkeys.
- Switching presets crossfades over 200ms and never causes a format renegotiation — if a preset specifies a format outside the currently published set, apply everything else and show the reconnect confirmation from §3.2 for the format alone.
- Export and import as JSON so configurations are shareable. This matters for an open-source project: shared presets are how a community forms around a tool like this.

**A preset also has to arrive intact in a build that is not this one.** Export makes the format a sharing format, so compatibility runs backwards too: the person opening it may be on the previous release. The stage on/off table is where that is easiest to get silently wrong — `flags` is keyed by a String *enum*, which `JSONEncoder` writes as a flat alternating key/value array, and decoding such an array is all-or-nothing: one stage name the reader has no case for throws for the whole dictionary, the tolerant decode above substitutes an empty one, and the preset arrives with *every* effect switched off and no error anywhere. Adding a single stage would do that to every preset the new build exports. So the table has two shapes, for the same reason `StyleSettings` does: `stageFlags`, a plain object keyed by the stage's raw name, walked one entry at a time so an unknown stage costs that one switch and nothing else, is what a build reads; and `flags` stays written in the old array shape, restricted to the stages an older build can name, so a shared preset still carries its LUT, its blur and its backdrop into that build. A stage added from here on travels in `stageFlags` only.

**Forward compatibility is a hard requirement, not a nicety.** Presets and the saved configuration are on-disk formats that outlive the build that wrote them. Swift's synthesised `Codable` throws on an absent key rather than falling back to a property default, so a naively-coded settings struct means every new field silently resets every existing user's entire setup on upgrade — configuration *and* every preset they had saved. Every persisted settings struct therefore decodes each field independently, at **every** nesting level. Top-level tolerance alone is not enough: version skew shows up as a partial nested object, and a tolerant parent decoding a throwing child discards the child wholesale.

### 5.6 Eye-contact correction

Redirects the subject's gaze toward the lens so they can read notes off-camera while appearing to look at whoever they are talking to.

| Property | Specification |
|---|---|
| Stage | `.gaze`, `.expensive`, before Geometry |
| Trigger | Scene section toggle, plus global hotkey ⌥⌘E |
| Detection | The shared `FaceTracker` (§3.3): `VNDetectFaceLandmarksRequest`, `.constellation76Points` (pupils only exist in the 76-point constellation), on a serial queue every 2nd frame, request input capped at 720p |
| Measurement | Drift of the pupil from the centre of its own eye opening |
| Correction | A `strength` fraction of that drift, removed |
| Clamp | `maxShift` iris radii, default 0.5 |

**The correction needs no knowledge of where the camera is mounted.** When someone looks into the lens, the pupil sits near the centre of the palpebral fissure; when they look at the screen instead, it sits off centre — down for the usual camera-above-display laptop, sideways for a monitor beside the webcam. Measuring how far the pupil has drifted from the centre of its own eye and pulling part of that back therefore self-calibrates. A setup where centred is not the truth (an oddly mounted external camera) is handled by `verticalBias` on top.

**What this is.** The redirection itself is a geometric warp (`Gaze.metal`) driven by an on-device ML landmark model. It is *not* a learned image-to-image gaze synthesiser — it moves the iris you have rather than generating the one you would have had. That is the honest trade at this latency budget. `maxShift` clamps rather than extrapolates because past roughly half an iris width the sclera stretch becomes visible, and a subtly-wrong eye is far better than an uncanny one. **Do not describe this feature to users in terms that imply synthesis.**

The warp per eye is the product of two falloffs: rigid across the iris disc (so the pupil and limbal ring keep their shape instead of smearing into an oval), and pinned at the eye-opening boundary (so eyelids, lashes and skin do not move). The sclera between them takes up the difference by stretching.

Detection flickers, and a correction that pops on and off is more distracting than none, so tracking confidence ramps over ~0.25 s in both directions and scales the shift. Landmark smoothing defaults high: Vision's per-frame jitter is small but visible on something as fine as an iris.

### 5.7 Virtual backgrounds

Full background replacement — a still, a looping video, or a flat colour — using the same person mask as background blur (§3.3).

| Property | Specification |
|---|---|
| Stage | `.background`, `.expensive`, after blur |
| Modes | colour, image, video |
| Fit | fill by default (a letterboxed backdrop reads as a bug); letterbox available. Never stretch. |
| Edge controls | mask contrast, edge softness, light wrap |

**Light wrap** bleeds the new background into the subject's rim. It is the cheapest thing that stops a composite reading as a sticker: real subjects pick up the colour of what is behind them.

**Every degraded path errs toward covering the background, never toward revealing it.** This stage exists partly for privacy — someone turns it on because they do not want the room behind them on camera. Therefore:

- No mask yet → composite against an all-zero mask, showing the backdrop across the whole frame for the frame or two segmentation takes to warm up.
- Asset missing, still opening, or failed to load → the flat colour.
- The stage will **not** pass the camera through under any circumstance.

Blur and replacement are mutually exclusive and share one UI control (§8.7).

### 5.8 Green-screen compositing

Up to **five** placed, keyed layers over the finished frame — the stage that turns PRISM from a camera filter into a stage.

| Property | Specification |
|---|---|
| Stage | `.overlay`, `.moderate`, after virtual background |
| Sources | image (alpha honoured), looping video, text, or a live feed |
| Keying | none, chroma, or luma |
| Placement | in front of everything, or behind the subject (mask-gated) |
| Anchor | the frame, or a face landmark (`LayerAnchor`, `FaceAnchorPoint`) |
| Transform | scale, offset, rotation, mirror, opacity |
| Layer cap | 5 total (`OverlaySettings.maxLayers`), of which 3 video (`maxVideoLayers`) |

Keying is computed in YCbCr so the key colour is arbitrary rather than hard-coded green, and despill works for any hue. Despill removes what is left of the key hue from surviving pixels, so a green screen stops tinting hair and shoulders.

The layer cap is a memory constraint, not a GPU one: each layer is one compute pass, but each *video* layer carries its own decoder and frame FIFO, and resident memory is the binding limit (§7). That is why the two caps differ — a text or live layer has no decoder to pay for. Layers are admitted in the user's own order until either cap is reached. At scale 1 a layer is fitted into the frame with its own aspect preserved — a square PNG stays square.

Layers composite bottom-up in array order. Dropping an image or video onto the Scene pane adds it as a layer, the same affordance as dropping a `.cube` to import a LUT.

A `.live` layer is the second running capture rather than a file — §5.25 is what it is for, and why it holds when the picture does. A `.text` layer is a string rasterised by Core Text rather than a file — §5.26 is what it is for, why it is placed by pixel instead of fitted, and why it costs no decoder.

**Face-anchored layers.** A layer pinned to `.face` rides the head instead of the frame: a hat above it, glasses on the eye line, a moustache under the nose, or a mask over the whole of it. It is driven by the shared `FaceTracker` (§3.3), which the overlay stage demands **only when a layer is actually face-anchored** — a frame-anchored lower third costs no Vision, however many of them there are, and removing the last face-anchored layer drops the demand again.

| Property | Specification |
|---|---|
| Anchor points | above the head, eyes, under the nose, mouth, chin, whole face (`FaceAnchorPoint`) |
| Size | measured against the tracked face, not the frame: at size 1 the layer is exactly as wide as the face box |
| Offset | in face widths, and carried around with the layer so a nudge stays put as the head turns |
| Rotation | the head's roll, added to the layer's own — opt-in per layer (`followsRoll`) |
| Tracking loss | fade out over ~0.25 s, holding the last pose; fade back in on reacquisition |

Size follows the face so a prop keeps its proportion as someone leans toward the camera and back out, and so the same number means the same thing at 720p and 1080p. The eye anchor uses the *measured* eye midpoint when both eyes are landmarked and falls back to a fraction of the face box otherwise — a profile turn still reports a box after the landmark constellation has given up. The anchor point always swings with the head's tilt, whether or not the layer itself rotates: a moustache belongs under the nose wherever the nose has gone. Roll following is off by default because roll is the noisiest quantity the tracker reports, and a prop that jitters in rotation is more distracting than one that stays level.

**Losing the face fades the layer out rather than freezing or cutting it.** Freezing at the last pose leaves a moustache hanging in mid-air where a head used to be, and cutting instantly makes the prop flash on and off with every detection flicker — both are worse on camera than a quarter-second fade. The tracker's confidence ramp already runs ~0.25 s in each direction and already holds the last pose through a dropout, so the layer shrinks out of sight from where it was standing and returns to where the head is now. At zero confidence the pass is skipped outright, so a stale pose can never reach the picture.

**The face is measured before Geometry and the layers land after it**, so the placement is built in the tracker's own pre-Geometry space and then composed with the frame's geometry matrix (`GeometryStage.appliedUVTransform`). Nothing is decomposed: zoom, pan, free rotation, mirror, a non-square crop and continuous auto-framing all arrive intact, and the prop is glued to the face in camera space. Without this a hat would sit where the head was before the zoom moved it — and auto-framing moves it continuously.

### 5.9 Instant replay

A rolling buffer of the last N seconds, so "say that again" is a keystroke rather than an awkward redo.

| Property | Specification |
|---|---|
| Trigger | Moments tile, plus global hotkey ⌥⌘R |
| Buffer | 4–30 s, default 10 s, **off by default** |
| Recording | Hardware H.264 via `VTCompressionSession`, height capped (540p/720p/1080p, default 1080p), no frame reordering, 1 s keyframe interval |
| Playback | 0.25–4×, default 1.5×; scrubbable; returns to live at the end by default |

**The buffer stores encoded frames, not raw ones.** Ten seconds of raw 1080p30 is ~2.5 GB — an order of magnitude past the entire app's memory budget (§7). Encoded, it is ~10 MB, the encode happens on the media engine rather than the GPU or CPU, and the only real cost on the frame path is one downscale pass. This is why the buffer cannot simply be a bigger `FrameRing`.

**It buffers camera frames, upstream of every effect.** A replay therefore runs through the live effects chain like any other source. Recording the finished output instead would double-apply every effect, and a replay that does not match the current look reads as a glitch rather than a rewind. Change your look mid-replay and the replay changes with it.

Playback above 1× catches back up to live, which is the point: the user is showing someone the thing they missed, not screening a rerun. The buffer records only while something is actually consuming frames (§5.1 demand gating), and is off by default — an armed buffer runs a hardware encoder on every frame, and a resident agent must cost nothing for a feature nobody has switched on.

Alongside the compressed ring, a 32×18 luma thumbnail is kept per frame. §5.10 explains why.

**There is one transport, and claiming it is one act.** `ReplayPlayer` plays a replay, the away loop and the lag switch's delay (§5.12, and the bad connection's delay half in §5.14) from the same ring: `begin()` re-bases it, so whatever it was playing is destroyed the instant somebody else starts it. Every claim therefore goes through one path (`AppState.claimReplayTransport`), and the flags each surface reads — away, lagging, catching up, connection-engaged — are *derived* from the claimant rather than set by hand. A claim that left another claimant's flag standing would leave the menu bar saying "Away" over delayed live camera, with nobody in front of the camera to notice; deriving them makes that unstateable rather than merely fixed at each call site. The outgoing claimant's own undo travels with it: the away loop's mute comes off, presence drops its claim on the loop, and the audio delay line goes back to zero. A start the player refuses changes nothing — whatever was playing is still playing, and the app has to keep saying so.

**Claiming the transport does not mean an instant picture.** `begin()` clears the player's frames and hands decoding to its own queue, which has to create a decompression session and decode forward from the newest keyframe at or before the target — up to a full GOP, one second by construction. For those frames the player has nothing to hand over, and substituting nothing would put the live camera on air (and leave the §5.25 live layers moving) at the exact moment the user has been told they are away and has stood up to leave. So claiming the transport also arms `ReplayStage` with a **bridge frame**: the sharpest frame of the preceding 300 ms out of the freeze ring — the same pick §5.2 makes — held until the first decoded frame lands, and released by it. It costs one texture (~8 MB at 1080p), paid only while a transport is spinning up, and a bridge never outlives its transport.

### 5.10 Away loop

An auto-generated "still here" idle loop instead of a static freeze when the user steps away.

| Property | Specification |
|---|---|
| Trigger | Moments tile, plus global hotkey ⌥⌘A |
| Source | The §5.9 rolling buffer (one recorder serves both) |
| Loop length | 2–10 s, default 4 s |
| Seam crossfade | 0–1500 ms, default 400 ms |
| Audio | Mutes by default — stepping away means stepping away |

**Cut-point selection is the whole feature.** Two things make an auto-generated idle loop convincing, and they pull in different directions: the cut has to be invisible, which wants the first and last frames to match; and the loop has to look alive rather than like a stuck stream, which wants *some* motion. The score is therefore the seam difference (weighted 3×, because a visible jump cut is what gives these away) plus the segment's mean frame-to-frame motion, minimised over all candidate segments.

This is what the per-frame thumbnails exist for. The §5.2 sharpness score yields one scalar per frame, which can rank frames but cannot answer "do these two frames match closely enough to loop between them?" Thumbnails can, at 576 floats per frame.

**The most recent second is excluded outright.** The away loop is triggered as someone gets up, so the newest frames are exactly the ones with a hand reaching off-screen in them.

At the wrap point the loop crossfades its tail into its own held first frame and restarts on that frame. Holding one frame costs one texture (~8 MB); crossfading two arbitrary points of a compressed stream would mean two decompression sessions and two frame FIFOs, for an identical result.

A frozen frame tells everyone you left. A loop that breathes does not — worth being deliberate about, and the reason the menu bar glyph has a dedicated away state (§8.2).

### 5.11 Panic

One chord: freeze, mute, and swap to a "back in a bit" backdrop. Built entirely from primitives PRISM already has.

| Property | Specification |
|---|---|
| Trigger | Moments tile, plus global hotkey ⌥⌘P |
| Components | freeze / mute / backdrop swap, each individually switchable |
| Backdrop | user image or video, falling back to a flat colour |

Deliberately un-shifted: a panic key you have to reach for is not one.

Pressing it again restores **exactly** the prior state, including a freeze or mute the user had engaged themselves beforehand — panic tracks what it changed rather than blanket-reverting. Both halves follow the rule presence automation follows (§5.28): `PanicHold` records what the chord actually engaged, and the release undoes only that, only while it is still true. Deciding the release from the settings instead — "panic freezes, so releasing thaws" — would thaw the picture a user froze to step out of shot and put them back on air without asking.

The backdrop swap mutates the live configuration so every surface shows what is actually on air, but the pre-panic configuration snapshot is what gets persisted and what a preset save captures. Relaunching after a panic must leave the user where they were, not stuck behind a "back in a bit" card with no memory of why.

### 5.12 Lag switch

Deliberate added latency — the exact inverse of everything else in this document.

| Property | Specification |
|---|---|
| Trigger | Moments tile, plus global hotkey ⌥⌘L (held by default) |
| Delay | 200 ms – 10 s, default 3 s, bounded by the rolling buffer |
| Video | Trails live via the §5.9 rolling buffer |
| Audio | Circular PCM delay line in the capture path, on by default |
| Release | Snap back (default) or catch up |

**Engaging holds, it does not rewind.** Jumping the output back three seconds would replay the last three seconds — viewers would watch the user say the same thing twice. Instead the output holds the frame it was on for the full delay, and only then resumes at 1×, permanently that far behind. That is what a transport hiccup does and it is what "add latency" means. Audio behaves identically: the delay line emits silence until it has filled.

**The delay is set in exact milliseconds.** The delay row's numeric field is the primary control, not a readout: type `1500`, `1500 ms` or `1500ms` and press Return. Dragging steps in 50 ms so an ordinary gesture lands on round numbers, ⌥-drag is continuous, and double-click resets to 3000 ms. The field is sized to the widest value its range can produce and shows figures ungrouped (`3000 ms`, not `3,000 ms`), because a field you type precise values into must be able to display them. The slider's upper bound is the *lesser* of the rolling buffer's capacity and the 10 s settings clamp, so the control can never offer a figure that would be silently reduced in use.

**The delay is adjustable while engaged.** Changing it mid-lag retargets live (`ReplayPlayer.adjustLag`): deepening rebases onto the frame currently on air and holds it until the extra delay is absorbed — the same stall as engaging, never a rewind — and shortening jumps forward, dropping exactly the difference in backlog: a partial snap-back. Changes under 10 ms are ignored as float noise — deliberately below one slider step and far below anything typed, so every figure the user states is actually applied. A catch-up in flight owns the clock (the control waits), and the mic's delay line follows in one step, since audio has no honest gradual path. When the bad connection (§5.14) owns the delay, its own delay field is the one that retargets live.

**The two paths are delayed by completely different mechanisms, because their costs are nothing alike.** Ten seconds of 48 kHz stereo float is under 4 MB, so the microphone gets a plain preallocated circular buffer on the RT path. Ten seconds of 1080p is gigabytes, so video is delayed by trailing the compressed rolling buffer instead. This is also why the delay cannot exceed the buffer length, and why delayed video passes through the buffer's encoder.

**Release.** *Snap back* cuts to live and never sends the backlog — what a recovering connection does. *Catch up* plays the backlog out at 1.25–4× until it reaches live, so nothing said while lagging is lost. Audio always snaps back regardless: speeding up an audio delay line means resampling or dropping samples, and both sound worse than the skew. Say so in the UI rather than pretending otherwise.

**Hold, don't toggle.** The hotkey is momentary by default — a switch you hold is what the name describes, and it cannot be left on by accident. It is the only combo whose key *release* is observed. Releases are matched on the keycode alone: nobody releases ⌥, ⌘ and L in a defined order, and requiring the full combo on the way up would routinely miss the release and strand the switch on. As a second failsafe, a press while already lagging releases.

**Reporting (§6).** The delay is reported in `LatencyReport.deliberateDelayMs`, **separate from** `totalAddedMs`. The latency meter's entire job is showing what PRISM costs you against a budget; folding three seconds of requested delay into it would peg it permanently and destroy the one number this app exists to keep honest. So the meter keeps measuring the involuntary cost, the status line gains `· +3.0 s lag`, and `endToEndMs` is the field that combines them. Never hide a deliberate delay.

### 5.13 Voice changer

Goofy, deliberate voice effects on the microphone path — the audio sibling of the LUT rack.

| Property | Specification |
|---|---|
| Trigger | Voice module picker, plus global hotkey ⌃⌥⌘V (toggles the last used effect; ⌥⌘V is Finder's "Move Item Here" and ⌥⇧⌘V is the system Paste and Match Style, so the voice chord takes ⌃) |
| Effects | Chipmunk, Helium, Deep, Giant, Alien, Robot, Autotune, Telephone, Cave, Underwater |
| Strength | 0.25…1, default 1 — scales pitch offsets geometrically and mixes linearly |
| Scope | Live microphone only; clip audio (§5.3) is never processed |
| Cost | Well under the §6 processing budget per IO slice; pitched effects add ~21 ms of audio latency, reported via `addedLatencyMs` |
| Mic check | Record ≤ 5 s of the processed microphone, play it back through the default output — a passive tap; the on-air path is untouched |

Everything runs inside the existing RT capture callback (§4.4), between format conversion and the ring write — so the deliberate delay line (§5.12) and the ring both carry the processed voice — and under the same rules: no allocation, no locks (a trylock parameter mailbox that falls back to the previous program), no logging. The chain is time-domain DSP — a dual-grain delay-line pitch shifter, ring modulation, biquad filters, soft-clip drive, tremolo, and a damped feedback echo — and every stage is skipped when its parameters are identity, so `.off` costs one comparison. Stereo microphones are mixed to mono first: a voice is mono, and every effect here deliberately is.

**Autotune is honest pitch quantisation, not synthesis.** An autocorrelation detector (on a ×4-decimated 12 kHz window, ~10 ms hop, with an octave-error guard and parabolic lag refinement) finds the voice's fundamental, snaps it to the nearest semitone — or drags it toward one fixed note, which is what Robot is — and drives the pitch shifter's ratio with a fast glide. The hard snap is the sound people mean by "autotune", so the glide is fast by default. Unvoiced stretches glide back to the base ratio rather than holding the last correction into the next phrase.

**The pitch shifter buys its shift with latency.** The grain window is 2048 frames; the two crossfaded read taps average half a window behind the write head, so a pitched effect adds ~21 ms to the audio path. That exceeds the §6 involuntary budget — which is fine, because it is not involuntary: it is folded into `addedLatencyMs`, shows in the meter's audio figure and the A/V skew readout, and disappears the moment the effect is off. Never hide it.

**The user cannot hear themselves.** PRISM publishes a microphone; it does not monitor one. The main window's Voice pane therefore carries the §8.4 honesty line — everyone else hears the effect, you hear yourself unchanged — the popover's collapsed Voice label names the effect on air, and the menu bar treats an active voice as an active effect (filled prism): forgetting your voice is an alien is the same class of failure as forgetting a freeze.

**The mic check is how you hear yourself anyway.** The honesty line can say what is on air, but only a playback can let you *hear* it — so the Voice surfaces carry a record-then-play-back check, the exact shape of Zoom's mic test: press it, say something (up to 5 s, live level meter), and PRISM plays the take back through the default output. The recording is tapped **after** the voice changer, so the playback is sample-for-sample what the ring — and the call — receives; with the effect off it is a plain mic test. The tap is passive and armed only while recording: the on-air path is never rerouted, never interrupted, and the mic stays live throughout, which the pane says plainly (playing back through speakers near a hot mic is the user's call to make). A take that contains only silence is not played — it is diagnosed: `PRISM didn't hear anything. Check the microphone picker.` The check refuses to record while muted or while clip audio owns the ring, stating why, because recording guaranteed silence and then reporting it would be a lie about the microphone.

**Mute is an acoustic boundary in both directions.** While muted (or while clip audio owns the ring, §5.3) neither the voice chain nor the §5.12 delay line runs, so their buffers would otherwise freeze holding pre-mute audio — and an unmute would open by replaying it. The RT path therefore clears the chain's state on resume from any interruption, and whenever an effect switches from off to on. A mute never leaks sound into the gap, and never replays sound out of it.

This is a house rule about echo tails and a privacy guarantee about the lag switch, and the second one is the sharper of the two. With §5.12 engaged the delay line is holding **seconds of speech that has not gone out yet**, so a user who mutes mid-sentence to say something private in the room and unmutes afterwards would have exactly those seconds read out of the line and put on the call. The line is emptied on the same interruption as everything else — and again whenever the requested depth is zero, so releasing the switch cannot leave a session's audio sitting in the buffer for the next engage to open with. Coming back from off air always starts from the stall (silence until the line refills), never from the middle of what was said before it.

Voice settings persist in `StudioSettings`, not in presets: a preset captures a look, and switching from Meeting to Studio must not silently change what you sound like. The ⌃⌥⌘V toggle remembers the last effect used, so a quick unmask does not lose it.

### 5.14 Bad connection

One switch that makes the published feed look like a struggling network: the picture goes blocky and colour-starved, the frame rate collapses, and — by default — the whole feed falls behind live.

| Property | Specification |
|---|---|
| Trigger | Moments tile ("Glitch"), plus global hotkey ⌥⌘B (toggle — the stunt runs for minutes, nobody holds a chord through a meeting) |
| Severity | One knob, 0.1–1, default 0.6, driving block size (4–48 px at 1080p, quadratic), colour steps (34–12 per channel), mean refresh rate (18–6 fps) and per-refresh block-update fraction (0.9–0.4) together |
| Picture | `ConnectionStage`, one `prism_connection` pass: macroblock pixelation, posterisation, per-block shimmer, and partial refresh against the previous degraded frame; held-frame throttle on a jittered cadence with stalls; effective severity wanders ±30% |
| Delay | Optional (on by default), 200 ms–10 s, default 1.2 s, riding the §5.12 transport; microphone delayed to match |
| Release | Instant clean picture; a delay this switch engaged snaps back to live |

**One knob, because "my connection is struggling" is one story.** A real network never pixelates without dropping frames, or drops frames without falling behind; independent sliders would let you dial in a failure mode no network produces, and a stunt you configure mid-call has to be one gesture. Severity maps to all three degradations in one place (`ConnectionSettings`), the settings pane shows what the mapping buys ("19 px blocks · 16 colour steps · 11 fps"), and the severity floor exists because a severity of zero would be an on-switch that changes nothing (§8.7).

**The stage degrades the finished frame, not the camera.** It is the last user stage in the chain (§3.3): backdrop, overlays and effects pixelate together, exactly as an encoder starved of bits would treat them. Underneath, PRISM keeps running the full chain at full rate — the degradation is one cheap pass plus a held texture — so releasing the switch restores a clean picture instantly and costs nothing.

**Uniformity is the tell, so nothing here is uniform.** A whole-frame mosaic at a metronomic frame rate reads as a deliberate filter; three mechanisms break that:

- *Irregular cadence.* The frame gate draws each refresh interval from a jittered distribution around the mean rate — usually a little under it, roughly one draw in ten a stall of 3–7 intervals, the shape of a packet-loss burst. Deterministic per seed, so a cadence can be replayed in tests.
- *Partial refresh.* Each pass, a per-block lottery updates only `updateFraction` of the blocks; the rest copy last frame's degraded pixels. A moving subject therefore leaves stale blocks behind — the packet-loss smear that is the single most recognisable artifact of real degraded video.
- *Quality breathing.* The effective severity wanders ±30% around the knob (random-target smoothing, stepped per refresh), the way adaptive bitrate collapses and part-recovers. The knob stays the honest centre of the wander, and every derived value stays inside its documented bounds.

The per-block shimmer is reseeded on every refresh so held frames "boil" between refreshes rather than freezing their noise, and the shimmer is applied before posterisation so blocks flicker between adjacent colour bands — codec artifact, not film grain.

**The delay is the §5.12 lag switch's transport, not a second mechanism.** Same rolling-buffer bound, same hold-then-trail engage, same audio delay line — with the connection's own, shorter default (1.2 s: a struggling connection is behind, not absent). The microphone is always delayed to match, for the §5.12 reason: picture behind live audio reads as broken software. Releasing a delay this switch engaged itself always snaps back — a recovering connection drops its backlog — while a delay the user engaged separately with the lag switch is left alone (`connectionEngagedLag`). If the rolling buffer is off, the visual half still engages and a warning offers to arm the buffer, because a switch that does nothing is worse than a switch that does half and says so.

**The delay half never takes the transport from something already substituting.** It is the optional half of this switch, and a replay, an away loop or a delay the user engaged themselves is a picture they deliberately put on air. Claiming §5.9's single transport from an away loop would destroy the loop and put the *live* camera, a second behind, in front of the meeting — with the user out of the room. So when the transport is already claimed the stunt degrades whatever is on air (which is the point of it) and adds no delay, and it says so when the loop is what it stepped around.

**Reporting.** Engaged, the menu bar shows the wifi badge (§8.2, outranking the hourglass — the badge names the stunt the user engaged, and the delay is part of it), the Moments caption states the degradation in the settings' own terms ("19 px blocks · ≈11 fps · 1.2 s behind live" — ≈ because the rate is a mean of an irregular cadence), and any delay reports through `LatencyReport.deliberateDelayMs` exactly as §5.12 — never folded into the involuntary meter.

Connection settings persist in `StudioSettings`, not in presets: switching from Meeting to Studio must not silently fake a network problem. Engagement itself is never persisted — PRISM always launches with a clean feed.

### 5.15 Save the last seconds

The rolling buffer, written to a file.

| Property | Specification |
|---|---|
| Trigger | Capture tile, plus global hotkey ⌥⌘S |
| Source | The §5.9 rolling buffer — requires it to be armed |
| Container | QuickTime `.mov`, `AVAssetWriter` with `outputSettings: nil` |
| Contents | Video only. The raw camera, upstream of every effect. No audio |
| Naming | `PRISM Clip <date> at <time>.mov` in the §5.16 folder |

**Nothing is re-encoded.** The samples in the ring are already hardware-encoded H.264 with a valid format description and no frame reordering (§5.9), so the save is a remux: passthrough input, no media engine work, no GPU work at all. Saving the last ten seconds must not be the thing that makes the next ten seconds stutter.

**Durations are synthesised, and that is the whole trick.** The ring's samples carry `.invalid` durations — VideoToolbox is handed `.invalid` on the way in and hands it straight back — and `AVAssetWriter` cannot build a sample table without them. `ClipPlanner` trims to the first keyframe (a clip that starts mid-GOP references pictures the file does not contain), rebases presentation times to zero (host-clock timestamps produce a file that is legal and unplayable in half the tools that open it), and derives each sample's duration from the next sample's presentation delta, the last inheriting the gap before it. Durations are floored at 1/240 s and capped at 1 s: a duplicate timestamp cannot be written, and a single sample held across an eleven-second camera stall reads as a hung file rather than as a gap.

Any failure cancels the writer and deletes the partial file. A truncated `.mov` in the user's folder is worse than no file, because it looks like the save worked.

**The confirmation is the feature.** The buffer records the camera *upstream of every effect* — that is what lets a replay run through the current look (§5.9), and it is what makes a saved clip a recording of everything the effects were covering. Saving while background blur, a virtual background, a behind-the-subject layer, or the panic backdrop is on air writes a video of the room the user was hiding.

So:

- Every surface states, always, that a saved clip is the raw camera with no effects and no sound. Not only when PRISM has decided there is a risk — a caption that appears only at the moment of danger teaches nobody what the feature does.
- When something concealing *is* on air, the write does not happen until a modal alert has been read and accepted. This is the only deliberately modal confirmation in PRISM: everything else the app does is undoable or visible on air, and this one is reached by a global chord that works with every PRISM window closed, so there is no surface a passive warning could appear on. Cancel is the default button — a return key pressed out of habit must not disclose anything.
- The confirmation fires for concealment only (`ClipDisclosure`). Cropping, rotation and colour also make a saved clip differ from the call, and the standing caption covers them; a modal that fires on a zoom is a modal nobody reads by the time it matters.

### 5.16 Stills

One frame, saved as a picture.

| Property | Specification |
|---|---|
| Trigger | Capture tile, plus global hotkey ⌥⌘⇧S |
| Source | The **finished** output — post-effects, exactly what the call sees |
| Format | PNG (default) or HEIC |
| Countdown | 0–10 s, default 0 |
| Sharpest frame | Off by default |
| Folder | User-chosen, persisted in `CaptureSettings`; default `~/Movies/PRISM` |
| Naming | `PRISM <date> at <time>.png`, the system's screenshot convention |

**A still is the opposite of a saved clip, deliberately.** A photo pulled off a call should look like the person on the call — retouched, framed, in front of whatever background they chose. A clip you keep should not quietly turn out to be a recording you did not know you were making. The two features read from opposite ends of the pipeline for those two reasons, and both surfaces say which is which.

**The sharpest recent frame, optionally.** PRISM already scores every frame it produces for Laplacian variance — it is how a freeze avoids landing mid-blink (§5.2) — so a still can be the best frame of the recent moment rather than whichever one arrived when the key went down. `StillRing` holds six *finished* frames and their scores; it takes references to the pipeline's own pool buffers rather than copying, so the only per-frame cost is one threadgroup of `prism_sharpness` inside the frame's existing command buffer.

It is off by default for two reasons. Six full output frames is ~50 MB at 1080p against a 250 MB budget (§7), and it must not be spent on a feature nobody switched on — disarmed, the ring holds nothing. And the honest still is the one the user was looking at, which is what PRISM saves when the setting is off: the last frame that reached the sink.

Encoding is `CGImageDestination`, never Core Image. The pixels are copied out of the pool buffer first, row by row against the buffer's real stride — the pipeline reuses that buffer the moment nothing references it, and a lazy encoder would be racing the next frame.

Stills and clips share one folder: two would mean two places to look for the thing you just saved, and the names already say which is which. The folder is created and proved writable *before* anything is encoded — a capture that fails after the work is done has already cost the moment it was trying to keep — and a second capture inside the same second is disambiguated the way the system disambiguates a second screenshot.

Capture settings persist in `StudioSettings`, not in presets: a preset captures a look, and switching from Meeting to Studio must never repoint someone's folder.

### 5.17 Input level, muted-and-talking, and cleanup

Three answers to one complaint: PRISM owns your microphone and until now told you nothing about it.

| Property | Specification |
|---|---|
| Input meter | Continuous RMS from the RT capture callback via a lock-free scalar mailbox, sampled by the UI at 10Hz. Shown in the popover's Voice section and the main window's Voice pane, with the mic check's scaling and decay |
| Demand | Armed only while a preview surface is open **or** the microphone is off air. Idle, unmuted, no window: nothing is measured, nothing is published, no timer runs |
| Muted-and-talking | Sustained speech (above `micWatch.thresholdDB`, default −34dBFS, for `sustainSeconds`, default 1.2s accumulated, gaps under 0.5s not counted) while the mic is off air. Drives `AppState.mutedTalking`, the menu bar's `mutedTalking` state, and — opt-in, `micWatch.isEnabled` — a notice row |
| Cleanup | One picker: Off / Clean up / Studio, plus a Strength slider (0.2–1, default 0.7). Default Off, and Off is bit-exact pass-through |
| Chain | High-pass 80Hz → two-band noise expander (complementary split at 1.2kHz) → feed-forward compressor → light corrective EQ (Studio only) |
| Cost | Zero added latency in every mode; ~50 flops per sample, far inside the §6 ≤ 1.0ms processing budget |

**The meter is read ahead of everything.** It is taken from the raw device slice, before mute, before suppression, before cleanup and before the voice changer, because the question it answers — *is my microphone hearing me* — has to keep being answerable while muted. That is also the entire basis of the muted-and-talking watch, and it is what somebody troubleshooting a dead-sounding microphone actually wants to see. The bar therefore keeps moving while muted, in a different colour, captioned so the distinction is not a guess.

**The mailbox is a mailbox, not a ring.** A meter only ever wants the newest value; a ring would hand the reader a backlog it would immediately discard. One release-store per 1024-frame window, one acquire-load per UI tick, through the same C atomic shims `MicTapRing` uses (§4.3). The window counter shares the atomic word with the value, so a reader seeing an unchanged counter knows no audio arrived — capture stopped, device gone, meter disarmed — and decays rather than holding a stale reading forever.

**The muted-and-talking watch exists to be quiet.** The design problem is nagging, not detection. So: a cough never fires it (150ms against a 1.2s sustain, where a gap over 0.5s resets the accumulator); it fires **once per mute**, and will not fire again until the microphone goes back on air, which is the user acting on it; and a holdoff — `micWatch.reminderIntervalSeconds`, default 20s — floors the interval between alerts so mashing the mute key cannot turn "once per mute" into a stutter. The signal clears when the talking stops, so the menu bar stops pointing at a problem that has gone away.

**It does not use the warning slot.** There is exactly one `warning`, and posting through it would evict whatever was there — including a device-disconnect message, which is a fact, in favour of a hint. `AppState.notice` is a second, independent slot with its own row (§8.3), and the two can show at once. The banner ships **off**: an interruption is a strong claim to make about somebody's meeting and PRISM has no idea whether the mute was a mistake. The ambient menu-bar signal is not opt-in, because it costs nothing and changes no behaviour.

**The notice slot is shared, and the hint always yields.** §5.15 and §5.16 post events to it ("Saved …", cleared on a 12s timer); this posts a condition, cleared when the mute ends rather than on a clock. A condition is only ever posted into an empty slot and never re-asserted over an event, so confirming a file the user just asked for outranks reminding them of a mute they can also see in the menu bar. A notice carrying an action drops the confirmation green for orange — still not the red §8.2 reserves for *wrong*.

**Cleanup runs before the voice changer, and the order is load-bearing.** It exists to hand the effects a clean signal: the autotune detector and the grain shifter both degrade on a noisy input. Expanding a deliberately ring-modulated or echoed signal afterwards would chew the effect's own tail. The two are otherwise independent — you can clean up a chipmunk — and cleanup never reaches the menu bar's effect glyph, because it is a repair, not a costume.

**The denoiser tracks a minimum, not an average.** Each band's noise floor is the minimum its envelope reached over the last 750ms window, eased toward rather than snapped to. Minimum-tracking is what lets a floor sit under a voice without being dragged up by one — speech dips between syllables and steady noise does not — and, unlike a tracker gated on being *near* the floor already, it converges from below, so a floor that starts underneath the real one can still find it. A ceiling at −34dBFS caps the damage a sustained loud input can do: nothing above that is a noise floor, and without the cap a test tone would train the expander into gating the voice it exists to protect.

**Mode is what, Strength is how much** — the same split the voice changer already ships (§5.13), and the reason each control still answers one question (§8.7). Strength scales the *depth* of the noise removal in dB, so half of "20dB down" is 10dB down, which is what a listener would call half. It deliberately does not touch the compressor or the EQ: folding those in would make the slider mean something different in each mode.

**Studio is not "Clean up, more".** It expands harder *and* adds the EQ — a 350Hz boxiness cut and a 4.5kHz presence shelf — which is exactly the point where tidying a microphone turns into changing what somebody sounds like. Keeping that behind its own name is the honest split, and it is why Clean up carries no EQ beyond the high-pass.

Cleanup and watch settings persist in `StudioSettings`, not in presets: switching from Meeting to Studio must not quietly start gating your room, for the same reason it must not change what you sound like.
### 5.18 Per-app rules

PRISM already knows which apps are watching — the extension reports their signing IDs over `'clnt'`. Two things follow from knowing that, and this section is both of them: give each app the look it should have, and decide which apps may have the camera at all.

**Ships off.** `AppRulesSettings.isEnabled` is `false` and `defaultAccess` is `.allow` out of the box. This is the only feature in PRISM that can leave an app without a camera while PRISM is not running, and nothing here does anything until the user deliberately turns it on.

#### Per-app presets

An ordered list of rules, each naming one app by signing ID and optionally a preset. When a rule's app starts streaming, its preset goes on air over the existing 200 ms crossfade (§5.5); when the app stops, PRISM crossfades back to whatever the user had before any rule fired.

| Property | Specification |
|---|---|
| Matching | Whole signing ID, case-folded. Never a prefix — that would let `us.zoom.xos.evil` inherit a rule written for Zoom — but case is folded on both sides, because signing identifiers are case-insensitive in practice and the editor lets people type them by hand |
| Conflict | **List order.** The earliest rule whose app is streaming wins |
| Apply | `applyPreset(_:mayRepublishFormats:)`, the shared body of `selectPreset` — the 200 ms crossfade, minus the format republish |
| Revert | The snapshot is taken once, on the transition into "a rule is in effect", so a Zoom → Teams handover in one sitting still returns to where the user started |
| Override | An explicit preset pick — or any hand edit to the look — takes the wheel back: the rule stops being in effect and there is nothing left to revert to, so an hour of adjustment during a call is never thrown away when the call ends |
| Persistence | Rule-driven looks are never saved as the user's configuration, exactly like a panic backdrop (§5.11) — `persistConfig` writes `appRuleRestore ?? panicRestore ?? config` |

**Two clients at once is the case that has to be specified, not discovered.** PRISM Camera is one camera with one picture; the extension's source stream fans that picture out to every consumer. So when Zoom and FaceTime stream together there is no honest way to give them different looks. "Most recent to connect" would make the look depend on which app the user happened to open first — unpredictable, and impossible to write down. List order is the rule instead: it is visible on screen, it is stable, and dragging a row is how the user says which app matters more. A rule that names no preset does not veto a lower rule that does; neither does a blocked rule.

**Saying so without nagging.** A look that changes itself is indistinguishable from a bug, so PRISM posts one notification naming both sides — `Zoom connected — Meeting preset applied` — and then goes quiet. There is no notification on revert. The preset surfaces carry the state continuously instead: the popover's chip swaps its active dot for a badge, the Presets pane spells it out (`Applied by a rule for Zoom`), and both announce it to VoiceOver. Which preset is on air *because of a rule* rather than because you picked it is always answerable at a glance.

#### Per-app blocking

`authorizedToStartStream` becomes a real policy hook. The policy travels over the `'polc'` custom device property in the same style as `'pfmt'` — §3.1 says the CMIO channel is the only IPC there is, and App Groups do not cross the user/root boundary.

**The extension fails open, on every path.** No policy ever received, a missing or unreadable `policy.json`, a `version` above what this build understands, or a signing ID the policy does not mention under `defaultAccess: "allow"` all resolve to *allow*. The hook is written as "refuse only on an explicit no" rather than "allow only on an explicit yes", so even a released `deviceSource` reference admits the client instead of locking the camera. PRISM's own signing ID is never refused at any layer.

**The policy is persisted, and that is deliberate.** CMIO extensions are launched on demand and torn down when idle, so an in-memory policy would be cleared by quitting and reopening the very app the user blocked — a block anybody can bypass by accident is not a block. A corrupt policy file is deleted on read rather than left to fail open forever in silence.

**A blocked client is refused, not shown a card.** `stream.send` fans one picture out to every consumer, so there is no way to show *this* client a placeholder while another sees video; a per-client card would need a stream per client, which CMIOExtension does not offer. Returning `false` makes the client's `AVCaptureSession` fail to start — the same shape as a TCC denial, which is a failure every video app already knows how to draw. The refusal is invisible from inside the refused app, so the extension reports recent refusals over `'blkd'` and PRISM says what happened.

**Getting out.** The failure mode this feature makes easy is blocking the app you are on a call in, so:

- Blocking an app that is streaming right now raises a confirmation, and the block only bites on that app's *next* camera start — PRISM never cuts a call that is already running.
- Turning `defaultAccess` to `.block` (allow-list mode) raises its own confirmation naming the consequence for apps installed later.
- A live refusal raises the §8.3 warning row, with `Unblock all` in the row itself (`WarningMessage.Action.clearBlocks`): the user never has to find a pane to get out. It is the one warning action that fixes the condition instead of navigating to it, because it is the one condition that can outlive PRISM.
- The Apps pane carries `Unblock every app`, which lifts every block and resets the default while keeping preset assignments — the failure being recovered from is "my camera is dead", not "I regret my presets".
- Removing PRISM removes the embedded extension, and every block with it.

Rules live in `AppRulesSettings`, inside `StudioSettings` rather than in a preset: a preset captures a look, and "Zoom gets the Meeting look" is a rule *about* presets. A preset that carried rules could apply itself. The full editor lives in the main window's Apps pane (§8.3 puts deeper controls in the roomier surface); the consequences — which preset a rule chose, and who is being refused — appear in both surfaces.
### 5.19 Keyboard shortcuts

Every action in the table below is bindable; the defaults are the chords §5.2–§5.16 document.

| Property | Specification |
|---|---|
| Actions | `ShortcutAction` (Hotkeys.swift), all seventeen: freeze, mute, freeze and mute, instant replay, away loop, panic, eye contact, lag switch, bad connection, voice changer, save the last seconds, take a still, share a screen, prompter, transcribe this call, ask the assistant, live insights |
| Editing | Shortcuts pane (main window) and Settings → General, both built from one `ShortcutsList`; a recorder captures the real key-down |
| Rules | A binding needs ⌥ or ⌃; function keys may stand alone; a modifier key alone is never a binding |
| Conflicts | A chord has one owner. Assigning one that is taken takes it, leaves the previous owner unbound, and says so in the warning row |
| Reset | Per row and globally; a reset is an assignment and goes through the same conflict check |
| Storage | `HotkeyBindings` (HotkeyBindings.swift) under `PRISM.hotkeys`, string-keyed and tolerant per field |

**⌥ or ⌃, because PRISM never swallows the keystroke.** The tap is listen-only (§5.2), so a ⌘-only or bare-key binding would fire PRISM's action *and* whatever the front app does with that chord — freeze the camera while quitting Pages. ⌥ and ⌃ chords are rare in menus, and function keys type nothing at all, so those are the two shapes a global binding may take.

**Stealing beats refusing.** Refusing a taken chord leaves the user to hunt for the owner; allowing a duplicate leaves two actions on one chord with match order deciding which fires. Taking it, naming the loser, and leaving "Reset all" one click away is the only option where the keyboard's state is always legible. Preset chords (§5.5) are in the same namespace and checked the same way — they go through the same tap.

**Keys are named through the active layout.** `KeyCodeNames` resolves a keycode with `UCKeyTranslate` against `TISCopyCurrentKeyboardLayoutInputSource`, falling back to the ASCII-capable source when an input method has no layout data, and caches per layout with the cache dropped on `kTISNotifySelectedKeyboardInputSourceChanged`. Layout-independent keys (function keys, arrows, the editing block, the keypad) come from a fixed table so they read the way macOS menus print them; an ANSI table is the last resort for contexts where no layout is available at all. Bindings are recorded rather than picked from a list, so naming the key back correctly is the whole contract: a fixed 26-entry table names A–Z on a US layout and prints `key57` for everything else.

**Recording stops the tap.** Otherwise binding a key to Panic panics while you bind it.

### 5.20 External control

Local hardware — a Stream Deck, a Focus filter, a Shortcuts automation — can drive PRISM through App Intents. Off by default (`PRISM.externalControl`).

| Property | Specification |
|---|---|
| Mechanism | App Intents (`PrismIntents.swift`); no `AppShortcutsProvider`, so no Siri phrases |
| Verbs | Freeze, mute, panic, away loop, instant replay, eye contact, voice changer, background blur, apply preset — each on/off/toggle |
| Gate | Every invocation checks the master switch and fails with what to turn on |
| Returns | Confirmation only. No intent returns video, audio, frames, buffer contents, or the session log |

**A URL scheme was rejected.** `open prism://panic` from any local process — any script, any page that can talk someone into a click — is an unauthenticated RPC endpoint into a camera. For an app whose entire trust argument is that it phones nobody, an unauthenticated local endpoint is worse than a telemetry ping. App Intents run through the system's own permission and attribution machinery, and the user opts in once.

**What is not exposed is the specification.** No device selection ("switch to the other camera" is a surveillance verb). No published-format change — that is a reconnect boundary that would drop every client mid-call (§3.2). No clip, LUT, background or overlay loading, which would make an automation a file-read primitive aimed at an arbitrary path. No quit, which would take the virtual camera down under a live call. Nothing that edits the shortcut table or this switch, so an automation can never widen its own surface. And no Siri phrases, because "Hey Siri, panic" is a phrase meetings say out loud.

### 5.21 Session diagnostics

PRISM already computes every auto-disable, every device change, every dropped frame and every per-stage GPU cost, and then discards them. The Diagnostics pane keeps them for the life of the process so "why did my effects turn off?" has an answer after the warning row has moved on.

| Property | Specification |
|---|---|
| Contents | Degradation events (§3.4), device arrivals/removals and capture failures, dropped-frame bursts, client apps starting and stopping, format changes, and every change of what clients can see (the §8.2 glyph) |
| Numbers | Session duration, dropped frames, added latency now and at its peak, per-stage GPU cost now and at its peak |
| Storage | `SessionLog`, in memory, 300 rows, consecutive repeats coalesced with a count |
| Export | Plain text, written only when the user picks Export |

**Recording is not optional, because the point is the past tense.** A default-off history answers the question it exists for with "we didn't record that". What makes it safe is not a switch but the storage: a bounded array in this process, no file, no network, gone when PRISM quits.

**A row may name a device or an application; it may never name the contents of one.** "Unless the user exports it" is where the risk lives — an export is a plain-text file that gets attached to a support thread, and the pane says so. A shared window's *title* is a document name or a browser tab ("Q3 layoffs (confidential).xlsx"), which is the one thing in this app's reach that would genuinely embarrass the person who sent the file. So a window is named to the log by its application and not by its title, on every sentence that names a source: the pick, the stop, the fallback. The user still sees the full title everywhere it is useful — the picker, the status line, the warning row. The redaction happens where the sentence is built, not inside the log, because a log that redacts is a log that has to keep guessing what a string is.

**Repeats coalesce rather than scroll.** A camera that reconnects forty times is one story; forty rows would push the auto-disable that actually explains the session off the end of a bounded list.

**The menu bar glyph is the recording point for what is on air.** It already summarises freeze, mute, panic, away, replay, lag and bad connection with the right precedence, and it changes exactly when that answer changes — so one call there beats a call at every intent.

### 5.22 Skin retouch

An edge-preserving smooth over skin, and nothing else in the frame.

| Property | Specification |
|---|---|
| Stage | `.retouch`, `.expensive`, between Geometry and Adjust |
| Kernels | `prism_retouch_blur` (separable bilateral, one direction per pass), `prism_retouch_combine` |
| Passes | half-resolution downsample → bilateral H → bilateral V → full-resolution combine |
| Control | **one** — Amount (0…1) |
| Gate | skin chroma, narrowed by the person mask when one already exists |
| Default | stage off, amount 0 |

**What this is.** It smooths the skin you have. The smoothing is a weighted average of pixels already in the frame; there is no face model, nothing is generated, and nothing is replaced. §5.6 sets the precedent and the same instruction applies: **do not describe this feature to users in terms that imply a rendered or synthesised face.**

**Why it does not go plastic.** Two mechanisms, both necessary. The blur is *bilateral* — each tap is weighted by luma distance as well as by spatial distance — so eyelashes, nostrils, the lip line and the hairline are cliffs the smoothing steps around rather than melts; a plain Gaussian's treatment of those edges is exactly what reads as a mask. Then the combine hands the removed texture back: everything the blur took out is `source − smoothed`, and `detail` of it is added to the result, which is frequency separation. Pores and stubble therefore survive a heavy smooth. `detail` is a persisted field and deliberately **not** a control — §8.7 asks one question per effect, and "how much of what you removed would you like back" is not a question a user can hold in their head.

**Half resolution costs nothing visually.** The bilateral runs at half resolution and the combine at full, so the frequencies the downsample discards are precisely the ones the combine restores from the full-resolution source.

**The gate is chroma, and the person mask is opportunistic.** Skin occupies a compact region of Rec.601 Cb/Cr, and across skin tones melanin moves brightness far more than it moves hue — so a chroma region covers the range of human skin where a luma threshold would quietly work for some people and not others. Chroma needs nothing but the frame, which is the point: **turning retouch on must never buy a Vision segmentation request.** Retouch is therefore not in the pipeline's mask-consumer set. When a mask does happen to exist — someone has blur, a virtual background, or a layer behind them — it narrows the gate to the subject. That can only change the picture *outside* the person, never on the face, which is what makes an opportunistic input honest here.

**Measured cost**, 1920×1080, Apple silicon: 0.64 ms at the default amount, 0.78 ms at full, against background blur's 0.92 ms in the same harness. The 60 fps balanced budget is 6.7 ms (§3.4), so the stage is about a tenth of it. Its GPU weight is 9, against blur's 12.

**Amount 0 is off, and 0 is where it ships.** The stage declines to encode, `isInert` reports it, and every surface says `On, but the amount is 0.` Switching the stage on when the amount is still zero lifts it to `RetouchSettings.defaultAmount` — the LUT/Neutral and Style/Normal remedy for the §8.7 inert-toggle problem, applied to an effect that has exactly one knob and therefore exactly one unambiguous value meaning "on".

### 5.23 Resource governance

Every elastic allocation in PRISM was sized against §7's 250 MB ceiling independently, none of them knew about each other, and the sum had never been added up. It does not fit. `ResourceGovernor` is the one place that adds it up and decides who gets what.

**Measured, on an M-series Mac.** One BGRA `IOSurface` slot costs 3.5 MB at 720p, 7.9 MB at 1080p, 31.7 MB at 4K. `FrameRing` at its shipped depth — half a second, so its slot count follows the frame rate — measured **118.9 MB at 1080p30, 237.9 MB at 1080p60 and 474.8 MB at 4K30**. The output pool plus the two working intermediates measured 31.7 MB at 1080p and 126.6 MB at 4K. An armed `StillRing` measured 47.6 MB at 1080p. Everything that is not a pixel buffer measured 36 MB peak with the chain built and no camera, plus 33 MB once the three Vision models are resident (15.8 segmentation, 11.1 landmarks, 6.5 hand pose). A live session with the chain running measured 446 MB resident, 293 MB of it `IOSurface`.

**What the governor decides**, from the negotiated format and nothing else:

| Output | Meaning |
|---|---|
| `freezeDepth` | `FrameRing` slots |
| `freezeStride` | record one camera frame in this many |
| `stillDepth` | `StillRing` slots; 0 means stills fall back to the last frame |
| `screenDepth` | frames ScreenCaptureKit holds while a screen is captured (§5.24); 0 otherwise |
| `tier` | `full` / `reduced` / `minimum` / `exceeded` |
| `plannedMB` | the sum, against `ceilingMB` |

**What goes into the sum, and at which size.** A slot is not one number: the output pool's four frames and the fit scratch are the *negotiated* format's, and everything else — `FrameRing`, the two working intermediates, and every stage-private working texture — is the **source's**, because that is where they are allocated. §3.2 picks the smallest native camera format at least as large as the output in both dimensions, so a 4:3 sensor serving a 16:9 call is strictly larger: a Continuity Camera hands over 1920×1440 for a 1080p call, which is 10.5 MB a slot against the 7.9 the plan used to assume. Pricing the working set at the output understated the ring by a third and let the widening step spend memory that was never there. The source's size enters the plan from the first camera frame, and never from the no-camera heartbeat — that texture is the output's size and re-planning against it would make the freeze window flap every time the camera paused.

Three demands join `screenDepth` as fixed costs taken off the top, for the same reason it is one — the governor cannot make any of them smaller, and planning the freeze window against memory that is already spent is not planning:

| Demand | What it allocates | Cost at 1080p |
|---|---|---|
| §5.9 rolling replay buffer armed | a six-slot raw record pool at the capped record size, the compressed ring at `ReplayBuffer.bitRate` for the whole window, and a 32×18 luma thumbnail per recorded frame | ~58 MB at the 10 s default; ~99 MB at 30 s |
| §5.5 draft preview on screen | a second chain: two intermediates, the same stage-private working textures, a three-deep output pool, and a second segmenter and face tracker | ~119 MB |
| §5.24 screen session running | ScreenCaptureKit's queue | ~24 MB |

**Which formats fit, plainly.** 720p and below fit with room to spare. 1080p fits **bare and at freeze's floor** — 242 MB of the 250, six slots, 200 ms — and nothing more fits beside it: a screen source (266), an armed replay buffer (300), a staged draft (362) or a camera larger than the call (275) each put it over. 4K was already over before any of this. Over the ceiling the governor does what it does everywhere: takes freeze's floor and no more, refuses the still ring outright, reports `exceeded`, names the figure in the sentence, and puts that sentence in the §5.21 session log. It does not silently plan a window it cannot afford, which is exactly what it was doing while these four allocations were outside the sum.

**The order of service is fixed**, which is what makes the degradation predictable: freeze's floor, then the still ring if the user armed it, then whatever is left widening the freeze window back toward half a second. Nothing is decided by which feature asked first. ScreenCaptureKit's queue is not in that order at all — it joins the structural frames, because PRISM cannot make it smaller than three and planning the freeze window against memory that is already spent is not planning. The stage-private working textures join them too, and are counted whether or not their stage is on: Style's motion history and stack scratch (§5.29), Overlay's layer ping-pong pair (§5.26, allocated the moment a second layer renders and never released after), and Retouch's pair (§5.22, half resolution in both dimensions, so a quarter of a frame each) — 4.5 frames in all. Costing them on demand would make the freeze window change length when the user picked Underwater or dropped a lower third on the picture, and a window that reaches back four tenths of a second on Tuesday and three on Wednesday is worse to reason about than one that is permanently a few slots shorter.

**Freeze's floor is the guarantee, and it is never spent.** §5.2 promises the sharpest frame of the recent past. A ring too shallow to hold a choice turns that into "the frame at the moment you pressed it", which §5.2 says freeze is not. So: **never fewer than six slots, and never less than 200 ms of wall time.** Six, because two slots are unavailable at any instant — the one being written and the one whose command buffer has not landed. 200 ms, because a blink closes the eyes for 100–150 ms and a window shorter than one has nothing sharper to offer. Where those two pull against each other — 200 ms of 60 fps is twelve slots — the ring **strides**: six slots recording every second frame still span 200 ms and still hold a choice, for half the memory. A coarser choice inside the window is a far cheaper loss than a window narrower than a blink.

**The still ring is granted whole or refused.** Below `StillRing.minimumDepth` (4 slots, 133 ms at 30 fps) it is paying full-frame prices for no real choice, so it gets nothing and `stillFrame()` falls back to the last frame — which it already does, and which is the honest answer to "save what I am looking at".

**4K is over the ceiling and says so.** At 31.7 MB a frame the output pool and the intermediates alone exceed 250 MB before freeze holds anything; the plan reports `exceeded` and names the figure rather than pretending. See §7.

**The policy is legible or it is a mystery.** The Diagnostics pane shows the planned figure against the ceiling, how far back freeze reaches in seconds and frames, and the sentence explaining why. A change to the plan is a §5.21 session event, for the same reason an auto-disabled effect is: the freeze window shortening is invisible until somebody freezes and finds the picture came from less history than they expected.

**Vision consolidation.** `VisionCoordinator` decides which Vision request runs on each frame. At most one request per modality per frame and at most one modality per frame; each modality declares its own duty cycle; each consumer declares its own standing demand, evaluated per frame rather than cached. The pick is the modality furthest past its own cadence, ties to the earlier-declared one — which reproduces the previous hard-coded even/odd alternation exactly when only the person mask and the face are demanded, and shares the slip proportionally when a third modality is. Modalities are `face` (cadence 2), `person` (2), `hands` (3, §5.31) and `presence` (15, §5.28), in that declaration order — which is also the tie-break order, and the reason a slower modality declared later cannot take frames off the eye-contact warp. An unregistered modality never runs however loudly it is demanded, which is the seam every new recogniser arrives through.

### 5.24 Screen or window as the source

A display or a single window in place of the camera, so the thing you are talking about can be the thing on air.

| Property | Specification |
|---|---|
| Framework | `ScreenCaptureKit` — `SCStream`, 32BGRA, `IOSurface`-backed |
| Sources | any display, or any on-screen titled window (`SCShareableContent`) |
| Trigger | the Source picker in both surfaces, plus global hotkey ⌥⌘D |
| Grant | Screen Recording TCC, requested only when a screen is first chosen |
| Scaling | fitted into the negotiated format with its own aspect preserved |
| Frame rate | the negotiated format's, via `minimumFrameInterval` |
| Queue depth | 3 — ScreenCaptureKit's floor, and charged to §5.23 |
| Default | off; the camera is the source |

**The frames enter through the camera's door.** `ScreenCapture.onFrame` calls the same `VideoPipeline.submitCameraFrame` the camera does, and nothing downstream is told the difference. That is the whole design: one command buffer per frame, the `FrameRing`, freeze, the rolling replay buffer, the still ring, the crossfade and the latency attribution all keep working on a screen because none of them ever asked where the pixels came from. Every effect applies to a screen. So does every moment — you can freeze a slide, replay the last ten seconds of a demo, and save the clip.

**A still screen is still a screen.** ScreenCaptureKit reports frames as `.idle` when the display has not changed, which is correct for a recorder and wrong for a live source: a virtual camera receiving nothing falls back to the extension's placeholder (§3.2), and a static slide would blank the call. `ScreenCapture` therefore re-submits its last frame at the configured rate whenever none has arrived for more than one and a half intervals. That is what a camera pointed at a motionless scene does, and it keeps every downstream clock running on real frames.

**Never a black frame.** A closed window, an unplugged display, a stream that will not build, a missing grant: each stops the session, names itself in a sentence, and falls back to the camera — the one source that exists without a grant. §3.2's placeholder rule is the precedent, and the honest degradation is always toward something, never toward a dark rectangle nobody can explain. A failed session is not retried on a loop; a new pick, a wake, a fresh look at what is shareable, or the grant arriving are what let it try again.

**The pick is stored as an id and re-resolved at launch.** A display id survives a reboot; a window id does not. `VideoSourceSelection` therefore persists the kind and the id and nothing else, and the app asks the window server whether the id still means anything before starting any capture against it. One that does not resolve reverts to the camera and says so in the session log — quietly, because this happens on every launch after a reboot for anyone who shared a window, and a warning that fires on a schedule is one people stop reading.

**The capture is fitted, not filled.** A 6K display at native size is three `IOSurface` slots of roughly 100 MB each, to produce pixels `OutputFitStage` is about to throw away. The stream is configured at the largest size that fits inside the negotiated format with the source's own aspect preserved, so ScreenCaptureKit is never asked to pad — the letterboxing is decided once, by the same stage that decides it for every other source. PRISM is excluded from a display capture **by application, not by a list of windows**, because a preview of the capture cannot be in the capture — which also takes the teleprompter out of PRISM's own screen source, on top of the system-wide exclusion §5.27 relies on. The distinction is the whole guarantee: the shareable-content list is a snapshot taken when the stream is built, the filter is never rebuilt (a selection or format change restarts the stream; a window appearing does not), and PRISM makes its windows lazily — the main window on first open, the prompter *pane* inside it, the popover's window on demand. A filter built from that snapshot composites every one of them into the outgoing camera the moment it appears, which for the pane where the script is typed is the exact failure §5.27 exists to prevent. Excluding the application covers windows that do not exist yet. If PRISM cannot be found in the content at all, the capture does not start and says so — a share that fails is recoverable in a way a script read out to the call is not.

**The grant is demanded by the feature, not by the app.** Screen Recording is not requested at first launch: the feature ships off, and a permission dialog for something nobody has asked for is how an app loses that grant for good. Choosing a screen raises the prompt; until then the picker offers the camera and a sentence. The setup banner grows a fourth row exactly while something is asking for a screen (§9), and macOS applies the grant when PRISM is next opened — which the copy says, rather than leaving the user to wonder why the screen is still not on air.

### 5.25 Picture-in-picture

You over your screen, or your screen over you.

| Property | Specification |
|---|---|
| Mechanism | a `.live` overlay layer (§5.8), through `prism_overlay` |
| Feeds | `LiveLayerFeed.camera`, `LiveLayerFeed.screen` |
| Default placement | bottom right, 0.28 of the frame, no key |
| Cost | one compute pass; no decoder, so no `maxVideoLayers` slot |
| Default | off |

**It is not a stage.** `prism_overlay` already does aspect-preserving placement, scale, offset, rotation, mirror, opacity, chroma and luma keying, and behind-the-subject gating against the shared person mask. A dedicated picture-in-picture kernel would be that kernel again, byte for byte, and a second one to keep in step with it forever. So a picture-in-picture is a layer: it inherits every control §5.8 already has, including standing *behind* you, which is how a screen becomes a background you are presenting in front of.

**Whichever feed is not the picture is the layer.** Only one capture drives the pipeline; the other publishes into `LiveFeeds`, and the overlay stage reads it on the frame queue. Nothing is published for the feed that *is* the source, so a layer pointed at it draws nothing — a picture-in-picture of the picture is a picture of itself, and the surfaces say so rather than showing a recursive rectangle. Adding one is therefore a single action rather than a choice (§8.7): the button offers the other feed, and names it.

**The hold is the correctness point.** A live layer sits at `.overlay`, far downstream of clip, replay and freeze. Left alone it would keep moving under a picture the user believes is held — freeze the screen and your face carries on talking in the corner; freeze the camera and the screen keeps scrolling behind it. That is the most damaging failure this app can produce, and it is the same failure in both directions, so it gets one answer: **while any substituting stage is engaged, the feeds are held.** The layer's texture is snapshotted and every frame published behind it is dropped until the substitution ends. This covers freeze, replay, the away loop, the lag switch and panic without any of them knowing the feature exists, because all five reach the picture through `.clip`, `.replay` or `.freeze`.

The snapshot is a copy rather than a retained reference. Capture pools are shallow — three slots for ScreenCaptureKit — and a freeze can last minutes; holding one of their buffers that long starves the session that owns it. The copy costs one private texture per held feed, paid only while held, which is the trade `FreezeStage` already makes for the same reason. A feed with nothing on screen when the hold engages stays empty: handing it the next frame that arrives would be the same failure one beat later.

A stage that is *supposed* to be substituting but has nothing to draw is the same failure wearing a different hat, so the two cases where that can happen are closed at the source rather than here: a deferred freeze takes hold on the next frame including the heartbeat (§5.2), and a transport still spinning up draws its bridge frame (§5.9).

The decision is taken at the layers' own position in the chain walk, once every substituting stage has had its say. `ChainRegistrationTests` asserts that the substituting set is complete and that every member of it runs before `.overlay` — a stage added later that replaces the picture and forgets to join the set would be exactly the bug this paragraph exists to prevent, and it would not show up until it happened on someone's call.

### 5.26 Text layers and lower thirds

Words in the picture: a caption, a handle, or a name banner in two fields.

| Property | Specification |
|---|---|
| Mechanism | a `.text` overlay layer (§5.8), through `prism_overlay` |
| Rasteriser | Core Text → `CGBitmapContext` → `MTLTexture` (`TextRasterizer`) |
| Content | a line and an optional second line (`OverlayTextStyle`) |
| Style | family, size, weight, colour, alignment, plate, padding |
| Plates | none, a solid rounded slab, or a blurred halo |
| Size | points at 1080p, scaled by the frame's own height |
| Cost | one rasterisation per change; one compute pass per frame |
| Cap | a total slot, never a `maxVideoLayers` slot — text has no decoder |
| Default | off; no layer exists until one is added |

**It is not a stage.** `prism_overlay` already places, rotates, mirrors, fades and depth-gates a layer against the person mask, and it already honours a PNG's alpha. A caption is a bitmap with alpha. So text arrives as a layer and inherits all of it — including standing *behind* the subject, which is how a caption ends up painted on the wall you are sitting in front of. The kernel is unchanged and does not know text exists.

**The cache is the design.** Laying out and drawing a paragraph costs milliseconds, and §3.4 budgets the entire chain in single digits — a rasterisation on the frame path would blow the budget on the frame it happened, and this app does not drop frames to preserve an effect. So the bitmap is redrawn only when the string, the style, or the pixel size it will occupy actually changes, and even then on a private queue. The frame queue asks for a texture and takes whatever is currently drawn: a brand-new caption is invisible for a frame or two, and a caption being retyped keeps showing its previous spelling rather than blinking on every keystroke. A caption that arrives one frame late is invisible. A frame that arrives one frame late is not.

**Placement is by pixel, not by fit.** Every other layer kind is *fitted* into the frame at scale 1, aspect preserved. Text is the one exception, and it has to be: the rasteriser has already sized the caption for this exact frame, so fitting it would blow two words up to the width of the picture and make the point size mean nothing. A text layer is placed at its own pixel size instead. That is also what makes the size honest across formats — the point size is quoted at 1080p and scaled by the frame's own height, so the same preset draws the same fraction of the picture at 720p and at 4K.

**Alignment pins an edge.** The canvas is tight to the words, so it grows as they are typed. Anchoring its *centre* would slide a name banner sideways with every letter — so for text, alignment decides which edge the horizontal offset holds: leading pins the left, trailing the right, centre keeps the centre. A lower third therefore grows rightward from a fixed left margin, which is what a lower third does. Inside the canvas the same setting is the paragraph alignment, so the two meanings agree.

**Straight alpha, and no dark rim.** The kernel mixes the layer's RGB into the base by its alpha, exactly as it does for a PNG, so the bitmap is un-premultiplied after drawing. Fully transparent pixels are then *coloured* rather than left at zero, because the kernel samples bilinearly and a transparent black neighbour would drag a dark halo around every glyph on the way out.

**The blurred plate is a halo, not frosted glass.** Frosted glass means sampling the base twice with a blur between, inside a kernel every layer in the app shares — a text-only branch through `prism_overlay` would be paid for by hats and green screens forever. A soft halo hugging the letterforms is what actually buys legibility over a busy picture, it is baked into the layer's own alpha, and it costs nothing at composite time.

**A lower third is a preset shape, not a second feature.** It is a text layer with the plate, the alignment, the size and the height already decided, so setting one up is typing a name and a job. Everything underneath is the same generic layer, and every knob stays reachable.

**A caption pays a total slot and never a video one.** The five-layer cap is about compute passes and the three-video cap is about decoders (§5.8). Text has no decoder — that is precisely why the total was allowed above three — and the canvas is bounded at 94% of the frame in each axis so a pasted essay cannot allocate a texture larger than the picture it is drawn into.

### 5.27 Teleprompter

Your script, on your screen, where nobody else can read it.

| Property | Specification |
|---|---|
| Mechanism | a floating `NSPanel` over the user's own desktop — **not** a layer |
| Capture | `sharingType = .none`: excluded from every screen recorder, system-wide |
| Trigger | the Prompter section, the Prompter pane, and ⌃⌥⌘T |
| Controls | speed in lines per minute, size, opacity, mirrored, start / hold / top |
| Position | dragged; opens at top, middle or bottom of the display |
| Persistence | in `StudioSettings`, never in a preset; the open state is never restored |
| Default | off |

**A prompter is for the person reading it.** Drawn into the outgoing frame it would be a prompter everyone on the call can read, which is not a feature. So it is a panel on the reader's own screen, positioned by them next to their lens — which is exactly what makes it compose with eye contact (§5.6): read from just under the camera and the correction closes the last few degrees. Nothing on the frame path knows the prompter exists. `PrompterSettings` lives in `StudioSettings`, no stage reads it, and there is no code path from a script to a texture.

**Screen sharing cannot capture it either, and that is the harder half.** Somebody prompting is very likely also sharing a screen, and PRISM cannot ask Zoom to leave a window out. `sharingType = .none` takes the panel out of the window server's capture surface entirely: Zoom, Teams, QuickTime, ScreenCaptureKit and PRISM's own screen source all receive the desktop with a prompter-shaped hole in it, because the refusal is made below all of them. PRISM's display capture already excludes every window PRISM owns (§5.24), so the one screen source this app does control refuses it twice.

**The chord holds the script; it does not dismiss it.** ⌃⌥⌘T opens the panel if it is closed and otherwise runs or holds the scroll, because the thing worth reaching for mid-sentence is "stop, I've lost my place" — never "make it go away". Putting the prompter away is a click on a panel you are already looking at, or the switch in either surface. Rebinding follows §5.19 like every other chord.

**Lines a minute, not pixels a second.** The scroll rate is derived from the font's own line height, so changing the size changes how much fits on the panel and not how fast the reader is being pushed. The script comes to rest with its last line a third of the way up rather than scrolling away into an empty panel, and editing the script returns the reader to the top — a position measured in lines means nothing once the lines have changed.

**Nothing about it opens itself.** PRISM launches at login for most people; a panel that restored last week's script over whatever they actually sat down to do would be a private document appearing with no visible cause. The words are persisted, the decision to show them is not. The script is also not part of any preset — switching from Meeting to Studio changes a look, and it must never load somebody else's words onto the screen.

**The panel stays out of the way.** Non-activating and floating, so clicking it does not pull focus off the call in front of it and it stays visible over a full-screen meeting window on any space. Its controls — hold, back to the top, close — appear only under the pointer, because this thing sits in the reader's eyeline while they are on camera and a permanent row of buttons there is a row of buttons everyone watches them look at. Mirroring flips the words, not the panel, for a beam-splitter rig where the script is read off glass in front of the lens.


### 5.28 Presence automation

The away loop (§5.10) without the keystroke: when nobody has been in frame for a while, take the configured action; when they come back, undo it.

| Property | Specification |
|---|---|
| Detector | `VNDetectHumanRectanglesRequest`, upper body only, on a 640×360 downsample |
| Scheduling | a `VisionCoordinator` modality of its own at cadence 15 — about 1 Hz under full contention |
| Demand | only while an action or the nudge is switched on, **and** the camera is the source |
| Action | nothing / away loop / freeze — **`.none` by default** |
| Leaving | 2–60 s, default 6 s below the coverage threshold |
| Returning | 0.2–10 s, default 1 s above it |
| Coverage | 0.005–0.5 of the frame, default 0.04; release at 0.75 of that |
| Muting | follows §5.10's "mute while away" for both actions — one question, one control |
| Nudge | optional Notification Centre line when the frame empties, default off |

**Choosing the detector is the cost decision, and there were three candidates.** The person mask (§5.4) is already being produced, which makes reading it look free — but it is only produced while somebody else wants it, and presence watching is on for the whole meeting. Demanding `.person` on presence's behalf would pin the single most expensive request in the pipeline on permanently, to answer a question that never needed a per-pixel silhouette: six milliseconds a frame for one bit a second. Frame differencing is nearly free and answers the wrong question — it measures motion, not presence, so the first person it declares absent is the one sitting still and reading, which is both the commonest way to be present and the worst possible false trigger; it also tracks the camera's own gain and noise, so a threshold tuned in daylight fires at dusk. A human-rectangle request on a quarter-size copy is the cheapest thing that actually answers the question asked, and upper-body-only is the right mode because a seated person's legs are under the desk and the torso is what leaves when they stand up.

**It is a coordinated modality, declared last and cadenced slowest.** §5.23's schedule gives at most one modality per frame, so a new one competing at eye contact's cadence would take frames off the warp. Presence asks for one frame in fifteen and loses every tie it enters, which still leaves it running about once a second against a threshold measured in seconds. It is demanded only while one of its switches is on, and it stands down on the frames the no-camera heartbeat produces — the flat dark texture is a measurement of nothing, not evidence that the room emptied.

**Hysteresis is the whole feature, and it is deliberately asymmetric.** A late trigger costs nothing: the loop starts a second after the user walked out, and nobody was watching. A false trigger costs the thing this app exists to protect — it puts a recording of the user on air while they are sitting there talking, and they find out when somebody says "you've frozen". So leaving is slow and returning is fast; the two coverage thresholds are different numbers, with a dead band between them where nothing is decided, so a subject sitting exactly on one cannot flap across it; the absence clock restarts on the first sighting, so four seconds out, one second in and four seconds out is not eight seconds away; and one observation can only advance the clock by two seconds however long the gap before it was. That last rule is what stops a sleeping Mac from firing the away loop at the exact moment the user sat back down.

`unknown` is a real third state and not a synonym for absent. Before anything has been measured there is no evidence either way, and acting on no evidence is the failure.

**The away loop needs an armed rolling buffer, so choosing it arms one.** The loop reads from §5.9's recorder, and an automation that fires into an unarmed buffer is an automation that does nothing at the one moment it was supposed to work — so picking the loop turns the buffer on, exactly as the first press of ⌥⌘A does, and both surfaces say so beside the control. When the loop still cannot start because nothing is recorded yet, PRISM holds the frame instead and says which happened. What it never does is nothing.

**Disclosure, because this is the one thing in PRISM that acts without being asked each time.** Armed, both surfaces print what will happen and after how long. Fired, the menu bar takes its existing `.away` glyph (or the freeze bar), the notice row says which action ran and why, and a system notification goes out — the user is by definition not at the keyboard. Every one of those carries the same one-tap escape, and the escape is also the Away and Freeze tiles themselves: turning off by hand what presence turned on releases the mute that went with it, which a user who unfroze themselves and stayed silently muted would have no way to connect. Presence undoes only what it did — a freeze the user engaged first stays engaged, and a mute they set themselves survives them walking back into shot. And it fires once per departure, not once per absent observation, which is what makes the manual escape stick: nothing comes back on until the user has been seen in frame and left again.

**The nudge is the one presence behaviour that changes nothing on air**, which is why it can be switched on by itself with the action left at nothing: "you left your camera on", said once, in Notification Centre.

### 5.29 Stacking two style effects

One effect was always the plan and it is one effect too few: the pairing people reach for is a distortion with a trail on top of it — Underwater with Afterimage, Twirl with Echo — and neither half is available as a single kernel. So `StyleSettings` holds **two slots** rather than one effect. Slot 0 is applied to the picture, slot 1 to slot 0's output, and every other detail follows from those two sentences.

| Property | Specification |
|---|---|
| Slots | exactly 2, always present; `Normal` in a slot means it runs nothing |
| Order | slot 0 then slot 1, over the same frame, in one command buffer |
| Motion effects | **at most one across both slots** — the earlier slot keeps it |
| Cost | a second full-frame pass, charged as such (§3.4) |
| Memory | one extra working-resolution texture, always counted (§5.23) |

**Two, and the cap is a consequence rather than a preference.** Each slot is another full-frame compute pass and another working-resolution texture off §7's ceiling; the second one already costs freeze roughly three slots of its window at 1080p. A third would buy an effect nobody can read on top of two, for a third pass. A style catalogue is a look, not a modular synth.

**A stage may encode twice, and a private texture is what makes that legal.** The pipeline hands every stage exactly one input and one output, ping-ponged between the two shared intermediates, so a second pass has nowhere of its own to land — and reading a texture the same pass is writing is undefined however careful the kernel is. Style therefore owns a scratch texture: slot 0 writes into it, slot 1 reads it and writes the real output, and the picture the chain carries forward is `output` whichever slots were filled. Both passes ride the frame's single command buffer; the one-command-buffer rule is about frames, not passes.

**One motion effect, because there is one history texture.** The motion family feeds on its own output (§5.4), and two feedback loops sharing a single frame of history would each be trailing the other's ghosts. A second history would be another full-frame texture for a combination that reads as mud. So the model admits the first motion effect and drops the second, both pickers stop offering motion effects once one is running, and the caption says which effect is holding the history. The blit that publishes the history is taken from **that pass's** destination rather than the stage's, so a motion effect in slot 0 trails its own picture rather than whatever slot 1 painted over it.

**A stack is charged for two passes, not averaged into one number.** `stageWeights[.style]` stays the weight of one pass and the stage reports how many it ran; the attribution multiplies. Averaging the two configurations was the tempting version and it is wrong for both — it would make a single effect look 60% dearer than it is, which is the degradation engine's cue to turn it off first.

**Every existing preset holds the old single-effect shape, and this is the hard part.** The persisted struct now has two live shapes: the flat `effect` / `intensity` / `audioReactive` triple, and the `layers` array. The rule is one sentence: **`layers` wins whenever the key is present at all, even as an empty array; the flat keys build slot 0 only when it is absent.** It has to be this way round because a file this build writes carries *both*, and its flat keys describe only the first of two effects — preferring them would silently drop the second effect every time a preset went through its own decoder. Present-but-empty is a cleared stack rather than a missing key, which is why this one field cannot use the tolerant helper: that helper cannot tell absent from empty. And the flat keys are still **written**, mirroring slot 0, so a preset exported from this build still loads its primary effect in a build that predates the stack — shared presets are how a community forms around this (§5.5), and one that reads as blank in an older build is a worse failure than one that arrives with an effect missing.

**In the interface it is one menu, not a second catalogue.** The grid is how a look is browsed; the second slot is a modifier on a look already chosen, so it is a `Then also` menu that appears only once there is something to stack onto, with its own intensity beneath it. Both surfaces carry the menu; the intensity sliders live in the main window, exactly as the first slot's already does.

### 5.30 Style that moves with your voice

An effect that pulses when you speak, off by default. The microphone level PRISM already publishes for the meter (§5.17) drives the style intensity, so a Twirl breathes with a sentence instead of sitting at a constant.

| Property | Specification |
|---|---|
| Source | `InputLevelMailbox` — the same lock-free scalar the meter reads |
| Sampling | once per frame, on the frame queue: one acquire-load |
| Staleness | a publish counter that has not moved for 100 ms reads as **silence** |
| Off air | muted, or stood down for clip audio (§5.3), reads as **silence** |
| Envelope | attack 60 ms, release 350 ms, stepped on the frame clock |
| Opt-in | **per slot** (§5.29); a stack can have one effect breathing over one that holds still |
| Depth | **one** control for the whole stack, 0…1, default 0.7 |
| Mapping | `intensity × (1 − depth + depth × envelope)` |
| Default | off, and the depth below 1 so a silent room still shows the effect |

**Neither thread waits for the other, and that is the whole data path.** The RT capture callback already publishes one packed word per 21 ms window through a release-store; the frame path takes one acquire-load of it. No queue, no callback, no allocation, nothing the audio thread can block on and nothing the frame queue can block on. The level arrives through a closure the stage samples, so the pipeline layer never learns that a capture session exists.

**The envelope is the difference between an effect and a fault.** A raw RMS window lands about 47 times a second and jumps by half its range between two of them; driving a warp straight off it looks like a broken cable. Attack fast enough to arrive with the word, release slow enough to ride over the consonant gaps inside it — the asymmetry is the musicality, and it is the shape a compressor's envelope has for the same reason. One frame may only advance the envelope by 100 ms, so a nap does not put a full-strength pulse on the first frame back; a gap longer than half a second resets it outright, alongside the trail history it already resets.

**Depth is one number because it is one question** (§8.7): "how much does my voice move the picture". It sits below 1 by default so silence dims the effect rather than removing it — an audio-reactive style that vanished between sentences would read as a dropout.

**Silence is the answer to every question the mailbox cannot answer.** A mailbox has no decay: when the RT callback stops publishing — capture stopped, the meter disarmed, the device unplugged — the cell holds the last word spoken for the life of the process. Read raw, that pins the effect at the loudness it was disarmed at and the picture stays warped forever, which is a fault the call can see. So the frame side reads the publish counter as well as the value and treats a counter that has not moved for 100 ms as silence, releasing the envelope. 100 ms is about five missed windows: long enough that a 60 fps chain sampling a 47 Hz mailbox never reads a live microphone as a pause, short enough that nobody could call the effect stuck.

**A muted microphone drives nothing.** §5.17 takes the meter from the raw device slice, ahead of the mute and the suppression, precisely so "is my microphone hearing me" stays answerable off air — and an effect driven from that same reading would put every syllable of a private aside onto the picture and tell the meeting the user is talking while muted. The call cannot hear them, so the picture does not react to them. The same applies while clip audio owns the ring (§5.3): what the call is hearing is not the microphone.

**It is an audience for the level meter, and the only one with no surface on screen.** §5.17 arms the mailbox on demand: a preview showing the bar, or the muted-and-talking watch. An audio-reactive style joins that list, because an unarmed mailbox publishes nothing and a style set to pulse would simply hold still — which looks exactly like a broken effect. Turning the switch on arms it immediately rather than at the next reconciliation, since the whole visible consequence is that the picture starts moving.

No kernel knows any of this exists: it is a multiply into `PRISMStyleParams.intensity` at encode time.

### 5.31 Gesture triggers

Hand poses as a second hotkey surface, for the moments when the keyboard is not where your hands are. **Ships off, and ships with nothing bound.**

| Property | Specification |
|---|---|
| Detector | `VNDetectHumanHandPoseRequest`, up to two hands, on a 960×540 downsample |
| Scheduling | a `VisionCoordinator` modality of its own at cadence 3 (§5.23) |
| Demand | only while the switch is on **and** a pose is bound to something, **and** the camera is the source |
| Poses | open palm, Victory, fist |
| Actions | nothing / mute / freeze / still / replay / panic — **all `.none` by default** |
| Confidence floor | 0.5–1, default **0.85** |
| Dwell | 0.3–3 s, default **0.8 s**; panic never less than **1.5 s** |
| Cooldown | 0.5–10 s, default **2 s** |
| Debounce | one held pose is one action, until the pose is seen to end |

**The whole feature lives or dies on false positives, and the failure is not symmetric.** A gesture that does not fire costs a raised hand and a second try. A gesture that fires by itself mutes a call nobody asked to mute. People talk with their hands: an open palm is what you make while explaining something, and a fist is what a hand resting on a mouse looks like from a webcam — both of those happen while the user is saying words they expect to be heard. So four independent rules have to agree before anything happens, and every one of them is asymmetric in the same direction as §5.28's hysteresis.

- **The confidence floor** is high on purpose. Below it there is not a weak sighting of a pose; there is no observation, so it cannot accumulate a dwell however long the hand stays there, and one flaky reading mid-hold restarts the hold rather than being smoothed over.
- **The dwell** is what talking hands cannot pass. Gesticulation is never still for eight tenths of a second; a hand raised to do something is.
- **The debounce** makes one held pose one action. After firing, the recogniser latches until it has seen the pose actually end — a palm held for four seconds is one mute, not forty.
- **The cooldown** is refractory across every pose, so a gesture cannot be followed instantly by another one, including the one that would undo it. That is how a flickering recogniser becomes a strobing mute.

And the clock advances only on observations, capped at a quarter second each, for the reason §5.28's does: a gap in the stream is not evidence that a hand was held through it. Ten minutes between two sightings does not satisfy an eight-tenths-of-a-second hold.

**Panic is bound to nothing, and it is guarded twice.** A hand is exactly what is free at the moment panic is wanted, so refusing to offer it would be its own kind of failure — but a camera that blanks itself because somebody gestured while talking is the worst thing this app could do. So: nothing is bound out of the box, which means the master switch alone cannot arm anything at all; and once somebody binds it deliberately, panic takes a hold of its own — 1.5 s, which the general dwell slider cannot lower, because 0.3 s is inside the range a hand passing the lens occupies. A second slider for panic's dwell was the alternative and is the wrong shape (§8.7): nobody has an opinion about it that is not already expressed by whether they bound it at all.

**The pose classifier names three shapes and refuses everything else.** Each finger is read radially — the tip further from the wrist than its middle joint means extended, back inside it means folded — which is invariant to how the hand is rolled in frame, the one thing a webcam guarantees will vary. Between the two ratios a finger is not read at all, so a hand in transit cannot resolve into a pose on its way past, and a partly seen hand is not a pose at all: guessing the missing finger is exactly how a wave becomes a Victory. The thumb is deliberately ignored — it sits nearly as far from the wrist folded as extended, and none of the three poses needs it. Nil is by far the commonest answer and is the point: a classifier that always names its closest match turns every gesticulation into an input.

**It runs against the camera frame, not the composed picture.** A virtual background erases the hand outright, a crop can put it outside the frame, and a freeze would hold a gesture on screen forever — so a recogniser reading the finished picture would fail exactly when the effects are on, which is when a keyboard-free control is most wanted. Same reason §5.28's detector reads `source`.

**Cadence 3, and that number is the bargain with eye contact.** The `hands` modality has existed since §5.23's schedule replaced the two hard-coded parities, deliberately unregistered, with a test asserting that an unregistered modality never runs however loudly it is demanded — so this feature arrives as a registration and one demand closure rather than as a change to the schedule. Three rather than the face's two because a gesture is held for the better part of a second and only has to be *seen* several times, while the eye-contact warp is applied to every frame and slips visibly the moment its landmarks age. Even at one frame in five under full contention that is six sightings inside the shortest hold the settings allow.

**Every gesture says so out loud.** A chord has a key under it and a tile has a click; a hand in the air has neither, so a gesture that acted silently would be indistinguishable from the app doing something by itself. Every firing names the pose and the action in the notice row and in the §5.21 session log, and the Gestures pane shows the last one.


### 5.32 Meeting transcript

What was said, written down on this Mac.

| Property | Specification |
|---|---|
| Mechanism | WhisperKit (Core ML) running locally; one model downloaded once |
| Sources | the microphone always; the far end optionally, via an audio-only `SCStream` |
| Signal | tapped after conversion to 48 kHz, **before** §5.17 cleanup and §5.13 effects |
| Off air | nothing is transcribed while muted — the tap receives nothing at all |
| Storage | `~/Library/Application Support/PRISM/Meetings`; the transcript only, never audio |
| Network | none, for the transcript. Notes are a separate, user-pressed action |
| Persistence | `MeetingSettings` in `StudioSettings`, never in a preset |
| Trigger | the Meeting section, the Meeting pane, ⌃⌥⌘M, or explicit acceptance of a detected-call notification |
| Default | off; far end off; a stock build downloads nothing |

**Nothing is transcribed while you are muted, and that is architecture rather than policy.** The transcription tap sits after the mute and suppression early returns in the RT callback, so a muted microphone does not deliver silence to the recogniser — it delivers nothing, and there is no buffer holding what was said before. A promise implemented as a check somewhere is a promise that survives until somebody moves the check. This one is a consequence of where three lines sit.

**Meeting detection may ask and may never consent for the user.** A supported
meeting app beginning to consume PRISM Camera is the strong signal; PRISM
Microphone in use while a supported meeting app is frontmost is the
camera-off fallback. Zoom, FaceTime and Teams are named directly. Browser
calls are named by browser because PRISM does not inspect tab URLs or titles.
The notification has `Start Meeting Mode` and `Not Now` actions, fires once
per observed call, and starts nothing unless the first action is pressed.

**The transcript is tapped before the voice changer, and the mic check is tapped after it, for opposite reasons.** §5.13 exists to play back exactly what the call receives, so its tap belongs at the end of the chain. A recogniser wants the opposite: Chipmunk, Robot and Telephone make speech unintelligible, and a transcript that changed because somebody picked a voice effect would be a transcript of the effect. It is also ahead of §5.17 cleanup, so a noise gate cannot clip a word onset. Whisper is robust to a noisy room; it is not robust to a ring modulator.

**Two streams beat one model.** "Who said what" is normally a diarization problem — cluster the voices in a mixed recording and hope. PRISM does not have a mixed recording: it owns the microphone and captures the far end separately, so the physical origin of every word is known before any model sees it. The near side is labelled *You* and the far side gets whatever the user calls them, and on a 1:1 call that is the whole of speaker attribution, exactly right, for free. This is the one place where PRISM's architecture — a resident agent that already sits on the microphone — makes something cheap that is expensive for everybody else.

**The far end is ScreenCaptureKit, and that is a floor decision rather than a preference.** A Core Audio process tap is the better API in every respect that matters, and it is macOS 14.4 in practice. PRISM's floor is 13.0, and the people most likely to be on Ventura are the ones already running a camera extension and a HAL plug-in. So: an audio-only `SCStream`, with no `.screen` output registered and nothing ever decoded, and the tap path as a runtime-gated fast path later. macOS calls the permission Screen Recording; PRISM captures no pixels for it, and the pane says so rather than letting the name speak for itself.

**Silence is not transcribed, because a model asked about silence answers anyway.** Whisper was trained on subtitles and hallucinates their furniture — "Thank you.", subtitle credits, a phrase repeated until the chunk is full. The cheapest defence by a wide margin is not to ask: an RMS gate runs *before* the recogniser, and a sanitizer catches what still gets through. The gate's threshold is calibrated rather than guessed, and it deliberately does not drop "yes", "no" or "ok" — those are real one-word answers, and a filter that eats the answer is worse than no filter.

**A gap is a gap.** When the microphone goes off air, or the tap ring laps because the reader stalled, the buffer is broken rather than stitched. Two halves of a sentence minutes apart, joined, is a sentence nobody said — and it would be indistinguishable from one they did.

**A row of the session log may say that PRISM was transcribing. It may never say what it heard.** §5.21's redaction rule is absolute here and gets its own test: a transcript is the most sensitive string this application will ever hold, and an exported log is a plain-text file people attach to support threads. The log names the fact, the duration, and the application being listened to — all things the pickers already show. Nothing else.

**Notes are the one moment this feature uses the network, and only because a button was pressed.** The transcript is written and kept locally with no provider configured at all; *Write notes* sends it to whichever provider the user chose (§5.33), once, and puts the result in a markdown file beside the transcript. Where the transcript fits in one pass it goes in one pass, because every seam in a map-reduce is a place a decision gets summarised twice or missed. The action-items table carries a quoted line and its timestamp for every row, which is the cheapest grounding measure available: a model made to cite the line cannot invent the owner.

**Audio is never written to disk, under any setting.** There is no switch for this and no code path to it. A recording of a conversation is a different object with a different consent story, and this feature does not need one to do its job.


### 5.33 Meeting assistant

An answer only you can see, while you are still in the conversation.

| Property | Specification |
|---|---|
| Mechanism | a floating `NSPanel` with `sharingType = .none`, as §5.27 |
| Trigger | ⌃⌥⌘A, push-to-ask. Detection lights a control and never sends anything — except under §5.34, which is off by default |
| Provider | Claude, Ollama on this Mac, or any OpenAI-compatible endpoint; none by default |
| Sent | the last *n* transcript lines, the About-you text, and the question. Nothing else |
| Key storage | Keychain, never `StudioSettings`, never an exported preset |
| Persistence | `AssistantSettings` in `StudioSettings`; the open state is never restored |
| Default | off, with no provider |

**Push-to-ask, because every project that shipped automatic answering removed it.** The detector runs continuously over the far-end transcript and its entire output is a highlight on a control. cheating-daddy deleted its five-second capture loop and left the dead parameter behind; Amurex, the only fully automatic one, needed a server-side rate cap and a two-field guard to make the noise bearable. An assistant that answers unprompted talks over the meeting. The user presses the key. Live insights (§5.34) is the one opt-in exception, and it is a separate mode with a separate switch — built out of the controls those projects added afterwards — so that this one never grows an automatic branch.

**A typed question travels with the conversation; a detected one travels alone.** This asymmetry is the highest-leverage idea in the design and it is counter-intuitive. When the user types, the question is *about* the discussion and the rolling transcript is context. When the far end asked something specific and PRISM already knows what it was, sending the transcript alongside it dilutes the answer rather than improving it, so the detected path sends the question and the About-you block and nothing else.

**`sharingType = .none` is a real defence against one kind of capture and no defence against another, and the pane says which.** It is honoured by window-list capture — the mode Zoom, Teams and PRISM's own screen source use — and that is what keeps the panel out of an ordinary screen share. It is not honoured by a capture path that composites the framebuffer, and Apple has stated on the record that no public API prevents screen capture. PRISM cannot fix that. What it can do is not claim otherwise: the Assistant pane states the limit in those terms and presents the chord as the reliable way to put the panel away. §5.27 makes a stronger-sounding promise about the prompter; the difference is that an answer the user is about to say out loud is worth being more careful about than a script they wrote.

**The chord never dismisses.** ⌃⌥⌘A opens the panel if it is closed and otherwise asks, for §5.27's reason: the key you reach for mid-sentence means "answer this", never "make it disappear", and dismissing something you cannot see you dismissed is unrecoverable.

**Nothing about it opens itself.** `isEnabled` is hard-coded out of the decoder rather than merely defaulting off. PRISM launches at login for most people, and a panel that restored itself would put yesterday's answer over whatever they actually opened their Mac to do — floating, on every space.

**The key is not a setting.** `StudioSettings` is JSON in a plist that any process running as this user can read, and it is what gets exported with a preset and attached to a support thread. The API key lives in the data-protection Keychain, is read once at launch because every `SecItem` call blocks the calling thread, and never reaches a view.

**A stalled provider is a failure, not a state.** A stream that stops mid-answer without closing leaves the panel waiting forever and wedges every later question until the app is relaunched — glass has exactly this bug. A watchdog rearmed on every token turns it into a sentence the user can read.


### 5.34 Live insights

Cards that appear on the assistant's panel while the call goes on, without a key being pressed.

| Property | Specification |
|---|---|
| Mechanism | `InsightSession`: measures the transcript, decides against `InsightPolicy`, asks once, filters what comes back |
| Trigger | a question from the other side, or enough new settled conversation and a pause — never mid-sentence, never inside a cooldown, never past the ceiling |
| Sent | the last *n* transcript lines, the About-you text, the kinds asked for, the titles of cards already shown, and the detected question when there is one |
| Reply | JSON: zero to two cards, each a kind, a title, a body, and the transcript line that prompted it |
| Armed by | the mode switch **and** the panel up with a provider **and** a meeting listening; any one off, nothing is sent |
| Pace | `quiet` (questions only), `balanced`, `eager` — one `InsightPolicy` each: word floor, quiet gap, cooldown, requests per ten minutes |
| Persistence | `liveInsights`, `insightPace`, `insightKinds` in `AssistantSettings`; the mode is a preference and is restored, the panel never is |
| Surfaces | the Assistant pane, the panel's hover strip, the popover's Meeting section, and ⌃⌥⌘I |
| Default | off |

**This is the one thing in PRISM that sends without a key being pressed, and it has its own switch because of that.** §5.33's finding stands — every open-source project that shipped automatic answering took it back out — and this mode does not revise it. It is built out of the controls those projects added afterwards: a floor on how much new material is worth a request, a quiet gap so the request lands between turns rather than inside one, a cooldown, and a hard ceiling per rolling ten minutes. The numbers live in one struct per pace, and the trigger is a pure function over a snapshot so that every rule has a test that runs in milliseconds against a fake clock.

**The model is told that nothing is the usual answer, and then it is not believed.** The schema permits an empty list and the prompt asks for one by default; what does come back is filtered again here, in code and cheapest first: the kinds the user wants, the quote that has to be real, the titles already shown this meeting, and the titles the user dismissed. A term defined once stays defined; a dismissed card stays dismissed. Two cards per reply at most, six on the panel at most, and an unpinned card leaves after two minutes — the panel is about the current minute of the call, not the whole of it. `fact` is off by default: it is the one kind no project in the open-source record has shipped and measured, and the one most likely to be a confident invention about the user's own company.

**Every card quotes the line that prompted it, and the quote is checked.** §5.32's action-item rule, for the same reason: a model made to cite the line cannot invent the card, and the quote lets the user check it in a glance without leaving the panel. The check is not left to the prompt — a card whose quote is not mostly present in the window the model was actually sent is dropped before it is shown.

**A detected question is a trigger here and a light everywhere else.** §5.33's detector is reused unchanged; what changes is what is wired to it. In this mode the newest settled far-end line that reads as a complete question goes out after a short gap and a short cooldown, without waiting for the word floor — the question arrived complete, and the clock is running on the user's reply. The same question is never asked about twice; a question the user has already started answering (a settled reply of eight words or more) is not asked about at all; and a question that has waited out a cooldown or a request in flight for more than twelve seconds is dropped rather than answered late.

**Turning it on turns on what it needs.** §8.7: the chord shows the panel if it is down and starts listening if it is not running, because a chord that did nothing until two other switches were found is a chord nobody presses twice. Turning it off leaves both alone — the transcript is still wanted for the notes, and a panel the user may be reading an answer on is not this switch's to close. It is refused, with the reason in the warning row, when there is no provider: a mode that sends on its own must not be switchable into a state where every attempt fails quietly.

**The panel gates the sending.** Close the panel and the mode disarms and its cards go; reopen it and the mode is back. Nothing is sent on behalf of a screen nobody is looking at.

**What it says about itself is conditional.** §5.33's "never sent on its own" is true while this is off and false while it is on, so every surface that says it — the pane's detection caption, the privacy inventory, the popover's caption — says which, and the inventory names the cadence and the ceiling in numbers. The panel's live row always carries the request count, because a panel that sends on its own and says nothing about it reads as broken. A row of the session log says the mode went on or off and which provider, and one more at the end of the meeting says how many requests, cards and dismissals there were — counts only, and never a word of what a card said. Those counts are the only way the defaults will ever be tuned against real use.


---

## 6. Latency requirements

Zero latency is not physically available. The floor is one camera frame interval plus one GPU pass plus one IPC hop. The requirement is that PRISM adds nothing perceptible and never drops a frame.

### Video

Fixed costs, independent of format:

| Stage | Budget |
|---|---|
| Capture callback → Metal texture | ≤ 1.0ms |
| Sink push → source emit | ≤ 3.0ms |

Variable cost — the effects chain — is bounded by the policy table in §3.4. Total added latency is therefore:

```
added_latency = 4.0ms + effects_gpu_time
```

Resulting ceilings at the default Balanced policy: **8.7ms** at 60fps, **17.3ms** at 30fps, **20.7ms** at 24fps. At Lowest latency: **5.3ms** at 60fps, **7.7ms** at 30fps.

Higher frame rates yield lower total added latency but a tighter effects budget. Say this plainly in the UI rather than making users infer it — see §8.3.

### Audio

| Stage | Budget |
|---|---|
| HAL input buffer, 256 frames @ 48kHz | 5.3ms |
| Processing | ≤ 1.0ms |
| Ring traversal | 1 client buffer period |
| **Total added** | **≤ 12.0ms** |

The buffer and the ring alone spend ~10.7ms of that, so the remaining budget is ~1.3ms and it is *not* enough to buy lookahead. Every always-available audio stage is therefore zero-latency by construction: mute, the input meter and the whole cleanup chain (§5.17) add nothing. The one exception is opt-in and declared — a pitched voice effect (§5.13) adds ~21ms, reported through `addedLatencyMs` and visible in the meter, and it disappears the moment the effect is off.

### A/V sync

Video and audio take different paths, so drift is structural. Requirement: `|video added latency − audio added latency| ≤ 15ms`. Measure it in the harness; do not assume it. Lip-sync error becomes visible around 45ms.

Freeze and clip playback intentionally break sync. Expected, not a bug.

### Reporting

Measured latency is a first-class output of the app, not diagnostics. `LatencyMonitor` publishes at 4Hz:

```swift
struct LatencyReport {
    let captureMs: Double
    let stages: [StageID: Double]     // GPU ms per enabled stage
    let handoffMs: Double             // sink push → source emit
    let totalAddedMs: Double
    let budgetMs: Double              // current policy budget
    let frameIntervalMs: Double
    let droppedFrames: Int            // since session start
    let audioAddedMs: Double
    let syncSkewMs: Double            // video − audio
}
```

Every field is surfaced in the UI per §8.3. Users cannot make sensible trade-offs against a number they can't see.

### Hard SLO

Zero dropped frames at 1080p30 with the full effects chain at Balanced policy, on an M-series Mac, sustained for 60 minutes. Verified separately at 1080p60 and 4K30.

---

## 7. Non-functional requirements

| Requirement | Value |
|---|---|
| Idle CPU, popover closed, pass-through, 1080p30 | < 3% |
| Resident memory, 720p and below | < 250MB, enforced by `ResourceGovernor` (§5.23) |
| Resident memory, 1080p, nothing else armed | < 250MB, at freeze's floor — 242 MB planned |
| Resident memory, 1080p with a screen source, an armed replay buffer, a staged draft, or a camera whose native format is larger than the call | over the ceiling; the plan reports the figure and takes freeze's floor |
| Resident memory, 4K | over the ceiling; the plan reports the figure |
| Time from login to first valid virtual camera frame | < 2s |
| Launch at login | `SMAppService.mainApp`, default enabled, user-disableable |
| Network access | **None for PRISM's own purposes.** No analytics, no telemetry, no crash reporting, no update check — unchanged, and not going to change. Two user-initiated exceptions exist (§5.32, §5.33), confined to one file. With no AI provider configured — the default — PRISM makes no connections at all. |

**The memory ceiling is a policy, not a hope.** It was written as a number and nothing enforced it, so the elastic allocations grew past it independently and nobody could have said by how much. §5.23 is the enforcement: one function decides every depth from the negotiated format, the sum is checked in `ResourceGovernorTests`, and the formats that cannot be made to fit are the ones the table above now admits to. 4K30's output pool and working intermediates measured 126.6 MB before freeze holds a single frame; there is no depth that redeems that, and a requirement quietly false for one published format is worse than one that names it.

**And the sum has to contain everything, or it is not enforcement.** For a while it did not: the rolling replay buffer (~58 MB at 1080p on the shipped defaults), the draft chain (~119 MB while a preview surface has an edit staged), Overlay's and Retouch's stage-private scratch, and the working set generally — priced at the negotiated output while every ring slot, intermediate and stage texture is allocated at the *source's* size, which §3.2 deliberately picks larger. All four are counted now (§5.23). The arithmetic that follows is the honest one, and it moved rows in the table above rather than being tuned until they held: 1080p fits bare, at freeze's floor, and nothing more than that fits alongside it. A requirement that only held because four allocations were missing from the sum was the failure this section exists to prevent.

**Sleep/wake** is the single most common real-world failure for apps in this category. `AVCaptureSession` and the HAL input unit must both reestablish automatically on `NSWorkspace.didWakeNotification`, with a retry schedule of 0.5s / 1s / 2s / 4s. Treat this as a first-class test case at M7, not an edge case.

**Crash isolation.** If PRISM.app crashes: the camera extension continues emitting the placeholder card, and the audio plug-in continues emitting silence. Neither client apps nor `coreaudiod` may be taken down with it. The `producerAlive` flag and heartbeat in §4.3 exist for exactly this.

**No network access PRISM did not ask you about** is a verifiable property in an open-source repo and is the strongest trust argument PRISM has for an app that sits on your camera and microphone. Do not add a "check for updates" feature.

The property was once simply "none", and §5.32 and §5.33 changed it. It is worth being exact about how, because a promise that quietly becomes a smaller promise is worth less than one that never existed.

What has not changed: PRISM sends nothing on its own behalf. No analytics, no telemetry, no crash reporting, no update check, no beacon at launch, nothing on a timer. A stock build, which ships with no AI provider configured, opens no sockets at all — transcription (§5.32) runs entirely on this Mac against a model on this Mac.

What is new: a user may point PRISM at an AI provider, and PRISM will then send that provider what the user asked it to send — a transcript when they press *Write notes*, a question when they press the ask chord, and nothing otherwise. There is one further request: the speech model itself, downloaded once from Hugging Face after the user confirms the size.

**Every byte leaves through one file**, `PRISM/AI/LLM/LLMTransport.swift`, at about 150 lines and written to be read in full before it is trusted. That is the whole of the enforcement, and CI is what keeps it true. The source grep that used to scan every compiled directory still does, with exactly one path allowlisted, so a networking call added anywhere else — `PRISMShared` included, where shared C on the RT audio path is compiled into the app, the tests and the plug-in and a BSD socket would link nothing but libSystem — still fails the build. A second step asserts that the allowlisted file names no endpoint outside the two hosts PRISM knows about. A third greps the whole tree for telemetry-shaped symbols.

That third check is **new**. The amendment made the guarantee narrower in exactly one file and stronger everywhere else, which is the only shape of amendment worth accepting.

The linker tripwire (`otool -L`) is **unchanged**, and that was a surprise worth recording. It was expected to need narrowing — a model download and HTTPS requests to a provider looked certain to pull in CFNetwork — but measured on the built binary, neither CFNetwork nor `Network.framework` links, because `URLSession` is reached through Foundation and the speech package pulls in nothing else. So the check stayed as it was. If a later change does make CFNetwork link, this failing is the correct outcome: it means something has started reaching the network by a route the source allowlist cannot see, which is exactly what the linker check is for.

---

## 8. Interface

**Design direction: this should read as an app Apple shipped.** Specifically, it should feel like Control Center — system materials, SF Symbols, semantic colors, standard metrics. Do not introduce a custom brand palette, custom typefaces, or non-standard corner radii. The discipline here is restraint: an app that lives in the menu bar and touches your camera should look like part of the operating system, not like something bolted onto it.

### 8.1 Design tokens

```swift
// DesignSystem.swift
enum Metrics {
    static let popoverWidth: CGFloat  = 320
    static let gutter: CGFloat        = 16   // popover horizontal inset
    static let sectionGap: CGFloat    = 16
    static let metaGap: CGFloat       = 6    // between preview/status/meter/in-use
    static let itemGap: CGFloat       = 8
    static let cardRadius: CGFloat    = 10
    static let tileRadius: CGFloat    = 10
    static let controlRadius: CGFloat = 6
    static let tileHeight: CGFloat    = 64
}
```

**Color.** Semantic system colors only: `.primary`, `.secondary`, `.tertiary`, `Color.accentColor`, `.red` for error states. Background is the material `MenuBarExtra` provides — do not paint over it. Light and dark mode both supported automatically; do not hardcode either.

**Typography.** System font (SF Pro) exclusively, via Dynamic Type styles, never fixed point sizes:

| Role | Style |
|---|---|
| Section headers | `.headline` (13pt semibold) |
| Body, labels | `.body` (13pt) |
| Status line, metadata | `.caption` (11pt), `.secondary` |
| Numeric readouts (fps, ms) | `.caption` with `.monospacedDigit()` |

**Iconography.** SF Symbols only. `pause.fill`, `mic.slash.fill`, `film`, `camera.filters`, `video`, `exclamationmark.triangle.fill`.

**Motion.** `.easeOut` at 0.2s for state changes; `.spring(response: 0.3, dampingFraction: 0.85)` for the popover. Gate everything behind `@Environment(\.accessibilityReduceMotion)`.

### 8.2 Menu bar item

`MenuBarExtra` with `.menuBarExtraStyle(.window)`. Glyph is an 18×18pt template PDF in `Assets.xcassets` marked **Render As: Template Image** so it inherits menu bar tinting and dark mode automatically.

| State | Glyph |
|---|---|
| Not in use by any client | Outline prism, 40% opacity |
| Live, pass-through | Outline prism, full opacity |
| Effects active | Filled prism |
| Replaying | Filled prism with rewind badge |
| Away | Filled prism with moon badge |
| Bad connection | Filled prism with wifi badge |
| Lagging | Filled prism with hourglass badge |
| Frozen | Filled prism with pause bar |
| Muted while talking | Filled prism with slash, `.red` tint |
| Muted | Filled prism with slash |
| Sharing a screen | Filled prism with display badge |
| Panic engaged | Filled prism with raised-hand badge, `.red` tint |
| Error | Filled prism, `.red` tint |

Precedence: error > panicked > away > bad connection > lagging > replaying > frozen > muted while talking > muted > sharing a screen > effects > live > idle.

The substitution states outrank the effect states because forgetting you are in one is the damaging failure this app can produce. Replay, away and panic each get their own glyph rather than folding into frozen, because *"why can nobody see me moving"* has to be answerable at a glance. Bad connection outranks lagging because when the switch engaged the delay itself, the delay is part of the stunt — the badge names what the user engaged. Talking while muted (§5.17) outranks plain muted, and is the only non-error state to spend the red, because it is the one state the user is provably unaware of — they are talking. Sharing a screen sits below the mute states, since everyone in the call can already see the screen is up, but above effects, because it says *what* the camera publishes rather than how.

There is deliberately no recording state: writing a file changes nothing on air, and this ladder ranks what is on air.

### 8.3 Popover layout

320pt wide, height fits content. Sections below the preview are collapsible and remember their state.

```
┌────────────────────────────────────┐
│  ╔══════════════════════════════╗  │  Preview, 288×162 (16:9)
│  ║   live output preview        ║  │  10pt corner radius
│  ╚══════════════════════════════╝  │
│  1080p · 30 fps  ▓▓▓▓░░░  7.2/13.3 │  status + meter share a row, §8.6
│  In use by Zoom, FaceTime          │  .caption, .secondary
│                                    │
│  ┌────────┐ ┌────────┐ ┌────────┐  │  Control tiles, 64pt tall
│  │ Freeze │ │  Mute  │ │  Clip  │  │  equal width, 8pt gaps
│  └────────┘ └────────┘ └────────┘  │
│  ┌─────┐ ┌─────┐ ┌─────┐ ┌─────┐   │  Moments tiles, one full row
│  │Replay││Away ││Panic││ Lag │     │  never a part-filled row
│  └─────┘ └─────┘ └─────┘ └─────┘   │
│  ┌──────────────┐ ┌──────────────┐ │  Capture tiles, §5.15/§5.16
│  │    Still     │ │  Save clip   │ │
│  └──────────────┘ └──────────────┘ │
│  A saved clip is the raw camera —  │  .caption2 — always, not only
│  no effects, no sound.             │  when something is being hidden
│                                    │
│  ● Natural  Meeting  Studio  ＋     │  preset bar, horizontal scroll
│                                    │
│  Framing                      ⌄    │
│  ┌──────────────────────────────┐  │
│  │ Zoom      ──●──────    1.4×  │  │
│  │ Rotate    ────●────      0°  │  │
│  │ Flip output          ●       │  │
│  │   Others will see this       │  │  .caption2, .secondary — only
│  │   flipped                    │  │  while the switch is on
│  │ Auto-frame           ○       │  │
│  └──────────────────────────────┘  │
│                                    │
│  Effects                      ⌄    │
│  ┌──────────────────────────────┐  │
│  │ Adjust              ● 0.4ms  │  │  per-stage cost, .caption2
│  │ LUT          Warm ⌄ ● 0.9ms  │  │
│  │ Style       Twirl ⌄ ● 1.1ms  │  │
│  │ Blur      Balanced ⌄ ○ 5.8ms │  │
│  └──────────────────────────────┘  │
│                                    │
│  Format                       ⌄    │
│  ┌──────────────────────────────┐  │
│  │ Resolution      1920×1080 ⌄  │  │
│  │ Frame rate          30 fps ⌄ │  │
│  │ Latency        Balanced   ⌄  │  │
│  └──────────────────────────────┘  │
│                                    │
│  Camera        FaceTime HD  ⌄      │  Picker, .menu style
│  Microphone    MacBook Mic  ⌄      │
│                                    │
│  ⚙︎                            ✕   │  Settings, Quit
└────────────────────────────────────┘
```

**Density rules.** The preview, status line, latency meter and in-use line
are metadata about one output, so they are separated by `metaGap`, not
`sectionGap` — four caption rows floating 16pt apart read as four sections
that happen to be short. The status line and the meter share a row whenever
they are adjacent, and the status line prints added latency only when the
meter is hidden: the same number twice, one line apart, is clutter rather
than reassurance. A lag callout (§5.12) takes the status line back to a full
row of its own.

Tile rows are always full. Three tiles across at 320pt, or four when a module
has four — never a row with one tile and two empty slots.

Explanatory captions appear when the thing they explain is on. "Others will
see this flipped" under an off switch is noise on every open; as a tooltip
on the switch it is still discoverable before the fact.

The Capture caption is the one standing exception, and §5.15 is why: what a
saved clip contains has to be legible *before* the file exists, so the line
is there on every open and only gets louder when something on air is
actually hiding a room.

Height fits content up to the visible screen height, then scrolls. A dropdown
whose bottom is off the display is worse than one that scrolls.

**Progressive disclosure is what keeps this from reading as a control panel.** Default state on first launch: preview, status, tiles, and presets expanded; Framing, Effects, and Format collapsed. A user who only wants freeze and mute never sees a slider. A user who wants to rebuild their camera has everything one disclosure away. Deeper controls — pan, crop aspect, orientation, per-adjustment sliders, published format set editing, shortcut binding (§5.19), external control (§5.20), session diagnostics (§5.21) — live in Settings and the main window, not the popover. None of the three is a live control over the picture, so none of them is worth a row in a dropdown you open to freeze your camera.

Every slider has a discrete numeric field beside it. Option-drag gives fine adjustment; double-click resets to default.

**Preview** is the *output* — post-effects, exactly what clients see. Render from the same `MTLTexture` the pipeline already produced; do not re-render. **When the popover is closed the preview path is fully torn down: zero GPU cost, `MTKView.isPaused = true`, texture references released.**

**Control tiles** follow the Control Center pattern: rounded rect, SF Symbol above a label, `Color.accentColor` fill when active, `.quaternary` when inactive, `.primary`/`.secondary` label respectively. Tap toggles. Momentary press feedback at 0.96 scale.

**Warning row**, when present, sits directly under the status line: `exclamationmark.triangle.fill` in `.red`, message in `.caption`.

**Notice row** sits directly under the warning row and is a separate slot: a symbol naming what was noticed, message in `.caption`, and at most one button. Two slots rather than two uses of one, because a warning is a fact and a notice is a hint, and the hint must never evict the fact. Confirmations of something that went right (§5.15, §5.16) take `.green` and a Show button when they produced a file; a standing condition asking to be fixed (§5.17) takes `.orange` and the button that fixes it.

### 8.4 Copy

Sentence case throughout. Active voice. Name things by what the user controls, never by implementation.

| Situation | Text |
|---|---|
| No client using PRISM | `Not in use` |
| One or more clients | `In use by Zoom, FaceTime` |
| Effect auto-disabled | `Background blur turned off to keep video smooth` |
| Pinned chain over budget | `Effects are exceeding your latency budget` + action `Raise budget` |
| Format change with clients live | `Zoom and FaceTime will need to reselect PRISM Camera. Change anyway?` |
| After a format change | `Reselect PRISM Camera in Zoom to use the new format` |
| Auto-frame without blur | `Auto-framing uses the same subject detection as background blur, so it costs about the same` |
| Camera unplugged | `FaceTime HD Camera disconnected. Using built-in camera.` |
| Extension not approved | `Approve PRISM Camera in System Settings to continue` |
| Audio plug-in missing | `Install the audio component to use PRISM Microphone` |
| Replay/away without a buffer | `Turn on the rolling buffer to use instant replay` + action `Turn on` |
| Away armed on first use | `Rolling buffer on. The away loop needs a few seconds of video first.` |
| Away with too little buffered | `Not enough video buffered yet for an away loop` |
| Overlay layer cap reached | `PRISM composites up to 3 layers at once` |
| Eye contact searching | `Looking for your eyes…` |
| Eye contact active | `Tracking your eyes` |
| Replay on air | `Playing back at 1.5× — everyone is seeing the past right now.` |
| Away on air | `Looping. Everyone sees the idle clip until you turn this off.` |
| Lag without a buffer | `Turn on the rolling buffer to use the lag switch` + action `Turn on` |
| Lag during a replay | `Stop the replay before adding delay` |
| Lag absorbing the delay | `Holding — 1.2s of 3.0s absorbed` |
| Lag engaged | `3.0s behind live` |
| Lag catching up | `Catching up at 2×…` |
| Status line | `1080p · 30 fps` (`· +7.2 ms` only when the meter is hidden) |
| Status line while lagging | `1080p · 30 fps · +3.0 s lag` |
| Voice effect on air | `Everyone else hears it — you hear yourself unchanged.` |
| Talking while muted | `You're muted — nobody can hear you.` + action `Unmute` |
| Input meter, muted | `Muted — this is what PRISM hears, not what the call does.` |
| Mic check recording | `Say something…` |
| Mic check playing | `This is what everyone else hears.` |
| Mic check heard silence | `PRISM didn't hear anything. Check the microphone picker.` |
| Mic check while muted | `Unmute to test your voice` |
| Saved clip / still, standing line | `A saved clip is the raw camera — no effects, no sound.` |
| Saved clip with an effect hiding the room | `Right now that means the room behind background blur. PRISM will ask before it writes the file.` |
| Saved clip confirmation | `This clip will show the room behind you.` — buttons `Save the raw camera` / `Cancel` (Cancel is the default) |
| Save with the buffer off | `Turn the rolling buffer on to save the last seconds` + action `Turn it on` |
| Save with an empty buffer | `Nothing buffered to save yet` |
| Capture folder not writable | `PRISM can't write to /Volumes/Gone. Choose another folder.` + action `Choose folder` |
| Capture succeeded | `Saved PRISM 2026-08-18 at 14.23.05.png` + action `Show` |
| Rule applied a preset | `Zoom connected — Meeting preset applied` |
| A block is refusing a client | `PRISM is blocking Zoom from using PRISM Camera` + action `Unblock all` |
| In-use line while blocking | `In use by FaceTime · blocking Zoom` |
| Blocking a live client | `Zoom is using PRISM Camera right now. Block it anyway?` |
| Allow-list confirmation | `Block every app you have not allowed?` |

Errors state what happened and what to do. They do not apologize and are never vague.

### 8.5 Accessibility

Non-optional, part of the quality floor:

- VoiceOver label and value on every control. Tiles announce state: `Freeze, off, button`.
- Full keyboard navigation with visible focus rings.
- `accessibilityReduceMotion` gates all animation.
- `accessibilityReduceTransparency` swaps materials for opaque `.windowBackgroundColor`.
- `accessibilityDifferentiateWithoutColor`: active tiles gain a filled SF Symbol variant, not just an accent fill.

### 8.6 Latency meter

The meter sits on the status line — same row when both are shown, otherwise directly beneath it — and is always visible: it is the primary feedback loop for every customization decision the user makes.

- Horizontal bar, 4pt tall, 6pt radius, taking whatever content width the status line leaves.
- Fill represents `totalAddedMs / budgetMs`.
- Fill color: `.green` below 70% of budget, `.yellow` from 70–100%, `.red` above. These are the one justified exception to accent-color-only, because the meter encodes a threshold rather than a brand.
- Track is `.quaternary`.
- Trailing label: `7.2/13.3` in `.caption` `.monospacedDigit()`.
- Value is smoothed over 1 second. A meter that jitters is noise, not information.
- Hovering shows a popover breakdown: per-stage GPU ms, capture, handoff, audio added latency, A/V skew, dropped frames this session.
- Clicking opens the Format section and focuses the Latency policy control — the meter is the affordance that leads users to the setting that changes it.

`accessibilityDifferentiateWithoutColor` adds a threshold tick mark at the budget line and changes the trailing label to include `over budget` when exceeded.

Per-stage cost appears inline in the Effects list at `.caption2` `.secondary`. When a user toggles blur and watches the meter move from green to yellow, they have learned the trade-off without reading documentation. That is the entire design intent of exposing these numbers.

### 8.7 One question, one control

Background blur (§5.4) and virtual backgrounds (§5.7) are separate stages with separate costs, but they answer the same question and cannot both be true — blurring a background you have already replaced is nonsense. They are therefore presented as **one** control with modes: `Off / Blur / Colour / Image / Video`. Two independent switches would let a user construct exactly the nonsense case, and the underlying stage flags are kept consistent for them.

The same reasoning governs where things live. `Effects` holds per-pixel colour work (Adjust, LUT, Style). `Scene` holds everything that changes what is in frame besides you (Background, Overlay, Eye contact). `Moments` holds everything that changes what is on air in *time* rather than space (Replay, Away, Panic).

**Per-app rules are not part of a preset either (§5.18).** "Zoom gets the Meeting look" is a rule *about* presets; a preset that carried rules could apply itself. They persist as `AppRulesSettings` inside `StudioSettings`, and their editor lives in the main window rather than the popover — but which preset a rule put on air, and which app is being refused, show in both surfaces, because those are things happening to you rather than settings you are changing.

**Replay, away and panic settings are not part of a preset.** A preset captures a look. "How many seconds do you keep in memory" and "what does the panic key do" are not looks, and switching from Meeting to Studio must not silently rearm a hardware encoder or repoint a panic backdrop. They persist separately as `StudioSettings`.

---

## 9. Permissions and installation

Three grants, in this order:

1. **Camera and microphone TCC** for PRISM.app. Request via `AVCaptureDevice.requestAccess(for:)` on first launch.
2. **System Extension approval** for the camera extension, via `OSSystemExtensionManager.shared.submitRequest`. Sends the user to System Settings → Privacy & Security.
3. **Admin authentication** for the `.pkg` installing the audio HAL plug-in.

…and a fourth that is conditional:

4. **Screen Recording TCC**, for §5.24. Never requested at launch — the feature ships off, and a permission dialog for something nobody has asked for is how an app loses that grant for good. `CGRequestScreenCaptureAccess()` is called the first time a screen or window is chosen, and `CGPreflightScreenCaptureAccess()` reports the state after that. Unlike the other three PRISM cannot grant this by prompting: macOS only offers to open the pane, and the grant takes effect at the next launch. The copy says so.

`OnboardingView` drives these as an explicit state machine. A half-approved install produces confusing symptoms — camera works, microphone missing — so the popover shows a persistent setup banner until all of them are satisfied. Each step has its own row with a state indicator and an action button.

The screen row is the one exception to "until all of them are satisfied": it appears while something is actually asking for a screen — a screen source chosen, or a picture-in-picture layer looking at one — and goes away with it (`SetupStatus.screenRecordingNeeded`). A banner that never clears because of a feature the user has not switched on is a banner people learn to ignore, which would cost the other three rows their meaning.

Document these operational hazards in the README and surface them in-app where relevant:

- Camera extension updates frequently require a reboot to reload. Design so extension updates are rare — the extension is a relay and should almost never change.
- Major macOS updates may require re-approving extensions.
- The audio `.pkg` postinstall restarts `coreaudiod`, briefly interrupting all system audio. Warn before running.

---

## 10. Build, signing, distribution

All three components must be signed and notarized to load, including for an open-source release. Contributors building from source need their own Apple Developer Team ID and must substitute `TEAMID` in entitlements and `Info.plist` files. This is a documented friction point in every CoreMediaIO sample project and belongs at the top of the README, not buried.

**Release artifacts:**

- `PRISM.dmg` — notarized, contains PRISM.app with the camera extension embedded.
- `PRISM-Audio.pkg` — notarized, installs the HAL plug-in, postinstall restarts `coreaudiod`.

Ship a single combined `.pkg` that does both if it can be made reliable; otherwise ship the two and sequence them in onboarding.

`Tools/build_pkg.sh` and `Tools/notarize.sh` automate this. Notarization uses `notarytool` with credentials from a keychain profile, never hardcoded.

---

## 11. Milestones

Each milestone has a binary exit criterion. Do not proceed until it passes.

| # | Deliverable | Exit criterion |
|---|---|---|
| M0 | Camera extension skeleton | `PRISM Camera` appears in FaceTime and Photo Booth, showing the placeholder card |
| M1 | Video pass-through | Live camera visible in Zoom via PRISM; harness measures added latency < 12ms; **verify whether CMIO fans out one source stream to multiple simultaneous clients — test Zoom and Photo Booth reading at once before building further** |
| M2 | Menu bar shell | Popover renders per §8, live output preview, latency meter live and accurate, source pickers, launch at login, preview fully torn down when closed |
| M3 | Freeze | Freeze/unfreeze within one frame interval; sharpest-frame selection demonstrably avoids blinks; icon state correct |
| M4 | Audio plug-in | `PRISM Microphone` selectable in Zoom and QuickTime; pass-through with zero underruns over 30 minutes |
| M4.5 | Format control | All published formats negotiable from Zoom, FaceTime, QuickTime; reconnect confirmation fires correctly; physical capture format selected per §3.2 |
| M5 | Effects chain | Geometry + Adjust + LUT + blur + auto-frame functional; per-stage cost reported; degradation and pinning behave correctly under synthetic load |
| M6 | Clip playback + presets | Load, loop, scrub; clip audio routed; clean 200ms crossfade back to live; presets save, switch, bind to hotkeys, export and import as JSON |
| M7 | Hardening | Sleep/wake, hot-unplug, crash isolation, 60-minute soak at 1080p30 with zero dropped frames; repeat at 1080p60 and 4K30 |
| M8 | Release | Notarized `.dmg` and `.pkg`, onboarding flow complete, README with Team ID instructions |

M1's fan-out test is the highest-risk unknown in the project. If CMIO does not fan out, the extension design changes, so resolve it before M2.

---

## Appendix A — References

- Apple, *Creating a camera extension with Core Media I/O*
- WWDC22 session 10022, *Create camera extensions with Core Media IO*
- WWDC21 session 10190, *Create audio drivers with DriverKit* — read for the explicit guidance **not** to use it for virtual devices
- Apple Human Interface Guidelines, *Menu bar extras* and *Materials*
- `ldenoue/cameraextension` — minimal CMIO sink/source sample
- OBS Studio `mac-virtualcam` — production reference for the camera extension path
- Apple sample code: `NullAudio` AudioServerPlugIn

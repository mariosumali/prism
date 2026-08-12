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
├── PRISM.xcodeproj
├── PRISM/                          # Menu bar agent
│   ├── PRISMApp.swift              # @main, MenuBarExtra
│   ├── AppState.swift              # ObservableObject, single source of truth
│   ├── Capture/
│   │   ├── CameraCapture.swift     # AVCaptureSession wrapper
│   │   ├── AudioCapture.swift      # HAL input AudioUnit wrapper
│   │   └── DeviceMonitor.swift     # hot-plug, default-device changes
│   ├── Pipeline/
│   │   ├── VideoPipeline.swift     # frame graph orchestration
│   │   ├── EffectStage.swift       # protocol
│   │   ├── Stages/                 # Geometry, Adjust, LUT, Blur, Freeze, Clip
│   │   ├── FrameRing.swift         # 500ms sharpest-frame buffer
│   │   ├── FormatManager.swift     # advertised format set, negotiation
│   │   ├── PresetStore.swift       # named user configurations
│   │   └── LatencyMonitor.swift    # per-stage timing, budget enforcement
│   ├── Sinks/
│   │   ├── CMIOSink.swift          # push frames to camera extension
│   │   └── AudioSink.swift         # write PCM to shared ring buffer
│   ├── Clip/
│   │   └── ClipPlayer.swift        # AVAssetReader-based decode
│   ├── UI/
│   │   ├── PopoverView.swift
│   │   ├── PreviewView.swift       # MTKView wrapper
│   │   ├── ControlTile.swift
│   │   ├── EffectsSection.swift
│   │   ├── FormatSection.swift     # resolution, fps, framing
│   │   ├── LatencyMeter.swift      # live readout + per-stage breakdown
│   │   ├── PresetBar.swift
│   │   ├── OnboardingView.swift
│   │   └── DesignSystem.swift      # tokens, §8.1
│   ├── System/
│   │   ├── ExtensionInstaller.swift  # OSSystemExtensionManager
│   │   ├── LoginItem.swift           # SMAppService
│   │   ├── Hotkeys.swift             # CGEventTap
│   │   └── Permissions.swift         # AVCaptureDevice authorization
│   └── Resources/
│       ├── Assets.xcassets
│       └── LUTs/                   # bundled .cube files
├── PRISMCameraExtension/
│   ├── main.swift
│   ├── ExtensionProvider.swift     # CMIOExtensionProviderSource
│   ├── DeviceSource.swift          # CMIOExtensionDeviceSource
│   ├── StreamSource.swift          # source + sink CMIOExtensionStreamSource
│   └── PlaceholderRenderer.swift   # "PRISM not running" card
├── PRISMAudioPlugIn/
│   ├── PRISM_PlugIn.cpp            # AudioServerPlugInDriverInterface
│   ├── PRISM_Device.cpp
│   ├── PRISM_Stream.cpp
│   └── Info.plist
├── PRISMShared/
│   ├── RingBuffer.h / .c           # lock-free SPSC, shared by app + plug-in
│   ├── SharedTypes.h               # SHM name, control block layout
│   └── PixelFormats.swift
├── PRISMKernels/
│   ├── LUT.metal
│   ├── Adjust.metal
│   ├── Blur.metal
│   └── Composite.metal
└── Tools/
    ├── latency_harness/            # measures end-to-end added latency
    ├── build_pkg.sh
    └── notarize.sh
```

---

## 3. Video path

### 3.1 Architecture rule

The camera extension is a dumb relay. It exposes a **sink stream** that PRISM.app writes into and a **source stream** that client apps read from, and forwards sink → source. All processing lives in PRISM.app.

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
Clip → Replay → Freeze → Eye contact → Geometry → Adjust → LUT →
Background blur → Virtual background → Overlay → Output fit → Push
```

The three substituting stages come first because they replace the source; everything downstream applies to whatever the source ends up being. They are ordered by escalating authority: a replay overrides a playing clip, and a freeze overrides a replay — each is a more deliberate "stop showing me live" than the one before it. Since every substituting stage writes the whole frame, chain position *is* precedence.

Eye contact precedes Geometry so the warp happens in the same space Vision measured its landmarks in; putting it after zoom and rotation would mean transforming every landmark through the geometry matrix just to stay aligned. Geometry precedes color so that crop and zoom do not change how a LUT reads.

Background blur, Virtual background and Overlay all consume the same person mask and composite over the finished look, so they run last. Blur and Virtual background are mutually exclusive — they answer the same question — and the UI presents them as one control (§8.7). Overlay follows Virtual background so a foreground layer sits above a replaced background.

Output fit is not a user stage — it is the final scale/letterbox into the negotiated format and always runs.

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

**Degradation.** When the 60-frame mean total GPU time exceeds the budget, disable the most expensive currently-enabled stage (`.expensive` before `.moderate` before `.cheap`; ties broken by later position in the chain), post a UI warning naming the disabled stage, and mark it `autoDisabled`. Re-enable automatically when the mean drops below 60% of budget for 120 consecutive frames.

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
Format:            32-bit float, non-interleaved
Transport type:    kAudioDeviceTransportTypeVirtual
Safety offset:     512 frames
Zero timestamp period: 4096 frames
```

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

Sample-rate conversion to 48kHz, when required, uses `AudioConverterRef` in the capture callback. v1 audio processing is pass-through plus mute only — no noise suppression, no gain, no EQ.

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
| Frame selected | **Not** the frame at click time. `FrameRing` retains the last 500ms of frames; on freeze, select the sharpest frame within the preceding 300ms, scored by Laplacian variance computed on a 128×72 downsample. |
| Audio | Continues live. Mute is a separate control with a separate hotkey (⌥⌘M). |
| Combined | ⌥⌘⇧F freezes and mutes together. |
| Response time | Freeze and unfreeze take effect within one frame interval (33.3ms) of the trigger. |
| Indicator | Menu bar glyph changes state. Mandatory — accidentally remaining frozen is the most damaging failure this app can produce. |

Audio continuing by default is deliberate: people freeze because something visual happened, not because they stopped talking.

`FrameRing` holds 15 frames at 30fps in a preallocated `CVPixelBufferPool`. Sharpness scoring runs on the GPU as part of the normal command buffer, writing a single float per frame into a small `MTLBuffer` — never as a separate synchronous pass.

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

Each stage is individually bypassable and individually pinnable (§3.4). Chain order is fixed as specified in §3.3.

### 5.5 Presets

Customizability without presets is a settings panel nobody returns to. `PresetStore` persists named configurations capturing the full pipeline state: format selection, latency policy, all stage parameters, enabled/pinned flags, source device selections.

- Ship 4 built-ins: `Natural` (pass-through), `Meeting` (mild adjust + balanced blur + auto-frame), `Studio` (LUT + adjust, no blur, quality policy), `Low latency` (geometry only, lowest policy).
- Users create, rename, reorder, delete, duplicate. Built-ins can be duplicated but not edited.
- Presets bind to optional global hotkeys.
- Switching presets crossfades over 200ms and never causes a format renegotiation — if a preset specifies a format outside the currently published set, apply everything else and show the reconnect confirmation from §3.2 for the format alone.
- Export and import as JSON so configurations are shareable. This matters for an open-source project: shared presets are how a community forms around a tool like this.

**Forward compatibility is a hard requirement, not a nicety.** Presets and the saved configuration are on-disk formats that outlive the build that wrote them. Swift's synthesised `Codable` throws on an absent key rather than falling back to a property default, so a naively-coded settings struct means every new field silently resets every existing user's entire setup on upgrade — configuration *and* every preset they had saved. Every persisted settings struct therefore decodes each field independently, at **every** nesting level. Top-level tolerance alone is not enough: version skew shows up as a partial nested object, and a tolerant parent decoding a throwing child discards the child wholesale.

### 5.6 Eye-contact correction

Redirects the subject's gaze toward the lens so they can read notes off-camera while appearing to look at whoever they are talking to.

| Property | Specification |
|---|---|
| Stage | `.gaze`, `.expensive`, before Geometry |
| Trigger | Scene section toggle, plus global hotkey ⌥⌘E |
| Detection | `VNDetectFaceLandmarksRequest`, `.constellation76Points` (pupils only exist in the 76-point constellation), on a serial queue every 2nd frame, request input capped at 720p |
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

Up to **three** placed, keyed layers over the finished frame — the stage that turns PRISM from a camera filter into a stage.

| Property | Specification |
|---|---|
| Stage | `.overlay`, `.moderate`, after virtual background |
| Sources | image (alpha honoured) or looping video |
| Keying | none, chroma, or luma |
| Placement | in front of everything, or behind the subject (mask-gated) |
| Transform | scale, offset, rotation, mirror, opacity |
| Layer cap | 3 (`OverlaySettings.maxLayers`) |

Keying is computed in YCbCr so the key colour is arbitrary rather than hard-coded green, and despill works for any hue. Despill removes what is left of the key hue from surviving pixels, so a green screen stops tinting hair and shoulders.

The layer cap is a memory constraint, not a GPU one: each layer is one compute pass, but each *video* layer carries its own decoder and frame FIFO, and resident memory is the binding limit (§7). At scale 1 a layer is fitted into the frame with its own aspect preserved — a square PNG stays square.

Layers composite bottom-up in array order. Dropping an image or video onto the Scene pane adds it as a layer, the same affordance as dropping a `.cube` to import a LUT.

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

Pressing it again restores **exactly** the prior state, including a freeze or mute the user had engaged themselves beforehand — panic tracks what it changed rather than blanket-reverting.

The backdrop swap mutates the live configuration so every surface shows what is actually on air, but the pre-panic configuration snapshot is what gets persisted and what a preset save captures. Relaunching after a panic must leave the user where they were, not stuck behind a "back in a bit" card with no memory of why.

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
| Resident memory | < 250MB |
| Time from login to first valid virtual camera frame | < 2s |
| Launch at login | `SMAppService.mainApp`, default enabled, user-disableable |
| Network access | **None.** No analytics, no telemetry, no update check. |

**Sleep/wake** is the single most common real-world failure for apps in this category. `AVCaptureSession` and the HAL input unit must both reestablish automatically on `NSWorkspace.didWakeNotification`, with a retry schedule of 0.5s / 1s / 2s / 4s. Treat this as a first-class test case at M7, not an edge case.

**Crash isolation.** If PRISM.app crashes: the camera extension continues emitting the placeholder card, and the audio plug-in continues emitting silence. Neither client apps nor `coreaudiod` may be taken down with it. The `producerAlive` flag and heartbeat in §4.3 exist for exactly this.

**No network access** is a verifiable property in an open-source repo and is the strongest trust argument PRISM has for an app that sits on your camera and microphone. Do not add a "check for updates" feature.

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
| Frozen | Filled prism with pause bar |
| Muted | Filled prism with slash |
| Panic engaged | Filled prism with raised-hand badge, `.red` tint |
| Error | Filled prism, `.red` tint |

Precedence: error > panic > away > replaying > frozen > muted > effects > live > idle.

The four substitution states outrank the effect states because forgetting you are in one is the damaging failure this app can produce. Replay, away and panic each get their own glyph rather than folding into frozen, because *"why can nobody see me moving"* has to be answerable at a glance.

### 8.3 Popover layout

320pt wide, height fits content. Sections below the preview are collapsible and remember their state.

```
┌────────────────────────────────────┐
│  ╔══════════════════════════════╗  │  Preview, 288×162 (16:9)
│  ║   live output preview        ║  │  10pt corner radius
│  ╚══════════════════════════════╝  │
│  1080p · 30 fps · +7.2 ms          │  .caption, monospacedDigit
│  ▓▓▓▓▓▓▓▓▓▓░░░░░░░░░░  7.2/13.3    │  latency meter, §8.6
│  In use by Zoom, FaceTime          │  .caption, .secondary
│                                    │
│  ┌────────┐ ┌────────┐ ┌────────┐  │  Control tiles, 64pt tall
│  │ Freeze │ │  Mute  │ │  Clip  │  │  equal width, 8pt gaps
│  └────────┘ └────────┘ └────────┘  │
│                                    │
│  ● Natural  Meeting  Studio  ＋     │  preset bar, horizontal scroll
│                                    │
│  Framing                      ⌄    │
│  ┌──────────────────────────────┐  │
│  │ Zoom      ──●──────    1.4×  │  │
│  │ Rotate    ────●────      0°  │  │
│  │ Flip output          ○       │  │
│  │   Others will see this       │  │  .caption2, .secondary
│  │   flipped                    │  │
│  │ Auto-frame           ○       │  │
│  └──────────────────────────────┘  │
│                                    │
│  Effects                      ⌄    │
│  ┌──────────────────────────────┐  │
│  │ Adjust              ● 0.4ms  │  │  per-stage cost, .caption2
│  │ LUT          Warm ⌄ ● 0.9ms  │  │
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

**Progressive disclosure is what keeps this from reading as a control panel.** Default state on first launch: preview, status, tiles, and presets expanded; Framing, Effects, and Format collapsed. A user who only wants freeze and mute never sees a slider. A user who wants to rebuild their camera has everything one disclosure away. Deeper controls — pan, crop aspect, orientation, per-adjustment sliders, published format set editing, hotkey bindings — live in Settings, not the popover.

Every slider has a discrete numeric field beside it. Option-drag gives fine adjustment; double-click resets to default.

**Preview** is the *output* — post-effects, exactly what clients see. Render from the same `MTLTexture` the pipeline already produced; do not re-render. **When the popover is closed the preview path is fully torn down: zero GPU cost, `MTKView.isPaused = true`, texture references released.**

**Control tiles** follow the Control Center pattern: rounded rect, SF Symbol above a label, `Color.accentColor` fill when active, `.quaternary` when inactive, `.primary`/`.secondary` label respectively. Tap toggles. Momentary press feedback at 0.96 scale.

**Warning row**, when present, sits directly under the status line: `exclamationmark.triangle.fill` in `.red`, message in `.caption`.

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

Errors state what happened and what to do. They do not apologize and are never vague.

### 8.5 Accessibility

Non-optional, part of the quality floor:

- VoiceOver label and value on every control. Tiles announce state: `Freeze, off, button`.
- Full keyboard navigation with visible focus rings.
- `accessibilityReduceMotion` gates all animation.
- `accessibilityReduceTransparency` swaps materials for opaque `.windowBackgroundColor`.
- `accessibilityDifferentiateWithoutColor`: active tiles gain a filled SF Symbol variant, not just an accent fill.

### 8.6 Latency meter

The meter sits directly under the status line and is always visible — it is the primary feedback loop for every customization decision the user makes.

- Horizontal bar, 4pt tall, 6pt radius, full popover content width.
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

The same reasoning governs where things live. `Effects` holds per-pixel colour work (Adjust, LUT). `Scene` holds everything that changes what is in frame besides you (Background, Overlay, Eye contact). `Moments` holds everything that changes what is on air in *time* rather than space (Replay, Away, Panic).

**Replay, away and panic settings are not part of a preset.** A preset captures a look. "How many seconds do you keep in memory" and "what does the panic key do" are not looks, and switching from Meeting to Studio must not silently rearm a hardware encoder or repoint a panic backdrop. They persist separately as `StudioSettings`.

---

## 9. Permissions and installation

Three grants, in this order:

1. **Camera and microphone TCC** for PRISM.app. Request via `AVCaptureDevice.requestAccess(for:)` on first launch.
2. **System Extension approval** for the camera extension, via `OSSystemExtensionManager.shared.submitRequest`. Sends the user to System Settings → Privacy & Security.
3. **Admin authentication** for the `.pkg` installing the audio HAL plug-in.

`OnboardingView` drives these as an explicit state machine. A half-approved install produces confusing symptoms — camera works, microphone missing — so the popover shows a persistent setup banner until all three are satisfied. Each step has its own row with a state indicator and an action button.

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

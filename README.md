# PRISM

## Run it right now, without any of the signing ceremony

```sh
Tools/run_local.sh
```

Builds ad-hoc signed with no entitlements and launches the menu bar agent —
no Team ID, no provisioning profile, no Apple account. You get the popover,
the live preview, the full Metal effects chain, freeze, clips, presets and
hotkeys. What you do **not** get is `PRISM Camera` inside Zoom or FaceTime:
installing the camera system extension requires an entitlement that only a
provisioning profile can grant, so onboarding stays incomplete and the
popover shows a setup banner. That is the expected state for this mode.

For the virtual camera itself, read on.

## ⚠️ You need an Apple Developer Team ID for the real thing

**The camera extension and the audio HAL plug-in will not load without your
own Apple Developer Team ID.** All three components must be signed (and, for
distribution, notarized) or macOS refuses to load them. This is the
documented friction point of every CoreMediaIO extension project, so it goes
here at the top, not in a footnote.

The committed Team ID is `744ZKK233L`. If you are not building on that team,
substitute your own in **three files**:

| File | What to change |
|---|---|
| `project.yml` | `DEVELOPMENT_TEAM:` in the `signing` setting group |
| `PRISM/PRISM.entitlements` | app group `<TEAM>.horse.prism.PRISM` |
| `PRISMCameraExtension/PRISMCameraExtension.entitlements` | app group `<TEAM>.horse.prism.PRISM` |

Your Team ID is the `OU` field of your signing certificate —
`security find-identity -v -p codesigning` gives you the identity name, and
`security find-certificate -c "<identity>" -p | openssl x509 -noout -subject`
prints the `OU`.

Then regenerate the project (`xcodegen generate`). If you fork PRISM for
distribution, also replace the `horse.prism` reverse-DNS prefix throughout —
bundle IDs, device UIDs, and the shared memory name must match across all
three components.

The test suite is exempt: `PRISMTests` is ad-hoc signed and needs no Team ID,
so `xcodebuild test -project PRISM.xcodeproj -scheme PRISMTests -destination
'platform=macOS'` works on a bare checkout.

### When Xcode cannot create a profile

```
error: Unable to process request - PLA Update available: You currently don't
have access to this membership resource. To resolve this issue, agree to the
latest Program License Agreement in your developer account.
error: No profiles for 'horse.prism.PRISM' were found
```

The second error is a symptom of the first, not a separate problem. Apple
publishes a new Program License Agreement periodically and **blocks all
profile issuance for the account until someone with the Account Holder role
accepts it** — no local change fixes this. Sign in at
[developer.apple.com/account](https://developer.apple.com/account), accept the
banner at the top, then rebuild. In the meantime `Tools/run_local.sh` needs
none of this.

Other causes of the same "No profiles" error: no *paid* membership (the free
tier cannot issue the System Extension entitlement at all), or the App ID
existing without the System Extension capability enabled.

Additional signing realities:

- The camera **system extension** only loads from an app running in
  `/Applications` (a Debug build running from DerivedData can use
  `systemextensionsctl developer on` on a machine with SIP configured for
  development).
- The audio **HAL plug-in** is hosted inside `coreaudiod`, cannot ship in the
  Mac App Store, and cannot be debugged with SIP fully enabled. Budget a
  SIP-disabled development machine or VM for audio work.

---

## What PRISM is

PRISM is a resident macOS menu bar agent that sits between your physical
capture hardware and every app that consumes camera or microphone input. It
publishes two synthetic devices, selectable in any app (FaceTime, Photo
Booth, QuickTime, Zoom, Safari, Meet, Discord, …):

- **PRISM Camera** — a CoreMediaIO camera extension.
- **PRISM Microphone** — an AudioServerPlugIn input device.

Default behavior is transparent pass-through. On top of that, PRISM adds:

- **Freeze frame** (⌥⌘F) — holds the sharpest recent frame (picked from the
  last 300 ms by Laplacian variance, so you never freeze mid-blink). Audio
  keeps running; **mute** (⌥⌘M) is separate; ⌥⌘⇧F does both.
- **Clip playback** — substitute a video file for the live feed, with clip
  audio optionally routed to PRISM Microphone.
- **GPU effects chain** — framing (zoom/pan/rotate/flip), color adjust,
  LUTs, background blur, auto-framing — all Metal, all measured, all
  governed by a visible latency budget.
- **Eye contact** (⌥⌘E) — reads notes off-camera while appearing to look at
  the lens. Vision's face-landmark model measures how far your pupils have
  drifted from the centre of your own eyes, and a Metal warp pulls part of
  that back — so it works out where your camera is by itself. It moves the
  eyes you have rather than synthesizing new ones, and clamps at about half
  an iris width, because a subtly-wrong eye beats an uncanny one.
- **Virtual backgrounds** — full replacement with a still, a looping video,
  or a flat color, sharing one person-segmentation pass with background blur
  rather than paying for a second. If the file is still opening, you get the
  color: this never falls back to showing your actual room.
- **Green-screen compositing** — drop in up to three keyed layers (chroma or
  luma, any key color) and place them in front of you or behind you. An
  animated hat, a fire border, a lower third, a picture-in-picture of a
  second feed. Same operation each time; PRISM becomes a stage.
- **Instant replay** (⌥⌘R) — rewind and scrub the last 4–30 seconds instead
  of an awkward redo, played back fast enough to catch up to live. Frames go
  through the hardware H.264 encoder, so ten seconds costs ~10 MB rather
  than the ~2.5 GB it would cost raw.
- **Away loop** (⌥⌘A) — an auto-generated "still here" idle loop instead of
  a static freeze. PRISM searches the buffer for the stillest stretch whose
  first and last frames match, so the cut is as close to invisible as the
  recording allows, then crossfades the seam.
- **Panic** (⌥⌘P) — one chord: freeze + mute + swap to a "back in a bit"
  backdrop, each part switchable. Pressing it again restores exactly what
  you had, including a freeze or mute you'd engaged yourself.
- **Lag switch** (hold ⌥⌘L) — deliberate added latency, the exact inverse of
  everything else here. Engaging holds the picture where it is and only then
  resumes, up to 10 seconds behind: a stall, not a rewind, because jumping
  back would make you say the same thing twice. Audio follows by default.
  Release snaps back to live, or catches up by playing the backlog out fast.
  The delay is always stated outright — the latency meter keeps measuring
  what PRISM costs you involuntarily, and the status line gains `+3.0 s lag`
  next to it.

The rolling buffer behind instant replay and the away loop is **off by
default** and records only while something is actually using PRISM. An armed
buffer runs a hardware encoder on every frame, and a resident agent should
cost nothing for a feature you aren't using.

PRISM shows in both the Dock and the menu bar; clicking the Dock icon (or
the window button in the popover) opens the main PRISM window — a full
control surface with the live preview, every framing/effect/format/device
control, preset management, and a Menu Bar pane that customizes which
modules the menu bar dropdown shows and in what order. (SPEC §1 specifies a
menu bar-only agent with `LSUIElement = true` — the app deliberately
diverges, see the comment in `PRISM/Info.plist`.) No network access.
Apache-2.0.

---

## Architecture

Three separately signed components. The camera extension is a dumb relay —
all processing lives in the app, because the extension runs as root and the
CMIO sink stream is the only practical IPC channel across that boundary.

```
┌─────────────────┐        ┌──────────────────────────────────────────────────┐
│ Physical camera │───────▶│ PRISM.app  (menu bar agent, runs as user)        │
└─────────────────┘ AVFdn  │                                                  │
┌─────────────────┐        │  CameraCapture ─▶ Metal effects chain ─▶ CMIOSink│
│ Physical mic    │───────▶│  AudioCapture ─▶ mute / clip audio ─▶ AudioSink  │
└─────────────────┘ HAL AU └─────────────┬──────────────────────────┬─────────┘
                                         │ CMIO sink stream         │ lock-free SPSC ring in
                                         │ (IOSurface frames, IPC)  │ POSIX shared memory
                                         ▼                          ▼ /horse.prism.audio.v1
                    ┌────────────────────────────────┐  ┌───────────────────────────────┐
                    │ Camera extension               │  │ PRISM.driver (HAL plug-in,    │
                    │ horse.prism.PRISM.camera       │  │ horse.prism.PRISM.audio,      │
                    │ (root, sandboxed, CMIO)        │  │ hosted inside coreaudiod)     │
                    │                                │  │                               │
                    │  sink stream ─▶ relay ─▶ source│  │  ring reader ─▶ input stream  │
                    │  (placeholder card when idle)  │  │  (silence when app is gone)   │
                    └───────────────┬────────────────┘  └───────────────┬───────────────┘
                                    │ "PRISM Camera"                    │ "PRISM Microphone"
                                    ▼                                   ▼
                    ┌──────────────────────────────────────────────────────────────────┐
                    │      Client apps: Zoom, FaceTime, QuickTime, Safari, Meet …      │
                    └──────────────────────────────────────────────────────────────────┘
```

Crash isolation is structural: if PRISM.app dies, the camera extension keeps
emitting its placeholder card and the audio plug-in keeps emitting silence
(a producer heartbeat in the shared ring detects the dead app). Client apps
and `coreaudiod` are never taken down.

---

## Building from source

Requirements: macOS 13+, Xcode 15+, [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`), and an Apple Developer Team ID (see the warning
at the top).

```sh
git clone <your fork>
cd prism

# 1. If you are not on team 744ZKK233L, substitute your Team ID in
#    project.yml and the two .entitlements files (table at the top).

# 2. Generate the Xcode project.
xcodegen generate

# 3. Build.
open PRISM.xcodeproj      # build the PRISM scheme in Xcode, or:
xcodebuild -project PRISM.xcodeproj -target PRISM -configuration Release build \
    -allowProvisioningUpdates
xcodebuild -project PRISM.xcodeproj -target PRISMAudioPlugIn -configuration Release build \
    -allowProvisioningUpdates
```

`-allowProvisioningUpdates` lets xcodebuild register App IDs and create
profiles on your account; Xcode's Run button does the same thing implicitly.
Without it, a command-line build fails with "Automatic signing is disabled and
unable to generate a profile" even when everything is configured correctly.

To skip provisioning entirely while iterating, use `Tools/run_local.sh`
(ad-hoc, no entitlements) or run the tests, which never need signing.

Release packaging and notarization are scripted:

```sh
Tools/build_pkg.sh    # → dist/PRISM.dmg + dist/PRISM-Audio.pkg
Tools/notarize.sh     # notarytool (keychain profile PRISM_NOTARY) + staple
```

`Tools/latency_harness/run.sh` compiles and runs a standalone CLI that
measures the shared-ring traversal latency and the virtual camera's
end-to-end added latency against the numbers below.

---

## Installing (order matters)

Three grants, in this order — the in-app onboarding drives the same sequence
and shows a setup banner until all three are satisfied:

1. **Camera and microphone permission** for PRISM.app (system TCC prompts on
   first launch).
2. **Camera extension approval.** PRISM submits the system extension request;
   macOS sends you to System Settings → Privacy & Security to approve it.
   PRISM.app must be in `/Applications`.
3. **Audio component install.** Run `PRISM-Audio.pkg` (admin authentication).
   Its postinstall restarts `coreaudiod`, which **briefly interrupts all
   system audio** — don't do this mid-meeting.

A half-finished install produces confusing symptoms (camera works,
microphone missing) — finish all three steps.

## Operational hazards

Known sharp edges of the platform, not bugs in PRISM:

- **Camera extension updates frequently require a reboot** to reload.
  PRISM's extension is a thin relay precisely so it almost never changes —
  effects updates only touch the app.
- **Major macOS updates may silently de-approve system extensions.** If
  PRISM Camera disappears after an OS update, re-approve it in System
  Settings → Privacy & Security.
- **Installing or updating the audio plug-in restarts `coreaudiod`**,
  briefly interrupting all system audio (every HAL plug-in has this).
- **The HAL plug-in cannot be debugged with SIP enabled** — plan on a
  SIP-disabled machine or VM for audio-path development.

---

## Latency model

Zero added latency is not physically available — the floor is one camera
frame interval plus one GPU pass plus one IPC hop. PRISM's requirement is
that it adds nothing perceptible and never drops a frame, and it shows you
its measured numbers live in the popover (latency meter + per-stage costs).

```
added_latency = 4.0 ms fixed + effects GPU time
```

Fixed video costs (independent of format):

| Stage | Budget |
|---|---|
| Capture callback → Metal texture | ≤ 1.0 ms |
| Sink push → source emit | ≤ 3.0 ms |

The effects GPU budget derives from the negotiated frame rate and the user's
latency policy (Lowest = 20% of frame interval, Balanced = 40%, Quality = 70%):

| Policy | 60 fps (16.7 ms) | 30 fps (33.3 ms) | 24 fps (41.7 ms) |
|---|---|---|---|
| Lowest latency | 3.3 ms | 6.7 ms | 8.3 ms |
| Balanced (default) | 6.7 ms | 13.3 ms | 16.7 ms |
| Maximum quality | 11.7 ms | 23.3 ms | 29.2 ms |

Resulting total added-latency ceilings: **8.7 ms** at 1080p60 Balanced,
**17.3 ms** at 30 fps, **20.7 ms** at 24 fps (5.3/7.7 ms at Lowest for
60/30 fps). Higher frame rates mean lower total latency but a tighter
effects budget. When the measured mean exceeds budget, PRISM disables the
most expensive unpinned effect (and tells you) rather than ever dropping a
frame — a stutter is more noticeable than a filter switching off.

Audio path:

| Stage | Budget |
|---|---|
| HAL input buffer (256 frames @ 48 kHz) | 5.3 ms |
| Processing | ≤ 1.0 ms |
| Ring traversal | 1 client buffer period |
| **Total added** | **≤ 12.0 ms** |

A/V sync requirement: |video added − audio added| ≤ 15 ms (lip-sync error
becomes visible around 45 ms). Freeze and clip playback intentionally break
sync. `Tools/latency_harness` measures all of this rather than assuming it.

---

## Trust: no network access

PRISM makes **zero network connections**. No analytics, no telemetry, no
crash reporting, no update checks. For an app that sits on your camera and
microphone this is the strongest trust property it can offer, and in an
open-source repo it is *verifiable* — grep the source: there is no
networking code to find. Updates are deliberate: you download a new release
yourself.

## License

Apache License 2.0 — see [LICENSE](LICENSE). Copyright PRISM contributors.

The audio plug-in is original code modeled on Apple's `NullAudio` sample
architecture. It deliberately contains no code from GPL-licensed virtual
audio drivers (BlackHole, BackgroundMusic).

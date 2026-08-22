# PRISM

PRISM is a resident macOS menu bar agent that sits between your physical
capture hardware and every app that consumes camera or microphone input. It
publishes two synthetic devices, selectable in any app (FaceTime, Photo
Booth, QuickTime, Zoom, Safari, Meet, Discord, …):

- **PRISM Camera** — a CoreMediaIO camera extension.
- **PRISM Microphone** — an AudioServerPlugIn input device.

Default behaviour is transparent pass-through. Everything else — effects,
freeze, replay, backgrounds, the teleprompter — is something you switch on.
PRISM makes **zero network connections**, and the whole feature set below is
measured against a visible latency budget it is not allowed to exceed.

Apache-2.0. macOS 13+.

---

## Run it right now, without any of the signing ceremony

```sh
Tools/run_local.sh
```

Builds with the local capture entitlements and launches the agent — no Team
ID, provisioning profile, or Apple account required. It uses an Apple
Development certificate when one is available and otherwise signs ad hoc.
You get the dropdown, the main window, the live preview, the full Metal
effects chain, freeze, clips, presets and hotkeys. What you do **not** get is
`PRISM Camera` inside Zoom or FaceTime: installing the camera system
extension requires an entitlement that only a provisioning profile can
grant, so onboarding stays incomplete and a setup banner stays up. That is
the expected state for this mode.

For the virtual devices themselves, read on.

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

## What PRISM does

Nothing in this list is on by default. Anything that costs a GPU pass, a
Vision request or a hardware encoder is inert until you switch it on,
because a resident agent should cost nothing for a feature you aren't using.

### The picture

- **Framing** — zoom, pan, rotation, orientation, mirror, crop aspect, and
  **auto-framing** that rides the same person-segmentation pass background
  blur already pays for rather than running a second one.
- **Colour** — exposure, contrast, saturation, temperature, vignette, and
  `.cube` **LUTs** (five bundled; drop a file anywhere on the window or the
  dropdown to import it).
- **Skin retouch** — an edge-preserving smooth gated to skin. It smooths the
  skin you have: no face model, no synthesis, and the fine texture the
  smoothing removes is handed back deliberately, because that is what keeps
  a retouched face from reading as a mask.
- **Style** — up to two stacking effects over the finished picture, in three
  families: *distortions* (bulge, dent, twirl, squeeze, fisheye, stretch,
  mirror, light tunnel, kaleidoscope, wave, underwater, glitch, tiny planet,
  RGB split), *motion* (afterimage, echo, long exposure, strobe) and *looks*
  (thermal, X-ray, night vision, VHS, pixellate). Intensity can breathe with
  your microphone level.
- **Eye contact** (⌥⌘E) — read notes off-camera while appearing to look at
  the lens. Vision's face-landmark model measures how far your pupils have
  drifted from the centre of your own eyes, and a Metal warp pulls part of
  that back — so it works out where your camera is by itself. It moves the
  eyes you have rather than synthesizing new ones, and clamps at about half
  an iris width, because a subtly-wrong eye beats an uncanny one.

### The scene

- **Background blur** and **virtual backgrounds** — full replacement with a
  still, a looping video, or a flat colour, sharing one person-segmentation
  pass with blur rather than paying for a second. If the file is still
  opening you get the colour: this never falls back to showing your actual
  room.
- **Green-screen compositing** — up to five keyed layers (chroma or luma,
  any key colour) placed in front of you or behind you. An animated hat, a
  fire border, a lower third, a picture-in-picture. Same operation each time;
  PRISM becomes a stage. At most three of the five may be *video*: a video
  layer carries its own decoder, and three 1080p decoders already cost more
  resident memory than the rest of the pipeline combined. Text and live
  layers have no decoder, which is why the total can go higher.
- **Text layers** — captions and lower thirds rasterised into the frame.
- **Live layers** — whichever of the camera and the screen is *not* currently
  feeding the pipeline can be composited as one more keyed layer, which is
  how you get a picture-in-picture of your face over a shared screen. While
  anything is substituting the picture (freeze, clip, replay) these layers
  are held too, so a frozen frame can never have a live corner still moving
  in it.

### The source

- **Screens and windows** — share a display or a single window *through*
  PRISM instead of through the meeting app, so freeze, replay, the effects
  and every saved clip work on it unchanged (⌥⌘D). A still screen keeps
  being sent rather than falling back to the placeholder card. If the window
  closes, PRISM falls back to the camera and says so — never to black.
- **Clip playback** — substitute a video file for the live feed, with clip
  audio optionally routed to PRISM Microphone.
- **Device selection** — which camera, which microphone, with a stated
  fallback when one disconnects mid-call.

### Time

The rolling buffer behind these is **off by default** and records only while
something is actually using PRISM. An armed buffer runs a hardware encoder
on every frame.

- **Freeze frame** (⌥⌘F) — holds the sharpest recent frame (picked from the
  last 300 ms by Laplacian variance, so you never freeze mid-blink). Audio
  keeps running; **mute** (⌥⌘M) is separate; ⌥⌘⇧F does both.
- **Instant replay** (⌥⌘R) — rewind and scrub the last 4–30 seconds instead
  of an awkward redo, played back fast enough to catch up to live. Frames go
  through the hardware H.264 encoder, so ten seconds costs ~10 MB rather
  than the ~2.5 GB it would cost raw.
- **Away loop** (⌥⌘A) — an auto-generated "still here" idle loop instead of
  a static freeze. PRISM searches the buffer for the stillest stretch whose
  first and last frames match, so the cut is as close to invisible as the
  recording allows, then crossfades the seam.
- **Presence** — optionally start the away loop or a freeze when the frame
  has been empty for a while (six seconds by default), and release when you
  are back. Off by default, with asymmetric hysteresis in both directions:
  a late trigger costs nothing, a false one puts a recording of you on air
  while you are sitting there talking. It can also just post a "you left
  your camera on" notification and change nothing on air.
- **Lag switch** (hold ⌥⌘L) — deliberate added latency, the exact inverse of
  everything else here. Engaging holds the picture where it is and only then
  resumes, up to 10 seconds behind: a stall, not a rewind, because jumping
  back would make you say the same thing twice. Audio follows by default.
  Release snaps back to live, or catches up by playing the backlog out fast.
  The delay is always stated outright — the latency meter keeps measuring
  what PRISM costs you involuntarily, and the status line gains `+3.0 s lag`
  next to it.
- **Bad connection** (⌥⌘B) — one switch that makes the feed look like a
  struggling network: macroblock pixelation, starved colour, a collapsed
  frame rate, and (by default) a short fall behind live riding the lag
  switch's transport. One severity knob drives all of it, because "my
  connection is struggling" is one story, not three settings. The full chain
  keeps running clean underneath, so recovery is instant.
- **Panic** (⌥⌘P) — one chord: freeze + mute + swap to a "back in a bit"
  backdrop, each part switchable. Pressing it again restores exactly what
  you had, including a freeze or mute you'd engaged yourself.

### Keeping things

- **Stills** (⌥⌘⇧S) — PNG or HEIC, with an optional countdown and an option
  to pick the sharpest of the last few frames rather than the literal one.
- **Clips** (⌥⌘S) — write the rolling buffer straight to a `.mov`. The
  samples are already hardware-encoded, so the save is a remux: no
  re-encode, no GPU, and saving the last ten seconds is not the thing that
  makes the next ten seconds stutter.

Both save the **raw camera**, not the processed picture, and PRISM confirms
before saving anything a virtual background or a keyed layer was concealing.

### The voice

- **Cleanup** — off (bit-exact pass-through, and the default), *Clean up*
  (steady broadband noise: fans, air conditioning, hiss) or *Studio* (also
  reverb and transient room noise). Recursive filters and instantaneous
  gains only: zero samples of lookahead, because the §6 audio budget has
  1.3 ms left after the HAL buffer and the ring traversal, and a spectral
  denoiser would spend all of it on window delay before doing anything.
- **Voice changer** (⌃⌥⌘V) — chipmunk, helium, deep, giant, alien, robot,
  autotune, telephone, cave, underwater. Time-domain DSP throughout, for the
  same budget reason.
- **Level meter**, shared by the dropdown and the Voice pane so the two can
  never disagree about how loud you are.

### While you're talking

- **Teleprompter** (⌃⌥⌘T) — a floating, chrome-free script panel with speed,
  size, opacity and a mirrored mode. `sharingType = .none` is the
  load-bearing line: the window server refuses these pixels to every screen
  recorder, including other apps' screen shares and PRISM's own screen
  source. Nobody else can see it.
- **Hand gestures** — an open palm, a victory sign or a fist can mute,
  freeze, take a still, start a replay or panic. Four independent rules have
  to agree before anything fires, all of them asymmetric towards *not*
  firing, because people talk with their hands and a gesture that fires by
  itself mutes a call nobody asked to mute. Off by default.

### The conversation

- **Live transcript** (⌃⌥⌘M) — PRISM transcribes the call on this Mac with a
  speech model it downloads once. Your side always; the other side too if you
  let it listen to the meeting app. Because PRISM already owns the microphone
  and captures the far end separately, it knows which side every word came
  from without any speaker-identification model — on a one-to-one call that is
  the whole of "who said what", exactly right, for free.
- **Meeting detection asks first** — when Zoom, FaceTime, Teams, or a browser
  call such as Google Meet begins using PRISM Camera or PRISM Microphone,
  PRISM posts a notification offering to start Meeting mode. Dismissing it
  does nothing; detection never starts transcription on its own.
- **Nothing is transcribed while you are muted**, and that is architecture
  rather than a setting. Mute and the transcription tap receives nothing at
  all — not silence, nothing — and no buffer holds what you said before.
  Audio is never written to disk under any setting.
- **Meeting notes** — when the call ends, PRISM can write structured notes
  from the transcript using a provider you choose: Claude, an Ollama model
  running on this Mac, or any OpenAI-compatible endpoint. Every action item
  carries the transcript line it came from and its timestamp, so you can
  check it. No provider is set by default, and with none set nothing leaves
  the machine.
- **Assistant** (⌃⌥⌘A) — a floating answer panel only you can see, over your
  own screen. It answers the question you were just asked. It runs when you
  press the key and at no other time: PRISM notices questions and lights up
  the composer, but never sends one by itself.
- **Live insights** (⌃⌥⌘I) — the opt-in exception to that. While you are
  listening and the panel is up, PRISM sends the last few lines to your
  provider on its own — between turns, never closer than a cooldown, never
  more than a ceiling per ten minutes — and puts up a card when there is
  something worth saying: the answer to what you were just asked, a term
  that went past, a commitment somebody made, a question worth asking next.
  It is told that nothing is the usual answer, and every card quotes the
  line that prompted it. Off by default, with its own switch, and it
  disarms the moment the panel closes or listening stops.

### Driving it

- **Global shortcuts** for everything above, all rebindable.
- **Presets** — named configurations of the whole chain, four built-in,
  with their own chords. Exportable and importable as JSON.
- **Per-app rules** — which preset PRISM wears for a given client, and
  whether a client is allowed to open the camera at all. Matched on the
  client's code-signing identifier, not its path or process name.
- **Shortcuts app / App Intents** — freeze, mute, panic, replay, away, eye
  contact, voice changer, blur, and preset switching, so a Stream Deck or a
  Focus automation can drive PRISM without it growing a server. Off until
  you turn it on. Deliberately *not* a `prism://` URL scheme, which would be
  an unauthenticated local RPC endpoint into somebody's camera; and
  deliberately no Siri phrases, because "Hey Siri, panic" is exactly the
  phrase a meeting will say out loud. No intent can read video, audio,
  frames, the replay buffer or the log; none can load a file, pick a device,
  change format, quit PRISM, or widen its own surface.
- **Diagnostics** — an in-memory record of what happened this session
  (auto-disables, device changes, dropped frames). Never written to disk
  unless you export it, never sent anywhere, and it names devices and apps
  but never the *contents* of anything.

---

## Using it

PRISM shows in both the Dock and the menu bar.

- The **menu bar dropdown** is the in-a-meeting surface: preview, status,
  latency meter, the in-use line, and whichever control modules you chose.
  The Menu Bar pane in the main window picks which modules appear and in
  what order.
- The **main PRISM window** — Dock icon, ⌘,, or the gear in the dropdown —
  is the full control surface: a live preview and twenty panes grouped
  into *On air*, *Recording*, *Sources & output*, *Control* and *PRISM*.
  There is no separate Settings window; ⌘, opens this one.

SPEC §1 specifies a menu bar-only agent (`LSUIElement = true`). The app
deliberately diverges — a control surface this size wants a real window, and
a window needs somewhere in the Dock to be raised from. See the comment in
`PRISM/Info.plist`.

Editing is live and mirrored between the two surfaces instantly. Turning on
**Preview edits before applying** stages your edits into a private draft
instead: you see them, apps keep seeing the applied look, and an Apply /
Discard bar settles it.

Default shortcuts:

| Chord | Action |
|---|---|
| ⌥⌘F / ⌥⌘M / ⌥⌘⇧F | Freeze / mute / both |
| ⌥⌘R | Instant replay |
| ⌥⌘A | Away loop |
| ⌥⌘P | Panic |
| ⌥⌘E | Eye contact |
| ⌥⌘L *(hold)* | Lag switch |
| ⌥⌘B | Bad connection |
| ⌥⌘S / ⌥⌘⇧S | Save clip / take a still |
| ⌥⌘D | Screen or window as the source |
| ⌃⌥⌘V | Voice changer |
| ⌃⌥⌘T | Teleprompter |
| ⌃⌥⌘M | Transcribe this call |
| ⌃⌥⌘A | Ask the assistant |
| ⌃⌥⌘I | Live insights on or off |

⌃ is in those last rows because PRISM's event tap never consumes a chord: a
plain ⌥⌘V would also trigger Finder's "Move Item Here" every time you put a
chipmunk on air, and ⌥⌘T would open the frontmost app's font panel.

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

The repository:

| Path | What lives there |
|---|---|
| `PRISM/` | The app: capture, the Metal pipeline, state, and the UI |
| `PRISMKernels/` | The Metal kernels the pipeline stages dispatch |
| `PRISMShared/` | Types and the lock-free ring shared with the plug-ins |
| `PRISMCameraExtension/` | The CoreMediaIO relay |
| `PRISMAudioPlugIn/` | The AudioServerPlugIn HAL driver (C++, no ARC) |
| `PRISMTests/` | The logic suite; no signing, no devices, no window |
| `Tools/` | Build, packaging, notarization and measurement scripts |
| `docs/` | [SPEC.md](docs/SPEC.md) — what it must do; [CONTRACTS.md](docs/CONTRACTS.md) — how each file must do it |

---

## Building from source

Requirements: macOS 13+, Xcode 15+, [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`), and an Apple Developer Team ID (see the warning
above).

`PRISM.xcodeproj/project.pbxproj` is generated, not committed — run
`xcodegen generate` after a checkout and after anything that changes
`project.yml` or adds a file.

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

### The iteration loop

```sh
./rebuild.sh                 # app → /Applications/PRISM.app, then relaunch
./rebuild.sh --with-driver   # app AND the audio driver (needs sudo)
./rebuild.sh --driver-only   # just the audio driver
```

The normal rebuild installs an optimized Release build. For a deliberately
unoptimized installed build while diagnosing with a debugger, set
`PRISM_BUILD_CONFIGURATION=Debug`; `Tools/run_local.sh` is the faster Debug
loop when the system extension is not needed.

The app and the driver install to two different places and neither implies
the other, which is the usual reason a change "didn't work". `rebuild.sh`
always reports which halves are actually current on disk and warns when the
installed driver is older than the driver sources in the checkout.
Installing the driver restarts `coreaudiod` — see the hazards below.

To skip provisioning entirely while iterating, use `Tools/run_local.sh`
(ad-hoc, no entitlements) or run the tests, which never need signing:

```sh
xcodebuild test -project PRISM.xcodeproj -scheme PRISMTests -destination 'platform=macOS'
```

Release packaging and notarization are scripted:

```sh
Tools/build_pkg.sh    # → dist/PRISM.dmg + dist/PRISM-Audio.pkg
Tools/notarize.sh     # notarytool (keychain profile PRISM_NOTARY) + staple
```

`Tools/latency_harness/run.sh` compiles and runs a standalone CLI that
measures the shared-ring traversal latency and the virtual camera's
end-to-end added latency against the numbers below. `Tools/driver_smoke/`
and `Tools/mic_probe/` exercise the audio plug-in from outside the app.

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

Screen sharing needs a fourth grant, Screen Recording, but only if you use
it: the setup row appears when the feature does, because a permission banner
for something you never switched on is a banner people learn to ignore.

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
its measured numbers live (latency meter + per-stage costs).

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
frame — a stutter is more noticeable than a filter switching off. Pin an
effect to exempt it from that.

Audio path:

| Stage | Budget |
|---|---|
| HAL input buffer (256 frames @ 48 kHz) | 5.3 ms |
| Processing | ≤ 1.0 ms |
| Ring traversal | 1 client buffer period |
| **Total added** | **≤ 12.0 ms** |

A/V sync requirement: |video added − audio added| ≤ 15 ms (lip-sync error
becomes visible around 45 ms). Freeze, clip playback and the lag switch
intentionally break sync. `Tools/latency_harness` measures all of this
rather than assuming it.

---

## Trust: no network access you did not ask for

**PRISM has never phoned home and never will.** No analytics, no telemetry,
no crash reporting, no update check, nothing at launch, nothing on a timer.
Updates are deliberate: you download a new release yourself.

For a long time that was the whole story, and the section was called "no
network access". Meeting notes and the assistant changed it, so here is the
exact shape of what changed — a promise that quietly becomes a smaller
promise is worth less than one that was never made.

**A stock build opens no sockets at all.** No AI provider is configured by
default. Live transcription runs entirely on this Mac against a model on
this Mac, so you can transcribe every call you ever take and PRISM will not
connect to anything.

**When you configure a provider, PRISM sends it what you asked it to send.**
A transcript when you press *Write notes*. A question, the last few lines of
transcript and your "About you" text when you press the ask chord. And —
only if you turn on live insights — those same last few lines on their own
while the panel is up and you are listening, between turns, with a cooldown
and a ceiling the Assistant pane states in numbers. That switch is off by
default and is the one thing in PRISM that sends without a key press.
Nothing otherwise — not your audio, not your camera, not your screen. There
is one further request in the app's life: the speech model, downloaded once
from Hugging Face after you confirm the size.

**Every byte goes through one file you can read.**
`PRISM/AI/LLM/LLMTransport.swift` is about 150 lines and is meant to be read
in full. CI enforces that it is the only one: the same source scan as before
runs on every push across every directory that ends up in a shipped binary,
with exactly that one path allowlisted, so a networking call anywhere else
fails the build. A second check asserts that file names no endpoint beyond
`api.anthropic.com` and localhost. A third — which is new, and which did not
exist when this section made a bigger claim — greps the entire tree for
telemetry-shaped symbols. The `otool -L` check that the built app links no
networking framework is unchanged, and still passes.

## License

Apache License 2.0 — see [LICENSE](LICENSE). Copyright PRISM contributors.

The audio plug-in is original code modeled on Apple's `NullAudio` sample
architecture. It deliberately contains no code from GPL-licensed virtual
audio drivers (BlackHole, BackgroundMusic).

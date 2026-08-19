// ResourceGovernor.swift
// PRISM
//
// Who gets the memory, and what happens when there is not enough of it.
//
// §7 asks for resident memory under 250 MB. Every elastic allocation in the
// app was sized independently against that number, none of them knew about
// each other, and the sum had never been added up. It does not fit. Measured
// on an M-series Mac, one BGRA IOSurface slot costs 3.5 MB at 720p, 7.9 MB at
// 1080p and 31.7 MB at 4K, and FrameRing alone — half a second of raw camera,
// so its slot count follows the frame rate — measured 118.9 MB at 1080p30,
// 237.9 MB at 1080p60 and 474.8 MB at 4K30. A live session with the chain
// running measured 446 MB resident, 293 MB of it IOSurface.
//
// So the ring depth cannot be a constant. This picks it, and the still ring's
// depth beside it, from the negotiated format and what is left of the
// ceiling, in a fixed order that is the same every time: freeze's floor
// first, then the still ring the user actually asked for, then whatever is
// left widening the freeze window back toward half a second.
//
// The floor is the part that matters. Freeze promises the sharpest frame of
// the recent past (§5.2), and a ring too shallow to hold a choice turns that
// into "the frame at the moment you pressed it" — which is precisely what
// §5.2 says freeze is not. A blink closes the eyes for roughly 100–150 ms, so
// the window has to be longer than a blink for there to be anything better to
// pick; 200 ms is the shortest window that clears one, and six slots is the
// fewest that holds a choice at all once the slot being written and the slot
// still in flight are set aside. Hence: never fewer than six slots, and never
// less than 200 ms of wall time. Everything above that floor is negotiable.
//
// Those two floors pull against each other at high frame rates — 200 ms of
// 60 fps is twelve slots — so where the memory is not there, the ring records
// every second frame rather than shrinking its window. Six slots at stride
// two still span 200 ms and still hold a choice; they just hold a coarser
// one, which is a far cheaper loss than a window narrower than a blink.
//
// The other half of the job is counting everything, and for a while it did
// not. Four allocations were outside the sum while it reported that the
// ceiling held: the rolling replay buffer, which one user switch turns into
// ~80 MB; the draft chain, which is a second segmenter, a second face
// tracker, a second set of intermediates and a second output pool for as
// long as a preview surface is open; Overlay's and Retouch's stage-private
// scratch; and the working set generally, which was priced at the negotiated
// OUTPUT while FrameRing, the intermediates and every stage texture are
// allocated at the SOURCE's size — and §3.2 deliberately picks the smallest
// native format at least as large as the output, so on a 4:3 sensor serving
// a 16:9 call that is a third more bytes per slot than the plan believed.
// All four are counted now, which is why a plan that used to read 246 MB at
// 1080p60 with a screen source reads what it actually costs.
//
// None of them are elastic from here — the governor cannot make an armed
// buffer shorter or a preview cheaper — so they join the fixed costs taken
// off the top, and what gives instead is the freeze window, down to its
// floor and then, honestly, `exceeded`.
//
// Nothing here allocates or touches the GPU. It is arithmetic on a format and
// a ceiling, which is what makes it testable — see ResourceGovernorTests.
//
// Licensed under the Apache License, Version 2.0.

import Foundation

/// What the pipeline is being asked to hold, this format and this session.
public struct ResourceDemand: Equatable {
    public var format: VideoFormat
    /// The size the source actually delivers, when it is not the negotiated
    /// output size. §3.2 picks the smallest native camera format at least as
    /// large as the output in BOTH dimensions, so a 4:3 sensor serving a 16:9
    /// output is strictly larger — a Continuity Camera hands over 1920×1440
    /// for a 1080p call. FrameRing, the two working intermediates and every
    /// stage-private working texture are allocated at THAT size, so pricing
    /// them at the output's understates the ring by a third and the plan
    /// spends memory it never had. Zero means "not known yet": the plan then
    /// prices the working set at the output format, which is the smallest it
    /// can honestly be until a frame has arrived.
    public var sourceWidth: Int
    public var sourceHeight: Int
    /// §5.16 — the "sharpest frame" setting is armed, so the still ring wants
    /// output frames held. The only elastic demand a user switches on
    /// directly, which is why it outranks widening the freeze window.
    public var stillsWantSharpest: Bool
    /// §5.24 — a ScreenCaptureKit session is running. Not elastic and not
    /// negotiable: the framework holds its own queue of full-size surfaces
    /// and PRISM cannot shrink it below three, so it is a fixed cost that has
    /// to be taken off the top rather than something the plan can trade.
    public var screenSourceActive: Bool
    /// §5.9 — the rolling replay buffer is armed. The largest thing a single
    /// user switch allocates in this app, and until it was priced here the
    /// plan reported the same figure with it on and with it off.
    public var replayArmed: Bool
    /// How far back the armed buffer records, and the height it caps
    /// recording at (§5.9). Both move the cost by tens of megabytes, so the
    /// plan reads the settings rather than assuming the defaults.
    public var replaySeconds: Double
    public var replayMaxHeight: Int
    /// §5.5 — a draft preview is on screen, which means DraftRenderer is
    /// running a complete second chain over the same frames: its own
    /// intermediates, its own stage scratch, its own output pool and its own
    /// segmenter and face tracker. Demand-driven rather than always counted,
    /// for the same reason the screen session is: it exists only while a
    /// preview surface is open with an edit staged.
    public var draftChainActive: Bool

    public init(format: VideoFormat, stillsWantSharpest: Bool = false,
                screenSourceActive: Bool = false,
                sourceWidth: Int = 0, sourceHeight: Int = 0,
                replayArmed: Bool = false, replaySeconds: Double = 0,
                replayMaxHeight: Int = 1080,
                draftChainActive: Bool = false) {
        self.format = format
        self.stillsWantSharpest = stillsWantSharpest
        self.screenSourceActive = screenSourceActive
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
        self.replayArmed = replayArmed
        self.replaySeconds = replaySeconds
        self.replayMaxHeight = replayMaxHeight
        self.draftChainActive = draftChainActive
    }
}

/// How much of what PRISM would like to hold it can actually afford. A rank,
/// not a severity: `minimum` is a working configuration, not a fault.
public enum ResourceTier: String, Equatable {
    case full        // the freeze window is the full half second
    case reduced     // shortened, still longer than the floor
    case minimum     // at the floor — freeze still picks, from less
    case exceeded    // even the floor does not fit inside the ceiling
}

/// The decision, and the sentences that explain it. Both surfaces read the
/// same plan, so neither can describe a policy the pipeline is not running.
public struct ResourcePlan: Equatable {
    public var format: VideoFormat
    /// FrameRing slots (§5.2).
    public var freezeDepth: Int
    /// Record one camera frame in this many. 1 is every frame; 2 halves the
    /// memory a given window costs at the price of a coarser choice within
    /// it, which is the right trade at 60 fps and pointless at 24.
    public var freezeStride: Int
    /// StillRing slots (§5.16); 0 means stills fall back to the last frame.
    public var stillDepth: Int
    /// Frames ScreenCaptureKit holds while a screen is being captured
    /// (§5.24); 0 when no screen session is running.
    public var screenDepth: Int
    public var plannedMB: Double
    public var ceilingMB: Double
    public var tier: ResourceTier
    /// What the still ring did with what it was given, when there is
    /// something to say. Silent when nobody asked for it.
    public var stillsSummary: String?

    public init(format: VideoFormat, freezeDepth: Int, freezeStride: Int = 1,
                stillDepth: Int, screenDepth: Int = 0,
                plannedMB: Double, ceilingMB: Double,
                tier: ResourceTier, stillsSummary: String? = nil) {
        self.format = format
        self.freezeDepth = freezeDepth
        self.freezeStride = freezeStride
        self.stillDepth = stillDepth
        self.screenDepth = screenDepth
        self.plannedMB = plannedMB
        self.ceilingMB = ceilingMB
        self.tier = tier
        self.stillsSummary = stillsSummary
    }

    /// How far back freeze can reach, in seconds.
    public var freezeSpanSeconds: Double {
        Double(freezeDepth * freezeStride) / Double(max(1, format.frameRate))
    }

    public var headroomMB: Double { ceilingMB - plannedMB }

    /// One sentence about the freeze window, for the diagnostics pane. The
    /// number is always in it: "reduced" without a figure is the kind of
    /// vagueness that makes people think something is broken.
    public var summary: String {
        let span = String(format: "%.2g s", freezeSpanSeconds)
        switch tier {
        case .full:
            return "Holding \(span) of recent camera — the full freeze window."
        case .reduced:
            return "Holding \(span) of recent camera to stay inside "
                + "\(Int(ceilingMB)) MB."
        case .minimum:
            return "Holding \(span) of recent camera — the shortest window "
                + "freeze can still pick a sharp frame from."
        case .exceeded:
            return "\(format.resolutionLabel) needs about \(Int(plannedMB.rounded())) MB, "
                + "more than the \(Int(ceilingMB)) MB PRISM aims to stay inside. "
                + "Freeze is holding the least it can."
        }
    }
}

public enum ResourceGovernor {

    // MARK: - The numbers, all of them measured

    /// §7's resident ceiling.
    public static let ceilingMB: Double = 250

    /// Everything that is not a pixel buffer. Measured: 36 MB peak with the
    /// whole chain built and no camera running, plus 33 MB for the three
    /// Vision models once they are resident (15.8 for segmentation, 11.1 for
    /// 76-point landmarks, 6.5 for hand pose), plus the capture session, the
    /// replay encoder and the preview view. Reserved at the live figure
    /// rather than the idle one: a budget that only holds until the user
    /// switches on background blur is not a budget.
    static let reservedMB: Double = 80

    /// Vision's staging buffers, itemised because the line used to read
    /// "three modalities × two 720p slots" and two of the four modalities are
    /// not at 720p: two BGRA slots each for segmentation and landmarks at
    /// 720p (7.0 MB each), two at 640×360 for presence (1.8 MB), two at
    /// 960×540 for hand pose (4.0 MB — fingers need more lines than a torso
    /// does, §5.31), and the three-deep mask pool, which is R8 rather than
    /// BGRA (2.6 MB). 22.4 MB against a reservation that was already 24, so
    /// the fourth modality fits inside the rounding the old sentence was
    /// carrying rather than costing the freeze window a slot. Fixed, because
    /// every request's input is capped regardless of the negotiated format.
    static let visionStagingMB: Double = 24

    /// Structural buffers at the NEGOTIATED OUTPUT size: four in the output
    /// pool (two frames in flight, the retained last output, a crossfade
    /// endpoint) and the fit scratch a crossfade lands in. Not elastic —
    /// dropping any of them stops the pipeline rather than shrinking it.
    static let outputFrames: Int = 5

    /// …and the two the chain ping-pongs between, which are allocated at the
    /// SOURCE's size (VideoPipeline.ensureWorking takes source.width), not
    /// the output's. Kept apart from `outputFrames` for exactly that reason:
    /// the two groups are not the same number of bytes on a camera whose
    /// native format is larger than the call (§3.2).
    static let workingIntermediates: Int = 2

    /// Working-resolution textures the stages keep for themselves, counted
    /// always rather than only while their stage is on. Style's motion
    /// history and its stacked-pass scratch (§5.29) are two; Overlay's layer
    /// ping-pong pair (§5.26) — allocated the moment a second layer renders,
    /// and never released after — is two more; Retouch's pair (§5.22) is at
    /// half resolution in both dimensions, so a quarter of a frame each.
    ///
    /// Counting them on demand was the obvious alternative and it is the
    /// wrong one: the freeze window would then change length when the user
    /// picked Underwater or dropped a lower third on the picture, and a
    /// freeze that reaches back four tenths of a second on Tuesday and three
    /// on Wednesday is worse to reason about than one that is permanently a
    /// few slots shorter. This costs 1080p roughly six slots of ring, which
    /// is the honest price of the looks and is written down here rather than
    /// discovered later.
    static let stageWorkingFrames: Double = 2 + 2 + 0.5

    /// The draft chain's second set of Vision resources (§5.5): a segmenter
    /// and a face tracker of its own, so their 720p staging pairs (7.0 MB
    /// each) and the three-deep R8 mask pool (2.6) are allocated twice, and
    /// the segmentation and landmark models (15.8 + 11.1) are charged again.
    /// Charging the models is the conservative reading — Vision may share a
    /// compiled model between requests in one process — and conservative is
    /// the only safe direction for a ceiling: under-counting is the failure
    /// this whole file exists to stop.
    static let draftVisionMB: Double = 44

    /// Never fewer slots than this, whatever the arithmetic says. Two of any
    /// ring are unavailable at any instant — the one being written and the
    /// one whose command buffer has not landed — so six is the fewest that
    /// leaves freeze an actual choice.
    public static let minimumFreezeDepth = 6
    /// …and never less wall time than this. A blink closes the eyes for
    /// 100–150 ms; a window shorter than one has nothing sharper to offer.
    public static let minimumFreezeSeconds = 0.2
    /// §5.2's half second, and the most any of this is ever worth.
    public static let preferredFreezeSeconds = 0.5
    /// FrameRing's slot ceiling — half a second at 128 fps, far above §3.2.
    public static let maximumFreezeDepth = 64

    // MARK: - The policy

    /// Slots that hold the full §5.2 window at this format, every frame.
    public static func preferredDepth(for format: VideoFormat) -> Int {
        let byTime = Int((Double(max(1, format.frameRate)) * preferredFreezeSeconds).rounded(.up))
        return min(maximumFreezeDepth, max(minimumFreezeDepth, byTime))
    }

    /// Record one camera frame in this many, so `depth` slots still span the
    /// minimum window. At 30 fps and below this is always 1; at 60 it is what
    /// lets six slots cover 200 ms instead of 100, for half the memory a
    /// twelve-slot ring would cost. A coarser choice inside the window is a
    /// far smaller loss than a window narrower than a blink.
    public static func stride(depth: Int, frameRate: Int) -> Int {
        let wanted = minimumFreezeSeconds * Double(max(1, frameRate)) / Double(max(1, depth))
        return max(1, Int(wanted.rounded(.up)))
    }

    /// One full frame at this format, in MB. BGRA, so four bytes a pixel and
    /// no chroma subsampling to argue about.
    public static func frameMB(for format: VideoFormat) -> Double {
        Double(format.width * format.height * 4) / (1024 * 1024)
    }

    /// One frame at the size the chain actually works in — the source's,
    /// where it is known, and the output's before the first frame lands.
    /// Every ring slot, intermediate and stage scratch is this size; only the
    /// output pool, the fit scratch and the still ring are `frameMB`.
    public static func workingFrameMB(for demand: ResourceDemand) -> Double {
        guard demand.sourceWidth > 0, demand.sourceHeight > 0 else {
            return frameMB(for: demand.format)
        }
        return Double(demand.sourceWidth * demand.sourceHeight * 4) / (1024 * 1024)
    }

    /// §5.9's rolling buffer, itemised the way it is actually allocated:
    /// a six-slot record pool of raw BGRA at the capped record size
    /// (ReplayBuffer.ensureResources), the compressed ring — CMSampleBuffers
    /// at ReplayBuffer's own bit rate for the whole window — and the 32×18
    /// luma thumbnail per recorded frame plus the eight-slot slack the ring
    /// keeps. Zero when the switch is off, which is where it ships.
    public static func replayMB(for demand: ResourceDemand) -> Double {
        guard demand.replayArmed, demand.replaySeconds > 0 else { return 0 }
        let working = workingSize(for: demand)
        let record = ReplayBuffer.recordSize(width: working.width,
                                             height: working.height,
                                             maxHeight: demand.replayMaxHeight)
        let pool = Double(ReplayBuffer.recordPoolDepth * record.width * record.height * 4)
            / (1024 * 1024)
        let bits = Double(ReplayBuffer.bitRate(width: record.width,
                                               height: record.height))
        let compressed = bits * demand.replaySeconds / 8 / (1024 * 1024)
        let slots = Double(max(16, Int((demand.replaySeconds
            * Double(max(1, demand.format.frameRate))).rounded(.up)) + 8))
        let thumbnails = slots * Double(ReplayBuffer.thumbnailWidth
            * ReplayBuffer.thumbnailHeight * MemoryLayout<Float>.stride)
            / (1024 * 1024)
        return pool + compressed + thumbnails
    }

    /// §5.5's draft preview: a second chain, priced the same way the first
    /// one is. Two working intermediates, the same stage-private working
    /// textures, a three-deep output pool at the negotiated format, and its
    /// own Vision resources. No FrameRing and no still ring — a draft
    /// previews the live camera with the draft look and nothing more.
    public static func draftMB(for demand: ResourceDemand) -> Double {
        guard demand.draftChainActive else { return 0 }
        let working = workingFrameMB(for: demand)
        return (Double(workingIntermediates) + stageWorkingFrames) * working
            + Double(DraftRenderer.outputPoolDepth) * frameMB(for: demand.format)
            + draftVisionMB
    }

    private static func workingSize(for demand: ResourceDemand)
        -> (width: Int, height: Int) {
        guard demand.sourceWidth > 0, demand.sourceHeight > 0 else {
            return (demand.format.width, demand.format.height)
        }
        return (demand.sourceWidth, demand.sourceHeight)
    }

    /// The plan. Deterministic: the same demand always produces the same
    /// answer, because a memory policy that depends on when you asked is one
    /// nobody can reason about after the fact.
    public static func plan(for demand: ResourceDemand) -> ResourcePlan {
        let format = demand.format
        let frame = frameMB(for: format)
        // What the chain works in, which is not what it publishes: the ring
        // and the intermediates are the source's size (§3.2), the output pool
        // and the still ring are the negotiated format's.
        let working = workingFrameMB(for: demand)
        // ScreenCaptureKit's queue joins the structural frames rather than
        // the elastic ones: PRISM cannot make it smaller, so pretending it is
        // negotiable would only mean the freeze window is planned against
        // memory that is already spent. The armed replay buffer and the draft
        // chain join them for the same reason — the governor cannot shrink
        // either, and a plan that leaves them out is not a plan, it is a
        // number that happens to be under the ceiling.
        let screenDepth = demand.screenSourceActive ? ScreenCapture.queueDepth : 0
        let fixed = reservedMB + visionStagingMB
            + Double(outputFrames + screenDepth) * frame
            + (Double(workingIntermediates) + stageWorkingFrames) * working
            + replayMB(for: demand)
            + draftMB(for: demand)

        let floor = minimumFreezeDepth
        let preferred = preferredDepth(for: format)

        // Freeze's floor is taken before anything is weighed, including
        // against the ceiling: a freeze that cannot pick is a broken feature,
        // and the honest response to not affording it is to say so.
        var remaining = ceilingMB - fixed - Double(floor) * working
        var freezeDepth = floor

        // Then the still ring, because it is the one elastic demand a user
        // switched on deliberately (§5.16). It takes as many slots as fit,
        // down to a floor of its own; below that it is not worth the memory
        // and stills fall back to the last frame, which they already do.
        var stillDepth = 0
        if demand.stillsWantSharpest, frame > 0 {
            let affordable = Int(max(0, remaining) / frame)
            if affordable >= StillRing.minimumDepth {
                stillDepth = min(StillRing.maximumDepth, affordable)
                remaining -= Double(stillDepth) * frame
            }
        }

        // Whatever is left widens the freeze window back toward half a second.
        if working > 0 {
            let extra = Int(max(0, remaining) / working)
            freezeDepth = min(preferred, freezeDepth + extra)
            remaining -= Double(freezeDepth - floor) * working
        }

        let planned = fixed + Double(freezeDepth) * working
            + Double(stillDepth) * frame
        let tier: ResourceTier
        if planned > ceilingMB {
            tier = .exceeded
        } else if freezeDepth >= preferred {
            tier = .full
        } else if freezeDepth > floor {
            tier = .reduced
        } else {
            tier = .minimum
        }

        return ResourcePlan(format: format,
                            freezeDepth: freezeDepth,
                            freezeStride: stride(depth: freezeDepth,
                                                 frameRate: format.frameRate),
                            stillDepth: stillDepth,
                            screenDepth: screenDepth,
                            plannedMB: planned,
                            ceilingMB: ceilingMB,
                            tier: tier,
                            stillsSummary: stillsSummary(demand: demand,
                                                         depth: stillDepth,
                                                         format: format))
    }

    private static func stillsSummary(demand: ResourceDemand, depth: Int,
                                      format: VideoFormat) -> String? {
        guard demand.stillsWantSharpest else { return nil }
        guard depth > 0 else {
            return "Stills take the last frame rather than the sharpest of the "
                + "last moment — holding finished \(format.resolutionLabel) frames "
                + "would not fit."
        }
        let span = Double(depth) / Double(max(1, format.frameRate))
        return String(format: "Stills pick the sharpest of the last %.2g s.", span)
    }
}

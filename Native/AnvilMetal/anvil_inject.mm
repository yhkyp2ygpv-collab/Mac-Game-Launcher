// Anvil's frame interceptor.
//
// Inserted into the game's process with DYLD_INSERT_LIBRARIES. By the time a frame
// reaches here, D3DMetal has already translated it and it is a Metal texture on a
// CAMetalLayer — so Anvil's passes run natively, with no D3D round trip.
//
// Two hooks, at two different moments, because they do different jobs:
//
//   -[CAMetalLayer nextDrawable]      — too early to touch pixels (the game hasn't
//                                       drawn yet), but the only place to clear
//                                       framebufferOnly before the drawable exists.
//   -[MTLCommandBuffer presentDrawable:] — the actual frame boundary. The game's
//                                       rendering is already encoded on this command
//                                       buffer, so a compute pass appended here runs
//                                       after it and before the frame is shown.

#include "anvil_pack.h"
#include "anvil_shaderset.h"
#include "anvil_guardian.h"
#include "anvil_io.h"
#import <Foundation/Foundation.h>
#include <Block.h>
#import <QuartzCore/QuartzCore.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <os/log.h>
#import <atomic>
#import <cstdarg>
#import <algorithm>
#import <simd/simd.h>
#import <mach/mach.h>
#import <sys/time.h>
#import <thread>
#import <mutex>
#import <dlfcn.h>
#import <vector>
#import <deque>
#import <os/lock.h>
#import <IOKit/IOKitLib.h>
#import <IOSurface/IOSurface.h>
#import <IOKit/ps/IOPowerSources.h>
#import <IOKit/ps/IOPSKeys.h>
#import <time.h>

extern "C" const char* AnvilCaptureStall(const char* label);

extern "C" void anvil_report_window_fit(void);
extern "C" void anvil_report_windows_later(void);
extern "C" void anvil_watch_front(void);
extern "C" bool anvil_game_in_front(void);
extern "C" bool anvil_screen_away(void);
extern "C" double anvil_behind_seconds(double now);
extern "C" void anvil_ensure_setup(const char* where);
extern "C" void anvil_screens_offer(id<MTLCommandBuffer> cb, id<MTLTexture> frame);

// FSR to the display (see "FSR to the display" below): what D3DMetal is handed in place of
// the layer's drawable. Its texture is the size the game draws at; everything else is the
// real drawable's, which Anvil fills with the upscaled picture and presents.
@interface AnvilProxyDrawable : NSProxy {
@public
    id<CAMetalDrawable> _real;
    id<MTLTexture> _input;
    // Smooth Motion between frames: a stand-in with no drawable of the layer's behind it (_real nil).
    // Smooth Motion's presenter takes one only to show the frame, and answers for it what the game
    // asks of a drawable — its layer, an ID, when it was shown and the handlers to call then.
    CAMetalLayer* _layer;
    double _requestedAt;
    NSUInteger _id;
    CFTimeInterval _presentedTime;
    NSMutableArray* _presentedHandlers;
}
- (instancetype)initWithReal:(id<CAMetalDrawable>)real input:(id<MTLTexture>)input;
- (instancetype)initForLayer:(CAMetalLayer*)layer input:(id<MTLTexture>)input;
@end

// Smooth Motion's display link (see "Smooth Motion's display link" below): called just before each refresh it
// shows a frame at, with a drawable of the game's layer to show it in.
API_AVAILABLE(macos(14.0))
@interface AnvilMidLink : NSObject <CAMetalDisplayLinkDelegate>
@end

namespace {

std::atomic<uint64_t> g_frames{0};

/// Diagnostics go to a file as well as os_log. A Rosetta-translated process does not
/// reliably surface os_log to the host, and "the game exited and I have no idea why"
/// is the hardest failure to work with.
void diag(const char* fmt, ...) __attribute__((format(printf, 1, 2)));
void diag(const char* fmt, ...) {
    const char* path = getenv("ANVIL_LOG");
    if (!path) return;
    FILE* f = fopen(path, "a");
    if (!f) return;
    // Wall-clock time on every line, so what the game did can be lined up against
    // Anvil's launch log and Unity's own output.
    struct timeval tv; gettimeofday(&tv, nullptr);
    struct tm lt; localtime_r(&tv.tv_sec, &lt);
    fprintf(f, "%02d:%02d:%02d.%03d ", lt.tm_hour, lt.tm_min, lt.tm_sec, (int)(tv.tv_usec / 1000));
    va_list args;
    va_start(args, fmt);
    vfprintf(f, fmt, args);
    va_end(args);
    fputc('\n', f);
    fclose(f);
}

id<MTLDevice>               g_device      = nil;
id<MTLCommandQueue>         g_queue       = nil;
id<MTLComputePipelineState> g_rcas        = nil;
id<MTLComputePipelineState> g_easu        = nil;
id<MTLComputePipelineState> g_overlay     = nil;
id<MTLComputePipelineState> g_finish      = nil;   // RCAS + overlay in one dispatch
id<MTLComputePipelineState> g_counter     = nil;   // the overlay's box alone
id<MTLTexture>              g_counterScratch = nil;
id<MTLComputePipelineState> g_flowToMotion = nil;
id<MTLComputePipelineState> g_downsample  = nil;
id<MTLComputePipelineState> g_upsample    = nil;

// --- Apple frame interpolation ------------------------------------------------
//
// MTLFXFrameInterpolator wants colour, previous colour, depth and motion. Anvil
// already keeps the two colour frames, and its optical flow supplies the motion —
// so a game that ships no upscaler and no motion vectors of its own can still be
// interpolated by Apple's production implementation rather than Anvil's own.
//
// Depth is the one input that genuinely cannot be recovered from a finished frame.
// A flat buffer is supplied instead: the interpolator runs, and loses the
// depth-based disocclusion handling it would otherwise do.
// Interpolation places a frame *between* two real ones, so it can only be shown
// once both exist — and Anvil emits it after the newer one has already been
// presented, which puts it out of order: A, B, mid(A,B), C. Forward, back, forward.
// Showing it correctly means holding the real frame back, which is a whole frame of
// added latency.
//
// Projection has neither problem: it predicts forward from the two frames already
// shown, so it belongs exactly where it is emitted and nothing is held back. It is
// the default for that reason, and MetalFX interpolation is opt-in.
bool           g_useMetalFX = false;
id             g_interpolator = nil;      // id<MTLFXFrameInterpolator>
id<MTLTexture> g_motionTex = nil;
id<MTLTexture> g_depthTex = nil;
id<MTLTexture> g_interpOut = nil;
// Interpolation runs at half resolution. At 3024x1964 the full-resolution pass
// costs 12.27 ms — an 82fps ceiling before the game draws anything — against
// 4.35 ms including the downscale and rescale. The generated frame is on screen
// for about eight milliseconds, so the softness is a far cheaper price than the
// frame rate.
id<MTLTexture> g_halfCurr = nil;
id<MTLTexture> g_halfPrev = nil;
float g_interpScale = 0.5f;

// How coarse the motion field is. The flow search is the most expensive pass in the
// projected path — 3.0 ms at 3024x1964 — and its cost falls with the square of this
// divisor, because it is one threadgroup per output vector. Coarser motion is
// slightly less precise at object edges; on a frame that exists for eight
// milliseconds that is a better trade than the milliseconds.
int g_flowDivisor = 4;

// Frame generation runs on the game's own thread, inside nextDrawable. Everything
// it does — acquiring a drawable, encoding the downsamples, the flow, the
// interpolation — happens before the game is allowed to continue, and in Unity that
// same thread pumps input. When the work outruns the GPU the calls stack up, the
// thread stalls, and input events arrive late or are missed entirely: a stick that
// keeps travelling because the return-to-centre never landed.
//
// So a generated frame is skipped whenever the previous one is still in flight.
// Dropping a synthesised frame costs nothing that matters; blocking the thread that
// reads the controller costs the input.
std::atomic<int> g_inFlight{0};
std::atomic<uint64_t> g_skippedGenerations{0};
std::atomic<uint64_t> g_skippedBusy{0};      // …because the one before was still on the GPU
std::atomic<uint64_t> g_skippedPool{0};      // …because no drawable was free for it
id<MTLComputePipelineState> g_luma        = nil;
id<MTLComputePipelineState> g_flow        = nil;
id<MTLComputePipelineState> g_interp      = nil;   // held back: costs a frame
id<MTLComputePipelineState> g_extrap      = nil;   // projects forward: no added latency
id<MTLTexture>              g_scratch     = nil;

// Frame-generation state. Two real frames are kept, because the interpolated frame
// is the midpoint between them and both must still exist when it is built.
id<MTLTexture> g_frameA = nil;      // older real frame
id<MTLTexture> g_prevFrame = nil;   // newer real frame (B)
id<MTLTexture> g_lumaPrev  = nil;
id<MTLTexture> g_lumaCurr  = nil;
id<MTLTexture> g_flowField = nil;
bool           g_haveHistory = false;
uint64_t       g_frameCounter = 0;

CAMetalLayer* g_layer = nil;

// --- Render scaling -----------------------------------------------------------
//
// The frame rate lever. A game renders into whatever drawable the layer hands it,
// so shrinking drawableSize before nextDrawable makes it render fewer pixels —
// without the game knowing or needing to support anything. Anvil then upscales the
// result with FSR's EASU into a full-size drawable, which is a far better image
// than the plain bilinear stretch the layer would otherwise apply.
float          g_renderScale = 1.0f;
CGSize         g_nativeSize = CGSizeZero;    // the size the game originally asked for
CGSize         g_appliedSize = CGSizeZero;   // the size Anvil last wrote

// --- FSR to the display -------------------------------------------------------------
//
// A game under Wine draws at the size of its window in points — LEGO Star Wars at 1512x982
// on a display of 3024x1964 pixels — and the compositor stretches that to the panel with a
// plain bilinear filter: soft, never sharpened. Anvil now does that last step itself. The
// layer is set to the display's pixels; D3DMetal is handed a stand-in drawable whose texture
// is the size it asked for; and at present that texture goes through AMD's FSR 1 — EASU,
// then RCAS — into the real drawable, which is what is shown. One compute pass in the
// game's own command buffer; nothing is held back, so it adds no latency.
//
// Taking over the layer used to look impossible: a full-size drawable would have to be
// asked for while the game held its own, and that deadlocks. With the stand-in the real
// drawable is asked for once, in nextDrawable, where the game holds none.
//
// Only for a layer whose size D3DMetal itself sets — D3DMetal copies its finished frame into
// the drawable and presents it, and does nothing else with either — and only when the
// display has at least 15% more pixels each way than the game draws. Anything else, and
// any failure, leaves the layer as it was.
bool g_outputWanted = false;
bool g_outputAnyCaller = false;            // tests only: any caller counts as the game
std::atomic<bool> g_outputActive{false};
std::atomic<bool> g_outputFailed{false};
CAMetalLayer* g_outLayer = nil;
CGSize g_gameSize = CGSizeZero;             // what the game draws at

// anvil_gpuwork.mm: texture detail for FSR, shader compiles, and where the GPU time goes.
extern "C" void AnvilWatchCommandBuffers(Class cls);
extern "C" void AnvilOwnGpuWork(bool own);
extern "C" void AnvilGpuGameSize(double width, double height);
extern "C" void AnvilGpuFrameEnd();
extern "C" int AnvilGpuWorkWindow(char* out, size_t room);
extern "C" bool AnvilGpuFrameAnatomy(char* out, size_t room);
extern "C" void AnvilTextureDetailReport(int* seen, int* sharpened, float* bias, int* anisotropy);
extern "C" void AnvilCompileTotals(uint64_t* count, double* ms, double* longestMs, uint64_t* failed);
extern "C" void AnvilCompileConcurrency(int* before, int* after);
/// Anvil's own GPU work from here to the end of the scope: FSR and frame generation's passes
/// are timed as Anvil's, not the game's.
struct OwnGpuWork {
    OwnGpuWork() { AnvilOwnGpuWork(true); }
    ~OwnGpuWork() { AnvilOwnGpuWork(false); }
};
CGSize g_outSize = CGSizeZero;              // the display pixels it is shown on
IMP g_originalSetDrawableSize = nullptr;
id<MTLComputePipelineState> g_fsrEasu = nil;
// FSR in one pass (anvil_fsr_fused), when Graphics Prep measured it quicker for the game.
id<MTLComputePipelineState> g_fsrFused = nil;
int g_fsrPass = kAnvilFSRSplit;
MTLSize g_fusedShape = {32, 32, 1};
// Graphics Prep's archive of Anvil's pipelines, compiled for this Mac before the game started.
char g_archivePath[1024] = "";
// FSR 3 for every game (ANVIL_FSR3=1; AnvilShaders.metal, "FSR 3 for every game"): in place of
// FSR 1 alone, Anvil's temporal FSR — motion measured from the game's own frames, then EASU,
// RCAS and a blend with the frames before, at the display's size, in one pass in the game's own
// command buffer. Launcher asks for it only where Graphics Prep's test found it better than
// FSR 1 at the game's sizes. At the display's own size there is nothing to upscale, and the
// layer is taken over for the blend alone.
bool g_fsr3Wanted = false;
bool g_fsr3Native = false;          // at the display's own size too (ANVIL_FSR3_NATIVE=1): only where Graphics Prep found it better there
AnvilFSR3 g_fsr3 = {};
std::atomic<bool> g_fsr3Failed{false};
std::atomic<uint64_t> g_fsr3Frames{0};
double g_fsr3LastAt = 0.0;          // when the last frame went through it
bool g_fsr3Live = false;            // the last real frame did: frame generation follows its picture and motion
// FSR 3 within the frame's budget (fsr3Govern): FSR 1 for a while when the game is below an
// even 80 with the GPU full, FSR 3 again once the GPU has room for it.
std::atomic<bool> g_fsr3Eased{false};
std::atomic<uint64_t> g_fsr3Eases{0};
double g_fsr3ExtraMs = 2.3;         // its cost over FSR 1, ms a frame: Graphics Prep's (ANVIL_FSR3_EXTRA_MS), then as seen
id<MTLTexture> g_outScratch = nil;          // EASU's output, RCAS's input
id<MTLTexture> g_genScratch = nil;          // a generated frame at the game's size, before FSR
id<MTLCommandQueue> g_gameQueue = nil;      // the game's own queue: Anvil's work after its frame
std::mutex g_inputsLock;
std::vector<std::pair<void*, id<MTLTexture>>> g_inputs;   // real drawable's texture → stand-in texture
std::atomic<uint64_t> g_outputFrames{0};
Class g_proxyClass = nil;

// Frame generation by the player's choice, whatever the display: on a variable-refresh
// panel too, which on its own Anvil left to show the game's frames as they came.
bool g_genForce = false;
id<MTLCommandQueue> workQueue();
bool outputEncode(id<MTLCommandBuffer> cb, id<MTLTexture> input, id<MTLTexture> target);
// How long the game has to be below the display's rate before generation starts, when
// it is the player's choice: long enough to step over a load, short enough to be there
// for the fight that caused it.
constexpr double kGenForceEngageSeconds = 3.0;

bool  g_enabled     = true;
bool  g_frameGen    = false;
float g_sharpness   = 0.5f;
std::atomic<uint64_t> g_generated{0};

// --- Latency control and measurement ---------------------------------------
//
// The dominant term is not GPU time, it is how many frames the presentation queue
// is allowed to hold. CAMetalLayer defaults to 3 drawables: a frame can therefore
// sit finished-but-unshown for two whole frame intervals, which at 60 fps is 33 ms
// of latency that no amount of shader optimisation touches.
int   g_maxDrawables = 0;        // 0 = leave the layer alone
int   g_displaySync  = -1;       // -1 = leave alone, 0 = off, 1 = on
bool  g_measure      = true;

// --- Memory budget ----------------------------------------------------------
//
// macOS grants no kernel-enforced per-process memory cap: RLIMIT_AS, RLIMIT_DATA
// and RLIMIT_RSS all return EINVAL, and the jetsam interfaces need private
// entitlements. What is available is exact measurement via task_info, and control
// over how much Anvil itself allocates and what the game is told it may use.
//
// So the budget is honoured on three levels rather than enforced by the kernel:
// the figure is reported down to the translation layer so the game sizes its own
// pools to it, Anvil keeps its own working set inside the remainder, and the
// footprint is measured continuously so overrun is visible rather than silent.
// --- Frame pacing -----------------------------------------------------------
//
// Presenting the synthesised frame the instant it is ready puts it right next to
// the real frame it follows, so the display shows two frames close together and
// then a long gap. The counter doubles but the motion judders. Scheduling it for
// the midpoint of the measured real-frame interval is what turns a doubled frame
// count into motion that actually looks smoother.
bool     g_pacing = true;
// Recording every thread's stack when the game slows or freezes. It runs `sample` on the
// game, the Wine server and the device host for three seconds — suspending each thread
// every 2 ms — and vmmap after a freeze, which is a hitch of its own at exactly the
// moment the game is struggling. Every session did it once or more; now only when
// ANVIL_CAPTURE_STALLS=1 asks for it, while a problem is being chased.
bool     g_captureStalls = false;
double   g_lastRealPresent = 0.0;
double   g_frameInterval = 1.0 / 60.0;   // smoothed estimate

// The game's unaided rate, measured while its frames are being held.
//
// Generation used to stop for one window every minute to take an honest reading,
// because a game held to the grid, or to every second refresh, presents at the rate
// it is held to rather than the rate it could manage. That showed as a few seconds of
// the game's own uneven frames in the middle of a fight. The holding all happens in
// one place — inside nextDrawable, in Anvil's slot wait and the pool's own blocking —
// so the time spent there is measured and taken off each present interval. What is
// left is the game's own work per frame, readable continuously, and generation never
// has to pause to find out whether it is still needed.
double   g_hookWaitSec     = 0.0;        // time inside nextDrawable since the last real present
double   g_ownLastPresent  = 0.0;
double   g_ownWindowSum    = 0.0;        // own frame time summed over this window
uint64_t g_ownWindowCount  = 0;
// The same over the last two seconds, for genDecide. Decided once a statistics window — 600
// frames — generated frames reacted 24 s late at 25 fps, the rate they're for; every two seconds,
// a heavy area gets Smooth Motion within a few.
double   g_ownQuickSum     = 0.0;
uint64_t g_ownQuickCount   = 0;
double   g_ownQuickSince   = -1.0;
constexpr double kDecideEvery = 2.0;

// --- Cadence lock ---------------------------------------------------------------
// An average of 120 fps is not the same thing as a stable 120, and the difference is
// the whole complaint. Measured on this Mac, the game's own render rate wandered
// between 65 and 120 while the display average stayed near 120. At 67 fps on a
// 120 Hz panel a real frame arrives every 1.79 refreshes, so consecutive frames land
// two refreshes apart, then one, then two. That beat is what is felt as stutter, and
// no amount of extra frames fixes it — the frames have to be evenly spaced.
//
// So Anvil stops letting frames present whenever they happen to finish and puts them
// on the panel's own grid: real frames on every second refresh, generated frames on
// the ones between. `presentDrawable:atTime:` hands the schedule to the compositor
// instead of stalling the CPU, so the spacing costs no latency of its own; the game
// is throttled the way any frame limiter throttles it, by the drawable pool.
double   g_refreshPeriod   = 0.0;    // seconds per display refresh, 0 = unknown
double   g_realSlotPeriod  = 0.0;    // seconds between real frames on the grid
double   g_nextRealSlot    = 0.0;    // absolute time the next real frame is due
double   g_lastRealTarget  = 0.0;    // where the last real frame was scheduled
int      g_targetFPS       = 0;      // 0 = follow the display
bool     g_steadyWanted    = false;  // ANVIL_TARGET_FPS=80: see Steady below
std::atomic<uint64_t> g_resyncs{0};  // times the grid had to be re-established

// Drawables the layer has handed out that have not yet been shown.
//
// This exists because of a deadlock the grid made possible. Generation runs inside
// the game's own nextDrawable call — that is the one window where the game holds no
// drawable — and it asks the same pool for a drawable of its own. Presenting real
// frames on a schedule instead of immediately leaves more of them pending, and with
// a three-deep pool the generator's request could find nothing left. It then blocked
// inside the call the game was waiting on, and both stopped: the game sat at 2%% CPU
// with the window up and nothing moving.
//
// So generation asks first whether the pool can spare one, and simply skips the
// frame when it cannot. A missed synthesised frame is invisible; a hung game is not.
std::atomic<int> g_pendingPresents{0};

// --- One frame in flight --------------------------------------------------------
// How many drawables the layer may hand out is the single largest term in input
// latency that Anvil controls. With three, a game that is faster than the display
// renders two frames ahead of it: input sampled now reaches the screen two refreshes
// later, about 16.7 ms at 120 Hz. With two, it renders one frame ahead, and the same
// input arrives a refresh sooner. That is the whole idea behind "max frame latency 1"
// on other platforms.
//
// The cost is slack. With two drawables a frame that runs long has nothing queued
// behind it and the display shows the previous frame again, which is a stutter. So
// Anvil runs two only while the game is filling every refresh with its own frames,
// counts every refresh the game misses, and goes back to three for the rest of the
// session the moment misses appear. Generating frames always takes three: a
// synthesised frame needs a drawable of its own.
bool     g_lowLatency   = false;    // measured: no gain on Cat Quest II, stutter at start
int      g_depthFloor   = 2;             // raised to 3 if the game cannot keep up at 2
int      g_appliedDepth = 0;
std::atomic<uint64_t> g_nearMisses{0};   // gaps of about two refreshes: a missed slot

// --- Is generation even needed? -------------------------------------------------
// Frame generation buys smoothness with latency and with image quality: a synthesised
// frame is a guess, and holding the game to half the refresh rate costs input
// response. When the game can already render at the panel's full rate, all three of
// those costs are being paid for nothing.
//
// The presented rate cannot answer this once the grid is capping it, so what is
// measured is the game's own work: the time between being handed a drawable and
// presenting it. That is unaffected by the cap, because the throttle happens before
// the drawable is handed out.
bool     g_frameGenRequested = false;   // what the user asked for
bool     g_adaptive          = true;

/// Whether synthesised frames are currently being produced.
///
/// This is decided from the game's *unaided* frame rate, and that distinction is the
/// whole point. The obvious test — "are the game's frames arriving further apart than
/// a refresh?" — cannot be used, because generating frames is itself what pushes them
/// apart: a generated frame takes GPU time and a drawable away from the game. Measured
/// here, the same game rendered 120 fps with generation off and 91 fps with it on,
/// whereupon generation dutifully filled the gap it had just created. Once started it
/// could never stop, and half of every second was a warped guess standing in for a
/// real frame the machine could have drawn — which is what "the graphics are shaking"
/// was.
///
/// So generation starts off, the honest rate is measured, and it is only turned on if
/// the game genuinely cannot fill the display. While it is on, the game's unaided rate
/// is still read — from its work time, with the waiting taken out (g_hookWaitSec) — so
/// it is turned off again as soon as the game can manage without it.
bool     g_generating   = false;
// How long the game must stay below the threshold before generation starts. Ten
// seconds switched it on four times in one Cat Quest II session for ordinary dips, and
// generated frames warp what moves. Six windows fixed that but, because a window is 600
// frames, meant 48 seconds of uneven frames at the start of every fight at 75 fps.
// Measured in seconds instead: longer than any dip seen outside a fight, and a fight
// gets help within about twenty seconds.
constexpr double kGenEngageSeconds = 20.0;
double   g_belowSeconds  = 0.0;
double   g_lastWindowAt  = 0.0;
// While generating: how long the game has been able to do better than its cadence.
double   g_recoverSeconds = 0.0;         // could hold the display rate on its own
double   g_upSeconds      = 0.0;         // could leave half-rate for gap filling
double   g_downSeconds    = 0.0;         // needs half-rate after gap filling
constexpr double kGenAdjustSeconds = 10.0;

// --- Half-rate cadence ----------------------------------------------------------
// Filling "whatever slots the game leaves empty" only works when the game's rate
// divides the display's evenly. At about 90 fps it does — three real frames and one
// generated, 120 shown, every gap on the beat. At 70 it does not: real frames land one,
// two or three refreshes apart, there is one generated frame per real one at most, and
// the pool of three drawables is often full when the generator asks. Measured in a Cat
// Quest II fight: 70 real frames became 105 shown, a third of gaps two refreshes long —
// the stutter that remained.
//
// Below 90 the game is held to every second refresh instead, which it can sustain with
// room to spare, and exactly one frame is generated between each pair: 60 + 60, every
// refresh filled, the same way every time. The game waits for its slot before it is
// handed a drawable, so it never queues frames ahead and the generator always has one.
bool     g_halfRate      = false;
double   g_fullSlotPeriod = 0.0;            // the real-frame spacing when not halved
constexpr double kHalfRateBelow = 0.75;     // of the display rate: 90 fps at 120 Hz
// And only for a game that can hold every second refresh with room to spare. LEGO Star
// Wars at 48–54 fps could not make a 16.7 ms slot, missed every other one, and fell to 30
// real frames with a guessed frame beside each — half of what was shown was a guess
// stretched over twice the motion.
constexpr double kHalfRateFloor = 0.55;     // 66 fps at 120 Hz

// --- Generated frames on a variable-refresh panel, chosen by the player -------------------
// LEGO Star Wars on 11 October, two sessions of 12 and 28 minutes: generation began on a
// loading screen 46 s in — the game at 46 fps, the display still being looked at — and, chosen
// by the player, stayed on for the session. With it on, Steady stood aside (no even 80, and on
// battery no long-session 80 either), and frames went on the fixed 120 grid instead of being
// shown as ready: at 50–60 fps for minutes, 0–5% of gaps on the beat and 50–65 ms from input to
// screen; later, the game at 23–45 fps in heavy scenes, held to every second refresh with half of
// everything shown a guess stretched over 25–40 ms of motion — the picture breaking up the longer
// it was played. Its own frames on that panel, shown as they're ready, are even at any rate it
// makes. So there, the player's generated frames are two to one — 60 of the game's, a guess
// between each — and only for a game that holds every second refresh with room to spare but
// not Steady's even 80: from about 66 to 76 fps at 120 Hz (to 90 without Steady). Never in the
// first 30 s, nor while the display is being looked at again, nor in a long session; off again
// once the game can hold the even rate on its own, or can't keep up with the two-to-one, and
// waiting longer each time it has to start again within a minute of starting.
double   g_sessionStartAt   = -1.0;   // the game's first present
double   g_genStartedAt     = -1.0;
double   g_genEngageBackoff = 0.0;    // added to the seconds below before generation starts again
double   g_genShortSeconds  = 0.0;    // two to one, the game short of every second refresh
constexpr double kGenEngageBackoffMax = 120.0;
constexpr double kGenRestartWithin    = 60.0;
constexpr double kGenShortSeconds     = 5.0;
// On such a panel a start needs this long in the band — two of the log's windows at 70 fps —
// so one heavy stretch between lighter ones isn't a change of cadence each way.
constexpr double kGenVrrEngageSeconds = 10.0;
// Smooth Motion: a heavy scene on a variable-refresh panel. The game's own frames are shown as
// they're ready, and one made from them shown halfway between each two — 30 fps of the game's
// is 60 on the screen, 45 is 90. Below what every second refresh needs (two to one, above), from
// kFillLowFPS up to kFillHigh of the display's rate, in a long session too: there the GPU is
// full with the game's own work whatever is done, and an even 80 isn't to be had. On 12 October
// LEGO Star Wars at Endor made 25–35 fps of its own for minutes at a time, with nothing between.
constexpr double kFillLowFPS = 24.0;          // below this, too much happens between frames to guess
constexpr double kFillHigh = 0.52;            // of the display's rate: 62 at 120 Hz
// Leaving takes more than coming in: 74 at 120 Hz. With one edge both ways, a game held to 60 of its own measured
// 60–65 with frames made ahead of it, and Smooth Motion went on and off every 4–6 s in Hogwarts Legacy (21 October).
constexpr double kFillLeaveHigh = 0.62;
constexpr double kFillEngageSeconds = 3.0;
constexpr double kFillLeaveSeconds = 4.0;

// --- Smooth Motion between frames ----------------------------------------------------------------
// 0.47's Smooth Motion projected each made frame ahead from the last two real ones. In LEGO Star
// Wars' heavy scenes on 13 October it was choppy, and its log says why. The made frame went on the
// game's own queue, behind the next frame's work: with the GPU full it finished just before the next
// real frame rather than halfway — a gap of a frame, then a sliver. The game's frame held one of the
// layer's three drawables from asking for it until its GPU work was done, so with one frame on screen
// and one queued there was often none for the made frame: up to 280 of 600 skipped, every one "no
// drawable". And a guess ahead is wrong wherever motion turns, so the next real frame stepped back.
// It also stopped at 24 fps of the game's own: at 18–23 fps for twelve minutes it made nothing at all.
//
// With FSR 3 to the display, frames now go through a presenter of Anvil's own:
//  - The made frame is the one between the last two real frames, made from FSR 3's pictures and its
//    motion (anvil_midpoint) in the game's own command buffer right after FSR 3. On Graphics Prep's
//    moving scene it is 3.5 from the true picture half a frame back at any speed, where the frame
//    projected ahead was 5.9–6.6 from its own moment, and the older frame still on screen 13–23.
//  - The game draws into a stand-in with no drawable of the layer's behind it, and FSR writes the
//    frame into a picture of Anvil's. A drawable is taken only to show a frame, when its GPU work is
//    done — so the game never holds one while the GPU works on its frame. Held, as in 0.47 and in the
//    first try at this, the layer's three were one short: the game waited up to 65 ms for its next
//    every other frame, and fell from 29 to 21 fps in Anvil's stand-in.
//  - When the game's frame is done on the GPU, the presenter copies the made frame and the real one
//    into drawables and shows the made one at once and the real one half the game's frame time
//    later, every gap alike — each real frame half a frame later than shown-as-ready: the price of a
//    frame between. The copies are the CPU's, into the drawables' IOSurfaces from pictures the GPU
//    wrote to memory both can read, and the frames are shown with no GPU work at all: anything put
//    on the GPU then — even a copy on a queue of Anvil's own — waited behind the game's next frame,
//    and reached the screen 10–70 ms late with the GPU full (Anvil's stand-in, 13 October). On an M4
//    a frame at LEGO's 3024x1964 is 3 ms of one core's time.
//  - Each present is timed from when the frame before it was shown, not by the clock: asked for a
//    moment, a frame reaches this display about 20 ms after the soonest it could, 12 ms after a later
//    one, so a made frame asked for at once and its real one 18 ms on were shown 10 ms apart.
//  - No more than two of the game's frames are on their way to the screen at once: the drawables it
//    no longer holds were what held it back.
bool     g_midWanted = true;                      // ANVIL_SMOOTH_MOTION_MID=0: 0.47's frames made ahead
std::atomic<bool> g_mid{false};                   // frames through the presenter now
id<MTLComputePipelineState> g_midpoint = nil;
// The made frames' check (AnvilShaders.metal: anvil_midpoint_check, anvil_midpoint_judge): before each, the two frames
// looked at on FSR 3's luma planes (a plane pixel in 16; 0.02 ms a frame on an M4 at LEGO's sizes), and where they
// disagree over too much of the picture for a few frames running the nearer real frame is shown in the made one's
// place. Its state stays on the GPU (MidGate, mirrored here); what it held is read for the stats line.
// ANVIL_MID_CHECK=apart,share sets how far apart a pixel is (0.015 of the luma range outside the other frame's 3x3) and
// what share of them is too much (0.04): on Graphics Prep's scenes at four speeds the plain picture, a heat haze and
// sparks came to at most 2.4% apart, a chequerboard at most 1.7%; a reflection over the lower third moving fast enough
// to break the made frames, 4.9–9.2%. Set to hold only what's clearly broken. ANVIL_MID_CHECK=0 turns it off (tests).
id<MTLComputePipelineState> g_midCheck = nil, g_midJudge = nil;
struct MidCheckState { uint32_t looked, apart; float score; uint32_t hold, judged, held; float share, most; uint32_t parted; };
id<MTLBuffer> g_midCheckState = nil;
bool  g_midCheckOn = true;
// How far apart is apart; the share of the picture apart from which the nearer real frame is shown whole (0.58: almost a
// third of it; 4% until 0.57, see anvil_midpoint); and from which a made frame counts as taking its pixels where they disagree.
float g_midCheckApart = 0.015f, g_midCheckShare = 0.3f, g_midCheckPart = 0.04f;
uint32_t g_midCheckJudgedSeen = 0, g_midCheckHeldSeen = 0, g_midCheckPartedSeen = 0;   // at the last stats line
id<MTLTexture> g_midApartMap = nil;   // where the two frames disagree: a value for each 4x4 of FSR 3's luma planes
id<MTLCommandQueue> g_midQueue = nil;
dispatch_queue_t g_midDispatch = nullptr;
// Made frames and the game's frames after FSR, at the display's size and the drawable's format, in
// memory the CPU reads as the GPU wrote it (a texture over a shared buffer, rows as in an IOSurface).
// Made frames: up to three for each of the game's — Smooth Motion at four frames a frame, 20 fps of the game's
// shown as 80 — in two sets, one being shown while the next is made.
constexpr int kMidMultMax = 4;
id<MTLTexture> g_midFrames[2][kMidMultMax - 1] = {};
int      g_midNext = 0;
// Frames shown for each of the game's own: 2 (one made between) to 4 (three), the presenter's choice from the
// game's rate, read when the next made frames are encoded. Two, unless ANVIL_MID_MULT_MAX asks for more (tests):
// three and four, in LEGO Star Wars on 14 October, cost the game its own frames — Anvil's GPU work up to 12.6 ms
// a frame of the game's (three made frames at the display's size), the game making 16.4 fps where it could make
// 25.9 — with 60–85 ms between a frame being ready and its showing, and neither presenter (timed from the frame
// before, or a display link) showed every real frame in Anvil's stand-in (see below).
std::atomic<int> g_midMult{2};
int      g_midMultMax = 2;
int      g_midMultWant = 2;                       // the presenter's own: what it would choose now, and since when
double   g_midMultSince = 0.0;
// With two or three made, each frame is shown at a time of its own on the clock (presentAtTime:), evenly between,
// the first this long after the game's frame was done: what a frame asked for that soon reaches this display by.
// Timed from the frame before instead, as one made between is, a frame not yet shown is overtaken by the next
// game frame's first made one (each is timed from the one on screen, ~20 ms behind) — 557 of 598 real frames
// never reached the screen at four a frame in Anvil's stand-in (14 October).
constexpr double kMidLead = 0.036;
double   g_midLastTarget = 0.0;                   // the presenter's own: the last time it asked for

// --- Smooth Motion's display link: three or four frames for each of the game's --------------------------------
// Pushed to the layer as each game frame is done — timed from the frame before (presentAfterMinimumDuration) or
// at a time on the clock (presentAtTime:) — four frames a frame didn't fit through it. A frame takes ~20 ms to
// reach this display once asked for, longer than the 12.5 ms between frames at 80, and the layer has three
// drawables: timed from the one before, the next game frame's first made frame overtook the real frame still
// waiting (557 of 598 real frames never shown, in Anvil's stand-in at 18 fps, 14 October); timed on the clock,
// three drawables held that long carried only ~65 frames a second. A CAMetalDisplayLink asks for each frame just
// before the refresh it's shown at, with the drawable to show it in: in a test program under Rosetta at 80 fps,
// copying each frame in by the CPU as here, every gap 12.5 ms and each frame shown when asked (preferred latency
// 2 refreshes). So with two or three made, the presenter only puts each game frame's frames on a timetable —
// made ones evenly between, then the real one — and the link shows the newest one due at each of its refreshes.
struct MidEntry {
    id<MTLTexture> picture;
    double due;
    bool real;
    AnvilProxyDrawable* standIn;                  // answered when this one is shown (retained), or nil
};
os_unfair_lock g_dlLock = OS_UNFAIR_LOCK_INIT;
std::deque<MidEntry>* g_dlQueue = nullptr;        // made once and never destroyed (see anvil_io.mm's locks)
id       g_dlLink = nil;                          // CAMetalDisplayLink, made on its own thread
id       g_dlDelegate = nil;
std::atomic<bool> g_dlActive{false};
bool     g_dlWanted = true;                       // ANVIL_MID_DL=0: three or four a frame pushed, as clock-timed
double   g_dlLastDue = 0.0;                       // the presenter's own
double   g_dlTick = 1.0 / 80.0;
CFRunLoopRef g_dlRunLoop = nullptr;               // the link's thread's: anything done to the link is done there

// A made frame's code: which set (×8) and how many were made in it.
inline int midMadeCode(int set, int count) { return set * 8 + count; }
inline int midMadeSet(int made) { return made / 8; }
inline int midMadeCount(int made) { return made < 0 ? 0 : made % 8; }
id<MTLTexture> g_midShown[3] = {nil, nil, nil};   // the game's frames after FSR
int      g_midShownNext = 0;
id<MTLTexture> g_midInputs[3] = {nil, nil, nil};  // what the game draws into, at its size
int      g_midInputNext = 0;
Class    g_drawableClass = nil;                   // the layer's drawables' class, for a stand-in without one
std::atomic<int>  g_midBacklog{0};                // frames handed over that the presenter hasn't shown yet
std::atomic<uint64_t> g_midBoosts{0};             // presenter work raised to user-interactive priority, behind
int g_midStalls = 0;                               // stalls with the game's frames waiting, this session
/// Nothing shown this long with the game's frames waiting: the presenter has stalled (midStalled).
constexpr double kMidStallSec = 0.4;
void midStalled(double now);
int g_midInFlight = 2;                            // the game's frames on their way to the screen at most (ANVIL_MID_IN_FLIGHT)
bool g_jitOn = false;                             // each frame started just in time at a low frame rate (jitHold; ANVIL_JIT=1)
std::atomic<bool> g_midInsert{false};             // making frames between, at the rate the presenter sees
std::atomic<double> g_midRate{0.0};               // the game's frames a second, as the presenter receives them
std::atomic<double> g_midHandedAt{0.0};           // when a frame was last handed over
std::atomic<double> g_midShownAt{0.0};            // when the presenter last showed one
std::atomic<uint64_t> g_midMade{0};               // made frames shown
std::atomic<uint64_t> g_midGateWaitUs{0};         // the game's wait for its frames in flight, this window
std::atomic<uint64_t> g_midGateTimeouts{0};
std::atomic<uint64_t> g_midWaitUs{0};             // the presenter's wait for drawables, this window
std::atomic<int> g_midDebug{0};                   // ANVIL_MID_DEBUG=n: the first n presenter steps, in the log
#ifdef ANVIL_INJECT_TEST
int      g_midAvailableForTest = -1;              // steady_test: whether frames between can be made (-1: as found)
#endif
double   g_midEngagedAt = -1.0;
double   g_midRateBefore = 0.0;                   // the game's own rate when it began
int      g_midGpuBefore = -1;                     // the GPU's busy percent then
double   g_midStarvedSeconds = 0.0;
// The presenter's own (its queue only).
double   g_midLastDone = 0.0;                     // when the last frame's GPU work finished
double   g_midInterval = 0.0;                     // the time between them, smoothed
double   g_midLastRealAt = 0.0;                   // when the last real frame was asked to show
bool     g_midInserting = false;
// The presenter's frames asked to show and not on screen yet: two or more and the screen is behind, so
// the next made frame is left out to catch up rather than everything after it shown later.
std::atomic<int> g_midOnWay{0};
std::atomic<uint64_t> g_midBehind{0};             // made frames left out for that, this window
// The game told its frame is on screen when the first of the two shown for it is, not half a frame later
// with the real one (ANVIL_MID_EARLY=0: with the real one, as 0.48). D3DMetal counts a game's frames in
// flight to the screen (addPresentedHandler:): LEGO Star Wars waited for them, and every millisecond the
// real frame was held back was one the game didn't start its next in — 13 October (see midPresent).
int      g_midEarly = 1;                           // 2 (tests): as soon as its GPU work is done, before it's shown
// From 15 fps: between two frames the motion is seen from both sides, not guessed. Engaged under
// half the display's rate, as a frame between needs two refreshes; left above 62% of it.
constexpr double kMidLowFPS = 15.0;
constexpr double kMidEngageHigh = 0.5;
constexpr double kMidLeaveHigh = 0.62;
constexpr double kMidEngageSeconds = 1.0;
// Paused, not stopped for the session, when frames between cost the game its own (see genDecide): a
// minute, twice as long each time after, up to ten.
double   g_midPausedUntil = 0.0;
double   g_midPauseFor = 0.0;

// --- Guardian ------------------------------------------------------------------------------------------
// A small part of Anvil that wakes every few seconds while a game plays, makes sure what Anvil does for it
// is working, and learns what works on this Mac (anvil_guardian.h):
//  - Every two seconds, with Smooth Motion's decision: now and then, with frames between running steadily,
//    a few seconds of the game's own frames alone to compare — the same scene, seconds apart — and, where
//    frames between have been found to cost more than they give at a rate, the game's own frames there,
//    looked at again now and then. Kept between sessions, for this game on this Mac.
//  - Every ten seconds, a check-up: frames still reaching the screen from Smooth Motion's presenter (a
//    stall puts the game's own frames back), Smooth Motion or Steady not switching back and forth (slowed
//    down when they do — LEGO Star Wars switched Steady 134 times and Smooth Motion about 25 in its 108
//    minutes of 13 October), and how many of the game's frames never reached the screen.
// It never restarts the game or changes its settings: only what Anvil does inside it, as it plays.
bool     g_guardian = true;                       // ANVIL_GUARDIAN=0: off
int      g_guardProbe = 0;                        // a check under way: 1 frames between held off, 2 made for it
bool     g_guardEligible = false;                 // frames between could be made at the game's rate now (genDecide)
double   g_guardChangedAt = -1.0;                 // when something of Anvil's last changed: a hold, an ease, a switch
double   g_guardCheckAt = 0.0;                    // the last check-up
double   g_guardSummaryAt = 0.0;                  // the last summary in the log
double   g_guardCalmUntil = 0.0;                  // Smooth Motion switching often: slower to switch until then
double   g_guardSteadyCalmAt = -1e9;              // Steady last slowed down
int      g_guardCheckUps = 0, g_guardFixes = 0;
uint64_t g_guardNotShownBase = 0, g_guardRealBase = 0;
double   g_guardNotShownSaidAt = -1e9;
// What reached the screen in the window, for Guardian's measure (under g_shownLock).
double   g_gShownN = 0.0, g_gGapN = 0.0, g_gGapSum = 0.0, g_gGapSq = 0.0;
// Smooth Motion's starts and Steady's lets-go, the last sixteen of each.
constexpr int kGuardTimes = 16;
double   g_guardStarts[kGuardTimes];
int      g_guardStartsN = 0;
double   g_guardLetGo[kGuardTimes];
int      g_guardLetGoN = 0;

void guardNoteTime(double* ring, int& n, double t) {
    if (n == kGuardTimes) { for (int i = 1; i < kGuardTimes; ++i) ring[i - 1] = ring[i]; n = kGuardTimes - 1; }
    ring[n++] = t;
}

int guardCountSince(const double* ring, int n, double since) {
    int c = 0;
    for (int i = 0; i < n; ++i) if (ring[i] >= since) ++c;
    return c;
}

// The grid's phase, taken from a frame the display actually showed.
//
// Snapping to the panel is the whole point and it cannot be done from a wall clock:
// "now" is some arbitrary moment inside a refresh interval, so scheduling at "now"
// puts the frame back where it started — a fraction of a refresh out, differently
// every time. A presented time, on the other hand, is by definition a moment the
// display refreshed. Every target is quantised against one.
double   g_gridPhase = 0.0;

/// The first grid instant at or after `t`.
double snapToGrid(double t) {
    if (g_gridPhase <= 0.0 || g_refreshPeriod <= 0.0) return t;
    double k = ceil((t - g_gridPhase) / g_refreshPeriod - 1e-6);
    if (k < 0.0) k = 0.0;
    return g_gridPhase + k * g_refreshPeriod;
}

/// Whether the main display can refresh on demand. ANVIL_VRR forces it either way;
/// otherwise AppKit is asked, when it is loaded (it is in a game — Wine's Mac driver is
/// built on it). A display that says yes is still checked against what it actually
/// shows before Anvil relies on it; see g_vrrVerified.
int detectVariableRefresh() {
    if (const char* v = getenv("ANVIL_VRR")) return v[0] == '1' ? 1 : 0;
    Class screenClass = objc_getClass("NSScreen");
    if (!screenClass) return -1;
    id screen = ((id (*)(id, SEL))objc_msgSend)(screenClass, sel_registerName("mainScreen"));
    SEL minSel = sel_registerName("minimumRefreshInterval");
    SEL maxSel = sel_registerName("maximumRefreshInterval");
    if (!screen || ![screen respondsToSelector:minSel] || ![screen respondsToSelector:maxSel]) return -1;
    const double minI = ((double (*)(id, SEL))objc_msgSend)(screen, minSel);
    const double maxI = ((double (*)(id, SEL))objc_msgSend)(screen, maxSel);
    if (minI <= 0.0 || maxI <= 0.0) return -1;
    return maxI > minI * 1.5 ? 1 : 0;
}

/// The display's refresh period, read once. Falls back to a measured value if
/// CoreGraphics cannot tell us, and to 120 Hz if nothing can.
double displayRefreshPeriod() {
    // Tests: a display at another rate (ANVIL_REFRESH_HZ=60 with ANVIL_VRR=0: a 60 Hz one at a fixed rate).
    if (const char* hz = getenv("ANVIL_REFRESH_HZ")) { const double v = atof(hz); if (v > 20.0 && v < 1000.0) return 1.0 / v; }
    CGDirectDisplayID display = CGMainDisplayID();
    if (CGDisplayModeRef mode = CGDisplayCopyDisplayMode(display)) {
        const double hz = CGDisplayModeGetRefreshRate(mode);
        CGDisplayModeRelease(mode);
        if (hz > 20.0 && hz < 1000.0) return 1.0 / hz;
    }
    return 0.0;
}

int  g_budgetMB = 0;                 // 0 = unlimited
std::atomic<uint64_t> g_peakFootprintMB{0};
std::atomic<bool>     g_overBudget{false};

double currentFootprintMB() {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS)
        return 0.0;
    return info.phys_footprint / 1048576.0;
}

std::atomic<uint64_t> g_latencySamples{0};
std::atomic<uint64_t> g_latencyTotalUs{0};
std::atomic<uint64_t> g_latencyMaxUs{0};

// --- Overlay ------------------------------------------------------------------
// Apple's Metal HUD reports everything it knows and offers no supported way to ask
// for less, which is why "show me the frame rate" arrived as a wall of numbers.
// Anvil already touches every presented frame, so it draws its own.
bool   g_overlayOn = false;
int    g_overlayCorner = 0;        // 0 TL, 1 TR, 2 BL, 3 BR
int    g_overlayScale = 3;
bool   g_overlayThermal = false;   // the counter's plate red while the Mac is hot (ANVIL_OVERLAY_THERMAL)
float  overlayCornerParam();       // the corner for the shaders, plus 4 while the Mac is hot (below g_powerFlags)
double g_fpsSmoothed = 0.0;        // frames the *game* renders, per second
double g_lastOverlayTime = 0.0;

// --- What actually reached the screen -----------------------------------------
// Counting submissions is not evidence. A drawable that is presented can still be
// superseded before the display picks it up, and with frame generation the whole
// question is whether the synthesised frames are being shown or thrown away — a
// pipeline that generates diligently and displays nothing looks identical from
// inside the process.
//
// `addPresentedHandler:` fires when a frame is actually put on the display, with
// the time it happened. That is the only number worth calling a frame rate once
// frame generation is on, so it is what the overlay shows.
std::atomic<uint64_t> g_shownReal{0};
std::atomic<uint64_t> g_shownGenerated{0};
double g_displayedFPS = 0.0;
// Frames over time, not the mean of 1/gap (0.57): 8.3 and 16.7 ms in turn are 80 a second, and read 90 that way — the
// overlay showed LEGO Star Wars' juddering 80 as 91 and its even 80 as a drop to 80. The overlay's figure is the mean gap's;
// the stats line's, the window's frames over its time (a loading pause of a quarter second or more left out, as Guardian does).
double g_shownMeanGap = 0.0;
double g_windowShownSec = 0.0;
uint64_t g_windowShownN = 0;
double g_lastShownTime = 0.0;
std::mutex g_shownLock;

// Evenness, which is what "no stutter" actually means. An average frame rate hides
// the thing being complained about: 120 fps made of alternating 4 ms and 12 ms gaps
// averages exactly the same as a steady 8.3 ms and looks nothing like it.
std::atomic<uint64_t> g_shownIntervals{0};   // displayed gaps measured
std::atomic<uint64_t> g_shownOnBeat{0};      // gaps within a quarter refresh of target
std::atomic<uint64_t> g_shownSteady{0};      // gaps within a fifth of the running average gap
double                g_shownGapEma = 0.0;

// --- Variable refresh -----------------------------------------------------------
// The MacBook Pro's ProMotion panel refreshes when a frame arrives, anywhere from 24 to
// 120 times a second, the way G-Sync and FreeSync do. Measured in Cat Quest II's menu,
// which caps itself at 80: every displayed gap was exactly 12.5 ms — a fixed 120 Hz
// panel can only show multiples of 8.33 ms.
//
// Anvil's grid fought that. Below 120 it rounded every frame up to the next 8.33 ms
// step from the last one, so a 13 ms frame waited for 16.7: frames 8.3 and 16.7 ms
// apart in no pattern, which is the stutter in fights, and which frame generation was
// then asked to paper over with guessed frames — the glitches. On a variable-refresh
// panel a game below the display rate is now shown each frame as it is ready, no
// sooner than just under its own average frame time, and the panel follows it.
// Real frames only, evenly spaced, no added wait.
int      g_vrrState     = -1;      // -1 unknown, 0 fixed refresh, 1 variable, 2 looking again
bool     g_smoothMotion = false;   // ANVIL_SMOOTH_MOTION=1: Smooth Motion allowed (with frame generation chosen)
bool     g_fill         = false;   // generating in Smooth Motion: halfway between frames shown as ready
double   g_fillOutSeconds = 0.0;   // how long the game has been outside Smooth Motion's band
// What the display says it can do, whatever the looks at it find. A ProMotion panel is judged
// "doesn't follow" in some sessions' first seconds and following on a later look (above); the
// player's generated frames follow its rules from the start, not a fixed display's.
bool     g_vrrReported  = false;
bool     g_vrrActive    = false;   // frames currently shown as ready rather than on the grid
bool     g_vrrVerified  = false;   // a displayed gap has proved the panel follows the game
uint64_t g_vrrOffGrid   = 0;       // displayed gaps that were not a whole number of refreshes
uint64_t g_vrrChecked   = 0;       // gaps looked at while the game's own time was between steps
// The same panel follows the game in one session and not in the next: LEGO Star Wars on
// 1–2 October, nine sessions confirmed and six not, alike in every setting. The look is
// made in the first seconds, on a loading screen, often while another app is in front. A
// "doesn't follow" is looked at again — after 10 s, then 30 s, 1, 2, 4 and 8 minutes — with
// frames shown as ready and nothing held, which a fixed panel shows no differently. The first
// look again came after 30 s until 0.39: on 10 October LEGO Star Wars was judged fixed 3 s into
// its first hold at 80, was confirmed following on the next look, and spent the 30 s between
// on the fixed grid at 96–120 fps — a refresh missed in one gap of three.
double   g_vrrRetryAt   = 0.0;
int      g_vrrRetries   = 0;
// ANVIL_VRR_KNOWN: Anvil has seen this display follow games in earlier sessions (DisplayProfile).
// With macOS reporting it variable too, it is taken as following from the start: the look made
// on a loading screen at the display's own rate can't tell, and judged fixed there, a game's
// first minutes were held to the 120 Hz grid (LEGO Star Wars, 12 October: four minutes).
bool     g_vrrKnown     = false;
/// macOS's answer about the display, applied: variable and already known to follow games, it is
/// confirmed at once.
void applyReportedRefresh(int v, const char* when) {
    if (v == 1) g_vrrReported = true;
    if (v == 1 && g_vrrKnown && !g_vrrVerified) {
        g_vrrState = 1;
        g_vrrVerified = true;
        diag("[anvil] the display follows games' own frame rates — confirmed in earlier sessions on this Mac, so frames are "
             "shown as they're ready from the start (%s)", when);
    }
}
constexpr int kVrrRetriesMax = 6;

/// When to look again after the `retries`-th "doesn't follow" (0 for the first).
double vrrRetryDelay(int retries) { return retries <= 0 ? 10.0 : 30.0 * (double)(1 << (retries - 1)); }
std::atomic<uint64_t> g_vrrFrames{0};   // real frames shown as ready, this window
std::atomic<uint64_t> g_realFrames{0};  // real frames, this window
// Frames handed to the display that it never showed — replaced by a newer one before their
// refresh. On 3 October LEGO Star Wars, started offline, handed over 600 frames for every 450
// shown on its loading screen; this says whether they were dropped there or went elsewhere.
std::atomic<uint64_t> g_notShown{0};
/// Frames presented while another app was in front, and the rate they are held to then.
std::atomic<uint64_t> g_behindFrames{0};
constexpr double kBehindPeriod = 1.0 / 30.0;
// Behind for two minutes — the game's loading done, Hogwarts Legacy's in 45 s and LEGO Star Wars' in 40 — 10 fps; with
// the screen locked or asleep, 5. Hogwarts Legacy drew 28 fps for half an hour behind Chrome on 22 October and for
// three hours behind a locked screen the night before, on battery.
constexpr double kBehindLongAfter = 120.0, kBehindLongPeriod = 1.0 / 10.0, kAwayPeriod = 1.0 / 5.0;
// Nothing held for the first two seconds behind: on 23 October Hogwarts Legacy lost the front for a second 24 times in
// 45 minutes of play — the Finder's desktop or Anvil's hidden window, clicked by a stray tap — and each dropped it to
// 30 fps there and then, seen as a stutter.
constexpr double kBehindGrace = 2.0;

/// One frame in how long, behind another app: none held the first two seconds, then 30 a second, 10 after two
/// minutes, 5 with nobody watching. 0 for no hold.
double behindPeriod(double now) {
    if (anvil_screen_away()) return kAwayPeriod;
    const double behind = anvil_behind_seconds(now);
    if (behind < kBehindGrace) return 0.0;
    return behind >= kBehindLongAfter ? kBehindLongPeriod : kBehindPeriod;
}
double   g_ownEma       = 0.0;     // smoothed own frame time, for the pacing choice
double   g_presentEma   = 0.0;     // smoothed time between the game's own presents
// Generated frames are only considered below this on a variable-refresh panel. It was
// 48; LEGO Star Wars dips to the mid-40s in heavy scenes, and a guessed frame spread over
// that much motion is the distortion that was reported. ProMotion follows a game down to
// 24 Hz, so on such a panel Anvil now leaves every frame the game's own.
constexpr double kVrrFloorFPS = 24.0;

// --- Steady 80 (ANVIL_TARGET_FPS=80, variable-refresh panels) ---------------------
// ProMotion shows frames on a 240 Hz grid, so the only even rates below 120 are 80,
// 60 and 48. A game between 80 and ~108 fps shown as ready alternates 8.3 and 12.5 ms
// gaps. This holds such a game to an even 12.5 ms instead, and lets it go the moment
// it could do 120 again, which is where the 0.13.0 lock at 80 went wrong: that one
// held frames on the display side, so the queue behind the hold made the game look
// no faster than 80 and it never climbed back.
//
// Here the hold is a frame limiter on the game's own thread: its present waits until
// the next 12.5 ms point on an 80 Hz cadence, so nothing queues behind the display and
// the frame's latency stays what the game's own work costs. The wait is known exactly,
// so what the game spent working is known too: when that drops below what 120 needs,
// a half-second look at the game unheld confirms it and it goes back to 120.
//
// Modelled on the 240 Hz grid (Tools: steady_model3.py): at 93 fps 99% of gaps even
// instead of 58%, input to screen 15 ms instead of 13; at 104 fps jittery 100% even at
// 80 instead of 70% at 104. That last trade showed 80 where the game could show 100, and
// since 0.24 the hold covers only a game below about 94 (kHoldBelow, below).
enum class Steady { off, full, hold, probe, low };
Steady   g_steady        = Steady::off;
double   g_steadySince   = 0.0;
// The start. A game's first half minute is logos, intros and loading, its pace swinging every
// second or two: on 10 October Cat Quest II was held to 80 and let go to 120 nine times in its
// first 30 s — each a change of cadence the player sees as a hitch — and from then on ran an
// unbroken 120. So until the start has settled nothing is held and nothing probed: below the
// display's rate each frame is shown as it is ready, which a variable-refresh panel follows.
// ANVIL_STEADY_SETTLE sets the seconds (0 for none).
double   g_steadySettleSec = 30.0;
double   g_steadyStartAt   = -1.0;   // the first present Steady saw this session
bool     g_steadySettled   = false;
double   g_probeEnd      = 0.0;
double   g_cadence       = 0.0;      // the next present time on the 80 Hz cadence
double   g_workEma       = 0.0;      // the game's own frame time, holds excluded
double   g_resumedAt     = 0.0;      // when the game's thread left the last present
double   g_holdWaitSec   = 0.0;      // time held in the last present, for the log
std::atomic<uint64_t> g_heldFrames{0};
constexpr int kPresentRing = 256;
double   g_presentRing[kPresentRing];
int      g_presentHead   = 0;
int      g_presentCount  = 0;

// --- The even 80 on the panel (0.57) ---------------------------------------------------
// The panel shows a held frame 12.5 ms after the last only while it follows the game. On 16
// October LEGO Star Wars was held to 80 in 459 of its windows and in 42% of them the frames
// reached the screen 8.3 and 16.7 ms apart in turn — every frame on the panel's own 120 Hz
// steps, an average 80 that judders — for as long as nine minutes at a time, with nothing
// changed in Anvil either side (the overlay read 91, the mean of 120 and 60). Measured in a
// stand-in on this Mac (17 October): a late frame, or frames ready well before their point, can
// tip the panel onto its own steps, and it comes back when it will — runs of the same stand-in
// read anything from 1% to 100% even. Tried and left out, as the panel paid no attention: the
// cadence nudged sooner whenever a held frame came a step late (93–97% even when presenting
// directly, but 37–99% through Anvil's FSR, which made frames queue and the game wait), and held
// frames presented only once the GPU had finished them (36–76%, 15 ms more latency). Kept: the
// panel is asked for 10.5 ms rather than 12.0, which still lands on the 12.5 ms step and is less
// easily pushed to the 16.7 one (82% even after a late frame against 56% presenting directly;
// 70% of held stretches against 60% through Anvil). g_holdLag, a held frame's wait from its
// present to the screen, goes in the log.
std::atomic<double> g_holdLag{0.0};

/// What a held frame asks the panel for: no sooner than this after the last one shown.
double steadyHoldMinGap() { return std::max(g_refreshPeriod + 0.0005, 1.5 * g_refreshPeriod - 0.002); }

// --- Load, for the log --------------------------------------------------------------
// Whether a slow stretch is the GPU or one busy thread decides what would help, and the
// frame rate alone cannot say. Read off the render thread, once a window.
std::atomic<int> g_gpuBusy{-1};          // IOAccelerator "Device Utilization %"
std::atomic<int> g_topThreadBusy{-1};    // busiest thread in the game, % of one core
std::atomic<int> g_nextThreadBusy{-1};   // the one after it
double g_worstGapMs = 0.0;                   // longest single gap seen

// --- Probing for 120 from the hold --------------------------------------------------
// The hold sees the game's work on the CPU, not the GPU's. Held at 80, a frame the GPU
// needs 10.5 ms for finishes with time to spare, so the work reads 8.2 ms — fast enough
// for 120 — while the game unheld can make 95. LEGO Star Wars on 30 September probed
// every 1.5–2 seconds for minutes on end, each probe failing within half a second and
// each one half a second of uneven frames. The GPU's own utilisation says beforehand
// what the probe would find: at 80 fps and 84% busy it has room for 95, not 120. And a
// probe that fails anyway waits 4 seconds, then twice as long each time, up to 16.
std::atomic<int>    g_gpuNow{-1};        // GPU utilisation, sampled twice a second while held
std::atomic<double> g_gpuNowAt{0.0};
double   g_gpuAskedAt    = 0.0;
double   g_nextProbeAt   = 0.0;
double   g_lastProbeAt   = 0.0;
double   g_probeBackoff  = 0.0;
// LEGO Star Wars on 3 October, hovering between 95 and 110: each probe found 120, held it
// five to twelve seconds and fell back to 80 — past the four seconds that counted as a failed
// probe, so the back-off never grew and the rate changed every few seconds for minutes, each
// change a stutter. A fall from the full rate within 15 s of reaching it is now a failed
// probe, and the back-off grows to a minute.
constexpr double kProbeBackoffMax = 60.0;
constexpr double kFallWithin = 15.0;
// 0.16 in LEGO Star Wars: probes that did find 120 — for the half second after the hold
// let go, while the frames it had held back went out at once — and a second later the
// game was at 107 and back to 80. Twenty-three changes a minute. So a probe now lasts a
// second and is judged on its last 0.6 s, after that rush; a fall from 120 within a few
// seconds of reaching it counts as a failed probe; and a GPU reading that has promised
// room it didn't have is no longer allowed to skip the back-off.
double   g_promotedAt    = -1.0;     // when 120 was last reached from below
bool     g_gpuMisled     = false;    // the GPU reading promised room that wasn't there
double   g_overSince     = -1.0;     // since when the held game's work has been too long for 80
// LEGO Star Wars on 2 October, in a heavy stretch swinging between 44 and 97 fps: held,
// let go 1.3 s later, held again 2 s after that, let go again — six changes in ten seconds,
// each one a lurch. A hold that has to let go within 10 s waits 5 s before the next, then
// twice as long each time up to a minute; twenty seconds held clears it. Until 0.40 only a hold
// under 3 s counted, up to 20 s, and ten seconds cleared it: on 10 October, on battery, LEGO
// hovered at 64–86 fps and was held and let go 74 times in 40 minutes — ten in one minute —
// its holds lasting 1 to 7 s.
double   g_holdBackoff   = 0.0;
double   g_nextHoldAt    = 0.0;
constexpr double kHoldBackoffMax = 60.0;
constexpr double kShortHold = 10.0;     // a hold let go sooner than this counts against the next
constexpr double kHoldClears = 20.0;    // and one this long clears the back-off
// However busy the GPU reads — another app can be using it — a probe still happens this
// often, so a game that could make 120 is never kept at 80 by a reading. Once any back-off
// earned by failed probes has passed: it used to override that too, and a game hovering
// between 90 and 105 was probed every 20 s however often it had fallen back.
constexpr double kProbeAtLeastEvery = 20.0;
// Where the hold starts and stops, as shares of the panel's top rate. It held everything
// from 80 to 108 fps at an even 80 and let go only for a game ready to make 119 — so a
// game able to make 100 was shown at 80, all session. Asked for the best frame rate, the
// hold now keeps only a game below about 94 at an even 80, where showing it as ready
// gains a few frames and loses the evenness; from about 98 the game runs at its own rate,
// shown as ready, up to the panel's 120. The gap between the two keeps a game near the
// line from flipping.
constexpr double kHoldBelow = 0.78;   // 93.6 fps at 120 Hz, 112 at 144
constexpr double kFreeAt    = 0.82;   // 98.4 fps at 120 Hz, 118 at 144

// --- Long sessions ----------------------------------------------------------------------
// Hours of play on a MacBook: on battery, in Low Power Mode or with the Mac hot, frames past
// an even 80 cost power and heat for little. On 3 October LEGO Star Wars, let run at 95–110,
// kept the GPU 90–100% busy. Long sessions (ANVIL_ENDURANCE: automatic, the default — on
// battery, in Low Power Mode or hot; 1 always; 0 never) hold an even 80 with no looking for
// 120, and leave FSR 3 a smaller share of the GPU (fsr3Govern). A hot Mac also gets FSR 1 in
// place of FSR 3 until it cools. Read every 5 s off the game's threads (watchPower).
int g_enduranceSetting = 2;                       // 0 never, 1 always, 2 automatic
constexpr int kOnBattery = 1, kLowPower = 2, kHot = 4;
std::atomic<int>  g_powerFlags{0};
std::atomic<bool> g_endurance{false};

bool enduranceOn() { return g_endurance.load(std::memory_order_relaxed); }
float overlayCornerParam() {
    const bool hot = g_overlayThermal && (g_powerFlags.load(std::memory_order_relaxed) & kHot) != 0;
    return (float)(std::clamp(g_overlayCorner, 0, 3) + (hot ? 4 : 0));
}
bool macHot() { return g_enduranceSetting != 0 && (g_powerFlags.load(std::memory_order_relaxed) & kHot) != 0; }

/// Whether long sessions apply, for this setting and these readings.
bool enduranceFor(int setting, int flags) {
    if (setting == 0) return false;
    return setting == 1 || (flags & (kOnBattery | kLowPower | kHot)) != 0;
}

const char* enduranceWhy(int flags) {
    if (flags & kHot) return "the Mac is hot";
    if (flags & kLowPower) return "Low Power Mode is on";
    if (flags & kOnBattery) return "on battery";
    return "set to always in Anvil";
}

/// Where the power comes from, Low Power Mode, and how hot the Mac is.
int readPowerFlags() {
    int flags = 0;
#ifndef ANVIL_INJECT_TEST
    if (CFTypeRef info = IOPSCopyPowerSourcesInfo()) {
        if (CFStringRef type = IOPSGetProvidingPowerSourceType(info))
            if (CFStringCompare(type, CFSTR(kIOPSBatteryPowerValue), 0) == kCFCompareEqualTo) flags |= kOnBattery;
        CFRelease(info);
    }
    NSProcessInfo* process = [NSProcessInfo processInfo];
    if (process.lowPowerModeEnabled) flags |= kLowPower;
    if (process.thermalState >= NSProcessInfoThermalStateSerious) flags |= kHot;
#endif
    return flags;
}

/// A fresh reading: long sessions on or off, said in the game log when that changes.
void notePowerFlags(int flags) {
    const int before = g_powerFlags.exchange(flags);
    const bool was = g_endurance.load(), on = enduranceFor(g_enduranceSetting, flags);
    g_endurance.store(on);
    const double period = g_refreshPeriod > 0.0 ? g_refreshPeriod : 1.0 / 120.0;
    const int full = (int)lround(1.0 / period), hold = (int)lround(1.0 / (1.5 * period));
    if (on && !was)
        diag("[anvil] long sessions: %s — an even %d with no looking for %d, and FSR 3 only in the GPU's spare time, "
             "so the battery and the Mac last", enduranceWhy(flags), hold, full);
    else if (!on && was)
        diag("[anvil] long sessions: off — %s; up to %d again when the game can", (flags & kOnBattery) ? "cooler again" : "plugged in", full);
    if (g_enduranceSetting != 0 && ((flags ^ before) & kHot)) {
        if (flags & kHot) diag("[anvil] the Mac is hot (thermal state serious or worse): an even %d, and FSR 1 in place of FSR 3 until it cools", hold);
        else diag("[anvil] the Mac has cooled: FSR 3 again when the GPU has room");
    }
}

/// From the game's first frame, every 5 s for the session.
void watchPower() {
#ifndef ANVIL_INJECT_TEST
    static std::atomic<bool> started{false};
    if (started.exchange(true)) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ notePowerFlags(readPowerFlags()); });
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                     dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    if (!timer) return;
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), 5 * NSEC_PER_SEC, NSEC_PER_SEC);
    dispatch_source_set_event_handler(timer, ^{ notePowerFlags(readPowerFlags()); });
    dispatch_resume(timer);                       // kept for the session
#endif
}

// A histogram of displayed frame gaps, so the 1% low can be reported.
//
// The 1% low is the number that answers "is it stable", and an average cannot: a
// run that spends 99% of its time at 120 fps and the rest at 30 still averages
// close to 120. Anvil measures the 99th-percentile gap between frames the display
// actually showed and reports it as a frame rate, which is what a 1% low is.
constexpr int    kGapBuckets = 400;          // 0.25 ms each, up to 100 ms
constexpr double kGapBucketMs = 0.25;
std::atomic<uint32_t> g_gapHistogram[kGapBuckets];

// The window's displayed gaps at the middle and the 90th percentile, as onePercentLowFPS last read
// them: how evenly frames reached the screen, where an average says nothing — Smooth Motion's made
// and real frames alternating 16.7 and 20.8 ms on the panel's 240 Hz steps read "16.7 and 20.8".
double g_gapP50Ms = 0.0, g_gapP90Ms = 0.0;

double onePercentLowFPS() {
    uint64_t total = 0;
    uint32_t counts[kGapBuckets];
    for (int i = 0; i < kGapBuckets; ++i) {
        counts[i] = g_gapHistogram[i].exchange(0, std::memory_order_relaxed);
        total += counts[i];
    }
    g_gapP50Ms = g_gapP90Ms = 0.0;
    if (total < 100) return 0.0;             // too few samples to mean anything
    {
        uint64_t seen = 0;
        for (int i = 0; i < kGapBuckets; ++i) {
            seen += counts[i];
            if (g_gapP50Ms <= 0.0 && seen * 2 >= total) g_gapP50Ms = (i + 0.5) * kGapBucketMs;
            if (seen * 10 >= total * 9) { g_gapP90Ms = (i + 0.5) * kGapBucketMs; break; }
        }
    }

    // Walk down from the slowest frames until 1% of them have been counted. The
    // bucket that lands in is the 99th-percentile gap.
    const uint64_t want = total / 100;
    uint64_t seen = 0;
    for (int i = kGapBuckets - 1; i >= 0; --i) {
        seen += counts[i];
        if (seen >= want) {
            const double gapMs = (i + 1) * kGapBucketMs;
            return (gapMs > 0.0) ? 1000.0 / gapMs : 0.0;
        }
    }
    return 0.0;
}

void noteShown(bool generated, double when) {
    // Any presented time is, by definition, on the panel's grid.
    if (when > 0.0) g_gridPhase = when;

    if (generated) g_shownGenerated.fetch_add(1, std::memory_order_relaxed);
    else           g_shownReal.fetch_add(1, std::memory_order_relaxed);

    std::lock_guard<std::mutex> lock(g_shownLock);
    if (g_lastShownTime > 0.0) {
        const double dt = when - g_lastShownTime;
        // A presented handler can fire twice for the same refresh; anything under
        // half a 240 Hz interval is not a separate displayed frame.
        if (dt > 0.002 && dt < 1.0) {
            // Guardian's window: frames on the screen and how evenly (a loading pause left out of the gaps).
            g_gShownN += 1.0;
            if (dt < 0.25) { g_gGapN += 1.0; g_gGapSum += dt * 1000.0; g_gGapSq += dt * dt * 1e6; }
            const double gap = std::min(dt, 0.25);
            g_shownMeanGap = g_shownMeanGap > 0.0 ? g_shownMeanGap * 0.92 + gap * 0.08 : gap;
            g_displayedFPS = 1.0 / g_shownMeanGap;
            if (dt < 0.25) { g_windowShownSec += dt; ++g_windowShownN; }

            if (g_refreshPeriod > 0.0) {
                g_shownIntervals.fetch_add(1, std::memory_order_relaxed);
                // On the beat means one refresh apart, give or take a quarter of one.
                if (fabs(dt - g_refreshPeriod) < g_refreshPeriod * 0.25) {
                    g_shownOnBeat.fetch_add(1, std::memory_order_relaxed);
                }
                // Steady means close to the running average gap, whatever it is. On a
                // variable-refresh panel an even 80 fps is 12.5 ms every time and never
                // "on the beat", so both are reported.
                if (g_shownGapEma > 0.0 && fabs(dt - g_shownGapEma) <= g_shownGapEma * 0.2) {
                    g_shownSteady.fetch_add(1, std::memory_order_relaxed);
                }
                g_shownGapEma = (g_shownGapEma > 0.0) ? g_shownGapEma * 0.9 + dt * 0.1 : dt;
                // Does the panel follow the game? Only asked while the game is *handing
                // over* frames between two refresh steps, where a fixed panel would have to
                // round and a variable one does not. This read the game's work time before,
                // and a game with its own vsync — LEGO Star Wars locks itself to 60 — works
                // for 18 ms but presents every 16.7: its frames were on the grid because it
                // put them there, and the panel was wrongly judged fixed.
                if (g_vrrActive && !g_vrrVerified && g_vrrState != 0 && g_presentEma > 0.0 && anvil_game_in_front()) {
                    const double own = g_presentEma / g_refreshPeriod;
                    if (fabs(own - round(own)) > 0.2) {
                        ++g_vrrChecked;
                        const double r = dt / g_refreshPeriod;
                        if (r > 1.1 && fabs(r - round(r)) > 0.2) ++g_vrrOffGrid;
                        if (g_vrrOffGrid >= 20) {
                            g_vrrVerified = true;
                            g_vrrState = 1;
                            diag("[anvil] the display follows the game's own frame rate (variable refresh confirmed)");
                        } else if (g_vrrChecked >= 360) {
                            g_vrrState = 0;
                            g_vrrActive = false;
                            const bool again = g_vrrRetries < kVrrRetriesMax;
                            if (again) g_vrrRetryAt = when + vrrRetryDelay(g_vrrRetries);
                            ++g_vrrRetries;
                            diag("[anvil] the display did not follow the game (%llu of %llu gaps off the refresh grid) "
                                 "— back to the fixed grid%s", (unsigned long long)g_vrrOffGrid,
                                 (unsigned long long)g_vrrChecked,
                                 again ? (g_vrrRetries == 1 ? ", looked at again in 10 s" : ", looked at again later") : "");
                        }
                    }
                }
                const double ms = dt * 1000.0;
                if (ms > g_worstGapMs) g_worstGapMs = ms;

                // A gap of about two refreshes is a missed slot. A gap of hundreds of
                // milliseconds is the game loading, and says nothing about queue depth.
                if (dt > g_refreshPeriod * 1.5 && dt < g_refreshPeriod * 3.5) {
                    g_nearMisses.fetch_add(1, std::memory_order_relaxed);
                }

                int bucket = (int)(ms / kGapBucketMs);
                if (bucket < 0) bucket = 0;
                if (bucket >= kGapBuckets) bucket = kGapBuckets - 1;
                g_gapHistogram[bucket].fetch_add(1, std::memory_order_relaxed);
            }
        }
    }
    if (when > g_lastShownTime) g_lastShownTime = when;
}

bool  g_ready     = false;

/// Set once the drawable has been inspected. A hook that cannot legally touch a
/// game's frames must do nothing at all rather than take the game down with it.
bool  g_canWrite  = false;
/// An sRGB drawable FSR to the display can write through a plain view (see inspectDrawable).
bool  g_viewWrite = false;
bool  g_inspected = false;

/// Metal treats an illegal texture write as a fatal validation error, not a
/// recoverable one, so every capability is checked before the first write rather
/// than discovered by crashing.
void inspectDrawable(id<MTLTexture> target) {
    if (g_inspected) return;
    g_inspected = true;

    const MTLPixelFormat fmt = target.pixelFormat;
    const bool isSRGB = (fmt == MTLPixelFormatBGRA8Unorm_sRGB ||
                         fmt == MTLPixelFormatRGBA8Unorm_sRGB ||
                         fmt == MTLPixelFormatBGR10_XR_sRGB ||
                         fmt == MTLPixelFormatBGRA10_XR_sRGB);
    const bool writable = (target.usage & MTLTextureUsageShaderWrite) != 0;

    // Anvil's passes on the game's own frame write straight into the drawable, and an sRGB
    // one is left alone there. The layer's framebufferOnly flag is cleared earlier, which is
    // what grants shaderWrite; when a game configures its layer some other way, that grant
    // never arrives.
    g_canWrite = writable && !isSRGB;
    // FSR to the display writes an sRGB drawable through a plain view of the same pixels —
    // the picture as encoded, which is where AMD says FSR belongs. A drawable with
    // framebufferOnly off allows the view (usage 0x17 on an M4, 3 October).
    g_viewWrite = writable && isSRGB && (target.usage & MTLTextureUsagePixelFormatView) != 0;

    os_log(OS_LOG_DEFAULT,
           "[anvil] drawable %lux%lu format=%lu writable=%d srgb=%d -> pipeline %{public}s",
           (unsigned long)target.width, (unsigned long)target.height,
           (unsigned long)fmt, writable, isSRGB,
           g_canWrite ? "active" : "disabled (frames left untouched)");
    diag("[anvil] drawable %lux%lu format=%lu writable=%d srgb=%d -> %s",
         (unsigned long)target.width, (unsigned long)target.height,
         (unsigned long)fmt, writable, isSRGB,
         g_canWrite ? "ACTIVE" : "DISABLED (frames untouched)");
    // The game is drawing: say once whether its window fills the screen.
    anvil_report_window_fit();
    // And later, every window it has open: what a game stuck on one screen is waiting for.
    anvil_report_windows_later();
    // And whether it is the app in front, which decides its frame rate while it isn't.
    anvil_watch_front();
    // And the power and heat that decide a long session.
    watchPower();

    if (!g_canWrite && !g_viewWrite) {
        // Everything downstream reads these, so clearing them here disables the
        // whole pipeline in one place.
        g_frameGen = false;
        g_renderScale = 1.0f;
    }
}

void readEnvironment() {
    if (const char* e = getenv("ANVIL_HOOK_ENABLED")) g_enabled = (e[0] == '1');
    if (const char* s = getenv("ANVIL_SHARPNESS"))    g_sharpness = atof(s);
    if (const char* f = getenv("ANVIL_FRAME_GEN"))    g_frameGen = (f[0] == '1');
    if (const char* d = getenv("ANVIL_MAX_DRAWABLES")) g_maxDrawables = atoi(d);
    if (const char* v = getenv("ANVIL_DISPLAY_SYNC"))  g_displaySync = atoi(v);
    if (const char* m = getenv("ANVIL_MEASURE"))       g_measure = (m[0] == '1');
    if (const char* b = getenv("ANVIL_MEMORY_BUDGET_MB")) g_budgetMB = atoi(b);
    if (const char* p = getenv("ANVIL_PACING")) g_pacing = (p[0] == '1');
    if (const char* c = getenv("ANVIL_CAPTURE_STALLS")) g_captureStalls = (c[0] == '1');
    if (const char* t = getenv("ANVIL_TARGET_FPS")) g_targetFPS = atoi(t);
    if (const char* a = getenv("ANVIL_ADAPTIVE")) g_adaptive = (a[0] == '1');
    if (const char* l = getenv("ANVIL_LOW_LATENCY")) g_lowLatency = (l[0] == '1');
    if (const char* o = getenv("ANVIL_OUTPUT")) g_outputWanted = (o[0] == '1');
    if (const char* o = getenv("ANVIL_OUTPUT_ANY_CALLER")) g_outputAnyCaller = (o[0] == '1');
    if (const char* f = getenv("ANVIL_FRAME_GEN_FORCE")) g_genForce = (f[0] == '1');
    if (const char* a = getenv("ANVIL_SHADER_ARCHIVE")) strlcpy(g_archivePath, a, sizeof(g_archivePath));
    if (const char* fp = getenv("ANVIL_FSR_PASS")) g_fsrPass = strcmp(fp, "fused") == 0 ? kAnvilFSRFused : kAnvilFSRSplit;
    if (const char* f3 = getenv("ANVIL_FSR3")) g_fsr3Wanted = (f3[0] == '1');
    if (const char* f3n = getenv("ANVIL_FSR3_NATIVE")) g_fsr3Native = (f3n[0] == '1');
    // How many frames FSR 3 blends at most: fewer for a game that smooths its own edges (Launcher).
    if (const char* f3f = getenv("ANVIL_FSR3_FRAMES")) {
        const double frames = atof(f3f);
        if (frames >= 2.0 && frames <= 16.0) g_fsr3.maxFrames = (float)frames;
    }
    if (const char* f3x = getenv("ANVIL_FSR3_EXTRA_MS")) {
        const double ms = atof(f3x);
        if (ms >= 0.3 && ms <= 8.0) g_fsr3ExtraMs = ms;
    }
    if (const char* en = getenv("ANVIL_ENDURANCE")) g_enduranceSetting = en[0] == '0' ? 0 : en[0] == '1' ? 1 : 2;
    if (const char* v = getenv("ANVIL_STEADY_SETTLE")) g_steadySettleSec = std::max(0.0, atof(v));
    if (const char* ft = getenv("ANVIL_FSR_TILE")) {
        unsigned tw = 0, th = 0;
        if (sscanf(ft, "%ux%u", &tw, &th) == 2 && tw >= 4 && th >= 4 && tw * th <= 1024)
            g_fusedShape = MTLSizeMake(tw, th, 1);
    }
    g_frameGenRequested = g_frameGen;

    g_refreshPeriod = displayRefreshPeriod();
    if (g_refreshPeriod <= 0.0) g_refreshPeriod = 1.0 / 120.0;

    // One slot per refresh, always. There is no "frame generation mode": the game is
    // never held below what it can do, and a synthesised frame is only ever put in a
    // slot the game left empty. A title that can hold 120 fills every slot itself and
    // nothing is generated at all — which is the best outcome, because a real frame
    // beats a guessed one and costs less latency.
    // 80 is not a grid rate on a 120 Hz panel; it is the steady mode, which runs on
    // top of the display's own rate.
    g_steadyWanted = (g_targetFPS == 80);
    double displayTarget = (g_targetFPS > 0 && !g_steadyWanted) ? (double)g_targetFPS : (1.0 / g_refreshPeriod);
    if (displayTarget > 1.0 / g_refreshPeriod + 0.5) displayTarget = 1.0 / g_refreshPeriod;
    g_realSlotPeriod = 1.0 / displayTarget;
    g_fullSlotPeriod = g_realSlotPeriod;

    diag("[anvil] display %.1f Hz — locking to %.0f fps (one frame every %.2f ms); "
         "generation fills only the slots the game leaves empty",
         1.0 / g_refreshPeriod, displayTarget, g_realSlotPeriod * 1000.0);
    // AppKit only on the main thread. Read anywhere else — at a game's first thread, see
    // anvil_ensure_setup — it is asked later, on the main queue, when the present hook goes in.
    if (const char* k = getenv("ANVIL_VRR_KNOWN")) g_vrrKnown = k[0] == '1';
    if (const char* m = getenv("ANVIL_SMOOTH_MOTION")) g_smoothMotion = m[0] == '1';
    if (const char* m = getenv("ANVIL_SMOOTH_MOTION_MID")) g_midWanted = m[0] != '0';
    if (const char* m = getenv("ANVIL_MID_DEBUG")) g_midDebug = atoi(m);
    if (const char* m = getenv("ANVIL_MID_EARLY")) g_midEarly = atoi(m);
    if (const char* m = getenv("ANVIL_MID_IN_FLIGHT")) g_midInFlight = std::clamp(atoi(m), 1, 3);
    if (const char* j = getenv("ANVIL_JIT")) g_jitOn = j[0] != '0';
    if (const char* m = getenv("ANVIL_MID_CHECK")) {
        if (m[0] == '0' && m[1] == 0) g_midCheckOn = false;
        else sscanf(m, "%f,%f,%f", &g_midCheckApart, &g_midCheckShare, &g_midCheckPart);
    }
    // Frames shown for each of the game's at most (2–4; 2 unless asked): for tests of three and four a frame.
    if (const char* m = getenv("ANVIL_MID_MULT_MAX")) g_midMultMax = std::clamp(atoi(m), 2, kMidMultMax);
    if (const char* m = getenv("ANVIL_MID_DL")) g_dlWanted = m[0] != '0';
    // Guardian: on unless ANVIL_GUARDIAN=0; what it learns kept in ANVIL_GUARDIAN_STATE (the app's, one file a
    // game on this Mac); ANVIL_GUARDIAN_FAST=1 runs its checks at a test's pace.
    if (const char* g = getenv("ANVIL_GUARDIAN")) g_guardian = g[0] != '0';
    if (g_guardian) {
        const char* fast = getenv("ANVIL_GUARDIAN_FAST");
        anvil_guardian::configure(getenv("ANVIL_GUARDIAN_STATE"), fast && fast[0] == '1');
        const bool known = anvil_guardian::load();
        char learned[640];
        anvil_guardian::describe(learned, sizeof learned);
        diag("[anvil] guardian: on — checks every few seconds that what Anvil does is working, and learns what runs best "
             "here | on this Mac so far: %s", known ? learned : "nothing yet (a first session)");
    }
    if (pthread_main_np()) { g_vrrState = detectVariableRefresh(); g_vrrReported = g_vrrState == 1; applyReportedRefresh(g_vrrState, "at load"); }
    if (const char* o = getenv("ANVIL_OVERLAY")) g_overlayOn = (o[0] == '1');
    if (const char* m = getenv("ANVIL_METALFX_FRAMEGEN")) g_useMetalFX = (m[0] == '1');
    // Projection is the default; interpolation has to be asked for.
    if (const char* fm = getenv("ANVIL_FRAMEGEN_MODE")) {
        g_useMetalFX = (strcmp(fm, "interpolated") == 0);
    }
    if (const char* fd = getenv("ANVIL_FLOW_DIVISOR")) {
        g_flowDivisor = atoi(fd);
        if (g_flowDivisor < 2 || g_flowDivisor > 16) g_flowDivisor = 4;
    }
    if (const char* is = getenv("ANVIL_INTERP_SCALE")) {
        g_interpScale = atof(is);
        if (g_interpScale < 0.25f || g_interpScale > 1.0f) g_interpScale = 0.5f;
    }
    if (const char* c = getenv("ANVIL_OVERLAY_CORNER")) g_overlayCorner = atoi(c);
    if (const char* z = getenv("ANVIL_OVERLAY_SCALE")) g_overlayScale = std::max(1, atoi(z));
    if (const char* t = getenv("ANVIL_OVERLAY_THERMAL")) g_overlayThermal = (t[0] == '1');
    if (const char* r = getenv("ANVIL_RENDER_SCALE")) {
        g_renderScale = atof(r);
        // Above 1.0 supersamples: the game is handed a larger drawable and renders
        // more pixels, which is the fix when a window is only being given its size
        // in points on a Retina display and everything looks soft.
        if (g_renderScale <= 0.1f || g_renderScale > 2.0f) g_renderScale = 1.0f;
    }
}

/// Time from the app asking for a drawable to that drawable actually being on
/// screen. This is the latency a player feels, and the only number worth tuning
/// against.
void recordLatency(id<CAMetalDrawable> drawable, CFTimeInterval requestedAt) {
    if (!g_measure) return;
    [drawable addPresentedHandler:^(id<MTLDrawable> d) {
        CFTimeInterval shown = d.presentedTime;
        if (shown <= 0) shown = CACurrentMediaTime();
        uint64_t us = (uint64_t)((shown - requestedAt) * 1e6);
        if (us > 5'000'000) return;            // ignore stalls from breakpoints etc.
        g_latencySamples.fetch_add(1);
        g_latencyTotalUs.fetch_add(us);
        uint64_t prev = g_latencyMaxUs.load();
        while (us > prev && !g_latencyMaxUs.compare_exchange_weak(prev, us)) {}
    }];
}

/// Choose the queue depth for this moment and apply it only when it changes —
/// assigning it rebuilds the drawable pool, which is itself a hitch.
void applyDepth(CAMetalLayer* layer) {
    if (!(g_lowLatency && g_pacing)) return;
    const int want = g_generating ? 3 : g_depthFloor;
    if (want == g_appliedDepth) return;
    layer.maximumDrawableCount = want;
    g_appliedDepth = want;
    diag("[anvil] frames in flight: %d (%s)", want - 1,
         g_generating ? "generating needs a spare drawable"
                      : (want == 2 ? "lowest latency" : "the game missed refreshes at 1"));
}

/// Apply the layer-level latency settings once.
void tuneLayer(CAMetalLayer* layer) {
    static bool done = false;
    if (done) return;
    done = true;

    if (!(g_lowLatency && g_pacing) && (g_maxDrawables == 2 || g_maxDrawables == 3)) {
        layer.maximumDrawableCount = g_maxDrawables;
        g_appliedDepth = g_maxDrawables;
        os_log(OS_LOG_DEFAULT, "[anvil] maximumDrawableCount = %d", g_maxDrawables);
    }
    if (g_displaySync >= 0) {
        layer.displaySyncEnabled = (g_displaySync == 1);
        os_log(OS_LOG_DEFAULT, "[anvil] displaySyncEnabled = %d", g_displaySync);
    } else if (g_pacing && !layer.displaySyncEnabled) {
        // Turned off before the hook above could see it (see hookedSetDisplaySyncEnabled).
        layer.displaySyncEnabled = YES;
        diag("[anvil] the game's layer had V-Sync off, which tears — turned on: Anvil paces the frames itself");
    }
    // Presenting inside a CoreAnimation transaction serialises the present with the
    // windowing system and adds a frame; nothing here needs it.
    layer.presentsWithTransaction = NO;

    // A Windows swapchain's alpha channel is ignored — DXGI shows every pixel opaque —
    // and games leave whatever they like in it. A layer that is not opaque would
    // blend by it instead: part-transparent patches wherever a game wrote less than
    // full alpha. Anvil's full-frame pass used to hide that by writing alpha 1 over
    // every pixel; now that the game's frame is left alone, the layer says so itself.
    // Set on the main thread, where Core Animation commits layer changes; this runs on
    // the game's render thread, which has no run loop to commit an implicit one.
    if (!layer.opaque) {
        CAMetalLayer* opaqueLayer = layer;
        dispatch_async(dispatch_get_main_queue(), ^{ opaqueLayer.opaque = YES; });
        diag("[anvil] game layer was not opaque — making it opaque, as a Windows swapchain is");
    }

    // When the game is rendering below native, the compositor performs the scale.
    // Its default is linear; trilinear samples across mip levels and is visibly
    // steadier on fine detail in motion, for no measurable cost.
    if (g_renderScale < 0.999f) {
        layer.magnificationFilter = kCAFilterTrilinear;
        layer.minificationFilter = kCAFilterTrilinear;
    }
}

/// Metal asserts and aborts on a blit between differently-sized textures — it is not
/// an exception, so it cannot be caught. Anvil changes drawableSize at runtime for
/// Retina supersampling and render scaling, which leaves cached textures stale for a
/// frame, so every blit is checked first and simply skipped when it would not match.
bool sameSize(id<MTLTexture> a, id<MTLTexture> b) {
    return a && b
        && a.width == b.width
        && a.height == b.height
        && a.pixelFormat == b.pixelFormat;
}

/// Let go of a Metal object a second from now: a frame already sent to the GPU may still
/// read it, and the game's own command buffers may not hold on to what they use.
void releaseLater(id object) {
    if (!object) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [object release];
    });
}

id<MTLTexture> makeTexture(id<MTLDevice> device, NSUInteger w, NSUInteger h,
                           MTLPixelFormat format) {
    MTLTextureDescriptor* d =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
                                                           width:w height:h mipmapped:NO];
    d.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    d.storageMode = MTLStorageModePrivate;
    return [device newTextureWithDescriptor:d];
}

/// Anvil's shaders, made for one device: every kernel's pipeline, and how they were come by.
struct ShaderSet {
    id<MTLDevice> device = nil;
    id<MTLComputePipelineState> pso[kAnvilKernelCount] = {};
    int made = 0, readyMade = 0;
    bool archive = false;
    double compileMs = 0, pipelinesMs = 0;
};

/// The library compiled (or loaded) and every pipeline made — from Graphics Prep's archive
/// where it has them. Runs on any thread: it touches no global but the settings.
ShaderSet* buildShaderSet(id<MTLDevice> device) {
    ShaderSet* set = new ShaderSet();
    set->device = [device retain];
    id<MTLLibrary> library = AnvilShaderLibrary(device, diag, &set->compileMs);
    if (!library) return set;
    id<MTLBinaryArchive> archive = g_archivePath[0] ? AnvilOpenArchive(device, g_archivePath, diag) : nil;
    set->archive = archive != nil;
    const CFTimeInterval t0 = CACurrentMediaTime();
    for (int k = 0; k < kAnvilKernelCount; k++) {
        bool readyMade = false;
        set->pso[k] = AnvilPipeline(device, library, k, archive, &readyMade);
        if (set->pso[k]) set->made++;
        if (readyMade) set->readyMade++;
    }
    set->pipelinesMs = (CACurrentMediaTime() - t0) * 1000.0;
    [archive release];
    [library release];
    return set;
}

void freeShaderSet(ShaderSet* set) {
    if (!set) return;
    for (int k = 0; k < kAnvilKernelCount; k++) [set->pso[k] release];
    [set->device release];
    delete set;
}

// Shaders compiled in the background from the moment the game opens Metal (see
// AnvilWarmShaders), so its first frame needn't wait for them.
std::atomic<ShaderSet*> g_warmSet{nullptr};
dispatch_semaphore_t g_warmDone = nullptr;
std::atomic<bool> g_warmStarted{false};

/// Build the compute pipelines once, for the device the game draws with.
bool prepare(id<MTLDevice> device) {
    if (g_ready) return g_queue != nil;
    g_ready = true;

    // The queue first, and whatever happens to the shaders below. Pacing, variable
    // refresh, the statistics and the watchdog all live in the present hook, which
    // needs only this — it used to be installed only when the shader library loaded,
    // so a library that failed to compile silently took pacing away as well.
    g_queue = [device newCommandQueue];
    g_device = device;

    // Compiling Anvil's shaders cold takes most of a second (690 ms for the library and
    // 116 ms for its pipelines, measured on an M4 under Rosetta) — which, done here, is
    // a game's first frame held up for it after every Anvil update, or whenever macOS
    // has cleared its shader cache. Started when the game first opens Metal, it is
    // usually done by now; the frame waits only for whatever is left.
    ShaderSet* set = nullptr;
    if (g_warmDone) {
        const CFTimeInterval t0 = CACurrentMediaTime();
        if (dispatch_semaphore_wait(g_warmDone, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC)) == 0) {
            set = g_warmSet.exchange(nullptr);
            const double waited = (CACurrentMediaTime() - t0) * 1000.0;
            if (set && set->device != device) {
                diag("[anvil] shaders: compiled for another GPU than the game draws with — again for this one");
                freeShaderSet(set);
                set = nullptr;
            } else if (set) {
                diag("[anvil] shaders: compiled in the background since the game opened Metal; "
                     "the first frame waited %.0f ms for them", waited);
            }
        } else {
            diag("[anvil] shaders: still compiling in the background after 20 s — compiling them here instead");
        }
    }
    if (!set) set = buildShaderSet(device);
    if (set->made > 0) {
        if (set->archive)
            diag("[anvil] shaders: %d of %d pipelines ready-made from Graphics Prep (%.0f ms), %d compiled",
                 set->readyMade, set->made, set->pipelinesMs, set->made - set->readyMade);
        else
            diag("[anvil] shaders: %d pipelines compiled in %.0f ms", set->made, set->pipelinesMs);
    }

    g_rcas         = set->pso[kAnvilRcas];
    g_easu         = set->pso[kAnvilEasu];
    g_fsrEasu      = set->pso[kAnvilFsrEasu];
    g_fsrFused     = set->pso[kAnvilFsrFused];
    g_overlay      = set->pso[kAnvilOverlay];
    g_finish       = set->pso[kAnvilFinish];
    g_counter      = set->pso[kAnvilCounter];
    g_flowToMotion = set->pso[kAnvilFlowToMotion];
    g_downsample   = set->pso[kAnvilDownsample];
    g_upsample     = set->pso[kAnvilUpsample];
    g_luma         = set->pso[kAnvilLumaPyramid];
    g_flow         = set->pso[kAnvilOpticalFlow];
    g_interp       = set->pso[kAnvilInterpolate];
    g_extrap       = set->pso[kAnvilExtrapolate];
    g_fsr3.luma    = set->pso[kAnvilFsr3Luma];
    g_fsr3.flow    = set->pso[kAnvilOpticalFlow];
    g_fsr3.motion  = set->pso[kAnvilFsr3Motion];
    g_fsr3.settle  = set->pso[kAnvilFsr3Settle];
    g_fsr3.widen   = set->pso[kAnvilFsr3Wide];
    g_fsr3.panCost = set->pso[kAnvilFsr3PanCost];
    g_fsr3.panPick = set->pso[kAnvilFsr3PanPick];
    g_fsr3.panFineCost = set->pso[kAnvilFsr3PanFineCost];
    g_fsr3.panFinePick = set->pso[kAnvilFsr3PanFinePick];
    g_fsr3.resolve = set->pso[kAnvilFsr3Resolve];
    g_midpoint     = set->pso[kAnvilMidpoint];
    g_midCheck     = set->pso[kAnvilMidpointCheck];
    g_midJudge     = set->pso[kAnvilMidpointJudge];
    const bool none = set->made == 0;
    [set->device release];
    delete set;   // its pipelines are the globals' now

    if (none) {
        os_log_error(OS_LOG_DEFAULT, "[anvil] no shader library");
        diag("[anvil] no shader library — frames left untouched, pacing still on");
        g_frameGen = false;
        return g_queue != nil;
    }

    // FSR in one pass, if Graphics Prep chose it: in a shape this GPU takes, else in two.
    if (g_fsrPass == kAnvilFSRFused) {
        const MTLSize shape = AnvilFusedShape(g_fsrFused, device, g_fusedShape);
        if (shape.width == 0) {
            diag("[anvil] FSR: the one-pass version doesn't fit this GPU — two passes, as before");
            g_fsrPass = kAnvilFSRSplit;
        } else {
            g_fusedShape = shape;
            diag("[anvil] FSR: one pass (EASU and RCAS together, %lux%lu groups) — "
                 "Graphics Prep measured it quicker for this game", (unsigned long)shape.width, (unsigned long)shape.height);
        }
    }

    if (g_frameGen && (!g_luma || !g_flow || !g_extrap)) {
        os_log_error(OS_LOG_DEFAULT, "[anvil] frame generation kernels missing");
        g_frameGen = false;
    }
    if (g_fsr3Wanted && (!g_fsr3.luma || !g_fsr3.flow || !g_fsr3.motion || !g_fsr3.settle || !g_fsr3.resolve)) {
        diag("[anvil] FSR 3: its shaders aren't in the library this game loaded — FSR 1, as before");
        g_fsr3Failed = true;
    }
    return g_queue != nil;
}

/// Dispatch helper — every pass here is a full-coverage 2D compute grid.
void dispatch(id<MTLComputeCommandEncoder> enc, id<MTLComputePipelineState> pso,
              NSUInteger w, NSUInteger h) {
    AnvilDispatch2D(enc, pso, w, h);
}

API_AVAILABLE(macos(26.0)) bool ensureMetalFX(id<MTLTexture> reference);

/// Synthesise a frame and present it.
///
/// Motion comes from comparing two images, so this needs nothing from the game —
/// which is the point: it works in titles with no upscaler support of any kind.
///
/// The frame is *extrapolated* forward from the two most recent real frames rather
/// than interpolated between them. Interpolating is higher quality, but the midpoint
/// of two frames can only be shown once both exist, so the newer one has to be held
/// back — one full frame of added latency. Projecting forward holds nothing back and
/// leaves latency where it would be with frame generation off entirely.
///
/// It also fixes an ordering error. Emitting interp(A,B) here, after B has already
/// been presented, shows a frame from the past after a newer one: the displayed
/// sequence ran A, B, interp(A,B), C — forward, back, forward. A projected frame
/// belongs after B, which is exactly where this is emitted.
IMP g_originalNextDrawable = nullptr;      // set by the constructor
std::atomic<bool> g_inGenerate{false};

// Set while Anvil itself is asking for a timed present. If Metal implements the timed
// variants by calling presentDrawable: underneath, that call arrives back here; it is
// passed straight through (see hookedPresentDrawable) instead of being paced a second time — or recursing.
thread_local bool t_inTimedPresent = false;
struct TimedPresent { TimedPresent() { t_inTimedPresent = true; } ~TimedPresent() { t_inTimedPresent = false; } };


/// Schedule a synthesised frame on the refresh between two real ones.
///
/// The target is derived from where the real frame was *scheduled*, not from when it
/// happened to be presented — the whole point of the grid is that it does not inherit
/// the game's jitter. Handing the time to the compositor costs no latency here: the
/// CPU does not wait, and the frame was going to sit in the queue regardless.
void presentGenerated(id<MTLCommandBuffer> cb, id<CAMetalDrawable> extra) {
    g_pendingPresents.fetch_add(1, std::memory_order_release);
    if (g_fill && g_frameInterval > 0.0 && g_refreshPeriod > 0.0) {
        // Smooth Motion: half the game's own frame time after its newest frame is shown — asked for
        // a little short of it, as the panel rounds the gap up to its next 240 Hz step.
        TimedPresent timed;
        [cb presentDrawable:extra afterMinimumDuration:std::max(g_refreshPeriod, 0.5 * g_frameInterval - 0.0025)];
        return;
    }
    if (g_pacing && g_lastRealTarget > 0.0 && g_refreshPeriod > 0.0) {
        const double now = CACurrentMediaTime();
        // The slot immediately after the last real frame — the gap being filled.
        double target = g_lastRealTarget + g_refreshPeriod;
        // A generated frame that has missed its slot is worth nothing; showing it
        // late would push the next real frame off the grid, which is the stutter
        // this exists to remove. Drop it onto the next slot instead.
        if (target < now) target = snapToGrid(now);
        if (target > now + g_realSlotPeriod * 2.0) target = snapToGrid(now);
        // Claim the slot so the next real frame does not land on top of it.
        if (g_nextRealSlot < target + g_refreshPeriod) {
            g_nextRealSlot = target + g_refreshPeriod;
        }
        TimedPresent timed;
        [cb presentDrawable:extra atTime:target];
    } else {
        // Anvil's own queue makes the same kind of command buffer the game's does, so
        // this would otherwise be counted and paced as one of the game's frames.
        TimedPresent timed;
        [cb presentDrawable:extra];
    }
}

/// Where a generated frame is made: straight into the drawable, or — with FSR to the display,
/// where the history is at the game's size — into a texture of that size, upscaled into the
/// drawable after.
id<MTLTexture> generationTarget(id<MTLTexture> drawableTexture, id<MTLTexture> curr) {
    if (sameSize(drawableTexture, curr)) return drawableTexture;
    if (!sameSize(g_genScratch, curr)) {
        [g_genScratch release];
        MTLTextureDescriptor* gd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:curr.pixelFormat
                                                                                       width:curr.width
                                                                                      height:curr.height
                                                                                   mipmapped:NO];
        gd.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
        gd.storageMode = MTLStorageModePrivate;
        g_genScratch = [g_device newTextureWithDescriptor:gd];
    }
    return g_genScratch;
}

bool drawCounter(id<MTLCommandBuffer> cb, id<MTLTexture> target, int scale);
id<MTLTexture> rawView(id<MTLCommandBuffer> cb, id<MTLTexture> t);

/// FSR 3's motion for the frames frame generation holds, when it measured it: the last real
/// frame went through FSR 3, and what was recorded of it is the frame as shown, at the
/// display's size. nil otherwise — frame generation then measures its own.
id<MTLTexture> fsr3MotionFor(id<MTLTexture> recorded) {
    if (!g_fsr3Live || !recorded) return nil;
    if (recorded.width != g_fsr3.outWidth || recorded.height != g_fsr3.outHeight) return nil;
    return AnvilFSR3Motion(&g_fsr3);
}

void generateFrame() {
    OwnGpuWork own;
    // An sRGB drawable only through FSR to the display, whose history is kept as encoded.
    if (!g_canWrite && !(g_viewWrite && g_outputActive.load())) return;

    // Never let generation queue behind itself.
    if (g_inFlight.load(std::memory_order_acquire) > 0) {
        g_skippedGenerations.fetch_add(1, std::memory_order_relaxed);
        g_skippedBusy.fetch_add(1, std::memory_order_relaxed);
        return;
    }
    // Never take the drawable the game is about to need. nextDrawable blocks when
    // the pool is empty, and this runs inside the game's own call to it.
    {
        const int depth = (g_appliedDepth > 0) ? g_appliedDepth
                        : ((g_maxDrawables > 0) ? g_maxDrawables : 3);
        if (g_pendingPresents.load(std::memory_order_acquire) >= depth - 1) {
            g_skippedGenerations.fetch_add(1, std::memory_order_relaxed);
            g_skippedPool.fetch_add(1, std::memory_order_relaxed);
            return;
        }
    }
    // Re-entrancy guard: this function asks the layer for a drawable, and that call
    // must not come back through the hook that called us.
    if (g_inGenerate.exchange(true)) return;
    struct Guard { ~Guard() { g_inGenerate = false; } } guard;

    if (!g_layer || !g_haveHistory || !g_frameA || !g_prevFrame) return;

    id<MTLTexture> curr = g_prevFrame;
    const NSUInteger w = curr.width, h = curr.height;

    // Called from nextDrawable, before the game has taken its drawable — so the pool
    // has one free and this cannot block. Asking for it during presentDrawable:
    // deadlocks instead: the game is still holding its own drawable at that point,
    // and nextDrawable waits forever for one that will not be released until the
    // present it is blocking completes.
    // Call the original implementation directly. Sending -nextDrawable to the layer
    // would re-enter the swizzled method and recurse until the stack is exhausted.
    id<CAMetalDrawable> extra = (id<CAMetalDrawable>)
        ((id (*)(id, SEL))g_originalNextDrawable)(g_layer, @selector(nextDrawable));
    if (!extra) return;

    id<MTLCommandBuffer> cb = [workQueue() commandBuffer];

    // Every texture in this pass has to agree with the frame that just arrived.
    if (!sameSize(g_prevFrame, curr) || !sameSize(g_frameA, curr)) return;
    if (!g_lumaPrev || !g_lumaCurr || !g_flowField) return;

    id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];

    // After FSR 3 its motion is already measured — per 16x16 of the game's pixels and to a
    // fraction of one, finer than this pass's — and the frames held are as shown, so the one
    // made here goes straight to the drawable with no FSR after it.
    id<MTLTexture> fsr3Motion = fsr3MotionFor(curr);
    id<MTLTexture> motionField = fsr3Motion ? fsr3Motion : g_flowField;
    const float motionScale = fsr3Motion && g_fsr3.width > 0 ? (float)g_fsr3.outWidth / (float)g_fsr3.width : 1.0f;
    id<MTLTexture> shownTarget = nil;
    if (fsr3Motion) {
        id<MTLTexture> view = rawView(cb, extra.texture);
        if (view.width == curr.width && view.height == curr.height) shownTarget = view;
    }

    if (!fsr3Motion) {
        // Luma for the current frame; the previous frame's plane is still valid.
        [enc setComputePipelineState:g_luma];
        [enc setTexture:curr atIndex:0];
        [enc setTexture:g_lumaCurr atIndex:1];
        dispatch(enc, g_luma, g_lumaCurr.width, g_lumaCurr.height);

        // One 256-thread threadgroup per flow texel: the group cooperatively loads the
        // search window into threadgroup memory, then scores all 289 candidates from it.
        const int stride = g_flowDivisor;
        [enc setComputePipelineState:g_flow];
        [enc setTexture:g_lumaPrev atIndex:0];
        [enc setTexture:g_lumaCurr atIndex:1];
        [enc setTexture:g_flowField atIndex:2];
        [enc setBytes:&stride length:sizeof(stride) atIndex:0];
        [enc dispatchThreadgroups:MTLSizeMake(g_flowField.width, g_flowField.height, 1)
            threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];
    }

    // Apple's interpolator, driven by Anvil's flow. Preferred when available: it is
    // a production implementation with proper disocclusion and inpainting, where
    // Anvil's own pass falls back to a blend.
    bool usedMetalFX = false;
    if (@available(macOS 26.0, *)) {
        // Not in Smooth Motion: Apple's interpolator makes the frame between the last two, which
        // shown after the newer of them would step back in time; projected, it lands in order.
        if (g_useMetalFX && !g_fill && g_flowToMotion && g_downsample && g_upsample
            && ensureMetalFX(curr)) {
            // Both colour frames down to interpolation resolution, and the flow
            // expanded to match.
            [enc setComputePipelineState:g_downsample];
            [enc setTexture:curr atIndex:0];
            [enc setTexture:g_halfCurr atIndex:1];
            dispatch(enc, g_downsample, g_halfCurr.width, g_halfCurr.height);
            [enc setTexture:g_frameA atIndex:0];
            [enc setTexture:g_halfPrev atIndex:1];
            dispatch(enc, g_downsample, g_halfPrev.width, g_halfPrev.height);

            [enc setComputePipelineState:g_flowToMotion];
            [enc setTexture:motionField atIndex:0];
            [enc setTexture:g_motionTex atIndex:1];
            dispatch(enc, g_flowToMotion, g_motionTex.width, g_motionTex.height);
            [enc endEncoding];

            id<MTLFXFrameInterpolator> fx = (id<MTLFXFrameInterpolator>)g_interpolator;
            fx.colorTexture = g_halfCurr;
            fx.prevColorTexture = g_halfPrev;
            fx.outputTexture = g_interpOut;
            fx.depthTexture = g_depthTex;
            fx.motionTexture = g_motionTex;
            // Vectors are already in pixels, so no further scaling.
            fx.motionVectorScaleX = 1.0f;
            fx.motionVectorScaleY = 1.0f;
            fx.jitterOffsetX = 0.0f;
            fx.jitterOffsetY = 0.0f;
            fx.deltaTime = (float)g_frameInterval;
            fx.depthReversed = NO;
            fx.shouldResetHistory = !g_haveHistory;
            [fx encodeToCommandBuffer:cb];

            // Scale the result up into the drawable. A blit cannot resize, so this
            // is a sampled pass rather than a copy. With FSR to the display it goes to the
            // game's size first and through FSR from there, like every real frame: a
            // generated frame stretched straight to the display's pixels was softer than
            // the real ones either side of it, which flickers.
            id<MTLTexture> upTarget = shownTarget ? shownTarget : generationTarget(extra.texture, curr);
            if (!upTarget) return;
            id<MTLComputeCommandEncoder> post = [cb computeCommandEncoder];
            [post setComputePipelineState:g_upsample];
            [post setTexture:g_interpOut atIndex:0];
            [post setTexture:upTarget atIndex:1];
            dispatch(post, g_upsample, upTarget.width, upTarget.height);
            [post endEncoding];
            if (shownTarget) {
                if (g_overlayOn) drawCounter(cb, shownTarget, (int)std::max(1.0, round(g_overlayScale * (double)motionScale)));
            } else if (upTarget != extra.texture && !outputEncode(cb, upTarget, extra.texture)) return;
            usedMetalFX = true;
        }
    }

    if (usedMetalFX) {
        id<MTLBlitCommandEncoder> blit2 = [cb blitCommandEncoder];
        [blit2 copyFromTexture:g_lumaCurr toTexture:g_lumaPrev];
        [blit2 endEncoding];
        @try {
            [extra addPresentedHandler:^(id<MTLDrawable> shown) {
                g_pendingPresents.fetch_sub(1, std::memory_order_release);
                noteShown(true, shown.presentedTime);
            }];
        } @catch (NSException*) {}
        presentGenerated(cb, extra);
        g_inFlight.fetch_add(1, std::memory_order_release);
        [cb addCompletedHandler:^(id<MTLCommandBuffer>) {
            g_inFlight.fetch_sub(1, std::memory_order_release);
        }];
        [cb commit];
        ++g_generated;
        return;
    }

    // With FSR to the display the history is at the game's size: the frame is made there,
    // then upscaled like any other. After FSR 3 it is at the display's, and made in place.
    id<MTLTexture> genTarget = shownTarget ? shownTarget : generationTarget(extra.texture, curr);
    if (!genTarget) { [enc endEncoding]; return; }
    [enc setComputePipelineState:g_extrap];
    [enc setTexture:g_frameA atIndex:0];
    [enc setTexture:curr atIndex:1];
    [enc setTexture:motionField atIndex:2];
    [enc setTexture:genTarget atIndex:3];
    // How far past the newest real frame this one is being shown.
    //
    // This was a fixed 0.5 — half of the game's own frame interval — and that stopped
    // being true when frames were put on the display's refresh grid. The generated
    // frame is presented exactly one refresh after the real frame's slot, which is
    // 8.33 ms here; half the game's interval at 91 fps is 5.5 ms. So the image was
    // warped to where things would be at 5.5 ms and shown at 8.33 ms, and every
    // second frame sat slightly behind where it belonged. Alternating correct and
    // displaced frames sixty times a second is seen as shaking.
    //
    // The warp now uses the real ratio between where the frame is shown and how long
    // the game's own frames take, so it lands where it is displayed.
    float phase = 0.5f;
    if (g_fill) {
        // Smooth Motion: halfway to the game's next frame, where it is shown.
    } else if (g_frameInterval > 0.0001 && g_refreshPeriod > 0.0) {
        phase = (float)(g_refreshPeriod / g_frameInterval);
        // Never project further than one whole frame: past that the motion estimate
        // is extrapolating beyond anything it has evidence for.
        if (phase > 1.0f) phase = 1.0f;
        if (phase < 0.05f) phase = 0.05f;
    }
    simd_float4 params = { phase, motionScale, 0, 0 };
    [enc setBytes:&params length:sizeof(params) atIndex:0];
    dispatch(enc, g_extrap, w, h);
    [enc endEncoding];
    if (shownTarget) {
        // The counter as FSR 3 draws it on the real frames, so it doesn't flicker between them.
        if (g_overlayOn) drawCounter(cb, shownTarget, (int)std::max(1.0, round(g_overlayScale * (double)motionScale)));
    } else if (genTarget != extra.texture && !outputEncode(cb, genTarget, extra.texture)) return;

    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    [blit copyFromTexture:g_lumaCurr toTexture:g_lumaPrev];
    [blit endEncoding];

    @try {
        [extra addPresentedHandler:^(id<MTLDrawable> shown) {
            g_pendingPresents.fetch_sub(1, std::memory_order_release);
            noteShown(true, shown.presentedTime);
        }];
    } @catch (NSException*) {}

    presentGenerated(cb, extra);
    g_inFlight.fetch_add(1, std::memory_order_release);
    [cb addCompletedHandler:^(id<MTLCommandBuffer>) {
        g_inFlight.fetch_sub(1, std::memory_order_release);
    }];
    [cb commit];
    ++g_generated;
}

/// Track the process footprint against the budget, and keep Anvil's own textures
/// out of the way when the game is near its ceiling.
void updateMemoryState() {
    if (g_budgetMB <= 0) return;
    const double mb = currentFootprintMB();

    uint64_t peak = g_peakFootprintMB.load();
    while ((uint64_t)mb > peak && !g_peakFootprintMB.compare_exchange_weak(peak, (uint64_t)mb)) {}

    const bool over = mb > g_budgetMB;
    if (over != g_overBudget.exchange(over)) {
        os_log_with_type(OS_LOG_DEFAULT,
                         over ? OS_LOG_TYPE_ERROR : OS_LOG_TYPE_DEFAULT,
                         "[anvil] footprint %.0f MB %s budget %d MB",
                         mb, over ? "EXCEEDS" : "back within", g_budgetMB);
    }

    // Only once, on crossing the line. Setting purgeable state every sample made
    // the kernel repeatedly reclaim and refault Anvil's history textures, which is
    // itself a stutter — the opposite of the intent.
    if (over) {
        [g_frameA setPurgeableState:MTLPurgeableStateVolatile];
        [g_prevFrame setPurgeableState:MTLPurgeableStateVolatile];
        diag("[anvil] over budget — history textures made reclaimable");
    }
}

/// Build Apple's interpolator for this drawable size, with the extra textures it
/// needs that the game does not provide.
API_AVAILABLE(macos(26.0))
bool ensureMetalFX(id<MTLTexture> reference) {
    const NSUInteger iw = MAX((NSUInteger)(reference.width * g_interpScale), 64u);
    const NSUInteger ih = MAX((NSUInteger)(reference.height * g_interpScale), 64u);
    // Kept while the frame keeps its size and format. This compared the interpolator's
    // output — a fraction of the frame — with the frame itself, which never matched below
    // full scale: Smoothest built a new interpolator and five textures for every frame it
    // generated, and (this file managing its own memory) never freed the old ones — several
    // megabytes a frame. Found on the GPU bench on 3 October: 461 builds in 20 s.
    if (g_interpolator && g_interpOut && g_interpOut.width == iw && g_interpOut.height == ih
        && g_interpOut.pixelFormat == reference.pixelFormat) return true;
    releaseLater(g_interpolator); g_interpolator = nil;
    releaseLater(g_motionTex); g_motionTex = nil;
    releaseLater(g_interpOut); g_interpOut = nil;
    releaseLater(g_halfCurr); g_halfCurr = nil;
    releaseLater(g_halfPrev); g_halfPrev = nil;
    releaseLater(g_depthTex); g_depthTex = nil;

    MTLFXFrameInterpolatorDescriptor* desc = [MTLFXFrameInterpolatorDescriptor new];
    desc.inputWidth = iw;
    desc.inputHeight = ih;
    desc.outputWidth = iw;
    desc.outputHeight = ih;
    desc.colorTextureFormat = reference.pixelFormat;
    desc.outputTextureFormat = reference.pixelFormat;
    desc.depthTextureFormat = MTLPixelFormatDepth32Float;
    desc.motionTextureFormat = MTLPixelFormatRG16Float;

    g_interpolator = [desc newFrameInterpolatorWithDevice:g_device];
    if (!g_interpolator) {
        diag("[anvil] MetalFX interpolator unavailable — using Anvil's own");
        g_useMetalFX = false;
        return false;
    }

    g_motionTex = makeTexture(g_device, iw, ih, MTLPixelFormatRG16Float);
    g_interpOut = makeTexture(g_device, iw, ih, reference.pixelFormat);
    g_halfCurr  = makeTexture(g_device, iw, ih, reference.pixelFormat);
    g_halfPrev  = makeTexture(g_device, iw, ih, reference.pixelFormat);

    MTLTextureDescriptor* dd =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float
                                                           width:iw
                                                          height:ih
                                                       mipmapped:NO];
    dd.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
    dd.storageMode = MTLStorageModePrivate;
    g_depthTex = [g_device newTextureWithDescriptor:dd];

    diag("[anvil] MetalFX interpolation ready: %lux%lu (drawable %lux%lu, scale %.2f)",
         (unsigned long)iw, (unsigned long)ih,
         (unsigned long)reference.width, (unsigned long)reference.height, g_interpScale);
    return g_interpolator && g_motionTex && g_interpOut && g_depthTex
        && g_halfCurr && g_halfPrev;
}

/// Allocate or resize the frame-generation working set.
void ensureFrameGenResources(id<MTLTexture> reference) {
    const NSUInteger w = reference.width, h = reference.height;
    if (sameSize(g_prevFrame, reference) && sameSize(g_frameA, reference)) return;
    for (id<MTLTexture>* t : { &g_frameA, &g_prevFrame, &g_lumaPrev, &g_lumaCurr, &g_flowField }) {
        releaseLater(*t);
        *t = nil;
    }

    g_frameA    = makeTexture(g_device, w, h, reference.pixelFormat);
    g_prevFrame = makeTexture(g_device, w, h, reference.pixelFormat);
    g_lumaPrev  = makeTexture(g_device, MAX(w / 4, 1u), MAX(h / 4, 1u), MTLPixelFormatR16Float);
    g_lumaCurr  = makeTexture(g_device, MAX(w / 4, 1u), MAX(h / 4, 1u), MTLPixelFormatR16Float);
    // Luma is quarter-resolution; the flow field is a further g_flowDivisor down.
    const NSUInteger flowW = MAX(w / (4 * (NSUInteger)g_flowDivisor), 1u);
    const NSUInteger flowH = MAX(h / (4 * (NSUInteger)g_flowDivisor), 1u);
    g_flowField = makeTexture(g_device, flowW, flowH, MTLPixelFormatRGBA16Float);
    diag("[anvil] flow field %lux%lu (divisor %d)",
         (unsigned long)flowW, (unsigned long)flowH, g_flowDivisor);
    g_haveHistory = false;
}

/// Record a real frame. B becomes A, the new frame becomes B.
void recordFrame(id<MTLTexture> curr) {
    OwnGpuWork own;
    // A resized drawable invalidates the history; rebuilding it is handled by
    // ensureFrameGenResources, and until the sizes agree this frame is skipped.
    if (!sameSize(g_prevFrame, curr) || !sameSize(g_frameA, g_prevFrame)) return;

    id<MTLCommandBuffer> cb = [workQueue() commandBuffer];
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    [blit copyFromTexture:g_prevFrame toTexture:g_frameA];
    [blit copyFromTexture:curr toTexture:g_prevFrame];
    [blit endEncoding];

    id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
    [enc setComputePipelineState:g_luma];
    [enc setTexture:curr atIndex:0];
    [enc setTexture:g_lumaCurr atIndex:1];
    dispatch(enc, g_luma, g_lumaCurr.width, g_lumaCurr.height);
    [enc endEncoding];
    [cb commit];

    if (g_frameCounter++ >= 1) g_haveHistory = true;   // need two real frames
}

/// Where the counter's box sits in a frame of this size — the same arithmetic as
/// anvil_counter and anvil_finish, so all three agree to the pixel.
struct CounterBox { NSUInteger x, y, w, h; bool fits; };
CounterBox counterBox(NSUInteger width, NSUInteger height, double fps, int scale = 0) {
    const int value = std::clamp((int)(fps + 0.5), 0, 9999);
    const int s = std::max(scale > 0 ? scale : g_overlayScale, 1);
    const int glyphW = 3 * s, glyphH = 5 * s, gap = s;
    const int digits = value >= 1000 ? 4 : (value >= 100 ? 3 : (value >= 10 ? 2 : 1));
    const int boxW = digits * glyphW + (digits - 1) * gap + 4 * s;
    const int boxH = glyphH + 4 * s;
    const int inset = 8 * s;
    const int corner = std::clamp(g_overlayCorner, 0, 3);
    const int w = (int)width, h = (int)height;
    const int x = (corner == 1 || corner == 3) ? (w - boxW - inset) : inset;
    const int y = (corner >= 2) ? (h - boxH - inset) : inset;
    const bool fits = x >= 0 && y >= 0 && x + boxW <= w && y + boxH <= h;
    return { (NSUInteger)std::max(x, 0), (NSUInteger)std::max(y, 0),
             (NSUInteger)boxW, (NSUInteger)boxH, fits };
}

/// Draw the frame counter and nothing else: its box is copied out, drawn over and
/// written back, and no other pixel of the game's frame is read or written.
/// False when the kernel is unavailable, so the caller can fall back.
bool drawCounter(id<MTLCommandBuffer> cb, id<MTLTexture> target, int scale = 0) {
    if (!g_counter) return false;
    const int s = scale > 0 ? scale : g_overlayScale;
    const double fps = (g_frameGen && g_displayedFPS > 0.0) ? g_displayedFPS : g_fpsSmoothed;
    const CounterBox box = counterBox(target.width, target.height, fps, s);
    if (!box.fits) return true;                  // a frame too small for it: touch nothing
    // Sized for the widest box, four digits, so it is not rebuilt as the rate crosses 100.
    const NSUInteger maxW = counterBox(target.width, target.height, 9999.0, s).w;
    if (!g_counterScratch || g_counterScratch.pixelFormat != target.pixelFormat
        || g_counterScratch.width < maxW || g_counterScratch.height < box.h) {
        g_counterScratch = makeTexture(g_device, maxW, box.h, target.pixelFormat);
    }
    if (!g_counterScratch) return true;

    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    [blit copyFromTexture:target sourceSlice:0 sourceLevel:0
             sourceOrigin:MTLOriginMake(box.x, box.y, 0) sourceSize:MTLSizeMake(box.w, box.h, 1)
                toTexture:g_counterScratch destinationSlice:0 destinationLevel:0
        destinationOrigin:MTLOriginMake(0, 0, 0)];
    [blit endEncoding];

    id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
    [enc setComputePipelineState:g_counter];
    [enc setTexture:g_counterScratch atIndex:0];
    [enc setTexture:target atIndex:1];
    const bool hot = g_overlayThermal && (g_powerFlags.load() & kHot);
    simd_float4 params = { 0.0f, (float)fps, (float)s, hot ? 1.0f : 0.0f };
    [enc setBytes:&params length:sizeof(params) atIndex:0];
    simd_uint4 rect = { (uint32_t)box.x, (uint32_t)box.y, (uint32_t)box.w, (uint32_t)box.h };
    [enc setBytes:&rect length:sizeof(rect) atIndex:1];
    dispatch(enc, g_counter, box.w, box.h);
    [enc endEncoding];
    return true;
}

/// Run Anvil's pass over the drawable's texture, in place from the game's point of
/// view. A scratch texture is needed because a compute kernel cannot read and write
/// the same texture safely.
void processDrawable(id<MTLCommandBuffer> cb, id<CAMetalDrawable> drawable) {
    id<MTLTexture> target = drawable.texture;
    if (!target || !g_rcas || !g_device) return;

    inspectDrawable(target);
    if (!g_canWrite) return;

    // Encoding into a command buffer that has already been committed or scheduled is
    // fatal, not an error you can catch. D3DMetal does not always call
    // presentDrawable: while the buffer is still open for encoding.
    if (cb.status != MTLCommandBufferStatusNotEnqueued) {
        diag("[anvil] command buffer status %ld at present — skipping this frame",
             (long)cb.status);
        return;
    }

    // Sharpening exists to offset the compositor's stretch when the game renders below
    // native. At native it only stacked on the game's own sharpening and anti-aliasing
    // — LEGO Star Wars has both switched on — and put every pixel of every frame
    // through Anvil. So at native the game's image is left exactly as it drew it.
    const bool wantSharpen = g_sharpness > 0.001f && g_renderScale < 0.999f;
    const bool wantOverlay = g_overlayOn && (g_overlay != nil || g_counter != nil);
    if (!wantSharpen && !wantOverlay) return;
    // The counter alone touches only its own box.
    if (!wantSharpen && drawCounter(cb, target)) return;

    if (!sameSize(g_scratch, target)) {
        MTLTextureDescriptor* d =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:target.pixelFormat
                                                               width:target.width
                                                              height:target.height
                                                           mipmapped:NO];
        d.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
        d.storageMode = MTLStorageModePrivate;
        g_scratch = [g_device newTextureWithDescriptor:d];
    }
    if (!sameSize(g_scratch, target)) return;

    // Copy out, process back in: the drawable stays the texture the game presents,
    // so nothing downstream needs to know Anvil was here.
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    [blit copyFromTexture:target toTexture:g_scratch];
    [blit endEncoding];

    // One dispatch for both. Run separately they cost two full-resolution blits and
    // two dispatches — 2.26 ms at 3024x1964, against 1.29 ms fused. At 90fps that
    // difference is a tenth of the frame budget, and it is felt as stutter.
    if (g_finish) {
        id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
        [enc setComputePipelineState:g_finish];
        [enc setTexture:g_scratch atIndex:0];
        [enc setTexture:target atIndex:1];
        simd_float4 params = {
            wantSharpen ? g_sharpness : 0.0f,
            // With frame generation on, the rate the game renders at is not the
            // rate you see. The counter reports what reached the display.
            (float)((g_frameGen && g_displayedFPS > 0.0) ? g_displayedFPS : g_fpsSmoothed),
            (float)g_overlayScale,
            wantOverlay ? overlayCornerParam() : -1.0f,
        };
        [enc setBytes:&params length:sizeof(params) atIndex:0];
        dispatch(enc, g_finish, target.width, target.height);
        [enc endEncoding];
        return;
    }

    // Fallback for a metallib without the fused kernel.
    if (wantSharpen) {
        id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
        [enc setComputePipelineState:g_rcas];
        [enc setTexture:g_scratch atIndex:0];
        [enc setTexture:target atIndex:1];
        simd_float4 params = { g_sharpness, 0, 0, 0 };
        [enc setBytes:&params length:sizeof(params) atIndex:0];
        dispatch(enc, g_rcas, target.width, target.height);
        [enc endEncoding];
    }

}

// ---- FSR to the display: the pieces ----------------------------------------------

/// Called from D3DMetal itself: libd3dshared or the D3DMetal framework.
bool callerIsD3DMetal(const void* ret) {
    Dl_info info;
    if (!ret || !dladdr(ret, &info) || !info.dli_fname) return false;
    return strstr(info.dli_fname, "d3dshared") != nullptr || strstr(info.dli_fname, "D3DMetal") != nullptr;
}

/// The main display in pixels, and pixels per point.
CGSize displayPixels(double* scale) {
    static CGSize pixels = CGSizeZero;
    static double perPoint = 1.0;
    if (CGSizeEqualToSize(pixels, CGSizeZero)) {
        if (CGDisplayModeRef mode = CGDisplayCopyDisplayMode(CGMainDisplayID())) {
            pixels = CGSizeMake(CGDisplayModeGetPixelWidth(mode), CGDisplayModeGetPixelHeight(mode));
            const double points = (double)CGDisplayModeGetWidth(mode);
            if (points > 0) perPoint = pixels.width / points;
            CGDisplayModeRelease(mode);
        }
    }
    if (scale) *scale = perPoint;
    return pixels;
}

// The layer's size on screen, in points, as last read on the main thread (outputWatchLayer);
// zero until then. LEGO Star Wars on 3 October was sized while its layer's bounds were
// 1512x967 points of a 1512x982 screen, and drawn at 3024x1934 the whole session: the
// compositor stretched every frame to the screen's 1964 rows, softening what FSR had drawn.
std::atomic<double> g_layerPointsW{0.0}, g_layerPointsH{0.0};
// Whether the picture is shown at its own shape inside the layer, with black either side.
std::atomic<bool> g_keptShape{false};

/// The size a layer has on screen, in points: its bounds through every transform above it.
CGSize layerPointsOnScreen(CALayer* layer) {
    CGSize size = layer.bounds.size;
    CALayer* root = layer;
    while (root.superlayer) root = root.superlayer;
    if (root != layer) {
        const CGRect r = [layer convertRect:layer.bounds toLayer:root];
        if (r.size.width >= 1.0 && r.size.height >= 1.0) size = r.size;
    }
    return size;
}

/// A picture of shape `game` inside `box`: the box itself when the shapes are within 2% — a
/// difference no one sees, where bars would look like a fault — else the largest size of the
/// game's shape that fits.
CGSize fitShape(CGSize game, CGSize box) {
    if (game.width < 1.0 || game.height < 1.0 || box.width < 1.0 || box.height < 1.0) return box;
    const double g = game.width / game.height, b = box.width / box.height;
    if (fabs(g / b - 1.0) <= 0.02) return box;
    return g > b ? CGSizeMake(box.width, round(box.width / g)) : CGSizeMake(round(box.height * g), box.height);
}

/// The display pixels a layer covers: its size on screen at the display's pixels per point,
/// never more than the display has — and within that, the game's own shape, so a 16:9 frame
/// on a MacBook's screen is shown whole with bars rather than stretched.
CGSize outputSizeFor(CAMetalLayer* layer, CGSize game) {
    double scale = 1.0;
    const CGSize screen = displayPixels(&scale);
    const double seenW = g_layerPointsW.load(), seenH = g_layerPointsH.load();
    const CGSize points = (seenW >= 1.0 && seenH >= 1.0) ? CGSizeMake(seenW, seenH) : layer.bounds.size;
    CGSize out = (points.width > 0 && points.height > 0)
        ? CGSizeMake(round(points.width * scale), round(points.height * scale))
        : CGSizeMake(round(game.width * scale), round(game.height * scale));
    if (screen.width > 0 && screen.height > 0 && (out.width > screen.width || out.height > screen.height)) {
        const double fit = std::min(screen.width / out.width, screen.height / out.height);
        out = CGSizeMake(floor(out.width * fit), floor(out.height * fit));
    }
    return fitShape(game, out);
}

/// The layer showing a drawable smaller than itself at its own shape, centred on black, rather
/// than stretched to fill: once, on the main thread, where a layer's look is changed.
void keepShape(CALayer* layer, CGSize game, CGSize shown) {
    if (!layer || g_keptShape.exchange(true)) return;
    [layer retain];
    dispatch_async(dispatch_get_main_queue(), ^{
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        layer.contentsGravity = kCAGravityResizeAspect;
        CGColorRef black = CGColorCreateGenericRGB(0, 0, 0, 1);
        layer.backgroundColor = black;
        CGColorRelease(black);
        [CATransaction commit];
        [layer release];
    });
    diag("[anvil] picture: the game draws %.0fx%.0f, a different shape from its window — shown whole at %.0fx%.0f "
         "with black either side, not stretched", game.width, game.height, shown.width, shown.height);
}

bool outputTake(CAMetalLayer* layer, CGSize game);

/// Once a second on the main thread while FSR draws to the display: the layer's size on
/// screen, and the drawable sized again when that has changed — the same new size twice
/// running, so a window in the middle of a change isn't followed.
void outputWatchLayer() {
    static std::atomic<bool> started{false};
    if (started.exchange(true)) return;
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    if (!timer) return;
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), NSEC_PER_SEC, NSEC_PER_SEC / 4);
    dispatch_source_set_event_handler(timer, ^{
        static CGSize pending = CGSizeZero;
        static bool said = false;
        CAMetalLayer* layer = g_outLayer;
        if (!layer || g_outputFailed.load()) return;
        const CGSize points = layerPointsOnScreen(layer);
        if (points.width < 1.0 || points.height < 1.0) return;
        const CGSize bounds = layer.bounds.size;
        if (!said && (fabs(points.width - bounds.width) >= 1.0 || fabs(points.height - bounds.height) >= 1.0)) {
            said = true;
            diag("[anvil] FSR to the display: the game's layer is %.0fx%.0f points on screen, its bounds %.0fx%.0f",
                 points.width, points.height, bounds.width, bounds.height);
        }
        g_layerPointsW = points.width;
        g_layerPointsH = points.height;
        if (!g_outputActive.load() || g_gameSize.width < 1.0) return;
        const CGSize out = outputSizeFor(layer, g_gameSize);
        if (fabs(out.width - g_outSize.width) < 1.0 && fabs(out.height - g_outSize.height) < 1.0) { pending = CGSizeZero; return; }
        if (!CGSizeEqualToSize(out, pending)) { pending = out; return; }
        pending = CGSizeZero;
        diag("[anvil] FSR to the display: the game's layer is now %.0fx%.0f points on screen — drawing %.0fx%.0f (was %.0fx%.0f), "
             "the display's own pixels, so nothing stretches it after", points.width, points.height,
             out.width, out.height, g_outSize.width, g_outSize.height);
        @try { outputTake(layer, g_gameSize); }
        @catch (NSException* e) { diag("[anvil] FSR to the display: %s — %s", e.name.UTF8String, e.reason.UTF8String); }
    });
    dispatch_resume(timer);                      // kept for the session
}

/// The format of the same pixels without sRGB conversion.
MTLPixelFormat plainFormat(MTLPixelFormat f) {
    switch (f) {
    case MTLPixelFormatBGRA8Unorm_sRGB: return MTLPixelFormatBGRA8Unorm;
    case MTLPixelFormatRGBA8Unorm_sRGB: return MTLPixelFormatRGBA8Unorm;
    default: return f;
    }
}

/// Layer formats FSR to the display takes, and why not when it doesn't. 8-bit, 10-bit and
/// 8-bit sRGB colour, and 16-bit float that stays in the standard range — the formats a
/// game's swap chain comes in. Each was written by a compute pass, with Metal's validation
/// on, on the M4 (3 October). Extended range (HDR) is left as the game draws it: FSR 1's
/// arithmetic expects colour between 0 and 1.
const char* outputFormatRefusal(CAMetalLayer* layer, MTLPixelFormat f) {
    switch (f) {
    case MTLPixelFormatBGRA8Unorm: case MTLPixelFormatRGBA8Unorm:
    case MTLPixelFormatBGRA8Unorm_sRGB: case MTLPixelFormatRGBA8Unorm_sRGB:
    case MTLPixelFormatRGB10A2Unorm: case MTLPixelFormatBGR10A2Unorm:
        return nullptr;
    case MTLPixelFormatRGBA16Float:
        return layer.wantsExtendedDynamicRangeContent ? "HDR colour beyond the standard range" : nullptr;
    default:
        return "a pixel format FSR doesn't take";
    }
}

/// The same pixels with no sRGB conversion: FSR works on the picture as encoded, where AMD
/// says it belongs. A plain texture is itself. A view lives until the command buffer that
/// uses it has finished.
id<MTLTexture> rawView(id<MTLCommandBuffer> cb, id<MTLTexture> t) {
    if (!t || !cb) return t;
    const MTLPixelFormat plain = plainFormat(t.pixelFormat);
    if (plain == t.pixelFormat || !(t.usage & MTLTextureUsagePixelFormatView)) return t;
    id<MTLTexture> view = [t newTextureViewWithPixelFormat:plain];     // +1
    if (!view) return t;
    [cb addCompletedHandler:^(id<MTLCommandBuffer>) { [view release]; }];
    return view;
}

void clearInputs() {
    std::lock_guard<std::mutex> hold(g_inputsLock);
    for (auto& entry : g_inputs) [entry.second release];
    g_inputs.clear();
}

/// The layer back at the size the game draws at, for the rest of the session.
void outputAbandon(CAMetalLayer* layer, const char* why) {
    if (g_outputFailed.exchange(true)) return;
    g_outputActive = false;
    g_fsr3Live = false;        // nothing of FSR 3's is current once the layer is the game's again
    clearInputs();
    if (layer && g_originalSetDrawableSize && g_gameSize.width > 0)
        ((void (*)(id, SEL, CGSize))g_originalSetDrawableSize)(layer, @selector(setDrawableSize:), g_gameSize);
    diag("[anvil] FSR to the display: off for this session — %s; the game's frames go to the display as they are", why);
}

/// Take the layer over for FSR, at the display's pixels for the game's size. True when the
/// size now set is Anvil's.
bool outputTake(CAMetalLayer* layer, CGSize game) {
    if (g_outputFailed.load() || !g_originalSetDrawableSize) return false;
    if (g_outLayer && g_outLayer != layer) return false;       // one layer: the game's
    // Formats a compute pass can write and FSR's arithmetic expects (0–1); anything else is
    // left exactly as the game set it up.
    const MTLPixelFormat format = layer.pixelFormat;
    if (const char* why = outputFormatRefusal(layer, format)) {
        static std::atomic<bool> said{false};
        if (!said.exchange(true))
            diag("[anvil] FSR to the display: not for this game's frames (pixel format %lu, %s) — shown as the game draws them",
                 (unsigned long)format, why);
        return false;
    }
    const CGSize out = outputSizeFor(layer, game);
    // FSR 1 only where there's something to upscale. FSR 3 wherever the display has more
    // pixels than the game, and at the display's own size too — where its blend is the whole
    // of it — when Graphics Prep found that better for the game.
    const bool fsr3 = g_fsr3Wanted && !g_fsr3Failed.load();
    const bool atDisplaySize = fabs(out.width - game.width) < 0.5 && fabs(out.height - game.height) < 0.5;
    const double need = fsr3 ? 1.0 : 1.15;
    if (game.width < 16 || game.height < 16 || out.width < game.width * need - 0.5 || out.height < game.height * need - 0.5
        || (atDisplaySize && !(fsr3 && g_fsr3Native))) {
        if (g_outputActive.exchange(false)) {
            clearInputs();
            diag("[anvil] FSR to the display: the game now draws %.0fx%.0f, about the display's own %.0fx%.0f — nothing to upscale",
                 game.width, game.height, out.width, out.height);
        }
        g_gameSize = game;
        AnvilGpuGameSize(game.width, game.height);
        return false;
    }
    const bool changed = !CGSizeEqualToSize(game, g_gameSize) || !CGSizeEqualToSize(out, g_outSize) || !g_outputActive.load();
    g_gameSize = game;
    AnvilGpuGameSize(game.width, game.height);
    g_outSize = out;
    if (!g_outLayer) g_outLayer = [layer retain];
    if (changed) {
        clearInputs();
        AnvilFSR3Reset(&g_fsr3);
        const bool same = fabs(out.width - game.width) < 0.5 && fabs(out.height - game.height) < 0.5;
        if (!same)
            diag("[anvil] FSR to the display: the game draws %.0fx%.0f; Anvil upscales it to the display's %.0fx%.0f "
                 "with AMD FSR 1 (EASU, then RCAS) instead of the compositor's bilinear stretch",
                 game.width, game.height, out.width, out.height);
        if (fsr3)
            diag("[anvil] FSR 3: the game draws %.0fx%.0f, shown at %.0fx%.0f%s — Anvil's temporal FSR 3: motion measured "
                 "from the game's own frames, then %s and a blend with the frames before, in one pass",
                 game.width, game.height, out.width, out.height, same ? ", the display's own size: nothing to upscale" : "",
                 same ? "RCAS" : "EASU, RCAS");
    }
    g_outputActive = true;
    outputWatchLayer();
    // A picture of another shape than the layer: shown whole, centred, not stretched.
    {
        double scale = 1.0;
        displayPixels(&scale);
        const double seenW = g_layerPointsW.load(), seenH = g_layerPointsH.load();
        const CGSize points = (seenW >= 1.0 && seenH >= 1.0) ? CGSizeMake(seenW, seenH) : layer.bounds.size;
        if (fabs(out.width - points.width * scale) >= 2.0 || fabs(out.height - points.height * scale) >= 2.0) {
            const CGSize box = CGSizeMake(round(points.width * scale), round(points.height * scale));
            if (!CGSizeEqualToSize(fitShape(game, box), box)) keepShape(layer, game, out);
        }
    }
    // Only when it differs: every assignment rebuilds the layer's pool of drawables.
    if (!CGSizeEqualToSize(layer.drawableSize, out))
        ((void (*)(id, SEL, CGSize))g_originalSetDrawableSize)(layer, @selector(setDrawableSize:), out);
    return true;
}

/// Whether a texture is one of the stand-ins the game draws its picture into (anvil_gpuwork.mm's frame anatomy).
extern "C" bool AnvilIsShownPicture(void* texture) {
    if (!texture) return false;
    std::lock_guard<std::mutex> hold(g_inputsLock);
    for (auto& entry : g_inputs) if ((__bridge void*)entry.second == texture) return true;
    return false;
}

/// The stand-in texture for a real drawable: one per drawable in the layer's pool, the size
/// the game draws at. The real drawable comes back to the pool only after its last use was
/// shown, which is after Anvil's pass read the stand-in — so one each is enough.
id<MTLTexture> outputInputFor(id<CAMetalDrawable> real, MTLPixelFormat format) {
    if (!g_device || !real) return nil;
    void* key = (__bridge void*)real.texture;
    std::lock_guard<std::mutex> hold(g_inputsLock);
    for (auto& entry : g_inputs) {
        if (entry.first != key) continue;
        id<MTLTexture> t = entry.second;
        if (t.width == (NSUInteger)g_gameSize.width && t.height == (NSUInteger)g_gameSize.height && t.pixelFormat == format)
            return t;
        [t release];
        entry.second = nil;
        break;
    }
    // A pool rebuilt behind Anvil's back leaves entries for drawables that are gone.
    if (g_inputs.size() >= 8) {
        for (auto& entry : g_inputs) [entry.second release];
        g_inputs.clear();
    }
    MTLTextureDescriptor* d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
                                                                                  width:(NSUInteger)g_gameSize.width
                                                                                 height:(NSUInteger)g_gameSize.height
                                                                              mipmapped:NO];
    d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    // An sRGB frame is read through a plain view of it (rawView).
    if (plainFormat(format) != format) d.usage |= MTLTextureUsagePixelFormatView;
    d.storageMode = MTLStorageModePrivate;
    id<MTLTexture> t = [g_device newTextureWithDescriptor:d];     // +1, released in clearInputs
    if (!t) return nil;
    bool replaced = false;
    for (auto& entry : g_inputs) if (entry.first == key) { entry.second = t; replaced = true; break; }
    if (!replaced) g_inputs.emplace_back(key, t);
    return t;
}

/// FSR from a frame at the game's size into a drawable at the display's: EASU into a
/// scratch texture, then RCAS — with the frame counter, when it is on — into the drawable;
/// or both in one pass, where Graphics Prep measured that quicker for the game.
bool outputEncode(id<MTLCommandBuffer> cb, id<MTLTexture> input, id<MTLTexture> target) {
    OwnGpuWork own;
    const bool onePass = g_fsrPass == kAnvilFSRFused && g_fsrFused && g_fusedShape.width > 0;
    if ((!onePass && (!g_fsrEasu || !g_finish)) || !input || !target || !g_device) return false;
    // An sRGB frame and drawable, as encoded (see rawView).
    input = rawView(cb, input);
    target = rawView(cb, target);
    if (!onePass && !sameSize(g_outScratch, target)) {
        [g_outScratch release];
        MTLTextureDescriptor* d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:target.pixelFormat
                                                                                      width:target.width
                                                                                     height:target.height
                                                                                  mipmapped:NO];
        d.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
        d.storageMode = MTLStorageModePrivate;
        g_outScratch = [g_device newTextureWithDescriptor:d];
        if (!g_outScratch) return false;
    }
    id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
    const bool overlay = g_overlayOn;
    // The counter at the size it has on the game's own frame.
    const double scaleUp = input.width > 0 ? (double)target.width / (double)input.width : 1.0;
    simd_float4 params = {
        // FSR's sharpening, as strong as the player set it; AMD's own default is 0.2 stops.
        g_sharpness > 0.001f ? g_sharpness : 0.9f,
        (float)((g_frameGen && g_displayedFPS > 0.0) ? g_displayedFPS : g_fpsSmoothed),
        (float)std::max(1.0, round(g_overlayScale * scaleUp)),
        overlay ? overlayCornerParam() : -1.0f,
    };
    AnvilEncodeFSR(enc, onePass ? kAnvilFSRFused : kAnvilFSRSplit, g_fusedShape,
                   g_fsrEasu, g_finish, g_fsrFused, input, g_outScratch, target, params);
    [enc endEncoding];
    g_outputFrames.fetch_add(1, std::memory_order_relaxed);
    return true;
}

/// FSR 3 off for the rest of the session, once, saying why: FSR 1 from the next frame, or — at
/// the display's own size, where FSR 1 has nothing to do — the layer handed back to the game.
void fsr3Stop(const char* why) {
    if (g_fsr3Failed.exchange(true)) return;
    g_fsr3Live = false;
    diag("[anvil] FSR 3: off for this session — %s; FSR 1, as before", why);
}

/// FSR 3 from the game's frame at its size into the drawable at the display's, in the game's
/// own command buffer. False when it isn't on or couldn't run — the caller then uses FSR 1.
bool fsr3Encode(id<MTLCommandBuffer> cb, id<MTLTexture> input, id<MTLTexture> target) {
    OwnGpuWork own;
    g_fsr3Live = false;
    if (!g_fsr3Wanted || g_fsr3Failed.load() || !g_device || !input || !target) return false;
    // Eased to FSR 1 for now (fsr3Govern). Its history starts over when it comes back: the
    // gap since its last frame is longer than the restart below allows.
    if (g_fsr3Eased.load(std::memory_order_relaxed)) return false;
    input = rawView(cb, input);
    target = rawView(cb, target);
    if (!AnvilFSR3Ensure(&g_fsr3, g_device, input.width, input.height, target.width, target.height)) {
        fsr3Stop("the GPU hadn't room for its textures at these sizes");
        return false;
    }
    // After a pause — a load, another app in front — the picture it holds isn't the one on
    // screen any more: start again from this frame.
    const double now = CACurrentMediaTime();
    if (g_fsr3LastAt > 0.0 && now - g_fsr3LastAt > 0.25) AnvilFSR3Reset(&g_fsr3);
    g_fsr3LastAt = now;
    const bool native = input.width == target.width && input.height == target.height;
    const double scaleUp = input.width > 0 ? (double)target.width / (double)input.width : 1.0;
    const simd_float4 params = {
        // As strong as the player set it; at the display's own size, half that — there it
        // only offsets the blend's softening, and a game's own sharpening may already be on.
        native ? g_sharpness * 0.5f : (g_sharpness > 0.001f ? g_sharpness : 0.9f),
        (float)((g_frameGen && g_displayedFPS > 0.0) ? g_displayedFPS : g_fpsSmoothed),
        (float)std::max(1.0, round(g_overlayScale * scaleUp)),
        g_overlayOn ? overlayCornerParam() : -1.0f,
    };
    id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
    const bool ok = AnvilEncodeFSR3(&g_fsr3, enc, input, target, params);
    [enc endEncoding];
    if (!ok) {
        fsr3Stop("its pass couldn't be encoded");
        return false;
    }
    if (g_fsr3Frames.fetch_add(1, std::memory_order_relaxed) == 0)
        diag("[anvil] FSR 3: first frame — %lux%lu to %lux%lu, motion matched per %dx%d pixels, up to %.0f frames blended",
             (unsigned long)input.width, (unsigned long)input.height, (unsigned long)target.width, (unsigned long)target.height,
             8 * g_fsr3.scale, 8 * g_fsr3.scale,
             g_fsr3.maxFrames > 0 ? g_fsr3.maxFrames : (native ? kAnvilFSR3FramesNative : kAnvilFSR3Frames));
    g_outputFrames.fetch_add(1, std::memory_order_relaxed);
    g_fsr3Live = true;
    return true;
}

/// Frame generation's history at the game's size, recorded in the game's own command
/// buffer: after its frame, and before anything Anvil generates from it.
void recordFrameIn(id<MTLCommandBuffer> cb, id<MTLTexture> curr) {
    if (!sameSize(g_prevFrame, curr) || !sameSize(g_frameA, g_prevFrame) || !g_luma || !g_lumaCurr) return;
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    [blit copyFromTexture:g_prevFrame toTexture:g_frameA];
    [blit copyFromTexture:curr toTexture:g_prevFrame];
    [blit endEncoding];
    id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
    [enc setComputePipelineState:g_luma];
    [enc setTexture:curr atIndex:0];
    [enc setTexture:g_lumaCurr atIndex:1];
    dispatch(enc, g_luma, g_lumaCurr.width, g_lumaCurr.height);
    [enc endEncoding];
    if (g_frameCounter++ >= 1) g_haveHistory = true;
}

/// The queue Anvil's own work goes on: the game's, once a frame has been seen, so that what
/// Anvil reads was finished by the game first. On a queue of its own Anvil's copies could run
/// before the game's frame was done.
id<MTLCommandQueue> workQueue() { return g_gameQueue ? g_gameQueue : g_queue; }

void noteGameQueue(id<MTLCommandBuffer> cb) {
    id<MTLCommandQueue> q = cb.commandQueue;
    if (q && q != g_gameQueue) { [g_gameQueue release]; g_gameQueue = [q retain]; }
}

/// Why the final upscale is left to the compositor.
///
/// The better image would come from running EASU into a full-size drawable. That
/// needs a second drawable taken during presentDrawable:, and resizing the layer
/// while the game still holds its own drawable deadlocks — verified at both 2 and 3
/// drawables, so it is not pool depth. CAMetalLayer therefore performs the scale,
/// and Anvil counteracts the softness by running RCAS at the reduced resolution
/// beforehand, where it is also cheaper.
///
/// The frame-rate gain is unaffected by this: it comes entirely from the game
/// rendering fewer pixels, which is already happening by the time anything is
/// presented.

// ---- Steady 80 and load ------------------------------------------------------

/// Presents per second over the last `window` seconds, from the game's own present calls.
double presentRate(double window, double now) {
    int n = 0;
    double first = 0.0;
    for (int i = 0; i < g_presentCount; ++i) {
        const double t = g_presentRing[(g_presentHead - 1 - i + kPresentRing) % kPresentRing];
        if (now - t > window) break;
        first = t;
        ++n;
    }
    if (n < 3 || now - first <= 0.0) return -1.0;
    return (n - 1) / (now - first);
}

void notePresentCall(double now) {
    g_presentRing[g_presentHead] = now;
    g_presentHead = (g_presentHead + 1) % kPresentRing;
    if (g_presentCount < kPresentRing) ++g_presentCount;
}

// Steady's rates follow the display. Modelled and measured on a 120 Hz MacBook Pro —
// hold at 80, let go below 77, back to 120 at 114 — and written here as shares of the
// panel's top rate, so the same decisions hold on any Mac's display: a 60 Hz MacBook Air
// never reaches the steady mode (it needs a variable-refresh panel), a 120 Hz ProMotion
// panel holds 80, and a 144 Hz external display holds 96, two frames every three refreshes.
double steadyFullRate() { return g_refreshPeriod > 0.0 ? 1.0 / g_refreshPeriod : 120.0; }
double steadyHoldRate() { return steadyFullRate() / 1.5; }

const char* steadyName(Steady s) {
    // One buffer per state: a transition line names two different ones.
    static char full[32], hold[40], probe[40], low[40];
    const int f = (int)lround(steadyFullRate()), h = (int)lround(steadyHoldRate());
    switch (s) {
    case Steady::full:  snprintf(full, sizeof full, "%d or as ready", f); return full;
    case Steady::hold:  snprintf(hold, sizeof hold, "held to an even %d", h); return hold;
    case Steady::probe: snprintf(probe, sizeof probe, "checking for %d", f); return probe;
    case Steady::low:   snprintf(low, sizeof low, "below %d, as ready", h); return low;
    default:            return "off";
    }
}

/// The GPU's utilisation, as Activity Monitor shows it: the accelerator's own figure.
int readGpuUtilisation() {
    int gpu = -1;
    io_iterator_t it = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it) == KERN_SUCCESS) {
        io_object_t svc;
        while ((svc = IOIteratorNext(it))) {
            CFTypeRef stats = IORegistryEntryCreateCFProperty(svc, CFSTR("PerformanceStatistics"), kCFAllocatorDefault, 0);
            if (stats && CFGetTypeID(stats) == CFDictionaryGetTypeID()) {
                auto n = (CFNumberRef)CFDictionaryGetValue((CFDictionaryRef)stats, CFSTR("Device Utilization %"));
                int v = -1;
                if (n && CFNumberGetValue(n, kCFNumberIntType, &v) && v > gpu) gpu = v;
            }
            if (stats) CFRelease(stats);
            IOObjectRelease(svc);
        }
        IOObjectRelease(it);
    }
    return gpu;
}

/// A fresh GPU reading for the hold's decisions, at most twice a second, off the
/// game's thread.
void requestGpuSample(double now) {
    if (now - g_gpuAskedAt < 0.5) return;
    g_gpuAskedAt = now;
#ifndef ANVIL_INJECT_TEST
    static std::atomic<bool> busy{false};
    if (busy.exchange(true)) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        g_gpuNow.store(readGpuUtilisation());
        g_gpuNowAt.store(CACurrentMediaTime());
        busy.store(false);
    });
#endif
}

/// What the GPU could make unheld: held at `rate` it is busy `gpu`% of the time, so
/// about rate / busy. -1 without a fresh reading.
double gpuRoom(double now, double rate) {
    const int gpu = g_gpuNow.load();
    if (gpu <= 0 || now - g_gpuNowAt.load() > 1.5 || rate <= 0.0) return -1.0;
    return rate * 100.0 / gpu;
}

void steadyEnter(Steady next, double now, double measured) {
    if (next == g_steady) return;
    const int gpu = g_gpuNow.load();
    const int hold = (int)lround(steadyHoldRate());
    if (gpu >= 0 && now - g_gpuNowAt.load() < 1.5)
        diag("[anvil] steady %d: %s → %s (%.1f fps, the game's own work %.2f ms a frame, GPU %d%% busy)",
             hold, steadyName(g_steady), steadyName(next), measured, g_workEma * 1000.0, gpu);
    else
        diag("[anvil] steady %d: %s → %s (%.1f fps, the game's own work %.2f ms a frame)",
             hold, steadyName(g_steady), steadyName(next), measured, g_workEma * 1000.0);
    // Reaching 120 from below, and falling from it again soon after, which counts as
    // a failed probe.
    if (next == Steady::full && g_steady != Steady::off) g_promotedAt = now;
    if (g_steady == Steady::hold && next == Steady::low) {
        if (now - g_steadySince < kShortHold) {
            g_holdBackoff = std::min(g_holdBackoff > 0.0 ? g_holdBackoff * 2.0 : 5.0, kHoldBackoffMax);
            g_nextHoldAt = now + g_holdBackoff;
        } else if (now - g_steadySince >= kHoldClears) {
            g_holdBackoff = 0.0;
        }
    }
    if (g_steady == Steady::full && next != Steady::full && g_promotedAt >= 0.0 && now - g_promotedAt < kFallWithin) {
        g_probeBackoff = std::min(g_probeBackoff > 0.0 ? g_probeBackoff * 2.0 : 4.0, kProbeBackoffMax);
        g_nextProbeAt = now + g_probeBackoff;
        if (gpuRoom(now, measured) >= kFreeAt * steadyFullRate() || g_gpuNow.load() > 0) g_gpuMisled = true;
    }
    g_guardChangedAt = now;
    if (g_steady == Steady::hold && next == Steady::low) guardNoteTime(g_guardLetGo, g_guardLetGoN, now);
    g_steady = next;
    g_steadySince = now;
    g_cadence = 0.0;
    g_overSince = -1.0;
    if (next == Steady::probe) { g_probeEnd = now + 1.0; g_lastProbeAt = now; }
}

/// Where the game stands, once per present. At 120 Hz: hold below about 94, release when
/// the game's work passes 13 ms (it cannot keep 80 even held), free to run at its own rate
/// again when a probe confirms 98 or better.
void steadyDecide(double now) {
    if (!g_steadySettled) {
        if (now - g_steadyStartAt < g_steadySettleSec) return;
        g_steadySettled = true;
        // Judged afresh from here, not from the start's swings.
        g_steadySince = now - 1.0;
        diag("[anvil] steady %d: the start has settled — from here held to an even %d or let run up to %d as the game needs",
             (int)lround(steadyHoldRate()), (int)lround(steadyHoldRate()), (int)lround(steadyFullRate()));
    }
    const double held = now - g_steadySince;
    const double full = steadyFullRate(), holdRate = steadyHoldRate();
    switch (g_steady) {
    case Steady::full: {
        // Held at the full rate for a while: whatever back-off earlier probes earned is spent.
        if (g_probeBackoff > 0.0 && g_promotedAt >= 0.0 && now - g_promotedAt >= kFallWithin + 5.0) g_probeBackoff = 0.0;
        const double r = presentRate(1.0, now);
        if (held > 1.0 && r > 0 && r < kHoldBelow * full) steadyEnter(r >= holdRate ? Steady::hold : Steady::low, now, r);
        // Long sessions: an even 80 even where the game could make more.
        else if (enduranceOn() && held > 1.0 && r >= holdRate) steadyEnter(Steady::hold, now, r);
        break;
    }
    case Steady::hold: {
        requestGpuSample(now);
        if (g_holdBackoff > 0.0 && held >= kHoldClears) g_holdBackoff = 0.0;
        // Let go only when the work has been too long for 80 for a whole second — at
        // the line, one long frame used to flip it between held and below and back.
        if (g_workEma > 1.0 / (0.96 * holdRate)) {
            if (g_overSince < 0.0) g_overSince = now;
            if (held > 1.0 && now - g_overSince >= 1.0) { steadyEnter(Steady::low, now, presentRate(1.0, now)); break; }
        } else {
            g_overSince = -1.0;
        }
        if (!(held > 0.8 && g_workEma > 0.0 && g_workEma < 1.0 / (kFreeAt * full))) break;
        if (enduranceOn()) break;              // long sessions: no looking for 120
        const double r = presentRate(1.0, now);
        const double room = gpuRoom(now, r);
        const double sinceProbe = now - std::max(g_lastProbeAt, g_steadySince);
        // Due once the back-off has passed, unless the GPU says the full rate is out of reach.
        const bool due = now >= g_nextProbeAt && (room < 0.0 || room >= kFreeAt * full);
        // A scene that has become much lighter doesn't wait out a back-off earned in a
        // heavier one.
        const bool clear = !g_gpuMisled && room >= (kFreeAt + 0.14) * full && sinceProbe >= 3.0;
        const bool overdue = sinceProbe >= kProbeAtLeastEvery && now >= g_nextProbeAt;
        if (due || clear || overdue) steadyEnter(Steady::probe, now, r);
        break;
    }
    case Steady::probe:
        if (now >= g_probeEnd) {
            // Judged after the rush of frames the hold had kept back.
            const double r = presentRate(0.6, now);
            const Steady next = r >= kFreeAt * full ? Steady::full : (r >= holdRate ? Steady::hold : Steady::low);
            if (next != Steady::full && (gpuRoom(now, r) >= kFreeAt * full)) g_gpuMisled = true;
            // A probe that doesn't find the full rate doubles the back-off. One that does
            // leaves it, until the full rate has held for a few seconds (below): a game
            // swinging either side of 110 passed probes in its fast second and fell back
            // in its slow one, and clearing the back-off on each pass kept it at 4 s.
            if (next != Steady::full) {
                g_probeBackoff = std::min(g_probeBackoff > 0.0 ? g_probeBackoff * 2.0 : 4.0, kProbeBackoffMax);
                g_nextProbeAt = now + g_probeBackoff;
            }
            steadyEnter(next, now, r);
        }
        break;
    case Steady::low: {
        const double r = presentRate(1.5, now);
        // Straight to the full rate only when a probe would be allowed now; otherwise to
        // the hold, which probes when it may.
        if (held > 1.5 && r >= kFreeAt * full && now >= g_nextProbeAt && !enduranceOn()) steadyEnter(Steady::full, now, r);
        else if (held > 1.5 && r >= 1.075 * holdRate && now >= g_nextHoldAt) steadyEnter(Steady::hold, now, r);
        break;
    }
    default:
        break;
    }
}

void resumeAfterGap(double now, double gap);
double g_lastPresentCallAt = -1.0;
/// Seconds on a clock that keeps going while the Mac sleeps. CACurrentMediaTime — every other time here —
/// stops then, so to it a night asleep is no gap at all, and a pause taken before it is still running after.
double sleepingClock() { return (double)clock_gettime_nsec_np(CLOCK_MONOTONIC) / 1e9; }
double g_lastPresentWall = -1.0;
/// No frame for this long, then frames again: the Mac slept with the game open, or the game sat paused behind
/// another app (LEGO Star Wars stops drawing there), or a long load. See resumeAfterGap.
constexpr double kResumeGapSec = 15.0;
/// After coming back, this long shown as each frame is ready before Steady holds or probes again.
constexpr double kResumeSettleSec = 8.0;

/// Each of the game's frames in front, whoever shows it: a long gap since the last is the game back from a break
/// (resumeAfterGap). Until 0.62 only frames Steady judged counted, and while Smooth Motion showed them Steady
/// isn't asked — so each time it stopped, its whole run read as a gap with no frames. In Hogwarts Legacy on 22
/// October that lifted the pause Guardian had just put on it after its presenter stalled, 18 minutes of play read as
/// "back after 1035 s", and it started again seconds later and stalled again.
void noteFrameForGap(double callAt) {
    const double wall = sleepingClock();
    if (g_lastPresentCallAt > 0.0) {
        const double gap = std::max(callAt - g_lastPresentCallAt, g_lastPresentWall > 0.0 ? wall - g_lastPresentWall : 0.0);
        if (gap >= kResumeGapSec) resumeAfterGap(callAt, gap);
    }
    g_lastPresentCallAt = callAt;
    g_lastPresentWall = wall;
}

/// At each present: what the game spent on the frame — from leaving the last present
/// to arriving at this one, less any wait for a drawable — and where it stands.
void steadyOnPresent(double callAt) {
    noteFrameForGap(callAt);
    if (g_steadyStartAt < 0.0) {
        g_steadyStartAt = callAt;
        g_steadySettled = g_steadySettleSec <= 0.0;
        if (!g_steadySettled)
            diag("[anvil] steady %d: the game's first %.0f s shown as each frame is ready, nothing held, while its start settles",
                 (int)lround(steadyHoldRate()), g_steadySettleSec);
    }
    if (g_steady == Steady::off) { g_steady = Steady::full; g_steadySince = callAt; }
    if (g_resumedAt > 0.0) {
        const double work = callAt - g_resumedAt - g_hookWaitSec;
        if (work > 0.0005 && work < 0.25) g_workEma = g_workEma > 0.0 ? g_workEma * 0.8 + work * 0.2 : work;
    }
    notePresentCall(callAt);
    steadyDecide(callAt);
}

// --- FSR 3 within the frame's budget ----------------------------------------------------
// FSR 3 costs about 2.3 ms a frame more than FSR 1 on an M4 at LEGO's sizes (Graphics Prep
// measures it for each game and passes it on). On 3 October LEGO Star Wars ran it with the GPU
// an average 89% busy, against 75–80% with FSR 1, and was below 78 fps a fifth of the time:
// where the game is short of an even 80 with the GPU full, those milliseconds are the
// difference. So FSR 3 eases to FSR 1 after 2 s of that — where FSR 1's saving gets the game to
// 80; where it wouldn't (50 fps with the GPU full: 17.6 ms a frame less 2 is still 15.6) FSR 3
// stays, its picture kept for the same lack of frames. It comes back once, for 3 s, the GPU's
// time a frame with FSR 3's added fits an even 80 with a tenth to spare (a fifth in a long
// session) — at least 8 s later, and twice as long each time it has to ease again within 20 s
// of coming back, up to two minutes. Its cost is then learned from the GPU's load either side
// of coming back. A hot Mac gets FSR 1 until it cools.
//
// Judged a frame at a time. 0.30.0 first judged the GPU's share a second: at 110 fps FSR 3's
// 2 ms is 22% of a second, so a GPU 85% busy never had room, and LEGO's sessions of 4 and 5
// October ran FSR 1 for 93–99% of their windows, though FSR 3 would have kept them above 90.
double g_fsr3ShortSince = -1.0, g_fsr3RoomSince = -1.0;
double g_fsr3BackAt = -1.0, g_fsr3NextBackAt = 0.0, g_fsr3EaseBackoff = 0.0, g_fsr3GovernAt = 0.0;
int    g_fsr3GpuBefore = -1;            // the GPU's load just before FSR 3 came back,
double g_fsr3RateBefore = 0.0;          // and the frame rate then
double g_fsr3HeavierSince = -1.0;       // eased, and the game since down in Smooth Motion's band past FSR 1's reach
constexpr double kFsr3EaseBackoffMax = 120.0;

bool midWouldEngage(double now, double ownFPS);

/// The game back after a long gap with no frames. What Anvil had backed off from before it — Smooth Motion
/// paused after frames between cost the game its own (a minute, doubling to ten), FSR 3 kept eased to FSR 1
/// for up to two minutes, frame generation's slower start after a quick stop, Steady's probe and hold
/// back-offs — was about the scene and the Mac before the gap, not the ones it comes back to: a ten-minute
/// pause earned in one fight would otherwise still be running after the Mac slept through dinner (LEGO Star
/// Wars slept 40 minutes mid-session on 17 October). So it all starts afresh, and the first seconds back are
/// shown as each frame is ready, nothing held, while the game catches up (a resume often loads and compiles).
/// What Guardian has learned is kept: it is about this Mac, not the moment.
void resumeAfterGap(double now, double gap) {
    const bool midWasPaused = g_midPausedUntil > now;
    g_midPauseFor = 0.0;
    if (midWasPaused) g_midPausedUntil = now;
    g_genEngageBackoff = 0.0;
    g_probeBackoff = 0.0;
    g_nextProbeAt = now;
    g_holdBackoff = 0.0;
    g_nextHoldAt = now;
    g_overSince = -1.0;
    g_fsr3EaseBackoff = 0.0;
    g_fsr3ShortSince = g_fsr3RoomSince = g_fsr3HeavierSince = -1.0;
    const bool fsr3WasEased = g_fsr3Eased.load();
    if (fsr3WasEased) g_fsr3NextBackAt = now;
    // The settle: Steady's start-up rule again, for kResumeSettleSec.
    if (g_steadySettleSec > 0.0) {
        g_steadyStartAt = now - std::max(0.0, g_steadySettleSec - kResumeSettleSec);
        g_steadySettled = false;
    }
    diag("[anvil] back after %.0f s with no frames (the Mac asleep, or the game paused or behind another app) — "
         "%s%s Steady's back-offs cleared, and the first %.0f s shown as each frame is ready",
         gap, midWasPaused ? "Smooth Motion's pause lifted, " : "", fsr3WasEased ? "FSR 3 free to come back, " : "",
         kResumeSettleSec);
}

/// FSR 3's cost as seen: the GPU's milliseconds a frame a few seconds after it came back,
/// less those just before, at about the same frame rate.
void fsr3Learn(double now, double rate, int gpu) {
    if (g_fsr3GpuBefore < 0 || g_fsr3BackAt < 0.0 || now - g_fsr3BackAt < 2.0) return;
    if (now - g_fsr3BackAt <= 5.0 && gpu > 0 && gpu < 100 && rate > 1.0 && g_fsr3RateBefore > 1.0
        && fabs(rate - g_fsr3RateBefore) < 0.1 * g_fsr3RateBefore) {
        const double seen = (gpu / rate - g_fsr3GpuBefore / g_fsr3RateBefore) * 10.0;
        if (seen > 0.0) g_fsr3ExtraMs = std::min(std::max(0.5 * g_fsr3ExtraMs + 0.5 * seen, 0.8), 8.0);
    }
    g_fsr3GpuBefore = -1;
}

/// The GPU's milliseconds a frame: busy `gpu`% of the time at `rate` frames a second. -1 not known.
double gpuMsPerFrame(double rate, int gpu) { return (gpu > 0 && rate > 1.0) ? gpu * 10.0 / rate : -1.0; }

/// A step of the budget, at most four times a second: `rate` the game's own frames a second,
/// `gpu` the GPU's busy percent (-1 not known), `hot` whether the Mac is.
void fsr3GovernStep(double now, double rate, int gpu, bool hot) {
    const double target = steadyHoldRate();
    const double budgetMs = 1000.0 / target;               // 12.5 at 80
    const double gpuMs = gpuMsPerFrame(rate, gpu);
    if (!g_fsr3Eased.load()) {
        // Short of an even 80 with the GPU full, and FSR 1's saving would get it there. Not while
        // Smooth Motion makes frames between from FSR 3's pictures — unless the Mac is hot.
        const bool shortOf = hot || (gpu >= 88 && rate > 1.0 && rate < 0.97 * target
                                     && gpuMs - g_fsr3ExtraMs <= 1.05 * budgetMs && !g_mid.load());
        if (!shortOf) { g_fsr3ShortSince = -1.0; fsr3Learn(now, rate, gpu); return; }
        if (g_fsr3ShortSince < 0.0) g_fsr3ShortSince = now;
        if (!hot && now - g_fsr3ShortSince < 2.0) return;
        g_fsr3EaseBackoff = (g_fsr3BackAt >= 0.0 && now - g_fsr3BackAt < 20.0)
            ? std::min(std::max(g_fsr3EaseBackoff, 8.0) * 2.0, kFsr3EaseBackoffMax) : 8.0;
        g_fsr3NextBackAt = now + g_fsr3EaseBackoff;
        g_fsr3Eased = true;
        g_guardChangedAt = now;
        g_fsr3ShortSince = g_fsr3RoomSince = -1.0;
        g_fsr3GpuBefore = -1;
        g_fsr3Eases.fetch_add(1, std::memory_order_relaxed);
        if (hot)
            diag("[anvil] FSR 3: FSR 1 for now — the Mac is hot; FSR 3 again once it has cooled and the GPU has room");
        else
            diag("[anvil] FSR 3: FSR 1 for now — the game is at %.0f fps with the GPU %d%% busy (%.1f ms a frame), short of "
                 "an even %.0f that FSR 1's %.1f ms less reaches; FSR 3 again in %.0f s or more, once it fits",
                 rate, gpu, gpuMs, target, g_fsr3ExtraMs, g_fsr3EaseBackoff);
        return;
    }
    // Heavier since (0.55): the game down in Smooth Motion's band, where FSR 1's saving no longer reaches an even 80
    // — the reason it was eased — and frames between are made from FSR 3's pictures alone. Eased, they couldn't be,
    // and 0.47's frames made ahead filled in over FSR 1: on 16 October LEGO Star Wars eased at 72–76 fps, came into a
    // heavier place at 47–56, and spent 63 of the evening's 910 windows like that, the look of both at their least.
    // Back after 2 s of it, whatever the wait, so Smooth Motion can take over.
    if (!hot && rate > 1.0 && rate < 0.97 * target && midWouldEngage(now, rate)) {
        if (g_fsr3HeavierSince < 0.0) g_fsr3HeavierSince = now;
        if (now - g_fsr3HeavierSince >= 2.0) {
            g_fsr3HeavierSince = -1.0;
            g_fsr3Eased = false;
            g_guardChangedAt = now;
            g_fsr3BackAt = now;
            g_fsr3RoomSince = -1.0;
            g_fsr3GpuBefore = -1;
            diag("[anvil] FSR 3: back — the game is down to %.0f fps of its own, past what FSR 1's saving lifts to an even %.0f; "
                 "Smooth Motion makes its frames between from FSR 3's pictures", rate, target);
            return;
        }
    } else {
        g_fsr3HeavierSince = -1.0;
    }
    if (hot || now < g_fsr3NextBackAt || gpuMs < 0.0) { g_fsr3RoomSince = -1.0; return; }
    // Room: at an even 80 or better, the GPU's time a frame with FSR 3's added fits 80 with a
    // tenth to spare — a fifth in a long session.
    const double spare = enduranceOn() ? 0.80 : 0.90;
    if (!(rate >= 0.99 * target && gpuMs + g_fsr3ExtraMs <= spare * budgetMs)) { g_fsr3RoomSince = -1.0; return; }
    if (g_fsr3RoomSince < 0.0) g_fsr3RoomSince = now;
    if (now - g_fsr3RoomSince < 3.0) return;
    g_fsr3Eased = false;
    g_guardChangedAt = now;
    g_fsr3BackAt = now;
    g_fsr3RoomSince = -1.0;
    g_fsr3GpuBefore = gpu;
    g_fsr3RateBefore = rate;
    diag("[anvil] FSR 3: back — %.0f fps with the GPU %d%% busy, %.1f ms a frame: %.1f with FSR 3, inside an even %.0f's %.1f",
         rate, gpu, gpuMs, gpuMs + g_fsr3ExtraMs, target, budgetMs);
}

/// At each present while FSR 3 is on: the game's rate and a fresh GPU reading, for the budget.
void fsr3Govern(double now) {
    if (!g_fsr3Wanted || g_fsr3Failed.load() || !g_outputActive.load()) return;
    if (now - g_fsr3GovernAt < 0.25) return;
    g_fsr3GovernAt = now;
    requestGpuSample(now);
    const int gpu = (g_gpuNow.load() >= 0 && now - g_gpuNowAt.load() <= 1.5) ? g_gpuNow.load() : -1;
    const double measured = g_steady != Steady::off ? presentRate(1.0, now) : -1.0;
    fsr3GovernStep(now, measured > 0.0 ? measured : g_fpsSmoothed, gpu, macHot());
}

/// While held: this frame's point on the 80 Hz cadence. A frame later than one whole
/// step starts the cadence again from itself rather than trying to catch up.
double steadyHoldTarget(double now) {
    const double hold = 1.5 * g_refreshPeriod;
    const double target = (g_cadence <= 0.0 || now > g_cadence + hold) ? now : g_cadence + hold;
    g_cadence = target;
    return target;
}

/// Each present: whether Steady runs, and a fresh look at the display when one is due.
///
/// The hold needs a display that follows the game. On a fixed 120 Hz grid an even 80 can't
/// be shown: a frame held to 12.5 ms waits for the 16.7 ms refresh, and a held game is
/// shown at 60. That is what LEGO Star Wars got on 2 October: the hold began in the first
/// second, the display was then judged fixed, and the hold never ended — every frame held
/// for the whole session, 60–80 fps shown while the game could make 85 to 185.
void steadyAtPresent(double callAt, bool drawable) {
    if (drawable) noteFrameForGap(callAt);
    if (g_vrrState == 0 && g_vrrRetryAt > 0.0 && callAt >= g_vrrRetryAt) {
        g_vrrRetryAt = 0.0;
        g_vrrChecked = 0;
        g_vrrOffGrid = 0;
        g_vrrState = 2;
        diag("[anvil] looking again at whether the display follows the game");
    }
    // A long session holds an even 80 in a game set to run up to the display's rate too; one
    // held to 60 or 30 keeps that.
    const bool wanted = g_steadyWanted || (enduranceOn() && g_targetFPS <= 0);
    if (wanted && g_vrrState == 1 && !g_generating && g_refreshPeriod > 0.0 && drawable) {
        steadyOnPresent(callAt);
    } else if (g_steady != Steady::off) {
        if (g_steady == Steady::hold && g_vrrState != 1 && !g_generating && drawable)
            diag("[anvil] steady %d: nothing held while the display doesn't follow the game — each frame "
                 "shown at the display's next refresh", (int)lround(steadyHoldRate()));
        g_steady = g_vrrState == 1 ? Steady::full : Steady::off;
        g_cadence = 0.0;
    }
}

/// Past the game's first seconds of logos, intros and loading (g_steadySettleSec).
bool startSettled(double now) {
    return g_steadySettleSec <= 0.0 || (g_sessionStartAt >= 0.0 && now - g_sessionStartAt >= g_steadySettleSec);
}

// --- Smooth Motion between frames: the presenter (see g_mid) --------------------------------------

NSUInteger midPixelBytes(MTLPixelFormat f);

/// Whether frames can be made between: FSR 3 to the display is on, with its pictures and motion.
bool midAvailable() {
#ifdef ANVIL_INJECT_TEST
    if (g_midAvailableForTest >= 0) return g_midWanted && g_midAvailableForTest == 1;
#endif
    return g_midWanted && g_midpoint && g_outputActive.load() && g_fsr3Wanted && !g_fsr3Failed.load()
        && !g_fsr3Eased.load() && g_outLayer && g_originalNextDrawable && g_drawableClass
        && midPixelBytes(g_outLayer.pixelFormat) > 0;
}

/// The presenter's dispatch queue and Metal queue.
bool midEnsureQueue() {
    if (!g_device || !g_midpoint) return false;
    if (!g_midQueue) g_midQueue = [g_device newCommandQueue];
    if (!g_midDispatch) {
        // At utility priority, which macOS runs on the efficiency cores: the copies there leave the
        // power budget to the GPU. At user-interactive, on the performance cores, the game made 32.4 fps
        // of its own under Rosetta in Anvil's stand-in; at utility 34.1; with Smooth Motion off 36.0 —
        // and frames reached the screen as evenly (13 October). Its timing needs no precision of its
        // own: each present is timed by the display from the one before.
        qos_class_t qos = QOS_CLASS_UTILITY;
        if (const char* q = getenv("ANVIL_MID_QOS")) qos = q[0] == 'i' ? QOS_CLASS_USER_INTERACTIVE : q[0] == 'd' ? QOS_CLASS_DEFAULT : qos;
        g_midDispatch = dispatch_queue_create("anvil.smooth-motion", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, qos, 0));
    }
    return g_midQueue && g_midDispatch;
}

/// `t` as a private texture of this size and format — made again when it isn't — that compute writes
/// (through a plain view, for an sRGB format) and blits copy.
bool midTexture(id<MTLTexture>& t, NSUInteger width, NSUInteger height, MTLPixelFormat format, MTLTextureUsage usage) {
    if (t && t.width == width && t.height == height && t.pixelFormat == format) return true;
    releaseLater(t);
    t = nil;
    if (!g_device || width == 0 || height == 0) return false;
    MTLTextureDescriptor* d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:width height:height mipmapped:NO];
    d.usage = usage | MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    if (plainFormat(format) != format) d.usage |= MTLTextureUsagePixelFormatView;
    d.storageMode = MTLStorageModePrivate;
    t = [g_device newTextureWithDescriptor:d];
    return t != nil;
}

/// Bytes a pixel of a format the presenter copies — 0 for one it doesn't.
NSUInteger midPixelBytes(MTLPixelFormat f) {
    switch (f) {
    case MTLPixelFormatBGRA8Unorm: case MTLPixelFormatRGBA8Unorm: case MTLPixelFormatRGB10A2Unorm:
    case MTLPixelFormatBGR10A2Unorm: return 4;
    case MTLPixelFormatRGBA16Float: return 8;
    default: return 0;
    }
}

/// `t` as a picture at the display's size the GPU writes and the CPU reads as written: a texture over
/// a shared buffer, its rows 256-byte aligned as an IOSurface's are.
bool midPicture(id<MTLTexture>& t, NSUInteger width, NSUInteger height, MTLPixelFormat format) {
    if (t && t.width == width && t.height == height && t.pixelFormat == format) return true;
    releaseLater(t);
    t = nil;
    const NSUInteger bpp = midPixelBytes(format);
    if (!g_device || width == 0 || height == 0 || bpp == 0) return false;
    const NSUInteger align = std::max<NSUInteger>(256, [g_device minimumLinearTextureAlignmentForPixelFormat:format]);
    const NSUInteger row = (width * bpp + align - 1) / align * align;
    id<MTLBuffer> buffer = [g_device newBufferWithLength:row * height options:MTLResourceStorageModeShared];
    if (!buffer) return false;
    MTLTextureDescriptor* d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:width height:height mipmapped:NO];
    d.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    d.storageMode = MTLStorageModeShared;
    t = [buffer newTextureWithDescriptor:d offset:0 bytesPerRow:row];
    [buffer release];                                    // the texture keeps it
    return t != nil;
}

/// `picture` into `drawable` by the CPU: its IOSurface locked and the rows copied, on the presenter's own
/// thread. One thread, not four: four at once finished sooner but drew the power the GPU runs on — the
/// game made 32.6 fps of its own beside them in Anvil's stand-in, 34.3 beside one, 35.6 with Smooth
/// Motion off (13 October). One copies LEGO's 3024x1964 in about 3 ms.
bool midCopyIn(id<MTLTexture> picture, id<CAMetalDrawable> drawable) {
    id<MTLTexture> dt = drawable.texture;
    IOSurfaceRef surface = dt.iosurface;
    id<MTLBuffer> buffer = picture.buffer;
    const NSUInteger bpp = midPixelBytes(picture.pixelFormat);
    if (!surface || !buffer || !bpp || dt.width != picture.width || dt.height != picture.height
        || dt.pixelFormat != picture.pixelFormat) return false;
    if (IOSurfaceLock(surface, 0, nullptr) != kIOReturnSuccess) return false;
    uint8_t* dst = (uint8_t*)IOSurfaceGetBaseAddress(surface);
    const size_t dstRow = IOSurfaceGetBytesPerRow(surface);
    const uint8_t* src = (const uint8_t*)buffer.contents + picture.bufferOffset;
    const size_t srcRow = picture.bufferBytesPerRow, rowBytes = picture.width * bpp, rows = picture.height;
    const bool fits = dst && IOSurfaceGetAllocSize(surface) >= dstRow * rows && dstRow >= rowBytes;
    if (fits) {
        if (dstRow == srcRow) memcpy(dst, src, rows * dstRow);
        else for (size_t y = 0; y < rows; ++y) memcpy(dst + y * dstRow, src + y * srcRow, rowBytes);
    }
    IOSurfaceUnlock(surface, 0, nullptr);
    return fits;
}

/// The next of the textures the game draws into while frames go through the presenter, at its size.
id<MTLTexture> midInputNext(MTLPixelFormat format) {
    const int k = g_midInputNext;
    if (!midTexture(g_midInputs[k], (NSUInteger)g_gameSize.width, (NSUInteger)g_gameSize.height, format,
                    MTLTextureUsageRenderTarget)) return nil;
    g_midInputNext = (k + 1) % 3;
    return g_midInputs[k];
}

/// The frames between FSR 3's last two pictures — one halfway, or two or three evenly between (g_midMult) — in
/// the game's command buffer right after FSR 3, into the presenter's textures like `shown`: their code
/// (midMadeCode), or -1 when there are none to make.
int midEncode(id<MTLCommandBuffer> cb, id<MTLTexture> shown) {
    OwnGpuWork own;
    id<MTLTexture> before = AnvilFSR3PictureBefore(&g_fsr3), after = AnvilFSR3Picture(&g_fsr3);
    id<MTLTexture> motion = AnvilFSR3Motion(&g_fsr3), motionBefore = AnvilFSR3MotionBefore(&g_fsr3);
    if (!before || !after || !motion || !shown || !g_midpoint) return -1;
    if (after.width != shown.width || after.height != shown.height) return -1;
    const int k = g_midNext;
    const int m = std::clamp(g_midMult.load(), 2, std::min(g_midMultMax, kMidMultMax));
    for (int j = 0; j < m - 1; ++j)
        if (!midPicture(g_midFrames[k][j], shown.width, shown.height, shown.pixelFormat)) return -1;
    g_midNext ^= 1;
    const double scaleUp = g_fsr3.width > 0 ? (double)g_fsr3.outWidth / (double)g_fsr3.width : 1.0;
    // The counter as FSR 3 draws it on the real frames, so it doesn't flicker between them.
    const simd_float4 params = {
        0.0f,
        (float)(g_displayedFPS > 0.0 ? g_displayedFPS : g_fpsSmoothed),
        (float)std::max(1.0, round(g_overlayScale * scaleUp)),
        g_overlayOn ? overlayCornerParam() : -1.0f,
    };
    const simd_float4 game = {(float)g_fsr3.width, (float)g_fsr3.height, (float)(8 * g_fsr3.scale), 0.0f};
    if (!g_midCheckState) {
        g_midCheckState = [g_device newBufferWithLength:sizeof(MidCheckState) options:MTLResourceStorageModeShared];
        if (g_midCheckState) memset(g_midCheckState.contents, 0, sizeof(MidCheckState));
    }
    if (!g_midCheckState) return -1;
    id<MTLTexture> lumaBefore = AnvilFSR3LumaBefore(&g_fsr3), luma = AnvilFSR3Luma(&g_fsr3);
    // The map of where the two frames disagree, a value for each 4x4 of the planes the check looks at (1x1 with none).
    {
        const NSUInteger mw = luma ? std::max<NSUInteger>(1, (luma.width + 3) / 4) : 1, mh = luma ? std::max<NSUInteger>(1, (luma.height + 3) / 4) : 1;
        if (!g_midApartMap || g_midApartMap.width != mw || g_midApartMap.height != mh) {
            releaseLater(g_midApartMap);
            MTLTextureDescriptor* d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR16Float width:mw height:mh mipmapped:NO];
            d.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
            d.storageMode = MTLStorageModePrivate;
            g_midApartMap = [g_device newTextureWithDescriptor:d];
        }
    }
    if (!g_midApartMap) return -1;
    const bool checked = g_midCheckOn && g_midCheck && g_midJudge && lumaBefore && luma;
    id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
    if (checked) {
        // The two frames looked at (FSR 3's luma planes of them), and the verdict: the made frames below read it,
        // and the map of where. One encoder, in order.
        const simd_float4 halfway = {0.5f, 0.0f, 0.0f, 0.0f};
        const simd_float4 rule = {g_midCheckApart, g_midCheckShare, g_midCheckPart, 0.0f};
        const simd_float4 planes = {game.x, game.y, game.z, (float)g_fsr3.scale};
        [enc setComputePipelineState:g_midCheck];
        [enc setTexture:lumaBefore atIndex:0];
        [enc setTexture:luma atIndex:1];
        [enc setTexture:motion atIndex:2];
        [enc setTexture:g_midApartMap atIndex:3];
        [enc setBuffer:g_midCheckState offset:0 atIndex:0];
        [enc setBytes:&halfway length:sizeof(halfway) atIndex:1];
        [enc setBytes:&planes length:sizeof(planes) atIndex:2];
        [enc setBytes:&rule length:sizeof(rule) atIndex:3];
        dispatch(enc, g_midCheck, (luma.width + 3) / 4, (luma.height + 3) / 4);
        [enc setComputePipelineState:g_midJudge];
        [enc setBuffer:g_midCheckState offset:0 atIndex:0];
        [enc setBytes:&rule length:sizeof(rule) atIndex:1];
        [enc dispatchThreads:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
    }
    [enc setComputePipelineState:g_midpoint];
    [enc setTexture:before atIndex:0];
    [enc setTexture:after atIndex:1];
    [enc setTexture:motion atIndex:2];
    [enc setTexture:motionBefore ? motionBefore : motion atIndex:3];
    [enc setBytes:&params length:sizeof(params) atIndex:0];
    [enc setBytes:&game length:sizeof(game) atIndex:2];
    [enc setBuffer:g_midCheckState offset:0 atIndex:3];
    [enc setTexture:g_midApartMap atIndex:5];
    // Each at its moment between the two: 1/m, 2/m, … of the way from the earlier frame to the later.
    for (int j = 0; j < m - 1; ++j) {
        id<MTLTexture> out = rawView(cb, g_midFrames[k][j]);
        const simd_float4 mid = {(float)(j + 1) / (float)m, motionBefore ? 1.0f : 0.0f, checked ? 0.0f : 16.0f, 0.0f};
        [enc setTexture:out atIndex:4];
        [enc setBytes:&mid length:sizeof(mid) atIndex:1];
        dispatch(enc, g_midpoint, out.width, out.height);
    }
    [enc endEncoding];
    return midMadeCode(k, m - 1);
}

void midAnswerStandIn(AnvilProxyDrawable* s, CFTimeInterval presented) {
    if (!s) return;
    s->_presentedTime = presented;
    for (MTLDrawablePresentedHandler h in s->_presentedHandlers) h((id<MTLDrawable>)s);
    [s release];
}

/// The link running at `fps`, made on a thread of its own the first time. False where it can't be (before macOS 14).
bool midLinkStart(double fps) {
    if (!g_dlWanted || !g_outLayer) return false;
    if (@available(macOS 14.0, *)) {
        if (!g_dlQueue) g_dlQueue = new std::deque<MidEntry>();
        if (!g_dlLink) {
            dispatch_semaphore_t made = dispatch_semaphore_create(0);
            CAMetalLayer* layer = [g_outLayer retain];
            NSThread* thread = [[NSThread alloc] initWithBlock:^{
                @autoreleasepool {
                    AnvilMidLink* delegate = [AnvilMidLink new];
                    CAMetalDisplayLink* link = [[CAMetalDisplayLink alloc] initWithMetalLayer:layer];
                    link.delegate = delegate;
                    link.preferredFrameLatency = 2.0f;
                    link.paused = YES;
                    [link addToRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
                    g_dlDelegate = delegate;
                    g_dlLink = link;
                    g_dlRunLoop = (CFRunLoopRef)CFRetain(CFRunLoopGetCurrent());
                    // A port of its own, so the run loop runs while the link is paused too: with nothing else to
                    // wait on, a run loop returns at once, and the link made paused never called (14 October).
                    [[NSRunLoop currentRunLoop] addPort:[NSMachPort port] forMode:NSDefaultRunLoopMode];
                    [layer release];
                    dispatch_semaphore_signal(made);
                }
                while (true) @autoreleasepool { [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]]; }
            }];
            thread.name = @"Anvil Smooth Motion link";
            thread.qualityOfService = NSQualityOfServiceUtility;
            [thread start];
            if (dispatch_semaphore_wait(made, dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC)) != 0 || !g_dlLink) return false;
        }
        CAMetalDisplayLink* link = (CAMetalDisplayLink*)g_dlLink;
        g_dlTick = 1.0 / fps;
        g_dlLastDue = 0.0;
        g_dlActive.store(true);
        // On the link's own thread, as it was made: changed from another, it stalled (Anvil's stand-in, 14 October).
        const float rate = (float)fps;
        CFRunLoopPerformBlock(g_dlRunLoop, kCFRunLoopDefaultMode, ^{
            link.preferredFrameRateRange = CAFrameRateRangeMake(rate, rate, rate);
            link.paused = NO;
        });
        CFRunLoopWakeUp(g_dlRunLoop);
        diag("[anvil] Smooth Motion: shown through a display link at %.0f fps — each frame asked for just before its refresh", fps);
        return true;
    }
    return false;
}

/// The link stopped, and whatever it still had answered as not shown.
void midLinkStop() {
    if (!g_dlActive.exchange(false)) return;
    if (@available(macOS 14.0, *)) {
        if (g_dlRunLoop) {
            CAMetalDisplayLink* link = (CAMetalDisplayLink*)g_dlLink;
            CFRunLoopPerformBlock(g_dlRunLoop, kCFRunLoopDefaultMode, ^{ link.paused = YES; });
            CFRunLoopWakeUp(g_dlRunLoop);
        }
    }
    std::deque<MidEntry> left;
    os_unfair_lock_lock(&g_dlLock);
    if (g_dlQueue) left.swap(*g_dlQueue);
    os_unfair_lock_unlock(&g_dlLock);
    for (MidEntry& e : left) midAnswerStandIn(e.standIn, 0.0);
}

/// One refresh of the link's: the newest frame due by its time, copied into the drawable it gives and shown.
/// Nothing new due: nothing shown, the screen keeps the frame it has.
void midLinkUpdate(id<CAMetalDrawable> drawable, double target) {
    if (!g_dlActive.load() || !g_dlQueue) return;
    MidEntry chosen{};
    bool have = false;
    std::vector<MidEntry> passed;
    os_unfair_lock_lock(&g_dlLock);
    while (!g_dlQueue->empty() && g_dlQueue->front().due <= target + 0.5 * g_dlTick) {
        if (have) passed.push_back(chosen);
        chosen = g_dlQueue->front();
        have = true;
        g_dlQueue->pop_front();
    }
    os_unfair_lock_unlock(&g_dlLock);
    // Two due at one refresh: the newer shown, the older passed over — its game frame answered with the one shown.
    for (MidEntry& e : passed) {
        if (e.real) g_notShown.fetch_add(1, std::memory_order_relaxed);
        else g_skippedGenerations.fetch_add(1, std::memory_order_relaxed);
        if (e.standIn && !chosen.standIn) { chosen.standIn = e.standIn; e.standIn = nil; }
        midAnswerStandIn(e.standIn, 0.0);
    }
    if (!have) return;
    if (!drawable || !midCopyIn(chosen.picture, drawable)) {
        if (chosen.real) g_notShown.fetch_add(1, std::memory_order_relaxed);
        midAnswerStandIn(chosen.standIn, 0.0);
        return;
    }
    const bool real = chosen.real;
    AnvilProxyDrawable* standIn = chosen.standIn;
    g_pendingPresents.fetch_add(1, std::memory_order_release);
    @try {
        [drawable addPresentedHandler:^(id<MTLDrawable> shown) {
            g_pendingPresents.fetch_sub(1, std::memory_order_release);
            if (real && shown.presentedTime <= 0) g_notShown.fetch_add(1, std::memory_order_relaxed);
            noteShown(!real, shown.presentedTime);
            midAnswerStandIn(standIn, shown.presentedTime);
        }];
    } @catch (NSException*) {
        g_pendingPresents.fetch_sub(1, std::memory_order_release);
        midAnswerStandIn(standIn, 0.0);
    }
    [drawable present];
    if (!real) { g_midMade.fetch_add(1, std::memory_order_relaxed); ++g_generated; }
}


void midPresent(id<CAMetalDrawable> real, AnvilProxyDrawable* proxy, int shown, int made, double finished, double handled);

/// The game's frame to the presenter, shown once its GPU work is done: either already in `real` (a
/// stand-in made before frames went through the presenter), or after FSR in Anvil's picture `shown`
/// for the stand-in `proxy`, which has no drawable of the layer's behind it.
void midHandOff(id<MTLCommandBuffer> cb, id<CAMetalDrawable> real, AnvilProxyDrawable* proxy, int shown, int made) {
    [real retain];                                       // both released by the presenter
    [proxy retain];
    g_midBacklog.fetch_add(1, std::memory_order_acq_rel);
    g_midHandedAt.store(CACurrentMediaTime());
    [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
        // When its GPU work ended, on the clock presents are timed with.
        const double handled = CACurrentMediaTime();
        const double ended = done.GPUEndTime > 0.0 ? done.GPUEndTime : handled;
        dispatch_block_t work = ^{ midPresent(real, proxy, shown, made, ended, handled); };
        // The presenter behind — frames waiting, nothing shown for three of the game's frames: this one, and with it
        // whatever is ahead of it on the presenter's queue, runs at user-interactive priority. At utility priority,
        // on the efficiency cores, it went without the CPU for 1–2.6 s at a time in Hogwarts Legacy on 22 October,
        // the game's own threads at three quarters of a core each and the Mac swapping: the game, which waits for
        // its frames to reach the screen, stopped with it.
        if (g_midBacklog.load() >= 2 && handled - g_midShownAt.load() > std::max(0.1, 3.0 * g_midInterval)) {
            dispatch_block_t urgent = dispatch_block_create_with_qos_class(DISPATCH_BLOCK_ENFORCE_QOS_CLASS, QOS_CLASS_USER_INTERACTIVE, 0, work);
            dispatch_async(g_midDispatch, urgent);
            Block_release(urgent);
            g_midBoosts.fetch_add(1, std::memory_order_relaxed);
        } else {
            dispatch_async(g_midDispatch, work);
        }
    }];
}

/// A stand-in with no drawable behind it, presented in `cb`: FSR from what the game drew into Anvil's
/// picture of the frame, the frame between made after it, and both to the presenter. False when FSR
/// couldn't be encoded — the frame is then not shown.
bool midPresentStandIn(id<MTLCommandBuffer> cb, AnvilProxyDrawable* proxy) {
    if (!g_outLayer || !cb || cb.status != MTLCommandBufferStatusNotEnqueued) return false;
    const int k = g_midShownNext;
    if (!midPicture(g_midShown[k], (NSUInteger)g_outSize.width, (NSUInteger)g_outSize.height, g_outLayer.pixelFormat))
        return false;
    g_midShownNext = (k + 1) % 3;
    id<MTLTexture> target = g_midShown[k];
    bool upscaled = false;
    @try {
        upscaled = fsr3Encode(cb, proxy->_input, target);
        if (!upscaled) upscaled = outputEncode(cb, proxy->_input, target);
    } @catch (NSException* e) {
        if (g_fsr3Wanted && !g_fsr3Failed.load()) fsr3Stop("Metal refused a pass at present");
        diag("[anvil] FSR to the display: %s — %s", e.name.UTF8String, e.reason.UTF8String);
        upscaled = false;
    }
    if (!upscaled) return false;
    const int made = (g_midInsert.load() && g_fsr3Live) ? midEncode(cb, target) : -1;
    midHandOff(cb, nil, proxy, k, made);
    return true;
}

/// A drawable of the game's layer, for the presenter to show a frame in: waits, if it must, for the
/// one on screen to be replaced — a frame it has already asked to show.
id<CAMetalDrawable> midDrawable() {
    if (!g_outLayer || !g_originalNextDrawable) return nil;
    const double from = CACurrentMediaTime();
    id<CAMetalDrawable> d = ((id (*)(id, SEL))g_originalNextDrawable)(g_outLayer, @selector(nextDrawable));
    g_midWaitUs.fetch_add((uint64_t)((CACurrentMediaTime() - from) * 1e6), std::memory_order_relaxed);
    return d;
}

/// The presenter, on its own queue, for each frame of the game's as its GPU work ends: the made
/// frame between it and the one before shown now, this one half the game's frame time later.
void midPresent(id<CAMetalDrawable> real, AnvilProxyDrawable* proxy, int shown, int made, double finished, double handled) {
    OwnGpuWork own;
    @autoreleasepool {
        const double began = CACurrentMediaTime();
        if (g_midLastDone > 0.0) {
            const double dt = finished - g_midLastDone;
            if (dt > 0.003 && dt < 0.25)
                g_midInterval = g_midInterval > 0.0 ? g_midInterval * 0.8 + dt * 0.2 : dt;
        }
        g_midLastDone = finished;
        if (g_midInterval > 0.0) g_midRate.store(1.0 / g_midInterval);
        // A frame between needs two refreshes' room: made from below 58 fps at 120 Hz, not above 61.
        const double two = 2.0 * g_refreshPeriod;
        if (!g_midInserting && g_midInterval >= two * 1.04 && g_midInterval <= 1.0 / kMidLowFPS) g_midInserting = true;
        else if (g_midInserting && (g_midInterval < two * 0.99 || g_midInterval > 1.0 / (kMidLowFPS - 3.0))) g_midInserting = false;
        g_midInsert.store(g_midInserting && g_mid.load());
        const bool debug = g_midDebug.load() > 0;
        if (debug) g_midDebug.fetch_sub(1);
        // How many frames to show for each of the game's: as many as bring it nearest the steady rate (80 on a
        // 120 Hz ProMotion panel, the display's own rate on one at a fixed rate) — 20 fps of the game's shown as
        // 80 with three made between each two, 27 as 81 with two, 40 as 80 with one — each at least a refresh
        // apart, at most four. Changed after a second of wanting it, not frame by frame.
        {
            const double refreshNow = g_refreshPeriod > 0.0 ? g_refreshPeriod : 1.0 / 60.0;
            const double target = g_vrrState == 0 ? 1.0 / refreshNow : steadyHoldRate();
            int want = (int)std::lround(target * g_midInterval);
            want = std::min(want, (int)std::floor(g_midInterval / (refreshNow * 1.02)));
            want = std::clamp(want, 2, std::min(g_midMultMax, kMidMultMax));
            if (want != g_midMultWant) { g_midMultWant = want; g_midMultSince = began; }
            if (want != g_midMult.load() && began - g_midMultSince >= 1.0 && g_midInserting) {
                g_midMult.store(want);
                diag("[anvil] Smooth Motion: %d frames shown for each of the game's (%.1f fps of its own, about %.0f on the screen)",
                     want, g_midInterval > 0.0 ? 1.0 / g_midInterval : 0.0, g_midInterval > 0.0 ? want / g_midInterval : 0.0);
                // Three or four a frame through the display link; one made between as before.
                if (want > 2 && !g_dlActive.load()) midLinkStart(target);
                else if (want == 2) midLinkStop();
            }
        }
        const int count = midMadeCount(made);           // made frames for this one, as encoded
        const int perFrame = count + 1;
        const double half = g_midInterval / perFrame;
        // The gaps. The made frame is shown as soon as it's ready — the game's frame done — no sooner than
        // a refresh after the real one before it; the real one follows it by half the game's frame, in
        // whole steps of the panel (240 Hz on a 120 Hz ProMotion panel, which shows frames only on them;
        // a whole refresh on a display at a fixed rate), asked a millisecond short so it lands on the step.
        // Never so long that the two take more than the game's frame: the real one at most the game's
        // frame less a refresh after the made one, so the next made frame always has its refresh.
        //
        // 0.48 timed both from the frame before, each the same whole number of steps — up to 5% more than
        // half the game's frame between them. LEGO Star Wars waits for its frames to reach the screen
        // (D3DMetal counts them there), so a pair that took longer to show than the game took to make held
        // the game to the pair's pace, which was then measured as the game's — and the gaps were made from
        // it again. On 13 October it stuck at exactly 40 and 20 fps of its own (three and six steps a gap)
        // where it could make 55, and Smooth Motion took that for its own cost and stopped for the session.
        // In Anvil's stand-in waiting for its frames the same way: 24.0 fps of its own for a whole minute,
        // through a heavy stretch and a light one it made 50 fps in.
        //
        // With two or three made (0.51), the same: the first made frame as soon as it's ready, each one after it
        // and the real one the game's frame over how many are shown apart — all of those after the first never
        // more than the game's frame less a refresh.
        const double refresh = g_refreshPeriod > 0.0 ? g_refreshPeriod : 1.0 / 60.0;
        const double step = g_vrrState == 0 ? refresh : 0.5 * refresh;
        double steps = std::max(1.0, std::round(half / step));
        const int after = std::max(1, perFrame - 1);    // gaps after the first made frame
        while (steps > 1.0 && after * steps * step > g_midInterval - refresh + 0.0005) steps -= 1.0;
        const double realGap = std::max(refresh, steps * step) - 0.001;
        const double madeGap = refresh - 0.001;

        // Retained here, answered when the first of its frames is on screen (g_midEarly) or the real one.
        AnvilProxyDrawable* standIn = (proxy && !real) ? [proxy retain] : nil;
        auto answer = [](AnvilProxyDrawable* s, CFTimeInterval presented) { midAnswerStandIn(s, presented); };

        // Three or four a frame: on the display link's timetable (see "Smooth Motion's display link") — the made
        // ones the game's frame over how many are shown apart from as soon as it was done, then the real one.
        if (g_dlActive.load() && proxy && !real && g_dlQueue) {
            const double spacing = g_midInterval / perFrame;
            // From the first refresh the link can show a frame at once it's done — two of its refreshes on (its
            // preferred latency) — not from when it was done: due then, three of four were due at once.
            const double base = std::max(finished + 2.0 * g_dlTick, g_dlLastDue + 0.5 * spacing);
            std::vector<MidEntry> entries;
            if (g_midInserting && made >= 0)
                for (int j = 0; j < count; ++j) entries.push_back({g_midFrames[midMadeSet(made)][j], base + j * spacing, false, nil});
            if (shown >= 0 && g_midShown[shown]) entries.push_back({g_midShown[shown], base + entries.size() * spacing, true, nil});
            std::vector<MidEntry> dropped;
            if (!entries.empty()) {
                // The game told its frame is on screen with the first of them (g_midEarly), else with the real one.
                (g_midEarly == 1 ? entries.front() : entries.back()).standIn = standIn;
                g_dlLastDue = entries.back().due;
                os_unfair_lock_lock(&g_dlLock);
                for (MidEntry& e : entries) g_dlQueue->push_back(e);
                // More than three game frames' worth waiting: the screen far behind, the oldest let go.
                while (g_dlQueue->size() > (size_t)(3 * perFrame)) { dropped.push_back(g_dlQueue->front()); g_dlQueue->pop_front(); }
                os_unfair_lock_unlock(&g_dlLock);
            } else {
                midAnswerStandIn(standIn, 0.0);
            }
            for (MidEntry& e : dropped) {
                if (e.real) g_notShown.fetch_add(1, std::memory_order_relaxed);
                else g_midBehind.fetch_add(1, std::memory_order_relaxed);
                midAnswerStandIn(e.standIn, 0.0);
            }
            if (debug)
                diag("[anvil] mid: link — %zu queued from %.1f ms on, %.1f ms apart (interval %.1f), backlog %d",
                     entries.size(), (base - CACurrentMediaTime()) * 1000.0, spacing * 1000.0, g_midInterval * 1000.0, g_midBacklog.load());
            g_midLastRealAt = CACurrentMediaTime();
            [real release];
            [proxy release];
            g_midShownAt.store(CACurrentMediaTime());
            g_midBacklog.fetch_sub(1, std::memory_order_acq_rel);
            return;
        }

        // The made frame first, in the drawable that's free now: the real one before it may still be on
        // its way to the screen, and the made frame is due as soon as that has had its refresh. Left out
        // when two of the presenter's frames are still on their way: the screen is behind, and showing it
        // would put every frame after it later still.
        bool madeShown = false;
        bool answered = false;
        if (g_midEarly >= 2 && standIn) { answer(standIn, handled); answered = true; standIn = nil; }
        // Behind, for one made frame: two of the presenter's frames still on their way to the screen. With two or
        // three made, frames are always queued — that's how four a frame are shown — and that rule left out 393
        // of 1,400 in Anvil's stand-in at 18 fps (14 October); so did the game's next frame waiting for the
        // presenter (706: it arrives while this one's four are still going out). There it's behind when this
        // frame's own time is up — as long since its GPU work ended as the game takes for a frame — and the rest
        // of its made frames are left out so the next one starts on time.
        auto behind = [&] { return perFrame > 2 ? CACurrentMediaTime() - finished > 0.9 * g_midInterval : g_midOnWay.load() >= 2; };
        // Two or three made: each at its own time on the clock, the game's frame over how many are shown apart, the
        // first kMidLead after the game's frame was done and never sooner than a refresh after the last one asked
        // for — so a frame is never asked for before one already waiting (see kMidLead). A made frame whose time
        // is already too close to make is left out.
        const bool scheduled = perFrame > 2;
        const double spacing = g_midInterval / perFrame;
        const double base = std::max(finished + kMidLead, g_midLastTarget + 0.98 * refresh);
        auto due = [&](int k) { return base + k * spacing; };
        for (int j = 0; j < count; ++j) {
        id<MTLTexture> between = made >= 0 ? g_midFrames[midMadeSet(made)][j] : nil;
        // The first one shown as soon as it's ready; any after it the game's frame over how many are shown apart.
        const double thisGap = madeShown ? realGap : madeGap;
        if (between && proxy && !real && g_midInserting && g_midLastRealAt > 0.0) {
            const bool late = scheduled ? CACurrentMediaTime() + 0.020 > due(j) : behind();
            id<CAMetalDrawable> extra = late ? nil : midDrawable();
            if (extra && midCopyIn(between, extra)) {
                const double asked = CACurrentMediaTime();
                AnvilProxyDrawable* early = (g_midEarly == 1 && standIn && !answered) ? standIn : nil;
                g_pendingPresents.fetch_add(1, std::memory_order_release);
                g_midOnWay.fetch_add(1, std::memory_order_acq_rel);
                @try {
                    [extra addPresentedHandler:^(id<MTLDrawable> shownNow) {
                        g_pendingPresents.fetch_sub(1, std::memory_order_release);
                        g_midOnWay.fetch_sub(1, std::memory_order_acq_rel);
                        noteShown(true, shownNow.presentedTime);
                        if (debug && shownNow.presentedTime > 0)
                            diag("[anvil] mid: made frame shown %.1f ms after", (shownNow.presentedTime - asked) * 1000.0);
                        if (early) answer(early, shownNow.presentedTime);
                    }];
                    answered = answered || early != nil;
                } @catch (NSException*) {
                    g_pendingPresents.fetch_sub(1, std::memory_order_release);
                    g_midOnWay.fetch_sub(1, std::memory_order_acq_rel);
                }
                if (scheduled) { [extra presentAtTime:due(j)]; g_midLastTarget = due(j); }
                else [extra presentAfterMinimumDuration:thisGap];
                madeShown = true;
                g_midMade.fetch_add(1, std::memory_order_relaxed);
                ++g_generated;
            } else {
                if (late) g_midBehind.fetch_add(1, std::memory_order_relaxed);
                else g_skippedPool.fetch_add(1, std::memory_order_relaxed);
                g_skippedGenerations.fetch_add(1, std::memory_order_relaxed);
            }
        }
        }

        // The real frame: the stand-in's own drawable, or one taken now — once the frame shown before
        // the made one is replaced — and the picture copied in.
        id<MTLTexture> picture = (proxy && shown >= 0) ? g_midShown[shown] : nil;
        id<CAMetalDrawable> target = real ? real : (picture ? midDrawable() : nil);
        if (picture && target && !midCopyIn(picture, target)) target = nil;
        const double now = CACurrentMediaTime();
        // After the made one by half the game's frame. Without a made frame: as it's ready, no sooner
        // than a refresh after the last.
        const double gap = madeShown ? realGap : 0.95 * refresh;
        if (target) {
            // From the game asking for somewhere to draw to this frame on screen.
            if (proxy && !real) recordLatency(target, proxy->_requestedAt);
            g_pendingPresents.fetch_add(1, std::memory_order_release);
            g_midOnWay.fetch_add(1, std::memory_order_acq_rel);
            AnvilProxyDrawable* late = answered ? nil : standIn;
            const double asked = now;
            @try {
                [target addPresentedHandler:^(id<MTLDrawable> shownNow) {
                    g_pendingPresents.fetch_sub(1, std::memory_order_release);
                    g_midOnWay.fetch_sub(1, std::memory_order_acq_rel);
                    if (shownNow.presentedTime <= 0) g_notShown.fetch_add(1, std::memory_order_relaxed);
                    noteShown(false, shownNow.presentedTime);
                    if (debug && shownNow.presentedTime > 0)
                        diag("[anvil] mid: real frame shown %.1f ms after", (shownNow.presentedTime - asked) * 1000.0);
                    // What the game asked of its stand-in, answered for the frame as shown.
                    if (late) answer(late, shownNow.presentedTime);
                }];
                answered = true;
            } @catch (NSException*) {
                g_pendingPresents.fetch_sub(1, std::memory_order_release);
                g_midOnWay.fetch_sub(1, std::memory_order_acq_rel);
            }
            // At four a frame, at its own time after the made ones — or, the presenter late, as soon as it can be.
            const double at = std::max(due(count), CACurrentMediaTime() + 0.022);
            if (real) {
                // A stand-in made before frames went through the presenter: drawn by the GPU in the game's
                // command buffer, done by now.
                id<MTLCommandBuffer> cb = [g_midQueue commandBuffer];
                TimedPresent timed;
                if (scheduled) [cb presentDrawable:target atTime:at];
                else [cb presentDrawable:target afterMinimumDuration:gap];
                [cb commit];
            } else if (scheduled) {
                [target presentAtTime:at];
            } else {
                [target presentAfterMinimumDuration:gap];
            }
            g_midLastTarget = scheduled ? at : 0.0;
            g_midLastRealAt = now;
        }
        // Not shown at all: the game is told so, rather than waiting on it.
        if (!answered && standIn) answer(standIn, 0.0);
        if (debug)
            diag("[anvil] mid: done %.1f ms ago (began %.1f), interval %.1f, %s, real %.1f ms after it, on the way %d, backlog %d",
                 (now - finished) * 1000.0, (began - finished) * 1000.0, g_midInterval * 1000.0,
                 madeShown ? "made" : (made >= 0 ? "made, not shown" : "none made"), (gap + 0.001) * 1000.0,
                 g_midOnWay.load(), g_midBacklog.load());
        [real release];
        [proxy release];
        g_midShownAt.store(now);
        g_midBacklog.fetch_sub(1, std::memory_order_acq_rel);
    }
}

/// Frames through the presenter from the game's next. False when its queues couldn't be made.
bool midStart(double now, double ownFPS) {
#ifdef ANVIL_INJECT_TEST
    if (g_midAvailableForTest >= 0 && !g_device) {
        g_midEngagedAt = now; g_midRateBefore = ownFPS; g_midGpuBefore = g_gpuBusy.load(); g_midStarvedSeconds = 0.0;
        g_midRate.store(0.0); g_midInsert.store(false); g_mid.store(true);
        return true;
    }
#endif
    if (!midEnsureQueue()) return false;
    g_midEngagedAt = now;
    g_midRateBefore = ownFPS;
    g_midGpuBefore = g_gpuBusy.load();
    g_midStarvedSeconds = 0.0;
    g_midRate.store(0.0);
    g_midInsert.store(false);
    g_midMult.store(2);
    // The check starts over: no verdict carried from another scene. (The GPU has none of it in flight: frames
    // between were off.)
    if (g_midCheckState) {
        auto* st = (MidCheckState*)g_midCheckState.contents;
        st->looked = st->apart = 0; st->score = 0.0f; st->hold = 0;
    }
    // Before any frame of this start reaches the presenter: its queue runs in order.
    dispatch_async(g_midDispatch, ^{
        g_midLastDone = g_midInterval = g_midLastRealAt = 0.0;
        g_midInserting = false;
    });
    g_mid.store(true);
    return true;
}

/// Frames shown from the game's command buffer again from its next. Whatever the presenter still
/// holds is shown first (the wait in hookedNextDrawable).
void midStop() {
    if (!g_mid.exchange(false)) return;
    g_midInsert.store(false);
    if (g_midDispatch) dispatch_async(g_midDispatch, ^{ g_midInserting = false; midLinkStop(); });
}

/// Generated frames off, saying nothing: the game's own from the next frame, Steady judging it afresh.
void genHalt(double now) {
    // Stopped again soon after it started: the next start waits longer — not for frames between,
    // which start and stop without a change the eye catches (a heavy scene and a light one either
    // side of a turn of the camera, every few seconds in LEGO Star Wars).
    const bool quick = g_genStartedAt >= 0.0 && now - g_genStartedAt < kGenRestartWithin && !g_mid.load();
    g_genEngageBackoff = quick ? std::min(std::max(g_genEngageBackoff * 2.0, 10.0), kGenEngageBackoffMax) : 0.0;
    midStop();
    g_generating = false;
    g_halfRate = false;
    g_fill = false;
    g_fillOutSeconds = 0.0;
    g_realSlotPeriod = g_fullSlotPeriod;
    g_haveHistory = false;
    g_frameCounter = 0;
    g_belowSeconds = g_recoverSeconds = g_upSeconds = g_downSeconds = g_genShortSeconds = 0.0;
    g_genStartedAt = -1.0;
    g_guardChangedAt = now;
    if (g_steady != Steady::off) { g_steadySince = now; g_cadence = 0.0; g_overSince = -1.0; }
}

/// Generated frames off, and why, in the log.
void genStop(double now, const char* line, double ownFPS) {
    genHalt(now);
    diag(line, ownFPS);
}

/// Smooth Motion on from the game's next frame: frames between where they can be made (`between`), else
/// 0.47's frames made ahead.
void fillEngage(double now, double ownFPS, bool between) {
    const double targetHz = g_refreshPeriod > 0.0 ? 1.0 / g_refreshPeriod : 60.0;
    g_halfRate = false;
    g_fill = true;
    g_fillOutSeconds = 0.0;
    g_realSlotPeriod = g_fullSlotPeriod;
    if (between && midStart(now, ownFPS))
        diag("[anvil] Smooth Motion: the game makes %.1f fps of its own here — a frame made between each two of its own, "
             "from both: about %.0f on the screen, each of its frames half a frame later than shown as ready",
             ownFPS, std::min(2.0 * ownFPS, targetHz));
    else
        diag("[anvil] Smooth Motion: the game makes %.1f fps of its own here — each of its frames shown as it's ready, and one "
             "made from them shown halfway between each two: about %.0f on the screen", ownFPS, 2.0 * ownFPS);
    g_belowSeconds = 0.0;
    g_recoverSeconds = g_upSeconds = g_downSeconds = g_genShortSeconds = 0.0;
    g_genStartedAt = now;
    g_generating = true;
    g_guardChangedAt = now;
    guardNoteTime(g_guardStarts, g_guardStartsN, now);
}

/// Whether Smooth Motion would make frames between at `ownFPS` of the game's own now, were FSR 3's pictures there
/// (midAvailable aside): chosen, the game in front, on a display they're made for, in their band, and not held off
/// here by Guardian — genDecide's own tests.
bool midWouldEngage(double now, double ownFPS) {
#ifdef ANVIL_INJECT_TEST
    const bool made = g_midAvailableForTest >= 0 ? g_midAvailableForTest == 1 : g_midpoint != nil;
#else
    const bool made = g_midpoint != nil;
#endif
    if (!(g_smoothMotion && g_genForce && g_midWanted && made) || g_refreshPeriod <= 0.0 || !anvil_game_in_front()) return false;
    const bool vrrPanel = g_vrrState == 1 || g_vrrReported;
    const bool fillAllowed = vrrPanel && g_vrrState != 0 && g_vrrState != 2;
    const bool fixedBetween = g_vrrState == 0;
    const bool inBand = ownFPS >= kMidLowFPS && ownFPS < kMidEngageHigh / g_refreshPeriod;
    const bool held = g_guardProbe == 1 || now < g_midPausedUntil || (g_guardian && !anvil_guardian::betweenWanted(ownFPS));
    return (fillAllowed || fixedBetween) && inBand && !held;
}

/// Each statistics window: whether frames are generated, from the game's own rate over it
/// (`ownFPS`, measured with every hold taken out) and the window's length.
void genDecide(double now, double ownFPS, double windowSec) {
    if (!(g_frameGenRequested && g_adaptive && g_refreshPeriod > 0.0)) return;
    const double targetHz = 1.0 / g_refreshPeriod;
    // Halving only from a full-rate target; a user's own cap is left alone.
    const bool canHalve = g_fullSlotPeriod < g_refreshPeriod * 1.5;
    // On a variable-refresh panel the game's own frames are already shown evenly at whatever
    // rate it manages, so guessed frames are only worth their cost where that stops working:
    // far below the display rate. Asked for by the player, generation fills a variable-refresh
    // panel too, two to one (vrrTwoToOne); otherwise such a panel shows the game's own frames.
    const bool vrrCarries = !g_genForce && g_vrrState != 0 && g_vrrState != 2 && ownFPS >= kVrrFloorFPS;
    // With Steady on, a game that holds its even rate on its own frames is left on them:
    // generated frames are only for what it can't reach. On 5 October LEGO Star Wars made
    // 81.8 fps of its own, was taken for short of 120, and was held to 60 real frames with 60
    // generated between them — the warped edges in its picture — where Steady had it at an
    // even 80 of its own.
    const double ownFloor = (g_steadyWanted || enduranceOn()) ? 0.95 * steadyHoldRate() : 0.0;
    // A display that follows the game, or says it can and may yet be found to.
    const bool vrrPanel = g_vrrState == 1 || g_vrrReported;
    const bool vrrTwoToOne = g_genForce && vrrPanel;
    const double halfLow = kHalfRateFloor * targetHz;
    const double halfHigh = std::min(kHalfRateBelow * targetHz, ownFloor > 0.0 ? ownFloor : 1e9);
    // A long session on such a panel is Steady's even 80, of the game's own frames.
    const bool longSession = enduranceOn() && vrrPanel;

    // Smooth Motion: chosen by the player, in a heavy scene. With FSR 3 to the display, frames between
    // (g_mid): from 15 fps, under half the display's rate, at once — on a panel that follows the game, and
    // since 0.49 on one at a fixed rate too (60 Hz: from 15 to 30 fps of the game's own, shown at up to 60;
    // the presenter's gaps are then whole refreshes). Otherwise, on a panel that follows the game, 0.47's
    // frames made ahead, from 24 fps.
    // Not while another app is in front: the game is held to 30 there, and its frames aren't seen.
    const bool smoothAllowed = g_smoothMotion && g_genForce && anvil_game_in_front();
    const bool fillAllowed = smoothAllowed && vrrPanel && g_vrrState != 0 && g_vrrState != 2;
    const bool fixedBetween = smoothAllowed && g_vrrState == 0;
    const bool canBetween = (fillAllowed || fixedBetween) && midAvailable();
    const bool inMidBand = ownFPS >= kMidLowFPS && ownFPS < kMidEngageHigh * targetHz;
    // Held off here by Guardian — for a check of its worth, where it was found to cost more than it gives at
    // this rate on this Mac, or paused after costing the game its own — and nothing in its place: the game's
    // own frames are what was found better.
    const bool forced = g_guardProbe == 2;
    const bool held = !forced && (g_guardProbe == 1 || now < g_midPausedUntil
                                  || (g_guardian && !anvil_guardian::betweenWanted(ownFPS)));
    g_guardEligible = canBetween && inMidBand && startSettled(now);
    const bool between = canBetween && !held;
    const bool fillBand = between ? (inMidBand || forced)
                                  : (fillAllowed && !canBetween && ownFPS >= kFillLowFPS && ownFPS < kFillHigh * targetHz);
    // Switching often (Guardian's check-up): slower to start and to stop for a while.
    const bool calm = now < g_guardCalmUntil;
    if (!g_generating && fillBand && (startSettled(now) || forced)) {
        g_belowSeconds += windowSec;
        const double need = between ? kMidEngageSeconds * (calm ? 3.0 : 1.0) : kFillEngageSeconds + g_genEngageBackoff;
        if (g_belowSeconds < need && !forced) return;
        fillEngage(now, ownFPS, between);
        return;
    }
    if (g_generating && g_fill) {
        if (g_mid.load()) {
            // The rate the game's frames reach the presenter: its waits for a drawable behind the
            // presenter's aren't time it could have used, so the time it measures for itself reads high.
            const double rate = g_midRate.load() > 0.0 ? g_midRate.load() : ownFPS;
            const bool out = !(fillAllowed || fixedBetween) || !midAvailable() || held
                          || (!forced && (rate >= kMidLeaveHigh * targetHz || rate < kMidLowFPS - 3.0));
            g_fillOutSeconds = out ? g_fillOutSeconds + windowSec : 0.0;
            // Frames between must not cost the game its own: held for its drawable while the GPU sits
            // idle is the game slowed, not helped. 0.48 stopped them for the session then, and on 13 October
            // that was the presenter's own lock (see midPresent): LEGO Star Wars' heaviest place, at 18 fps,
            // then had none. Paused now — a minute, longer each time — and counted against them at the rate
            // they began at, so Guardian leaves them off there if it keeps happening.
            const int gpu = g_gpuBusy.load();
            const bool starved = g_midGpuBefore >= 85 && gpu >= 0 && gpu < g_midGpuBefore - 20
                              && g_midRateBefore > 0.0 && rate < 0.85 * g_midRateBefore;
            g_midStarvedSeconds = starved ? g_midStarvedSeconds + windowSec : 0.0;
            if (g_midStarvedSeconds >= 6.0) {
                if (g_guardian) anvil_guardian::noteCost(g_midRateBefore);
                g_midPauseFor = std::min(std::max(g_midPauseFor * 2.0, 60.0), 600.0);
                g_midPausedUntil = now + g_midPauseFor;
                genHalt(now);
                diag("[anvil] Smooth Motion: frames between cost the game its own here (%.1f fps of its own, %.1f before, the GPU "
                     "idle while it waited) — the game's own frames for %.0f s; Guardian counts it against them at %.0f fps",
                     rate, g_midRateBefore, g_midPauseFor, g_midRateBefore);
                return;
            }
            if (g_fillOutSeconds >= kFillLeaveSeconds * (calm ? 2.0 : 1.0)) {
                genStop(now, !anvil_game_in_front() ? "[anvil] Smooth Motion off while another app is in front (the game at %.1f fps)"
                           : !midAvailable() ? "[anvil] Smooth Motion off for now — FSR 3, whose pictures it makes frames from, is "
                                               "eased to FSR 1 or off (the game at %.1f fps of its own)"
                           : held ? "[anvil] Smooth Motion off here — Guardian found the game's own frames better at %.1f fps on this Mac"
                           : rate >= kMidLowFPS ? "[anvil] Smooth Motion off — the game is at %.1f fps of its own, enough on its own"
                                                : "[anvil] Smooth Motion off — the game is down to %.1f fps of its own, too far apart to make a frame between",
                        rate);
            }
            return;
        }
        // Made ahead, and frames between can be made now — FSR 3 back from FSR 1 (fsr3GovernStep, 0.55): those
        // instead, from the next frame, as when they're first chosen.
        if (between && inMidBand) {
            genHalt(now);
            fillEngage(now, ownFPS, true);
            return;
        }
        // Out of the band — the game back above it, down below what can be guessed, or the panel
        // no longer following — for a few seconds: the game's own frames, shown as ready. Out above it only past
        // kFillLeaveHigh, and below it a little under where it comes in, as frames between leave theirs.
        const bool stays = fillAllowed && !canBetween && ownFPS >= kFillLowFPS - 3.0 && ownFPS < kFillLeaveHigh * targetHz;
        const bool out = !stays;
        g_fillOutSeconds = out ? g_fillOutSeconds + windowSec : 0.0;
        if (g_fillOutSeconds >= kFillLeaveSeconds) {
            genStop(now, ownFPS >= kFillLowFPS ? "[anvil] Smooth Motion off — the game is at %.1f fps of its own, enough on its own"
                                               : "[anvil] Smooth Motion off — the game is down to %.1f fps of its own, too far apart to make a frame between",
                    ownFPS);
        }
        return;
    }

    if (!g_generating) {
        // Not now, whatever the rate: the start, a fresh look at the display, a long session — nor,
        // with Smooth Motion on, on a panel that follows the game: there its frames between are for a
        // heavy scene, and above it the game's own are shown as ready. Held to every second refresh, a
        // game at 70 was shown 60 of its own and 60 guesses (LEGO Star Wars, 13 October): fewer of its
        // own for the sake of the count.
        // Nor where Guardian holds frames between off at this rate: the game's own frames were found better
        // there, so no guessed ones in their place either.
        if (!startSettled(now) || g_vrrState == 2 || longSession || (g_smoothMotion && vrrTwoToOne)
            || (canBetween && inMidBand && held)) {
            g_belowSeconds = 0.0;
            return;
        }
        const bool want = vrrTwoToOne
            ? canHalve && ownFPS >= halfLow && ownFPS < halfHigh
            : ownFPS > 0.0 && ownFPS < targetHz * 0.85 && ownFPS < (ownFloor > 0.0 ? ownFloor : 1e9) && !vrrCarries;
        if (!want) {
            // Said only after a real stretch: decided every two seconds, a rate at the band's edge
            // would otherwise say it every few.
            if (g_belowSeconds >= 6.0)
                diag("[anvil] game at %.1f fps on its own after %.0f s — no generated frames", ownFPS, g_belowSeconds);
            g_belowSeconds = 0.0;
            return;
        }
        g_belowSeconds += windowSec;
        const double need = vrrTwoToOne ? kGenVrrEngageSeconds : g_genForce ? kGenForceEngageSeconds : kGenEngageSeconds;
        if (g_belowSeconds < need + g_genEngageBackoff) return;
        g_halfRate = vrrTwoToOne || (canHalve && ownFPS < targetHz * kHalfRateBelow && ownFPS >= halfLow);
        g_realSlotPeriod = g_halfRate ? 2.0 * g_fullSlotPeriod : g_fullSlotPeriod;
        diag("[anvil] game holds only %.1f fps of %.0f on its own for %.0f s — generating frames to fill the gap (%s)",
             ownFPS, targetHz, g_belowSeconds,
             g_halfRate ? "real frames every second refresh, one generated between each"
                        : "generated frames only in the slots it leaves empty");
        g_belowSeconds = 0.0;
        g_recoverSeconds = g_upSeconds = g_downSeconds = g_genShortSeconds = 0.0;
        g_genStartedAt = now;
        g_generating = true;
        return;
    }

    // Two to one needs the game at every second refresh: short of it for a few seconds, the
    // guesses stretch over twice the motion — LEGO at 23–45 fps on 11 October.
    g_genShortSeconds = (g_halfRate && ownFPS > 0.0 && ownFPS < 0.5 * targetHz) ? g_genShortSeconds + windowSec : 0.0;

    if (vrrPanel && (g_genForce || longSession)) {
        if (longSession) {
            genStop(now, "[anvil] long session: generated frames off — an even 80 of the game's own frames (%.1f fps of its own)", ownFPS);
            return;
        }
        // Started on a display then taken for fixed: on this one, two to one or nothing.
        if (!g_halfRate) {
            if (canHalve && ownFPS >= halfLow && ownFPS < halfHigh) {
                g_halfRate = true;
                g_realSlotPeriod = 2.0 * g_fullSlotPeriod;
                diag("[anvil] game at %.1f fps — real frames every second refresh, one generated between each", ownFPS);
            } else {
                genStop(now, "[anvil] game at %.1f fps on its own, shown as each frame is ready — generated frames off", ownFPS);
            }
            return;
        }
        g_recoverSeconds = ownFPS >= halfHigh ? g_recoverSeconds + windowSec : 0.0;
        if (g_genShortSeconds >= kGenShortSeconds)
            genStop(now, "[anvil] game down to %.1f fps — short of every second refresh, so its own frames shown as each is ready "
                         "rather than guessed frames stretched over the gaps; generated frames off", ownFPS);
        else if (g_recoverSeconds >= kGenAdjustSeconds)
            genStop(now, "[anvil] game can hold %.1f fps on its own again — generated frames off", ownFPS);
        return;
    }

    // A fixed-refresh display. No pauses: every decision here comes from the rate the game
    // could manage, measured while its frames are held.
    g_recoverSeconds = (ownFPS >= targetHz * 0.9 || vrrCarries) ? g_recoverSeconds + windowSec : 0.0;
    g_upSeconds   = (g_halfRate && ownFPS >= targetHz * 0.8) ? g_upSeconds + windowSec : 0.0;
    g_downSeconds = (!g_halfRate && canHalve && ownFPS < targetHz * 0.72
                     && ownFPS >= halfLow && (ownFloor <= 0.0 || ownFPS < ownFloor))
                  ? g_downSeconds + windowSec : 0.0;
    // Chosen by the player, generation stays on for the session there: whether a refresh
    // needs a frame is decided frame by frame (gapToFill), and the rate the game "could" make
    // reads high while its frames wait on generated ones for a drawable — 56 fps read as 156
    // in Anvil's bench — which turned it off and on again every 13 s.
    if (g_genForce) g_recoverSeconds = 0.0;
    if (g_recoverSeconds >= kGenAdjustSeconds) {
        // Its own frames are correct; a synthesised one never is.
        genStop(now, "[anvil] game can hold %.1f fps on its own again — generated frames off", ownFPS);
    } else if (g_upSeconds >= kGenAdjustSeconds || g_genShortSeconds >= kGenShortSeconds) {
        g_halfRate = false;
        g_realSlotPeriod = g_fullSlotPeriod;
        const bool short_ = g_genShortSeconds >= kGenShortSeconds;
        g_upSeconds = g_genShortSeconds = 0.0;
        diag(short_ ? "[anvil] game down to %.1f fps, short of every second refresh — generated frames only in the slots it leaves empty"
                    : "[anvil] game could do %.1f fps — back to its own frames with generated ones only in the gaps", ownFPS);
    } else if (g_downSeconds >= kGenAdjustSeconds) {
        g_halfRate = true;
        g_realSlotPeriod = 2.0 * g_fullSlotPeriod;
        g_downSeconds = 0.0;
        diag("[anvil] game down to %.1f fps — real frames every second refresh, one generated between each", ownFPS);
    }
}

// --- Stutters (Guardian) -------------------------------------------------------------------------------
// A frame three times as long as the game's frames have lately been, and 50 ms or more, while the game is in
// front: what happened in it. On 13 October LEGO Star Wars' worst moments (21 of its 22 gaps of 100 ms or
// more) came as it reached somewhere new, with the shaders it compiled there in the same stretch — and,
// most likely, its data read from disk. Said for each, and counted: reading its data (any thread, during the
// frame), compiling shaders, waiting on the GPU or the display, or the game's own work.
AnvilReadTotals g_stutRead{};
uint64_t g_stutCompileN = 0;
double   g_stutCompileMs = 0.0;
int      g_stutters = 0, g_stutReading = 0, g_stutCompiling = 0, g_stutWaiting = 0, g_stutOwn = 0;
double   g_stutSaidAt = -1e9;
double   g_stutLongestMs = 0.0;

/// What a stutter was mostly: whichever of reading the game's data (with half a megabyte or more read),
/// compiling shaders or waiting on the GPU or the display took 40% of it or more, in that order; else the
/// game's own work. 0 reading, 1 compiling, 2 waiting, 3 the game's own.
int stutterCause(double ms, double readMs, double readMB, double compileMs, double waitMs) {
    if (readMs >= 0.4 * ms && readMB >= 0.5) return 0;
    if (compileMs >= 0.4 * ms) return 1;
    if (waitMs >= 0.4 * ms) return 2;
    return 3;
}

void guardianFrame(double now, double dt, double waited) {
    AnvilReadTotals r;
    AnvilReadTotalsGet(&r);
    uint64_t cn = 0, failed = 0;
    double cms = 0.0, longest = 0.0;
    AnvilCompileTotals(&cn, &cms, &longest, &failed);
    const double readMs = (double)(r.ns - g_stutRead.ns) * 1e-6, readMB = (double)(r.bytes - g_stutRead.bytes) / 1048576.0;
    const double compileMs = cms - g_stutCompileMs;
    const uint64_t compiles = cn - g_stutCompileN;
    g_stutRead = r;
    g_stutCompileN = cn;
    g_stutCompileMs = cms;
    if (!g_guardian || g_presentEma <= 0.0 || g_frames.load(std::memory_order_relaxed) < 600 || !anvil_game_in_front()) return;
    if (!(dt >= 0.05 && dt >= 3.0 * g_presentEma)) return;
    const double ms = dt * 1000.0, waitMs = waited * 1000.0;
    ++g_stutters;
    g_stutLongestMs = std::max(g_stutLongestMs, ms);
    static const char* const kCauses[] = {"reading its data", "compiling shaders", "waiting on the GPU or the display", "the game's own work"};
    const int which = stutterCause(ms, readMs, readMB, compileMs, waitMs);
    int* const counts[] = {&g_stutReading, &g_stutCompiling, &g_stutWaiting, &g_stutOwn};
    ++*counts[which];
    const char* cause = kCauses[which];
    if (now - g_stutSaidAt < 5.0) return;
    g_stutSaidAt = now;
    diag("[anvil] guardian: stutter %.0f ms (frames had been %.1f ms) — mostly %s: %.1f MB of its data read in %.0f ms, "
         "%llu shader%s compiled in %.0f ms, %.0f ms waiting on the GPU or the display",
         ms, g_presentEma * 1000.0, cause, readMB, readMs, (unsigned long long)compiles, compiles == 1 ? "" : "s", compileMs, waitMs);
}

/// Smooth Motion's presenter stalled with the game's frames waiting: the game's own frames again at once, frames
/// between paused half a minute, and the presenter's queue raised to user-interactive priority so what it still
/// holds goes out. On the game's thread (its nextDrawable, or Guardian's check-up).
void midStalled(double now) {
    if (!g_mid.load()) return;
    const double quiet = now - g_midShownAt.load();
    g_midPauseFor = std::max(g_midPauseFor, 30.0);
    g_midPausedUntil = now + 30.0;
    genHalt(now);
    if (g_midDispatch) {
        dispatch_block_t lift = dispatch_block_create_with_qos_class(DISPATCH_BLOCK_ENFORCE_QOS_CLASS, QOS_CLASS_USER_INTERACTIVE, 0, ^{});
        dispatch_async(g_midDispatch, lift);
        Block_release(lift);
    }
    ++g_guardFixes;
    ++g_midStalls;
    diag("[anvil] Smooth Motion: its presenter showed nothing for %.1f s with the game's frames waiting — the game's own "
         "frames from this one, frames between paused for 30 s (%d this session; the presenter raised to full priority %llu "
         "times when behind)", quiet, g_midStalls, (unsigned long long)g_midBoosts.load());
}

/// Guardian's check-up, every ten seconds of play: that frames still reach the screen, and that nothing of
/// Anvil's switches back and forth.
void guardianCheckUp(double now) {
    ++g_guardCheckUps;
    // Smooth Motion's presenter stalled with the game's frames in it: the game's own frames again at once,
    // frames between paused half a minute. The game waits on the presenter for its frames in flight.
    if (g_mid.load() && g_midBacklog.load() > 0 && now - g_midShownAt.load() > 1.0 && now - g_midHandedAt.load() < 0.5) midStalled(now);
    // Smooth Motion started five times or more in two minutes: slower to start and to stop for three.
    if (now >= g_guardCalmUntil && guardCountSince(g_guardStarts, g_guardStartsN, now - 120.0) >= 5) {
        g_guardCalmUntil = now + 180.0;
        ++g_guardFixes;
        diag("[anvil] guardian: Smooth Motion started %d times in two minutes — for the next three it waits three times as "
             "long to start and twice as long to stop, so a scene at the edge of its range doesn't flicker between the two",
             guardCountSince(g_guardStarts, g_guardStartsN, now - 120.0));
    }
    // Steady let go of its even rate six times or more in a minute: as ready for 20 s before it holds again.
    if (g_steady != Steady::off && now - g_guardSteadyCalmAt >= 300.0
        && guardCountSince(g_guardLetGo, g_guardLetGoN, now - 60.0) >= 6) {
        g_guardSteadyCalmAt = now;
        g_holdBackoff = std::max(g_holdBackoff, 20.0);
        g_nextHoldAt = std::max(g_nextHoldAt, now + 20.0);
        ++g_guardFixes;
        diag("[anvil] guardian: Steady let go of an even %d %d times in a minute — the game's frames as ready for 20 s before "
             "it holds again", (int)lround(steadyHoldRate()), guardCountSince(g_guardLetGo, g_guardLetGoN, now - 60.0));
    }
    // The game's frames that never reached the screen, in front: a fifth or more in ten seconds, said once
    // in ten minutes. Nothing of Anvil's to change for it; the Doctor reads it.
    const uint64_t notShown = g_notShown.load(std::memory_order_relaxed), real = g_realFrames.load(std::memory_order_relaxed);
    // Both counters start again with each statistics window: counted from nothing after one has.
    const uint64_t dn = notShown >= g_guardNotShownBase ? notShown - g_guardNotShownBase : notShown;
    const uint64_t dr = real >= g_guardRealBase ? real - g_guardRealBase : real;
    g_guardNotShownBase = notShown;
    g_guardRealBase = real;
    if (anvil_game_in_front() && dr >= 100 && dn * 5 >= dr && now - g_guardNotShownSaidAt >= 600.0) {
        g_guardNotShownSaidAt = now;
        diag("[anvil] guardian: %llu of the game's last %llu frames didn't reach the screen", (unsigned long long)dn,
             (unsigned long long)dr);
    }
    // Where the game read its large data files, kept for the memory warm-up at its next start: a minute at
    // a time, off the game's thread.
    static double heatAt = 0.0;
    if (now - heatAt >= 60.0) {
        heatAt = now;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ AnvilReadHeatSave(); });
    }
    // Every five minutes, what it has done and learned.
    if (now - g_guardSummaryAt >= 300.0) {
        if (g_guardSummaryAt > 0.0) {
            char learned[640];
            anvil_guardian::describe(learned, sizeof learned);
            AnvilReadTotals r;
            AnvilReadTotalsGet(&r);
            diag("[anvil] guardian: %d check-ups, %d fixes, %d checks of Smooth Motion's worth this session | stutters: %d "
                 "(%d reading its data, %d compiling shaders, %d waiting on the GPU or the display, %d the game's own work; "
                 "longest %.0f ms) | the game read %.1f GB of its data, %.1f ms a read on average, %llu reads of 20 ms or more "
                 "| on this Mac: %s",
                 g_guardCheckUps, g_guardFixes, anvil_guardian::checksThisSession(), g_stutters, g_stutReading, g_stutCompiling,
                 g_stutWaiting, g_stutOwn, g_stutLongestMs, (double)r.bytes / 1073741824.0,
                 r.calls ? (double)r.ns * 1e-6 / (double)r.calls : 0.0, (unsigned long long)r.slow, learned);
        }
        g_guardSummaryAt = now;
    }
}

/// Guardian, every decision window (two seconds): its measure of the window, and a check of frames between's
/// worth when one is due (anvil_guardian.h); a check-up every ten seconds.
void guardianStep(double now, double ownFPS, double windowSec) {
    if (!g_guardian) return;
    // The check-up in every game; the checks of Smooth Motion's worth only where it can run.
    if (now - g_guardCheckAt >= 10.0) {
        g_guardCheckAt = now;
        guardianCheckUp(now);
    }
    if (!g_frameGenRequested || g_refreshPeriod <= 0.0) return;
    anvil_guardian::Window w;
    {
        std::lock_guard<std::mutex> lock(g_shownLock);
        w.shown = windowSec > 0.0 ? g_gShownN / windowSec : 0.0;
        if (g_gGapN >= 2.0) {
            w.gapMeanMs = g_gGapSum / g_gGapN;
            w.gapSdMs = std::sqrt(std::max(0.0, g_gGapSq / g_gGapN - w.gapMeanMs * w.gapMeanMs));
        }
        g_gShownN = g_gGapN = g_gGapSum = g_gGapSq = 0.0;
    }
    w.now = now;
    w.seconds = windowSec;
    w.own = ownFPS;
    w.between = g_mid.load();
    w.eligible = g_guardEligible;
    w.calm = now - windowSec > g_guardChangedAt && anvil_game_in_front() && !macHot();
    const int probe = g_guardProbe;
    switch (anvil_guardian::step(w)) {
    case anvil_guardian::Action::probeOff:
        g_guardProbe = 1;
        genHalt(now);
        diag("[anvil] guardian: checking Smooth Motion's worth here — 4 s of the game's own frames alone (%.1f fps of its own "
             "with frames between)", ownFPS);
        break;
    case anvil_guardian::Action::probeOn:
        g_guardProbe = 2;
        diag("[anvil] guardian: looking again at frames between here — 4 s with them (%.1f fps of the game's own without)", ownFPS);
        if (!g_generating && midAvailable()) fillEngage(now, ownFPS, true);
        break;
    case anvil_guardian::Action::endProbe: {
        g_guardProbe = 0;
        anvil_guardian::Result r;
        if (anvil_guardian::lastResult(&r))
            diag("[anvil] guardian: at %.0f–%.0f fps of the game's own, frames between were %+.0f%% against its own frames alone "
                 "(%d check%s here, %+.0f%% on average) — %s here on this Mac", r.lo, r.hi, r.change * 100.0, r.n,
                 r.n == 1 ? "" : "s", r.mean * 100.0, r.wanted ? "frames between" : "the game's own frames");
        anvil_guardian::save();
        // Back as found better: frames between started again at once where they're wanted, stopped where not.
        if (probe == 1 && g_guardEligible && anvil_guardian::betweenWanted(ownFPS) && !g_generating && midAvailable())
            fillEngage(now, ownFPS, true);
        else if (probe == 2 && g_mid.load() && !anvil_guardian::betweenWanted(ownFPS))
            genStop(now, "[anvil] Smooth Motion off here — Guardian found the game's own frames better at %.1f fps on this Mac",
                    ownFPS);
        break;
    }
    case anvil_guardian::Action::abortProbe:
        g_guardProbe = 0;
        diag("[anvil] guardian: check left unfinished — the scene changed under it (%.1f fps of the game's own now)", ownFPS);
        if (probe == 1 && g_guardEligible && anvil_guardian::betweenWanted(ownFPS) && !g_generating && midAvailable())
            fillEngage(now, ownFPS, true);
        else if (probe == 2 && g_mid.load() && !anvil_guardian::betweenWanted(ownFPS))
            genHalt(now);
        break;
    default:
        break;
    }
}

void sleepUntil(double target) {
    for (int i = 0; i < 64; ++i) {
        const double left = target - CACurrentMediaTime();
        if (left <= 0.0002) return;
        const double nap = left > 0.0015 ? left - 0.001 : 0.0002;
        struct timespec ts{0, static_cast<long>(nap * 1e9)};
        nanosleep(&ts, nullptr);
    }
}

/// GPU and thread load, read on a background queue so the render thread never waits
/// on the kernel for it.
void sampleLoadAsync() {
    static std::atomic<bool> busy{false};
    if (busy.exchange(true)) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        g_gpuBusy.store(readGpuUtilisation());

        // Threads: CPU time each spent since the last reading, as a share of one core.
        static std::mutex lock;
        static std::vector<std::pair<uint64_t, double>> previous;   // thread id, seconds used
        static double previousAt = 0.0;
        std::lock_guard<std::mutex> hold(lock);
        thread_act_array_t threads = nullptr;
        mach_msg_type_number_t count = 0;
        if (task_threads(mach_task_self(), &threads, &count) == KERN_SUCCESS) {
            const double at = CACurrentMediaTime();
            std::vector<std::pair<uint64_t, double>> now;
            now.reserve(count);
            for (mach_msg_type_number_t i = 0; i < count; ++i) {
                thread_basic_info_data_t basic;
                mach_msg_type_number_t n = THREAD_BASIC_INFO_COUNT;
                thread_identifier_info_data_t ident;
                mach_msg_type_number_t in = THREAD_IDENTIFIER_INFO_COUNT;
                if (thread_info(threads[i], THREAD_BASIC_INFO, (thread_info_t)&basic, &n) == KERN_SUCCESS
                    && thread_info(threads[i], THREAD_IDENTIFIER_INFO, (thread_info_t)&ident, &in) == KERN_SUCCESS) {
                    const double used = basic.user_time.seconds + basic.user_time.microseconds * 1e-6
                                      + basic.system_time.seconds + basic.system_time.microseconds * 1e-6;
                    now.emplace_back(ident.thread_id, used);
                }
                mach_port_deallocate(mach_task_self(), threads[i]);
            }
            vm_deallocate(mach_task_self(), (vm_address_t)threads, count * sizeof(thread_act_t));
            if (previousAt > 0.0 && at - previousAt > 0.5) {
                double top = 0.0, next = 0.0;
                for (const auto& t : now) {
                    for (const auto& p : previous) {
                        if (p.first != t.first) continue;
                        const double share = (t.second - p.second) / (at - previousAt);
                        if (share > top) { next = top; top = share; }
                        else if (share > next) next = share;
                        break;
                    }
                }
                g_topThreadBusy.store(static_cast<int>(top * 100.0 + 0.5));
                g_nextThreadBusy.store(static_cast<int>(next * 100.0 + 0.5));
            }
            previous.swap(now);
            previousAt = at;
        }
        busy.store(false);
    });
}

// ---- Latency at a low frame rate: the game's next frame started just in time ----------------
//
// GPU-bound, a game hands over its frame and starts the next at once — the next then waits on the GPU behind
// the one before, and what the player does reaches the screen two of the game's frames later: in Anvil's
// stand-in at 19 fps (16 October), 102–109 ms from a frame's start to the screen; allowing Anvil's presenter one
// frame on its way instead of two changed nothing (110–112 ms). So, as the game's frame is handed over (its
// command buffer committed), its thread is held until the GPU is about to finish that frame, less a quarter of
// the GPU's time a frame for the game to have its next on the GPU, and the next frame is made from what the
// player does then.
//
// The GPU's time a frame is measured from its own clock: the time covered by the game's command buffers, start
// to end, in the frame — gaps where the GPU waited for one don't count, and overlaps count once. (Taken from
// frames finishing apart, a hold that made the GPU wait made frames look longer, the next hold longer, and the
// stand-in fell from 19.6 to 11.6 fps; learning the game's lead from the GPU's waits, the lead grew to nine
// tenths of the frame and gained nothing.) Measured on the stand-in at 18–19 fps: frame start to the screen
// 102–107 ms down to 76–90 ms without Smooth Motion, 105–109 down to 94–96 with it — and 7–12% of the game's own
// frames lost, whatever the lead (a quarter, 0.4 and 0.55 of a frame all cost about the same). A trade, so a
// choice: off unless asked for (Upscaling › Lower latency at low frame rates, ANVIL_JIT=1); only where the GPU
// sets the pace (busy 85% or more of the time between frames) below 55 fps. ANVIL_JIT_LEAD: the lead, as a
// share of the GPU's frame (tests).
std::atomic<uint64_t> g_jitSeq{0}, g_jitDoneSeq{0};   // the game's frames handed over, and finished on the GPU
std::atomic<double> g_jitDoneAt{0.0};                 // when the last finished
std::atomic<double> g_jitGpu{0.0};                    // the GPU's own time a frame, averaged
std::atomic<double> g_jitBusy{0.0};                   // that, of the time between frames finishing, averaged
std::atomic<double> g_jitIdleLast{0.0};               // the GPU's waits for the game's work, in the last frame
std::atomic<double> g_jitStartGap{-1.0};              // the GPU's wait for the first work after the last hold (-1: none yet)
std::atomic<bool> g_jitAwaitFirst{false};             // a hold just ended: the next command buffer committed is the frame's first
os_unfair_lock g_jitLock = OS_UNFAIR_LOCK_INIT;
double g_jitWork = 0.0, g_jitIdle = 0.0, g_jitLastEnd = 0.0;   // the frame being finished, under the lock
double g_jitLead = 0.0;                               // what the game is given to have its next frame on the GPU
bool g_jitActive = false, g_jitSaid = false, g_jitHeldLast = false;
std::atomic<uint64_t> g_jitFrames{0}, g_jitHeld{0}, g_jitHeldUs{0}, g_jitLate{0};
thread_local void* t_jitCB = nullptr;
thread_local uint64_t t_jitSeqThis = 0;

/// The game's frame handed over in `cb` (not yet committed): marked, for its commit.
void jitHandedOver(id<MTLCommandBuffer> cb) {
    if (!g_jitOn || !cb || cb.status != MTLCommandBufferStatusNotEnqueued) return;
    t_jitCB = (__bridge void*)cb;
    t_jitSeqThis = g_jitSeq.fetch_add(1, std::memory_order_relaxed) + 1;
}

/// A command buffer of the game's, about to be committed: its GPU time counted; the frame's last closes it.
void jitWatch(id<MTLCommandBuffer> cb, bool last, uint64_t seq) {
    const bool first = g_jitAwaitFirst.exchange(false, std::memory_order_relaxed);
    [cb addCompletedHandler:^(id<MTLCommandBuffer> b) {
        const double from = b.GPUStartTime, to = b.GPUEndTime;
        os_unfair_lock_lock(&g_jitLock);
        // The first work after a hold: how long the GPU had nothing of the game's to do before it — the hold's doing.
        if (first && from > 0.0 && g_jitLastEnd > 0.0) g_jitStartGap.store(std::max(0.0, from - g_jitLastEnd), std::memory_order_relaxed);
        if (to > from && from > 0.0) {
            // The time the GPU was at the game's work at all: command buffers' spans overlap (in Anvil's stand-in
            // added up to 80–88 ms for frames 55 ms apart), so only what's beyond the last one's end counts.
            g_jitWork += std::max(0.0, to - std::max(from, g_jitLastEnd));
            const double gap = from - g_jitLastEnd;
            if (g_jitLastEnd > 0.0 && gap > 0.0005 && gap < 0.5) g_jitIdle += gap;
            g_jitLastEnd = std::max(g_jitLastEnd, to);
        }
        if (last) {
            const double work = g_jitWork, idle = g_jitIdle;
            g_jitWork = 0.0; g_jitIdle = 0.0;
            os_unfair_lock_unlock(&g_jitLock);
            const double at = CACurrentMediaTime();
            const double before = g_jitDoneAt.exchange(at, std::memory_order_acq_rel);
            const uint64_t prev = g_jitDoneSeq.exchange(seq, std::memory_order_acq_rel);
            g_jitIdleLast.store(idle, std::memory_order_relaxed);
            if (work > 0.001 && work < 0.5) {
                const double g = g_jitGpu.load(std::memory_order_relaxed);
                g_jitGpu.store(g <= 0.0 ? work : 0.8 * g + 0.2 * work, std::memory_order_relaxed);
                if (prev + 1 == seq && before > 0.0 && at > before) {
                    const double share = std::min(1.0, work / (at - before));
                    const double b0 = g_jitBusy.load(std::memory_order_relaxed);
                    g_jitBusy.store(b0 <= 0.0 ? share : 0.9 * b0 + 0.1 * share, std::memory_order_relaxed);
                }
            }
            return;
        }
        os_unfair_lock_unlock(&g_jitLock);
    }];
}

/// Frame `seq` committed: the game's thread held until its next frame should start (above).
void jitHold(uint64_t seq) {
    const double now = CACurrentMediaTime();
    g_jitFrames.fetch_add(1, std::memory_order_relaxed);
    const double G = g_jitGpu.load(std::memory_order_relaxed), busy = g_jitBusy.load(std::memory_order_relaxed);
    const bool want = G >= 1.0 / 55.0 && G <= 0.25 && busy >= 0.85 && g_steady != Steady::hold;
    static const bool debug = getenv("ANVIL_JIT_DEBUG") != nullptr;
    if (!want) {
        if (debug && seq % 50 == 0) diag("[anvil] jit: frame %llu — GPU %.1f ms a frame, busy %.0f%%: not held",
                                         (unsigned long long)seq, G * 1000.0, busy * 100.0);
        g_jitActive = false; g_jitHeldLast = false;
        return;
    }
    static const double share = std::clamp(getenv("ANVIL_JIT_LEAD") ? atof(getenv("ANVIL_JIT_LEAD")) : 0.25, 0.05, 0.95);
    g_jitLead = share * G;
    if (!g_jitActive) {
        g_jitActive = true;
        if (!g_jitSaid) {
            g_jitSaid = true;
            diag("[anvil] low frame rate (%.0f fps of the GPU's, %.1f ms a frame, busy %.0f%% of the time): each of the "
                 "game's frames started just in time — held after handing one over until the GPU is about to finish it, so "
                 "the next is made from what the player does then, about one frame from the screen rather than two",
                 1.0 / G, G * 1000.0, busy * 100.0);
        }
    } else if (g_jitHeldLast) {
        // Whether the GPU waited for the first work after the last hold — said in the stats line.
        const double gap = g_jitStartGap.exchange(-1.0, std::memory_order_relaxed);
        if (gap > 0.001) g_jitLate.fetch_add(1, std::memory_order_relaxed);
    }
    g_jitHeldLast = false;
    // When this frame will be done: the last finished, and the GPU's time for each of those still to go.
    const uint64_t done = g_jitDoneSeq.load(std::memory_order_acquire);
    if (done >= seq || seq - done > 3) return;
    const double target = g_jitDoneAt.load(std::memory_order_acquire) + (double)(seq - done) * G - g_jitLead;
    if (target > now) sleepUntil(std::min(target, now + 2.0 * G));
    const double held = CACurrentMediaTime() - now;
    if (held > 0.0005) {
        g_jitHeld.fetch_add(1, std::memory_order_relaxed);
        g_jitHeldUs.fetch_add((uint64_t)(held * 1e6), std::memory_order_relaxed);
        g_jitHeldLast = true;
        g_jitAwaitFirst.store(true, std::memory_order_relaxed);
    }
    if (debug && seq % 50 == 0)
        diag("[anvil] jit: frame %llu held %.1f ms; GPU %.1f ms a frame, busy %.0f%%, lead %.1f ms, idle in the frame %.1f ms; %llu still to go",
             (unsigned long long)seq, held * 1000.0, G * 1000.0, busy * 100.0, g_jitLead * 1000.0,
             g_jitIdleLast.load() * 1000.0, (unsigned long long)(seq - done));
}

// ---- Swizzles ---------------------------------------------------------------

IMP g_originalPresent = nullptr;
IMP g_originalCommit = nullptr;
std::atomic<bool> g_presentHooked{false};

/// A command buffer committed: the game's, its GPU time counted (jitWatch); its frame's last, handed over — held
/// for its next (jitHold).
void hookedCommit(id self, SEL _cmd) {
    const bool frameEnd = t_jitCB && (__bridge void*)self == t_jitCB;
    if (g_jitOn && g_gameQueue && [(id<MTLCommandBuffer>)self commandQueue] == g_gameQueue
        && [(id<MTLCommandBuffer>)self status] == MTLCommandBufferStatusNotEnqueued)
        jitWatch((id<MTLCommandBuffer>)self, frameEnd, frameEnd ? t_jitSeqThis : 0);
    ((void (*)(id, SEL))g_originalCommit)(self, _cmd);
    if (frameEnd) {
        t_jitCB = nullptr;
        jitHold(t_jitSeqThis);
    }
}

void hookedPresentDrawable(id self, SEL _cmd, id drawable) {
    if (t_inTimedPresent) {
        ((void (*)(id, SEL, id))g_originalPresent)(self, _cmd, drawable);
        return;
    }
    // The game's frame ends here, with Anvil's passes after it: where the GPU's frames are
    // counted for timing (anvil_gpuwork.mm), however this present returns.
    struct FrameEnd { ~FrameEnd() { AnvilGpuFrameEnd(); } } frameEnd;
    if (self) noteGameQueue((id<MTLCommandBuffer>)self);
    if (self) jitHandedOver((id<MTLCommandBuffer>)self);
    // The stand-in D3DMetal drew into: FSR from it into the real drawable, in the game's own
    // command buffer, and from here on the real drawable is the frame.
    bool upscaled = false;
    bool handedOff = false;              // Smooth Motion's presenter shows this frame (see g_mid)
    id<MTLTexture> gameFrame = nil;      // the frame at the game's size, for frame generation
    if (drawable && g_proxyClass && object_getClass(drawable) == g_proxyClass
        && !((AnvilProxyDrawable*)drawable)->_real) {
        // Smooth Motion between frames: a stand-in with no drawable behind it. FSR into Anvil's
        // picture of the frame, the frame between made after it, and both to the presenter (g_mid).
        AnvilProxyDrawable* proxy = (AnvilProxyDrawable*)drawable;
        id<MTLCommandBuffer> cb = (id<MTLCommandBuffer>)self;
        upscaled = midPresentStandIn(cb, proxy);
        if (upscaled) anvil_screens_offer(cb, proxy->_input);
        handedOff = true;                // shown by the presenter — or, not encodable, not at all
        drawable = nil;
    } else if (drawable && g_proxyClass && object_getClass(drawable) == g_proxyClass) {
        AnvilProxyDrawable* proxy = (AnvilProxyDrawable*)drawable;
        id<MTLCommandBuffer> cb = (id<MTLCommandBuffer>)self;
        // The first frame's look at the drawable — and the reports that start with it — as
        // on the path without FSR. A drawable Anvil can't write to can't be upscaled into.
        inspectDrawable(proxy->_real.texture);
        if (!g_canWrite && !g_viewWrite) {
            outputAbandon(g_outLayer, "the display's drawable can't be written to");
            // This frame as the game drew it, at its own size, can't go to a drawable twice its
            // size: it is dropped, and the next one is a drawable of the game's size again.
            return;
        }
        @try {
            if (cb.status == MTLCommandBufferStatusNotEnqueued) {
                upscaled = fsr3Encode(cb, proxy->_input, proxy->_real.texture);
                if (!upscaled) upscaled = outputEncode(cb, proxy->_input, proxy->_real.texture);
                // FSR 3 stopped at the display's own size: this frame through FSR 1 at 1:1 (as
                // good as the frame itself), and the layer back to the game from the next.
                if (g_fsr3Failed.load() && CGSizeEqualToSize(g_gameSize, g_outSize))
                    outputAbandon(g_outLayer, "FSR 3 stopped, and the game draws at the display's own size");
            }
        } @catch (NSException* e) {
            if (g_fsr3Wanted && !g_fsr3Failed.load()) fsr3Stop("Metal refused a pass at present");
            diag("[anvil] FSR to the display: %s — %s", e.name.UTF8String, e.reason.UTF8String);
            upscaled = false;
        }
        if (!upscaled) {
            // Not encodable here: the same pass in a command buffer of its own, on the
            // game's queue so it follows the frame, presented as it is.
            id<MTLCommandBuffer> own = [cb.commandQueue commandBuffer];
            if (own && (fsr3Encode(own, proxy->_input, proxy->_real.texture)
                        || outputEncode(own, proxy->_input, proxy->_real.texture))) {
                TimedPresent timed;
                [own presentDrawable:proxy->_real];
                [own commit];
            } else {
                outputAbandon(g_outLayer, "its pass couldn't be encoded");
            }
            return;
        }
        // What the game drew, at its own size, now and then for Anvil to read (anvil_screens.mm).
        anvil_screens_offer(cb, proxy->_input);
        // Frame generation's history as encoded too, so a frame it makes is upscaled like
        // the game's own.
        gameFrame = rawView(cb, proxy->_input);
        drawable = proxy->_real;
        if (g_mid.load()) {
            // Smooth Motion between frames, begun while the game held this drawable: to the presenter
            // too, so no frame is shown out of turn — as it is, with none made between.
            midHandOff(cb, proxy->_real, nil, -1, -1);
            handedOff = true;
        } else if (g_enabled && g_frameGen && g_generating) {
            // After FSR 3, the frame as shown (its blend is at the display's size); after FSR 1,
            // the game's own, upscaled with each generated frame.
            id<MTLTexture> record = g_fsr3Live ? rawView(cb, proxy->_real.texture) : gameFrame;
            ensureFrameGenResources(record);
            recordFrameIn(cb, record);
        }
    }
    // Handed to the presenter, the frame is no longer this hook's to show.
    id<CAMetalDrawable> d = handedOff ? nil : (id<CAMetalDrawable>)drawable;

    // What the game spent on this frame: from leaving the last present to arriving at
    // this one, less any wait for a drawable. Holds are Anvil's, not the game's.
    const double callAt = CACurrentMediaTime();
    if (g_sessionStartAt < 0.0) g_sessionStartAt = callAt;
    // Behind another app: one frame every 1/30 s (see anvil_watch_front), and the pacing
    // left as it was — the rate seen back here says nothing about the game's own.
    const bool inFront = anvil_game_in_front();
    if (!inFront && (d || handedOff)) {
        static double lastBehind = 0.0;
        const double period = behindPeriod(callAt);
        // Said once each time it moves down to 10 a second (5 is said as the screen goes).
        static bool saidLong = false;
        if (period == kBehindLongPeriod && !saidLong) {
            saidLong = true;
            diag("[anvil] behind other apps for two minutes — held to 10 fps until the game is back");
        } else if (period == kBehindPeriod) {
            saidLong = false;
        }
        const double due = lastBehind + period;
        if (period > 0.0 && due > callAt && due < callAt + period + 0.001) {
            sleepUntil(due);
            g_hookWaitSec += CACurrentMediaTime() - callAt;
        }
        lastBehind = CACurrentMediaTime();
        g_behindFrames.fetch_add(1, std::memory_order_relaxed);
    }
    if (inFront) steadyAtPresent(callAt, d != nil || handedOff);
    if (inFront && upscaled) fsr3Govern(callAt);

    // Anvil is a guest in this process. Anything it throws must not reach the game's
    // own frame loop, so the work is fenced and the frame simply goes out untouched
    // if it fails.
    @try {
        // Before sharpening and the counter: the frame as the game drew it.
        if (d && !upscaled) anvil_screens_offer((id<MTLCommandBuffer>)self, d.texture);
        if (g_enabled && d && g_rcas && !upscaled) {
            processDrawable((id<MTLCommandBuffer>)self, d);
        }
    } @catch (NSException* e) {
        os_log_error(OS_LOG_DEFAULT, "[anvil] disabled after %{public}s", e.name.UTF8String);
        diag("[anvil] EXCEPTION in present: %s — %s (pipeline disabled, game continues)",
             e.name.UTF8String, e.reason.UTF8String);
        g_enabled = false;
    }



    // Registered before presenting, which is the only point it is accepted. This is
    // what distinguishes a frame that was submitted from a frame that was shown, and
    // it is also how a drawable is known to be back in the pool.
    if ((g_frameGen || g_pacing) && d) {
        @try {
            g_pendingPresents.fetch_add(1, std::memory_order_release);
            [d addPresentedHandler:^(id<MTLDrawable> shown) {
                g_pendingPresents.fetch_sub(1, std::memory_order_release);
                if (shown.presentedTime <= 0) g_notShown.fetch_add(1, std::memory_order_relaxed);
                noteShown(false, shown.presentedTime);
            }];
        } @catch (NSException*) {
            g_pendingPresents.fetch_sub(1, std::memory_order_release);
        }
    }

    // Put this frame on the panel's grid rather than presenting it the instant it is
    // ready. Evenly spaced frames are what "stable" means; an unpaced 67 fps on a
    // 120 Hz panel is 120 fps on average and visibly uneven.
    bool paced = false;
    // Below the display rate on a variable-refresh panel: show each frame as soon as it
    // is ready, never faster than the panel's top rate. Entered below ~116 fps and left
    // above ~119, so it does not flicker between modes at the edge; above that the
    // grid below holds the game to an even 120.
    if (g_pacing && d && g_vrrState != 0 && !g_generating && g_refreshPeriod > 0.0 && g_ownEma > 0.0) {
        if (!g_vrrActive && g_ownEma > g_refreshPeriod * 1.03) g_vrrActive = true;
        else if (g_vrrActive && g_ownEma < g_refreshPeriod * 1.01) g_vrrActive = false;
    } else if (g_generating) {
        // Smooth Motion shows the game's own frames as they're ready, as without it.
        g_vrrActive = g_fill && g_pacing && g_vrrState != 0;
    }
    g_realFrames.fetch_add(1, std::memory_order_relaxed);
    if (g_steady == Steady::hold && d && !g_generating) {
        // An even 80: three 240 Hz steps. The game's thread waits for its point on the
        // cadence here — before its next frame starts, so nothing queues and input is
        // read late rather than shown late — and the panel keeps the spacing.
        const double now = CACurrentMediaTime();
        const double target = steadyHoldTarget(now);
        if (target > now) sleepUntil(target);
        const double waited = CACurrentMediaTime() - now;
        g_hookWaitSec += waited;
        g_holdWaitSec = waited;
        @try {
            // Its wait from here to the screen, for the log (g_holdLag).
            const double presentAt = CACurrentMediaTime();
            [d addPresentedHandler:^(id<MTLDrawable> shown) {
                const double lag = shown.presentedTime - presentAt;
                if (shown.presentedTime > 0 && lag > 0.0 && lag < 0.25) {
                    const double was = g_holdLag.load(std::memory_order_relaxed);
                    g_holdLag.store(was > 0.0 ? was * 0.9 + lag * 0.1 : lag, std::memory_order_relaxed);
                }
            }];
            TimedPresent timed;
            [(id<MTLCommandBuffer>)self presentDrawable:d afterMinimumDuration:steadyHoldMinGap()];
            paced = true;
            g_heldFrames.fetch_add(1, std::memory_order_relaxed);
            g_nextRealSlot = 0.0;
        } @catch (NSException*) { paced = false; }
    }
    if (!paced && g_vrrActive && d) {
        // No hold beyond one refresh. This used to be 0.92 of the game's average frame
        // time, to even out a frame that finished early — on the assumption that the
        // panel can show a frame at any moment. MacBook Pro's ProMotion panel cannot:
        // it shows frames on a 240 Hz grid (every displayed gap in the logs is a
        // multiple of 4.17 ms). Any hold between 8.33 and 12.5 ms became a wait for the
        // 12.5 ms step, so a game that could run at 96 fps was shown at exactly 80; the
        // frames queued behind the hold then made the game itself measure 80, and it
        // never climbed back. LEGO Star Wars on 29 September: 94 of 258 five-second
        // windows at 80.0 fps, 30 of them with the game able to do 85–110. The same
        // happened at 60 for a game near 67. Shown as ready, the game's own rate
        // reaches the screen: gaps of 8.3 and 12.5 ms that average what it renders.
        // A cap below the display's rate (60, 30) holds here too. It used to apply only
        // on the grid, which the game leaves as soon as it drops below 116 fps — so a
        // 60 cap let a game at 100 through at 100. Half a millisecond under, so the
        // frame lands on the step the cap means and not the one after.
        double minGap = g_refreshPeriod;
        if (g_fullSlotPeriod > g_refreshPeriod * 1.05) minGap = g_fullSlotPeriod - 0.0005;
        // Smooth Motion: the frame shown before this one is the one made halfway — this one no
        // sooner than 0.3 of the game's frame time after it. Not more: the panel shows frames on its
        // 240 Hz steps, each gap rounded up to one, and two gaps asked for at half a frame each
        // added up to more than the frame — the screen fell behind a little every frame until the
        // pool was full and a made frame was skipped (a fifth of them in Anvil's stand-in).
        if (g_fill && g_frameInterval > 0.0) minGap = std::max(minGap, 0.3 * g_frameInterval);
        @try {
            TimedPresent timed;
            [(id<MTLCommandBuffer>)self presentDrawable:d afterMinimumDuration:minGap];
            paced = true;
            g_vrrFrames.fetch_add(1, std::memory_order_relaxed);
            g_nextRealSlot = 0.0;   // the grid is re-established from scratch on return
        } @catch (NSException*) { paced = false; }
    }
    if (!paced && g_pacing && g_realSlotPeriod > 0.0 && d) {
        const double now = CACurrentMediaTime();
        // Re-establish the grid on the first frame, and any time the game has fallen
        // far enough behind that the old slots are meaningless — after a load screen,
        // or a hitch. Chasing stale slots would present a burst of frames at once.
        if (g_nextRealSlot <= 0.0 || g_nextRealSlot < now - 4.0 * g_realSlotPeriod
                                  || g_nextRealSlot > now + 4.0 * g_realSlotPeriod) {
            if (g_nextRealSlot > 0.0) g_resyncs.fetch_add(1, std::memory_order_relaxed);
            g_nextRealSlot = now;
        }
        double target = (g_nextRealSlot > now) ? g_nextRealSlot : now;
        // A game running faster than the panel waits at most one slot. Letting the
        // schedule run further ahead would queue finished frames behind each other,
        // which is latency with nothing shown for it.
        //
        // Not by waiting here, as vsync would. 0.25.0 tried that, to stop frames being
        // drawn and not shown (160 drawn for 120 shown on LEGO Star Wars' loading screen,
        // a few percent of the GPU): it took away the frame of slack that covers a loading
        // screen's hiccups, a slot was missed whenever one came, and Steady read the misses
        // as a slow game — held to 80, let go, held again, every few seconds, on a screen
        // the game could draw at 300 (3 October). A frame thrown away now and then is the
        // cheaper of the two.
        if (target > now + g_realSlotPeriod) target = now + g_realSlotPeriod;
        target = snapToGrid(target);
        g_nextRealSlot = target + g_realSlotPeriod;
        g_lastRealTarget = target;

        @try {
            TimedPresent timed;
            [(id<MTLCommandBuffer>)self presentDrawable:d atTime:target];
            paced = true;
        } @catch (NSException*) { paced = false; }
    }
    if (!paced && !handedOff) {
        ((void (*)(id, SEL, id))g_originalPresent)(self, _cmd, drawable);
    }
    ++g_frames;



    // Frame rate, measured here because this is the one point that runs exactly once
    // per displayed frame. The overlay reads this; without it the counter draws a
    // correct, permanent zero.
    {
        const double now = CACurrentMediaTime();
        if (g_lastOverlayTime > 0.0) {
            const double dt = now - g_lastOverlayTime;
            if (dt > 0.0002 && dt < 1.0) {
                const double instant = 1.0 / dt;
                g_fpsSmoothed = (g_fpsSmoothed > 0.0)
                    ? g_fpsSmoothed * 0.92 + instant * 0.08
                    : instant;
            }
        }
        g_lastOverlayTime = now;
    }

    {
        const double now = CACurrentMediaTime();
        if (g_ownLastPresent > 0.0) {
            const double dt = now - g_ownLastPresent;
            if (dt > 0.001 && dt < 0.5) {
                guardianFrame(now, dt, g_hookWaitSec);
                double own = dt - g_hookWaitSec;
                if (own < 0.001) own = 0.001;
                g_ownWindowSum += own;
                ++g_ownWindowCount;
                g_ownQuickSum += own;
                ++g_ownQuickCount;
                g_ownEma = (g_ownEma > 0.0) ? g_ownEma * 0.9 + own * 0.1 : own;
                g_presentEma = (g_presentEma > 0.0) ? g_presentEma * 0.9 + dt * 0.1 : dt;
            }
        }
        g_ownLastPresent = now;
        g_hookWaitSec = 0.0;
        // Whether to generate frames, every two seconds of the game's own rate.
        if (g_ownQuickSince < 0.0) g_ownQuickSince = now;
        if (now - g_ownQuickSince >= kDecideEvery && g_ownQuickCount >= 8 && g_ownQuickSum > 0.0) {
            genDecide(now, (double)g_ownQuickCount / g_ownQuickSum, now - g_ownQuickSince);
            guardianStep(now, (double)g_ownQuickCount / g_ownQuickSum, now - g_ownQuickSince);
            g_ownQuickSum = 0.0;
            g_ownQuickCount = 0;
            g_ownQuickSince = now;
        }
    }

    if (g_enabled && g_frameGen) {
        // Track the cadence of real frames. Smoothed, because a single long frame
        // should not swing where the next synthesised one is placed.
        const double now = CACurrentMediaTime();
        if (g_lastRealPresent > 0.0) {
            const double dt = now - g_lastRealPresent;
            if (dt > 0.001 && dt < 0.5) g_frameInterval = g_frameInterval * 0.9 + dt * 0.1;
        }
        g_lastRealPresent = now;
    }

    // History is kept only while frames are actually being generated. It used to be
    // kept whenever generation was merely requested: two full-frame copies, a
    // luminance pass and a command buffer of its own on every frame, committed from
    // the game's render thread — the busiest thread a struggling game has — and then
    // thrown away, because the game was filling the display itself and nothing was
    // generated. Generation needs two frames of history, so switching it on costs two
    // frames of warm-up; that is the whole price of not doing this work the rest of
    // the time.
    if (g_enabled && g_frameGen && g_generating && d && d.texture && !upscaled && g_canWrite) {
        ensureFrameGenResources(d.texture);
        recordFrame(d.texture);
        // Sampled once a second rather than per frame; task_info is a trap call.
        if ((g_frames.load() % 60) == 0) updateMemoryState();
    }

    // Periodic accounting. Frame generation is the one feature whose success is
    // invisible from outside the process: a generated frame looks like any other
    // frame, and a pipeline that silently generates nothing is indistinguishable
    // from one that is working. These counters were maintained and never reported,
    // so "is frame generation actually running?" had no answer. Now it does.
    {
        const uint64_t n = g_frames.load(std::memory_order_relaxed);
        // Reported whether or not frames are being generated. It used to be gated on
        // generation being on, which meant the one configuration worth comparing
        // against — the game running entirely on its own frames — produced no numbers
        // at all.
        if (n > 0 && (n % 600) == 0) {
            const uint64_t skip = g_skippedGenerations.load(std::memory_order_relaxed);
            const uint64_t sr = g_shownReal.load(std::memory_order_relaxed);
            const uint64_t sg = g_shownGenerated.load(std::memory_order_relaxed);
            // Windowed, not cumulative. A lifetime average is dominated by the
            // first seconds — loading, shader compilation, the grid being
            // established — and says nothing about whether it is smooth *now*.
            const uint64_t iv   = g_shownIntervals.exchange(0, std::memory_order_relaxed);
            const uint64_t beat = g_shownOnBeat.exchange(0, std::memory_order_relaxed);
            const double low1 = onePercentLowFPS();
            const uint64_t lsamp = g_latencySamples.exchange(0, std::memory_order_relaxed);
            const uint64_t ltot  = g_latencyTotalUs.exchange(0, std::memory_order_relaxed);
            const uint64_t lmax  = g_latencyMaxUs.exchange(0, std::memory_order_relaxed);
            const uint64_t misses = g_nearMisses.exchange(0, std::memory_order_relaxed);
            const uint64_t steady = g_shownSteady.exchange(0, std::memory_order_relaxed);
            const uint64_t vrrN   = g_vrrFrames.exchange(0, std::memory_order_relaxed);
            const uint64_t realN  = g_realFrames.exchange(0, std::memory_order_relaxed);
            // The game's unaided rate over this window: frames over the time it spent
            // working on them.
            const double ownFPS = (g_ownWindowCount > 0 && g_ownWindowSum > 0.0)
                                ? (double)g_ownWindowCount / g_ownWindowSum : g_fpsSmoothed;
            g_ownWindowSum = 0.0;
            g_ownWindowCount = 0;
            // What limited this window: the GPU's own busy figure and the busiest threads,
            // read in the background as of the last window.
            char load[1024] = "";
            {
                const int gpu = g_gpuBusy.load(), top = g_topThreadBusy.load(), next = g_nextThreadBusy.load();
                int used = 0;
                if (gpu >= 0) used += snprintf(load + used, sizeof load - used, " | GPU %d%% busy", gpu);
                if (top >= 0 && used < (int)sizeof load)
                    used += snprintf(load + used, sizeof load - used, " | busiest threads %d%% and %d%% of a core", top, next);
                const uint64_t heldN = g_heldFrames.exchange(0, std::memory_order_relaxed);
                if (g_steady != Steady::off && used < (int)sizeof load) {
                    char extra[96] = "";
                    const double lag = g_holdLag.exchange(0.0, std::memory_order_relaxed);
                    if (heldN > 0 && lag > 0.0) snprintf(extra, sizeof extra, ", %.0f ms each from present to screen", lag * 1000.0);
                    used += snprintf(load + used, sizeof load - used, " | steady %d: %s (%llu held%s)",
                                     (int)lround(steadyHoldRate()), steadyName(g_steady), (unsigned long long)heldN, extra);
                }
                const uint64_t dropped = g_notShown.exchange(0, std::memory_order_relaxed);
                if (dropped > 0 && used < (int)sizeof load)
                    used += snprintf(load + used, sizeof load - used, " | not shown %llu", (unsigned long long)dropped);
                // Frames drawn while another app was in front, held to 30: not play to measure.
                const uint64_t behind = g_behindFrames.exchange(0, std::memory_order_relaxed);
                if (behind > 0 && used < (int)sizeof load)
                    used += snprintf(load + used, sizeof load - used, " | behind %llu", (unsigned long long)behind);
                // Generated frames among those shown in this stretch, so what is measured of
                // the game — by Auto-Tune, by the checks after a session — is its own frames.
                {
                    static uint64_t lastReal = 0, lastGen = 0;
                    const uint64_t dReal = sr - lastReal, dGen = sg - lastGen;
                    lastReal = sr; lastGen = sg;
                    if (dGen > 0 && used < (int)sizeof load)
                        used += snprintf(load + used, sizeof load - used, " | generated %llu of %llu shown",
                                         (unsigned long long)dGen, (unsigned long long)(dReal + dGen));
                    // Why made frames were skipped, when some were: the last one still on the GPU,
                    // or no drawable free.
                    const uint64_t busy = g_skippedBusy.exchange(0), pool = g_skippedPool.exchange(0);
                    if ((busy || pool) && used < (int)sizeof load)
                        used += snprintf(load + used, sizeof load - used, " (skipped %llu: GPU busy %llu, no drawable %llu)",
                                         (unsigned long long)(busy + pool), (unsigned long long)busy, (unsigned long long)pool);
                    // Smooth Motion between frames: how long the game waited, a frame, with two of its frames
                    // on their way to the screen — time the GPU was still busy with them — and the
                    // presenter for drawables to show them in.
                    const uint64_t waitedUs = g_midGateWaitUs.exchange(0), late = g_midGateTimeouts.exchange(0);
                    const uint64_t presenterUs = g_midWaitUs.exchange(0), behind = g_midBehind.exchange(0);
                    if (g_mid.load() && used < (int)sizeof load)
                        used += snprintf(load + used, sizeof load - used, " | frames between: the game waited %.1f ms a frame for "
                                         "its frames in flight%s, the presenter %.1f ms for drawables",
                                         dReal > 0 ? (double)waitedUs / 1000.0 / (double)dReal : 0.0,
                                         late ? " (some waits cut short at 100 ms)" : "",
                                         dReal > 0 ? (double)presenterUs / 1000.0 / (double)dReal : 0.0);
                    if (g_mid.load() && g_midMult.load() > 2 && used < (int)sizeof load)
                        used += snprintf(load + used, sizeof load - used, ", %d frames shown for each of the game's", g_midMult.load());
                    if (g_mid.load() && behind && used < (int)sizeof load)
                        used += snprintf(load + used, sizeof load - used, ", %llu made frames left out with the screen behind",
                                         (unsigned long long)behind);
                    // The made frames' check: of those made, how many were the nearer real frame instead.
                    if (g_midCheckState) {
                        auto* st = (MidCheckState*)g_midCheckState.contents;
                        const uint32_t judged = st->judged, held = st->held, parted = st->parted;
                        const float most = st->most;
                        st->most = 0.0f;
                        const uint32_t dj = judged - g_midCheckJudgedSeen, dh = held - g_midCheckHeldSeen, dp = parted - g_midCheckPartedSeen;
                        g_midCheckJudgedSeen = judged; g_midCheckHeldSeen = held; g_midCheckPartedSeen = parted;
                        if (g_mid.load() && dj && used < (int)sizeof load)
                            used += dh ? snprintf(load + used, sizeof load - used,
                                                  ", %u of %u made frames the nearer real one instead (the two frames disagreed over up to "
                                                  "%.0f%% of the picture: reflections, heat, flames or motion too fast to follow)",
                                                  dh, dj, 100.0 * most)
                                       : snprintf(load + used, sizeof load - used, ", made frames checked (the two frames disagreed over "
                                                  "%.0f%% of the picture at most)", 100.0 * most);
                        if (g_mid.load() && dp && used < (int)sizeof load)
                            used += snprintf(load + used, sizeof load - used,
                                             ", %u with the real frame's pixels where the two disagreed (flames, sparks, reflections)", dp);
                    }
                }
                if (g_outputActive.load() && used < (int)sizeof load)
                    used += snprintf(load + used, sizeof load - used, " | FSR %.0fx%.0f to %.0fx%.0f",
                                     g_gameSize.width, g_gameSize.height, g_outSize.width, g_outSize.height);
                // Frames through FSR 3 in this stretch, of those the game drew.
                {
                    static uint64_t lastFsr3 = 0;
                    const uint64_t n3 = g_fsr3Frames.load(std::memory_order_relaxed);
                    if (n3 > lastFsr3 && used < (int)sizeof load)
                        used += snprintf(load + used, sizeof load - used, " | FSR 3 on %llu",
                                         (unsigned long long)(n3 - lastFsr3));
                    lastFsr3 = n3;
                    if (g_fsr3Wanted && g_fsr3Eased.load() && used < (int)sizeof load)
                        used += snprintf(load + used, sizeof load - used, " | FSR 3 eased to FSR 1");
                }
                if (enduranceOn() && used < (int)sizeof load)
                    used += snprintf(load + used, sizeof load - used, " | long session (%s)",
                                     enduranceWhy(g_powerFlags.load()));
                if (g_gapP50Ms > 0.0 && used < (int)sizeof load)
                    used += snprintf(load + used, sizeof load - used, " | gaps: half under %.1f ms, 90%% under %.1f ms",
                                     g_gapP50Ms, g_gapP90Ms);
                // Each frame started just in time, at a low frame rate: how many were held, how long.
                {
                    const uint64_t frames = g_jitFrames.exchange(0), held = g_jitHeld.exchange(0), heldUs = g_jitHeldUs.exchange(0),
                                   late = g_jitLate.exchange(0);
                    if (held && used < (int)sizeof load)
                        used += snprintf(load + used, sizeof load - used, " | just in time: %llu of %llu frames started later, %.1f ms each (the GPU %.1f ms a frame, busy %.0f%%; the game given %.1f ms; %llu reached it late)",
                                         (unsigned long long)held, (unsigned long long)frames, heldUs / 1000.0 / (double)held,
                                         g_jitGpu.load() * 1000.0, g_jitBusy.load() * 100.0, g_jitLead * 1000.0, (unsigned long long)late);
                }
                if (used < (int)sizeof load) used += AnvilGpuWorkWindow(load + used, sizeof load - used);
            }
            // What sharpening textures for FSR did: once the game has made its samplers, and
            // again a minute on, when a level's worth more have been made.
            {
                static int said = 0;
                static double firstAt = 0.0;
                int seen = 0, sharpened = 0, aniso = 0;
                float bias = 0.0f;
                AnvilTextureDetailReport(&seen, &sharpened, &bias, &aniso);
                const double now = CACurrentMediaTime();
                if (seen > 0 && (bias != 0.0f || aniso > 1) && (said == 0 || (said == 1 && now - firstAt > 60.0))) {
                    if (said == 0) firstAt = now;
                    ++said;
                    char filtering[48] = "";
                    if (aniso > 1) snprintf(filtering, sizeof filtering, " and %d× anisotropic filtering", aniso);
                    diag("[anvil] textures: sharpened for FSR — mip bias %.2f%s on %d of the %d samplers the game has made "
                         "(filtered and mipmapped; shadow, interface and lookup ones left as they are)",
                         bias, filtering, sharpened, seen);
                }
            }
            // How many of the game's shaders Metal compiles at once (anvil_gpuwork.mm), once.
            {
                static bool said = false;
                int before = -1, after = -1;
                AnvilCompileConcurrency(&before, &after);
                if (!said && after > 0) {
                    said = true;
                    if (after > before)
                        diag("[anvil] shaders: the game's compiled up to %d at once, as many as Metal can on this Mac (%d before asking)"
                             " — a burst of them on entering a new area takes less of a frame", after, before);
                    else
                        diag("[anvil] shaders: the game's compiled up to %d at once — Metal's most on this Mac already, so asking for "
                             "more changed nothing", after);
                }
            }
            // A frame of the game's 3D world, its passes in order, once a session (anvil_gpuwork.mm).
            {
                static char anatomy[3072];
                if (AnvilGpuFrameAnatomy(anatomy, sizeof anatomy)) diag("[anvil] frame anatomy: %s", anatomy);
            }
            sampleLoadAsync();
            // The window's frames on the screen over its time (see g_windowShownSec).
            double shownRate = g_displayedFPS;
            {
                std::lock_guard<std::mutex> hold(g_shownLock);
                if (g_windowShownN >= 30 && g_windowShownSec > 0.0) shownRate = (double)g_windowShownN / g_windowShownSec;
                g_windowShownN = 0;
                g_windowShownSec = 0.0;
            }
            diag("[anvil] displayed %.1f fps | 1%% LOW %.1f fps | STEADY %.1f%% | shown as ready %.0f%%%s | EVENNESS %.1f%% on-beat "
                 "(%llu of %llu gaps) worst gap %.1f ms | rendered %.1f fps (game could %.1f) | "
                 "real=%llu gen=%llu skipped=%llu resyncs=%llu | "
                 "LATENCY %.1f ms avg %.1f ms max | in flight %d | missed %llu | memory %.0f MB%s",
                 shownRate, low1,
                 iv ? 100.0 * (double)steady / (double)iv : 0.0,
                 realN ? 100.0 * (double)vrrN / (double)realN : 0.0,
                 g_vrrState == 1 ? (g_vrrVerified ? " (variable refresh, confirmed)" : " (variable refresh)")
                                 : (g_vrrState == 0 ? " (fixed refresh)" : g_vrrState == 2 ? " (fixed refresh, looking again)" : ""),
                 iv ? 100.0 * (double)beat / (double)iv : 0.0,
                 (unsigned long long)beat, (unsigned long long)iv, g_worstGapMs,
                 g_fpsSmoothed, ownFPS,
                 (unsigned long long)sr, (unsigned long long)sg,
                 (unsigned long long)skip,
                 (unsigned long long)g_resyncs.load(std::memory_order_relaxed),
                 lsamp ? (double)ltot / (double)lsamp / 1000.0 : 0.0, lmax / 1000.0,
                 g_appliedDepth > 0 ? g_appliedDepth - 1 : 0,
                 (unsigned long long)misses,
                 currentFootprintMB(), load);

            // One frame in flight is kept only while it costs nothing. More than
            // half a percent of refreshes missed means the game needs the slack, and
            // it gets it for the rest of the session — flipping back and forth would
            // be a stutter of its own.
            if (g_lowLatency && g_pacing && !g_generating && g_depthFloor == 2
                && iv > 0 && misses * 200 > iv) {
                g_depthFloor = 3;
                diag("[anvil] game missed %llu of %llu refreshes with one frame in flight "
                     "— going to two for the rest of the session",
                     (unsigned long long)misses, (unsigned long long)iv);
            }
            // Worst-gap resets each window so one early hitch does not mask a run
            // that has since settled.
            g_worstGapMs = 0.0;

            const double windowAt = CACurrentMediaTime();
            const double windowSec = (g_lastWindowAt > 0.0) ? windowAt - g_lastWindowAt : 5.0;
            g_lastWindowAt = windowAt;
            if (g_refreshPeriod > 0.0 && ownFPS > 0.0 && ownFPS < 0.85 / g_refreshPeriod) {
                // The first slow stretch of a session is profiled while it happens, so
                // what limits the game in a fight can be read rather than guessed.
                static bool profiled = false;
                if (g_captureStalls && !profiled && g_frames.load(std::memory_order_relaxed) > 3000) {
                    profiled = true;
                    if (const char* dir = AnvilCaptureStall("slow1"))
                        diag("[anvil] game at %.1f fps on its own — recording what every thread "
                             "is doing to %s", ownFPS, dir);
                }
            }
            (void)windowSec;   // generated frames are decided every two seconds now (above)

        }
    }
    // The game has its thread back from here: the start of its next frame.
    g_resumedAt = CACurrentMediaTime();
}

/// The command buffer class is private and only reachable from a live instance, so
/// the present hook is installed the first time a frame goes past.
void installPresentHook(id<MTLCommandQueue> queue) {
    if (g_presentHooked.exchange(true)) return;

    id<MTLCommandBuffer> probe = [queue commandBuffer];
    Class cls = object_getClass(probe);
    Method m = class_getInstanceMethod(cls, @selector(presentDrawable:));
    if (!m) {
        os_log_error(OS_LOG_DEFAULT, "[anvil] presentDrawable: not found on %{public}s",
                     class_getName(cls));
        return;
    }
    g_originalPresent = method_getImplementation(m);
    method_setImplementation(m, (IMP)hookedPresentDrawable);
    // Its commit: where a frame handed over is held for the next to start just in time (jitHold).
    if (g_jitOn) {
        if (Method c = class_getInstanceMethod(cls, @selector(commit))) {
            g_originalCommit = method_getImplementation(c);
            method_setImplementation(c, (IMP)hookedCommit);
        }
    }
    // The same class's passes, timed one frame in two seconds (anvil_gpuwork.mm).
    AnvilWatchCommandBuffers(cls);

    // Ask AppKit about the display now that the game has a window — at load time it
    // was not there to ask. On the main thread, which AppKit expects, and without
    // waiting for it.
    if (g_vrrState < 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            const int v = detectVariableRefresh();
            if (v == 1) g_vrrReported = true;
            if (g_vrrState < 0 && v >= 0) {
                g_vrrState = v;
                diag("[anvil] display reports %s", v ? "variable refresh" : "a fixed refresh rate");
            }
            applyReportedRefresh(v, "with the game's window");
        });
    }

    // Frame watchdog. Every session with a working controller stopped reporting
    // statistics after 5-15 seconds while the game kept handling input, which means it
    // had stopped drawing. This records exactly when that happens and for how long, so
    // it can be lined up with controller activity and with which app is in front.
    // What the game read meanwhile is said as it resumes: Hogwarts Legacy's stops of 1.8 s on 22 October came with
    // 300–900 MB of its data read in the same seconds — the game loading the next part of the castle, not a hang.
    std::thread([] {
        uint64_t seen = 0; double changedAt = CACurrentMediaTime(); bool stalled = false;
        AnvilReadTotals before{};
        for (;;) {
            usleep(250000);
            const uint64_t n = g_frames.load(std::memory_order_relaxed);
            const double t = CACurrentMediaTime();
            if (n != seen) {
                if (stalled) {
                    AnvilReadTotals after;
                    AnvilReadTotalsGet(&after);
                    diag("[anvil] frames RESUMED after %.1f s without a frame — %.1f MB of its data read meanwhile",
                         t - changedAt, (double)(after.bytes - before.bytes) / 1048576.0);
                }
                stalled = false; seen = n; changedAt = t;
                AnvilReadTotalsGet(&before);
            } else if (!stalled && n > 120 && t - changedAt > 1.5) {
                stalled = true;
                diag("[anvil] frames STOPPED: no frame for %.1f s (after %llu frames)",
                     t - changedAt, (unsigned long long)n);
                // The first two freezes of a session are recorded while they happen:
                // three seconds of every thread's stack, in the game and in Wine.
                static unsigned captures = 0;
                if (g_captureStalls && captures < 2) {
                    const char* label = (++captures == 1) ? "freeze1" : "freeze2";
                    if (const char* dir = AnvilCaptureStall(label))
                        diag("[anvil] recording what every thread is doing to %s", dir);
                }
            }
        }
    }).detach();
    os_log(OS_LOG_DEFAULT, "[anvil] present hook installed on %{public}s", class_getName(cls));
}

id hookedNextDrawable(id self, SEL _cmd) {
    anvil_ensure_setup("first frame");
    CAMetalLayer* layer = (CAMetalLayer*)self;
    // Everything the game spends in here is waiting, not working: see g_hookWaitSec.
    const double hookEntered = CACurrentMediaTime();
    struct WaitClock { double from; ~WaitClock() { g_hookWaitSec += CACurrentMediaTime() - from; } } waitClock{hookEntered};

    // A layer that is framebufferOnly hands out textures a compute kernel may not
    // write. This has to be cleared before the drawable is created, which is the
    // only reason this hook exists.
    if (g_enabled && layer.framebufferOnly) layer.framebufferOnly = NO;
    g_layer = layer;
    if (g_enabled) { tuneLayer(layer); applyDepth(layer); }

    // Remember the size the game asked for, then hand it the scaled one. Not while FSR to
    // the display owns the layer's size.
    if (g_enabled && fabsf(g_renderScale - 1.0f) > 0.001f && !(g_outputActive.load() && layer == g_outLayer)) {
        const CGSize current = layer.drawableSize;
        // Adopt a new baseline only when the game picked a size Anvil did not write.
        // Comparing against the scaled value alone was not enough: once the layer
        // reported back something Anvil had set, that value was mistaken for the
        // game's own choice and scaled again, so the drawable ratcheted upward every
        // time — 1512 to 2017 to 4034 — growing the frame cost without bound.
        if (CGSizeEqualToSize(g_nativeSize, CGSizeZero) ||
            (!CGSizeEqualToSize(current, g_appliedSize)
             && !CGSizeEqualToSize(current, g_nativeSize))) {
            g_nativeSize = current;
        }

        if (g_nativeSize.width > 0) {
            CGSize want = CGSizeMake(floor(g_nativeSize.width * g_renderScale),
                                     floor(g_nativeSize.height * g_renderScale));

            // Never ask for more pixels than the display can show. Beyond that the
            // cost is real and the detail is discarded.
            static CGSize screenPixels = CGSizeZero;
            if (CGSizeEqualToSize(screenPixels, CGSizeZero)) {
                if (CGDisplayModeRef mode = CGDisplayCopyDisplayMode(CGMainDisplayID())) {
                    screenPixels = CGSizeMake(CGDisplayModeGetPixelWidth(mode),
                                              CGDisplayModeGetPixelHeight(mode));
                    CGDisplayModeRelease(mode);
                }
            }
            if (screenPixels.width > 0 && want.width > screenPixels.width) {
                const double fit = screenPixels.width / want.width;
                want = CGSizeMake(floor(want.width * fit), floor(want.height * fit));
            }

            // Snap to a whole-number fraction of the display.
            //
            // This is the fix for the picture shimmering — "the graphics are
            // shaking". A render scale of 1.334 on this panel produced a 2017x1310
            // drawable that the compositor then stretched to 3024x1964, a ratio of
            // 1.4993. At a fraction like that every output pixel is a different blend
            // of its neighbours, and the blend changes as the camera moves, so edges
            // crawl and fine detail boils. It is not a frame-rate problem and no
            // amount of pacing touches it.
            //
            // At a whole-number ratio — 1:1, or exactly half, or a third — each output
            // pixel is a fixed combination of the same input pixels every frame, and
            // the image is stable. So whatever scale is asked for, the drawable is
            // moved to the nearest clean ratio rather than used as given.
            if (screenPixels.width > 0 && want.width > 0) {
                double k = (double)screenPixels.width / want.width;
                k = floor(k + 0.5);                       // nearest whole ratio
                if (k < 1.0) k = 1.0;
                if (k > 4.0) k = 4.0;
                const CGSize snapped = CGSizeMake(floor(screenPixels.width / k),
                                                  floor(screenPixels.height / k));
                if (!CGSizeEqualToSize(snapped, want)) {
                    // Said once, not once per frame. This runs on every drawable
                    // request, and an unconditional diag here opened and closed the
                    // log file 9,133 times in a single session.
                    static CGSize lastReported = CGSizeZero;
                    if (!CGSizeEqualToSize(lastReported, snapped)) {
                        lastReported = snapped;
                        diag("[anvil] render scale %.3f asked for %.0fx%.0f; using %.0fx%.0f "
                             "(1/%.0f of the display) so the image does not shimmer",
                             g_renderScale, want.width, want.height,
                             snapped.width, snapped.height, k);
                    }
                    want = snapped;
                }
            }
            // Only when it actually differs. Assigning drawableSize invalidates and
            // rebuilds CAMetalLayer's drawable pool, so writing it every frame — even
            // the same value — costs a pool rebuild per frame. That was the stutter:
            // it scaled with how often this ran, not with how much work the pass did,
            // which is why turning an upscaler on made it worse rather than better.
            if (!CGSizeEqualToSize(layer.drawableSize, want)) {
                layer.drawableSize = want;
                g_appliedSize = want;
                diag("[anvil] drawable resized to %.0fx%.0f (base %.0fx%.0f, scale %.3f)",
                     want.width, want.height, g_nativeSize.width, g_nativeSize.height,
                     g_renderScale);
            }
        }
    }

    // Smooth Motion between frames (see g_mid): no more than two of the game's frames on their way to
    // the screen — the layer's drawables, which held it back, it no longer holds. On the way out,
    // every frame handed to the presenter is shown before the game's next is.
    if (g_enabled && layer == g_outLayer && (g_mid.load() || g_midBacklog.load() > 0)) {
        const double from = CACurrentMediaTime();
        bool timedOut = true;
        while (CACurrentMediaTime() < from + 0.1) {
            if (g_midBacklog.load() < (g_mid.load() ? g_midInFlight : 1)) { timedOut = false; break; }
            usleep(100);
        }
        if (timedOut) {
            g_midGateTimeouts.fetch_add(1, std::memory_order_relaxed);
            // Handed over and never back — a command buffer that never finished — is given up on.
            const double now = CACurrentMediaTime();
            if (!g_mid.load() && now - g_midShownAt.load() > 0.5 && now - g_midHandedAt.load() > 0.5) g_midBacklog.store(0);
            // The presenter stalled with the game's frames in it: the game's own frames from this one, not after
            // Guardian's next look (up to ten seconds, each frame meanwhile held here a tenth of a second).
            if (g_mid.load() && now - g_midShownAt.load() > kMidStallSec) midStalled(now);
        }
        g_midGateWaitUs.fetch_add((uint64_t)((CACurrentMediaTime() - from) * 1e6), std::memory_order_relaxed);
    }
    // Its stand-in, with no drawable of the layer's behind it.
    if (g_enabled && g_mid.load() && g_outputActive.load() && layer == g_outLayer && g_drawableClass
        && g_presentHooked.load() && g_fsrEasu && g_finish) {
        if (id<MTLTexture> input = midInputNext(layer.pixelFormat)) {
            if (!g_proxyClass) g_proxyClass = [AnvilProxyDrawable class];
            return [[[AnvilProxyDrawable alloc] initForLayer:layer input:input] autorelease];
        }
    }

    const CFTimeInterval requestedAt = CACurrentMediaTime();

    // Emit the synthesised frame here, in the window where the game holds no
    // drawable. Doing it inside presentDrawable: deadlocks: the game still holds its
    // own drawable there, and the pool has nothing left to hand out.
    // Generate only into a gap. When the game's own frames arrive about one refresh
    // apart it is already filling every slot, and a synthesised frame would displace
    // a real one — worse image, worse latency, no more frames. The threshold sits at
    // 1.4 refreshes so a game hovering near the panel's rate is left alone.
    // Whether to generate at all is decided once per window, on a measurement that
    // generation cannot corrupt — see the reporting block. Here it is only asked
    // whether this particular moment has a gap in it.
    const bool gapToFill = g_generating
                        && (g_refreshPeriod <= 0.0
                            || g_frameInterval > g_refreshPeriod * 1.25);
    // Half-rate cadence: the game waits here for its slot, the way any frame limiter
    // holds a game, until a drawable is free for the generated frame as well as its
    // own. Without the wait a game faster than 60 queues a second real frame, the pool
    // is full when the generator asks, and that refresh goes unfilled.
    // Smooth Motion the same, for at most a fifth of the game's own frame: a full pool when its
    // frame is made skips it, and that gap is shown twice as long as the others. In Anvil's stand-in
    // at 24.5 fps of its own: 19 of 398 skipped without the wait, none with it, for 3% of the
    // game's own rate (23.7) and 49.6 fps on the screen either way.
    if (g_enabled && g_frameGen && g_generating && (g_halfRate || g_fill) && g_pacing && g_refreshPeriod > 0.0 && !g_mid.load()) {
        const int depth = (g_appliedDepth > 0) ? g_appliedDepth
                        : ((g_maxDrawables > 0) ? g_maxDrawables : 3);
        const double deadline = CACurrentMediaTime()
                              + (g_fill ? std::min(2.5 * g_refreshPeriod, 0.2 * g_frameInterval) : 2.5 * g_refreshPeriod);
        while (g_pendingPresents.load(std::memory_order_acquire) >= depth - 1
               && CACurrentMediaTime() < deadline) {
            usleep(250);
        }
    }
    if (g_enabled && g_frameGen && gapToFill && g_haveHistory && g_rcas && !g_mid.load()) {
        @try {
            generateFrame();
        } @catch (NSException* e) {
            os_log_error(OS_LOG_DEFAULT, "[anvil] frame generation disabled after %{public}s",
                         e.name.UTF8String);
            g_frameGen = false;
        }
    }

    // The process that draws is the game: tell macOS so. Timer coalescing, which saves
    // power by letting a wake-up drift by up to a millisecond or more, is off for a
    // latency-critical activity — and every hold, cadence and grid step above is a timed
    // wake-up. App Nap stays off for it too. Once, in this process only.
    if (g_enabled) {
        static std::atomic<bool> declared{false};
        if (!declared.exchange(true)) {
            static id<NSObject> activity = [[NSProcessInfo processInfo]
                beginActivityWithOptions:(NSActivityUserInitiated | NSActivityLatencyCritical)
                                  reason:@"Game rendering (Anvil frame pacing)"];
            (void)activity;
            diag("[anvil] this process draws the game: latency-critical, so frame timing isn't coalesced");
        }
    }

    id drawable = ((id (*)(id, SEL))g_originalNextDrawable)(self, _cmd);
    if (drawable && !g_drawableClass) g_drawableClass = object_getClass(drawable);
    // From the game asking for somewhere to draw to that frame being on screen. This
    // function existed and was never called, so "measure latency" measured nothing.
    if (g_enabled && drawable) recordLatency((id<CAMetalDrawable>)drawable, requestedAt);
    if (g_enabled && layer.device && prepare(layer.device)) {
        installPresentHook(g_queue);   // pacing needs the queue, not the shaders
    }
    // FSR to the display: the game draws into a stand-in at its own size; the real drawable,
    // at the display's, is filled at present. Anything missing, and the layer goes back to
    // the game's size for the session — with a drawable of that size for this frame.
    if (drawable && g_outputActive.load() && layer == g_outLayer) {
        if (!g_enabled || !g_fsrEasu || !g_finish || !g_presentHooked.load()) {
            outputAbandon(layer, !g_fsrEasu || !g_finish ? "Anvil's FSR shaders aren't available" : "Anvil's present hook isn't in");
            return ((id (*)(id, SEL))g_originalNextDrawable)(self, _cmd);
        }
        @try {
            if (!g_proxyClass) g_proxyClass = [AnvilProxyDrawable class];
            id<MTLTexture> input = outputInputFor((id<CAMetalDrawable>)drawable, layer.pixelFormat);
            if (input) return [[[AnvilProxyDrawable alloc] initWithReal:(id<CAMetalDrawable>)drawable input:input] autorelease];
        } @catch (NSException* e) {
            diag("[anvil] FSR to the display: %s — %s", e.name.UTF8String, e.reason.UTF8String);
        }
        outputAbandon(layer, "a texture for the game's frame couldn't be made");
        return ((id (*)(id, SEL))g_originalNextDrawable)(self, _cmd);
    }
    return drawable;
}

// The layer's size, as the game sets it: taken over for FSR to the display when D3DMetal
// is the one setting it (see outputTake), kept at the display's pixels when anything else —
// Wine, on a window change — sets the size of a layer Anvil draws into.
/// Which library sets a layer's size, once each, with the layer's format: the live half of
/// Anvil's graphics scan reads it to say what draws the game — D3DMetal, MoltenVK (Vulkan,
/// and DirectX through DXVK), or Wine itself sizing a window.
void noteLayerSizer(const void* ret, CAMetalLayer* layer, CGSize size) {
    static std::mutex lock;
    static char seen[6][96];
    static int count = 0;
    Dl_info info;
    const char* path = (ret && dladdr(ret, &info) && info.dli_fname) ? info.dli_fname : "an unknown library";
    const char* slash = strrchr(path, '/');
    const char* name = slash ? slash + 1 : path;
    {
        std::lock_guard<std::mutex> hold(lock);
        for (int i = 0; i < count; ++i) if (strncmp(seen[i], name, sizeof seen[i] - 1) == 0) return;
        if (count >= 6) return;
        strlcpy(seen[count++], name, sizeof seen[0]);
    }
    diag("[anvil] graphics: %s sets a layer to %.0fx%.0f, pixel format %lu%s", name, size.width, size.height,
         (unsigned long)layer.pixelFormat, layer.wantsExtendedDynamicRangeContent ? ", extended range (HDR)" : "");
}

void hookedSetDrawableSize(id self, SEL _cmd, CGSize size) {
    noteLayerSizer(__builtin_return_address(0), (CAMetalLayer*)self, size);
    if (g_outputWanted && !g_outputFailed.load()) {
        const bool fromGame = g_outputAnyCaller || callerIsD3DMetal(__builtin_return_address(0));
        @try {
            if (fromGame) {
                if (outputTake((CAMetalLayer*)self, size)) return;
            } else if (self == g_outLayer && g_outputActive.load()) {
                if (outputTake((CAMetalLayer*)self, g_gameSize)) return;
            }
        } @catch (NSException* e) {
            diag("[anvil] FSR to the display: %s — %s", e.name.UTF8String, e.reason.UTF8String);
            g_outputFailed = true;
            g_outputActive = false;
        }
    }
    // Without FSR to the display: a game's frame of another shape than its window is still
    // shown whole, with bars, rather than stretched by the compositor.
    if (!g_outputActive.load() && callerIsD3DMetal(__builtin_return_address(0))) {
        const CGSize points = ((CAMetalLayer*)self).bounds.size;
        if (points.width >= 1.0 && points.height >= 1.0 && !CGSizeEqualToSize(fitShape(size, points), points))
            keepShape((CAMetalLayer*)self, size, size);
    }
    ((void (*)(id, SEL, CGSize))g_originalSetDrawableSize)(self, _cmd, size);
}

// --- No tearing ---------------------------------------------------------------------
// A Windows game with V-Sync off presents with a sync interval of 0, and D3DMetal —
// 2.1 and 3.0 alike call setDisplaySyncEnabled: — turns that into a layer that shows
// each frame the moment it arrives, mid-refresh. In a fullscreen game, drawn straight
// to the panel, the top of the screen then shows one frame and the rest the next:
// tearing. It also takes the display's timing out of Anvil's hands, and every paced
// present — held to 80, shown as ready, on the 120 grid — relies on it. So while Anvil
// paces the frames the layer stays synced to the display. That adds no wait: the
// pacing already decides when each frame goes, and a ProMotion panel follows the game
// anywhere from 24 to 120 Hz. ANVIL_DISPLAY_SYNC=0 lets the game have its way.
IMP g_originalSetDisplaySync = nullptr;

void hookedSetDisplaySyncEnabled(id self, SEL _cmd, BOOL enabled) {
    anvil_ensure_setup("V-Sync change");
    BOOL want = enabled;
    if (!enabled && g_enabled && g_displaySync != 0 && (g_pacing || g_displaySync == 1)) {
        want = YES;
        static std::atomic<bool> said{false};
        if (!said.exchange(true))
            diag("[anvil] the game turned V-Sync off, which tears — kept on: Anvil paces the frames "
                 "itself, so this adds no wait");
    }
    ((void (*)(id, SEL, BOOL))g_originalSetDisplaySync)(self, _cmd, want);
}

} // namespace

// Counters for Anvil's own test bench (fsr_bench), which can't see a frame on screen.
extern "C" uint64_t AnvilGeneratedFrames() { return g_generated.load(); }
extern "C" uint64_t AnvilUpscaledFrames() { return g_outputFrames.load(); }
extern "C" uint64_t AnvilFSR3Frames() { return g_fsr3Frames.load(); }

// The stand-in drawable. Everything but its texture is the real drawable's; presenting it
// directly — which D3DMetal doesn't do, but a drawable allows — runs the same FSR pass in a
// command buffer of its own on the game's queue. One with no real drawable goes to Smooth Motion's
// presenter the same way.
static void anvilProxyPresent(AnvilProxyDrawable* proxy, int kind, CFTimeInterval value) {
    if (!proxy->_real) {
        id<MTLCommandBuffer> cb = [workQueue() commandBuffer];
        if (cb) midPresentStandIn(cb, proxy);
        [cb commit];
        return;
    }
    id<MTLCommandBuffer> cb = [workQueue() commandBuffer];
    if (!cb || !(fsr3Encode(cb, proxy->_input, proxy->_real.texture) || outputEncode(cb, proxy->_input, proxy->_real.texture))) {
        outputAbandon(g_outLayer, "a stand-in was presented on its own and couldn't be upscaled");
        return;
    }
    TimedPresent timed;
    if (kind == 1) [cb presentDrawable:proxy->_real atTime:value];
    else if (kind == 2) [cb presentDrawable:proxy->_real afterMinimumDuration:value];
    else [cb presentDrawable:proxy->_real];
    [cb commit];
}

@implementation AnvilMidLink
- (void)metalDisplayLink:(CAMetalDisplayLink*)link needsUpdate:(CAMetalDisplayLinkUpdate*)update API_AVAILABLE(macos(14.0)) {
    @autoreleasepool { midLinkUpdate(update.drawable, update.targetPresentationTimestamp); }
}
@end

@implementation AnvilProxyDrawable
- (instancetype)initWithReal:(id<CAMetalDrawable>)real input:(id<MTLTexture>)input {
    _real = [real retain];
    _input = [input retain];
    return self;
}
- (instancetype)initForLayer:(CAMetalLayer*)layer input:(id<MTLTexture>)input {
    static std::atomic<NSUInteger> ids{1u << 30};
    _real = nil;
    _input = [input retain];
    _layer = [layer retain];
    _requestedAt = CACurrentMediaTime();
    _id = ids.fetch_add(1);
    return self;
}
- (void)dealloc {
    [_real release];
    [_input release];
    [_layer release];
    [_presentedHandlers release];
    [super dealloc];
}
- (id<MTLTexture>)texture { return _input; }
- (CAMetalLayer*)layer { return _real ? _real.layer : _layer; }
- (void)addPresentedHandler:(MTLDrawablePresentedHandler)block {
    if (_real) { [_real addPresentedHandler:block]; return; }
    if (!block) return;
    if (!_presentedHandlers) _presentedHandlers = [[NSMutableArray alloc] init];
    id copied = [block copy];
    [_presentedHandlers addObject:copied];
    [copied release];
}
- (CFTimeInterval)presentedTime { return _real ? _real.presentedTime : _presentedTime; }
- (NSUInteger)drawableID { return _real ? _real.drawableID : _id; }
- (void)present { anvilProxyPresent(self, 0, 0); }
- (void)presentAtTime:(CFTimeInterval)t { anvilProxyPresent(self, 1, t); }
- (void)presentAfterMinimumDuration:(CFTimeInterval)d { anvilProxyPresent(self, 2, d); }
// Without a real drawable, what else a drawable answers is answered as one would — its class's
// methods, invoked on nothing (zero, nil) — rather than an unknown selector taking the game down.
- (NSMethodSignature*)methodSignatureForSelector:(SEL)sel {
    if (_real) return [(NSObject*)_real methodSignatureForSelector:sel];
    NSMethodSignature* sig = g_drawableClass ? [g_drawableClass instanceMethodSignatureForSelector:sel] : nil;
    return sig ? sig : [NSMethodSignature signatureWithObjCTypes:"v@:"];
}
- (void)forwardInvocation:(NSInvocation*)invocation { [invocation invokeWithTarget:_real]; }
- (BOOL)respondsToSelector:(SEL)sel {
    if (_real) return [(NSObject*)_real respondsToSelector:sel];
    return g_drawableClass && [g_drawableClass instancesRespondToSelector:sel];
}
- (BOOL)conformsToProtocol:(Protocol*)protocol {
    if (_real) return [(NSObject*)_real conformsToProtocol:protocol];
    return g_drawableClass && [g_drawableClass conformsToProtocol:protocol];
}
- (BOOL)isKindOfClass:(Class)cls {
    if (_real) return [(NSObject*)_real isKindOfClass:cls];
    return g_drawableClass && [g_drawableClass isSubclassOfClass:cls];
}
@end

extern "C" uint64_t AnvilFrameCount() { return g_frames.load(); }
extern "C" uint64_t AnvilGeneratedFrameCount() { return g_generated.load(); }

extern "C" double AnvilMeanLatencyMs() {
    uint64_t n = g_latencySamples.load();
    return n ? (double)g_latencyTotalUs.load() / (double)n / 1000.0 : 0.0;
}
extern "C" double AnvilMaxLatencyMs() { return g_latencyMaxUs.load() / 1000.0; }
extern "C" uint64_t AnvilLatencySampleCount() { return g_latencySamples.load(); }

extern "C" double   AnvilFootprintMB()     { return currentFootprintMB(); }
extern "C" uint64_t AnvilPeakFootprintMB() { return g_peakFootprintMB.load(); }
extern "C" int      AnvilMemoryBudgetMB()  { return g_budgetMB; }
extern "C" double   AnvilFrameIntervalMs() { return g_frameInterval * 1000.0; }
extern "C" double   AnvilRenderScale()     { return g_renderScale; }
extern "C" double   AnvilCurrentFPS()      { return g_fpsSmoothed; }
extern "C" uint64_t AnvilSkippedGenerations() { return g_skippedGenerations.load(); }
extern "C" bool     AnvilIsOverBudget()    {
    // Evaluated live rather than read from the frame loop's flag, so a query made
    // between frames reports the truth.
    return g_budgetMB > 0 && currentFootprintMB() > g_budgetMB;
}

/// Hooks on CAMetalLayer, once. Separate from reading the settings: the hooks can go in
/// before the settings are there to read.
static std::atomic<bool> g_layerHooked{false};
static void installLayerHooks() {
    if (g_layerHooked.load()) return;
    static std::mutex lock;
    std::lock_guard<std::mutex> guard(lock);
    if (g_layerHooked.load()) return;
    Class layerClass = objc_getClass("CAMetalLayer");
    if (!layerClass) return;
    Method m = class_getInstanceMethod(layerClass, @selector(nextDrawable));
    if (!m) return;
    g_originalNextDrawable = method_getImplementation(m);
    method_setImplementation(m, (IMP)hookedNextDrawable);
    if (Method sync = class_getInstanceMethod(layerClass, @selector(setDisplaySyncEnabled:))) {
        g_originalSetDisplaySync = method_getImplementation(sync);
        method_setImplementation(sync, (IMP)hookedSetDisplaySyncEnabled);
    }
    // Always in: the hooks go in before Anvil's settings can be read (see anvil_ensure_setup),
    // and the hook does nothing unless FSR to the display was asked for.
    if (Method size = class_getInstanceMethod(layerClass, @selector(setDrawableSize:))) {
        g_originalSetDrawableSize = method_getImplementation(size);
        method_setImplementation(size, (IMP)hookedSetDrawableSize);
    }
    g_layerHooked = true;
}

static std::atomic<bool> g_settingsRead{false};

/// Everything the interceptor needs, done once, from wherever it is first possible.
///
/// It used to happen only in the library's constructor. Under Wine 7.7 that was enough:
/// the game ran in the process Anvil started, with Anvil's settings in its environment
/// from the first instruction. Under Wine 9 (Mythic Engine 3.0) the game runs in a process
/// Wine starts, and in it the constructor found none of Anvil's settings — on 1 October
/// LEGO Star Wars ran two sessions on it with no pacing and not one frame counted, while
/// the parts of the library that read their settings later (audio, thread priority)
/// worked. So the settings are read at the first moment they are there — the constructor,
/// the game's first new thread, its first frame — and the hooks go in at the first moment
/// CAMetalLayer exists.
extern "C" void anvil_ensure_setup(const char* where) {
    installLayerHooks();
    if (g_settingsRead.load()) return;
    if (!getenv("ANVIL_LOG") && !getenv("ANVIL_HOOK_ENABLED")) return;   // not there yet
    static std::mutex lock;
    std::lock_guard<std::mutex> guard(lock);
    if (g_settingsRead.load()) return;
    readEnvironment();
    g_settingsRead = true;
    // Where the game read its data, kept for the memory warm-up when it quits too (anvil_io.mm).
    if (getenv("ANVIL_WARM_STATE")) atexit(+[] { AnvilReadHeatSave(); });
    os_log(OS_LOG_DEFAULT, "[anvil] injected");
    diag("[anvil] injected into pid %d (%s), frameGen=%d renderScale=%.3f sharpness=%.2f",
         getpid(), where, g_frameGen, g_renderScale, g_sharpness);
}

/// Called when the game first opens Metal (anvil_guard.mm interposes the calls that do):
/// Anvil's shaders start compiling then, in the background, rather than at the game's first
/// frame — so a cold compile is spent while the game is still loading. Once per process,
/// and only where the interceptor is on.
extern "C" void AnvilWarmShaders(id<MTLDevice> device) {
    if (!device) return;
    anvil_ensure_setup("Metal device");
    if (!g_settingsRead.load() || !g_enabled || g_ready) return;
    bool expected = false;
    if (!g_warmStarted.compare_exchange_strong(expected, true)) return;
    [device retain];
    g_warmDone = dispatch_semaphore_create(0);
    dispatch_semaphore_t done = g_warmDone;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        ShaderSet* set = buildShaderSet(device);
        [device release];
        g_warmSet.store(set);
        dispatch_semaphore_signal(done);
    });
}

#ifndef ANVIL_INJECT_TEST
__attribute__((constructor))
static void anvil_init() {
    anvil_ensure_setup("at load");
}
#endif

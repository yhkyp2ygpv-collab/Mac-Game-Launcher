// Surround sound on a stereo Mac.
//
// Some Windows games always mix in surround and leave the fold-down to Windows. LEGO Star
// Wars: The Skywalker Saga reads the output's format and, when it is stereo, creates its
// XAudio2 mastering voice with eight channels anyway (7.1 — `cmp channels, 2 / ja /
// mov channels, 8` in the game's audio setup). Windows' audio engine folds that into the
// headphones or speakers. Characters' voices are on the centre channel of the mix.
//
// Wine's CoreAudio driver hands the game's stream to a HAL output unit as it is: eight
// interleaved channels in, no channel layout. On a stereo output CoreAudio plays the
// first two and drops the rest. Measured with AudioConverter, which the output unit
// uses: 8-to-2 keeps input channels 1 and 2 at full level and gives exact silence for 3
// to 8, with or without channel layouts set. So in LEGO every line of dialogue, the
// surrounds and the LFE were silent while the music, which sits in the front pair, played.
//
// This does what Windows would. When Wine's driver gives an output unit a stream wider
// than a stereo or mono output, the unit is given the output's own channel count, and
// Wine's render callback is wrapped: Wine fills a buffer at the game's width, and the
// wrapper folds it into the output with the usual coefficients — centre and surrounds at
// −3 dB into both sides, LFE left out, as XAudio2's and Windows' own fold-downs do.
// Any other stream, and any call that does not come from Wine's driver, passes through.
//
// 3D sound (ANVIL_SPATIAL=1). Folding a 7.1 mix into two channels keeps every sound, but puts
// them all between the ears. Apple's spatial mixer (AUSpatialMixer) places each channel of the
// mix where its speaker would be, around the listener, and renders that for what is listening:
// binaural for headphones and earbuds (with the player's personalized spatial audio where it is
// set up, and AirPods' head tracking if asked for), Apple's own virtualization for a Mac's
// built-in speakers, external stereo speakers, or a real surround system, each channel to its
// own speaker. And so that a game has a surround mix to place — most mix to whatever Windows
// says the output plays — Wine's driver is told a stereo output plays 7.1 (ANVIL_SURROUND_MIX).
//
// Anvil Surround (ANVIL_UPMIX, anvil_upmix.h). Some games mix in stereo whatever they're told, and
// some put their stereo in a 7.1 mix's front pair and leave the rest silent: 3D sound would then
// have only two speakers ahead to place. A stereo stream is split into 7.1 (5.1 on a 5.1 system)
// before the mixer — what the two sides share and is panned to the middle to the centre, what
// they don't share (the room) beside and behind — and a 5.1 or 7.1 stream is watched: once its
// front pair has played for 4 s with every other channel exactly silent, its front pair is split
// the same way, with the game's own channels still passed on; the first sound the game puts in
// any other channel hands the mix back to the game for good.

#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/CoreAudio.h>
#import <dlfcn.h>
#import <dispatch/dispatch.h>
#import <os/lock.h>
#import <algorithm>
#import <atomic>
#import <cmath>
#import <cstdarg>
#import <cstdint>
#import <cstdio>
#import <cstdlib>
#import <cstring>
#import <cctype>
#import <initializer_list>
#import <new>
#import "anvil_upmix.h"

namespace anvil_audio {
namespace {

// What the wrapper needs from CoreAudio, behind pointers so the test can stand in for it.
struct Backend {
    OSStatus (*setProperty)(AudioUnit, AudioUnitPropertyID, AudioUnitScope, AudioUnitElement,
                            const void*, UInt32);
    OSStatus (*getProperty)(AudioUnit, AudioUnitPropertyID, AudioUnitScope, AudioUnitElement,
                            void*, UInt32*);
    OSStatus (*dispose)(AudioComponentInstance);
    UInt32 (*deviceChannels)(AudioDeviceID);
    UInt32 (*deviceTransport)(AudioDeviceID);
    bool (*fromWine)(const void* returnAddress);
    // 3D sound: which of a built-in device's outputs is in use ('ispk', 'hdpn'), its name, and
    // the property calls Wine's driver makes (passed through unless answered for 3D sound).
    UInt32 (*dataSource)(AudioDeviceID);
    bool (*deviceName)(AudioDeviceID, char*, size_t);
    OSStatus (*objectGetSize)(AudioObjectID, const AudioObjectPropertyAddress*, UInt32, const void*, UInt32*);
    OSStatus (*objectGet)(AudioObjectID, const AudioObjectPropertyAddress*, UInt32, const void*, UInt32*, void*);
};

[[maybe_unused]] UInt32 realDeviceChannels(AudioDeviceID device) {
    AudioObjectPropertyAddress address = {kAudioDevicePropertyStreamConfiguration,
                                          kAudioDevicePropertyScopeOutput, kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(device, &address, 0, nullptr, &size) != noErr || size < sizeof(AudioBufferList))
        return 0;
    auto* list = static_cast<AudioBufferList*>(malloc(size));
    if (!list) return 0;
    UInt32 channels = 0;
    if (AudioObjectGetPropertyData(device, &address, 0, nullptr, &size, list) == noErr) {
        for (UInt32 i = 0; i < list->mNumberBuffers; ++i) channels += list->mBuffers[i].mNumberChannels;
    }
    free(list);
    return channels;
}

[[maybe_unused]] UInt32 realDeviceTransport(AudioDeviceID device) {
    AudioObjectPropertyAddress address = {kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal,
                                          kAudioObjectPropertyElementMain};
    UInt32 transport = 0, size = sizeof(transport);
    if (AudioObjectGetPropertyData(device, &address, 0, nullptr, &size, &transport) != noErr) return 0;
    return transport;
}

[[maybe_unused]] UInt32 realDataSource(AudioDeviceID device) {
    AudioObjectPropertyAddress address = {kAudioDevicePropertyDataSource, kAudioDevicePropertyScopeOutput,
                                          kAudioObjectPropertyElementMain};
    UInt32 source = 0, size = sizeof(source);
    if (AudioObjectGetPropertyData(device, &address, 0, nullptr, &size, &source) != noErr) return 0;
    return source;
}

[[maybe_unused]] bool realDeviceName(AudioDeviceID device, char* out, size_t room) {
    AudioObjectPropertyAddress address = {kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal,
                                          kAudioObjectPropertyElementMain};
    CFStringRef name = nullptr;
    UInt32 size = sizeof(name);
    if (AudioObjectGetPropertyData(device, &address, 0, nullptr, &size, &name) != noErr || !name) return false;
    const bool ok = CFStringGetCString(name, out, static_cast<CFIndex>(room), kCFStringEncodingUTF8);
    CFRelease(name);
    return ok;
}

// Only Wine's own CoreAudio driver is steered; Apple's frameworks and anything else in
// the process that sets up an output unit is left alone.
[[maybe_unused]] bool realFromWine(const void* returnAddress) {
    Dl_info info;
    if (!dladdr(returnAddress, &info) || !info.dli_fname) return false;
    return strstr(info.dli_fname, "winecoreaudio") != nullptr;
}

#ifndef ANVIL_AUDIO_TEST
Backend g_backend = {&AudioUnitSetProperty, &AudioUnitGetProperty, &AudioComponentInstanceDispose,
                     &realDeviceChannels, &realDeviceTransport, &realFromWine,
                     &realDataSource, &realDeviceName, &AudioObjectGetPropertyDataSize, &AudioObjectGetPropertyData};
#else
Backend g_backend = {};
#endif

std::atomic<int> g_state{-1};              // -1 unread, 0 off, 1 on

bool enabled() {
    int s = g_state.load(std::memory_order_relaxed);
    if (s < 0) {
        const char* e = getenv("ANVIL_AUDIO_FOLD");
        s = (e && e[0] == '0') ? 0 : 1;
        g_state.store(s, std::memory_order_relaxed);
    }
    return s == 1;
}

// --- 3D sound: settings and who is listening ------------------------------------------------

/// Read at each stream's setup, never on CoreAudio's thread: ANVIL_SPATIAL=1 renders in 3D;
/// ANVIL_SPATIAL_OUTPUT says what is listening (auto, headphones, speakers); ANVIL_SPATIAL_HEAD=1
/// follows AirPods' head tracking; ANVIL_SURROUND_MIX=0 keeps games' own stereo mix.
bool spatialWanted() { const char* e = getenv("ANVIL_SPATIAL"); return e && e[0] == '1'; }
bool surroundMixWanted() {
    const char* e = getenv("ANVIL_SURROUND_MIX");
    return spatialWanted() && !(e && e[0] == '0');
}
bool headTrackingWanted() { const char* e = getenv("ANVIL_SPATIAL_HEAD"); return e && e[0] == '1'; }
bool upmixWanted() {
    const char* e = getenv("ANVIL_UPMIX");
    return spatialWanted() && !(e && e[0] == '0');
}

enum class Listener : uint8_t { headphones, builtInSpeakers, externalSpeakers, surround };

const char* listenerName(Listener l) {
    switch (l) {
    case Listener::headphones: return "headphones";
    case Listener::builtInSpeakers: return "this Mac's built-in speakers";
    case Listener::externalSpeakers: return "external speakers";
    case Listener::surround: return "a surround system";
    }
    return "the output";
}

/// What a device name says it is, lower-cased: something worn, or something across the room.
bool nameHas(const char* name, std::initializer_list<const char*> words) {
    char lower[256];
    size_t i = 0;
    for (; name[i] && i + 1 < sizeof lower; ++i) lower[i] = static_cast<char>(tolower(static_cast<unsigned char>(name[i])));
    lower[i] = 0;
    for (const char* w : words) if (strstr(lower, w)) return true;
    return false;
}

/// Who is listening to `device`, which plays `channels`: the player's choice, else what the
/// device says — the headphone jack or the speakers of a built-in output (on Apple silicon the
/// jack can be a device of its own, "External Headphones"), a Bluetooth device worn unless its
/// name says speaker, a USB one across the room unless its name says headset.
Listener listenerFor(AudioDeviceID device, UInt32 transport, UInt32 channels) {
    if (channels > 2) return Listener::surround;
    const char* force = getenv("ANVIL_SPATIAL_OUTPUT");
    if (force && !strcmp(force, "headphones")) return Listener::headphones;
    char name[256] = "";
    if (g_backend.deviceName) g_backend.deviceName(device, name, sizeof name);
    const bool builtIn = transport == kAudioDeviceTransportTypeBuiltIn;
    if (force && !strcmp(force, "speakers"))
        return builtIn ? Listener::builtInSpeakers : Listener::externalSpeakers;
    switch (transport) {
    case kAudioDeviceTransportTypeBuiltIn: {
        const UInt32 source = g_backend.dataSource ? g_backend.dataSource(device) : 0;
        return source == 'hdpn' || nameHas(name, {"headphone"}) ? Listener::headphones : Listener::builtInSpeakers;
    }
    case kAudioDeviceTransportTypeBluetooth:
    case kAudioDeviceTransportTypeBluetoothLE:
        return nameHas(name, {"speaker", "soundlink", "boom", "jbl flip", "jbl charge", "homepod", "echo", "sonos", "soundbar"})
                   ? Listener::externalSpeakers : Listener::headphones;
    case kAudioDeviceTransportTypeUSB:
        return nameHas(name, {"headset", "headphone", "earphone", "buds", "airpods", "arctis", "hyperx", "cloud", "blackshark",
                              "kraken", "g pro", "astro", "virtuoso", "void"})
                   ? Listener::headphones : Listener::externalSpeakers;
    default:
        return Listener::externalSpeakers;
    }
}

void note(const char* fmt, ...) __attribute__((format(printf, 1, 2)));
void note(const char* fmt, ...) {
    const char* path = getenv("ANVIL_LOG");
    if (!path) return;
    FILE* f = fopen(path, "a");
    if (!f) return;
    fputs("[anvil] audio: ", f);
    va_list args;
    va_start(args, fmt);
    vfprintf(f, fmt, args);
    va_end(args);
    fputc('\n', f);
    fclose(f);
}

const char* layoutName(UInt32 channels) {
    switch (channels) {
    case 2: return "stereo";
    case 3: return "2.1";
    case 4: return "quadraphonic";
    case 5: return "4.1";
    case 6: return "5.1";
    case 7: return "6.1";
    case 8: return "7.1";
    default: return "surround";
    }
}

const char* transportName(UInt32 transport) {
    switch (transport) {
    case kAudioDeviceTransportTypeBuiltIn: return "built-in speakers or headphone jack";
    case kAudioDeviceTransportTypeBluetooth:
    case kAudioDeviceTransportTypeBluetoothLE: return "Bluetooth";
    case kAudioDeviceTransportTypeUSB: return "USB";
    case kAudioDeviceTransportTypeHDMI: return "HDMI";
    case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort";
    case kAudioDeviceTransportTypeAirPlay: return "AirPlay";
    case kAudioDeviceTransportTypeThunderbolt: return "Thunderbolt";
    case kAudioDeviceTransportTypeVirtual: return "virtual device";
    case kAudioDeviceTransportTypeAggregate: return "aggregate device";
    default: return "output";
    }
}

// Left and right weight of each input channel, in the order Windows gives that many
// channels — the default WAVEFORMATEXTENSIBLE masks, which both Wine's driver and FAudio
// write. Three channels are 2.1, where dropping the LFE is already all a fold-down does.
// A mono output plays the average of the two sides; unfolded it would get only the left.
constexpr float k3dB = 0.70710678f;

struct Matrix { float left[8]; float right[8]; };

bool matrixFor(UInt32 channels, Matrix& m) {
    const float k = k3dB;
    switch (channels) {
    case 2: m = {{1, 0}, {0, 1}}; return true;                                              // FL FR, for mono
    case 4: m = {{1, 0, k, 0}, {0, 1, 0, k}}; return true;                                  // FL FR BL BR
    case 5: m = {{1, 0, 0, k, 0}, {0, 1, 0, 0, k}}; return true;                            // FL FR LFE BL BR
    case 6: m = {{1, 0, k, 0, k, 0}, {0, 1, k, 0, 0, k}}; return true;                      // FL FR FC LFE BL BR
    case 7: m = {{1, 0, k, 0, k, 0, 0.5f}, {0, 1, k, 0, 0, k, 0.5f}}; return true;          // … BC
    case 8: m = {{1, 0, k, 0, k, 0, k, 0}, {0, 1, k, 0, 0, k, 0, k}}; return true;          // … SL SR
    default: return false;
    }
}

enum class Sample : uint8_t { f32, s16, s32 };

inline float toFloat(float v) { return v; }
inline float toFloat(int16_t v) { return v * (1.0f / 32768.0f); }
inline float toFloat(int32_t v) { return static_cast<float>(v * (1.0 / 2147483648.0)); }

template <typename T> T fromFloat(float v);
template <> inline float fromFloat<float>(float v) { return v; }
template <> inline int16_t fromFloat<int16_t>(float v) {
    return static_cast<int16_t>(lrintf(std::min(std::max(v, -1.0f), 1.0f) * 32767.0f));
}
template <> inline int32_t fromFloat<int32_t>(float v) {
    return static_cast<int32_t>(llrint(std::min(std::max(static_cast<double>(v), -1.0), 1.0) * 2147483647.0));
}

template <typename T>
void foldFrames(const Matrix& m, UInt32 inChannels, UInt32 outChannels, const void* src, void* dst,
                UInt32 frames) noexcept [[clang::nonblocking]] {
    const T* in = static_cast<const T*>(src);
    T* out = static_cast<T*>(dst);
    for (UInt32 i = 0; i < frames; ++i, in += inChannels) {
        float left = 0.0f, right = 0.0f;
        for (UInt32 c = 0; c < inChannels; ++c) {
            const float s = toFloat(in[c]);
            left += m.left[c] * s;
            right += m.right[c] * s;
        }
        if (outChannels == 2) {
            *out++ = fromFloat<T>(left);
            *out++ = fromFloat<T>(right);
        } else {
            *out++ = fromFloat<T>(0.5f * (left + right));
        }
    }
}

// One output unit Wine's driver gave a stream wider than stereo, or stereo on a mono output.
struct Stream {
    AudioUnit unit = nullptr;
    AudioStreamBasicDescription asked = {};   // the game's own format, as Wine set it
    bool folding = false;                     // the unit was given the output's width
    UInt32 outputChannels = 0;
    UInt32 transport = 0;
    const char* reason = nullptr;             // why a wide stream is left as it is

    // Fixed before the unit starts; read on CoreAudio's I/O thread.
    Matrix matrix = {};
    Sample sample = Sample::f32;
    UInt32 inChannels = 0, outChannels = 0, bytesPerSample = 0, capacityFrames = 0;
    uint8_t* scratch = nullptr;
    AURenderCallback wineProc = nullptr;
    void* wineRefCon = nullptr;
    bool wrapped = false;                     // foldRender is the unit's callback
    bool reported = false;

    std::atomic<bool> stale{false};           // format set again after the wrap: pass through
    std::atomic<uint64_t> frames{0};
    std::atomic<uint64_t> odd{0};             // buffers in a shape neither side asked for: silence

    // Drop-outs (see noteDropouts). Read and written on CoreAudio's I/O thread only.
    float lastPeak = 0.0f;                    // the loudest channel of the last frame with sound
    UInt32 zeroRun = 0;                       // frames of exact silence since then
    bool cutFromSound = false;                // that silence began straight after sound

    // 3D sound (makeSpatial): Apple's spatial mixer between Wine and the output, which is given
    // the mixer's output as float. Set up before the unit starts.
    bool spatial = false;
    Listener listener = Listener::headphones;
    AudioUnit mixer = nullptr;
    float* mixOut = nullptr;                  // outChannels planes of capacityFrames
    float* mixIn = nullptr;                   // inChannels planes, should the mixer give no buffer
    bool personalized = false;                // the mixer said it uses the player's own spatial audio
    bool headTracked = false;
    bool spatialFailed = false;               // 3D sound was wanted and its mixer wouldn't start
    char deviceName[96] = "";

    // Anvil Surround. `bed` is the mixer's input width: the game's own, or 8 (6 on a 5.1 system)
    // for a stereo stream made surround.
    enum class Upmix : uint8_t { off, stereo, watching };
    Upmix upmix = Upmix::off;
    UInt32 bed = 0;
    anvil_upmix::Upmixer* upmixer = nullptr;
    float* upOut = nullptr;                   // watching: the split of the front pair, bed planes
    // Watching a 5.1 or 7.1 stream (I/O thread): frames of sound in the front pair alone, and how
    // far the front pair has been handed to the split (0 the game's own, 1 the split).
    uint64_t frontOnlyFrames = 0;
    float blend = 0.0f;
    std::atomic<int> watch{0};                // 0 deciding, 1 front pair only: split, 2 the game's own surround
    std::atomic<bool> wasSplit{false};        // the front pair was split at some point
    int watchSaid = 0;                        // the last of those the log was told (timer thread)
    Stream* next = nullptr;
};

os_unfair_lock g_lock = OS_UNFAIR_LOCK_INIT;
Stream* g_streams = nullptr;                  // under g_lock
std::atomic<int> g_reports{0};

struct Locked {
    Locked() { os_unfair_lock_lock(&g_lock); }
    ~Locked() { os_unfair_lock_unlock(&g_lock); }
};

Stream* find(AudioUnit unit) {
    for (Stream* s = g_streams; s; s = s->next)
        if (s->unit == unit) return s;
    return nullptr;
}

Stream* detach(AudioUnit unit) {
    for (Stream** p = &g_streams; *p; p = &(*p)->next) {
        if ((*p)->unit == unit) {
            Stream* s = *p;
            *p = s->next;
            s->next = nullptr;
            return s;
        }
    }
    return nullptr;
}

void release(Stream* s) {
    if (!s) return;
    if (s->mixer) {
        AudioUnitUninitialize(s->mixer);
        AudioComponentInstanceDispose(s->mixer);
    }
    free(s->mixOut);
    free(s->mixIn);
    free(s->scratch);
    free(s->upOut);
    delete s->upmixer;
    delete s;
}

// Drop-outs: the game's sound arriving too late for the output. Wine's driver hands the output
// what the game has written and fills the rest with exact silence, so a late buffer is heard
// as sound cut off dead — no fade, every channel at exactly zero — and back a moment later.
// Sound that ends in a game fades, or has music and ambience under it. So a run of exact
// silence, at least 32 frames long and under a quarter of a second, that starts straight
// after a frame with sound in it (a channel past 2%) and ends with sound again is counted.
// On 11 October the player heard LEGO Star Wars' dialogue go choppy now and then: these say
// whether the whole mix dropped out (here) or the game's own voice stream (nothing here).
std::atomic<uint64_t> g_dropouts{0};
std::atomic<uint64_t> g_droppedFrames{0};

template <typename T>
void noteDropouts(Stream* s, const void* src, UInt32 frames, double rate) noexcept [[clang::nonblocking]] {
    const T* in = static_cast<const T*>(src);
    const UInt32 longest = static_cast<UInt32>(rate * 0.25);
    for (UInt32 i = 0; i < frames; ++i, in += s->inChannels) {
        float peak = 0.0f;
        bool silent = true;
        for (UInt32 c = 0; c < s->inChannels; ++c) {
            if (in[c] != T(0)) silent = false;
            peak = std::max(peak, std::fabs(toFloat(in[c])));
        }
        if (silent) {
            if (s->zeroRun == 0) s->cutFromSound = s->lastPeak > 0.02f;
            if (s->zeroRun < UINT32_MAX) ++s->zeroRun;
            continue;
        }
        if (s->zeroRun > 0) {
            if (s->cutFromSound && s->zeroRun >= 32 && s->zeroRun <= longest) {
                g_dropouts.fetch_add(1, std::memory_order_relaxed);
                g_droppedFrames.fetch_add(s->zeroRun, std::memory_order_relaxed);
            }
            s->zeroRun = 0;
        }
        s->lastPeak = peak;
    }
}

// --- 3D sound: the mixer between Wine and the output ------------------------------------------

/// The game's channels in Windows' order — the default WAVEFORMATEXTENSIBLE masks, as Wine's
/// driver and FAudio write them — as positions around the listener. A 7.1 mix's back pair is
/// behind (CoreAudio's rear surrounds), its side pair beside (its surrounds); 5.1's and quad's
/// one pair of surrounds are where 5.1's are.
bool windowsLabels(UInt32 channels, AudioChannelLabel out[8]) {
    switch (channels) {
    case 1: out[0] = kAudioChannelLabel_Center; return true;
    case 2: out[0] = kAudioChannelLabel_Left; out[1] = kAudioChannelLabel_Right; return true;
    case 3: out[0] = kAudioChannelLabel_Left; out[1] = kAudioChannelLabel_Right; out[2] = kAudioChannelLabel_LFEScreen; return true;
    case 4: { const AudioChannelLabel l[4] = {kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_LeftSurround,
                                               kAudioChannelLabel_RightSurround};
              memcpy(out, l, sizeof l); return true; }
    case 5: { const AudioChannelLabel l[5] = {kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_LFEScreen,
                                               kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround};
              memcpy(out, l, sizeof l); return true; }
    case 6: { const AudioChannelLabel l[6] = {kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_Center,
                                               kAudioChannelLabel_LFEScreen, kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround};
              memcpy(out, l, sizeof l); return true; }
    case 7: { const AudioChannelLabel l[7] = {kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_Center,
                                               kAudioChannelLabel_LFEScreen, kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround,
                                               kAudioChannelLabel_CenterSurround};
              memcpy(out, l, sizeof l); return true; }
    case 8: { const AudioChannelLabel l[8] = {kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_Center,
                                               kAudioChannelLabel_LFEScreen, kAudioChannelLabel_RearSurroundLeft,
                                               kAudioChannelLabel_RearSurroundRight, kAudioChannelLabel_LeftSurround,
                                               kAudioChannelLabel_RightSurround};
              memcpy(out, l, sizeof l); return true; }
    default: return false;
    }
}

/// A layout of channel descriptions, malloc'd; nil for a width Windows has no default for.
AudioChannelLayout* layoutFor(const AudioChannelLabel* labels, UInt32 channels, UInt32* size) {
    *size = static_cast<UInt32>(offsetof(AudioChannelLayout, mChannelDescriptions) + channels * sizeof(AudioChannelDescription));
    auto* layout = static_cast<AudioChannelLayout*>(calloc(1, *size));
    if (!layout) return nullptr;
    layout->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
    layout->mNumberChannelDescriptions = channels;
    for (UInt32 i = 0; i < channels; ++i) layout->mChannelDescriptions[i].mChannelLabel = labels[i];
    return layout;
}

/// The output's own speaker layout, for a surround system: nil if it won't say.
AudioChannelLayout* deviceLayout(AudioDeviceID device, UInt32* size) {
    if (!g_backend.objectGetSize || !g_backend.objectGet) return nullptr;
    AudioObjectPropertyAddress address = {kAudioDevicePropertyPreferredChannelLayout, kAudioDevicePropertyScopeOutput,
                                          kAudioObjectPropertyElementMain};
    if (g_backend.objectGetSize(device, &address, 0, nullptr, size) != noErr || *size < sizeof(AudioChannelLayout)) return nullptr;
    auto* layout = static_cast<AudioChannelLayout*>(malloc(*size));
    if (!layout) return nullptr;
    if (g_backend.objectGet(device, &address, 0, nullptr, size, layout) != noErr) { free(layout); return nullptr; }
    return layout;
}

template <typename T>
void deinterleave(const void* src, UInt32 channels, UInt32 frames, AudioBufferList* io) noexcept [[clang::nonblocking]] {
    const T* in = static_cast<const T*>(src);
    const UInt32 planes = std::min(channels, io->mNumberBuffers);
    for (UInt32 c = 0; c < planes; ++c) {
        float* dst = static_cast<float*>(io->mBuffers[c].mData);
        if (!dst) continue;
        for (UInt32 i = 0; i < frames; ++i) dst[i] = toFloat(in[static_cast<size_t>(i) * channels + c]);
    }
}

/// A 5.1 or 7.1 stream, watched for sound in its front pair alone (on CoreAudio's I/O thread):
/// once that pair has played for 4 s with every other channel exactly silent, it is crossfaded
/// over 50 ms to the split of that pair, the game's own other channels still added in; the first
/// sound in any of them (past −80 dB) fades the split out for the rest of the stream.
void watchFrontPair(Stream* s, AudioBufferList* io, UInt32 frames) noexcept [[clang::nonblocking]] {
    int state = s->watch.load(std::memory_order_relaxed);
    if (state == 2 && s->blend == 0.0f) return;
    const UInt32 bed = s->bed;
    float* p[8];
    float* up[8];
    for (UInt32 c = 0; c < bed; ++c) {
        p[c] = static_cast<float*>(io->mBuffers[c].mData);
        up[c] = s->upOut + static_cast<size_t>(c) * s->capacityFrames;
    }
    const double rate = s->asked.mSampleRate > 0 ? s->asked.mSampleRate : 48000.0;
    if (state != 2) {
        float rest = 0.0f, front = 0.0f, m = 0.0f;
        for (UInt32 c = 2; c < bed; ++c) { vDSP_maxmgv(p[c], 1, &m, frames); rest = std::max(rest, m); }
        if (rest > 1e-4f) {
            state = 2;
            s->watch.store(2, std::memory_order_relaxed);
        } else {
            vDSP_maxmgv(p[0], 1, &m, frames); front = m;
            vDSP_maxmgv(p[1], 1, &m, frames); front = std::max(front, m);
            if (front > 1e-3f) s->frontOnlyFrames += frames;
            if (state == 0 && s->frontOnlyFrames >= static_cast<uint64_t>(4.0 * rate)) {
                state = 1;
                s->watch.store(1, std::memory_order_relaxed);
                s->wasSplit.store(true, std::memory_order_relaxed);
            }
        }
    }
    // The split runs from the start, so it has its 512 samples in hand when it is needed.
    s->upmixer->process(p[0], p[1], frames, up);
    const float target = state == 1 ? 1.0f : 0.0f;
    if (s->blend == 0.0f && target == 0.0f) return;
    const float step = static_cast<float>(1.0 / (0.05 * rate));
    for (UInt32 i = 0; i < frames; ++i) {
        s->blend = target > s->blend ? std::min(target, s->blend + step) : std::max(target, s->blend - step);
        const float g = s->blend;
        p[0][i] = (1.0f - g) * p[0][i] + g * up[0][i];
        p[1][i] = (1.0f - g) * p[1][i] + g * up[1][i];
        for (UInt32 c = 2; c < bed; ++c) p[c][i] += g * up[c][i];
    }
}

/// The mixer's input, on CoreAudio's I/O thread: Wine's next frames, as the game wrote them, into
/// the mixer's planes — or, for Anvil Surround, the stereo the game wrote, split into surround.
OSStatus spatialInput(void* refCon, AudioUnitRenderActionFlags* flags, const AudioTimeStamp* ts, UInt32,
                      UInt32 frames, AudioBufferList* io) noexcept [[clang::nonblocking]] {
    Stream* s = static_cast<Stream*>(refCon);
    if (!io || io->mNumberBuffers != s->bed || frames > s->capacityFrames || !s->scratch) {
        for (UInt32 b = 0; io && b < io->mNumberBuffers; ++b)
            if (io->mBuffers[b].mData) memset(io->mBuffers[b].mData, 0, io->mBuffers[b].mDataByteSize);
        return noErr;
    }
    for (UInt32 c = 0; c < io->mNumberBuffers; ++c) {
        if (!io->mBuffers[c].mData) io->mBuffers[c].mData = s->mixIn + static_cast<size_t>(c) * s->capacityFrames;
        io->mBuffers[c].mDataByteSize = frames * sizeof(float);
    }
    AudioBufferList wine;
    wine.mNumberBuffers = 1;
    wine.mBuffers[0].mNumberChannels = s->inChannels;
    wine.mBuffers[0].mDataByteSize = frames * s->inChannels * s->bytesPerSample;
    wine.mBuffers[0].mData = s->scratch;
    const OSStatus status = s->wineProc(s->wineRefCon, flags, ts, 0, frames, &wine);
    if (status != noErr) {
        for (UInt32 c = 0; c < io->mNumberBuffers; ++c) memset(io->mBuffers[c].mData, 0, io->mBuffers[c].mDataByteSize);
        return status;
    }
    const double rate = s->asked.mSampleRate > 0 ? s->asked.mSampleRate : 48000.0;
    switch (s->sample) {
    case Sample::f32: noteDropouts<float>(s, s->scratch, frames, rate); deinterleave<float>(s->scratch, s->inChannels, frames, io); break;
    case Sample::s16: noteDropouts<int16_t>(s, s->scratch, frames, rate); deinterleave<int16_t>(s->scratch, s->inChannels, frames, io); break;
    case Sample::s32: noteDropouts<int32_t>(s, s->scratch, frames, rate); deinterleave<int32_t>(s->scratch, s->inChannels, frames, io); break;
    }
    if (s->upmix == Stream::Upmix::stereo) {
        float* planes[8];
        for (UInt32 c = 0; c < s->bed; ++c) planes[c] = static_cast<float*>(io->mBuffers[c].mData);
        s->upmixer->process(planes[0], planes[1], frames, planes);
    } else if (s->upmix == Stream::Upmix::watching) {
        watchFrontPair(s, io, frames);
    }
    return noErr;
}

/// The output unit's callback with 3D sound, on CoreAudio's I/O thread: the mixer rendered,
/// pulling Wine through spatialInput, into the unit's interleaved float.
OSStatus spatialRender(void* refCon, AudioUnitRenderActionFlags* flags, const AudioTimeStamp* ts, UInt32 bus,
                       UInt32 frames, AudioBufferList* io) noexcept [[clang::nonblocking]] {
    Stream* s = static_cast<Stream*>(refCon);
    if (s->stale.load(std::memory_order_relaxed)) return s->wineProc(s->wineRefCon, flags, ts, bus, frames, io);
    const bool expected = io && io->mNumberBuffers == 1 && io->mBuffers[0].mNumberChannels == s->outChannels
                       && io->mBuffers[0].mData && s->capacityFrames;
    float* out = expected ? static_cast<float*>(io->mBuffers[0].mData) : nullptr;
    const UInt32 room = expected ? std::min(frames, io->mBuffers[0].mDataByteSize / (s->outChannels * static_cast<UInt32>(sizeof(float)))) : 0;
    struct { UInt32 count; AudioBuffer buffers[8]; } planes;
    AudioTimeStamp at = ts ? *ts : AudioTimeStamp{};
    UInt32 done = 0;
    while (done < frames && s->capacityFrames) {
        const UInt32 n = std::min(frames - done, s->capacityFrames);
        planes.count = s->outChannels;
        for (UInt32 c = 0; c < s->outChannels; ++c)
            planes.buffers[c] = {1, n * static_cast<UInt32>(sizeof(float)), s->mixOut + static_cast<size_t>(c) * s->capacityFrames};
        AudioUnitRenderActionFlags mixFlags = 0;
        if (AudioUnitRender(s->mixer, &mixFlags, &at, 0, n, reinterpret_cast<AudioBufferList*>(&planes)) != noErr) break;
        if (done < room) {
            const UInt32 m = std::min(n, room - done);
            for (UInt32 i = 0; i < m; ++i)
                for (UInt32 c = 0; c < s->outChannels; ++c)
                    out[static_cast<size_t>(done + i) * s->outChannels + c] = s->mixOut[static_cast<size_t>(c) * s->capacityFrames + i];
        }
        done += n;
        at.mSampleTime += n;
    }
    if (!expected) {
        s->odd.fetch_add(1, std::memory_order_relaxed);
        for (UInt32 b = 0; io && b < io->mNumberBuffers; ++b)
            if (io->mBuffers[b].mData) memset(io->mBuffers[b].mData, 0, io->mBuffers[b].mDataByteSize);
    } else {
        const size_t used = static_cast<size_t>(std::min(done, room)) * s->outChannels * sizeof(float);
        if (io->mBuffers[0].mDataByteSize > used) memset(reinterpret_cast<uint8_t*>(out) + used, 0, io->mBuffers[0].mDataByteSize - used);
    }
    s->frames.fetch_add(frames, std::memory_order_relaxed);
    return noErr;
}

/// Apple's spatial mixer for a stream, before its unit starts: the game's channels as a bed of
/// speakers around the listener (or, on a surround system with as many speakers, each to its
/// own), rendered for who is listening. False, with nothing left behind, if any of it fails —
/// the stream is then folded or left as before.
bool makeSpatial(Stream* s, AudioDeviceID device, UInt32 maxFrames) {
    // Anvil Surround first: without its split, a stereo stream is placed as the stereo it is.
    if (s->upmix != Stream::Upmix::off) {
        s->upmixer = new (std::nothrow) anvil_upmix::Upmixer;
        if (!s->upmixer || !s->upmixer->init(s->asked.mSampleRate, s->bed)) {
            delete s->upmixer;
            s->upmixer = nullptr;
            s->upmix = Stream::Upmix::off;
            s->bed = s->inChannels;
        }
    }
    AudioChannelLabel labels[8];
    if (!windowsLabels(s->bed, labels)) return false;
    const AudioComponentDescription d = {kAudioUnitType_Mixer, kAudioUnitSubType_SpatialMixer, kAudioUnitManufacturer_Apple, 0, 0};
    AudioComponent component = AudioComponentFindNext(nullptr, &d);
    AudioUnit m = nullptr;
    if (!component || AudioComponentInstanceNew(component, &m) != noErr || !m) return false;
    const UInt32 capacity = std::max<UInt32>(4096, std::min<UInt32>(maxFrames, 65536));
    bool ok = true;
    auto set = [&](AudioUnitPropertyID id, AudioUnitScope scope, const void* data, UInt32 size) {
        if (ok && AudioUnitSetProperty(m, id, scope, 0, data, size) != noErr) ok = false;
    };
    const Float64 rate = s->asked.mSampleRate > 0 ? s->asked.mSampleRate : 48000.0;
    auto planar = [&](UInt32 channels) {
        AudioStreamBasicDescription f = {};
        f.mSampleRate = rate;
        f.mFormatID = kAudioFormatLinearPCM;
        f.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved;
        f.mBytesPerPacket = f.mBytesPerFrame = sizeof(float);
        f.mFramesPerPacket = 1;
        f.mChannelsPerFrame = channels;
        f.mBitsPerChannel = 32;
        return f;
    };
    const UInt32 buses = 1;
    set(kAudioUnitProperty_ElementCount, kAudioUnitScope_Input, &buses, sizeof buses);
    const AudioStreamBasicDescription in = planar(s->bed), out = planar(s->outChannels);
    set(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, &in, sizeof in);
    set(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, &out, sizeof out);
    UInt32 size = 0;
    if (AudioChannelLayout* layout = layoutFor(labels, s->bed, &size)) {
        set(kAudioUnitProperty_AudioChannelLayout, kAudioUnitScope_Input, layout, size);
        free(layout);
    } else ok = false;
    bool bypass = false;
    if (s->listener == Listener::surround) {
        AudioChannelLayout* layout = deviceLayout(device, &size);
        if (!layout) ok = false;
        else { set(kAudioUnitProperty_AudioChannelLayout, kAudioUnitScope_Output, layout, size); free(layout); }
        bypass = s->outChannels >= s->bed;
    } else {
        AudioChannelLayout stereo = {};
        stereo.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo;
        set(kAudioUnitProperty_AudioChannelLayout, kAudioUnitScope_Output, &stereo, sizeof stereo);
    }
    const UInt32 algorithm = kSpatializationAlgorithm_UseOutputType;
    set(kAudioUnitProperty_SpatializationAlgorithm, kAudioUnitScope_Input, &algorithm, sizeof algorithm);
    const UInt32 mode = bypass ? kSpatialMixerSourceMode_Bypass : kSpatialMixerSourceMode_AmbienceBed;
    set(kAudioUnitProperty_SpatialMixerSourceMode, kAudioUnitScope_Input, &mode, sizeof mode);
    const UInt32 type = s->listener == Listener::headphones ? kSpatialMixerOutputType_Headphones
                      : s->listener == Listener::builtInSpeakers ? kSpatialMixerOutputType_BuiltInSpeakers
                                                                 : kSpatialMixerOutputType_ExternalSpeakers;
    set(kAudioUnitProperty_SpatialMixerOutputType, kAudioUnitScope_Global, &type, sizeof type);
    set(kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, &capacity, sizeof capacity);
    const AURenderCallbackStruct input = {&spatialInput, s};
    set(kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, &input, sizeof input);
    if (ok) {
        // The player's personalized spatial audio, as macOS is set; head tracking if asked for.
        // Neither is needed: a refusal leaves the generic rendering.
        const UInt32 hrtf = kSpatialMixerPersonalizedHRTFMode_Auto;
        AudioUnitSetProperty(m, kAudioUnitProperty_SpatialMixerPersonalizedHRTFMode, kAudioUnitScope_Global, 0, &hrtf, sizeof hrtf);
        if (s->listener == Listener::headphones && headTrackingWanted()) {
            const UInt32 on = 1;
            s->headTracked = AudioUnitSetProperty(m, kAudioUnitProperty_SpatialMixerEnableHeadTracking, kAudioUnitScope_Global, 0,
                                                  &on, sizeof on) == noErr;
        }
    }
    s->capacityFrames = capacity;
    s->scratch = ok ? static_cast<uint8_t*>(calloc(capacity, static_cast<size_t>(s->inChannels) * s->bytesPerSample)) : nullptr;
    s->mixOut = ok ? static_cast<float*>(calloc(static_cast<size_t>(capacity) * s->outChannels, sizeof(float))) : nullptr;
    s->mixIn = ok ? static_cast<float*>(calloc(static_cast<size_t>(capacity) * s->bed, sizeof(float))) : nullptr;
    if (ok && s->upmix == Stream::Upmix::watching)
        s->upOut = static_cast<float*>(calloc(static_cast<size_t>(capacity) * s->bed, sizeof(float)));
    if (!ok || !s->scratch || !s->mixOut || !s->mixIn || (s->upmix == Stream::Upmix::watching && !s->upOut)
        || AudioUnitInitialize(m) != noErr) {
        AudioComponentInstanceDispose(m);
        free(s->scratch); free(s->mixOut); free(s->mixIn); free(s->upOut);
        s->scratch = nullptr; s->mixOut = s->mixIn = s->upOut = nullptr; s->capacityFrames = 0;
        delete s->upmixer;
        s->upmixer = nullptr;
        return false;
    }
    UInt32 personal = 0, got = sizeof personal;
    if (AudioUnitGetProperty(m, kAudioUnitProperty_SpatialMixerAnyInputIsUsingPersonalizedHRTF, kAudioUnitScope_Global, 0,
                             &personal, &got) == noErr)
        s->personalized = personal != 0;
    s->mixer = m;
    return true;
}

// Runs on CoreAudio's I/O thread: no locks, no allocation, no logging — which the
// compiler checks, since CoreAudio declares its render callbacks nonblocking.
OSStatus foldRender(void* refCon, AudioUnitRenderActionFlags* flags, const AudioTimeStamp* ts, UInt32 bus,
                    UInt32 frames, AudioBufferList* io) noexcept [[clang::nonblocking]] {
    Stream* s = static_cast<Stream*>(refCon);
    const UInt32 shape = (io && io->mNumberBuffers == 1) ? io->mBuffers[0].mNumberChannels : UINT32_MAX;
    // The unit asks at the game's own width once its format has been put back, or set
    // again from outside: Wine fills it directly, as it would without the wrapper.
    if (s->stale.load(std::memory_order_relaxed) || shape == s->inChannels)
        return s->wineProc(s->wineRefCon, flags, ts, bus, frames, io);

    const bool expected = (shape == s->outChannels || shape == 0) && io->mBuffers[0].mData && s->capacityFrames;
    const UInt32 inFrame = s->inChannels * s->bytesPerSample;
    const UInt32 outFrame = s->outChannels * s->bytesPerSample;
    uint8_t* out = expected ? static_cast<uint8_t*>(io->mBuffers[0].mData) : nullptr;
    const UInt32 room = expected ? std::min(frames, io->mBuffers[0].mDataByteSize / outFrame) : 0;

    // Wine is asked for every frame, so the game's audio clock keeps its pace even
    // through a buffer that has to be left silent.
    OSStatus status = noErr;
    UInt32 done = 0;
    while (done < frames && s->capacityFrames) {
        const UInt32 n = std::min(frames - done, s->capacityFrames);
        AudioBufferList wine;
        wine.mNumberBuffers = 1;
        wine.mBuffers[0].mNumberChannels = s->inChannels;
        wine.mBuffers[0].mDataByteSize = n * inFrame;
        wine.mBuffers[0].mData = s->scratch;
        status = s->wineProc(s->wineRefCon, flags, ts, bus, n, &wine);
        if (status != noErr) break;
        {
            const double rate = s->asked.mSampleRate > 0 ? s->asked.mSampleRate : 48000.0;
            switch (s->sample) {
            case Sample::f32: noteDropouts<float>(s, s->scratch, n, rate); break;
            case Sample::s16: noteDropouts<int16_t>(s, s->scratch, n, rate); break;
            case Sample::s32: noteDropouts<int32_t>(s, s->scratch, n, rate); break;
            }
        }
        if (done < room) {
            const UInt32 m = std::min(n, room - done);
            uint8_t* dst = out + static_cast<size_t>(done) * outFrame;
            switch (s->sample) {
            case Sample::f32: foldFrames<float>(s->matrix, s->inChannels, s->outChannels, s->scratch, dst, m); break;
            case Sample::s16: foldFrames<int16_t>(s->matrix, s->inChannels, s->outChannels, s->scratch, dst, m); break;
            case Sample::s32: foldFrames<int32_t>(s->matrix, s->inChannels, s->outChannels, s->scratch, dst, m); break;
            }
        }
        done += n;
    }

    if (!expected) {
        s->odd.fetch_add(1, std::memory_order_relaxed);
        for (UInt32 b = 0; io && b < io->mNumberBuffers; ++b)
            if (io->mBuffers[b].mData) memset(io->mBuffers[b].mData, 0, io->mBuffers[b].mDataByteSize);
    } else {
        const size_t used = static_cast<size_t>(std::min(done, room)) * outFrame;
        if (io->mBuffers[0].mDataByteSize > used) memset(out + used, 0, io->mBuffers[0].mDataByteSize - used);
    }
    s->frames.fetch_add(frames, std::memory_order_relaxed);
    return status;
}

// Sets up a Stream for a format Wine's driver asked for, or returns null for a stream the
// output already plays in full.
Stream* plan(AudioUnit unit, const AudioStreamBasicDescription& a, bool allowSpatial = true) {
    const UInt32 channels = a.mChannelsPerFrame;
    if (a.mFormatID != kAudioFormatLinearPCM || channels < 2) return nullptr;

    AudioDeviceID device = 0;
    UInt32 size = sizeof(device);
    const bool known = g_backend.getProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                             &device, &size) == noErr && device;
    const UInt32 outputChannels = known ? g_backend.deviceChannels(device) : 0;
    // 3D sound takes every stream of up to 8 channels on an output of 2 to 8.
    const bool spatial = allowSpatial && spatialWanted() && outputChannels >= 2 && outputChannels <= 8 && channels <= 8;
    if (channels == 2 && outputChannels != 1 && !spatial) return nullptr;   // stereo on stereo, or unknown: as it was

    auto* s = new Stream;
    s->unit = unit;
    s->asked = a;
    s->inChannels = channels;
    s->outputChannels = outputChannels;
    s->transport = known ? g_backend.deviceTransport(device) : 0;
    if (!known) { s->reason = "its output could not be read"; return s; }
    if (outputChannels == 0) { s->reason = "its output's channels could not be read"; return s; }

    const bool isFloat = a.mFormatFlags & kAudioFormatFlagIsFloat;
    const bool isInt = a.mFormatFlags & kAudioFormatFlagIsSignedInteger;
    if (isFloat && a.mBitsPerChannel == 32) s->sample = Sample::f32;
    else if (isInt && a.mBitsPerChannel == 16) s->sample = Sample::s16;
    else if (isInt && a.mBitsPerChannel == 32) s->sample = Sample::s32;
    else { s->reason = "its sample format is not one the fold-down handles"; return s; }
    s->bytesPerSample = a.mBitsPerChannel / 8;
    if ((a.mFormatFlags & kAudioFormatFlagIsNonInterleaved) || a.mFramesPerPacket != 1
        || a.mBytesPerFrame != channels * s->bytesPerSample || a.mBytesPerPacket != a.mBytesPerFrame) {
        s->reason = "it is not packed and interleaved";
        return s;
    }

    if (spatial) {
        s->listener = listenerFor(device, s->transport, outputChannels);
        s->outChannels = s->listener == Listener::surround ? outputChannels : 2;
        s->bed = channels;
        if (upmixWanted() && channels == 2) {
            s->upmix = Stream::Upmix::stereo;
            s->bed = s->listener == Listener::surround && outputChannels == 6 ? 6 : 8;
        } else if (upmixWanted() && (channels == 6 || channels == 8)) {
            s->upmix = Stream::Upmix::watching;
        }
        if (g_backend.deviceName) g_backend.deviceName(device, s->deviceName, sizeof s->deviceName);
        s->spatial = true;
        s->folding = true;
        return s;
    }
    if (outputChannels >= channels) { s->reason = "the output plays that many"; return s; }
    if (outputChannels > 2) { s->reason = "the output plays more than two but fewer than the game"; return s; }
    if (!matrixFor(channels, s->matrix)) {
        s->reason = channels == 3 ? "three channels are 2.1, whose only extra is the LFE" : "no fold-down for that width";
        return s;
    }
    s->outChannels = outputChannels;
    s->folding = true;
    return s;
}

OSStatus setFormat(AudioUnit unit, const AudioStreamBasicDescription& asked, const void* data, UInt32 size) {
    auto pass = [&] {
        return g_backend.setProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, data, size);
    };
    {
        Locked l;
        if (Stream* live = find(unit)) {
            if (live->wrapped) {
                // Wine sets a unit's format once, before its callback. Should it ever
                // change on a running unit, the unit gets exactly what was asked for and
                // the wrapper steps aside.
                live->stale.store(true, std::memory_order_relaxed);
                return pass();
            }
            release(detach(unit));
        }
    }

    Stream* s = plan(unit, asked);
    if (!s) return pass();
    if (s->spatial) {
        // The mixer first; should it not start, the stream is folded or left as it would be.
        AudioDeviceID device = 0;
        UInt32 size = sizeof(device), maxFrames = 0, got = sizeof(maxFrames);
        g_backend.getProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, &size);
        if (g_backend.getProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, &got) != noErr)
            maxFrames = 0;
        bool started = makeSpatial(s, device, maxFrames);
        if (started) {
            AudioStreamBasicDescription floats = {};
            floats.mSampleRate = asked.mSampleRate;
            floats.mFormatID = kAudioFormatLinearPCM;
            floats.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
            floats.mBytesPerPacket = floats.mBytesPerFrame = s->outChannels * static_cast<UInt32>(sizeof(float));
            floats.mFramesPerPacket = 1;
            floats.mChannelsPerFrame = s->outChannels;
            floats.mBitsPerChannel = 32;
            started = g_backend.setProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &floats,
                                            sizeof(floats)) == noErr;
        }
        if (!started) {
            release(s);
            s = plan(unit, asked, false);
            if (!s) return pass();
            s->spatialFailed = true;
        }
    }
    if (s->folding && !s->spatial) {
        AudioStreamBasicDescription folded = asked;
        folded.mChannelsPerFrame = s->outChannels;
        folded.mBytesPerFrame = folded.mBytesPerPacket = s->outChannels * s->bytesPerSample;
        const OSStatus status = g_backend.setProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                                                      &folded, sizeof(folded));
        if (status != noErr) {
            s->folding = false;
            s->reason = "CoreAudio would not take the output's width";
        }
    }
    const OSStatus status = s->folding ? noErr : pass();
    Locked l;
    s->next = g_streams;
    g_streams = s;
    return status;
}

// The first stream of each kind is reported: a game that opens and closes its output
// as the Mac's audio route changes adds nothing new to the log after that.
bool firstOfItsKind(const Stream* s) {
    static uint32_t seen[16];
    static int count = 0;
    const uint32_t kind = s->inChannels << 16 | s->outputChannels << 8 | static_cast<uint32_t>(s->listener) << 4
                        | static_cast<uint32_t>(s->upmix) << 2 | (s->spatial ? 2 : 0) | (s->folding ? 1 : 0);
    Locked l;
    for (int i = 0; i < count; ++i)
        if (seen[i] == kind) return false;
    if (count == 16) return false;
    seen[count++] = kind;
    return true;
}

void reportStart(Stream* s) {
    s->reported = true;
    if (!firstOfItsKind(s)) return;
    if (s->spatial) {
        const char* named = s->deviceName[0] ? s->deviceName : transportName(s->transport);
        char made[160] = "";
        if (s->upmix == Stream::Upmix::stereo)
            snprintf(made, sizeof made, " made %s by Anvil Surround (voices to the centre, the room beside and behind you)",
                     layoutName(s->bed));
        const char* watching = s->upmix == Stream::Upmix::watching
                                   ? "; Anvil Surround stands by in case the game leaves all but the front pair silent" : "";
        if (s->listener == Listener::surround)
            note("3D sound: the game's %s mix (%u channels)%s on %s %u-speaker surround system (%s), %s%s",
                 layoutName(s->inChannels), s->inChannels, made, s->outChannels == 8 ? "an" : "a", s->outChannels, named,
                 s->outChannels >= s->bed ? "each channel to its own speaker" : "placed across its speakers by Apple's spatial audio",
                 watching);
        else
            note("3D sound: the game's %s mix (%u channels)%s placed around you on %s (%s) with Apple's spatial audio%s%s%s",
                 layoutName(s->inChannels), s->inChannels, made, listenerName(s->listener), named,
                 s->personalized ? ", with your personalized spatial audio" : "",
                 s->headTracked ? ", following your head" : "", watching);
        return;
    }
    if (s->spatialFailed)
        note("3D sound couldn't start for this output (Apple's spatial mixer wouldn't take it) — sound as before");
    if (s->folding && s->inChannels > 2) {
        note("the game mixes %u channels (%s) and this output (%s) plays %u — folding the mix into %s, so %s "
             "heard instead of dropped",
             s->inChannels, layoutName(s->inChannels), transportName(s->transport), s->outChannels,
             s->outChannels == 2 ? "stereo" : "mono",
             s->inChannels >= 6 ? "the centre channel (voices) and the surrounds are" : "the rear channels are");
    } else if (s->folding) {
        note("the game plays stereo and this output (%s) plays one channel — folding both sides into it instead "
             "of playing only the left", transportName(s->transport));
    } else {
        note("the game mixes %u channels (%s) and this output (%s) plays %u; left as it is: %s", s->inChannels,
             layoutName(s->inChannels), transportName(s->transport), s->outputChannels,
             s->reason ? s->reason : "not needed");
    }
}

void watchDropouts(double rate);

/// What Anvil Surround found in the 5.1 and 7.1 streams it watches, said once each way (off
/// CoreAudio's thread, from the drop-out timer).
[[maybe_unused]] void sayWatches() {
    Locked l;
    for (Stream* s = g_streams; s; s = s->next) {
        if (s->upmix != Stream::Upmix::watching) continue;
        const int state = s->watch.load(std::memory_order_relaxed);
        if (state == s->watchSaid) continue;
        if (state == 1)
            note("Anvil Surround: the game's %s mix has had sound only in its front pair (the rest silent) — splitting that "
                 "pair into surround: voices to the centre, the room beside and behind you", layoutName(s->inChannels));
        else if (state == 2 && (s->watchSaid == 1 || s->wasSplit.load(std::memory_order_relaxed)))
            note("Anvil Surround: the game began using its %s mix's other channels — handed back to the game's own surround",
                 layoutName(s->inChannels));
        else if (state == 2)
            note("Anvil Surround: the game mixes its own surround (%s) — left as it is", layoutName(s->inChannels));
        s->watchSaid = state;
    }
}

OSStatus setCallback(AudioUnit unit, const AURenderCallbackStruct& cb, const void* data, UInt32 size) {
    auto pass = [&] {
        return g_backend.setProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, data, size);
    };
    Stream* s = nullptr;
    {
        Locked l;
        s = find(unit);
    }
    if (!s) return pass();
    if (!s->folding) {
        if (cb.inputProc && !s->reported) reportStart(s);
        return pass();
    }
    if (!cb.inputProc || s->wrapped) {
        // Clearing the callback, or a second one on a unit already wrapped: the unit
        // goes back to the game's width so Wine's own callback fits it.
        g_backend.setProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &s->asked,
                              sizeof(s->asked));
        s->stale.store(true, std::memory_order_relaxed);
        return pass();
    }

    if (s->spatial) {
        s->wineProc = cb.inputProc;
        s->wineRefCon = cb.inputProcRefCon;
        AURenderCallbackStruct ours = {&spatialRender, s};
        const OSStatus status = g_backend.setProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &ours,
                                                      sizeof(ours));
        if (status == noErr) {
            s->wrapped = true;
            reportStart(s);
            watchDropouts(s->asked.mSampleRate > 0 ? s->asked.mSampleRate : 48000.0);
            return noErr;
        }
        // Wine's callback writes the game's own format, so it only goes in once the unit has it.
        g_backend.setProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &s->asked, sizeof(s->asked));
        s->stale.store(true, std::memory_order_relaxed);
        s->spatial = false;
        s->folding = false;
        s->reason = "3D sound's wrapper could not be installed";
        reportStart(s);
        return pass();
    }

    UInt32 maxFrames = 0, got = sizeof(maxFrames);
    if (g_backend.getProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames,
                              &got) != noErr)
        maxFrames = 0;
    const UInt32 capacity = std::max<UInt32>(4096, std::min<UInt32>(maxFrames, 65536));
    auto* scratch = static_cast<uint8_t*>(calloc(capacity, static_cast<size_t>(s->inChannels) * s->bytesPerSample));

    OSStatus status = kAudio_MemFullError;
    if (scratch) {
        free(s->scratch);
        s->scratch = scratch;
        s->capacityFrames = capacity;
        s->wineProc = cb.inputProc;
        s->wineRefCon = cb.inputProcRefCon;
        AURenderCallbackStruct ours = {&foldRender, s};
        status = g_backend.setProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &ours,
                                       sizeof(ours));
    }
    if (status == noErr) {
        s->wrapped = true;
        reportStart(s);
        watchDropouts(s->asked.mSampleRate > 0 ? s->asked.mSampleRate : 48000.0);
        return noErr;
    }
    // Wine's callback writes the game's full width, so it only goes in once the unit is
    // back at that width.
    g_backend.setProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &s->asked,
                          sizeof(s->asked));
    s->folding = false;
    s->reason = "the wrapper could not be installed";
    reportStart(s);
    return pass();
}

/// Every 30 s from the first folded stream, off CoreAudio's thread: the drop-outs since the last
/// look, in the game log, when there were any.
void watchDropouts(double rate) {
    static std::atomic<bool> started{false};
    if (started.exchange(true)) return;
#ifndef ANVIL_AUDIO_TEST
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                     dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    if (!timer) return;
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC), 30 * NSEC_PER_SEC, 5 * NSEC_PER_SEC);
    dispatch_source_set_event_handler(timer, ^{
        static uint64_t seen = 0, seenFrames = 0;
        const uint64_t n = g_dropouts.load(std::memory_order_relaxed), f = g_droppedFrames.load(std::memory_order_relaxed);
        if (n > seen)
            note("the game's sound arrived too late %llu time%s in the last 30 s — %.0f ms of silence in all, heard as the "
                 "sound cutting out (Wine had nothing new to play)", (unsigned long long)(n - seen), n - seen == 1 ? "" : "s",
                 (double)(f - seenFrames) * 1000.0 / rate);
        seen = n;
        seenFrames = f;
        sayWatches();
    });
    dispatch_resume(timer);                       // kept for the session
#else
    (void)rate;
#endif
}

void reportEnd(const Stream* s) {
    if (!s->folding || !s->wrapped) return;
    const double rate = s->asked.mSampleRate > 0 ? s->asked.mSampleRate : 48000.0;
    const double seconds = s->frames.load(std::memory_order_relaxed) / rate;
    const uint64_t odd = s->odd.load(std::memory_order_relaxed);
    if (seconds < 1.0 && !odd) return;
    if (g_reports.fetch_add(1, std::memory_order_relaxed) >= 16) return;
    if (s->spatial) {
        const char* made = s->upmix == Stream::Upmix::stereo ? ", made surround by Anvil Surround"
                         : s->upmix == Stream::Upmix::watching && s->watch.load(std::memory_order_relaxed) == 1
                               ? ", its front pair made surround by Anvil Surround" : "";
        note("%s stream closed after %.0f s in 3D sound on %s%s%s", layoutName(s->inChannels), seconds, listenerName(s->listener),
             made, odd ? " — some buffers came in a shape neither side asked for and were left silent" : "");
        return;
    }
    note("%s stream closed after %.0f s folded into %s%s", layoutName(s->inChannels), seconds,
         s->outChannels == 2 ? "stereo" : "mono",
         odd ? " — some buffers came in a shape neither side asked for and were left silent" : "");
}

} // namespace
} // namespace anvil_audio

extern "C" OSStatus anvil_AudioUnitSetProperty(AudioUnit unit, AudioUnitPropertyID id, AudioUnitScope scope,
                                               AudioUnitElement element, const void* data, UInt32 size) {
    using namespace anvil_audio;
    if (unit && data && scope == kAudioUnitScope_Input && element == 0 && enabled()) {
        if (id == kAudioUnitProperty_StreamFormat && size >= sizeof(AudioStreamBasicDescription)
            && g_backend.fromWine(__builtin_return_address(0)))
            return setFormat(unit, *static_cast<const AudioStreamBasicDescription*>(data), data, size);
        if (id == kAudioUnitProperty_SetRenderCallback && size >= sizeof(AURenderCallbackStruct)
            && g_backend.fromWine(__builtin_return_address(0)))
            return setCallback(unit, *static_cast<const AURenderCallbackStruct*>(data), data, size);
    }
    return g_backend.setProperty(unit, id, scope, element, data, size);
}

// What Wine's driver asks of a device to tell a game how many channels to mix: its preferred
// speaker layout. With 3D sound, a stereo output is answered with 7.1's eight speakers —
// labelled as Wine's driver reads them into Windows' 7.1 (front, centre, LFE, back, side) — so
// the game mixes in surround, and the mixer has each sound's direction to place. Mono outputs
// and real surround systems keep their own answer; so does everything else in the process.
namespace anvil_audio {
namespace {
const AudioChannelLabel kSurroundForWine[8] = {
    kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_Center, kAudioChannelLabel_LFEScreen,
    kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround,              // Wine: back left, back right
    kAudioChannelLabel_LeftSurroundDirect, kAudioChannelLabel_RightSurroundDirect,  // Wine: side left, side right
};
constexpr UInt32 kSurroundLayoutSize =
    static_cast<UInt32>(offsetof(AudioChannelLayout, mChannelDescriptions) + 8 * sizeof(AudioChannelDescription));

bool answerSurround(AudioObjectID object, const AudioObjectPropertyAddress* address, const void* caller) {
    if (!address || address->mSelector != kAudioDevicePropertyPreferredChannelLayout
        || address->mScope != kAudioObjectPropertyScopeOutput) return false;
    if (!enabled() || !surroundMixWanted() || !g_backend.fromWine(caller)) return false;
    return g_backend.deviceChannels(object) == 2;
}
} // namespace
} // namespace anvil_audio

extern "C" OSStatus anvil_AudioObjectGetPropertyDataSize(AudioObjectID object, const AudioObjectPropertyAddress* address,
                                                         UInt32 qualifierSize, const void* qualifier, UInt32* size) {
    using namespace anvil_audio;
    if (size && answerSurround(object, address, __builtin_return_address(0))) {
        *size = kSurroundLayoutSize;
        return noErr;
    }
    return g_backend.objectGetSize(object, address, qualifierSize, qualifier, size);
}

extern "C" OSStatus anvil_AudioObjectGetPropertyData(AudioObjectID object, const AudioObjectPropertyAddress* address,
                                                     UInt32 qualifierSize, const void* qualifier, UInt32* size, void* data) {
    using namespace anvil_audio;
    if (size && data && answerSurround(object, address, __builtin_return_address(0))) {
        if (*size < kSurroundLayoutSize) return kAudioHardwareBadPropertySizeError;
        memset(data, 0, kSurroundLayoutSize);
        auto* layout = static_cast<AudioChannelLayout*>(data);
        layout->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
        layout->mNumberChannelDescriptions = 8;
        for (int i = 0; i < 8; ++i) layout->mChannelDescriptions[i].mChannelLabel = kSurroundForWine[i];
        *size = kSurroundLayoutSize;
        static std::atomic<bool> said{false};
        if (!said.exchange(true))
            note("3D sound: told the game this stereo output plays 7.1, so it mixes its sound in surround for 3D placement");
        return noErr;
    }
    return g_backend.objectGet(object, address, qualifierSize, qualifier, size, data);
}

// Disposing stops the unit's I/O first, so the wrapper is gone before its state is freed.
extern "C" OSStatus anvil_AudioComponentInstanceDispose(AudioComponentInstance instance) {
    using namespace anvil_audio;
    const OSStatus status = g_backend.dispose(instance);
    Stream* s = nullptr;
    {
        Locked l;
        s = detach(instance);
    }
    if (s) {
        reportEnd(s);
        release(s);
    }
    return status;
}

#ifndef ANVIL_AUDIO_TEST
__attribute__((used, section("__DATA,__interpose")))
static struct { const void* replacement; const void* original; } anvil_audio_interposes[] = {
    {(const void*)&anvil_AudioUnitSetProperty, (const void*)&AudioUnitSetProperty},
    {(const void*)&anvil_AudioComponentInstanceDispose, (const void*)&AudioComponentInstanceDispose},
    {(const void*)&anvil_AudioObjectGetPropertyDataSize, (const void*)&AudioObjectGetPropertyDataSize},
    {(const void*)&anvil_AudioObjectGetPropertyData, (const void*)&AudioObjectGetPropertyData},
};
#endif

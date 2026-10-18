// anvil-soundcheck: what a sound output can do for surround, found by running Anvil's own game
// audio (anvil_audio.mm, the code libanvil runs inside every game) against it.
//
//   anvil-soundcheck scan [device]            what the output is and can play, and a dry run of 3D
//                                             sound for a 7.1 game and a stereo one: the device's
//                                             own answers, Apple's spatial mixer set up for it as
//                                             a game would get it, and a second of each rendered
//                                             into memory (nothing is heard)
//   anvil-soundcheck play surround [device]   a sound burst from each speaker of a 7.1 mix in turn
//                                             — front left, centre, front right, then around
//   anvil-soundcheck play stereo [device]     a stereo game's sound through Anvil Surround: a voice
//                                             in the middle, a room, then left and right
//
// Writes `key=value` lines (Core/SoundCheck reads them). `play` writes `playing=<speaker>` as each
// part starts, and `done=1` at the end. The settings are a game's: ANVIL_SPATIAL_OUTPUT,
// ANVIL_SPATIAL_HEAD and ANVIL_UPMIX as Anvil passes them; 3D sound is always on for the check.
#include "../AnvilMetal/anvil_audio.mm"
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <string>
#include <thread>
#include <vector>

namespace {

using namespace anvil_audio;

// --- The device -------------------------------------------------------------------------------

template <typename T>
bool get(AudioObjectID object, AudioObjectPropertySelector selector, AudioObjectPropertyScope scope, T& value) {
    AudioObjectPropertyAddress a = {selector, scope, kAudioObjectPropertyElementMain};
    UInt32 size = sizeof(T);
    return AudioObjectGetPropertyData(object, &a, 0, nullptr, &size, &value) == noErr;
}

template <typename T>
std::vector<T> getList(AudioObjectID object, AudioObjectPropertySelector selector, AudioObjectPropertyScope scope) {
    AudioObjectPropertyAddress a = {selector, scope, kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(object, &a, 0, nullptr, &size) != noErr || size < sizeof(T)) return {};
    std::vector<T> list(size / sizeof(T));
    if (AudioObjectGetPropertyData(object, &a, 0, nullptr, &size, list.data()) != noErr) return {};
    list.resize(size / sizeof(T));
    return list;
}

std::string fourcc(UInt32 v) {
    if (!v) return "-";
    std::string s;
    for (int shift = 24; shift >= 0; shift -= 8) {
        const char c = static_cast<char>((v >> shift) & 0xff);
        s += (c >= 32 && c < 127) ? c : '?';
    }
    while (!s.empty() && s.back() == ' ') s.pop_back();
    return s;
}

const char* shortLabel(AudioChannelLabel l) {
    switch (l) {
    case kAudioChannelLabel_Left: return "L";
    case kAudioChannelLabel_Right: return "R";
    case kAudioChannelLabel_Center: return "C";
    case kAudioChannelLabel_LFEScreen: return "LFE";
    case kAudioChannelLabel_LeftSurround: return "Ls";
    case kAudioChannelLabel_RightSurround: return "Rs";
    case kAudioChannelLabel_RearSurroundLeft: return "Rls";
    case kAudioChannelLabel_RearSurroundRight: return "Rrs";
    case kAudioChannelLabel_LeftSurroundDirect: return "Lsd";
    case kAudioChannelLabel_RightSurroundDirect: return "Rsd";
    case kAudioChannelLabel_CenterSurround: return "Cs";
    case kAudioChannelLabel_Mono: return "M";
    case kAudioChannelLabel_Unused: return "-";
    default: return "?";
    }
}

AudioDeviceID defaultOutput() {
    AudioDeviceID d = 0;
    get(kAudioObjectSystemObject, kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, d);
    return d;
}

void scanDevice(AudioDeviceID d) {
    char name[256] = "";
    realDeviceName(d, name, sizeof name);
    printf("device.id=%u\ndevice.name=%s\n", d, name);
    printf("device.transport=%s\n", fourcc(realDeviceTransport(d)).c_str());
    printf("device.source=%s\n", fourcc(realDataSource(d)).c_str());
    const UInt32 channels = realDeviceChannels(d);
    printf("device.channels=%u\n", channels);
    Float64 rate = 0;
    get(d, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, rate);
    printf("device.rate=%.0f\n", rate);

    // Every width its output streams can be set to (a TV on HDMI that plays 2 now may take 8).
    UInt32 most = channels;
    std::string widths;
    for (AudioStreamID stream : getList<AudioStreamID>(d, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput)) {
        for (const auto& f : getList<AudioStreamRangedDescription>(stream, kAudioStreamPropertyAvailablePhysicalFormats,
                                                                    kAudioObjectPropertyScopeGlobal)) {
            const UInt32 n = f.mFormat.mChannelsPerFrame;
            most = std::max(most, n);
            const std::string tag = "," + std::to_string(n) + ",";
            if (("," + widths + ",").find(tag) == std::string::npos) widths += (widths.empty() ? "" : ",") + std::to_string(n);
        }
    }
    printf("device.widths=%s\ndevice.mostChannels=%u\n", widths.c_str(), most);

    // Its own speaker layout, as Wine's driver reads it.
    {
        AudioObjectPropertyAddress a = {kAudioDevicePropertyPreferredChannelLayout, kAudioObjectPropertyScopeOutput,
                                        kAudioObjectPropertyElementMain};
        UInt32 size = 0;
        std::string labels;
        if (AudioObjectGetPropertyDataSize(d, &a, 0, nullptr, &size) == noErr && size >= sizeof(AudioChannelLayout)) {
            std::vector<uint8_t> buffer(size);
            auto* layout = reinterpret_cast<AudioChannelLayout*>(buffer.data());
            if (AudioObjectGetPropertyData(d, &a, 0, nullptr, &size, layout) == noErr) {
                for (UInt32 i = 0; i < layout->mNumberChannelDescriptions; ++i)
                    labels += std::string(i ? " " : "") + shortLabel(layout->mChannelDescriptions[i].mChannelLabel);
                if (labels.empty() && layout->mChannelLayoutTag) labels = "tag " + std::to_string(layout->mChannelLayoutTag);
            }
        }
        printf("device.layout=%s\n", labels.c_str());
    }

    // How late sound reaches the speakers: the device's own latency and safety margin, its
    // buffer, and its stream's latency.
    UInt32 latency = 0, safety = 0, buffer = 0, streamLatency = 0;
    get(d, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput, latency);
    get(d, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput, safety);
    get(d, kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal, buffer);
    const auto streams = getList<AudioStreamID>(d, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput);
    if (!streams.empty()) get(streams[0], kAudioStreamPropertyLatency, kAudioObjectPropertyScopeGlobal, streamLatency);
    const double frames = double(latency) + safety + buffer + streamLatency;
    printf("device.latencyMs=%.1f\n", rate > 0 ? frames * 1000.0 / rate : 0.0);
    UInt32 alive = 0, elsewhere = 0;
    pid_t hog = -1;
    get(d, kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal, alive);
    get(d, kAudioDevicePropertyDeviceIsRunningSomewhere, kAudioObjectPropertyScopeGlobal, elsewhere);
    get(d, kAudioDevicePropertyHogMode, kAudioObjectPropertyScopeOutput, hog);
    printf("device.alive=%u\ndevice.runningSomewhere=%u\ndevice.hogPid=%d\n", alive, elsewhere, static_cast<int>(hog));
}

// --- A game's audio, run dry: the real device's answers, an output unit that plays nothing ----

struct DryUnit {
    AudioDeviceID device = 0;
    UInt32 maxFrames = 512;
    AudioStreamBasicDescription format = {};
    AURenderCallbackStruct callback = {};
};

OSStatus drySet(AudioUnit unit, AudioUnitPropertyID id, AudioUnitScope, AudioUnitElement, const void* data, UInt32) {
    auto* u = reinterpret_cast<DryUnit*>(unit);
    if (id == kAudioOutputUnitProperty_CurrentDevice) u->device = *static_cast<const AudioDeviceID*>(data);
    else if (id == kAudioUnitProperty_StreamFormat) u->format = *static_cast<const AudioStreamBasicDescription*>(data);
    else if (id == kAudioUnitProperty_SetRenderCallback) u->callback = *static_cast<const AURenderCallbackStruct*>(data);
    return noErr;
}
OSStatus dryGet(AudioUnit unit, AudioUnitPropertyID id, AudioUnitScope, AudioUnitElement, void* data, UInt32*) {
    auto* u = reinterpret_cast<DryUnit*>(unit);
    if (id == kAudioOutputUnitProperty_CurrentDevice) { *static_cast<AudioDeviceID*>(data) = u->device; return noErr; }
    if (id == kAudioUnitProperty_MaximumFramesPerSlice) { *static_cast<UInt32*>(data) = u->maxFrames; return noErr; }
    return kAudioUnitErr_InvalidProperty;
}
OSStatus dryDispose(AudioComponentInstance) { return noErr; }
bool asWine(const void*) { return true; }

AudioStreamBasicDescription gameFormat(UInt32 channels, double rate) {
    AudioStreamBasicDescription a = {};
    a.mFormatID = kAudioFormatLinearPCM;
    a.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    a.mSampleRate = rate;
    a.mBytesPerPacket = a.mBytesPerFrame = channels * 4;
    a.mFramesPerPacket = 1;
    a.mChannelsPerFrame = channels;
    a.mBitsPerChannel = 32;
    return a;
}

// A game's own sound: noise bursts in one channel at a time (`channel`, −1 for none), or for a
// stereo game a voice in the middle (`stereo` 1), a room (2), left alone (3) or right alone (4).
struct Game {
    UInt32 channels = 8;
    std::atomic<int> channel{-1};
    std::atomic<int> stereo{0};
    std::atomic<float> level{0.0f};           // eased toward `target` so nothing clicks
    float target = 0.0f, eased = 0.0f, lp1 = 0.0f, lp2 = 0.0f, lp3 = 0.0f;
    uint32_t seedA = 22222, seedB = 9876543;
    double rate = 48000;
    uint64_t frames = 0;
};

float white(uint32_t& x) { x = x * 1664525u + 1013904223u; return static_cast<float>(x >> 8) / 16777216.0f * 2.0f - 1.0f; }

OSStatus gameRender(void* user, AudioUnitRenderActionFlags*, const AudioTimeStamp*, UInt32, UInt32 frames,
                    AudioBufferList* data) noexcept [[clang::nonblocking]] {
    auto* g = static_cast<Game*>(user);
    float* out = static_cast<float*>(data->mBuffers[0].mData);
    const int channel = g->channel.load(std::memory_order_relaxed), stereo = g->stereo.load(std::memory_order_relaxed);
    const float target = g->level.load(std::memory_order_relaxed);
    const float ease = static_cast<float>(1.0 / (0.02 * g->rate));
    for (UInt32 i = 0; i < frames; ++i, ++g->frames) {
        g->eased += std::clamp(target - g->eased, -ease, ease);
        const float a = white(g->seedA), b = white(g->seedB);
        // A voice: noise in its band (four poles at ~3 kHz) with a syllable rhythm.
        g->lp1 += 0.33f * (a - g->lp1); g->lp2 += 0.33f * (g->lp1 - g->lp2); g->lp3 += 0.33f * (g->lp2 - g->lp3);
        const float syllable = 0.55f + 0.45f * std::sin(static_cast<float>(2.0 * M_PI * 4.0 * g->frames / g->rate));
        const float voice = 1.6f * g->lp3 * syllable;
        float* f = out + static_cast<size_t>(i) * g->channels;
        for (UInt32 c = 0; c < g->channels; ++c) f[c] = 0.0f;
        const float k = 0.25f * g->eased;
        if (g->channels == 2) {
            switch (stereo) {
            case 1: f[0] = f[1] = k * voice; break;
            case 2: f[0] = 0.7f * k * a; f[1] = 0.7f * k * b; break;
            case 3: f[0] = k * a; break;
            case 4: f[1] = k * a; break;
            default: break;
            }
        } else if (channel >= 0 && channel < static_cast<int>(g->channels)) {
            f[channel] = k * (channel == 3 ? 4.0f * g->lp3 : a);
        }
    }
    return noErr;
}

/// A game's stream of `channels` set up on device `d` the way libanvil sets it up in a game, run
/// dry for a second; prints what became of it under `key`.
void dryRun(AudioDeviceID d, UInt32 channels, const char* key) {
    Float64 rate = 48000;
    get(d, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, rate);
    DryUnit u;
    Game game;
    game.channels = channels;
    game.rate = rate;
    game.level = 1.0f;
    game.stereo = channels == 2 ? 2 : 0;
    game.channel = channels == 2 ? -1 : 0;
    auto* unit = reinterpret_cast<AudioUnit>(&u);
    const AudioStreamBasicDescription fmt = gameFormat(channels, rate);
    anvil_AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &d, sizeof d);
    anvil_AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &fmt, sizeof fmt);
    AURenderCallbackStruct cb = {&gameRender, &game};
    anvil_AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, sizeof cb);
    Stream* s = nullptr;
    {
        Locked l;
        s = find(unit);
    }
    const bool spatial = s && s->spatial && s->mixer;
    printf("%s.spatial=%d\n", key, spatial ? 1 : 0);
    if (s) {
        printf("%s.listener=%s\n", key, s->spatial ? (s->listener == Listener::headphones ? "headphones"
                                                     : s->listener == Listener::builtInSpeakers ? "builtInSpeakers"
                                                     : s->listener == Listener::externalSpeakers ? "externalSpeakers" : "surround") : "-");
        printf("%s.bed=%u\n%s.out=%u\n", key, s->bed, key, s->outChannels);
        printf("%s.upmix=%s\n", key, s->upmix == Stream::Upmix::stereo ? "stereo" : s->upmix == Stream::Upmix::watching ? "watching" : "off");
        printf("%s.personalized=%d\n%s.headTracked=%d\n", key, s->personalized ? 1 : 0, key, s->headTracked ? 1 : 0);
        if (s->spatialFailed) printf("%s.failed=Apple's spatial mixer wouldn't take this output\n", key);
        else if (!s->spatial && s->reason) printf("%s.failed=%s\n", key, s->reason);
    } else {
        printf("%s.failed=left as the game plays it (nothing for 3D sound to do)\n", key);
    }
    if (spatial && u.callback.inputProc) {
        const UInt32 out = u.format.mChannelsPerFrame ? u.format.mChannelsPerFrame : 2;
        std::vector<float> buffer(512 * out);
        AudioTimeStamp ts = {};
        ts.mFlags = kAudioTimeStampSampleTimeValid;
        double energy = 0;
        bool finite = true;
        const auto t0 = std::chrono::steady_clock::now();
        const int blocks = static_cast<int>(rate / 512);
        for (int b = 0; b < blocks; ++b) {
            AudioBufferList io;
            io.mNumberBuffers = 1;
            io.mBuffers[0] = {out, static_cast<UInt32>(buffer.size() * sizeof(float)), buffer.data()};
            AudioUnitRenderActionFlags flags = 0;
            u.callback.inputProc(u.callback.inputProcRefCon, &flags, &ts, 0, 512, &io);
            ts.mSampleTime += 512;
            for (float v : buffer) { finite = finite && std::isfinite(v); energy += double(v) * v; }
        }
        const double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
        printf("%s.rendered=%d\n%s.cpuMsPerSecond=%.2f\n", key, finite && energy > 0 ? 1 : 0, key, ms);
    }
    anvil_AudioComponentInstanceDispose(reinterpret_cast<AudioComponentInstance>(&u));
}

int scan(AudioDeviceID d) {
    g_backend = {&drySet, &dryGet, &dryDispose, &realDeviceChannels, &realDeviceTransport, &asWine,
                 &realDataSource, &realDeviceName, &AudioObjectGetPropertyDataSize, &AudioObjectGetPropertyData};
    scanDevice(d);
    // What a game is told the output plays.
    {
        AudioObjectPropertyAddress a = {kAudioDevicePropertyPreferredChannelLayout, kAudioObjectPropertyScopeOutput,
                                        kAudioObjectPropertyElementMain};
        UInt32 size = 0;
        UInt32 told = 0;
        if (anvil_AudioObjectGetPropertyDataSize(d, &a, 0, nullptr, &size) == noErr && size >= sizeof(AudioChannelLayout)) {
            std::vector<uint8_t> buffer(size);
            auto* layout = reinterpret_cast<AudioChannelLayout*>(buffer.data());
            if (anvil_AudioObjectGetPropertyData(d, &a, 0, nullptr, &size, layout) == noErr)
                told = layout->mNumberChannelDescriptions ? layout->mNumberChannelDescriptions
                                                          : AudioChannelLayoutTag_GetNumberOfChannels(layout->mChannelLayoutTag);
        }
        printf("engine.toldChannels=%u\n", told ? told : realDeviceChannels(d));
    }
    dryRun(d, 8, "game71");
    dryRun(d, 2, "gameStereo");
    printf("done=1\n");
    return 0;
}

// --- Played for real -------------------------------------------------------------------------

int play(AudioDeviceID d, bool surround) {
    g_backend = {&AudioUnitSetProperty, &AudioUnitGetProperty, &AudioComponentInstanceDispose, &realDeviceChannels,
                 &realDeviceTransport, &asWine, &realDataSource, &realDeviceName, &AudioObjectGetPropertyDataSize,
                 &AudioObjectGetPropertyData};
    const AudioComponentDescription desc = {kAudioUnitType_Output, kAudioUnitSubType_HALOutput, kAudioUnitManufacturer_Apple, 0, 0};
    AudioComponent component = AudioComponentFindNext(nullptr, &desc);
    AudioUnit unit = nullptr;
    if (!component || AudioComponentInstanceNew(component, &unit) != noErr) { printf("failed=no output unit\n"); return 1; }
    Float64 rate = 48000;
    get(d, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, rate);
    Game game;
    game.channels = surround ? 8 : 2;
    game.rate = rate;
    const AudioStreamBasicDescription fmt = gameFormat(game.channels, rate);
    const char* step = "its device";
    OSStatus status = anvil_AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &d, sizeof d);
    if (status == noErr) { step = "the game's format"; status = anvil_AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &fmt, sizeof fmt); }
    AURenderCallbackStruct cb = {&gameRender, &game};
    if (status == noErr) { step = "the game's sound"; status = anvil_AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, sizeof cb); }
    if (status == noErr) { step = "setting up"; status = AudioUnitInitialize(unit); }
    if (status == noErr) { step = "starting"; status = AudioOutputUnitStart(unit); }
    if (status != noErr) {
        AudioStreamBasicDescription have = {};
        UInt32 size = sizeof have;
        AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &have, &size);
        printf("failed=the output wouldn't start: %s (%d; %u channels at %.0f Hz)\n", step, static_cast<int>(status),
               have.mChannelsPerFrame, have.mSampleRate);
        anvil_AudioComponentInstanceDispose(unit);
        return 1;
    }
    {
        Locked l;
        const Stream* s = find(unit);
        printf("spatial=%d\nupmix=%s\n", s && s->spatial ? 1 : 0,
               s && s->upmix == Stream::Upmix::stereo ? "stereo" : "off");
    }
    fflush(stdout);
    auto part = [&](const char* label, int channel, int stereo, double seconds) {
        printf("playing=%s\n", label);
        fflush(stdout);
        game.channel = channel;
        game.stereo = stereo;
        game.level = 1.0f;
        std::this_thread::sleep_for(std::chrono::duration<double>(seconds));
        game.level = 0.0f;
        std::this_thread::sleep_for(std::chrono::milliseconds(300));
    };
    std::this_thread::sleep_for(std::chrono::milliseconds(300));
    if (surround) {
        // Windows' 7.1 order: FL FR FC LFE BL BR SL SR — played clockwise from the front left.
        part("front left", 0, 0, 1.0);
        part("centre", 2, 0, 1.0);
        part("front right", 1, 0, 1.0);
        part("side right", 7, 0, 1.0);
        part("back right", 5, 0, 1.0);
        part("back left", 4, 0, 1.0);
        part("side left", 6, 0, 1.0);
    } else {
        part("voice in the middle", -1, 1, 2.0);
        part("room", -1, 2, 2.5);
        part("left", -1, 3, 1.2);
        part("right", -1, 4, 1.2);
    }
    AudioOutputUnitStop(unit);
    anvil_AudioComponentInstanceDispose(unit);
    printf("done=1\n");
    return 0;
}

} // namespace

int main(int argc, char** argv) {
    setvbuf(stdout, nullptr, _IOLBF, 0);
    setenv("ANVIL_SPATIAL", "1", 1);
    setenv("ANVIL_SURROUND_MIX", "1", 1);
    unsetenv("ANVIL_LOG");
    const std::string mode = argc > 1 ? argv[1] : "scan";
    auto device = [&](int at) -> AudioDeviceID {
        return argc > at ? static_cast<AudioDeviceID>(strtoul(argv[at], nullptr, 10)) : defaultOutput();
    };
    // Device numbers are macOS's for as long as the device is connected: one that went away can
    // come back as another device's — a microphone's, with nothing to play through.
    auto gone = [](AudioDeviceID d) { return !d || realDeviceChannels(d) == 0; };
    if (mode == "scan") {
        const AudioDeviceID d = device(2);
        if (gone(d)) { printf("failed=that output isn't connected any more — or plays nothing\ndone=1\n"); return 1; }
        return scan(d);
    }
    if (mode == "play" && argc > 2) {
        const AudioDeviceID d = device(3);
        if (gone(d)) { printf("failed=that output isn't connected any more — or plays nothing\ndone=1\n"); return 1; }
        return play(d, std::string(argv[2]) == "surround");
    }
    fprintf(stderr, "usage: anvil-soundcheck scan [device] | play surround|stereo [device]\n");
    return 2;
}

// The surround fold-down, run on the library's own code against stand-ins for CoreAudio's
// output unit and for Wine's CoreAudio driver, which drive it in the order Wine 7.7's
// create_stream does: device, format, render callback, then renders and dispose.
//
//   clang++ -std=c++17 -ObjC++ -DANVIL_AUDIO_TEST -fsanitize=address,undefined -g \
//     -framework AudioToolbox -framework CoreAudio \
//     Native/Tools/tests/audio_fold_test.mm -o /tmp/audio_fold_test && /tmp/audio_fold_test
#include "../../AnvilMetal/anvil_audio.mm"
#include <cmath>
#include <cstdio>
#include <fstream>
#include <map>
#include <sstream>
#include <string>
#include <vector>

static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { ++failures; printf("FAIL %s:%d: ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

// --- CoreAudio's output unit ---------------------------------------------------------
struct FakeUnit {
    AudioDeviceID device = 0;
    UInt32 maxFrames = 512;
    AudioStreamBasicDescription format = {};
    int formatSets = 0;
    AURenderCallbackStruct callback = {};
    UInt32 rejectChannels = 0;          // refuses a format this wide
    OSStatus callbackError = noErr;     // refuses every render callback
    bool disposed = false;
};

static std::map<AudioDeviceID, UInt32> g_outputs = {{10, 2}, {11, 1}, {12, 8}, {13, 6}};
static bool g_fromWine = true;

static OSStatus fakeSet(AudioUnit unit, AudioUnitPropertyID id, AudioUnitScope, AudioUnitElement, const void* data,
                        UInt32) {
    auto* u = reinterpret_cast<FakeUnit*>(unit);
    if (id == kAudioOutputUnitProperty_CurrentDevice) { u->device = *static_cast<const AudioDeviceID*>(data); return noErr; }
    if (id == kAudioUnitProperty_StreamFormat) {
        const auto* a = static_cast<const AudioStreamBasicDescription*>(data);
        if (u->rejectChannels && a->mChannelsPerFrame == u->rejectChannels) return kAudioUnitErr_FormatNotSupported;
        u->format = *a;
        ++u->formatSets;
        return noErr;
    }
    if (id == kAudioUnitProperty_SetRenderCallback) {
        if (u->callbackError) return u->callbackError;
        u->callback = *static_cast<const AURenderCallbackStruct*>(data);
        return noErr;
    }
    return noErr;
}

static OSStatus fakeGet(AudioUnit unit, AudioUnitPropertyID id, AudioUnitScope, AudioUnitElement, void* data, UInt32*) {
    auto* u = reinterpret_cast<FakeUnit*>(unit);
    if (id == kAudioOutputUnitProperty_CurrentDevice) {
        if (!u->device) return kAudioUnitErr_InvalidProperty;
        *static_cast<AudioDeviceID*>(data) = u->device;
        return noErr;
    }
    if (id == kAudioUnitProperty_MaximumFramesPerSlice) { *static_cast<UInt32*>(data) = u->maxFrames; return noErr; }
    return kAudioUnitErr_InvalidProperty;
}

static OSStatus fakeDispose(AudioComponentInstance unit) { reinterpret_cast<FakeUnit*>(unit)->disposed = true; return noErr; }
static UInt32 fakeChannels(AudioDeviceID d) { auto it = g_outputs.find(d); return it == g_outputs.end() ? 0 : it->second; }
static std::map<AudioDeviceID, UInt32> g_transports;
static UInt32 fakeTransport(AudioDeviceID d) {
    auto it = g_transports.find(d);
    return it == g_transports.end() ? kAudioDeviceTransportTypeBuiltIn : it->second;
}
static std::string g_caseName;
static UInt32 g_caseSource = 0;
static bool fakeName(AudioDeviceID, char* out, size_t room) { snprintf(out, room, "%s", g_caseName.c_str()); return true; }
static UInt32 fakeSource(AudioDeviceID) { return g_caseSource; }
static bool fakeFromWine(const void*) { return g_fromWine; }

// --- Wine's driver -------------------------------------------------------------------
// Like ca_render_cb: writes exactly frames × nBlockAlign bytes of the game's stream.
// Each channel carries its own level times a ramp over the stream position, so a
// dropped, repeated or misplaced frame shows up in the output.
struct FakeWine {
    AudioStreamBasicDescription fmt = {};
    std::vector<float> level;
    uint64_t position = 0;
    int calls = 0;
    bool fitted = true;                 // every buffer Wine was given held what it wrote
    // Exact silence over these stream positions, as Wine fills a buffer the game was late with;
    // and a fade to silence from `fadeFrom`, over 400 frames, as a sound that ends.
    uint64_t silentFrom = UINT64_MAX, silentTo = 0, fadeFrom = UINT64_MAX;
};

static float ramp(uint64_t frame) { return 0.25f + 0.5f * static_cast<float>((frame % 997) / 997.0); }

static OSStatus fakeWineRender(void* user, AudioUnitRenderActionFlags*, const AudioTimeStamp*, UInt32, UInt32 frames,
                               AudioBufferList* data) noexcept [[clang::nonblocking]] {
    auto* w = static_cast<FakeWine*>(user);
    ++w->calls;
    const UInt32 channels = w->fmt.mChannelsPerFrame, bytes = w->fmt.mBitsPerChannel / 8;
    if (data->mNumberBuffers != 1 || data->mBuffers[0].mDataByteSize < frames * w->fmt.mBytesPerFrame) w->fitted = false;
    auto* out = static_cast<uint8_t*>(data->mBuffers[0].mData);
    for (UInt32 i = 0; i < frames; ++i, ++w->position) {
        for (UInt32 c = 0; c < channels; ++c) {
            float v = w->level[c] * ramp(w->position);
            if (w->position >= w->silentFrom && w->position < w->silentTo) v = 0.0f;
            if (w->position >= w->fadeFrom) v *= std::max(0.0f, 1.0f - static_cast<float>(w->position - w->fadeFrom) / 400.0f);
            uint8_t* p = out + static_cast<size_t>(i) * w->fmt.mBytesPerFrame + c * bytes;
            if (w->fmt.mFormatFlags & kAudioFormatFlagIsFloat) memcpy(p, &v, 4);
            else if (bytes == 2) { int16_t s = static_cast<int16_t>(lrintf(std::max(-1.0f, std::min(1.0f, v)) * 32767)); memcpy(p, &s, 2); }
            else { int32_t s = static_cast<int32_t>(llrint(std::max(-1.0, std::min(1.0, (double)v)) * 2147483647.0)); memcpy(p, &s, 4); }
        }
    }
    return noErr;
}

// Wine 7.7's ca_get_audiodesc for a WAVE_FORMAT_EXTENSIBLE stream.
static AudioStreamBasicDescription wineFormat(UInt32 channels, bool isFloat, UInt32 bits) {
    AudioStreamBasicDescription a = {};
    a.mFormatID = kAudioFormatLinearPCM;
    a.mFormatFlags = isFloat ? kAudioFormatFlagIsFloat : kAudioFormatFlagIsSignedInteger;
    a.mSampleRate = 48000;
    a.mBytesPerPacket = a.mBytesPerFrame = channels * bits / 8;
    a.mFramesPerPacket = 1;
    a.mChannelsPerFrame = channels;
    a.mBitsPerChannel = bits;
    return a;
}

// What create_stream does with a new output unit.
static void wineCreate(FakeUnit& u, AudioDeviceID device, FakeWine& w) {
    auto* unit = reinterpret_cast<AudioUnit>(&u);
    anvil_AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device,
                               sizeof(device));
    anvil_AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &w.fmt, sizeof(w.fmt));
    AURenderCallbackStruct cb = {&fakeWineRender, &w};
    anvil_AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, sizeof(cb));
}

// CoreAudio pulling one buffer at the unit's input width, with a guard band behind it.
template <typename T>
static std::vector<float> pull(FakeUnit& u, UInt32 frames, UInt32 shape = 0) {
    const UInt32 channels = shape ? shape : u.format.mChannelsPerFrame;
    std::vector<T> buffer(static_cast<size_t>(frames) * channels + 64, static_cast<T>(77));
    AudioBufferList io;
    io.mNumberBuffers = 1;
    io.mBuffers[0].mNumberChannels = channels;
    io.mBuffers[0].mDataByteSize = frames * channels * sizeof(T);
    io.mBuffers[0].mData = buffer.data();
    AudioUnitRenderActionFlags flags = 0;
    AudioTimeStamp ts = {};
    const OSStatus status = u.callback.inputProc(u.callback.inputProcRefCon, &flags, &ts, 0, frames, &io);
    CHECK(status == noErr, "render returned %d", (int)status);
    for (size_t i = static_cast<size_t>(frames) * channels; i < buffer.size(); ++i)
        CHECK(buffer[i] == static_cast<T>(77), "wrote past the unit's buffer at %zu", i);
    std::vector<float> out(static_cast<size_t>(frames) * channels);
    for (size_t i = 0; i < out.size(); ++i) out[i] = anvil_audio::toFloat(buffer[i]);
    return out;
}

static bool is(AURenderCallback installed, const void* fn) { return reinterpret_cast<const void*>(installed) == fn; }
static const void* const kWine = reinterpret_cast<const void*>(&fakeWineRender);
static const void* const kFold = reinterpret_cast<const void*>(&anvil_audio::foldRender);

static bool near(float a, float b, float tolerance = 2e-4f) { return std::fabs(a - b) <= tolerance; }
static void dispose(FakeUnit& u) { anvil_AudioComponentInstanceDispose(reinterpret_cast<AudioComponentInstance>(&u)); }

static std::string logText(const char* path) {
    std::ifstream f(path);
    std::stringstream s;
    s << f.rdbuf();
    return s.str();
}

// Left and right weight each input channel should get, written out independently.
static const float k = 0.70710678f;
static const float kStereoGains[9][8][2] = {
    {}, {}, {}, {},
    {{1, 0}, {0, 1}, {k, 0}, {0, k}},                                                // quad
    {{1, 0}, {0, 1}, {0, 0}, {k, 0}, {0, k}},                                        // 4.1
    {{1, 0}, {0, 1}, {k, k}, {0, 0}, {k, 0}, {0, k}},                                // 5.1
    {{1, 0}, {0, 1}, {k, k}, {0, 0}, {k, 0}, {0, k}, {0.5f, 0.5f}},                  // 6.1
    {{1, 0}, {0, 1}, {k, k}, {0, 0}, {k, 0}, {0, k}, {k, 0}, {0, k}},                // 7.1
};

template <typename T>
static void checkGains(UInt32 channels, bool isFloat, UInt32 bits, AudioDeviceID output) {
    const UInt32 outChannels = g_outputs[output];
    for (UInt32 c = 0; c < channels; ++c) {
        FakeUnit u;
        FakeWine w;
        w.fmt = wineFormat(channels, isFloat, bits);
        w.level.assign(channels, 0.0f);
        w.level[c] = 0.8f;
        wineCreate(u, output, w);
        CHECK(u.format.mChannelsPerFrame == outChannels, "%u ch into %u: unit given %u", channels, outChannels,
              u.format.mChannelsPerFrame);
        CHECK(is(u.callback.inputProc, kFold), "%u ch into %u: callback not wrapped", channels, outChannels);
        const UInt32 frames = 300;
        const std::vector<float> out = pull<T>(u, frames);
        CHECK(w.fitted, "Wine was handed a buffer smaller than the game's width");
        const float tol = isFloat ? 2e-4f : 3e-4f;
        for (UInt32 i = 0; i < frames; ++i) {
            const float in = 0.8f * ramp(i);
            const float l = kStereoGains[channels][c][0] * in, r = kStereoGains[channels][c][1] * in;
            if (outChannels == 2) {
                if (!near(out[i * 2], l, tol) || !near(out[i * 2 + 1], r, tol)) {
                    CHECK(false, "%u ch, input %u, frame %u: got L %.4f R %.4f, want %.4f %.4f", channels, c, i,
                          out[i * 2], out[i * 2 + 1], l, r);
                    break;
                }
            } else if (!near(out[i], 0.5f * (l + r), tol)) {
                CHECK(false, "%u ch into mono, input %u, frame %u: got %.4f, want %.4f", channels, c, i, out[i],
                      0.5f * (l + r));
                break;
            }
        }
        dispose(u);
    }
}

int main() {
    const char* tmp = getenv("TMPDIR");
    std::string pathTemplate = std::string(tmp ? tmp : "/tmp") + "/anvil_audio_test_XXXXXX";
    std::vector<char> logBuffer(pathTemplate.begin(), pathTemplate.end());
    logBuffer.push_back('\0');
    char* logPath = logBuffer.data();
    const int fd = mkstemp(logPath);
    if (fd < 0) { printf("cannot create a log file at %s\n", logPath); return 1; }
    close(fd);
    setenv("ANVIL_LOG", logPath, 1);
    anvil_audio::g_backend = {&fakeSet, &fakeGet, &fakeDispose, &fakeChannels, &fakeTransport, &fakeFromWine};

    // LEGO Star Wars' mix on a MacBook's speakers, and every other width, float and integer.
    checkGains<float>(8, true, 32, 10);
    checkGains<float>(6, true, 32, 10);
    checkGains<float>(7, true, 32, 10);
    checkGains<float>(5, true, 32, 10);
    checkGains<float>(4, true, 32, 10);
    checkGains<int16_t>(8, false, 16, 10);
    checkGains<int16_t>(6, false, 16, 10);
    checkGains<int32_t>(8, false, 32, 10);
    checkGains<float>(8, true, 32, 11);           // mono output
    checkGains<int16_t>(6, false, 16, 11);

    // Stereo on a mono output: both sides, not only the left.
    {
        FakeUnit u;
        FakeWine w;
        w.fmt = wineFormat(2, true, 32);
        w.level = {0.8f, 0.4f};
        wineCreate(u, 11, w);
        CHECK(u.format.mChannelsPerFrame == 1, "stereo on mono: unit given %u", u.format.mChannelsPerFrame);
        const auto out = pull<float>(u, 100);
        CHECK(near(out[10], 0.5f * (0.8f + 0.4f) * ramp(10)), "stereo on mono: got %.4f", out[10]);
        dispose(u);
    }

    // Buffers larger than the scratch are filled in turns, with no frame lost or repeated.
    // (Over a second of audio, so the stream's closing line is written too.)
    {
        FakeUnit u;
        FakeWine w;
        w.fmt = wineFormat(8, true, 32);
        w.level = {0.1f, 0.2f, 0.3f, 0.05f, 0.15f, 0.25f, 0.35f, 0.45f};
        wineCreate(u, 10, w);
        const UInt32 frames = 50000;
        const auto out = pull<float>(u, frames);
        CHECK(w.calls == (int)((frames + 4095) / 4096), "%u frames with a 4096-frame scratch took %d of Wine's calls",
              frames, w.calls);
        CHECK(w.position == frames, "Wine was asked for %llu frames, not %u", (unsigned long long)w.position, frames);
        for (UInt32 i = 0; i < frames; ++i) {
            float l = 0, r = 0;
            for (UInt32 c = 0; c < 8; ++c) {
                l += kStereoGains[8][c][0] * w.level[c] * ramp(i);
                r += kStereoGains[8][c][1] * w.level[c] * ramp(i);
            }
            if (!near(out[i * 2], l) || !near(out[i * 2 + 1], r)) {
                CHECK(false, "chunked frame %u: got %.4f %.4f want %.4f %.4f", i, out[i * 2], out[i * 2 + 1], l, r);
                break;
            }
        }
        // And the next buffer carries on from where that one ended.
        const auto more = pull<float>(u, 64);
        float l = 0;
        for (UInt32 c = 0; c < 8; ++c) l += kStereoGains[8][c][0] * w.level[c] * ramp(frames);
        CHECK(near(more[0], l), "position after chunking: got %.4f want %.4f", more[0], l);
        dispose(u);
    }

    // Integers saturate instead of wrapping when everything is loud at once.
    {
        FakeUnit u;
        FakeWine w;
        w.fmt = wineFormat(8, false, 16);
        w.level.assign(8, 1.0f);
        wineCreate(u, 10, w);
        std::vector<int16_t> raw(2 * 500);
        AudioBufferList io;
        io.mNumberBuffers = 1;
        io.mBuffers[0].mNumberChannels = 2;
        io.mBuffers[0].mDataByteSize = static_cast<UInt32>(raw.size() * 2);
        io.mBuffers[0].mData = raw.data();
        AudioUnitRenderActionFlags flags = 0;
        AudioTimeStamp ts = {};
        u.callback.inputProc(u.callback.inputProcRefCon, &flags, &ts, 0, 500, &io);
        // Frame 400: every channel at 0.45, so the left side sums to 1.4.
        CHECK(raw[2 * 400] == 32767 && raw[2 * 400 + 1] == 32767, "saturation: got %d %d", raw[2 * 400], raw[2 * 400 + 1]);
        dispose(u);
    }

    // Left alone: stereo on stereo, surround on an output that plays it, 2.1, calls that
    // are not Wine's, a unit that refuses the narrower format, and the switch turned off.
    {
        FakeUnit u;
        FakeWine w;
        w.fmt = wineFormat(2, true, 32);
        w.level = {0.5f, 0.5f};
        wineCreate(u, 10, w);
        CHECK(u.format.mChannelsPerFrame == 2 && is(u.callback.inputProc, kWine), "stereo on stereo was touched");
        dispose(u);
    }
    {
        FakeUnit u;
        FakeWine w;
        w.fmt = wineFormat(8, true, 32);
        w.level.assign(8, 0.5f);
        wineCreate(u, 12, w);
        CHECK(u.format.mChannelsPerFrame == 8 && is(u.callback.inputProc, kWine), "7.1 on a 7.1 output was touched");
        dispose(u);
    }
    {
        FakeUnit u;
        FakeWine w;
        w.fmt = wineFormat(8, true, 32);
        w.level.assign(8, 0.5f);
        wineCreate(u, 13, w);
        CHECK(u.format.mChannelsPerFrame == 8 && is(u.callback.inputProc, kWine),
              "7.1 on a 5.1 output was touched (it is left to CoreAudio)");
        dispose(u);
    }
    {
        FakeUnit u;
        FakeWine w;
        w.fmt = wineFormat(3, true, 32);
        w.level.assign(3, 0.5f);
        wineCreate(u, 10, w);
        CHECK(u.format.mChannelsPerFrame == 3 && is(u.callback.inputProc, kWine), "2.1 was touched");
        dispose(u);
    }
    {
        g_fromWine = false;
        FakeUnit u;
        FakeWine w;
        w.fmt = wineFormat(8, true, 32);
        w.level.assign(8, 0.5f);
        wineCreate(u, 10, w);
        CHECK(u.format.mChannelsPerFrame == 8 && is(u.callback.inputProc, kWine), "a call not from Wine was touched");
        dispose(u);
        g_fromWine = true;
    }
    {
        FakeUnit u;
        u.rejectChannels = 2;
        FakeWine w;
        w.fmt = wineFormat(8, true, 32);
        w.level.assign(8, 0.5f);
        wineCreate(u, 10, w);
        CHECK(u.format.mChannelsPerFrame == 8 && is(u.callback.inputProc, kWine),
              "a unit refusing stereo should get the game's own format and Wine's callback");
        dispose(u);
    }
    {
        anvil_audio::g_state.store(0);
        FakeUnit u;
        FakeWine w;
        w.fmt = wineFormat(8, true, 32);
        w.level.assign(8, 0.5f);
        wineCreate(u, 10, w);
        CHECK(u.format.mChannelsPerFrame == 8 && is(u.callback.inputProc, kWine), "ANVIL_AUDIO_FOLD=0 was ignored");
        dispose(u);
        anvil_audio::g_state.store(1);
    }

    // A unit that will not take the wrapper goes back to the game's width before Wine's
    // own callback goes in, so that callback never writes 8 channels into a 2-channel buffer.
    {
        FakeUnit u;
        u.callbackError = kAudioUnitErr_InvalidProperty;
        FakeWine w;
        w.fmt = wineFormat(8, true, 32);
        w.level.assign(8, 0.5f);
        wineCreate(u, 10, w);
        CHECK(u.format.mChannelsPerFrame == 8, "after a refused wrapper the unit should be back at 8, is %u",
              u.format.mChannelsPerFrame);
        dispose(u);
    }

    // Is-format-supported: a format on a unit that is thrown away without a callback.
    {
        FakeUnit u;
        auto* unit = reinterpret_cast<AudioUnit>(&u);
        AudioDeviceID device = 10;
        anvil_AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device,
                                   sizeof(device));
        const auto fmt = wineFormat(8, true, 32);
        anvil_AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &fmt, sizeof(fmt));
        dispose(u);
    }

    // Buffers in a shape the wrapper did not set up: the game's own width goes straight to
    // Wine; anything else is silent, but Wine still advances.
    {
        FakeUnit u;
        FakeWine w;
        w.fmt = wineFormat(8, true, 32);
        w.level.assign(8, 0.5f);
        wineCreate(u, 10, w);
        const auto wide = pull<float>(u, 32, 8);
        CHECK(near(wide[2], 0.5f * ramp(0)), "a buffer at the game's width should be Wine's own samples");
        const uint64_t before = w.position;
        const auto odd = pull<float>(u, 32, 3);
        bool silent = true;
        for (float v : odd) silent = silent && v == 0.0f;
        CHECK(silent, "a buffer of unexpected width should be silent");
        CHECK(w.position == before + 32, "Wine should still be asked for the frames of an odd buffer");
        dispose(u);
    }

    // Drop-outs: the game's sound cut off dead and back a moment later counts; a sound fading
    // out, a stretch too short to hear or long enough to be a pause doesn't.
    {
        auto dropsAfter = [](uint64_t silentFrom, uint64_t silentTo, uint64_t fadeFrom, UInt32 total) {
            FakeUnit u;
            FakeWine w;
            w.fmt = wineFormat(8, true, 32);
            w.level.assign(8, 0.4f);
            w.silentFrom = silentFrom; w.silentTo = silentTo; w.fadeFrom = fadeFrom;
            wineCreate(u, 10, w);
            const uint64_t before = anvil_audio::g_dropouts.load(), framesBefore = anvil_audio::g_droppedFrames.load();
            for (UInt32 done = 0; done < total; done += 512) pull<float>(u, 512);
            dispose(u);
            return std::make_pair(anvil_audio::g_dropouts.load() - before, anvil_audio::g_droppedFrames.load() - framesBefore);
        };
        const auto cut = dropsAfter(1000, 1200, UINT64_MAX, 4096);
        CHECK(cut.first == 1 && cut.second == 200, "200 frames cut off dead mid-sound: one drop-out of 200 frames (%llu, %llu)",
              (unsigned long long)cut.first, (unsigned long long)cut.second);
        const auto acrossBuffers = dropsAfter(500, 1300, UINT64_MAX, 4096);
        CHECK(acrossBuffers.first == 1 && acrossBuffers.second == 800, "across buffers: one drop-out of 800 frames (%llu, %llu)",
              (unsigned long long)acrossBuffers.first, (unsigned long long)acrossBuffers.second);
        CHECK(dropsAfter(1000, 1020, UINT64_MAX, 4096).first == 0, "20 frames of silence: too short to count");
        CHECK(dropsAfter(1000, 1000 + 20000, UINT64_MAX, 24576).first == 0, "silence of 0.4 s: a pause, not a drop-out");
        CHECK(dropsAfter(UINT64_MAX, 0, 1000, 4096).first == 0, "a sound fading to silence: not a drop-out");
    }

    // The table the app's panel is held to as well (sound_output_cases.txt): who listens on each
    // kind of output, and whether 3D sound takes a game's 7.1 mix there.
    {
        std::ifstream table("Native/Tools/tests/sound_output_cases.txt");
        CHECK(table.good(), "sound_output_cases.txt not found (run from the Anvil folder)");
        const std::map<std::string, UInt32> connections = {
            {"builtin", kAudioDeviceTransportTypeBuiltIn}, {"bluetooth", kAudioDeviceTransportTypeBluetooth},
            {"bluetoothLE", kAudioDeviceTransportTypeBluetoothLE}, {"usb", kAudioDeviceTransportTypeUSB},
            {"hdmi", kAudioDeviceTransportTypeHDMI}, {"displayport", kAudioDeviceTransportTypeDisplayPort},
            {"airplay", kAudioDeviceTransportTypeAirPlay}, {"thunderbolt", kAudioDeviceTransportTypeThunderbolt},
            {"virtual", kAudioDeviceTransportTypeVirtual}, {"aggregate", kAudioDeviceTransportTypeAggregate}};
        const std::map<std::string, anvil_audio::Listener> listeners = {
            {"headphones", anvil_audio::Listener::headphones}, {"builtInSpeakers", anvil_audio::Listener::builtInSpeakers},
            {"externalSpeakers", anvil_audio::Listener::externalSpeakers}, {"surround", anvil_audio::Listener::surround}};
        auto trim = [](std::string t) {
            const size_t a = t.find_first_not_of(" \t"), b = t.find_last_not_of(" \t");
            return a == std::string::npos ? std::string() : t.substr(a, b - a + 1);
        };
        anvil_audio::g_backend.deviceName = &fakeName;
        anvil_audio::g_backend.dataSource = &fakeSource;
        setenv("ANVIL_SPATIAL", "1", 1);
        int rows = 0;
        std::string line;
        while (std::getline(table, line)) {
            if (line.empty() || line[0] == '#') continue;
            std::vector<std::string> f;
            std::stringstream cells(line);
            for (std::string cell; std::getline(cells, cell, '|');) f.push_back(trim(cell));
            if (f.size() != 7 || !connections.count(f[0]) || !listeners.count(f[5])) {
                CHECK(false, "table row not understood: %s", line.c_str());
                continue;
            }
            ++rows;
            const AudioDeviceID device = 200;
            g_outputs[device] = static_cast<UInt32>(std::stoul(f[1]));
            g_transports[device] = connections.at(f[0]);
            g_caseSource = f[2].size() == 4 ? (UInt32(f[2][0]) << 24 | UInt32(f[2][1]) << 16 | UInt32(f[2][2]) << 8 | UInt32(f[2][3])) : 0;
            g_caseName = f[4];
            setenv("ANVIL_SPATIAL_OUTPUT", f[3].c_str(), 1);
            const auto listener = anvil_audio::listenerFor(device, g_transports[device], g_outputs[device]);
            CHECK(listener == listeners.at(f[5]), "%s (%s, %s ch, %s): libanvil hears %s, the table says %s", f[4].c_str(),
                  f[0].c_str(), f[1].c_str(), f[3].c_str(), anvil_audio::listenerName(listener), f[5].c_str());
            // A game's 7.1 mix, as Wine asks for it on that output.
            FakeUnit u;
            u.device = device;
            const AudioStreamBasicDescription mix = wineFormat(8, true, 32);
            anvil_audio::Stream* planned = anvil_audio::plan(reinterpret_cast<AudioUnit>(&u), mix);
            const bool spatial = planned && planned->spatial;
            const bool compatible = f[6] == "threeD" || f[6] == "virtualSurround" || f[6] == "surround";
            CHECK(spatial == compatible, "%s (%s, %s ch): libanvil's 3D sound %s it, the table says %s", f[4].c_str(),
                  f[0].c_str(), f[1].c_str(), spatial ? "takes" : "leaves", f[6].c_str());
            if (spatial)
                CHECK(planned->listener == listeners.at(f[5]), "%s: planned for %s, the table says %s", f[4].c_str(),
                      anvil_audio::listenerName(planned->listener), f[5].c_str());
            anvil_audio::release(planned);
        }
        CHECK(rows >= 25, "only %d rows read from the table", rows);
        unsetenv("ANVIL_SPATIAL");
        unsetenv("ANVIL_SPATIAL_OUTPUT");
        anvil_audio::g_backend.deviceName = nullptr;
        anvil_audio::g_backend.dataSource = nullptr;
        g_outputs.erase(200);
        g_transports.erase(200);
        printf("sound output table: %d rows agree with libanvil\n", rows);
    }

    {
        anvil_audio::Locked l;
        CHECK(anvil_audio::g_streams == nullptr, "streams left behind after every unit was disposed");
    }

    const std::string log = logText(logPath);
    CHECK(log.find("the game mixes 8 channels (7.1) and this output (built-in speakers or headphone jack) plays 2 — "
                   "folding the mix into stereo") != std::string::npos, "no fold-down line in the log:\n%s", log.c_str());
    CHECK(log.find("7.1 stream closed after") != std::string::npos, "no closing line in the log");
    CHECK(log.find("left as it is: the output plays that many") != std::string::npos, "no line for 7.1 on 7.1");
    CHECK(log.find("the game plays stereo and this output") != std::string::npos, "no line for stereo on mono");
    size_t lines = 0;
    for (char ch : log) lines += ch == '\n';
    CHECK(lines <= 40, "the log has %zu lines", lines);
    unlink(logPath);

    if (failures) { printf("%d failures\n", failures); return 1; }
    printf("all checks passed\n%s", log.c_str());
    return 0;
}

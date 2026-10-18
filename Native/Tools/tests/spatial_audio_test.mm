// 3D sound, run on the library's own code with Apple's real spatial mixer and stand-ins for
// CoreAudio's output unit and Wine's driver. A tone is put in one channel of the game's mix at a
// time and what reaches the two ears (or the surround system's speakers) is measured: each
// channel must come from its own side, the centre from both, and nothing may be lost. Needs
// AudioToolbox's audio units, so it runs in a terminal of the Mac's own, not a sandbox.
//
//   clang++ -std=c++17 -ObjC++ -DANVIL_AUDIO_TEST -g -framework AudioToolbox -framework CoreAudio \
//     -framework Foundation Native/Tools/tests/spatial_audio_test.mm -o spatial_audio_test && ./spatial_audio_test
#include "../../AnvilMetal/anvil_audio.mm"
#include <chrono>
#include <cmath>
#include <cstdio>
#include <map>
#include <vector>

static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { ++failures; printf("FAIL %s:%d: ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); } \
                              else { printf("ok: "); printf(__VA_ARGS__); printf("\n"); } } while (0)

// --- CoreAudio's output unit -------------------------------------------------------------------
struct FakeUnit {
    AudioDeviceID device = 0;
    UInt32 maxFrames = 512;
    AudioStreamBasicDescription format = {};
    AURenderCallbackStruct callback = {};
};
struct FakeDevice { UInt32 channels; UInt32 transport; UInt32 source; const char* name; AudioChannelLayoutTag layout; };
static std::map<AudioDeviceID, FakeDevice> g_devices = {
    {20, {2, kAudioDeviceTransportTypeBuiltIn, 'hdpn', "MacBook Pro Headphones", 0}},
    {21, {2, kAudioDeviceTransportTypeBuiltIn, 'ispk', "MacBook Pro Speakers", 0}},
    {22, {2, kAudioDeviceTransportTypeBluetooth, 0, "AirPods Pro", 0}},
    {23, {2, kAudioDeviceTransportTypeBluetooth, 0, "JBL Flip 6 Speaker", 0}},
    {24, {8, kAudioDeviceTransportTypeHDMI, 0, "AV Receiver", kAudioChannelLayoutTag_WAVE_7_1}},
    {25, {6, kAudioDeviceTransportTypeHDMI, 0, "TV 5.1", kAudioChannelLayoutTag_MPEG_5_1_A}},
    {26, {2, kAudioDeviceTransportTypeUSB, 0, "SteelSeries Arctis 7", 0}},
};
static OSStatus fakeSet(AudioUnit unit, AudioUnitPropertyID id, AudioUnitScope, AudioUnitElement, const void* data, UInt32) {
    auto* u = reinterpret_cast<FakeUnit*>(unit);
    if (id == kAudioOutputUnitProperty_CurrentDevice) { u->device = *static_cast<const AudioDeviceID*>(data); return noErr; }
    if (id == kAudioUnitProperty_StreamFormat) { u->format = *static_cast<const AudioStreamBasicDescription*>(data); return noErr; }
    if (id == kAudioUnitProperty_SetRenderCallback) { u->callback = *static_cast<const AURenderCallbackStruct*>(data); return noErr; }
    return noErr;
}
static OSStatus fakeGet(AudioUnit unit, AudioUnitPropertyID id, AudioUnitScope, AudioUnitElement, void* data, UInt32*) {
    auto* u = reinterpret_cast<FakeUnit*>(unit);
    if (id == kAudioOutputUnitProperty_CurrentDevice) { *static_cast<AudioDeviceID*>(data) = u->device; return noErr; }
    if (id == kAudioUnitProperty_MaximumFramesPerSlice) { *static_cast<UInt32*>(data) = u->maxFrames; return noErr; }
    return kAudioUnitErr_InvalidProperty;
}
static OSStatus fakeDispose(AudioComponentInstance) { return noErr; }
static UInt32 fakeChannels(AudioDeviceID d) { return g_devices.count(d) ? g_devices[d].channels : 0; }
static UInt32 fakeTransport(AudioDeviceID d) { return g_devices.count(d) ? g_devices[d].transport : 0; }
static UInt32 fakeSource(AudioDeviceID d) { return g_devices.count(d) ? g_devices[d].source : 0; }
static bool fakeName(AudioDeviceID d, char* out, size_t room) { if (!g_devices.count(d)) return false; snprintf(out, room, "%s", g_devices[d].name); return true; }
static bool g_fromWine = true;
static bool fakeFromWine(const void*) { return g_fromWine; }
static int g_passedThrough = 0;
static OSStatus fakeObjectSize(AudioObjectID d, const AudioObjectPropertyAddress* a, UInt32, const void*, UInt32* size) {
    if (a->mSelector == kAudioDevicePropertyPreferredChannelLayout && g_devices.count(d) && g_devices[d].layout) {
        *size = sizeof(AudioChannelLayout); return noErr;
    }
    ++g_passedThrough;
    *size = 4;
    return kAudioHardwareUnknownPropertyError;
}
static OSStatus fakeObject(AudioObjectID d, const AudioObjectPropertyAddress* a, UInt32, const void*, UInt32* size, void* data) {
    if (a->mSelector == kAudioDevicePropertyPreferredChannelLayout && g_devices.count(d) && g_devices[d].layout) {
        AudioChannelLayout l = {};
        l.mChannelLayoutTag = g_devices[d].layout;
        memcpy(data, &l, sizeof l);
        *size = sizeof l;
        return noErr;
    }
    ++g_passedThrough;
    return kAudioHardwareUnknownPropertyError;
}

// --- Wine's driver: a tone in one channel of the game's mix --------------------------------------
struct FakeWine {
    AudioStreamBasicDescription fmt = {};
    int toneChannel = 0;
    uint64_t position = 0;
    // Anvil Surround's tests: 1 the same noise in the front pair (a voice in the middle), 2 unrelated
    // noise in each (a room); and a tone in `laterChannel` from `laterFrom` on.
    int stereo = 0;
    int laterChannel = -1;
    uint64_t laterFrom = 0;
    uint32_t seedL = 1, seedR = 2;
};
static float nextNoise(uint32_t& x) { x = x * 1664525u + 1013904223u; return (static_cast<float>(x >> 8) / 16777216.0f - 0.5f) * 0.6f; }
static OSStatus wineRender(void* user, AudioUnitRenderActionFlags*, const AudioTimeStamp*, UInt32, UInt32 frames,
                           AudioBufferList* data) noexcept [[clang::nonblocking]] {
    auto* w = static_cast<FakeWine*>(user);
    const UInt32 channels = w->fmt.mChannelsPerFrame, bytes = w->fmt.mBitsPerChannel / 8;
    auto* out = static_cast<uint8_t*>(data->mBuffers[0].mData);
    for (UInt32 i = 0; i < frames; ++i, ++w->position) {
        const float tone = 0.3f * sinf(static_cast<float>(w->position) * 2.0f * 3.14159265f * 500.0f / 48000.0f);
        float nl = 0.0f, nr = 0.0f;
        if (w->stereo) { nl = nextNoise(w->seedL); nr = w->stereo == 1 ? nl : nextNoise(w->seedR); }
        for (UInt32 c = 0; c < channels; ++c) {
            float v = w->stereo ? (c == 0 ? nl : c == 1 ? nr : 0.0f) : (static_cast<int>(c) == w->toneChannel ? tone : 0.0f);
            if (static_cast<int>(c) == w->laterChannel && w->position >= w->laterFrom) v += tone;
            uint8_t* p = out + static_cast<size_t>(i) * w->fmt.mBytesPerFrame + c * bytes;
            if (w->fmt.mFormatFlags & kAudioFormatFlagIsFloat) memcpy(p, &v, 4);
            else { int16_t s = static_cast<int16_t>(lrintf(v * 32767)); memcpy(p, &s, 2); }
        }
    }
    return noErr;
}
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
static void create(FakeUnit& u, AudioDeviceID device, FakeWine& w) {
    auto* unit = reinterpret_cast<AudioUnit>(&u);
    anvil_AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, sizeof device);
    anvil_AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &w.fmt, sizeof w.fmt);
    AURenderCallbackStruct cb = {&wineRender, &w};
    anvil_AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, sizeof cb);
}

/// The energy of each output channel over the last second of `seconds` rendered.
static std::vector<double> energy(FakeUnit& u, double seconds = 1.25) {
    const UInt32 out = u.format.mChannelsPerFrame;
    std::vector<double> sum(out, 0.0);
    std::vector<float> buffer(512 * out);
    AudioTimeStamp ts = {};
    ts.mFlags = kAudioTimeStampSampleTimeValid | kAudioTimeStampHostTimeValid;
    const int blocks = static_cast<int>(48000 * seconds / 512), skip = blocks - 48000 / 512;
    for (int b = 0; b < blocks; ++b) {
        AudioBufferList io;
        io.mNumberBuffers = 1;
        io.mBuffers[0] = {out, static_cast<UInt32>(buffer.size() * sizeof(float)), buffer.data()};
        AudioUnitRenderActionFlags flags = 0;
        u.callback.inputProc(u.callback.inputProcRefCon, &flags, &ts, 0, 512, &io);
        ts.mSampleTime += 512;
        ts.mHostTime += 512 * 24000 / 1000;
        if (b < skip) continue;
        for (size_t i = 0; i < buffer.size(); ++i) {
            if (!std::isfinite(buffer[i])) { sum.assign(out, -1.0); return sum; }
            sum[i % out] += buffer[i] * buffer[i];
        }
    }
    return sum;
}
static void dispose(FakeUnit& u) { anvil_AudioComponentInstanceDispose(reinterpret_cast<AudioComponentInstance>(&u)); }

static const char* kNames[8] = {"front left", "front right", "centre", "LFE", "back left", "back right", "side left", "side right"};

int main() {
    setvbuf(stdout, nullptr, _IONBF, 0);
    char logPath[] = "/tmp/anvil_spatial_test_XXXXXX";
    const int fd = mkstemp(logPath);
    if (fd >= 0) close(fd);
    setenv("ANVIL_LOG", logPath, 1);
    anvil_audio::g_backend = {&fakeSet, &fakeGet, &fakeDispose, &fakeChannels, &fakeTransport, &fakeFromWine,
                              &fakeSource, &fakeName, &fakeObjectSize, &fakeObject};
    setenv("ANVIL_SPATIAL", "1", 1);

    // Can this Mac's AudioToolbox make the mixer at all?
    {
        const AudioComponentDescription d = {kAudioUnitType_Mixer, kAudioUnitSubType_SpatialMixer, kAudioUnitManufacturer_Apple, 0, 0};
        AudioComponent c = AudioComponentFindNext(nullptr, &d);
        AudioUnit m = nullptr;
        if (!c || AudioComponentInstanceNew(c, &m) != noErr) { printf("spatial audio: AUSpatialMixer can't be made here (a sandbox?) — skipped\n"); return 2; }
        AudioComponentInstanceDispose(m);
    }

    // 1. LEGO Star Wars' 7.1 on headphones: each channel from its own side, nothing lost.
    {
        FakeUnit probe; FakeWine w0; w0.fmt = wineFormat(8, true, 32);
        create(probe, 20, w0);
        CHECK(probe.format.mChannelsPerFrame == 2 && (probe.format.mFormatFlags & kAudioFormatFlagIsFloat),
              "7.1 on headphones: the output unit is given two channels of float (%u)", probe.format.mChannelsPerFrame);
        dispose(probe);
        for (int ch = 0; ch < 8; ++ch) {
            if (ch == 3) continue;                      // the LFE, below
            FakeUnit u; FakeWine w; w.fmt = wineFormat(8, true, 32); w.toneChannel = ch;
            create(u, 20, w);
            const auto e = energy(u);
            const double l = e[0], r = e[1], db = 10.0 * log10((l + 1e-12) / (r + 1e-12));
            printf("   headphones, %-11s → left %.1f, right %.1f (%+.1f dB left)\n", kNames[ch], l, r, db);
            const bool left = ch == 0 || ch == 4 || ch == 6, right = ch == 1 || ch == 5 || ch == 7;
            if (left) CHECK(db > 3.0 && r > 0.0, "headphones: %s comes from the left (%+.1f dB), and reaches the right ear too", kNames[ch], db);
            if (right) CHECK(db < -3.0 && l > 0.0, "headphones: %s comes from the right (%+.1f dB), and reaches the left ear too", kNames[ch], db);
            if (ch == 2) CHECK(fabs(db) < 1.5 && l > 100.0, "headphones: the centre (voices) from straight ahead (%+.1f dB), and heard", db);
            dispose(u);
        }
        FakeUnit u; FakeWine w; w.fmt = wineFormat(8, true, 32); w.toneChannel = 3;
        create(u, 20, w);
        const auto e = energy(u);
        printf("   headphones, LFE         → left %.1f, right %.1f\n", e[0], e[1]);
        CHECK(e[0] >= 0.0 && e[1] >= 0.0, "headphones: the LFE renders without fault");
        dispose(u);
    }

    // 2. The same on a MacBook's speakers, AirPods, a USB headset and Bluetooth speakers.
    for (AudioDeviceID d : {21u, 22u, 26u, 23u}) {
        FakeUnit u; FakeWine w; w.fmt = wineFormat(8, true, 32); w.toneChannel = 6;   // side left
        create(u, d, w);
        const auto e = energy(u);
        const double db = 10.0 * log10((e[0] + 1e-12) / (e[1] + 1e-12));
        printf("   %-22s side left → %+.1f dB left\n", g_devices[d].name, db);
        if (d == 21)
            // Apple's rendering for a Mac's own speakers places sound by cancelling what each ear hears
            // of the far speaker, not by loudness: both play, and only listening says where it is.
            CHECK(e[0] > 10.0 && e[1] > 10.0, "%s: both speakers play, rendered for this Mac's own (direction is by listening)", g_devices[d].name);
        else
            CHECK(e[0] > 0.0 && db > 1.0, "%s: a sound on the left is on the left (%+.1f dB)", g_devices[d].name, db);
        dispose(u);
    }

    // 3. A stereo game on headphones: placed in front, as speakers would be — not glued to each ear.
    {
        FakeUnit u; FakeWine w; w.fmt = wineFormat(2, false, 16); w.toneChannel = 0;
        create(u, 20, w);
        CHECK(u.format.mChannelsPerFrame == 2 && (u.format.mFormatFlags & kAudioFormatFlagIsFloat),
              "stereo (16-bit) on headphones: through 3D sound too");
        const auto e = energy(u);
        const double db = 10.0 * log10((e[0] + 1e-12) / (e[1] + 1e-12));
        printf("   stereo game, left only → %+.1f dB left\n", db);
        CHECK(db > 2.0 && db < 30.0, "stereo's left speaker heard mostly on the left, a little on the right, as a real speaker is (%+.1f dB)", db);
        dispose(u);
    }

    // 4. A real 7.1 receiver: each channel of Windows' 7.1 to the speaker of the same name, though
    // the receiver orders them otherwise (CoreAudio's WAVE 7.1 has the back pair before the sides,
    // as Windows does; MPEG 5.1 A puts the centre third). And 7.1 on a 5.1 TV: the sides placed.
    {
        FakeUnit u; FakeWine w; w.fmt = wineFormat(8, true, 32); w.toneChannel = 6;   // side left
        create(u, 24, w);
        CHECK(u.format.mChannelsPerFrame == 8, "7.1 on a 7.1 receiver: eight channels out (%u)", u.format.mChannelsPerFrame);
        const auto e = energy(u);
        int loudest = 0;
        for (int i = 1; i < 8; ++i) if (e[i] > e[loudest]) loudest = i;
        printf("   7.1 receiver, side left → speaker %d\n", loudest);
        CHECK(loudest == 6, "7.1 receiver: side left to its side-left speaker (%d)", loudest);
        dispose(u);
        FakeUnit t; FakeWine w2; w2.fmt = wineFormat(8, true, 32); w2.toneChannel = 2;   // centre
        create(t, 25, w2);
        const auto e2 = energy(t);
        int top = 0;
        for (size_t i = 1; i < e2.size(); ++i) if (e2[i] > e2[top]) top = static_cast<int>(i);
        printf("   5.1 TV, centre → speaker %d of %zu\n", top, e2.size());
        CHECK(e2.size() == 6 && top == 2, "7.1 on a 5.1 TV: the centre to the TV's centre (MPEG 5.1 A's third) (%d)", top);
        dispose(t);
    }

    // 5. What Wine's driver is told: a stereo output plays 7.1, when 3D sound is on.
    {
        AudioObjectPropertyAddress a = {kAudioDevicePropertyPreferredChannelLayout, kAudioObjectPropertyScopeOutput, 0};
        UInt32 size = 0;
        CHECK(anvil_AudioObjectGetPropertyDataSize(22, &a, 0, nullptr, &size) == noErr && size > sizeof(AudioChannelLayout),
              "Wine asks AirPods' layout: an answer for eight speakers (%u bytes)", size);
        std::vector<uint8_t> buffer(size);
        auto* layout = reinterpret_cast<AudioChannelLayout*>(buffer.data());
        CHECK(anvil_AudioObjectGetPropertyData(22, &a, 0, nullptr, &size, layout) == noErr && layout->mNumberChannelDescriptions == 8
              && layout->mChannelDescriptions[4].mChannelLabel == kAudioChannelLabel_LeftSurround
              && layout->mChannelDescriptions[6].mChannelLabel == kAudioChannelLabel_LeftSurroundDirect,
              "…eight, labelled as Wine reads them into Windows' 7.1");
        const int before = g_passedThrough;
        anvil_AudioObjectGetPropertyDataSize(24, &a, 0, nullptr, &size);
        a.mScope = kAudioObjectPropertyScopeInput;
        anvil_AudioObjectGetPropertyDataSize(22, &a, 0, nullptr, &size);
        a.mScope = kAudioObjectPropertyScopeOutput;
        g_fromWine = false;
        anvil_AudioObjectGetPropertyDataSize(22, &a, 0, nullptr, &size);
        g_fromWine = true;
        setenv("ANVIL_SPATIAL", "0", 1);
        anvil_AudioObjectGetPropertyDataSize(22, &a, 0, nullptr, &size);
        setenv("ANVIL_SPATIAL", "1", 1);
        CHECK(g_passedThrough - before == 3, "a real surround system's own answer, a microphone's, anyone but Wine's, and 3D sound off: "
              "passed through (%d of 4 asked; the receiver's own layout is answered by the stand-in itself)", g_passedThrough - before);
    }

    // 6. What it costs: a second of 7.1 rendered for headphones.
    {
        FakeUnit u; FakeWine w; w.fmt = wineFormat(8, true, 32); w.toneChannel = 0;
        create(u, 20, w);
        const auto start = std::chrono::steady_clock::now();
        energy(u);
        const double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count() / 1.25;
        printf("   a second of 7.1 to headphones in %.1f ms of one core\n", ms);
        CHECK(ms < 50.0, "3D sound costs under 5%% of a core (%.1f ms a second)", ms);
        dispose(u);
    }

    // 7. Anvil Surround, with Apple's own mixer after it.
    {
        // A stereo game: made 7.1 before the mixer. A voice in the middle stays straight ahead.
        FakeUnit u; FakeWine w; w.fmt = wineFormat(2, true, 32); w.stereo = 1;
        create(u, 20, w);
        anvil_audio::Stream* st = nullptr;
        { anvil_audio::Locked l; st = anvil_audio::find(reinterpret_cast<AudioUnit>(&u)); }
        CHECK(st && st->spatial && st->upmix == anvil_audio::Stream::Upmix::stereo && st->bed == 8 && st->upmixer,
              "a stereo game on headphones: made 7.1 by Anvil Surround before the mixer (bed %u)", st ? st->bed : 0);
        const auto e = energy(u);
        const double db = 10.0 * log10((e[0] + 1e-12) / (e[1] + 1e-12));
        CHECK(fabs(db) < 1.5 && e[0] > 10.0, "a voice in the middle of a stereo game: straight ahead on headphones (%+.1f dB)", db);
        dispose(u);
        // The same voice with Anvil Surround off: as loud, within 3 dB.
        setenv("ANVIL_UPMIX", "0", 1);
        FakeUnit o; FakeWine wo; wo.fmt = wineFormat(2, true, 32); wo.stereo = 1;
        create(o, 20, wo);
        { anvil_audio::Locked l; st = anvil_audio::find(reinterpret_cast<AudioUnit>(&o)); }
        CHECK(st && st->upmix == anvil_audio::Stream::Upmix::off && st->bed == 2, "Anvil Surround off: the stereo placed as it is");
        const auto eo = energy(o);
        const double change = 10.0 * log10((e[0] + e[1]) / (eo[0] + eo[1] + 1e-12));
        CHECK(fabs(change) < 3.0, "Anvil Surround keeps a stereo game's loudness (%+.1f dB against off)", change);
        dispose(o);
        setenv("ANVIL_UPMIX", "1", 1);
    }
    {
        // On a 5.1 TV: the split is 5.1, each channel to its own speaker — the voice to the TV's
        // centre, the room to its surrounds.
        FakeUnit u; FakeWine w; w.fmt = wineFormat(2, false, 16); w.stereo = 1;
        create(u, 25, w);
        const auto e = energy(u);
        int top = 0;
        for (size_t i = 1; i < e.size(); ++i) if (e[i] > e[top]) top = static_cast<int>(i);
        CHECK(e.size() == 6 && top == 2, "a stereo game's voice on a 5.1 TV: from its centre speaker (%d)", top);
        dispose(u);
        FakeUnit r; FakeWine wr; wr.fmt = wineFormat(2, false, 16); wr.stereo = 2;
        create(r, 25, wr);
        const auto er = energy(r);
        double sum = 0; for (double v : er) sum += v;
        const double around = (er[4] + er[5]) / (sum + 1e-12);
        CHECK(around > 0.2 && er[2] < 0.05 * sum, "a stereo game's room on a 5.1 TV: %.0f%% from its surround speakers, little from the centre", 100 * around);
        dispose(r);
    }
    {
        // A 7.1 mix with sound in its front pair only (XAudio2 placing a stereo game): split after
        // 4 s, so the 7.1 receiver's surrounds play the room; the first sound the game puts in
        // another channel hands the mix back.
        FakeUnit u; FakeWine w; w.fmt = wineFormat(8, true, 32); w.stereo = 2; w.laterChannel = 4; w.laterFrom = 48000 * 7;
        create(u, 24, w);
        anvil_audio::Stream* st = nullptr;
        { anvil_audio::Locked l; st = anvil_audio::find(reinterpret_cast<AudioUnit>(&u)); }
        CHECK(st && st->upmix == anvil_audio::Stream::Upmix::watching, "a 7.1 mix: watched");
        const auto early = energy(u, 2.0);
        CHECK(st && st->watch.load() == 0 && early[6] + early[7] + early[4] + early[5] < 1e-6 * (early[0] + early[1]),
              "a 7.1 mix with sound only in its front pair, first 2 s: left as the game mixed it");
        const auto split = energy(u, 3.5);                // to 5.5 s
        double sum = 0; for (double v : split) sum += v;
        const double around = (split[4] + split[5] + split[6] + split[7]) / (sum + 1e-12);
        CHECK(st && st->watch.load() == 1 && around > 0.2,
              "…after 4 s of the front pair alone: split, %.0f%% of the room from beside and behind", 100 * around);
        energy(u, 2.0);                                   // to 7.5 s: the game's own back-left tone from 7 s
        CHECK(st && st->watch.load() == 2 && st->blend == 0.0f, "…the game's own back-left sound hands the mix back for good");
        const auto back = energy(u, 1.0);
        double sumBack = 0; for (double v : back) sumBack += v;
        CHECK(back[6] + back[7] < 0.01 * sumBack, "…and the side speakers fall quiet again (%.2f%%)", 100 * (back[6] + back[7]) / (sumBack + 1e-12));
        anvil_audio::sayWatches();
        dispose(u);
        // A game mixing its own surround from the start is never split.
        FakeUnit g; FakeWine wg; wg.fmt = wineFormat(8, true, 32); wg.toneChannel = 2;
        create(g, 20, wg);
        energy(g, 5.0);
        { anvil_audio::Locked l; st = anvil_audio::find(reinterpret_cast<AudioUnit>(&g)); }
        CHECK(st && st->watch.load() == 2 && st->blend == 0.0f, "a game with its own centre channel: left as it mixes, throughout");
        anvil_audio::sayWatches();
        dispose(g);
    }

    FILE* f = fopen(logPath, "r");
    char line[512];
    while (f && fgets(line, sizeof line, f)) printf("   log: %s", line);
    if (f) fclose(f);
    unlink(logPath);
    printf(failures ? "spatial audio: %d failure(s)\n" : "spatial audio: all checks passed\n", failures);
    return failures ? 1 : 0;
}

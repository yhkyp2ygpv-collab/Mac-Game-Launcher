import Foundation

/// Version and release notes.
///
/// The notes live here rather than in a downloaded file so the running build can
/// always say exactly what it is — the point is to be able to tell whether the app
/// in front of you includes a given fix.
enum AnvilVersion {
    static let current = "0.58.1"
    static let build = buildStamp

    /// Baked at compile time from the source's own modification date, so two builds
    /// of the same version are still distinguishable.
    private static var buildStamp: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd.HHmm"
        let url = Bundle.main.executableURL
        let date = (try? url?.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate) ?? Date()
        return formatter.string(from: date)
    }

    static var display: String { "Anvil \(current) (\(build))" }

    struct Release: Identifiable {
        var id: String { version }
        var version: String
        var date: String
        var headline: String
        var fixed: [String]
        var added: [String]
        /// Stated plainly, because a release note that only lists wins is marketing.
        var known: [String]
    }

    static let releases: [Release] = [
        Release(
            version: "0.58.1",
            date: "17 October 2026",
            headline: "Anvil is open: its source code is published, under the Anvil Source License.",
            fixed: [],
            added: [
                "Anvil's full source code is on GitHub (github.com/yhkyp2ygpv-collab/Mac-Game-Launcher), under the Anvil Source License: free to use, build, change and share. Anyone who clones or forks it credits Jay Chirag Patel as a collaborator — in their README and credits, and as a collaborator on their repository. Selling it, or publishing it for money in any way, needs Jay Chirag Patel's written permission first.",
                "Settings › About links to the source code and says the licence's terms. The licence travels with Anvil as before (License.txt in the .dmg and in Anvil.app › Contents › Resources › Legal), and the read-me and Anvil's ownership file say it too.",
            ],
            known: [
                "Nothing about how Anvil plays has changed since 0.58.0.",
            ]),
        Release(
            version: "0.58.0",
            date: "17 October 2026",
            headline: "Smooth Motion keeps working through explosions, lightning and fire, and a crash that wasn't FSR 3's no longer takes FSR 3 and Smooth Motion away.",
            fixed: [
                "In explosions, lightning, sparks and fire, Smooth Motion mostly showed a real frame twice. Its check of each made frame looks at whether the game's two frames agree along their motion, and from 4% of the picture apart it showed the nearer real frame whole instead of the made one. Heavy LEGO Star Wars scenes — Mustafar's lava and embers, lightsabers clashing — are that far apart most of the time: on 17 October 17,608 of 27,682 made frames were a real frame again, so those scenes ran at the game's own rate with Smooth Motion's half-frame latency for nothing. Now the check leaves a map of where the frames disagree, averaged over areas, and the made frame takes the real frame's pixels only in the areas where much of what it looked at is apart — the flames, the sparks, a reflection — and stays made everywhere else: the camera's motion and the characters still between. The whole frame is the real one only from almost a third of the picture apart, a cut or a flash. On Graphics Prep's test scenes the made frames score as before; it costs under 0.1 ms a frame on an M4.",
                "LEGO Star Wars crashed 2 seconds after the Mac woke from 27 minutes asleep with it in the background, and Autopilot, seeing FSR 3 on, switched FSR 3 off for it — and with it Smooth Motion, which is made from FSR 3's pictures, so the next two hours of play had neither and filled in with frames guessed ahead. The game keeps its own crash record (a minidump), and it said otherwise: an access violation in the game's own code with Epic Online Services under it on its stack, no graphics code anywhere near, the network still off from the sleep. Anvil now reads a game's own crash record and, where it rules graphics out, leaves FSR 3 and frame generation on and says what it found. FSR 3 is back on for LEGO Star Wars (once, from Anvil's launch log and that record).",
            ],
            added: [
                "When a game closes unexpectedly, the check-up after it says what its own crash record shows, and when that came just after the Mac woke, to save before letting the Mac sleep with it open.",
                "The check-up counts the game's graphics pipelines D3DMetal couldn't build and left out (LEGO Star Wars: 4 on 17 October, 22 since 3 October) — where a missing glow or spark went. It happens in D3DMetal's own shader translation, before any of Anvil's code.",
                "Shader compile timing includes the mesh pipelines D3DMetal builds for a game's geometry shaders, so a stutter from one is put down to compiling rather than to the game's own work.",
                "The statistics line says how many made frames took the real frame's pixels where the two disagreed.",
            ],
            known: [
                "How much of a LEGO Star Wars heavy scene the made frames now keep is the next session's to show: Graphics Prep's scenes never disagree as much as Mustafar does. The log line \"N with the real frame's pixels where the two disagreed\" and \"N of M made frames the nearer real one instead\" say it.",
                "Between 60 and 80 fps of the game's own — a quarter of 17 October's play — nothing is made: a frame between needs two refreshes' room (below about 60 at 120 Hz), and holding the game to 60 to make the other 60 was tried in 0.47 and showed warped edges. Those stretches are shown as ready, the game's own frames.",
                "The heaviest scenes are the game's own drawing: in Mustafar's boss fight its scene pass alone took 21–24 ms a frame. Smooth Motion's own cost there is small — 4–7% of the game's frames, measured by Guardian turning it off and on.",
            ]),
        Release(
            version: "0.57.0",
            date: "17 October 2026",
            headline: "The frame rate Anvil shows is now the one on the screen, a held 80 holds its spacing better, and the heaviest frames are timed in full — from the logs of 16 October's LEGO Star Wars sessions.",
            fixed: [
                "The frame rate on the overlay and in the log averaged 1 ÷ each gap, which overstates uneven frames: 8.3 and 16.7 ms in turn read 90, though only 80 frames a second reach the screen. On 16 October LEGO Star Wars' held 80 showed as 91 whenever its frames were uneven and fell to 80 when they were even — a drop on the counter where the screen had got smoother. The overlay now shows frames over time (its mean gap), and the log's statistics line the window's frames over its time, a loading pause of a quarter second or more left out. Figures from now on are lower than before where frames were uneven, and true.",
                "A held 80 is less easily knocked off its spacing. Held frames (as on battery) ask the display for 10.5 ms after the one before rather than 12.0: still the 12.5 ms step on its 240 Hz grid, further from the 16.7 ms one. In a stand-in game on this Mac, frames held after a late one were even 82% of the time against 56%, and through Anvil held stretches averaged 70% even against 60%.",
                "Where the GPU's time goes was measured only for a frame's first 192 passes. LEGO Star Wars' heaviest frames have more: on 16 October a 10 fps stretch read \"GPU work 34 ms a frame\" with the GPU 90% busy at 95 ms a frame, and Anvil's own passes, which come last, read 0.0. Now up to 1024 passes, Metal's most in one sample buffer (4096 timestamps, measured on the M4), so a heavy place's numbers are whole.",
            ],
            added: [
                "The statistics line says how long a held frame waits from its present to the screen: \"steady 80: held to an even 80 (600 held, 22 ms each from present to screen)\".",
            ],
            known: [
                "A held 80 can still judder. In 42% of LEGO Star Wars' held windows on 16 October its frames reached the screen 8.3 and 16.7 ms apart in turn — the display on its own 120 Hz steps, an average 80 that judders — for up to nine minutes at a time, with nothing changed in Anvil either side. The display decides that: in the stand-in, runs alike in every way read anything from 1% to 100% even. Two ways of steering it were tried and left out, as it paid them no attention — the hold's cadence nudged sooner whenever a frame came a step late (it made frames queue and the game wait), and held frames presented only once the GPU had finished them (no steadier, 15 ms more latency). The log now says each held frame's wait to the screen, so the next session shows what the display did.",
                "The worst drop on 16 October was the game's own: 10 minutes at 9–22 fps in one heavy place, its scene pass alone 20–30 ms a frame and its shadows 4–7 ms — on a base M4, more than FSR 3 and Smooth Motion can cover (Smooth Motion stops below about 15 fps of the game's own, where frames are too far apart to make one between). Lighter graphics there are the game's settings to change.",
                "Stutters as a game first draws something are still mostly its shaders compiling: 53 of 72 on 16 October, about 100 ms each. D3DMetal compiles each one the first time the game needs it and keeps it — LEGO Star Wars' cache is 120 MB and kept between sessions — so they come where the game meets something new.",
            ]),
        Release(
            version: "0.56.0",
            date: "17 October 2026",
            headline: "Minecraft's PC version, the genuine one: Bedrock in Windows 11 through VMware Fusion, set up for Minecraft by Anvil and started straight into the game.",
            fixed: [],
            added: [
                "Minecraft › Bedrock Edition for PC. Bedrock's PC version is a Microsoft Store app that arrives encrypted and licence-locked, so it can't run under Wine without breaking that protection — which Anvil never does, and which is what gets accounts banned. It runs as it is in Windows: the Minecraft page now takes you through Windows 11 for Arm in VMware Fusion (free for personal use), with the Microsoft Store, your own Microsoft account, Xbox sign-in, Realms, the Marketplace and cross-play as on any PC.",
                "Set for Minecraft: with Windows shut down, Anvil sets the machine up for the game — processor cores and memory for this Mac, 3D graphics (DirectX 11 through Metal) and their memory, full screen as it starts, your controller plugged in to Windows as it starts, and a folder shared with Windows for its setup. Its settings as they were are kept beside them.",
                "Set up Minecraft, run once in Windows from that folder: it shows what it will do and asks first, then takes out Windows' consumer extras (news, tips, promoted apps, Teams, Copilot) and keeps the Microsoft Store, the Xbox app, Gaming Services and the Xbox sign-in; turns off widgets, suggestions and background start-ups; sets high-performance power with no sleep, Game Mode on and background recording off; installs the Minecraft Launcher from the Microsoft Store; and opens Minecraft whenever Windows signs in. Windows' security, updates and firewall are left as they are, and \"undo\" puts its settings back. What it did shows on the Minecraft page.",
                "Play and Put Away: Play starts Windows in Fusion, full screen, into Minecraft; Put Away suspends Windows with the game in it and gives its memory back to the Mac, so the next Play resumes inside Minecraft in seconds instead of booting Windows.",
            ],
            known: [
                "Installing Fusion and Windows, and signing in to Microsoft, are yours to do: Fusion makes the virtual machine itself, because Windows 11 needs the TPM Fusion only adds to a machine it encrypts, and Anvil never handles your passwords. A Windows licence is needed to activate Windows; it runs unactivated with limits until then.",
                "Windows runs Minecraft under its own x64 emulation, with DirectX 11 through Fusion — slower than on a PC. Vibrant Visuals needs DirectX 12, which Fusion doesn't give Windows.",
                "Your controller is handed to Windows as the machine starts. Whether Minecraft takes a Nintendo-style pad there depends on Windows' own drivers for it; the setup reports what Windows sees.",
                "Tested in Anvil's own checks and on the settings of a Fusion machine; the first full run on a real Windows machine is still to come.",
            ]),
        Release(
            version: "0.55.0",
            date: "17 October 2026",
            headline: "Reflections at the game's best on a standard M-series Mac, paid for by quicker upscaling — and heavy scenes keep FSR 3 and Smooth Motion instead of falling back to FSR 1 with frames guessed ahead.",
            fixed: [
                "In a heavy stretch, the picture could be at its least for minutes: FSR 1 with 0.47's frames guessed ahead. FSR 3 eases to FSR 1 when that is what lifts a game to an even 80 — at 72–76 fps with the GPU full — and comes back once there's room at 80. When the game then came into a heavier place, at 47–56 fps, FSR 1 could no longer reach 80, yet FSR 3 waited for an 80 that never came; and Smooth Motion, whose frames between are made from FSR 3's pictures, couldn't run, so frames guessed ahead filled in. LEGO Star Wars spent 63 of the 910 statistics windows of 16 October like that. Now, once the game is down in Smooth Motion's range for 2 seconds, FSR 3 comes back and Smooth Motion makes its frames between from both frames; frames guessed ahead that are already running hand over to them at once. Without Smooth Motion chosen, or above its range, FSR 1's quicker frames are kept as before.",
            ],
            added: [
                "FSR 3 and FSR 1 upscale faster at twice the game's size — a game at half a Retina display's pixels each way, the usual. Each 2×2 of the display's pixels is drawn from the same 4×4 of the game's, so the four are now worked out together: the game's pixels read and their edge found once instead of four times. On an M4 at LEGO Star Wars' sizes, FSR 3 takes 3.63 ms a frame from 3.87 and FSR 1 1.29 ms in one pass from 1.46 in two, the picture the same — every score on Graphics Prep's test scene equal to the thousandth. Graphics Prep runs again once on the next start of each game, as Anvil's shaders changed, and picks FSR 1's one pass where it's now the quicker.",
                "Ray tracing at its best on a standard GPU (a base M4 included): LEGO Star Wars' screen-space ray-traced reflections now run at the game's own quality at Light and Medium, where 0.52 to 0.54 set them a step lower. Only an entry-level GPU keeps the lighter step. The Ray Tracing switch still turns them off.",
            ],
            known: [
                "Stutters as a game first draws something new are mostly its shaders compiling: on 16 October 25 of LEGO Star Wars' 30, up to 38 shaders in one frame of 66 ms. Anvil now asks Metal to compile as many of a game's shaders at once as it can, and the log says how many — but on an M4 Metal already allowed its most, 10 at once, so there it changes nothing. A shader can't be compiled before the game first needs it: D3DMetal makes each then.",
                "Smooth Motion's made frame still takes about 1.7 ms of GPU time at LEGO Star Wars' sizes. Two ways to make it quicker were tried and left out: in two passes (its rare edge pixels on their own) it took longer, about 2.1 ms; with FSR 3's pictures kept in 10 bits instead of 16, 0.3 ms less, but too coarse for a game without its own temporal anti-aliasing.",
                "The reflections at their best cost some of the GPU's time where there's a lot to reflect: all of them at their highest came to about 0.8 ms a frame on a base M4 on 14 October. How much of that is the step from quality 2 to 3 isn't measured yet — the next session's GPU work line shows it. Where frames matter more, the Ray Tracing switch turns them off.",
            ]),
        Release(
            version: "0.54.0",
            date: "16 October 2026",
            headline: "Smooth Motion on repeating patterns: the whole picture's motion found first, so a fast pan over tiles, studs or brick is followed rather than mistaken one repeat off — and a switch for lower latency at low frame rates.",
            fixed: [
                "A fast pan over a repeating pattern broke Smooth Motion's made frames up. FSR 3's motion search matched each block of the picture on its own, and a block of tiles or studs fits one repeat off as well as at the truth — while the camera speeds up faster than the search can follow, as it does at a low frame rate, the blocks lost the true motion and the made frame came out in fragments. Now the whole picture's motion — the pan — is found first, on a blurred copy of the picture where the repeating pattern is gone and its large shapes aren't, made exact on the full picture, and offered to every block. On Graphics Prep's repeating floor with landmarks, the camera speeding up to 21 and 37 game pixels a frame: motion found right in 73% and 62% of blocks, from 6% and 3%; clearly wrong pixels in the made frame 13% and 14%, from 45% and 59%. The natural scene as before or a little better; the shipped test unchanged. It costs about 0.1 ms of GPU time a frame on an M4 at LEGO Star Wars' sizes (FSR 3's motion search, 0.88 ms without it and 0.98 with, timed with nothing else running).",
                "The pan is used only where it can be trusted: where the blurred picture holds something large enough to find it from (a floor with nothing else on it can't tell one repeat from the next, and still can't — it stays as before), and only where it fits the whole picture clearly better than what the blocks themselves followed last frame.",
            ],
            added: [
                "Upscaling › Lower latency at low frame rates (off by default). Below 55 fps with the GPU working flat out, a game starts its next frame at once and it waits behind the last on the GPU: what you do reaches the screen about two of its frames later. With this on, each frame is started only as the GPU is about to finish the last — measured from the GPU's own clock, the time covered by the game's work — so it's made from your controls then. On Anvil's test game at 18–19 fps: 15–25% less from a frame's start to the screen (102–107 ms to 76–90 without Smooth Motion; 105–109 to 94–96 with it), for 7–12% fewer frames of the game's own. A trade, so it's a choice.",
            ],
            known: [
                "A pattern repeating over the whole screen, with nothing else in view, can't be told from one repeat to the next — two frames of it look the same either way — so a very fast pan over it still breaks the made frames up, as before.",
                "Lower latency at low frame rates costs frames: tried with the game given a quarter, 0.4 and 0.55 of a frame to start its next, the cost was about the same. Learning the right amount from the GPU's own waits made it worse, so it's fixed.",
            ]),
        Release(
            version: "0.53.0",
            date: "15 October 2026",
            headline: "Epic games: how big each one is before you install it, a Cancel button for a download, and Delete for a game you've installed.",
            fixed: [
                "A stopped or failed Epic download left its folder behind with no way to see it or clear it from Anvil (Styx: Master of Shadows' 4.2 GB in ~/Games/Anvil on 15 October). The Epic page now lists any such folder with its size and a Move to Trash button — and installing that game again carries on from what's there.",
            ],
            added: [
                "An ⓘ beside each game on the Epic page: what it downloads and what it takes installed, from Epic's own list of the game's files (legendary info), with what's free on this Mac and a warning when it won't fit. While it downloads, its row says how much of how much.",
                "Cancel for an Epic download: stop and keep what's downloaded (installing again carries on from there, as legendary writes down how far it got), or stop and send the partial download to the Trash.",
                "Delete for an installed game — on the Epic page, in the library's right-click menu (Delete Game…) and on the game's page: its saves exported first to Documents › Anvil Saves (a game never played has none, and that no longer stops it), then its folder moved to the Trash, or deleted at once to free the space now, with its size said. Anvil's Epic records of it and its DLC are cleared, and it leaves the library; Install brings it back. Only the game's own folder is ever taken — never a top-level folder, the home folder or a folder of games.",
            ],
            known: [
                "The ⓘ asks Epic, so it needs a connection and a few seconds the first time for each game.",
                "A Steam game's files are Steam's: uninstall it in Steam to free its space.",
            ]),
        Release(
            version: "0.52.0",
            date: "15 October 2026",
            headline: "A Ray Tracing switch for each game, set up for your Mac by Graphics Prep; the picture no longer distorts with the game's reflections on; and Smooth Motion stops costing frames — made frames are checked before they're shown, one between each two.",
            fixed: [
                "The picture distorted with the game's own look on (14 October). Three things did it. The game's water and heat distortion ripples the picture a little differently every frame; FSR 3's blend and Smooth Motion's made frames follow a picture that moves, not one that warps. A reflection moving its own way over a floor gave Smooth Motion two motions in one place: on Graphics Prep's test scene the lines under a reflection broke into dashes and a heat haze into fragments, in the made frames only. And at three or four frames for each of the game's, each made frame stood in for up to 60 ms of motion.",
                "Medium now keeps the game's reflections and turns its water and heat distortion off, with depth of field and the motion blurs (LEGO Star Wars). A game put at its own look by 0.51's Look Check is moved to Medium once; the game's own look is still one button away.",
                "Smooth Motion made frames that broke up where the picture's two frames disagree. Now the two frames are looked at first, on the small luma planes FSR 3 already keeps (0.02 ms a frame on an M4): where more than 4% of the picture lies outside what the other frame has around it, for two frames running, the nearer real frame is shown in the made one's place until they agree again — the timing as it was, nothing warped. On Graphics Prep's scenes at four speeds the plain picture, a heat haze and sparks came to at most 2.4% and were never held, a chequerboard at most 1.7%; a reflection over the lower third moving fast enough to break the made frames, 4.9–9.2%, and held. Set to step in only where a made frame is clearly broken. Tried and dropped: more motions tried per pixel, including the pan, made the plain scene worse (2.4% of its pixels clearly wrong against 0.75%); the nearer frame for each pixel that disagreed, on its own, changed nothing visible; and a straight difference of the two frames took a chequerboard's edges for disagreement and held every made frame of it. The stats line and the Doctor say how often it happened.",
                "The frame-rate drop: Smooth Motion at three and four frames a frame cost the game its own frames. In LEGO Star Wars on 14 October Anvil's GPU work rose to 12.6 ms for each of the game's frames, and the game made 16.4 fps where it could make 25.9, with 60–85 ms between a frame being ready and being shown. Smooth Motion is back to one frame made between each two (40 fps shown as 80); three and four stay held back until they can be shown without that cost. The 30-minute session ran at 56 fps on average against 84 the night before at Light graphics, in heavier places.",
            ],
            added: [
                "A Ray Tracing switch on each game's page (in Graphics Prep) for a game with ray tracing of its own: on or off at every graphics level, Full included. LEGO Star Wars' is its reflections — its shaders trace rays through the depth of what's on screen (\"SSRRaytracedReflection\" in them) — on at Medium and Full, off at Light, unless switched. Graphics Prep sets them up for the Mac before the game starts: on a standard or entry-level GPU (a base M4) at quality 2 of the game's 3 at Light and Medium, where at their highest they cost about 0.8 ms of GPU time a frame in the heaviest places on 14 October; the game's own quality on Pro and Max. For a DirectX 12 game with ray-traced effects the switch is D3DMetal's hardware ray tracing (M3 and later). Graphics Prep's steps and the launch log say what was set.",
                "The game's frame anatomy, once a session in game.log: one frame of its 3D world, its passes in order — what each draws into, which share a depth target, which draw into the picture shown, and the GPU time of each. It's what Anvil needs to know where an effect of its own that uses the scene's depth — screen-space ray-traced light — could go in under the game's HUD rather than over it.",
                "The Look Check says what each effect is and why it's off or on: reflections (traced through what's on screen, as a DirectX 11 game does them), depth of field, and water and heat distortion — flagged where it's on, with Medium offered.",
            ],
            known: [
                "Hardware ray tracing needs the game to describe its whole scene to the GPU — DirectX 12's DXR. A DirectX 11 game like LEGO Star Wars never does, so nothing outside it can trace rays through its world. What it ray-marches is what's on screen: its reflections and ambient occlusion, which are on at Medium.",
                "The made frames' check catches a problem over much of the picture; a small one — sparks, a little heat haze — is still made between, as before.",
                "Found while testing, and not fixed in this version: on a strongly repeating pattern (a chequerboard on Graphics Prep's scene; in a game, studs, tiles or brick) panned fast — 21 game pixels a frame and more — FSR 3's motion search can lock onto the pattern one repeat off and still be sure of it. FSR 3's own picture stays clean (it doesn't believe a history that disagrees), but the frame Smooth Motion makes from that motion is broken, and the check can't see it, as the two frames do agree along the wrong motion. It's been so since 0.48; the motion search is next.",
                "With Medium's reflections the heaviest places cost a little more than at Light (about 0.8 ms of the game's GPU time a frame, measured on 14 October).",
            ]),
        Release(
            version: "0.51.0",
            date: "14 October 2026",
            headline: "Smooth Motion up to four frames for each of the game's — 20 fps shown as 80 — checked on your Mac before it's used; the Look Check; and the game's own look back, reflections and all.",
            fixed: [
                "LEGO Star Wars' reflections were off: Anvil's Light graphics, which Auto-Tune chose for it on 11 October to make it faster, turns the game's screen-space reflections, depth of field and water distortion off. The new Look Check on the game's page says so, and Use the Game's Own Look turns them back on.",
                "The game's own look (Full graphics) had its motion and speed blurs back on and its own sharpening over FSR's while FSR upscaled: both are now off at every level while FSR upscales — the blurs smear across FSR 3's blend and Smooth Motion's made frames — and back as the game had them when it doesn't.",
            ],
            added: [
                "Smooth Motion makes up to three frames between each two of the game's — at a quarter, half and three-quarters of the way — as many as bring it nearest an even 80 on a MacBook Pro (the display's own rate on one at a fixed rate): 20 fps of the game's shown as 80, 27 as 81, 40 as 80. In Anvil's stand-in at 18 fps, under Rosetta and waiting for its frames as LEGO does: 72 frames a second on the screen where it showed 21 alone and 44 with one made between, half the gaps under 12.4 ms and 90% under 25, and 98% of the game's own frames kept (789 against 802 with Smooth Motion off). The made frames at a quarter and three-quarters are as close to the true picture as the one halfway: 3.3–3.5 from it on Graphics Prep's moving scene at every speed, against 13–27 for the older frame still on screen — 1.5–1.7 ms of GPU time each on an M4.",
                "Graphics Prep now checks Smooth Motion's made frames on your Mac before the game starts, on its moving test scene: at a quarter, half and three-quarters between two frames, against the true picture at that moment. Up to four frames a frame where they come out well clear of the older frame (on this M4: 7.4 against 26.5); one made between each two where they don't. Every game is prepared once more for it before its next start.",
                "The Look Check, on each game's page: what's on and off in its picture and why — the game's reflections, depth of field and water, its shadows (as the game draws them, always), its blurs, ray tracing, and Graphics Prep's simulated test of FSR 3 and Smooth Motion on this Mac — with what would bring back what's off.",
                "Ray tracing on by itself for a DirectX 12 game that has ray-traced effects, on a Mac whose GPU traces rays in hardware (M3, M4 and later): the game offers its ray-traced reflections, shadows and lighting in its own settings. Chosen per game in the Look Check.",
            ],
            known: [
                "Smooth Motion's frames make 20 fps look like 80, but the game still answers the controls 20 times a second, and its own frames reach the screen three-quarters of a frame later with three made between (about 40 ms at 18 fps). It costs a little GPU time: 2% of the game's own frames in the stand-in.",
                "Ray tracing can only come from a game's own renderer, which knows the whole scene: a picture can't be ray traced after it's drawn. LEGO Star Wars draws with DirectX 11, which has none; its own reflections are what can be turned back on.",
                "The game's own look costs frames in the heaviest places (its reflections most); Smooth Motion carries the frames there.",
            ]),
        Release(
            version: "0.50.0",
            date: "14 October 2026",
            headline: "The memory warm-up: the parts of a game's data you play most are read into your Mac's spare unified memory as it starts — and Guardian now says what every stutter was.",
            fixed: [],
            added: [
                "The memory warm-up (on by default, on each game's Graphics page). LEGO Star Wars keeps 38 GB of data in archives of up to 4.3 GB, too much to hold in memory, and on 13 October 21 of its 22 gaps of 100 ms or more came as it reached somewhere new — reading the data for it. Now Anvil notes, while a game plays, which 4 MB pieces of its large data files it reads (this session's in full, earlier sessions' at half, so the places played lately count most), and at its next start reads the most-read pieces into memory while Wine starts and the store signs in: places played before load from memory, not the disk. It takes at most half of the memory free beyond 4 GB, no more than 8 GB — half that on battery — reads below the game's own reads in the disk's priority, and only ever reads. On 13 October's start that would have been up to 4.5 GB.",
                "Guardian's stutter reports: any frame three times as long as the game's frames had been and 50 ms or more, while it's in front, is put down to what took most of it — reading the game's data, compiling shaders, waiting on the GPU or the display, or the game's own work — with the numbers, and counted every five minutes with how much the game read and how fast. The Doctor says what the session's stutters were mostly, and what the warm-up read before it started.",
                "Where the speed goes, measured on this Mac (base M4, LEGO Star Wars' last session): macOS's Game Mode was on for the whole session (it gives a game first call on the CPU and GPU and turns background work down — checked in the system's own log); in the heavy scenes the GPU was 90–100% busy with the game's own drawing, Anvil's part about 5 ms of a frame; the game's busiest threads used two-thirds of a core, so the CPU wasn't what held it back. FSR 3's passes were measured again — 0.82 ms finding motion, 2.89 ms for the picture at the display's size — and one more way of laying out its work tried: slower (3.07 ms), so not kept.",
            ],
            known: [
                "The warm-up helps the places a game has been played in before; somewhere new still reads from the disk the first time. It learns from the first session with 0.50 on.",
                "Most of a heavy scene's time is the game's own drawing on the GPU, which nothing outside the game can make shorter; what Anvil can do there is Smooth Motion (fixed in 0.49) and keeping its own part small.",
            ]),
        Release(
            version: "0.49.0",
            date: "14 October 2026",
            headline: "Guardian: a small part of Anvil inside each game that checks every few seconds that everything is working and learns what runs best on your Mac — and Smooth Motion can't hold a game back any more, on 60 Hz displays too.",
            fixed: [
                "Smooth Motion could hold a game to its own pace. LEGO Star Wars waits for its frames to reach the screen, and 0.48's presenter could take a little longer to show a frame and the one made before it than the game took to make them — so the game slowed to the pair's pace, which was then measured as the game's own, and the gaps were made from it again. On 13 October it stuck at exactly 40 and then 20 fps of its own where it could make 55; Smooth Motion took that for its own cost and stopped for the rest of the session, so the heaviest place, at 18 fps, had none. In Anvil's stand-in waiting for its frames the same way, 0.48 held it at 24.0 fps for a whole minute, through a light stretch it made 44 in. Now the made frame is shown as soon as it's ready and the real one half the game's frame after it, never longer than the game's frame in all, and the game is told its frame is on screen when the first of the two is: in the same test it ran 36–38 fps of its own through the light stretch, shown as 80–83, half the gaps under 12.4 ms.",
                "When frames between did cost a game its own, they stopped for the session. Now they pause for a minute (twice as long each time after, up to ten), and Guardian counts it against them at that frame rate.",
                "A made frame isn't shown when two of the presenter's frames are still on their way to the screen: the screen is behind, and showing it would only put every frame after it later.",
            ],
            added: [
                "Guardian, on by default (Upscaling › Guardian). Every few seconds while a game plays, it checks that what Anvil does is working: that frames keep reaching the screen — a stalled presenter gets the game's own frames back at once — that Smooth Motion isn't costing the game its own frames, and that nothing switches back and forth: Smooth Motion starting five times in two minutes, or Steady letting go of its even 80 six times in a minute (LEGO Star Wars switched it 134 times in 108 minutes on 13 October), is slowed down for a while. It never restarts a game or changes its settings.",
                "Guardian learns what runs best on your Mac. Now and then, with Smooth Motion running steadily, it shows the game's own frames alone for 4 seconds and compares — the same scene, seconds apart: the frames on the screen (made ones at 0.7 of a real one) and how evenly they came. At each frame rate where Smooth Motion has cost more than it gives, three times or more, it leaves it off there, and looks again now and then. An M4 makes a frame between in a quarter of a base M1's time, and games differ, so what it learns is kept for each game on each Mac, and the Doctor says what it found. In Anvil's stand-in on this M4: at 20–25 fps of the game's own, frames between were 37–118% better in its checks, kept on, and read back at the next start.",
                "Smooth Motion on displays at a fixed rate too — a MacBook Air's, most external displays: from 15 fps of the game's own up to half the display's rate (30 at 60 Hz), a frame between each two of the game's, shown a refresh apart. In Anvil's stand-in on a 60 Hz display (simulated on this Mac): 56 frames a second shown where the game made 22, half the gaps 16.6 ms where they were 41.6, the game's own rate down 3%.",
                "Anvil's check-up (Check-Up) runs again every three hours while Anvil is open and no game is running, so a full disk, a changed engine or an expired sign-in is found before the next game rather than by it.",
            ],
            known: [
                "Frames between still cost a game that waits for its frames on screen some of its own: in Anvil's stand-in about 15% (37 fps of its own against 44 without, shown as 81 against 44). Guardian's checks are what decide, game by game and Mac by Mac, whether that's worth it.",
                "Guardian's checks show the game's own frames alone for 4 seconds now and then — at most once every 45 seconds, and once every 15 minutes at a frame rate it's sure of. The first few minutes in a new kind of scene are when it checks most.",
                "Smooth Motion on a 60 Hz display was tested on this Mac's display set to behave as one, not on a MacBook Air.",
            ]),
        Release(
            version: "0.48.0",
            date: "13 October 2026",
            headline: "Smooth Motion rebuilt: each made frame is now made between two of the game's own, from both, and shown evenly — from 15 fps up, in the heaviest places too.",
            fixed: [
                "Smooth Motion was choppy in LEGO Star Wars' heavy scenes. Its log showed why. Each made frame was guessed ahead from the last two real frames and put on the game's own GPU queue, behind the next frame's work: with the GPU full it finished just before the next real frame instead of halfway, a gap of a whole frame and then a sliver. Up to 280 of 600 made frames were skipped because none of the display's three drawables was free (the game held one for its whole frame). And a guess ahead is wrong wherever motion turns or stops, so the next real frame stepped back.",
                "In the heaviest place (18–23 fps for twelve minutes, lots of shadows) Smooth Motion did nothing at all: it stopped at 24 fps. And it switched off and on every few seconds as the frame rate swung between about 40 and 80.",
                "With Smooth Motion on, a game at 66–76 fps was held to 60 of its own frames with 60 guesses between: fewer real frames for a bigger number. Its own frames are now shown as they're ready there.",
            ],
            added: [
                "The made frame is the one between two real frames, built from both of them and FSR 3's motion: each pixel takes the motion both frames agree on, so nothing is guessed — where motion turns or stops, it is still right. Measured against the true picture half a frame back on Graphics Prep's moving test scene: 3.5 from it at every speed, where the frame guessed ahead was 5.9–6.6 from its own moment and the older frame still on screen 13–23. It costs about 1.5 ms of GPU a frame on an M4 at LEGO's 3024x1964.",
                "A presenter of Anvil's own shows the frames: when the game's frame is done on the GPU, the made frame is shown, then the real one half the game's frame later, each timed from when the one before reached the screen, in whole steps of the ProMotion panel. Frames are copied into the display's buffers by the CPU — otherwise idle in a heavy scene: about 3.5 ms a frame on one efficiency core, which leaves the power budget to the GPU (on four performance cores at once the game lost twice as much of its own rate) — so nothing waits behind the game's GPU work. The game no longer holds a display buffer while its frame is drawn, which is what left none for the made frame.",
                "Smooth Motion now starts from 15 fps of the game's own (at once — within two seconds — with no growing wait between starts) and stays on until the game makes 74 fps or more. Between 60 and 74 it shows the game's own frames as they're ready, without switching itself off. While another app is in front it stops.",
                "Where the GPU's time goes, in heavy stretches: the three passes that took longest in the heaviest frame are now named with what they draw into (\"scene 14.2 ms (1512x982, 4 colour (8-bit) + depth)\"), and the Doctor reads them out — what's needed to lighten exactly the costly part of a shadow-heavy scene, and nothing else. The stats line also says how evenly frames reached the screen (\"gaps: half under 16.7 ms, 90% under 20.8 ms\").",
            ],
            known: [
                "Each real frame reaches the screen half a frame later with Smooth Motion between frames (about 15 ms at 33 fps): a frame between two can only be shown once both exist. That's the price of a frame that doesn't guess.",
                "It needs FSR 3 to the display, whose pictures and motion it makes frames from. Where FSR 3 is off or eased to FSR 1 (the Mac hot), Smooth Motion makes frames ahead as 0.47 did, from 24 fps.",
                "The panel shows frames only on 4.17 ms steps, so the gaps alternate by a step where half the game's frame falls between two (16.7 and 20.8 ms at 27 fps): the evenest the display can do.",
                "The game's own frame rate drops a little with it on — the made frame's GPU work and its copies, 4–5% in Anvil's heavy stand-in (35.6 to 34.3 fps natively, 36.0 to 34.1 under Rosetta) — while what's shown about doubles: 1% lows from 20 to 34 fps, the worst gap from 50 to 33 ms, half the gaps under 12.4 ms where they were 25–29. In the very heaviest scenes the GPU is full with the game's own drawing (28–36 ms a frame at LEGO's heaviest place): more real frames there means lighter settings, which the new pass report will show where to find.",
            ]),
        Release(
            version: "0.47.0",
            date: "12 October 2026",
            headline: "Smooth Motion: in heavy scenes, a frame made between each two of the game's — 30 fps of its own shown as 60 — and smooth from the first second.",
            fixed: [
                "Frame generation was switched off for every session Auto-Tune was still measuring a game — and it measures while you play until it has decided, so LEGO Star Wars had none all session on 12 October. Only its quick test, which relaunches the game to measure, turns it off now; while you play it counts the game's own frames, which are told apart from made ones.",
                "A MacBook Pro's display was judged unable to follow the game's frame rate in a session's first minutes — the look is made on loading screens and menus, where it can't tell — and frames were held to the 120 Hz grid until a later look: four minutes of uneven frames at Endor. A display already seen following games is now taken as following from the first frame (yours: 57 times).",
                "The GPU's time by kind read almost all of it as \"shadows\": D3DMetal makes every render target an array of one, which looked like a shadow map's cascades. Each pass is in its own kind now — and copies and uploads (textures streamed in as an area loads) are timed too.",
            ],
            added: [
                "Smooth Motion, with frame generation on: where the game can only make 24–62 fps of its own — a heavy area like Endor's forest — each of its frames is shown as soon as it's ready and one made from FSR 3's motion is shown halfway between each two: 30 becomes 60 on the screen, 45 becomes 90. On a long session (on battery) too, where the GPU is full with the game's work anyway. Made frames keep any spot whose motion can't be trusted — the edge of something moving across something else — as it is rather than smear it. Measured against the scene itself half a frame on: 56–68% closer than showing the newest frame again, closer around moving objects too. In Anvil's stand-in game at 24 fps of its own: 49.6 fps on the screen, no made frame skipped, its own rate down 3%. It starts within a few seconds of the game slowing — the decision is made every two seconds now, not every 600 frames (24 s at 25 fps). Upscaling › Smooth Motion in heavy scenes turns it off.",
                "Graphics Prep can now test made frames against the truth (development), which is how the made frame was chosen: five other ways of building it measured better on paper and looked worse — torn, mosaicked or doubled detail on moving objects — so the one shipped is the one that looked clean.",
            ],
            known: [
                "A made frame can only be as good as the motion measured between the game's frames, without the game's own motion vectors: a fast object with fine repeating detail can be held half a step behind in the made frame (that spot shown as in the newest frame), which reads as that object moving at the game's own rate while everything else moves at twice it.",
                "A shader the game compiles for the first time in a new area still makes a stutter the first time; D3DMetal keeps it, and the Doctor says how many there were. Anvil can't compile ahead what the game hasn't shown yet.",
            ]),
        Release(
            version: "0.46.0",
            date: "12 October 2026",
            headline: "Textures made for FSR — sharp at the display's own size — and Anvil now times where every frame's GPU work goes, and every shader the game compiles.",
            fixed: [
                "Textures were a level blurrier than the picture FSR builds: a game drawn at half the display's width picks its textures' mip levels for that size, so at Endor LEGO Star Wars' tree bark came out a brown smear after upscaling. Now the game's filtered textures are sampled a mip level sharper for each halving — the level the display's own size would pick, as AMD's FSR guidance asks — with 8× anisotropic filtering for ground and walls seen at an angle. Shadow maps, the interface and lookup textures are left alone. Checked on this Mac's GPU: a texture drawn at half size now samples its full-detail level. Upscaling › Sharper textures with FSR turns it off.",
                "LEGO Star Wars sharpened its 1512x982 picture before FSR's own sharpening ran on the upscaled one — sharpened twice, edges ring — and smoothed edges with a filter on top of its temporal anti-aliasing, softening what FSR reconstructs from. While FSR upscales, both are off (its temporal AA stays on); not upscaling, or at Full, they're back as the game had them.",
            ],
            added: [
                "Where the GPU's time goes: one frame in every two seconds, each pass the game draws is timed on the GPU itself — shadows, the scene, full-size effects, smaller effects, compute — and Anvil's own (FSR, frame generation), shared out fairly where passes overlap. Each stretch of game.log says it (\"GPU work 27.1 ms a frame: scene 11.2, shadows 6.3, …\"), and the game's Doctor reads it for the heavy scenes, so what to lighten — or not — is decided on measurements, not guesses.",
                "Shader compiling: every pipeline the game compiles is timed — how many, how long, the longest, how many failed — so a stutter on entering a new area is told apart from a scene that's just heavy. The Doctor calls out compiles long enough to be felt.",
            ],
            known: [
                "This release measures; it doesn't yet lighten anything in heavy scenes like Endor, where LEGO's own drawing takes 25–28 ms a frame with the GPU full. A few minutes there on 0.46 says which of its effects cost the most, for the next step: lighter settings only where they don't show, and frame generation good enough for heavy scenes.",
            ]),
        Release(
            version: "0.45.0",
            date: "12 October 2026",
            headline: "Anvil Surround: games that only have stereo sound now get surround too — and Anvil can scan what you listen on and play a test through it.",
            fixed: [
                "A game that mixes only in stereo got two speakers' worth of 3D sound, both ahead of you. Many do — and many more put their stereo in a 7.1 mix's front pair and leave the rest silent, which got the same.",
            ],
            added: [
                "Anvil Surround, on with 3D sound: a stereo game's sound is split into 7.1 (5.1 on a 5.1 system) before 3D sound places it. Band by band, every 2.7 ms, what both sides share and is panned to the middle — voices — goes to the centre, what they don't share — the room: rain, crowds, echoes — beside and behind you, a little after the front so each sound still starts where it is, and sounds panned to one side and the bass stay at the front where the game put them. Nothing is lost or doubled: every band keeps its loudness. Tested: a voice in the middle 79% from the centre, a stereo room 35% from beside and behind, a sound in one side alone returned exactly; 10.7 ms of delay, 0.2% of one core.",
                "A 5.1 or 7.1 game with sound only in its front pair is caught after 4 s and split the same way, its own other channels still passed on; the first sound it puts anywhere else hands the mix back to the game for good. Games with their own surround — LEGO Star Wars — are left as they mix.",
                "Surround check: scan the output you're listening on, silently, with the same sound engine games use here — its channels now and what it could be set to, its speaker layout, how late its sound arrives, and a dry run of 3D sound for a 7.1 game and a stereo one — and get a plain answer: can it be used for surround, and how. It runs by itself when the panel opens and whenever you change output. A TV or receiver set to stereo that takes 8 channels is pointed to Audio MIDI Setup; Bluetooth's delay is called out.",
                "Listen: a Surround Test plays a burst from each speaker of a 7.1 mix in turn, around you, and a Stereo Game Test plays a stereo game's sound through Anvil Surround — a voice in the middle, a room, then left and right — with a map lighting where each should come from.",
                "Surround for stereo games can be turned off in the panel; each game's log and its Doctor say what Anvil Surround did.",
            ],
            known: [
                "Splitting stereo can't know what the game meant to be behind you: it reads the room from what the two sides don't share. A game's own surround mix, where it has one, is always used instead.",
            ]),
        Release(
            version: "0.44.0",
            date: "12 October 2026",
            headline: "One switch for 3D surround sound in every game — and Anvil shows whether what you're listening on can play it.",
            fixed: [
                "Headphones in the jack of an Apple silicon Mac, which macOS can show as a device of their own (\"External Headphones\"), were taken for the Mac's speakers and given virtual surround meant for speakers; they now get 3D sound for headphones.",
            ],
            added: [
                "3D Surround Sound, on or off for every game, from the speaker button in the Library's toolbar, the line under the Mac's details in the sidebar, the menu bar menu and Settings.",
                "Beside it, the output the Mac plays through now — AirPods, headphones, the Mac's speakers, a TV, a 5.1 or 7.1 system — marked Compatible or Not compatible, with what you'll hear there: 3D sound on headphones and earbuds, virtual surround on two speakers, real surround on a 5.1 or 7.1 system. It changes as you plug in headphones, connect AirPods or switch outputs.",
                "Where an output can't do it, why and what to do: one speaker can't place a sound around you; AirPods or a headset that an app's microphone has put in call mode play one channel until another microphone is chosen. A TV or receiver on HDMI is pointed to Audio MIDI Setup when it could play 5.1 or 7.1; AirPlay's delay is mentioned.",
                "Every other output on the Mac listed with its own verdict, and each game's launch log names the output it started on.",
            ],
            known: [
                "A game that's running keeps the sound it started with — the switch takes effect at a game's next start, and the panel says so while a game runs.",
            ]),
        Release(
            version: "0.43.1",
            date: "12 October 2026",
            headline: "Minecraft's page is Java Edition, and says plainly what Bedrock's PC version needs on a Mac.",
            fixed: [
                "The Bedrock launcher 0.43.0 installed played Bedrock's Android (Pocket) version, not the PC one you wanted — it's no longer offered. Bedrock's PC version is a Microsoft Store app that can't run under Wine without breaking the store's protection, which Anvil won't do; the page now explains the way it can be played on a Mac (Windows in Parallels Desktop). If you installed that launcher, Anvil leaves it where it is — yours to keep or delete.",
            ],
            added: [],
            known: []),
        Release(
            version: "0.43.0",
            date: "11 October 2026",
            headline: "3D sound in every game — on headphones, earbuds, AirPods, the Mac's speakers or a surround system — and Minecraft, Java and Bedrock, from its own page.",
            fixed: [],
            added: [
                "3D sound, on for every game: games are told your output plays 7.1, so they mix in surround, and Apple's spatial audio places each sound where it is — beside you, behind you, ahead. On headphones, earbuds and AirPods it's binaural 3D, with your personalized spatial audio if you've set it up; on the Mac's own speakers and on external ones, Apple's virtual surround; on a real 5.1 or 7.1 system each channel goes to its own speaker, in the right order for that system. Tested with Apple's spatial mixer: every channel of a 7.1 mix comes from its own side on headphones, voices from straight ahead; about half a percent of one core. Settings › 3D sound turns it off, picks headphones or speakers if Anvil guesses wrong, and can follow your head with AirPods.",
                "Minecraft, in the sidebar: Java Edition opens Mojang's own Minecraft Launcher, which runs natively. Bedrock Edition installs the open-source Minecraft Bedrock Launcher — downloaded from the project's own releases and checked against the checksum it publishes — which plays Bedrock's Android version natively on Apple silicon, with Xbox sign-in in the game for servers and Realms.",
            ],
            known: [
                "Bedrock through this launcher needs Minecraft bought on Google Play (the Android version), separate from a Windows, Xbox or PlayStation purchase. The Windows version can't run under Wine without getting around the Microsoft Store's protection, which Anvil doesn't do. Joining an Xbox friend's world directly often times out; servers and Realms work.",
                "Which output is headphones is guessed from the device for Bluetooth and USB; Settings › Listening on sets it if the guess is wrong. A game started on one output keeps that rendering if you switch outputs mid-game.",
            ]),
        Release(
            version: "0.42.0",
            date: "11 October 2026",
            headline: "FSR 3 that holds together in fast scenes — motion followed at speed, no trails behind what moves — and LEGO Star Wars' own blur kept off.",
            fixed: [
                "Fast scenes smeared. Anvil's FSR 3 measures how the picture moves and blends the frames before into this one; in a fast pan its measurement went wrong — on Graphics Prep's test scene moved at five and ten times its speed, only half the picture was followed right on an irregular surface, and on a repeating one none of it, every block trusted all the same — and thin lines and fine detail washed out. Now motion is also searched on a picture blurred to its broad shapes, an eighth of the game's size, where a repeating pattern can't fool it: on the irregular scene at ten times the speed, 88% of the picture is followed right instead of 50%.",
                "And what FSR 3 blends holds back where it should: the faster something moves (from 8 to 40 pixels a frame), the fewer frames it blends — down to 3 — and the stricter it is about what it keeps, because fast motion has no fine detail to gain and every old frame is a trail. Where something moving meets what's behind it, each pixel also tries the motion of the blocks beside it and keeps what matches. Measured against a supersampled picture on the irregular scene: 6–7% closer in a fast pan, 6–7% less trail behind the moving disc, 5% less flicker. It costs about 0.4 ms a frame more at LEGO Star Wars' sizes on an M4 (3.7 ms in all).",
                "A game that smooths its own edges over time — LEGO Star Wars' temporal anti-aliasing is on — hands over frames already blended, and FSR 3 blending ten more on top made a smear of its own: on the test scene drawn anti-aliased it came out further from the reference than plain FSR 1, and trailed more. FSR 3 now blends at most 3 frames for such a game, and Graphics Prep tests it on anti-aliased frames: 20% closer than FSR 1 at every speed.",
                "LEGO Star Wars' motion blur and speed blur — effects that smear every moving frame on purpose — kept turning themselves back on: Anvil turned them off, and by 10 October the game's settings had them on again, so Anvil had left them, taking that for the player's choice. At Light and Medium they're now kept off at every start (Full leaves them to the game).",
                "Generated frames no longer drag the background along with whatever moves: where the motion around a pixel disagrees, a generated frame shows the newest real frame there as it is.",
            ],
            added: [
                "Choppy sound is now caught: when the game's sound reaches the Mac too late and cuts out for a moment, Anvil counts it in the game's log, and the check-up after a session says how often — so a stutter in the dialogue can be told apart from the game's own voice stream falling behind.",
            ],
            known: [
                "Anvil's FSR 3 works from the picture alone. DLSS and the game's own FSR 3 are given the game's exact motion and depth by the game itself, which nothing outside a game can get for one that doesn't offer them; LEGO Star Wars offers neither. Its own temporal anti-aliasing does have them, which is why it's left on.",
            ]),
        Release(
            version: "0.41.0",
            date: "11 October 2026",
            headline: "Long play stays clean: frame generation no longer takes over a session — the picture and the pace hold up from the first minute to the last.",
            fixed: [
                "The longer you played, the worse the picture got. On 11 October, with frame generation on, LEGO Star Wars started generating frames on a loading screen 46 seconds in — and, being your choice, it stayed on for the rest of the session. From then on the even 80 stood aside (on battery too, where Anvil promises one), the game's frames went on the display's fixed 120 grid instead of being shown as they're ready, and for minutes at 50–60 fps almost no frame landed evenly, with input taking 50–65 ms to reach the screen. Later, in heavy scenes at 23–45 fps, half of everything shown was a guessed frame stretched over too much motion — edges and moving things breaking up. Now, on a ProMotion display, generated frames are used only where they look clean: a game holding about 66–76 fps, short of an even 80, gets 60 of its own frames with one generated between each. They're never used in a game's first 30 seconds, below 60 fps, or in a long session (on battery, by default). Generation stops as soon as the game can hold an even 80 itself, or can't keep up, and waits longer before starting again if it had to stop soon after starting. Replayed on your 28-minute session: generated frames for 9 seconds instead of 27 minutes.",
                "After that session Anvil said it ran at 93 fps on average, 80 or more 78% of the time, and that everything ran as it should. Those figures counted the generated frames. The session summary now counts only the game's own frames, and the after-session check says so when generated frames stood in for a slow game.",
            ],
            added: [
                "A picture of the game every 10 minutes for the whole session, not just its first 5 — so what was on screen late in a long session can be seen afterwards, as the first minutes already could. Kept on this Mac only, as before.",
            ],
            known: [
                "Generated frames are guesses from the picture alone. Even where they're used now, fast motion can show a little smearing; Frame generation off in the game's Upscaling settings gives the game's own frames only.",
            ]),
        Release(
            version: "0.40.0",
            date: "10 October 2026",
            headline: "Your Steam games listed like your Epic games, each a click from installing — and the Epic page opens at once, with signing in right on it.",
            fixed: [
                "The Epic page took up to half a minute to show anything: it asked Epic for the whole list of games at every opening — 209 here — and then fetched every cover at full size, often half a megabyte each to show 40 points wide. The list is now kept on this Mac and shown at once, read again from Epic in the background (every half hour at most, or with Refresh), and each cover is fetched once at the size it's shown — about 30 times smaller — and kept.",
                "An Install on the Epic page sat at “0%” while legendary read Epic's file list. It says it's getting ready, then shows the download's speed and how long is left.",
                "Steadier where a game hovers around 80: on 10 October, on battery, LEGO Star Wars sat between 64 and 86 fps and was held to an even 80 and let go again 74 times in 40 minutes — ten times in one minute — each a change of pace you could feel. A hold that has to let go within 10 seconds now waits longer before the next (5 s, then twice as long each time, up to a minute), and twenty seconds held clears it. Replayed on the test bench, that stretch went from 9 changes a minute to 3½.",
            ],
            added: [
                "Steam: your Steam account's games, listed on the Steam page with their covers, like Epic's. Install opens Steam's own install window for that game (Steam opens with it if it isn't open), Steam downloads and updates it as always, and once it's ready it joins your library here by itself. Read from what Steam keeps on this Mac — nothing new is asked of your account.",
                "Epic sign-in on the Epic page itself, no window to open: Epic's own page right there, which hands the code over by itself; or your browser, where your saved passwords and passkeys work — copy the line Epic shows and press Paste Code & Sign In. The clipboard is read only when you press it.",
                "The Epic page says who's signed in, with Switch Account and Sign Out. When Epic's sign-in has run out — it does after a few weeks unused — the page asks for a new one instead of failing to list your games, and a game that found it gone has it waiting there.",
            ],
            known: [
                "Steam lists what its own cache holds: a game bought on another computer shows once this Steam has been signed in and opened since.",
            ]),
        Release(
            version: "0.39.0",
            date: "10 October 2026",
            headline: "Steady from the first second: a game's start no longer swings between 80 and 120 — and every kind of DirectX game is drawn the way it can be, with Steam's library changed only from a button in Settings.",
            fixed: [
                "The start of a game is steady. Its first 30 seconds are logos, intros and loading, its pace swinging every second or two, and Anvil's frame pacing followed every swing: on 10 October Cat Quest II was held to 80 and let go to 120 nine times in its first half minute, each a hitch you could see, then ran an unbroken 120. Now each frame is shown as it's ready until the start has settled — the ProMotion display follows the game anyway — and holding to an even 80 or reaching for 120 starts from there.",
                "A game that keeps its saves in your Documents folder (Cat Quest II) could sit on its loading screen with nothing happening. macOS asks once whether Anvil may open Documents — and again after each new build of Anvil — and until it's answered every read there waits, the game's own load of its save included, while the question was hidden behind the game. Now, before such a game starts, Anvil checks first: if macOS is asking, Anvil comes to the front, says why, and starts the game the moment it's answered (or after 3 minutes either way). If access was refused, it says where to turn it on. Anvil's own save copy before a start no longer holds the start up at all.",
                "A game ended from outside with SIGKILL — a force quit from another app, or macOS freeing memory — counted as a crash, and Anvil's Autopilot switched its FSR 3 off for it. Nothing inside a game can cause that ending; it's now said as what it is, and the game's settings are left alone.",
                "When the display looked as if it wasn't following the game, Anvil waited 30 s before looking again, with frames on the fixed grid in between. On 10 October LEGO Star Wars spent those 30 s at 96–120 fps with a refresh missed in one gap of three, and the next look found the display following after all. It looks again after 10 s now.",
                "DXVK as a graphics setting never worked: Anvil told Wine to use DXVK's DLLs but never put them in the container, so a game set to DXVK couldn't load DirectX at all, and a DirectX 9 game there had nothing to draw with. Now DXVK's DLLs go into the container when a game starts on DXVK, and the engine's own come back when it doesn't — swapped so a program already running keeps what it loaded, and never left half one and half the other. Tested with Cat Quest II on DXVK: Direct3D 11 through Vulkan and MoltenVK on the Apple M4.",
                "32-bit DirectX 10 and 11 games were drawn by Wine's old OpenGL renderer: D3DMetal is 64-bit only, and that renderer can't give most DirectX 11 games what they need to start on a Mac. They now go through DXVK, which has 32-bit DLLs, unless WineD3D is chosen for them.",
                "A game DXVK can't draw stays on D3DMetal whatever the setting: DirectX 12, 64-bit DirectX 10 (D3DMetal's), and DirectX 9 (Wine's own, under every setting). The launch log says when that happens and why.",
                "The Graphics Scan said DirectX 10 games were drawn by Wine's OpenGL renderer, out of FSR's reach. They go through D3DMetal, and Anvil's FSR reaches them. Games are scanned again once for this.",
                "Steam's own session reported the frame rate of the game started beside it as its own. Each session's frame statistics are now its own, and a store's window has none.",
            ],
            added: [
                "Settings › Steam: every game with its own Add to Steam or Remove button, and Add All and Remove All. Anvil never puts a game in Steam's library by itself. Remove takes out only what Anvil put there, cover art included; your own Steam shortcuts are left alone. The game's page has Remove from Steam beside Add.",
                "An anvil://add-to-steam link asks before it changes Steam's library.",
                "The Doctor says when Epic is waiting for you to finish something on your account — newer terms to accept, a detail to confirm — which a game can only show as a page in your browser under Wine. Cat Quest II's sign-in hit this on 10 October.",
            ],
            known: [
                "Anvil's FSR reaches games drawn through D3DMetal: 64-bit DirectX 10, 11 and 12, nearly every Windows game of the last ten years. A game drawn through DXVK, Vulkan or Wine's OpenGL renderer runs without it, at the size it draws.",
            ]),
        Release(
            version: "0.38.2",
            date: "10 October 2026",
            headline: "A game that keeps its saves in Documents has them backed up too — Cat Quest II's never were.",
            fixed: [
                "Cat Quest II keeps its progress in Documents/Cat Quest II/save_file1.dat, and a container's Documents is usually a link to the Mac's own. Anvil left all of it out of its copies, to keep away from the person's files — so every start of Cat Quest II said “saves: none yet”, no copy was taken before it ran, and Export Saves left its progress behind. Now the game's own folder there is kept (its saves and settings, not its crash reports); nothing else in Documents is read. macOS may ask once whether Anvil can see the Documents folder: allowing it is what lets Anvil keep that game's saves.",
            ],
            added: [],
            known: []),
        Release(
            version: "0.38.1",
            date: "10 October 2026",
            headline: "anvil://add-to-steam/<game>: a game into Steam's library from a link or Shortcuts, as its page's button does.",
            fixed: [],
            added: [
                "anvil://add-to-steam/<game id>: the same as Add to Steam's Library on the game's page. Play in Steam then starts the game through Anvil, in its own container with its own saves — and with no connection, the way Anvil starts it offline. Tested with Cat Quest II, whose Offline Test found it plays offline.",
            ],
            known: [
                "A game that needs its store's sign-in to start (LEGO Star Wars' Epic edition) needs it from Steam too: Steam starts the same program.",
            ]),
        Release(
            version: "0.38.0",
            date: "10 October 2026",
            headline: "Starts are smooth again: D3DMetal's compiled shaders are kept and used, instead of compiled again at every start — and LEGO Star Wars' shadows are drawn as the game draws them.",
            fixed: [
                "Every start of LEGO Star Wars compiled its shaders again, which is the lag at the beginning that cleared once it had been played a while. D3DMetal stamps its shader cache with the macOS it was made for and throws away one with another stamp. After the update to macOS 27.0.1 the copy Anvil keeps (168 MB, made on 27.0.0) was bigger than the one D3DMetal was building again, and Anvil put the bigger one back before every start — so D3DMetal threw it away on the first frame, every time, and the new one was never kept because it was smaller. On 10 October the first minute dropped to 4.6 fps with half-second gaps, and ran at an even 120 once everything was compiled. Anvil now reads the stamp: a copy goes back only when D3DMetal will use it, and the newest valid one is always kept.",
                "LEGO Star Wars' shadows: Anvil's graphics levels had turned soft shadows off and shadows down (Medium), and ambient occlusion off (Light) — hard, jagged shadow edges that crawl as things move, and figures with no shading where they meet the ground. Shadows and ambient occlusion are now left as the game draws them at every level, and put back where Anvil had turned them down; reflections, depth of field and water distortion are still what the lighter levels turn off. Shadow quality and motion blur set in the game's own menu stay as set there.",
                "A change to a game's tuning set its motion blur off again even where the player had turned it back on after 0.31; that now happens once, for the version it was for.",
            ],
            added: [
                "The launch log says what happened to the game's shader cache before every start and after it ends: D3DMetal's own kept, or Anvil's copy put back, and why.",
            ],
            known: [
                "The first start after a macOS update still compiles every shader the game uses once: D3DMetal's cache is made for one macOS. From the next start on, it's kept.",
                "LEGO Star Wars' Epic edition still needs internet to start.",
            ]),
        Release(
            version: "0.37.0",
            date: "10 October 2026",
            headline: "Offline Test: Anvil finds out whether each game really plays with no connection — while you're still online — and the Check-Up lists every game by how it does offline.",
            fixed: [
                "The Check-Up said “Every Epic game can start offline” when it meant only that Anvil had each one's offline start ready; LEGO Star Wars was listed while it needs internet to start. It now says the offline starts are ready, and lists separately which games play offline and which need internet.",
                "The Doctor still said Anvil asks before starting a game that needs internet; since 0.36 Auto start waits for the connection instead.",
            ],
            added: [
                "Offline Test, on each game's page and for every untested game at once from the Check-Up (or anvil://offline-test/<game> and anvil://offline-test/all): Anvil starts the game exactly as it starts with no connection — Epic's offline start, its own connections held back — while the Mac stays online, watches it for a little over a minute, closes it the way Quit does, and judges from the pictures it keeps of the screen. Compared with the same moments of the game's online starts, a game that gets as far as they do plays offline, and one that stays on a screen they leave within seconds needs internet to start. A screen waiting for a button press counts as going; a sign-in or connection error still showing at the end counts as needing internet. When there's nothing to compare and it stayed on one screen, Anvil shows you its picture and asks. The result goes into the game's offline record, so Auto start and offline starts use it, and the test's picture is shown beside the online one. A test isn't play: no play time, no Auto-Tune, nothing learned from it as a session. On 10 October's pictures LEGO Star Wars' offline start was judged as needing internet (still on its loading screen at 30 s, which its online starts leave by 10 s) and its online start as playing.",
                "Offline in the Check-Up: which games play offline, which need internet to start, which haven't been tested (with Test Them Offline), which tests need your answer, and whether Steam is ready for its own Offline Mode — a remembered sign-in and every game up to date.",
            ],
            known: [
                "A game that needs internet to start still won't start with none — Offline Test finds that out; it doesn't change it. LEGO Star Wars' Epic edition is one: it waits for Epic's sign-in at every start.",
                "Steam games are not test-started: Steam's Offline Mode is Steam's own to turn on. Their readiness for it is checked instead.",
                "A game whose frames Anvil doesn't see (Cat Quest II, on WhiskyWine) leaves no pictures, so its test asks you what it showed.",
            ]),
        Release(
            version: "0.36.0",
            date: "10 October 2026",
            headline: "Auto start: a game that needs internet to start is started online whenever there's a connection, and with none Anvil waits and starts it by itself the moment it's back.",
            fixed: [
                "A start with no connection of a game that needs internet to start no longer counts toward Auto-Tune: on 10 October LEGO Star Wars' loading screen was measured as 0.6 minutes of play at 78 fps.",
            ],
            added: [
                "Auto start, for every game Anvil has seen stay on its loading screen with no connection (LEGO Star Wars' Epic edition: every start with no connection here, 1–10 October, every way it can be started — with Epic's arguments, as Epic's Offline Mode starts it, and as its program alone). Online, Play starts it online at once — the start that gets past its loading screen in about 20 seconds — even with Offline Mode on. Connected but with its store not answering yet (a VPN still connecting, a network that wants its sign-in page), Anvil waits for it rather than starting into the loading screen. With no connection, Anvil starts another copy of the same game in the library that plays offline, such as its Steam edition in Steam's Offline Mode; with none, it waits, shows how long, and starts the game by itself as soon as the connection is back — from Play, the menu bar, the Dock, a shortcut or Steam's library. Start Offline Anyway and Cancel are there; a wait of 30 minutes ends without starting it. The game's page says what Auto start will do right now.",
            ],
            known: [
                "A game that needs internet to start still can't be started with none: it signs in to its store as it starts, and Anvil doesn't get around a store's sign-in. Once it's past its loading screen it plays on offline. Started from Steam's library, LEGO Star Wars' Epic edition is the same game, with the same saves, and needs the same connection; only a copy bought on Steam starts in Steam's Offline Mode, and its saves are its own.",
                "The Epic sign-in still takes 3–8 seconds of an online start: almost all of it is Epic's sign-in tool, legendary, unpacking itself at every run (2.6 s for `legendary --version` alone here).",
            ]),
        Release(
            version: "0.35.1",
            date: "9 October 2026",
            headline: "Steam opens on its Library and sits at 6% of a core instead of 80–88% — CPU a game keeps.",
            fixed: [
                "Steam opened on its Store page, which never stops drawing — carousels and trailers, every pixel on the CPU under Wine — and took 80–88% of a core while it sat behind other windows. On its Library it takes 5–6%, measured over 16 s after it settled. Steam's window now opens on its Library (Steam's own steam://open/games), and on this Mac Steam's own settings were set to start there, with Low Performance Mode on and no store content on the Library's home. Steam started beside a game opens no window and is unchanged.",
            ],
            added: [],
            known: [
                "Measured and left out: -cef-force-occlusion (under Wine Steam's window counts as visible even when covered), -cef-force-opaque-backgrounds, -cef-disable-breakpad and -cef-disable-js-logging — no change beyond the noise. Steam's GPU drawing stays off: Steam turns it off under Wine whatever it is told.",
            ]),
        Release(
            version: "0.35.0",
            date: "9 October 2026",
            headline: "Steam's window runs almost twice as smoothly, and any game of Anvil's can go in Steam's library — started through Anvil, with everything Anvil does for it.",
            fixed: [
                "Steam's window lagged: under Wine Steam has its web view draw every pixel on the CPU (it passes --disable-gpu to each of its processes whatever its own GPU setting says; -cef-force-gpu and its GPU setting changed nothing here). At Retina that was 2560 × 1600 for a 1280 × 800 window: 27 fps, with frames of up to 92 ms, measured over a full-window repaint. Steam's window is now drawn at the display's point size — 46 fps, frames of at most 42 ms — while the games it starts, in the same container, still get its Retina resolution for Anvil's FSR. Each Wine process reads the resolution as it starts, so Anvil sets it just before each: Steam's at point size, the game's at the container's own. A switch on the container's page puts Steam's window back at Retina, sharper and slower.",
            ],
            added: [
                "Add to Steam's Library, on a game's page: the game goes into Steam's library as a non-Steam game, with its cover cut to Steam's three image sizes. Play in Steam opens the game's anvil:// link on the Mac (Wine's winebrowser hands it to macOS), so Anvil starts it exactly as its own Play does — its Epic sign-in, FSR, frame pacing, controller fixes and save backups included. Steam's own .exe start would have run it in Steam's container with none of those. Steam closes with its own -shutdown while it's added and opens again; shortcuts already in Steam are kept.",
            ],
            known: [
                "Started from Steam, LEGO Star Wars' Epic edition still signs in to Epic as it starts, so it still needs a connection to start; Steam's offline mode covers games bought on Steam.",
                "Steam's window at point size is a little softer than at Retina.",
            ]),
        Release(
            version: "0.34.2",
            date: "9 October 2026",
            headline: "Steam's sign-in takes a pasted password: ⌘V pastes in a container that holds Steam or Epic's launcher.",
            fixed: [
                "Signing in to Steam always ended in “Please check your password and account name and try again”, though the same account signed in on Steam's website. Steam's connection was fine — its sign-in window sent a request every 5 s and had an answer within 0.2 s — but the password never reached it as copied: in Wine the ⌘ keys are the Windows key unless set otherwise, so ⌘V pasted nothing, or a “v”. In a container that holds Steam or Epic's own launcher the ⌘ keys are now Ctrl, unless chosen otherwise on its page, so ⌘V, ⌘C and ⌘A work in their sign-in boxes. It is set at the store's next start.",
            ],
            added: [],
            known: [
                "Steam's server ends a sign-in connection that hasn't signed in after about a minute, and the window starts a new one: a Steam Guard code or approval left longer than that can need entering again.",
                "Steam's offline mode is for games bought on Steam. An Epic game added to Steam starts the same .exe, which still waits for Epic's sign-in.",
            ]),
        Release(
            version: "0.34.1",
            date: "8 October 2026",
            headline: "A game that needs internet to start says so — on its tile, its page and before an offline start — with how to play it offline anyway.",
            fixed: [
                "The warning before starting such a game with no connection had Start Anyway as its default button, so Return started a game that would only wait on its loading screen. Cancel is the default now.",
            ],
            added: [
                "“Needs internet to start”, on the library tile and the game's page, for a game whose starts with no connection don't get going here however Anvil starts it — LEGO Star Wars' Epic edition. It says why in plain words (its Epic edition signs in to Epic every time it starts, and waits until it can) and what works: start it online, then go offline once it's past its loading screen; it keeps playing.",
                "The check-up and the note when Anvil starts such a game online by itself say the same.",
            ],
            known: [
                "Guides that say any Epic game plays offline in Epic's Offline Mode describe the launcher: the game itself is given only your account name and id, and one that needs Epic's sign-in to start still waits. Anvil gives LEGO that same start; it waited, as it did the other two ways.",
            ]),
        Release(
            version: "0.34.0",
            date: "8 October 2026",
            headline: "An Epic game that won't start offline one way is tried the next: Epic Offline Mode's own start, then its program on its own.",
            fixed: [
                "Anvil's offline start for Epic games passed Epic's sign-in arguments with an empty code. Epic's own launcher, in its Offline Mode, passes only the account's name and id (Epic's store testing guide), and a game may take the two differently. Both are now tried.",
            ],
            added: [
                "Offline ways for Epic games, tried in turn: Epic's arguments from the game's last online start, as before; if two starts with no connection don't get going, Epic Offline Mode's own start; if that doesn't, the game's program on its own, with nothing from Epic. Whichever gets the game playing is kept for it. Only when none does does Anvil start it online when there is a connection, and say so before a start with none. The game's page and its check-up say which way is next.",
            ],
            known: [
                "LEGO Star Wars' Epic edition was started each of the three ways on 8 October with its connections held back, for 150 s each: it stayed on its loading screen every time, idle at 2.2 GB, while online starts pass it in about 35 s. It needs a connection to start; once started it keeps running if the connection drops. Cat Quest II, started as its program alone, carried on past its failed Epic sign-in to its save.",
                "None of the ways signs a game in or gets around a sign-in it waits for: each gives the game what it would have on a PC with no internet.",
            ]),
        Release(
            version: "0.33.0",
            date: "8 October 2026",
            headline: "Games start the way that works for them, saves come out in one file before a game is deleted, and Steam has a cover.",
            fixed: [
                "With Offline Mode on and a connection, a game whose starts with no connection don't get going here — LEGO Star Wars' Epic edition — is now started online by itself, the start that works, and Offline Mode stays on for everything else. 0.32 asked first; now it asks only when the Mac has no connection at all, when there is nothing else to try.",
                "Cover art came only from Mythic's and Heroic's records of Epic's catalogue, not Anvil's own: games installed through Anvil's Epic connection had none. Anvil's own is read first now, and the look for art missing from any game runs by itself once there is a connection — a Steam game's from the cover Steam downloaded.",
            ],
            added: [
                "Saves, game by game (on its page, Game Data): Export Saves puts only that game's saves into one .zip — its own folders under Windows' profile, found by its name, and its Steam cloud folder for a Steam game; the Mac's own Documents, linked into a container, is never taken. Restore puts an export back where the game looks for it, in its container or a new one, with what is there already moved aside rather than overwritten. Delete Game, Keep Saves exports first and deletes nothing unless that worked, then moves the game's folder to the Trash — the folder its store recorded for an Epic game; a Steam game's files are Steam's to uninstall — and takes it out of the library. Exports go to Documents › Anvil Saves.",
                "Steam has a cover: Anvil draws a tile for a store's own app — its colours, the symbol the sidebar uses for it and its name — since a store's files carry no cover of itself (the image Steam calls its library logo is a sample of Google Chrome's).",
                "Stores says plainly what Anvil does for your account: the store's app runs unchanged, nothing of Anvil's goes into a game with anti-cheat or changes a game's files, and nothing works around anti-cheat or a store's sign-in or ownership checks.",
            ],
            known: [
                "Epic's own Windows launcher was tried in a copy of LEGO's container: it installs and updates under Anvil's engine, but then waits on Epic Online Services, whose installer is a .NET program that fails there, so the launcher quits before its sign-in. It isn't part of Anvil; LEGO's Epic edition still needs a connection to start.",
                "No one can promise an account will never be banned — that is the store's and the game's decision. Anvil keeps away from what bans are for.",
            ]),
        Release(
            version: "0.32.0",
            date: "8 October 2026",
            headline: "Anvil reads what a game shows on screen, knows which games get going offline here, and says so before an offline start that won't.",
            fixed: [
                "Opening Stores with no connection ran Epic's game list anyway, which can't work offline, and logged it as a fault (“epic: list failed with 1”, 8 October). It now waits for the connection and reads the list then; installed games play offline either way.",
                "The check-up called an Epic offline start “so it couldn't wait on a sign-in to Epic”. LEGO Star Wars did wait: some games need their store's online sign-in every time they start. It now says only what was done.",
            ],
            added: [
                "What a game shows: Anvil's library keeps a small picture of the game's screen at set times in its first five minutes, and one every five seconds after, replaced — the last before it was closed. After the session Anvil reads the words in them on this Mac (Apple's Vision) and the check-up says what the game was showing when it was closed: waiting for a button press, a message about its connection, an error, still loading. The pictures stay on this Mac, for a game's last eight sessions.",
                "Offline, game by game: Anvil keeps how each game's starts with no connection went here — played, or closed again within minutes on one screen — and shows it on the game's page. Started offline twice running without getting going (LEGO Star Wars' Epic edition, seven times from 1 to 8 October, while every online start got past its loading screen in about 35 seconds), Anvil asks before the next offline start, with what the game showed last time; with Offline Mode on and a connection, it can turn Offline Mode off and start it. The record starts from the starts already in Anvil's log.",
                "Every start writes whether it was made with no connection, for that record.",
            ],
            known: [
                "Anvil can't sign a game in without its store, and doesn't get around a store's sign-in. A game whose Epic edition needs Epic's online sign-in at every start — as LEGO Star Wars' seems to — starts online; other single-player games start offline as before: DRM-free ones, Epic games made to run offline, and Steam games once Steam is in its own Offline Mode.",
                "Games drawn without Anvil's frame hook (Steam's own window, or a game with enhancements off) have no pictures to read.",
            ]),
        Release(
            version: "0.31.0",
            date: "7 October 2026",
            headline: "Steam signs in, Epic signs in inside Anvil, and only the game's own frames — in their true shape — reach the screen.",
            fixed: [
                "Steam couldn't sign in: its sign-in window talks to Steam over a connection on this Mac, and Steam only takes one it can see coming from its own window — and turned away every one (“WebUITransport: Connection rejected”, every few seconds on 4 October), so nothing typed there ever reached Steam. Under Wine before 10, Windows' table of connections is made from a list macOS now gives each program only for its own connections, with each socket's id cut to 32 bits: under Mythic Engine 3.0 a program with three connections open was told of none. Anvil's library now gives Wine that table, from the sockets of this user's Wine programs, with each one's owner. Checked under Wine 9: 0 connections listed before, 3 after, owner found; and in this Mac's own Steam: its window's connection was taken at once, Steam reached its servers and showed the sign-in.",
                "Steam itself now starts with Anvil's library for that alone — no frame hook, pacing, controller or sound changes. Health tells a Steam that turned its own window away apart from one that couldn't reach its servers; on 4 October it blamed the VPN.",
                "Distortion: frame generation was on for every game since 0.26, and LEGO Star Wars's last long session showed 23% made-up frames — for minutes at a time it made 82 fps of its own, was taken for short of the display's 120 and held to 60 real frames with 60 generated between them. Generated frames are guessed from motion between the game's own, without its motion vectors or depth, and bend edges, text and the HUD. Off for every game; each game's Upscaling section still has it. Switched on, it now leaves a game that holds Steady's 80 on its own frames.",
                "Distortion: 0.30 told LEGO Star Wars its screen was 16:9 so its menus would show whole. The game takes that as the monitor's shape, so on a MacBook's 3:2 screen the picture can be squeezed rather than bordered. Back to the screen's own shape for every game; the 16:9 layout is a choice on the Performance tab, said for what it is.",
                "Blur: the game's own motion blur and speed blur were back on in its settings, on top of FSR 3, which blends frames already — every moving frame smeared twice. Off once more, once; turned on in the game after this, they stay.",
            ],
            added: [
                "Epic sign-in inside Anvil: Epic's own page opens in the sign-in sheet; once you've signed in there, Anvil takes the one-time code from the page Epic ends on and finishes by itself — nothing to copy or paste. Your password goes only to Epic; the code is used once and written nowhere. The page remembers Epic's sign-in like a browser, so signing in again is a click. The browser-and-paste way is still there.",
                "Any Windows launcher that checks who is connecting to it — as Steam does — gets the same connection table under the older engines.",
            ],
            known: [
                "LEGO Star Wars lays its menus out for 16:9, so at the screen's own shape a MacBook's taller screen trims their left and right edges — the gameplay picture is whole and in proportion.",
                "Steam games play offline once Steam is in its own offline mode, chosen in Steam (Steam › Go Offline) while online and signed in; Anvil doesn't change Steam's own settings. Epic games start offline as before.",
                "Not yet seen on a game's screen: the picture after these changes. game.log after the next LEGO session says how many frames were generated (gen=) and whether FSR 3 ran.",
            ]),
        Release(
            version: "0.30.1",
            date: "7 October 2026",
            headline: "FSR 3 runs again where it fits: the budget that keeps an even 80 now judges a frame at a time.",
            fixed: [
                "In LEGO's sessions of 4 and 5 October FSR 3 stepped aside for FSR 1 in a heavy stretch and almost never came back: FSR 1 ran in 93–99% of each session. The budget judged FSR 3's cost as a share of the GPU's second — at 110 fps its 2 ms a frame is 22% more — so a GPU 83–86% busy never had room, though the game would have stayed above 90 with it. It now judges a frame at a time: FSR 3 comes back when the GPU's time a frame with FSR 3's added fits an even 80 with a tenth to spare (7.7 ms + 2.0 against 12.5 at 110 fps). Replaying those sessions' 775 windows through the new rule, FSR 3 runs in 89% of them instead of 5%.",
                "FSR 3 no longer steps aside where FSR 1 couldn't hold 80 either: at 50 fps with the GPU full, FSR 1's 2 ms less still leaves 15.6 ms a frame, so the picture keeps FSR 3 for the same lack of frames. It steps aside where that saving reaches an even 80 — 73 fps with the GPU 88% busy, for one.",
            ],
            added: [
                "Seen working in LEGO's sessions on 0.30.0: the picture drawn at the screen's own 3024×1964 from its first second (it had been 3024×1934, stretched by macOS); frame pacing switching 4–5 times a session against 297 on 0.29; below 78 fps 0–5% of the time against 21%, the lowest 1% up from 61 to 72 fps; long sessions on as soon as the Mac was unplugged and off when plugged in, in a two-hour session; all 18 of Anvil's pipelines ready-made, the first frame waiting 0 ms.",
            ],
            known: [
                "LEGO accepts the 16:9 picture setting and keeps it in its own file; whether it shows black above and below or squeezes the picture has still to be seen on screen. “Fill the screen” under Graphics on its Performance tab puts it back.",
            ]),
        Release(
            version: "0.30.0",
            date: "4 October 2026",
            headline: "The whole picture, drawn at the screen's own pixels; FSR 3 quicker and kept within an even 80's budget; and Long sessions, for hours of play on battery.",
            fixed: [
                "The picture was stretched by macOS after FSR had drawn it: in most of LEGO's sessions FSR drew 3024×1934 on the 3024×1964 screen, because the game's layer was sized while its window was still 15 points short of the screen, and nothing looked again. macOS then stretched every frame by 1.5% to fill the screen, softening what FSR had sharpened. The layer's size on screen is now looked at every second, and the drawable follows it to the screen's own pixels.",
                "LEGO Star Wars cut off the sides of its own picture on a MacBook: made for 16:9, it widens its view for a wider screen but crops a narrower one, so on the 1512×982 screen (about 3:2) its menus lost their left and right edges — the player's name tag cut in half. Anvil now tells it the screen is 16:9, so all of the picture, menus and HUD show, with black above and below (where the camera notch is). “Fill the screen” on the game's Performance tab, under Graphics, puts it back.",
                "Frame pacing changed its mind every few seconds in a game hovering between 95 and 110 fps: a check for 120 found it, the game fell back within five to twelve seconds — past the four that counted as a failed check — and a check every 20 seconds overrode the wait anyway. A fall within 15 seconds now counts, the wait grows to a minute, and the 20-second check waits for it too. In the pacing model, 36 switches in two and a half minutes became 16, three of them in the last half; light scenes still reach 120 within two seconds.",
            ],
            added: [
                "FSR 3 is quicker: its blend works in half precision, as its history is kept, and a pixel that didn't move reads its history instead of filtering it — which lets a work group be 32×32 instead of 16×16, so less of each tile's border is upscaled twice. On an M4 at LEGO's sizes the pass went from 2.95 to 2.58 ms, and FSR 3 in all from 3.67 to 3.31 ms a frame, with the same scores on Graphics Prep's test scene. (A smaller 10-bit history was tried too and measured the same: the pass is bound by its arithmetic, not memory.) Every game is prepared again once, since the shaders changed.",
                "FSR 3 within an even 80's budget: when a game is short of 80 for two seconds with the GPU 88% busy or more, FSR 3 steps aside for FSR 1 — about 2 ms a frame back — and returns once the GPU has had room for FSR 3's share for three seconds; the first wait is 8 s, twice as long each time it has to step aside again soon after, up to two minutes. Its cost starts from Graphics Prep's measure for the game and is then learned from the GPU's load either side of each return. game.log says each time, and why.",
                "Long sessions, in Settings: for hours of play on a MacBook. On battery, in Low Power Mode or with the Mac hot (the default; or always, or never), Anvil holds an even 80 with no reaching for 120, and runs FSR 3 only when the GPU has a fifth to spare — frames past 80 cost power and heat for little. A Mac that reaches a serious thermal state gets FSR 1 until it cools. Power and heat are read every five seconds during play, so plugging in or unplugging takes effect at once.",
                "Any game whose frame is a different shape from its window — a 1920×1080 game on a MacBook's screen, say — is shown whole, centred on black, rather than stretched to fill; with FSR to the display and without.",
                "The check-up after a session says when FSR 3 stepped aside for FSR 1, when a long session held an even 80 and why, and when the Mac got hot during play.",
            ],
            known: [
                "LEGO's whole picture comes from the game's own 16:9 setting (its AspectRatio), which Anvil hasn't yet seen on this screen. If the picture looks squeezed rather than bordered in black, choose “Fill the screen” under Graphics on its Performance tab.",
                "While FSR 3 has stepped aside, edges in motion shimmer as they do with FSR 1; that is the trade for holding 80 where the GPU can't do both.",
                "A long session holds 80 even where the game could make 120. Settings › Long sessions › Never keeps the old behaviour.",
            ]),
        Release(
            version: "0.29.0",
            date: "3 October 2026",
            headline: "FSR 3 for every game: a third FSR 3 option that needs nothing from the game — Anvil measures the motion from its frames — compiled and tested for each game by Graphics Prep.",
            fixed: [
                "Graphics Prep's ready-made shaders were never used in a game: LEGO's sessions on 0.28 all said \"0 of 14 pipelines ready-made\", where Graphics Prep's own check had found 14 of 14. Metal compiles a shader as the newest language version the program was built for, and Wine is built for macOS 15 while Anvil's helper is built for macOS 27 — so the game's copy of Anvil's shaders never matched the archive. The version is now named, the same everywhere; reproduced with a program built as Wine is: 0 of 18 before, 18 of 18 after, and the first frame no longer waits half a second for them. Every game is prepared again once.",
                "Frame generation's motion was measured for the wrong part of the picture: with Anvil's default motion setting, its grid of blocks reached only half-way across and down the frame, and each vector was used at twice its block's position — motion from the top-left quarter, applied to the whole picture. Each block now covers its own part of the frame. This may be behind the distorted motion seen in generated frames before.",
                "The Graphics Scan said LEGO Star Wars had \"FSR 3.1 (FidelityFX SDK 1.0.1.41314)\" of its own in some scans and nothing in others, on the same program and the same engine. That FSR 3.1 was Anvil's: the FidelityFX payload force-injected into its folder from the Upscaling page, which Autopilot took out again after each session. The scan counted any FidelityFX library beside a game as the game's. A kept scan was also read back while only the program and engine were unchanged, so \"FSR 3.1\" outlived the files. LEGO's program carries no FSR at all. The scan now tells the game's own libraries from those Anvil injected, by the injection's record and the files themselves. Where an injection set the game's own copy aside, that copy is the one named. The libraries beside a game are now part of what a kept scan is of, so they can't outlive a change. Every game is scanned again once, and what its last session showed is kept. Checked with Anvil's own injection put in and taken out of a made-up game: five scans in a row give the same answer with it there and without.",
                "The Upscaling page's own scan had the same blind spot. With Anvil's FidelityFX force-injected into its folder, a game with no FSR, such as LEGO Star Wars, was said to integrate FSR, with Anvil's version given as the game's; an injected shim's XeSS and DLSS libraries counted too. A Rescan then kept “FSR 3 temporal — only if the game already has FSR”, and “Install into game” was offered for an FSR the game doesn't have. That scan now counts only the game's own libraries too. Where an injection set the game's copy aside, its version is read from that copy. A mode the game's files don't support now runs as FSR 3 for every game at launch, as the page says it will; before, that held only for a game never scanned, and one scanned without FSR launched set up for an upscaler that wasn't there. Rescan no longer changes the mode of a forced injection. Checked with Anvil's injection put in and taken out of made-up games: five scans in a row give the same answer with it there and without, and a game's own FSR 2.2.1 under Anvil's 3.1.5 is reported as 2.2.1.",
            ],
            added: [
                "“FSR 3 — every game”, a third FSR 3 option beside the two that need a game's own FSR, DLSS or XeSS, and now the recommended one. Like AMD's FSR 3 it is temporal: each frame is upscaled (AMD's EASU), sharpened (RCAS) and blended with the frames before it, moved along their motion, at the display's size — so edges that shimmer and crawl in motion settle. AMD's needs the game's motion vectors; Anvil measures the motion from the game's own frames instead: per 16×16 pixels, scored at a dozen guesses (no motion, last frame's here and around, the coarse field's), refined to a fraction of a pixel by two gradient steps, and made to agree with its neighbours so a repeating pattern can't fool it. The blend takes each pixel's history from where its motion says — or from where it is, for a HUD over a moving scene — and holds it to what the current frame's neighbourhood allows, so a wrong measurement falls back to the frame rather than smearing. All of it runs in one pass at the display's size, in the game's own command buffer; nothing is held back, so it adds no latency beyond its GPU time.",
                "Measured on the M4 with a moving test scene against a supersampled picture of it (LEGO's 1512×982 to 3024×1934): in motion 16–19% closer than FSR 1, 19–22% less flicker, 16–18% closer standing still, no trail behind a moving object. Also better at 1280×720 and 1920×1080 to 3024×1964 and in 16-bit colour. It costs 3.6 ms a frame against FSR 1's 1.4.",
                "Frame generation after FSR 3 is made from the frames as shown and FSR 3's own motion — finer than its own measurement, which it then skips — straight into the display's frame.",
                "Graphics Prep compiles FSR 3's four pipelines with the rest (18 in all) and tests FSR 3 on that moving scene at each game's own sizes and colour format, beside FSR 1. FSR 3 is used for a game where it comes out better; FSR 1 where it doesn't. The result is on the game's Performance tab and in the wait before a start.",
                "Every game and container that used FSR 1, MetalFX or no upscaler mode moves to FSR 3 once; one set to a game's own FSR or DLSS keeps it. Because Anvil's shaders changed, every game is prepared again once before its next start. A game that closes unexpectedly with FSR 3 on goes back to FSR 1 for its next start (Autopilot), and FSR 3 switches itself to FSR 1 for the session if anything it needs isn't there.",
                "game.log says when FSR 3 starts, how many frames it took in each stretch, and why it stopped if it did; the check-up after a session says so too.",
            ],
            known: [
                "This is Anvil's FSR 3, not AMD's FSR 3 library: AMD's takes motion vectors, depth and a jittered camera from inside the game's renderer, which only a game built for it hands over. Anvil's measures motion from the finished frames, which is why it works everywhere — and why, where the motion is hard to see (fast-changing effects, fine repeating detail), a pixel falls back to the current frame rather than gaining from the ones before. A game with its own FSR, DLSS or XeSS can still turn that on in its menu; the Graphics Scan says which.",
                "At the display's own size there is nothing to upscale, and on the test scene the blend alone came out slightly worse than the game's own frame there (motion measured from the frames isn't quite exact enough for that). Such a game — Cat Quest II draws at the display's size — keeps its frames as it draws them, with frame generation, unless Graphics Prep's test at its sizes finds otherwise. For more frames in any game, choose a lower resolution in its own settings: FSR 3 takes whatever it draws to the display.",
                "FSR 3 adds about 2 ms of GPU time a frame over FSR 1 at LEGO's sizes on an M4. In a game held back by its GPU that is a few frames a second of its own; frame generation still doubles what reaches the display. “FSR 1 — built in” and the Maximum FPS preset remain the cheapest.",
            ]),
        Release(
            version: "0.28.0",
            date: "3 October 2026",
            headline: "Graphics Prep: Anvil's FSR and frame generation compiled for your Mac and tested on its GPU before a game starts — a short wait, shown step by step, that you can skip.",
            fixed: [
                "After every Anvil update, and whenever macOS cleared its shader cache, a game's first frame waited while Anvil compiled its shaders: 690 ms for the library and 116 ms for the pipelines cold, measured on an M4 under Rosetta (287 ms in LEGO's first session on 0.26). They now start compiling in the background the moment the game opens Metal, while it is still loading, and the pipelines come ready-made from Graphics Prep in 1 ms.",
            ],
            added: [
                "Graphics Prep, before a game's first start: Anvil looks at the game's graphics (its Graphics Scan), puts the game's own compiled shaders back where D3DMetal reads them if macOS cleared them, compiles all 14 of its FSR and frame generation pipelines for the Mac's GPU into a Metal archive, and tests FSR on the GPU at the game's size and in its colour format — a flat colour must come out unchanged, and each way of running FSR must give the same picture. It times them, keeps the quicker, and has the game's own side (under Rosetta, as the game runs) open the archive to check every pipeline is found. About two seconds the first time, under one after; again only when Anvil's shaders, macOS, the GPU or the game's colour format change. It runs in a process of its own, stops itself at a minute, and whatever happens the game starts. Each step shows as it goes, with Skip and Start.",
                "On each game's Performance tab: what Graphics Prep found — how many pipelines are ready-made, which way FSR runs and what it costs a frame, frame generation, the game's own compiled shaders — a Prepare Now button, and a switch to start without the wait.",
                "FSR in one pass, where it is quicker: EASU and RCAS in a single dispatch, the upscaled tile kept in the GPU's threadgroup memory so the full-size frame never goes out to memory between them. Measured on an M4 at 1512×982 to 3024×1934: 1.57 ms a frame for a 16-bit float picture against 1.88 in two passes — 17% less GPU time on every frame shown, generated ones included. For 8- and 10-bit pictures two passes stay quicker (1.44 ms against 1.52) and are kept. Chosen per game by measuring it, checked against the two-pass picture, and put back to two passes by Autopilot if the game closes unexpectedly with it.",
                "game.log says where Anvil's shaders came from each session — ready-made from Graphics Prep or compiled, and how long the first frame waited for them, if at all — and the game's page shows it after the session.",
            ],
            known: [
                "Graphics Prep compiles and tests Anvil's own part of the picture. A game's own shaders are compiled by D3DMetal the first time the game uses each one and kept from then on — Anvil keeps a copy macOS can't sweep away — but nothing can compile them before the game asks for them, because only the game knows what they are. That is the hitch a new area can still have, once.",
                "For LEGO Star Wars, which draws in 8-bit colour, FSR was already as quick as it gets on the M4. Of the ways measured — two passes in seven threadgroup shapes, one pass in seven, EASU reading its patch of the frame once per group, and EASU's edge fit worked out once per texel — the two passes LEGO already ran were quickest, so it keeps them, its picture unchanged to the last bit. What Graphics Prep changes for LEGO is the start: no compile wait.",
                "FSR 3 itself still needs the motion vectors and depth only a game's own renderer has; see the Graphics Scan.",
            ]),
        Release(
            version: "0.27.0",
            date: "3 October 2026",
            headline: "A graphics scan for every game before its first start, DLSS through Apple's MetalFX, and FSR in more games.",
            fixed: [
                "LEGO Star Wars froze for good seven minutes into a session on 3 October, as it loaded a new area: through D3DMetal it asked Metal for a depth-stencil state with stencil operations and a compare function out of range, and Metal answers that with a failed assertion that stops the process. Anvil now looks at every depth-stencil state on its way to Metal and puts a value out of range back to Direct3D's own default (keep; always). Reproduced on the M4 with the exact values — the process stops without Anvil, and with it the state is made and a frame using it completes, on Apple silicon and under Rosetta, with Metal's validation on too.",
                "After that freeze, Autopilot switched FSR and frame generation off for LEGO, though neither touches depth or stencil. A crash is now read first: when the logs name a cause FSR and frame generation have nothing to do with, they stay on and the cause is said. LEGO's were put back on.",
                "The container advice set generated frames off after every session — left over from before 0.26 — so frame generation went off for LEGO's container after its first session. Removed; the player's choice stands, and it was put back on.",
                "Smoothest frame generation built a new MetalFX interpolator and five textures for every frame it generated, and never freed the old ones: several megabytes a frame. Found on the GPU bench (461 builds in 20 seconds); now one, with memory flat over a minute at 59 generated frames a second.",
                "Smoothest's generated frames with FSR to the display were stretched straight to the display's pixels, softer than the FSR'd real frames either side of them. They now go through FSR like the game's own.",
                "For Unreal games, the anti-cheat check looked inside the game's own folder, not the install folder above it where Engine and Easy Anti-Cheat sit.",
            ],
            added: [
                "Graphics Scan: before a game's first start — and again after an update or on another engine — Anvil reads what it draws with, the engine it was built on, every upscaler and frame generator it ships (FSR 2, 3, 3.1 and 4, DLSS and DLSS frame generation, XeSS, with versions read from the libraries), its anti-cheat, the engine it runs on and the display, and decides what to do. It takes well under a second for most games (1.4 s for LEGO's 100 MB program) and runs for every game in the background when Anvil starts. The first session then shows what really happened — what drew the game, at what size, in what format, whether FSR ran, how many frames were generated — and that is kept with the scan. On each game's Performance tab.",
                "DLSS through Apple's MetalFX: for a game that ships DLSS, on Mythic Engine 3.0, Anvil sets up Apple's DLSS-to-MetalFX translation (in D3DMetal 3.0): choosing DLSS in the game runs MetalFX temporal upscaling from the game's own motion vectors and depth — the kind of upscaling FSR 3 does — and DLSS frame generation runs as MetalFX frame interpolation. Nothing goes into the game's folder or the engine: Anvil's own folder and the container's system32. Not for a game with anti-cheat; switched off by itself if the game crashes with it on.",
                "FSR to the display in more games: sRGB colour (through a plain view of the same pixels, so FSR works on the picture as encoded, as AMD intends), 10-bit colour, and 16-bit float in the standard range — each written and checked on the M4 with exact colours, with frame generation through it. HDR beyond the standard range is left as the game draws it.",
                "Anvil's library says which part of the engine sets the size of each picture it draws, so the scan can tell D3DMetal from MoltenVK from Wine itself.",
            ],
            known: [
                "FSR 3 itself — its temporal upscaling and frame generation — needs motion vectors and depth that only a game's renderer has; nothing outside a game can switch it on. Where a game has them (DLSS, or its own FSR 2/3), the scan says to choose that in the game; everywhere else Anvil does what AMD's own driver does for games without FSR: FSR 1 on the finished picture, and frames generated from the picture.",
                "DLSS through MetalFX is set up exactly as Apple's toolkit describes, and checked as far as Wine: a program asking for nvngx.dll gets Apple's translator, which loads the engine's own D3DMetal. None of the games here ships DLSS, so it hasn't been seen running in a game; whether a game offers DLSS on a Mac is the game's decision.",
                "FSR to the display reaches games D3DMetal draws (DirectX 11 and 12). A game drawn through MoltenVK (Vulkan, or DirectX on DXVK) or by Wine's own OpenGL renderer is shown as before; the scan says which.",
            ]),
        Release(
            version: "0.26.0",
            date: "3 October 2026",
            headline: "AMD FSR in every game, and frame generation you can switch on for any of them.",
            fixed: [
                "Frame generation recorded the frames it worked from on a GPU queue of its own while the game drew on another, so a copy could run before the game had finished its frame. Everything Anvil does with a frame now goes on the game's own queue, after it.",
                "Chosen by the player, frame generation switched itself off whenever the game seemed able to fill the display — and while generated frames wait for a drawable the game seems far faster than it is (56 fps read as 156 in Anvil's bench), so it turned off and on every 13 seconds. It stays on for the session; whether a refresh needs a frame is still decided frame by frame.",
            ],
            added: [
                "FSR to the display, in every game, on by default. A game under Wine draws at its window's size — half the display's pixels each way on a Retina Mac — and macOS stretched that to the panel with a bilinear filter. Anvil now hands the game a drawable of its own size, and takes its frame to the display's full resolution with AMD FSR 1: EASU, ported from AMD's FidelityFX SDK, then RCAS sharpening. Edges come out half as wide as the stretch made them (2 px against 4, measured), with no halos; it holds no frame back, so no latency is added; it costs 1.47 ms a frame at 3024×1964 on an M4 (measured, in 16-bit, which Apple GPUs run at twice the rate). Only where D3DMetal presents the frames, in 8-bit colour; anything else is shown as before.",
                "Frame generation for every game, on for all of them: when a game is below the display's rate Anvil makes the frames in between from the motion between the game's own, on a variable-refresh display too — 60 of the game's frames and 60 generated, 120 on the display, evenly spaced. Lowest latency (projected forward: about 6 ms more from drawing to display at 60 fps, measured) or Smoothest (Apple's MetalFX interpolation, a frame more). Generated frames go through FSR like the game's own.",
                "Auto-Tune, the engine trial and the checks after a session measure the game's own frames whatever was generated, and Auto-Tune measures with generation off. A game that closes unexpectedly with frame generation or FSR on has both switched off for it, and says so.",
                "Anvil's test bench for both (fsr_bench) runs on the Mac's GPU: AMD's EASU against a bilinear stretch, and the whole present path as D3DMetal drives it — 5,850 frames with generation on, the game resizing mid-session, layers FSR must leave alone — with no frame lost or held up.",
            ],
            known: [
                "This is FSR 1, AMD's spatial upscaler, with Anvil's own frame generation — not FSR 3's temporal upscaling and frame generation, which need motion vectors, depth and a jittered camera from the game itself; a game without FSR can't supply them.",
                "Generated frames come from the picture alone, so fast motion and on-screen text can show a little smearing in them.",
                "D3DMetal draws at the size the game asks for, so FSR makes the picture sharper but doesn't make the game draw fewer pixels: the frame rate comes from frame generation. In a game already short of GPU, FSR's 1.5 ms can cost a few frames a second; it can be switched off per game under Upscaling.",
                "Not yet seen in a real game session: the bench drives the same calls D3DMetal makes, but on a layer that isn't on screen.",
            ]),
        Release(
            version: "0.25.1",
            date: "3 October 2026",
            headline: "The checks after a session no longer suggest an engine already tried and switched back from.",
            fixed: [
                "After every LEGO Star Wars session the checks suggested Engine 3.0, which was tried on 1 October and switched back from — slower here (83 fps typically against 95) and without the Switch Pro mode the pad uses. An engine a container switched back from isn't suggested again; the checks say it was tried.",
            ],
            added: [],
            known: [
                "In heavy parts of LEGO Star Wars the game typically makes about 64 fps on this Mac, with the processor and graphics taking turns — the limit of D3DMetal 2.1. Auto-Tune is measuring its graphics levels while you play, and keeps the one that holds 80 best.",
            ]),
        Release(
            version: "0.25.0",
            date: "3 October 2026",
            headline: "LEGO Star Wars loads offline and behind other apps, and Anvil checks and fixes itself.",
            fixed: [
                "With Offline Mode on and the Mac still connected, LEGO Star Wars sat on its loading screen: it was still there after 45 seconds in front on 3 October, with a connection to Epic open. Started offline, an Epic game gets its account but no sign-in code — exactly what Epic's own launcher gives it — and on a connected Mac it reached Epic and tried to sign in with nothing. A game Anvil starts offline is now kept off the network for that session, as with Wi-Fi off: names don't resolve and connections out of the Mac are unreachable, so it finds no connection at once and carries on offline. An offline start with it reached the game in 36 seconds, as an online start does, and another finished loading while behind other apps. Everything inside the Mac is untouched, and online starts are as they were.",
                "LEGO Star Wars stops whenever another app is in front, its loading included — its own code sleeps ten milliseconds at a time until it is back. Every start closed as stuck had spent part of its load behind Anvil, Finder, Chrome or Claude; one was still on its loading screen, paused, twenty minutes later. Its engine has a switch of its own to carry on (-NoFocus_Process), and Anvil now starts any game whose program has it that way: a load finishes while you're elsewhere. Behind other apps the game is held to 30 fps, so it costs little. It's on unless switched off in the game's settings, under Behind Other Apps.",
                "The controller driver took a quarter of a processor core for whole sessions — with LEGO Star Wars paused behind another app too — reading the pad a thousand times a second. The pad is still read every millisecond while it's in use, so it feels the same; after five seconds untouched it is read every 4 ms until it moves, and every 10 ms while the game is behind another app.",
                "Auto-Tune counted a start that sat on its loading screen or at a sign-in as play, and closed LEGO Star Wars at its menu for \"1.6 minutes measured\" on 3 October. For a game whose sessions always go on into a heavier first scene, play now starts there and a session that never got there has none; stretches drawn behind other apps count nowhere.",
                "A failed offline Epic start, or a start with no Epic sign-in, went unreported by the checks after a session: what the launch log says had changed. Both are reported again, with the sign-in a button away.",
            ],
            added: [
                "A game that finishes loading while you're in another app says so: a notice that it's ready, which brings it forward when clicked, and \"Ready\" in the Now Playing bar. LEGO Star Wars takes about 35–40 seconds from Play to its first scene on this Mac, online or offline — its own logos and loading, which can't be skipped — so it can now be started and left.",
                "Check-Up, under System: Anvil looks over everything a game depends on when it starts and after every game, online or offline, and fixes what it safely can by itself — every Epic game made ready to start offline (from legendary's offline answer, which reaches nothing), saves copied where there's no copy from the last week, its own leftover files tidied. It says when the Epic sign-in is missing, Rosetta isn't installed, the disk is nearly full, a game's program has gone, an engine has changed since it was sealed, or Windows programs are still running with no game behind them, which one button stops.",
                "Auto-Tune keeps learning after it decides. Every session with its choice adds to what it knows, and when two sessions in a row run clearly below what that choice measured — a heavier part of the game, an update, a Mac running hot — it measures every setup again while you play. Nothing is closed or restarted for it.",
                "After a game is closed while still loading, its Overview says for how long it was in front, how long it usually takes to load here, and whether something held it up.",
            ],
            known: [
                "LEGO Star Wars' start still takes about 35–40 seconds: its logos and loading are its own, packed into its game files, and Anvil doesn't change a game's files. On 3 October an offline start reached the game in 36 seconds, as online ones do.",
                "A game can still draw frames on a light loading screen that are never shown (up to a quarter of them on LEGO Star Wars'). Making it wait for each refresh instead was tried in this release and taken out again: it made the loading screen stutter between 80 and 120 fps.",
                "Started offline, a game has no connection at all for the session: achievements and DLC ownership are checked again at the next online start.",
                "A game kept running behind other apps still hears the controller there.",
            ]),
        Release(
            version: "0.24.2",
            date: "3 October 2026",
            headline: "Anvil's protection key survives a restart.",
            fixed: [
                "After this Mac restarted, the Secure Enclave refused the key it had held for Anvil since 30 September (\"unable to compute shared secret\", from Anvil and from any other program alike). 0.24.1 then made a stand-in key, and the Epic sign-in sealed with the old one could no longer be opened. Anvil's key is now 512 random bits in its Keys folder, readable only by you, mixed with this Mac's own hardware identity: the same after every restart, update or password change, and useless on another Mac.",
                "What an earlier key sealed is opened with it and sealed again with the new one — the Epic sign-in, each game's offline start and every engine's seal. An engine sealed with an earlier key is checked against that seal first, so a changed file is still caught; a launch is never refused because the key changed.",
                "A sign-in no key on this Mac can open is set aside as user.json.sealed.unreadable, not deleted, and Epic shows as signed out so it asks for a sign-in — instead of counting a sign-in it couldn't use. It comes back by itself if a key for it turns up. While Anvil has none, Mythic's Epic sign-in on this Mac is brought in again.",
                "Without a sign-in, an Epic game's start ran legendary anyway, which spent 4.6 seconds failing and reported only \"No module named '_socket'\" — an error legendary's packaging throws on the way out, after the real one (no account to start the game as). Anvil now says Epic isn't signed in, at once, and a failure reports legendary's first error rather than its last. legendary is also told the Mac's language, which an app started from the Dock doesn't pass on.",
            ],
            added: [
                "The game log counts frames the game handed to the display that it never showed. LEGO Star Wars, started offline on 3 October, handed over 600 for every 450 shown on its loading screen.",
            ],
            known: [
                "The Epic sign-in sealed with the Secure Enclave key before the restart can't be opened by anything: sign in to Epic once more in Stores. A game's offline start is made again by its next online start.",
            ]),
        Release(
            version: "0.24.1",
            date: "2 October 2026",
            headline: "Games start sooner: Anvil's own part of a launch cut from up to 6 seconds to about 1 offline.",
            fixed: [
                "The save backup before LEGO Star Wars' first start on 0.24.0 took 1.9 seconds, against 50 ms for the saves themselves: it looked into the Mac's own Documents folder, which the Windows Documents folder links to, and macOS makes an app wait for permission there. It no longer looks there — nothing in it is a container's — and a backup never holds a start up for more than half a second; it finishes beside the game, which writes no save in its first seconds.",
                "Online, the Epic sign-in waited for a separate look at whether Epic could be reached — a round trip, about a second through a VPN — before it began. Both now start together. Offline, a game starts from Anvil's sealed copy of its last online start, with no run of legendary at all.",
                "The daily full check of every engine's files ran at Anvil's start even with a game starting, competing with the game's own loading. It now waits for a start with nothing running; each launch still checks its own engine first.",
                "In a heavy stretch swinging between 45 and 97 fps, Steady held the game at 80, let it go a second later and held it again — 24 changes in half a minute in a model of LEGO Star Wars' 2 October session. A hold that has to let go within 3 seconds now waits before the next, longer each time: 8 changes in the same half minute.",
            ],
            added: [
                "While a game loads, the Now Playing bar shows how far it is into the time it usually takes on this Mac, from its earlier sessions.",
            ],
            known: [
                "LEGO Star Wars' opening logos are its loading screen and can't be skipped; on this Mac they take about 20–30 seconds, with the processor and graphics mostly idle — a fixed sequence, not work Anvil can speed up. Offline it is if anything quicker than online, since the game's Epic sign-in has nothing to wait for. It still pauses while another app is in front.",
            ]),
        Release(
            version: "0.24.0",
            date: "2 October 2026",
            headline: "Higher frame rates, a game that is still loading no longer looks stuck, and every save backed up before every game.",
            fixed: [
                "Steady pacing held LEGO Star Wars to 60–74 fps all through its last three sessions while the game could make 85 and more, with the GPU 55–85% busy and its busiest thread under half a core. Held to an even 80 in its first second, the game was then found on a display not following it — which happens in some sessions and not others — and the hold carried on regardless: on a fixed refresh a frame held for 12.5 ms waits for the 16.7 ms refresh, so it was shown at 60. Nothing is held now on a display that doesn't follow the game, and Anvil looks again after 30 seconds and then less often, since the same display follows the game in most sessions.",
                "Steady also showed every game between 80 and 108 fps at exactly 80, and let one go only when it could make 119 — so a game able to make 100 was shown at 80 for a whole session. It now holds only a game below about 94 at an even 80; from about 98 the game runs at its own rate, up to 120. Auto-Tune measures again what it measured under the old pacing.",
                "LEGO Star Wars started offline looked stuck on its loading screen. It wasn't: online it takes about 40 seconds to load on this Mac (up to nearly 2 minutes), and every offline start was closed after 23 to 43 seconds — each time after switching to Anvil, Finder or Chrome, and the game stops, loading included, whenever another app is in front. In the one offline start it was given 20 seconds in front, it reached its first scene. The Now Playing bar now says how long the game takes to load here and that it must stay in front, and Quit asks first while it is still loading.",
                "Deleting a container erased it outright if the Trash refused it. It is now set aside in Removed Containers instead, and its saves are backed up first, somewhere emptying the Trash doesn't reach.",
                "Restoring a snapshot could swap a container out from under a running game, and erased the copy it replaced. It now refuses while a game runs or starts there, stops Wine's server first, backs the saves up, and sends the replaced copy to the Trash — with any game installed inside since.",
                "A library that couldn't be read for a moment could be saved over with an empty one. Anvil now never writes over a library it couldn't read, never saves an empty library over a full one unless you removed the last game, and keeps hourly copies to bring back a missing one.",
                "Taking an upscaler out of a game's folder could remove a file the game had since updated, or put an older one back over it. Only Anvil's own copies come out now, and a copy that fails half-way puts the game's own file straight back.",
            ],
            added: [
                "Save Backups: before every game starts, the container's saves are copied — only when they changed, leaving out logs, caches and anything in the Mac's own Documents that isn't a game's folder. On this Mac's drive a copy is a clone that takes no space until the game changes a file. The newest ten are kept, and one a day for a month, in each container's settings, with Put Back.",
                "After a game closes, any save file that was whole before and is empty now — what a game ended while writing leaves — is put back from the copy made before it started.",
                "Quit gives a game that is still writing its save up to half a minute more before forcing it.",
                "A game isn't started with less than 1 GB free, where a save written onto a full disk would be a broken save; below 5 GB Anvil says so.",
            ],
            known: [
                "A game shown as ready between 98 and 119 fps alternates 8.3 and 12.5 ms frames on a ProMotion display; that is the cost of the higher rate.",
                "Games pause in the background on their own; Anvil can't keep one loading while another app is in front.",
            ]),
        Release(
            version: "0.23.3",
            date: "1 October 2026",
            headline: "Epic games start offline at once, and a game stuck on one screen says why.",
            fixed: [
                "Started offline, an Epic game waited up to 10 seconds before it began: 3 to find Epic out of reach, then about 7 for legendary — a single-file build that unpacks itself on every run — to give the offline arguments (LEGO Star Wars, 1 October, 22:07). Anvil now keeps those arguments from each game's last online start — the one-time sign-in code taken out, sealed with this Mac's key (AES-256-GCM) — and starts the game from them offline without running legendary at all. They are dropped when a different Epic account signs in."
            ],
            added: [
                "The game log lists every window a game has open 15, 45 and 90 seconds after its first frame, and whether it is the app in front. LEGO Star Wars, started offline twice on 1 October, stayed on one screen until it was closed; a Windows message box hidden behind the fullscreen picture, or nothing at all, now shows there."
            ],
            known: [
                "Whether LEGO Star Wars' Epic version can get past its first screen offline isn't known yet. It signs in to Epic Online Services only with the one-time code an online start gives it, and offline there is none; Epic marks it as able to run offline, but its sign-in system holds the game while it signs in. If it can't, the way round it is to start it while online — it signs in within seconds — before going offline; whether it then keeps going without a connection the next session's log will show."
            ]),
        Release(
            version: "0.23.2",
            date: "1 October 2026",
            headline: "Steam's “can't connect” errors explained, with what to do.",
            fixed: [
                "Steam opened after its update but kept saying there was an error. Its own logs show it never signed in: 34 of Steam's servers didn't answer — in Frankfurt, Santiago, São Paulo, Buenos Aires, Lima, Johannesburg and others, none in the US — and its sign-in found no connection four times. Proton VPN was connected: Steam picks its servers by where a connection seems to come from, and often can't sign in through a VPN. Health now reads Steam's logs after each session and says this — which servers failed, that a VPN is on and which, and to turn it off or choose a server in your own country — and when Steam is on a preview engine, offers Engine 2.6.1 for it with one click. Starting Steam while a VPN is on says so up front."
            ],
            added: [],
            known: [
                "The other message Steam showed — “Failed to reconnect to websocket” — is Steam's own check that its window lost touch with its web view for a moment; it came back on its own. On Engine 3.0 Steam's web view also met a network call Wine 9 doesn't support (Windows socket error 10045), which Engine 2.6.1 is worth trying for if Steam still can't connect with the VPN off."
            ]),
        Release(
            version: "0.23.1",
            date: "1 October 2026",
            headline: "Game Mode on Engine 3.0, found and fixed.",
            fixed: [
                "Games and Steam on Engine 3.0 never got Game Mode: macOS registered them as plain “wine” with no app. Naming the right program in Anvil's Game Mode copy (0.19.2, 0.21.1) couldn't help, because Engine 3.0's Wine copies its program into a temporary folder and runs every process from there — …/T/winetemp-…/wine, services.exe, explorer.exe — so each shows under its Windows name, outside any app (lsappinfo: bundleID NULL, for Steam on 1 October). macOS's CoreFoundation takes a process's own path from CFProcessPath when it is set, so Anvil now sets it to its Game Mode copy's program for engines like this: tried on this Mac with an Intel program under Rosetta, as Wine runs, macOS then registered it as dev.anvil.game.mythic-engine-3.0.0 at Anvil Game.app, in the games category."
            ],
            added: [],
            known: [
                "The next start of Steam or of a game on Engine 3.0 shows it in the launch log: “focus: … came to the front (as dev.anvil.game.mythic-engine-3.0.0, bundle Anvil Game.app)”."
            ]),
        Release(
            version: "0.23.0",
            date: "1 October 2026",
            headline: "LEGO Star Wars back on its faster engine with the Switch Pro mode, and Steam's first start made to finish.",
            fixed: [
                "An engine trial only compared speed, so it couldn't see what a new engine took away. Engine 3.0 was kept for LEGO Star Wars because it held 80 as often as 2.6.1 — but it typically ran at 84 fps against 95, and on it the PowerA pad lost the Switch Pro mode it gets on Engine 2.6.1 (Wine 9 has a different controller driver). A new engine that takes away something the game was using now has to be clearly faster to stay. Judged again under that rule, from Auto-Tune's 4.4 minutes on Engine 3.0, LEGO Star Wars goes back to Engine 2.6.1 at the next start — its saves and settings as they are — and Engine 3.0 isn't tried there again until Anvil supports it better. It can still be chosen by hand.",
                "Steam's first start was cut short 14 MB into its 328 MB download — its window was closed or quit while it updated — and Health called it a failed start. Valve's installer puts in only Steam's updater, which downloads Steam at its first start. Anvil now shows that download's progress while it runs (“Steam is updating — 14 of 328 MB. Leave it open until its window appears”), and Health says when it was stopped and that opening Steam again carries on where it stopped.",
                "Health counted Steam's own entry running without Anvil's enhancements as a problem. Anvil runs Steam that way on purpose — its windows have nothing to pace — so it no longer does."
            ],
            added: [],
            known: [
                "The Epic sign-in still takes about 3½ seconds with Anvil's own legendary: it is a single-file build that unpacks itself on every run, and repackaging it isn't safe to do. Offline Mode skips the sign-in.",
                "LEGO Star Wars' first start back on Engine 2.6.1 takes about 13 seconds longer once, while Wine sets its Windows setup back to 2.6.1's files."
            ]),
        Release(
            version: "0.22.0",
            date: "1 October 2026",
            headline: "Games with anti-cheat kept safe from anything that could look like tampering, and better gaming on a MacBook's trackpad and keyboard.",
            fixed: [
                "Nothing stopped Anvil from putting upscaler libraries into the folder of a game with anti-cheat — a library that isn't the game's own is exactly what anti-cheat flags, and that can get an account banned. Anvil now never puts files into such a game's folder: Force injection and installing an upscaler are refused there (the Upscaling page says why and offers “FSR — built in”, which changes no files), a launch leaves any old injection setting out, and files Anvil put there before are taken out at the next launch, putting the game's own back."
            ],
            added: [
                "Trackpad & Keyboard, in each container's settings. Two-finger scrolling reaches games as whole mouse-wheel steps — Wine otherwise passes the trackpad's smooth scrolling as fractions of a step, which many Windows games ignore or read as dozens of steps at once. The left Option key works as Alt (the right one still types accents), and the ⌘ keys can work as Ctrl, far easier to reach on a laptop than Control. Scrolling in steps and Option as Alt are on for every container; they are written to Wine once, at a container's next launch, in a second or two."
            ],
            known: [
                "Online play in games with anti-cheat works only where the game's maker allows it on a Mac. Kernel-level anti-cheat (Riot Vanguard, EA Javelin and others) needs Windows itself and never runs under Wine; Easy Anti-Cheat and BattlEye only where the maker has switched on their Wine support, which on a Mac is rare. Anvil doesn't work around anti-cheat — that is what gets accounts banned. Such games' own Mac versions, or cloud services like GeForce NOW, are the safe ways to play them online.",
                "Wine's handling of the trackpad and keyboard settings was not run here — this sandbox can't start Wine. What was checked: the settings file Anvil writes and the single Wine run that imports it, on a stand-in engine.",
                "Some limits aren't Anvil's to lift: the Switch Pro mode needs Wine 7.7's controller driver (Engines 2.6.x), D3DMetal is Apple's and comes only with the engine, and the Epic sign-in speed is legendary's own build."
            ]),
        Release(
            version: "0.21.1",
            date: "1 October 2026",
            headline: "Offline Mode, faster offline starts, engines read correctly, and another go at Game Mode on Engine 3.0.",
            fixed: [
                "Every engine was recorded as not starting on this Mac — Engine 3.0 included, two minutes after it ran LEGO Star Wars at 120 fps — so Autopilot would never have offered one. The warm-up looked for Wine's registry the moment its first run ended, but Wine writes it a few seconds later, when its server finishes. It now waits for the server, also counts the Windows folder Wine makes during the run, and treats an engine as not starting only when that is certain: it couldn't be run at all, or failed at once without making anything. The four wrong records are dropped and the engines prepared again.",
                "LEGO Star Wars still wasn't the Game Mode app on Engine 3.0: it came to the front as plain \"wine\". Engine 3.0 runs games inside its own preloader, wine-preloader, just as Engine 2.6.1 runs them inside wine64-preloader — the name that works there — so Anvil's Game Mode copy of Engine 3.0 now names wine-preloader, and is rebuilt once.",
                "With the Mac connected but Epic out of reach — a VPN still connecting, as on 1 October, or a network that wants its sign-in page — a launch waited up to 15 seconds for the sign-in to give up. Anvil now checks that Epic answers (3 seconds at most) and otherwise starts the game in Epic's offline mode at once.",
                "Offline, a Steam game waited up to 2½ minutes for Steam to sign in. It now waits 20 seconds, then starts the game and says how Steam's own offline mode is turned on.",
                "An engine trial said the new engine \"runs at least as well\" when it was only as smooth: LEGO Star Wars held 80 or more as often on Engine 3.0 (90%) but typically ran at 83 fps against 95 on 2.6.1. It says that now."
            ],
            added: [
                "Offline Mode, in Settings, the Game menu and Anvil's menu bar menu: play without connecting even while the Mac is online. Epic games start in Epic's own offline mode as your account, with your saves; Anvil downloads and fetches nothing until it's switched off. The sidebar shows it, and a click there turns it off. A game that needs a connection to play still needs one. Without a connection Anvil does all this by itself, as before."
            ],
            known: [
                "Whether naming wine-preloader brings Game Mode to Engine 3.0 shows in the next session's launch log: \"focus: … came to the front (as dev.anvil.game.mythic-engine-3.0.0, bundle Anvil Game.app)\". This sandbox can't run Wine to see it first.",
                "The engine warm-up's new check was run on stand-in engines here — one that writes its registry late, one that makes only its Windows folder, one that fails at once — not on real Wine.",
                "The Epic sign-in at launch takes about 3½ seconds with Anvil's own legendary (once 12), against about 1⅓ with Mythic's: Anvil's is a single-file build that unpacks itself on every run. With Offline Mode on there is no sign-in, and a game starts in under a second.",
                "LEGO Star Wars stays on Engine 3.0, which its trial kept: as smooth as 2.6.1, at a lower typical frame rate. Switch pads reach it as Xbox-style pads there; Engine 2.6.1 can be chosen again for the Pro Controller under Toolchain in the “Star Wars” container's settings."
            ]),
        Release(
            version: "0.21.0",
            date: "1 October 2026",
            headline: "Auto-Tune and the engine warm-ups fixed after LEGO's first 0.20 session, and the shared edition locked down as far as a Mac allows.",
            fixed: [
                "Auto-Tune lost LEGO Star Wars' six-minute session on 1 October — 95 fps on average, 80 or more 90% of the time. At each start Anvil looks over every game's last session; Play was pressed four seconds after Anvil opened, while it was still looking, and it started Auto-Tune on LEGO in the middle of its launch, after the launch had already chosen its settings, so nothing tied those minutes to Auto-Tune. A game being launched now counts as busy, exactly like a running one: Autopilot, Auto-Tune and engine switches wait until it has run, and its session is counted when it ends.",
                "No engine had been made ready for this Mac. 0.20.0's warm-up at a start was stopped by LEGO two seconds in, and was only tried again at the next start. It now begins once Anvil has been quiet for a little while after a start, carries on 45 seconds after the last game closes, and while anything is running or starting it looks again every two minutes.",
                "A warm-up ended by a game's launch could have been recorded as the engine not starting on this Mac — when the launch ended it and was over before the warm-up looked again — and Autopilot would then never have offered that engine. A warm-up a game ends is now always paused and done again, never judged."
            ],
            added: [
                "The public edition is now signed with the hardened runtime and its own entitlements, which the kernel enforces for as long as Anvil runs: no debugger can attach to it, no library it wasn't built with can be loaded into it, and no DYLD environment variable can pull foreign code in. Until now the shared copy was closed on disk — compiled with no source inside, symbols stripped, its signature checked at every start so a changed file stops it — but could still be pried into while it ran. That gap is shut. The private edition (Jay's own) is unchanged and stays fully debuggable.",
                "Settings › About says what protects the edition in front of you: the shared edition is self-checked at every start and closed to debuggers; the private one is marked as having no self-check. Both keep Anvil's own data — the Epic sign-in, the engine seals — sealed with AES-256-GCM under a key the Secure Enclave never lets off this Mac. Game files and save files are left as they are, as asked, and the engine itself is untouched."
            ],
            known: [
                "LEGO Star Wars is on Engine 3.0 on trial since its last session (it switched by itself, with a snapshot). Its next start takes a little longer once while Wine 9 updates its Windows setup (going back to 2.6.1 took 13 seconds). Engine 3.0 is kept only if it plays about as well as 2.6.1 did — 95 fps typical, 80 or more 90% of the time — and goes back by itself if it runs clearly slower, won't start or crashes.",
                "A program's own instructions cannot be encrypted at rest and still run: the CPU needs them in the clear to execute, so no Mac app encrypts its own code. What protects compiled code is being stripped, signed, tamper-evident and closed to inspection — which the public edition now is, to the limit macOS enforces. The number of bits in a cipher isn't the lever here; AES-256 already needs far longer than the universe's age to break, well beyond a 2000-bit key.",
                "Signed ad hoc (no paid Apple Developer ID), the hardened runtime is enforced by the kernel just the same; a Developer ID additionally lets other Macs verify the maker and skips the first-open warning. Set ANVIL_SIGN_IDENTITY and ANVIL_NOTARY_PROFILE when building to add that.",
                "The lockdown was built into the public edition and its signature verified here (hardened runtime present, entitlements embedded, the self-check still passes on the signed app). The kernel's refusal of a debugger and of injected libraries is enforced on a real Mac at run time; this sandbox can't launch the GUI to watch it happen."
            ]),
        Release(
            version: "0.20.0",
            date: "30 September 2026",
            headline: "Every engine made ready for this Mac by itself — online or offline — and newer engines given a fair, measured chance.",
            fixed: [
                "Engine 3.0's games still weren't the Game Mode app: the menu bar said \"CrossOver-Hosted Application\". Wine 9 starts a game's own process through the engine's bin/ folder, which in Anvil's Game Mode copy is a link, and macOS doesn't count a program started through a link as inside the app. Anvil now starts the engine by its real path and tells Wine 9 to start the game's processes from there too (WINELOADER).",
                "Autopilot could start an engine trial for a game it had nothing to compare with; such a trial could never be judged. A trial now waits until the game has a measured session of a minute and a half on its current engine."
            ],
            added: [
                "Engine profiles. Each engine is read from its own files — no Wine run, so offline as well — for its Wine version, D3DMetal, how its games run and what its drivers support, and Anvil runs games on it accordingly. The Engines page says what that means for each one (Mythic Engine 2.6.1: Wine 7.7, D3DMetal 2.1, Switch pads as a real Pro Controller; Engine 3.0: Wine 9.0, D3DMetal 3.0 handing frames to the GPU without waiting, games started from inside the Game Mode copy).",
                "Engines made ready for this Mac by themselves. When an engine is installed or updated — and at a start for any engine that isn't ready — Anvil seals it, builds its Game Mode copy and runs it once into a throwaway Windows setup, unseen, so Rosetta's translation of it is done before a game needs it and Anvil knows it starts on this Mac. One that doesn't start isn't offered by Autopilot. It runs in the background at low priority and gives way the moment a game starts.",
                "The picture fitted to the screen by itself. Anvil's library now reports whether the game's window filled the screen — or sat below the menu bar, or was larger than the screen with its edges cut off. When it didn't, the game starts the next time in the next display mode (fullscreen, a borderless window, the game's own fullscreen window), and the one that fills the screen is remembered for that kind of engine — so going back to an engine finds what worked on it.",
                "Fair retries. An engine that lost a trial before Anvil supported its kind fully gets one more measured trial once Anvil does — Engine 3.0 for LEGO Star Wars, now that its Game Mode, pacing and picture are handled — and the faster engine stays. An engine you switch back from by hand is never tried again by itself."
            ],
            known: [
                "None of this has run with Wine from here; the sandbox can't start it or show a window. Engine profiles were read from the real engines, and the retry and display rules were run on copies of the library. Whether Wine 9 honours WINELOADER for the game's own process, and which display mode fills the screen on it, the next sessions on Engine 3.0 show — and Anvil acts on what they show.",
                "LEGO Star Wars stays on Engine 2.6.1 until it has a measured session there; then Engine 3.0 gets its measured trial, starting in the display mode not yet tried on Wine 9.",
                "D3DMetal itself can't be changed: an older engine can't be given Engine 3.0's D3DMetal. What Anvil improves is everything around it."
            ]),
        Release(
            version: "0.19.3",
            date: "30 September 2026",
            headline: "LEGO Star Wars back on Engine 2.6.1, fullscreen as before, and real frames only on Autopilot.",
            fixed: [
                "Engine 3.0 was kept for LEGO Star Wars without ever being compared with 2.6.1: a trial ended after any three sessions that didn't crash, and all three were in menus or under a minute and a half. The first measured play on it ran at 58 fps typical against 81 on 2.6.1, with the picture not fitting, no Switch Pro mode and no Game Mode. The game's container goes back to Engine 2.6.1 — its saves and settings stay as they are — and Autopilot won't offer 3.0 there again; it can still be chosen by hand. From now on an engine on trial stays on trial until a measured session has judged it.",
                "0.19.2's borderless window sat below the menu bar on Engine 3.0 and didn't fill the screen. LEGO Star Wars is set to fullscreen again, as it ran on 2.6.1, at exactly the size and refresh rate of the screen Anvil finds at each launch.",
                "Frame generation was back on for LEGO Star Wars after 0.19.2 set it off. A game on Autopilot now always runs real frames only, whatever its upscaling page says; switching Autopilot off for a game hands the choice back."
            ],
            added: [],
            known: [
                "Engine 2.6.1 starts on a Windows setup that Engine 3.0 updated; Wine brings it back to 2.6.1's own files at the first start, which takes a few extra seconds once.",
                "On 2.6.1 LEGO Star Wars held 80 fps or more 60–81% of the time at Medium graphics. Auto-Tune measures again from the next session and moves to Light graphics if Medium can't hold 80 nearly all the time."
            ]),
        Release(
            version: "0.19.2",
            date: "30 September 2026",
            headline: "LEGO Star Wars on Engine 3.0: Anvil's pacing reaches the game again, the picture fits the screen, and Game Mode is back.",
            fixed: [
                "On Mythic Engine 3.0 (Wine 9) Anvil's frame pacing never reached the game. Two sessions on 1 October logged not a single frame: no Steady 80, no V-Sync hold, nothing for Auto-Tune or the engine trial to measure — which is why the frame rate felt worse. Wine 9 runs the game in a process it starts itself, and there Anvil's library set itself up before Anvil's settings were in the process, so it stayed off. It now sets itself up at the first moment it can — when the library loads, the game's first new thread, or its first frame — whichever comes after the settings are there. Tested by starting a program with the library and no settings, then giving it the settings: it set up at the first thread, put its hooks in, and only once.",
                "The picture didn't fit the screen on Engine 3.0 — its left edge was cut off. The game was set to exclusive fullscreen at 1512×982, which asks for a display-mode change, and Wine 9 handles that differently from 7.7. Before every launch Anvil now sets LEGO Star Wars to a borderless window exactly the size of the screen Anvil finds, at its refresh rate: no mode change on any engine, and right on any Mac or display. Its graphics settings are untouched, and nothing is changed if \"The game's own settings\" is chosen.",
                "Game Mode was off on Engine 3.0: the game came to the front as plain \"wine\". Wine 9 runs games as `wine` itself, not its preloader, and Anvil's Game Mode copy named the preloader as the app. It names the binary the game really runs as now, and the copy is rebuilt once.",
                "LEGO Star Wars' own upscaling had been set by hand to FSR 1 Ultra Performance — a third of the screen's resolution — with generated frames on and the upscaler forced into its folder. With Autopilot on, those go back to automatic once: its own resolution, real frames only. Anything set from now on is kept."
            ],
            added: [],
            known: [
                "Engine 3.0 hasn't been measured yet, because the library never reached it. The next session of three minutes or more is the trial's: kept if it runs as well as Engine 2.6.1 did (81 fps typical, 80+ 60% of the time), back to 2.6.1 by itself if it runs clearly slower.",
                "Switch pads on Engine 3.0 reach the game as Xbox-style pads (Anvil's Pro Controller is built for Wine 7.7's controller driver)."
            ]),
        Release(
            version: "0.19.1",
            date: "30 September 2026",
            headline: "Fixes from 0.19.0's first start on this Mac, and a quicker check before every launch.",
            fixed: [
                "0.19.0's first start made three empty \"Epic Games\" containers, 434 MB each. The startup, the setup and the Epic page each asked for the Epic container within the seconds Wine takes to make one, and each made its own — though Mythic's two games were already in the library and needed none. The container is now made only for a game that needs it, and callers at the same moment share the one being made. The three empty ones go to the Trash at the next start; nothing was in them. Setting up Steam is guarded the same way.",
                "The engine check before every launch took about 0.2 s; it now walks the engine with fts, which hands back each file's details as it goes — about 15 ms for 4,656 files.",
                "A sign-in sealed with a key this Mac can't use right now is kept rather than deleted, in case the key comes back; only one that was changed is discarded.",
                "Rebuilding Anvil while it runs left the app without its interceptor for the 15 seconds that takes to compile, so a game started then ran without Anvil's pacing. The new build is now assembled beside the old one and swapped in at once."
            ],
            added: [],
            known: [
                "From the first start: the Secure Enclave holds the 512-bit key, all three engines are sealed, the Epic sign-in is encrypted, Anvil's own legendary runs (205 games listed), the GPU measured 2.7 TFLOPS, and LEGO Star Wars is on Engine 3.0 on trial. It hasn't been played on it yet."
            ]),
        Release(
            version: "0.19.0",
            date: "30 September 2026",
            headline: "Engines sealed against tampering, the Epic sign-in encrypted, and a 512-bit key that belongs to this Mac.",
            fixed: [],
            added: [
                "A protection key for this Mac: 512 bits, worked out from a private key the Secure Enclave holds and never lets out of the chip — so it is never stored anywhere. Every use gets its own key derived from it with HKDF-SHA-512. (Where the Enclave can't be used, a random 512-bit key is kept in Anvil's Keys folder, readable only by you.)",
                "Every engine is sealed: the SHA-256 of each of its files — 4,656 in Mythic Engine 2.6.1 — recorded when it is installed and signed with HMAC-SHA-512 under that key. Before every launch Anvil checks every file's size and date and hashes again any that differ (about 0.2 s); once a day it hashes every file in full (about 0.3 s for 845 MB). A file changed, added or removed — or a seal that wasn't signed on this Mac — stops games on that engine, with the file named, until Repair on the Engines page puts the changed copy in the Trash and installs a clean one. Game Mode's copies of engines are sealed too, and rebuilt by themselves if changed. Engines already installed are sealed as they are at the first start.",
                "The Epic sign-in is encrypted on disk with AES-256-GCM. legendary keeps it as plain JSON; Anvil now keeps it sealed, decrypts it only while legendary runs, and seals the new token Epic hands back the moment the last run ends. A sealed sign-in that was changed by even one bit is refused and discarded — Epic simply asks to sign in again.",
                "Settings › About shows where the key is held and what is protected."
            ],
            known: [
                "Engines and installed games are sealed, not encrypted: Wine and the games read them as plain files every time they run, so encrypted copies would have to be decrypted to disk at every launch — about a gigabyte per engine — and would sit decrypted all through every game anyway. Save files are neither, as asked.",
                "The Secure Enclave can't be reached from this sandbox, so the tests here ran on the Keys-folder key. Anvil uses the Enclave when it starts on a Mac; Settings › About says which it got.",
                "Nothing local stops someone who already controls your Mac account: they could remove Anvil's seals and keys together, and Anvil would seal what it finds afresh. The seal catches changes made by anything that doesn't target Anvil specifically — another program, a damaged download, a file swapped by hand."
            ]),
        Release(
            version: "0.18.1",
            date: "30 September 2026",
            headline: "An ownership file Anvil checks at every start, and no readable shader source in the public edition.",
            fixed: [
                "The public edition carried its shaders as readable source whenever it was built without Apple's separate Metal toolchain — which is every build since Xcode 27. They are now packed: compressed and scrambled, unpacked by Anvil's own library and compiled at a game's first frame, as the source was. A precompiled library still takes their place whenever the toolchain is installed."
            ],
            added: [
                "An ownership file, Anvil.app › Contents › Resources › Ownership.txt, naming Jay Chirag Patel of Santa Clara as Anvil's maker. Its SHA-256 is compiled into Anvil, and every edition checks it at every start: changed, moved or deleted, Anvil says so and doesn't start. Nothing else is touched — a fresh copy from the .dmg starts normally. In the public edition the signature check covers it too.",
                "The credit is in the app, quietly: \"Made by Jay Chirag Patel · Santa Clara\" at the foot of the sidebar, with the full credit and copyright on hover, and in About, Settings and the setup."
            ],
            known: [
                "As with 0.18.0: not run with Wine or Metal from here. The ownership check was tested on both built editions — edited, a space added, deleted and moved were each refused — and the packed shaders were unpacked from the built public app byte for byte."
            ]),
        Release(
            version: "0.18.0",
            date: "30 September 2026",
            headline: "Steam and Epic built in, a setup that learns the Mac, and an edition to share as a .dmg.",
            fixed: [
                "Steam's window never appeared on 30 September: its web helper ended with \"crash server failed to launch, self-terminating\", over and over. Steam now starts without Chromium's sandbox, which can't work under Wine; and if its web helper crashes anyway, Anvil starts Steam again with its web view drawn without the GPU, by itself, once."
            ],
            added: [
                "Steam, inside Anvil. Set Up Steam downloads Valve's installer from Valve and installs Windows Steam in a container of its own. Games installed in it — in any of its library folders, on any drive — appear in the library at every start, with Steam's own cover art. A Steam game starts from its own program, with Steam running and signed in beside it in the same Windows setup, so its online play, DRM, cloud saves and achievements work as on Windows, while Anvil still paces, measures and tunes it like any other game. After the game, Steam is asked to close properly, finishing its cloud saves, before the Windows setup shuts down.",
                "Epic Games, inside Anvil. The Epic Games page lists every game the account owns, installs any of them through Anvil's own legendary into ~/Games/Anvil with progress, and adds it to the library in an Epic container, signed in at every launch.",
                "Anti-cheat, said up front. A game's folder is checked for Easy Anti-Cheat, BattlEye, Riot Vanguard, EA Javelin, XIGNCODE3, GameGuard, PunkBuster and Anti-Cheat Expert. The game's page and the Steam page say whether its online play can work on a Mac at all: the kernel-level ones need Windows itself; Easy Anti-Cheat and BattlEye only where the game's maker allows Wine. Anvil never tries to get around anti-cheat — that is what gets accounts banned.",
                "A setup at the first start. It measures the Mac — chip, CPU and GPU cores, memory, display, and the GPU's real speed with a one-second test — and says what Anvil will do on it; makes sure an engine is installed, downloading one if not; and offers to set up Steam, sign in to Epic and bring in games from other launchers. A game Anvil hasn't measured yet starts at the graphics level the Mac's class can hold (Light for entry-level graphics or 8 GB, Medium for standard, Full for Pro and above); Auto-Tune and Autopilot take it from there. Settings › Run Setup Again repeats it.",
                "Two editions. The private edition is the one built here, as before. The public edition, built by scripts/build_editions.sh into a .dmg with the licence and a read-me, is optimised and stripped, ships no source code, and checks its own signature at every start: if any file inside Anvil.app was changed, removed or added, it says so and doesn't start. Nothing is ever deleted by that check — a fresh copy from the .dmg starts again. Signed with a Developer ID, the check is pinned to that team.",
                "Made by Jay Chirag Patel, Santa Clara — in the About window, Settings, the sidebar, the setup, the app's copyright and the licence."
            ],
            known: [
                "Not run with Wine from here: this sandbox can start neither Wine nor Metal. Steam's library reading, game import, sign-in check, installer check and web-helper recovery were tested on a made-up Steam setup with two library drives; Epic's list, progress and import on legendary's real formats; the self-check on a signed app with a file edited, added and removed. Valve's installer address was checked (2.4 MB). The GPU test needs Metal, so it measures for the first time on a real start.",
                "Steam under Wine on a Mac is the least dependable part: every Mac launcher has trouble with its window after some Steam updates. If Steam's window stays blank even in the safer mode, games already installed still start from the library.",
                "Without an Apple Developer ID, the public edition is signed ad hoc: Macs it is sent to show \"cannot verify\" the first time (System Settings › Privacy & Security › Open Anyway), and its self-check catches changed files but not a copy someone re-signs. A Developer ID ($99 a year from Apple) fixes both: set ANVIL_SIGN_IDENTITY and ANVIL_NOTARY_PROFILE when building.",
                "The engine isn't inside the .dmg. It's Apple's D3DMetal with Wine, published by Mythic's makers; Anvil downloads it from them in the setup, as it does for updates, rather than redistributing it."
            ]),
        Release(
            version: "0.17.0",
            date: "30 September 2026",
            headline: "Newer engines by themselves, no tearing, steadier frames — and Anvil needs no other launcher.",
            fixed: [
                "Tearing. A game with V-Sync off in its own options presents with a sync interval of 0, and D3DMetal — 2.1 and 3.0 both — turned that into a layer that shows each frame the moment it arrives, mid-refresh: in a fullscreen game drawn straight to the panel, the top of the screen showed one frame and the rest the next. It also took the display's timing out of Anvil's pacing, which every held, grid and as-ready present relies on. While Anvil paces a game the layer now stays synced to the display. It adds no wait: the pacing already decides when each frame goes, and ProMotion follows the game anywhere from 24 to 120 Hz.",
                "Steady still changed its mind 23 times a minute in LEGO Star Wars on 0.16. The GPU check stopped the probes that failed outright; two kinds were left. A probe let the hold go and measured the half second after — while the frames it had kept back went out at once — so it saw 120 where the game could make 107, and fell back a second later. And in heavy stretches the game's frame time sat right at the 80 fps line, so one long frame flipped it between held and below. A probe now lasts a second and is judged after that rush; a fall from 120 within four seconds of reaching it counts as a failed probe and backs off (4, 8, then 16 seconds); a GPU reading that promised room it didn't have no longer skips the back-off; and a game is let go below 80 only after a whole second too slow for it. On the library's own code against a game swinging between 95 and 125 fps: 10 changes in 30 seconds instead of 34, fewer as it goes on; every other scene as before.",
                "LEGO Star Wars ran from Mythic's own engine folder, not Anvil's copy of it. Both have the same name, and Mythic's sorted first — so an update in Mythic would have changed the game underneath Anvil. Anvil's own copy of an engine always wins now, and a container still using another app's engine gets Anvil's own copy of it at the next start (an APFS clone: a second or two, no extra disk).",
                "A look at the menu overwrote a game's Health with \"everything ran as it should\". A session too short to judge now keeps what the last real session found, marked with its date.",
                "Health never reported a failed Epic sign-in: it looked for the wording from before 0.15. It does now, with a Sign In button.",
                "Steam added from a Whisky bottle went into the first container, whose Windows had none of it — its sign-in, its games and its updates are in the bottle it was installed into — and closed after two seconds. A program installed inside another app's Wine setup (a Whisky or CrossOver bottle, a Mythic or Heroic prefix) now gets a container of its own, made from a copy of that setup on the matching engine; the original is left as it is, and a second program from the same bottle joins the same container. One already in the library is moved by Autopilot, or with a button in Health.",
                "Steam closes itself after updating, with code 42, and expects to be started again. Anvil now starts it again, and Health no longer calls it a crash."
            ],
            added: [
                "Autopilot moves a game to a newer engine by itself. For a DirectX 11 or 12 game that doesn't hold 80, it finds the newest D3DMetal — installed, or in Mythic's engine list, downloading it — takes a snapshot of the container, switches, and starts Auto-Tune again on the new engine. After three minutes of play it compares the game with how it ran before: kept when it runs about as well or better, back to the old engine when it runs clearly slower (typical frame rate 8% lower and 10 points less time at 80), and back at once if the game won't start or crashes on it. An engine that went back isn't tried again for that game. For LEGO Star Wars that means Mythic Engine 3.0 with D3DMetal 3.0 on the next start; its numbers before: 81 fps typical, 80 or more 60% of the time.",
                "Anvil's own Epic Games connection. legendary — the open-source Epic client Mythic and Heroic use — is downloaded from the legendary project's own releases and installed only if it matches the SHA-256 GitHub publishes for it; the sign-in and game list come over from Mythic once, so nothing needs signing in again. Mythic can be removed. If Epic's sign-in expires, Sign In to Epic on the game's page does it in Anvil, through Epic's own web page.",
                "Every Mac's display. What counts as smooth follows the screen: 80 on a 120 Hz ProMotion MacBook Pro, 60 on a MacBook Air's 60 Hz display (where 80 can't be shown, and every game read as failing), two thirds of the rate on a faster variable-refresh display. The steady mode's own thresholds follow the display's top rate too — on a 144 Hz display it holds an even 96. Health, Auto-Tune and Autopilot all use it.",
                "The game's own process tells macOS it is latency-critical, so the waits Anvil's pacing makes aren't drifted by timer coalescing, and App Nap leaves it alone."
            ],
            known: [
                "Not run in a game from here: this sandbox can start neither Wine nor Metal. The engine upgrade was run end to end on copies of the library, the Auto-Tune results and both real engines — switched with a snapshot, kept after a faster session, back after a slower one and not tried again. Engine 3.0 was checked for Anvil's needs: its Game Mode copy builds, the real Wine binary is used rather than the bash wrapper, and D3DMetal reads as 3.0.",
                "Engine 3.0 is Mythic's preview and has no published checksum; it installs as any engine without one always has. On it Anvil's Pro Controller for Switch pads isn't available (it is built for Wine 7.7's controller driver); a Switch pad reaches games as an Xbox-style pad. Wine 9 fixes the raw-input bug Anvil patches into 7.7 by itself.",
                "legendary 0.21.1 was downloaded and checked against GitHub's checksum here, and a tampered copy was refused; it couldn't be started in this sandbox, which blocks the semaphores it uses. If it doesn't run on a Mac, Anvil keeps using Mythic's copy with its own sign-in.",
                "Once Anvil signs games in with its own copy of the Epic sign-in, Mythic's copy stops working — Epic replaces the sign-in each time it is used. Mythic asks to sign in again if it is opened."
            ]),
        Release(
            version: "0.16.0",
            date: "30 September 2026",
            headline: "Anvil checks every game after every session, fixes what it safely can, and tunes it by itself. Steadier frame pacing in heavy scenes.",
            fixed: [
                "In heavy scenes Steady switched between an even 80 and 120 every one to two seconds — 24 times a minute in the last LEGO Star Wars session — and each switch was half a second of uneven frames. Held at 80, the game's own work on the CPU read 8.2 ms, fast enough for 120, so Anvil kept trying; but the GPU needed 10.5 ms a frame, so unheld the game made 95 and fell straight back. Anvil now reads the GPU's utilisation twice a second while it holds: at 80 fps and 84% busy the GPU has room for 95, not 120, so it doesn't try. A try that fails anyway waits twice as long before the next, up to 16 seconds, and a scene that becomes much lighter is let back to 120 within a few seconds regardless. Checked on the library's own code against simulated GPU-bound scenes: one try in 30 seconds instead of one every two, an even 80 throughout, and 120 again within 3 seconds of a lighter scene.",
                "An earlier Anvil had injected the whole AMD FidelityFX SDK into LEGO Star Wars' and Cat Quest II's folders — thirteen libraries each — and replaced LEGO's own amd_ags_x64.dll with the SDK's. Nothing used them, and the Remove button would have put the SDK's copies back into Cat Quest II's folder: an injection repeated over an earlier one had backed up the earlier one's files, and the manifest could no longer tell them from the game's. Remove now judges each backup by the file itself — a backup with the injected copy's exact contents and date is the SDK's, not the game's. Autopilot removes unused injections by itself: LEGO gets its own amd_ags_x64.dll back, and Cat Quest II keeps exactly its own three libraries. Checked on copies of both folders.",
                "Every launch set WINE_FULLSCREEN_FSR — in \"ultraperformance\" mode for LEGO — and DXVK_FSR. They are Proton's and a patched DXVK's; no display driver and no DXVK on this Mac reads them (checked in Mythic Engine 2.6.1 and 3.0, Whisky 2.5 and both DXVK builds), so they did nothing but look like a setting. Gone, as is DXVK's memory limit on containers that don't use DXVK.",
                "Switching a container to a newer engine from Best Container took no snapshot, although the dialog said it could be switched back. It now takes one first, and the switch is on trial: if a game exits straight away or crashes on the new engine, the container goes back to the old one by itself and starts the game again there.",
                "When no setup holds 80, Auto-Tune took a lighter look for two points more time at 80 — a difference no one sees, paid for with the game's shadows. A lighter look now has to hold 80 at least eight points longer to win.",
                "A session under a minute was summed up as \"over 0 min\"; it now says how many seconds."
            ],
            added: [
                "Health, at the top of every game's page. When a session ends Anvil reads what it left in the logs and says, in words: whether the game ran smoothly; what held it back when it didn't — the GPU, one of its threads, the two taking turns, or the game's own frame cap; hitches and freezes (a freeze with the game in the background is the game pausing itself, and isn't counted); a crash or a start that failed, with the last error the game printed; Epic sign-in trouble; Low Power Mode, heat, or memory pushed to the SSD by other apps; a Pro Controller that never completed its handshake; and what is working, like the voices folded into stereo. Each thing that can be put right has its button. A short note after each session says what was found, with the way to the details; the first start of 0.16 reads the sessions already played.",
                "Autopilot, on for every game and switched off on the same page. After each session it removes files Anvil left in a game's folder, sets the container settings measured to be better for every game — synchronisation, shader and Rosetta caches, Game Mode, thread priority, no generated frames — and starts Auto-Tune while you play for a game Auto-Tune hasn't measured, counting the session just played as the first measurement when it ran with that setup. It never changes how a game looks by hand-picked settings, its pacing choice or its engine without asking.",
                "A newer D3DMetal is pointed out where it would help: Mythic's Engine 3.0 (a preview release) carries Apple's D3DMetal 3.0 and Wine 9. D3DMetal 3.0 hands each frame's work to the GPU without waiting for it — D3DM_ENABLE_ASYNC_COMMIT, on by default, read out of its binary — which is aimed at exactly what slows LEGO Star Wars below 80 on this Mac: in its heavy scenes neither the GPU (78% busy) nor its busiest thread (51% of a core) is at its limit, because D3DMetal 2.1 makes each wait for the other. Engine 3.0's Wine 9 also fixes the raw-input bug Anvil patches into Wine 7.7 by itself."
            ],
            known: [
                "Not run in a game from here: this sandbox can start neither Wine nor Metal. The checks were run on the real game.log and anvil.log — every session in them, from Cat Quest II's failed starts on 27 September to today's LEGO session — and Autopilot was run end to end on copies of the library, the logs and both games' folders.",
                "Engine 3.0 is Mythic's preview. Its catalogue entry has no checksum and the checksum file beside it answers 403, so it installs without one, as any engine without a published checksum always has; it is installed only when you choose it in Runtimes. On it, Anvil's Pro Controller for Switch pads isn't available (it is built for Wine 7.7's controller driver) and the pad reaches games as an Xbox-style pad — Health says so if it happens.",
                "Autopilot's Auto-Tune changes LEGO Star Wars' graphics level between sessions while it measures (Medium, then Light or Full) — about four minutes of play each — and then keeps one. Choosing a level by hand on the Performance tab stops that."
            ]),
        Release(
            version: "0.15.0",
            date: "29 September 2026",
            headline: "Auto-Tune: Anvil tests a game with different settings and keeps the best. The best container for each game, and everything works offline.",
            fixed: [
                "Starting a game with no connection waited for Epic's sign-in to time out — up to 30 seconds — before starting offline. Anvil now knows the Mac is offline and starts the game in Epic's offline mode at once, with your saves; DLC ownership is checked again once you're online.",
                "Generated frames were still switched on in containers set up before 0.12 — LEGO Star Wars' among them, ANVIL_FRAME_GEN=1 in every launch — although every session with them drew a report of distorted motion. They are off everywhere now; real frames only, as asked. One switch in Upscaling brings them back.",
                "The engine list in Runtimes was empty offline and after every restart until checked again. The last list fetched is kept and shown, with when it was fetched; installing waits for a connection and says so."
            ],
            added: [
                "Auto-Tune, on every game's Performance tab. Choose what best means — Smooth 80+, Highest frame rate, Best graphics or Balanced — and Anvil measures the game with different setups and keeps the one that meets it. Test Now starts the game with each setup in turn: load in and play or stand somewhere busy, and after about ninety seconds of play Anvil closes it and starts the next, then makes the winner the game's settings. Tune While I Play does the same over your normal sessions instead. Only real play is measured — not the menus or the load — from the statistics Anvil already records inside the game: the share of time at 80 or better, what the display showed, what the game could make on its own before any pacing, the 1% low and hitches. Every result is shown, with the reason the winner won.",
                "What Auto-Tune changes: for LEGO Star Wars, the game's own graphics at three levels — Light (the heaviest effects off, shadows low, ambient occlusion and water distortion off), Medium (what 0.14 set) and Full (the game's own) — which can also be picked by hand; for a game that draws at its window's size, like Cat Quest II, full resolution or half and upscaled; for every game, the frame pacing its goal wants. A value you change in a game's own menu is still yours and is never overwritten.",
                "Best Container for This Game, on the Advanced tab: what the game is, read from its own files (its DirectX, engine and whether it is 64-bit), and every container setting that would suit it better for the goal, each with its reason — one click applies them. A newer D3DMetal installed in another engine is offered, never switched to without asking.",
                "Everything works offline. Games, tuning, settings, saves and controllers never needed a connection; the few things that do now wait for one rather than fail: the Epic sign-in starts offline, cover art is fetched when the connection returns, and the engine list shows its kept copy. The sidebar says when the Mac is offline.",
                "Kept on disk and reused: Auto-Tune's results with what they were measured on (they are marked out of date when the game, its engine, macOS or Anvil changes), what each game is (read once per build of the game), and anything fetched from the internet — each with the date it was fetched."
            ],
            known: [
                "Not run in a game from here: this sandbox can start neither Wine nor Metal. Auto-Tune's measuring was checked against the real game.log — it reads the 52-minute LEGO session as 80 or more 81% of the time, the same as the session summary — and a whole tuning run was driven through the real code with simulated sessions, down to the graphics level written into a copy of LEGO's settings file. The game analysis read LEGO's and Cat Quest II's real executables.",
                "Test Now doesn't press anything in the game: each time it starts, load into your game. It closes the game gracefully between setups, and forces it only if it is still open after 20 seconds.",
                "Scenes differ from one session to the next, so setups within 3% of each other count as equally fast, and a result from Tune While I Play is less exact than one from Test Now in the same place each time.",
                "DXVK isn't among the setups: Anvil doesn't install it into containers, which carry D3DMetal's own libraries."
            ]),
        Release(
            version: "0.14.1",
            date: "29 September 2026",
            headline: "Characters' voices in LEGO Star Wars — and the rest of a surround mix — are heard on a stereo Mac.",
            fixed: [
                "LEGO Star Wars played its music and effects but no dialogue. The game reads the output's format and, when it is stereo, mixes in 7.1 anyway — eight channels, `cmp channels, 2 / ja / mov channels, 8` in its audio setup — and leaves the fold-down to Windows, whose audio engine does it. Characters' voices are on the centre channel of that mix. Wine's CoreAudio driver handed all eight channels to the Mac's output with no layout, and CoreAudio played the first two and dropped the rest: measured with CoreAudio's own converter, an 8-to-2 conversion keeps input channels 1 and 2 and returns exact silence for 3 to 8. So every line of dialogue, the rear and side channels and the LFE were silent, while the music, which sits in the front pair, played. Anvil now does what Windows would: when a game's stream is wider than a stereo or mono output, the output is opened at its own width and the game's mix is folded into it — centre and surrounds at −3 dB into both sides, LFE left out, as XAudio2's and Windows' own fold-downs do. It is done where Wine's driver meets CoreAudio, so it holds for any game that mixes in surround, not only LEGO; everything else passes through untouched.",
                "The same applies to a stereo game on a mono output, which played only its left side."
            ],
            added: [
                "game.log says what each game's audio is: its width, the output's, and whether the mix was folded — and, when the stream closes, for how long."
            ],
            known: [
                "Not heard from here: this sandbox has no audio devices. The fold-down was checked against stand-ins for CoreAudio's output unit and for Wine's driver, driven in the order Wine 7.7 drives them — every input channel lands where it should at the right level, long buffers are filled in turns with no frame lost or repeated, integers saturate rather than wrap, nothing is written past a buffer (under AddressSanitizer), and the compiler checks that the audio thread's code neither locks nor allocates. The real library, inserted into a process, steers only calls that come from Wine's driver. The engine's driver matches Wine 7.7's source message for message.",
                "Only stereo and mono outputs get a fold-down. A game mixing 7.1 into a 5.1 output is left to CoreAudio as before."
            ]),
        Release(
            version: "0.14.0",
            date: "29 September 2026",
            headline: "Switch pads become a real Pro Controller to games that support one, a steady 80 or better, and a new library.",
            fixed: [
                "Buttons on a Switch pad did something other than what LEGO Star Wars showed, whichever setting was chosen. The cause was not the mapping. LEGO drives the Switch Pro Controller itself: it opens the device, performs Nintendo's USB handshake and decodes Nintendo's own reports, byte by byte — read out of its SwitchProControllerInputDevicePC. Since 0.12.2 Anvil had only renamed the pad to \"Pro Controller\", and a pad Wine exposes speaks none of that protocol, so LEGO showed Nintendo prompts but never got a single input from its Switch Pro support. Every button it did act on came from a second, Xbox-style copy of the same pad through XInput — treated as an Xbox pad, confirm and cancel included, while the prompts were Nintendo's. No mapping could make the two agree. Now the pad is hidden, and a Pro Controller made by Anvil takes its place: it answers the handshake and every command, and reports the pad in Nintendo's format. LEGO then uses its own Nintendo support, exactly as with a real Pro Controller: A is A, B is B, confirm and cancel as on the Switch, ZL, ZR, −, + and Home included. Checked by running Anvil's reports through a copy of LEGO's own decoder, taken from the game instruction for instruction: every button reaches the game as the button printed on the pad, and the sticks read zero at rest.",
                "In every LEGO session since 0.12.2 one of its threads spent its time opening and closing the renamed pad several times a second — its handshake failing and starting over — each attempt a round of registry reads and device requests through the Wine server. It shows in every stall recording from then on and in none before. It is gone with the Pro Controller, which answers the handshake the first time.",
                "A frame-rate cap below the display's rate (60 or 30) held only while the game ran faster than about 116 fps; below that frames were shown as ready, so a 60 cap let a game at 100 through at 100. It now holds at every rate."
            ],
            added: [
                "Steady frame rate, now the default: 120 while a game can hold it, and an even 80 — every frame 12.5 ms apart — while it can't, instead of a rate that moves with the scene. ProMotion shows frames on a 240 Hz grid, so 80 is the only even rate between 60 and 120. Unlike the lock at 80 that 0.13.1 removed, the hold happens before each frame starts, so nothing queues — in a model of the panel it adds about 2 ms of delay where a hold at the display added 11 — and the moment a frame takes less than 120 needs, the game is let go to 120 again. Below 77 fps nothing is held. Up to 120 (every frame as soon as it's ready) is one choice away under Performance.",
                "LEGO Star Wars' heavy effects tuned for this Mac, once, before the next launch: reflections, soft shadows, depth of field, motion blur and speed blur off, shadows at medium. A sample of a slow scene had the game's render thread waiting on the GPU for 42% of the time; these effects are where that time goes at this size. The game's own values are kept and come back with one choice under Performance, and anything changed afterwards in the game's own menu is left as it is.",
                "How the last session ran, on the game's page and in the library: the average frame rate, how much of the time it was at 80 or more and at 120, and the lowest 1% low — read from the frame statistics Anvil already records. LEGO's session of 29 September, for comparison: 89 fps on average, 80 or more 81% of the time, 120 for 26%.",
                "The frame statistics in game.log now say how busy the GPU was and the two busiest threads, so a slow stretch shows whether the graphics or one thread of the game held it back.",
                "A new library: the game you played last in a large banner with Play one click away and how it ran last time, larger artwork tiles that lift under the pointer with Play on them, games without artwork in a colour and initials of their own instead of identical icons, and an Add tile with its choices in a popover.",
                "A new game page: the game's artwork across the top with Play, how the last session ran, and settings in four tabs — Overview, Performance, Controller and Advanced — instead of one long list."
            ],
            known: [
                "Not tried in a game from here: this sandbox can start neither Wine nor Metal presentation. The Pro Controller was checked against LEGO's decoder and a full driver's setup sequence, and inside a stand-in for winebus built from the real one's layout — including that every reference is released when the pad is unplugged; it only switches on in an engine whose winebus matches, byte for byte, the build it was read from (Mythic Engine 2.6.1 and Whisky 2.5 both do). game.log says whether the game opened it and completed the handshake.",
                "The Pro Controller is only for games that drive one themselves — LEGO Star Wars and other TT Games titles. Other games read pads as Xbox pads, as before.",
                "Steady shows 80 in a scene where the game could manage 90 to 107: evenness in exchange for that difference. LEGO still drops below 80 in its heaviest scenes; the tuned graphics are meant to make that rarer, not impossible.",
                "The graphics are tuned only once LEGO has written its settings file, so a fresh install is tuned from its second launch."
            ]),
        Release(
            version: "0.13.1",
            date: "28 September 2026",
            headline: "Heavy scenes are no longer held at 80 fps, and every button on a Switch pad matches LEGO Star Wars' prompts.",
            fixed: [
                "Games that could run at 85 to 110 fps were shown at exactly 80. Below 120, Anvil held each frame back to 92% of the game's average frame time, to even out frames that finished early — assuming the display can show a frame at any moment. This MacBook's ProMotion panel shows frames only on a 240 Hz grid: every gap between frames in the logs is a multiple of 4.17 ms. Any hold longer than 8.3 ms became a wait for the 12.5 ms step, which is 80 fps, and the frames queued behind it made the game measure 80 itself, so it never climbed back. In LEGO Star Wars on 29 September, 94 of 258 five-second stretches sat at 80.0 fps, 30 of them with the game able to do 85 to 110; a game near 67 was held at 60 the same way. Frames below 120 are now shown the moment they are ready, never faster than 120 Hz. A model of the panel reproduces the old behaviour exactly — 80.0 fps for any game between 85 and 105 — and with the change shows each game's own rate. Latency drops with it: frames no longer wait in a queue behind the hold (37 ms at the held 80, against 25 ms at 120 in the same session).",
                "The buttons on the PowerA Switch pad were still wrong in LEGO Star Wars, whichever face-button setting was chosen. LEGO had been set to “Match the letters on the pad” and also given a controller profile with “Swap confirm and cancel”. Each swaps A and B, so together they cancelled: A and B stayed put and only X and Y moved, which is wrong under either layout. The launch log shows it — the “letters” sessions sent a:b1,b:b2 exactly as the “positions” one did. The profile switch no longer applies to Switch pads, where the face-button setting alone decides A and B, and LEGO's two settings are set back to Automatic, once.",
                "Automatic is back to matching by position in games that show Nintendo prompts. LEGO Star Wars' own prompt code settles it: its buttons are NORTH, EAST, SOUTH and WEST, drawn with each platform's letter for that place, so its Switch Pro prompt for the bottom button is B. The bottom button therefore has to reach the game as its A — and then B on screen is B on your pad, A is A, Y is Y, X is X. 0.13.0 had switched this to letters, reading the hand-set “letters” as proof; that setting had never taken effect.",
                "Anvil no longer records every thread's stack when a game slows down or freezes. It ran Apple's sample tool on the game, the Wine server and the controller host for three seconds — stopping each thread every 2 ms to read it — and mapped the game's memory after a freeze, in every session: a burst of hitches at exactly the moment a game was already struggling. It was for chasing one bug, and it is now off unless ANVIL_CAPTURE_STALLS=1 is set."
            ],
            added: [
                "Clearer face-button choices: “Automatic — match this game's prompts”, “The pad's A is the game's A” and “The bottom button is the game's A”, each explained for the game's own prompts, including when a choice will not match them.",
                "“Swap confirm and cancel” in a controller profile says it applies to Xbox and PlayStation pads."
            ],
            known: [
                "Not tried in a game from here: the pacing change is checked against a model of the panel built from the logged frame gaps, and the button fix against LEGO's own prompt code and the mappings in the launch log. The next session's game.log should show the displayed rate following the game's own instead of sitting at 80.0.",
                "Below 120 fps the gaps between frames are a mix of 8.3 and 12.5 ms, because the panel cannot show a frame in between. That is the game's full rate, but not perfectly even; a perfectly even rate below 120 exists only at 80 or 60.",
                "LEGO Star Wars cannot render 120 fps in its heaviest scenes at this resolution — the game itself manages 60 to 100 in some fights — so those scenes still show below 120. Only a lower resolution or generated frames change that, and generated frames are not used on this display."
            ]),
        Release(
            version: "0.13.0",
            date: "28 September 2026",
            headline: "Close a game from Anvil, start any game in one click from anywhere, and play time that is actually kept.",
            fixed: [
                "Force Quit on the Activity screen sent the game's process SIGTERM, which Wine turns into ending the one thread that receives it — so it often closed nothing. Quit now asks the game to close the way its own close box does (WM_CLOSE to its windows through Wine's taskkill, checked in Wine 7.7's source), so it can save; a game still open after 8 seconds is force-quit. Force Quit ends everything in the game's container with wineserver -k, which Wine follows by saving the registry before it exits.",
                "Play time was never recorded: every game read \"0 min\" however long it had been played. It is kept now, counting only time the Mac is awake — 22 of the 52 minutes of LEGO Star Wars on 29 September were the Mac asleep with the game open. Earlier sessions are recovered from the launch log, once.",
                "Automatic face buttons on Switch pads went by letter in games that show Nintendo prompts too. (Wrong, and reverted in 0.13.1: the hand-set “letters” this was based on had never taken effect.)",
                "Delete Container erased the container outright on one click, with every save its games keep inside it. It now asks, says what goes, and moves the container to the Trash.",
                "A game closed from Anvil within 25 seconds of starting would have been taken for a failed start and relaunched without Anvil's enhancements. A game you close is never retried.",
                "Every line a running game printed redrew the whole library grid behind it. The game output now has its own object, and only the Activity screen redraws for it.",
                "The launch log was never trimmed. It is moved aside past 8 MB, so there are two files at most.",
                "The app no longer builds a stray second copy of the shaders. Xcode 27's Swift build system compiles any .metal file inside the app's sources, and there is no Metal compiler on this Mac, so the build stopped there. The shaders Anvil ships are the ones in Native/AnvilMetal, compiled at game start as before."
            ],
            added: [
                "Quit Game and Force Quit everywhere a game can be seen: on the tile when the pointer is over it, in its right-click menu, on its settings page, in a bar along the bottom of the window while it runs, in the menu bar, in the Dock icon's menu, and in the Game menu (⌘. and ⌥⌘.).",
                "Anvil in the menu bar: the running game with Show, Quit and Force Quit — reachable while the game has the screen and Anvil is hidden behind it — and every game one click away, most recently played first. It can be switched off in Settings.",
                "Game shortcuts. “Add Shortcut to Applications” makes a small app for a game in Applications › Anvil Games, with the game's artwork as its icon. It starts the game from Spotlight, Launchpad or the Dock through Anvil, with every setting, exactly as Play does, and is renamed and redrawn when the game is.",
                "Play on the tile: move the pointer over a game and press Play. The library sorts by Recently Played by default, or by Title or Most Played, and each tile says how long a game has been played and when.",
                "Play Last Game (⌘Return) in the Game menu, and the Dock icon's menu lists games to start.",
                "Faster start: the Epic sign-in and the Game Mode check now run alongside preparing the container instead of after it. That is up to two seconds on a LEGO Star Wars launch when Epic is slow to answer (28 September), and little when it answers at once (29 September). The launch log now gives each step's time in milliseconds, so a slow start says where the time went.",
                "The Mac stays awake while a game runs. A controller is not activity as far as macOS's idle timer goes, so a game played only on a pad could have the display sleep under it. Switchable in Settings.",
                "The launch log records whether Low Power Mode is on and how hot the Mac is, since either holds a game back; Settings says so when Low Power Mode is on.",
                "Quitting Anvil with a game running asks first, then closes the game properly instead of leaving it running with nothing tracking it.",
                "Containers on disk that no container in the library uses are listed in Runtimes, with their size and whether they may hold saves, and can be moved to the Trash. Four are on this Mac, about 1.7 GB, left by containers from early September.",
                "A Settings window (⌘,)."
            ],
            known: [
                "Quit, Force Quit and the shortcut apps have not been run against a real game from here: the sandbox this build was made in cannot start Wine or reach Launch Services. What was checked: taskkill's and wineserver's behaviour in Wine 7.7's own source, and a shortcut app built by this code — its Info.plist passes plutil, its icon reads back through Apple's iconutil at every size, and it is renamed and removed with its game.",
                "A game that answers its close box with an “are you sure?” dialog is force-quit after 8 seconds, and loses anything unsaved.",
                "Anvil still does not start Wine before Play is pressed. The controller mappings and face-button layout are set per game by the first program started in a container, so a container warmed up in advance would hand one game another's controls."
            ]),
        Release(
            version: "0.12.4",
            date: "28 September 2026",
            headline: "Anvil no longer switches off D3DMetal's safety checks, and leaves the game's picture exactly as the game drew it.",
            fixed: [
                "Anvil set D3DM_BOUNDS_CHECK=0 on every launch, calling it a debug aid. It is the bounds checking in D3DMetal's shader converter, and D3DMetal turns it on by default for every game — read out of both engines' D3DMetal, where it is the first compatibility flag handed to the converter. It is what makes a translated shader behave as DirectX promises: a read past the end of a buffer returns zero, and a write past it is dropped. With it off, such a read returned whatever memory came next and such a write could land in another resource — corruption that comes and goes with how full the game's buffers are, which is heaviest in fights, explosions and cutscenes. It is now left at D3DMetal's default in every game.",
                "Every frame was copied out and written back sharpened — at 80% in LEGO Star Wars — on top of the game's own anti-aliasing and sharpening. Sharpening is there to offset the stretch when a game renders below native, so that is now the only time it runs. At native, the game's image is left exactly as it drew it.",
                "The sharpening maths divided by zero wherever all four neighbours of a pixel were at full intensity in a colour channel — a lightsaber core, an explosion, blown-out bloom. The shaders are built with fast maths, which does not guarantee that the resulting NaN is discarded, so such a pixel could come out black or garbage. The divisor is now kept just below zero, and those pixels are left as they are.",
                "The frame counter used to cost a copy and a rewrite of the whole frame, every frame: 1.3 ms at 3024×1964. It now reads and writes only its own small box, and no other pixel of the game's frame passes through Anvil.",
                "Pacing, variable refresh and the frame statistics were only switched on if Anvil's shaders loaded, so a shader problem would silently have taken pacing away too. They now depend only on Metal itself.",
                "The Texture sharpness slider wrote its value into D3DM_LOD_BIAS, which is not a bias but a switch for the game's own LOD bias: \"-0.50\" parsed as 0 and turned the game's bias off. D3DMetal has no bias value to set, so the slider is gone.",
                "Force injection copied every DLL in the FidelityFX SDK folder into the game — AMD's GPU services, the D3D12 runtime, the shader compiler, PIX and RenderDoc among them — and in LEGO Star Wars that replaced the game's own amd_ags_x64.dll, which it links against. Injection now copies only the upscaler's own libraries, each once.",
                "Removing an injection could put SDK files back into the game's folder. A name listed twice was backed up from Anvil's own first copy, and Remove restored that as if it were the game's. Remove now restores only what was really the game's; checked against LEGO Star Wars' own injection record, every SDK file goes and the game's amd_ags_x64.dll comes back."
            ],
            added: [
                "The game's layer is marked opaque when it was not. A Windows swapchain ignores alpha; a layer that is not opaque would blend by whatever the game left in the alpha channel. Anvil's old full-frame pass hid that by writing alpha 1 over every pixel.",
                "The launch log says when a precompiled shader library is older than the shaders it ships with, and compiles the source instead."
            ],
            known: [
                "The Metal compiler is not installed on this Mac (Xcode 27 made it a separate download), so the shaders are compiled when the game starts. That takes a fraction of a second, once, before the first frame. The shader source was type-checked here against a Metal stub, and the previous source, which real Metal compiles, passes the same check.",
                "Not tried in a game from here. The bounds-check cause was found in the code, not in a capture of the distortion. If distortion still appears with this build, it comes from the game or from D3DMetal itself; a screenshot of it would show which.",
                "Bounds checking costs some GPU time. It is what D3DMetal runs by default, and a correct picture comes first.",
                "LEGO Star Wars' folder still holds the earlier FidelityFX injection until Remove is pressed in its Upscaling settings. It cannot help that game — it has no FSR, and the payload had no proxy to load it — and its only effect was the replaced amd_ags_x64.dll."
            ]),
        Release(
            version: "0.12.3",
            date: "28 September 2026",
            headline: "Every button on a Switch pad is the one printed on it, and the right stick's up and down work.",
            fixed: [
                "Three of four face buttons were one place round on Switch pads from other makers. With no entry for the PowerA pad in the engine's SDL, Anvil built its mapping from the pad's descriptor, which says how many buttons there are but not which is which, and assumed the bottom button comes first. Switch pads from other makers put Y first — Y, B, A, X — as SDL's own database and the community one record for every PowerA and Hori Switch pad, and as the community one records for this exact pad. So the pad's Y was the game's A and its A was the game's X. Under Xbox prompts that passed unnoticed; under LEGO Star Wars' Nintendo prompts the letter on screen was the wrong button.",
                "The right stick's up and down never reached a game. SDL stores a mapping with its own \"crc:\" field appended directly after the last character, and Anvil's mappings did not end in a comma, so the field fused with the last element — \"righty:a3crc:578a\" — and SDL threw the element away. The last element was the right stick's vertical axis. Every mapping now ends in a comma, as SDL's own do.",
                "Both checked by feeding a virtual copy of the pad — 17 buttons, four axes, one hat, 20d6:a720 — through each engine's own SDL (2.32.8 in Mythic Engine, 2.30.11 in Whisky) with the mapping a launch sends. Before: Y gave A, A gave X, and the right stick's vertical axis gave nothing. After: every button, trigger, d-pad direction and stick axis lands where it should, and Capture reaches the game as well."
            ],
            added: [
                "Face buttons follow the game. Nintendo prints A and B the other way round from Xbox, so a Switch pad can match a game's prompts by position or by letter, and both only when the game shows Nintendo's own prompts. Automatic, per launch: a game that shows Nintendo prompts for the pad (LEGO Star Wars) goes by position, so B at the bottom is B on screen and on the pad; a game that shows Xbox prompts (Cat Quest II) goes by letter, so the A on screen is the A on the pad. Nintendo's own pads get the same choice, through SDL's Switch driver.",
                "Face buttons on Switch pads, in each game's controller settings: Automatic, Match the letters on the pad, or Match the positions (Xbox layout).",
                "The community controller database, SDL_GameControllerDB, is bundled (its 1,185 macOS and Windows entries; zlib licence alongside). A pad the engine's SDL does not know gets its listed mapping instead of a guess from its descriptor, and an entry naming a button or axis the pad lacks is refused.",
                "The launch log says which face-button layout each launch used and why."
            ],
            known: [
                "Checked through the engines' SDL with a virtual copy of the pad, not with the real pad in a game from here. The real pad's button order is taken from SDL's database and the community one, which agree.",
                "In games with Xbox prompts the face buttons change: the pad's A is now the game's A, where it used to be the game's X.",
                "The Switch 2 pad's C button has no counterpart in SDL 2 or XInput, so it still does nothing."
            ]),
        Release(
            version: "0.12.2",
            date: "28 September 2026",
            headline: "Games with built-in Switch Pro support see a Switch pad as one, and show Nintendo prompts.",
            fixed: [
                "LEGO Star Wars: The Skywalker Saga has a Switch Pro Controller input device and Nintendo button prompts built in (SwitchProControllerInputDevicePC and the NNXPRO prompt set, beside its PlayStation and Xbox ones), and picks them by the pad's USB id and name. A Switch pad from another maker reports its maker's id — PowerA's is 20d6 — so the game treated it as an unknown gamepad and showed Xbox prompts.",
                "Wine gives Windows the id and name SDL reports, through three calls. Anvil already sits between Wine and SDL, and now answers those three for a Nintendo-style third-party pad as a Switch Pro Controller: 057e:2009, \"Pro Controller\". Nothing else about the pad changes — to XInput it is the same Xbox-layout gamepad. Tested against a stand-in SDL: the PowerA reads as 057e:2009 \"Pro Controller\", an Xbox pad beside it is untouched, and without a rule nothing changes."
            ],
            added: [
                "Show Nintendo-style pads as, in each game's controller settings: Automatic, Nintendo Switch Pro Controller, or As connected. Automatic presents a Switch Pro when the game's own executable says it supports one — found in LEGO Star Wars, not in Cat Quest II — and a Nintendo-style pad from another maker is connected.",
                "The launch log says which identity each launch used and why."
            ],
            known: [
                "Not tried in a game from here. If a game with built-in support drives the Switch Pro with its own protocol rather than reading it as a gamepad, buttons may act up; As connected puts the pad back as it was.",
                "Only the executable is checked for support, not the libraries beside it, because an input library that speaks the Switch Pro's own protocol would be handed a pad that only looks like one."
            ]),
        Release(
            version: "0.12.1",
            date: "28 September 2026",
            headline: "ProMotion stays on in exclusive-fullscreen games, and Game Mode gets a real app bundle.",
            fixed: [
                "LEGO Star Wars still stuttered in heavy scenes because Anvil read the display as fixed-refresh — and in that game it was. It runs in exclusive full screen, and Wine's Mac driver answers a fullscreen request by capturing the displays and switching to the matching macOS mode; every macOS mode with a stated rate is a fixed one, so the switch took the panel out of ProMotion for as long as the game ran. Below 120, frames were then rounded to 8.3 or 16.7 ms. Cat Quest II, which never switches, showed the panel following it at 80 Hz.",
                "When a game asks for the size the display already shows — only the rate differs — Anvil now skips the switch and reports it done, so the panel stays in ProMotion and follows the game. The capture Wine takes first is held back until a switch that really changes the resolution needs it, so a real change still gets macOS's automatic restore if the game dies.",
                "Game Mode did not turn on with only the Wine launcher's embedded Info.plist rewritten: the launcher ran from a plain bin/ folder, which macOS does not treat as an app. Anvil's copy of the engine is now an app bundle — Anvil Game.app, with Wine's programs in Contents/MacOS, its libraries beside them where Wine looks, an Info.plist that says it is a game under an identifier of its own, and registered with Launch Services. Tested: built in 0.8 s, and Wine runs from inside it."
            ],
            added: [
                "The launch log records which app identity macOS gives the game while it is in front, so if Game Mode still does not appear, the reason can be read."
            ],
            known: [
                "Game Mode can still only be confirmed in play, by the controller icon in the menu bar.",
                "Not measured in a game from here."
            ]),
        Release(
            version: "0.12.0",
            date: "28 September 2026",
            headline: "Game Mode for every game, and a game that fails with Anvil's enhancements gets a second try without.",
            fixed: [
                "No game run through Whisky's or Mythic's engine has ever had macOS Game Mode. Game Mode — first call on the CPU and GPU, background work held back, Bluetooth controllers polled twice as often — turns on only for an app whose Info.plist says it is a game, and Wine's launcher in both engines carries an Info.plist inherited from CrossOver with no category at all. Anvil now runs games through its own copy of the engine whose launcher says it is one.",
                "The copy is an APFS clone, so it costs no disk beyond the one file that changes, and neither engine is touched. The launcher's embedded Info.plist sits in a fixed 1,072-byte section; the rewrite adds the category, is compacted and padded to exactly that size, and is parsed back before use. Tested on both engines' launchers: only bytes inside that section change, all twelve existing entries are kept, and Wine runs from the copy. Made in half a second on first use, instant after, remade if the engine changes; anything short of that and the engine is used as it is.",
                "A game that closes within 25 seconds with an error while Anvil's library is loaded is started once more without it. If that run lasts, the enhancements are switched off for that game and you are told; if it fails too, the library was not the cause and nothing changes."
            ],
            added: [
                "A Game Mode switch in each container, on by default.",
                "An Anvil enhancements switch in each game's settings — frame pacing, overlay and controller fixes — showing when Anvil has turned it off by itself."
            ],
            known: [
                "Whether macOS actually turns Game Mode on can only be seen in play: a game controller icon appears in the menu bar. It also requires the game to be full screen.",
                "D3DMetal 2.1, the newest on this Mac, has no MetalFX or DLSS support in it — the binary contains neither — so DLSS cannot be routed to MetalFX with these engines.",
                "Not measured in a game from here."
            ]),
        Release(
            version: "0.11.2",
            date: "28 September 2026",
            headline: "No more guessed frames in LEGO Star Wars' heavy scenes.",
            fixed: [
                "The sign-in worked — the launch log shows LEGO Star Wars signed in with Classic Obi-Wan installed — and the loop was gone, but heavy cutscenes and fights distorted. That was generated frames, switched on by a mistake of Anvil's.",
                "The check for whether the display follows the game looked at how long the game worked on a frame. LEGO Star Wars locks itself to 60: it works for about 18 ms and hands a frame over every 16.7, so its frames sat exactly on the refresh grid because it put them there. Anvil read that as a fixed-refresh display, switched variable refresh off, and — no longer counting on it — started generating frames when the game dipped to 54. The check now looks at when the game hands frames over, and Anvil also asks macOS about the display once the game's window exists.",
                "The generating pattern that followed held real frames to every second refresh. A game at 48–54 fps cannot make a 16.7 ms slot, so it missed every other one and fell to 30 real frames, each paired with a guess stretched over twice the motion. That pattern now needs a game that can do 66 fps or more.",
                "On a variable-refresh display generated frames are now considered only below 24 fps, where ProMotion stops following; above that every frame shown is the game's own. The Smoothest and Lowest Latency profiles no longer switch frame generation on."
            ],
            added: [
                "The launch log confirms memory: in that LEGO Star Wars session the game used about 4 GB and swap stayed at 329 MB from start to finish — the game is not what sends this Mac to swap."
            ],
            known: [
                "LEGO Star Wars' own settings ask for 60 Hz with its vsync on, so where it cannot hold 60 it drops straight to 30. Setting its refresh rate to 120 and its vsync off in the game's graphics options lets it run at whatever it manages, and Anvil and the display keep that even.",
                "Both games still have Frame generation switched on in their own settings; it no longer runs on this display, and can be switched off there to be certain."
            ]),
        Release(
            version: "0.11.1",
            date: "28 September 2026",
            headline: "LEGO Star Wars no longer sits at the sign-in step.",
            fixed: [
                "The Epic sign-in crashed inside legendary on its first real use: on macOS it builds the Wine command line before it answers, and with no Wine configured for a game it indexes an empty list — IndexError in get_app_launch_command, reproduced against a copy of Mythic's install records. Anvil now gives it the game's Wine, and it answers with the arguments Epic's launcher would pass.",
                "That crash is why LEGO Star Wars looped. The game keeps saves per Epic account, in SAVEDGAMES/EPIC/<account id>; started without one it had no profile to open and never got past signing in. In Mythic that folder holds your progress; in the new Anvil container it was empty.",
                "If Epic cannot be reached, the game now starts offline as the signed-in account — no exchange code, but the account's name and id — so a game that can run offline finds its profile and saves. The launch log says which happened.",
                "legendary's failure reason is now the exception line, not the PyInstaller line after it that says only that the script failed."
            ],
            added: [],
            known: [
                "Your LEGO Star Wars progress is in Mythic's container. Import Saves & Game Data on the game brings it across; it lands under the same account folder, so the signed-in game finds it.",
                "The game's own settings file asks for 60 Hz, which is why it ran at 60 fps; it can be raised in its graphics options."
            ]),
        Release(
            version: "0.11.0",
            date: "28 September 2026",
            headline: "Import saves for any game, and Epic DLC that unlocks the way it does in Mythic.",
            fixed: [
                "Importing saves was only in a container's settings, and adding or importing games only in the toolbar or on an empty library. The last tile in the library is now a menu — add a game, import installed games, import saves — and every game has Import Saves & Game Data in its right-click menu and its settings.",
                "Opened from a game, the import looks through Mythic, Heroic, Whisky and CrossOver for that game's saves, opens the one that has them and ticks them. As before, nothing is removed from the other launcher and anything already in Anvil is moved aside, not overwritten; registry-held settings come too.",
                "Epic games started from their .exe were never signed in — every Cat Quest II launch logged EOS rejecting an empty sign-in token — so they could not see DLC their owner has, nor use cloud saves or achievements. For a game installed through Mythic or Heroic, Anvil now asks that launcher's own legendary for the arguments Epic's launcher would pass, the same call Mythic makes on Play, and hands them to the game. If that fails the game starts as before and the launch log says why."
            ],
            added: [
                "An Epic Games section for games installed through Mythic or Heroic: the sign-in switch, and every DLC the store lists with which are installed — read from the launcher's own records each time, so DLC installed there shows up here with nothing to do. Checked against this Mac: LEGO Star Wars: The Skywalker Saga lists 14, with Classic Obi-Wan installed.",
                "The launch log records free memory and swap in use when a game starts and when it ends, and game.log records the game's own memory every five seconds — so whether a game is what sends the Mac to swap can be read rather than guessed."
            ],
            known: [
                "The sign-in's one-time code, account name and account id are passed to the game and written nowhere: the launch log shows them as <hidden>, including if a game prints its own command line.",
                "DLC that is not installed has to be downloaded by the launcher that owns it; Anvil lists it but does not download.",
                "Not tested with a real Epic sign-in from here: this sandbox cannot reach Epic, and using your session is not something to do in a test. The first launch's log line will show it."
            ]),
        Release(
            version: "0.10.9",
            date: "28 September 2026",
            headline: "Below 120, frames are shown as they are ready and the ProMotion display follows the game.",
            fixed: [
                "The first recorded slow stretch answered what limits fights: the game's busiest thread was running a third of the time and waiting the rest, and the thread handing frames to the display spent 90% of its time waiting on the GPU. Even with Anvil's own holding taken out, the game could manage 77 fps. It is limited by the GPU, not the CPU.",
                "The same session showed the display is variable-refresh. In the menu, which caps itself at 80, every displayed gap was exactly 12.5 ms — a fixed 120 Hz panel can only show multiples of 8.33 ms. ProMotion refreshes when a frame arrives, as G-Sync and FreeSync do.",
                "Anvil's grid fought that. Below 120 it rounded every frame up to the next 8.33 ms step from the last, so a 13 ms frame waited for 16.7: frames 8.3 and 16.7 ms apart in no pattern, the stutter in fights. Frame generation was then asked to cover it, and guessed frames of a menu are the glitches — generation switched on in that 80 fps menu, since it was below 102.",
                "Below about 104 fps the game's frames are now shown as soon as they are ready, never sooner than just under its own average frame time after the last, and the panel follows: real frames, evenly spaced, no added wait. The grid returns above about 113. Anvil checks the display really follows before relying on it, and goes back to the grid if it does not.",
                "Generated frames are only used below 48 fps on such a display, where following the game stops being smooth. Cat Quest II never goes that low, so it gets no guessed frames at all.",
                "Anvil's own generated frames could be counted and paced as the game's own when pacing was off. They are now passed straight through."
            ],
            added: [
                "game.log reports STEADY — the share of frames close to the running average gap, which is what smooth means at any frame rate — beside EVENNESS, and the share of frames shown as ready.",
                "Every line Anvil writes to game.log is checked by the compiler against its format."
            ],
            known: [
                "The game still renders about 77 fps in heavy fights; they will look smooth rather than read 120. The real lever is the GPU: Mythic Engine 2.6.1 is installed with D3DMetal 2.1, newer than the 2.0 this container runs — the container's Runtime setting offers the switch, with a snapshot first.",
                "Not measured in a game from here."
            ]),
        Release(
            version: "0.10.8",
            date: "28 September 2026",
            headline: "Generation never pauses to re-check the game.",
            fixed: [
                "Generation used to stop for a few seconds every minute to measure the game's own rate, because a game held to the display's grid, or to every second refresh, presents at the rate it is held to rather than the rate it could manage. That showed as a few seconds of the game's own uneven frames in the middle of a fight.",
                "All of that holding happens inside one call — the game asking for somewhere to draw — so Anvil now times how long the game waits there and takes it off each frame. What remains is the game's own work per frame, measured continuously while generation runs. Generation switches between its two patterns, and off again when the fight is over, from that reading alone, after ten seconds of it being clear."
            ],
            added: [
                "Each statistics line in game.log gives what the game could manage on its own beside what it rendered."
            ],
            known: [
                "FSR 3 frame generation cannot be used with Cat Quest II: it has to be built into a game, which supplies it motion vectors, and this Direct3D 11 game has no FSR or DLSS support to hand them over. The same is true of DLSS-style frame generation.",
                "Generators that interpolate — FSR 3, DLSS, Apple's MetalFX — wait for the next real frame before showing the one between, which adds delay. Anvil predicts forward from the frames it has, which adds no wait, and is kept for that reason.",
                "Not measured in a game from here; the next session's game.log will show the readings and every switch."
            ]),
        Release(
            version: "0.10.7",
            date: "28 September 2026",
            headline: "Fights get a steady 120: the game on every second refresh, a generated frame between.",
            fixed: [
                "Measured in the last session: outside fights the game held 120 with a 1% low of 117.6. In fights it fell to 72–83 fps on its own for 40 seconds and more, with only 10–15% of frames landing on the display's beat — the stutter. This Mac is an M4 with four performance cores, and a Unity game through Rosetta and Wine runs out of CPU there.",
                "Generation now starts after 20 seconds below 102 fps, not six measurement windows: a window is 600 frames, so at 75 fps six of them took 48 seconds, most of a fight.",
                "When it did start, generated frames went only into slots the game left empty. That works at about 90 fps — three real frames and one generated, 120 shown, every gap on the beat — and failed at 70: real frames landed one, two or three refreshes apart, the three-drawable pool was often full when the generator asked, and the display got 105 frames a second with a third of gaps two refreshes long.",
                "Below 90 the game is now held to every second refresh, which it sustains with room to spare, and exactly one frame is generated between each pair: 60 + 60, the same pattern every time. The game waits for its slot before it is handed a drawable, so it never queues a frame ahead and the generator always has one. Above 90 the old gap-filling stays, since it already produced an even 120 there with fewer generated frames."
            ],
            added: [
                "The first slow stretch of each session is profiled while it happens: three seconds of every thread's stack in the game, wineserver and the device host, saved to Stalls/. The next optimisation will come from what that shows limits the game in a fight."
            ],
            known: [
                "Not measured in a game from here: macOS does not let this sandbox open a window, so the new cadence could only be reviewed, not watched. The next session's game.log will show it.",
                "Generated frames are predicted from motion Anvil measures between frames; they are not an AI model. In the half-rate cadence half of what is shown is generated, so fast motion in fights can look softer than real frames. Latency in that cadence is about 33 ms, against 27 ms for the game's own 75 fps.",
                "Every 60 seconds generation pauses for one window to re-measure the game, which shows as a few seconds of the game's own frames."
            ]),
        Release(
            version: "0.10.6",
            date: "27 September 2026",
            headline: "Generated frames no longer switch on for a short dip — they were what distorted the picture.",
            fixed: [
                "0.10.5's first session confirmed the controller fix: 16,384 queued controller reports reached the game intact, and the game never froze. But with real play came a new problem: the picture warped whenever anything moved.",
                "That was frame generation. Cat Quest II has it switched on in its own settings, and Anvil turned it on after two five-second windows below 102 fps. Heavy scenes — the first was the Wolfen boss area — dip for about ten seconds, and that switched it on four times in one session for 60–90 seconds each. A generated frame is predicted from motion, so moving things warp in it; latency also went from 16.3 to 24.7 ms while it ran.",
                "Generation now needs six windows in a row (about 30 seconds) below the threshold. Across every session recorded so far, no dip lasted longer than two windows, so none of them would have switched it on. A game that genuinely cannot reach the display's rate still gets generated frames, and after each scheduled re-check it resumes at once if it is still needed."
            ],
            added: [
                "game.log notes each dip that was ridden out without generated frames."
            ],
            known: [
                "The dips themselves remain: about ten seconds at 72–97 fps in heavy scenes. They are the game's own frames, shown as they are.",
                "To never use generated frames in Cat Quest II, switch off Frame generation in its settings."
            ]),
        Release(
            version: "0.10.5",
            date: "27 September 2026",
            headline: "Wine 7.7 was handing the game controller reports with their data missing.",
            fixed: [
                "0.10.4 was aimed at the wrong cause. The last session measured about 70 controller events a second — no flood — and merging stick updates changed almost nothing (2 of 2,000). The game still stopped drawing for 5.1, 8.6 and 3.3 seconds, only while the controller was in use.",
                "The cause is in Wine 7.7's server, the version both installed engines (Whisky 2.5 and Mythic 2.6) run. Rewired, the input library in Cat Quest II and many Unity games, reads the controller report it was handed and then every report queued behind it in one batch. Wine 7.7 answers that batch by copying each report and moving on by the size of its header alone, so each one is overwritten by the next and the report bytes never reach the game. The game reads stale memory and garbage as buttons and sticks: the inputs nobody made. It only happens when reports queue up — when the game is momentarily behind — which is why it arrived with lag and why keyboard and mouse, whose messages carry no extra data, were never affected.",
                "Wine 8.0 fixed this in the server. Anvil now puts Wine 8's version of that one request handler into Wine 7.7's server as it starts, and only when the server's code matches the build it was checked against byte for byte; any other Wine is left untouched. Proved by running Wine's own handler, taken from both installed wineservers, on the same queues as Anvil's: identical messages removed and identical counts, and of 60 queued controller reports the game could read 0 intact from Wine's reply and 60 from Anvil's.",
                "The 0.10.4 note said the pad sends up to 1,100 events a second. Measured in play it was about 70. The stick-merging it added stays — it costs nothing — but it was not the fix."
            ],
            added: [
                "The first two freezes of a session are recorded as they happen: three seconds of every thread's call stack in the game, in wineserver and in Wine's device host, saved to Stalls/ beside game.log. If anything still stops the game, the next report says exactly where.",
                "game.log states whether the server fix went in, and how many queued controller reports it has delivered intact."
            ],
            known: [
                "Not yet measured in a game from here. The next session's game.log will show the fix going in and, if the game still freezes, the recorded stacks.",
                "Unity's “Invalid raw input data size: 0 bytes” lines continue — Rewired forwarding an empty set to Unity — and are harmless."
            ]),
        Release(
            version: "0.10.4",
            date: "27 September 2026",
            headline: "The game was being flooded with controller messages until it stopped drawing.",
            fixed: [
                "Every session with a working controller stopped producing frames 5–15 seconds in while the game kept handling controller messages — over 1,000 of them in the last one. Sessions where SDL could not see the pad never did. A Windows game handles every waiting message before it draws; the pad sends up to ~1,100 stick events a second, each a message under Wine, and when they arrive faster than they are handled the game never gets to draw. That is the lag — and the “random inputs” are the backlog playing out when the sticks ease off.",
                "Anvil now passes each stick axis to the game at most 125 times a second, keeping the newest value. The game reads the controller once per frame, so at 120 fps that loses nothing it can use. Buttons are never held back. Tested with a scripted stick through the same call Wine uses: 301 events became 79, each axis at least 8 ms apart, and a released stick returned to centre every time.",
                "A test caught the previous filter leaving a released stick at 1000 instead of 0 — its resting-zone rule dropped the last steps back to centre. That rule is gone."
            ],
            added: [
                "“Stick updates sent to the game” in the controller settings: 60, 125, 250 or unlimited.",
                "game.log now timestamps every line and records the moment a game stops drawing and when it resumes. The launch log records which app comes to the front during a game."
            ],
            known: [
                "The flood itself comes from Wine 7.7. The Wine 9.0 preview engine may end it at the source.",
                "Not yet measured in a game: the next session will show whether frames still stop."
            ]),
        Release(
            version: "0.10.3",
            date: "27 September 2026",
            headline: "-nolog removed Unity's stack walks; the first launch after setup no longer dies.",
            fixed: [
                "Measured after 0.10.2: Unity still rejected 269 empty raw-input messages in a short session, but with zero stack walks — each rejection is now one line instead of a native stack walk and 26 lines of log. That was the expensive part.",
                "A launch straight after preparing the prefix exited with code 1 in 0.2 seconds: wineboot leaves wineserver and its services running, and the game started into them. Anvil now waits for Wine to finish (wineserver -w, at most 20 seconds) whenever preparation or a settings write actually ran.",
                "With -nolog, Unity writes to standard output instead, which Anvil reads. Its per-report rejection line is now counted rather than copied into the launch log, along with the preloader warning Wine prints for every process.",
                "The Lowest Latency profile no longer starts sessions with one frame in flight. On this Mac that missed 7–79 refreshes at the start of every one of four measured sessions before backing off, for no latency gain. Only the explicit switch in Latency turns it on."
            ],
            added: [],
            known: [
                "The empty messages themselves come from Wine 7.7. The Wine 9.0 preview engine is the likely end to them."
            ]),
        Release(
            version: "0.10.2",
            date: "27 September 2026",
            headline: "The controller lag was Unity rejecting an empty message for every controller report.",
            fixed: [
                "Wine 7.7 delivers every controller report to the game as a raw-input message with no data. Cat Quest II's input library forwards it to Unity, which rejects it — “Invalid raw input data size: 0 bytes” — by walking the stack and writing about 26 lines to its log, on the main thread. The game's log recorded 2,004 of these in a 32-second session, during which the game fell below 30 fps. Keyboard and mouse raw input arrives intact, which is why they never lagged and the controller always did.",
                "Measured on the pad with the engine's own SDL: up to about 1,100 controller events a second while the sticks move, each one a message Unity has to reject. The game can use at most one reading per frame.",
                "Unity games now start with Unity's own -nolog option, confirmed present in this Unity build, so none of that is written. “Keep the game's own log” turns it back on for troubleshooting.",
                "Engines whose bin/wine64 is a bash wrapper — the Wine 9 preview engine is one — are now launched through the real binary. Through the wrapper, macOS would have stripped Anvil's interceptor and library paths.",
                "Changing a container's engine now upgrades its prefix during “Preparing…” instead of silently inside the first launch."
            ],
            added: [
                "Anvil drops controller events that carry nothing — exact repeats, and an axis resting inside a small zone around centre — and counts every event, so game.log shows the rate. Measured on the PowerA this removes little: the pad sends nothing at true rest."
            ],
            known: [
                "The root cause is in Wine 7.7, which both installed engines use. The preview engine is Wine 9.0 with D3DMetal 3.0 — checked in its files — and Wine 8 and 9 rewrote raw input, so it is the likely real fix. It is a preview with no published checksum; Anvil snapshots a container before switching engines, so it can be undone.",
                "Whether -nolog removes enough of the cost to end the lag has not been measured in a game from here."
            ]),
        Release(
            version: "0.10.1",
            date: "27 September 2026",
            headline: "More CPU for the game, and less work stolen from it every frame.",
            fixed: [
                "Wine starts every game thread at macOS's default priority, so the scheduler could run a game's main and render threads on the efficiency cores. Cat Quest II held 120 fps on the title screen but dropped to 80–109 rendered in real play — at half resolution, so the CPU, not the GPU, was the limit. Anvil now raises Wine's threads to the priority macOS gives interactive work. Tested under Rosetta: a new thread goes from “default” to “user-interactive”.",
                "When frame generation was only requested, Anvil still kept its history on every frame — two full-frame copies, a luminance pass and a command buffer of its own, committed from the game's render thread — and threw it away, because nothing was being generated. That work now happens only while frames are actually being generated.",
                "The Lowest Latency profile asked for a two-deep drawable pool with no way back, which on this Mac missed up to 79 refreshes in five seconds. With the refresh lock on, fewer queued frames now goes through the adaptive mode, which backs off by itself when refreshes are missed.",
                "“Game threads at high priority” had been a setting since early on and nothing read it. It controls the new priority now."
            ],
            added: [],
            known: [
                "More memory does not lower input lag; the game already has a 15 GB budget and was nowhere near it. The lag comes from frames that take longer than a refresh, which is CPU time.",
                "None of this could be measured in a game from here. game.log will show whether the 1% low and on-beat share improve in real play."
            ]),
        Release(
            version: "0.10.0",
            date: "26 September 2026",
            headline: "Controllers work in games again — macOS 27 had been handing them to a path that never delivers input under Wine.",
            fixed: [
                "After the macOS 27 update no controller reached any game. Anvil still listed the PowerA pad, but the engine's own SDL — the library Wine reads controllers through — reported zero controllers under every setting, including none at all.",
                "Cause, found by asking SDL directly on the real pad: SDL asks Apple's GameController framework whether it supports each device, and steps aside for its GameController-based backend when the answer is yes. macOS 27 started saying yes for this pad. That backend never delivers input where Wine runs SDL. With SDL_JOYSTICK_MFI=0, SDL sees the pad, treats it as a gamepad with Anvil's mapping, and read 163 inputs in ten seconds — every face button, the d-pad, both shoulders, ZL/ZR, both stick clicks, −, + and Home, and both sticks.",
                "Correction to 0.9.9: it said switching SDL's dedicated drivers off had cost first-party pads their triggers and rumble. With the GameController hand-off on, those pads were really being sent down the same path that just failed for the PowerA. Now they use the dedicated drivers, as intended."
            ],
            added: [
                "“Test controllers with the game engine” on the Controllers screen. It runs the engine's own SDL with exactly the settings a launch would use, for eight seconds, and shows whether the game will see each controller and every input it reads — no game launch needed. It is the test that found this."
            ],
            known: [
                "Your pad's fix is measured end to end in SDL. It has not yet been confirmed inside Cat Quest II itself — that is the next thing to check."
            ]),
        Release(
            version: "0.9.9",
            date: "26 September 2026",
            headline: "Every controller goes to whatever handles it best, instead of one guessed layout for all of them.",
            fixed: [
                "Anvil sent one fixed button layout for every connected pad and overrode SDL's own. It was verified on the PowerA pad it was written for and was wrong elsewhere: SDL's database has a DualShock 4's confirm button on button 1, not 0, and a PlayStation-layout pad on that path has its right stick on Z/Rz and its triggers on Rx/Ry — so L2 moved the camera.",
                "SDL's dedicated controller drivers were switched off for everything (SDL_JOYSTICK_HIDAPI=0), which took analog triggers, rumble and event-driven input away from every PlayStation, Xbox, Switch and Steam pad. They are back on. The one pad they once broke — yours — is kept off them by device ID, so it stays on the path verified in September.",
                "A controller macOS recognised but could not match to a USB device got a mapping keyed to an all-zero ID. It gets none now.",
                "“Invert look” inverted both sticks. It inverts the camera stick only.",
                "Two launches in the same second — a double-click on Play, or two copies of Anvil — started two games in one prefix and both died within 0.3 s. Play now ignores a second click while a game is starting, brings a running game forward instead of starting another, and a second copy of Anvil hands over to the first.",
                "One frame in flight is off by default. Measured on Cat Quest II it gave no latency gain (16.8–20 ms against 16.4 ms with two) and stuttered for the first five seconds of every session before backing off."
            ],
            added: [
                "Per pad: Sony, Nintendo, Microsoft and Valve controllers use SDL's dedicated drivers; other pads SDL's built-in database covers use SDL's mapping; anything else gets a mapping built from its own HID descriptor — buttons, axes and hat as the pad declares them. Checked against the real descriptor: your PowerA gets exactly the mapping verified on it before.",
                "Anvil remembers every controller it has seen, so one plugged in during a game — after SDL has read its configuration — is still handled correctly.",
                "The Controllers screen shows which of those paths each connected pad uses.",
                "Rumble enabled for PlayStation pads on SDL's drivers."
            ],
            known: [
                "Only your PowerA pad was connected, and this session could not open controllers from its sandbox, so the new paths for other pads follow SDL's standard configuration but have not been tried on hardware here.",
                "Remaps apply to third-party pads. First-party pads on SDL's drivers use the standard layout; remap those in the game's own settings."
            ]),
        Release(
            version: "0.9.8",
            date: "26 September 2026",
            headline: "The macOS 27 update removed Rosetta, and Anvil said it was installed.",
            fixed: [
                "Play failed with “Bad CPU type in executable”. Every Wine engine on this Mac is an Intel program, and after the macOS 27 update this Mac can no longer run Intel code at all — even Apple's own /usr/bin/true fails as x86_64. Anvil now checks before launching and says what is wrong and how to fix it: softwareupdate --install-rosetta --agree-to-license.",
                "Rosetta detection was a file-exists check on /usr/libexec/rosetta/oahd. That file survived the update; Rosetta did not. Anvil now runs a real Intel binary to find out, and checks at every launch, so reinstalling Rosetta works without restarting Anvil."
            ],
            added: [],
            known: [
                "Only Intel-only engines need Rosetta. Anvil reads each engine's Mach-O header to decide, so a native Apple-silicon engine would not be blocked."
            ]),
        Release(
            version: "0.9.7",
            date: "26 September 2026",
            headline: "The in-game statistics were never written anywhere you could read them.",
            fixed: [
                "The interceptor only writes its frame rate, 1% low, latency and pacing decisions when told where to, and Anvil never told it. Every figure quoted in these notes came from test runs that set the path by hand; a normal launch recorded none of them. They now go to ~/Library/Application Support/Anvil/game.log, with a header per session naming the game and Anvil version."
            ],
            added: [],
            known: [
                "game.log is kept under 5 MB; the previous one is moved aside as game.old.log."
            ]),
        Release(
            version: "0.9.6",
            date: "26 September 2026",
            headline: "One frame in flight for lower latency, a build that survives Xcode 27, and the Metal 4 panel that never did anything.",
            fixed: [
                "Updating to Xcode 27 broke the build outright. The Metal toolchain is a separate download now, and the build script runs under `set -e`, so the missing shader compiler aborted the whole build — no app at all, not just no shaders. The script now precompiles when it can, reuses a library built from byte-identical source when it cannot, and always ships the source, which the interceptor compiles at runtime if nothing else is available.",
                "“Measure latency” never measured anything. The function that records latency existed and was never called. It is wired in, always on, and every launch now writes average and worst-case latency to the log beside the frame rate and 1% low.",
                "“Lock to the display's refresh” silently did nothing whenever upscaling, frame generation and the FPS overlay were all off, because the interceptor that does the locking was only loaded for those three. It now loads for the lock too.",
                "The Metal panel's generation picker and four switches set eleven environment variables that nothing reads — checked against the D3DMetal binary in both installed engines, where the known-real MTL_HUD_ENABLED appears and these do not. They could not have worked: Metal 4 is an API a program chooses in its own code, and a game's Metal is D3DMetal's. The panel now reports what this Mac supports and says plainly what Anvil can and cannot change.",
                "The app bundle's version string had been stuck at 0.7.0; it now comes from this file."
            ],
            added: [
                "One frame in flight. A game faster than the display normally renders two frames ahead of it, so input reaches the screen two refreshes later. While the game fills every refresh with its own frames Anvil now holds it to one, which gets input on screen a refresh sooner — about 8.3 ms at 120 Hz. Anvil counts refreshes the game misses and goes back to two for the session if more than half a percent are missed; generating frames always uses two.",
                "Honest answer on new Metal: macOS 27 added no presentation or latency API — QuartzCore has nothing new, and Metal's additions are tensor and machine-learning features. The new MetalFX options all need depth and motion vectors from the game engine, which a Windows game through D3DMetal does not provide. The newest D3DMetal is still 2.1 stable and 3.0 preview; the engine catalogue has not changed since February."
            ],
            known: [
                "None of this release could be run. The session it was built in had no access to the GPU and could not write Anvil's data folder, so nothing here has been measured in a game. It compiles cleanly — zero warnings in the app and the interceptor, both architectures — and every change was checked by reading, but the latency gain is a design figure until a launch log says otherwise.",
                "If one frame in flight costs smoothness in a heavy scene, it backs off to two by itself; turning off “Lowest latency” in Latency does the same from the start."
            ]),
        Release(
            version: "0.9.5",
            date: "6 September 2026",
            headline: "Frame generation was creating the shortfall it then filled in, and half your frames were guesses.",
            fixed: [
                "Measured both ways on the same game and settings: with generation off it rendered 120 fps on its own at full 3024×1964. With generation on it rendered 91, and generation dutifully filled the gap it had just made. A synthesised frame costs GPU time and takes a drawable away from the game, so switching it on is what pushed the game below the rate that justified switching it on.",
                "The test for “is the game keeping up?” was the spacing of its frames — a number that generation itself inflates. Once started it could never stop, so half of every second was a warped guess standing in for a real frame the machine could have drawn. That is what the shaking was.",
                "Generation now starts off, the game's honest rate is measured, and frames are only synthesised for a game that genuinely cannot fill the display. While generating, it stops for one window periodically to take an honest reading again. Verified: with frame generation switched on, the game held 120 fps by itself and Anvil generated nothing at all — 2,398 real frames, zero synthesised.",
                "The wrong controller button was firing. Anvil set SDL to swap the face buttons of a Nintendo pad so its letters match the shell, while Wine translates to XInput, which is purely positional. Anvil's own mapping was already positional and correct — verified against this pad's HID report: 17 buttons, and the Switch order really does put B at usage 1 and A at usage 2. The swap was applied on top of a correct mapping, so the game received the neighbouring button."
            ],
            added: [
                "Frame statistics are reported whether or not frames are being generated. They used to be gated on generation being on, which meant the one configuration worth comparing against — the game running entirely on its own frames — produced no numbers at all. That gate is why this took several attempts to find."
            ],
            known: [
                "Measured after, at full 3024×1964 with everything enabled: 120.0 fps displayed, 1% low 117.6, 600 of 600 gaps exactly one refresh apart, worst gap 8.3 ms — and every frame a real one.",
                "Scene loads still cost a single gap of 300–350 ms. That is the game reading from disk.",
                "On a heavier game that genuinely cannot reach 120, generation will switch on and synthesised frames will be visible in motion. That is the trade it makes; it is now only made when it buys something."
            ]),
        Release(
            version: "0.9.4",
            date: "6 September 2026",
            headline: "The shaking was a fractional render scale, and it was never a frame-rate problem.",
            fixed: [
                "Anvil was rendering at 1.334× — a 2017×1310 drawable that the compositor then stretched to 3024×1964, a ratio of 1.4993. At a fraction like that every output pixel is a shifting blend of its neighbours, so edges crawl and fine detail boils as the camera moves. No amount of frame pacing touches it. The drawable is now snapped to a whole-number fraction of the display, whatever scale is asked for: verified taking 1.334 and using 3024×1964 at 1:1 instead.",
                "Profiles no longer offer fractional scales at all. Balanced rendered at two-thirds of the backing store to save performance this Mac does not need — it holds 120 fps at full resolution. Only 1:1 and exactly half remain, because nothing in between looks stable.",
                "Generated frames were warped for the wrong moment. The projection was a fixed half of the game's frame interval, but since frames were put on the refresh grid they are shown exactly one refresh later — 8.33 ms here against 5.5 ms at 91 fps. Every second frame sat slightly behind where it belonged, and alternating correct and displaced frames sixty times a second is seen as shaking. The warp now uses the real ratio between when a frame is shown and how long the game's own frames take.",
                "Frame generation switched on and off from one frame to the next when the game hovered near the panel's rate, so the picture alternated between real and synthesised frames in no steady pattern — judder while the counter still said 120. It now starts only when the game is clearly behind and stops only once it is clearly keeping up."
            ],
            added: [],
            known: [
                "Measured after the fix, in gameplay: 120.0 fps displayed, 1% low 117.6, 900 of 900 gaps exactly one refresh apart, worst gap 8.3 ms — sustained across four windows, at full 3024×1964.",
                "Scene loads still drop a window to a 1% low near 60, with single gaps of 333–725 ms. That is the game reading from disk and nothing here can fill it.",
                "Whether the shaking is gone is the one thing that needs your eyes. All three causes are code that was provably doing the wrong thing, and the resolution fix is confirmed in the log, but a shimmer is temporal and cannot be seen in a screenshot."
            ]),
        Release(
            version: "0.9.3",
            date: "6 September 2026",
            headline: "Play did nothing for 22 seconds, because the fullscreen fix ran four wine processes first.",
            fixed: [
                "Writing the display preference took 22 seconds on every launch. It was four separate “wine reg add” calls, and each one starts wine and waits on wineserver. Play was pressed, nothing appeared for 22 seconds, and nothing on screen said why — which is indistinguishable from a broken button. It is now a single registry import, and it is skipped entirely once the prefix already has the setting: 22 seconds, then 2, then 0.",
                "A launch now shows what it is doing — preparing the prefix, setting the display mode, starting the game — so a slow first launch can never look like a dead one again.",
                "Anvil shuts the prefix down once no game is using it. A wineserver outlives the game it served, and one left holding a prefix is why a relaunch moments later can fail; three launches in a row died after 0.2 s, 15 s and 21 s before settling. It is also the documented way to avoid a half-written registry."
            ],
            added: [
                "A launch log at ~/Library/Application Support/Anvil/anvil.log, recording every step with timings, the full environment, and the game's own output. Two rounds were spent guessing at this failure because nothing survived the window closing. It took one log to find it.",
                "“Anvil --launch-test” runs the real Play path headlessly and reports whether the game started, whether it was still running 25 seconds later, and which app ended up in front."
            ],
            known: [
                "Verified after the fix: three consecutive launches, all still running at 25 seconds, with the game frontmost. The first launch after changing display settings still costs about two seconds.",
                "The earlier report that the game closed after loading in is separately fixed in 0.9.1, and the window opening behind Anvil in 0.9.2. This release is the third cause — all three looked identical from the outside."
            ]),
        Release(
            version: "0.9.2",
            date: "6 September 2026",
            headline: "Play launched the game behind Anvil, which is why it looked dead and why the controller kept stopping.",
            fixed: [
                "Both problems were one bug, and it was mine. Switching fullscreen to borderless in 0.9.1 fixed the crash but lost something exclusive fullscreen had been doing for free: forcing the window to the front. macOS will not let a process launched by the active application take focus from it, so the game opened behind Anvil and stayed there — running, rendering at 120, and invisible.",
                "That is why Play looked like it did nothing. The game was already playing.",
                "And it is why controller input stopped. An unfocused Unity window ignores the gamepad, so switching to another app and back “fixed” it — that hands focus over. Launching focused fixes it at the root.",
                "Anvil now hides itself the moment a game starts, waits for the game's window, and brings it forward — then comes back when the game exits. Verified end to end: the game was frontmost 3 seconds after launch."
            ],
            added: [
                "A failed launch now shows the reason instead of doing nothing quietly. A Play button that silently fails is indistinguishable from one that is broken, which is exactly the position this release was reported from."
            ],
            known: [
                "If you click back to Anvil while a game is running, the game loses focus and the controller stops until you return to it. That is macOS behaviour, not something Anvil can override — but Anvil now stays out of the way rather than sitting in front of the game."
            ]),
        Release(
            version: "0.9.1",
            date: "6 September 2026",
            headline: "The game closing after you load in was Anvil's fault, and it is fixed.",
            fixed: [
                "Anvil appended “-screen-fullscreen 1” to every launch. Unity acts on that by asking Windows to change the display mode, which under Wine runs through win32u — and the game crashed there a second or two after the first scene finished loading. Unity's own crash report named it: RazerChromaManager, then the title scene, then “delay ended”, then Crash!!! in win32u.",
                "I told you twice this exit was not Anvil's doing. That was wrong, and it was wrong for a bad reason: every control run I compared against carried the same flag, so the crash showed up in both and looked like the game's own. A control run with the flag removed lasted 6 minutes 40 seconds and had to be killed; with the flag it died every time.",
                "Fullscreen is now written into the game's own display preference as borderless, at the display's real resolution. Borderless never changes the display mode, so it cannot take that path — and it alt-tabs cleanly. Verified: 11,998 frames, then a full game-world scene load of 204,264 objects, with everything else still enabled."
            ],
            added: [
                "1% low frame rate, which is the number that actually answers “is it stable”. An average cannot: a run that spends 99% of its time at 120 and the rest at 30 still averages near 120. Anvil takes the 99th-percentile gap between frames the display really showed and reports it as a rate. Measured in steady play: 1% low 117.6 fps against a 120 fps average, 99.8% of gaps exactly one refresh apart."
            ],
            known: [
                "Scene loads still produce a single long gap — up to 975 ms while the game loads 204,264 objects. That is the game reading from disk, and no frame schedule can fill it. It is what pulls the 1% low down in the window where it happens.",
                "Cat Quest II's Razer Chroma plugin fails to load because mfc140u.dll is not in the prefix. The game survives it, but it is a real missing dependency and Anvil should offer to install it rather than leaving it to fail.",
                "Of the MTL_* variables Anvil sets, only MTL_HUD_ENABLED and MTL_SHADER_VALIDATION are proven real — they appear in the D3DMetal binary. The rest could not be verified either way, because Metal lives in the dyld shared cache and scanning it finds none of these names, including the two that certainly are real. They are left set because an unread variable costs nothing, and nothing in the UI claims they do anything."
            ]),
        Release(
            version: "0.9.0",
            date: "6 September 2026",
            headline: "A stable 120, not an average of 120 — every frame on the display's own grid.",
            fixed: [
                "Frames were presented the instant they finished, which is what the stutter was. At 67 fps on a 120 Hz panel a frame arrives every 1.79 refreshes, so consecutive gaps alternate between one refresh and two. The average reads 120 and it judders. Anvil now schedules every frame — real and generated — onto the panel's refresh grid, quantised against a time the display actually refreshed rather than against the wall clock.",
                "Measured on Cat Quest II at 3024×1964: 900 of 900 displayed gaps exactly one refresh apart, worst gap in a window 8.3 ms, held across 7,798 frames.",
                "Frame generation no longer runs when there is nothing to gain. When the game reached 120 fps on its own, generation stopped entirely and the display stayed at a locked 120 — all real frames. A real frame beats a synthesised one and costs less latency, so nothing is generated unless the game has left a refresh empty."
            ],
            added: [
                "Evenness is measured and reported, because an average frame rate hides exactly the thing being complained about: 120 fps made of alternating 4 ms and 12 ms gaps averages the same as a steady 8.3 ms and looks nothing like it.",
                "“Lock to the display's refresh” and a frame-rate target in the Latency section."
            ],
            known: [
                "The game is never capped below what it can do. It rendered 91 fps with generation filling the gaps, then 120 with generation off, and both held 100% on-beat — so the lock costs no frames and no latency beyond at most one refresh on a game already faster than the panel.",
                "A loading screen still produces a single long gap — 325 ms was the worst seen. That is the game loading, not the pacing, and no frame schedule can fill it.",
                "Anvil briefly deadlocked itself during this work: generation runs inside the game's own nextDrawable call and asks the same drawable pool, so holding more frames pending could leave nothing for the game and both sides waited. Generation now checks the pool has one to spare and skips the frame if not. A missed synthesised frame is invisible; a hung game is not."
            ]),
        Release(
            version: "0.8.1",
            date: "6 September 2026",
            headline: "Frame generation verified against what the display actually showed — and the FPS counter's digits were wrong.",
            fixed: [
                "Seven of the ten digits in the overlay font were wrong. Each one's comment described the correct shape and the value beside it did not match — 6 and 9 were each other's bitmap, so a real 69 fps was displayed as 96. The table is now generated from those comments rather than typed by hand.",
                "The frame-rate counter reports what reached the display. With frame generation on it was showing the rate the game renders at, which is about half what you are actually seeing — measured here as 65 rendered against 120 displayed."
            ],
            added: [
                "Frame generation now proves itself. Counting submitted frames is not evidence: a drawable can be presented and still be superseded before the display picks it up, so a pipeline generating diligently and displaying nothing looked identical from inside. Anvil registers a presented handler on every frame, real and generated, and reports what was actually shown.",
                "Measured on Cat Quest II at 3024×1964: 8,400 real frames submitted, 8,396 generated, 2 skipped — 8,398 real and 8,395 generated confirmed displayed. The game rendered at 65–75 fps and the display ran at 120."
            ],
            known: [
                "120 fps is this display's ceiling, so once the game renders above 60 the generated frames are what fill the panel rather than raising the number further. The gain is in smoothness at a rendered rate below 60.",
                "The game still exits on its own after a while. A control run on the same engine with nothing injected lasted 36 seconds; the run with frame generation and everything else enabled was still going after 8,400 frames. Whatever ends it, it is not Anvil.",
                "Disocclusion is still a cross-fade — where motion uncovers geometry that was hidden, the generated frame guesses. Depth from the render pass would fix it and is not captured yet."
            ]),
        Release(
            version: "0.8.0",
            date: "6 September 2026",
            headline: "Anvil had never found Mythic's engine, and several settings did nothing.",
            fixed: [
                "Mythic Engine is found. Anvil looked for it under Mythic's bundle identifier, a path that does not exist — so it silently fell back to Whisky's toolchain and ran every game on D3DMetal 2.0 while D3DMetal 2.1 sat installed on the same Mac.",
                "The toolchain picker now shows each one's D3DMetal version, and Anvil defaults to the newest rather than the first it happens to find. Two toolchains both reporting wine-7.7 can ship D3DMetal builds nine months apart.",
                "Retina mode and DPI are applied. They are registry keys inside the prefix; Anvil set them as the environment variables WINE_RETINA_MODE, WINEDPI and WINE_RESOLUTION, which Wine does not read. Games were being handed a low-DPI display no matter what the UI said, and Anvil was compensating by enlarging the drawable after the fact.",
                "Removed nine settings that changed nothing. WINE_HEAP_LIMIT_MB, WINE_REPORTED_MEMORY_MB, D3DM_VRAM_MB, WINE_VK_VRAM_MB, WINE_CPU_TOPOLOGY, WINE_PRESENT_MODE, D3DM_TRIPLE_BUFFER, D3DM_SHADER_CACHE_SIZE_MB and DXMT_METALFX_SPATIAL appear in neither the Wine tree nor the D3DMetal binary. The switches that set them are gone, and the frame-rate estimate no longer credits them.",
                "Taking ownership of a toolchain clones instead of copying, so it is instant, costs no disk on APFS, and cannot write to the app it came from."
            ],
            added: [
                "Compiled shaders survive macOS cleanups. D3DMetal caches them under /var/folders, which macOS clears on its own schedule; when it does, the game recompiles everything and the stutter comes back in a game that had already run smoothly. Anvil keeps a copy where nothing sweeps it, restores it before launch, and takes the grown copy back afterwards.",
                "Engine installs. Anvil reads Mythic's public engine catalogue and installs into its own store — a Mythic install on the same Mac keeps the engine it has and keeps updating it on its own schedule. A preview engine carrying D3DMetal 3.0 is listed there.",
                "Every version lands in its own folder and containers keep pointing at what they were built against, so reverting a bad engine is one click and never touches a save or a prefix.",
                "Real D3DMetal controls: multithreaded command submission, ray tracing (off by default — it is the most expensive thing this layer can be asked to do), and a texture-sharpness bias that keeps textures crisp when the frame is rendered below native and sharpened back up.",
                "Downloads are fetched over HTTPS even though the catalogue publishes plain http, and verified against the published checksum before anything is unpacked."
            ],
            known: [
                "The preview engine with D3DMetal 3.0 publishes no checksum, so Anvil can verify the transport but not the contents. It is listed under a preview toggle that is off by default.",
                "Ray tracing only does anything for a DirectX 12 title on D3DMetal that offers it; on DXVK and WineD3D the switch is inert and hidden.",
                "The frame-rate estimate is still a model. It now models only levers that exist, which makes it honest, not accurate — a logged measurement always replaces it."
            ]),
        Release(
            version: "0.7.0",
            date: "5 September 2026",
            headline: "Controller polling cut from 10 ms to 1 ms, without rebuilding Wine.",
            fixed: [
                "Wine reads controllers from an SDL_WaitEventTimeout loop and asks for a 10 ms wait — measured, not assumed. SDL's macOS joystick backend polls with IOHIDDeviceGetValue rather than taking the input callback, so a pad's state is only observed when that loop comes round. That 10 ms was the floor on controller latency, and it is exactly why keyboard and mouse felt instant: they arrive as events through Wine's Mac driver and never touch this path.",
                "winebus resolves SDL through dlsym rather than linking it, so the function could not be interposed directly. dlsym itself is interposed instead: when Wine asks for SDL_WaitEventTimeout it receives a wrapper that shortens the wait, and every other symbol passes through untouched. No patched Wine, no rebuild. Verified in a live game — the interception fires, Wine's 10 ms request is logged, and the pad is still recognised as a gamepad.",
            ],
            added: [
                "Controller poll interval is a container setting. There is nothing to gain below 1 ms: the pad reports every 4 ms.",
            ],
            known: [
                "This shortens the wait between polls. It does not make SDL's backend event-driven, which would need a patched SDL.",
            ]),
        Release(
            version: "0.6.1",
            date: "5 September 2026",
            headline: "Frame generation down to about 3.9 ms, and the controller delay traced.",
            fixed: [
                "The optical flow search is one threadgroup per motion vector, so its cost falls with the square of how coarse the field is: 2.19 ms at the previous setting against 0.73 ms one step coarser. Motion is marginally less precise at object edges, on a frame that exists for eight milliseconds. The projected pipeline now costs roughly 3.9 ms per frame, from 17.2 ms three versions ago.",
            ],
            added: [
                "Motion field coarseness is adjustable.",
            ],
            known: [
                "Controller latency is not Anvil's to fix. The pad reports at 250 Hz — a 4 ms floor — and keyboard and mouse are unaffected because Wine delivers those as events through its Mac driver. The controller goes through winebus and SDL instead, and the delay is inside that path. Anvil's own contributions have been removed: the thread stall during frame generation, five environment variables that did not exist, and SDL's polling thread now runs at realtime priority. What remains is inside Wine, and cannot be tuned from outside it.",
            ]),
        Release(
            version: "0.6.0",
            date: "5 September 2026",
            headline: "Frame generation projects forward instead of filling in behind — lower latency and less judder at once.",
            fixed: [
                "MetalFX was being fed the two most recent real frames and asked for the midpoint between them, but the result was emitted after the newer one had already been shown. The sequence ran A, B, mid(A,B), C — forward, back, forward. That is the judder, and it makes motion read as late. It is the same ordering fault fixed early on for Anvil's own interpolator, reintroduced when MetalFX was wired in.",
                "Frame generation now projects forward from the two frames already shown. The synthesised frame belongs exactly where it is emitted, nothing is held back, and no queue latency is added — which is what makes frame generation and low input lag possible together. It is also cheaper: about 6.2 ms per frame against 9.4 ms.",
                "Lowest input lag now keeps frame generation on, in its projected form. The two were only mutually exclusive because interpolation was the only mode.",
            ],
            added: [
                "A frame generation mode choice. Projected adds no latency and is the default; Interpolated uses MetalFX for a better image and costs a frame, and says so.",
            ],
            known: [
                "A projected frame assumes motion continues, so a sudden reversal is mispredicted for a single frame; confidence and a speed taper fall back to the unmodified frame rather than tearing.",
            ]),
        Release(
            version: "0.5.1",
            date: "5 September 2026",
            headline: "Frame generation was stalling the thread that reads the controller.",
            fixed: [
                "Generation ran on the game's own thread inside nextDrawable — acquiring a drawable and encoding every pass before the game was allowed to continue. In Unity that same thread pumps input, so the stall arrived as late input and, when a release event was missed entirely, as a stick that kept travelling after being let go. A generated frame is now skipped whenever the previous one is still in flight: losing a synthesised frame costs nothing, blocking the controller costs the input.",
                "With frame generation on, the presentation queue is forced to three. Generation takes a second drawable while the game holds its own, and a two-deep pool has none spare — nextDrawable then blocks outright, which is the same stall by a different route.",
                "The controller's real HID layout was read rather than assumed: X, Y, Z, Rz with 17 buttons and a hat, which confirms the axis mapping was correct and the stuck stick was a dropped event, not a bad map.",
            ],
            added: [],
            known: [
                "Frame generation adds input latency by construction, and no amount of optimisation changes that. It is off in every profile except Smoothest.",
            ]),
        Release(
            version: "0.5.0",
            date: "5 September 2026",
            headline: "Frame generation was costing more than a 60fps frame budget on its own.",
            fixed: [
                "MetalFX interpolation was running at full resolution: 12.27 ms at 3024×1964, an 82fps ceiling before the game rendered anything. With optical flow, the luma pyramid and the finish pass on top, Anvil was spending 17.2 ms per frame — over a 60fps budget with no game work at all, which is exactly why frame generation never reached 60. It now interpolates at half resolution and scales the result: 4.35 ms including both conversions, and about 9.5 ms for the whole pipeline.",
            ],
            added: [
                "Interpolation resolution is adjustable from 25% to 100%, since it is the single most expensive thing in the pipeline.",
            ],
            known: [
                "A generated frame is slightly softer than a rendered one at half interpolation resolution. It is on screen for roughly eight milliseconds.",
                "Frame generation adds input latency by construction. Lowest input lag turns it off for that reason.",
            ]),
        Release(
            version: "0.4.1",
            date: "5 September 2026",
            headline: "Controller input latency, and the removal of settings that did nothing.",
            fixed: [
                "Five of the variables Anvil set for controllers do not exist. SDL_JOYSTICK_DEADZONE, SDL_HINT_JOYSTICK_THREAD and SDL_GYRO_AS_RIGHT_STICK appear nowhere in this SDL build; WINE_XINPUT_ENABLE and WINE_DINPUT_HIDRAW appear nowhere in Wine. They were invented. The deadzone sliders and the gyro toggle were connected to them, so those controls moved and changed nothing — they have been removed rather than left looking functional.",
                "SDL polls the pad on its own thread, and that thread being scheduled behind a game using every core makes the poll late and the input late with it. SDL_THREAD_FORCE_REALTIME_TIME_CRITICAL, which does exist in this build, is now set.",
                "The Lowest input lag profile rendered at full resolution, which maximises GPU load — and a frame that only just finishes in time is a late frame with input queued behind it. It now renders at two-thirds to keep headroom.",
            ],
            added: [],
            known: [
                "Deadzone must be set in the game's own options for now. Wine's DirectInput exposes no deadzone key, so there is nothing for Anvil to write.",
                "This build was not verified against a live game: repeated launches in quick succession exit early, with or without Anvil injected.",
            ]),
        Release(
            version: "0.4.0",
            date: "5 September 2026",
            headline: "One profile switch, because the individual settings could multiply into nonsense.",
            fixed: [
                "Scaling and upscaler quality multiplied together, so choosing native scaling and then an upscaler rendered *below* the game's own resolution: 1512×982 became 889×577 on a 3024×1964 display, stretched back up. That is worse than doing nothing, and nothing in the interface prevented reaching it. A profile now owns the render scale outright.",
                "The three regressions that followed from that combination — softer picture, worse stutter, delayed input — were all consequences of settings interacting, not of separate faults. Sharpest returns the full 3024×1964 drawable, verified.",
            ],
            added: [
                "Performance profiles: Sharpest, Balanced, Smoothest, Lowest input lag, Custom. Each sets resolution, upscaling, frame generation and queue depth together, and the container shows the resolution the game will actually render at before anything is launched.",
            ],
            known: [
                "Frame generation and a deeper queue both cost input latency by design. Smoothest accepts that; Lowest input lag refuses it. There is no setting that gives both.",
            ]),
        Release(
            version: "0.3.2",
            date: "5 September 2026",
            headline: "Cover art appears by itself, and more memory is spent on smoothness.",
            fixed: [
                "The presentation queue defaulted to two frames. That is the lowest-latency setting but leaves no slack — one frame that runs long has nothing queued behind it, the display repeats, and it reads as a stutter. Three is now the default: a frame of latency and a little memory in exchange for absorbing spikes.",
                "Anvil re-marked its own history textures reclaimable on every memory sample while over budget, so the kernel repeatedly reclaimed and refaulted them — a stutter caused by the code meant to avoid one. Done once now, on crossing the line.",
            ],
            added: [
                "Cover art is found automatically when a game is added, from the metadata the launchers already cached — so the match is made from files on disk rather than by searching for a title. Art shipped beside the executable is preferred; otherwise the storefront image is fetched. Verified matching Cat Quest II, Hogwarts Legacy and LEGO Star Wars, including across differences in punctuation.",
                "A toolbar action to fill in artwork for every game that has none, and a per-game action to look one up on demand.",
                "Shader caches are given room to grow. A pipeline compiled mid-frame is a hitch; every one that survives to the next session is a hitch that does not happen twice.",
            ],
            known: [
                "Frame interpolation still uses a flat depth buffer.",
            ]),
        Release(
            version: "0.3.1",
            date: "5 September 2026",
            headline: "The stutter was a drawable-pool rebuild every single frame.",
            fixed: [
                "Anvil assigned CAMetalLayer.drawableSize on every frame, including when the value had not changed. Each assignment invalidates and rebuilds the layer's drawable pool, so the cost scaled with frame count rather than with any work being done — which is why switching an upscaler on made the stutter worse instead of better. It is now written only when it actually differs: measured at 1 resize over 200 frames, against 200 before.",
                "The drawable ratcheted upward without bound. Anvil could mistake a size it had written for the game's own choice and scale it again — 1512 to 2017 to 4034 — raising the frame cost every time. It now tracks what it wrote, and clamps to the display's real pixel count.",
                "Enabling an upscaler overrode the Retina scale instead of composing with it, so turning FSR on dropped a Retina container from 3024×1964 to 1008×655 — below the half resolution it started at. Retina now decides how many pixels the display wants and the quality mode decides what fraction to render, so Quality on Retina lands at 2017×1309.",
            ],
            added: [],
            known: [
                "Depth for frame interpolation is still approximated with a flat buffer.",
            ]),
        Release(
            version: "0.3.0",
            date: "5 September 2026",
            headline: "Apple's frame interpolator, running in games that supply nothing.",
            fixed: [],
            added: [
                "Metal frame generation. MTLFXFrameInterpolator requires colour, previous colour, depth and motion. Anvil already keeps the two colour frames, and its optical flow supplies the motion — so Apple's production interpolator now runs in a game that ships no FSR, DLSS or XeSS and no motion vectors of its own. Verified initialising and generating frames.",
            ],
            known: [
                "Depth is the one input that cannot be recovered from a finished frame; a flat buffer is supplied, so the interpolator loses its depth-based disocclusion handling. Capturing the game's real depth buffer from the render pass would fix that and is the next thing worth building.",
                "Verified in the test harness. Not yet confirmed over a long session in a real game.",
            ]),
        Release(
            version: "0.2.3",
            date: "5 September 2026",
            headline: "Anvil's own per-frame cost cut by 43%.",
            fixed: [
                "Sharpening and the overlay ran as separate passes: two full-resolution blits and two dispatches, measured at 2.26 ms per frame at 3024×1964 — a fifth of the budget at 90fps, and enough to be felt as stutter. They are now one dispatch behind one blit, measured at 1.29 ms. The blit was the expensive part at 1.08 ms, so doing one instead of two is where the saving is.",
            ],
            added: [],
            known: [
                "Retina rendering means the game draws four times the pixels it did before. That is the sharpness, and it is also the largest single cost — if the frame rate is short, an FSR quality mode claws most of it back while keeping the image close.",
                "FSR 3's temporal upscaling still cannot be injected into a game that ships no upscaler: it requires motion vectors, depth and a jittered projection as function inputs. Anvil's optical-flow frame generation is the path that needs nothing from the engine.",
            ]),
        Release(
            version: "0.2.2",
            date: "5 September 2026",
            headline: "Controllers work. Anvil had been disabling them itself.",
            fixed: [
                "Anvil set SDL_JOYSTICK_HIDAPI=1. That backend claims devices exclusively and drops the ones it cannot claim rather than falling back, so Wine never enumerated the controller at all — Anvil was breaking every pad it launched a game with. Measured on a wired PowerA pad: HIDAPI on, not enumerated; HIDAPI off, enumerated as is_gamepad 1 and mapped to XInput. Applies to wired and Bluetooth pads from any vendor.",
                "The controller list was only refreshed at app start and on GameController notifications, which never fire for a pad macOS has no profile for. A controller plugged in after Anvil started produced no mapping at all. It is now re-scanned immediately before every launch, and IOKit hotplug callbacks keep the list live.",
            ],
            added: [],
            known: [
                "Verified as far as Wine recognising the pad as a gamepad and mapping it to XInput. Whether a given game responds to input has not been confirmed by pressing buttons.",
            ]),
        Release(
            version: "0.2.1",
            date: "5 September 2026",
            headline: "The FPS counter shows a number, and controllers reach the game.",
            fixed: [
                "The FPS counter drew a permanent zero. The overlay read a frame-rate value that nothing ever wrote — the measurement had been lost when an earlier revert rolled back the function containing it. Now measured at the one point that runs exactly once per displayed frame; verified reading 120.0.",
                "Controllers never reached the game. Wine did enumerate the pad, but SDL reported is_gamepad 0 because it has no mapping for that device's GUID, so Wine registered it as a generic HID joystick and never mapped it to XInput — which is what Unity reads. Anvil now supplies a mapping keyed to the device's own GUID, verified flipping Wine to is_gamepad 1.",
            ],
            added: [],
            known: [
                "The controller fix is verified as far as Wine recognising the pad as a gamepad. Whether a given game then responds to it has not been confirmed.",
            ]),
        Release(
            version: "0.2.0",
            date: "5 September 2026",
            headline: "Crash fixed, full-resolution rendering, controllers mapped to XInput.",
            fixed: [
                "Games crashed with an abort inside Metal's blit encoder. Anvil resizes the drawable at runtime for Retina and render scaling, which left its own cached textures stale for a frame; a mismatched blit asserts and aborts, and cannot be caught. Every blit now checks first and skips instead.",
                "Games rendered at half resolution. A window on a Retina display is handed a drawable measured in points, so Cat Quest II drew 1512×982 on a 3024×1964 screen and the compositor stretched it. Anvil now enlarges the drawable — four times the pixels.",
                "Controllers were never mapped to XInput. A fresh Wine prefix has no DirectInput registry key, so a pad is enumerated as a plain joystick and Unity games never see it.",
                "The injector was arm64-only and wine64 runs x86_64 under Rosetta. dyld terminates a process whose inserted dylib will not load, so every injected launch died instantly. Now universal.",
                "Epic titles launched EOSBootstrapper.exe instead of the game, because the bootstrapper is often the larger binary.",
                "Save imports missed registry-backed saves, which is where Unity keeps settings and bindings.",
            ],
            added: [
                "Anvil draws its own FPS counter. Apple's Metal HUD reports everything it knows and cannot be asked for less.",
                "Fullscreen option.",
                "Sync: reconcile the library with other launchers — add new installs, repair moved games, report ones that are gone.",
                "Import installed games from Mythic, Heroic and other launchers, with cover art.",
                "File integrity: SHA-256 baselines, and a size check that found two partial downloads on this machine.",
                "Per-game memory budget, presentation-queue latency controls, and frame pacing.",
            ],
            known: [
                "Frame generation is experimental. It runs, but has not been verified over a long session in a real game.",
                "FSR 3's temporal modes only apply to games that already ship FSR, DLSS or XeSS. They need motion vectors, depth and a jittered projection from the engine, which cannot be supplied from outside. The built-in FSR mode works everywhere and needs nothing.",
                "The upscale after render scaling is performed by the compositor rather than by FSR's EASU; routing it through EASU starves the drawable pool.",
            ]),
    ]

    static var latest: Release { releases[0] }

    /// True the first time this version runs, so the notes can be shown once.
    static var isFirstRunOfThisVersion: Bool {
        let key = "anvil.lastSeenVersion"
        let seen = UserDefaults.standard.string(forKey: key)
        return seen != current
    }

    static func markVersionSeen() {
        UserDefaults.standard.set(current, forKey: "anvil.lastSeenVersion")
    }
}

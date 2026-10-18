// When the game stops drawing, or first slows down, record what every thread is doing.
//
// A freeze leaves nothing behind but its length. macOS's `sample` tool can read the
// call stacks of a Rosetta-translated process — Wine's own frames included — so the
// first freezes of a session are captured while they are happening: the game, the Wine
// server every Windows call waits on, and the device host that feeds it controller
// input. The files land in Stalls/ next to game.log.

#include <spawn.h>
#include <fcntl.h>
#include <unistd.h>
#include <signal.h>
#include <sys/wait.h>
#include <mach/machine.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>


namespace {

// Positional arguments: $1 folder, $2 game pid, $3 label (freeze1, slow1, ...).
constexpr const char* kScript = R"SH(
d="$1"; pid="$2"; n="$3"
mkdir -p "$d" || exit 0
out="$d/$(date +%Y%m%d-%H%M%S)-$n"
list() { ps -axo pid=,pcpu=,cputime=,state=,command= | grep -i -E 'wine|[.]exe' | grep -v -E 'grep|/usr/bin/sample|anvil-stall'; }
{ date; echo "game pid $pid"; list; } > "$out-processes.txt" 2>&1
/usr/bin/sample "$pid" 3 2 -mayDie -file "$out-game.txt" >/dev/null 2>&1 &
for p in $(pgrep -x wineserver); do /usr/bin/sample "$p" 3 2 -mayDie -file "$out-wineserver-$p.txt" >/dev/null 2>&1 & done
for p in $(list | grep -i 'winedevice[.]exe' | awk '{print $1}'); do /usr/bin/sample "$p" 3 2 -mayDie -file "$out-winedevice-$p.txt" >/dev/null 2>&1 & done
wait
{ echo; date; list; } >> "$out-processes.txt" 2>&1
[ "$n" = freeze1 ] && /usr/bin/vmmap -interleaved "$pid" > "$out-game-vmmap.txt" 2>&1
exit 0
)SH";

} // namespace

/// Starts a capture in the background and returns at once. Returns the folder written
/// to, or nullptr when nothing was started.
extern "C" const char* AnvilCaptureStall(const char* label) {
    static std::string folder;
    const char* logPath = getenv("ANVIL_LOG");
    if (!logPath) return nullptr;
    folder = logPath;
    const size_t slash = folder.rfind('/');
    if (slash == std::string::npos) return nullptr;
    folder = folder.substr(0, slash) + "/Stalls";

    char pid[16];
    snprintf(pid, sizeof pid, "%d", getpid());
    const char* argv[] = {"/bin/sh", "-c", kScript, "anvil-stall", folder.c_str(), pid, label, nullptr};

    // A clean child: no Wine descriptors, no inherited signal state, and none of the
    // DYLD or Wine variables — the tools must not load Anvil or think they are Wine.
    std::string home = std::string("HOME=") + (getenv("HOME") ? getenv("HOME") : "/tmp");
    const char* env[] = {"PATH=/usr/bin:/bin:/usr/sbin:/sbin", home.c_str(), nullptr};

    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    sigset_t none, all;
    sigemptyset(&none);
    sigfillset(&all);
    posix_spawnattr_setsigmask(&attr, &none);
    posix_spawnattr_setsigdefault(&attr, &all);
    posix_spawnattr_setpgroup(&attr, 0);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF |
                                    POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT);
    cpu_type_t prefer[] = {CPU_TYPE_ARM64, CPU_TYPE_X86_64};
    size_t set = 0;
    posix_spawnattr_setbinpref_np(&attr, 2, prefer, &set);

    posix_spawn_file_actions_t files;
    posix_spawn_file_actions_init(&files);
    for (int fd = 0; fd < 3; ++fd)
        posix_spawn_file_actions_addopen(&files, fd, "/dev/null", fd ? O_WRONLY : O_RDONLY, 0);

    pid_t child = 0;
    const int rc = posix_spawn(&child, "/bin/sh", &files, &attr, const_cast<char* const*>(argv),
                               const_cast<char* const*>(env));
    posix_spawn_file_actions_destroy(&files);
    posix_spawnattr_destroy(&attr);
    if (rc != 0) return nullptr;
    std::thread([child] { int status; waitpid(child, &status, 0); }).detach();
    return folder.c_str();
}

// The game's own connections, held back while Anvil starts it offline.
//
// An Epic game started offline is given its account but no sign-in code — exactly what
// Epic's own launcher and legendary do. On a Mac with no connection that is all it needs:
// Epic Online Services finds no network at once and the game goes on offline, and on
// 1 October LEGO Star Wars reached its first scene in about 20 seconds in front that way.
// With Offline Mode on and the Mac still connected, the same start found Epic, tried to
// sign in with the empty code, and was still on its loading screen after 45 seconds in
// front on 3 October, with a connection to Epic open.
//
// So while Anvil starts a game offline, the game sees what a Mac with Wi-Fi off shows it:
// names don't resolve and connections out of the Mac are unreachable. Everything inside
// the Mac — Wine's own sockets, anything on this Mac's loopback — is left alone. Whether
// it applies is a file Anvil creates for the session (ANVIL_OFFLINE_FLAG), looked at
// again at most once a second: the wineserver, where Wine makes connections, can outlive
// a session and serve the next one, and the next one may be online.
#import <Foundation/Foundation.h>
#include <arpa/inet.h>
#include <dlfcn.h>
#include <errno.h>
#include <libproc.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/in_pcb.h>
#include <netinet/tcp_fsm.h>
#include <netinet/tcp_var.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/proc_info.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>
#include <algorithm>
#include <atomic>
#include <vector>

namespace {

std::atomic<int> g_offline{-1};          // -1 not looked at yet
std::atomic<double> g_lookedAt{0.0};
std::atomic<int> g_heldBack{0};

double monotonic() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec * 1e-9;
}

bool offlineNow() {
    const double now = monotonic();
    if (g_offline.load(std::memory_order_relaxed) >= 0 && now - g_lookedAt.load(std::memory_order_relaxed) < 1.0)
        return g_offline.load(std::memory_order_relaxed) == 1;
    const char* flag = getenv("ANVIL_OFFLINE_FLAG");
    struct stat st;
    const int value = (flag && flag[0] && stat(flag, &st) == 0) ? 1 : 0;
    g_offline.store(value, std::memory_order_relaxed);
    g_lookedAt.store(now, std::memory_order_relaxed);
    return value == 1;
}

/// Inside the Mac: Unix sockets, the loopback, and "any" (which only means this Mac).
bool local(const struct sockaddr* addr) {
    if (!addr) return true;
    switch (addr->sa_family) {
    case AF_UNIX:
        return true;
    case AF_INET: {
        const uint32_t a = ntohl(reinterpret_cast<const sockaddr_in*>(addr)->sin_addr.s_addr);
        return (a >> 24) == 127 || a == 0;
    }
    case AF_INET6: {
        const in6_addr& a = reinterpret_cast<const sockaddr_in6*>(addr)->sin6_addr;
        if (IN6_IS_ADDR_LOOPBACK(&a) || IN6_IS_ADDR_UNSPECIFIED(&a)) return true;
        if (IN6_IS_ADDR_V4MAPPED(&a)) return a.s6_addr[12] == 127;
        return false;
    }
    default:
        return true;    // not an internet address
    }
}

bool localName(const char* host) {
    if (!host || !host[0]) return true;
    if (!strcasecmp(host, "localhost") || !strcasecmp(host, "localhost.") || !strcmp(host, "::1")) return true;
    return !strncmp(host, "127.", 4);
}

/// The first few things held back, in game.log, so a session says what the game tried.
void note(const char* what) {
    const int n = g_heldBack.fetch_add(1, std::memory_order_relaxed);
    if (n >= 4) return;
    const char* path = getenv("ANVIL_LOG");
    if (!path) return;
    if (FILE* f = fopen(path, "a")) {
        if (n == 0)
            fprintf(f, "[anvil] offline: %s held back — started offline, the game sees no connection this session, as with Wi-Fi off\n", what);
        else
            fprintf(f, "[anvil] offline: %s held back too%s\n", what, n == 3 ? " (further ones not listed)" : "");
        fclose(f);
    }
}

void describe(const struct sockaddr* addr, char* out, size_t size) {
    char ip[INET6_ADDRSTRLEN] = "?";
    unsigned port = 0;
    if (addr->sa_family == AF_INET) {
        auto in = reinterpret_cast<const sockaddr_in*>(addr);
        inet_ntop(AF_INET, &in->sin_addr, ip, sizeof ip);
        port = ntohs(in->sin_port);
    } else if (addr->sa_family == AF_INET6) {
        auto in = reinterpret_cast<const sockaddr_in6*>(addr);
        inet_ntop(AF_INET6, &in->sin6_addr, ip, sizeof ip);
        port = ntohs(in->sin6_port);
    }
    snprintf(out, size, "a connection to %s port %u", ip, port);
}

bool holdBack(const struct sockaddr* addr) {
    if (!addr || local(addr) || !offlineNow()) return false;
    char what[96];
    describe(addr, what, sizeof what);
    note(what);
    return true;
}

} // namespace

extern "C" int anvil_connect(int fd, const struct sockaddr* addr, socklen_t len) {
    if (holdBack(addr)) { errno = ENETUNREACH; return -1; }
    return connect(fd, addr, len);
}

extern "C" ssize_t anvil_sendto(int fd, const void* buf, size_t n, int flags, const struct sockaddr* addr, socklen_t len) {
    if (holdBack(addr)) { errno = ENETUNREACH; return -1; }
    return sendto(fd, buf, n, flags, addr, len);
}

extern "C" ssize_t anvil_sendmsg(int fd, const struct msghdr* msg, int flags) {
    if (msg && msg->msg_name && holdBack(static_cast<const struct sockaddr*>(msg->msg_name))) { errno = ENETUNREACH; return -1; }
    return sendmsg(fd, msg, flags);
}

extern "C" int anvil_getaddrinfo(const char* host, const char* service, const struct addrinfo* hints, struct addrinfo** res) {
    if (!localName(host) && offlineNow()) {
        // A literal address needs no lookup; its connection is what gets held back.
        struct in6_addr a6; struct in_addr a4;
        if (inet_pton(AF_INET, host, &a4) != 1 && inet_pton(AF_INET6, host, &a6) != 1) {
            char what[300];
            snprintf(what, sizeof what, "looking up %s", host);
            note(what);
            return EAI_NONAME;
        }
    }
    return getaddrinfo(host, service, hints, res);
}

extern "C" struct hostent* anvil_gethostbyname(const char* host) {
    if (!localName(host) && offlineNow()) {
        struct in_addr a4;
        if (inet_pton(AF_INET, host, &a4) != 1) {
            char what[300];
            snprintf(what, sizeof what, "looking up %s", host);
            note(what);
            h_errno = HOST_NOT_FOUND;
            return nullptr;
        }
    }
    return gethostbyname(host);
}

// Which program owns a connection, as Windows tells it (GetExtendedTcpTable with owner ids).
//
// Steam's window is a web view, steamwebhelper.exe, that talks to steam.exe over a socket on
// this Mac — and steam.exe only takes a connection whose owner is its own web helper. On
// 4 October every one was turned away ("WebUITransport: Connection rejected"), while the sign-in
// window sent "UI Request: connect" over and over and never signed in.
//
// Wine before 10 builds Windows' connection table in winedevice, from net.inet.tcp.pcblist, and
// finds each connection's owner by matching it against every Wine process's sockets. Neither
// works on this macOS, measured on 7 October:
// - the list now holds only the asking process's own connections: 27 open on the Mac, 0 listed
//   to a program that had none — so winedevice, which has none, lists nothing, and under Mythic
//   Engine 3.0 GetExtendedTcpTable gave 0 rows with three connections open in the program asking;
// - and where it does list one, it carries the socket's id cut to 32 bits (xsocket.so_pcb is a
//   u_int32_t) while proc_pidfdinfo gives all 64 — 0xdc75df64 against 0xbfc33b25dc75df64 for the
//   same socket — so even then no owner would ever match.
// Wine 10 keeps both in its own server instead. Here, for the Wine before it, the list is made
// from the sockets of this user's Wine programs, which proc_pidfdinfo still reads (476 of 476
// processes), in the kernel's own layout, with each id cut the way the list cuts it — and the id
// proc_pidfdinfo hands Wine is cut the same way, so the owner matches. For Steam, and for any
// other launcher that checks who is connecting to it.
namespace {

std::atomic<int> g_ownerFix{-1};     // -1 not looked at yet
std::atomic<bool> g_listNoted{false};

bool ownerFix() {
    int on = g_ownerFix.load(std::memory_order_relaxed);
    if (on < 0) {
        const char* e = getenv("ANVIL_TCP_OWNER_FIX");
        on = (e && e[0] == '1') ? 1 : 0;
        g_ownerFix.store(on, std::memory_order_relaxed);
    }
    return on == 1;
}

void noteList(size_t rows) {
    if (g_listNoted.exchange(true)) return;
    const char* path = getenv("ANVIL_LOG");
    if (!path) return;
    if (FILE* f = fopen(path, "a")) {
        fprintf(f, "[anvil] connections (pid %d): Windows asked for this Mac's connections — given the %zu of "
                   "its Wine programs, each with its owner, which macOS no longer lists to Wine 9 itself; so a "
                   "launcher such as Steam can tell its own window is the one connecting\n", getpid(), rows);
        fclose(f);
    }
}

/// One of this user's Wine programs: what Wine runs, wherever this engine copied it to.
bool winePath(pid_t pid) {
    if (pid == getpid()) return true;
    char path[PROC_PIDPATHINFO_MAXSIZE];
    if (proc_pidpath(pid, path, sizeof path) <= 0) return false;
    return strcasestr(path, "wine") || strstr(path, "/Anvil Game.app/");
}

/// Every TCP socket of this user's Wine programs, as net.inet.tcp.pcblist rows.
std::vector<struct xtcpcb> wineConnections() {
    std::vector<struct xtcpcb> rows;
    int count = proc_listallpids(nullptr, 0);
    if (count <= 0) return rows;
    std::vector<pid_t> pids(count + 64);
    count = proc_listallpids(pids.data(), (int)(pids.size() * sizeof(pid_t)));
    const uid_t me = getuid();
    std::vector<uint64_t> seen;
    for (int i = 0; i < count; i++) {
        struct proc_bsdshortinfo info;
        if (proc_pidinfo(pids[i], PROC_PIDT_SHORTBSDINFO, 0, &info, sizeof info) != (int)sizeof info) continue;
        if (info.pbsi_uid != me || !winePath(pids[i])) continue;
        int size = proc_pidinfo(pids[i], PROC_PIDLISTFDS, 0, nullptr, 0);
        if (size <= 0) continue;
        std::vector<struct proc_fdinfo> fds(size / sizeof(struct proc_fdinfo) + 16);
        size = proc_pidinfo(pids[i], PROC_PIDLISTFDS, 0, fds.data(), (int)(fds.size() * sizeof(struct proc_fdinfo)));
        for (int j = 0; j < size / (int)sizeof(struct proc_fdinfo); j++) {
            if (fds[j].proc_fdtype != PROX_FDTYPE_SOCKET) continue;
            struct socket_fdinfo s;
            if (proc_pidfdinfo(pids[i], fds[j].proc_fd, PROC_PIDFDSOCKETINFO, &s, sizeof s) != (int)sizeof s) continue;
            if (s.psi.soi_kind != SOCKINFO_TCP) continue;
            // A socket handed down to a child shows in both.
            if (std::find(seen.begin(), seen.end(), s.psi.soi_pcb) != seen.end()) continue;
            seen.push_back(s.psi.soi_pcb);
            const struct in_sockinfo& in = s.psi.soi_proto.pri_tcp.tcpsi_ini;
            struct xtcpcb row;
            memset(&row, 0, sizeof row);
            row.xt_len = sizeof row;
            row.xt_inp.inp_vflag = in.insi_vflag;
            row.xt_inp.inp_lport = (u_short)in.insi_lport;    // network order, as the kernel keeps it
            row.xt_inp.inp_fport = (u_short)in.insi_fport;
            if (in.insi_vflag & INP_IPV4) {
                row.xt_inp.inp_laddr = in.insi_laddr.ina_46.i46a_addr4;
                row.xt_inp.inp_faddr = in.insi_faddr.ina_46.i46a_addr4;
            } else {
                row.xt_inp.in6p_laddr = in.insi_laddr.ina_6;
                row.xt_inp.in6p_faddr = in.insi_faddr.ina_6;
            }
            row.xt_tp.t_state = s.psi.soi_proto.pri_tcp.tcpsi_state;
            row.xt_socket.xso_protocol = IPPROTO_TCP;
            row.xt_socket.xso_family = s.psi.soi_family;
            row.xt_socket.so_pcb = (uint32_t)s.psi.soi_pcb;
            rows.push_back(row);
        }
    }
    return rows;
}

/// A header, the rows, and the closing header the list ends with — as many rows as fit.
size_t writeList(const std::vector<struct xtcpcb>& rows, void* out, size_t room) {
    const size_t fixed = 2 * sizeof(struct xinpgen);
    const size_t n = room < fixed ? 0 : std::min(rows.size(), (room - fixed) / sizeof(struct xtcpcb));
    char* p = static_cast<char*>(out);
    struct xinpgen head;
    memset(&head, 0, sizeof head);
    head.xig_len = sizeof head;
    head.xig_count = (u_int)n;
    head.xig_gen = 1;           // every row's generation, 0, is older: none is skipped as freed
    memcpy(p, &head, sizeof head);
    if (n) memcpy(p + sizeof head, rows.data(), n * sizeof(struct xtcpcb));
    memcpy(p + sizeof head + n * sizeof(struct xtcpcb), &head, sizeof head);
    return fixed + n * sizeof(struct xtcpcb);
}

} // namespace

extern "C" int anvil_sysctl(int* name, u_int namelen, void* oldp, size_t* oldlenp, void* newp, size_t newlen) {
    if (namelen == 4 && name && name[0] == CTL_NET && name[1] == PF_INET && name[2] == IPPROTO_TCP
        && name[3] == TCPCTL_PCBLIST && !newp && oldlenp && ownerFix()) {
        const std::vector<struct xtcpcb> rows = wineConnections();
        const size_t whole = 2 * sizeof(struct xinpgen) + rows.size() * sizeof(struct xtcpcb);
        if (!oldp) {
            // Asked how much room it needs: room for a few more, as Wine asks again to fill it.
            *oldlenp = whole + 32 * sizeof(struct xtcpcb);
            return 0;
        }
        *oldlenp = writeList(rows, oldp, *oldlenp);
        noteList(rows.size());
        return 0;
    }
    return sysctl(name, namelen, oldp, oldlenp, newp, newlen);
}

extern "C" int anvil_proc_pidfdinfo(int pid, int fd, int flavor, void* buffer, int size) {
    const int n = proc_pidfdinfo(pid, fd, flavor, buffer, size);
    if (flavor == PROC_PIDFDSOCKETINFO && buffer && n >= (int)sizeof(struct socket_fdinfo) && ownerFix())
        static_cast<struct socket_fdinfo*>(buffer)->psi.soi_pcb &= 0xffffffffull;
    return n;
}

// Interposed for every image in each Wine process, as dlsym is in anvil_input.mm. Each
// replacement calls the real function by name: inside the image doing the interposing,
// dyld leaves calls to the originals alone.
__attribute__((used, section("__DATA,__interpose")))
static struct { void* replacement; void* original; } kNetInterposers[] = {
    { reinterpret_cast<void*>(&anvil_sysctl), reinterpret_cast<void*>(&sysctl) },
    { reinterpret_cast<void*>(&anvil_proc_pidfdinfo), reinterpret_cast<void*>(&proc_pidfdinfo) },
    { reinterpret_cast<void*>(&anvil_connect), reinterpret_cast<void*>(&connect) },
    { reinterpret_cast<void*>(&anvil_sendto), reinterpret_cast<void*>(&sendto) },
    { reinterpret_cast<void*>(&anvil_sendmsg), reinterpret_cast<void*>(&sendmsg) },
    { reinterpret_cast<void*>(&anvil_getaddrinfo), reinterpret_cast<void*>(&getaddrinfo) },
    { reinterpret_cast<void*>(&anvil_gethostbyname), reinterpret_cast<void*>(&gethostbyname) },
};

// libanvil's connection table for Wine before 10 (anvil_net.mm), checked without Wine.
//
// macOS lists in net.inet.tcp.pcblist only the asking program's own connections, and cuts each
// socket's id to 32 bits there while proc_pidfdinfo gives 64 — so Wine 9's winedevice listed
// none, and could match no owner. Run with libanvil inserted and ANVIL_TCP_OWNER_FIX=1:
//   DYLD_INSERT_LIBRARIES=…/libanvil.dylib ANVIL_TCP_OWNER_FIX=1 ./wine_tcp_owner_test
// A child (named like a Wine program: this file's name has "wine" in it) holds a connection;
// the parent must find both ends in the list, with ids that match the child's sockets as
// proc_pidfdinfo gives them. Needs local sockets, so not inside a sandbox that forbids them.
#include <arpa/inet.h>
#include <libproc.h>
#include <netinet/in.h>
#include <netinet/in_pcb.h>
#include <netinet/tcp_var.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/proc_info.h>
#include <sys/socket.h>
#include <sys/sysctl.h>
#include <sys/wait.h>
#include <unistd.h>

int main(void) {
    int ready[2];
    if (pipe(ready) != 0) return 2;
    pid_t child = fork();
    if (child == 0) {
        int ls = socket(AF_INET, SOCK_STREAM, 0);
        struct sockaddr_in a = {0};
        a.sin_family = AF_INET;
        a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        if (bind(ls, (void*)&a, sizeof a) != 0 || listen(ls, 1) != 0) _exit(3);
        socklen_t l = sizeof a;
        getsockname(ls, (void*)&a, &l);
        int c = socket(AF_INET, SOCK_STREAM, 0);
        if (connect(c, (void*)&a, sizeof a) != 0) _exit(4);
        int s = accept(ls, NULL, NULL);
        unsigned short port = ntohs(a.sin_port);
        write(ready[1], &port, sizeof port);
        pause();
        (void)s;
        _exit(0);
    }
    unsigned short port = 0;
    if (read(ready[0], &port, sizeof port) != sizeof port) { printf("FAIL: the child couldn't open a connection\n"); return 1; }

    int mib[] = {CTL_NET, PF_INET, IPPROTO_TCP, TCPCTL_PCBLIST};
    size_t len = 0;
    if (sysctl(mib, 4, NULL, &len, NULL, 0) != 0) { perror("sysctl"); kill(child, SIGKILL); return 1; }
    char* buf = malloc(len);
    if (sysctl(mib, 4, buf, &len, NULL, 0) != 0) { perror("sysctl"); kill(child, SIGKILL); return 1; }
    int rows = 0, ours = 0, matched = 0;
    struct xinpgen* head = (void*)buf;
    for (struct xinpgen* x = (void*)((char*)head + head->xig_len); x->xig_len > sizeof(struct xinpgen);
         x = (void*)((char*)x + x->xig_len)) {
        struct xtcpcb* t = (void*)x;
        rows++;
        if (ntohs(t->xt_inp.inp_lport) != port && ntohs(t->xt_inp.inp_fport) != port) continue;
        ours++;
        // As Wine does: the owner is whoever has a socket whose id is this row's.
        int size = proc_pidinfo(child, PROC_PIDLISTFDS, 0, NULL, 0);
        struct proc_fdinfo* fds = malloc(size);
        size = proc_pidinfo(child, PROC_PIDLISTFDS, 0, fds, size);
        for (int i = 0; i < size / (int)sizeof *fds; i++) {
            if (fds[i].proc_fdtype != PROX_FDTYPE_SOCKET) continue;
            struct socket_fdinfo si;
            if (proc_pidfdinfo(child, fds[i].proc_fd, PROC_PIDFDSOCKETINFO, &si, sizeof si) != sizeof si) continue;
            if (si.psi.soi_pcb == (uint64_t)t->xt_socket.so_pcb) { matched++; break; }
        }
        free(fds);
    }
    kill(child, SIGKILL);
    waitpid(child, NULL, 0);
    printf("%d rows; %d of the child's connection on port %u; %d with an owner found\n", rows, ours, port, matched);
    if (ours >= 3 && matched == ours) { printf("PASS\n"); return 0; }
    printf("FAIL\n");
    return 1;
}

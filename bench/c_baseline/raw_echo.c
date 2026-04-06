/*
 * raw_echo.c — Raw C kqueue echo server baseline.
 *
 * Single-threaded kqueue event loop. No framework, no abstraction.
 * This is the theoretical minimum overhead for a kqueue echo server.
 *
 * Usage: ./raw_echo <port>
 * Compile: cc -O2 -o raw_echo raw_echo.c
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/event.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <fcntl.h>
#include <errno.h>

#define MAX_EVENTS 256
#define BUF_SIZE 4096

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "Usage: %s <port>\n", argv[0]);
        return 1;
    }
    int port = atoi(argv[1]);

    int listen_fd = socket(AF_INET, SOCK_STREAM, 0);
    int opt = 1;
    setsockopt(listen_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    struct sockaddr_in addr = {
        .sin_family = AF_INET,
        .sin_port = htons(port),
        .sin_addr.s_addr = htonl(INADDR_LOOPBACK),
    };
    bind(listen_fd, (struct sockaddr *)&addr, sizeof(addr));
    listen(listen_fd, 256);
    fcntl(listen_fd, F_SETFL, fcntl(listen_fd, F_GETFL) | O_NONBLOCK);

    int kq = kqueue();
    struct kevent ev;
    EV_SET(&ev, listen_fd, EVFILT_READ, EV_ADD, 0, 0, NULL);
    kevent(kq, &ev, 1, NULL, 0, NULL);

    fprintf(stderr, "Raw C kqueue echo on :%d\n", port);

    struct kevent events[MAX_EVENTS];
    char buf[BUF_SIZE];

    while (1) {
        int n = kevent(kq, NULL, 0, events, MAX_EVENTS, NULL);
        for (int i = 0; i < n; i++) {
            int fd = (int)events[i].ident;
            if (fd == listen_fd) {
                while (1) {
                    int conn = accept(listen_fd, NULL, NULL);
                    if (conn < 0) break;
                    fcntl(conn, F_SETFL, fcntl(conn, F_GETFL) | O_NONBLOCK);
                    int one = 1;
                    setsockopt(conn, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
                    EV_SET(&ev, conn, EVFILT_READ, EV_ADD, 0, 0, NULL);
                    kevent(kq, &ev, 1, NULL, 0, NULL);
                }
            } else if (events[i].flags & EV_EOF) {
                close(fd);
            } else {
                ssize_t r = read(fd, buf, BUF_SIZE);
                if (r > 0) {
                    write(fd, buf, r);
                } else if (r == 0) {
                    close(fd);
                }
            }
        }
    }
}

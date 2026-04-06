/*
 * bench_client.c — Multi-threaded echo benchmark client.
 *
 * Spawns NUM_CLIENTS threads, each sending MSGS_PER_CLIENT synchronous
 * echo round-trips. Reports aggregate throughput and latency.
 *
 * Usage: ./bench_client <port>
 * Compile: cc -O2 -pthread -o bench_client bench_client.c
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/time.h>

#define NUM_CLIENTS 50
#define MSGS_PER_CLIENT 10000
#define MSG "hello reshift kqueue echo!\n"
#define MSG_LEN 27

typedef struct {
    int port;
    long msgs_ok;
    long errors;
    double elapsed;
} client_result_t;

static double now() {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return tv.tv_sec + tv.tv_usec / 1e6;
}

static void *client_fn(void *arg) {
    client_result_t *r = (client_result_t *)arg;
    int port = r->port;

    int sock = socket(AF_INET, SOCK_STREAM, 0);
    int one = 1;
    setsockopt(sock, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));

    struct sockaddr_in addr = {
        .sin_family = AF_INET,
        .sin_port = htons(port),
        .sin_addr.s_addr = htonl(INADDR_LOOPBACK),
    };

    if (connect(sock, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        r->errors = 1;
        close(sock);
        return NULL;
    }

    double start = now();
    char buf[4096];

    for (int i = 0; i < MSGS_PER_CLIENT; i++) {
        /* Send */
        if (write(sock, MSG, MSG_LEN) != MSG_LEN) { r->errors++; break; }

        /* Receive echo */
        int got = 0;
        while (got < MSG_LEN) {
            int n = read(sock, buf + got, MSG_LEN - got);
            if (n <= 0) { r->errors++; goto done; }
            got += n;
        }
        r->msgs_ok++;
    }
done:
    r->elapsed = now() - start;
    close(sock);
    return NULL;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "Usage: %s <port>\n", argv[0]);
        return 1;
    }
    int port = atoi(argv[1]);

    client_result_t results[NUM_CLIENTS] = {};
    pthread_t threads[NUM_CLIENTS];

    double wall_start = now();

    for (int i = 0; i < NUM_CLIENTS; i++) {
        results[i].port = port;
        pthread_create(&threads[i], NULL, client_fn, &results[i]);
    }
    for (int i = 0; i < NUM_CLIENTS; i++) {
        pthread_join(threads[i], NULL);
    }

    double wall = now() - wall_start;

    long total_ok = 0, total_err = 0;
    for (int i = 0; i < NUM_CLIENTS; i++) {
        total_ok += results[i].msgs_ok;
        total_err += results[i].errors;
    }

    printf("  %d clients x %d msgs = %ld sent, %ld ok, %ld errors\n",
           NUM_CLIENTS, MSGS_PER_CLIENT, (long)NUM_CLIENTS * MSGS_PER_CLIENT, total_ok, total_err);
    printf("  Wall: %.3fs\n", wall);
    printf("  Throughput: %.0f msg/sec\n", total_ok / wall);
    printf("  Avg round-trip: %.1f us\n", wall / total_ok * 1e6 * NUM_CLIENTS);

    return 0;
}

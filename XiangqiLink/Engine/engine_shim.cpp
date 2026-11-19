// engine_shim.cpp —— 把 Pikafish 的 UCI 主循环包成 C 接口
//
// Pikafish(Stockfish 系) 新版入口是 Stockfish::UCIEngine：
//     auto cli = CommandLine(argc, argv);
//     auto uci = std::make_unique<UCIEngine>(std::move(cli));
//     Tune::init(uci->engine_options());
//     uci->loop();
// 我们用管道把 fd 0/1 接管过来，于是在另一个线程里跑 loop() 就能收发 UCI 文本。

#include "engine_shim.h"

#include <unistd.h>
#include <pthread.h>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <cstdint>
#include <string>
#include <thread>
#include <memory>
#include <utility>
#include <iostream>

#include "attacks.h"
#include "misc.h"
#include "position.h"
#include "tune.h"
#include "uci.h"

static int          g_in_fd   = -1;
static int          g_out_fd  = -1;
static xq_line_cb   g_cb      = nullptr;
static void        *g_ctx     = nullptr;
static volatile int g_started = 0;

static void *reader_thread(void *) {
    FILE *fp = fdopen(g_out_fd, "r");
    if (!fp) return nullptr;
    char buf[16384];
    while (fgets(buf, sizeof(buf), fp)) {
        size_t n = strlen(buf);
        while (n > 0 && (buf[n - 1] == '\n' || buf[n - 1] == '\r')) buf[--n] = '\0';
        xq_line_cb cb = g_cb;
        if (cb && n > 0) cb(buf, g_ctx);
    }
    return nullptr;
}

static void send_cmd(const char *s) {
    if (g_in_fd >= 0) {
        ssize_t r = ::write(g_in_fd, s, strlen(s));
        (void)r;
    }
}

extern "C" void xq_set_cb(xq_line_cb cb, void *ctx) {
    g_cb  = cb;
    g_ctx = ctx;
}

extern "C" int xq_start(const char *nnue_path, int threads, int hash_mb) {
    if (g_started) return 0;

    int in_pipe[2], out_pipe[2];
    if (::pipe(in_pipe) != 0 || ::pipe(out_pipe) != 0) return -1;

    if (::dup2(in_pipe[0], STDIN_FILENO) < 0)   return -1;
    if (::dup2(out_pipe[1], STDOUT_FILENO) < 0) return -1;
    ::close(in_pipe[0]);
    ::close(out_pipe[1]);

    std::cout.setf(std::ios::unitbuf);
    std::cout.flush();

    g_in_fd   = in_pipe[1];
    g_out_fd  = out_pipe[0];
    g_started = 1;

    std::thread([] {
        using namespace Stockfish;
        static char a0[] = "pikafish";
        static char *argv[] = { a0, nullptr };

        std::cout << engine_info() << std::endl;
        Attacks::init();

        auto cli = CommandLine(1, argv);
        auto uci = std::make_unique<UCIEngine>(std::move(cli));
        Tune::init(uci->engine_options());
        uci->loop();
    }).detach();

    pthread_t th;
    if (pthread_create(&th, nullptr, reader_thread, nullptr) == 0)
        pthread_detach(th);

    send_cmd("uci\n");

    if (nnue_path && *nnue_path) {
        std::string c = "setoption name EvalFile value ";
        c += nnue_path;
        c += "\n";
        send_cmd(c.c_str());
    }

    char tmp[96];
    snprintf(tmp, sizeof(tmp), "setoption name Threads value %d\n", threads > 0 ? threads : 1);
    send_cmd(tmp);
    snprintf(tmp, sizeof(tmp), "setoption name Hash value %d\n", hash_mb > 0 ? hash_mb : 64);
    send_cmd(tmp);

    send_cmd("isready\n");
    send_cmd("ucinewgame\n");
    return 0;
}

extern "C" int xq_go(const char *fen, int depth, int movetime_ms) {
    if (!g_started || !fen) return -1;

    std::string cmd = "position fen ";
    cmd += fen;
    cmd += "\n";

    char go[96];
    if (movetime_ms > 0)
        snprintf(go, sizeof(go), "go movetime %d\n", movetime_ms);
    else
        snprintf(go, sizeof(go), "go depth %d\n", depth > 0 ? depth : 12);
    cmd += go;

    send_cmd(cmd.c_str());
    return 0;
}

extern "C" void xq_stop(void) {
    send_cmd("stop\n");
}

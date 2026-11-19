#ifndef ENGINE_SHIM_H
#define ENGINE_SHIM_H

#ifdef __cplusplus
extern "C" {
#endif

/* 每读到引擎一行输出就回调一次（在独立的读线程里） */
typedef void (*xq_line_cb)(const char *line, void *ctx);

/* 启动引擎（内部用管道把 stdin/stdout 接到 Pikafish 的 UCI::loop）
 * nnue_path: 必须传绝对路径，指向 App 包里的 pikafish.nnue
 * 返回 0 成功，-1 失败 */
int  xq_start(const char *nnue_path, int threads, int hash_mb);

/* 让引擎算一步棋。fen 用标准象棋 FEN，depth/movetime 任一 >0 即可 */
int  xq_go(const char *fen, int depth, int movetime_ms);

/* 立即停止当前搜索 */
void xq_stop(void);

/* 设置输出回调 */
void xq_set_cb(xq_line_cb cb, void *ctx);

#ifdef __cplusplus
}
#endif

#endif

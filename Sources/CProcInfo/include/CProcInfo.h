#ifndef CPROCINFO_H
#define CPROCINFO_H

#include <sys/types.h>
#include <sys/cdefs.h>

__BEGIN_DECLS

/// 一个进程的只读快照。字符串缓冲区由调用方提供并清零；
/// 读不到的字段保持为空 / 0，不视为失败。
typedef struct {
    pid_t pid;
    pid_t ppid;
    uid_t uid;
    unsigned long long rss_bytes;
    unsigned long long cpu_ns;
    long long start_sec;
    char name[64];
    char path[4096];
    char cwd[4096];
} an_proc_info_t;

/// 返回写入的 pid 数量；capacity 为 pids 数组能容纳的元素个数。
int an_proc_list(pid_t *pids, int capacity);

/// 返回 0 成功；-1 表示进程已退出或不可读。
int an_proc_info(pid_t pid, an_proc_info_t *out);

/// 读取命令行（空格连接并截断）。只对可能是 Agent 的进程调用；
/// 缓冲区由实现复用，调用方不得持久化内容。
int an_proc_args(pid_t pid, char *out, int out_len);

__END_DECLS

#endif

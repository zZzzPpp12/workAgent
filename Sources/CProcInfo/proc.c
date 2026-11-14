#include "CProcInfo.h"

#include <libproc.h>
#include <sys/proc_info.h>
#include <sys/sysctl.h>
#include <sys/types.h>
#include <mach/mach_time.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void copy_string(char *dst, size_t len, const char *src) {
    if (dst == NULL || len == 0) return;
    if (src == NULL) {
        dst[0] = '\0';
        return;
    }
    strlcpy(dst, src, len);
}

int an_proc_list(pid_t *pids, int capacity) {
    if (pids == NULL) return proc_listallpids(NULL, 0);
    if (capacity <= 0) return 0;
    return proc_listallpids(pids, capacity * (int)sizeof(pid_t));
}

/// 读取进程工作目录；读不到时保持空串。
static void read_cwd(pid_t pid, char *out, size_t len) {
    struct proc_vnodepathinfo info;
    memset(&info, 0, sizeof(info));
    if (proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, sizeof(info)) == sizeof(info)) {
        copy_string(out, len, info.pvi_cdir.vip_path);
    }
}

/// 读取命令行（KERN_PROCARGS2），参数以空格连接并截断；
/// 仅用于本机会话匹配，调用方不得持久化。缓冲区按线程复用，避免每个进程 malloc。
int an_proc_args(pid_t pid, char *out, int out_len) {
    if (out == NULL || out_len <= 0) return -1;
    out[0] = '\0';

    static _Thread_local char *buffer = NULL;
    static _Thread_local int buffer_size = 0;
    static _Thread_local int argmax = 0;

    int mib[3] = {CTL_KERN, KERN_PROCARGS2, pid};
    if (argmax <= 0) {
        int query[2] = {CTL_KERN, KERN_ARGMAX};
        size_t size = sizeof(argmax);
        if (sysctl(query, 2, &argmax, &size, NULL, 0) != 0 || argmax <= 0) {
            argmax = 1 << 18;
        }
    }

    if (buffer == NULL || buffer_size < argmax) {
        char *next = realloc(buffer, (size_t)argmax);
        if (next == NULL) return -1;
        buffer = next;
        buffer_size = argmax;
    }

    size_t size = (size_t)argmax;
    if (sysctl(mib, 3, buffer, &size, NULL, 0) != 0 || size < sizeof(int)) {
        return -1;
    }

    int argc = 0;
    memcpy(&argc, buffer, sizeof(int));
    char *p = buffer + sizeof(int);
    char *end = buffer + size;

    while (p < end && *p != '\0') p++;   // 可执行文件路径
    while (p < end && *p == '\0') p++;   // 填充的 NUL

    size_t n = 0;
    for (int i = 0; i < argc && p < end; i++) {
        size_t len = strnlen(p, (size_t)(end - p));
        if (n + 1 >= (size_t)out_len) break;
        if (n > 0) out[n++] = ' ';
        size_t room = (size_t)out_len - 1 - n;
        size_t take = len < room ? len : room;
        memcpy(out + n, p, take);
        n += take;
        p += len + 1;
    }
    out[n] = '\0';
    return (int)n;
}

int an_proc_info(pid_t pid, an_proc_info_t *out) {
    if (out == NULL || pid <= 0) return -1;
    memset(out, 0, sizeof(*out));
    out->pid = pid;

    struct proc_bsdinfo bsd;
    memset(&bsd, 0, sizeof(bsd));
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, sizeof(bsd)) != sizeof(bsd)) {
        return -1;
    }

    out->ppid = (pid_t)bsd.pbi_ppid;
    out->uid = bsd.pbi_uid;
    out->start_sec = (long long)bsd.pbi_start_tvsec;
    copy_string(out->name, sizeof(out->name), bsd.pbi_comm);

    struct proc_taskinfo task;
    memset(&task, 0, sizeof(task));
    if (proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, sizeof(task)) == sizeof(task)) {
        static mach_timebase_info_data_t timebase;
        if (timebase.denom == 0) {
            mach_timebase_info(&timebase);
        }
        unsigned long long total = task.pti_total_user + task.pti_total_system;
        out->rss_bytes = task.pti_resident_size;
        if (timebase.denom != 0) {
            out->cpu_ns = total * timebase.numer / timebase.denom;
        }
    }

    if (proc_pidpath(pid, out->path, (uint32_t)sizeof(out->path)) <= 0) {
        out->path[0] = '\0';
    }
    read_cwd(pid, out->cwd, sizeof(out->cwd));
    return 0;
}

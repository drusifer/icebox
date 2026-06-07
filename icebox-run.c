/* icebox-run — Landlock ABI v4 sandbox wrapper.
 * Usage: icebox-run <cmd> [args...]
 * Restricts: FS writes to /workspace+/tmp; TCP connect to egress.ports in /icebox/config.yaml.
 * If Landlock is unavailable (ABI < 4), executes the command unrestricted with a warning.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <unistd.h>

/* ── Inline Landlock ABI v4 definitions (avoids linux-libc-dev dependency) ── */

struct ll_ruleset_attr {
    uint64_t handled_access_fs;
    uint64_t handled_access_net;  /* ABI v4 */
};

struct ll_path_beneath {
    uint64_t allowed_access;
    int32_t  parent_fd;
} __attribute__((packed));

struct ll_net_port {
    uint64_t allowed_access;
    uint64_t port;
};

#define LL_RULE_PATH_BENEATH    1
#define LL_RULE_NET_PORT        2
#define LL_CREATE_VERSION_FLAG  (1U << 0)

#define FS_EXEC     (1ULL <<  0)
#define FS_WR_FILE  (1ULL <<  1)
#define FS_RD_FILE  (1ULL <<  2)
#define FS_RD_DIR   (1ULL <<  3)
#define FS_RM_DIR   (1ULL <<  4)
#define FS_RM_FILE  (1ULL <<  5)
#define FS_MK_CHAR  (1ULL <<  6)
#define FS_MK_DIR   (1ULL <<  7)
#define FS_MK_REG   (1ULL <<  8)
#define FS_MK_FIFO  (1ULL <<  9)
#define FS_MK_BLK   (1ULL << 10)
#define FS_MK_SYM   (1ULL << 11)
#define FS_REFER    (1ULL << 12)  /* ABI v2 */
#define FS_TRUNC    (1ULL << 13)  /* ABI v3 */

#define NET_CONNECT_TCP (1ULL << 1)

#define FS_RW_ALL (FS_EXEC|FS_WR_FILE|FS_RD_FILE|FS_RD_DIR|FS_RM_DIR|FS_RM_FILE| \
                   FS_MK_CHAR|FS_MK_DIR|FS_MK_REG|FS_MK_FIFO|FS_MK_BLK|FS_MK_SYM| \
                   FS_REFER|FS_TRUNC)

#define FS_RO     (FS_EXEC|FS_RD_FILE|FS_RD_DIR|FS_REFER)

/* Compile-time layout checks — kernel ABI requires exact sizes */
_Static_assert(sizeof(struct ll_ruleset_attr) == 16, "ll_ruleset_attr must be 16 bytes");
_Static_assert(sizeof(struct ll_path_beneath) == 12, "ll_path_beneath must be 12 bytes (packed)");
_Static_assert(sizeof(struct ll_net_port)     == 16, "ll_net_port must be 16 bytes");

/* Syscall wrappers — numbers are stable across x86_64 and arm64 */
static inline int ll_create(const struct ll_ruleset_attr *a, size_t sz, uint32_t flags) {
    return (int)syscall(444, a, sz, flags);
}
static inline int ll_add_rule(int rfd, int rt, const void *ra, uint32_t flags) {
    return (int)syscall(445, rfd, rt, ra, flags);
}
static inline int ll_restrict(int rfd, uint32_t flags) {
    return (int)syscall(446, rfd, flags);
}

/* ── Config parser: extract egress.ports integers from YAML ── */

static int parse_ports(const char *path, int *ports, int max) {
    FILE *f = fopen(path, "r");
    if (!f) return 0;
    char line[256];
    int in_egress = 0, in_ports = 0, count = 0;
    while (fgets(line, sizeof(line), f) && count < max) {
        line[strcspn(line, "\n")] = 0;
        if (strcmp(line, "egress:") == 0) { in_egress = 1; in_ports = 0; continue; }
        if (in_egress && strncmp(line, "  ports:", 8) == 0) {
            in_ports = 1;
            char *lb = strchr(line, '[');  /* inline list: ports: [443, 80] */
            if (lb) {
                char *p = lb + 1;
                while (*p && *p != ']' && count < max) {
                    char *end;
                    int port = (int)strtol(p, &end, 10);
                    if (end != p && port > 0) ports[count++] = port;
                    p = end;
                    while (*p == ' ' || *p == ',') p++;
                }
                break;
            }
            continue;
        }
        if (in_ports && strncmp(line, "  - ", 4) == 0) {
            int port = atoi(line + 4);
            if (port > 0) ports[count++] = port;
            continue;
        }
        if ((in_egress || in_ports) && line[0] != ' ' && line[0] != '\0' && line[0] != '#')
            in_egress = in_ports = 0;
    }
    fclose(f);
    return count;
}

/* ── FS rule helper: open path and add beneath-rule (silently skips absent paths) ── */

static void add_fs(int rfd, const char *path, uint64_t access) {
    int fd = open(path, O_PATH | O_CLOEXEC);
    if (fd < 0) return;
    struct ll_path_beneath rule = { .allowed_access = access, .parent_fd = fd };
    ll_add_rule(rfd, LL_RULE_PATH_BENEATH, &rule, 0);
    close(fd);
}

/* ── Main ── */

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "Usage: icebox-run <cmd> [args...]\n");
        return 1;
    }

    /* Check ABI version — require v4 for network restrictions */
    int abi = ll_create(NULL, 0, LL_CREATE_VERSION_FLAG);
    if (abi < 4) {
        fprintf(stderr, "icebox-run: Landlock ABI v4 required (got %d); running without sandbox.\n", abi);
        execvp(argv[1], argv + 1);
        perror(argv[1]);
        return 127;
    }

    /* Parse allowed TCP ports */
    int ports[64];
    int nports = parse_ports("/icebox/config.yaml", ports, 64);

    /* Create ruleset handling both FS and net */
    struct ll_ruleset_attr rs = {
        .handled_access_fs  = FS_RW_ALL,
        .handled_access_net = NET_CONNECT_TCP,
    };
    int rfd = ll_create(&rs, sizeof(rs), 0);
    if (rfd < 0) { perror("icebox-run: landlock_create_ruleset"); return 1; }

    /* FS: full RW for agent work directories */
    add_fs(rfd, "/workspace", FS_RW_ALL);
    add_fs(rfd, "/tmp",       FS_RW_ALL);
    /* FS: read-only for system paths (needed for dynamic linker and binaries) */
    add_fs(rfd, "/usr",   FS_RO);
    add_fs(rfd, "/lib",   FS_RO);
    add_fs(rfd, "/lib64", FS_RO);
    add_fs(rfd, "/proc",  FS_RO);
    add_fs(rfd, "/dev",   FS_RO);

    /* Net: allow TCP connect only on configured ports */
    for (int i = 0; i < nports; i++) {
        struct ll_net_port nr = { .allowed_access = NET_CONNECT_TCP, .port = (uint64_t)ports[i] };
        ll_add_rule(rfd, LL_RULE_NET_PORT, &nr, 0);
    }

    if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) < 0) { perror("icebox-run: prctl"); return 1; }
    if (ll_restrict(rfd, 0) < 0) { perror("icebox-run: landlock_restrict_self"); return 1; }
    close(rfd);

    execvp(argv[1], argv + 1);
    perror(argv[1]);
    return 127;
}

/*
 * portable-ruby stub
 *
 * Self-extracting loader with content-addressed caching.
 *
 * At runtime:
 *   1. Opens its own executable (via /proc/self/exe or argv[0])
 *   2. Reads the 24-byte footer to find the payload offset and size
 *   3. Derives a cache key from offset+size (unique per build)
 *   4. Checks ~/.cache/portable-ruby/<key>/ for existing extraction
 *   5. If not cached, extracts payload there
 *   6. Execs the bundled Ruby interpreter with the entry script
 *
 * On Linux, Ruby is exec'd through the bundled musl dynamic linker
 * (lib/ld-musl-*.so.1) so the binary works on ANY Linux distro
 * regardless of the host's libc (glibc, musl, etc).
 *
 * Footer layout (last 24 bytes of the binary):
 *   [8 bytes] payload offset (little-endian uint64)
 *   [8 bytes] payload size   (little-endian uint64)
 *   [8 bytes] magic          "CRUBY\x00\x01\x00"
 *
 * Env vars:
 *   PORTABLE_RUBY_CACHE    Override cache directory
 *   PORTABLE_RUBY_NO_CACHE Set to 1 to extract to tmpdir with cleanup
 *   PORTABLE_RUBY_VERBOSE  Set to 1 for debug messages
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <sys/file.h>
#include <errno.h>
#include <limits.h>
#include <fcntl.h>
#include <dirent.h>
#include <glob.h>

#ifdef __linux__
#include <sys/syscall.h>
#endif

#ifdef __APPLE__
#include <mach-o/dyld.h>
#endif

#define FOOTER_SIZE 24
#define MAGIC "CRUBY\x00\x01\x00"
#define MAGIC_SIZE 8

static const char PAYLOAD_MAGIC[MAGIC_SIZE] = MAGIC;
static int verbose = 0;

#define LOG(...) do { if (verbose) fprintf(stderr, "portable-ruby: " __VA_ARGS__); } while(0)

static int self_exe_path(char *buf, size_t bufsize) {
#ifdef __linux__
    ssize_t len = readlink("/proc/self/exe", buf, bufsize - 1);
    if (len > 0) {
        buf[len] = '\0';
        return 0;
    }
#endif
#ifdef __APPLE__
    uint32_t size = (uint32_t)bufsize;
    if (_NSGetExecutablePath(buf, &size) == 0) {
        char resolved[PATH_MAX];
        if (realpath(buf, resolved)) {
            strncpy(buf, resolved, bufsize - 1);
            buf[bufsize - 1] = '\0';
        }
        return 0;
    }
#endif
    return -1;
}

static int mkdirp(const char *path, mode_t mode) {
    char tmp[PATH_MAX];
    char *p = NULL;
    size_t len;

    snprintf(tmp, sizeof(tmp), "%s", path);
    len = strlen(tmp);
    if (tmp[len - 1] == '/') tmp[len - 1] = '\0';

    for (p = tmp + 1; *p; p++) {
        if (*p == '/') {
            *p = '\0';
            mkdir(tmp, mode);
            *p = '/';
        }
    }
    return mkdir(tmp, mode);
}

static int make_tmpdir(char *buf, size_t bufsize) {
    const char *tmpdir = getenv("TMPDIR");
    if (!tmpdir) tmpdir = getenv("TMP");
    if (!tmpdir) tmpdir = "/tmp";

    snprintf(buf, bufsize, "%s/portable-ruby.XXXXXX", tmpdir);
    if (mkdtemp(buf) == NULL) {
        perror("mkdtemp");
        return -1;
    }
    return 0;
}

static void cleanup_dir(const char *path) {
    char cmd[PATH_MAX + 16];
    snprintf(cmd, sizeof(cmd), "rm -rf '%s'", path);
    (void)system(cmd);
}

static void build_cache_path(char *buf, size_t bufsize, const char *cache_key) {
    const char *override = getenv("PORTABLE_RUBY_CACHE");
    if (override && override[0]) {
        snprintf(buf, bufsize, "%s", override);
        return;
    }

#ifdef __linux__
    /*
     * On Linux, prefer /dev/shm (tmpfs / shared memory) for the cache.
     * This is RAM-backed on virtually all Linux systems, so extraction
     * and subsequent loads happen entirely in memory with no disk I/O.
     * Skip if /dev/shm is mounted noexec (common in Docker) since we
     * need to exec the loader and mmap Ruby's binary with PROT_EXEC.
     */
    struct stat shm_st;
    if (stat("/dev/shm", &shm_st) == 0 && S_ISDIR(shm_st.st_mode) &&
        access("/dev/shm", W_OK) == 0) {
        /* Check for noexec by trying to create and exec a tiny script */
        int shm_exec_ok = 0;
        char test_path[] = "/dev/shm/.portable-ruby-exec-test";
        int tfd = open(test_path, O_CREAT | O_WRONLY | O_TRUNC, 0755);
        if (tfd >= 0) {
            const char *script = "#!/bin/sh\nexit 0\n";
            if (write(tfd, script, strlen(script)) > 0) {
                close(tfd);
                char test_cmd[PATH_MAX + 32];
                snprintf(test_cmd, sizeof(test_cmd), "%s 2>/dev/null", test_path);
                shm_exec_ok = (system(test_cmd) == 0);
            } else {
                close(tfd);
            }
            unlink(test_path);
        }
        if (shm_exec_ok) {
            snprintf(buf, bufsize, "/dev/shm/portable-ruby/%s", cache_key);
            LOG("/dev/shm supports exec, using RAM cache\n");
            return;
        } else {
            LOG("/dev/shm is noexec, using disk cache\n");
        }
    }
#endif

    const char *xdg = getenv("XDG_CACHE_HOME");
    if (xdg && xdg[0]) {
        snprintf(buf, bufsize, "%s/portable-ruby/%s", xdg, cache_key);
    } else {
        const char *home = getenv("HOME");
        if (!home) home = "/tmp";
        snprintf(buf, bufsize, "%s/.cache/portable-ruby/%s", home, cache_key);
    }
}

static int verify_extraction(const char *dest_dir) {
    char path[PATH_MAX];
    snprintf(path, sizeof(path), "%s/bin/ruby", dest_dir);
    /* Use R_OK not X_OK: /dev/shm is mounted noexec on many systems,
     * but we exec through the bundled musl loader, not directly. */
    return access(path, R_OK);
}

static int extract_payload(const char *exe_path, off_t offset, off_t size,
                           const char *dest_dir) {
    char cmd[PATH_MAX * 2 + 256];

    /*
     * Payload is gzip-compressed tar. Try two dd strategies:
     * 1. GNU dd with iflag=skip_bytes (fast, 64K blocks)
     * 2. POSIX dd with bs=1 (slow but works on macOS/busybox)
     */

    /* Attempt 1: GNU dd (fast) */
    snprintf(cmd, sizeof(cmd),
        "dd if='%s' iflag=skip_bytes,count_bytes bs=65536 skip=%lld count=%lld 2>/dev/null | "
        "gzip -d -c | tar xf - -C '%s' 2>/dev/null",
        exe_path, (long long)offset, (long long)size, dest_dir);
    LOG("trying: fast dd + gzip\n");
    (void)system(cmd);
    if (verify_extraction(dest_dir) == 0) return 0;

    /* Attempt 2: POSIX dd (slow, universal) */
    snprintf(cmd, sizeof(cmd),
        "dd if='%s' bs=1 skip=%lld count=%lld 2>/dev/null | "
        "gzip -d -c | tar xf - -C '%s' 2>/dev/null",
        exe_path, (long long)offset, (long long)size, dest_dir);
    LOG("trying: slow dd + gzip\n");
    (void)system(cmd);
    return verify_extraction(dest_dir);
}

static uint64_t read_le64(const unsigned char *p) {
    return (uint64_t)p[0]
         | (uint64_t)p[1] << 8
         | (uint64_t)p[2] << 16
         | (uint64_t)p[3] << 24
         | (uint64_t)p[4] << 32
         | (uint64_t)p[5] << 40
         | (uint64_t)p[6] << 48
         | (uint64_t)p[7] << 56;
}

#ifdef __linux__
/*
 * Find the bundled musl dynamic linker.
 * It's at <cache_dir>/lib/ld-musl-<arch>.so.1
 * Returns 0 on success and fills loader_path.
 */
static int find_musl_loader(const char *cache_dir, char *loader_path, size_t bufsize) {
    char pattern[PATH_MAX];
    snprintf(pattern, sizeof(pattern), "%s/lib/ld-musl-*.so.1", cache_dir);

    glob_t g;
    int ret = glob(pattern, 0, NULL, &g);
    if (ret == 0 && g.gl_pathc > 0) {
        snprintf(loader_path, bufsize, "%s", g.gl_pathv[0]);
        globfree(&g);
        return 0;
    }
    if (ret != GLOB_NOMATCH) globfree(&g);
    return -1;
}
#endif

int main(int argc, char **argv) {
    char exe_path[PATH_MAX];
    char cache_dir[PATH_MAX];
    char ruby_bin[PATH_MAX];
    char entry_script[PATH_MAX];
    char lock_path[PATH_MAX];
    unsigned char footer[FOOTER_SIZE];

    verbose = (getenv("PORTABLE_RUBY_VERBOSE") != NULL);
    int no_cache = 0;
    const char *nc = getenv("PORTABLE_RUBY_NO_CACHE");
    if (nc && nc[0] == '1') no_cache = 1;

    /* Find our own executable */
    if (self_exe_path(exe_path, sizeof(exe_path)) != 0) {
        if (argv[0] && realpath(argv[0], exe_path) == NULL) {
            fprintf(stderr, "portable-ruby: cannot determine executable path\n");
            return 1;
        }
    }
    LOG("exe: %s\n", exe_path);

    /* Read the footer */
    FILE *fp = fopen(exe_path, "rb");
    if (!fp) {
        fprintf(stderr, "portable-ruby: cannot open %s: %s\n",
                exe_path, strerror(errno));
        return 1;
    }

    if (fseek(fp, -FOOTER_SIZE, SEEK_END) != 0) {
        fprintf(stderr, "portable-ruby: cannot seek to footer\n");
        fclose(fp);
        return 1;
    }

    if (fread(footer, 1, FOOTER_SIZE, fp) != FOOTER_SIZE) {
        fprintf(stderr, "portable-ruby: cannot read footer\n");
        fclose(fp);
        return 1;
    }
    fclose(fp);

    /* Verify magic */
    if (memcmp(footer + 16, PAYLOAD_MAGIC, MAGIC_SIZE) != 0) {
        fprintf(stderr, "portable-ruby: no payload found (bad magic)\n");
        return 1;
    }

    uint64_t payload_offset = read_le64(footer);
    uint64_t payload_size = read_le64(footer + 8);

    char cache_key[33];
    snprintf(cache_key, sizeof(cache_key), "%08llx%08llx",
             (unsigned long long)payload_offset,
             (unsigned long long)payload_size);

    LOG("payload: offset=%llu size=%llu key=%s\n",
        (unsigned long long)payload_offset,
        (unsigned long long)payload_size, cache_key);

    int needs_extract = 1;
    int is_tmpdir = 0;

    if (no_cache) {
        if (make_tmpdir(cache_dir, sizeof(cache_dir)) != 0) return 1;
        is_tmpdir = 1;
        LOG("no-cache mode, extracting to %s\n", cache_dir);
    } else {
        build_cache_path(cache_dir, sizeof(cache_dir), cache_key);
        snprintf(ruby_bin, sizeof(ruby_bin), "%s/bin/ruby", cache_dir);

        if (access(ruby_bin, R_OK) == 0) {
            needs_extract = 0;
            LOG("cache hit: %s\n", cache_dir);
        } else {
            LOG("cache miss, extracting to %s\n", cache_dir);
            mkdirp(cache_dir, 0755);
        }
    }

    if (needs_extract) {
        snprintf(lock_path, sizeof(lock_path), "%s.lock", cache_dir);
        int lock_fd = open(lock_path, O_CREAT | O_WRONLY, 0644);
        if (lock_fd >= 0) {
            if (flock(lock_fd, LOCK_EX) == 0) {
                snprintf(ruby_bin, sizeof(ruby_bin), "%s/bin/ruby", cache_dir);
                if (access(ruby_bin, R_OK) == 0) {
                    needs_extract = 0;
                    LOG("cache populated by another process\n");
                }
            }
        }

        if (needs_extract) {
            int extract_ok = (extract_payload(exe_path, (off_t)payload_offset,
                               (off_t)payload_size, cache_dir) == 0);

#ifdef __linux__
            /* If extraction to /dev/shm failed (e.g. size limit), fall back
             * to ~/.cache on disk. */
            if (!extract_ok && strncmp(cache_dir, "/dev/shm/", 9) == 0) {
                LOG("shm extraction failed, falling back to disk cache\n");
                cleanup_dir(cache_dir);
                if (lock_fd >= 0) { unlink(lock_path); close(lock_fd); lock_fd = -1; }

                /* Rebuild path without /dev/shm preference */
                const char *home = getenv("HOME");
                if (!home) home = "/tmp";
                snprintf(cache_dir, sizeof(cache_dir),
                         "%s/.cache/portable-ruby/%s", home, cache_key);
                mkdirp(cache_dir, 0755);

                snprintf(lock_path, sizeof(lock_path), "%s.lock", cache_dir);
                lock_fd = open(lock_path, O_CREAT | O_WRONLY, 0644);
                if (lock_fd >= 0) flock(lock_fd, LOCK_EX);

                LOG("retrying extraction to %s\n", cache_dir);
                extract_ok = (extract_payload(exe_path, (off_t)payload_offset,
                                             (off_t)payload_size, cache_dir) == 0);
            }
#endif

            if (!extract_ok) {
                fprintf(stderr, "portable-ruby: extraction failed\n");
                if (is_tmpdir) cleanup_dir(cache_dir);
                if (lock_fd >= 0) { unlink(lock_path); close(lock_fd); }
                return 1;
            }
            LOG("extraction complete\n");
        }

        if (lock_fd >= 0) {
            flock(lock_fd, LOCK_UN);
            unlink(lock_path);
            close(lock_fd);
        }
    }

    /* Build paths */
    snprintf(ruby_bin, sizeof(ruby_bin), "%s/bin/ruby", cache_dir);
    snprintf(entry_script, sizeof(entry_script), "%s/entry.rb", cache_dir);

    if (access(ruby_bin, R_OK) != 0) {
        fprintf(stderr, "portable-ruby: ruby not found at %s\n", ruby_bin);
        if (is_tmpdir) cleanup_dir(cache_dir);
        return 1;
    }

    if (access(entry_script, R_OK) != 0) {
        fprintf(stderr, "portable-ruby: entry.rb not found at %s\n", entry_script);
        if (is_tmpdir) cleanup_dir(cache_dir);
        return 1;
    }

    /* Set environment */
    char root_env[PATH_MAX + 32];
    snprintf(root_env, sizeof(root_env), "PORTABLE_RUBY_ROOT=%s", cache_dir);
    putenv(root_env);

    putenv("BUNDLE_GEMFILE=");

    if (is_tmpdir) {
        char cleanup_env[PATH_MAX + 32];
        snprintf(cleanup_env, sizeof(cleanup_env),
                 "PORTABLE_RUBY_CLEANUP=%s", cache_dir);
        putenv(cleanup_env);
    }

    /*
     * On Linux we exec Ruby through the bundled musl dynamic linker.
     * This makes the binary work on ANY Linux distro (glibc, musl, etc.)
     * because we carry our own libc.
     *
     * The invocation is:
     *   /path/to/ld-musl-<arch>.so.1 --library-path /path/to/lib \
     *       /path/to/ruby entry.rb [args...]
     *
     * On macOS we exec Ruby directly (system dyld handles everything).
     */

#ifdef __linux__
    char loader_path[PATH_MAX];
    char lib_path[PATH_MAX];

    if (find_musl_loader(cache_dir, loader_path, sizeof(loader_path)) == 0) {
        snprintf(lib_path, sizeof(lib_path), "%s/lib", cache_dir);
        LOG("using bundled loader: %s\n", loader_path);

        /* argv: loader --library-path <lib> ruby entry.rb [user args...] */
        char *exec_loader = loader_path;
        int new_argc = argc + 5;
        char **new_argv = malloc(sizeof(char *) * (new_argc + 1));
        if (!new_argv) { perror("malloc"); return 1; }

        new_argv[0] = exec_loader;
        new_argv[1] = "--library-path";
        new_argv[2] = lib_path;
        new_argv[3] = ruby_bin;
        new_argv[4] = entry_script;
        for (int i = 1; i < argc; i++) {
            new_argv[i + 4] = argv[i];
        }
        new_argv[argc + 4] = NULL;

        execv(exec_loader, new_argv);
        fprintf(stderr, "portable-ruby: exec loader failed: %s\n", strerror(errno));
        free(new_argv);
        /* Fall through to direct exec as fallback */
    } else {
        LOG("no bundled loader found, exec'ing ruby directly\n");
    }
#endif

    /* Direct exec (macOS, or Linux fallback if no bundled loader) */
    char **new_argv = malloc(sizeof(char *) * (argc + 2));
    if (!new_argv) {
        perror("malloc");
        if (is_tmpdir) cleanup_dir(cache_dir);
        return 1;
    }

    new_argv[0] = ruby_bin;
    new_argv[1] = entry_script;
    for (int i = 1; i < argc; i++) {
        new_argv[i + 1] = argv[i];
    }
    new_argv[argc + 1] = NULL;

    execv(ruby_bin, new_argv);

    fprintf(stderr, "portable-ruby: exec failed: %s\n", strerror(errno));
    if (is_tmpdir) cleanup_dir(cache_dir);
    free(new_argv);
    return 1;
}

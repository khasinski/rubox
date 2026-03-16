/*
 * portable-cruby stub
 *
 * This is the self-extracting loader. It gets compiled as a small static binary,
 * then the payload (compressed tarball of Ruby + gems + app) is appended to it.
 *
 * At runtime:
 *   1. Opens its own executable (via /proc/self/exe or argv[0])
 *   2. Reads the 24-byte footer to find the payload offset and size
 *   3. Extracts the payload to a temp directory
 *   4. Execs the bundled Ruby interpreter with the entry script
 *
 * Footer layout (last 24 bytes of the binary):
 *   [8 bytes] payload offset (little-endian uint64)
 *   [8 bytes] payload size   (little-endian uint64)
 *   [8 bytes] magic          "CRUBY\x00\x01\x00"
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <errno.h>
#include <limits.h>
#include <fcntl.h>
#include <signal.h>

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

/* Read the path to our own executable */
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
        return 0;
    }
#endif
    /* Fallback: try argv[0] with realpath */
    return -1;
}

/* Create a temporary directory for extraction */
static int make_tmpdir(char *buf, size_t bufsize) {
    const char *tmpdir = getenv("TMPDIR");
    if (!tmpdir) tmpdir = getenv("TMP");
    if (!tmpdir) tmpdir = "/tmp";

    snprintf(buf, bufsize, "%s/portable-cruby.XXXXXX", tmpdir);
    if (mkdtemp(buf) == NULL) {
        perror("mkdtemp");
        return -1;
    }
    return 0;
}

/* Recursively remove a directory (best-effort cleanup) */
static void cleanup_dir(const char *path) {
    char cmd[PATH_MAX + 16];
    snprintf(cmd, sizeof(cmd), "rm -rf '%s'", path);
    system(cmd);
}

/* Extract a zstd-compressed tar from a region of a file */
static int extract_payload(const char *exe_path, off_t offset, off_t size,
                           const char *dest_dir) {
    char cmd[PATH_MAX * 2 + 128];

    /*
     * Use dd to extract the payload region, pipe through zstd decompression,
     * then untar into the destination directory.
     *
     * We try zstd first (better compression), fall back to gzip.
     */
    snprintf(cmd, sizeof(cmd),
        "dd if='%s' bs=1 skip=%lld count=%lld status=none 2>/dev/null | "
        "zstd -d -c 2>/dev/null | "
        "tar xf - -C '%s' 2>/dev/null",
        exe_path, (long long)offset, (long long)size, dest_dir);

    int ret = system(cmd);
    if (ret == 0) return 0;

    /* Fall back to gzip */
    snprintf(cmd, sizeof(cmd),
        "dd if='%s' bs=1 skip=%lld count=%lld status=none 2>/dev/null | "
        "gzip -d -c 2>/dev/null | "
        "tar xf - -C '%s' 2>/dev/null",
        exe_path, (long long)offset, (long long)size, dest_dir);

    return system(cmd);
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

int main(int argc, char **argv) {
    char exe_path[PATH_MAX];
    char tmpdir[PATH_MAX];
    char ruby_bin[PATH_MAX];
    char entry_script[PATH_MAX];
    char load_path[PATH_MAX];
    char gem_path[PATH_MAX];
    unsigned char footer[FOOTER_SIZE];

    /* Find our own executable */
    if (self_exe_path(exe_path, sizeof(exe_path)) != 0) {
        /* Fall back to argv[0] */
        if (argv[0] && realpath(argv[0], exe_path) == NULL) {
            fprintf(stderr, "portable-cruby: cannot determine executable path\n");
            return 1;
        }
    }

    /* Read the footer */
    FILE *fp = fopen(exe_path, "rb");
    if (!fp) {
        fprintf(stderr, "portable-cruby: cannot open %s: %s\n",
                exe_path, strerror(errno));
        return 1;
    }

    if (fseek(fp, -FOOTER_SIZE, SEEK_END) != 0) {
        fprintf(stderr, "portable-cruby: cannot seek to footer\n");
        fclose(fp);
        return 1;
    }

    if (fread(footer, 1, FOOTER_SIZE, fp) != FOOTER_SIZE) {
        fprintf(stderr, "portable-cruby: cannot read footer\n");
        fclose(fp);
        return 1;
    }
    fclose(fp);

    /* Verify magic */
    if (memcmp(footer + 16, PAYLOAD_MAGIC, MAGIC_SIZE) != 0) {
        fprintf(stderr, "portable-cruby: no payload found (bad magic)\n");
        fprintf(stderr, "This binary was not packaged correctly.\n");
        return 1;
    }

    uint64_t payload_offset = read_le64(footer);
    uint64_t payload_size = read_le64(footer + 8);

    /* Check for cached extraction */
    const char *cache_dir = getenv("PORTABLE_CRUBY_CACHE");
    int use_cache = (cache_dir != NULL && cache_dir[0] != '\0');
    int needs_extract = 1;

    if (use_cache) {
        snprintf(tmpdir, sizeof(tmpdir), "%s", cache_dir);
        /* Check if already extracted */
        snprintf(ruby_bin, sizeof(ruby_bin), "%s/bin/ruby", tmpdir);
        if (access(ruby_bin, X_OK) == 0) {
            needs_extract = 0;
        } else {
            mkdir(tmpdir, 0700);
        }
    } else {
        if (make_tmpdir(tmpdir, sizeof(tmpdir)) != 0) {
            return 1;
        }
    }

    if (needs_extract) {
        if (extract_payload(exe_path, (off_t)payload_offset,
                           (off_t)payload_size, tmpdir) != 0) {
            fprintf(stderr, "portable-cruby: failed to extract payload\n");
            if (!use_cache) cleanup_dir(tmpdir);
            return 1;
        }
    }

    /* Build paths */
    snprintf(ruby_bin, sizeof(ruby_bin), "%s/bin/ruby", tmpdir);
    snprintf(entry_script, sizeof(entry_script), "%s/entry.rb", tmpdir);
    snprintf(load_path, sizeof(load_path), "%s/lib", tmpdir);
    snprintf(gem_path, sizeof(gem_path), "%s/gems", tmpdir);

    if (access(ruby_bin, X_OK) != 0) {
        fprintf(stderr, "portable-cruby: ruby binary not found at %s\n", ruby_bin);
        if (!use_cache) cleanup_dir(tmpdir);
        return 1;
    }

    if (access(entry_script, R_OK) != 0) {
        fprintf(stderr, "portable-cruby: entry script not found at %s\n", entry_script);
        if (!use_cache) cleanup_dir(tmpdir);
        return 1;
    }

    /*
     * Build argv for ruby.
     * We pass: ruby -I<load_path> <entry_script> [original args...]
     */
    int new_argc = argc + 3; /* ruby, -I, entry, [args...], NULL */
    char **new_argv = malloc(sizeof(char *) * (new_argc + 1));
    if (!new_argv) {
        perror("malloc");
        if (!use_cache) cleanup_dir(tmpdir);
        return 1;
    }

    new_argv[0] = ruby_bin;

    /* Set GEM_PATH so bundled gems are found */
    char gem_path_env[PATH_MAX + 16];
    snprintf(gem_path_env, sizeof(gem_path_env), "GEM_PATH=%s", gem_path);
    putenv(gem_path_env);

    /* Set GEM_HOME to prevent writing to system gem dir */
    char gem_home_env[PATH_MAX + 16];
    snprintf(gem_home_env, sizeof(gem_home_env), "GEM_HOME=%s", gem_path);
    putenv(gem_home_env);

    /* Tell bundler not to look for a Gemfile */
    putenv("BUNDLE_GEMFILE=");

    /* Store extraction dir for the entry script */
    char root_env[PATH_MAX + 32];
    snprintf(root_env, sizeof(root_env), "PORTABLE_CRUBY_ROOT=%s", tmpdir);
    putenv(root_env);

    /* If not using cache, register cleanup on common signals */
    if (!use_cache) {
        char cleanup_env[PATH_MAX + 32];
        snprintf(cleanup_env, sizeof(cleanup_env),
                 "PORTABLE_CRUBY_CLEANUP=%s", tmpdir);
        putenv(cleanup_env);
    }

    new_argv[1] = entry_script;

    /* Copy original argv[1..] (skip argv[0] which is the packed binary name) */
    for (int i = 1; i < argc; i++) {
        new_argv[i + 1] = argv[i];
    }
    new_argv[argc + 1] = NULL;

    /* Exec ruby - this replaces the current process */
    execv(ruby_bin, new_argv);

    /* If exec fails */
    fprintf(stderr, "portable-cruby: failed to exec ruby: %s\n", strerror(errno));
    if (!use_cache) cleanup_dir(tmpdir);
    free(new_argv);
    return 1;
}

/*
 * write-footer: append the 24-byte portable-ruby footer to a file.
 * Usage: write-footer <file> <payload_offset> <payload_size>
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

static void write_le64(FILE *fp, uint64_t v) {
    for (int i = 0; i < 8; i++) {
        fputc((int)(v & 0xff), fp);
        v >>= 8;
    }
}

int main(int argc, char **argv) {
    if (argc != 4) {
        fprintf(stderr, "Usage: %s <file> <payload_offset> <payload_size>\n", argv[0]);
        return 1;
    }

    const char *path = argv[1];
    uint64_t offset = (uint64_t)strtoull(argv[2], NULL, 10);
    uint64_t size = (uint64_t)strtoull(argv[3], NULL, 10);

    FILE *fp = fopen(path, "ab");
    if (!fp) {
        perror("fopen");
        return 1;
    }

    write_le64(fp, offset);
    write_le64(fp, size);
    fwrite("CRUBY\x00\x01\x00", 1, 8, fp);
    fclose(fp);
    return 0;
}

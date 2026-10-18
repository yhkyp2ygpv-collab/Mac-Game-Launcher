// shader_pack <source.metal> <out.pack> — see Native/AnvilMetal/anvil_pack.h.
#include "../AnvilMetal/anvil_pack.h"
#include <compression.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char** argv) {
    if (argc != 3) { fprintf(stderr, "usage: shader_pack <source> <out>\n"); return 2; }
    FILE* in = fopen(argv[1], "rb");
    if (!in) { perror(argv[1]); return 1; }
    fseek(in, 0, SEEK_END);
    long size = ftell(in);
    fseek(in, 0, SEEK_SET);
    uint8_t* source = malloc((size_t)size);
    if (!source || fread(source, 1, (size_t)size, in) != (size_t)size) { fclose(in); return 1; }
    fclose(in);
    size_t cap = (size_t)size + 4096;
    uint8_t* packed = malloc(cap);
    size_t n = compression_encode_buffer(packed, cap, source, (size_t)size, NULL, COMPRESSION_ZLIB);
    if (n == 0) { fprintf(stderr, "compression failed\n"); return 1; }
    for (size_t i = 0; i < n; i++) packed[i] ^= anvil_pack_key[i % ANVIL_PACK_KEY_LENGTH];
    FILE* out = fopen(argv[2], "wb");
    if (!out) { perror(argv[2]); return 1; }
    uint8_t header[8] = {'A', 'N', 'V', 'P', (uint8_t)size, (uint8_t)(size >> 8), (uint8_t)(size >> 16), (uint8_t)(size >> 24)};
    fwrite(header, 1, 8, out);
    fwrite(packed, 1, n, out);
    fclose(out);
    return 0;
}

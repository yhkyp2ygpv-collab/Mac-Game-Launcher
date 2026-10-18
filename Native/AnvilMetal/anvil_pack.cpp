#include "anvil_pack.h"
#include <compression.h>
#include <stdlib.h>
#include <string.h>

char* anvil_unpack_source(const uint8_t* data, size_t length, size_t* outLength) {
    if (!data || length < 8 || memcmp(data, ANVIL_PACK_MAGIC, 4) != 0) return NULL;
    uint32_t size = (uint32_t)data[4] | (uint32_t)data[5] << 8 | (uint32_t)data[6] << 16 | (uint32_t)data[7] << 24;
    if (size == 0 || size > 64u << 20) return NULL;
    size_t packed = length - 8;
    uint8_t* body = (uint8_t*)malloc(packed);
    char* out = (char*)malloc((size_t)size + 1);
    if (!body || !out) { free(body); free(out); return NULL; }
    for (size_t i = 0; i < packed; i++) body[i] = data[8 + i] ^ anvil_pack_key[i % ANVIL_PACK_KEY_LENGTH];
    size_t got = compression_decode_buffer((uint8_t*)out, size, body, packed, NULL, COMPRESSION_ZLIB);
    free(body);
    if (got != size) { free(out); return NULL; }
    out[size] = 0;
    if (outLength) *outLength = size;
    return out;
}

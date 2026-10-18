// The public edition's shaders, packed: compressed and scrambled so the .app carries no
// readable shader source when it couldn't be built with a precompiled library.
//
// Layout: "ANVP", the source length (uint32, little-endian), then the source compressed
// as raw DEFLATE (Apple's COMPRESSION_ZLIB) with every byte XORed with the key below.
#pragma once
#include <stddef.h>
#include <stdint.h>

#define ANVIL_PACK_MAGIC "ANVP"
#define ANVIL_PACK_KEY_LENGTH 32
static const uint8_t anvil_pack_key[ANVIL_PACK_KEY_LENGTH] = {
    0x4a, 0x43, 0x50, 0x2d, 0x53, 0x43, 0x2d, 0x41, 0x6e, 0x76, 0x69, 0x6c, 0x9d, 0x31, 0xe7, 0x08,
    0x5b, 0xc2, 0x7f, 0x13, 0xa4, 0x66, 0x0e, 0xd9, 0x28, 0xb5, 0x71, 0x3c, 0xe0, 0x94, 0x57, 0x1b};

#ifdef __cplusplus
extern "C" {
#endif
/// The source, NUL-terminated, in a buffer the caller frees; NULL if the data isn't a pack.
char* anvil_unpack_source(const uint8_t* data, size_t length, size_t* outLength);
#ifdef __cplusplus
}
#endif

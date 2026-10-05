#ifndef CHELPERS_H
#define CHELPERS_H

#include <stddef.h>
#include <stdint.h>

/// Raw (headerless) DEFLATE, equivalent to SharpZipLib's Deflater(level, noHeader: true)
/// followed by Flush() + Finish(). Returns the number of bytes written, or -1 if the
/// output buffer is too small or zlib fails.
long psx_deflate_raw(const uint8_t *input, size_t inputLength,
                     uint8_t *output, size_t outputCapacity, int level);

/// Raw (headerless) INFLATE. Returns the number of bytes produced, or -1 on error.
long psx_inflate_raw(const uint8_t *input, size_t inputLength,
                     uint8_t *output, size_t outputCapacity);

#endif

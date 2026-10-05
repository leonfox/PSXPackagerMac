#include "CHelpers.h"
#include <string.h>
#include <zlib.h>

long psx_deflate_raw(const uint8_t *input, size_t inputLength,
                     uint8_t *output, size_t outputCapacity, int level)
{
    z_stream strm;
    memset(&strm, 0, sizeof(strm));

    /* windowBits -15: raw deflate, no zlib header or adler32 trailer */
    if (deflateInit2(&strm, level, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY) != Z_OK)
        return -1;

    strm.next_in = (Bytef *)input;
    strm.avail_in = (uInt)inputLength;
    strm.next_out = output;
    strm.avail_out = (uInt)outputCapacity;

    /* SharpZipLib's DeflaterOutputStream.Flush() performs a sync flush before Finish() */
    int ret = deflate(&strm, Z_SYNC_FLUSH);
    if (ret != Z_OK && ret != Z_BUF_ERROR) { deflateEnd(&strm); return -1; }

    ret = deflate(&strm, Z_FINISH);
    if (ret != Z_STREAM_END) { deflateEnd(&strm); return -1; }

    long produced = (long)(outputCapacity - strm.avail_out);
    deflateEnd(&strm);
    return produced;
}

long psx_inflate_raw(const uint8_t *input, size_t inputLength,
                     uint8_t *output, size_t outputCapacity)
{
    z_stream strm;
    memset(&strm, 0, sizeof(strm));

    if (inflateInit2(&strm, -15) != Z_OK)
        return -1;

    strm.next_in = (Bytef *)input;
    strm.avail_in = (uInt)inputLength;
    strm.next_out = output;
    strm.avail_out = (uInt)outputCapacity;

    int ret = inflate(&strm, Z_FINISH);
    long produced = (long)(outputCapacity - strm.avail_out);
    inflateEnd(&strm);

    if (ret != Z_STREAM_END && ret != Z_BUF_ERROR && ret != Z_OK)
        return -1;

    return produced;
}

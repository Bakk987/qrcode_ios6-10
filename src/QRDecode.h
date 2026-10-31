#ifndef QRDECODE_H
#define QRDECODE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Opaque decoder context (wraps a quirc instance). Not thread-safe:
 * use one context per thread / serial queue. */
typedef struct qr_decoder qr_decoder;

qr_decoder *qr_decoder_new(void);
void qr_decoder_free(qr_decoder *d);

/* Scan an 8-bit grayscale image (e.g. the Y plane of a camera frame).
 * On success copies the first decoded payload into `out` (NUL-terminated,
 * truncated to out_cap-1 bytes) and returns the payload length.
 * Returns -1 if no QR code could be decoded. */
int qr_decoder_scan(qr_decoder *d, const uint8_t *gray, int width, int height,
                    int bytes_per_row, uint8_t *out, int out_cap);

#ifdef __cplusplus
}
#endif

#endif

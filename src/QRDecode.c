#include "QRDecode.h"
#include "../quirc/quirc.h"

#include <stdlib.h>
#include <string.h>

struct qr_decoder {
	struct quirc *q;
	int w;
	int h;
	struct quirc_code code;
	struct quirc_data data;
};

qr_decoder *qr_decoder_new(void)
{
	qr_decoder *d = (qr_decoder *)calloc(1, sizeof(*d));
	if (!d)
		return NULL;
	d->q = quirc_new();
	if (!d->q) {
		free(d);
		return NULL;
	}
	return d;
}

void qr_decoder_free(qr_decoder *d)
{
	if (!d)
		return;
	if (d->q)
		quirc_destroy(d->q);
	free(d);
}

int qr_decoder_scan(qr_decoder *d, const uint8_t *gray, int width, int height,
                    int bytes_per_row, uint8_t *out, int out_cap)
{
	int i, y, count;
	uint8_t *buf;
	int bw, bh;

	if (!d || !gray || width <= 0 || height <= 0 || !out || out_cap <= 0)
		return -1;

	if (d->w != width || d->h != height) {
		if (quirc_resize(d->q, width, height) < 0)
			return -1;
		d->w = width;
		d->h = height;
	}

	buf = quirc_begin(d->q, &bw, &bh);
	if (bytes_per_row == width) {
		memcpy(buf, gray, (size_t)width * (size_t)height);
	} else {
		for (y = 0; y < height; y++)
			memcpy(buf + (size_t)y * width,
			       gray + (size_t)y * bytes_per_row, (size_t)width);
	}
	quirc_end(d->q);

	count = quirc_count(d->q);
	for (i = 0; i < count; i++) {
		quirc_decode_error_t err;

		quirc_extract(d->q, i, &d->code);
		err = quirc_decode(&d->code, &d->data);
		if (err == QUIRC_ERROR_DATA_ECC) {
			/* Possibly a mirrored code: flip and retry. */
			quirc_flip(&d->code);
			err = quirc_decode(&d->code, &d->data);
		}
		if (err == QUIRC_SUCCESS) {
			int n = d->data.payload_len;
			if (n > out_cap - 1)
				n = out_cap - 1;
			memcpy(out, d->data.payload, (size_t)n);
			out[n] = 0;
			return n;
		}
	}
	return -1;
}

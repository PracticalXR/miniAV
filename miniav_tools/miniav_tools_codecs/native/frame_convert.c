/* frame_convert.c — first-party, FFmpeg-free CPU pixel-format conversion for the
 * player's cross-platform present fallback (and the reference the WGSL GPU
 * converters mirror byte-for-byte).
 *
 * On platforms with no zero-copy GPU present plugin, the decoder's planar YUV
 * frame reaches Flutter as packed RGBA8888 for `dart:ui`. Doing the per-pixel
 * colour convert in C (~1-2 ms/1080p) instead of Dart (~20-50 ms) is what keeps
 * the fallback smooth. These functions also handle the full spread of formats a
 * software decoder actually emits (4:2:0 / 4:2:2 / 4:4:4, 8- and 10-bit,
 * limited- and full/JPEG-range) so a 10-bit HEVC or MJPEG frame renders with
 * correct colour instead of being mis-read as 8-bit 4:2:0.
 *
 * Colour math: BT.601, libyuv-style x256 integer fixed point. Limited range
 * (coeffs 298/409/516/-100/-208) is byte-identical to the player's
 * kYuv420ToRgbaBt601Wgsl / yuv420pToRgba8. Full range (JPEG, yuvj*) uses the
 * no-luma-offset coefficient set. Output is RGBA8888, A=255.
 */
#include <stddef.h>
#include <stdint.h>

#if defined(_WIN32)
#  define MFC_API __declspec(dllexport)
#else
#  define MFC_API __attribute__((visibility("default")))
#endif

static inline uint8_t clip8(int v) {
  if (v < 0) return 0;
  if (v > 255) return 255;
  return (uint8_t)v;
}

/* x256 fixed-point YCbCr->RGB coefficients.
 *   c = Y - yOff; d = U-128; e = V-128
 *   R = (c*yMul + rV*e + 128) >> 8
 *   G = (c*yMul - gU*d - gV*e + 128) >> 8
 *   B = (c*yMul + bU*d + 128) >> 8 */
typedef struct {
  int yOff, yMul, rV, gU, gV, bU;
} coeffs_t;

/* Matrix x range coefficient tables (mirrors color_coeffs.dart exactly).
 * matrix: 0 = BT.601 (the miniAV default), 1 = BT.709 (HD), 2 = BT.2020 NCL
 * (UHD; the MATRIX only — PQ/HLG transfer is NOT applied here, see the
 * color-signaling notes). full_range: 0 = limited/studio, 1 = full/JPEG. */
static const coeffs_t k601Limited  = {16, 298, 409, 100, 208, 516};
static const coeffs_t k601Full     = {0,  256, 359,  88, 183, 454};
static const coeffs_t k709Limited  = {16, 298, 459,  55, 136, 541};
static const coeffs_t k709Full     = {0,  256, 403,  48, 120, 475};
/* BT.2020 NCL: Kr=0.2627 Kb=0.0593 -> rV=2(1-Kr), bU=2(1-Kb),
 * gU=2(1-Kb)Kb/Kg, gV=2(1-Kr)Kr/Kg, Kg=0.6780; x255/224 for limited. */
static const coeffs_t k2020Limited = {16, 298, 430,  48, 167, 548};
static const coeffs_t k2020Full    = {0,  256, 378,  42, 146, 482};

static inline const coeffs_t *pick(int matrix, int full_range) {
  if (matrix == 2) return full_range ? &k2020Full : &k2020Limited;
  if (matrix == 1) return full_range ? &k709Full : &k709Limited;
  return full_range ? &k601Full : &k601Limited;
}

static inline void conv(int Y, int U, int V, const coeffs_t *k, uint8_t *o) {
  const int c = Y - k->yOff;
  const int d = U - 128;
  const int e = V - 128;
  const int yy = c * k->yMul + 128;
  o[0] = clip8((yy + k->rV * e) >> 8);
  o[1] = clip8((yy - k->gU * d - k->gV * e) >> 8);
  o[2] = clip8((yy + k->bU * d) >> 8);
  o[3] = 255;
}

/* Read a little-endian 10-bit sample from a 16-bit plane and scale to 8-bit. */
static inline int ld10(const uint8_t *p, int i) {
  const int s = (int)p[2 * i] | ((int)p[2 * i + 1] << 8);
  return s >> 2;
}

/* ---- 8-bit planar ------------------------------------------------------- */

/* I420 / YUV420P (chroma subsampled 2x H and V). Strides <=0 => tightly packed
 * (width / ceil(width/2)). `full_range` selects JPEG-range coeffs (yuvj420p). */
MFC_API void miniav_i420_to_rgba(const uint8_t *y, const uint8_t *u,
                                 const uint8_t *v, int sy, int su, int sv,
                                 int width, int height, uint8_t *out,
                                 int full_range, int matrix) {
  if (!y || !u || !v || !out || width <= 0 || height <= 0) return;
  const coeffs_t *k = pick(matrix, full_range);
  const int cw = (width + 1) >> 1;
  if (sy <= 0) sy = width;
  if (su <= 0) su = cw;
  if (sv <= 0) sv = cw;
  for (int j = 0; j < height; ++j) {
    const uint8_t *yr = y + (size_t)j * sy;
    const uint8_t *ur = u + (size_t)(j >> 1) * su;
    const uint8_t *vr = v + (size_t)(j >> 1) * sv;
    uint8_t *o = out + (size_t)j * width * 4;
    for (int i = 0; i < width; ++i, o += 4)
      conv(yr[i], ur[i >> 1], vr[i >> 1], k, o);
  }
}

/* I422 / YUV422P (chroma subsampled 2x H, FULL V). */
MFC_API void miniav_i422_to_rgba(const uint8_t *y, const uint8_t *u,
                                 const uint8_t *v, int sy, int su, int sv,
                                 int width, int height, uint8_t *out,
                                 int full_range, int matrix) {
  if (!y || !u || !v || !out || width <= 0 || height <= 0) return;
  const coeffs_t *k = pick(matrix, full_range);
  const int cw = (width + 1) >> 1;
  if (sy <= 0) sy = width;
  if (su <= 0) su = cw;
  if (sv <= 0) sv = cw;
  for (int j = 0; j < height; ++j) {
    const uint8_t *yr = y + (size_t)j * sy;
    const uint8_t *ur = u + (size_t)j * su;
    const uint8_t *vr = v + (size_t)j * sv;
    uint8_t *o = out + (size_t)j * width * 4;
    for (int i = 0; i < width; ++i, o += 4)
      conv(yr[i], ur[i >> 1], vr[i >> 1], k, o);
  }
}

/* I444 / YUV444P (no chroma subsampling). */
MFC_API void miniav_i444_to_rgba(const uint8_t *y, const uint8_t *u,
                                 const uint8_t *v, int sy, int su, int sv,
                                 int width, int height, uint8_t *out,
                                 int full_range, int matrix) {
  if (!y || !u || !v || !out || width <= 0 || height <= 0) return;
  const coeffs_t *k = pick(matrix, full_range);
  if (sy <= 0) sy = width;
  if (su <= 0) su = width;
  if (sv <= 0) sv = width;
  for (int j = 0; j < height; ++j) {
    const uint8_t *yr = y + (size_t)j * sy;
    const uint8_t *ur = u + (size_t)j * su;
    const uint8_t *vr = v + (size_t)j * sv;
    uint8_t *o = out + (size_t)j * width * 4;
    for (int i = 0; i < width; ++i, o += 4) conv(yr[i], ur[i], vr[i], k, o);
  }
}

/* NV12 (Y + interleaved UV, 4:2:0). */
MFC_API void miniav_nv12_to_rgba(const uint8_t *y, const uint8_t *uv, int sy,
                                 int suv, int width, int height, uint8_t *out,
                                 int full_range, int matrix) {
  if (!y || !uv || !out || width <= 0 || height <= 0) return;
  const coeffs_t *k = pick(matrix, full_range);
  if (sy <= 0) sy = width;
  if (suv <= 0) suv = width;
  for (int j = 0; j < height; ++j) {
    const uint8_t *yr = y + (size_t)j * sy;
    const uint8_t *uvr = uv + (size_t)(j >> 1) * suv;
    uint8_t *o = out + (size_t)j * width * 4;
    for (int i = 0; i < width; ++i, o += 4) {
      const int c = (i >> 1) << 1;
      conv(yr[i], uvr[c], uvr[c + 1], k, o);
    }
  }
}

/* P010: 10-bit NV12 — Y plane + interleaved UV plane, 16-bit LE samples with
 * the 10 significant bits in the HIGH bits (15..6), unlike yuv420p10le which
 * uses the LOW bits. 8-bit value = u16 >> 8. Strides in BYTES; <=0 => tightly
 * packed (2*width for both planes). This is the D3D11/NVDEC/VideoToolbox HW
 * 10-bit surface layout, so the CPU fallback can consume mapped HW frames. */
static inline int ldp010(const uint8_t *p, int i) {
  return (int)p[2 * i + 1]; /* high byte of the LE u16 == u16 >> 8 */
}

MFC_API void miniav_p010_to_rgba(const uint8_t *y, const uint8_t *uv, int sy,
                                 int suv, int width, int height, uint8_t *out,
                                 int full_range, int matrix) {
  if (!y || !uv || !out || width <= 0 || height <= 0) return;
  const coeffs_t *k = pick(matrix, full_range);
  if (sy <= 0) sy = 2 * width;
  if (suv <= 0) suv = 2 * width;
  for (int j = 0; j < height; ++j) {
    const uint8_t *yr = y + (size_t)j * sy;
    const uint8_t *uvr = uv + (size_t)(j >> 1) * suv;
    uint8_t *o = out + (size_t)j * width * 4;
    for (int i = 0; i < width; ++i, o += 4) {
      const int c = (i >> 1) << 1; /* sample index of this pair's U */
      conv(ldp010(yr, i), ldp010(uvr, c), ldp010(uvr, c + 1), k, o);
    }
  }
}

/* ---- 10-bit planar (16-bit LE samples, scaled down to 8-bit) ------------ */
/* Strides are in BYTES; <=0 => tightly packed (2*width / 2*ceil(width/2)). */

MFC_API void miniav_i420p10_to_rgba(const uint8_t *y, const uint8_t *u,
                                    const uint8_t *v, int sy, int su, int sv,
                                    int width, int height, uint8_t *out,
                                 int full_range, int matrix) {
  if (!y || !u || !v || !out || width <= 0 || height <= 0) return;
  const coeffs_t *k = pick(matrix, full_range);
  const int cw = (width + 1) >> 1;
  if (sy <= 0) sy = 2 * width;
  if (su <= 0) su = 2 * cw;
  if (sv <= 0) sv = 2 * cw;
  for (int j = 0; j < height; ++j) {
    const uint8_t *yr = y + (size_t)j * sy;
    const uint8_t *ur = u + (size_t)(j >> 1) * su;
    const uint8_t *vr = v + (size_t)(j >> 1) * sv;
    uint8_t *o = out + (size_t)j * width * 4;
    for (int i = 0; i < width; ++i, o += 4)
      conv(ld10(yr, i), ld10(ur, i >> 1), ld10(vr, i >> 1), k, o);
  }
}

MFC_API void miniav_i422p10_to_rgba(const uint8_t *y, const uint8_t *u,
                                    const uint8_t *v, int sy, int su, int sv,
                                    int width, int height, uint8_t *out,
                                 int full_range, int matrix) {
  if (!y || !u || !v || !out || width <= 0 || height <= 0) return;
  const coeffs_t *k = pick(matrix, full_range);
  const int cw = (width + 1) >> 1;
  if (sy <= 0) sy = 2 * width;
  if (su <= 0) su = 2 * cw;
  if (sv <= 0) sv = 2 * cw;
  for (int j = 0; j < height; ++j) {
    const uint8_t *yr = y + (size_t)j * sy;
    const uint8_t *ur = u + (size_t)j * su;
    const uint8_t *vr = v + (size_t)j * sv;
    uint8_t *o = out + (size_t)j * width * 4;
    for (int i = 0; i < width; ++i, o += 4)
      conv(ld10(yr, i), ld10(ur, i >> 1), ld10(vr, i >> 1), k, o);
  }
}

/* ---- RGBA -> YUV (the inverse direction, encode-side) ------------------- */

/* x256 fixed-point RGB->YCbCr coefficients (mirrors RgbaYuvCoeffs in
 * color_coeffs.dart exactly — see there for the derivation notes):
 *   Y = ((yR*R + yG*G + yB*B + 128) >> 8) + yOff
 *   U = ((uR*R + uG*G + uB*B + 128) >> 8) + 128
 *   V = ((vR*R + vG*G + vB*B + 128) >> 8) + 128 */
typedef struct {
  int yR, yG, yB, uR, uG, uB, vR, vG, vB, yOff;
} inv_coeffs_t;

static const inv_coeffs_t ki601Limited  = {66, 129, 25, -38, -74, 112, 112, -94, -18, 16};
static const inv_coeffs_t ki601Full     = {77, 150, 29, -43, -85, 128, 128, -107, -21, 0};
static const inv_coeffs_t ki709Limited  = {47, 157, 16, -26, -86, 112, 112, -102, -10, 16};
static const inv_coeffs_t ki709Full     = {54, 183, 19, -29, -99, 128, 128, -116, -12, 0};
static const inv_coeffs_t ki2020Limited = {58, 149, 13, -31, -81, 112, 112, -103,  -9, 16};
static const inv_coeffs_t ki2020Full    = {67, 174, 15, -36, -92, 128, 128, -118, -10, 0};

static inline const inv_coeffs_t *inv_pick(int matrix, int full_range) {
  if (matrix == 2) return full_range ? &ki2020Full : &ki2020Limited;
  if (matrix == 1) return full_range ? &ki709Full : &ki709Limited;
  return full_range ? &ki601Full : &ki601Limited;
}

/* Packed RGBA8888 (or BGRA8888 when `bgra` != 0) -> tightly-packed I420
 * planes. `stride` is the source row stride in BYTES (<=0 => 4*width).
 * Chroma = rounded 2x2 box average of the RGB cell (edges replicate for odd
 * dims), converted once per chroma sample — byte-identical to the pure-Dart
 * dartRgbaToI420 and the GPU converter. BGRA costs nothing: it just swaps
 * which byte offsets the R/B coefficients read. */
MFC_API void miniav_rgba_to_i420(const uint8_t *rgba, int stride, int width,
                                 int height, uint8_t *y, uint8_t *u, uint8_t *v,
                                 int full_range, int matrix, int bgra) {
  if (!rgba || !y || !u || !v || width <= 0 || height <= 0) return;
  const inv_coeffs_t *k = inv_pick(matrix, full_range);
  const int ri = bgra ? 2 : 0;
  const int bi = bgra ? 0 : 2;
  if (stride <= 0) stride = 4 * width;
  for (int j = 0; j < height; ++j) {
    const uint8_t *p = rgba + (size_t)j * stride;
    uint8_t *o = y + (size_t)j * width;
    for (int i = 0; i < width; ++i, p += 4)
      o[i] = clip8(((k->yR * p[ri] + k->yG * p[1] + k->yB * p[bi] + 128) >> 8) +
                   k->yOff);
  }
  const int cw = (width + 1) >> 1;
  const int ch = (height + 1) >> 1;
  for (int cj = 0; cj < ch; ++cj) {
    const int j0 = cj * 2;
    const int j1 = (j0 + 1 < height) ? j0 + 1 : j0;
    const uint8_t *r0 = rgba + (size_t)j0 * stride;
    const uint8_t *r1 = rgba + (size_t)j1 * stride;
    uint8_t *uo = u + (size_t)cj * cw;
    uint8_t *vo = v + (size_t)cj * cw;
    for (int ci = 0; ci < cw; ++ci) {
      const int i0 = ci * 2 * 4;
      const int i1 = (ci * 2 + 1 < width) ? i0 + 4 : i0;
      const int r = (r0[i0 + ri] + r0[i1 + ri] + r1[i0 + ri] + r1[i1 + ri] + 2) >> 2;
      const int g = (r0[i0 + 1] + r0[i1 + 1] + r1[i0 + 1] + r1[i1 + 1] + 2) >> 2;
      const int b = (r0[i0 + bi] + r0[i1 + bi] + r1[i0 + bi] + r1[i1 + bi] + 2) >> 2;
      uo[ci] = clip8(((k->uR * r + k->uG * g + k->uB * b + 128) >> 8) + 128);
      vo[ci] = clip8(((k->vR * r + k->vG * g + k->vB * b + 128) >> 8) + 128);
    }
  }
}

MFC_API void miniav_i444p10_to_rgba(const uint8_t *y, const uint8_t *u,
                                    const uint8_t *v, int sy, int su, int sv,
                                    int width, int height, uint8_t *out,
                                 int full_range, int matrix) {
  if (!y || !u || !v || !out || width <= 0 || height <= 0) return;
  const coeffs_t *k = pick(matrix, full_range);
  if (sy <= 0) sy = 2 * width;
  if (su <= 0) su = 2 * width;
  if (sv <= 0) sv = 2 * width;
  for (int j = 0; j < height; ++j) {
    const uint8_t *yr = y + (size_t)j * sy;
    const uint8_t *ur = u + (size_t)j * su;
    const uint8_t *vr = v + (size_t)j * sv;
    uint8_t *o = out + (size_t)j * width * 4;
    for (int i = 0; i < width; ++i, o += 4)
      conv(ld10(yr, i), ld10(ur, i), ld10(vr, i), k, o);
  }
}

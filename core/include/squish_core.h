// C interface to the Squish Rust optimization engine (core/src/lib.rs).
#ifndef SQUISH_CORE_H
#define SQUISH_CORE_H

#include <stdbool.h>
#include <stdint.h>

#define SQUISH_OK 0
#define SQUISH_ALREADY_OPTIMAL 1
#define SQUISH_ERR_IO (-1)
#define SQUISH_ERR_UNSUPPORTED (-2)
#define SQUISH_ERR_DECODE (-3)
#define SQUISH_ERR_ENCODE (-4)
#define SQUISH_ERR_INTERNAL (-5)

typedef enum {
    SquishFormatUnknown = 0,
    SquishFormatPNG = 1,
    SquishFormatJPEG = 2,
    SquishFormatWebP = 3,
    SquishFormatAVIF = 4,
    SquishFormatSVG = 5,
    SquishFormatGIF = 6,
    SquishFormatTIFF = 7,
    SquishFormatBMP = 8,
    SquishFormatHEIC = 9,
} SquishFormat;

typedef struct {
    uint8_t quality;          // 1...100, lossy encoders only
    bool lossless;            // pixel-identical transformations only
    bool strip_metadata;
    bool keep_color_profile;  // keep ICC even when stripping
    uint8_t effort;           // 0 fast, 1 balanced, 2 maximum
    uint8_t output_format;    // SquishFormat, 0 keeps the source format
    uint32_t max_dimension;   // longest edge in pixels, larger images are downscaled; 0 keeps the size
} SquishOptions;

typedef struct {
    int32_t status;
    uint8_t input_format;
    uint8_t output_format;
    uint32_t width;
    uint32_t height;
    uint64_t original_size;
    uint64_t optimized_size;
    uint64_t elapsed_ms;
    char *message;            // nullable, free with squish_result_free
} SquishResult;

/// Writes to output_path only when the result is smaller (or the format or size changes).
SquishResult squish_optimize_file(const char *input_path, const char *output_path, const SquishOptions *options);
void squish_result_free(SquishResult *result);
uint8_t squish_detect_format(const char *path);
const char *squish_engine_info(void);
const char *squish_version(void);

#endif

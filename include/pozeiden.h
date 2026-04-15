/*
 * pozeiden.h — C API for libpozeiden (Mermaid diagram renderer)
 *
 * Link with: -lpozeiden
 *
 * Example
 * -------
 *   char *svg = NULL;
 *   size_t svg_len = 0;
 *   if (pozeiden_render(src, src_len, &svg, &svg_len) == 0) {
 *       fwrite(svg, 1, svg_len, stdout);
 *       pozeiden_free(svg);
 *   } else {
 *       fprintf(stderr, "pozeiden error: %s\n", pozeiden_last_error());
 *   }
 */
#ifndef POZEIDEN_H
#define POZEIDEN_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Render `input_len` bytes of Mermaid source text at `input` to SVG.
 *
 * On success, `*out_svg` is set to a heap-allocated, NUL-terminated SVG
 * string, `*out_len` is set to the number of bytes (excluding NUL), and 0
 * is returned.  Free the string with pozeiden_free().
 *
 * On failure, `*out_svg` is set to NULL, `*out_len` is set to 0, and -1 is
 * returned.  Call pozeiden_last_error() for a description of the failure.
 */
int pozeiden_render(const char *input, size_t input_len,
                    char **out_svg, size_t *out_len);

/**
 * Free an SVG string previously returned by pozeiden_render().
 * Passing NULL is safe (no-op).
 */
void pozeiden_free(char *svg);

/**
 * Return the error message from the most recent failed pozeiden_render() call
 * on this thread.  The returned pointer is valid until the next call on this
 * thread and must NOT be freed.  Returns "" if no error has occurred.
 */
const char *pozeiden_last_error(void);

/**
 * Detect the diagram type of `input_len` bytes at `input`.
 * Returns a NUL-terminated string literal such as "flowchart", "sequence",
 * "pie", "gitgraph", etc., or "unknown" for unrecognised input.
 * The returned pointer is a compile-time constant — do NOT free it.
 */
const char *pozeiden_detect(const char *input, size_t input_len);

#ifdef __cplusplus
}
#endif

#endif /* POZEIDEN_H */

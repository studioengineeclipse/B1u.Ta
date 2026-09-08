/*
 * C conformance entrypoint (SPEC/20-b1-canon-1.md §5) — the normative one.
 *
 *   stdin  : a JSON document
 *   stdout : 64 lowercase hex digits + newline
 *   stderr : a B1_ERR_* token when the document is rejected
 */

#include "b1_abi.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(void)
{
    size_t cap = 65536, len = 0;
    char *input = (char *)malloc(cap);
    if (!input) {
        fprintf(stderr, "B1_ERR_NOMEM\n");
        return 3;
    }

    for (;;) {
        if (len == cap) {
            size_t next = cap * 2;
            char *grown = (char *)realloc(input, next);
            if (!grown) {
                free(input);
                fprintf(stderr, "B1_ERR_NOMEM\n");
                return 3;
            }
            input = grown;
            cap = next;
        }
        size_t got = fread(input + len, 1, cap - len, stdin);
        len += got;
        if (got == 0) break;
    }

    char hex[65];
    b1_status st = b1_digest(input, len, hex);
    free(input);

    if (st != B1_OK) {
        fprintf(stderr, "%s\n", b1_status_token(st));
        return 2;
    }
    printf("%s\n", hex);
    return 0;
}

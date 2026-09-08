// C++ conformance entrypoint (SPEC/20-b1-canon-1.md §5).
//
//   stdin  : a JSON document
//   stdout : 64 lowercase hex digits + newline
//   stderr : a B1_ERR_* token when the document is rejected
//
// This calls libb1sig over the C ABI rather than reimplementing the codec. C and C++ are the one
// pair where sharing is the correct architecture: a second canonicalizer here would be a duplicate
// implementation of the same logic in a language that links the original directly, which SPEC/17
// forbids. The consequence is recorded honestly — C++'s conformance result confirms that the ABI
// boundary works, not that a second independent implementation agrees. The manifest marks it
// `via_c_abi` so the participation report never overstates what it proves.

#include "../c/b1_abi.h"

#include <cstdio>
#include <iostream>
#include <iterator>
#include <string>

int main()
{
    std::ios::sync_with_stdio(false);
    std::string input((std::istreambuf_iterator<char>(std::cin)), std::istreambuf_iterator<char>());

    char hex[65];
    b1_status st = b1_digest(input.data(), input.size(), hex);
    if (st != B1_OK) {
        std::cerr << b1_status_token(st) << "\n";
        return 2;
    }
    std::cout << hex << "\n";
    return 0;
}

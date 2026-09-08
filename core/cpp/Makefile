# b1-media — the media/temporal analyzer.
#
# Links libb1sig (core/c) over the C ABI. The frame signature has exactly one definition and it
# lives in C; this component consumes it rather than restating it.

CXX      ?= g++
CXXFLAGS ?= -std=c++20 -O2 -Wall -Wextra -Wpedantic -Wshadow -Wconversion -Werror
BUILD    := build
CLIB     := ../c/build/libb1sig.a

.PHONY: all clean test
all: $(BUILD)/b1media $(BUILD)/b1conform

$(BUILD):
	@mkdir -p $(BUILD)

# libb1sig is a genuine build dependency, not a convenience: this component cannot compute a frame
# signature without it, which is what makes the ABI boundary load-bearing.
$(CLIB):
	$(MAKE) -C ../c

$(BUILD)/b1media: b1_media.cpp ../c/b1_abi.h $(CLIB) | $(BUILD)
	$(CXX) $(CXXFLAGS) -o $@ b1_media.cpp $(CLIB)

$(BUILD)/b1conform: b1_conform.cpp ../c/b1_abi.h $(CLIB) | $(BUILD)
	$(CXX) $(CXXFLAGS) -o $@ b1_conform.cpp $(CLIB)

test: all
	@./run_tests.sh

clean:
	rm -rf $(BUILD)

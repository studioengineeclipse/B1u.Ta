# libb1sig — the normative signal kernel (SPEC/80 §2).
#
# No external dependencies: the whole verification graph must build and run offline.

CC      ?= gcc
CFLAGS  ?= -std=c11 -O2 -Wall -Wextra -Wpedantic -Wshadow -Wconversion -Werror
BUILD   := build
SRC     := b1_sha256.c b1_canon.c b1_signature.c
OBJ     := $(addprefix $(BUILD)/,$(SRC:.c=.o))

.PHONY: all clean test
all: $(BUILD)/b1conform $(BUILD)/libb1sig.a $(BUILD)/b1sigtest

$(BUILD):
	@mkdir -p $(BUILD)

$(BUILD)/%.o: %.c b1_abi.h | $(BUILD)
	$(CC) $(CFLAGS) -c $< -o $@

$(BUILD)/libb1sig.a: $(OBJ)
	ar rcs $@ $(OBJ)

$(BUILD)/b1conform: $(BUILD)/b1_conform.o $(BUILD)/libb1sig.a
	$(CC) $(CFLAGS) -o $@ $< -L$(BUILD) -lb1sig

$(BUILD)/b1sigtest: $(BUILD)/b1_sigtest.o $(BUILD)/libb1sig.a
	$(CC) $(CFLAGS) -o $@ $< -L$(BUILD) -lb1sig

test: $(BUILD)/b1sigtest
	@$(BUILD)/b1sigtest

clean:
	rm -rf $(BUILD)

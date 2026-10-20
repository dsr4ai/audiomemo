# AudioMemo portable core (C11). `make test` runs the unit tests; `make tools` builds the offline WAV tool.
CC ?= cc
CFLAGS ?= -std=c11 -O2 -Wall -Wextra -Wno-unused-result -Iinclude
SRC = src/am_aec.c src/am_fft.c src/am_level.c
OBJ = $(SRC:src/%.c=build/%.o)

all: build/libaudiomemo_core.a tools
build/%.o: src/%.c include/audiomemo_core.h src/am_fft.h | build ; $(CC) $(CFLAGS) -c $< -o $@
build/libaudiomemo_core.a: $(OBJ) ; ar rcs $@ $^
build: ; mkdir -p build
tools: build/am_aec_wav
build/am_aec_wav: tools/am_aec_wav.c build/libaudiomemo_core.a ; $(CC) $(CFLAGS) $< build/libaudiomemo_core.a -lm -o $@
build/test_core: tests/test_core.c build/libaudiomemo_core.a ; $(CC) $(CFLAGS) $< build/libaudiomemo_core.a -lm -o $@
test: build/test_core ; ./build/test_core
clean: ; rm -rf build
.PHONY: all tools test clean

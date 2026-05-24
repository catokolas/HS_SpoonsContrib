# Phase 1 diagnostic CLI tools.
CC      = clang
CFLAGS  = -Wall -Wextra -O0 -g -fobjc-arc
LDFLAGS = -framework AppKit -framework ApplicationServices

all: diag focus_test

diag: diag.m
	$(CC) $(CFLAGS) $(LDFLAGS) -o diag diag.m

focus_test: focus_test.m
	$(CC) $(CFLAGS) $(LDFLAGS) -o focus_test focus_test.m

clean:
	rm -f diag focus_test

.PHONY: all clean

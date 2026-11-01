CC      = xcrun clang
CXX     = xcrun clang++
ARCH   ?= -arch arm64 -arch x86_64
VER    := $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
CFLAGS  = -O2 -Wall -Wextra $(ARCH) -mmacosx-version-min=13.0
CXXFLAGS= $(CFLAGS) -std=c++20 -fobjc-arc -DPW_VER='"$(VER)"'
PREFIX ?= /usr/local
B       = build
OBJ     = $(B)/main.o $(B)/sys.o
DIST    = $(B)/powerwarden-$(VER)-macos-universal

all: $(B)/powerwarden

$(B)/powerwarden: $(OBJ)
	$(CXX) $(ARCH) -o $@ $(OBJ) -framework Foundation
	codesign -s - -f $@

$(B)/%.o: src/%.mm src/pw.h | $(B)
	$(CXX) $(CXXFLAGS) -c -o $@ $<
$(B)/%.o: src/%.c src/pw.h | $(B)
	$(CC) $(CFLAGS) -c -o $@ $<
$(B):
	mkdir -p $@

check: $(B)/powerwarden
	sh test/check.sh $(B)/powerwarden

install: $(B)/powerwarden
	install -d $(DESTDIR)$(PREFIX)/bin $(DESTDIR)$(PREFIX)/etc $(DESTDIR)/Library/LaunchDaemons
	install -m 755 $(B)/powerwarden $(DESTDIR)$(PREFIX)/bin/
	[ -f $(DESTDIR)$(PREFIX)/etc/powerwarden.conf ] || install -m 644 etc/powerwarden.conf $(DESTDIR)$(PREFIX)/etc/
	install -m 644 etc/org.tryhard.powerwarden.plist $(DESTDIR)/Library/LaunchDaemons/

uninstall:
	-launchctl bootout system/org.tryhard.powerwarden
	rm -f $(DESTDIR)$(PREFIX)/bin/powerwarden $(DESTDIR)/Library/LaunchDaemons/org.tryhard.powerwarden.plist

dist: $(B)/powerwarden
	rm -rf $(DIST) && mkdir -p $(DIST)
	cp $(B)/powerwarden etc/powerwarden.conf etc/org.tryhard.powerwarden.plist README.md LICENSE $(DIST)/
	tar -C $(B) -czf $(DIST).tar.gz $(notdir $(DIST))
	shasum -a 256 $(DIST).tar.gz > $(DIST).tar.gz.sha256

clean:
	rm -rf $(B)

.PHONY: all check install uninstall dist clean

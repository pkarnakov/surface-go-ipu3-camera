# On the Surface Go 3 (Fedora 43): install the IR camera feed. Needs
# v4l-utils, python3-numpy and v4l2loopback (RPM Fusion: akmod-v4l2loopback).
#   make check                    dependencies, syntax
#   sudo ./surface-ir.py --test 90    a 3 s run without loopback, prints the AE
#   sudo make install / uninstall
# Installs the script and pam-start in $(LIBEXEC), surface-ir.service in
# /etc/systemd/system and the v4l2loopback options in /etc/modprobe.d. PAM
# is not touched: see README.md. uninstall removes exactly these files.
PREFIX ?= /usr/local
LIBEXEC = $(PREFIX)/libexec/surface-ir
UNIT = /etc/systemd/system/surface-ir.service
MODPROBE = /etc/modprobe.d/99-surface-ir.conf

.PHONY: check install uninstall

check:
	python3 -m py_compile surface-ir.py && rm -rf __pycache__
	bash -n pam-start
	@for p in v4l-utils python3-numpy v4l2loopback; do \
	  rpm -q $$p >/dev/null || echo "missing: $$p"; done
	@modinfo v4l2loopback >/dev/null 2>&1 || echo "v4l2loopback module not built for $$(uname -r)"

install:
	@[ "$$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
	install -D -m 755 surface-ir.py $(LIBEXEC)/surface-ir.py
	sed 's|@LIBEXEC@|$(LIBEXEC)|g' pam-start > $(LIBEXEC)/pam-start
	chmod 755 $(LIBEXEC)/pam-start
	sed 's|@LIBEXEC@|$(LIBEXEC)|g' surface-ir.service > $(UNIT)
	install -m 644 99-surface-ir.conf $(MODPROBE)
	systemctl daemon-reload
	@echo "reload v4l2loopback for the options: modprobe -r v4l2loopback"

uninstall:
	@[ "$$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
	-systemctl stop surface-ir.service
	rm -f $(LIBEXEC)/surface-ir.py $(LIBEXEC)/pam-start $(UNIT) $(MODPROBE)
	-rmdir $(LIBEXEC)
	systemctl daemon-reload

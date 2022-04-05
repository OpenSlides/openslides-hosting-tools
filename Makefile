SHELL := bash
.DEFAULT_GOAL := all

INSTALL=install
PREFIX=/usr/local
BINDIR=$(PREFIX)/bin

dest_bindir := $(DESTDIR)$(BINDIR)

all:
	@echo "Available target: 'install'"

install:
	$(INSTALL) -d $(dest_bindir)
	$(INSTALL) -pm 0755 osinstancectl.sh $(dest_bindir)/os4instancectl
	$(INSTALL) -pm 644 bash-completion.sh /etc/bash_completion.d/os4instancectl
	$(INSTALL) -pm 0755 openslides-bulk-update.sh \
	  $(dest_bindir)/os4-bulk-update
	$(INSTALL) -pm 0755 openslides-bin-installer.sh $(dest_bindir)/openslides-bin-installer

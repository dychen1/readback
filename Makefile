.DEFAULT_GOAL := help

INSTALL_DIR ?= $(HOME)/Applications
OPEN ?= 1

.PHONY: help build install

help:
	@echo "make install   Build, install to ~/Applications, and open ReadBack"
	@echo "make build     Build a locally signed app in dist/ReadBack.app"
	@echo ""
	@echo "Options: INSTALL_DIR=/Applications   OPEN=0 (do not open after install)"

build:
	READBACK_ALLOW_AD_HOC_SIGN=1 ./Scripts/build-app

install:
	READBACK_INSTALL_DIR="$(INSTALL_DIR)" READBACK_OPEN_AFTER_INSTALL="$(OPEN)" ./Scripts/install-app

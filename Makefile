# Makefile for Fusion 360 on Ubuntu 24.04 + NVIDIA (Wine).
#
# Common targets:
#   make start_fusion_360         launch Fusion via the virtual-desktop launcher
#   make start_fusion_360_native  launch Fusion with native WM (no virtual desktop)
#   make install                  run str0g's installer wrapper (./run-install.sh)
#   make logs                     tail the Fusion launch log
#   make clean_desktop_duplicates remove Wine-generated duplicate menu entries
#   make install_desktop_entry    re-install our Fusion360.desktop (user menu + ~/Desktop)
#   make doctor                   summarise current state (prefix, DXVK, glvnd, DPI)

SHELL := /bin/bash

FUSION_ROOT     := $(HOME)/.fusion360
WINEPREFIX      := $(FUSION_ROOT)/wineprefixes
LAUNCHER_VD     := $(WINEPREFIX)/box-run-vd.sh
LAUNCHER_NATIVE := $(WINEPREFIX)/box-run.sh
LAUNCH_LOG      := $(CURDIR)/fusion-launch.log

APPS_DIR        := $(HOME)/.local/share/applications
DESKTOP_FILE    := $(APPS_DIR)/Fusion360.desktop
DESKTOP_LINK    := $(HOME)/Desktop/Fusion360.desktop

.PHONY: help start_fusion_360 start_fusion_360_native install logs \
        clean_desktop_duplicates install_desktop_entry doctor

help:
	@awk 'BEGIN{FS=":.*##"} /^[a-zA-Z0-9_]+:.*##/ {printf "  \033[36m%-28s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@echo ""
	@echo "  (no ## comment on a target = internal; see 'make' source for details)"

start_fusion_360: ## Launch Fusion 360 via the virtual-desktop launcher (recommended)
	@test -x "$(LAUNCHER_VD)" || { echo "Launcher not found: $(LAUNCHER_VD)"; exit 1; }
	@mkdir -p $(dir $(LAUNCH_LOG))
	@echo "[make] Rotating launch log -> $(LAUNCH_LOG).1"
	@if [ -f "$(LAUNCH_LOG)" ]; then mv -f "$(LAUNCH_LOG)" "$(LAUNCH_LOG).1"; fi
	@echo "[make] Starting Fusion 360 (virtual desktop). Log: $(LAUNCH_LOG)"
	@"$(LAUNCHER_VD)" >"$(LAUNCH_LOG)" 2>&1 &
	@echo "[make] launched; PID $$!. Tail with: make logs"

start_fusion_360_native: ## Launch Fusion 360 with native WM (no virtual desktop)
	@test -x "$(LAUNCHER_NATIVE)" || { echo "Launcher not found: $(LAUNCHER_NATIVE)"; exit 1; }
	@mkdir -p $(dir $(LAUNCH_LOG))
	@if [ -f "$(LAUNCH_LOG)" ]; then mv -f "$(LAUNCH_LOG)" "$(LAUNCH_LOG).1"; fi
	@echo "[make] Starting Fusion 360 (native WM). Log: $(LAUNCH_LOG)"
	@"$(LAUNCHER_NATIVE)" >"$(LAUNCH_LOG)" 2>&1 &
	@echo "[make] launched; PID $$!. Tail with: make logs"

install: ## Run str0g's Fusion installer wrapper (./run-install.sh)
	@./run-install.sh

logs: ## Tail the latest fusion-launch.log
	@test -f "$(LAUNCH_LOG)" || { echo "No log yet at $(LAUNCH_LOG)"; exit 0; }
	@tail -n 200 -f "$(LAUNCH_LOG)"

clean_desktop_duplicates: ## Remove Wine-generated duplicate Start Menu entries
	@echo "[make] Looking for Wine-generated Fusion entries..."
	@# Wine installer drops a duplicate under applications/wine/Programs/Autodesk/.
	@# It runs Fusion without our env vars (no DXVK scoping, no glvnd, no vdesk)
	@# so it's always broken. Remove it and the empty subdirs it leaves behind.
	@if [ -f "$(APPS_DIR)/wine/Programs/Autodesk/Autodesk Fusion.desktop" ]; then \
		rm -v "$(APPS_DIR)/wine/Programs/Autodesk/Autodesk Fusion.desktop"; \
		rmdir --ignore-fail-on-non-empty \
			"$(APPS_DIR)/wine/Programs/Autodesk" \
			"$(APPS_DIR)/wine/Programs" \
			"$(APPS_DIR)/wine" 2>/dev/null || true; \
	else \
		echo "  (nothing to remove — already clean)"; \
	fi
	@echo "[make] Refreshing desktop database..."
	@update-desktop-database "$(APPS_DIR)" 2>/dev/null || true
	@# GNOME caches .desktop files aggressively; a logout/login picks up changes
	@# reliably, but this usually suffices:
	@touch "$(APPS_DIR)" 2>/dev/null || true
	@echo "[make] Done. Re-open the Activities Overview to see the change."

install_desktop_entry: ## Install/refresh our Fusion360.desktop (menu + ~/Desktop)
	@test -x "$(LAUNCHER_VD)" || { echo "Launcher not found: $(LAUNCHER_VD)"; exit 1; }
	@mkdir -p "$(APPS_DIR)" "$(HOME)/Desktop"
	@printf '%s\n' \
		'[Desktop Entry]' \
		'Version=1.0' \
		'Type=Application' \
		'Name=Autodesk Fusion 360' \
		'GenericName=3D CAD/CAM' \
		'Comment=Fusion 360 — 3D modelling, CAD, CAM, CAE and PCB design (Wine)' \
		'Exec=$(LAUNCHER_VD)' \
		'Icon=ECF6_Fusion360.0' \
		'Path=$(WINEPREFIX)' \
		'Terminal=false' \
		'StartupNotify=true' \
		'StartupWMClass=explorer.exe' \
		'Categories=Education;Engineering;Graphics;Science;' \
		'Keywords=CAD;CAM;CAE;3D;Fusion;Autodesk;' \
		> "$(DESKTOP_FILE)"
	@cp -f "$(DESKTOP_FILE)" "$(DESKTOP_LINK)"
	@chmod +x "$(DESKTOP_LINK)"
	@gio set "$(DESKTOP_LINK)" metadata::trusted true 2>/dev/null || true
	@update-desktop-database "$(APPS_DIR)" 2>/dev/null || true
	@echo "[make] Installed: $(DESKTOP_FILE)"
	@echo "[make] Desktop:   $(DESKTOP_LINK)"

doctor: ## Print a quick summary of current Fusion-on-Wine setup state
	@echo "== wine =="; wine --version 2>/dev/null || echo "wine not in PATH"
	@echo "== winetricks =="; winetricks --version 2>/dev/null | head -1 || echo "winetricks not in PATH"
	@echo "== glvnd NVIDIA ICD =="; \
		test -f /usr/share/glvnd/egl_vendor.d/10_nvidia.json && echo "OK" || echo "MISSING"
	@echo "== DXVK version string (from dxgi.dll) =="; \
		strings "$(WINEPREFIX)/drive_c/windows/system32/dxgi.dll" 2>/dev/null \
			| grep -oE 'v[0-9]+\.[0-9]+(\.[0-9]+)?' | sort -u | tail -3 || echo "not installed"
	@echo "== Wine DPI (LogPixels) =="; \
		WINEPREFIX="$(WINEPREFIX)" wine reg query 'HKCU\Control Panel\Desktop' /v LogPixels 2>/dev/null \
			| awk '/LogPixels/ {print $$NF}' || echo "?"
	@echo "== launcher scripts =="; \
		ls -la "$(LAUNCHER_VD)" "$(LAUNCHER_NATIVE)" 2>/dev/null || true
	@echo "== desktop entries matching 'fusion' =="; \
		grep -l -i 'fusion' $(APPS_DIR)/*.desktop $(APPS_DIR)/wine/Programs/Autodesk/*.desktop 2>/dev/null | sort
	@echo "== visible (NoDisplay!=true) entries =="; \
		for f in $$(grep -l -i 'fusion' $(APPS_DIR)/*.desktop 2>/dev/null); do \
			grep -q '^NoDisplay=true' "$$f" || echo "  VISIBLE: $$f"; \
		done

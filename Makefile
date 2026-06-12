PKGNAME ?= timeshift-btrbk-bridge
PREFIX ?= /usr

SYSTEMD ?= true

SHARE_DIR = $(DESTDIR)$(PREFIX)/share
LIB_DIR = $(DESTDIR)$(PREFIX)/lib
ETC_DIR = $(DESTDIR)/etc
BIN_DIR = $(DESTDIR)$(PREFIX)/local/bin

.PHONY: install uninstall

install:
	@if test "$(shell id -u)" != 0; then \
		echo "You are not root, run this target as root please."; \
		exit 1; \
	fi
	@echo "Installing $PKGNAME... "
	@echo
	@install --verbose -Dm744 -t "$(BIN_DIR)/" ./bin/timeshift-btrbk-bridge-mount-filesystems.sh;
	@install --verbose -Dm744 -t "$(BIN_DIR)/" ./bin/timeshift-btrbk-bridge.sh;
	@install --verbose -Dm744 -t "$(BIN_DIR)/" ./bin/timeshift-btrbk-bridge-umount-filesystems.sh;
	@install --verbose -Dm744 -t "$(BIN_DIR)/" ./bin/wait-for-backup-drive.sh;
	@# Systemd init system
	@if test "$(SYSTEMD)" = true; then \
		echo "Installing systemd .service file"; \
		install --verbose -Dm644 -t "$(ETC_DIR)/systemd/system/" ./etc/systemd/system/mnt-btrbk_archive.mount; \
		install -v -Dm644 -t "$(ETC_DIR)/systemd/system/" ./etc/systemd/system/systemd-service-failure@.service; \
		install -v -Dm644 -t "$(ETC_DIR)/systemd/system/" ./etc/systemd/system/timeshift-btrbk-bridge.service; \
		install -v -Dm644 -t "$(ETC_DIR)/systemd/system/" ./etc/systemd/system/timeshift-btrbk-bridge.timer; \
		install -v -Dm644 -t "$(ETC_DIR)/systemd/system/" ./etc/systemd/system/timeshift.service; \
		install -v -Dm644 -t "$(ETC_DIR)/systemd/system/" ./etc/systemd/system/timeshift.timer; \
		systemctl daemon-reload; \
	fi

uninstall:
	@if test "$(shell id -u)" != 0; then \
		echo "You are not root, run this target as root please."; \
		exit 1; \
	fi
	@echo "Uninstalling timeshift-btrbk-bridge... "
	@echo
	@rm -f "$(BIN_DIR)/timeshift-btrbk-bridge-mount-filesystems.sh"
	@rm -f "$(BIN_DIR)/timeshift-btrbk-bridge-umount-filesystems.sh"
	@rm -f "$(BIN_DIR)/wait-for-backup-drive.sh"
	@rm -f "$(BIN_DIR)/timeshift-btrbk-bridge.sh"
	@if test "$(SYSTEMD)" = true; then \
		echo "Uninstalling systemd .service files"; \
		rm -v "$(ETC_DIR)/systemd/system/mnt-btrbk_archive.mount"; \
		rm -v "$(ETC_DIR)/systemd/system/systemd-service-failure@.service"; \
		rm -v "$(ETC_DIR)/systemd/system/timeshift-btrbk-bridge.service"; \
		rm -v "$(ETC_DIR)/systemd/system/timeshift-btrbk-bridge.timer"; \
		rm -v "$(ETC_DIR)/systemd/system/timeshift.service"; \
		rm -v "$(ETC_DIR)/systemd/system/timeshift.timer"; \
		systemctl daemon-reload; \
	fi

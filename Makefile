.PHONY: all help init install uninstall clean ssh

# --- CONFIGURATION ---
# STRICT PATH TO THE ENGINE
ENGINE_DIR := /media/ilja/DATA/soft/sre-consilium
TOFU_BIN := tofu
PYTHON_BIN := python3
VENV_DIR := .venv
KEY_DIR := ssh_keys

# Colors
YELLOW := \033[1;33m
GREEN := \033[1;32m
RESET := \033[0m

# --- MAIN COMMANDS ---

help:
	@echo "=== Infra (this repo root) ==="
	@echo "  make init        Configure local env + tofu init"
	@echo "  make install     Apply OpenTofu (deploy)"
	@echo "  make uninstall   Destroy OpenTofu resources"
	@echo "  make ssh         SSH into instance"
	@echo "  make clean       Remove local caches"
	@echo ""
	@echo "=== E8miner (subproject) ==="
	@$(MAKE) -C E8miner --no-print-directory help

init:
	@echo "$(YELLOW)🔧 Configuring local project environment...$(RESET)"
	
	# 1. Create local venv
	$(PYTHON_BIN) -m venv $(VENV_DIR)
	./$(VENV_DIR)/bin/pip install --upgrade pip
	
	# 2. Check if Engine exists, then link requirements
	@if [ ! -f "$(ENGINE_DIR)/requirements.txt" ]; then \
		echo "❌ ERROR: $(ENGINE_DIR)/requirements.txt not found!"; \
		echo "👉 Run 'make install' in ~/consilium/install first."; \
		exit 1; \
	fi
	@echo "🔗 Linking requirements.txt from Engine..."
	@ln -sf $(ENGINE_DIR)/requirements.txt requirements.txt
	
	# 3. Install dependencies (ignoring system packages to prevent split-brain)
	./$(VENV_DIR)/bin/pip install --ignore-installed -r requirements.txt
	
	# 4. Initialize OpenTofu
	$(TOFU_BIN) init
	@echo "$(GREEN)✅ Project init complete. Dependencies synced with Engine.$(RESET)"

install:
	@echo "$(YELLOW)🔄 Re-deploying Infrastructure...$(RESET)"
	$(TOFU_BIN) apply -replace="oci_core_instance.arm_instance" -auto-approve

uninstall:
	$(TOFU_BIN) destroy -auto-approve

clean:
	rm -f *.log consilium_*.md requirements.txt
	rm -rf $(VENV_DIR) __pycache__ .aider*

ssh:
	@chmod 600 $(KEY_DIR)/* 2>/dev/null || true
	@IP=$$( $(TOFU_BIN) output -raw instance_public_ip 2>/dev/null ); \
	if [ -z "$$IP" ]; then echo "No IP found."; else ssh -o StrictHostKeyChecking=no -i $(KEY_DIR)/nixos_key root@$$IP; fi

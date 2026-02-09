---
iterations: unlimited
auto_approve: true
architecture_mode: false
strict_commands: false
iteration_mode: turns
architect_mode: file
architect_file: ARCHITECT.md
architect_poll_seconds: 10
architect_kb_mode: reuse
architect_kb_limit: 5
project_read_all: true
project_read_mode: head
project_read_max_lines: 200
project_read_max_bytes: 200000
---
# Role: Senior NixOS/SRE Expert & Functional Architect
# Language: English Only (Code, Comments, and Reasoning)
# Style: Functional, Stateless, Immutable Infrastructure (Senior Level)

## 1. Context & Objective
**Goal:** Successfully boot a NixOS installer on Oracle Cloud (ARM), then partition disks (ZFS root + XFS/LVM-thin data) according to the README.
**Current State:** The instance is BRICKED.
**Symptoms:** Kernel Panic during boot. Errors: `Unit initrd.target not found`, `default.target not found`, `Freezing execution`.
**Infrastructure:** Terraform (OpenTofu) + Python/Bash scripts + Nix configuration. Keys are in `tfvars`.

## 2. System Constraints (CRITICAL NIXOS RULES)
1. **OS ENFORCEMENT:** This is **NixOS**.
2. **FORBIDDEN:** DO NOT use `apt`, `yum`, `flatpak`, `pip` (system-wide), or imperative commands. Dont create more than 1 compute instance!
3. **ALLOWED:** Use `edit_code` to modify `.nix` files (flake.nix, configuration.nix), then `tofu apply -replace="oci_core_instance.arm_instance" -auto-approve`.
4. **DRIVER CHECK:** Ensure `virtio_pci`, `virtio_blk`, `virtio_net`, and `virtio_scsi` are present in `boot.initrd.availableKernelModules`.
5. **STORAGE CHECK:** Ensure that structure of disk storage structure is the same as described in README. You can use `lsblk -f` to check it.


## 3. Token Economy & Efficiency Rules (STRICT)
1. **NO BROWSING:** Do not use web search. Use internal knowledge base.
2. **LOG EFFICIENCY:** NEVER read the full console history. ALWAYS use `| tail -n 50` or `grep -C 10`.
3. **NO CHATTER:** Do not explain "why" unless asked. Output only the diagnosis and the planned fix.
4. **CACHE FRIENDLY:** Focus on editing existing files surgically to maximize context caching.
5. **LOG LOCATION:** Write execution logs to `consilium_run.log` in this repo (not in this file).

## 4. The Autonomous Iterative Loop
**INSTRUCTION:** Execute the following cycle REPEATEDLY and AUTONOMOUSLY using `run_bash` and `edit_code` until the **Exit Condition** is met. Do not stop to ask for permission if a failure is detected—fix it and retry.

### Step 0: PREPARE (Read the Project)
Before anything else in each run, read all project files. If `.consilium_project_snapshot.md` exists, read it first.
```
test -f .consilium_project_snapshot.md && sed -n '1,200p' .consilium_project_snapshot.md
rg --files | sort | while read -r f; do echo "### $f"; sed -n '1,200p' "$f"; done | tail -n 2000
```

### Step A: DIAGNOSE (The Oracle CLI)
Fetch the crash log using the CLI. Focus specifically on the last 50 lines:
```
COMPARTMENT_ID=$(awk -F= '/^compartment_id/ {print $2}' terraform.tfvars | sed 's/#.*//' | tr -d ' "')
INSTANCE_ID=$(tofu show -json | jq -r '.values.root_module.resources[] | select(.address=="oci_core_instance.arm_instance") | .values.id')
STATE=$(oci compute instance get --instance-id "$INSTANCE_ID" --query 'data."lifecycle-state"' --raw-output)
if [ "$STATE" = "RUNNING" ]; then
  oci compute console-history list --compartment-id "$COMPARTMENT_ID" --instance-id "$INSTANCE_ID" --output json | jq -r '.data[].id' | head -n 3 | xargs -r -I {} oci compute console-history delete --instance-console-history-id {} --force
  HISTORY_ID=$(oci compute console-history capture --instance-id "$INSTANCE_ID" --query 'data.id' --raw-output)
  oci compute console-history get-content --instance-console-history-id "$HISTORY_ID" --file /tmp/console.txt
  tail -n 50 /tmp/console.txt
else
  echo "Instance state is $STATE; skip console history capture."
fi
```

* *Hint:* If `initrd` cannot mount the disk, the system freezes. Check specific NixOS boot errors.
* *Important:* Do NOT use `oci compute console-history list` here (it requires `--compartment-id`). Use the exact commands above.

### Step B: FIX (The Code)
Apply surgical fixes to `disk-config.nix`, `configuration.nix`, `flake.nix`, or Terraform files using `edit_code`.
* *Style Guide:* Use stateless logic. Avoid hardcoded paths if dynamic dispatch is possible. Ensure `hostId` is generated correctly for ZFS.

### Step C: RECONNECT / FALLBACK (Conditional)
If SSH fails, wait 60 seconds and retry. If SSH still fails, attempt OCI Console Connection. **Only then** consider rebuild.
```
IP=$(tofu output -raw server_public_ip)
INSTANCE_ID=$(tofu show -json | jq -r '.values.root_module.resources[] | select(.address=="oci_core_instance.arm_instance") | .values.id')

if timeout 10s ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "root@${IP}" "echo SSH_OK" >/dev/null 2>&1; then
  echo "SSH reachable; proceed to Step D."
else
  echo "SSH unreachable; waiting 60s and retry..."
  sleep 60
  if timeout 10s ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "root@${IP}" "echo SSH_OK" >/dev/null 2>&1; then
    echo "SSH reachable after wait; proceed to Step D."
  else
    echo "SSH still unreachable; attempting OCI console connection..."
    CONN_ID=$(oci compute instance-console-connection create --instance-id "$INSTANCE_ID" --ssh-public-key-file ~/.ssh/id_rsa.pub --query 'data.id' --raw-output)
    CONN_STR=$(oci compute instance-console-connection get --instance-console-connection-id "$CONN_ID" --query 'data.connection-string' --raw-output)
    if [ -n "$CONN_STR" ]; then
      timeout 60s ssh -o StrictHostKeyChecking=no -i ~/.ssh/id_rsa "$CONN_STR" "uname -a" || true
    fi
    echo "If console is unreachable and logs indicate brick, rebuild."
    tofu apply -replace="oci_core_instance.arm_instance" -auto-approve
  fi
fi
```

### Step D: VERIFY (The Connection)
Attempt to SSH into the instance.
* **STRICT TIMEOUT:** Wait **MAXIMUM 60 SECONDS**.
* **IF TIMEOUT/FAIL:** Return to Step A (Diagnose).
* **IF SUCCESS:** Execute the on-host script: `/root/installer/on-host-zfs-install.sh`.

Use these exact commands:
```
IP=$(tofu output -raw server_public_ip)
timeout 60s ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "root@${IP}" "uname -a"
timeout 60s ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "root@${IP}" "/root/installer/on-host-zfs-install.sh"
```

## 5. Exit Condition
Stop the loop ONLY when:
1. SSH connection is established and stable.
2. The `/root/installer/on-host-zfs-install.sh` script executes with **Exit Code 0**.
3. Ensure that structure of disk storage structure is the same as described in README.md. You can use `lsblk -f` to check it. 

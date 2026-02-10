# Oracle Cloud NixOS Architecture: ZFS + XFS (100 + 100)

This project deploys NixOS + ZFS on Oracle Cloud Infrastructure (OCI) ARM Always Free instances using OpenTofu.

The instance boots from a custom image that is imported from a public QCOW2 URL (Object Storage).



## Quickstart (OpenTofu)

1) Configure OCI credentials + settings in `terraform.tfvars`.

2) (Optional) Override the public image URL:

   - set `nixos_zfs_public_image_url` in `terraform.tfvars`, or
   - pass `-var nixos_zfs_public_image_url=...` to `tofu`.

3) Deploy:

    tofu init
    tofu plan
    tofu apply -auto-approve

   If your IAM user can't create quotas, set `enable_quota_guardrails=false` in `terraform.tfvars`.

4) Connect:

    IP="$(tofu output -raw server_public_ip)"
    ssh -i ~/.ssh/id_rsa -o StrictHostKeyChecking=no root@"$IP"

5) Destroy:

    tofu destroy -auto-approve

The architecture is intentionally optimized for:

- OCI Always Free storage limits (200 GB total)
- Network-backed boot volumes
- NixOS rebuild-heavy workloads
- Containerized microservices with parallel I/O
- Maximum performance via filesystem-level tuning (“controlled shamanism”)

---

## Storage Layout (100 GB + 100 GB)

![Architecture Diagram](arch.svg)

### 1. Operating System — ZFS on Boot Volume (100 GB)

- Mountpoints: `/`, `/nix`, `/tmp`
- Disk: OCI boot volume (`/dev/sda`)
- Partitioning:
  - ESP (FAT32) → `/boot`
  - ZFS pool `zroot` → remainder
- Filesystem: ZFS (single-disk pool)
- Size: 100 GB

Why ZFS on the boot volume:

- ARC and compression reduce physical I/O on slow network-backed storage.
- TXG batching smooths write bursts.
- Snapshots and NixOS generations enable fast rollbacks.
- Dataset-level tuning allows aggressive optimization where it is safe.

This boot volume hosts the entire system, including `/nix`.  
No additional system block volumes or iSCSI are used — simplicity and predictability are preferred over theoretical maximum throughput.

#### ZFS Dataset Strategy (System)

`/root` (root):

- conservative settings
- `sync=standard`
- stability is prioritized over raw speed

`/nix`:

- performance-oriented
- `recordsize=16K`
- `compression=lz4`
- `atime=off`
- `redundant_metadata=most`
- `sync=disabled`
- data is reproducible and safe to rebuild or roll back

`/tmp`:

- aggressive performance settings
- `sync=disabled`
- small recordsize

All stateful runtime data is intentionally excluded from ZFS.

---

### 2. Data Storage — LVM-Thin + XFS on Data Volume (100 GB)

- Mountpoint: `/data`
- Disk: OCI data volume (`/dev/sdc`)
- Stack:
  - Physical Volume (PV)
  - Volume Group (VG), e.g. `data_vg`
  - LVM-thin pool, e.g. `data_thinpool`
  - Thin Logical Volume, e.g. `data`
  - XFS filesystem → `/data`
- Size:
  - 100 GB physical volume
  - thin-provisioned logical volumes (overprovisioning allowed)

Why LVM-Thin + XFS:

- XFS provides strong parallel I/O characteristics for container workloads.
- LVM-thin enables:
  - fast, lightweight snapshots
  - overprovisioning
  - flexible growth without data migration
- No interaction with ZFS ARC or memory contention.
- Clear separation between system I/O and service I/O.

This volume is intended for:

- container data
- application state
- databases
- persistent service files

Short-lived snapshots are handled via LVM-thin.  
Long-term backups are handled via OCI volume snapshots.

---

## Glossary: OCI → Device → Stack → Filesystem

OCI Boot Volume → `/dev/sda`:

- ESP: 512 MB FAT32 → `/boot`
- ZFS pool: `zroot`
  - `zroot/root` → `/`
  - `zroot/root` → `/root`
  - `zroot/nix` → `/nix`
  - `zroot/tmp` → `/tmp`

OCI Data Volume → `/dev/sdc`:

- PV → `data_vg`
- Thin pool → `data_thinpool`
- Thin LV → `data`
- XFS filesystem → `/data`

---

## Memory Management Strategy

- ZFS ARC:
  - limited (approximately 6–8 GB)
  - prevents ARC from starving containers

- ZRAM:
  - ZSTD compression
  - sized at approximately 30–35% of RAM
  - used as a real RAM extender, not just OOM protection
  - particularly effective for text-heavy and highly compressible workloads

This setup absorbs rebuild spikes and memory pressure without disk thrashing.

---

## Why This Architecture Works Well on OCI

- Boot volume reality: OCI boot volumes are network-backed and throughput-limited. ZFS reduces physical I/O via compression and caching instead of fighting these limits.
- NixOS-friendly: `/nix` is metadata-heavy and rebuild-oriented — a perfect fit for ZFS.
- Controlled risk: `sync=disabled` is applied only where data is reproducible (e.g. `/nix` and `/tmp`).
- Isolation by design: system I/O and service I/O never compete on the same disk.
- Always Free–compatible: exactly 200 GB total, no hidden volumes.
- Fast recovery: rollback via ZFS snapshots or NixOS generations is routine.
- Immutable mindset: the flake configuration is the real backup; disks are just caches.

---

## Snapshot Capability

### ZFS (System)

Used for:

- system rollbacks
- configuration checkpoints
- experimentation

Create a snapshot:

    sudo zfs snapshot zroot/root@prechange

Rollback:

    sudo zfs rollback zroot/root@prechange

### LVM-Thin (Data)

Used for:

- short-lived `/data` rollbacks
- testing and experimentation

Create a snapshot:

    sudo lvcreate -s -n data_snap_1 /dev/data_vg/data

### OCI Volume Snapshots (Long-term Backups)

Used for:

- boot volume backups (system)
- data volume backups (`/data`)

---

## Deployment Workflow

1. Import custom image

   OpenTofu imports an `oci_core_image` from `var.nixos_zfs_public_image_url` (public QCOW2 in Object Storage).

2. Launch instance

   OpenTofu launches the Always Free ARM instance with `source_type = "image"`.

3. Boot

   The system boots directly into NixOS on ZFS.

---

## Troubleshooting

- ZFS pool imports but filesystems are not mounted:

  Verify `mountpoint=legacy` on datasets and matching `fileSystems` entries in the NixOS configuration.

- LVM-thin volumes do not activate:

  Ensure the `dm_thin_pool` module is included in the initrd (`boot.initrd.kernelModules`).

- Unexpected memory pressure:

  Re-check `zfs_arc_max` and ZRAM sizing — ARC should not compete with containers for RAM.

---

## Notes

- `/data` is intended for containers and services.
- Docker or containerd `data-root` should be moved to `/data`.
- If device names differ from `/dev/sda` and `/dev/sdc`, adjust your local provisioning accordingly.

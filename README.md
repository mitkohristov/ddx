# ddx — universal `dd` disk imaging & cloning wizard

One bash script for **every** disk imaging direction, with compression, progress, checksums and safety rails. Clone it, answer a few questions, and go.

```
git clone https://github.com/<your-user>/ddx
cd ddx
sudo ./ddx.sh
```

No dependencies beyond standard tools (`dd`, `ssh`, and whichever compressor you pick). `pv` is optional but recommended for the progress bar.

## Why

`dd` over SSH is one of the most powerful tools in a sysadmin's kit — and one of the easiest to get wrong. Wrong direction, compression on the wrong side of the wire, overwriting the wrong disk. **ddx** builds the correct pipeline for you, always compresses on the smart side so the network carries compressed bytes, shows you the exact command before running it, and makes you type the device path before it will destroy anything.

## Supported directions

| # | Source        | Destination    | Example |
|---|---------------|----------------|---------|
| 1 | local disk    | local image    | `ddx.sh -s /dev/sda -d ./sda.img.zst` |
| 2 | local image   | local disk     | `ddx.sh -s ./sda.img.zst -d /dev/sdb` |
| 3 | local disk    | remote image   | `ddx.sh -s /dev/sda -d root@nas:/backup/sda.img.gz` |
| 4 | remote disk   | local image    | `ddx.sh -s root@web1:/dev/sda -d ./web1.img.zst` |
| 5 | local image   | remote disk    | `ddx.sh -s ./web1.img.zst -d root@web2:/dev/sda` |
| 6 | remote image  | local disk     | `ddx.sh -s root@nas:/backup/sda.img.gz -d /dev/sdb` |
| 7 | local disk    | remote disk    | `ddx.sh -s /dev/sda -d root@new:/dev/sda` |
| 8 | remote disk   | local disk     | `ddx.sh -s root@old:/dev/sda -d /dev/sdb` |
| 9 | remote disk   | remote image   | `ddx.sh -s root@old:/dev/sda -d root@nas:/b/old.img.gz` |
| 10| remote disk   | remote disk    | `ddx.sh -s root@old:/dev/sda -d root@new:/dev/sda` |
| 11| image         | image          | recompress: `ddx.sh -s old.img.gz -d old.img.zst -c zstd -l 10` |

Remote↔remote is relayed through the machine running ddx (standard SSH tunneling — no server-to-server SSH trust needed).

## Endpoint syntax

rsync-style. Anything under `/dev/` is a block device, everything else is an image file. Compression of existing images is auto-detected from the extension.

```
/dev/sda                        local disk
./backups/sda.img.zst           local image
root@10.0.0.5:/dev/sda          remote disk
root@10.0.0.5:/b/sda.img.gz     remote image
```

## Compression

| Tool  | Levels | Extension | Notes |
|-------|--------|-----------|-------|
| none  | —      | `.img`    | raw |
| gzip  | 1–9    | `.gz`     | universal |
| pigz  | 1–9    | `.gz`     | parallel gzip — much faster on multicore |
| zstd  | 1–19   | `.zst`    | **recommended default** — best speed/ratio |
| xz    | 0–9    | `.xz`     | smallest files, slowest |
| lz4   | 1–12   | `.lz4`    | fastest, lighter compression |

Compression always runs where it belongs: creating a remote image from a local disk compresses **locally**; pulling a remote disk to a local image compresses **on the remote**; restoring an image to a remote disk decompresses **on the remote**. The SSH link always carries compressed data when possible.

For raw disk→disk clones over the network, `--wire auto|zstd|lz4|gzip|none` adds transparent transfer compression (compress on one end, decompress on the other — the target disk still gets raw bytes).

## Options

```
-s, --source SPEC       source endpoint
-d, --dest SPEC         destination endpoint
-c, --compression NAME  none|gzip|pigz|zstd|xz|lz4
-l, --level N           compression level
-b, --bs SIZE           dd block size (default 4M)
-p, --ssh-port PORT     SSH port
-i, --ssh-key FILE      SSH identity file
    --wire MODE         transfer compression for raw streams over SSH
    --remote-sudo       prefix remote dd with 'sudo -n' (needs NOPASSWD)
    --checksum          write .sha256 next to created images
-n, --dry-run           print the pipeline, don't run it
-y, --yes               skip confirmations (careful!)
    --list [HOST]       list local or remote disks
```

Run with **no arguments** for the interactive wizard.

## Safety features

- Prints the full pipeline **before** executing — use `--dry-run` to only print it
- Writing to a disk requires typing the exact device path to confirm
- Refuses to write to mounted disks (local check hard-fails, remote check via SSH)
- Warns when the destination disk is smaller than the source
- Verifies compressors exist on remote hosts before starting
- `conv=fsync` on disk writes + `sync` at the end
- Optional `--checksum` produces a `.sha256` for every image you create

## Recipes

```bash
# Nightly backup of a server's system disk to your backup box
ddx.sh -s root@web1:/dev/sda -d /srv/backups/web1-$(date +%F).img.zst -c zstd -l 3 --checksum -y

# Migrate a server: old machine's disk straight onto the new machine's disk
ddx.sh -s root@old:/dev/sda -d root@new:/dev/sda --wire zstd

# Restore from your laptop to a rescue-booted server
ddx.sh -s ./web1.img.zst -d root@rescue:/dev/sda

# Convert years of old gzip backups to zstd
for f in *.img.gz; do ddx.sh -s "$f" -d "${f%.gz}.zst" -c zstd -l 10 -y; done

# Non-root remote reads (sudo NOPASSWD for dd required)
ddx.sh -s admin@host:/dev/sda -d ./host.img.zst --remote-sudo
```

## Tips

- Boot the machine from a live/rescue system when imaging its own root disk — imaging a running root filesystem gives you a crash-consistent copy at best.
- `pigz`/`zstd -T0` use all cores; on gigabit links zstd level 1–3 usually saturates the network while shrinking transfer size 2–3×.
- Multiple remote hosts with different ports/keys? Define them in `~/.ssh/config` — ddx respects it.
- Restoring to a **larger** disk works fine; grow the partition afterwards (`growpart`, `parted`, `resize2fs`/`xfs_growfs`).

## Requirements

- bash 4.4+, `dd`, `ssh`, `lsblk`
- Optional: `pv` (progress), `pigz`, `zstd`, `xz`, `lz4`
- Root (or sudo) for reading/writing block devices

## Roadmap / ideas

PRs welcome:

- [ ] Resume interrupted transfers (`dd skip/seek` bookkeeping)
- [ ] Partition-aware sparse imaging (`partclone` backend)
- [ ] Post-restore verification mode (re-read + compare hash)
- [ ] `--split SIZE` for chunked images
- [ ] Bandwidth limiting (`pv -L`)

## License

MIT — see [LICENSE](LICENSE).

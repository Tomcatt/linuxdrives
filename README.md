# linuxdrives

Use your Linux install's disks from Windows **without ever writing to them**.

* **Read-only mount**: md RAID, Btrfs RAID, XFS, ext4 … assembled and mounted inside WSL2
  and opened in Explorer.
* **Try mode**: boot the Linux install itself in a VM (QEMU/KVM inside WSL2), on the real
  disks. Everything the VM writes goes into overlay files, so the physical disks are never
  touched. Changes carry over between try-mode sessions. Shared text clipboard with
  Windows, window resize and SSH into the guest are included.

Think "Parallels for your dual-boot Linux", but open source and paranoid about your data.

Built and tested on Windows 11 + WSL2 (Arch) with CachyOS on a 4-disk mdadm RAID0 + XFS
with the Limine bootloader. Other layouts *should* work. Reports are welcome.

## Why it's safe

Everything is read-only by construction, with several independent layers:

1. Windows takes the disks offline (`Set-Disk -IsOffline`) and hands them to WSL raw
   (`wsl --mount --bare`).
2. Before anything looks at them, every disk and partition is locked with
   `blockdev --setro`. After that the **kernel** refuses writes, whatever md, XFS or
   Btrfs try to do.
3. md arrays are blocked from auto-assembling, then assembled `--readonly`. XFS mounts with
   `norecovery`, ext4 with `noload` and Btrfs with `rescue=nologreplay`, because replaying
   a journal would be a write.
4. In try mode, QEMU opens each disk `read-only=on` as well, under a qcow2 overlay that
   takes every guest write.
5. A **tripwire** checks each run: md superblock event counters plus a SHA-256 of every
   small partition (the ESPs, which Linux rewrites on every boot) before and after. Any
   leak shows up as `FAIL`.

The test suite builds throwaway RAID10 arrays (md+XFS and Btrfs) on 1 GiB VHDX files and
proves that every member stays byte-identical after mounting and after a try-mode selftest
that writes through the VM's disk chain.

## Requirements

* Windows 11 with WSL2 (`wsl --mount` needs Windows 11 or Server 2022)
* A WSL distro with `mdadm`, `xfsprogs` and `btrfs-progs`, plus for try mode
  `qemu-desktop`, `edk2-ovmf`, `socat` and `xclip` (Arch package names). On Arch:
  `pacman -S mdadm xfsprogs btrfs-progs qemu-desktop edk2-ovmf socat xclip`
* `/dev/kvm` inside WSL (on by default on current WSL2 with nested virtualization)
* PowerShell 7 (`pwsh`)
* The Linux disks must **not** hold Windows' boot or system volume. The script refuses
  those, and disk 0.

## Setup

1. Copy `linuxdrives.example.json` to `linuxdrives.json`. Set `distro` to your WSL distro
   and list your Linux disks by serial number:
   ```powershell
   Get-Disk | Format-Table Number, FriendlyName, SerialNumber, Size
   ```
2. Optional: `stopServices` lists Windows services that hold Linux partitions and would
   block `wsl --mount` (Paragon Linux File Systems, for example). They are paused during a
   session and restarted afterwards.

## Usage

```powershell
.\linuxdrives.ps1                  # mount read-only, opens Explorer; Enter in the window unmounts
.\linuxdrives.ps1 -Boot            # try mode: boot the install in a VM
.\linuxdrives.ps1 -Boot -Fresh     # try mode, throwing the previous try-mode session away first
.\linuxdrives.ps1 -Unmount         # clean up after a crash or a closed window
.\linuxdrives.ps1 -Target name     # another target from linuxdrives.json
.\make-test-arrays.ps1             # build the test arrays and run the safety tests
```

The script elevates itself; it needs admin for `wsl --mount` and `Set-Disk`. Logs go to
`logs\`.

## Try mode

The VM runs QEMU with KVM inside WSL2 and shows its window through WSLg: q35, OVMF (UEFI),
the disks on AHCI, and virtio-gpu.

* **Your changes are kept** in `/var/tmp/linuxdrives-keep/<target>/` on WSL's virtual disk,
  one qcow2 overlay per physical disk. The overlays are named by the disk's GPT id, so a
  changed `/dev/sdX` letter can't attach one to the wrong disk.
* **Booting the install natively makes the kept session invalid**, because the disks
  underneath changed. The next try-mode start notices (the tripwire no longer matches),
  moves the old session to `<target>.stale` and starts fresh. It never stacks old changes
  on new data.
* Try-mode changes **never reach the native install**. It's a sandbox copy.
* Overlays grow with what the guest writes; a big game update writes tens of GB. WSL's
  `ext4.vhdx` grows on the Windows drive it lives on and doesn't shrink by itself.
* **Resize**: resizing the window sets the guest's preferred mode; KDE Plasma follows it.
* **Clipboard** (text, both ways): see [Shared clipboard](#shared-clipboard) below.
* **SSH**: the guest's port 22 is forwarded to `127.0.0.1:2223` on the WSL side
  (`VM_SSH_PORT` to change it).
* **Tuning**: `VM_CPUS` (default 8), `VM_MEM` (default 16G) and `VM_EXTRA` (extra QEMU args)
  are environment variables read by `linuxdrives.sh`.
* There's no GPU passthrough: the guest renders with virtio-gpu, so it's fine for the
  desktop and settings, not for games.
* The guest knows it's a VM (`systemd-detect-virt` says `kvm`), and NVIDIA or other
  hardware-specific services in it will fail to find their hardware. That's harmless.

### Shared clipboard

QEMU's own clipboard support (GTK + spice-vdagent) doesn't work under WSLg: it never
notices a Windows copy, and on a Wayland desktop the guest agent never sees one either.
linuxdrives brings its own instead. `clipsync.sh` runs at both ends and passes text over a
dedicated virtio-serial port. In WSL, `linuxdrives.sh` starts it for you; it uses WSLg's
X11 clipboard, which WSLg keeps in sync with Windows. In the guest it uses the Wayland
clipboard.

One-time setup inside the Linux install (natively or in try mode), as your desktop user.
It needs `wl-clipboard`, and asks for sudo once to install a udev rule that lets you open
the port:

```sh
git clone https://github.com/Tomcatt/linuxdrives && sh linuxdrives/guest/install.sh
```

The script installs `clipsync.sh` to `~/.local/bin`, an autostart entry, and
`/etc/udev/rules.d/70-linuxdrives-clipboard.rules`. Outside try mode the autostart entry
finds no port and exits at once. If you set it up from inside try mode, it lands in the
overlay only, so it's gone again once the session is thrown away.

Tested with KDE Plasma (Wayland). Other Wayland desktops whose compositor supports the
data-control protocol (`wl-paste --watch` works) should be fine; GNOME doesn't support it.

## How it works

`linuxdrives.ps1` (Windows, elevated) takes the disks offline, attaches them to WSL and
calls `linuxdrives.sh` (inside WSL as root) for the Linux side: `prepare` (block md
auto-assembly) → `protect` (setro) → `mount` / `boot`, then `unmount`, after which the
disks go back to Windows. `common.ps1` holds the shared helpers.

## Limitations

* LUKS and LVM are detected but not mounted yet.
* One session at a time; a second launch refuses while one is active.
* The shared clipboard carries text only, no images or files.
* Try mode was tested with Limine and an initramfs that has AHCI. Most distro kernels have
  it built in or in the initramfs. If yours was built with `autodetect` on a machine that
  uses NVMe only, it may not find its disks in the VM.

## License

MIT, see [LICENSE](LICENSE).

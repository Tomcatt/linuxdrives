#!/usr/bin/env bash
# linuxdrives.sh - WSL side of linuxdrives.ps1. Runs as root inside the distro.
#
# Everything here is read-only by construction: every newly attached disk and
# partition is locked with `blockdev --setro` before anything else looks at it,
# so the kernel itself refuses writes no matter what md/xfs/btrfs try to do.
#
#   prepare            snapshot current disks, block md auto-assembly, load modules
#   protect <count>    find the newly attached disks, lock them read-only
#   hash <file>        sha256 every new disk (test runs only - slow on big disks)
#   mount              assemble md arrays read-only, mount every filesystem read-only
#   verify             check MANIFEST.sha256 in each mount + prove writes fail
#   compare <a> <b>    compare two hash files
#   release            unmount + stop arrays, keep state
#   unmount            release, then reset udev rule + state
#   boot <target> [--fresh|--selftest]  try mode: boot the disks in a VM, writes go to a kept overlay
set -uo pipefail

STATE=/run/linuxdrives
# /mnt/wsl has shared propagation: mounts made from the elevated session show up
# in every other session too (Explorer's \\wsl.localhost, normal shells)
MNT=/mnt/wsl/linuxdrives
UDEV_RULE=/run/udev/rules.d/64-md-raid-assembly.rules

die() { echo "ERROR: $*" >&2; exit 1; }
disks() { lsblk -dnro NAME,TYPE | awk '$2=="disk"{print $1}' | sort; }
# whole disks + partitions belonging to the newly attached disks
new_devs() {
	local d
	while read -r d; do
		lsblk -lnpo NAME,TYPE "/dev/$d" | awk '$2=="disk"||$2=="part"{print $1}'
	done < "$STATE/new"
}
fsprop() { blkid -p -s "$2" -o value "$1" 2>/dev/null; }

cmd_prepare() {
	mkdir -p "$STATE" "$(dirname "$UDEV_RULE")"
	# An empty rule of the same name overrides mdadm's udev rule, so arrays are
	# not auto-started read-write the moment their disks appear.
	: > "$UDEV_RULE"
	udevadm control --reload 2>/dev/null
	disks > "$STATE/before"
	local m
	for m in md_mod raid0 raid1 raid10 raid456 btrfs; do modprobe "$m" 2>/dev/null; done
	echo "prepared ($(wc -l < "$STATE/before") existing disks)"
}

cmd_protect() {
	local expected=${1:?usage: protect <count>}
	[[ -f $STATE/before ]] || die "run prepare first"
	# wsl --mount returns before the kernel has seen every disk (hotplug is
	# asynchronous, so udevadm settle may have nothing queued yet): wait for them
	local n i
	for i in $(seq 20); do
		udevadm settle 2>/dev/null
		comm -13 "$STATE/before" <(disks) > "$STATE/new"
		n=$(wc -l < "$STATE/new")
		((n < expected)) || break
		sleep 1
	done
	[[ $n -eq $expected ]] || die "expected $expected new disks, found $n"
	local dev
	for dev in $(new_devs); do
		blockdev --setro "$dev" || die "setro failed on $dev"
		[[ $(blockdev --getro "$dev") == 1 ]] || die "$dev did not go read-only"
	done
	echo "locked read-only:"
	lsblk -i -o NAME,SIZE,RO,TYPE,FSTYPE,LABEL $(sed 's|^|/dev/|' "$STATE/new")
}

cmd_hash() {
	local out=${1:?usage: hash <file>} d
	: > "$out"
	while read -r d; do
		sha256sum "/dev/$d" | awk -v d="$d" '{print d, $1}' >> "$out"
	done < "$STATE/new"
	cat "$out"
}

# md arrays whose members are on our disks
our_arrays() {
	local md s
	for md in /sys/block/md*; do
		[[ -d $md/slaves ]] || continue
		for s in "$md"/slaves/*; do
			if grep -qx "/dev/$(basename "$s")" <(new_devs); then
				echo "/dev/$(basename "$md")"
				break
			fi
		done
	done
}

mount_one() { # <dev...> -- <type> <name> <opts>
	local devs=() t name opts dir i=2
	while [[ $1 != -- ]]; do devs+=("$1"); shift; done
	shift
	t=$1 name=$2 opts=$3
	dir=$MNT/$name
	while [[ -e $dir ]]; do dir=$MNT/$name-$((i++)); done
	mkdir -p "$dir"
	if mount -t "$t" -o "$opts" "${devs[0]}" "$dir"; then
		echo "$dir" >> "$STATE/mounts"
		printf '  %-40s %-6s %s\n' "$dir" "$t" "${devs[*]}"
	else
		rmdir "$dir"
		echo "  FAILED to mount ${devs[*]} ($t, $opts)" >&2
		FAILED=1
	fi
}

cmd_mount() {
	[[ -s $STATE/new ]] || die "run protect first"
	mkdir -p "$MNT"
	: > "$STATE/mounts"
	FAILED=0
	local devs=() raid=() p a

	mapfile -t devs < <(new_devs)
	for p in "${devs[@]}"; do
		[[ $(fsprop "$p" TYPE) == linux_raid_member ]] && raid+=("$p")
	done

	if ((${#raid[@]})); then
		echo "md RAID members: ${raid[*]}"
		# anything that slipped past the udev block gets forced read-only too
		for a in $(our_arrays); do mdadm --readonly "$a"; done
		{
			echo "DEVICE ${raid[*]}"
			mdadm --examine --brief "${raid[@]}"
		} > "$STATE/mdadm.conf"
		mdadm --assemble --scan --readonly --config="$STATE/mdadm.conf"
		for a in $(our_arrays); do
			local st
			st=$(cat "/sys/block/${a#/dev/}/md/array_state")
			[[ $st == readonly ]] || die "$a is '$st', not readonly - stopping"
			echo "  $a: $(cat "/sys/block/${a#/dev/}/md/level"), $(cat "/sys/block/${a#/dev/}/md/raid_disks") disks, $st"
			devs+=("$a")
		done
	fi
	our_arrays > "$STATE/arrays"

	echo "mounting under $MNT:"
	declare -A btrfs_devs=() btrfs_label=()
	local t label uuid name
	for p in "${devs[@]}"; do
		t=$(fsprop "$p" TYPE)
		[[ -z $t ]] && continue
		label=$(fsprop "$p" LABEL)
		uuid=$(fsprop "$p" UUID)
		name=${label:-$t-${uuid:0:8}}
		name=${name//[^A-Za-z0-9._-]/_}
		case $t in
			linux_raid_member | swap) ;;
			btrfs)
				btrfs_devs[$uuid]+="$p "
				btrfs_label[$uuid]=$name
				;;
			# norecovery/noload: don't replay the journal - that would be a write
			xfs) mount_one "$p" -- xfs "$name" ro,norecovery ;;
			ext3 | ext4) mount_one "$p" -- "$t" "$name" ro,noload ;;
			crypto_LUKS) echo "  skipped $p: LUKS encrypted (not supported yet)" ;;
			LVM2_member) echo "  skipped $p: LVM (not supported yet)" ;;
			*) mount_one "$p" -- "$t" "$name" ro ;;
		esac
	done
	for uuid in "${!btrfs_devs[@]}"; do
		local list=(${btrfs_devs[$uuid]}) opts=ro,rescue=nologreplay
		for p in "${list[@]}"; do opts+=",device=$p"; done
		mount_one "${list[@]}" -- btrfs "${btrfs_label[$uuid]}" "$opts"
	done
	return $FAILED
}

cmd_verify() {
	local m rc=0
	[[ -s $STATE/mounts ]] || die "nothing mounted"
	while read -r m; do
		if [[ -f $m/MANIFEST.sha256 ]]; then
			if (cd "$m" && sha256sum --quiet -c MANIFEST.sha256); then
				echo "PASS checksums: $m ($(wc -l < "$m/MANIFEST.sha256") files)"
			else
				echo "FAIL checksums: $m"; rc=1
			fi
		fi
		if touch "$m/.writetest" 2>/dev/null; then
			echo "FAIL write was allowed: $m"; rc=1
		else
			echo "PASS write refused: $m"
		fi
	done < "$STATE/mounts"
	return $rc
}

cmd_compare() { # <before> <after>
	if cmp -s "$1" "$2"; then
		echo "PASS all $(wc -l < "$1") member disks byte-identical before/after"
	else
		echo "FAIL member disks changed:"; diff "$1" "$2"; return 1
	fi
}

# unmount + stop arrays, but keep the disk list (so `hash` still works)
cmd_release() {
	local m a
	if [[ -f $STATE/mounts ]]; then
		tac "$STATE/mounts" | while read -r m; do umount "$m" && rmdir "$m"; done
		: > "$STATE/mounts"
	fi
	# fallback for a lost state file: anything still mounted under $MNT
	findmnt -rn -o TARGET | grep "^$MNT/" | sort -r | while read -r m; do umount "$m" && rmdir "$m"; done
	[[ -f $STATE/new ]] && for a in $(our_arrays); do mdadm --stop "$a"; done
	btrfs device scan --forget 2>/dev/null
	echo "released"
}

cmd_unmount() {
	cmd_release
	rm -f "$UDEV_RULE"
	udevadm control --reload 2>/dev/null
	rm -rf "$STATE"
	pkill -f "$VM_TAG" && sleep 2   # a try-mode VM left running
	rm -rf "$VMDIR"
	pkill -f '^sleep 2147483647$'   # keepalive started by linuxdrives.ps1
	echo "unmounted"
}

# --- try mode: boot the attached disks in a VM, every write goes to an overlay ---
#
# Each disk is opened read-only by QEMU (on top of the kernel's setro lock) and
# stacked under a qcow2 overlay. The guest sees normal writable disks; its writes
# land in the overlay. Overlays are kept between sessions in $KEEP_ROOT/<target>,
# named by the disk's GPT id so a changed /dev/sdX letter can't put one on the wrong disk.
# They are only reused while the disks are exactly as they were when the overlays
# were made (same tripwire) - after a native boot they'd sit on top of changed
# data, so they're set aside in $KEEP.stale and a fresh session starts.
#
# Display: resizing the GTK window passes the new size to virtio-gpu as the
# preferred mode (KWin follows it). Clipboard: QEMU's own (GTK + vdagent) never
# notices Windows copies under WSLg, so clipsync.sh does it instead: one copy in
# WSL on WSLg's X11 clipboard, one in the guest on its Wayland clipboard, talking
# over the virtio-serial port org.linuxdrives.clipboard.
VMDIR=/var/tmp/linuxdrives-vm         # per run: monitor socket, selftest overlays
KEEP_ROOT=/var/tmp/linuxdrives-keep   # per target: kept overlays + firmware vars + tripwire they were made on
KEEP=                                 # set by cmd_boot
VM_TAG='linuxdrives try mode'         # in the VM's name, so unmount can find a VM left running
OVMF_CODE=/usr/share/edk2/x64/OVMF_CODE.4m.fd
OVMF_VARS=/usr/share/edk2/x64/OVMF_VARS.4m.fd

disk_id() { blkid -p -s PTUUID -o value "/dev/$1"; }

# firmware vars + an overlay per attached disk in <dir>, creating whatever is missing
ensure_overlays() { # <dir>
	local d f
	mkdir -p "$1"
	[[ -f $1/vars.fd ]] || cp "$OVMF_VARS" "$1/vars.fd"
	while read -r d; do
		[[ $(disk_id "$d") ]] || die "/dev/$d has no partition table id"
		f=$1/$(disk_id "$d").qcow2
		# -u: don't open the backing disk here; size given explicitly
		[[ -f $f ]] || qemu-img create -q -f qcow2 -F raw -b "/dev/$d" -u "$f" "$(blockdev --getsize64 "/dev/$d")" || die "overlay for $d failed"
	done < "$STATE/new"
	[[ $(sort -u < <(while read -r d; do disk_id "$d"; done < "$STATE/new") | wc -l) -eq $(wc -l < "$STATE/new") ]] || die "two disks share a partition table id"
}

# the VM's disk chain: real disk opened read-only, under a writable overlay
disk_nodes() { # <dir> <i> <disk>
	echo -blockdev "driver=host_device,node-name=raw$2,filename=/dev/$3,read-only=on"
	echo -blockdev "driver=qcow2,node-name=disk$2,file.driver=file,file.filename=$1/$(disk_id "$3").qcow2,backing=raw$2"
}

# one-time: the first kept session (2026-10-19) named overlays by /dev letter (ovN.qcow2 +
# ovN.src) and its tripwire by device path. Re-key both by disk id, recognising each
# disk by its ESP hash in that tripwire. Anything that doesn't match is left alone,
# so check_keep sees a mismatch and sets it all aside.
migrate_keep() { # <current tripwire>
	[[ -f $KEEP/ov0.src ]] || return 0
	local s old h id
	for s in "$KEEP"/ov*.src; do
		old=$(<"$s"); old=${old#/dev/}
		h=$(awk -v p="/dev/${old}1" '$2 == p {print $1}' "$KEEP/trip")
		id=$(awk -v h="$h" 'h != "" && $2 == "part1" && $3 == h {print $1}' "$1")
		[[ $id ]] || { echo "can't tell which disk kept overlay ${s##*/} belongs to"; return 0; }
		sed -i -E "s#^([0-9a-f]{64})  /dev/${old}([0-9]+)\$#$id part\\2 \\1#; s#^/dev/${old}([0-9]+) #$id part\\1 #" "$KEEP/trip"
		mv "${s%.src}.qcow2" "$KEEP/$id.qcow2" && rm "$s"
	done
	sort -o "$KEEP/trip" "$KEEP/trip"
}

# reuse the kept overlays only on exactly the disks they were made on
check_keep() { # <current tripwire>
	[[ -d $KEEP ]] || return 0
	migrate_keep "$1"
	if [[ -f $KEEP/trip ]] && cmp -s "$KEEP/trip" "$1"; then
		echo "continuing the last try-mode session ($(du -sh "$KEEP" | cut -f1) of changes)"
		return
	fi
	echo "the disks changed since the last try-mode session (booted natively?) - its changes"
	echo "no longer fit them, so they are set aside in $KEEP.stale and a fresh session starts"
	rm -rf "$KEEP.stale"
	mv "$KEEP" "$KEEP.stale"
}

# feed HMP monitor commands slowly enough that none are dropped
feed() { sleep 1; local c; for c in "$@"; do echo "$c"; sleep 1; done; echo quit; }

cmd_boot() { # <target> [--fresh | --selftest]
	local target=${1:?usage: boot <target> [--fresh|--selftest]}
	shift
	[[ $target =~ ^[A-Za-z0-9_-]+$ ]] || die "bad target name '$target'"
	KEEP=$KEEP_ROOT/$target
	[[ -s $STATE/new ]] || die "run protect first"
	[[ -e /dev/kvm ]] || die "/dev/kvm missing - nested virtualization is off in WSL"
	command -v qemu-system-x86_64 > /dev/null || die "qemu not installed (pacman -S qemu-desktop edk2-ovmf)"
	! pgrep -f "$VM_TAG" > /dev/null || die "a try-mode VM is already running"

	local args=() i d f cmds=() out disks=()
	mapfile -t disks < "$STATE/new"
	rm -rf "$VMDIR"
	mkdir -p "$VMDIR"
	if [[ ${1:-} == --selftest ]]; then
		# write through the same nodes the VM uses (paused, no guest disk devices -
		# those hold the write lock): data must land in the overlay only
		ensure_overlays "$VMDIR"
		for i in "${!disks[@]}"; do
			mapfile -t -O "${#args[@]}" args < <(disk_nodes "$VMDIR" "$i" "${disks[i]}" | tr ' ' '\n')
			cmds+=("qemu-io disk$i \"write -P 0xa5 0 64M\"" "qemu-io disk$i \"write -P 0x5a 512M 64M\"" "qemu-io disk$i \"read -P 0xa5 0 64M\"")
		done
		out=$(feed "${cmds[@]}" | qemu-system-x86_64 -S -machine q35,accel=kvm -m 512M -display none -nodefaults -monitor stdio "${args[@]}" 2>&1 |
			tr -d '\033' | sed -E 's/\[[KD]//g')
		grep -aoE '(wrote|read) [0-9/]+ bytes at offset [0-9]+' <<< "$out" | sed 's/^/  /'
		rm -rf "$VMDIR"
		[[ $(grep -aoE 'wrote [0-9]+/[0-9]+ bytes' <<< "$out" | wc -l) -eq $((2 * ${#disks[@]})) ]] && ! grep -aqE 'failed|rror' <<< "$out" || die "selftest writes did not all succeed"
		echo "selftest writes went through the VM chain"
		return
	fi

	if [[ ${1:-} == --fresh && -d $KEEP ]]; then
		echo "--fresh: discarding the last try-mode session ($(du -sh "$KEEP" | cut -f1))"
		rm -rf "$KEEP"
	fi
	tripwire > "$STATE/trip-before"
	check_keep "$STATE/trip-before"
	[[ -f $KEEP/trip ]] || echo "starting a new try-mode session"
	ensure_overlays "$KEEP"
	[[ -f $KEEP/trip ]] || cp "$STATE/trip-before" "$KEEP/trip"
	(($(df --output=avail -B1G "$KEEP" | tail -1) < 50)) && echo "WARNING: under 50G free for the overlays in $KEEP"
	# a VM that was killed rather than shut down can leave unreferenced clusters behind;
	# reclaiming those is the one repair that can't touch data. backing:null - the
	# /dev/sdX name recorded in the overlay may be some other disk by now
	for f in "$KEEP"/*.qcow2; do
		qemu-img check -q -r leaks "json:{\"driver\":\"qcow2\",\"file\":{\"driver\":\"file\",\"filename\":\"$f\"},\"backing\":null}" || die "$f is damaged - check it with qemu-img check, or start over with -Fresh"
	done

	for i in "${!disks[@]}"; do
		mapfile -t -O "${#args[@]}" args < <(disk_nodes "$KEEP" "$i" "${disks[i]}" | tr ' ' '\n')
		args+=(-device "ide-hd,bus=ahci.$i,drive=disk$i")
	done
	echo "booting in try mode - nothing the VM writes reaches the disks"
	export DISPLAY=${DISPLAY:-:0}
	# shared clipboard, host end: waits for QEMU's socket, ends when QEMU closes it.
	# A copy in $VMDIR keeps spaces in the script's own path away from socat
	local clip=
	if command -v xclip > /dev/null; then
		install -m 700 "$(dirname "$(readlink -f "$0")")/clipsync.sh" "$VMDIR/clipsync.sh"
		(for i in $(seq 30); do
			[[ -S $VMDIR/clip.sock ]] && exec socat UNIX-CONNECT:"$VMDIR/clip.sock" EXEC:"$VMDIR/clipsync.sh host $VMDIR"
			sleep 1
		done) &
		clip=$!
	else
		echo "note: no shared clipboard - install xclip in WSL for it"
	fi
	# QEMU's window goes through XWayland, the way resizing was tested
	GDK_BACKEND=${VM_GDK_BACKEND:-x11} qemu-system-x86_64 \
		-name "$target - $VM_TAG (disks untouched; changes kept in an overlay)" \
		-machine q35,accel=kvm -cpu host -smp "${VM_CPUS:-8}" -m "${VM_MEM:-16G}" \
		-drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
		-drive "if=pflash,format=raw,file=$KEEP/vars.fd" \
		-device ich9-ahci,id=ahci "${args[@]}" \
		-device virtio-vga,xres=1920,yres=1080 -display gtk,zoom-to-fit=off \
		-device virtio-serial-pci \
		-chardev "socket,id=clip,path=$VMDIR/clip.sock,server=on,wait=off" \
		-device virtserialport,chardev=clip,name=org.linuxdrives.clipboard \
		-nic user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:"${VM_SSH_PORT:-2223}"-:22 \
		-device qemu-xhci -device usb-tablet \
		-monitor "unix:$VMDIR/monitor.sock,server=on,wait=off" \
		${VM_EXTRA:-}
	local rc=$?
	[[ $clip ]] && { kill "$clip" 2> /dev/null; wait "$clip" 2> /dev/null; }
	rm -rf "$VMDIR"
	((rc == 0)) || echo "ERROR: QEMU failed (exit $rc) - see its message above"
	echo "VM exited ($rc); session kept in $KEEP ($(du -sh "$KEEP" | cut -f1)) - Boot -Fresh starts over"
	tripwire > "$STATE/trip-after"
	if cmp -s "$STATE/trip-before" "$STATE/trip-after"; then
		echo "PASS disks unchanged (md event counters + small partitions identical)"
	else
		echo "FAIL something reached the disks:"; diff "$STATE/trip-before" "$STATE/trip-after"; return 1
	fi
	return $rc
}

# Cheap whole-run write detector for big disks: any write through md bumps the
# member superblocks' Events/Update Time, and Linux rewrites loader/random-seed
# on the ESP every boot - so hash the small partitions and record md counters.
# Lines are keyed "<disk id> part<N>" and sorted, so /dev letters don't matter.
tripwire() {
	local p id n
	for p in $(new_devs); do
		[[ $(lsblk -dno TYPE "$p") == part ]] || continue
		id=$(disk_id "$(basename "$(readlink -f "/sys/class/block/${p##*/}/..")")")
		n=$(<"/sys/class/block/${p##*/}/partition")
		case $(fsprop "$p" TYPE) in
			linux_raid_member) echo "$id part$n $(mdadm --examine "$p" | grep -E 'Update Time|Events' | tr -s ' ' | tr '\n' ' ')" ;;
			*) (($(blockdev --getsize64 "$p") <= 16 * 1024 ** 3)) && echo "$id part$n $(sha256sum < "$p" | cut -d' ' -f1)" ;;
		esac
	done | sort
}

# braces + exit: bash parses this whole block before running it, so editing this
# file while a long command (boot) runs can't make it resume mid-way into new text
{
	cmd=${1:-}
	shift || true
	case $cmd in
		prepare | protect | hash | mount | verify | compare | release | unmount | boot) "cmd_$cmd" "$@" ;;
		*) die "usage: $0 prepare|protect <n>|hash <file>|mount|verify|compare <a> <b>|release|unmount|boot <target> [--fresh|--selftest]" ;;
	esac
	exit
}

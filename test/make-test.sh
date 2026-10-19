#!/usr/bin/env bash
# make-test.sh <md|btrfs> - build a 4-disk RAID10 test array on freshly attached
# test VHDs, laid out like the CachyOS drives (small first partition + big
# "Linux filesystem" partition), fill it with test data and a MANIFEST.sha256.
# DESTRUCTIVE - only ever pointed at the test VHDs by make-test-arrays.ps1.
set -euo pipefail

kind=${1:?usage: make-test.sh md|btrfs}
STATE=/run/linuxdrives
mapfile -t new < <(comm -13 "$STATE/before" <(lsblk -dnro NAME,TYPE | awk '$2=="disk"{print $1}' | sort))

# guard: exactly 4 new disks, each exactly 1 GiB - the test VHDs and nothing else
[[ ${#new[@]} -eq 4 ]] || { echo "expected 4 new disks, got ${#new[@]}" >&2; exit 1; }
for d in "${new[@]}"; do
	size=$(blockdev --getsize64 "/dev/$d")
	[[ $size -eq 1073741824 ]] || { echo "/dev/$d is $size bytes, not a 1 GiB test VHD" >&2; exit 1; }
done

parts=()
for d in "${new[@]}"; do
	sfdisk -q "/dev/$d" <<-EOF
		label: gpt
		size=64MiB, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B
		type=0FC63DAF-8483-4772-8E79-3D69D8477DE4
	EOF
	partprobe "/dev/$d" 2>/dev/null || blockdev --rereadpt "/dev/$d"
	udevadm settle
	mkfs.vfat -n BOOT "/dev/${d}1" > /dev/null
	parts+=("/dev/${d}2")
done

mnt=$(mktemp -d)
case $kind in
	md)
		mdadm --create /dev/md/ldtest --run --level=10 --raid-devices=4 --metadata=1.2 --assume-clean "${parts[@]}"
		mkfs.xfs -q -L testxfs /dev/md/ldtest
		mount /dev/md/ldtest "$mnt"
		;;
	btrfs)
		mkfs.btrfs -q -f -L testbtrfs -d raid10 -m raid10 "${parts[@]}"
		mount -o "device=${parts[1]},device=${parts[2]},device=${parts[3]}" "${parts[0]}" "$mnt"
		;;
esac

# test data: random binaries, nested dirs, odd filenames, a symlink
mkdir -p "$mnt/photos/2026/october" "$mnt/docs" "$mnt/spaces and ünïcödé"
head -c 150M /dev/urandom > "$mnt/big.bin"
for i in $(seq 1 200); do head -c $((RANDOM * 8)) /dev/urandom > "$mnt/photos/2026/october/img_$i.raw"; done
echo "hello from the $kind test array" > "$mnt/docs/readme.txt"
echo "unicode ok" > "$mnt/spaces and ünïcödé/fïlé (1).txt"
ln -s docs/readme.txt "$mnt/link-to-readme"
(cd "$mnt" && find . -type f ! -name MANIFEST.sha256 -print0 | xargs -0 sha256sum > MANIFEST.sha256)
echo "$kind: $(wc -l < "$mnt/MANIFEST.sha256") files, $(du -sh "$mnt" | cut -f1)"

umount "$mnt"
rmdir "$mnt"
[[ $kind == md ]] && mdadm --stop /dev/md/ldtest
btrfs device scan --forget 2>/dev/null || true
echo "built $kind test array on ${new[*]}"

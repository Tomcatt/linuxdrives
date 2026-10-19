#!/bin/sh
# Shared text clipboard between the try-mode VM and Windows, over the virtio-serial port
# org.linuxdrives.clipboard. The same script runs at both ends:
#   host  - in WSL, started by linuxdrives.sh; talks to WSLg's X11 clipboard (which WSLg
#           keeps in sync with Windows), stdin/stdout connected to QEMU's end of the port
#   guest - in the guest's desktop session (autostart); talks to the Wayland clipboard
# Each copy goes over as one base64 line. A hash of the last text sent or received keeps
# a received copy from being sent straight back. Text only; nothing is written to disk
# but that hash.
#   needs: host xclip, guest wl-clipboard
set -u
umask 077
sum() { sha256sum | cut -d' ' -f1; }

case ${1:-} in
_send) # stdin: the clipboard now. Send it unless it's empty or what we last saw.
	last=$2/clipsync.last
	t=$(cat; echo x); t=${t%x}
	[ -n "$t" ] || exit 0
	h=$(printf %s "$t" | sum)
	[ "$h" = "$(cat "$last" 2> /dev/null)" ] && exit 0
	echo "$h" > "$last"
	printf %s "$t" | base64 -w0; echo
	;;
host)
	dir=${2:?usage: clipsync.sh host <state dir>}
	# WSLg's X11 has no change notification we can wait on, so poll; reading the clipboard
	# when Windows owns it is cheap
	(while kill -0 $$ 2> /dev/null; do
		xclip -o -selection clipboard -t UTF8_STRING 2> /dev/null | "$0" _send "$dir"
		sleep 0.5
	done) &
	trap 'kill $! 2> /dev/null' EXIT
	trap exit HUP INT TERM
	put() { xclip -selection clipboard > /dev/null 2>&1; }
	;;
guest)
	dir=${XDG_RUNTIME_DIR:?clipsync needs XDG_RUNTIME_DIR (run it in the desktop session)}
	port=/dev/virtio-ports/org.linuxdrives.clipboard
	[ -e "$port" ] || { echo "no $port - not in a linuxdrives try-mode VM" >&2; exit 1; }
	# a virtio port can be open only once, so both directions share this one descriptor
	exec 0<> "$port" 1>&0
	wl-paste --type text --watch "$0" _send "$dir" &
	trap 'kill $! 2> /dev/null' EXIT
	trap exit HUP INT TERM
	put() { wl-copy > /dev/null 2>&1; }
	;;
*) echo "usage: clipsync.sh host <state dir> | guest" >&2; exit 2 ;;
esac

# the other end's copies
while IFS= read -r l; do
	t=$(printf %s "$l" | base64 -d; echo x); t=${t%x}
	printf %s "$t" | sum > "$dir/clipsync.last"
	printf %s "$t" | put
done

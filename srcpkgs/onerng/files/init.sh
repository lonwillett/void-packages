# sh source file

# Based on the OneRNG scripts: http://onerng.info/onerng
# See /usr/share/doc/onerng/README.Void

# Parameters:
#
#   ONERNGDEV -- Path of tty device (usually "/dev/ttyACM0")
#	NB: "${ONERNGDEV#/dev/}" should be free of any "/" characters, or
#	other special characters (it is used in the lockfile name).
#
# User parameters (settable in /etc/sv/rngd-onerng/conf):
#
#   ONERNG_MODE_COMMAND
#   ONERNG_VERIFY_FIRMWARE
#
# This script will:
#
#   Open (rw) the OneRNG device as fd 0.
#   Lock the OneRNG device.
#   Initialise the OneRNG device.
#   Verify the firmware signature, if requested.
#
# Note that fd 0 (stdin) will be open to the device when this script
# returns, and there is a lock (flock) held on it.

umask 0177

if [ -z "$ONERNGDEV" -o ! -c "${ONERNGDEV}" ]; then
    echo "Bad device: $ONERNGDEV" 2>&1
    exit 1
fi

###### OBTAIN DEVICE LOCKS

LOCKFILE="/var/lock/LCK..${ONERNGDEV#/dev/}"
LOCKTEMP="$LOCKFILE.tmp$$"

# Open device as fd 0 (stdin), and flock it
exec <>"$ONERNGDEV"
if [ $? -ne 0 ] || ! flock -n -x 0; then
    exec </dev/null
    echo "onerng: Can't lock $ONERNGDEV" >&2
    exit 1
fi

# Create a UUCP style lockfile for the tty node
if [ -e "$LOCKFILE" ]; then
    touch -d 'now - 3 minutes' "$LOCKTEMP"
    if [ "$LOCKFILE" -ot "$LOCKTEMP" ] && [ ! -e /proc/"$(head -1 "$LOCKFILE")" ]
    then
	# Quietly clean up stale lockfile.
	# (Only do this if lockfile doesn't contain a valid PID, and
	# is older than 3 minutes).
	# xxx Race condition here!
	rm -f "$LOCKFILE"
    fi
fi
echo $$ > "$LOCKTEMP"
chmod 644 "$LOCKTEMP"
if ! mv "$LOCKTEMP" "$LOCKFILE"; then
    rm -f "$LOCKTEMP"
    flock -u 0
    exec </dev/null
    echo "onerng: Couldn't lock tty: $LOCKFILE" >&2
    exit 1
fi

TEMPFILE=""
cleanup()
{
    if [ -n "$TEMPFILE" ]; then rm -f "$TEMPFILE"; TEMPFILE=""; fi
    rm -f "$LOCKFILE"
    flock -u 0
    exec </dev/null
}

trap 'cleanup' EXIT INT TERM


###### DEVICE INITIALISATION

stty -F /proc/self/fd/0 raw -echo clocal -crtscts

# loop waiting for things to come up (i.e. until we get some data)
# xxx There's probably a better way to do this.
i=0
TEMPFILE="$(mktemp)"
while [ ! -s "$TEMPFILE" ]; do
    i=$((i+1))
    if [ $i -gt 200 ]; then
	# something is broken
	echo "onerng: device not responding: $ONERNGDEV" >&2
	exit 2
    fi
    # off, produce nothing, flush
    echo "cmd0" >&0		# standard noise
    echo "cmdO" >&0		# turn it on
    dd if="$ONERNGDEV" of=$TEMPFILE bs=1 >/dev/null &
    pid=$!
    stty -F /proc/self/fd/0 raw -echo clocal -crtscts
    sleep 0.05

    echo "cmdo" >&0		# turn it off
    echo "cmd4" >&0		# turn off noise gathering
    echo "cmdw" >&0		# flush entropy pool
    sleep 0.05
    kill $pid
    wait $pid
done


###### FIRMWARE VERIFICATION

# Check firmware signature, if required
if [ "x$ONERNG_VERIFY_FIRMWARE" = "x1" ]; then
    sleep 0.1
    # read data into temp file
    truncate --size=0 "$TEMPFILE"
    dd if="$ONERNGDEV" iflag=fullblock of=$TEMPFILE bs=4 >/dev/null &
    pid=$!
    sleep 0.02

    echo "cmdO" >&0		# start it
    echo "cmdX" >&0		# extract image
    # wait a while, should be done, kill it
    sleep 3.5
    kill $pid
    echo "cmdo" >&0		# turn it off
    echo "cmdw" >&0		# flush entropy pool
    wait $pid

    # process the data, verify its signature, log any errors
    if ! python /usr/share/onerng/onerng_verify.py $TEMPFILE < /dev/null; then
	# failed: it's a bad or compromised board
	echo "onerng: firmware verification failed" >&2
	exit 2
    fi
fi

rm -f "$TEMPFILE"
TEMPFILE=""


###### HANDOVER TO USER (rngd)

# waste some entropy
dd if="$ONERNGDEV" of=/dev/null bs=10k count=1 >/dev/null &
pid=$!

# start the device
echo "${ONERNG_MODE_COMMAND:-cmd0}" >&0
echo "cmdO" >&0
wait $pid

trap - EXIT INT TERM
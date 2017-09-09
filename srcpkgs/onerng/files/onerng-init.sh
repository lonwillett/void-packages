# sh source file

# Based on the OneRNG 3.5 scripts: https://github.com/OneRNG/onerng.github.io

# Parameters:
#
#   $RNGDEV -- OneRNG device path
#   $TTYNAME -- Name of tty device for $RNGDEV
#	NB: "$RNGDEV" and "/dev/$TTYNAME" must be the same device.
#	NB: "$TTYNAME" must not contain "/" or other special characters.
#   $RUNLINK -- Name of symlink to device that we should create
#
# User parameters (settable in /etc/sv/onerng/conf):
#
#   $ONERNG_VERIFY_FIRMWARE
#   $ONERNG_MODE_COMMAND
#
# The usual setup is:
#
#   "/dev/ttyACM0" is the device node for the OneRNG device.
#   "/dev/onerng" is a symlink --> "ttyACM0" (created by udev).
#   RNGDEV="/dev/onerng"
#   TTYNAME="ttyACM0"
#   RUNLINK="/run/hwrng"
#
# This script will:
#
#   Open the OneRNG device as fd 0.
#   Lock and initalise the OneRNG device.
#   Create the symlink "/run/hwrng" --> "/dev/ttyACM0".

umask 0177

###### OBTAIN DEVICE LOCKS

LOCKFILE="/var/lock/LCK..$TTYNAME"

# Open device as fd 0 (stdin), and flock it
exec <>"$RNGDEV"
if [ $? -ne 0 ] || ! flock -n -x 0; then
    exec </dev/null
    echo "onerng: Can't lock $RNGDEV" >&2
    exit 1
fi

# Create a UUCP style lockfile for the tty node
TEMPFILE="$LOCKFILE.tmp$$"
if [ -e "$LOCKFILE" ]; then
    touch -d 'now - 3 minutes' "$TEMPFILE"
    if [ "$LOCKFILE" -ot "$TEMPFILE" ] && [ ! -e /proc/"$(head -1 "$LOCKFILE")" ]
    then
	# Quietly clean up old lockfile.
	# (Only do this if lockfile doesn't contain a valid PID, and
	# is older than 3 minutes).
	# xxx Race condition here!
	rm -f "$LOCKFILE"
    fi
fi
echo $$ > "$TEMPFILE"
chmod 644 "$TEMPFILE"
if ! mv "$TEMPFILE" "$LOCKFILE"; then
    rm -f "$TEMPFILE"
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

trap 'cleanup' EXIT

###### DEVICE INITIALISATION

stty raw -echo clocal -crtscts >&0

# loop waiting for things to come up (i.e. until we get some data)
# xxx There's probably a better way to do this.
i=0
TEMPFILE="$(mktemp)"
while [ ! -s "$TEMPFILE" ]; do
    i=$((i+1))
    if [ $i -gt 200 ]; then
	# something's broken
	echo "onerng: device not responding: $RNGDEV" >&2
	exit 2
    fi
    # off, produce nothing, flush
    echo "cmd0" >&0		# standard noise
    echo "cmdO" >&0		# turn it on
    dd if="$RNGDEV" of=$TEMPFILE bs=1 >/dev/null &
    pid=$!
    stty raw -echo clocal -crtscts >&0
    sleep 0.05

    echo "cmdo" >&0		# turn it off
    echo "cmd4" >&0		# turn off noise gathering
    echo "cmdw" >&0		# flush entropy pool
    kill $pid
    wait $pid
done

###### FIRMWARE VERIFICATION

# Check firmware signature, if required
if [ "x$ONERNG_VERIFY_FIRMWARE" != "x0" ]; then

    sleep 0.1
    # read data into temp file
    truncate --size=0 "$TEMPFILE"
    dd if="$RNGDEV" iflag=fullblock of=$TEMPFILE bs=4 >/dev/null &
    pid=$!
    sleep 0.02

    echo "cmdO" >&0		# start it
    echo "cmdX" >&0		# extract image
    # wait a while, should be done, kill it
    sleep 3.5
    kill $pid
    echo "cmdo" >&0		# turn it off
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

###### HANDOVER TO RNGD

# waste some entropy
dd if="$RNGDEV" of=/dev/null bs=10k count=1 >/dev/null &
pid=$!

# start the device
echo "$ONERNG_MODE_COMMAND" >&0
echo "cmdO" >&0
wait $pid

[ -n "$RUNLINK" ] && ln -f -s "/dev/$TTYNAME" "$RUNLINK"

trap - EXIT

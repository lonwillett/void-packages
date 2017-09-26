#!/bin/sh

# Based on the OneRNG 3.5 scripts: https://github.com/OneRNG/onerng.github.io

set -e
RNGDEV="/dev/onerng"

# Test for presence of device
if [ ! -c "$RNGDEV" ]; then
    echo "$0: Device not present: $RNGDEV" >&2
    exit 1
fi

# Stop onerng service
echo "Stopping onerng service..."
sv stop onerng

# Pause, to let things settle
sleep 2

# Make sure device has basic initialisation
stty -F "$RNGDEV" raw -echo clocal -crtscts
dd if="$RNGDEV" of=/dev/null bs=1 >/dev/null &
pid=$!
sleep 0.05
echo "cmdo" > "$RNGDEV"		# turn it off
echo "cmd4" > "$RNGDEV"		# turn off noise gathering
echo "cmdw" > "$RNGDEV"		# flush entropy pool
sleep 0.05
kill $pid
wait $pid

# Extract firmware image
# Assumes that the device is already initialised
echo "Extracting firmware..."
TEMPFILE="$(mktemp)"
dd if="$RNGDEV" iflag=fullblock of=$TEMPFILE bs=4 >/dev/null &
pid=$!
sleep 0.02

echo "cmdO" > "$RNGDEV"		# start it
echo "cmdX" > "$RNGDEV"		# extract image
# wait a while, should be done, kill it
sleep 3.5
kill $pid
echo "cmdo" > "$RNGDEV"		# turn it off
wait $pid

# process the data, verify its signature, log any errors
echo "Checking firmware signature..."
if ! python /usr/share/onerng/onerng_verify.py $TEMPFILE < /dev/null; then
    # failed: it's a bad or compromised board
    echo "onerng: firmware verification failed" >&2
    exit 2
fi
exit 0

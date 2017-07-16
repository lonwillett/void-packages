# sh source file


# Redefine the following function to filter out files/directories/
# symlinks that you don't want included in the checksum.
#
# Return 0 to include the file, 1 to exclude it.
#
# First arg is file name, second is file type ("f", "d", or "l").
#
# Cd'ed to directory containing file.
#
# Filtering out a directory filters out entire subtree.
#
# Default version filters everything staring with ".git"
#
checksum_filter()
{
    case "$1" in
	.git*)
	    return 1;
	    ;;
    esac
    return 0
}


# The following function checksums stdin.
# Change it if you don't like sha256.
checksum_stream()
{
    sha256sum | cut -d " " -f 1
}


dircontents()
{
    # Return contents of current directory, as used for checksum calculations.
    # This means a list of checksums of the individual files,
    # where each checksum includes file name and type, as well
    # as its contents.

    # We rely on the shell sorting the wild card expansion consistently
    for f in .* *; do
	if [ "x." = "x$f" -o "x.." = "x$f" ]; then
	    continue
	fi
	if [ -L "$f" ]; then
	    ftype="l"
	elif [ -f "$f" ]; then
	    ftype="f"
	elif [ -d "$f" ]; then
	    ftype="d"
	else
	    # Ignore devices and other such things
	    continue
	fi
	# Allow the function checksum_filter to choose
	# which files to ignore.
	if ! checksum_filter "$f" "$ftype"; then
	    continue
	fi
	# Print a checksum of file type, file name, and file contents
	(
	    echo -n "$ftype$f\0"
	    case "$ftype" in
		l)
		    readlink "$f"
		    ;;
		f)
		    cat "$f"
		    ;;
		d)
		    cd "$f"
		    dircontents
		    ;;
	    esac
	) | checksum_stream
    done
 }

# This is the main show: checksum a directory
# Alas, most errors will be ignored. But with the
# intended usage, this doesn't matter.
checksum_dir()
{
    if [ $# -ne 1 -o ! -d "$1" ]; then
	echo "Usage: checksum_dir DIRNAME" >&2
	return 1
    fi
    # Use a subshell, so "cd" doesn't mess up the
    # existing process. Also allows us to set LC_ALL.
    (
	LC_ALL=C
	export LC_ALL
	cd "$1"
	dircontents | checksum_stream
    )
}

#!/bin/sh
# Arguments are passed separately by QML; paths and URLs are never shell code.
if [ "$#" -ne 4 ]; then
    echo 'Usage: preview-cache.sh PATH URL USER_AGENT MINUTES' >&2
    exit 2
fi
case "$4" in
    ''|*[!0-9]*) exit 2 ;;
esac
[ "$4" -gt 0 ] || exit 2
name=${1##*/}
case "$name" in
    wallhaven-*) ;;
    *) exit 2 ;;
esac
case "$name" in
    *.part) exit 2 ;;
esac

dir=$(dirname -- "$1")
mkdir -p -- "$dir" || exit 1
# Leave unrelated files, subdirectories and downloads in progress alone.
find "$dir" -maxdepth 1 -type f -name 'wallhaven-*' ! -name '*.part' \
    ! -name "$name" -mmin +"$4" -delete 2>/dev/null

# QML starts a new validity interval on reuse, so renew the disk timestamp too.
if [ -s "$1" ]; then
    touch -c -- "$1" || exit 1
    [ -s "$1" ] && exit 0
fi

trap 'rm -f -- "$1.part"' 0
trap 'exit 1' 1 2 15
for attempt in 1 2; do
    if dms dl --connect-timeout 10 --timeout 180 --user-agent "$3" \
        -o "$1.part" "$2" >/dev/null 2>&1 && [ -s "$1.part" ]; then
        mv -- "$1.part" "$1" && exit 0
    fi
    [ "$attempt" -eq 2 ] || sleep 1
done
exit 1

#! /usr/bin/env bash

_ttl=0
_size_limit=0
_node_limit=0

declare -a dirs
declare -a ttls
declare -a size_limits
declare -a node_limits

usage() {
    echo "$0 [SPEC1 [SPEC2 [...]]]"
    echo "Each SPEC is a directory followed by at least one limit option"
    echo
    echo "SPEC: OPTIONS DIR"
    echo "Each option can be specified multiple times; they only apply"
    echo "to the directory that follows them on the command line."
    echo
    echo "OPTIONS"
    echo
    echo "  -t, --ttl SEC"
    echo "      If greater than 0, files older than SEC seconds are subject"
    echo "      to eviction. (default: 0)"
    echo
    echo "  -s, --size-limit SIZE"
    echo "      If greater than 0, evict files in LRU order until the files"
    echo "      in the directory account for no greater than SIZE bytes."
    echo "      (default: 0)"
    echo
    echo "  -n, --node-limit COUNT"
    echo "      If greater than 0, evict files in LRU order until the number"
    echo "      of files in the directory are no greater than COUNT."
    echo "      (default: 0)"
    echo
    echo "EXAMPLES"
    echo
    echo "Keep no more than 100 files in /A.  Remove files from /A if they"
    echo "are more than a day old.  Limit the storage consumed by files from"
    echo "/B to 48k.  Remove files from /B if they are more than a week old."
    echo
    echo "$0 -n 100 -t $(( 60*60*24 )) /A -s 48k -t $(( 60*60*24*7 )) /B"
    echo

    exit 1
}

while [ "${#@}" -gt 0 ] ; do
    arg="$1" ; shift
    case "$arg" in
      -t|--ttl)
        _ttl="$1" ; shift
        ;;
      -s|--size-limit)
        _size_limit="$1" ; shift
        ;;
      -n|--node-limit)
        _node_limit="$1" ; shift
        ;;
      -h|--help)
        usage
        ;;
      *)
        if [ "$_ttl"        '!=' 0 -o \
             "$_size_limit" '!=' 0 -o \
             "$_node_limit" '!=' 0    ] ; then

            i="${#dirs[@]}"
            dirs[$i]="$arg"

            [ -d "$arg" ] || mkdir "$arg" &> /dev/null

            ttls[$i]="$_ttl"
            size_limits[$i]="$_size_limit"
            node_limits[$i]="$_node_limit"

            _ttl=0
            _size_limit=0
            _node_limit=0
        fi
        ;;
    esac
done

if [ "${#dirs[@]}" '=' '0' ] ; then
    echo "No limits specified; nothing to do."
    usage
fi

_trap="rm -rf \"\$tmp\""
_trap="${_trap} ; killall entr &> /dev/null"
_trap="${_trap} ; \\exit"
trap "$_trap" INT TERM QUIT EXIT

tmp="$( mktemp -d )"
mkdir "$tmp/signal"

patrol() {
    local result=0
    local n="${#dirs[@]}"
    local i

    for ((i=0; i<n; ++i)) ; do
        local dir="${dirs[$i]}"
        local ttl="${ttls[$i]}"
        local size_limit="${size_limits[$i]}"
        local node_limit="${node_limits[$i]}"

        if [ "$ttl" '!=' '0' ] ; then
            if [ "$result" '=' '0' ] ; then
                find "$dir" -mindepth 1 \
                            -maxdepth 1 \
                            -not -newerat "$ttl seconds ago" |
                    grep -q '.'

                if [ "$?" '=' '0' ] ; then
                    result="1"
                fi
            fi

            find "$dir" -mindepth 1                       \
                        -maxdepth 1                       \
                        -not -newerat "$ttl seconds ago"  \
                        -exec rm -rf -- '{}' +            \
                        -exec echo "TTL ($ttl) Expired:" '{}' ';'
        fi

        local within_limits=0
        while [ "$within_limits" '=' '0' ] ; do
            within_limits=1

            if [ "$size_limit" '!=' '0' ] ; then
                if du -s -t "$size_limit" "$dir" | grep -q '.' ; then
                    du -s -t "-$size_limit" "$dir" | grep -q '.'
                    if [ "$?" '!=' '0' ] ; then
                        within_limits=0
                    fi
                fi
            fi

            if [ "$within_limits" '=' '1' ] ; then
                if [ "$node_limit" '!=' '0' ] ; then
                    local nodes="$(
                        find "$dir" -mindepth 1 -maxdepth 1 | wc -l )"
                    if [ "$nodes" -gt "$node_limit" ] ; then
                        within_limits=0
                    fi
                fi
            fi

            if [ "$within_limits" '=' '0' ] ; then
                result=1
                find "$dir" -mindepth 1 \
                            -maxdepth 1 \
                            -exec stat -c "%X {}" '{}' ';' |
                sort -n |
                head -n 1 |
                cut -d\  -f 2 |
                while read X ; do
                    echo "Evicting $X"
                    rm -rf "$X"
                done
            fi
        done
    done

    return $result
}

( exit 2 )
while [ "$?" '=' '2' ] ; do
    until patrol ; do true ; done

    killall entr &> /dev/null

    find "${dirs[@]}" -mindepth 1 -maxdepth 1 | head -n 1 | grep -q '.'
    if [ "$?" '=' '0' ] ; then
        script="x=\"$tmp/signal/dummy\""
        script="$script ; [ -f \"\$x\" ] && rm -f \"\$x\" || touch \"\$x\""

        ( find "${dirs[@]}" -mindepth 1 -maxdepth 1 |
               entr -p bash -c "$script" &> /dev/null & )
    fi

    (
        for dir in "${dirs[@]}" ; do
            echo "$dir"
        done
        echo "$tmp/signal"
    ) | entr -p -d true &> /dev/null
done


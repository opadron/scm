#! /usr/bin/env bash

_ttl=0
_size_limit=0
_node_limit=0

declare -a dirs
declare -a ttls
declare -a size_limits
declare -a node_limits

usage() {
    echo "$0 INTERVAL [SPEC1 [SPEC2 [...]]]"
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
    echo "  INTERVAL"
    echo "      Trigger a collection cycle every INTERVAL seconds."
    echo
    echo "EXAMPLES"
    echo
    echo "Keep no more than 100 files in /A.  Remove files from /A if they"
    echo "are more than a day old.  Limit the storage consumed by files from"
    echo "/B to 48k.  Remove files from /B if they are more than a week old."
    echo "Enforce these constraints with a collection cycle triggered every 30"
    echo "seconds."
    echo
    echo "$0 30 -n 100 -t $(( 60*60*24 )) /A -s 48k -t $(( 60*60*24*7 )) /B"
    echo

    exit 1
}

if [ "${#@}" -le 0 ] ; then
    usage
fi

poll_interval="$1" ; shift

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

ps -ef | awk '$0~/sle{2}p/&&$3=='$$'{print $2}'


_trap="kill \"\$sleep_pid\" &> /dev/null"
_trap="${_trap} ; \\exit"
trap "$_trap" INT TERM QUIT EXIT

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

true
while [ "$?" '=' '0' ] ; do
    until patrol ; do true ; done
    sleep "$poll_interval" &
    sleep_pid="$!"
    wait "$sleep_pid"
done


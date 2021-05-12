#!/bin/bash
#
# SPDX-License-Identifier: Apache-2.0
#
# download RPMs/SRPMs from different sources.
# this script was originated by Brian Avery, and later updated by Yong Hu

# set -o errexit
# set -o nounset

# By default, we use "sudo" and we don't use a local dnf.conf. These can
# be overridden via flags.

SUDOCMD="sudo -E"
RELEASEVER="--releasever=8"
DNFCONFOPT=""

DL_RPMS_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}" )" )"

source $DL_RPMS_DIR/utils.sh

usage() {
    echo "$0 [-n] [-c <dnf.conf>] [-s|-S|-u|-U] [-x] <rpms_list> <match_level> "
    echo ""
    echo "Options:"
    echo "  -n: Do not use sudo when performing operations"
    echo "  -c: Use an alternate dnf.conf rather than the system file"
    echo "  -x: Clean log files only, do not run."
    echo "  rpm_list: a list of RPM files to be downloaded."
    echo "  match_level: value could be L1, L2 or L3:"
    echo "    L1: use name, major version and minor version:"
    echo "        vim-7.4.160-2.el7 to search vim-7.4.160-2.el7.src.rpm"
    echo "    L2: use name and major version:"
    echo "        using vim-7.4.160 to search vim-7.4.160-2.el7.src.rpm"
    echo "    L3: use name:"
    echo "        using vim to search vim-7.4.160-2.el7.src.rpm"
    echo "    K1: Use Koji rather than dnf repos as a source."
    echo "        Koji has a longer retention period than epel mirrors."
    echo ""
    echo "  Download Source Options:  Only select one of these."
    echo "    -s: Download from StarlingX mirror only"
    echo "    -S: Download from StarlingX mirror, upstream as backup (default)"
    echo "    -u: Download from original upstream sources only"
    echo "    -U: Download from original upstream sources, StarlingX mirror as backup"
    echo ""
    echo "Returns: 0 = All files downloaded successfully"
    echo "         1 = Some files could not be downloaded"
    echo "         2 = Bad arguements or other error"
    echo ""
}


CLEAN_LOGS_ONLY=0
dl_rc=0

# Permitted values of dl_source
dl_from_stx_mirror="stx_mirror"
dl_from_upstream="upstream"
dl_from_stx_then_upstream="$dl_from_stx_mirror $dl_from_upstream"
dl_from_upstream_then_stx="$dl_from_upstream $dl_from_stx_mirror"

# Download from what source?
#   dl_from_stx_mirror = StarlingX mirror only
#   dl_from_upstream   = Original upstream source only
#   dl_from_stx_then_upstream = Either source, STX prefered (default)"
#   dl_from_upstream_then_stx = Either source, UPSTREAM prefered"
dl_source="$dl_from_stx_then_upstream"
dl_flag=""

distro="centos"

MULTIPLE_DL_FLAG_ERROR_MSG="Error: Please use only one of: -s,-S,-u,-U"

multiple_dl_flag_check () {
    if [ "$dl_flag" != "" ]; then
        echo "$MULTIPLE_DL_FLAG_ERROR_MSG"
        usage
        exit 1
    fi
}

# Parse option flags
while getopts "c:nxD:sSuUh" o; do
    case "${o}" in
        n)
            # No-sudo
            SUDOCMD=""
            ;;
        x)
            # Clean only
            CLEAN_LOGS_ONLY=1
            ;;
        c)
            # Use an alternate dnf.conf
            DNFCONFOPT="-c $OPTARG"
            grep -q "releasever=" $OPTARG && RELEASEVER="--$(grep releasever= ${OPTARG})"
            ;;
        D)
            distro="${OPTARG}"
            ;;

        s)
            # Download from StarlingX mirror only. Do not use upstream sources.
            multiple_dl_flag_check
            dl_source="$dl_from_stx_mirror"
            dl_flag="-s"
            ;;
        S)
            # Download from StarlingX mirror first, only use upstream source as a fallback.
            multiple_dl_flag_check
            dl_source="$dl_from_stx_then_upstream"
            dl_flag="-S"
            ;;
        u)
            # Download from upstream only. Do not use StarlingX mirror.
            multiple_dl_flag_check
            dl_source="$dl_from_upstream"
            dl_flag="-u"
            ;;
        U)
            # Download from upstream first, only use StarlingX mirror as a fallback.
            multiple_dl_flag_check
            dl_source="$dl_from_upstream_then_stx"
            dl_flag="-U"
            ;;

        h)
            # Help
            usage
            exit 0
            ;;
        *)
            usage
            exit 2
            ;;
    esac
done
shift $((OPTIND-1))

if [ $# -lt 2 ]; then
    usage
    exit 2
fi

if [ "$1" == "" ]; then
    echo "Need to supply the rpm file list"
    exit 2;
else
    rpms_list=$1
    echo "using $rpms_list as the download name lists"
fi

match_level="L1"

if [ ! -z "$2" -a "$2" != " " ];then
    match_level=$2
fi

timestamp=$(date +%F_%H%M)
echo $timestamp

export DL_MIRROR_LOG_DIR="${DL_MIRROR_LOG_DIR:-./logs}"
export DL_MIRROR_OUTPUT_DIR="${DL_MIRROR_OUTPUT_DIR:-./output/stx/CentOS/}"

MDIR_SRC="${DL_MIRROR_OUTPUT_DIR}/Source"
mkdir -p "$MDIR_SRC"
MDIR_BIN="${DL_MIRROR_OUTPUT_DIR}/Binary"
mkdir -p "$MDIR_BIN"

LOGSDIR="${DL_MIRROR_LOG_DIR}"
from=$(get_from $rpms_list)
LOG="$LOGSDIR/${match_level}_failmoved_url_${from}.log"
MISSING_SRPMS="$LOGSDIR/${match_level}_srpms_missing_${from}.log"
MISSING_RPMS="$LOGSDIR/${match_level}_rpms_missing_${from}.log"
FOUND_SRPMS="$LOGSDIR/${match_level}_srpms_found_${from}.log"
FOUND_RPMS="$LOGSDIR/${match_level}_rpms_found_${from}.log"
cat /dev/null > $LOG
cat /dev/null > $MISSING_SRPMS
cat /dev/null > $MISSING_RPMS
cat /dev/null > $FOUND_SRPMS
cat /dev/null > $FOUND_RPMS


if [ $CLEAN_LOGS_ONLY -eq 1 ];then
    exit 0
fi

STOP_SCHEDULING=0
FOUND_ERRORS=0
MAX_WORKERS=8
workers=0
max_workers=$MAX_WORKERS

# An array that maps worker index to pid, or to two special values
# 'Idle' indicates no running thread.
# 'Busy' indicates the worker is allocated, but it's pid isn't known yet.
declare -A dl_env

#
# init_dl_env: Init the array that maps worker index to pid.
#
init_dl_env () {
    local i=0
    local stop

    stop=$((max_workers-1))
    for i in $(seq 0 $stop); do
        dl_env[$i]='Idle'
    done
}

#
# get_idle_dl_env: Find an idle worker, mark it allocated
#                  and return it's index.
get_idle_dl_env () {
    local i=0
    local stop

    stop=$((max_workers-1))
    if [ $stop -ge 255 ]; then
        stop=254
    fi

    for i in $(seq 0 $stop); do
        if [ ${dl_env[$i]} == 'Idle' ]; then
            dl_env[$i]='Busy'
            return $i
        fi
    done

    return 255
}

#
# set_dl_env_pid: Set the pid of a previously allocated worker
#
set_dl_env_pid () {
    local idx=$1
    local val=$2
    dl_env[$idx]=$val
}

#
# release_dl_env: Mark a worker as idle.  Call after reaping the thread.
#
release_dl_env () {
    local idx=$1
    dl_env[$idx]='Idle'
}

#
# reaper: Look for worker threads that have exited.
#         Check/log it's exit code, and release the worker.
#         Return the number of threads reaped.
#
reaper ()  {
    local reaped=0
    local last_reaped=-1
    local i=0
    local stop
    local p=0
    local ret=0

    stop=$((max_workers-1))
    if [ $stop -ge 255 ]; then
        stop=254
    fi

    while [ $reaped -gt $last_reaped ]; do
        last_reaped=$reaped
        for i in $(seq 0 $stop); do
            p=${dl_env[$i]}
            if [ "$p" == "Idle" ] || [ "$p" == "Busy" ]; then
                continue
            fi
            # echo "test $i $p"
            kill -0 $p &> /dev/null
            if [ $? -ne 0 ]; then
                wait $p
                ret=$?
                workers=$((workers-1))
                reaped=$((reaped+1))
                release_dl_env $i
                if [ $ret -ne 0 ]; then
                    sleep 1
                    echo "ERROR: $FUNCNAME (${LINENO}): Failed to download in 'b$i'"
                    cat "$DL_MIRROR_LOG_DIR/$i" >> $DL_MIRROR_LOG_DIR/errors
                    echo "ERROR: $FUNCNAME (${LINENO}): Failed to download in 'b$i'" >> $DL_MIRROR_LOG_DIR/errors
                    echo "" >> $DL_MIRROR_LOG_DIR/errors
                    FOUND_ERRORS=1
                fi
            fi
        done
    done
    return $reaped
}

#
# download_worker: Download one file.
#                  This is the entry point for a worker thread.
#
download_worker () {
    local dl_idx=$1
    local ff="$2"
    local _level=$3

    local rpm_name=""
    local dest_dir=""
    local rc=0
    local dl_result=1
    local lvl=""
    local download_cmd=""
    local download_url=""
    local SFILE=""
    local _arch=""

    _arch=$(get_arch_from_rpm $ff)
    rpm_name="$(get_rpm_name $ff)"
    dest_dir="$(get_dest_directory $_arch)"

    if [ ! -e $dest_dir/$rpm_name ]; then
        for dl_src in $dl_source; do
            case $dl_src in
                $dl_from_stx_mirror)
                    lvl=$dl_from_stx_mirror
                    ;;
                $dl_from_upstream)
                lvl=$_level
                    ;;
                *)
                    echo "Error: Unknown dl_source '$dl_src'"
                    continue
                    ;;
            esac

            download_cmd="$(get_download_cmd $ff $lvl)"

            echo "Looking for $rpm_name"
            echo "--> run: $download_cmd"
            if $download_cmd ; then
                download_url="$(get_url $ff $lvl)"
                SFILE="$(get_rpm_level_name $rpm_name $lvl)"
                process_result "$_arch" "$dest_dir" "$download_url" "$SFILE"
                dl_result=0
                break
            else
                echo "Warning: $rpm_name not found"
            fi
        done

        if [ $dl_result -eq 1 ]; then
            echo "Error: $rpm_name not found"
            echo "missing_srpm:$rpm_name" >> $LOG
            echo $rpm_name >> $MISSING_SRPMS
            rc=1
        fi
    else
        echo "Already have $dest_dir/$rpm_name"
    fi
    return $rc
}

# Function to download different types of RPMs in different ways
download () {
    local _file=$1
    local _level=$2
    local _list=""
    local _from=""

    local _arch=""


    FOUND_ERRORS=0
    _list=$(cat $_file)
    _from=$(get_from $_file)

    echo "now the rpm will come from: $_from"
    for ff in $_list; do
        # Free up a worker if none available
        while [ $workers -ge $max_workers ]; do
            reaper
            reaped=$?
            if [ $reaped -eq 0 ]; then
                sleep 0.1
            fi
        done

        # Allocate a worker.  b=the worker index
        workers=$((workers+1))
        get_idle_dl_env
        b=$?
        if [ $b -ge 255 ]; then
            echo "get_idle_dl_env failed to find a free slot"
            exit 1
        fi
        PREFIX="b$b"

        # Launch a thread in the background
        ( download_worker $b $ff $_level 2>&1 | sed "s#^#${PREFIX}: #"  | tee $DL_MIRROR_LOG_DIR/$b; exit ${PIPESTATUS[0]} ) &

        # Record the pid of background process
        pp=$!
        set_dl_env_pid $b $pp
    done

    # Wait for remaining workers to exit
    while [ $workers -gt 0 ]; do
        reaper
        reaped=$?
        if [ $reaped -eq 0 ]; then
            sleep 0.1
        fi
    done

    return $FOUND_ERRORS
}


# Init the pool of worker threads
init_dl_env


# Prime the cache
loop_count=0
max_loop_count=5
echo "${SUDOCMD} dnf ${YUMCONFOPT} ${RELEASEVER} makecache"
while ! ${SUDOCMD} dnf ${YUMCONFOPT} ${RELEASEVER} makecache fast ; do
    # To protect against intermittent 404 errors, we'll retry
    # a few times.  The suspected issue is pulling repodata
    # from multiple source that are temporarily inconsistent.
    loop_count=$((loop_count + 1))
    if [ $loop_count -gt $max_loop_count ]; then
        break
    fi
    echo "makecache retry: $loop_count"

    # Wipe the inconsistent data from the last try
    echo "dnf ${DNFCONFOPT} ${RELEASEVER} clean all"
    dnf ${DNFCONFOPT} ${RELEASEVER} clean all
done


# Download files
if [ -s "$rpms_list" ];then
    echo "--> start searching $rpms_list"
    download $rpms_list $match_level
    if [ $? -ne 0 ]; then
        dl_rc=1
    fi
fi

echo "Done!"

exit $dl_rc

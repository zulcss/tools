#!/bin/bash
# tb.sh - tbuilder commands
#
# Subcommands:
# env - Display a selection of configuration values
# exec - Starts a shell inside a running container
# run - Starts a container
# stop - Stops a running container
#
# Configuration
# tb.sh expects to find its configuration file buildrc in the current
# directory, like Vagrant looks for Vagrantfile.

SCRIPT_DIR=$(cd $(dirname "$0") && pwd)
WORK_DIR=$(pwd)

# Load tbuilder configuration
if [[ -r ${WORK_DIR}/buildrc ]]; then
    source ${WORK_DIR}/buildrc
fi

CMD=$1

TC_CONTAINER_NAME=${MYUNAME}-centos-builder
TC_CONTAINER_TAG=local/${MYUNAME}-stx-builder:8.1.1911
TC_DOCKERFILE=Dockerfile
NO_CACHE=0

function create_container {
    local EXTRA_ARGS=""

    if [ ! -z ${MY_EMAIL} ]; then
        EXTRA_ARGS+="--build-arg MY_EMAIL=${MY_EMAIL}"
    fi

    if [ $NO_CACHE -eq 1 ]; then
        EXTRA_ARGS+=" --no-cache"
    fi

    docker build \
        --build-arg MYUID=$(id -u) \
        --build-arg MYUNAME=${USER} \
        ${EXTRA_ARGS} \
        --ulimit core=0 \
        --network host \
        -t ${TC_CONTAINER_TAG} \
        -f ${TC_DOCKERFILE} \
        .
}

function exec_container {
    echo "docker cp ${WORK_DIR}/buildrc ${TC_CONTAINER_NAME}:/home/${MYUNAME}"
    docker cp ${WORK_DIR}/buildrc ${TC_CONTAINER_NAME}:/home/${MYUNAME}
    docker cp ${WORK_DIR}/localrc ${TC_CONTAINER_NAME}:/home/${MYUNAME}
    docker exec -it --user=${MYUNAME} -e MYUNAME=${MYUNAME} ${TC_CONTAINER_NAME} script -q -c "/bin/bash" /dev/null
}

function run_container {
    # create localdisk
    mkdir -p ${LOCALDISK}/designer/${MYUNAME}/${PROJECT}
    #create centOS mirror
    mkdir -p ${HOST_MIRROR_DIR}/CentOS

    docker run -it --rm \
        --name ${TC_CONTAINER_NAME} \
        --detach \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v $(readlink -f ${LOCALDISK}):/${GUEST_LOCALDISK} \
        -v ${HOST_MIRROR_DIR}:/import/mirrors:ro \
        -v /sys/fs/cgroup:/sys/fs/cgroup:ro \
        -v ~/.ssh:/mySSH:ro \
        --tmpfs /tmp \
        --tmpfs /run \
        -e "container=docker" \
        -e MYUNAME=${MYUNAME} \
        --privileged=true \
        --security-opt seccomp=unconfined \
        ${TC_CONTAINER_TAG}
}

function stop_container {
    docker stop ${TC_CONTAINER_NAME}
}

function kill_container {
    docker kill ${TC_CONTAINER_NAME}
}

function clean_container {
    docker rm ${TC_CONTAINER_NAME} || true
    docker image rm ${TC_CONTAINER_TAG}
}

function usage {
    echo "$0 [create|create_no_cache|run|exec|env|stop|kill|clean]"
}

case $CMD in
    env)
        echo "LOCALDISK=${LOCALDISK}"
        echo "GUEST_LOCALDISK=${GUEST_LOCALDISK}"
        echo "TC_DOCKERFILE=${TC_DOCKERFILE}"
        echo "TC_CONTAINER_NAME=${TC_CONTAINER_NAME}"
        echo "TC_CONTAINER_TAG=${TC_CONTAINER_TAG}"
        echo "SOURCE_REMOTE_NAME=${SOURCE_REMOTE_NAME}"
        echo "SOURCE_REMOTE_URI=${SOURCE_REMOTE_URI}"
        echo "HOST_MIRROR_DIR=${HOST_MIRROR_DIR}"
        echo "MY_RELEASE=${MY_RELEASE}"
        echo "MY_REPO_ROOT_DIR=${MY_REPO_ROOT_DIR}"
        echo "LAYER=${LAYER}"
        echo "MYUNAME=${MYUNAME}"
        echo "MY_EMAIL=${MY_EMAIL}"
        ;;
    create)
        create_container
        ;;
    create_no_cache)
        NO_CACHE=1
        create_container
        ;;
    exec)
        exec_container
        ;;
    run)
        run_container
        ;;
    stop)
        stop_container
        ;;
    kill)
        kill_container
        ;;
    clean)
        clean_container
        ;;
    *)
        echo "Unknown command: $CMD"
        usage
        exit 1
        ;;
esac

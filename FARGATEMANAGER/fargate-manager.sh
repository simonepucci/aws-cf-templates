#!/bin/bash
#
#
# Fargate orchestration script
# Require Cluster Name and optionally Service Name
# The script will consider folder name as the Service name
# The script will launch or update a Fargate Service reading configurations from the following files:
# seviceFolder/skipdeploy   -> do nothing if the file is present
# seviceFolder/repoenv      -> the docker image to deploy
# seviceFolder/repotag      -> the tag of the docker image to deploy
# seviceFolder/scalevalue   -> the desired number of tasks for the service
# seviceFolder/cpuvalue     -> the desired number of Cpu Units for the service
# seviceFolder/memvalue     -> the desired number of GB of memory for the service
# seviceFolder/portvalue    -> the application exposed port number
# seviceFolder/albvalue     -> the application priority in the Alb listener rules
# seviceFolder/albhealth    -> the application health check path for the service
# seviceFolder/alertstack   -> Common Parent Stack for alerts
# seviceFolder/clusterstack -> Common Parent Stack for cluster
# seviceFolder/ddogstack    -> Common Parent Stack for datadog key


# Folder where configurations are stored 
# Required structure is: $WORKDIR/<ClusterName>/<ServiceName>/<ConfigFilesDescribedAbove>
WORKDIR="/tmp/fargate-manager"
ECSDOMAIN="ecs.lmcloud.aws"

#The following vars, should not be changed.
[ -d /dev/shm ] && TMPCACHEFOLD="/dev/shm/fargatemanager" || TMPCACHEFOLD="/tmp/fargatemanager"
mkdir -p ${TMPCACHEFOLD};
rm -f ${TMPCACHEFOLD}/*.log;

ERRLOG="${TMPCACHEFOLD}/fargate-manager-errors.$$.log"

LOCKFILE="${TMPCACHEFOLD}/fargatemanager.lok"
[ -f ${LOCKFILE} ] && { echo "A lockfile is present: ${LOCKFILE}"; echo "Verify pid"; exit 1; } || echo "$$" > ${LOCKFILE};

# Basic Utility Function
function usage(){
PNAME=`basename $0`
cat << EOF
Disclaimer: 
	This script will deploy services defined in work directory on fargate cluster.
        If service name is not passed, the script will run against all services defined in work directory.
Usage:
        $PNAME [OPTION]
Options:
        -h|H
                Print this help and exit
        -c|C
		Cluster Name (mandatory)
	-s|S
		Service Name (optional)
EOF
	exit 0;
}

# Basic Utility Function
# Write colored output recieve "colournumber" "message"
function colecho(){
	SETCOLOR_SUCCESS="echo -en \\033[1;32m";
	SETCOLOR_NORMAL="echo -en \\033[0;39m";
	SETCOLOR_FAILURE="echo -en \\033[1;31m";
	SETCOLOR_WARNING="echo -en \\033[1;33m";
	[ "$1" == "" ] && $SETCOLOR_NORMAL;
	[ "$1" == "0" ] && $SETCOLOR_SUCCESS;
	[ "$1" == "1" ] && $SETCOLOR_FAILURE;
	[ "$1" == "2" ] && $SETCOLOR_WARNING;
	[ "$2" == "" ] || echo "$2";
	$SETCOLOR_NORMAL;
}

# Basic Utility Function
function error(){
        [ "$1" == "" ] && usage || colecho "1" "$1";
        exit 1;
}

# Program Function
function cloudformateapp() {
# Create or upgrade Cloudformation for the service
    _ACTION="$1";
    [ -f ${WORKDIR}/${ENVNAME}/service-cluster-alb-fargate.yaml ] || error "CloudFormation Cluster Template: ${WORKDIR}/${ENVNAME}/service-cluster-alb-fargate.yaml is missing."
    let _MAX_SCALE=$((SCALEAPP * 4));
    aws cloudformation ${_ACTION}-stack  --stack-name ${APPDN} \
    --template-body file://${WORKDIR}/${ENVNAME}/service-cluster-alb-fargate.yaml \
    --capabilities CAPABILITY_IAM \
    --parameters \
      ParameterKey=ContainerPort,ParameterValue=${PORTAPP} \
      ParameterKey=Cpu,ParameterValue=${CPUAPP} \
      ParameterKey=Memory,ParameterValue=${MEMAPP} \
      ParameterKey=HealthCheckPath,ParameterValue=${ALBHEALTH} \
      ParameterKey=Image,ParameterValue="${BRANCH}:${TAGVER}" \
      ParameterKey=LoadBalancerDeregistrationDelay,ParameterValue=300 \
      ParameterKey=LoadBalancerPriority,ParameterValue=${ALBPRIAPP} \
      ParameterKey=LoadBalancerPath,ParameterValue=/* \
      ParameterKey=LoadBalancerHostPattern,ParameterValue=${APPDN}.${ENVNAME}.${ECSDOMAIN} \
      ParameterKey=LoadBalancerHttps,ParameterValue=false \
      ParameterKey=DesiredCount,ParameterValue=${SCALEAPP} \
      ParameterKey=MaxCapacity,ParameterValue=${_MAX_SCALE} \
      ParameterKey=MinCapacity,ParameterValue=1 \
      ParameterKey=ParentAlertStack,ParameterValue="${ALERTSTACK}" \
      ParameterKey=ParentClusterStack,ParameterValue="${CLUSTACK}" \
      ParameterKey=ParentDDogStack,ParameterValue="${DDOGSTACK}"
}

# Program Function
function setenv() {
    SERVICE_ENV="${TMPCACHEFOLD}/$$-env.log";
    # Require:
    # CLUSTER_NAME, SERVICE_NAME, ENV_FILE
    # Set the Environment variables for the app if required...
    CLUSTER_NAME="$1";
    SERVICE_NAME="$2";
    ENV_FILE="$3";

    # Read currently set env vars in service
    fargate service env list ${SERVICE_NAME} --cluster ${CLUSTER_NAME} > ${SERVICE_ENV};
    [ $? -eq 0 ] || return 1;

    sort ${SERVICE_ENV} -o ${SERVICE_ENV};
    sort ${ENV_FILE} -o ${ENV_FILE};

    #Extract KEYS only from variable files
    cut -d '=' -f 1 ${SERVICE_ENV} > ${SERVICE_ENV}.keysonly.log;
    cut -d '=' -f 1 ${ENV_FILE} > ${SERVICE_ENV}.keysonly-env.log;

    sort ${SERVICE_ENV}.keysonly.log -o ${SERVICE_ENV}.keysonly.log;
    sort ${SERVICE_ENV}.keysonly-env.log -o ${SERVICE_ENV}.keysonly-env.log;

    unset NL;
    #Unset environment variables from service if they have been removed from the ENV_FILE.
    NL=$(comm -23 ${SERVICE_ENV}.keysonly.log ${SERVICE_ENV}.keysonly-env.log | wc -l);
    if [ $NL -gt 0 ];
    then 
        comm -23 ${SERVICE_ENV}.keysonly.log ${SERVICE_ENV}.keysonly-env.log | xargs -I _ENVV_ echo "--key _ENVV_" | xargs fargate service env unset $APPDN --cluster ${ENVNAME}
    fi

    unset NL;
    #Add Variables to service that are not set or are different from the ENV_FILE.
    NL=$(comm -23 ${ENV_FILE} ${SERVICE_ENV} | wc -l);
    if [ $NL -gt 0 ];
    then
        comm -23 ${ENV_FILE} ${SERVICE_ENV} | xargs -I _ENVV_ echo "--env _ENVV_" | xargs fargate service env set $APPDN --cluster ${ENVNAME}
    fi

    # Delete temp files
    rm -f ${SERVICE_ENV} ${SERVICE_ENV}.keysonly.log ${SERVICE_ENV}.keysonly-env.log;
    return 0;
}

# Program Function
function checkapp() {
    RETVAL=4;
    SERVICE_INFO="${TMPCACHEFOLD}/$$.log";
    # Require:
    # CLUSTER_NAME, SERVICE_NAME, IMAGE_SRC, IMAGE_VERSION
    # Return 0 if SERVICE is already deployed in the right version
    # Return 4 if SERVICE is not deployed at all.
    # Return 3 if SERVICE is already deployed but IMAGE_SRC mismatch the RUNNING_IMAGE in the right version, 1 if not.
    # Return 2 if SERVICE is already deployed, the RUNNING_IMAGE is correct but the IMAGE_VERSION is different from the RUNNING_VERSION.
    # Return 1 if SERVICE is already deployed with the correct image and version but the SCALING_FACTOR mismatch the configured SCALEAPP.
    CLUSTER_NAME="$1";
    SERVICE_NAME="$2";
    IMAGE_SRC="$3";
    IMAGE_VERSION="$4";
    SCALING_FACTOR="$5";

    # Get service info if present
    fargate service info ${SERVICE_NAME} --cluster ${CLUSTER_NAME} > ${SERVICE_INFO};
    grep -q "Service not found" ${SERVICE_INFO};
    [ $? -ne 0 ] && let RETVAL=$((RETVAL - 1)) || return ${RETVAL};
    #echo "RETVAL1=${RETVAL}";

    # Check if deployed image is correct
    grep -q "${IMAGE_SRC}" ${SERVICE_INFO};
    [ $? -eq 0 ] && let RETVAL=$((RETVAL - 1)) || return ${RETVAL};
    #echo "RETVAL2=${RETVAL}";

    # Check if deployed version is correct
    grep -q "${IMAGE_SRC}:${IMAGE_VERSION}" ${SERVICE_INFO};
    [ $? -eq 0 ] && let RETVAL=$((RETVAL - 1)) || return ${RETVAL};
    #echo "RETVAL3=${RETVAL}";

    # Check if scaling factor is correct
    RUNNINGSF=$(grep -A 10 Deployments ${SERVICE_INFO} | grep -E 'primary|active' | tail -n 1 | grep "${IMAGE_SRC}:${IMAGE_VERSION}" | awk '{print $8}')
    if [ ${SCALING_FACTOR} -eq ${RUNNINGSF} ];
    then
        let RETVAL=$((RETVAL - 1));
    else
        return ${RETVAL};
    fi
    #echo "RETVAL4=${RETVAL}";

    rm -f ${SERVICE_INFO};
    return ${RETVAL};
}

# Options Parser
while getopts "hHc:C:s:S:" opt "$@"
do
        case $opt in
                c|C) ENVNAME=$OPTARG;;
                s|S) APPNAME=$OPTARG;;
                h|H) usage;;
                *) error "Unknown option!";
        esac
done

# Main ;)
[ -z "${ENVNAME}" ] && error "Cluster name is mandatory";
# Cycle on all services if no service is recieved by cmdline.
[ -z "${APPNAME}" ] || FINDAPPNAME="-iname ${APPNAME}";

TOTAPPNUM=$(find ${WORKDIR}/${ENVNAME} -mindepth 1 -maxdepth 1 -type d | wc -l);
CURAPPNUM=0
find ${WORKDIR}/${ENVNAME} -mindepth 1 -maxdepth 1 -type d ${FINDAPPNAME} | while read APPDIR;do
    ERROR=0;
    APPDN=${APPDIR##*/};
    CURAPPNUM=$((CURAPPNUM + 1))
    echo "${CURAPPNUM}-${APPDIR}:${APPDN}"
    echo
    echo "================================================================================";
    echo "= ${CURAPPNUM}/${TOTAPPNUM} =Pushing: \"${APPDN}\" on \"${ENVNAME}.${ECSDOMAIN}\"";
    echo "================================================================================";
    echo

    [ -f ${APPDIR}/skipdeploy ] && { echo "SKIPPING Forced"; echo "Found \"skipdeploy\" file for: ${APPDN}" > ${ERRLOG}; continue; }
    [ -s ${APPDIR}/repoenv ] && BRANCH=$(cat ${APPDIR}/repoenv);
    [ -s ${APPDIR}/repotag ] && TAGVER=$(cat ${APPDIR}/repotag);
    [ -f ${APPDIR}/scalevalue ] && SCALEAPP=$(cat ${APPDIR}/scalevalue);
    [ -f ${APPDIR}/cpuvalue ] && CPUAPP=$(cat ${APPDIR}/cpuvalue);
    [ -f ${APPDIR}/memvalue ] && MEMAPP=$(cat ${APPDIR}/memvalue);
    [ -f ${APPDIR}/portvalue ] && PORTAPP=$(cat ${APPDIR}/portvalue);
    [ -f ${APPDIR}/albvalue ] && ALBPRIAPP=$(cat ${APPDIR}/albvalue);
    [ -f ${APPDIR}/albhealth ] && ALBHEALTH=$(cat ${APPDIR}/albhealth);
    [ -f ${APPDIR}/alertstack ] && ALERTSTACK=$(cat ${APPDIR}/alertstack);
    [ -f ${APPDIR}/clusterstack ] && CLUSTACK=$(cat ${APPDIR}/clusterstack);
    [ -f ${APPDIR}/ddogstack ] && DDOGSTACK=$(cat ${APPDIR}/ddogstack);

    # Check if the APP already exist
    # Check if the APP version is already running
    # Check if the required scaling factor for the APP has already been set
    checkapp ${ENVNAME} ${APPDN} ${BRANCH} ${TAGVER} ${SCALEAPP};
    CHECKAPP=$?;
    echo "CHECKAPP=${CHECKAPP}"

    # Create or update APP
    [ ${CHECKAPP} -eq 4 ] && cloudformateapp create 
    [ ${CHECKAPP} -eq 3 ] && fargate service deploy ${APPDN} --image "${BRANCH}:${TAGVER}";
    [ ${CHECKAPP} -eq 2 ] && fargate service deploy ${APPDN} --image "${BRANCH}:${TAGVER}";
    [ ${CHECKAPP} -eq 1 ] && fargate service scale ${APPDN} ${SCALEAPP} --cluster ${ENVNAME};

    # Set ENV variables for the APP
    setenv ${ENVNAME} ${APPDN} "${APPDIR}/environmentvars"
done


rm -f ${LOCKFILE};
exit 0;

#!/bin/bash
#
#
# Fargate orchestration script
# Require Cluster Name and optionally Service Name
# The script will consider folder name as the Service name
# The script will launch or update a Fargate Service reading configurations from the following files:
# seviceFolder/skipdeploy    ->  do nothing if the file is present
# seviceFolder/repoenv       ->  the docker image to deploy
# seviceFolder/repotag       ->  the tag of the docker image to deploy
# seviceFolder/scalevalue    ->* the desired number of tasks for the service
# seviceFolder/minscalevalue ->* the minimum desired number of tasks for the service
# seviceFolder/maxscalevalue ->* the maximum desired number of tasks for the service
# seviceFolder/cpuvalue      ->* the desired number of Cpu Units for the service
# seviceFolder/memvalue      ->* the desired number of GB of memory for the service
# seviceFolder/portvalue     ->  the application exposed port number
# seviceFolder/albvalue      ->  the application priority in the Alb listener rules
# seviceFolder/albhealth     ->* the application health check path for the service
# seviceFolder/alertstack    ->  Common Parent Stack for alerts
# seviceFolder/clusterstack  ->  Common Parent Stack for cluster
# seviceFolder/ddogstack     ->  Common Parent Stack for datadog key
# The * means can be absent because a default value is always set.


# Folder where configurations are stored 
# Required structure is: $WORKDIR/<ClusterName>/<ServiceName>/<ConfigFilesDescribedAbove>
WORKDIR="/usr/share/fargate"
ECSDOMAIN="ecs.lmcloud.aws"

#The following vars, should not be changed.
[ -d /dev/shm ] && TMPCACHEFOLD="/dev/shm/fargatemanager" || TMPCACHEFOLD="/tmp/fargatemanager"
mkdir -p ${TMPCACHEFOLD};
rm -f ${TMPCACHEFOLD}/*.log;

ERRLOG="${TMPCACHEFOLD}/fargate-manager-errors.$$.log"

LOCKFILE="${TMPCACHEFOLD}/fargatemanager.lok"
if [ -f ${LOCKFILE} ];
then
    OLDPID=$(cat ${LOCKFILE});
    ps ax|awk '{print $1}'|grep -q "^${OLDPID}$";
    [ $? -eq 0 ] && { echo "A lockfile is present: ${LOCKFILE}"; echo "Verify pid"; exit 1; } || echo "$$" > ${LOCKFILE};
else
    echo "$$" > ${LOCKFILE};
fi

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
	-t|T
                Deploy Mode (optional FARGATE or EC2)
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
function populateworkdir() {
# Get workdir params via ssm
    SSMOUT="${TMPCACHEFOLD}/$$-ssmout.log";
    aws ssm get-parameters-by-path --max-items 10000 --path /${ENVNAME} --recursive --region eu-west-1 --output text > ${SSMOUT};
    cat ${SSMOUT} | while read line;
    do
        KEY=$(echo ${line} | awk '{print $2}');
        VAL=$(echo ${line} | awk '{print $4}');
        KEYDIR=${KEY%/*};
        DESTDIR="${WORKDIR}${KEYDIR}";
        [ -d ${DESTDIR} ] || mkdir -p ${DESTDIR};
        echo ${VAL} > ${WORKDIR}${KEY};
    done
    rm -f ${SSMOUT};
}

# Program Function
function cloudformateapp() {
# Create or upgrade Cloudformation for the service
    _ACTION="$1";
    _ENV_FILEPATTERN="$2";
    [ -f ${WORKDIR}/service-cluster-alb-ec2.yaml ] || error "CloudFormation Cluster Template: ${WORKDIR}/service-cluster-alb-ec2.yaml is missing."
    [ -f ${WORKDIR}/service-cluster-alb-fargate-envs.yaml ] || error "CloudFormation Cluster Template: ${WORKDIR}/service-cluster-alb-fargate-envs.yaml is missing."

    [ ${DEPLOYMODE} == "FARGATE" ] && CLUSTERTEMPLATE="service-cluster-alb-fargate-envs.yaml";
    [ ${DEPLOYMODE} == "EC2" ] && CLUSTERTEMPLATE="service-cluster-alb-ec2.yaml";


    # Check if environment variables number exceed the max allowed in Cloudformation template
    COUNTENV=0;
    for envfileitem in ${_ENV_FILEPATTERN}*;
    do
        let COUNTENV=$((COUNTENV + 1));
    done
    if [ ${COUNTENV} -gt 40 ];
    then
        if [ ${DEPLOYMODE} == "EC2" ];
	then
	    echo -n "Application: ";
	    colecho "0" "${APPDN}";
	    echo -n "-  Has: ";
	    colecho "1" "${COUNTENV}";
	    echo "-  Environment variables set, but with EC2 DEPLOYMODE, the limit is 40.";
	    echo "-  Exceding variables will not be set.";
	fi
    fi

    # Add the first 40 environment variables to Cloudformation template parameters
    COUNTENV=0;
    PARAMENVS="";
    for envfileitem in ${_ENV_FILEPATTERN}*;
    do
        let COUNTENV=$((COUNTENV + 1));
        [ ${COUNTENV} -gt 40 ] && continue;
        PARAMENVS="${PARAMENVS} ParameterKey=Env${COUNTENV},ParameterValue='$(cat ${envfileitem} 2>/dev/null)'";
    done

    aws cloudformation ${_ACTION}-stack  --stack-name ${APPDN} \
    --template-body file://${WORKDIR}/${CLUSTERTEMPLATE} \
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
      ParameterKey=HealthCheckGracePeriodSeconds,ParameterValue=${ALBGRACE} \
      ParameterKey=MaxCapacity,ParameterValue=${MAXSCALEAPP} \
      ParameterKey=MinCapacity,ParameterValue=${MINSCALEAPP} \
      ParameterKey=ParentAlertStack,ParameterValue="${ALERTSTACK}" \
      ParameterKey=ParentClusterStack,ParameterValue="${CLUSTACK}" \
      ParameterKey=ParentDDogStack,ParameterValue="${DDOGSTACK}" \
      ${PARAMENVS}

}

# Program Function
function setenv() {
    SERVICE_ENV="${TMPCACHEFOLD}/$$-env.log";
    # Require:
    # CLUSTER_NAME, SERVICE_NAME, ENV_FILE
    # Set the Environment variables for the app if required...
    CLUSTER_NAME="$1";
    SERVICE_NAME="$2";
    ENV_FILEPATTERN="$3";
    ENV_FILE="${SERVICE_ENV}.allenvs.log";
    for envfileitem in ${ENV_FILEPATTERN}*;
    do
        cat ${envfileitem} >> ${ENV_FILE} 2>/dev/null;
    done
    
    # Read currently set env vars in service
    if [ ${DEPLOYMODE} == "FARGATE" ];
    then
        fargate service env list ${SERVICE_NAME} --cluster ${CLUSTER_NAME} > ${SERVICE_ENV};
    elif [ ${DEPLOYMODE} == "EC2" ];
    then
	rm -f ${SERVICE_ENV}; touch ${SERVICE_ENV};
        aws ecs describe-task-definition --task-definition ${SERVICE_NAME} --output text | grep "^ENVIRONMENT" | while read line;
        do
	    echo -n "$line" | awk '{printf "%s=",$2}' >> ${SERVICE_ENV};
	    echo "$line" | awk '{$1=$2=""; print $0}' | sed "s/^[ \t]*//" >> ${SERVICE_ENV};
	done
    else
        error "1" "DEPLOYMODE: ${DEPLOYMODE} not recognized (Valid values are FARGATE or EC2)";
    fi

    sort ${SERVICE_ENV} -o ${SERVICE_ENV};
    sort ${ENV_FILE} -o ${ENV_FILE};

    #Extract KEYS only from variable files
    cut -d '=' -f 1 ${SERVICE_ENV} > ${SERVICE_ENV}.keysonly.log;
    cut -d '|' -f 1 ${ENV_FILE} > ${SERVICE_ENV}.keysonly-env.log;

    sort ${SERVICE_ENV}.keysonly.log -o ${SERVICE_ENV}.keysonly.log;
    sort ${SERVICE_ENV}.keysonly-env.log -o ${SERVICE_ENV}.keysonly-env.log;
    unset NL;
    #Unset environment variables from service if they have been removed from the ENV_FILE.
    NL=$(comm -23 ${SERVICE_ENV}.keysonly.log ${SERVICE_ENV}.keysonly-env.log | wc -l);
    if [ $NL -gt 0 ];
    then 
        [ ${DEPLOYMODE} == "FARGATE" ] && { comm -23 ${SERVICE_ENV}.keysonly.log ${SERVICE_ENV}.keysonly-env.log | xargs -I _ENVV_ echo "--key _ENVV_" | xargs fargate service env unset $APPDN --cluster ${ENVNAME}; };
	[ ${DEPLOYMODE} == "EC2" ] && { cloudformateapp update "${APPDIR}/environmentvars"; };
    fi

    unset NL;
    #Add Variables to service that are not set or are different from the ENV_FILE.
    cat ${ENV_FILE} | while read line;
    do
        echo $line | sed '0,/|/s//=/' > ${ENV_FILE}.tmp;
    done
    mv ${ENV_FILE}.tmp ${ENV_FILE};
    NL=$(comm -23 ${ENV_FILE} ${SERVICE_ENV} | wc -l);
    if [ $NL -gt 0 ];
    then
        [ ${DEPLOYMODE} == "FARGATE" ] && { comm -23 ${ENV_FILE} ${SERVICE_ENV} | xargs -I _ENVV_ echo "--env _ENVV_" | xargs fargate service env set $APPDN --cluster ${ENVNAME}; };
	[ ${DEPLOYMODE} == "EC2" ] && { cloudformateapp update "${APPDIR}/environmentvars"; };
    fi

    # Delete temp files
    rm -f ${SERVICE_ENV} ${SERVICE_ENV}.keysonly.log ${SERVICE_ENV}.keysonly-env.log ${ENV_FILE};
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
    aws ecs list-services --launch-type ${DEPLOYMODE} --cluster ${CLUSTER_NAME} --output text | awk '{print $2}' | cut -d '/' -f 2 | grep -q "${SERVICE_NAME}";
    [ $? -eq 0 ] && let RETVAL=$((RETVAL - 1)) || return ${RETVAL};
    #echo "RETVAL1=${RETVAL}";

    if [ ${DEPLOYMODE} == "FARGATE" ];
    then
        # Fill the temporary file with fargate service info
        fargate service info "${SERVICE_NAME}" --cluster ${CLUSTER_NAME} > ${SERVICE_INFO} 2>> ${SERVICE_INFO};
    elif [ ${DEPLOYMODE} == "EC2" ];
    then
	aws ecs describe-task-definition --task-definition "${SERVICE_NAME}" --output text > ${SERVICE_INFO} 2>> ${SERVICE_INFO};
    else
        error "1" "DEPLOYMODE: ${DEPLOYMODE} not recognized (Valid values are FARGATE or EC2)";
    fi
    # Check if deployed image is correct
    grep -q "${IMAGE_SRC}" ${SERVICE_INFO};
    [ $? -eq 0 ] && let RETVAL=$((RETVAL - 1)) || return ${RETVAL};
    #echo "RETVAL2=${RETVAL}";

    # Check if deployed version is correct
    grep -q "${IMAGE_SRC}:${IMAGE_VERSION}" ${SERVICE_INFO};
    [ $? -eq 0 ] && let RETVAL=$((RETVAL - 1)) || return ${RETVAL};
    #echo "RETVAL3=${RETVAL}";

    # Check if scaling factor is correct
    RUNNINGSF=$(aws ecs describe-services --cluster ${CLUSTER_NAME} --service ${SERVICE_NAME} --output text | grep 'SERVICES' | grep ${SERVICE_NAME} | awk '{print $9}');
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
while getopts "hHc:C:s:S:t:T:" opt "$@"
do
        case $opt in
                c|C) ENVNAME=$OPTARG;;
                s|S) APPNAME=$OPTARG;;
		t|T) DEPLOYMODE=$OPTARG;;
                h|H) usage;;
                *) error "Unknown option!";
        esac
done

# Main ;)
[ -z "${ENVNAME}" ] && error "Cluster name is mandatory";
# Cycle on all services if no service is recieved by cmdline.
[ -z "${APPNAME}" ] || FINDAPPNAME="-iname ${APPNAME}";
DEPLOYMODE=${DEPLOYMODE:-"FARGATE"};

if [ ${DEPLOYMODE} == "EC2" ];
then
    echo "Deploy Mode selected: ${DEPLOYMODE}";
elif [ ${DEPLOYMODE} == "FARGATE" ];
then
    echo "Deploy Mode selected: ${DEPLOYMODE}";
else
    error "1" "DEPLOYMODE: ${DEPLOYMODE} not recognized (Valid values are FARGATE or EC2)";
fi

#Fill the workdir via ssm
populateworkdir;
sleep 1;

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
    [ -f ${APPDIR}/scalevalue ] && SCALEAPP=$(cat ${APPDIR}/scalevalue); SCALEAPP=${SCALEAPP:-"1"};
    [ -f ${APPDIR}/albgracesec ] && ALBGRACE=$(cat ${APPDIR}/albgracesec); ALBGRACE=${ALBGRACE:-"120"};
    [ -f ${APPDIR}/minscalevalue ] && MINSCALEAPP=$(cat ${APPDIR}/minscalevalue); MINSCALEAPP=${MINSCALEAPP:-"1"};
    [ -f ${APPDIR}/maxscalevalue ] && MAXSCALEAPP=$(cat ${APPDIR}/maxscalevalue); MAXSCALEAPP=${MAXSCALEAPP:-"4"};
    [ -f ${APPDIR}/cpuvalue ] && CPUAPP=$(cat ${APPDIR}/cpuvalue); CPUAPP=${CPUAPP:-"512"};
    [ -f ${APPDIR}/memvalue ] && MEMAPP=$(cat ${APPDIR}/memvalue); MEMAPP=${MEMAPP:-"1024"};
    [ -f ${APPDIR}/portvalue ] && PORTAPP=$(cat ${APPDIR}/portvalue); 
    [ -f ${APPDIR}/albvalue ] && ALBPRIAPP=$(cat ${APPDIR}/albvalue); 
    [ -f ${APPDIR}/albhealth ] && ALBHEALTH=$(cat ${APPDIR}/albhealth); ALBHEALTH=${ALBHEALTH:-/};
    [ -f ${APPDIR}/alertstack ] && ALERTSTACK=$(cat ${APPDIR}/alertstack);
    [ -f ${APPDIR}/clusterstack ] && CLUSTACK=$(cat ${APPDIR}/clusterstack);
    [ -f ${APPDIR}/ddogstack ] && DDOGSTACK=$(cat ${APPDIR}/ddogstack);

    # Check if the APP already exist
    # Check if the APP version is already running
    # Check if the required scaling factor for the APP has already been set
    checkapp ${ENVNAME} ${APPDN} ${BRANCH} ${TAGVER} ${SCALEAPP};
    CHECKAPP=$?;
    echo -n "CHECKAPP=${CHECKAPP} - DEPLOYMODE=";
    colecho "0" "${DEPLOYMODE}";

    # Create or update APP
    [ ${CHECKAPP} -eq 4 ] && cloudformateapp create "${APPDIR}/environmentvars" && continue;
    if [ ${DEPLOYMODE} == "FARGATE" ];
    then
        [ ${CHECKAPP} -eq 3 ] && fargate service deploy ${APPDN} --image "${BRANCH}:${TAGVER}" --cluster ${ENVNAME} && continue;
        [ ${CHECKAPP} -eq 2 ] && fargate service deploy ${APPDN} --image "${BRANCH}:${TAGVER}" --cluster ${ENVNAME} && continue;
#       [ ${CHECKAPP} -eq 1 ] && fargate service scale ${APPDN} ${SCALEAPP} --cluster ${ENVNAME};
    elif [ ${DEPLOYMODE} == "EC2" ];
    then
        [ ${CHECKAPP} -eq 3 ] && cloudformateapp update "${APPDIR}/environmentvars" && continue;
        [ ${CHECKAPP} -eq 2 ] && cloudformateapp update "${APPDIR}/environmentvars" && continue;
#       [ ${CHECKAPP} -eq 1 ] && aws ecs update-service --cluster ${ENVNAME} --service ${APPDN} --desired-count ${SCALEAPP} --force-new-deployment
    else
        error "1" "DEPLOYMODE: ${DEPLOYMODE} not recognized (Valid values are FARGATE or EC2)";
    fi

    # Set ENV variables for the APP
    setenv ${ENVNAME} ${APPDN} "${APPDIR}/environmentvars"
done


rm -f ${LOCKFILE};
exit 0;

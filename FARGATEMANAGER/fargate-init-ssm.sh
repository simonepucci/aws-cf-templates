#!/bin/bash
#
#
#
#

# Require Cluster Name and Service Name
# -------------------------------------
#
# skipdeploy    ->  do nothing if the file is present
# repoenv       ->  the docker image to deploy
# repotag       ->  the tag of the docker image to deploy
# scalevalue    ->  the desired number of tasks for the service
# minscalevalue ->  the minimum desired number of tasks for the service
# maxscalevalue ->  the maximum desired number of tasks for the service
# cpuvalue      ->  the desired number of Cpu Units for the service
# memvalue      ->  the desired number of GB of memory for the service
# portvalue     ->  the application exposed port number
# albvalue      ->  the application priority in the Alb listener rules
# albhealth     ->  the application health check path for the service
# albgracesec   ->  the application health check grace period for the service
# clusterstack  ->  Common Parent Stack for cluster
# alertstack    ->  Common Parent Stack for alerts
# ddogstack     ->  Common Parent Stack for datadog key


# Basic Utility Function
function usage(){
PNAME=`basename $0`
cat << EOF
Disclaimer: 
	This script will set or update store parameters used by fargate-manager-ssm.sh to deploy services on Fargate cluster.
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
function checkparameter() {
    PARAM="$1";
    RESULT=$(aws ssm get-parameter --name /${ENVNAME}/${APPNAME}/${PARAM} --region eu-west-1 --output text 2>/dev/null);
    if [ $? -eq 0 ];
    then
#        KEY=$(echo ${RESULT} | awk '{print $2}');
        VAL=$(echo ${RESULT} | awk '{print $4}');
    else
#        KEY="/${ENVNAME}/${APPNAME}/${PARAM}";
	VAL="";
    fi
    echo ${VAL};
}

# Program Function
function useraskparameter() {
    PARAM="$1";
    USERPARAM="$2";
    PARAMDESCRIPT="$3";
    echo -n "Set a value for ";
    colecho "0" "${PARAM}";
    echo "This parameter means:";
    echo "    ${PARAMDESCRIPT} (press enter to keep proposed value)";
    echo
    echo -n "${PARAM} = [${USERPARAM}]: ";
    read ANSWER;
    ANSWER=${ANSWER:-${USERPARAM}};
    aws ssm put-parameter --name /${ENVNAME}/${APPNAME}/${PARAM} --region eu-west-1 --value ${ANSWER} --type String --overwrite >/dev/null;
    [ $? -eq 0 ] && colecho "0" "Param saved" || colecho "1" "There was and errod savin param! [Unexpected error]";
    echo
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
[ -z "${APPNAME}" ] && error "Serice name is mandatory";


SKIPDEPLOY=$(checkparameter skipdeploy);

REPOENV=$(checkparameter repoenv);
REPOTAG=$(checkparameter repotag);
SCALEVALUE=$(checkparameter scalevalue); SCALEVALUE=${SCALEVALUE:-"1"};
MINSCALEVALUE=$(checkparameter minscalevalue); MINSCALEVALUE=${MINSCALEVALUE:-"1"};
MAXSCALEVALUE=$(checkparameter maxscalevalue); MAXSCALEVALUE=${MAXSCALEVALUE:-"4"};
CPUVALUE=$(checkparameter cpuvalue); CPUVALUE=${CPUVALUE:-"2048"};
MEMVALUE=$(checkparameter memvalue); MEMVALUE=${MEMVALUE:-"4096"};
PORTVALUE=$(checkparameter portvalue); PORTVALUE=${PORTVALUE:-"80"};
ALBVALUE=$(checkparameter albvalue); 
ALBHEALTH=$(checkparameter albhealth); ALBHEALTH=${ALBHEALTH:-/status};
ALBGRACE=$(checkparameter albgracesec); ALBGRACE=${ALBGRACE:-"120"};
CLUSTERSTACK=$(checkparameter clusterstack); CLUSTERSTACK=${CLUSTERSTACK:-"$ENVNAME"};
ALERTSTACK=$(checkparameter alertstack); ALERTSTACK=${ALERTSTACK:-"operations-alert"};
DDOGSTACK=$(checkparameter ddogstack); DDOGSTACK=${DDOGSTACK:-"ddog-key"};

useraskparameter "repoenv" "${REPOENV}" "the docker image to deploy";
useraskparameter "repotag" "${REPOTAG}" "the tag of the docker image to deploy";
useraskparameter "scalevalue" "${SCALEVALUE}" "the desired number of tasks for the service";
useraskparameter "minscalevalue" "${MINSCALEVALUE}" "the minimum desired number of tasks for the service";
useraskparameter "maxscalevalue" "${MAXSCALEVALUE}" "the maximum desired number of tasks for the service";
useraskparameter "cpuvalue" "${CPUVALUE}" "the desired number of Cpu Units for the service (1024 -> 1 Cpu)";
useraskparameter "memvalue" "${MEMVALUE}" "the desired number of GB of memory for the service";
useraskparameter "portvalue" "${PORTVALUE}" "the application exposed port number";
useraskparameter "albvalue" "${ALBVALUE}" "the application priority in the Alb listener rules (!Must be Unique!)";
useraskparameter "albhealth" "${ALBHEALTH}" "the application health check path for the service";
useraskparameter "albgracesec" "${ALBGRACE}" "the application health check grace period for the service";
useraskparameter "clusterstack" "${CLUSTERSTACK}" "Common Parent Stack for cluster";
useraskparameter "alertstack" "${ALERTSTACK}" "Common Parent Stack Name for alerts (Should not be changed)";
useraskparameter "ddogstack" "${DDOGSTACK}" "Common Parent Stack for datadog key (Should not be changed)";

COUNTENV=0;
while :
do
    let COUNTENV=$((COUNTENV + 1));
    echo "Set environmentvars${COUNTENV} ?"
    colecho "1" "[(ctrl + c) to exit]: ";
    ENVCUR=$(checkparameter "environmentvars${COUNTENV}")
    useraskparameter "environmentvars${COUNTENV}" "${ENVCUR}" "Environment Variable ${COUNTENV}";
    echo
done

exit 0;

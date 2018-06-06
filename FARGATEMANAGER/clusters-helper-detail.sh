#!/bin/bash
#
#


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
        [ "$2" == "" ] || echo -en "$2";
        $SETCOLOR_NORMAL;
}

aws ecs list-clusters --output text | awk '{print $2}' | cut -d '/' -f 2 | while read line;
do
    BIGGER=$(aws ssm get-parameters-by-path --max-items 10000 --path /${line}/ --recursive --region eu-west-1 --output text | grep albvalue | awk {'print $4'} | sort -n | tail -n 1);
    echo -n "Last used albvalue for Cluster: ";
    colecho "0" "${line}";
    echo -n " -> ";
    colecho "1" "${BIGGER}\n";
    echo "All deployed services ordered per albvalue:";
    echo "-------------------------------------------";
    aws ssm get-parameters-by-path --max-items 10000 --path /${line}/ --recursive --region eu-west-1 --output text | grep albvalue | awk {'print $4 " -> " $2'} | sort -n | column -t;
    echo "--------------------------------------------------------------------------------";

    colecho "1" "EC2 Services:\n";
    aws ecs list-services --launch-type EC2 --cluster ${line} --output text | awk '{print $2}' | cut -d '/' -f 2
    echo;
    colecho "1" "FARGATE Services:\n";
    aws ecs list-services --launch-type FARGATE --cluster ${line} --output text | awk '{print $2}' | cut -d '/' -f 2
    echo "--------------------------------------------------------------------------------";
    echo;
done


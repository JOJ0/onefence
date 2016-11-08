#!/bin/bash

ARGS=$*

usage() {
 echo
 echo "Usage: install.sh [-u install_user] [-g install_group]"
 echo "                  [-d ONE_LOCATION] [-l] [-h]"
 echo
 echo "-d: target installation directory, if not defined it'd be root. Must be"
 echo "    an absolute path. Installation will be selfcontained"
 echo "-l: creates symlinks instead of copying files, useful for development"
 echo "-h: prints this help"
}

PARAMETERS="hlu:g:d:"

if [ $(getopt --version | tr -d " ") = "--" ]; then
    TEMP_OPT=`getopt $PARAMETERS "$@"`
else
    TEMP_OPT=`getopt -o $PARAMETERS -n 'install.sh' -- "$@"`
fi

if [ $? != 0 ] ; then
    usage
    exit 1
fi

eval set -- "$TEMP_OPT"

LINK="no"
ONEADMIN_USER=`id -u`
ONEADMIN_GROUP=`id -g`
SRC_DIR=$PWD

while true ; do
    case "$1" in
        -h) usage; exit 0;;
        -d) ROOT="$2" ; shift 2 ;;
        -l) LINK="yes" ; shift ;;
        -u) ONEADMIN_USER="$2" ; shift 2;;
        -g) ONEADMIN_GROUP="$2"; shift 2;;
        --) shift ; break ;;
        *)  usage; exit 1 ;;
    esac
done

export ROOT

if [ -z "$ROOT" ]; then
    VAR_LOCATION="/var/lib/one"
    REMOTES_LOCATION="$VAR_LOCATION/remotes"
    ETC_LOCATION="/etc/one"
else
    VAR_LOCATION="$ROOT/var"
    REMOTES_LOCATION="$VAR_LOCATION/remotes"
    ETC_LOCATION="$ROOT/etc"
fi

do_file() {
    if [ "$UNINSTALL" = "yes" ]; then
        rm $2/`basename $1`
    else
        if [ "$LINK" = "yes" ]; then
            ln -fs $SRC_DIR/$1 $2
        else
            cp -Rv $SRC_DIR/$1 $2
            if [[ "$ONEADMIN_USER" != "0" || "$ONEADMIN_GROUP" != "0" ]]; then
                chown -R $ONEADMIN_USER:$ONEADMIN_GROUP $2
            fi
        fi
    fi
}

copy_files() {
    FILES=$1
    DST=$DESTDIR$2

    mkdir -p $DST

    for f in $FILES; do
        do_file $f $DST
    done
}

create_dirs() {
    DIRS=$*

    for d in $DIRS; do
        dir=$DESTDIR$d
        mkdir -p $dir
    done
}

change_ownership() {
    DIRS=$*
    for d in $DIRS; do
        chown -R $ONEADMIN_USER:$ONEADMIN_GROUP $DESTDIR$d
    done
}

cd `dirname $0`

copy_files "host_error_linforge.rb" "$REMOTES_LOCATION/hooks/ft/"

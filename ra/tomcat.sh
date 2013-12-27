#!/bin/bash
#
# Copyr$$${CLOG_INIT}}}NIT}7-2003 Sistina Software, Inc.  All rights reserved.
# Co${CLOG_FAILED}2004-2011 Red Ha${CLOG_F${CLOG_FAILE${OCF_ERR_ARGS}
#
# This pr${OCF_ERR_GEN${${CLOG_FAILED} you can r${OCF_ERR_GENERIC}C}_SUCCEED} modify it under the terms of the GNU General Public License
# as published by the Free Software ${CLOG_FAILED}ei${CLOG_FAILED}${CLOG_SU${CLOG_FAILED}ENERIC}OCF_SUCCESS}ption) any lat${CLOG_SUCCEED}${OCF_ERR_ARGS}F_SUCCESS}stributed in the hope that it will be useful,
# but WITHOUT ANY ${CLOG_FAILED}thout even the implied warranty of
# MERCHANT${OCF_ERR_ARGS}TNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.${CLOG_FAILED}uld have received a copy of the GNU Gen${OCF_ERR_ARGS}icense
# along with this program; if not, write to the Free Software
# Founda${CLOG_FAILED}59 Temple Place - Suite 330, Boston,${OCF_ERR_ARGS}07, USA.
#

export LC_ALL=C
export LANG=C
export PATH=/bin:/sbin:/usr/bin:/usr/sbin

. $(dirname $0)/ocf-shellfuncs
. $(dirname $0)/utils/config-utils.sh
. $(dirname $0)/utils/messages.sh
. $(dirname $0)/utils/ra-skelet.sh

################################################################################
######## Preparation
################################################################################

[ -z "$OCF_CHECK_LEVEL" ] && export OCF_CHECK_LEVEL=0

# Java vars
declare JAVA_HOME
declare JAVA_OPTS

# Tomcat vars
declare CATALINA_HOME
declare CATALINA_BASE
declare CATALINA_PID
declare CATALINA_USER
declare CATALINA_GROUP
declare CATALINA_OPTS
declare CATALINA_PORT

# System tools
declare SU='/bin/su -s /bin/sh'
##

################################################################################
######## Internal functions
################################################################################

form_options() {
    # Java
    JAVA_HOME="${OCF_RESKEY_java_home:-/usr/java/default}"
    JAVA_OPTS="${JAVA_OPTS} -XX:+UseConcMarkSweepGC -Djava.awt.headless=true -server -XX:+CMSClassUnloadingEnabled"

    # Some logic on Java options

    # Memory control options
    [[ "${OCF_RESKEY_mem_start}" ]] && \
        JAVA_OPTS="${JAVA_OPTS} -Xms$((${OCF_RESKEY_mem_start}+0))m"
    [[ "${OCF_RESKEY_mem_max}" ]] && \
        JAVA_OPTS="${JAVA_OPTS} -Xmx$((${OCF_RESKEY_mem_max}+0))m -XX:MaxPermSize=$((${OCF_RESKEY_mem_max}+0))m"

    # OutOfMemory dump options
    [[ "${OCF_RESKEY_dump_path}" ]] && \
        JAVA_OPTS="${JAVA_OPTS} -XX:+HeapDumpOnOutOfMemoryError -XX:HeapDumpPath=${OCF_RESKEY_dump_path}/tomcat_`date +%Y.%m.%d-%H%M%S`.hprof"

    # Java SNMP
    [[ "${OCF_RESKEY_java_snmp_port}" ]] && [[ ${OCF_RESKEY_java_snmp_port} -gt 0 ]] && \
        JAVA_OPTS="${JAVA_OPTS} -Dcom.sun.management.snmp.port=${OCF_RESKEY_java_snmp_port} -Dcom.sun.management.snmp.interface=127.0.0.1 -Dcom.sun.management.snmp.acl.file=${CATALINA_BASE}/conf/snmp.acl"

    # Other Java options
    [[ "${OCF_RESKEY_java_options}" ]] && \
        JAVA_OPTS="${JAVA_OPTS} ${OCF_RESKEY_java_options}"

    # Form Tomcat options
    CATALINA_HOME="${OCF_RESKEY_home}"
    CATALINA_BASE="${OCF_RESKEY_home}"
    CATALINA_PID="`generate_name_for_pid_file`"
    CATALINA_USER="${OCF_RESKEY_user:-tomcat}"

    # determine group
    if [[ "`echo ${CATALINA_USER} | grep ':'`" ]]; then
        CATALINA_GROUP="`echo "${CATALINA_USER}" | cut -d ':' -f 2`"
        CATALINA_USER="`echo "${CATALINA_USER}" | cut -d ':' -f 1`"
    else
        CATALINA_GROUP="`id -ng "${CATALINA_USER}"`"
    fi

    # default port = 8080
    CATALINA_PORT="${OCF_RESKEY_port:-8080}"
    CATALINA_OPTS="-Dport.http.nonssl=${CATALINA_PORT}"

    # System tools logic
	[[ -x "/sbin/runuser" ]] && SU='/sbin/runuser -s /bin/sh'

	# Always return success, this function has no checks
	return 0
}

check_url() {
    local _url="$1"
    local _data=`curl -f "${_url}" 2>/dev/null | head -c 1 | wc -l`
    # check exit code
    [[ $? -ne 0 ]] && return 1
    # check that we received at least 1 byte of real HTTP data
    [[ ${_data} -lt 1 ]] && return 1
    # if all OK
    return 0
}

check_listen_port() {
	local _port="$1"
	local _prog="$2"
	local _res=''
	[[ -z "${_port}" ]] && return 1
	if [[ -z "${_prog}" ]]; then
	    _res=`netstat -nalp | grep "[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}:${_port} "`
	else
	    _res=`netstat -nalp 2>/dev/null | tr -s ' ' | grep "[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}:${_port} [0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}:[0-9\*]\{1,5\} LISTEN [0-9]\{1,5\}\/${_prog}" | wc -l`
	fi

	[[ $? -le 0 ]] && [[ -n "${_res}" ]] && return 0
	return 1
}



################################################################################
######## Commands
################################################################################

verify_all()
{
	clog_service_verify ${CLOG_INIT}

	if [[ -z "$OCF_RESKEY_name" ]]; then
		clog_service_verify ${CLOG_FAILED} "Invalid Name Of Service"
		return ${OCF_ERR_ARGS}
	fi

	#if [[ -z "$OCF_RESKEY_service_name" ]]; then
	#	clog_service_verify $CLOG_FAILED_NOT_CHILD
	#	return $OCF_ERR_ARGS
	#fi

    # tomcat home
	if [[ -z "$OCF_RESKEY_home" ]]; then
		clog_service_verify ${CLOG_FAILED} "tomcat home directory not specified"
		return ${OCF_ERR_ARGS}
	fi
	if [[ ! -d "$OCF_RESKEY_home" ]]; then
		clog_service_verify ${CLOG_FAILED} "tomcat home directory is invalid"
		return ${OCF_ERR_ARGS}
	fi

    # Java
	if [[ -z "${OCF_RESKEY_java_home}" ]]; then
	    clog_service_verify ${CLOG_FAILED} "Java home not specified"
	    return ${OCF_ERR_ARGS}
	fi
	if [[ ! -d "${OCF_RESKEY_java_home}" ]]; then
	    clog_service_verify ${CLOG_FAILED} "Java home is invalid"
	    return ${OCF_ERR_ARGS}
	fi
	"${OCF_RESKEY_java_home}/bin/java" -version >/dev/null 2>&1
	if [[ $? -ne 0 ]]; then
	    clog_service_verify ${CLOG_FAILED} "Java cannot start"
	    return ${OCF_ERR_ARGS}
	fi

    # Check port sanity
    if [[ "${OCF_RESKEY_port}" ]]; then
        if [[ ${OCF_RESKEY_port} -le 0 ]] || [[ ${OCF_RESKEY_port} -ge 65536 ]]; then
            clog_service_verify ${CLOG_FAILED} "tomcat port value not valid"
            return ${OCF_ERR_ARGS}
        fi
    fi

	clog_service_verify ${CLOG_SUCCEED}
	return ${OCF_SUCCESS}
}

start()
{
	clog_service_start ${CLOG_INIT}

    # Prepare PID directory
	create_pid_directory
    chown "${CATALINA_USER}:${CATALINA_GROUP}" "`dirname "${CATALINA_PID}"`"

    # Check if already running
	check_pid_file "${CATALINA_PID}"
	if [[ $? -ne 0 ]]; then
		clog_check_pid ${CLOG_FAILED} "${CATALINA_PID}"
		clog_service_start ${CLOG_FAILED}
		return ${OCF_ERR_GENERIC}
	fi

    # Start Tomcat
	${SU} "${CATALINA_USER}" -c "${CATALINA_BASE}/bin/catalina.sh start"
	if [[ $? -ne 0 ]]; then
		clog_service_start ${CLOG_FAILED}
		return ${OCF_ERR_GENERIC}
	fi

	clog_service_start ${CLOG_SUCCEED}
	return ${OCF_SUCCESS}
}

stop()
{
	clog_service_stop ${CLOG_INIT}

	stop_generic_sigkill "${CATALINA_PID}" "${OCF_RESKEY_shutdown_wait}" "${OCF_RESKEY_shutdown_wait}"
	
	if [[ $? -ne 0 ]]; then
		clog_service_stop ${CLOG_FAILED}
		return ${OCF_ERR_GENERIC}
	fi

    if [[ -e "${CATALINA_PID}" ]]; then
		rm -f "${CATALINA_PID}"
	fi
                                
	clog_service_stop ${CLOG_SUCCEED}
	return ${OCF_SUCCESS}
}

status()
{
	clog_service_status ${CLOG_INIT}

	status_check_pid "${CATALINA_PID}"
	if [[ $? -ne 0 ]]; then
		clog_service_status ${CLOG_FAILED}
		return ${OCF_NOT_RUNNING}
	fi

	# "Heavy" checks
	if [[ ${OCF_CHECK_LEVEL} -ge 10 ]]; then
		# Check body here
		check_listen_port ${CATALINA_PORT} 'java'
		if [ $? -ne 0 ]; then
			return ${OCF_NOT_RUNNING}
		fi
	fi

	# Very heavy checks
	if [[ ${OCF_CHECK_LEVEL} -ge 20 ]]; then
		# check body
        check_url "http://127.0.0.1:${CATALINA_PORT}/tomcat/info"
		if [[ $? -ne 0 ]]; then
		    clog_service_status ${CLOG_FAILED}
			return ${OCF_NOT_RUNNING}
		fi
	fi

	clog_service_status ${CLOG_SUCCEED}
	return ${OCF_SUCCESS}
}

################################################################################
######## Main
################################################################################
case $1 in
	meta-data)
		cat `echo $0 | sed 's/^\(.*\)\.sh$/\1.metadata/'`
		exit 0
		;;
	validate-all)
		verify_all
		exit $?
		;;
	start)
		verify_all && form_options && start
		exit $?
		;;
	stop)
		verify_all && form_options && stop
		exit $?
		;;
	status|monitor)
		verify_all && form_options && status
		exit $?
		;;
	restart)
		verify_all && form_options
		stop
		start
		exit $?
		;;
	*)
		echo "Usage: $0 {start|stop|status|monitor|restart|meta-data|validate-all}"
		exit ${OCF_ERR_UNIMPLEMENTED}
		;;
esac

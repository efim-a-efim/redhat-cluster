#!/bin/bash

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
declare JAVA_OPTS='-server -XX:+UseConcMarkSweepGC -Djava.awt.headless=true -XX:+CMSClassUnloadingEnabled'

# Tomcat vars
declare CATALINA_HOME
declare CATALINA_BASE
declare CATALINA_PID
declare CATALINA_USER
declare CATALINA_GROUP
declare CATALINA_OPTS
declare CATALINA_PORT

# System tools
declare SU='/bin/su -s /bin/sh -m '
declare WGET="`which wget | head -n 1`"

# Checker vars
declare CHECK_URL
##

################################################################################
######## Internal functions
################################################################################

form_options() {
    # Form Tomcat options
    export CATALINA_HOME="${OCF_RESKEY_home}"
    export CATALINA_BASE="${OCF_RESKEY_home}"
    export CATALINA_USER="${OCF_RESKEY_user:-tomcat}"
    export CATALINA_PID="`generate_name_for_pid_file`"

    # determine group
    if [[ "`echo ${CATALINA_USER} | grep ':'`" ]]; then
        CATALINA_GROUP="`echo "${CATALINA_USER}" | cut -d ':' -f 2`"
        CATALINA_USER="`echo "${CATALINA_USER}" | cut -d ':' -f 1`"
    else
        CATALINA_GROUP="`id -ng "${CATALINA_USER}"`"
    fi

    # default port = 8080
    CATALINA_PORT="${OCF_RESKEY_port:-8080}"
    CATALINA_OPTS="${CATALINA_OPTS} -Dport.http.nonssl=${CATALINA_PORT}"

    # Java
    export JAVA_HOME="${OCF_RESKEY_java_home:-/usr/java/default}"

    # Some logic on Java options

    # Memory control options
    [[ "${OCF_RESKEY_mem_start}" ]] && \
        CATALINA_OPTS="${CATALINA_OPTS} -Xms$((${OCF_RESKEY_mem_start}+0))m"
    [[ "${OCF_RESKEY_mem_max}" ]] && \
        CATALINA_OPTS="${CATALINA_OPTS} -Xmx$((${OCF_RESKEY_mem_max}+0))m"
    [[ "${OCF_RESKEY_mem_perm_max}" ]] && \
        CATALINA_OPTS="${CATALINA_OPTS} -XX:MaxPermSize=$((${OCF_RESKEY_mem_perm_max}+0))m"

    # OutOfMemory dump options
    [[ "${OCF_RESKEY_dump_path}" ]] && \
        CATALINA_OPTS="${CATALINA_OPTS} -XX:+HeapDumpOnOutOfMemoryError -XX:HeapDumpPath=${OCF_RESKEY_dump_path}/tomcat_`date +%Y.%m.%d-%H%M%S`.hprof"

    # Java SNMP
    [[ "${OCF_RESKEY_java_snmp_port}" ]] && [[ ${OCF_RESKEY_java_snmp_port} -gt 0 ]] && \
        CATALINA_OPTS="${CATALINA_OPTS} -Dcom.sun.management.snmp.port=${OCF_RESKEY_java_snmp_port} -Dcom.sun.management.snmp.interface=127.0.0.1 -Dcom.sun.management.snmp.acl.file=${CATALINA_BASE}/conf/snmp.acl"

    # JMX
    if [[ "${OCF_RESKEY_jmx_port}" ]] && [[ ${OCF_RESKEY_jmx_port} -gt 0 ]]; then
        CATALINA_OPTS="${CATALINA_OPTS} -Dcom.sun.management.jmxremote -Dcom.sun.management.jmxremote.port=${OCF_RESKEY_jmx_port} -Dcom.sun.management.jmxremote.authenticate=false -Dcom.sun.management.jmxremote.ssl=false"
    fi

    # Other Java options
    [[ "${OCF_RESKEY_java_options}" ]] && \
        JAVA_OPTS="${JAVA_OPTS} ${OCF_RESKEY_java_options}"

    export CATALINA_OPTS
    export JAVA_OPTS

    if [[ "${OCF_RESKEY_check_url}" ]]; then
        CHECK_URL="${OCF_RESKEY_check_url}"
    fi
    export CHECK_URL

	# Always return success, this function has no checks
	return 0
}

check_url() {
    local _url="$1"
    local _to="${2:-1}"
    ${WGET} -q -t 1 -T "${_to}" -O /dev/null "${_url}" >/dev/null 2>&1
    return $?
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

    # Java
	if [[ -z "${OCF_RESKEY_java_home}" ]]; then
	    clog_service_verify ${CLOG_FAILED} "Java home not specified"
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

    # Check memory options
    if [[ ${OCF_RESKEY_mem_start} -gt ${OCF_RESKEY_mem_max} ]]; then
        clog_service_verify ${CLOG_FAILED} "Max. memory is less than startup memory"
        return ${OCF_ERR_ARGS}
    fi

	clog_service_verify ${CLOG_SUCCEED}
	return ${OCF_SUCCESS}
}

status()
{
	clog_service_status ${CLOG_INIT}

	if [[ ! -d "$OCF_RESKEY_home" ]]; then
		clog_service_status ${CLOG_FAILED} "tomcat home directory is invalid"
		return ${OCF_NOT_RUNNING}
	fi

	if [[ ! -d "${OCF_RESKEY_java_home}" ]]; then
	    clog_service_status ${CLOG_FAILED} "Java home is invalid"
	    return ${OCF_NOT_RUNNING}
	fi

	ocf_log debug "Checking PID file ${CATALINA_PID}"
	status_check_pid "${CATALINA_PID}"
	if [[ $? -ne 0 ]]; then
		clog_service_status ${CLOG_FAILED}
		return ${OCF_NOT_RUNNING}
	fi
	ocf_log debug "PID file OK"

	# "Heavy" checks
	if [[ ${OCF_CHECK_LEVEL} -ge 10 ]]; then
	    ocf_log debug "Checking port listen ${CATALINA_PORT}"
		# Check body here
		check_listen_port ${CATALINA_PORT} 'java'
		if [ $? -ne 0 ]; then
		    clog_service_status ${CLOG_FAILED}
			return ${OCF_NOT_RUNNING}
		fi
		ocf_log debug "Port check OK"
	fi

	# Very heavy checks
#	if [[ ${OCF_CHECK_LEVEL} -ge 20 ]]; then
#	    ocf_log debug "Checking Tomcat by URL"
#		# check body
#        check_url "${CHECK_URL}" 10
#		if [[ $? -gt 0 ]]; then
#		    clog_service_status ${CLOG_FAILED}
#			return ${OCF_NOT_RUNNING}
#		fi
#		ocf_log debug "URL check OK"
#	fi

	clog_service_status ${CLOG_SUCCEED}
	return ${OCF_SUCCESS}
}

start()
{
	clog_service_start ${CLOG_INIT}

	if [[ ! -d "$OCF_RESKEY_home" ]]; then
		clog_service_start ${CLOG_FAILED} "tomcat home directory is invalid"
		return ${OCF_NOT_RUNNING}
	fi

	if [[ ! -d "${OCF_RESKEY_java_home}" ]]; then
	    clog_service_start ${CLOG_FAILED} "Java home is invalid"
	    return ${OCF_NOT_RUNNING}
	fi

    # Prepare PID directory
	create_pid_directory
    chown "${CATALINA_USER}:${CATALINA_GROUP}" "`dirname "${CATALINA_PID}"`"

    # Check if already running
	check_pid_file "${CATALINA_PID}"
	if [[ $? -ne 0 ]]; then
		clog_check_pid ${CLOG_FAILED} "${CATALINA_PID}"
		clog_service_start ${CLOG_FAILED}
		return ${OCF_NOT_RUNNING}
	fi

    # Test configs first
    ocf_log debug "Config test..."
	${SU} "${CATALINA_USER}" -c "${CATALINA_BASE}/bin/catalina.sh configtest" #>/dev/null 2>&1
	if [[ $? -ne 0 ]]; then
	    ocf_log debug "Config test failed"
		clog_service_start ${CLOG_FAILED}
		return ${OCF_NOT_RUNNING}
	fi

    # Start Tomcat
    ocf_log debug "Starting Tomcat..."
	${SU} "${CATALINA_USER}" -c "${CATALINA_BASE}/bin/catalina.sh start" #>/dev/null 2>&1
	if [[ $? -ne 0 ]]; then
	    ocf_log debug "Cannot start Tomcat"
		clog_service_start ${CLOG_FAILED}
		return ${OCF_NOT_RUNNING}
	fi

    clog_service_start ${CLOG_SUCCEED}
	return ${OCF_SUCCESS}

    # OK if check url not specified
#    if [[ -z "${CHECK_URL}" ]]; then
#        clog_service_start ${CLOG_SUCCEED}
#	    return ${OCF_SUCCESS}
#    fi
#    ocf_log debug "Waiting for Tomcat to fully start..."
#    local _wait_time=${OCF_RESKEY_RGMANAGER_meta_timeout}
#    while [[ ${_wait_time} -gt 2 ]]; do
#        if check_url "${CHECK_URL}" 2; then
#            clog_service_start ${CLOG_SUCCEED}
#	        return ${OCF_SUCCESS}
#	    fi
#	    sleep ${_wait_time}
#	    _wait_time=$((${OCF_RESKEY_RGMANAGER_meta_timeout}-2))
#    done

#    ocf_log debug "Failed to check Tomcat after start"
#	clog_service_start ${CLOG_FAILED}
#	return ${OCF_ERR_GENERIC}
}

stop()
{
	clog_service_stop ${CLOG_INIT}

    local _stop_wait=$((${OCF_RESKEY_RGMANAGER_meta_timeout}/2))

    ocf_log debug "Stopping Tomcat..."
    if [ -x "${CATALINA_BASE}/bin/catalina.sh" ]; then
	    ${SU} "${CATALINA_USER}" -c "${CATALINA_BASE}/bin/catalina.sh stop ${_stop_wait} -force" #>/dev/null 2>&1
        if [[ $? -eq 0 ]]; then
            clog_service_stop ${CLOG_SUCCEED}
            return ${OCF_SUCCESS}
        fi
    fi
    clog_service_stop ${CLOG_FAILED_NOT_STOPPED}

    # We shouldn't come here at all
    ocf_log debug "Killing Tomcat..."
	stop_generic_sigkill "${CATALINA_PID}" "${_stop_wait}" "${_stop_wait}"
	if [[ $? -ne 0 ]]; then
		clog_service_stop ${CLOG_FAILED_KILL}
		return ${OCF_ERR_GENERIC}
	fi

    if [[ -e "${CATALINA_PID}" ]]; then
		rm -f "${CATALINA_PID}"
	fi
                                
	clog_service_stop ${CLOG_SUCCEED}
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
	restart|recover)
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

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
[ -z "${OCF_RESKEY_RGMANAGER_meta_timeout}" ] && export OCF_RESKEY_RGMANAGER_meta_timeout=10

declare pid_file="`generate_name_for_pid_file`"
declare SU='/bin/su -s /bin/sh -m '

verify_all()
{
	clog_service_verify ${CLOG_INIT}

	if [[ -z "$OCF_RESKEY_name" ]]; then
		clog_service_verify ${CLOG_FAILED} "Invalid Name Of Service"
		return ${OCF_ERR_ARGS}
	fi

	# data directory
	if [[ -z "$OCF_RESKEY_data_directory" ]] || [[ ! -d "$OCF_RESKEY_data_directory" ]]; then
		clog_service_verify ${CLOG_FAILED} "Data directory not specified or invalid"
		return ${OCF_ERR_ARGS}
	fi

    # log directory
    if [[ "${OCF_RESKEY_log_file}" ]] && [[ ! -d "`dirname "${OCF_RESKEY_log_file}"`" ]]; then
        clog_service_verify ${CLOG_FAILED} "Log directory does not exist"
		return ${OCF_ERR_ARGS}
    fi

	clog_service_verify ${CLOG_SUCCEED}
	return ${OCF_SUCCESS}
}

status()
{
	clog_service_status ${CLOG_INIT}

	ocf_log debug "Checking PID file ${pid_file}"
	status_check_pid "${pid_file}"
	if [[ $? -ne 0 ]]; then
		clog_service_status ${CLOG_FAILED}
		return ${OCF_NOT_RUNNING}
	fi
	ocf_log debug "PID OK"

	clog_service_status ${CLOG_SUCCEED}
	return ${OCF_SUCCESS}
}

start()
{
    local _startup_time="`date '+%s'`"

	clog_service_start ${CLOG_INIT}

    check_pid_file "${pid_file}"
	if [[ $? -ne 0 ]]; then
		ocf_log warning 'Already running'
		clog_service_start ${CLOG_SUCCEED}
	    return ${OCF_SUCCESS}
	fi

    # Prepare variables
    local _user="`id -un`"
    [[ "${OCF_RESKEY_user}" ]] && _user="${OCF_RESKEY_user}"
    local _group="`id -gn "${_user}"`"
	if [[ "`echo "${OCF_RESKEY_user}" | grep ':'`" ]]; then
	    _user="`echo "${OCF_RESKEY_user}" | cut -d ':' -f 1`"
        _group="`echo "${OCF_RESKEY_user}" | cut -d ':' -f 2`"
    fi

    local _command="pg_receivexlog"
    [[ "${OCF_RESKEY_bin_path}" ]] && _command="${OCF_RESKEY_bin_path}/${_command}"
    [[ "${OCF_RESKEY_log_verbose}" -gt 0 ]] && _command="${_command} --verbose"

    # Prepare PID and data directories
    chown "${_user}:${_group}" "${OCF_RESKEY_data_directory}"
    create_pid_directory "${_user}"

    # Start
    ocf_log debug "Starting pg_receivexlog..."
	${SU} "${_user}" -c "${_command} -d '${OCF_RESKEY_connection_parameters}' -D '${OCF_RESKEY_data_directory}'" &>> "${OCF_RESKEY_log_file}" &
	echo "$!" > "${pid_file}"

	sleep "$((${OCF_RESKEY_RGMANAGER_meta_timeout}-1-`date '+%s'`+${_startup_time}))"
	check_pid_file "${pid_file}"
	if [[ $? -eq 0 ]]; then
		clog_check_pid ${CLOG_FAILED} "${pid_file}"
		clog_service_start ${CLOG_FAILED}
		return ${OCF_NOT_RUNNING}
	fi

    clog_service_start ${CLOG_SUCCEED}
	return ${OCF_SUCCESS}
}

stop()
{
	clog_service_stop ${CLOG_INIT}

    local _stop_wait=$(((${OCF_RESKEY_RGMANAGER_meta_timeout}-1)/2))

    # We shouldn't come here at all
    ocf_log debug "Killing pg_receivexlog..."
	stop_generic_sigkill "${pid_file}" "${_stop_wait}" "${_stop_wait}"
	if [[ $? -ne 0 ]]; then
		clog_service_stop ${CLOG_FAILED_KILL}
		return ${OCF_ERR_GENERIC}
	fi

    check_pid_file "${pid_file}"
	if [[ $? -ne 0 ]]; then
		clog_service_stop ${CLOG_FAILED_KILL}
		return ${OCF_ERR_GENERIC}
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
		verify_all && start
		exit $?
		;;
	stop)
		verify_all && stop
		exit $?
		;;
	status|monitor)
		verify_all status
		exit $?
		;;
	restart|recover)
		verify_all || exit $?
		stop
		start
		exit $?
		;;
	*)
		echo "Usage: $0 {start|stop|status|monitor|restart|meta-data|validate-all}"
		exit ${OCF_ERR_UNIMPLEMENTED}
		;;
esac

#!/bin/bash
#
# Copyright (C) 1997-2003 Sistina Software, Inc.  All rights reserved.
# Copyright (C) 2004-2011 Red Hat, Inc.  All rights reserved.
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA  02111-1307, USA.
#

export LC_ALL=C
export LANG=C
export PATH=/bin:/sbin:/usr/bin:/usr/sbin

. $(dirname $0)/ocf-shellfuncs
. $(dirname $0)/utils/config-utils.sh
. $(dirname $0)/utils/messages.sh
. $(dirname $0)/utils/ra-skelet.sh

declare PSQL_restart_timeout="30"
declare PSQL_connect_string="dbname=postgres user=postgres port=5432"

verify_all()
{
	clog_service_verify $CLOG_INIT

	if [ -z "$OCF_RESKEY_name" ]; then
		clog_service_verify $CLOG_FAILED "Invalid Name Of Service"
		return $OCF_ERR_ARGS
	fi
	
	# Predefines
	OCF_RESKEY_psql_path="${OCF_RESKEY_psql_path:-/usr/bin}"
	OCF_RESKEY_data_dir="${OCF_RESKEY_data_directory:-/var/lib/pgsql/9.3/data}"

	if [ ! -f "${OCF_RESKEY_data_directory}/recovery.conf" ] && [ ! -f "${OCF_RESKEY_data_directory}/recovery.done" ]; then
		clog_check_file_exist $CLOG_FAILED_NOT_FOUND "${OCF_RESKEY_data_directory}/recovery.[conf|done]"
		clog_service_verify $CLOG_FAILED
		return $OCF_ERR_ARGS
	fi

	clog_service_verify $CLOG_SUCCEED
		
	return $OCF_SUCCESS
}

form_args()
{
    PSQL_connect_string="dbname=postgres user=${OCF_RESKEY_user:-postgres} port=${OCF_RESKEY_port:-5432}"
    [ "${OCF_RESKEY_password}" ] && PSQL_connect_string="${PSQL_connect_string} password=${OCF_RESKEY_password}"
    export PSQL_connect_string
}
check_local_master()
{
	local _conn_str="${1:-host=localhost ${PSQL_connect_string}}"
	local _res=`su -l "${OCF_RESKEY_postmaster_user}" -c "${OCF_RESKEY_psql_path}/psql -A -q -t -d '${_conn_str}' -c 'select pg_is_in_recovery();'" 2>/dev/null | head -n 1 | tr -d ' '`
	[[ $? -le 0 ]] && [[ "${_res}" = "f" ]] && return 0
	return 1
}

# Get list of nodes the service may run on
get_service_nodes()
{
    local service_name="$1"
    [ -z "${service_name}" ] && return 1

    local _i=1
    local _ret=''
    local _nodename=''
    local _domain="`ccs_get "/cluster/rm/service[@name='${service_name}']/@domain"`"
    if [ "${_domain}" ]; then
        while : ; do
            _nodename="`ccs_get "/cluster/rm/failoverdomains/failoverdomain[@name='${_domain}']/failoverdomainnode[${_i}]/@name"`"
            [ -z "${_nodename}" ] && break
            _ret="${_ret} ${_nodename}"
            ((_i++))
        done
    else
        # service is running all over the cluster, just return all cluster nodes
        while : ; do
            _nodename="`ccs_get "/cluster/clusternodes/clusternode[${_i}]/@name"`"
            [ -z "${_nodename}" ] && break
            _ret="${_ret} ${_nodename}"
            ((_i++))
        done
    fi
    echo "${_ret}"
    return 0
}

# Get DB timeline
get_timeline()
{
    local _conn="${1:-host=localhost ${PSQL_connect_string}}"
    local _t="${2:--1}"

    while : ; do
        _tl="`su -l "${OCF_RESKEY_postmaster_user}" -c "${OCF_RESKEY_psql_path}/psql -q -t -A -d '${_conn}' -c 'SELECT pg_last_xlog_replay_location();'" 2>/dev/null`"
        if [ $? -eq 0 ]; then
            echo "${_tl}"
            return 0
        fi
        if [ ${_t} -lt 0 ]; then
            continue
        elif [ ${_t} -eq 0 ]; then
            break
        else
            ((_t--))
            sleep 1
            continue
        fi
    done
    return 1
}

# Wait for DB to accept connections on localhost
wait_for_db_connect()
{
    local _conn_str="${1:-host=localhost ${PSQL_connect_string}}"
    local _time=${2:--1}

    while : ; do
        su -l "${OCF_RESKEY_postmaster_user}" -c "${OCF_RESKEY_psql_path}/pg_isready -q -d \"${_conn_str}\"" &>/dev/null
        if [ $? -eq 0 ]; then
            ocf_log debug 'Postgres is ready to accept connections'
            return 0
        elif [ $? -ge 3 ]; then
            ocf_log error "Invalid connection parameters"
            return 2
        fi
        # Timeout work
        if [ ${_time} -lt 0 ]; then
            # Infinite timeout
            continue
        elif [ ${_time} -eq 0 ]; then
            # Time is over
            break
        else
            # Decrease timeout
            ((_time--))
            sleep 1
            continue
        fi
    done

    # If we reached here, xlogs didn't roll until timeout
    return 1
}

# Wait for xlog recovery to complete on local DB
wait_for_xlogs()
{
    local _conn_str="${1:-host=localhost ${PSQL_connect_string}}"
    local _time="${2:--1}"
    local _curr_xlog='00/00000000'
    local _diff=0



    while : ; do
        # Get xlog difference between prev. and current
        _diff="`su -l "${OCF_RESKEY_postmaster_user}" -c "${OCF_RESKEY_psql_path}/psql -q -t -A -d '${_conn_str}' -c \\\"SELECT pg_xlog_location_diff('${_curr_xlog}', pg_last_xlog_replay_location());\\\"" 2>/dev/null`"
        if [ $? -ne 0 ]; then
            # We simply skip connection errors, timeout will do all for us
            ocf_log error "Cannot connect to local DB or parameters are bad"
            break
        fi

        if [ ${_diff} -ne 0 ]; then
            # If we have a difference, remember last xlog and continue
            _curr_xlog="`su -l "${OCF_RESKEY_postmaster_user}" -c "${OCF_RESKEY_psql_path}/psql -q -t -A -d '${_conn_str}' -c 'SELECT pg_last_xlog_replay_location();'" 2>/dev/null`"
        else
            # If it didn't change, all OK, return from function
            return 0
        fi

        # Timeout work
        if [ ${_time} -lt 0 ]; then
            # Infinite timeout
            continue
        elif [ ${_time} -eq 0 ]; then
            # Time is over
            break
        else
            # Decrease timeout
            ((_time--))
            sleep 1
            continue
        fi
    done

    # If we reached here, xlogs didn't roll until timeout
    return 1
}

# Check archive location
check_archive()
{
    local _archive_url="${1:-${OCF_RESKEY_data_directory}/wal}"
    local _time="${2:--1}"
    local _fname="${3:-latest}"

    while : ; do
        curl -m 1 -f "${_archive_url}/${_fname}" &>/dev/null && \
            break

        # Timeout work
        if [ ${_time} -lt 0 ]; then
            # Infinite timeout
            continue
        elif [ ${_time} -eq 0 ]; then
            # Time is over, return bad status
            return 1
        else
            # Decrease timeout
            ((_time--))
            sleep 1
            continue
        fi
    done
    return 0
}

# Promote DB, with timeout
promote_db()
{
    local _time="${1:--1}"

    # Promote server
	su -l "${OCF_RESKEY_postmaster_user}" -c "${OCF_RESKEY_psql_path}/pg_ctl -D '${OCF_RESKEY_data_directory}' promote"
	if [ $? -ne 0 ]; then
		return 1
	fi
	# Recovery file
	if [ -f "${OCF_RESKEY_data_directory}/recovery.done" ]; then
	    mv "${OCF_RESKEY_data_directory}/recovery.done" "${OCF_RESKEY_data_directory}/recovery.conf"
		if [ $? -ne 0 ]; then
			return 1
		fi
	fi

	while : ; do
	    check_local_master && break
        # Timeout work
        if [ ${_time} -lt 0 ]; then
            # Infinite timeout
            continue
        elif [ ${_time} -eq 0 ]; then
            # Time is over
            break
        else
            # Decrease timeout
            ((_time--))
            sleep 1
            continue
        fi
	done
}

start()
{
	clog_service_start $CLOG_INIT

	# Check if postgres is running
	status_check_pid "${OCF_RESKEY_data_directory}/postmaster.pid"
	if [ $? -ne 0 ]; then
		clog_service_start $CLOG_FAILED
		return $OCF_NOT_RUNNING
	fi
	ocf_log debug 'Postgres process OK'

    ocf_log debug 'Waiting for Postgres to accept connections...'
    # Wait until DB accepts connections
	wait_for_db_connect "host=localhost ${PSQL_connect_string}" "${OCF_RESKEY_local_startup_timeout:-10}"
	if [ $? -ne 0 ]; then
		clog_service_start $CLOG_FAILED
		return $OCF_NOT_RUNNING
	fi
	ocf_log debug 'Local Postgres instance accepts connections'

    local _conn_str="${PSQL_connect_string}"
	# Determine if we have the latest DB version
    for _host in `get_service_nodes "${OCF_RESKEY_service_name}"`; do
        ocf_log debug "Getting timeline for host ${_host}"
        _tl="`get_timeline "host=${_host} ${PSQL_connect_string}" ${OCF_RESKEY_connection_timeout:-10}`"
        if [ $? -ne 0 ]; then
            ocf_log warning "Cannot get timeline from host ${_host}"
            # Cannot get timeline from host, so at least one host is invalid.
            # Fall back to archive recovery checks
            if [ -z "${OCF_RESKEY_archive_url}" ]; then
                # We cannot check archive, so fail
                ocf_log warning 'Archive URL not specified, cannot start'
                clog_service_start $CLOG_FAILED
                return $OCF_NOT_RUNNING
            fi
            ocf_log debug 'Waiting for xlog recovery'
            # Wait for archive recovery
            wait_for_xlogs "host=localhost ${PSQL_connect_string}" ${OCF_RESKEY_recovery_timeout:--1}
            if [ $? -ne 0 ]; then
                ocf_log error 'Xlog recovery didnt end until timeout, or DB is invalid'
                clog_service_start $CLOG_FAILED
                return $OCF_NOT_RUNNING
            fi
            ocf_log debug "Xlog recovery complete"

            ocf_log debug 'Getting last WAL file name from local DB'
            local _wal_name="`su -l "${OCF_RESKEY_postmaster_user}" -c "find '${OCF_RESKEY_data_directory}/pg_xlog' -name '????????????????????????' -printf '%f\n' | sort | tail -n 1"`"
            if [ $? -ne 0 ]; then
                ocf_log error 'Cannot get local timeline'
                clog_service_start $CLOG_FAILED
                return $OCF_NOT_RUNNING
            fi

            ocf_log debug "Checking archive for WAL file ${_wal_name}"
            check_archive "${OCF_RESKEY_archive_url}" ${OCF_RESKEY_archive_timeout:-10} "${_wal_name}"
            local _ret=$?
            if [ ${_ret} -eq 2 ]; then
                # WAL archive does not contain a valid record
                ocf_log error 'Local DB is too old, cannot recover from archive'
                clog_service_start $CLOG_FAILED
                return $OCF_NOT_RUNNING
            elif [ ${_ret} -ne 0 ]; then
                ocf_log error 'Archive not accessible or is invalid'
                clog_service_start $CLOG_FAILED
                return $OCF_NOT_RUNNING
            fi
            ocf_log debug "Archive check OK, recovery was correct"

            # Exit loop anyway
            break
        else
            ocf_log debug "Timeline for host ${_host} is ${_tl}"
            # Calculate timeline difference
            _diff="`su -l "${OCF_RESKEY_postmaster_user}" -c "${OCF_RESKEY_psql_path}/psql -q -t -A -d 'host=localhost ${PSQL_connect_string}' -c \\\"SELECT pg_xlog_location_diff('${_tl}', pg_last_xlog_replay_location());\\\"" 2>/dev/null`"
            if [ $? -ne 0 ]; then
                # Problem with local DB
                ocf_log error "Problem with local DB connection, not starting"
                clog_service_start $CLOG_FAILED
                return $OCF_NOT_RUNNING
            fi
            ocf_log debug "Timeline difference is ${_diff}"
            if [ ${_diff} -gt 0 ]; then
                # We have old DB version
                ocf_log warning "Local DB is too old, not starting master"
                clog_service_start $CLOG_FAILED
                return $OCF_NOT_RUNNING
            fi
        fi
    done

    ocf_log debug "Promoting local DB"
    # Anyway, if we're here, we have a relatively new DB, so we can start master
    promote_db "${OCF_RESKEY_promote_timeout:-10}"
    if [ $? -ne 0 ]; then
        ocf_log error "Promote problem"
        clog_service_start $CLOG_FAILED
        return $OCF_NOT_RUNNING
    fi

    ocf_log debug "Promote successful"
	clog_service_start $CLOG_SUCCEED
	return $OCF_SUCCESS;
}

stop()
{
	clog_service_stop $CLOG_INIT

	if [ -f "${OCF_RESKEY_data_directory}/recovery.done" ]; then
		mv "${OCF_RESKEY_data_directory}/recovery.done" "${OCF_RESKEY_data_directory}/recovery.conf"

		if [ $? -ne 0 ]; then
			clog_service_stop $CLOG_FAILED
			return $OCF_ERR_GENERIC
		fi
	fi

	# Check if postgres is running
	status_check_pid "${OCF_RESKEY_data_directory}/postmaster.pid"
	if [ $? -ne 0 ]; then
		clog_service_stop $CLOG_SUCCEED
		#return $OCF_ERR_GENERIC
		# If Postgres is dead, just exit
		return $OCF_SUCCESS
	fi

	# Restart Postgres to become slave
	su -l "${OCF_RESKEY_postmaster_user}" -c "${OCF_RESKEY_psql_path}/pg_ctl -D \"${OCF_RESKEY_data_directory}\" -t \"${PSQL_restart_timeout}\" -m fast restart"
	if [ $? -ne 0 ]; then
		clog_service_stop $CLOG_FAILED
		return $OCF_NOT_RUNNING
	fi
	
	clog_service_stop $CLOG_SUCCEED
	return $OCF_SUCCESS
}

status()
{
	clog_service_status $CLOG_INIT

	check_local_master
	if [ $? -eq 0 ]; then
		clog_service_status $CLOG_SUCCEED
		return $OCF_SUCCESS
	fi
	
	clog_service_status $CLOG_FAILED
	return $OCF_NOT_RUNNING
}

case $1 in
	meta-data)
		cat `echo $0 | sed 's/^\(.*\)\.sh$/\1.metadata/'`
		exit 0
		;;
	validate-all)
		verify_all && form_args
		exit $?
		;;
	start)
		verify_all && form_args && start
		exit $?
		;;
	stop)
		verify_all && form_args && stop
		exit $?
		;;
	status|monitor)
		verify_all && form_args && status
		exit $?
		;;
	restart)
		verify_all && form_args && stop && start
		exit $?
		;;
	*)
		echo "Usage: $0 {start|stop|status|monitor|restart|meta-data|validate-all}"
		exit $OCF_ERR_UNIMPLEMENTED
		;;
esac

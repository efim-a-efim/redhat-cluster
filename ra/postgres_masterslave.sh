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
declare PSQL_connect_string='host=localhost dbname=postgres'

verify_all()
{
	clog_service_verify $CLOG_INIT

	if [ -z "$OCF_RESKEY_name" ]; then
		clog_service_verify $CLOG_FAILED "Invalid Name Of Service"
		return $OCF_ERR_ARGS
	fi
	
	# Predefines
	OCF_RESKEY_psql_path="${OCF_RESKEY_psql_path:-/usr/bin}"
	OCF_RESKEY_data_dir="${OCF_RESKEY_data_directory:-/var/lib/pgsql/9.1/data}"

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
	PSQL_connect_string="${PSQL_connect_string} user=${OCF_RESKEY_user:-postgres} port=${OCF_RESKEY_port:-5432}"
	[ "${OCF_RESKEY_password}" ] && PSQL_connect_string="${PSQL_connect_string} password=${OCF_RESKEY_password}"
	return 0
}

check_local_master()
{
	#su -l "${OCF_RESKEY_postmaster_user}" -c "${OCF_RESKEY_psql_path}/psql -q -t -c 'select pg_is_in_recovery();' '${PSQL_connect_string}'" > /tmp/masterslave.log
	local _res=`su -l "${OCF_RESKEY_postmaster_user}" -c "${OCF_RESKEY_psql_path}/psql -q -t -c 'select pg_is_in_recovery();' '${PSQL_connect_string}'" 2>/dev/null | head -n 1 | tr -d ' '`
	[[ $? -le 0 ]] && [[ "${_res}" = "f" ]] && return 0
	return 1
}

start()
{
	clog_service_start $CLOG_INIT

	# Check if postgres is running
	status_check_pid "${OCF_RESKEY_data_directory}/postmaster.pid"
	if [ $? -ne 0 ]; then
		clog_service_start $CLOG_FAILED
		#return $OCF_ERR_GENERIC
		return $OCF_NOT_RUNNING
	fi

	# Promote server
	su -l "${OCF_RESKEY_postmaster_user}" -c "${OCF_RESKEY_psql_path}/pg_ctl -D '${OCF_RESKEY_data_directory}' promote"
	if [ $? -ne 0 ]; then
		clog_service_start $CLOG_FAILED
		#return $OCF_ERR_GENERIC
		return $OCF_NOT_RUNNING
	fi

	# Recovery file
	if [ -f "${OCF_RESKEY_data_directory}/recovery.done" ]; then
		mv "${OCF_RESKEY_data_directory}/recovery.done" "${OCF_RESKEY_data_directory}/recovery.conf"

		if [ $? -ne 0 ]; then
			clog_service_start $CLOG_FAILED
			return $OCF_ERR_GENERIC
		fi
	fi

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
	su -l "${OCF_RESKEY_postmaster_user}" -c "${OCF_RESKEY_psql_path}/pg_ctl -D '${OCF_RESKEY_data_directory}' -t '${PSQL_restart_timeout}' -m fast restart"
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

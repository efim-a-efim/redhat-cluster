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

declare PSQL_path="/usr/bin"
declare PSQL_pid_file="`generate_name_for_pid_file`"
declare PSQL_kill_timeout="5"
declare PSQL_stop_timeout="15"
declare PSQL_wait_after_start="2"

pg_check_pid() {
	declare pid_file="$1"

	if [ -z "$pid_file" ] || [ ! -e "$pid_file" ]; then
		return 1
	fi

	read pid < "$pid_file"
	
	if [ -z "$pid" ] || [ ! -d /proc/$pid ]; then
		return 1
	fi

	return 0
}

pg_prepare_slave() {
	local data_dir="$1"
	[ ! -d "${data_dir}" ] && return 1

	if [ ! -f "${data_dir}/recovery.conf" ] && [ -f "${data_dir}/recovery.done" ]; then
		mv "${data_dir}/recovery.done" "${data_dir}/recovery.conf"
		# don't catch errors - only recovery.conf existence is sufficient
	fi
	[ -f "${data_dir}/recovery.conf" ] && return 0

	# error if recovery configs don't exist
	return 1
}

pg_prepare_master() {
	local data_dir="$1"
	[ ! -d "${data_dir}" ] && return 1

	# Prefer recovery.conf even if recovery.done exists
	if [ -f "${data_dir}/recovery.conf" ]; then
		mv "${data_dir}/recovery.conf" "${data_dir}/recovery.done"
		# don't catch errors - only recovery.conf existence is sufficient
	fi
	[ ! -f "${data_dir}/recovery.conf" ] && return 0

	return 1
}

verify_all()
{
	clog_service_verify $CLOG_INIT

	if [ -z "$OCF_RESKEY_name" ]; then
		clog_service_verify $CLOG_FAILED "Invalid Name Of Service"
		return $OCF_ERR_ARGS
	fi

	if [ -z "$OCF_RESKEY_postmaster_user" ]; then
		clog_service_verify $CLOG_FAILED "Invalid User"
		return $OCF_ERR_ARGS
	fi

	if [ ! -d "$OCF_RESKEY_psql_path" ] || [ ! -x "${OCF_RESKEY_psql_path}/postgres" ] || [ ! -x "${OCF_RESKEY_psql_path}/pg_ctl" ]; then
		clog_service_verify $CLOG_FAILED "Invalid PostgreSQL binaries path"
		return $OCF_ERR_ARGS
	fi

	if [ ! -d "$OCF_RESKEY_data_directory" ]; then
		clog_service_verify $CLOG_FAILED "Data directory inaccessible"
		return $OCF_ERR_ARGS
	fi

	clog_service_verify $CLOG_SUCCEED
		
	return 0
}


start()
{
	clog_service_start $CLOG_INIT

	# Check PID
	pg_check_pid "${OCF_RESKEY_data_directory}/postmaster.pid"
	if [ $? -eq 0 ]; then
		clog_check_pid $CLOG_FAILED "${OCF_RESKEY_data_directory}/postmaster.pid"
		clog_service_start $CLOG_FAILED
		return $OCF_ERR_GENERIC
	fi

	if [ ${OCF_RESKEY_start_as_slave} -gt 0 ]; then
		pg_prepare_slave "$OCF_RESKEY_data_directory"
		if [ $? -ne 0 ]; then
			clog_service_start $CLOG_FAILED
			return $OCF_ERR_GENERIC
		fi
	else
		pg_prepare_master "$OCF_RESKEY_data_directory"
		if [ $? -ne 0 ]; then
			clog_service_start $CLOG_FAILED
			return $OCF_ERR_GENERIC
		fi
	fi

	su -l "$OCF_RESKEY_postmaster_user" -c "${OCF_RESKEY_psql_path}/postgres -D \"$OCF_RESKEY_data_directory\" $OCF_RESKEY_postmaster_options" &> /dev/null &

	# We need to sleep for a second to allow pg_ctl to detect that we've started.
	sleep $PSQL_wait_after_start

	su -l "$OCF_RESKEY_postmaster_user" -c "${OCF_RESKEY_psql_path}/pg_ctl status -D \"$OCF_RESKEY_data_directory\" $OCF_RESKEY_postmaster_options" &> /dev/null
	if [ $? -ne 0 ]; then
		clog_service_start $CLOG_FAILED
		return $OCF_ERR_GENERIC
	fi

	clog_service_start $CLOG_SUCCEED
	return 0;
}

stop()
{
	clog_service_stop $CLOG_INIT

	# Check PID
	pg_check_pid "${OCF_RESKEY_data_directory}/postmaster.pid"
	if [ $? -ne 0 ]; then
		clog_service_stop $CLOG_SUCCEED
		return 0
	fi

	# First try to stop it with pg_ctl
	su -l "$OCF_RESKEY_postmaster_user" -c "${OCF_RESKEY_psql_path}/pg_ctl stop -D \"$OCF_RESKEY_data_directory\" -t \"$PSQL_stop_timeout\" $OCF_RESKEY_postmaster_options" &> /dev/null
	if [ $? -eq 0 ]; then
		clog_service_stop $CLOG_SUCCEED
		return 0
	fi
	clog_service_stop $CLOG_FAILED_NOT_STOPPED

	# Kill app if it is not stopping
	stop_generic_sigkill "${OCF_RESKEY_data_directory}/postmaster.pid" "0" "$PSQL_kill_timeout"
	if [ $? -ne 0 ]; then
		clog_service_stop $CLOG_FAILED_KILL
		return $OCF_ERR_GENERIC
	fi
	
	clog_service_stop $CLOG_SUCCEED_KILL
	return 0;
}

status()
{
	clog_service_status $CLOG_INIT

	# Lightweight checks
	status_check_pid "${OCF_RESKEY_data_directory}/postmaster.pid"
	if [ $? -ne 0 ]; then
		clog_service_status $CLOG_FAILED "${OCF_RESKEY_data_directory}/postmaster.pid"
		return $OCF_NOT_RUNNING
	fi

	# "Heavy" checks
	if [ ${OCF_CHECK_LEVEL} -ge 10 ]; then
		su -l "$OCF_RESKEY_postmaster_user" -c "${OCF_RESKEY_psql_path}/pg_ctl status -D \"$OCF_RESKEY_data_directory\" $OCF_RESKEY_postmaster_options" &> /dev/null
		if [ $? -ne 0 ]; then
			return $OCF_NOT_RUNNING
		fi
	fi

	# Very heavy checks
	if [ ${OCF_CHECK_LEVEL} -ge 20 ]; then
		su -l "$OCF_RESKEY_postmaster_user" -c "${OCF_RESKEY_psql_path}/psql -c 'select 1;'" &> /dev/null
		if [ $? -ne 0 ]; then
			return $OCF_NOT_RUNNING
		fi
	fi

	clog_service_status $CLOG_SUCCEED
	return 0
}

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
		verify_all
		status
		exit $?
		;;
	restart)
		verify_all
		stop
		start
		exit $?
		;;
	*)
		echo "Usage: $0 {start|stop|status|monitor|restart|meta-data|validate-all}"
		exit $OCF_ERR_UNIMPLEMENTED
		;;
esac

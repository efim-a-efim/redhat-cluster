#!/usr/bin/env bash

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

################################################################################
######## Internal functions
################################################################################

check_rw() {
	local _target="$1"

	# First find RW FS
	local _path=`findmnt -n -f -o TARGET -O rw ${_target}`
	if [[ "${_path}" ]]; then
		# Create test file
		local _rwfile=`mktemp --tmpdir="${_path}"`
		# Write test
		dd if=/dev/urandom bs=1024 count=1 2>/dev/null > "${_rwfile}"
		if [[ $? -ne 0 ]]; then
			[[ -f "${_rwfile}" ]] && rm -f "${_rwfile}"
			return 1
		fi
		# Read test
		dd if="${_rwfile}" of=/dev/null bs=1024 count=1 2>&1
		if [[ $? -ne 0 ]]; then
			[[ -f "${_rwfile}" ]] && rm -f "${_rwfile}"
			return 1
		fi
		# if all OK
		[[ -f "${_rwfile}" ]] && rm -f "${_rwfile}"
		return 0
	else
		# Fall back to RO test
		_path=`findmnt -n -f -o TARGET ${_target}`
		if [[ -r "${_path}/$2" ]]; then
			dd if="${_path}/$2" of=/dev/null bs=1 count=1 2>&1
			[[ $? -ne 0 ]] && return 1
			# if all OK
			return 0
		else
			# Invalid options
			return 2
		fi
	fi
}

################################################################################
######## Commands
################################################################################
verify_all() {
	clog_service_verify $CLOG_INIT

	if [[ -z "$OCF_RESKEY_name" ]]; then
		clog_service_verify $CLOG_FAILED "Invalid Name Of Service"
		return $OCF_ERR_ARGS
	fi

	if [[ -z "$OCF_RESKEY_mountpoint" ]]; then
		clog_service_verify $CLOG_FAILED "Invalid mount point"
		return $OCF_ERR_ARGS
	fi

	if [[ -z "$OCF_RESKEY_host" ]]; then
		clog_service_verify $CLOG_FAILED "No hosts specified"
		return $OCF_ERR_ARGS
	fi

	if [[ -z "$OCF_RESKEY_volume" ]]; then
		clog_service_verify $CLOG_FAILED "Volume name invalid"
		return $OCF_ERR_ARGS
	fi

	# $OCF_RESKEY_no_umount
	# $OCF_RESKEY_force_umount
	# $OCF_RESKEY_options

	clog_service_verify $CLOG_SUCCEED
	return $OCF_SUCCESS
}


start() {
	clog_service_start $CLOG_INIT

	# Check if FS is already mounted, get its options
	findmnt -n -f -t "fuse.glusterfs" "${OCF_RESKEY_host}:/${OCF_RESKEY_volume}" "${OCF_RESKEY_mountpoint}" > /dev/null 2>&1
	if [[ $? -eq 0 ]]; then
		# Already mounted
		clog_service_start $CLOG_SUCCEED
		return $OCF_SUCCESS;
	fi

	# Try to mount
	mount -t glusterfs \
		-o "${OCF_RESKEY_options},backupvolfile-server=${OCF_RESKEY_host_backup}" \
		"${OCF_RESKEY_host}:/${OCF_RESKEY_volume}" \
		"${OCF_RESKEY_mountpoint}"
	if [[ $? -ne 0 ]]; then
		clog_service_start $CLOG_FAILED
		return $OCF_ERR_GENERIC
	fi

	clog_service_start $CLOG_SUCCEED
	return $OCF_SUCCESS;
}

stop() {
	clog_service_stop $CLOG_INIT

	if [[ "${OCF_RESKEY_no_umount}" == "0" ]]; then
		clog_service_stop $CLOG_SUCCEED
		return $OCF_SUCCESS
	fi

	# Check if already unmounted
	findmnt -n -f -t "fuse.glusterfs" "${OCF_RESKEY_host}:/${OCF_RESKEY_volume}" "${OCF_RESKEY_mountpoint}" > /dev/null 2>&1
	if [[ $? -ne 0 ]]; then
		clog_service_stop $CLOG_SUCCEED
		return $OCF_SUCCESS
	fi

	# Normal umount
	umount "${OCF_RESKEY_host}:/${OCF_RESKEY_volume}" "${OCF_RESKEY_mountpoint}"
	if [[ $? -ne 0 ]]; then
		clog_service_stop $CLOG_SUCCEED
		return $OCF_SUCCESS
	fi

	# Force umount
	clog_service_stop $CLOG_FAILED_NOT_STOPPED
	if [[ "${OCF_RESKEY_force_umount}" != "0" ]]; then
		umount -f "${OCF_RESKEY_host}:/${OCF_RESKEY_volume}" "${OCF_RESKEY_mountpoint}"
		if [[ $? -ne 0 ]]; then
			clog_service_stop $CLOG_SUCCEED_KILL
			return $OCF_SUCCESS
		fi
	fi
	
	# Cannot umount anyway, it's a big mess...
	clog_service_stop $CLOG_FAILED_KILL
	return $OCF_ERR_GENERIC
}

status() {
	clog_service_status $CLOG_INIT

	# Lightweight checks
	findmnt -n -f "${OCF_RESKEY_host}:/${OCF_RESKEY_volume}" "${OCF_RESKEY_mountpoint}" > /dev/null 2>&1
	if [[ $? -ne 0 ]]; then
		clog_service_status $CLOG_FAILED
		return $OCF_NOT_RUNNING
	fi

	# "Heavy" checks
	# if [ ${OCF_CHECK_LEVEL} -ge 10 ]; then
	# 	# Check body here
	# 	if [ $? -ne 0 ]; then
	# 		return $OCF_NOT_RUNNING
	# 	fi
	# fi

	# Very heavy checks
	if [ ${OCF_CHECK_LEVEL} -ge 20 ]; then
		check_rw "${OCF_RESKEY_mountpoint}" > /dev/null 2>&1
		if [[ $? -ne 0 ]]; then
			return $OCF_NOT_RUNNING
		fi
	fi

	clog_service_status $CLOG_SUCCEED
	return $OCF_SUCCESS
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

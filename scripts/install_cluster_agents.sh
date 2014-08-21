#!/bin/sh

echo 'Installing resource agents...'
cp ra_pgsql/postgres_masterslave.metadata ra_pgsql/postgres_masterslave.sh ra_pgsql/postgres.metadata ra_pgsql/postgres.sh /usr/share/cluster
chmod +x /usr/share/cluster/postgres.sh /usr/share/cluster/postgres_masterslave.sh
echo 'Done'

echo 'Installing fence agents...'
cp fence_pve/fence_pvevm fence_pve/fence_pvect /usr/sbin
chmod +x /usr/sbin/fence_pve*
echo 'Done'

echo 'Installing PostgreSQL replica restore script...'
cp postgresql_restore/postgresql-restore-replica.sh /usr/local/bin
chmod +x /usr/local/bin/postgresql-restore-replica.sh
echo 'Done'

echo 'Installing SNMP config...'
cp snmp/snmpd.conf /etc/snmp
echo 'Done'

echo 'Patching Luci...'
_cd="$(pwd)"
_m=`uname -m`
_lib='lib'
[[ "${_m}" = 'x86_64' ]] && _lib='lib64'
cd /usr/${_lib}/python2.6/site-packages/luci && patch -p1 < luci/luci-complex.patch && cd "${_cd}"
echo 'Done'

echo 'Cluster services restart...'
/etc/init.d/rgmanager stop && /etc/init.d/cman restart && /etc/init.d/rgmanager start
/etc/init.d/ricci restart
/etc/init.d/luci restart
/etc/init.d/snmpd restart
echo 'Done'

[ -f /etc/profile ] && source /etc/profile
PGDATA=/pg_data/data
export PGDATA
PATH="/usr/pgsql-9.1/bin:${PATH}"
export PATH

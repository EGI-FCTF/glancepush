#
# Regular cron jobs for the glancepush package
#
0 4	* * *	root	[ -x /usr/bin/glancepush_maintenance ] && /usr/bin/glancepush_maintenance

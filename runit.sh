#!/bin/bash
# DISCLAIMER OF WARRANTIES AND LIMITATION OF LIABILITY
# The software is supplied "as is" and all use is at your own risk.  Peak Performance Systems disclaims
# all warranties of any kind, either express or implied, as to the software, including, but not limited to,
# implied warranties of fitness for a particular purpose, merchantability or non - infringement of proprietary
# rights.  Neither this agreement nor any documentation furnished under it is intended to express or imply
# any warranty that the operation of the software will be uninterrupted, timely, or error - free.  Under no
# circumstances shall Peak Performance Systems be liable to any user for direct, indirect, incidental,
# consequential, special, or exemplary damages, arising from or relating to this agreement, the software, or
# user#s use or misuse of the softwares.  Such limitation of liability shall apply whether the damages arise
# from the use or misuse of the software (including such damages incurred by third parties), or errors of
# the software.                         


function msg() {
local type="$1"
local msg="$2" 
local now=$(date +"%Y.%m.%d-%H:%M:%S")

echo "${type} : ${now} : ${msg}"
}

function test_conn() {
local constring="$*"
local ret=0

msg NOTIFY ""
msg NOTIFY ""
msg NOTIFY ""
msg NOTIFY "Test connectivity with: db2 $constring"
msg NOTIFY ""
msg NOTIFY ""

db2 $constring
db2 "SELECT service_level, fixpack_num FROM TABLE (sysproc.env_get_inst_info()) as INSTANCEINFO"

ret=$?

return $ret
}

function count_pids() {
local pidfile=$1
local numpids=0

ps -p `cat $pidfile` | wc -l
return 0

}

function reset_snapshot() {
local constring="$1"
local dbname="$2"
local ret=0

db2 $constring
db2 "reset monitor for database ${dbname} global"

ret=$?

return $ret

}

function get_snapshot() {
local constring="$1"
local dbname="$2"
local ret=0

db2 $constring
db2 "get snapshot for database on ${dbname}"

ret=$?

return $ret

}



function wait_pids() {
local sessions=$1
local run_time=$2
local wl="$3"
local pids="$4"
local sleeptm=$(( run_time - 3 ))
local cnt=0
local monitor_limit=0
local x=0
local tmp=""
local pid_file="/tmp/${RANDOM}_slob.pids.out"

echo "$pids" > $pid_file 2>&1

if [ "$wl" -eq 0 ]
then
	msg NOTIFY "List of monitored db2 PIDs written to $pid_file"

	monitor_limit=300

	sleep 5
	tmp=`count_pids $pid_file`

	if [ $tmp -lt $sessions ]
	then
		msg FATAL "SLOB process monitoring discovered $(( sessions - tmp )) db2 processes have aborted."
		msg FATAL "Consider export SLOB_DEBUG=TRUE, re-running the test and then examine slob_debug.out"
		rm -f $pid_file
		return 1
	fi

	msg NOTIFY "Waiting for $(( sleeptm - 5 )) seconds before monitoring running processes (for exit)."
	sleep $(( sleeptm - 5 ))
else
	msg NOTIFY "This is a fixed-iteration run (see slob.conf->WORK_LOOP). "
	monitor_limit=0
fi

msg NOTIFY "Entering process monitoring loop."

while ( ps -p $pids > /dev/null 2>&1 )
do
	
	if [ "$monitor_limit" -ne 0 ]
	then
		if [ "$cnt" -gt $monitor_limit ]
		then
			msg FATAL "The following db2 processes have not exited after $monitor_limit seconds."
			ps -fp $pids
			return 1
		fi
	fi
	(( cnt = $cnt + 1 ))
	(( x = $cnt % 10 ))
	if [ $x = 0 ]
	then
		tmp=`count_pids $pid_file`		
		msg NOTIFY "There are $tmp db2 processes remaining."
	fi	

	sleep 1
done
rm -f $pid_file

return 0
}

function check_bom() {
local file=""

if [ ! -f ./misc/BOM ]
then
	#echo "FATAL: ${0}: ${FUNCNAME}: No BOM file in ./misc. Incorrect SLOB file contents or wrong PWD."
	msg FATAL "No BOM file in ./misc. Incorrect SLOB file contents or wrong PWD."
	return 1
fi

for file in `cat ./misc/BOM | xargs echo`
do
	if [ ! -f "$file" ]
	then
		#echo "FATAL: ${0}: ${FUNCNAME}: Missing ${file}. Incorrect SLOB file contents."
		msg FATAL "Missing ${file}. Incorrect SLOB directory contents."
		return 1
	fi
done

return 0
}

#---------- Main body

if [[ "$#" != 1 || "$1" < 1 ]]
then
	msg FATAL
	msg FATAL "${0}: Usage : ${0} <number of sessions to execute>"
	msg FATAL "SLOB abnormal end."

	exit 1
else
	sessions=$1
fi

export WORK_DIR=`pwd`
export SNAPSHOT=${WORK_DIR=}/snapshot.out
export LOG=${WORK_DIR=}/runit.out

SLOB_DEBUG=TRUE
if [ "$SLOB_DEBUG" = "TRUE" ]
then
	export debug_outfile="slob_debug.out"
	msg NOTIFY "Debug info being sent to $debug_outfile "
else
	export debug_outfile="/dev/null"
fi

if ( ! check_bom )
then
    msg FATAL "PWD does not have correct SLOB kit contents."
    msg FATAL "SLOB abnormal end."
    exit 1
fi

if [ ! -x ./mywait ]
then
	msg FATAL " "
	msg FATAL "./mywait executable not found or wrong permissions."
	msg FATAL "Please change directories to ./wait_kit and run make(1)."
	msg FATAL " "	
	msg FATAL "SLOB abnormal end."
	exit 1
fi

if ( ! type db2  >> $debug_outfile 2>&1 )
then
	msg FATAL "db2 is not executable in $PATH"
	msg FATAL "SLOB abnormal end."
	exit 1
fi

rm -f  iostat.out vmstat.out mpstat.out slob_debug.out *_slob.pids.out

# Just in case user deleted lines in slob.conf:
UPDATE_PCT=${UPDATE_PCT:=25}
RUN_TIME=${RUN_TIME:=300}
WORK_LOOP=${WORK_LOOP:=0}
SCALE=${SCALE:=10000}
WORK_UNIT=${WORK_UNIT:=256}
REDO_STRESS=${REDO_STRESS:=LITE}
SHARED_DATA_MODULUS=${SHARED_DATA_MODULUS:=0}

DO_UPDATE_HOTSPOT=${DO_UPDATE_HOTSPOT:=FALSE}
HOTSPOT_PCT=${HOTSPOT_PCT:=10}

THINK_TM_MODULUS=${THINK_TM_MODULUS:=0}
THINK_TM_MIN=${THINK_TM_MIN:=.1}
THINK_TM_MAX=${THINK_TM_MAX:=.5}


source ./slob.conf

db2_pids=""
misc_pids=""
before=""
tm=""
cmd=""
nt=0
slobargs=""
sleep_secs=""
cnt=1
x=0
instance=1
sessions_per_instance=0

conn_string=""

if [ ! -z "${DB_NAME}" ]
then
    conn_string="connect to ${DB_NAME}"
fi

if [ ! -z "${DB2_USER}" ]
then
    conn_string="${conn_string} user ${DB2_USER}"
fi

if [ ! -z "${DB2_PASS}" ]
then
    conn_string="${conn_string} using ${DB2_PASS}"
fi

export non_admin_connect_string="${conn_string}"
export admin_connect_string="${conn_string}"

# The following is the first screen output
msg NOTIFY " "
msg NOTIFY "Conducting SLOB pre-test checks."

echo "NOTIFY: 
UPDATE_PCT == $UPDATE_PCT
RUN_TIME == $RUN_TIME
WORK_LOOP == $WORK_LOOP
SCALE == $SCALE
WORK_UNIT == $WORK_UNIT
REDO_STRESS == $REDO_STRESS
admin_connect_string == \"$admin_connect_string\"
non_admin_connect_string == \"$non_admin_connect_string\"
"

msg NOTIFY "Verifying connectivity."
msg NOTIFY "Testing db2 connectivity to validate slob.conf settings."

if ( ! test_conn ${admin_connect_string}  >> $LOG 2>&1  )
then
    msg FATAL "${0}: cannot connect to db2."
	msg FATAL "Connect string: db2 \"${admin_connect_string}\""
    msg FATAL "Please verify the root password in slob.conf are correct for your connectivity model."
	msg FATAL "SLOB abnormal end."
    exit 1
fi


msg NOTIFY "Connectivity verified."

msg NOTIFY "Setting up trigger mechanism."
./create_sem > /dev/null 2>&1

if [ ! -n "$NO_OS_PERF_DATA" ]
then
	msg NOTIFY "Running iostat, vmstat and mpstat on current host--in background."
	( iostat -xm 3 > iostat.out 2>&1 ) &
	misc_pids="${misc_pids} $!"
	( vmstat 3 > vmstat.out 2>&1 ) &
	misc_pids="${misc_pids} $!"
	( mpstat -P ALL 3  > mpstat.out 2>&1) &
	misc_pids="${misc_pids} $!"
fi

msg NOTIFY "Connecting ${sessions} sessions ..."

#
# Launch the sessions
#

cnt=1 ; x=0 ; instance=1 ; sessions_per_instance=0 


until [ $cnt -gt $sessions ]
do
    cmd="db2 ${non_admin_connect_string}"
    slobargs="!./mywait; set schema user${cnt}; call user${cnt}.slob($UPDATE_PCT, $WORK_LOOP, $RUN_TIME, $SCALE, $WORK_UNIT, '$REDO_STRESS', $SHARED_DATA_MODULUS, $DO_UPDATE_HOTSPOT, $HOTSPOT_PCT, $THINK_TM_MODULUS, $THINK_TM_MIN, $THINK_TM_MAX)"
    echo $slobargs

	( ( $cmd; db2 -t <<EOF
!./mywait;
set schema user${cnt};
call user${cnt}.slob($UPDATE_PCT, $WORK_LOOP, $RUN_TIME, $SCALE, $WORK_UNIT, '$REDO_STRESS', $SHARED_DATA_MODULUS, $DO_UPDATE_HOTSPOT, $HOTSPOT_PCT, $THINK_TM_MODULUS, $THINK_TM_MIN, $THINK_TM_MAX);
EOF
) >> $debug_outfile 2>&1 ) &

	db2_pids="${db2_pids} $!"

	(( cnt = $cnt + 1 ))
	(( x = $cnt % 17 ))
	[[ $x -eq 0 ]] && sleep 1
done

msg NOTIFY " "

if [[  $(( cnt / 6 )) -gt 5 ]]
then
	sleep_secs=5
else
	(( sleep_secs = $cnt / 6 ))
fi

if [ "$sleep_secs" -gt 1 ]
then
	msg NOTIFY "Pausing for $sleep_secs seconds before triggering the test."
	sleep $sleep_secs
else
    sleep 5
fi


reset_snapshot "$admin_connect_string" ${DB_NAME} > snapshot.out
# Switch output to fd2 so $misc_pids shell kill feedback falls in line

msg NOTIFY " "
msg NOTIFY "Triggering the test." >&2
before=$SECONDS


./trigger > /dev/null 2>&1

if ( ! wait_pids "$sessions" "$RUN_TIME" "$WORK_LOOP" "$db2_pids" )
then
	msg FATAL "This is not a successful SLOB test." >&2
	exit 1
fi

get_snapshot "$admin_connect_string" ${DB_NAME} >> snapshot.out
(( tm =  $SECONDS - $before ))

msg NOTIFY "Run time in seconds was:  $tm" >&2
echo "Tm $tm" > tm.out

sleep 1

msg NOTIFY "Terminating background data collectors." >&2
/bin/kill -9 $misc_pids > /dev/null 2>&1 

wait
exit 0

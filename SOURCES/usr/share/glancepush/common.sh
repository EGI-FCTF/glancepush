#! /bin/bash
############################################################
#                                                          #
#                         common.sh                        #
#                                                          #
############################################################
#
# author:    mpuel@in2p3.fr
# date:      lundi 6 août 2012, 09:02:42 (UTC+0200)
# copyright: Copyright (c) by IN2P3 computing centre, Villeurbanne (Lyon), France
#
# purpose:
#  * implements common functions

etc=/etc/glancepush
test=$etc/test
logs=/var/log/glancepush
loop_thresh=100
loop_thresh_up=50
loop_sleep=30
meta=$etc/meta
rundir=/var/run/glancepush
vmcmapping=$etc/vmcmapping
transform=$etc/transform

ssh_opts="-F/dev/null -i $key -oConnectTimeout=20 -ostricthostkeychecking=no -oUserKnownHostsFile=/dev/null -opasswordauthentication=no -obatchmode=yes"

_log()
{
    logger -s -t glancepush -p user.notice "$*"
}

_debug()
{
    [ "$debug" = true ] && logger -s -t glancepush -p user.debug "$*"
}

_err()
{
    _log "$*" 1>&2
}


# scp a file into a running VM
# args: source host dest
push_file()
{
    source=$1
    host=$2
    dest=$3
    
    _debug "sending file"
    scp $ssh_opts $source root@${host}:$dest
}


# scp, execute a script and fetch the log
# args: script host log [args...]
exec_script()
{
    script=$1
    host=$2
    log=$3
    shift; shift; shift;
    scrname=$(basename $script)
    
    _debug "sending script"
    scp $ssh_opts $script root@${host}:/tmp
    _debug "executing script"
    ssh $ssh_opts root@${host} "/tmp/$scrname $@ < /dev/null" >> $log 2>&1 
}

# args: vmname
ping_ok()
{
    ping -c 1 $1 &> /dev/null
}

# conditions:
#  * pings
#  * ssh
# args: vmname
wait_vm_up()
{
    vmname=$1

    let i=0
    while [ $i -lt $loop_thresh_up ]
    do
        let i++
        if ! ping_ok $vmname
            then
            _debug "awaiting $vmname to ping... sleep $loop_sleep"
            sleep $loop_sleep
        else
            break
        fi
    done
    [ $i = $loop_thresh_up ] && { _err "VM failed to ping within $(($loop_thres * $loop_sleep)) seconds"; return 1; }

    while [ $i -lt $loop_thresh_up ]
    do
        let i++
        # wait for ssh to accept connections
        _debug "attempting connection <ssh $ssh_opts root@${vmname}>"
        if ! ssh $ssh_opts root@${vmname} /bin/true 2> /dev/null
            then
            _debug "no ssh access yet, sleep $loop_sleep"
            sleep $loop_sleep
            continue
        fi

        # ok, return now
        _debug "VM $vmname booted !"
        return 0
    done
    
    _err "VM failed accept ssh connection within $(($loop_thres * $loop_sleep)) seconds"
    return 1
}


# waits that the openstack status of the VM is "active"
wait_vm_active()
{
    vmname=$1

    let i=0
    status=
    while [ $i -lt $loop_thresh -a "$status" != active ]
    do
        let i++

        status=$(nova show $vmname | awk '/OS-EXT-STS:vm_state/{print $4}')
        _debug "VM status is <$status>"
        [ "$status" = active ] && continue
        sleep 30
    done

    [ "$status" = active ]
}

# returns VM's first IP address
get_vm_ip()
{
    vmname=$1

    nova show $vmname | grep network | cut -d\| -f3 | awk '{print $1}'
}


# output tenant id
# args: tenant name
tenant_id()
{
    keystone tenant-list | sed -n 's/^|\ \+\([^\ ]\+\)\ \+|\ \+'"$1"'\ .*/\1/p'
}


# launch a quarantined VM, test policy compliance
# requires a valid openstack account
test_policy()
{
    name=$1

    source $meta/$name
    servername=policytest.$RANDOM
    flavor=${flavor:-m1.tiny}
    
    _debug "starting policy checks for VM <$name>"
    _debug "booting quarantined VM: <nova boot --flavor $flavor --key-name $keypair --image ${name}.q $servername>"
    nova boot \
        --flavor $flavor \
        --key-name $keypair \
        --image ${name}.q \
        $servername
    [ $? != 0 ] && { _err "error instanciating VM"; return 1; }

    wait_vm_active $servername
    if [ $? = 0 ]
    then
        ip=$(get_vm_ip $servername)
        _debug "get VM ip: <$ip>"

        _debug "wait for connectivity"
        wait_vm_up $ip   
        if [ $? = 0 ]
        then
            _debug "scp the policy test script, execute it and fetch the log"
            push_file $test/lib $ip /tmp
            exec_script $test/$name $ip $logs/${name}.policy
            res=$?
        else
            _err "no connectivity to VM <$servername/$ip>"
            res=1
        fi
    
    else
        _err "error instanciating VM: status not active"; 
        res=1
    fi

    _debug "shutdown VM"
    nova delete $servername

    # returns result
    if [ $res -eq 0 ]
        then
        _log "policy checks succeeded"
    else
        _err "policy checks failed"
    fi
    return $res
}


pushlist()
{
    python <<EOF
import json
fp = open("$vmcmapping","r")
vmcmapping = json.loads(fp.read())
for i in vmcmapping.keys():
        print vmcmapping[i]
EOF

}


# args: image
# checks if image has been updated by vmcatcher more recently than the upload date to glance
updated()
{
    image=$1

    tmpf=$(mktemp -p /dev/shm)
    glance image-show $(glance_id "$image") > $tmpf
    glance_import_date=$(awk '/ created_at /{print $4}' $tmpf)
    image_deleted=$(awk '/ deleted /{print $4}' $tmpf)
    rm -f $tmpf

    if [ "$image_deleted" = True ]
        then
        _log "image <$image> has been deleted from glance, reupload"
        return 0
    fi

    vmcatcher_import_date=$( 
        (
            source $vmcatcher_conf
            vmcatcher_image -i -u $(vmcatcher_id "$image") | awk -F= '/imagelist.dc:date:imported/{print $2}'
        )
    )

    python <<EOF
from dateutil.parser import *
import sys
import pytz
utc=pytz.UTC
gd = parse("$glance_import_date")
vd = parse("$vmcatcher_import_date")
if vd > utc.localize(gd):
  sys.exit( 0 )
else:
  sys.exit( 1 )
EOF
    # beware: implicit return code
}


# args: image
# returns the vmcatcher id for an image
vmcatcher_id()
{
    image=$1

    sed -n 's/vmcatcher_id=\"\(.*\)\"/\1/p' "$rundir/$image"
}


# args: image
# returns the glance id for an image
glance_id()
{
    image=$1

    sed -n 's/glance_id=\"\(.*\)\"/\1/p' "$rundir/$image"
}

# args: image
# returns the path to the cached image
vmcatcher_cached_image()
{
    image=$1

    echo $vmcatcher_cache/$(vmcatcher_id "$image")
}


# returns the uuid of a quarantined image
quarantined_id()
{
    image=$1

    glance image-list --name ${image}.q | awk '/active/{print $2}'
}

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
transform=$etc/transform
spooldir=/var/spool/glancepush

ssh_opts="-F/dev/null -i $key -oConnectTimeout=20 -ostricthostkeychecking=no -oUserKnownHostsFile=/dev/null -opasswordauthentication=no -obatchmode=yes"

_log()
{
    logger -s -t glancepush -p user.notice "$*" 2>&1
}

_debug()
{
    [ "$debug" = true ] && logger -s -t glancepush -p user.debug "$*" 2>&1
}

_err()
{
    _log "error: $*" 1>&2
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
    ssh $ssh_opts root@${host} "chmod 755 /tmp/$scrname; /tmp/$scrname $@ < /dev/null" >> $log 2>&1 
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
            _debug "awaiting $vmname to ping... sleep $loop_sleep [$i/$loop_thresh_up]"
            sleep $loop_sleep
        else
            break
        fi
    done
    [ $i = $loop_thresh_up ] && { _err "VM failed to ping within $(($loop_thresh * $loop_sleep)) seconds"; return 1; }

    while [ $i -lt $loop_thresh_up ]
    do
        let i++
        # wait for ssh to accept connections
        _debug "attempting connection <ssh $ssh_opts root@${vmname}>"
        if ! ssh $ssh_opts root@${vmname} /bin/true 2> /dev/null
            then
            _debug "no ssh access yet, sleep $loop_sleep [$i/$loop_thresh_up]"
            sleep $loop_sleep
            continue
        fi

        # ok, return now
        _debug "VM $vmname booted !"
        return 0
    done
    
    _err "VM failed accept ssh connection within $(($loop_thresh * $loop_sleep)) seconds"
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
    network=$2

    desired_pref=${network#*/}

    ips=$(nova show $vmname | awk -F\| '/network/{print $3}' | sed 's/,//g')

    # only one ip allocated
    if [ -z "$network" ]
        then
        # indeed, echo
        if [ $(echo $ips | wc -w) = 1 ]
        then
            echo $ips
            return 0
        else
            _err "multiple ips attached to the VM and no network specified"
            return 1
        fi
    fi

    for ip in $ips
    do
        _debug "found ip for vm $vmname: $ip"
        net=$(ipcalc ${ip}/${desired_pref} -n)
        net=${net#*=}
        prefix=$(ipcalc ${ip}/${desired_pref} -p)
        prefix=${prefix#*=}

        if [ "$network" = "${net}/$prefix" ]
            then
            echo $ip
            return 0
        fi
    done

    _err "no attached ip found for vm $vmname in network $network"
    return 1
}


# output tenant id
# args: tenant name
tenant_id()
{
    keystone tenant-list | sed -n 's/^|\ \+\([^\ ]\+\)\ \+|\ \+'"$1"'\ .*/\1/p'
}


# add a floating ip to an instance
add_floating_ip()
{
    server=$1

    # wait VM gets its fixed IP
    i=0
    while ! get_vm_ip "$server" && [ $i -lt 20 ]
    do
        sleep 3
        let i++
    done
    [ $i = 20 ] && { _err "could not associate a floating ip to server <$server>, no fixed ip found"; return 1; }

    ip=$(nova floating-ip-create | awk '/None/{print $2}')
    _debug "created new floating ip <$ip>"
    _debug "attach it to the server <$server>"
    nova add-floating-ip "$server" "$ip"

    echo $ip
}

delete_floating_ip()
{
    ip=$1

    _debug "releasing public floating ip <$ip>"
    nova floating-ip-delete "$ip"
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

    _debug "checking one and only one image available"
    [ "$(glance_id "${name}.q" | wc -l)" = 1 ] || { _err "Image named <$name> is either stored zero or multiple times"; return 1; }

    _debug "booting quarantined VM: <nova boot --flavor $flavor --key-name $keypair --image ${name}.q $servername>"
    # latest ubuntu uec images disable the root account through cloud-init, avoid it
    cloudconfig=$(mktemp -p /dev/shm)
    cat > $cloudconfig <<EOF
#cloud-config
disable_root: false
EOF
    nova boot \
        --flavor $flavor \
        --key-name $keypair \
        --image ${name}.q \
        --user-data $cloudconfig \
        $servername
    ret=$?
    rm -f $cloudconfig
    [ $ret != 0 ] && { _err "error instanciating VM"; return 1; }

    if [ "$need_floating_ip" = yes ]
        then
        floating_ip=$(add_floating_ip "$servername")
    fi

    wait_vm_active $servername
    if [ $? = 0 ]
    then
        ip=$(get_vm_ip "$servername" "$private_network")
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
    [ -n "$floating_ip" ] && delete_floating_ip "$floating_ip"

    # returns result
    if [ $res -eq 0 ]
        then
        _log "policy checks succeeded"
    else
        _err "policy checks failed"
    fi
    return $res
}




# returns the uuid of an image
glance_id()
{
    image=$1

    glance image-list --name "$image" | awk '/active|queued|saving|deleted|pending_delete|killed/{print $2}'
}


# returns the path to the image
# args: image
image_path()
{
    image=$1

    awk -F= '/file=/{print $2}' "$spooldir/$image"
}


# returns the list of updated images
updated()
{
    ls --color=none -1 $spooldir
}


# returns keystone tenant id
# args: tenant_name
tenant_id()
{
    tenant=$1

    keystone tenant-list | awk '/ '"$tenant"' /{print $2}'
}


# once completed, remove the update flag
update_done()
{
    image=$1

    rm -f "$spooldir/$image"
}

# remove all images corresponding to given name
purge_image()
{
    image=$1

    _debug "purging image <$image>"
    for id in $(glance_id "$image")
    do
        _log "deleting image <$image> with id <$id>"
        glance image-update $id --is-protected False
        glance -f image-delete $id
    done
}

#!/bin/bash

CONFIGXML='/opt/vmware/nfc/config/ovf_env.xml'
FLAG="/opt/vmware/nfc/config/.sfd_bootstrap"
# bootstrap script
NFC_BOOTSTRAP="/opt/vmware/nfc/scripts/init/bootstrap_nfc.sh"
# cron
NFC_CRON="/opt/vmware/nfc/scripts/init/cron_nfc.sh"
PYTHON_PKG_PATH=$(python3 -c "import site; print(site.getsitepackages()[0])")
# purge
PURGE_JOB="python3 ${PYTHON_PKG_PATH}/nfc_purge/purge_nfc.py"
# log file
NFC_INIT_LOG="/opt/vmware/nfc/logs/nfc_init.log"

# read ovf params
read_ovf_params() {
    echo "$(date +%F_%T) Reading ovf parameters"
    if [[ ! -f $FLAG ]]; then
        vmtoolsd --cmd "info-get guestinfo.ovfenv" > $CONFIGXML
    fi
    password=`cat $CONFIGXML| grep -e password |sed -n -e '/value\=/ s/.*\=\" *//p'|sed 's/\"\/>//'`
    ipaddress=`cat $CONFIGXML| grep -e ip-address |sed -n -e '/value\=/ s/.*\=\" *//p'|sed 's/\"\/>//'`
    netmask=`cat $CONFIGXML| grep -e netmask |sed -n -e '/value\=/ s/.*\=\" *//p'|sed 's/\"\/>//'`
    gateway=`cat $CONFIGXML| grep -e default-gateway |sed -n -e '/value\=/ s/.*\=\" *//p'|sed 's/\"\/>//'`
    dns=`cat $CONFIGXML| grep -e domain-name-servers |sed -n -e '/value\=/ s/.*\=\" *//p'|sed 's/\"\/>//'`
    searchpath=`cat $CONFIGXML| grep -e domain-search-path |sed -n -e '/value\=/ s/.*\=\" *//p'|sed 's/\"\/>//'`
    ntp=`cat $CONFIGXML| grep -e ntp |sed -n -e '/value\=/ s/.*\=\" *//p'|sed 's/\"\/>//'`
    hostname=`cat $CONFIGXML| grep -e hostname |sed -n -e '/value\=/ s/.*\=\" *//p'|sed 's/\"\/>//'`
    rootssh=`cat $CONFIGXML| grep -e ssh-access |sed -n -e '/value\=/ s/.*\=\" *//p'|sed 's/\"\/>//'`

    echo "$(date +%F_%T) Printing OVF env parameters"
    echo "ip address: $ipaddress"
    echo "netmask: $netmask"
    echo "default gateway: $gateway"
    echo "dns server: $dns"
    echo "searchpath: $searchpath"
    echo "ntp server : $ntp"
    echo "hostname : $hostname"
    echo "lockRootUser: $rootssh"

}

# change default root password from ovf env parameters
configure_root_password() {
    # Modify root password
    echo "$(date +%F_%T) Modify root password"
    echo -e sfdsupport\\nsfdsupport | sudo -i passwd

    # Modify admin@sfd.local password
    echo "$(date +%F_%T) Modify admin@sfd.local password"
    echo -e admin@sfd.local:$password | sudo chpasswd
}

# change network settings
configure_network_settings() {
    echo "$(date +%F_%T) Apply network settings"
    truncate -s 0 /etc/network/interfaces.d/50-cloud-init.cfg
    truncate -s 0 /etc/resolv.conf

    # ip, netmask gateway setting
    read -d '' interface_content << EOF
# This file describes the network interfaces available on your system
# and how to activate them. For more information, see interfaces(5).
# The loopback network interface
auto lo
iface lo inet loopback
# The primary network interface
iface ens192 inet static
    address IPADDRESS
    netmask NETMASK
    gateway GATEWAY
EOF

    replace_interface_content=$(sed "s/IPADDRESS/$ipaddress/g;s/NETMASK/$netmask/g;s/GATEWAY/$gateway/g" <<<"$interface_content")

    # dns and domain search path
    read -d '' resolv_conf_content << EOF
# Dynamic resolv.conf(5) file for glibc resolver(3) generated by resolvconf(8)
#     DO NOT EDIT THIS FILE BY HAND -- YOUR CHANGES WILL BE OVERWRITTEN
nameserver NAMESERVER
search SEARCHPATH
EOF

    # if dns and searchpath are empty
    if [[(-z "$dns") && (-z "$searchpath")]]; then
        replace_resolv_conf=$(sed "/NAMESERVER/d;/SEARCHPATH/d" <<<"$resolv_conf_content")
    # only dns is empty
    elif [[(-z "$dns") && (! -z "$searchpath")]]; then
        replace_resolv_conf=$(sed "/NAMESERVER/d;s/SEARCHPATH/$searchpath/g" <<<"$resolv_conf_content")
    # only searchpath is empty
    elif [[(! -z "$dns") && ( -z "$searchpath")]]; then
        resolv_conf_content=$(sed "/SEARCHPATH/d" <<<"$resolv_conf_content")
        replace_dns $resolv_conf_content
    # both dns and search path has valid values
    else
        resolv_conf_content=$(sed "s/SEARCHPATH/$searchpath/g" <<<"$resolv_conf_content")
        replace_dns $resolv_conf_content
    fi

    ip addr flush ens192
    ifdown ens192 --ignore-errors
    echo "$replace_interface_content" > /etc/network/interfaces.d/50-cloud-init.cfg
    echo "$replace_resolv_conf" > /etc/resolv.conf
    ifup ens192 --ignore-errors
}

# replace dns values in /etc/resolv.conf
replace_dns() {
    echo "$(date +%F_%T) Configuring DNS"
    # if there are multiple values in dns
    if [[ "$dns" == *\ * ]]; then
        IFS=', ' read -r -a array <<< "$dns"
        dns_count=0 # max of 4 dns entries are allowed
        dns_entries=""
        for dns_entry in "${array[@]}"
        do
            if [[ dns_count -lt "4" ]]; then
                dns_entry="nameserver $dns_entry"
                dns_entries="$dns_entries\n$dns_entry"
                dns_count=$((dns_count + 1))
            fi
        done
        replace_resolv_conf=$(sed "s/.*NAMESERVER.*/$dns_entries/g" <<<"$resolv_conf_content")
    else
        replace_resolv_conf=$(sed "s/NAMESERVER/$dns/g" <<<"$resolv_conf_content")
    fi
}

#configure_ntp
configure_ntp() {
    echo "$(date +%F_%T) Configuring NTP"
    ntp_content=""
    if [[ "$ntp" == *\ * ]]; then
        IFS=', ' read -r -a array <<< "$ntp"
        ntp_count=0 # max of 4 ntp entries are allowed
        for ntp_entry in "${array[@]}"
            do
                if [[ ntp_count -lt "4" ]]; then
                    ntp_entry="pool ${ntp_entry} iburst"
                    ntp_content="$ntp_content\n$ntp_entry"
                    ntp_count=$((ntp_count + 1))
                fi
            done
        ntp_content="${ntp_content:2}"
    elif [[ "$ntp" == "" ]]; then
        ntp_content=""
    else
        ntp_content="pool ${ntp} iburst"
    fi


    sed -i '/iburst/d' /etc/ntp.conf
    sed -i '/ntp.ubuntu.com/d' /etc/ntp.conf
    sed -i "/Specify one or more NTP servers/a ${ntp_content}" /etc/ntp.conf

    timedatectl set-ntp off

    echo "-----RESTART NTP - START-----"
    timedatectl set-ntp off
    sleep 2
    systemctl restart ntp.service
    sleep 10
    systemctl status ntp.service
    echo "-----RESTART NTP - END-----"

    # Validate ntp service is running
    cnt=0
    max_tries=3 # check counter till 3. (total 90 seconds)
    echo "Checking if NTP service is running."

    until [[ $cnt -gt $max_tries ]]
    do
      status=$(systemctl status ntp.service | grep Active | awk '{print $2$3}')
      [[ "$status" == "active(running)" ]] && echo "NTP service is running." && break
      cnt=$[$cnt+1]
      if [[ $cnt -gt $max_tries ]]; then
           echo "NTP service is not running."
           return 1
      fi
      echo "Waiting for NTP service to come up. Restarting NTP and wait for 30 seconds..."
      systemctl restart ntp.service
      sleep 30
    done

    # Checking for NTP to get synchronized
    cnt=0
    max_tries=30 # check counter till 30. (total 300 seconds)
    echo "Checking if NTP is configured."
    until [[ $cnt -ge $max_tries ]]
    do
      ntpq -pn | awk '{print $2}' | xargs | grep -E -o "([0-9]{1,3}[\.]){3}[0-9]{1,3}|PPS|GPS|LOCAL|LOCL"
      [[ "$?" -eq 0 ]] && echo "NTP synchronized successfully." && return 0
      cnt=$[$cnt+1]
      echo "Waiting for NTP to get configured. Sleeping for 10 seconds..."
      sleep 10
    done

    echo "NTP failed to get synced."
    return 1
}


# verify hostname is same as input supplied in ova
verify_hostname() {
    echo "$(date +%F_%T) Verifying if the current hostname and ova input are same"
    # replace /etc/hosts with hostname
    replace_hostname="127.0.0.1 localhost $hostname"
    sed -i "/127.0.0.1 localhost/c\\$replace_hostname" /etc/hosts

    current_hostname=$(uname -n)
    echo "hostname input given during deployment : $hostname"
    echo "current sfd hostname : $current_hostname"
    cnt=0
    if [[ "$current_hostname" != "$hostname" ]]; then
        until [[ $cnt -ge 6 ]]
        do
           [[ "$current_hostname" == "$hostname" ]] && break
           cnt=$[$cnt+1]
           hostname $hostname
           current_hostname=$(uname -n)
           echo "sleeping for 30 seconds before checking if hostname matches with input hostname given during deployment... "
           sleep 30
        done
    fi

    if [[ "$current_hostname" == "$hostname" ]]; then
        return 0
    else
        return 1
    fi
}

# run bootstrap
bootstrap_nfc() {
    echo "$(date +%F_%T) Running bootstrap NFC"
    if [[ ! -f $FLAG ]]; then
        exec_flag=1
        # if kubeadm init fails, retry with 3 max attempts
        for i in $(seq 1 3); do
            ${NFC_BOOTSTRAP} --init_cluster
            if [[ "$?" -ne "0" ]]; then
                kubeadm reset -f
                rm -rf /root/.kube/config
                sleep 10
            else
                exec_flag=0
                break
            fi
        done
        touch /opt/vmware/nfc/config/.sfd_bootstrap
        # if kubeadm succeeded validate apiserver pods
        if [[ "${exec_flag}" -eq "0" ]]; then
            ${NFC_BOOTSTRAP} --validate_apiserver
            # if apiserver pod validation succeeds, deploy and validate
            # kube-nfc pods
            if [[ "$?" -eq 0 ]]; then
                ${NFC_BOOTSTRAP} --deploy
                # Sleep for 10 seconds before validating SFD pods
                sleep 10
                ${NFC_BOOTSTRAP} --validate_pods --namespace kube-nfc
            fi
        fi
    else
        echo "NFC bootstrap already executed during first boot"
    fi
}


#  Schedule cron jobs
schedule_cron() {
    echo "$(date +%F_%T) Scheduling cron jobs"
    systemctl restart cron.service
    ${NFC_CRON} --job "${PURGE_JOB}" --frequency daily
}


# cleanup
sfd_init_cleanup() {
    echo "$(date +%F_%T) Running cleanup"
    # remove DHCP client
    dhclient -r -v ens192 && rm /var/lib/dhcp/dhclient.ens192.leases
    sudo kill -9 $(cat /var/run/dhclient.ens192.pid)
    # remove locale message
    chmod -x /etc/update-motd.d/*
    # clear history
    cat /dev/null > ~/.bash_history && history -c
}

# Lock root user if chosen during deployment
check_root_user_lock() {
    # remove ssh access for root user
    echo "$(date +%F_%T) Lock SSH access on root user"
    sed -i 's/PermitRootLogin yes/PermitRootLogin no/' /etc/ssh/sshd_config
    sed -i 's/UsePAM yes/UsePAM no/' /etc/ssh/sshd_config

    # Lock ssh access for admin@sfd.local user, based on user input
    if [[ "${rootssh}" == "False" ]]; then
        echo "$(date +%F_%T) Lock SSH access on admin@sfd.local user"
        usermod -L -e "" admin@sfd.local
    fi

    /etc/init.d/ssh reload
}

admin_user_config() {
    echo "$(date +%F_%T) configure admin user"
    # copy /root/.kube/config certificate -> /home/admin@sfd.local/.kube/config
    cp /etc/kubernetes/admin.conf /home/admin@sfd.local/.kube/config
    chmod 777 /home/admin@sfd.local/.kube/config
}

apply_firewall_rules() {
    iptables -I INPUT 1 -p tcp --dport 5555 -j DROP
    iptables -I INPUT 1 -i lo -p tcp --dport 5555 -j ACCEPT

    iptables -I INPUT 1 -p tcp --dport 9099 -j DROP
    iptables -I INPUT 1 -i lo -p tcp --dport 9099 -j ACCEPT

    iptables -I INPUT 1 -p tcp --dport 9100 -j DROP
    iptables -I INPUT 1 -i lo -p tcp --dport 9100 -j ACCEPT
}

main() {
    read_ovf_params
    configure_root_password
    configure_network_settings
    configure_ntp
    is_ntp_configured=$?
    if [[ ${is_ntp_configured} -ne "0" ]]; then
        echo "NTP config failed"
        exit 1
    fi
    check_root_user_lock
    verify_hostname
    is_hostname_verified=$?
    if [[ ${is_hostname_verified} -eq "0" ]]; then
        bootstrap_nfc
        admin_user_config
        schedule_cron
        sfd_init_cleanup
    else
        echo "Unable to run NFC bootstrap as hostname is not set"
    fi
    # Apply firewall rules
    apply_firewall_rules

}

exec &> >(tee -a ${NFC_INIT_LOG})
main
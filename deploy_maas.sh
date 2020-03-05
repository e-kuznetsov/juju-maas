#!/bin/bash -xe
set -o pipefail

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

# Install tools
sudo apt-get update
sudo apt-get install snapd jq prips netmask -y

# determined variables
PHYS_INT=`ip route get 1 | grep -o 'dev.*' | awk '{print($2)}'`
NODE_IP=`ip addr show dev $PHYS_INT | grep 'inet ' | awk '{print $2}' | head -n 1 | cut -d '/' -f 1`
NODE_IP_WSUBNET=`ip addr show dev $PHYS_INT | grep 'inet ' | awk '{print $2}' | head -n 1`
NODE_SUBNET=`netmask $NODE_IP_WSUBNET`
readarray -t SUBNET_IPS <<< "$(prips $NODE_SUBNET)"

# user variables
MAAS_ADMIN=${MAAS_ADMIN:-"admin"}
MAAS_PASS=${MAAS_PASS:-"admin"}
MAAS_ADMIN_MAIL=${MAAS_ADMIN_MAIL:-"admin@maas.tld"}
UPSTREAM_DNS=${UPSTREAM_DNS:-"8.8.8.8"}
IPMI_IPS=${IPMI_IPS:-"192.168.50.20 192.168.50.21 192.168.50.22 192.168.50.23 192.168.50.24"}
IPMI_USER=${IPMI_USER:-"ADMIN"}
IPMI_PASS=${IPMI_PASS:-"ADMIN"}
IPMI_POWER_DRIVER=${IPMI_POWER_DRIVER:-"LAN_2_0"}
DHCP_RESERVATION_IP_START=${DHCP_RESERVATION_IP_START:-`echo ${SUBNET_IPS[@]:(-2):1}`}
DHCP_RESERVATION_IP_END=${DHCP_RESERVATION_IP_END:-`echo ${SUBNET_IPS[@]:(-64):1}`}

function set_ssh_keys() {
  [ ! -d ~/.ssh ] && mkdir ~/.ssh && chmod 0700 ~/.ssh
  [ ! -f ~/.ssh/id_rsa ] && ssh-keygen -t rsa -b 2048 -f ~/.ssh/id_rsa -N ''
  [ ! -f ~/.ssh/authorized_keys ] && touch ~/.ssh/authorized_keys && chmod 0600 ~/.ssh/authorized_keys
  grep "$(<~/.ssh/id_rsa.pub)" ~/.ssh/authorized_keys -q || cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys
}

# Install MAAS 2.7 and tools
sudo snap install maas --channel=2.7
sudo maas init --mode all \
    --maas-url "http://${NODE_IP}:5240/MAAS" \
    --admin-username "${MAAS_ADMIN}" \
    --admin-password "${MAAS_PASS}" \
    --admin-email "${MAAS_ADMIN_MAIL}"

# login
export PATH="$PATH:/snap/bin"
PROFILE="${MAAS_ADMIN}"
MAAS_URL="http://${NODE_IP}:5240/MAAS/api/2.0"
sudo maas apikey --username="$PROFILE" > ${MAAS_ADMIN}_API_KEY
maas login $PROFILE $MAAS_URL - < ${MAAS_ADMIN}_API_KEY

# Add public key to user "admin"
set_ssh_keys
SSH_KEY=$(cat ~/.ssh/id_rsa.pub)
maas $PROFILE sshkeys create "key=$SSH_KEY"

# Configure dns
maas $PROFILE maas set-config name=upstream_dns value=$UPSTREAM_DNS

# Configure dhcp
maas $PROFILE ipranges create type=dynamic \
    start_ip=${DHCP_RESERVATION[0]} end_ip=${DHCP_RESERVATION[1]}
maas $PROFILE vlan update 0 0 dhcp_on=True primary_rack=maas-dev

# Waiting for images downoad to complete
maas $PROFILE boot-resources import
i=0
while [ $i -le 30 ] ; do
  sleep 20
  i=$((i+1))
  if [[ `maas $PROFILE boot-resources is-importing` == "false" ]]; then
    if ! sudo lsof | grep -c "images.maas.io" ; then
      break
    fi
  fi
done

# Wait image sync on controller
sleep 15

for n in $IPMI_IPS ; do 
  maas $PROFILE machines create \
      architecture="amd64/generic" \
      hwe_kernel="ga-18.04" \
      power_type="ipmi" \
      power_parameters_power_driver=${IPMI_POWER_DRIVER} \
      power_parameters_power_user=${IPMI_USER} \
      power_parameters_power_pass=${IPMI_PASS} \
      power_parameters_power_address=${n}
done

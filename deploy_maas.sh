#!/bin/bash -xe
set -o pipefail

function set_ssh_keys() {
  [ ! -d ~/.ssh ] && mkdir ~/.ssh && chmod 0700 ~/.ssh
  [ ! -f ~/.ssh/id_rsa ] && ssh-keygen -t rsa -b 2048 -f ~/.ssh/id_rsa -N ''
  [ ! -f ~/.ssh/authorized_keys ] && touch ~/.ssh/authorized_keys && chmod 0600 ~/.ssh/authorized_keys
  grep "$(<~/.ssh/id_rsa.pub)" ~/.ssh/authorized_keys -q || cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys
}

# Install MAAS and tools
sudo apt-get update
sudo apt-get install snapd jq prips netmask -y
sudo snap install maas --channel=2.7

# Determined variables
PHYS_INT=`ip route get 1 | grep -o 'dev.*' | awk '{print($2)}'`
NODE_IP=`ip addr show dev $PHYS_INT | grep 'inet ' | awk '{print $2}' | head -n 1 | cut -d '/' -f 1`
NODE_IP_WSUBNET=`ip addr show dev $PHYS_INT | grep 'inet ' | awk '{print $2}' | head -n 1`
NODE_SUBNET=`netmask $NODE_IP_WSUBNET`
readarray -t SUBNET_IPS <<< "$(prips $NODE_SUBNET)"

# MAAS variables
MAAS_ADMIN=${MAAS_ADMIN:-"admin"}
MAAS_PASS=${MAAS_PASS:-"admin"}
MAAS_ADMIN_MAIL=${MAAS_ADMIN_MAIL:-"admin@maas.tld"}
UPSTREAM_DNS=${UPSTREAM_DNS:-"8.8.8.8"}
DHCP_RESERVATION_IP_START=${DHCP_RESERVATION_IP_START:-`echo ${SUBNET_IPS[@]:(-64):1}`}
DHCP_RESERVATION_IP_END=${DHCP_RESERVATION_IP_END:-`echo ${SUBNET_IPS[@]:(-2):1}`}

# Nodes for commissioning
IPMI_POWER_DRIVER=${IPMI_POWER_DRIVER:-"LAN_2_0"}
IPMI_IPS=${IPMI_IPS:-""}
IPMI_USER=${IPMI_USER:-"ADMIN"}
IPMI_PASS=${IPMI_PASS:-"ADMIN"}

# MAAS init
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
    start_ip=${DHCP_RESERVATION_IP_START} end_ip=${DHCP_RESERVATION_IP_END}
maas $PROFILE vlan update 0 0 dhcp_on=True primary_rack=maas-dev

# Import images. 
# Import may fail without any error messages, loop is workaround.
i=0
while [ $i -le 30 ] ; do
  maas $PROFILE boot-resources import
  i=$((i+1))
  sleep 5
  if maas $PROFILE boot-resources read | grep -q "ga-18.04"; then
    break
  fi
done

# Waiting for images downoad to complete
i=0
while [ $i -le 30 ] ; do
  sleep 20
  i=$((i+1))
  if maas $PROFILE boot-resources is-importing | grep 'false'; then
    break
  fi
done
sleep 15

# Add machines
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

# Wait for commissioning
sleep 180
i=0
while [ $i -le 30 ] ; do
  MASHINES_STATUS=`maas $PROFILE machines read | jq -r '.[] | .status_name'`
  MASHINES_COUNT=`echo "$MASHINES_STATUS" | wc -l`
  if [ -z $MASHINES_STATUS ]; then
    echo "MAAS setup is complete, but there are no any ready-to-use machines"
    exit 0
  fi
  if echo "$MASHINES_STATUS" | grep -q "Ready"; then    
    READY_COUNT=`echo "$MASHINES_STATUS" | grep -c "Ready"`
    if [ "$READY_COUNT" -ge "$MASHINES_COUNT" ]; then
      echo "MAAS READY"
      COMMISSIONING="success"
      break
    fi
  fi
  sleep 30
  i=$((i+1))
done
[[ -z "$COMMISSIONING" ]] && echo "ERROR: timeout exceeded" && exit 1

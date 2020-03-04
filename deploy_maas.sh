#!/bin/bash -xe
set -o pipefail

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

function set_ssh_keys() {
  [ ! -d ~/.ssh ] && mkdir ~/.ssh && chmod 0700 ~/.ssh
  [ ! -f ~/.ssh/id_rsa ] && ssh-keygen -t rsa -b 2048 -f ~/.ssh/id_rsa -N ''
  [ ! -f ~/.ssh/authorized_keys ] && touch ~/.ssh/authorized_keys && chmod 0600 ~/.ssh/authorized_keys
  grep "$(<~/.ssh/id_rsa.pub)" ~/.ssh/authorized_keys -q || cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys
}

sudo apt update
sudo apt-get install snapd -y
export PATH=$PATH:/snap/bin

sudo snap install maas --channel=2.7


sudo maas init --mode all \
    --maas-url "http://192.168.50.5:5240/MAAS" \
    --admin-username admin \
    --admin-password 12349876 \
    --admin-email ${USER}@domain.ltd

#login

PROFILE="admin"
MAAS_URL="http://192.168.50.5:5240/MAAS/api/2.0"
API_KEY_FILE=api_key
sudo maas apikey --username=$PROFILE > $API_KEY_FILE
maas login $PROFILE $MAAS_URL - < $API_KEY_FILE
set_ssh_keys
SSH_KEY=$(cat ~/.ssh/id_rsa.pub)
maas $PROFILE sshkeys create "key=$SSH_KEY"

#config values
MY_UPSTREAM_DNS="8.8.8.8"
maas $PROFILE maas set-config name=upstream_dns value=$MY_UPSTREAM_DNS


maas $PROFILE ipranges create type=dynamic \
    start_ip=192.168.50.100 end_ip=192.168.50.100 \
    comment='This is a reserved dynamic range'

maas $PROFILE vlan update 0 0 dhcp_on=True primary_rack=maas-dev

#maas $PROFILE boot-source-selections create 1 \
#    os="ubuntu" release="bionic" arches="amd64" \
#    subarches="*" labels="*"

maas $PROFILE boot-resources import
maas $PROFILE boot-resources read


maas $PROFILE machines create \
    architecture="amd64" \
    commission=false \
    power_type="ipmi" \
    power_parameters_power_driver=LAN_2_0 \
    power_parameters_power_user=ADMIN \
    power_parameters_power_pass=ADMIN \
    power_parameters_power_address=192.168.50.21
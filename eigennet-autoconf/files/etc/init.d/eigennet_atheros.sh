#!/bin/sh /etc/rc.common

<<COPYRIGHT

Copyright (C) 2010-2011  Gioacchino Mazzurco <gmazzurco89@gmail.com>

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this file.  If not, see <http://www.gnu.org/licenses/>.

COPYRIGHT

START=99
STOP=10

CONF_DIR="/etc/config/"

eigenDebug()
{
  [ $1 -ge $debugLevel ] &&
  {
    echo "Debug: $@" >> /tmp/eigenlog
  }
}

#[Doc]
#[Doc] Return physical interface list
#[Doc]
#[Doc] usage:
#[Doc] scan_interfacer
#[Doc]
scan_devices()
{
      eth=""
      radio=""
      wifi=""

      # Getting wired interfaces
      eth=$(cat /proc/net/dev | sed -n -e 's/:.*//' -e 's/[ /t]*//' -e '/^eth[0-9]$/p')

      # Getting ath9k interfaces
      if [ -e /lib/wifi/mac80211.sh ] && [ -e /sys/class/ieee80211/ ]; then
          radio=$(ls /sys/class/ieee80211/ | sed -n -e '/^phy[0-9]$/p' | sed -e 's/^phy/radio/')
      fi

      # Getting madwifi interfaces
      if [ -e /lib/wifi/madwifi.sh ]; then
          cd /proc/sys/dev/
          wifi=$(ls | grep wifi)
      fi

      echo "${eth} ${radio} ${wifi}" | sed 's/ /\n/g' | sed '/^$/d'
}

#[Doc]
#[Doc] Return MAC of given interface
#[Doc]
#[Doc] usage:
#[Doc] get_mac ifname
#[Doc]
#[Doc] example:
#[Doc] get_mac eth0
#[Doc]
get_mac()
{
      ifname=${1}
      ifbase=$(echo $ifname | sed -e 's/[0-9]*$//')

      if [ $ifbase == "wifi" ]; then
          mac=$(ifconfig $ifname | sed -n 1p | awk '{print $5}' | cut -c-17 | sed -e 's/-/:/g')
      elif [ $ifbase == "radio" ]; then
          mac=$(cat /sys/class/ieee80211/$(echo ${ifname} | sed 's/radio/phy/g')/addresses)
      elif [ $ifbase == "phy" ]; then
          mac=$(cat /sys/class/ieee80211/${ifname}/addresses)
      else
          mac=$(ifconfig $ifname | sed -n 1p | awk '{print $5}')
      fi

      echo $mac | tr '[a-z]' ['A-Z']
}

#[Doc]
#[Doc] Return given mac in ipv6 like format
#[Doc]
#[Doc] usage:
#[Doc] mac6ize mac_address
#[Doc]
#[Doc] example:
#[Doc] mac6ize ff:ff:ff:ff:ff:ff
#[Doc]
mac6ize()
{
    echo $1 | awk -F: '{print $1$2":"$3$4":"$5$6}' | tr '[a-z]' ['A-Z']
}

#[Doc]
#[Doc] Del given uci interface from network file 
#[Doc]
#[Doc] usage:
#[Doc] del_interface uci_interface_name
#[Doc]
#[Doc] example:
#[Doc] del_interface lan0
#[Doc]
del_interface()
{
  uci del network.$1
}

configureNetwork()
{
  local accept_clients		; config_get accept_clients	network		accept_clients 
  local firewallEnabled		; config_get firewallEnabled	network		firewallEnabled
  local ipv6prefix		; config_get ipv4prefix		network		client4Prefix
  local ipv4prefix		; config_get ipv6prefix		network		client6Prefix
  local meshPrefix		; config_get meshPrefix		network		mesh6Prefix
  local resolvers		; config_get resolvers		network		resolvers
  local sshEigenserverKey	; config_get sshEigenserverKey	network		sshEigenserverKey

  local ath9k_clients		; config_get ath9k_clients	wireless	ath9k_clients
  local ath9k_mesh		; config_get ath9k_mesh		wireless	ath9k_mesh
  local madwifi_clients		; config_get madwifi_clients	wireless	madwifi_clients
  local madwifi_mesh		; config_get madwifi_mesh	wireless	madwifi_mesh
  local mesh2channel		; config_get mesh2channel	wireless	mesh2channel
  local mesh5channel		; config_get mesh5channel	wireless	mesh5channel
  
  [ $firewallEnabled -eq 0 ] &&
  {
    /etc/init.d/firewall disable
  }
  
  echo "$sshEigenserverKey" >> "/etc/dropbear/authorized_keys"

  echo "
#Automatically generated for EigenNet

$(cat /etc/sysctl.conf | grep -v net.ipv4.ip_forward | grep -v net.ipv6.conf.all.forwarding | grep -v net.ipv6.conf.all.autoconf)

net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
net.ipv6.conf.all.autoconf=0
" > /etc/sysctl.conf

  echo "#Automatically generated for EigenNet" > $CONF_DIR/wireless
  
  for dns in $resolvers
  do
    echo nameserver $dns >> /etc/resolv.conf.auto
  done

  config_load network
  config_foreach del_interface interface

  for device in $(scan_devices)
  do
    devtype=$(echo $device | sed -e 's/[0-9]*$//')
    devindex=$(echo $device | sed -e 's/.*\([0-9]\)/\1/')

    case $devtype in
    "eth")
      uci set network.$device=interface
      uci set network.$device.ifname=$device
      uci set network.$device.proto=static
      uci set network.$device.ip6addr=$meshPrefix$(mac6ize $(get_mac $device))/64
      
      uci set babeld.$device=interface
      
      [ $accept_clients -eq 1 ] &&
      {	
	uci set network.$device.ipaddr=$ipv4prefix$devindex.1
	uci set network.$device.netmask=255.255.255.224

	uci set network.alias$device=alias
	uci set network.alias$device.interface=$device
	uci set network.alias$device.proto=static
	uci set network.alias$device.ip6addr=$ipv6prefix$devindex::1/64

	uci set radvd.alias$device=interface
	uci set radvd.alias$device.interface=alias$device
	uci set radvd.alias$device.AdvSendAdvert=1
	uci set radvd.alias$device.ignore=1

	uci set radvd.prefix$device=prefix
	uci set radvd.prefix$device.interface=alias$device
	uci set radvd.prefix$device.AdvOnLink=1
	uci set radvd.prefix$device.AdvAutonomous=1
	uci set radvd.prefix$device.ignore=1

	uci set dhcp.$device=dhcp
	uci set dhcp.$device.interface=$device
	uci set dhcp.$device.start=2
	uci set dhcp.$device.limit=28
	uci set dhcp.$device.leasetime=1h
      }
    ;;

    "wifi")
      uci set wireless.$device=wifi-device
      uci set wireless.$device.type=atheros
      uci set wireless.$device.channel=$mesh2channel
      uci set wireless.$device.disabled=0

      [ $madwifi_mesh -eq 1 ] &&
      {
	uci set wireless.mesh$device=wifi-iface
	uci set wireless.mesh$device.device=$device
	uci set wireless.mesh$device.network=mesh$device
	uci set wireless.mesh$device.sw_merge=1
	uci set wireless.mesh$device.mode=adhoc
	uci set wireless.mesh$device.ssid=Ninux.org
	uci set wireless.mesh$device.encryption=none

	uci set network.mesh$device=interface
	uci set network.mesh$device.proto=static
	uci set network.mesh$device.ip6addr=$meshPrefix$(mac6ize $(get_mac $device))/64

	uci set babeld.mesh$device=interface
      }

      [ $accept_clients -eq 1 ] && [ $madwifi_clients -eq 1 ] &&
      {
	uci set wireless.ap$device=wifi-iface
	uci set wireless.ap$device.device=$device
	uci set wireless.ap$device.network=ap$device
	uci set wireless.ap$device.sw_merge=1
	uci set wireless.ap$device.mode=ap
	uci set wireless.ap$device.ssid=EigenNet
	uci set wireless.ap$device.encryption=none

	uci set network.ap$device=interface
	uci set network.ap$device.proto=static
	uci set network.ap$device.ip6addr=$ipv6prefix$devindex::1/64
	uci set network.ap$device.ipaddr=$ipv4prefix$devindex.1
	uci set network.ap$device.netmask=255.255.255.224

	uci set radvd.ap$device=interface
	uci set radvd.ap$device.interface=ap$device
	uci set radvd.ap$device.AdvSendAdvert=1
	uci set radvd.ap$device.ignore=1

	uci set radvd.prefix$device=prefix
	uci set radvd.prefix$device.interface=alias$device
	uci set radvd.prefix$device.AdvOnLink=1
	uci set radvd.prefix$device.AdvAutonomous=1
	uci set radvd.prefix$device.ignore=1

	uci set dhcp.ap$device=dhcp
	uci set dhcp.ap$device.interface=$device
	uci set dhcp.ap$device.start=2
	uci set dhcp.ap$device.limit=28
	uci set dhcp.ap$device.leasetime=5m
      }
    ;;

    "radio")
      uci set wireless.$device=wifi-device
      uci set wireless.$device.type=mac80211
      uci set wireless.$device.macaddr=$(get_mac $device)
      uci set wireless.$device.channel=$mesh2channel
      uci set wireless.$device.disabled=0

      [ $ath9k_mesh -eq 1 ] &&
      {
	uci set wireless.mesh$device=wifi-iface
	uci set wireless.mesh$device.device=$device
	uci set wireless.mesh$device.network=mesh$device
	uci set wireless.mesh$device.sw_merge=1
	uci set wireless.mesh$device.mode=adhoc
	uci set wireless.mesh$device.ssid=Ninux.org
	uci set wireless.mesh$device.encryption=none

	uci set network.mesh$device=interface
	uci set network.mesh$device.proto=static
	uci set network.mesh$device.ip6addr=$meshPrefix$(mac6ize $(get_mac $device))/64

	uci set babeld.mesh$device=interface
      }

      [ $accept_clients -eq 1 ] && [ $ath9k_clients -eq 1 ] && 
      {
	uci set wireless.ap$device=wifi-iface
	uci set wireless.ap$device.device=$device
	uci set wireless.ap$device.network=ap$device
	uci set wireless.ap$device.sw_merge=1
	uci set wireless.ap$device.mode=ap
	uci set wireless.ap$device.ssid=EigenNet
	uci set wireless.ap$device.encryption=none

	uci set network.ap$device=interface
	uci set network.ap$device.proto=static
	uci set network.ap$device.ip6addr=$ipv6prefix$devindex::1/64
	uci set network.ap$device.ipaddr=$ipv4prefix$devindex.1
	uci set network.ap$device.netmask=255.255.255.224

	uci set radvd.ap$device=interface
	uci set radvd.ap$device.interface=ap$device
	uci set radvd.ap$device.AdvSendAdvert=1
	uci set radvd.ap$device.ignore=1

	uci set radvd.prefix$device=prefix
	uci set radvd.prefix$device.interface=alias$device
	uci set radvd.prefix$device.AdvOnLink=1
	uci set radvd.prefix$device.AdvAutonomous=1
	uci set radvd.prefix$device.ignore=1

	uci set dhcp.ap$device=dhcp
	uci set dhcp.ap$device.interface=$device
	uci set dhcp.ap$device.start=2
	uci set dhcp.ap$device.limit=28
	uci set dhcp.ap$device.leasetime=5m
      }
    ;;
    esac
  done

  [ $accept_clients -eq 1 ] &&
  {
    uci set babeld.fallback64=filter
    uci set babeld.fallback64.type=redistribute
    uci set babeld.fallback64.ip="$meshPrefix:/64"
    uci set babeld.fallback64.action=deny
    
    uci set babeld.clients6=filter
    uci set babeld.clients6.type=redistribute
    uci set babeld.clients6.ip="::0/0"
    uci set babeld.clients6.action="metric 386"
    
    uci set babeld.clients4=filter
    uci set babeld.clients4.type=redistribute
    uci set babeld.clients4.ip="0.0.0.0/0"
    uci set babeld.clients4.action="metric 384"
  }

  uci set eigennet.general.bootmode=2

  uci commit
}


start()
{
  config_load	eigennet

  config_get debugLevel	general	debugLevel
  config_get bootmode	general	bootmode
  
  eigenDebug 0 "Starting"

  [ $bootmode -eq 0 ] &&
  {
	sleep 61s
	uci set eigennet.general.bootmode=1
	uci commit eigennet
	reboot
	return 0
  }

  [ $bootmode -eq 1 ] &&
  {
    sleep 10s
    
    configureNetwork

    reboot
  }

  [ $bootmode -ge 2 ] &&
  {
	sysctl -w net.ipv4.ip_forward=1
	sysctl -w net.ipv6.conf.all.forwarding=1
	sysctl -w net.ipv6.conf.all.autoconf=0

	return 0
  }
}

stop()
{
  eigenDebug 0 "Stopping"
}

restart()
{
  stop
  sleep 2s
  start
}

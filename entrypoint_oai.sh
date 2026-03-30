#!/bin/bash

killall nr-softmodem
pkill -9 nr-softmodem

export LUA_SCHED=/phy/openairinterface5g/pf_dl_simple.lua
export LUA_SCHED_UL=/phy/openairinterface5g/pf_ul_simple.lua

current_folder=$PWD
cp /etc/oai/gnb.conf /gnb.conf

CONFIG_FILE=/gnb.conf

# Parsing of CPU cores, MAC addresses, etc.
python3 parsing_oai.py $CONFIG_FILE --ru-mac $RU_MAC

# This is the core network parsing inside the oai file to use core network 001/01
interface=eth0
AMF_IP=$(dig $CORE_NETWORK +short)
sed -i "s/ipv4\s*=\s*\"[0-9.]\+\"/ipv4 = \"$AMF_IP\"/g" $CONFIG_FILE
IP_NGU=$(ip -4 a show $interface | grep -Po 'inet \K[0-9.]*')
sed -i "s/GNB_IPV4_ADDRESS_FOR_NG_AMF\s*=\s*\"[0-9./]\+\"/GNB_IPV4_ADDRESS_FOR_NG_AMF = \"$IP_NGU\"/g" $CONFIG_FILE
sed -i "s/GNB_IPV4_ADDRESS_FOR_NGU\s*=\s*\"[0-9./]\+\"/GNB_IPV4_ADDRESS_FOR_NGU = \"$IP_NGU\"/g" $CONFIG_FILE
cd /phy/openairinterface5g/cmake_targets/ran_build/build/ 
/phy/openairinterface5g/cmake_targets/ran_build/build/nr-softmodem -O /gnb.conf

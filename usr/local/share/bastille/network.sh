#!/bin/sh
#
# SPDX-License-Identifier: BSD-3-Clause
#
# Copyright (c) 2018-2025, Christer Edwards <christer.edwards@gmail.com>
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#
# * Redistributions of source code must retain the above copyright notice, this
#   list of conditions and the following disclaimer.
#
# * Redistributions in binary form must reproduce the above copyright notice,
#   this list of conditions and the following disclaimer in the documentation
#   and/or other materials provided with the distribution.
#
# * Neither the name of the copyright holder nor the names of its
#   contributors may be used to endorse or promote products derived from
#   this software without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
# AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
# DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
# FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
# SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
# CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
# OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
# OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

. /usr/local/share/bastille/common.sh
. /usr/local/etc/bastille/bastille.conf

usage() {
    error_notify "Usage: bastille network [option(s)] TARGET [remove|add] INTERFACE [IP]"
    cat << EOF
	
    Options:

    -a | --auto                 Start/stop the jail(s) if required.
    -B | --bridge               Add a bridged VNET interface to an existing jail.
    -C | --classic              Add an interface to a classic (non-VNET) jail.
    -M | --static-mac           Generate a static MAC address for the interface.
    -n | --no-ip                Create interface without an IP (VNET only).
    -P | --passthrough          Pass the entire interface through to the jail.
    -V | --vnet                 Add a VNET interface to an existing jail.
    -v | --vlan VLANID          Add interface with specified VLAN ID (VNET only).
    -x | --debug                Enable debug mode.
    
EOF
    exit 1
}

# Handle options.
AUTO=0
BRIDGE=0
CLASSIC=0
STATIC_MAC=0
PASSTHROUGH=0
VNET=0
VLAN_ID=""
NO_IP=0
while [ "$#" -gt 0 ]; do
    case "${1}" in
        -h|--help|help)
            usage
            ;;
        -a|--auto)
            AUTO=1
            shift
            ;;
        -B|--bridge)
            BRIDGE=1
            shift
            ;;
        -C|--classic)
            CLASSIC=1
            shift
            ;; 
        -M|--static-mac)
            STATIC_MAC=1
            shift
            ;;
        -n|--no-ip)
            NO_IP=1
            shift
            ;;
        -P|--passthrough)
            PASSTHROUGH=1
            shift
            ;;
        -V|--vnet)
            VNET=1
            shift
            ;;
        -v|--vlan)
	    if echo "${2}" | grep -Eq '^[0-9]+$'; then
                VLAN_ID="${2}"
	    else
                error_exit "Not a valid VLAN ID: ${2}"
	    fi
            shift 2
            ;;
        -x|--debug)
            enable_debug
            shift
            ;;        
        -*)
            for _o in $(echo ${1} 2>/dev/null | sed 's/-//g' | fold -w1); do
                case ${_o} in
                    a) AUTO=1 ;;
                    B) BRIDGE=1 ;;
                    C) CLASSIC=1 ;;
                    M) STATIC_MAC=1 ;;
                    n) NO_IP=1 ;;
                    P) PASSTHROUGH=1 ;;
                    V) VNET=1 ;;
                    x) enable_debug ;;
                    *) error_exit "[ERROR]: Unknown Option: \"${1}\"" ;; 
                esac
            done
            shift
            ;;
        *)
            break
            ;;
    esac
done

TARGET="${1}"
ACTION="${2}"
INTERFACE="${3}"
if [ "${ACTION}" = "add" ] && [ "${NO_IP}" -eq 0 ] && [ -n "${4}" ]; then
    IP="${4}"
elif [ "${NO_IP}" -eq 1 ] && [ -n "${4}" ]; then
    error_exit "[ERROR]: IP should not be present when using -n|--no-ip."
else
    IP=""
fi

if [ "${ACTION}" = "add" ]; then
    if { [ "${VNET}" -eq 1 ] && [ "${BRIDGE}" -eq 1 ]; } || \
       { [ "${VNET}" -eq 1 ] && [ "${CLASSIC}" -eq 1 ]; } || \
       { [ "${VNET}" -eq 1 ] && [ "${PASSTHROUGH}" -eq 1 ]; } || \
       { [ "${BRIDGE}" -eq 1 ] && [ "${CLASSIC}" -eq 1 ]; } || \
       { [ "${BRIDGE}" -eq 1 ] && [ "${PASSTHROUGH}" -eq 1 ]; } || \
       { [ "${CLASSIC}" -eq 1 ] && [ "${PASSTHROUGH}" -eq 1 ]; } then
        error_exit "[ERROR]: Only one of [-B|--bridge], [-C|--classic], [-P|--passthrough] or [-V|--vnet] should be set."
    elif [ "${VNET}" -eq 0 ] && [ "${BRIDGE}" -eq 0 ] && [ "${CLASSIC}" -eq 0 ] && [ "${PASSTHROUGH}" -eq 0 ]; then 
        error_exit "[ERROR]: [-B|--bridge], [-C|--classic], [-P|--passthrough] or [-V|--vnet] must be set."
    elif [ "${VNET}" -eq 0 ] && [ "${BRIDGE}" -eq 0 ] && [ "${PASSTHROUGH}" -eq 0 ] && [ -n "${VLAN_ID}" ]; then
        error_exit "[ERROR]: VLANs can only be used with VNET interfaces."
    elif [ "${VNET}" -eq 0 ] && [ "${BRIDGE}" -eq 0 ] && [ "${NO_IP}" -eq 1 ]; then
        error_exit "[ERROR]: [-n|--no-ip] can only be used with VNET jails."
    elif [ "${bastille_network_vnet_type}" = "netgraph" ] && [ "${BRIDGE}" -eq 1 ]; then
        error_exit "[ERROR]: [-B|--bridge] cannot be used with Netgraph."
    fi
fi

if [ "$#" -lt 2 ] || [ "$#" -gt 4 ]; then
    usage
fi

bastille_root_check
set_target_single "${TARGET}"

# Validate jail state
check_target_is_stopped "${TARGET}" || if [ "${AUTO}" -eq 1 ]; then
    bastille stop "${TARGET}"
else
    info "\n[${_jail}]:"
    error_notify "Jail is running."
    error_exit "Use [-a|--auto] to auto-stop the jail."
fi

validate_ip() {

    local ip="${1}"
    local ip6="$( echo "${ip}" 2>/dev/null | grep -E '^(([a-fA-F0-9:]+$)|([a-fA-F0-9:]+\/[0-9]{1,3}$)|SLAAC)' )"

    if [ -n "${ip6}" ]; then
        info "\nValid: (${ip6})."
        IP6_ADDR="${ip6}"
    elif [ "${ip}" = "0.0.0.0" ] || [ "${ip}" = "DHCP" ] || [ "${ip}" = "SYNCDHCP" ]; then
        info "\nValid: (${ip})."
        IP4_ADDR="${ip}"
    else
        local IFS
        if echo "${ip}" 2>/dev/null | grep -Eq '^(([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.){3}([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])(\/([0-9]|[1-2][0-9]|3[0-2]))?$'; then
            TEST_IP=$(echo "${ip}" | cut -d / -f1)
            IFS=.
            set ${TEST_IP}
            for quad in 1 2 3 4; do
                if eval [ \$$quad -gt 255 ]; then
                    error_exit "Invalid: (${TEST_IP})"
                fi
            done
            info "\nValid: (${ip})."
            IP4_ADDR="${ip}"
        else
            error_exit "Invalid: (${ip})."
        fi
    fi
}

validate_netif() {

    local _interface="${1}"

    if ifconfig -l | grep -qwo ${_interface}; then
        info "\nValid: (${_interface})."
    else
        error_exit "Invalid: (${_interface})."
    fi
}

check_interface_added() {

    local _jailname="${1}"
    local _if="${2}"
    local _jail_config="${bastille_jailsdir}/${_jailname}/jail.conf" 

    if grep -qo "${_if}" "${_jail_config}"; then
        return 0
    else 
        return 1
    fi
}

add_interface() {

    local _jailname="${1}"
    local _if="${2}"
    local _ip="${3}"
    local _jail_config="${bastille_jailsdir}/${_jailname}/jail.conf"
    local _jail_rc_config="${bastille_jailsdir}/${_jailname}/root/etc/rc.conf"
    # Get number of interfaces manged by Bastille
    get_bastille_if_count
    local _vnet_if_count="$(grep -Eo 'vnet[1-9]+' ${_jail_rc_config} | sort -u | wc -l | awk '{print $1}')"
    local _if_vnet="vnet$((_vnet_if_count + 1))"
    local _bastille_if_num_range=$((_bastille_if_count + 1))

    if [ "${BRIDGE}" -eq 1 ]; then
       if [ "${_bastille_if_count}" -gt 0 ]; then  
            for _num in $(seq 0 "${_bastille_if_num_range}"); do
                if ! echo "${_bastille_if_list}" | grep -oqswx "${_num}"; then
                    if [ "$(echo -n "e${_num}a_${jail_name}" | awk '{print length}')" -lt 16 ]; then
                        local host_epair=e${_num}a_${_jailname}
                        local jail_epair=e${_num}b_${_jailname}
                    else
                        local host_epair=epair${_num}a
                        local jail_epair=epair${_num}b
                    fi
                    break
                fi
            done
        else
            if [ "$(echo -n "e0a_${_jailname}" | awk '{print length}')" -lt 16 ]; then
                local _num=0
                local host_epair=e${_num}a_${_jailname}
                local jail_epair=e${_num}b_${_jailname}
            else
                local _num=0
                local host_epair=epair${_num}a
                local jail_epair=epair${_num}b
            fi
        fi
        # Remove ending brace (it is added again with the netblock)
        sed -i '' '/}/d' "${_jail_config}"
        if [ "${STATIC_MAC}" -eq 1 ]; then
            # Generate NETBLOCK with static MAC
            generate_static_mac "${_jailname}" "${_if}"
            cat << EOF >> "${_jail_config}"
  ## ${host_epair} interface
  vnet.interface += ${jail_epair};
  exec.prestart += "ifconfig epair${_num} create";
  exec.prestart += "ifconfig ${_if} addm epair${_num}a";
  exec.prestart += "ifconfig epair${_num}a up name ${host_epair}";
  exec.prestart += "ifconfig epair${_num}b up name ${jail_epair}";
  exec.prestart += "ifconfig ${host_epair} ether ${macaddr}a";
  exec.prestart += "ifconfig ${jail_epair} ether ${macaddr}b";
  exec.prestart += "ifconfig ${host_epair} description \"${_if_vnet} host interface for Bastille jail ${_jailname}\"";
  exec.poststop += "ifconfig ${_if} deletem ${host_epair}";
  exec.poststop += "ifconfig ${host_epair} destroy";
}
EOF
        else
            # Generate NETBLOCK without static MAC
            cat << EOF >> "${_jail_config}"
  ## ${host_epair} interface
  vnet.interface += ${jail_epair};
  exec.prestart += "ifconfig epair${_num} create";
  exec.prestart += "ifconfig ${_if} addm epair${_num}a";
  exec.prestart += "ifconfig epair${_num}a up name ${host_epair}";
  exec.prestart += "ifconfig epair${_num}b up name ${jail_epair}";
  exec.prestart += "ifconfig ${host_epair} description \"${_if_vnet} host interface for Bastille jail ${_jailname}\"";
  exec.poststop += "ifconfig ${_if} deletem ${host_epair}";
  exec.poststop += "ifconfig ${host_epair} destroy";
}
EOF
        fi
	
        # Add config to /etc/rc.conf
        sysrc -f "${_jail_rc_config}" ifconfig_${jail_epair}_name="${_if_vnet}"
	    if [ -n "${IP6_ADDR}" ]; then
            if [ "${IP6_ADDR}" = "SLAAC" ]; then
                sysrc -f "${_jail_rc_config}" ifconfig_${_if_vnet}_ipv6="inet6 -ifdisabled accept_rtadv"
            else
                sysrc -f "${_jail_rc_config}" ifconfig_${_if_vnet}_ipv6="inet6 -ifdisabled ${IP6_ADDR}"
            fi
        elif [ -n "${IP4_ADDR}" ]; then
            # If 0.0.0.0 set DHCP, else set static IP address
            if [ "${_ip}" = "0.0.0.0" ] || [ "${_ip}" = "DHCP" ] || [ "${_ip}" = "SYNCDHCP" ]; then
                sysrc -f "${_jail_rc_config}" ifconfig_${_if_vnet}="SYNCDHCP"
            else
                sysrc -f "${_jail_rc_config}" ifconfig_${_if_vnet}="inet ${IP4_ADDR}"
            fi
        fi

        echo "Added interface: \"${_if}\""

    elif [ "${VNET}" -eq 1 ]; then
        if [ "${bastille_network_vnet_type}" = "if_bridge" ]; then
            for _num in $(seq 0 "${_bastille_if_num_range}"); do
                if ! echo "${_bastille_if_list}" | grep -oqswx "${_num}"; then
                        local _jail_if="bastille${_num}"
                        break
                fi
            done
            # Remove ending brace (it is added again with the netblock)
            sed -i '' '/}/d' "${_jail_config}"
            if [ "${STATIC_MAC}" -eq 1 ]; then
                # Generate NETBLOCK with static MAC
                generate_static_mac "${_jailname}" "${_if}"
                cat << EOF >> "${_jail_config}"
  ## ${_jail_if} interface
  vnet.interface += e0b_${_jail_if};
  exec.prestart += "jib addm ${_jail_if} ${_if}";
  exec.prestart += "ifconfig e0a_${_jail_if} ether ${macaddr}a";
  exec.prestart += "ifconfig e0b_${_jail_if} ether ${macaddr}b";
  exec.prestart += "ifconfig e0a_${_jail_if} description \"${_if_vnet} host interface for Bastille jail ${_jailname}\"";
  exec.poststop += "jib destroy ${_jail_if}";
}
EOF
            else
                # Generate NETBLOCK without static MAC
                cat << EOF >> "${_jail_config}"
  ## ${_jail_if} interface
  vnet.interface += e0b_${_jail_if};
  exec.prestart += "jib addm ${_jail_if} ${_if}";
  exec.prestart += "ifconfig e0a_${_jail_if} description \"${_if_vnet} host interface for Bastille jail ${_jailname}\"";
  exec.poststop += "jib destroy ${_jail_if}";
}
EOF
            fi
            # Add config to /etc/rc.conf
            sysrc -f "${_jail_rc_config}" ifconfig_e0b_${_jail_if}_name="${_if_vnet}"
	        if [ -n "${IP6_ADDR}" ]; then
                if [ "${IP6_ADDR}" = "SLAAC" ]; then
                    sysrc -f "${_jail_rc_config}" ifconfig_${_if_vnet}_ipv6="inet6 -ifdisabled accept_rtadv"
                else
                    sysrc -f "${_jail_rc_config}" ifconfig_${_if_vnet}_ipv6="inet6 -ifdisabled ${IP6_ADDR}"
                fi
            elif [ -n "${IP4_ADDR}" ]; then
                # If 0.0.0.0 set DHCP, else set static IP address
                if [ "${_ip}" = "0.0.0.0" ] || [ "${_ip}" = "DHCP" ] || [ "${_ip}" = "SYNCDHCP" ]; then
                    sysrc -f "${_jail_rc_config}" ifconfig_${_if_vnet}="SYNCDHCP"
                else
                    sysrc -f "${_jail_rc_config}" ifconfig_${_if_vnet}="inet ${IP4_ADDR}"
                fi
            fi
            echo "Added VNET interface: \"${_if}\""

        elif [ "${bastille_network_vnet_type}" = "netgraph" ]; then
            for _num in $(seq 0 "${_bastille_if_num_range}"); do
                if ! echo "${_bastille_if_list}" | grep -oqswx "${_num}"; then
                        local _jail_if="bastille${_num}"
                        break
                fi
            done
            # Remove ending brace (it is added again with the netblock)
            sed -i '' '/}/d' "${_jail_config}"
            if [ "${STATIC_MAC}" -eq 1 ]; then
                # Generate NETBLOCK with static MAC
                generate_static_mac "${_jailname}" "${_if}"
                cat << EOF >> "${_jail_config}"
  ## ${_jail_if} interface
  vnet.interface += ng0_${_jail_if};
  exec.prestart += "jng bridge ${_jail_if} ${_if}";
  exec.prestart += "ifconfig ng0_${_jail_if} ether ${macaddr}a";
  exec.poststop += "jng shutdown ${_jail_if}";
}
EOF
            else
                # Generate NETBLOCK without static MAC
                cat << EOF >> "${_jail_config}"
  ## ${_jail_if} interface
  vnet.interface += e0b_${_jail_if};
  exec.prestart += "jng bridge ${_jail_if} ${_if}";
  exec.poststop += "jng shutdown ${_jail_if}";
}
EOF
            fi
            # Add config to /etc/rc.conf
            sysrc -f "${_jail_rc_config}" ifconfig_jng_${_jail_if}_name="${_if_vnet}"
	        if [ -n "${_ip}" ]; then
                # If 0.0.0.0 set DHCP, else set static IP address
                if [ "${_ip}" = "0.0.0.0" ] || [ "${_ip}" = "DHCP" ]; then
                    sysrc -f "${_jail_rc_config}" ifconfig_${_if_vnet}="SYNCDHCP"
                else
                    sysrc -f "${_jail_rc_config}" ifconfig_${_if_vnet}="inet ${_ip}"
                fi
	        fi
            echo "Added VNET interface: \"${_if}\""
        fi

    elif [ "${PASSTHROUGH}" -eq 1 ]; then
        # Remove ending brace (it is added again with the netblock)
        sed -i '' '/}/d' "${_jail_config}"
        # Generate NETBLOCK (static MAC not used on passthrough)
        cat << EOF >> "${_jail_config}"
  ## ${_if} interface
  vnet.interface += ${_if};
  exec.prestop += "ifconfig ${_if} -vnet ${_jailname}";
}
EOF
        # Add config to /etc/rc.conf
	    if [ -n "${IP6_ADDR}" ]; then
            if [ "${IP6_ADDR}" = "SLAAC" ]; then
                sysrc -f "${_jail_rc_config}" ifconfig_${_if_vnet}_ipv6="inet6 -ifdisabled accept_rtadv"
            else
                sysrc -f "${_jail_rc_config}" ifconfig_${_if_vnet}_ipv6="inet6 -ifdisabled ${IP6_ADDR}"
            fi
        elif [ -n "${IP4_ADDR}" ]; then
            # If 0.0.0.0 set DHCP, else set static IP address
            if [ "${_ip}" = "0.0.0.0" ] || [ "${_ip}" = "DHCP" ] || [ "${_ip}" = "SYNCDHCP" ]; then
                sysrc -f "${_jail_rc_config}" ifconfig_${_if_vnet}="SYNCDHCP"
            else
                sysrc -f "${_jail_rc_config}" ifconfig_${_if_vnet}="inet ${IP4_ADDR}"
            fi
        fi
        echo "Added Passthrough interface: \"${_if}\""
 
    elif [ "${CLASSIC}" -eq 1 ]; then
        if [ -n "${IP6_ADDR}" ]; then
            sed -i '' "s/interface = .*/&\n  ip6.addr += ${_if}|${_ip};/" ${_jail_config}
        else
            sed -i '' "s/interface = .*/&\n  ip4.addr += ${_if}|${_ip};/" ${_jail_config}
        fi
    fi

    echo "Added interface: \"${_if}\""
}

remove_interface() {

    local _jailname="${1}"
    local _if="${2}"
    local _jail_config="${bastille_jailsdir}/${_jailname}/jail.conf"

    # Skip next block in case of classic jail
    if [ "$(bastille config ${TARGET} get vnet)" != "not set" ]; then
        local _jail_rc_config="${bastille_jailsdir}/${_jailname}/root/etc/rc.conf"
        if grep -q ${_if} ${_jail_config} | grep -Eoq -m 1 'bastille[0-9]+'; then
            local _if_bastille_num="$(grep ${_if} ${_jail_config} | grep -Eo -m 1 "bastille[0-9]+" | grep -Eo "[0-9]+")"
            if [ "${bastille_network_vnet_type}" = "if_bridge" ]; then
                local _if_jail="e0b_bastille${_if_bastille_num}"
            elif [ "${bastille_network_vnet_type}" = "netgraph" ]; then
                local _if_jail="ng0_bastille${_if_bastille_num}"
            fi
            _if_type="bastille"
        elif grep -q ${_if} ${_jail_config} | grep -Eoq -m 1 "epair[0-9]+"; then
            local _if_epair_num="$(grep ${_if} ${_jail_config} | grep -Eo -m 1 "epair[0-9]+" | grep -Eo "[0-9]+")"
            if grep -q epair${_if_epair_num}b ${_jail_config} | grep -Eoq -m 1 "e${_if_epair_num}b_${_jailname}"; then
                local _if_jail="$(grep epair${_if_epair_num}b ${_jail_config} | grep -Eo -m 1 "e${_if_epair_num}b_${_jailname}")"
            else
                local _if_jail="epair${_if_epair_num}b"
            fi
            _if_type="epair"
        elif grep -q "vnet.interface.*${_if};" ${_jail_config}; then
            local _if_jail="${_if}"
            _if_type="passthrough"
        else
            error_exit "[ERROR]: Could not find interface inside jail: \"${_if_jail}\""
        fi
        
        if [ "${_if_type}" = "bastille" ] || [ "${_if_type}" = "epair" ]; then
            if grep -oq "${_if_jail}" ${_jail_config}; then
                local _if_vnet="$(grep ${_if_jail} ${_jail_rc_config} | grep -Eo 'vnet[0-9]+')"
            else
                error_exit "[ERROR]: Interface not found: ${_if_jail}"
            fi
        elif [ "${_if_type}" = "passthrough" ]; then
            if grep -oq "${_if_jail}" ${_jail_config}; then
                local _if_vnet="${_if_jail}"
            else
                error_exit "[ERROR]: Interface not found: ${_if_jail}"
            fi
        fi
    
        # Do not allow removing default vnet0 interface
        if [ "${_if_vnet}" = "vnet0" ]; then
            error_exit "[ERROR]: Default interface cannot be removed."
        fi

        # Avoid removing entire file contents if variables aren't set for some reason
        if [ -z "${_if_jail}" ]; then
            error_exit "[ERROR]: Could not find specifed interface."
        fi
       
        # Remove interface from /etc/rc.conf
        if [ "${_if_type}" = "bastille" ] || [ "${_if_type}" = "epair" ]; then
            if [ -n "${_if_vnet}" ] && echo ${_if_vnet} 2>/dev/null | grep -Eoq 'vnet[0-9]+'; then
                sed -i '' "/.*${_if_vnet}.*/d" "${_jail_rc_config}"
            else
                error_exit "[ERROR]: Failed to remove interface from /etc/rc.conf"
            fi
        elif [ "${_if_type}" = "passthrough" ]; then
            if [ -n "${_if_vnet}" ]; then
                sed -i '' "/.*${_if_vnet}.*/d" "${_jail_rc_config}"
            else
                error_exit "[ERROR]: Failed to remove interface from /etc/rc.conf"
            fi
        fi

        # Remove VNET interface from jail.conf (VNET)
        if [ -n "${_if_jail}" ]; then
            if [ "${_if_type}" = "epair" ]; then
                sed -i '' "/.*epair${_if_epair_num}.*/d" "${_jail_config}" 
                sed -i '' "/.*e${_if_epair_num}a_${_jailname}.*/d" "${_jail_config}" 
                sed -i '' "/.*e${_if_epair_num}b_${_jailname}.*/d" "${_jail_config}" 
            elif [ "${_if_type}" = "bastille" ]; then
                sed -i '' "/.*${_if_jail}.*/d" "${_jail_config}"
                sed -i '' "/.*bastille${_if_bastille_num}.*/d" "${_jail_config}"
            elif [ "${_if_type}" = "passthrough" ]; then
                sed -i '' "/.*${_if_jail}.*/d" "${_jail_config}"
            fi
        else
            error_exit "[ERROR]: Failed to remove interface from jail.conf"
        fi
    else
        # Remove interface from jail.conf (non-VNET)
        if [ -n "${_if}" ]; then
            if grep ${_if} ${_jail_config} 2>/dev/null | grep -qo " = "; then
                error_exit "[ERROR]: Default interface cannot be removed."
            else
                sed -i '' "/.*${_if}.*/d" "${_jail_config}"
            fi
        else
            error_exit "[ERROR]: Failed to remove interface from jail.conf"
        fi
    fi

    echo "Removed interface: \"${_if}\""
}

add_vlan() {

    local _jailname="${1}"
    local _interface="${2}"
    local _ip="${3}"
    local _vlan_id="${4}"
    local _jail_config="${bastille_jailsdir}/${_jailname}/jail.conf"
    local _jail_rc_config="${bastille_jailsdir}/${_jailname}/root/etc/rc.conf"

    if [ "${VNET}" -eq 1 ]; then
        local _jail_epair_num="$(grep ${_interface} ${_jail_config} | grep -Eo -m 1 "bastille[0-9]+" | grep -Eo "[0-9]+")"
	local _jail_vnet="$(grep "e0b_bastille${_jail_epair_num}_name" ${_jail_rc_config} | grep -Eo "vnet[0-9]+")"
    elif [ "${BRIDGE}" -eq 1 ]; then
        local _jail_epair_num="$(grep ${_interface} ${_jail_config} | grep -Eo -m 1 "epair[0-9]+" | grep -Eo "[0-9]+")"
	local _jail_vnet="$(grep "e.*${_jail_epair_num}b.*_name" ${_jail_rc_config} | grep -Eo "vnet[0-9]+")"
    elif [ "${PASSTHROUGH}" -eq 1 ]; then
        local _jail_vnet="${_interface}"
    fi
    if grep -Eq "ifconfig_${_jail_vnet}_${_vlan_id}" "${bastille_jailsdir}/${_jailname}/root/etc/rc.conf"; then
        error_exit "[ERROR]: VLAN has already been added: VLAN ${_vlan_id}"
    else
        bastille start "${_jailname}"
        bastille template "${_jailname}" ${bastille_template_vlan} --arg VLANID="${_vlan_id}" --arg IFCONFIG="inet ${_ip}" --arg JAIL_VNET="${_jail_vnet}"
        bastille restart "${_jailname}"
    fi

    echo "Added VLAN ${_vlan_id} to interface: \"${_jail_vnet}\""
}

info "\n[${TARGET}]:"

case "${ACTION}" in
    add)
        validate_netconf
        validate_netif "${INTERFACE}"
        if check_interface_added "${TARGET}" "${INTERFACE}" && [ -z "${VLAN_ID}" ]; then
            error_exit "Interface is already added: \"${INTERFACE}\""
        elif { [ "${VNET}" -eq 1 ] || [ "${BRIDGE}" -eq 1 ] || [ "${PASSTHROUGH}" -eq 1 ]; } && [ -n "${VLAN_ID}" ]; then
            add_vlan "${TARGET}" "${INTERFACE}" "${IP}" "${VLAN_ID}"
            echo
            exit 0
        fi
        ## validate IP if not empty
        if [ -n "${IP}" ]; then
            validate_ip "${IP}"
        fi
        if [ "${VNET}" -eq 1 ]; then
            if [ "$(bastille config ${TARGET} get vnet)" = "not set" ]; then
                error_exit "[ERROR]: ${TARGET} is not a VNET jail."
            elif ifconfig -g bridge | grep -owq "${INTERFACE}"; then
                error_exit "[ERROR]: '${INTERFACE}' is a bridge interface."
            else
                add_interface "${TARGET}" "${INTERFACE}" "${IP}"
                if [ -n "${VLAN_ID}" ]; then
                    add_vlan "${TARGET}" "${INTERFACE}" "${IP}" "${VLAN_ID}"
                fi
                if [ "${AUTO}" -eq 1 ]; then
                    bastille start "${TARGET}"
                fi
            fi
        elif [ "${BRIDGE}" -eq 1 ]; then
            if [ "$(bastille config ${TARGET} get vnet)" = "not set" ]; then
                error_exit "[ERROR]: ${TARGET} is not a VNET jail."
            elif ! ifconfig -g bridge | grep -owq "${INTERFACE}"; then
                error_exit "[ERROR]: '${INTERFACE}' is not a bridge interface."
            else
                add_interface "${TARGET}" "${INTERFACE}" "${IP}"
                if [ -n "${VLAN_ID}" ]; then
                    add_vlan "${TARGET}" "${INTERFACE}" "${IP}" "${VLAN_ID}"
                fi
                if [ "${AUTO}" -eq 1 ]; then
                    bastille start "${TARGET}"
                fi
            fi
        elif [ "${PASSTHROUGH}" -eq 1 ]; then
            if [ "$(bastille config ${TARGET} get vnet)" = "not set" ]; then
                error_exit "[ERROR]: ${TARGET} is not a VNET jail."
	    else
                add_interface "${TARGET}" "${INTERFACE}" "${IP}"
            fi
            if [ -n "${VLAN_ID}" ]; then
                add_vlan "${TARGET}" "${INTERFACE}" "${IP}" "${VLAN_ID}"
            fi
            if [ "${AUTO}" -eq 1 ]; then
                bastille start "${TARGET}"
            fi
        elif [ "${CLASSIC}" -eq 1 ]; then
            if [ "$(bastille config ${TARGET} get vnet)" != "not set" ]; then
                error_exit "[ERROR]: ${TARGET} is a VNET jail."
            else
                add_interface "${TARGET}" "${INTERFACE}" "${IP}"
                if [ "${AUTO}" -eq 1 ]; then
                    bastille start "${TARGET}"
                fi
            fi
        fi
        ;;
    remove|delete)
        check_interface_added "${TARGET}" "${INTERFACE}" || error_exit "Interface not found in jail.conf: \"${INTERFACE}\"" 
        validate_netif "${INTERFACE}"
        if ! grep -q "${INTERFACE}" ${bastille_jailsdir}/${TARGET}/jail.conf; then
            error_exit "[ERROR]: Interface not found in jail.conf: \"${INTERFACE}\""
        else
            remove_interface "${TARGET}" "${INTERFACE}"
            if [ "${AUTO}" -eq 1 ]; then
                bastille start "${TARGET}"
            fi
        fi
        ;;
    *)
        error_exit "[ERROR]: Only [add|remove] are supported."
        ;;
esac
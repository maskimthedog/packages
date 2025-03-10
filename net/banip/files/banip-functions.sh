# banIP shared function library/include - ban incoming and outgoing IPs via named nftables Sets
# Copyright (c) 2018-2023 Dirk Brenken (dev@brenken.org)
# This is free software, licensed under the GNU General Public License v3.

# (s)hellcheck exceptions
# shellcheck disable=all

# set initial defaults
#
export LC_ALL=C
export PATH="/usr/sbin:/usr/bin:/sbin:/bin"

ban_basedir="/tmp"
ban_backupdir="/tmp/banIP-backup"
ban_reportdir="/tmp/banIP-report"
ban_feedfile="/etc/banip/banip.feeds"
ban_customfeedfile="/etc/banip/banip.custom.feeds"
ban_allowlist="/etc/banip/banip.allowlist"
ban_blocklist="/etc/banip/banip.blocklist"
ban_mailtemplate="/etc/banip/banip.tpl"
ban_pidfile="/var/run/banip.pid"
ban_rtfile="/var/run/banip_runtime.json"
ban_lock="/var/run/banip.lock"
ban_fetchcmd=""
ban_logreadcmd="$(command -v logread)"
ban_logcmd="$(command -v logger)"
ban_ubuscmd="$(command -v ubus)"
ban_nftcmd="$(command -v nft)"
ban_fw4cmd="$(command -v fw4)"
ban_awkcmd="$(command -v awk)"
ban_grepcmd="$(command -v grep)"
ban_sedcmd="$(command -v sed)"
ban_catcmd="$(command -v cat)"
ban_zcatcmd="$(command -v zcat)"
ban_lookupcmd="$(command -v nslookup)"
ban_mailcmd="$(command -v msmtp)"
ban_mailsender="no-reply@banIP"
ban_mailreceiver=""
ban_mailtopic="banIP notification"
ban_mailprofile="ban_notify"
ban_mailnotifcation="0"
ban_reportelements="1"
ban_nftloglevel="warn"
ban_nftpriority="-200"
ban_nftpolicy="memory"
ban_nftexpiry=""
ban_loglimit="100"
ban_logcount="1"
ban_logterm=""
ban_country=""
ban_asn=""
ban_loginput="1"
ban_logforwardwan="1"
ban_logforwardlan="0"
ban_allowurl=""
ban_allowlistonly="0"
ban_autoallowlist="1"
ban_autoallowuplink="subnet"
ban_autoblocklist="1"
ban_deduplicate="1"
ban_splitsize="0"
ban_autodetect="1"
ban_feed=""
ban_blockpolicy=""
ban_blockinput=""
ban_blockforwardwan=""
ban_blockforwardlan=""
ban_protov4="0"
ban_protov6="0"
ban_ifv4=""
ban_ifv6=""
ban_dev=""
ban_uplink=""
ban_fetchinsecure=""
ban_fetchretry="5"
ban_cores=""
ban_memory=""
ban_trigger=""
ban_triggerdelay="10"
ban_resolver=""
ban_enabled="0"
ban_debug="0"

# gather system information
#
f_system() {
	local cpu core

	if [ -z "${ban_dev}" ]; then
		ban_debug="$(uci_get banip global ban_debug)"
		ban_cores="$(uci_get banip global ban_cores)"
	fi
	ban_memory="$("${ban_awkcmd}" '/^MemAvailable/{printf "%s",int($2/1000)}' "/proc/meminfo" 2>/dev/null)"
	ban_ver="$(${ban_ubuscmd} -S call rpc-sys packagelist '{ "all": true }' 2>/dev/null | jsonfilter -ql1 -e '@.packages.banip')"
	ban_sysver="$(${ban_ubuscmd} -S call system board 2>/dev/null | jsonfilter -ql1 -e '@.model' -e '@.release.description' |
		"${ban_awkcmd}" 'BEGIN{RS="";FS="\n"}{printf "%s, %s",$1,$2}')"
	if [ -z "${ban_cores}" ]; then
		cpu="$("${ban_grepcmd}" -c '^processor' /proc/cpuinfo 2>/dev/null)"
		core="$("${ban_grepcmd}" -cm1 '^core id' /proc/cpuinfo 2>/dev/null)"
		[ "${cpu}" = "0" ] && cpu="1"
		[ "${core}" = "0" ] && core="1"
		ban_cores="$((cpu * core))"
	fi
}

# create directories
#
f_mkdir() {
	local dir="${1}"

	if [ ! -d "${dir}" ]; then
		rm -f "${dir}"
		mkdir -p "${dir}"
		f_log "debug" "f_mkdir     ::: directory: ${dir}"
	fi
}

# create files
#
f_mkfile() {
	local file="${1}"

	if [ ! -f "${file}" ]; then
		: >"${file}"
		f_log "debug" "f_mkfile    ::: file: ${file}"
	fi
}

# create temporary files and directories
#
f_tmp() {
	f_mkdir "${ban_basedir}"
	ban_tmpdir="$(mktemp -p "${ban_basedir}" -d)"
	ban_tmpfile="$(mktemp -p "${ban_tmpdir}" -tu)"

	f_log "debug" "f_tmp       ::: base_dir: ${ban_basedir:-"-"}, tmp_dir: ${ban_tmpdir:-"-"}"
}

# remove directories
#
f_rmdir() {
	local dir="${1}"

	if [ -d "${dir}" ]; then
		rm -rf "${dir}"
		f_log "debug" "f_rmdir     ::: directory: ${dir}"
	fi
}

# convert chars
#
f_char() {
	local char="${1}"

	if [ "${char}" = "1" ]; then
		printf "%s" "✔"
	elif [ "${char}" = "0" ] || [ -z "${char}" ]; then
		printf "%s" "✘"
	else
		printf "%s" "${char}"
	fi
}

# trim strings
#
f_trim() {
	local string="${1}"

	string="${string#"${string%%[![:space:]]*}"}"
	string="${string%"${string##*[![:space:]]}"}"
	printf "%s" "${string}"
}

# write log messages
#
f_log() {
	local class="${1}" log_msg="${2}"

	if [ -n "${log_msg}" ] && { [ "${class}" != "debug" ] || [ "${ban_debug}" = "1" ]; }; then
		if [ -x "${ban_logcmd}" ]; then
			"${ban_logcmd}" -p "${class}" -t "banIP-${ban_ver}[${$}]" "${log_msg}"
		else
			printf "%s %s %s\n" "${class}" "banIP-${ban_ver}[${$}]" "${log_msg}"
		fi
	fi
	if [ "${class}" = "err" ]; then
		"${ban_nftcmd}" delete table inet banIP >/dev/null 2>&1
		if [ "${ban_enabled}" = "1" ]; then
			f_genstatus "error"
			[ "${ban_mailnotification}" = "1" ] && [ -n "${ban_mailreceiver}" ] && [ -x "${ban_mailcmd}" ] && f_mail
		else
			f_genstatus "disabled"
		fi
		f_rmdir "${ban_tmpdir}"
		f_rmpid
		rm -rf "${ban_lock}"
		exit 1
	fi
}

# load config
#
f_conf() {
	unset ban_dev ban_ifv4 ban_ifv6 ban_feed ban_allowurl ban_blockinput ban_blockforwardwan ban_blockforwardlan ban_logterm ban_country ban_asn
	config_cb() {
		option_cb() {
			local option="${1}"
			local value="${2}"
			eval "${option}=\"${value}\""
		}
		list_cb() {
			local option="${1}"
			local value="${2}"
			case "${option}" in
				"ban_dev")
					eval "${option}=\"$(printf "%s" "${ban_dev}")${value} \""
					;;
				"ban_ifv4")
					eval "${option}=\"$(printf "%s" "${ban_ifv4}")${value} \""
					;;
				"ban_ifv6")
					eval "${option}=\"$(printf "%s" "${ban_ifv6}")${value} \""
					;;
				"ban_feed")
					eval "${option}=\"$(printf "%s" "${ban_feed}")${value} \""
					;;
				"ban_allowurl")
					eval "${option}=\"$(printf "%s" "${ban_allowurl}")${value} \""
					;;
				"ban_blockinput")
					eval "${option}=\"$(printf "%s" "${ban_blockinput}")${value} \""
					;;
				"ban_blockforwardwan")
					eval "${option}=\"$(printf "%s" "${ban_blockforwardwan}")${value} \""
					;;
				"ban_blockforwardlan")
					eval "${option}=\"$(printf "%s" "${ban_blockforwardlan}")${value} \""
					;;
				"ban_logterm")
					eval "${option}=\"$(printf "%s" "${ban_logterm}")${value}\\|\""
					;;
				"ban_country")
					eval "${option}=\"$(printf "%s" "${ban_country}")${value} \""
					;;
				"ban_asn")
					eval "${option}=\"$(printf "%s" "${ban_asn}")${value} \""
					;;
			esac
		}
	}
	config_load banip

	[ "${ban_action}" = "boot" ] && [ -z "${ban_trigger}" ] && sleep ${ban_triggerdelay}
}

# prepare fetch utility
#
f_fetch() {
	local item utils packages insecure

	if [ -z "${ban_fetchcmd}" ] || [ ! -x "$(command -v "${ban_fetchcmd}")" ]; then
		packages="$(${ban_ubuscmd} -S call rpc-sys packagelist '{ "all": true }' 2>/dev/null)"
		[ -z "${packages}" ] && f_log "err" "no local package repository"
		utils="aria2c curl wget uclient-fetch"
		for item in ${utils}; do
			if { [ "${item}" = "uclient-fetch" ] && printf "%s" "${packages}" | "${ban_grepcmd}" -q '"libustream-'; } ||
				{ [ "${item}" = "wget" ] && printf "%s" "${packages}" | "${ban_grepcmd}" -q '"wget-ssl'; } ||
				[ "${item}" = "curl" ] || [ "${item}" = "aria2c" ]; then
				ban_fetchcmd="$(command -v "${item}")"
				if [ -x "${ban_fetchcmd}" ]; then
					uci_set banip global ban_fetchcmd "${ban_fetchcmd##*/}"
					uci_commit "banip"
					break
				fi
			fi
		done
	else
		ban_fetchcmd="$(command -v "${ban_fetchcmd}")"
	fi
	[ ! -x "${ban_fetchcmd}" ] && f_log "err" "no download utility with SSL support"
	case "${ban_fetchcmd##*/}" in
		"aria2c")
			[ "${ban_fetchinsecure}" = "1" ] && insecure="--check-certificate=false"
			ban_fetchparm="${ban_fetchparm:-"${insecure} --timeout=20 --retry-wait=10 --max-tries=${ban_fetchretry} --max-file-not-found=${ban_fetchretry} --allow-overwrite=true --auto-file-renaming=false --log-level=warn --dir=/ -o"}"
			;;
		"curl")
			[ "${ban_fetchinsecure}" = "1" ] && insecure="--insecure"
			ban_fetchparm="${ban_fetchparm:-"${insecure} --connect-timeout 20 --retry-delay 10 --retry ${ban_fetchretry} --retry-all-errors --fail --silent --show-error --location -o"}"
			;;
		"uclient-fetch")
			[ "${ban_fetchinsecure}" = "1" ] && insecure="--no-check-certificate"
			ban_fetchparm="${ban_fetchparm:-"${insecure} --timeout=20 -O"}"
			;;
		"wget")
			[ "${ban_fetchinsecure}" = "1" ] && insecure="--no-check-certificate"
			ban_fetchparm="${ban_fetchparm:-"${insecure} --no-cache --no-cookies --timeout=20 --waitretry=10 --tries=${ban_fetchretry} --retry-connrefused --max-redirect=0 -O"}"
			;;
	esac

	f_log "debug" "f_fetch     ::: cmd: ${ban_fetchcmd:-"-"}, parm: ${ban_fetchparm:-"-"}"
}

# remove logservice
#
f_rmpid() {
	local ppid pid pids

	ppid="$("${ban_catcmd}" "${ban_pidfile}" 2>/dev/null)"
	[ -n "${ppid}" ] && pids="$(pgrep -P "${ppid}" 2>/dev/null)" || return 0
	for pid in ${pids}; do
		kill -INT "${pid}" >/dev/null 2>&1
	done
	: >"${ban_pidfile}"
}

# get nft/monitor actuals
#
f_actual() {
	local nft monitor

	if "${ban_nftcmd}" -t list set inet banIP allowlistvMAC >/dev/null 2>&1; then
		nft="$(f_char "1")"
	else
		nft="$(f_char "0")"
	fi
	if pgrep -f "logread" -P "$("${ban_catcmd}" "${ban_pidfile}" 2>/dev/null)" >/dev/null 2>&1; then
		monitor="$(f_char "1")"
	else
		monitor="$(f_char "0")"
	fi
	printf "%s" "nft: ${nft}, monitor: ${monitor}"
}

# get wan interfaces
#
f_getif() {
	local iface update="0"

	if [ "${ban_autodetect}" = "1" ]; then
		if [ -z "${ban_ifv4}" ]; then
			network_flush_cache
			network_find_wan iface
			if [ -n "${iface}" ] && "${ban_ubuscmd}" -t 10 wait_for network.interface."${iface}" >/dev/null 2>&1; then
				ban_protov4="1"
				ban_ifv4="${iface}"
				uci_set banip global ban_protov4 "1"
				uci_add_list banip global ban_ifv4 "${iface}"
				f_log "info" "add IPv4 interface '${iface}' to config"
			fi
		fi
		if [ -z "${ban_ifv6}" ]; then
			network_flush_cache
			network_find_wan6 iface
			if [ -n "${iface}" ] && "${ban_ubuscmd}" -t 10 wait_for network.interface."${iface}" >/dev/null 2>&1; then
				ban_protov6="1"
				ban_ifv6="${iface}"
				uci_set banip global ban_protov6 "1"
				uci_add_list banip global ban_ifv6 "${iface}"
				f_log "info" "add IPv6 interface '${iface}' to config"
			fi
		fi
	fi
	if [ -n "$(uci -q changes "banip")" ]; then
		update="1"
		uci_commit "banip"
	else
		ban_ifv4="${ban_ifv4%%?}"
		ban_ifv6="${ban_ifv6%%?}"
		for iface in ${ban_ifv4} ${ban_ifv6}; do
			if ! "${ban_ubuscmd}" -t 10 wait_for network.interface."${iface}" >/dev/null 2>&1; then
				f_log "err" "no wan interface '${iface}'"
			fi
		done
	fi
	[ -z "${ban_ifv4}" ] && [ -z "${ban_ifv6}" ] && f_log "err" "no wan interfaces"

	f_log "debug" "f_getif     ::: auto/update: ${ban_autodetect}/${update}, interfaces (4/6): ${ban_ifv4}/${ban_ifv6}, protocols (4/6): ${ban_protov4}/${ban_protov6}"
}

# get wan devices
#
f_getdev() {
	local dev iface update="0" cnt="0" cnt_max="30"

	if [ "${ban_autodetect}" = "1" ]; then
		while [ "${cnt}" -lt "${cnt_max}" ] && [ -z "${ban_dev}" ]; do
			network_flush_cache
			for iface in ${ban_ifv4} ${ban_ifv6}; do
				network_get_device dev "${iface}"
				if [ -n "${dev}" ]; then
					if printf "%s" "${dev}" | "${ban_grepcmd}" -qE "pppoe|6in4"; then
						dev="${iface}"
					fi
					if ! printf " %s " "${ban_dev}" | "${ban_grepcmd}" -q " ${dev} "; then
						ban_dev="${ban_dev}${dev} "
						uci_add_list banip global ban_dev "${dev}"
						f_log "info" "add device '${dev}' to config"
					fi
				fi
			done
			cnt="$((cnt + 1))"
			sleep 1
		done
	fi
	if [ -n "$(uci -q changes "banip")" ]; then
		update="1"
		uci_commit "banip"
	fi
	ban_dev="${ban_dev%%?}"
	[ -z "${ban_dev}" ] && f_log "err" "no wan devices"

	f_log "debug" "f_getdev    ::: auto/update: ${ban_autodetect}/${update}, devices: ${ban_dev}, cnt: ${cnt}"
}

# get local uplink
#
f_getuplink() {
	local uplink iface ip update="0"

	if [ "${ban_autoallowlist}" = "1" ] && [ "${ban_autoallowuplink}" != "disable" ]; then
		for iface in ${ban_ifv4} ${ban_ifv6}; do
			network_flush_cache
			if [ "${ban_autoallowuplink}" = "subnet" ]; then
				network_get_subnet uplink "${iface}"
			elif [ "${ban_autoallowuplink}" = "ip" ]; then
				network_get_ipaddr uplink "${iface}"
			fi
			if [ -n "${uplink}" ] && ! printf " %s " "${ban_uplink}" | "${ban_grepcmd}" -q " ${uplink} "; then
				ban_uplink="${ban_uplink}${uplink} "
			fi
			if [ "${ban_autoallowuplink}" = "subnet" ]; then
				network_get_subnet6 uplink "${iface}"
			elif [ "${ban_autoallowuplink}" = "ip" ]; then
				network_get_ipaddr6 uplink "${iface}"
			fi
			if [ -n "${uplink}" ] && ! printf " %s " "${ban_uplink}" | "${ban_grepcmd}" -q " ${uplink} "; then
				ban_uplink="${ban_uplink}${uplink} "
			fi
		done
		for ip in ${ban_uplink}; do
			if ! "${ban_grepcmd}" -q "${ip} " "${ban_allowlist}"; then
				if [ "${update}" = "0" ]; then
					"${ban_sedcmd}" -i '/# uplink added on /d' "${ban_allowlist}"
				fi
				printf "%-42s%s\n" "${ip}" "# uplink added on $(date "+%Y-%m-%d %H:%M:%S")" >>"${ban_allowlist}"
				f_log "info" "add uplink '${ip}' to local allowlist"
				update="1"
			fi
		done
		ban_uplink="${ban_uplink%%?}"
	elif [ "${ban_autoallowlist}" = "1" ] && [ "${ban_autoallowuplink}" = "disable" ]; then
		"${ban_sedcmd}" -i '/# uplink added on /d' "${ban_allowlist}"
		update="1"
	fi

	f_log "debug" "f_getuplink ::: auto/update: ${ban_autoallowlist}/${update}, uplink: ${ban_uplink:-"-"}"
}

# get feed information
#
f_getfeed() {
	json_init
	if [ -s "${ban_customfeedfile}" ]; then
		if ! json_load_file "${ban_customfeedfile}" >/dev/null 2>&1; then
			f_log "info" "can't load banIP custom feed file"
			if ! json_load_file "${ban_feedfile}" >/dev/null 2>&1; then
				f_log "err" "can't load banIP feed file"
			fi
		fi
	elif ! json_load_file "${ban_feedfile}" >/dev/null 2>&1; then
		f_log "err" "can't load banIP feed file"
	fi
}

# get Set elements
#
f_getelements() {
	local file="${1}"

	[ -s "${file}" ] && printf "%s" "elements={ $("${ban_catcmd}" "${file}" 2>/dev/null) };"
}

# build initial nft file with base table, chains and rules
#
f_nftinit() {
	local feed_log feed_rc file="${1}"

	{
		# nft header (tables and chains)
		#
		printf "%s\n\n" "#!/usr/sbin/nft -f"
		if "${ban_nftcmd}" -t list set inet banIP allowlistvMAC >/dev/null 2>&1; then
			printf "%s\n" "delete table inet banIP"
		fi
		printf "%s\n" "add table inet banIP"
		printf "%s\n" "add chain inet banIP wan-input { type filter hook input priority ${ban_nftpriority}; policy accept; }"
		printf "%s\n" "add chain inet banIP wan-forward { type filter hook forward priority ${ban_nftpriority}; policy accept; }"
		printf "%s\n" "add chain inet banIP lan-forward { type filter hook forward priority ${ban_nftpriority}; policy accept; }"

		# default wan-input rules
		#
		printf "%s\n" "add rule inet banIP wan-input ct state established,related counter accept"
		printf "%s\n" "add rule inet banIP wan-input iifname != { ${ban_dev// /, } } counter accept"
		printf "%s\n" "add rule inet banIP wan-input meta nfproto ipv4 udp sport 67-68 udp dport 67-68 counter accept"
		printf "%s\n" "add rule inet banIP wan-input meta nfproto ipv6 udp sport 547 udp dport 546 counter accept"
		printf "%s\n" "add rule inet banIP wan-input meta nfproto ipv4 icmp type { echo-request } limit rate 1000/second counter accept"
		printf "%s\n" "add rule inet banIP wan-input meta nfproto ipv6 icmpv6 type { echo-request } limit rate 1000/second counter accept"
		printf "%s\n" "add rule inet banIP wan-input meta nfproto ipv6 icmpv6 type { nd-neighbor-advert, nd-neighbor-solicit, nd-router-advert} limit rate 1000/second ip6 hoplimit 1 counter accept"
		printf "%s\n" "add rule inet banIP wan-input meta nfproto ipv6 icmpv6 type { nd-neighbor-advert, nd-neighbor-solicit, nd-router-advert} limit rate 1000/second ip6 hoplimit 255 counter accept"

		# default wan-forward rules
		#
		printf "%s\n" "add rule inet banIP wan-forward ct state established,related counter accept"
		printf "%s\n" "add rule inet banIP wan-forward iifname != { ${ban_dev// /, } } counter accept"

		# default lan-forward rules
		#
		printf "%s\n" "add rule inet banIP lan-forward ct state established,related counter accept"
		printf "%s\n" "add rule inet banIP lan-forward oifname != { ${ban_dev// /, } } counter accept"
	} >"${file}"

	# load initial banIP table within nft (atomic load)
	#
	feed_log="$("${ban_nftcmd}" -f "${file}" 2>&1)"
	feed_rc="${?}"

	f_log "debug" "f_nftinit   ::: devices: ${ban_dev}, priority: ${ban_nftpriority}, policy: ${ban_nftpolicy}, loglevel: ${ban_nftloglevel}, rc: ${feed_rc:-"-"}, log: ${feed_log:-"-"}"
	return ${feed_rc}
}

# handle downloads
#
f_down() {
	local log_input log_forwardwan log_forwardlan start_ts end_ts tmp_raw tmp_load tmp_file split_file ruleset_raw handle
	local cnt_set cnt_dl restore_rc feed_direction feed_rc feed_log feed="${1}" proto="${2}" feed_url="${3}" feed_rule="${4}" feed_flag="${5}"

	start_ts="$(date +%s)"
	feed="${feed}v${proto}"
	tmp_load="${ban_tmpfile}.${feed}.load"
	tmp_raw="${ban_tmpfile}.${feed}.raw"
	tmp_split="${ban_tmpfile}.${feed}.split"
	tmp_file="${ban_tmpfile}.${feed}.file"
	tmp_flush="${ban_tmpfile}.${feed}.flush"
	tmp_nft="${ban_tmpfile}.${feed}.nft"
	tmp_allow="${ban_tmpfile}.${feed%v*}"

	[ "${ban_loginput}" = "1" ] && log_input="log level ${ban_nftloglevel} prefix \"banIP/inp-wan/drp/${feed}: \""
	[ "${ban_logforwardwan}" = "1" ] && log_forwardwan="log level ${ban_nftloglevel} prefix \"banIP/fwd-wan/drp/${feed}: \""
	[ "${ban_logforwardlan}" = "1" ] && log_forwardlan="log level ${ban_nftloglevel} prefix \"banIP/fwd-lan/rej/${feed}: \""

	# set feed block direction
	#
	if [ "${ban_blockpolicy}" = "input" ]; then
		if ! printf "%s" "${ban_blockinput}" | "${ban_grepcmd}" -q "${feed%v*}" &&
			! printf "%s" "${ban_blockforwardwan}" | "${ban_grepcmd}" -q "${feed%v*}" &&
			! printf "%s" "${ban_blockforwardlan}" | "${ban_grepcmd}" -q "${feed%v*}"; then
			ban_blockinput="${ban_blockinput} ${feed%v*}"
		fi
	elif [ "${ban_blockpolicy}" = "forwardwan" ]; then
		if ! printf "%s" "${ban_blockinput}" | "${ban_grepcmd}" -q "${feed%v*}" &&
			! printf "%s" "${ban_blockforwardwan}" | "${ban_grepcmd}" -q "${feed%v*}" &&
			! printf "%s" "${ban_blockforwardlan}" | "${ban_grepcmd}" -q "${feed%v*}"; then
			ban_blockforwardwan="${ban_blockforwardwan} ${feed%v*}"
		fi
	elif [ "${ban_blockpolicy}" = "forwardlan" ]; then
		if ! printf "%s" "${ban_blockinput}" | "${ban_grepcmd}" -q "${feed%v*}" &&
			! printf "%s" "${ban_blockforwardwan}" | "${ban_grepcmd}" -q "${feed%v*}" &&
			! printf "%s" "${ban_blockforwardlan}" | "${ban_grepcmd}" -q "${feed%v*}"; then
			ban_blockforwardlan="${ban_blockforwardlan} ${feed%v*}"
		fi
	fi
	if printf "%s" "${ban_blockinput}" | "${ban_grepcmd}" -q "${feed%v*}"; then
		feed_direction="input"
	fi
	if printf "%s" "${ban_blockforwardwan}" | "${ban_grepcmd}" -q "${feed%v*}"; then
		feed_direction="${feed_direction} forwardwan"
	fi
	if printf "%s" "${ban_blockforwardlan}" | "${ban_grepcmd}" -q "${feed%v*}"; then
		feed_direction="${feed_direction} forwardlan"
	fi

	# chain/rule maintenance
	#
	if [ "${ban_action}" = "reload" ] && "${ban_nftcmd}" -t list set inet banIP "${feed}" >/dev/null 2>&1; then
		ruleset_raw="$("${ban_nftcmd}" -tj list ruleset 2>/dev/null)"
		{
			printf "%s\n" "flush set inet banIP ${feed}"
			handle="$(printf "%s\n" "${ruleset_raw}" | jsonfilter -l1 -qe "@.nftables[@.rule.table=\"banIP\"&&@.rule.chain=\"wan-input\"][@.expr[0].match.right=\"@${feed}\"].handle")"
			[ -n "${handle}" ] && printf "%s\n" "delete rule inet banIP wan-input handle ${handle}"
			handle="$(printf "%s\n" "${ruleset_raw}" | jsonfilter -l1 -qe "@.nftables[@.rule.table=\"banIP\"&&@.rule.chain=\"wan-forward\"][@.expr[0].match.right=\"@${feed}\"].handle")"
			[ -n "${handle}" ] && printf "%s\n" "delete rule inet banIP wan-forward handle ${handle}"
			handle="$(printf "%s\n" "${ruleset_raw}" | jsonfilter -l1 -qe "@.nftables[@.rule.table=\"banIP\"&&@.rule.chain=\"lan-forward\"][@.expr[0].match.right=\"@${feed}\"].handle")"
			[ -n "${handle}" ] && printf "%s\n" "delete rule inet banIP lan-forward handle ${handle}"
		} >"${tmp_flush}"
	fi

	# restore local backups during init
	#
	if { [ "${ban_action}" != "reload" ] || [ "${feed_url}" = "local" ]; } && [ "${feed%v*}" != "allowlist" ] && [ "${feed%v*}" != "blocklist" ]; then
		f_restore "${feed}" "${feed_url}" "${tmp_load}"
		restore_rc="${?}"
		feed_rc="${restore_rc}"
	fi

	# prepare local allowlist
	#
	if [ "${feed%v*}" = "allowlist" ] && [ ! -f "${tmp_allow}" ]; then
		"${ban_catcmd}" "${ban_allowlist}" 2>/dev/null >"${tmp_allow}"
		for feed_url in ${ban_allowurl}; do
			feed_log="$("${ban_fetchcmd}" ${ban_fetchparm} "${tmp_load}" "${feed_url}" 2>&1)"
			feed_rc="${?}"
			if [ "${feed_rc}" = "0" ] && [ -s "${tmp_load}" ]; then
				"${ban_catcmd}" "${tmp_load}" 2>/dev/null >>"${tmp_allow}"
			else
				f_log "info" "download for feed '${feed%v*}' failed (rc: ${feed_rc:-"-"}/log: ${feed_log})"
			fi
		done
	fi

	# handle local feeds
	#
	if [ "${feed%v*}" = "allowlist" ]; then
		{
			printf "%s\n\n" "#!/usr/sbin/nft -f"
			[ -s "${tmp_flush}" ] && "${ban_catcmd}" "${tmp_flush}"
			if [ "${proto}" = "MAC" ]; then
				"${ban_awkcmd}" '/^([0-9A-f]{2}:){5}[0-9A-f]{2}([[:space:]]|$)/{printf "%s, ",tolower($1)}' "${tmp_allow}" >"${tmp_file}"
				printf "%s\n" "add set inet banIP ${feed} { type ether_addr; policy ${ban_nftpolicy}; $(f_getelements "${tmp_file}") }"
				[ -z "${feed_direction##*forwardlan*}" ] && printf "%s\n" "add rule inet banIP lan-forward ether saddr @${feed} counter accept"
			elif [ "${proto}" = "4" ]; then
				"${ban_awkcmd}" '/^(([0-9]{1,3}\.){3}(1?[0-9][0-9]?|2[0-4][0-9]|25[0-5])(\/(1?[0-9]|2?[0-9]|3?[0-2]))?)([[:space:]]|$)/{printf "%s, ",$1}' "${tmp_allow}" >"${tmp_file}"
				printf "%s\n" "add set inet banIP ${feed} { type ipv4_addr; flags interval; auto-merge; policy ${ban_nftpolicy}; $(f_getelements "${tmp_file}") }"
				if [ -z "${feed_direction##*input*}" ]; then
					if [ "${ban_allowlistonly}" = "1" ]; then
						printf "%s\n" "add rule inet banIP wan-input ip saddr != @${feed} ${log_input} counter drop"
					else
						printf "%s\n" "add rule inet banIP wan-input ip saddr @${feed} counter accept"
					fi
				fi
				if [ -z "${feed_direction##*forwardwan*}" ]; then
					if [ "${ban_allowlistonly}" = "1" ]; then
						printf "%s\n" "add rule inet banIP wan-forward ip saddr != @${feed} ${log_forwardwan} counter drop"
					else
						printf "%s\n" "add rule inet banIP wan-forward ip saddr @${feed} counter accept"
					fi
				fi
				if [ -z "${feed_direction##*forwardlan*}" ]; then
					if [ "${ban_allowlistonly}" = "1" ]; then
						printf "%s\n" "add rule inet banIP lan-forward ip daddr != @${feed} ${log_forwardlan} counter reject with icmp type admin-prohibited"
					else
						printf "%s\n" "add rule inet banIP lan-forward ip daddr @${feed} counter accept"
					fi
				fi
			elif [ "${proto}" = "6" ]; then
				"${ban_awkcmd}" '!/^([0-9A-f]{2}:){5}[0-9A-f]{2}([[:space:]]|$)/{printf "%s\n",$1}' "${tmp_allow}" |
					"${ban_awkcmd}" '/^(([0-9A-f]{0,4}:){1,7}[0-9A-f]{0,4}:?(\/(1?[0-2][0-8]|[0-9][0-9]))?)([[:space:]]|$)/{printf "%s, ",tolower($1)}' >"${tmp_file}"
				printf "%s\n" "add set inet banIP ${feed} { type ipv6_addr; flags interval; auto-merge; policy ${ban_nftpolicy}; $(f_getelements "${tmp_file}") }"
				if [ -z "${feed_direction##*input*}" ]; then
					if [ "${ban_allowlistonly}" = "1" ]; then
						printf "%s\n" "add rule inet banIP wan-input ip6 saddr != @${feed} ${log_input} counter drop"
					else
						printf "%s\n" "add rule inet banIP wan-input ip6 saddr @${feed} counter accept"
					fi
				fi
				if [ -z "${feed_direction##*forwardwan*}" ]; then
					if [ "${ban_allowlistonly}" = "1" ]; then
						printf "%s\n" "add rule inet banIP wan-forward ip6 saddr != @${feed} ${log_forwardwan} counter drop"
					else
						printf "%s\n" "add rule inet banIP wan-forward ip6 saddr @${feed} counter accept"
					fi
				fi
				if [ -z "${feed_direction##*forwardlan*}" ]; then
					if [ "${ban_allowlistonly}" = "1" ]; then
						printf "%s\n" "add rule inet banIP lan-forward ip6 daddr != @${feed} ${log_forwardlan} counter reject with icmpv6 type admin-prohibited"
					else
						printf "%s\n" "add rule inet banIP lan-forward ip6 daddr @${feed} counter accept"
					fi
				fi
			fi
		} >"${tmp_nft}"
		feed_rc="0"
	elif [ "${feed%v*}" = "blocklist" ]; then
		{
			printf "%s\n\n" "#!/usr/sbin/nft -f"
			[ -s "${tmp_flush}" ] && "${ban_catcmd}" "${tmp_flush}"
			if [ "${proto}" = "MAC" ]; then
				"${ban_awkcmd}" '/^([0-9A-f]{2}:){5}[0-9A-f]{2}([[:space:]]|$)/{printf "%s, ",tolower($1)}' "${ban_blocklist}" >"${tmp_file}"
				printf "%s\n" "add set inet banIP ${feed} { type ether_addr; policy ${ban_nftpolicy}; $(f_getelements "${tmp_file}") }"
				[ -z "${feed_direction##*forwardlan*}" ] && printf "%s\n" "add rule inet banIP lan-forward ether saddr @${feed} ${log_forwardlan} counter reject"
			elif [ "${proto}" = "4" ]; then
				if [ "${ban_deduplicate}" = "1" ]; then
					"${ban_awkcmd}" '/^(([0-9]{1,3}\.){3}(1?[0-9][0-9]?|2[0-4][0-9]|25[0-5])(\/(1?[0-9]|2?[0-9]|3?[0-2]))?)([[:space:]]|$)/{printf "%s,\n",$1}' "${ban_blocklist}" >"${tmp_raw}"
					"${ban_awkcmd}" 'NR==FNR{member[$0];next}!($0 in member)' "${ban_tmpfile}.deduplicate" "${tmp_raw}" 2>/dev/null >"${tmp_split}"
					"${ban_awkcmd}" 'BEGIN{FS="[ ,]"}NR==FNR{member[$1];next}!($1 in member)' "${ban_tmpfile}.deduplicate" "${ban_blocklist}" 2>/dev/null >"${tmp_raw}"
					"${ban_catcmd}" "${tmp_raw}" 2>/dev/null >"${ban_blocklist}"
				else
					"${ban_awkcmd}" '/^(([0-9]{1,3}\.){3}(1?[0-9][0-9]?|2[0-4][0-9]|25[0-5])(\/(1?[0-9]|2?[0-9]|3?[0-2]))?)([[:space:]]|$)/{printf "%s,\n",$1}' "${ban_blocklist}" >"${tmp_split}"
				fi
				"${ban_awkcmd}" '{ORS=" ";print}' "${tmp_split}" 2>/dev/null >"${tmp_file}"
				printf "%s\n" "add set inet banIP ${feed} { type ipv4_addr; flags interval, timeout; auto-merge; policy ${ban_nftpolicy}; $(f_getelements "${tmp_file}") }"
				[ -z "${feed_direction##*input*}" ] && printf "%s\n" "add rule inet banIP wan-input ip saddr @${feed} ${log_input} counter drop"
				[ -z "${feed_direction##*forwardwan*}" ] && printf "%s\n" "add rule inet banIP wan-forward ip saddr @${feed} ${log_forwardwan} counter drop"
				[ -z "${feed_direction##*forwardlan*}" ] && printf "%s\n" "add rule inet banIP lan-forward ip daddr @${feed} ${log_forwardlan} counter reject with icmp type admin-prohibited"
			elif [ "${proto}" = "6" ]; then
				if [ "${ban_deduplicate}" = "1" ]; then
					"${ban_awkcmd}" '!/^([0-9A-f]{2}:){5}[0-9A-f]{2}([[:space:]]|$)/{printf "%s\n",$1}' "${ban_blocklist}" |
						"${ban_awkcmd}" '/^(([0-9A-f]{0,4}:){1,7}[0-9A-f]{0,4}:?(\/(1?[0-2][0-8]|[0-9][0-9]))?)([[:space:]]|$)/{printf "%s,\n",tolower($1)}' >"${tmp_raw}"
					"${ban_awkcmd}" 'NR==FNR{member[$0];next}!($0 in member)' "${ban_tmpfile}.deduplicate" "${tmp_raw}" 2>/dev/null >"${tmp_split}"
					"${ban_awkcmd}" 'BEGIN{FS="[ ,]"}NR==FNR{member[$1];next}!($1 in member)' "${ban_tmpfile}.deduplicate" "${ban_blocklist}" 2>/dev/null >"${tmp_raw}"
					"${ban_catcmd}" "${tmp_raw}" 2>/dev/null >"${ban_blocklist}"
				else
					"${ban_awkcmd}" '!/^([0-9A-f]{2}:){5}[0-9A-f]{2}([[:space:]]|$)/{printf "%s\n",$1}' "${ban_blocklist}" |
						"${ban_awkcmd}" '/^(([0-9A-f]{0,4}:){1,7}[0-9A-f]{0,4}:?(\/(1?[0-2][0-8]|[0-9][0-9]))?)([[:space:]]|$)/{printf "%s,\n",tolower($1)}' >"${tmp_split}"
				fi
				"${ban_awkcmd}" '{ORS=" ";print}' "${tmp_split}" 2>/dev/null >"${tmp_file}"
				printf "%s\n" "add set inet banIP ${feed} { type ipv6_addr; flags interval, timeout; auto-merge; policy ${ban_nftpolicy}; $(f_getelements "${tmp_file}") }"
				[ -z "${feed_direction##*input*}" ] && printf "%s\n" "add rule inet banIP wan-input ip6 saddr @${feed} ${log_input} counter drop"
				[ -z "${feed_direction##*forwardwan*}" ] && printf "%s\n" "add rule inet banIP wan-forward ip6 saddr @${feed} ${log_forwardwan} counter drop"
				[ -z "${feed_direction##*forwardlan*}" ] && printf "%s\n" "add rule inet banIP lan-forward ip6 daddr @${feed} ${log_forwardlan} counter reject with icmpv6 type admin-prohibited"
			fi
		} >"${tmp_nft}"
		feed_rc="0"

	# handle external feeds
	#
	elif [ "${restore_rc}" != "0" ] && [ "${feed_url}" != "local" ]; then
		# handle country downloads
		#
		if [ "${feed%v*}" = "country" ]; then
			for country in ${ban_country}; do
				feed_log="$("${ban_fetchcmd}" ${ban_fetchparm} "${tmp_raw}" "${feed_url}${country}-aggregated.zone" 2>&1)"
				feed_rc="${?}"
				[ "${feed_rc}" = "0" ] && "${ban_catcmd}" "${tmp_raw}" 2>/dev/null >>"${tmp_load}"
			done
			rm -f "${tmp_raw}"

		# handle asn downloads
		#
		elif [ "${feed%v*}" = "asn" ]; then
			for asn in ${ban_asn}; do
				feed_log="$("${ban_fetchcmd}" ${ban_fetchparm} "${tmp_raw}" "${feed_url}AS${asn}" 2>&1)"
				feed_rc="${?}"
				[ "${feed_rc}" = "0" ] && "${ban_catcmd}" "${tmp_raw}" 2>/dev/null >>"${tmp_load}"
			done
			rm -f "${tmp_raw}"

		# handle compressed downloads
		#
		elif [ -n "${feed_flag}" ]; then
			case "${feed_flag}" in
				"gz")
					feed_log="$("${ban_fetchcmd}" ${ban_fetchparm} "${tmp_raw}" "${feed_url}" 2>&1)"
					feed_rc="${?}"
					if [ "${feed_rc}" = "0" ]; then
						"${ban_zcatcmd}" "${tmp_raw}" 2>/dev/null >"${tmp_load}"
						feed_rc="${?}"
					fi
					rm -f "${tmp_raw}"
					;;
			esac

		# handle normal downloads
		#
		else
			feed_log="$("${ban_fetchcmd}" ${ban_fetchparm} "${tmp_load}" "${feed_url}" 2>&1)"
			feed_rc="${?}"
		fi
	fi
	[ "${feed_rc}" != "0" ] && f_log "info" "download for feed '${feed}' failed (rc: ${feed_rc:-"-"}/log: ${feed_log})"

	# backup/restore
	#
	if [ "${restore_rc}" != "0" ] && [ "${feed_rc}" = "0" ] && [ "${feed_url}" != "local" ] && [ ! -s "${tmp_nft}" ]; then
		f_backup "${feed}" "${tmp_load}"
		feed_rc="${?}"
	elif [ -z "${restore_rc}" ] && [ "${feed_rc}" != "0" ] && [ "${feed_url}" != "local" ] && [ ! -s "${tmp_nft}" ]; then
		f_restore "${feed}" "${feed_url}" "${tmp_load}" "${feed_rc}"
		feed_rc="${?}"
	fi

	# build nft file with Sets and rules for regular downloads
	#
	if [ "${feed_rc}" = "0" ] && [ ! -s "${tmp_nft}" ]; then
		# deduplicate Sets
		#
		if [ "${ban_deduplicate}" = "1" ] && [ "${feed_url}" != "local" ]; then
			"${ban_awkcmd}" "${feed_rule}" "${tmp_load}" 2>/dev/null >"${tmp_raw}"
			"${ban_awkcmd}" 'NR==FNR{member[$0];next}!($0 in member)' "${ban_tmpfile}.deduplicate" "${tmp_raw}" 2>/dev/null | tee -a "${ban_tmpfile}.deduplicate" >"${tmp_split}"
		else
			"${ban_awkcmd}" "${feed_rule}" "${tmp_load}" 2>/dev/null >"${tmp_split}"
		fi
		feed_rc="${?}"
		# split Sets
		#
		if [ "${feed_rc}" = "0" ]; then
			if [ -n "${ban_splitsize//[![:digit]]/}" ] && [ "${ban_splitsize//[![:digit]]/}" -gt "0" ]; then
				if ! "${ban_awkcmd}" "NR%${ban_splitsize//[![:digit]]/}==1{file=\"${tmp_file}.\"++i;}{ORS=\" \";print > file}" "${tmp_split}" 2>/dev/null; then
					rm -f "${tmp_file}".*
					f_log "info" "can't split Set '${feed}' to size '${ban_splitsize//[![:digit]]/}'"
				fi
			else
				"${ban_awkcmd}" '{ORS=" ";print}' "${tmp_split}" 2>/dev/null >"${tmp_file}.1"
			fi
			feed_rc="${?}"
		fi
		rm -f "${tmp_raw}" "${tmp_load}"
		if [ "${feed_rc}" = "0" ] && [ "${proto}" = "4" ]; then
			{
				# nft header (IPv4 Set)
				#
				printf "%s\n\n" "#!/usr/sbin/nft -f"
				[ -s "${tmp_flush}" ] && "${ban_catcmd}" "${tmp_flush}"
				printf "%s\n" "add set inet banIP ${feed} { type ipv4_addr; flags interval; auto-merge; policy ${ban_nftpolicy}; $(f_getelements "${tmp_file}.1") }"

				# input and forward rules
				#
				[ -z "${feed_direction##*input*}" ] && printf "%s\n" "add rule inet banIP wan-input ip saddr @${feed} ${log_input} counter drop"
				[ -z "${feed_direction##*forwardwan*}" ] && printf "%s\n" "add rule inet banIP wan-forward ip saddr @${feed} ${log_forwardwan} counter drop"
				[ -z "${feed_direction##*forwardlan*}" ] && printf "%s\n" "add rule inet banIP lan-forward ip daddr @${feed} ${log_forwardlan} counter reject with icmp type admin-prohibited"
			} >"${tmp_nft}"
		elif [ "${feed_rc}" = "0" ] && [ "${proto}" = "6" ]; then
			{
				# nft header (IPv6 Set)
				#
				printf "%s\n\n" "#!/usr/sbin/nft -f"
				[ -s "${tmp_flush}" ] && "${ban_catcmd}" "${tmp_flush}"
				printf "%s\n" "add set inet banIP ${feed} { type ipv6_addr; flags interval; auto-merge; policy ${ban_nftpolicy}; $(f_getelements "${tmp_file}.1") }"

				# input and forward rules
				#
				[ -z "${feed_direction##*input*}" ] && printf "%s\n" "add rule inet banIP wan-input ip6 saddr @${feed} ${log_input} counter drop"
				[ -z "${feed_direction##*forwardwan*}" ] && printf "%s\n" "add rule inet banIP wan-forward ip6 saddr @${feed} ${log_forwardwan} counter drop"
				[ -z "${feed_direction##*forwardlan*}" ] && printf "%s\n" "add rule inet banIP lan-forward ip6 daddr @${feed} ${log_forwardlan} counter reject with icmpv6 type admin-prohibited"
			} >"${tmp_nft}"
		fi
	fi

	# load generated nft file in banIP table
	#
	if [ "${feed_rc}" = "0" ]; then
		cnt_dl="$("${ban_awkcmd}" 'END{printf "%d",NR}' "${tmp_split}" 2>/dev/null)"
		if [ "${cnt_dl:-"0"}" -gt "0" ] || [ "${feed_url}" = "local" ] || [ "${feed%v*}" = "allowlist" ] || [ "${feed%v*}" = "blocklist" ]; then
			feed_log="$("${ban_nftcmd}" -f "${tmp_nft}" 2>&1)"
			feed_rc="${?}"

			# load additional split files
			#
			if [ "${feed_rc}" = "0" ]; then
				for split_file in "${tmp_file}".*; do
					[ ! -f "${split_file}" ] && break
					if [ "${split_file##*.}" = "1" ]; then
						rm -f "${split_file}"
						continue
					fi
					if ! "${ban_nftcmd}" add element inet banIP "${feed}" "{ $("${ban_catcmd}" "${split_file}") }" >/dev/null 2>&1; then
						f_log "info" "can't add split file '${split_file##*.}' to Set '${feed}'"
					fi
					rm -f "${split_file}"
				done
				if [ "${ban_debug}" = "1" ] && [ "${ban_reportelements}" = "1" ]; then
					cnt_set="$("${ban_nftcmd}" -j list set inet banIP "${feed}" 2>/dev/null | jsonfilter -qe '@.nftables[*].set.elem[*]' | wc -l 2>/dev/null)"
				fi
			fi
		else
			f_log "info" "skip empty feed '${feed}'"
		fi
	fi
	rm -f "${tmp_split}" "${tmp_nft}"
	end_ts="$(date +%s)"

	f_log "debug" "f_down      ::: name: ${feed}, cnt_dl: ${cnt_dl:-"-"}, cnt_set: ${cnt_set:-"-"}, split_size: ${ban_splitsize:-"-"}, time: $((end_ts - start_ts)), rc: ${feed_rc:-"-"}, log: ${feed_log:-"-"}"
}

# backup feeds
#
f_backup() {
	local backup_rc feed="${1}" feed_file="${2}"

	gzip -cf "${feed_file}" >"${ban_backupdir}/banIP.${feed}.gz"
	backup_rc="${?}"

	f_log "debug" "f_backup    ::: name: ${feed}, source: ${feed_file##*/}, target: banIP.${feed}.gz, rc: ${backup_rc}"
	return ${backup_rc}
}

# restore feeds
#
f_restore() {
	local tmp_feed restore_rc="1" feed="${1}" feed_url="${2}" feed_file="${3}" feed_rc="${4:-"0"}"

	[ "${feed_rc}" != "0" ] && restore_rc="${feed_rc}"
	[ "${feed_url}" = "local" ] && tmp_feed="${feed%v*}v4" || tmp_feed="${feed}"
	if [ -f "${ban_backupdir}/banIP.${tmp_feed}.gz" ]; then
		"${ban_zcatcmd}" "${ban_backupdir}/banIP.${tmp_feed}.gz" 2>/dev/null >"${feed_file}"
		restore_rc="${?}"
	fi

	f_log "debug" "f_restore   ::: name: ${feed}, source: banIP.${tmp_feed}.gz, target: ${feed_file##*/}, in_rc: ${feed_rc}, rc: ${restore_rc}"
	return ${restore_rc}
}

# remove disabled Sets
#
f_rmset() {
	local feedlist tmp_del ruleset_raw item table_sets handle del_set feed_log feed_rc

	f_getfeed
	json_get_keys feedlist
	tmp_del="${ban_tmpfile}.final.delete"
	ruleset_raw="$("${ban_nftcmd}" -tj list ruleset 2>/dev/null)"
	table_sets="$(printf "%s\n" "${ruleset_raw}" | jsonfilter -qe '@.nftables[@.set.table="banIP"].set.name')"
	{
		printf "%s\n\n" "#!/usr/sbin/nft -f"
		for item in ${table_sets}; do
			if ! printf "%s" "allowlist blocklist ${ban_feed}" | "${ban_grepcmd}" -q "${item%v*}" ||
				! printf "%s" "allowlist blocklist ${feedlist}" | "${ban_grepcmd}" -q "${item%v*}"; then
				del_set="${del_set}${item}, "
				rm -f "${ban_backupdir}/banIP.${item}.gz"
				printf "%s\n" "flush set inet banIP ${item}"
				handle="$(printf "%s\n" "${ruleset_raw}" | jsonfilter -l1 -qe "@.nftables[@.rule.table=\"banIP\"&&@.rule.chain=\"wan-input\"][@.expr[0].match.right=\"@${item}\"].handle")"
				[ -n "${handle}" ] && printf "%s\n" "delete rule inet banIP wan-input handle ${handle}"
				handle="$(printf "%s\n" "${ruleset_raw}" | jsonfilter -l1 -qe "@.nftables[@.rule.table=\"banIP\"&&@.rule.chain=\"wan-forward\"][@.expr[0].match.right=\"@${item}\"].handle")"
				[ -n "${handle}" ] && printf "%s\n" "delete rule inet banIP wan-forward handle ${handle}"
				handle="$(printf "%s\n" "${ruleset_raw}" | jsonfilter -l1 -qe "@.nftables[@.rule.table=\"banIP\"&&@.rule.chain=\"lan-forward\"][@.expr[0].match.right=\"@${item}\"].handle")"
				[ -n "${handle}" ] && printf "%s\n" "delete rule inet banIP lan-forward handle ${handle}"
				printf "%s\n\n" "delete set inet banIP ${item}"
			fi
		done
	} >"${tmp_del}"

	if [ -n "${del_set}" ]; then
		del_set="${del_set%%??}"
		feed_log="$("${ban_nftcmd}" -f "${tmp_del}" 2>&1)"
		feed_rc="${?}"
	fi
	rm -f "${tmp_del}"

	f_log "debug" "f_rmset     ::: sets: ${del_set:-"-"}, rc: ${feed_rc:-"-"}, log: ${feed_log:-"-"}"
}

# generate status information
#
f_genstatus() {
	local object duration item table_sets cnt_elements="0" custom="0" split="0" status="${1}"

	[ -z "${ban_dev}" ] && f_conf
	if [ "${status}" = "active" ]; then
		if [ -n "${ban_starttime}" ]; then
			ban_endtime="$(date "+%s")"
			duration="$(((ban_endtime - ban_starttime) / 60))m $(((ban_endtime - ban_starttime) % 60))s"
		fi
		table_sets="$("${ban_nftcmd}" -tj list ruleset 2>/dev/null | jsonfilter -qe '@.nftables[@.set.table="banIP"].set.name')"
		if [ "${ban_reportelements}" = "1" ]; then
			for item in ${table_sets}; do
				cnt_elements="$((cnt_elements + $("${ban_nftcmd}" -j list set inet banIP "${item}" 2>/dev/null | jsonfilter -qe '@.nftables[*].set.elem[*]' | wc -l 2>/dev/null)))"
			done
		fi
		runtime="action: ${ban_action:-"-"}, duration: ${duration:-"-"}, date: $(date "+%Y-%m-%d %H:%M:%S")"
	fi
	[ -s ${ban_customfeedfile} ] && custom="1"
	[ ${ban_splitsize:-"0"} -gt "0" ] && split="1"

	: >"${ban_rtfile}"
	json_init
	json_load_file "${ban_rtfile}" >/dev/null 2>&1
	json_add_string "status" "${status}"
	json_add_string "version" "${ban_ver}"
	json_add_string "element_count" "${cnt_elements}"
	json_add_array "active_feeds"
	for object in ${table_sets:-"-"}; do
		json_add_object
		json_add_string "feed" "${object}"
		json_close_object
	done
	json_close_array
	json_add_array "active_devices"
	for object in ${ban_dev:-"-"}; do
		json_add_object
		json_add_string "device" "${object}"
		json_close_object
	done
	for object in ${ban_ifv4:-"-"} ${ban_ifv6:-"-"}; do
		json_add_object
		json_add_string "interface" "${object}"
		json_close_object
	done
	json_close_array
	json_add_array "active_uplink"
	for object in ${ban_uplink:-"-"}; do
		json_add_object
		json_add_string "uplink" "${object}"
		json_close_object
	done
	json_close_array
	json_add_string "nft_info" "priority: ${ban_nftpriority}, policy: ${ban_nftpolicy}, loglevel: ${ban_nftloglevel}, expiry: ${ban_nftexpiry:-"-"}"
	json_add_string "run_info" "base: ${ban_basedir}, backup: ${ban_backupdir}, report: ${ban_reportdir}, feed/custom: ${ban_feedfile}/$(f_char ${custom})"
	json_add_string "run_flags" "auto: $(f_char ${ban_autodetect}), proto (4/6): $(f_char ${ban_protov4})/$(f_char ${ban_protov6}), log (wan-inp/wan-fwd/lan-fwd): $(f_char ${ban_loginput})/$(f_char ${ban_logforwardwan})/$(f_char ${ban_logforwardlan}), dedup: $(f_char ${ban_deduplicate}), split: $(f_char ${split}), allowed only: $(f_char ${ban_allowlistonly})"
	json_add_string "last_run" "${runtime:-"-"}"
	json_add_string "system_info" "cores: ${ban_cores}, memory: ${ban_memory}, device: ${ban_sysver}"
	json_dump >"${ban_rtfile}"
}

# get status information
#
f_getstatus() {
	local key keylist type value index_key1 index_key2 index_value1 index_value2

	[ -z "${ban_dev}" ] && f_conf
	json_load_file "${ban_rtfile}" >/dev/null 2>&1
	if json_get_keys keylist; then
		printf "%s\n" "::: banIP runtime information"
		for key in ${keylist}; do
			json_get_var value "${key}" >/dev/null 2>&1
			if [ "${key}" = "status" ]; then
				value="${value} ($(f_actual))"
			elif [ "${key}" = "active_devices" ]; then
				json_select "${key}" >/dev/null 2>&1
				index=1
				while json_get_type type "${index}" && [ "${type}" = "object" ]; do
					json_get_keys index_key1 "${index}" >/dev/null 2>&1
					json_get_keys index_key2 "$((index + 1))" >/dev/null 2>&1
					json_get_values index_value1 "${index}" >/dev/null 2>&1
					if [ "${index}" = "1" ] && [ "${index_key1// /}" = "device" ] && [ "${index_key2// /}" = "interface" ]; then
						json_get_values index_value2 "$((index + 1))" >/dev/null 2>&1
						value="${index_value1} ::: ${index_value2}"
						index="$((index + 1))"
					elif [ "${index}" = "1" ]; then
						value="${index_value1}"
					elif [ "${index}" != "1" ] && [ "${index_key1// /}" = "device" ] && [ "${index_key2// /}" = "interface" ]; then
						json_get_values index_value2 "$((index + 1))" >/dev/null 2>&1
						value="${value}, ${index_value1} ::: ${index_value2}"
						index="$((index + 1))"
					elif [ "${index}" != "1" ]; then
						value="${value}, ${index_value1}"
					fi
					index="$((index + 1))"
				done
				json_select ".."
			elif [ "${key%_*}" = "active" ]; then
				json_select "${key}" >/dev/null 2>&1
				index=1
				while json_get_type type "${index}" && [ "${type}" = "object" ]; do
					json_get_values index_value1 "${index}" >/dev/null 2>&1
					if [ "${index}" = "1" ]; then
						value="${index_value1}"
					else
						value="${value}, ${index_value1}"
					fi
					index="$((index + 1))"
				done
				json_select ".."
			fi
			printf "  + %-17s : %s\n" "${key}" "${value:-"-"}"
		done
	else
		printf "%s\n" "::: no banIP runtime information available"
	fi
}

# domain lookup
#
f_lookup() {
	local cnt list domain lookup ip elementsv4 elementsv6 start_time end_time duration cnt_domain="0" cnt_ip="0" feed="${1}"

	[ -z "${ban_dev}" ] && f_conf
	start_time="$(date "+%s")"
	if [ "${feed}" = "allowlist" ]; then
		list="$("${ban_awkcmd}" '/^([[:alnum:]_-]{1,63}\.)+[[:alpha:]]+([[:space:]]|$)/{printf "%s ",tolower($1)}' "${ban_allowlist}" 2>/dev/null)"
	elif [ "${feed}" = "blocklist" ]; then
		list="$("${ban_awkcmd}" '/^([[:alnum:]_-]{1,63}\.)+[[:alpha:]]+([[:space:]]|$)/{printf "%s ",tolower($1)}' "${ban_blocklist}" 2>/dev/null)"
	fi

	for domain in ${list}; do
		lookup="$("${ban_lookupcmd}" "${domain}" ${ban_resolver} 2>/dev/null | "${ban_awkcmd}" '/^Address[ 0-9]*: /{if(!seen[$NF]++)printf "%s ",$NF}' 2>/dev/null)"
		for ip in ${lookup}; do
			if [ "${ip%%.*}" = "0" ] || [ -z "${ip%%::*}" ]; then
				continue
			else
				if { [ "${feed}" = "allowlist" ] && ! "${ban_grepcmd}" -q "^${ip}" "${ban_allowlist}"; } ||
					{ [ "${feed}" = "blocklist" ] && ! "${ban_grepcmd}" -q "^${ip}" "${ban_blocklist}"; }; then
					if [ "${ip##*:}" = "${ip}" ]; then
						elementsv4="${elementsv4} ${ip},"
					else
						elementsv6="${elementsv6} ${ip},"
					fi
					if [ "${feed}" = "allowlist" ] && [ "${ban_autoallowlist}" = "1" ]; then
						printf "%-42s%s\n" "${ip}" "# '${domain}' added on $(date "+%Y-%m-%d %H:%M:%S")" >>"${ban_allowlist}"
					elif [ "${feed}" = "blocklist" ] && [ "${ban_autoblocklist}" = "1" ]; then
						printf "%-42s%s\n" "${ip}" "# '${domain}' added on $(date "+%Y-%m-%d %H:%M:%S")" >>"${ban_blocklist}"
					fi
					cnt_ip="$((cnt_ip + 1))"
				fi
			fi
		done
		cnt_domain="$((cnt_domain + 1))"
	done
	if [ -n "${elementsv4}" ]; then
		if ! "${ban_nftcmd}" add element inet banIP "${feed}v4" "{ ${elementsv4} }" >/dev/null 2>&1; then
			f_log "info" "can't add lookup file to Set '${feed}v4'"
		fi
	fi
	if [ -n "${elementsv6}" ]; then
		if ! "${ban_nftcmd}" add element inet banIP "${feed}v6" "{ ${elementsv6} }" >/dev/null 2>&1; then
			f_log "info" "can't add lookup file to Set '${feed}v6'"
		fi
	fi
	end_time="$(date "+%s")"
	duration="$(((end_time - start_time) / 60))m $(((end_time - start_time) % 60))s"

	f_log "debug" "f_lookup    ::: feed: ${feed}, domains: ${cnt_domain}, IPs: ${cnt_ip}, duration: ${duration}"
}

# table statistics
#
f_report() {
	local report_jsn report_txt tmp_val ruleset_raw item table_sets set_cnt set_input set_forwardwan set_forwardlan set_cntinput set_cntforwardwan set_cntforwardlan output="${1}"
	local detail set_details jsnval timestamp autoadd_allow autoadd_block sum_sets sum_setinput sum_setforwardwan sum_setforwardlan sum_setelements sum_cntinput sum_cntforwardwan sum_cntforwardlan

	[ -z "${ban_dev}" ] && f_conf
	f_mkdir "${ban_reportdir}"
	report_jsn="${ban_reportdir}/ban_report.jsn"
	report_txt="${ban_reportdir}/ban_report.txt"

	# json output preparation
	#
	ruleset_raw="$("${ban_nftcmd}" -tj list ruleset 2>/dev/null)"
	table_sets="$(printf "%s" "${ruleset_raw}" | jsonfilter -qe '@.nftables[@.set.table="banIP"].set.name')"
	sum_sets="0"
	sum_setinput="0"
	sum_setforwardwan="0"
	sum_setforwardlan="0"
	sum_setelements="0"
	sum_cntinput="0"
	sum_cntforwardwan="0"
	sum_cntforwardlan="0"
	timestamp="$(date "+%Y-%m-%d %H:%M:%S")"
	: >"${report_jsn}"
	{
		printf "%s\n" "{"
		printf "\t%s\n" '"sets":{'
		for item in ${table_sets}; do
			set_cntinput="$(printf "%s" "${ruleset_raw}" | jsonfilter -l1 -qe "@.nftables[@.rule.table=\"banIP\"&&@.rule.chain=\"wan-input\"][@.expr[0].match.right=\"@${item}\"].expr[*].counter.packets")"
			set_cntforwardwan="$(printf "%s" "${ruleset_raw}" | jsonfilter -l1 -qe "@.nftables[@.rule.table=\"banIP\"&&@.rule.chain=\"wan-forward\"][@.expr[0].match.right=\"@${item}\"].expr[*].counter.packets")"
			set_cntforwardlan="$(printf "%s" "${ruleset_raw}" | jsonfilter -l1 -qe "@.nftables[@.rule.table=\"banIP\"&&@.rule.chain=\"lan-forward\"][@.expr[0].match.right=\"@${item}\"].expr[*].counter.packets")"
			if [ "${ban_reportelements}" = "1" ]; then
				set_cnt="$("${ban_nftcmd}" -j list set inet banIP "${item}" 2>/dev/null | jsonfilter -qe '@.nftables[*].set.elem[*]' | wc -l 2>/dev/null)"
				sum_setelements="$((sum_setelements + set_cnt))"
			else
				set_cnt=""
				sum_setelements="n/a"
			fi
			if [ -n "${set_cntinput}" ]; then
				set_input="OK"
				sum_setinput="$((sum_setinput + 1))"
				sum_cntinput="$((sum_cntinput + set_cntinput))"
			else
				set_input="-"
				set_cntinput=""
			fi
			if [ -n "${set_cntforwardwan}" ]; then
				set_forwardwan="OK"
				sum_setforwardwan="$((sum_setforwardwan + 1))"
				sum_cntforwardwan="$((sum_cntforwardwan + set_cntforwardwan))"
			else
				set_forwardwan="-"
				set_cntforwardwan=""
			fi
			if [ -n "${set_cntforwardlan}" ]; then
				set_forwardlan="OK"
				sum_setforwardlan="$((sum_setforwardlan + 1))"
				sum_cntforwardlan="$((sum_cntforwardlan + set_cntforwardlan))"
			else
				set_forwardlan="-"
				set_cntforwardlan=""
			fi
			[ "${sum_sets}" -gt "0" ] && printf "%s\n" ","
			printf "\t\t%s\n" "\"${item}\":{"
			printf "\t\t\t%s\n" "\"cnt_elements\": \"${set_cnt}\","
			printf "\t\t\t%s\n" "\"cnt_input\": \"${set_cntinput}\","
			printf "\t\t\t%s\n" "\"input\": \"${set_input}\","
			printf "\t\t\t%s\n" "\"cnt_forwardwan\": \"${set_cntforwardwan}\","
			printf "\t\t\t%s\n" "\"wan_forward\": \"${set_forwardwan}\","
			printf "\t\t\t%s\n" "\"cnt_forwardlan\": \"${set_cntforwardlan}\","
			printf "\t\t\t%s\n" "\"lan_forward\": \"${set_forwardlan}\""
			printf "\t\t%s" "}"
			sum_sets="$((sum_sets + 1))"
		done
		printf "\n\t%s\n" "},"
		printf "\t%s\n" "\"timestamp\": \"${timestamp}\","
		printf "\t%s\n" "\"autoadd_allow\": \"$("${ban_grepcmd}" -c "added on ${timestamp% *}" "${ban_allowlist}")\","
		printf "\t%s\n" "\"autoadd_block\": \"$("${ban_grepcmd}" -c "added on ${timestamp% *}" "${ban_blocklist}")\","
		printf "\t%s\n" "\"sum_sets\": \"${sum_sets}\","
		printf "\t%s\n" "\"sum_setinput\": \"${sum_setinput}\","
		printf "\t%s\n" "\"sum_setforwardwan\": \"${sum_setforwardwan}\","
		printf "\t%s\n" "\"sum_setforwardlan\": \"${sum_setforwardlan}\","
		printf "\t%s\n" "\"sum_setelements\": \"${sum_setelements}\","
		printf "\t%s\n" "\"sum_cntinput\": \"${sum_cntinput}\","
		printf "\t%s\n" "\"sum_cntforwardwan\": \"${sum_cntforwardwan}\","
		printf "\t%s\n" "\"sum_cntforwardlan\": \"${sum_cntforwardlan}\""
		printf "%s\n" "}"
	} >>"${report_jsn}"

	# text output preparation
	#
	if [ "${output}" != "json" ] && [ -s "${report_jsn}" ]; then
		: >"${report_txt}"
		json_init
		if json_load_file "${report_jsn}" >/dev/null 2>&1; then
			json_get_var timestamp "timestamp" >/dev/null 2>&1
			json_get_var autoadd_allow "autoadd_allow" >/dev/null 2>&1
			json_get_var autoadd_block "autoadd_block" >/dev/null 2>&1
			json_get_var sum_sets "sum_sets" >/dev/null 2>&1
			json_get_var sum_setinput "sum_setinput" >/dev/null 2>&1
			json_get_var sum_setforwardwan "sum_setforwardwan" >/dev/null 2>&1
			json_get_var sum_setforwardlan "sum_setforwardlan" >/dev/null 2>&1
			json_get_var sum_setelements "sum_setelements" >/dev/null 2>&1
			json_get_var sum_cntinput "sum_cntinput" >/dev/null 2>&1
			json_get_var sum_cntforwardwan "sum_cntforwardwan" >/dev/null 2>&1
			json_get_var sum_cntforwardlan "sum_cntforwardlan" >/dev/null 2>&1
			{
				printf "%s\n%s\n%s\n" ":::" "::: banIP Set Statistics" ":::"
				printf "%s\n" "    Timestamp: ${timestamp}"
				printf "%s\n" "    ------------------------------"
				printf "%s\n" "    auto-added to allowlist today: ${autoadd_allow}"
				printf "%s\n\n" "    auto-added to blocklist today: ${autoadd_block}"
				json_select "sets" >/dev/null 2>&1
				json_get_keys table_sets >/dev/null 2>&1
				if [ -n "${table_sets}" ]; then
					printf "%-25s%-15s%-24s%-24s%s\n" "    Set" "| Elements" "| WAN-Input (packets)" "| WAN-Forward (packets)" "| LAN-Forward (packets)"
					printf "%s\n" "    ---------------------+--------------+-----------------------+-----------------------+------------------------"
					for item in ${table_sets}; do
						printf "    %-21s" "${item}"
						json_select "${item}"
						json_get_keys set_details
						for detail in ${set_details}; do
							json_get_var jsnval "${detail}" >/dev/null 2>&1
							case "${detail}" in
								"cnt_elements")
									printf "%-15s" "| ${jsnval}"
									;;
								"cnt_input" | "cnt_forwardwan" | "cnt_forwardlan")
									[ -n "${jsnval}" ] && tmp_val=": ${jsnval}"
									;;
								*)
									printf "%-24s" "| ${jsnval}${tmp_val}"
									tmp_val=""
									;;
							esac
						done
						printf "\n"
						json_select ".."
					done
					printf "%s\n" "    ---------------------+--------------+-----------------------+-----------------------+------------------------"
					printf "%-25s%-15s%-24s%-24s%s\n" "    ${sum_sets}" "| ${sum_setelements}" "| ${sum_setinput} (${sum_cntinput})" "| ${sum_setforwardwan} (${sum_cntforwardwan})" "| ${sum_setforwardlan} (${sum_cntforwardlan})"
				fi
			} >>"${report_txt}"
		fi
	fi

	# output channel (text|json|mail)
	#
	case "${output}" in
		"text")
			[ -s "${report_txt}" ] && "${ban_catcmd}" "${report_txt}"
			;;
		"json")
			[ -s "${report_jsn}" ] && "${ban_catcmd}" "${report_jsn}"
			;;
		"mail")
			[ -n "${ban_mailreceiver}" ] && [ -x "${ban_mailcmd}" ] && f_mail
			;;
	esac
	rm -f "${report_txt}"
}

# Set search
#
f_search() {
	local item table_sets ip proto hold cnt result_flag="/var/run/banIP.search" input="${1}"

	if [ -n "${input}" ]; then
		ip="$(printf "%s" "${input}" | "${ban_awkcmd}" 'BEGIN{RS="(([0-9]{1,3}\\.){3}[0-9]{1,3})+"}{printf "%s",RT}')"
		[ -n "${ip}" ] && proto="v4"
		if [ -z "${proto}" ]; then
			ip="$(printf "%s" "${input}" | "${ban_awkcmd}" 'BEGIN{RS="([A-Fa-f0-9]{1,4}::?){3,7}[A-Fa-f0-9]{1,4}"}{printf "%s",RT}')"
			[ -n "${ip}" ] && proto="v6"
		fi
	fi
	if [ -n "${proto}" ]; then
		table_sets="$("${ban_nftcmd}" -tj list ruleset 2>/dev/null | jsonfilter -qe "@.nftables[@.set.table=\"banIP\"&&@.set.type=\"ip${proto}_addr\"].set.name")"
	else
		printf "%s\n%s\n%s\n" ":::" "::: no valid search input" ":::"
		return
	fi
	printf "%s\n%s\n%s\n" ":::" "::: banIP Search" ":::"
	printf "    %s\n" "Looking for IP '${ip}' on $(date "+%Y-%m-%d %H:%M:%S")"
	printf "    %s\n" "---"
	cnt="1"
	for item in ${table_sets}; do
		if [ -f "${result_flag}" ]; then
			rm -f "${result_flag}"
			return
		fi
		(
			if "${ban_nftcmd}" get element inet banIP "${item}" "{ ${ip} }" >/dev/null 2>&1; then
				printf "    %s\n" "IP found in Set '${item}'"
				: >"${result_flag}"
			fi
		) &
		hold="$((cnt % ban_cores))"
		[ "${hold}" = "0" ] && wait
		cnt="$((cnt + 1))"
	done
	wait
	printf "    %s\n" "IP not found"
}

# Set survey
#
f_survey() {
	local set_elements input="${1}"

	if [ -z "${input}" ]; then
		printf "%s\n%s\n%s\n" ":::" "::: no valid survey input" ":::"
		return
	fi
	set_elements="$("${ban_nftcmd}" -j list set inet banIP "${input}" 2>/dev/null | jsonfilter -qe '@.nftables[*].set.elem[*]')"
	printf "%s\n%s\n%s\n" ":::" "::: banIP Survey" ":::"
	printf "    %s\n" "List of elements in the Set '${input}' on $(date "+%Y-%m-%d %H:%M:%S")"
	printf "    %s\n" "---"
	[ -n "${set_elements}" ] && printf "%s\n" "${set_elements}" || printf "    %s\n" "empty Set"
}

# send status mail
#
f_mail() {
	local msmtp_debug

	# load mail template
	#
	if [ -r "${ban_mailtemplate}" ]; then
		. "${ban_mailtemplate}"
	else
		f_log "info" "no mail template"
	fi
	[ -z "${mail_text}" ] && f_log "info" "no mail content"
	[ "${ban_debug}" = "1" ] && msmtp_debug="--debug"

	# send mail
	#
	ban_mailhead="From: ${ban_mailsender}\nTo: ${ban_mailreceiver}\nSubject: ${ban_mailtopic}\nReply-to: ${ban_mailsender}\nMime-Version: 1.0\nContent-Type: text/html;charset=utf-8\nContent-Disposition: inline\n\n"
	printf "%b" "${ban_mailhead}${mail_text}" | "${ban_mailcmd}" --timeout=10 ${msmtp_debug} -a "${ban_mailprofile}" "${ban_mailreceiver}" >/dev/null 2>&1
	f_log "info" "send status mail (${?})"

	f_log "debug" "f_mail      ::: notification: ${ban_mailnotification}, template: ${ban_mailtemplate}, profile: ${ban_mailprofile}, receiver: ${ban_mailreceiver}, rc: ${?}"
}

# initial sourcing
#
if [ -r "/lib/functions.sh" ] && [ -r "/lib/functions/network.sh" ] && [ -r "/usr/share/libubox/jshn.sh" ]; then
	. "/lib/functions.sh"
	. "/lib/functions/network.sh"
	. "/usr/share/libubox/jshn.sh"
else
	rm -rf "${ban_lock}"
	exit 1
fi

# check banIP availability
#
f_system
if [ "${ban_action}" != "stop" ]; then
	[ ! -d "/etc/banip" ] && f_log "err" "no banIP config directory"
	[ ! -r "/etc/config/banip" ] && f_log "err" "no banIP config"
	[ "$(uci_get banip global ban_enabled)" = "0" ] && f_log "err" "banIP is disabled"
fi

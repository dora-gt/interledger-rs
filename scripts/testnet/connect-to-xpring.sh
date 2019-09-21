#!/usr/bin/env bash

# $1 = error message
#
# error_and_exit "Error! Try again."
error_and_exit() {
    colored_output 31 1 "${1}\n" 1>&2
    exit 1
}

# 31 = Red
# 32 = Green
# 33 = Yellow
colored_output() {
    local color="${1:-31}"
    local style="${2:-1}"
    local message="${3:-}"
    printf "\e[%b%bm%b\e[m" "${color}" ";${style}" "${message}"
}

check_command() {
    local command=$1
    local install_name=$2
    local install_command=$3

    printf "Checking if you have ${command}..."
    which ${command}
    if [ $? -eq 0 ]; then
        return 0
    else
        error_and_exit "\nNot found. You have to install ${install_name} first."
    fi
}

# $1 = url
# $2 = timeout, default: -1 = don't timeout
# returns 0 if succeeds
# returns 1 if timeouts
#
# wait_to_serve "http://localhost:7770" 10
wait_to_serve() {
    local timeout=${2:--1}
    local start=$SECONDS
    while :
    do
        printf "."
        curl $1 &> /dev/null
        if [ $? -eq 0 ]; then
            break
        fi
        if [ $timeout -ge 0 ] && [ $(($SECONDS - $start)) -ge $timeout ]; then
          return 1
        fi
        sleep 1
    done
    return 0
}

usage() {
    cat << EOM
USAGE:
    $(basename $0)

    e.g.
    $(basename $0) -f -c

FLAGS:
    -c  Configure
    -s  Spin up services
    -l  Set up localtunnel
    -a  Add accounts
    -x  Stop services
    -f  Clear config and DB cache.
    -h  Show this help.

SEE:
    http://test.xpring.tech/pages/ilptestnet-credentials.html
EOM
}

prompt_with_message() {
    local message=$1
    local variable_name=$2

    read -p "$message" answer
    if [ -z "$answer" ]; then
        printf "\n"
        prompt_with_message "$message" "$variable_name"
        return $?
    fi
    eval "${variable_name}=\"${answer}\""
}

# $1 = prompt text
# $2 = default value in [yn]
# sets PROMPT_ANSWER in [yn]
#
# prompt_yn "Quit? [y/N]" n
function prompt_yn() {
    if [ $# -ne 2 ]; then
        return 1
    fi
    local text=$1
    local default=$2
    if ! [[ $default =~ [yn] ]]; then
        return 2
    fi
    read -p "$text" -n 1 answer
    if [[ "$answer" =~ ^[^yYnN]+ ]]; then
        printf "\n"
        prompt_yn "$text" "$default"
        return $?
    fi
    case "$answer" in
        [Yy]) PROMPT_ANSWER=y;;
        [Nn]) PROMPT_ANSWER=n;;
        *) PROMPT_ANSWER=$default;;
    esac
}

configure() {
    if [ -e "${CONFIG_NAME}" ]; then
        error_and_exit "${CONFIG_NAME} already exists.\nIf you want to override, try -f option."
    fi

    # input required information
    prompt_with_message "ILP address of your node: " "ilp_address"
    if [[ ! "$ilp_address" =~ ^test\. ]]; then
        error_and_exit "Specify correct ILP address. It should start with 'test.' (your option: ${ilp_address})."
    fi
    # https://github.com/interledger/rfcs/blob/master/0015-ilp-addresses/0015-ilp-addresses.md
    if [[ ! "$ilp_address" =~ ^(g|private|example|peer|self|test[1-3]?|local)([.][a-zA-Z0-9_~-]+)+$ ]]; then
        error_and_exit "Specify correct ILP address. (your option: ${ilp_address})."
    fi

    prompt_with_message "Admin auth token: " "admin_auth_token"

    # set variables
    secret_seed=$(openssl rand -hex 32) || error_and_exit "Could not generate secret_seed."

    # export config.json
    cat "${CONFIG_TEMPLATE_FILE}" | sed \
        -e "s/<ilp_address>/${ilp_address}/g" \
        -e "s/<secret_seed>/${secret_seed}/g" \
        -e "s/<admin_auth_token>/${admin_auth_token}/g" \
        > ${CONFIG_NAME} || error_and_exit "Error exporting config.json"

    colored_output 32 1 "Successfuly configured your '${CONFIG_NAME}'.\n"
}

free_ports() {
    # redis
    if lsof -Pi :6379 -sTCP:LISTEN -t >/dev/null ; then
        redis-cli -p 6379 shutdown
    fi

    # node
    if lsof -tPi :7770 >/dev/null ; then
        kill `lsof -tPi :7770`
    fi
}

stop_localtunnels() {
    if [ -e "${IOH_PID_FILE}" ]; then
        kill $(<"${IOH_PID_FILE}")
        rm "${IOH_PID_FILE}"
    fi
    if [ -e "${BTP_PID_FILE}" ]; then
        kill $(<"${BTP_PID_FILE}")
        rm "${BTP_PID_FILE}"
    fi
}

clear_redis() {
    if lsof -Pi :6379 -sTCP:LISTEN -t >/dev/null ; then
        redis-cli -p 6379 flushall
    fi
}

spin_up() {
    mkdir -p logs

    printf "Compiling code\n"
    cargo build --bin interledger
    colored_output 32 1 "done\n"

    printf "Spinning up Redis..."
    redis-server --port 6379 &> logs/redis.log &
    sleep 1
    colored_output 32 1 "done\n"

    printf "Spinning up a node"
    cargo run --bin interledger -- node config.json &> logs/node.log &
    wait_to_serve http://localhost:7770/ 10 || error_and_exit "Error spinning up a node.\nCheck log files."
    colored_output 32 1 "done\n"

    colored_output 33 21 "Logs are written in logs directory.\n"
}

set_up_localtunnel() {
    printf "Setting up localtunnels..."
    local ilp_address=$(cat ${CONFIG_NAME} | jq -r ".ilp_address") || error_and_exit "Could not load ilp_address from ${CONFIG_NAME}."
    # because localtunnel doesn't accept subdomains which contain dot
    ilp_address=${ilp_address//\./-}
    IOH_LT_SUBDOMAIN="ioh-${ilp_address}"
    BTP_LT_SUBDOMAIN="btp-${ilp_address}"
    lt -p 7770 -s "${IOH_LT_SUBDOMAIN}" &>logs/lt_ilp_over_http.log &
    printf "$!" > ${IOH_PID_FILE}
    lt -p 7768 -s "${BTP_LT_SUBDOMAIN}" &>logs/lt_btp.log &
    printf "$!" > ${BTP_PID_FILE}
    colored_output 32 1 "done\n"
    colored_output 33 21 "ILP over HTTP URL: $(get_localtunnel_url ${IOH_LT_SUBDOMAIN})\n"
    colored_output 33 21 "BTP URL: $(get_localtunnel_url ${BTP_LT_SUBDOMAIN})\n"
}

get_localtunnel_url() {
    printf "http://%s.localtunnel.me" "${1}"
}

stop_services() {
    printf "Shutting down services..."
    free_ports
    stop_localtunnels
    colored_output 32 1 "done\n"
}

inject_json_into_variable() {
    local json=$1
    local prefix=$2
    local keys=$(echo "${json}" | jq -r ".|keys|.[]")

    # WARN potentially not safe, evaling values from the server.
    for key in $keys; do
        local value=$(echo "${json}" | jq -r ".${key}")
        eval "${prefix}_${key}=${value}"
    done
}

add_accounts() {
    prompt_with_message "Asset code (xrp|eth): " "asset_code"
    if [[ ! "$asset_code" =~ (xrp|eth) ]]; then
        error_and_exit "Specify xrp or eth for the connection type (your option: ${asset_code})."
    fi

    curl http://test.xpring.tech/api/accounts/${asset_code} 2>/dev/null > credential.json || error_and_exit "Could not retrieve credential information."
    local credential=$(cat credential.json)
    inject_json_into_variable "${credential}" "credential"

    # load settings from setting file
    if [ ! -e "${CONFIG_NAME}" ]; then
        error_and_exit "Could not find config file: ${CONFIG_NAME}."
    fi
    local admin_auth_token=$(cat ${CONFIG_NAME} | jq -r ".admin_auth_token")
    local ilp_address=$(cat ${CONFIG_NAME} | jq -r ".ilp_address")

    #
    local xpring_secret=$(openssl rand -hex 32) || error_and_exit "Could not generate secret."
    local our_secret=$(openssl rand -hex 32) || error_and_exit "Could not generate secret."
    colored_output 33 21 "Auto generated Xpring incoming token: ${xpring_secret}\n"
    colored_output 33 21 "Auto generated Our incoming token: ${our_secret}\n"

    # create Xpring account json
    # TODO: Xpring ilp_address in unknown
    # TODO: do we need BTP connections?
    local xpring_account_json=$(cat "${ACCOUNT_TEMPLATE_FILE}" | sed \
        -e "/btp_endpoint/d" \
        -e "s/<user_name>/xpring/g" \
        -e "s/<ilp_address>/test.rs3.xpring.dev/g" \
        -e "s/<asset_code>/${credential_asset_code}/g" \
        -e "s/<asset_scale>/${credential_asset_scale}/g" \
        -e "s/<min_balance>/-1000/g" \
        -e "s/<http_incoming_token>/${xpring_secret}/g" \
        -e "s/<http_outgoing_token>/${credential_username}:${credential_passkey}/g" \
        -e "s~<http_endpoint>~${http_endpoint}~g")

    # insert the Xpring account into our node
    printf "Inserting the Xpring account into our node..."
    echo ${xpring_account_json} > logs/xpring_account.json
    echo ${xpring_account_json} | curl \
        -X POST \
        -H "Authorization: Bearer ${admin_auth_token}" \
        -H "Content-Type: application/json" \
        -d @- \
        http://localhost:7770/accounts >logs/xpring_account.log 2>/dev/null || error_and_exit "Could not insert the Xpring account."
    colored_output 32 1 "done\n"

    # create out account json
    local our_account_json=$(cat "${ACCOUNT_TEMPLATE_FILE}" | sed \
        -e "s/<user_name>/${credential_username}/g" \
        -e "s/<ilp_address>/${ilp_address}/g" \
        -e "s/<asset_code>/${credential_asset_code}/g" \
        -e "s/<asset_scale>/${credential_asset_scale}/g" \
        -e "s/<min_balance>/-1000/g" \
        -e "s/<http_incoming_token>/${our_secret}/g" \
        -e "s/<http_outgoing_token>/xpring:${xpring_secret}/g" \
        -e "s~<btp_endpoint>~https://${BTP_LT_SUBDOMAIN}.localtunnel.me~g" \
        -e "s~<http_endpoint>~https://${IOH_LT_SUBDOMAIN}.localtunnel.me~g")

    # insert our account into Xpring's node
    printf "Inserting our account into Xpring's node..."
    echo ${our_account_json} > logs/our_account.json
    echo ${our_account_json} | curl \
        -X POST \
        -H "Authorization: Bearer ${admin_auth_token}" \
        -H "Content-Type: application/json" \
        -d @- \
        https://rs3.xpring.dev/accounts >logs/our_account.log 2>/dev/null || error_and_exit "Could not insert our account."
    colored_output 32 1 "done\n"
}

# show usage if needed
if [ $# -eq 0 ]; then
    usage
    exit
fi

while getopts acslxfh: OPT
do
    case $OPT in
        a) CMD_ADD_ACCOUNTS=1 ;;
        c) CMD_CONFIGURE=1 ;;
        s) CMD_SPIN_UP=1 ;;
        l) CMD_SET_UP_LOCALTUNNEL=1 ;;
        x) CMD_STOP_SERVICES=1 ;;
        f) CLEAR_CACHE=1 ;;
        h)  usage ;;
        \?) usage ;;
    esac
done
shift $(($OPTIND - 1))

# set up global variables
BASE_DIR=$(cd $(dirname $0); pwd)
CONFIG_NAME="config.json"
CONFIG_TEMPLATE_NAME="config-template.json"
CONFIG_TEMPLATE_FILE="${BASE_DIR}/${CONFIG_TEMPLATE_NAME}"
ACCOUNT_TEMPLATE_NAME="account-template.json"
ACCOUNT_TEMPLATE_FILE="${BASE_DIR}/${ACCOUNT_TEMPLATE_NAME}"
IOH_PID_FILE="logs/lt_ioh.pid"
BTP_PID_FILE="logs/lt_btp.pid"
export RUST_LOG=interledger=trace

# check commands
check_command "lt" "localtunnel"
check_command "jq" "jq"
check_command "openssl" "openssl"
check_command "redis-server" "redis"
check_command "cargo" "Rust"

if [ "${CLEAR_CACHE}" = "1" ]; then
    if [ -e "${CONFIG_NAME}" ]; then
        rm "${CONFIG_NAME}"
    fi
    clear_redis
fi

if [ "${CMD_STOP_SERVICES}" = "1" ]; then
    stop_services
fi

if [ "${CMD_CONFIGURE}" = "1" ]; then
    configure
fi

if [ "${CMD_SPIN_UP}" = "1" ]; then
    spin_up
fi

if [ "${CMD_SET_UP_LOCALTUNNEL}" = "1" ]; then
    set_up_localtunnel
fi

if [ "${CMD_ADD_ACCOUNTS}" = "1" ]; then
    add_accounts
fi

#!/usr/bin/env bash

# 只允许root运行
[[ "$EUID" -ne '0' ]] && echo "Error:This script must be run as root!" && exit 1;

# 帮助
help() {
  echo -ne " Usage:\n\tbash api.sh\t-h/--help\t\thelp\n\t\t\t-f/--file string\tConfiguration file (default "warp-account.conf")\n\t\t\t-r/--register\t\tRegister an account\n\t\t\t-t/--token\t\tRegister with a team token\n\t\t\t-d/--device\t\tGet the devices information and plus traffic quota\n\t\t\t-a/--app\t\tFetch App information\n\t\t\t-b/--bind\t\tGet the account blinding devices\n\t\t\t-n/--name\t\tChange the device name\n\t\t\t-l/--license\t\tChange the license\n\t\t\t-u/--unbind\t\tUnbine a device from the account\n\t\t\t-c/--cancle\t\tCancle the account\n\t\t\t-i/--id\t\t\tShow the client id and reserved\n\n"
}

# 获取账户信息
fetch_account_information() {
  # 如不使用账户信息文件，则手动填写 Device id 和 Api token
  if [ -s "$register_path" ]; then
    # Teams 账户文件
    if grep -q 'xml version' $register_path; then
      id=$(grep 'correlation_id' $register_path | sed "s#.*>\(.*\)<.*#\1#")
      token=$(grep 'warp_token' $register_path | sed "s#.*>\(.*\)<.*#\1#")
      client_id=$(grep 'client_id' $register_path | sed "s#.*client_id&quot;:&quot;\([^&]\{4\}\)&.*#\1#")

    # 官方 api 文件
    elif grep -q 'client_id' $register_path; then
      id=$(grep -m1 '"id' "$register_path" | cut -d\" -f4)
      token=$(grep '"token' "$register_path" | cut -d\" -f4)
      client_id=$(grep 'client_id' "$register_path" | cut -d\" -f4)

    # client 文件，默认存放路径为 /var/lib/cloudflare-warp/reg.json
    elif grep -q 'registration_id' $register_path; then
      id=$(cut -d\" -f4 "$register_path")
      token=$(cut -d\" -f8 "$register_path")

    # wgcf 文件，默认存放路径为 /etc/wireguard/wgcf-account.toml
    elif grep -q 'access_token' $register_path; then
      id=$(grep 'device_id' "$register_path" | cut -d\' -f2)
      token=$(grep 'access_token' "$register_path" | cut -d\' -f2)

    # warp-go 文件，默认存放路径为 /opt/warp-go/warp.conf
    elif grep -q 'PrivateKey' $register_path; then
      id=$(awk -F' *= *' '/^Device/{print $2}' "$register_path")
      token=$(awk -F' *= *' '/^Token/{print $2}' "$register_path")

    else
      echo " There is no registered account information, please check the content. " && exit 1
    fi
  else
    read -rp " Input device id: " id
    local i=5
    until [[ "$id" =~ ^(t\.)?[A-F0-9a-f]{8}-[A-F0-9a-f]{4}-[A-F0-9a-f]{4}-[A-F0-9a-f]{4}-[A-F0-9a-f]{12}$ ]]; do
      (( i-- )) || true
      [ "$i" = 0 ] && echo " Input errors up to 5 times. The script is aborted. " && exit 1 || read -rp " Device id should be 36 or 38 characters, please re-enter (${i} times remaining): " id
    done

    read -rp " Input api token: " token
    local i=5
    until [[ "$token" =~ ^[A-F0-9a-f]{8}-[A-F0-9a-f]{4}-[A-F0-9a-f]{4}-[A-F0-9a-f]{4}-[A-F0-9a-f]{12}$ ]]; do
      (( i-- )) || true
      [ "$i" = 0 ] && echo " Input errors up to 5 times. The script is aborted. " && exit 1 || read -rp " Api token should be 36 characters, please re-enter (${i} times remaining): " token
    done
  fi
}

# 注册warp账户
register_account() {
  # 生成 wireguard 公私钥，并且补上 private key
  if [ $(type -p wg) ]; then
    private_key=$(wg genkey)
    public_key=$(wg pubkey <<< "$private_key")
  else
    wg_api=$(curl -m5 -sSL https://wg-key.forvps.gq/)
    private_key=$(awk 'NR==2 {print $2}' <<< "$wg_api")
    public_key=$(awk 'NR==1 {print $2}' <<< "$wg_api")
  fi

  register_path=${register_path:-warp-account.conf}
  [[ "$(dirname "$register_path")" != '.' ]] && mkdir -p $(dirname "$register_path")

  if [[ -n "$private_key" && -n "$public_key" ]]; then
    install_id=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 22)
    fcm_token="${install_id}:APA91b$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 134)"

    # 由于某些 IP 存在被限制注册，所以使用不停的注册来处理
    until grep -q 'account' <<< "$account"; do
      account=$(curl --request POST 'https://api.cloudflareclient.com/v0a2158/reg' \
      --silent \
      --location \
      --tlsv1.3 \
      --header 'User-Agent: okhttp/3.12.1' \
      --header 'CF-Client-Version: a-6.10-2158' \
      --header 'Content-Type: application/json' \
      --header "Cf-Access-Jwt-Assertion: ${team_token}" \
      --data '{"key":"'${public_key}'","install_id":"'${install_id}'","fcm_token":"'${fcm_token}'","tos":"'$(date +"%Y-%m-%dT%H:%M:%S.000Z")'","model":"PC","serial_number":"'${install_id}'","locale":"zh_CN"}')
    done

    client_id=$(sed 's/.*"client_id":"\([^\"]\+\)\".*/\1/' <<< "$account")
    reserved=$(echo "$client_id" | base64 -d | xxd -p | fold -w2 | while read HEX; do printf '%d ' "0x${HEX}"; done | awk '{print "["$1", "$2", "$3"]"}')
  
    account=$(python3 -m json.tool <<< "$account" 2>&1 | sed "/\"key\"/a\    \"private_key\": \"$private_key\","|  sed "/\"client_id\"/a\        \"reserved\": $reserved,")
    echo "$account" > $register_path 2>&1
  fi
  [[ ! -s $register_path || $(grep 'error' $register_path) ]] && { rm -f $register_path; exit 1; } || { cat $register_path; exit 0; }
}

# 获取设备信息
device_information() {
  [[ -z "$id" && -z "$token" ]] && fetch_account_information

  curl --request GET "https://api.cloudflareclient.com/v0a2158/reg/${id}" \
  --silent \
  --location \
  --header 'User-Agent: okhttp/3.12.1' \
  --header 'CF-Client-Version: a-6.10-2158' \
  --header 'Content-Type: application/json' \
  --header "Authorization: Bearer ${token}" \
  | python3 -m json.tool | sed "/\"warp_enabled\"/i\    \"token\": \"${token}\","
}

# 获取账户APP信息
app_information() {
  [[ -z "$id" && -z "$token" ]] && fetch_account_information

  curl --request GET "https://api.cloudflareclient.com/v0a2158/client_config" \
  --silent \
  --location \
  --header 'User-Agent: okhttp/3.12.1' \
  --header 'CF-Client-Version: a-6.10-2158' \
  --header 'Content-Type: application/json' \
  --header "Authorization: Bearer ${token}" \
  | python3 -m json.tool
}

# 查看账户绑定设备
account_binding_devices() {
  [[ -z "$id" && -z "$token" ]] && fetch_account_information

  curl --request GET "https://api.cloudflareclient.com/v0a2158/reg/${id}/account/devices" \
  --silent \
  --location \
  --header 'User-Agent: okhttp/3.12.1' \
  --header 'CF-Client-Version: a-6.10-2158' \
  --header 'Content-Type: application/json' \
  --header "Authorization: Bearer ${token}" \
  | python3 -m json.tool
}

# 添加或者更改设备名
change_device_name() {
  [[ -z "$id" && -z "$token" ]] && fetch_account_information

  curl --request PATCH "https://api.cloudflareclient.com/v0a2158/reg/${id}/account/reg/${id}" \
  --silent \
  --location \
  --header 'User-Agent: okhttp/3.12.1' \
  --header 'CF-Client-Version: a-6.10-2158' \
  --header 'Content-Type: application/json' \
  --header "Authorization: Bearer ${token}" \
  --data '{"name":"'$device_name'"}' \
  | python3 -m json.tool
}

# 更换 license
change_license() {
  [[ -z "$id" && -z "$token" ]] && fetch_account_information

  curl --request PUT "https://api.cloudflareclient.com/v0a2158/reg/${id}/account" \
  --silent \
  --location \
  --header 'User-Agent: okhttp/3.12.1' \
  --header 'CF-Client-Version: a-6.10-2158' \
  --header 'Content-Type: application/json' \
  --header "Authorization: Bearer ${token}" \
  --data '{"license": "'$license'"}' \
  | python3 -m json.tool
}

# 删除绑定设备
unbind_devide() {
  [[ -z "$id" && -z "$token" ]] && fetch_account_information

  curl --request PATCH "https://api.cloudflareclient.com/v0a2158/reg/${id}/account/reg/${id}" \
  --silent \
  --location \
  --header 'User-Agent: okhttp/3.12.1' \
  --header 'CF-Client-Version: a-6.10-2158' \
  --header 'Content-Type: application/json' \
  --header "Authorization: Bearer ${token}" \
  --data '{"active":false}' \
  | python3 -m json.tool
}

# 删除账户
cancle_account() {
  [[ -z "$id" && -z "$token" ]] && fetch_account_information

  local result=$(curl --request DELETE "https://api.cloudflareclient.com/v0a2158/reg/${id}" \
  --silent \
  --location \
  --header 'User-Agent: okhttp/3.12.1' \
  --header 'CF-Client-Version: a-6.10-2158' \
  --header 'Content-Type: application/json' \
  --header "Authorization: Bearer ${token}")

  [ -z "$result" ] && echo " Success. The account has been cancelled. " || echo " Failure. The account is not available. "
}

# reserved 解码
decode_reserved() {
  [[ -z "$id" && -z "$token" ]] && fetch_account_information
  [ -z "$client_id" ] && { fetch_client_id=$(device_information); client_id=$(expr " $fetch_client_id" | awk -F'"' '/client_id/{print $4}'); }
  reserved=$(echo "$client_id" | base64 -d | xxd -p | fold -w2 | while read HEX; do printf '%d ' "0x${HEX}"; done | awk '{print "["$1", "$2", "$3"]"}')
  echo -e "client id: $client_id\nreserved : $reserved"
}

[[ "$#" -eq '0' ]] && help && exit;

while [[ $# -ge 1 ]]; do
  case $1 in
    -f|--file)
      shift
      register_path="$1"
      shift
      ;;
    -r|--register)
      run=register_account
      shift
      ;;
    -d|--device)
      run=device_information
      shift
      ;;
    -a|--app)
      run=app_information
      shift
      ;;
    -b|--bind)
      run=account_binding_devices
      shift
      ;;
    -n|--name)
      shift
      device_name="$1"
      run=change_device_name
      shift
      ;;
    -l|--license)
      shift
      license="$1"
      run=change_license
      shift
      ;;
    -u|--unbind)
      run=unbind_devide
      shift
      ;;
    -c|--cancle)
      run=cancle_account
      shift
      ;;
    -i|--id)
      run=decode_reserved
      shift
      ;;
    -t|--token)
      shift
      team_token="$1"
      shift
      ;;
    -h|--help)
      help
      exit
      ;;
    *)
      help
      exit
      ;;
  esac
done

# 根据参数运行
$run
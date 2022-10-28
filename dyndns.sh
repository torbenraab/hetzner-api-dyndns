#!/bin/bash
# DynDNS Script for Hetzner DNS API by FarrowStrange
# Customized for Multidomain & Docker Usage by torbenraab
# v1.3

# get OS environment variables
auth_api_token=${HETZNER_AUTH_API_TOKEN:-''}

zone_name=${HETZNER_ZONE_NAME:-''}
zone_id=${HETZNER_ZONE_ID:-''}

record_name=${HETZNER_RECORD_NAME:-''}
record_ttl=${HETZNER_RECORD_TTL:-'60'}
record_type=${HETZNER_RECORD_TYPE:-'A'}

interval=${INTERVAL:-300}

display_help() {
  cat <<EOF

exec: ./dyndns.sh [ -z <Zone ID> | -Z <Zone Name> ] -r <Record ID> -n <Record Name>

parameters:
  -z  - Zone ID
  -Z  - Zone name
  -r  - Record IDs (comma separated)
  -n  - Record names (comma separated)

optional parameters:
  -t  - TTL (Default: 60)
  -T  - Record type (Default: A)
  -i  - Interval (Default: 300 | only with -l)
  -l  - Loop (Default: false)

help:
  -h  - Show Help 

requirements:
curl, dig and jq are required to run this script.

example:
  .exec: ./dyndns.sh -z 98jFjsd8dh1GHasdf7a8hJG7 -r AHD82h347fGAF1 -n dyn
  .exec: ./dyndns.sh -Z example.com -n dyn -T AAAA

EOF
  exit 1
}

logger() {
  echo $(date '+%Y-%m-%d %H:%M:%S') ${1}: ${2}
}
while getopts ":z:Z:r:rmulti:n:nmulti:t:T:h" opt; do
  case "$opt" in
    z  ) zone_id="${OPTARG}";;
    Z  ) zone_name="${OPTARG}";;
    r  ) record_id="${OPTARG}";;
    n  ) record_name="${OPTARG}";;
    t  ) record_ttl="${OPTARG}";;
    T  ) record_type="${OPTARG}";;
    i  ) interval="${OPTARG}";;
    h  ) display_help;;
    \? ) echo "Invalid option: -$OPTARG" >&2; exit 1;;
    :  ) echo "Missing option argument for -$OPTARG" >&2; exit 1;;
    *  ) echo "Unimplemented option: -$OPTARG" >&2; exit 1;;
  esac
done

# Check if tools are installed
for cmd in curl dig jq; do
  if ! command -v "${cmd}" &> /dev/null; then
    logger Error "To run the script '${cmd}' is needed, but it seems not to be installed."
    logger Error "Please check 'https://github.com/FarrowStrange/hetzner-api-dyndns#install-tools' for more informations and try again."
    exit 1
  fi
done

# Check if api token is set 
if [[ "${auth_api_token}" = "" ]]; then
  logger Error "No Auth API Token specified."
  exit 1
fi

# get all zones
zone_info=$(curl -s --location \
          "https://dns.hetzner.com/api/v1/zones" \
          --header 'Auth-API-Token: '${auth_api_token})

# check if either zone_id or zone_name is correct
if [[ "$(echo ${zone_info} | jq --raw-output '.zones[] | select(.name=="'${zone_name}'") | .id')" = "" && "$(echo ${zone_info} | jq --raw-output '.zones[] | select(.id=="'${zone_id}'") | .name')" = "" ]]; then
  logger Error "Something went wrong. Could not find Zone ID."
  logger Error "Check your inputs of either -z <Zone ID> or -Z <Zone Name>."
  logger Error "Use -h to display help."
  exit 1
fi

# get zone_id if zone_name is given and in zones
if [[ "${zone_id}" = "" ]]; then
  zone_id=$(echo ${zone_info} | jq --raw-output '.zones[] | select(.name=="'${zone_name}'") | .id')
fi

# get zone_name if zone_id is given and in zones
if [[ "${zone_name}" = "" ]]; then
  zone_name=$(echo ${zone_info} | jq --raw-output '.zones[] | select(.id=="'${zone_id}'") | .name')
fi

logger Info "Zone_ID: ${zone_id}"
logger Info "Zone_Name: ${zone_name}"

if [[ "${record_name}" = "" ]]; then
  logger Error "Mission option for record name: -n <Record Name>"
  logger Error "Use -h to display help."
  exit 1
fi

# get record id if not given as parameter
if [[ "${record_id}" = "" ]]; then
  record_zone=$(curl -s -w "\n%{http_code}" --location \
                 --request GET 'https://dns.hetzner.com/api/v1/records?zone_id='${zone_id} \
                 --header 'Auth-API-Token: '${auth_api_token})

  http_code=$(echo ${record_zone} | awk '{print $(NF)}')
  if [[ "${http_code}" != "200" ]]; then
    logger Error "HTTP Response ${http_code} - Aborting run to prevent multipe records."
    exit 1
  else
    # get array of record names saved in record_name devided by comma
    record_name_array=($(echo ${record_name} | tr "," "\n"))
    # for each record name in array get record id and push it to record_id_array
    for this_record_name in "${record_name_array[@]}"; do
      this_record_id=$(echo ${record_zone} | jq --raw-output '.records[] | select(.name=="'${this_record_name}'") | .id')
      if [[ "${this_record_id}" = "" ]]; then
        logger Error "Could not find record id for record name: ${record_name}"
      else
        record_id_array+=("${this_record_id}")
      fi
    done
  fi
# else create array and push ids saved in record_it devided by comma
else
  record_id_array=($(echo ${record_id} | tr "," "\n"))
fi 

# Log each record id with corresponding record name
for (( i=0; i<${#record_id_array[@]}; i++ )); do
  logger Info "Record_ID: ${record_id_array[$i]} - Record_Name: ${record_name_array[$i]}"
done

update_records() {
  # get current public ip address
  if [[ "${record_type}" = "AAAA" ]]; then
    logger Info "Using IPv6, because AAAA was set as record type."
    cur_pub_addr=$(dig -6 ch TXT +short whoami.cloudflare @2606:4700:4700::1111 | awk -F '"' '{print $2}')
    if [[ "${cur_pub_addr}" = "" ]]; then
      logger Error "It seems you don't have a IPv6 public address."
      exit 1
    else
      logger Info "Current public IP address: ${cur_pub_addr}"
    fi
  elif [[ "${record_type}" = "A" ]]; then
    logger Info "Using IPv4, because A was set as record type."
    cur_pub_addr=$(dig -4 ch TXT +short whoami.cloudflare @1.1.1.1 | awk -F '"' '{print $2}')
    if [[ "${cur_pub_addr}" = "" ]]; then
      logger Error "Apparently there is a problem in determining the public ip address."
      exit 1
    else
      logger Info "Current public IP address: ${cur_pub_addr}"
    fi
  else 
    logger Error "Only record type \"A\" or \"AAAA\" are support for DynDNS."
    exit 1
  fi

  # Loop through record_name_array and make the current record_id available as this_record_id and the corresponding record_name as this_record_name from record_name_array
  for ((i=0; i<${#record_name_array[@]}; i++)); do
    this_record_id=${record_id_array[$i]}
    this_record_name=${record_name_array[$i]}

      # create a new record
      if [[ "${this_record_id}" = "" ]]; then
        echo "DNS record \"${this_record_name}\" does not exists - will be created."
        curl -s -X "POST" "https://dns.hetzner.com/api/v1/records" \
            -H 'Content-Type: application/json' \
            -H 'Auth-API-Token: '${auth_api_token} \
            -d $'{
                "value": "'${cur_pub_addr}'",
                "ttl": '${record_ttl}',
                "type": "'${record_type}'",
                "name": "'${this_record_name}'",
                "zone_id": "'${zone_id}'"
              }'
      else
      # check if update is needed
        cur_dyn_addr=`curl -s "https://dns.hetzner.com/api/v1/records/${this_record_id}" -H 'Auth-API-Token: '${auth_api_token} | jq --raw-output '.record.value'`

        logger Info "Currently set IP address: ${cur_dyn_addr}"

      # update existing record
        if [[ $cur_pub_addr == $cur_dyn_addr ]]; then
          logger Info "DNS record \"${this_record_name}\" is up to date - nothing to to."
        else
          logger Info "DNS record \"${this_record_name}\" is no longer valid - updating record" 
          curl -s -X "PUT" "https://dns.hetzner.com/api/v1/records/${this_record_id}" \
              -H 'Content-Type: application/json' \
              -H 'Auth-API-Token: '${auth_api_token} \
              -d $'{
                "value": "'${cur_pub_addr}'",
                "ttl": '${record_ttl}',
                "type": "'${record_type}'",
                  "name": "'${record_name}'",
                "zone_id": "'${zone_id}'"
              }'
          if [[ $? != 0 ]]; then
            logger Error "Unable to update record: \"${this_record_name}\""
          else
            logger Info "DNS record \"${this_record_name}\" updated successfully"
          fi
        fi
      fi
  done
}

if [ -f /.dockerenv ]; then
  # Loop forever with a sleep of 300 seconds in between
  while true
  do
    update_records
    sleep ${interval}s
  done
else
  update_records
  exit 0
fi
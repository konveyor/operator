#!/bin/bash
#
# Usage: jwt.sh <key> <scope>
#
# scope - (string) space-separated scopes. (default: *:*).
#
key=$1
scope="${2:-*:*}"
header='{"typ":"JWT","alg":"HS512"}'
payload="{\"user\":\"operator\",\"scope\":\"${scope}\"}"
headerStr=$(echo -n ${header} \
  | base64 -w 0 \
  | sed s/\+/-/g \
  | sed 's/\//_/g' \
  | sed -E s/=+$//)
payloadStr=$(echo -n ${payload} \
  | base64 -w 0 \
  | sed s/\+/-/g \
  | sed 's/\//_/g' \
  | sed -E s/=+$//)
signStr=$(echo -n "${headerStr}.${payloadStr}" \
  | openssl dgst -sha512 -hmac ${key} -binary \
  | base64  -w 0 \
  | sed s/\+/-/g \
  | sed 's/\//_/g' \
  | sed -E s/=+$//)
token="${headerStr}.${payloadStr}.${signStr}"
echo "${token}"

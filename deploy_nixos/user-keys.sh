#!/usr/bin/env bash
#
# Unpacks the user-keys.json into individual keys
set -euo pipefail
shopt -s nullglob

keys_file=${1:-user-keys.json}
keys_dir=/var/user_keys

if [[ ! -f "$keys_file" ]]; then
  echo "error: $keys_file not found"
  exit 1
fi

# Fallback if jq is not installed
if ! type -p jq &>/dev/null; then
  jqOut=$(nix-build '<nixpkgs>' -A jq)
  jq() {
    "$jqOut/bin/jq" "$@"
  }
fi

# cleanup
mkdir -m 0750 -p "$keys_dir"
chown -v root:keys "$keys_dir"
chmod -v 0750 "$keys_dir"
for key in "$keys_dir"/* ; do
  rm -v "$key"
done

if [[ $(< "$keys_file") = "{}" ]]; then
  echo "no keys to unpack"
  exit
fi

echo "unpacking $keys_file"

# extract the keys from .user.json
for keyname in $(jq -S -r 'keys[]' "$keys_file"); do
  echo "unpacking: $keyname"
  user=$(jq -r ".\"$keyname\".\"user\"" < "$keys_file")
  # echo "user:$user"
  group=$(jq -r ".\"$keyname\".\"group\"" < "$keys_file")
  # echo "group:$group"
  value=$(jq -r ".\"$keyname\".\"value\"" < "$keys_file")
  # echo "value:$value"
  echo "$value" > "$keys_dir/$keyname"
  if [ $(getent group $group) ]; then
    chgrp $group "$keys_dir/$keyname"
  fi
  if id "$user" &>/dev/null; then
    chown $user "$keys_dir/$keyname"
  fi
  chmod 0440 "$keys_dir/$keyname"
done

echo "unpacking done"

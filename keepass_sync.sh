#!/usr/bin/env bash

cd /usr/local/lib/KeepassSync

MISSING_CONFIG="Invalid installation: Could not find configuration and translations files."

if [ -e "./lang/${LANG:0:2}.sh" ]; then 
  source "./lang/${LANG:0:2}.sh"
else
  echo "translation file ./local/${LANG:0:2}.sh is missing"
  source "./lang/en.sh"
fi

if [ -e "./config.sh" ]; then
  source "./config.sh"
else
  notify-send 'Keepass Sync Error' "$MISSING_CONFIG" --icon=dialog-error -a "Keepass Sync" -u critical
  exit 1
fi

nas_pwd=$(secret-tool lookup "NAS_KEEPASS" "$USER")
remote_db="/homes/$nas_user/kdbx/$kdbx_name.kdbx"
local_db="$HOME/kdbx/$kdbx_name.kdbx"
local_remote_db="$HOME/kdbx/$kdbx_name.remote.kdbx"
local_hash="$HOME/kdbx/$kdbx_name.hash"

err_msg=""

function backup {
  if [ -f "$2" ]; then
    [ -f "$HOME/kdbx/$kdbx_name.remote-10.kdbx" ] && rm "$HOME/kdbx/$kdbx_name.remote-10.kdbx" 
    for i in {9..1}; do
      [ -f "$HOME/kdbx/$kdbx_name.remote-$i.kdbx" ] && mv "$HOME/kdbx/$kdbx_name.remote-$i.kdbx" "$HOME/kdbx/$kdbx_name.remote-$(($i+1)).kdbx"
    done
    case $1 in
      "mv") mv "$2" "$HOME/kdbx/$kdbx_name.remote-1.kdbx";;
      "cp") cp "$2" "$HOME/kdbx/$kdbx_name.remote-1.kdbx";;
    esac
  fi
}

function ask_pwd {
  case $gui in
    "kde")
      pwd="$(kdialog --password "$1" --title "Keepass Sync")" && [ -n "$pwd" ] && echo "$pwd";;
    "gnome")
      pwd="$(zenity --password --title="$1")" && [ -n "$pwd" ] && echo "$pwd";;
  esac
}

function rm_local_remote {
  if [ -e "$local_remote_db" ]; then
    echo "remove local remote."
    rm "$local_remote_db"
  fi
}

function upload_local {
  echo "uploding local."
  SSH_ASKPASS_REQUIRE="" LFTP_PASSWORD="$nas_pwd" lftp --env-password -p 23 "sftp://$nas_user@greifsvpn.ddnss.de" -e "put -e $local_db -o $remote_db; bye"
  upload_failed=$?
  if [ $upload_failed -ne 0 ]; then
    echo "upload failed."
    err_msg="$UPLOAD_FAILED"
    rm_local_remote
  fi
  echo "upload successful. re-generate hash."
  cat "$local_db" | sha256sum -b > "$local_hash"
  return $upload_failed
}

function main {
  if [ -z "$nas_pwd" ]; then
    err_msg="$NO_NAS_PASSWORD"
    return 1
  fi
  echo "downloading remote."
  SSH_ASKPASS_REQUIRE="" LFTP_PASSWORD="$nas_pwd" lftp --env-password -p 23 "sftp://$nas_user@greifsvpn.ddnss.de" -e "get $remote_db -o $local_remote_db; bye"
  if [ $? -ne 0 ]; then
    err_msg="$ERR_FETCHING_REMOTE"
    echo "download of remote failed."
    rm_local_remote
    return 1
  fi

  if [ ! -f "$local_db" ]; then
    echo "database does not exist."
    cp "$local_remote_db" "$local_db"

    backup mv "$local_remote_db"

    echo "generating hash for local"
    cat "$local_db" | sha256sum -b > "$local_hash"
    return 0
  fi

  cat "$local_db" | sha256sum -c "$local_hash" --status
  local_db_changed=$?
  cat "$local_remote_db" | sha256sum -c "$local_hash" --status
  remote_db_changed=$?

  if [ $local_db_changed -eq 0 -a $remote_db_changed -eq 0 ]; then
    # nothing todo
    echo "neither local nor remote changed. nothing todo."
    rm_local_remote
    return 0
  fi
  if [ $local_db_changed -ne 0 -a $remote_db_changed -eq 0 ]; then
    # local changed, but not remote: just upload local

    upload_local || return $?

    echo "backing up local."
    backup cp "$local_db"
    rm_local_remote
    
    return 0
  fi
  if [ $local_db_changed -eq 0 -a $remote_db_changed -ne 0 ]; then
    # remote changed, but not local: just override local

    echo "overriding local"
    cp "$local_remote_db" "$local_db"

    echo "re-generate hash."
    cat "$local_db" | sha256sum -b > "$local_hash"

    echo "backing up local remote."
    backup mv "$local_remote_db"
    
    return 0
  fi

  # local and remote changed: merge and upload merged db

  echo "asking for password for merge."
  kp_pwd=$(ask_pwd "$KEEPASS_MERGE")
  if [ $? -ne 0 ]; then
    echo "merge canceled by user."
    err_msg="$MERGE_CANCELED"
    rm_local_remote
    return 1
  fi

  echo "merging databases."
  echo "$kp_pwd" | keepassxc-cli merge -s "$local_db" "$local_remote_db"
  if [ $? -ne 0 ]; then
    echo "merge failed."
    err_msg="$MERGE_FAILED"
    rm_local_remote
    return 1
  fi

  upload_local  || return $?
  
  echo "backing up local and local remote."
  backup cp "$local_db"
  backup mv "$local_remote_db"

  return 0
}

main

if [ $? -eq 0 ]; then
  if [ -n "$err_msg" ]; then
    notify-send 'Keepass Sync' "$err_msg" --icon=dialog-information -a "Keepass Sync" -t 2000
  fi
else
  notify-send 'Keepass Sync Error' "$err_msg" --icon=dialog-error -a "Keepass Sync" -u critical
fi


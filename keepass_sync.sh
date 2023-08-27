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

function backup_local_remote {
  if [ -e "$local_remote_db" ]; then
    if [ -e "$HOME/kdbx/$kdbx_name.remote-5.kdbx" ]; then
      rm "$HOME/kdbx/$kdbx_name.remote-5.kdbx"
    fi
    for i in {4..1}; do
      if [ -e "$HOME/kdbx/$kdbx_name.remote-$i.kdbx" ]; then
        mv "$HOME/kdbx/$kdbx_name.remote-$i.kdbx" "$HOME/kdbx/$kdbx_name.remote-$(($i+1)).kdbx"
      fi
    done
    mv "$local_remote_db" "$HOME/kdbx/$kdbx_name.remote-1.kdbx"
  fi
}

function check_need_backup {
  if [ -e "$HOME/kdbx/$kdbx_name.remote-1.kdbx" ]; then
    cmp --silent -- "$local_remote_db" "$HOME/kdbx/$kdbx_name.remote-1.kdbx"
    if [ $? -ne 0 ]; then
      return 0
    else
      return 1
    fi
  else
    return 0
  fi
}

function check_and_backup_local_remote {
  check_need_backup
  if [ $? -eq 0 ]; then
    echo "need backup, backing up local remote."
    backup_local_remote
  else
    echo "no need backup, removing local remote."
    rm "$local_remote_db"
  fi
}

function ask_pwd {
  case $gui in
    "kde")
      echo "$(kdialog --password "$1" --title "Keepass Sync")"
      return $?;;
    "gnome")
      echo "$(zenity --password --title="$1")"
      return $?;;
  esac
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
    if [ -e "$local_remote_db" ]; then
      echo "a local remote file exists after failed download. Deleting it."
      rm "$local_remote_db"
    fi
    return 1
  fi
  echo "comparing local remote to local."
  cmp --silent -- "$local_db" "$local_remote_db"
  if [ $? -eq 0 ]; then
    echo "remote is equal, nothing to do."
    if [ -e "$local_remote_db" ]; then
      echo "remove local remote."
      rm "$local_remote_db"
    fi
    return 0
  fi

  echo "check if local is modified since last run"
  if [ -e "$local_db" ]; then
    sha256sum -c "$local_hash"
    fast_forward=$?
  else
    echo "database does not exists yet. Creating it."
    kp_pwd=$(ask_pwd "$KEEPASS_INIT")
    if [ $? -ne 0 ]; then
      echo "initiazation canceled by user. remove local remote."
      err_msg="$INIT_CANCELED"
      rm "$local_remote_db"
      return 0
    fi
    echo "$kp_pwd" | keepassxc-cli open "$local_remote_db"
    if [ $? -ne 0 ]; then
      echo "password check failed. Maybe Wrong password? removing local remote"
      err_msg="$INIT_FAILED"
      rm "$local_remote_db"
      return 1
    fi
    echo "moving local remote over local."
    mv "$local_remote_db" "$local_db"


    echo "generating hash for local"
    sha256sum -b "$local_db" > "$local_hash"
    return 0
  fi

  if [ $fast_forward -eq 0 ]; then
    gui_msg="$KEEPASS_FAST_FORWARD"
  else
    gui_msg="$KEEPASS_MERGE"
  fi
  
  kp_pwd=$(ask_pwd "$gui_msg")
  
  if [ $? -ne 0 ]; then
    echo "merge canceled by user."
    err_msg="$MERGE_CANCELED"

    check_and_backup_local_remote
        
    return 0
  fi

  if [ $fast_forward -eq 0 ]; then
    echo "no modifications since last time."
    # database is same as last sync. So we can just fast forward it.
    
    # check password
    echo "checking password."
    echo "$kp_pwd" | keepassxc-cli open "$local_db"
    if [ $? -ne 0 ]; then
      echo "wrong password."
      err_msg="$WRONG_PASSWORD"
      check_and_backup_local_remote
      return 1
    fi

    echo "check succeeded"
    check_need_backup
    if [ $? -eq 0 ]; then
      echo "need backup, copy local remot over local then backup local remote."
      cp "$local_remote_db" "$local_db"
      backup_local_remote
    else
      echo "no need backup, move local remote over local."
      mv "$local_remote_db" "$local_db"
    fi
    
    echo "generating hash for new local"
    sha256sum -b "$local_db" > "$local_hash"
    return 0

  
  else
    # database was modified since last sync, so we merge
    echo "database modified since last time, merging local and local remote."
    
    echo "$kp_pwd" | keepassxc-cli merge -s "$local_db" "$local_remote_db"
  
    if [ $? -ne 0 ]; then
      echo "merge failed, probably wrong password, remove local hash forcing merge for next time."
      err_msg="$MERGE_FAILED"
      rm "$local_hash"
      check_and_backup_local_remote
      return 1
    fi

    echo "merge succeded, uploding local."
    SSH_ASKPASS_REQUIRE="" LFTP_PASSWORD="$nas_pwd" lftp --env-password -p 23 "sftp://$nas_user@greifsvpn.ddnss.de" -e "put -e $local_db -o $remote_db; bye"
    if [ $? -ne 0 ]; then
      echo "upload failed. do not backup, so that next sync does detect a change."
      err_msg="$UPLOAD_FAILE"
      return 1
    fi

    echo "upload succeded, generating new hash for local."
    sha256sum -b "$local_db" > "$local_hash"
    check_and_backup_local_remote

    return 0
  fi
}

main

if [ $? -eq 0 ]; then
  if [ -n "$err_msg" ]; then
    notify-send 'Keepass Sync' "$err_msg" --icon=dialog-information -a "Keepass Sync" -t 2000
  fi
else
  notify-send 'Keepass Sync Error' "$err_msg" --icon=dialog-error -a "Keepass Sync" -u critical
fi


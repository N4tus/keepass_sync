#!/usr/bin/env bash

usage=$'usage:\n\tinstall.sh install <nas_user> <gui>:(kde|gnome) [<db_name>:database]\n\tinstall.sh uninstall'

bin="/usr/local/bin"
lib="/usr/local/lib/KeepassSync"
local_share="$HOME/.local/share"
icons="$local_share/icons/hicolor"

function install {

  nas_user="$2"
  gui="$3"

  if [ "$nas_user" = "" ]; then
    echo -e "Missgin argument <nas_user>"
    echo "$usage"
    exit 1
  fi

  if [ "$gui" = "" ]; then
    echo -e "Missgin argument <gui>"
    echo "$usage"
    exit 1
  fi

  if [ "$gui" != "kde" -a $gui != "gnome" ]; then
    echo -e "Argument <gui> has to be 'kde' or 'gnome'"
    echo "$usage"
    exit 1
  fi
  
  if [ "$4" = "" ]; then
    db_name="database"
  else
    db_name="$4"
  fi
  
    
	sudo install -D -t "$lib" keepass_sync.sh
	sudo install -D -t "$lib/lang" lang/de.sh lang/en.sh

	tmp_config=$(mktemp)
	echo "kdbx_name=\"${db_name}\"" >> "$tmp_config"
	echo "nas_user=\"${nas_user}\"" >> "$tmp_config"
	echo "gui=\"${gui}\"" >> "$tmp_config"
	sudo install -D -T "$tmp_config" "$lib/config.sh"
	rm "$tmp_config"

	cp KeepassSync.desktop "$local_share/applications/KeepassSync.desktop"

	for dim in 16 24 32 48 64 96 128 192 256 512; do \
		mkdir -p "$icons/${dim}x${dim}/apps"
		inkscape -w $dim -h $dim KeepassSync.svg -o "$icons/${dim}x${dim}/apps/KeepassSync.png"
	done

  sudo ln -s "$lib/keepass_sync.sh" "$bin/keepass_sync.sh" 
}

function uninstall {
  sudo rm "$bin/keepass_sync.sh"
	sudo rm -r "$lib"
	rm "$local_share/applications/KeepassSync.desktop"
	for dim in 16 24 32 48 64 96 128 192 256 512; do
		rm "$icons/${dim}x${dim}/apps/KeepassSync.png"
	done
}

case $1 in
  "install")
    install $*;;
  "uninstall")
    uninstall;;
  *)
    echo "$usage";;
esac


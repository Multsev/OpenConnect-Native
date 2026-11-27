#!/bin/sh
# Install a reviewed copy, scoped by remote URL, so fresh clones are protected.
set -eu
umask 077
root=$(cd "$(dirname "$0")/.." && pwd)
dest="${XDG_CONFIG_HOME:-$HOME/.config}/git/openconnect-native-publication"
command -v gitleaks >/dev/null
mkdir -p "$dest/hooks"
stage=$(mktemp -d "$dest/.install.XXXXXX")
trap 'rm -rf "$stage"' EXIT
cp "$root/Scripts/check_publication.py" "$stage/check_publication.py"
for hook in pre-commit commit-msg pre-push; do
  sed 's|Scripts/check_publication.py|"$(dirname "$0")/../check_publication.py"|' "$root/.githooks/$hook" > "$stage/$hook"
  chmod 700 "$stage/$hook"
  mv "$stage/$hook" "$dest/hooks/$hook"
done
mv "$stage/check_publication.py" "$dest/check_publication.py"
git config --file "$dest/config" core.hooksPath "$dest/hooks"
git config --file "$dest/config" user.email maintainer@users.noreply.github.com
for remote in https://github.com/Multsev/OpenConnect-Native git@github.com:Multsev/OpenConnect-Native ssh://git@github.com/Multsev/OpenConnect-Native; do
  for suffix in '' '.git'; do
    key="includeIf.hasconfig:remote.*.url:$remote$suffix.path"
    if ! git config --global --get-all "$key" | grep -Fqx "$dest/config"; then
      git config --global --add "$key" "$dest/config"
    fi
  done
done

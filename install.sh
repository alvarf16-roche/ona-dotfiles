#!/usr/bin/env bash
# Ona dotfiles entrypoint. Ona clones this repo to ~/dotfiles and runs this
# script when an environment starts.
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${HOME}/.dotfiles-install.log"
exec > >(tee -a "$LOG_FILE") 2>&1

export USER="${USER:-$(id -un)}"
export HOME="${HOME:-$(getent passwd "$USER" | cut -d: -f6)}"

log() { echo "[dotfiles] $*"; }

as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    log "need root for: $*, but sudo is unavailable"
    return 1
  fi
}

source_nix() {
  local f
  for f in \
    "$HOME/.nix-profile/etc/profile.d/nix.sh" \
    /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh; do
    if [ -e "$f" ]; then
      set +u
      # shellcheck disable=SC1090
      . "$f"
      set -u
      return 0
    fi
  done
  return 1
}

install_nix() {
  if command -v nix >/dev/null 2>&1 || source_nix; then
    log "nix already installed: $(nix --version)"
    return
  fi

  # Single-user install: works in containers without systemd/a nix daemon.
  log "installing nix (single-user)"
  if [ ! -d /nix ]; then
    as_root mkdir -m 0755 /nix
    as_root chown "$USER" /nix
  fi
  curl --proto '=https' --tlsv1.2 -sSfL https://nixos.org/nix/install | sh -s -- --no-daemon
  source_nix
}

# Runs before install_nix so the installer's own nix invocations see it.
configure_nix() {
  mkdir -p "$HOME/.config/nix"
  local conf="$HOME/.config/nix/nix.conf"
  # As root, nix defaults to building as members of the `nixbld` group, which
  # only the multi-user installer creates. Build as the calling user instead.
  if [ "$(id -u)" -eq 0 ] && ! grep -qs '^build-users-group' "$conf"; then
    echo 'build-users-group =' >>"$conf"
  fi
  if ! grep -qs '^experimental-features' "$conf"; then
    echo 'experimental-features = nix-command flakes' >>"$conf"
  fi
  # Binary caches for prebuilt home-manager/nixvim dependencies, on top of
  # cache.nixos.org.
  if ! grep -qs '^extra-substituters' "$conf"; then
    cat >>"$conf" <<'EOF'
extra-substituters = https://nix-community.cachix.org
extra-trusted-public-keys = nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs=
EOF
  fi
}

# Public `github:` inputs still fail with HTTP 401 if nix sends a rejected
# token. Prefer the OSS account over an inherited enterprise/expired token,
# and check access to a required public repository before passing it to nix.
# Tokens are only used for this run; do not persist them or change gh's context.
configure_github_token() {
  if [ -z "${GITHUB_TOKEN_OSS:-}" ] && [ -z "${GITHUB_TOKEN:-}" ]; then
    log "GitHub tokens not set; using nix's existing authentication settings"
    return
  fi

  local token_var token status github_token=""
  for token_var in GITHUB_TOKEN_OSS GITHUB_TOKEN; do
    token="${!token_var:-}"
    [ -n "$token" ] || continue

    # Read the header from stdin so the token is not exposed in curl's argv.
    if ! status="$(printf 'Authorization: Bearer %s\n' "$token" | \
      curl --proto '=https' --tlsv1.2 --silent --show-error --max-time 15 \
        --header @- --output /dev/null --write-out '%{http_code}' \
        https://api.github.com/repos/javier-varez/nixvim-cfg)"; then
      log "could not check $token_var; skipping it"
      continue
    fi
    if [ "$status" = 200 ]; then
      log "using $token_var for nix fetches"
      github_token="$token"
      break
    fi
    log "$token_var rejected for public GitHub access (HTTP $status); ignoring it"
  done

  if [ -z "$github_token" ]; then
    log "no usable GitHub token; fetching public inputs without authentication (API rate limits may apply)"
  fi

  # Preserve credentials for other hosts, but replace GitHub credentials,
  # including path-specific ones that would override the selected token.
  local settings entry
  local -a existing_tokens=() access_tokens=()
  settings="$(nix config show access-tokens)"
  read -r -a existing_tokens <<<"$settings"
  [ -z "$github_token" ] || access_tokens+=("github.com=$github_token")
  for entry in "${existing_tokens[@]}"; do
    case "$entry" in
      github.com=*|github.com/*) ;;
      *) access_tokens+=("$entry") ;;
    esac
  done
  # Append, rather than prepend, so inherited NIX_CONFIG cannot override this.
  export NIX_CONFIG="${NIX_CONFIG:+$NIX_CONFIG
}access-tokens = ${access_tokens[*]}"
}

apply_home_manager() {
  log "applying home-manager configuration"
  # -b: back up any pre-existing files home-manager wants to manage.
  nix run "${DOTFILES_DIR}#home-manager" -- \
    switch --flake "${DOTFILES_DIR}#default" --impure -b hm-backup
}

set_default_shell() {
  local fish_path="$HOME/.nix-profile/bin/fish"
  if [ ! -x "$fish_path" ]; then
    log "fish not found at $fish_path, skipping default shell setup"
    return
  fi

  # Keep bash as the login shell: the Ona SSH gateway runs bash syntax
  # (`exec -l $SHELL -i`) through it, which fish can't parse. Undo any
  # earlier chsh to fish.
  if [ "$(getent passwd "$USER" | cut -d: -f7)" = "$fish_path" ] \
    && command -v chsh >/dev/null 2>&1; then
    as_root chsh -s /bin/bash "$USER" || log "chsh failed"
  fi

  # Switch interactive bash and zsh sessions to fish.
  local rc marker="# >>> dotfiles: exec fish >>>"
  for rc in "$HOME/.bashrc" "${ZDOTDIR:-$HOME}/.zshrc"; do
    if ! grep -qsF "$marker" "$rc"; then
      cat >>"$rc" <<EOF

$marker
if [[ \$- == *i* ]] && [ -t 0 ] && [ -z "\${VSCODE_RESOLVING_ENVIRONMENT:-}" ] \\
  && [ -x "$fish_path" ] && [ "\$(basename "\$(ps -o comm= -p \$PPID 2>/dev/null)")" != fish ]; then
  exec "$fish_path"
fi
# <<< dotfiles: exec fish <<<
EOF
    fi
  done
}

configure_nix
install_nix
configure_github_token
apply_home_manager
set_default_shell
log "done"

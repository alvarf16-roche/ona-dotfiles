# ona-dotfiles

Dotfiles for [Ona environments](https://ona.com/docs/ona/configuration/dotfiles/overview).
Ona clones this repo to `~/dotfiles` and runs `install.sh`, which:

1. Installs Nix (single-user, no daemon) if it isn't present, with flakes enabled and the
   `nix-community` cachix cache added as a substituter.
2. Applies the home-manager configuration in `home.nix`:
   - [nixvim-cfg](https://github.com/javier-varez/nixvim-cfg) (default package)
   - fish + starship prompt, `gits` → `git status`
   - fd, ripgrep, gitui, tmux, jujutsu, GitHub CLI (`gh`), and Node.js
   - pi-coding-agent, installed from npm's latest release on each Home Manager activation
   - `claude` and `pi` aliases that run through `ona environment keep-alive --`, keeping the
     environment alive while they run
   - rustup, with the stable Rust toolchain (`cargo`, `rustc`, `clippy`, `rustfmt`) installed as
     the default on activation unless a default toolchain is already configured
   - `ghctx`, a fish function to switch between GitHub accounts (see below)
3. Starts fish from interactive bash and zsh sessions (`exec fish` in `~/.bashrc` and
   `${ZDOTDIR:-$HOME}/.zshrc`). The login shell stays bash because the Ona SSH gateway
   runs bash syntax through it.

Logs are written to `~/.dotfiles-install.log`.

## GitHub contexts

Provide one token per account as `GITHUB_TOKEN_OSS` and `GITHUB_TOKEN_ENTERPRISE`, then:

```sh
ghctx             # print the active context: oss, enterprise, none, or unknown
ghctx oss         # set GITHUB_TOKEN from GITHUB_TOKEN_OSS
ghctx enterprise  # set GITHUB_TOKEN from GITHUB_TOKEN_ENTERPRISE
```

Interactive fish shells start in a context: an inherited `GITHUB_TOKEN` that matches one is
kept, otherwise `oss` is used, falling back to `enterprise` if `GITHUB_TOKEN_OSS` is unset.
A switch only affects the current shell; other sessions keep their own `GITHUB_TOKEN`.
`GH_TOKEN`, if set, takes precedence over `GITHUB_TOKEN` in `gh`.

## GitHub authentication during installation

The installer prefers `GITHUB_TOKEN_OSS`, then tries `GITHUB_TOKEN`. It checks each token's
access to the public `nixvim-cfg` repository before forwarding it to Nix. An expired token
or a token for a different GitHub host can otherwise make even public downloads fail with
HTTP 401; this is an authentication failure, not an API rate limit or binary-cache issue.

If neither token works (or the check fails), installation continues with unauthenticated
public GitHub fetches, which may be rate-limited on shared IPs. When either variable is
provided, the installer replaces Nix's GitHub credentials for this run while preserving
credentials for other hosts. With neither variable set, existing Nix authentication
settings are left alone. Tokens are not written to disk, and the shell's GitHub context
is not changed.

## Tests

Run the installer regression tests without installing packages or contacting GitHub:

```sh
python3 -m unittest discover -s tests -v
```

## Updating

```sh
nix flake update          # bump inputs, commit flake.lock
home-manager switch --flake ~/dotfiles#default --impure
```

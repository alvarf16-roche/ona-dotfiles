{ config, lib, pkgs, nixvim, ... }:
{
  home.stateVersion = "26.05";

  # Not running on NixOS: wire up XDG_DATA_DIRS, locales, etc.
  targets.genericLinux.enable = true;

  programs.home-manager.enable = true;

  home.packages = [
    nixvim
    pkgs.fd
    pkgs.ripgrep
    pkgs.gitui
    pkgs.tmux
    pkgs.nodejs
    pkgs.jujutsu
    pkgs.gh
    # Provides cargo, rustc, etc. as proxies to rustup-managed toolchains.
    pkgs.rustup
  ];

  # Install from npm's latest dist-tag rather than the version pinned in nixpkgs.
  home.activation.installPiCodingAgent = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    PATH="${pkgs.nodejs}/bin:$PATH" npm install --global --prefix "$HOME/.local" --no-audit --no-fund @earendil-works/pi-coding-agent@latest
  '';

  # Install the stable toolchain unless a default one is already configured.
  home.activation.installRustToolchain = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    if ! ${pkgs.rustup}/bin/rustup default >/dev/null 2>&1; then
      ${pkgs.rustup}/bin/rustup default stable
    fi
  '';

  home.sessionPath = [
    "${config.home.homeDirectory}/.local/bin"
    # `cargo install` target.
    "${config.home.homeDirectory}/.cargo/bin"
  ];

  home.sessionVariables = {
    EDITOR = "nvim";
    VISUAL = "nvim";
  };

  home.shellAliases = {
    claude = "ona environment keep-alive -- claude";
    pi = "ona environment keep-alive -- pi";
    gits = "git status";
    gitl = "git log";
    vi = "nvim";
    vim = "nvim";
  };

  programs.fish = {
    enable = true;
    interactiveShellInit = ''
      set -g fish_greeting

      # Start with a GitHub context: keep an inherited one, otherwise prefer
      # oss and fall back to enterprise.
      if not ghctx >/dev/null 2>&1
        for ctx in oss enterprise
          ghctx $ctx >/dev/null 2>&1; and break
        end
      end
    '';

    # A function rather than a script so it can set GITHUB_TOKEN in the
    # calling shell.
    functions.ghctx = {
      description = "Show or switch the active GitHub context (oss/enterprise)";
      body = ''
        set -l contexts oss enterprise

        if test (count $argv) -gt 1
            echo "Usage: ghctx [oss|enterprise]" >&2
            return 2
        end

        if test (count $argv) -eq 0
            if test -z "$GITHUB_TOKEN"
                echo none
                echo "ghctx: GITHUB_TOKEN is not set" >&2
                return 1
            end
            for ctx in $contexts
                set -l var GITHUB_TOKEN_(string upper $ctx)
                if test -n "$$var"; and test "$$var" = "$GITHUB_TOKEN"
                    echo $ctx
                    return 0
                end
            end
            echo unknown
            echo "ghctx: GITHUB_TOKEN matches none of GITHUB_TOKEN_{OSS,ENTERPRISE}" >&2
            return 1
        end

        switch $argv[1]
            case -h --help
                echo "Usage: ghctx [oss|enterprise]"
                echo
                echo "Without arguments, print the active GitHub context."
                echo "With a context, set GITHUB_TOKEN in the current shell from"
                echo "GITHUB_TOKEN_OSS or GITHUB_TOKEN_ENTERPRISE."
            case $contexts
                set -l var GITHUB_TOKEN_(string upper $argv[1])
                if test -z "$$var"
                    echo "ghctx: $var is not set" >&2
                    return 1
                end
                set -gx GITHUB_TOKEN $$var
                echo "GitHub context: $argv[1]"
                if set -q GH_TOKEN
                    echo "ghctx: warning: GH_TOKEN is set and takes precedence over GITHUB_TOKEN in gh" >&2
                end
            case '*'
                echo "ghctx: unknown context '$argv[1]' (expected oss or enterprise)" >&2
                return 2
        end
      '';
    };

    completions.ghctx = ''
      complete -c ghctx -f
      complete -c ghctx -s h -l help -d "Show help"
      complete -c ghctx -n "not __fish_seen_subcommand_from oss enterprise" -a oss -d "Use GITHUB_TOKEN_OSS"
      complete -c ghctx -n "not __fish_seen_subcommand_from oss enterprise" -a enterprise -d "Use GITHUB_TOKEN_ENTERPRISE"
    '';
  };

  programs.starship = {
    enable = true;
    enableFishIntegration = true;
  };
}

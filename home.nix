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
    pkgs.jj
  ];

  # Install from npm's latest dist-tag rather than the version pinned in nixpkgs.
  home.activation.installPiCodingAgent = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    PATH="${pkgs.nodejs}/bin:$PATH" npm install --global --prefix "$HOME/.local" --no-audit --no-fund @earendil-works/pi-coding-agent@latest
  '';

  home.sessionPath = [ "${config.home.homeDirectory}/.local/bin" ];

  home.sessionVariables = {
    EDITOR = "nvim";
    VISUAL = "nvim";
  };

  home.shellAliases = {
    gits = "git status";
    gitl = "git log";
    vi = "nvim";
    vim = "nvim";
  };

  programs.fish = {
    enable = true;
    interactiveShellInit = ''
      set -g fish_greeting

      if status is-interactive; and isatty stdin; and not set -q TMUX; and not set -q VSCODE_RESOLVING_ENVIRONMENT
        exec tmux new-session -A -s main
      end
    '';
  };

  programs.starship = {
    enable = true;
    enableFishIntegration = true;
  };
}

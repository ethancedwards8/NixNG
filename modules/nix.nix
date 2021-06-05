/*
 * NixNG
 * Copyright (c) 2021  GPL Magic_RB <magic_rb@redalder.org>   
 *  
 *  This file is free software: you may copy, redistribute and/or modify it  
 *  under the terms of the GNU General Public License as published by the  
 *  Free Software Foundation, either version 3 of the License, or (at your  
 *  option) any later version.  
 *  
 *  This file is distributed in the hope that it will be useful, but  
 *  WITHOUT ANY WARRANTY; without even the implied warranty of  
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU  
 *  General Public License for more details.  
 *  
 *  You should have received a copy of the GNU General Public License  
 *  along with this program.  If not, see <http://www.gnu.org/licenses/>.  
 */

{ pkgs, lib, config, nglib, ... }:
with lib;
let
  cfg = config.nix;

  nix = cfg.package.out;

  nixVersion = getVersion nix;

  isNix23 = versionAtLeast nixVersion "2.3pre";

  parser =
    let
      valToString = v:
        if isString v then
          "${v}"
        else if isInt v then
          "${toString v}"
        else if isBool v then
          if v then
            "true"
          else
            "false"
        else if isList v then
          concatMapStringsSep " " (x: valToString x) v
        else
          abort "Invalid config, module system should have caught this!";
    in
      config:
      concatStringsSep "\n" (mapAttrsToList (n: v:
        "${n} = ${valToString v}"
      ) config);
in
{
  options.nix = {
    enable = mkEnableOption "Enable Nix, add Nix the global path and creates the necessary folder structure.";

    package = mkOption {
      description = ''
        Which package to use for running Nix related commands, will also be added
        to the global system PATH, TODO.
      '';
      type = types.package;
      default = pkgs.nix;
    };

    buildUserCount = mkOption {
      description = ''
        How many build users, and groups should be created, if Nix runs out,
        increase this number.
      '';
      type = types.int;
      default = 32;
    };

    config = mkOption {
      description = ''
        Contents of <literal>nix.conf</literal>, represented using an attrset containing strings, bools, ints, or lists of strings, bools, or ints.
      '';
      type = with types; attrsOf (oneOf [ str int bool (listOf (oneOf [ str int bool ]))]);
      example =
        {
          sandbox = true;
          require-sigs = true;
          cores = 0;
        };
      default = {};
      apply = x:
        builtins.toFile "nix.conf" (parser x);
    };

    loadNixDb = mkOption {
      description = ''
        Whether to create the registration of this closure, and to load it at
        activation time. Useful when bootstraping a system, such as containers.
      '';
      type = types.bool;
      default = false;
    };
    
    nixPath = mkOption {
      description = ''
        The Nix Path, basically channels.
      '';
      type = with types; listOf str;
      default = [
        "nixpkgs=${pkgs.path}"
      ];
    };

    overlayNix = mkOption {
      description = ''
        Will overlay the included <literal>/nix</literal> and the one at the
        path in this option, with the second one being the upper dir. Can be
        used to persist <literal>/nix</literal> across container restarts.
      '';
      type = with types; nullOr str;
      default = null;
    };

    daemon = mkOption {
      description = ''
        Whether to start the Nix daemon, therefore run in multi-user or single-user mode.
      '';
      type = types.bool;
      default = false;
    };
  };

  config = mkIf cfg.enable {
    system.createNixRegistration = mkIf cfg.loadNixDb true;
    system.activation.loadNixDb = mkIf cfg.loadNixDb
      (nglib.dag.dagEntryAfter [ "currentSystem" "users" ]
        ''
          export PATH=${pkgs.busybox}/bin:${cfg.package}/bin

          if [[ ! -d /nix/var/nix/db ]] ; then
            nix-store --init
            nix-store --load-db < /run/current-system/registration
          fi
        '');

    system.activation.overlayNix = mkIf (cfg.overlayNix != null)
      (nglib.dag.dagEntryBefore [ "loadNixDb" ]
        ''
          export PATH=${pkgs.busybox}/bin

          mkdir -p ${cfg.overlayNix}/upper ${cfg.overlayNix}/work
          chmod 000 ${cfg.overlayNix}/work
          ${pkgs.fuse-overlayfs}/bin/fuse-overlayfs -o lowerdir=/nix,upperdir=${cfg.overlayNix}/upper,workdir=${cfg.overlayNix}/work /nix
        '');
      

    users = {
      users = mkMerge (map (x:
        {
          "nixbld${toString x}" = {
            uid = 30000 + x;
            group = "nixbld";
            home = "/var/empty";
            createHome = false;
            description = "Nix build user ${toString x}";
            shell = "${pkgs.busybox}/bin/nologin";
          };
        })
        (range 0 cfg.buildUserCount));

      groups.nixbld.gid = 30000;
    };

    environment.variables = {
      NIX_PATH = cfg.nixPath;
      NIX_REMOTE = mkIf cfg.daemon "daemon";
    };

    environment.systemPackages = [ cfg.package ];

    nix.config = mkDefault {
      build-users-group = "nixbld";
      max-jobs = "auto";
      cores = 0;
      sandbox = true;
      extra-sandbox-paths = [];
      substituters = [ "https://cache.nixos.org/" ];
      trusted-substituters = [];
      trusted-public-keys =
        [ "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=" ];
      auto-optimise-store = false;
      require-sigs = true;
      allowed-users = "*";
      builders = [];

      system-features =  mkDefault (
        [ "nixos-test" "benchmark" "big-parallel" "kvm" ] ++
        optionals (pkgs.hostPlatform.platform ? gcc.arch) (
          # a builder can run code for `platform.gcc.arch` and inferior architectures
          [ "gccarch-${pkgs.hostPlatform.platform.gcc.arch}" ] ++
          map (x: "gccarch-${x}") lib.systems.architectures.inferiors.${pkgs.hostPlatform.platform.gcc.arch}
        )
      );

      sandbox-fallback = mkIf isNix23 false;
    };

    system.activation.nix = nglib.dag.dagEntryAnywhere ''
      export PATH=${pkgs.busybox}/bin

      install -m 0755 -d /nix/var/nix/{gcroots,profiles}/per-user

      # NixOS canonical location + Debian/Ubuntu/Arch/Gentoo compatibility.
      mkdir -m 0755 -p /etc/nix
      ln -sfn ${cfg.config} /etc/nix/.nix.conf.tmp 
      mv /etc/nix/.nix.conf.tmp /etc/nix/nix.conf # atomically replace /etc/nix/nix.conf
    '';

    init.services.nix-daemon = mkIf cfg.daemon {
      script = pkgs.writeShellScript "nix-daemon" ''
        chpst -b nix-daemon ${cfg.package}/bin/nix-daemon --daemon
      '';
      enabled = true;
    };
  };
}
  

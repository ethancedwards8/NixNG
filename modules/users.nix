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

{ nglib, lib, pkgs, config, ... }:
with lib;
let
  ids = config.ids;
  cfg = config.users;

  userOpts = { config, ... }: {
    options = {
      uid = mkOption {
        description = "The account UID.";
        type = types.int;
      };
      group = mkOption {
        description = "The user's primary group.";
        type = types.str;
        default = "nogroup";
      };
      home = mkOption {
        description = "The user's home.";
        type = types.path;
        default = "/var/empty";
      };
      shell = mkOption {
        description = "The user's default shell.";
        type = types.path;
        default = "${pkgs.busybox}/bin/nologin";
      };
      createHome = mkOption {
        description = ''
              Whether to create the user's home directory automatically or not,
              if the home directory exists but is not owned by the user and their
              group, it will be chowned to match.
            '';
        type = types.bool;
        default = true;
      };
      description = mkOption {
        description = "The user's description.";
        type = types.str;
        default = "";
      };
      extraGroups = mkOption {
        description = "The user's auxiliary groups.";
        type = types.listOf types.str;
        default = [];
      };

      useDefaultShell = mkOption {
        description = ''
              If true, the user's shell will be set to <option>users.defaultUserShell</option>.
            '';
        type = types.bool;
        default = false;
      };
      isNormalUser = mkOption {
        description = ''
              Indicates whether this is an account for a 'real' user. This automatically sets
              <option>group</option> to <literal>users</literal>, <option>createHome</option>
              to <literal>true</literal>, <option>home</option> to <literal>/home/username</literal>,
              and <option>useDefaultShell</option> to <literal>true</literal>.
            '';
        type = types.bool;
        default = false;
      };

      hashedPassword = mkOption {
        description = ''
              Specifies the hashed password for the user, options <option>hashedPassword</option>
              and <option>hashedPasswordFile</option> are mutually exclusive and can't be set both
              at the same time. Use <literal>mkpasswd -m sha-512</literal> to create a suitable hash.

              Be careful, the hash isn't checked for format errors and therefore by 
              inputing a wrongly formatted hash you can yourself out!!
            '';
        type = types.nullOr types.str;
        default = null;
      };
      hashedPasswordFile = mkOption {
        description = ''
              Specifies the file containing the user's hashed password, options
              <option>hashedPassword</option> and <option>hashedPasswordFile</option> are mutually exclusive
              and can't be set both at the same time. Use <literal>mkPasswd -m sha-512</literal>
              to create a suitable hash. The file should contain one line on 
              which the password hash is specified.

              Be careful, the hash isn't checked for format errors and therefore by 
              inputing a wrongly formatted hash you can yourself out!!
            '';
        type = types.nullOr types.str;
        default = null;
      };
    };

    config = mkIf config.isNormalUser {
      group = mkDefault "users";
      createHome = mkDefault true;
      home = mkDefault "/home/${config.name}";
      useDefaultShell = mkDefault true;
    };
  };
in
{
  options.users = {
    defaultUserShell = mkOption {
      description = "The default normal user shell.";
      type = types.either types.shellPackage types.path;
      default = "${pkgs.bashInteractive}/bin/bash";
    };

    createDefaultUsersGroups = mkOption {
      description = ''
        Whether to create useful users and groups. Creates the users:
        <literal>root</literal>, <literal>nobody</literal>
        And groups:
        <literal>root</literal>, <literal>nogroup</literal>
      '';
      type = types.bool;
      default = true;
    };

    users = mkOption {
      description = "An attributes set of users to be created.";
      type = types.attrsOf (types.submodule userOpts);
      default = {};
    };

    groups = mkOption {
      description = "An attributes set of groups to be created.";
      type = types.attrsOf (types.submodule {
        options = {
          gid = mkOption {
            description = "Group GID.";
            type = types.int;
          };
          members = mkOption {
            description = ''
              The user names of the group members, added to the
              <literal>/etc/group</literal> file.
            '';
            type = with types; listOf str;
            default = [];
          };
        };
      });
      default = {};
    };

    passwdFile = mkOption {
      description = "Generate <literal>/etc/passwd</literal> file.";
      type = types.path;
      readOnly = true;
    };
    groupFile = mkOption {
      description = "Generate <literal>/etc/group</literal> file.";
      type = types.path;
      readOnly = true;
    };
    generateShadow = mkOption {
      description = ''
        An executable, which when run generates <literal>/etc/shadow</literal>
        to stdout. Used during activation to avoid the inclusion of the 
        <literal>/etc/shadow</literal> file in the world readable Nix store.
      '';
      type = types.path;
      readOnly = true;
    };
  };

  config = {
    assertions = flatten (mapAttrsToList (n: v:
      [
        {
          assertion = !(v.hashedPassword != null && v.hashedPasswordFile != null);
          message = "For user ${n} either `hashedPassword`, `hashedPasswordFile`, none must be non-null, but not both.";
        }
        {
          assertion = cfg.groups ? "${v.group}";
          message = "For user ${n} the group ${v.group} does not exist!";
        }
      ] ++
      (map (group:
        {
          assertion = cfg.groups ? v.group;
          message = "For user ${n} the extra group ${group} does not exist!";
        }
      ) v.extraGroups)
    ) cfg.users);

    system.activation."users" =
      let
        createHomes = 
          concatMapStringsSep "\n"
            ({ n, v }: "mkdir -p ${v.home} && chown ${n}:${v.group} ${v.home}")
            (filter ({ v, ... }: v.createHome)
              (mapAttrsToList (n: v: { n = n; v = v; }) cfg.users));
      in
        nglib.dag.dagEntryAnywhere ''
          export PATH=${pkgs.busybox}/bin

          ln -sf ${cfg.passwdFile} /etc/passwd
          ln -sf ${cfg.groupFile} /etc/group
          ${cfg.generateShadow} > /etc/shadow 
          ${createHomes}
        '';

    users = {
      users = mkIf cfg.createDefaultUsersGroups {
        root = {
          uid = ids.uids.root;
          group = "root";
          createHome = true;
          home = "/root";
          useDefaultShell = true;
        };
        nobody = {
          uid = ids.uids.nobody;
          group = "nogroup";
          createHome = true;
          home = "/var/empty";
          shell = "${pkgs.busybox}/bin/nologin";
        };
      };

      groups = mkMerge ([
        (optionalAttrs cfg.createDefaultUsersGroups {
          root.gid = ids.gids.root;
          nogroup.gid = ids.gids.nogroup;
        })
      ] ++ 
      (let
        filterGroups = groups:
          filter (group: cfg.groups ? "${group}") groups;
        members = flatten (mapAttrsToList (n: u: map (g: { "${g}".members = [n]; }) (u.extraGroups ++ singleton u.group)) cfg.users);
      in
         members));

      passwdFile = pkgs.writeText "passwd"
        (concatStringsSep "\n" (mapAttrsToList (n: v:
          with v;
          let
            shell = if useDefaultShell then cfg.defaultUserShell else v.shell;
          in
            "${n}:x:${toString uid}:${toString cfg.groups."${group}".gid}:${description}:${home}:${shell}"
        ) cfg.users));
      groupFile = pkgs.writeText "group"
        (concatStringsSep "\n" (mapAttrsToList (n: v:
          with v;
          "${n}:x:${toString gid}:${concatStringsSep "," members}"
        ) cfg.groups));
      generateShadow = pkgs.writeShellScript "generate-shadow"
        ''
          export PATH=${pkgs.busybox}/bin
          cat << EOF
          ${concatStringsSep "\n" (mapAttrsToList (n: v:
            with v;
            "${n}:${if hashedPassword != null then hashedPassword else if hashedPasswordFile != null then "$(<${hashedPasswordFile})" else "!"}:1::::::"
          ) cfg.users)}
          EOF
        '';
    };
  };
}

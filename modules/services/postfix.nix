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

{ pkgs, config, lib, nglib, ... }:
with lib;
let
  cfg = config.services.postfix;
  inherit (config.users) createDefaultUsersGroups;

  yes-no-nothing = types.enum [ "y" "n" "-" ];
  masterCfModule = with types; submodule {
    options = {
      type = mkOption {
        type = types.enum [ "inet" "unix" "unix-dgram" "fifo" "pass" ];
        description = ''
          Service type.
        '';
      };
      private = mkOption {
        type = yes-no-nothing;
        description = ''
          Whether or not access is restricted to the mail system.   Inter-
          net (type inet) services can't be private.
        '';
        default = "-";
      };
      unpriv = mkOption {
        type = yes-no-nothing;
        description = ''
          Whether the service runs with root privileges or as the owner of
          the  Postfix  system  (the  owner  name  is  controlled  by  the
          mail_owner configuration variable in the main.cf file).

          The  local(8), pipe(8), spawn(8), and virtual(8) daemons require
          privileges.
        '';
        default = "-";
      };
      chroot = mkOption {
        type = yes-no-nothing;
        description = ''
          Whether or not the service  runs  chrooted  to  the  mail  queue
          directory (pathname is controlled by the queue_directory config-
          uration variable in the main.cf file).

          Chroot should not be used with the local(8), pipe(8),  spawn(8),
          and virtual(8) daemons.  Although the proxymap(8) server can run
          chrooted, doing so defeats most of the purpose  of  having  that
          service in the first place.

          The files in the examples/chroot-setup subdirectory of the Post-
          fix source show how to set up a Postfix chroot environment on  a
          variety  of  systems.  See  also  BASIC_CONFIGURATION_README for
          issues related to running daemons chrooted.
        '';
        default = "-";
      };
      wakeup = mkOption {
        type = types.oneOf [ int str ];
        description = ''
          Automatically wake up the named service after the specified num-
          ber  of seconds. The wake up is implemented by connecting to the
          service and sending a wake up request.  A ? at the  end  of  the
          wake-up  time  field  requests  that  no  wake up events be sent
          before the first time a service is used.  Specify 0 for no auto-
          matic wake up.

          The  pickup(8),  qmgr(8)  and flush(8) daemons require a wake up
          timer.
        '';
        default = "-";
        apply = x:
          if isString x then
            x
          else
            toString x;
      };
      maxproc = mkOption {
        type = types.oneOf [ int str ];
        description = ''
          The maximum number of processes that may  execute  this  service
          simultaneously. Specify 0 for no process count limit.

          NOTE:  Some  Postfix  services  must  be  configured  as  a sin-
          gle-process service (for example,  qmgr(8))  and  some  services
          must   be   configured  with  no  process  limit  (for  example,
          cleanup(8)).  These limits must not be changed.
        '';
        default = "-";
        apply = x:
          if isString x then
            x
          else
            toString x;
      };
      command = mkOption {
        type = types.str;
        description = ''
          The command to be executed.  Characters that are special to  the
          shell  such  as  ">"  or  "|"  have no special meaning here, and
          quotes cannot be used to  protect  arguments  containing  white-
          space.  To  protect  whitespace,  use  "{"  and "}" as described
          below.

          The command name is relative to  the  Postfix  daemon  directory
          (pathname  is  controlled  by the daemon_directory configuration
          variable).

          The command argument syntax for specific commands  is  specified
          in the respective daemon manual page.
        '';
      };
    };
  };

  inherit (nglib.generators.postfix) toMainCnf;
in
{
  options = {
    services.postfix = {
      enable = mkEnableOption "Enable Postfix MTA.";

      package = mkOption {
        description = "Postfix package.";
        type = types.package;
        default = pkgs.postfix;
      };

      user = mkOption {
        description = "Postfix user.";
        type = types.str;
        default = "postfix";
      };

      group = mkOption {
        description = "Postfix group.";
        type = types.str;
        default = "postfix";
      };

      setgidGroup = mkOption {
        description = "Postfix privilege drop group.";
        type = types.str;
        default = "postdrop";
      };

      mainConfig = mkOption {
        description = "Postfix main.cnf.";
        type = with types;
          attrsOf (nullOr (oneOf [
            str
            int
            package
            bool
            (listOf (oneOf [ str int package bool ]))
          ]));
        default = {};
      };

      masterConfig = mkOption {
        description = "Postfix master.cfg.";
        type = with types;
          attrsOf (nullOr (either masterCfModule (listOf masterCfModule)));
        default = {};
        apply = x:
          concatStringsSep "\n" (mapAttrsToList (n: v:
            if isNull v then
              ""
            else if isAttrs v then
              with v;
              "${n} ${type} ${private} ${unpriv} ${chroot} ${wakeup} ${maxproc} ${command}"
            else
              concatMapStringsSep "\n" (y:
                with y;
                "${n} ${type} ${private} ${unpriv} ${chroot} ${wakeup} ${maxproc} ${command}"
              ) v
          ) x);
      };
    };
  };

  config = mkIf cfg.enable
    {
      users.users.${cfg.user} = mkDefault {
        description = "Postfix";
        group = cfg.group;
        createHome = false;
        home = "/var/empty";
        useDefaultShell = true;
        uid = config.ids.uids.postfix;
      };

      users.groups.${cfg.group} = {
        gid = mkDefault config.ids.gids.postfix;
      };

      users.groups.${cfg.setgidGroup} = {
        gid = mkDefault config.ids.gids.postdrop;
      };

      services.postfix = {
        mainConfig = {
          compatibility_level  = mkDefault cfg.package.version;
          mail_owner           = mkDefault cfg.user;
          default_privs        = mkDefault "nobody";

          # NixOS specific locations
          data_directory       = mkDefault "/var/lib/postfix/data";
          queue_directory      = mkDefault "/var/lib/postfix/queue";

          # Default location of everything in package
          meta_directory       = "${pkgs.postfix}/etc/postfix";
          command_directory    = "${pkgs.postfix}/bin";
          sample_directory     = mkDefault "/etc/postfix";
          newaliases_path      = "${pkgs.postfix}/bin/newaliases";
          mailq_path           = "${pkgs.postfix}/bin/mailq";
          readme_directory     = mkDefault false;
          sendmail_path        = "${pkgs.postfix}/bin/sendmail";
          daemon_directory     = "${pkgs.postfix}/libexec/postfix";
          manpage_directory    = "${pkgs.postfix}/share/man";
          html_directory       = "${pkgs.postfix}/share/postfix/doc/html";
          shlib_directory      = mkDefault false;
          mail_spool_directory = mkDefault "/var/spool/mail/";
          setgid_group         = mkDefault cfg.setgidGroup;
        };

        masterConfig = mapAttrs (_: v: mkDefault v) {
          pickup = {
            type = "unix";
            private = "n";
            chroot = "n";
            wakeup = "60";
            maxproc = "1";
            command = "pickup";
          };
          cleanup = { type = "unix"; private = "n"; chroot = "n"; maxproc = "0";
                      command = "cleanup"; };
          qmgr = { type = "unix"; private = "n"; chroot = "n"; wakeup = "300";
                   maxproc = "1"; command = "qmgr"; };
          tlsmgr = { type = "unix"; wakeup = "1000?"; maxproc = 1; command = "tlsmgr"; };
          rewrite = { type = "unix"; chroot = "n"; command = "trivial-rewrite"; };
          bounce = { type = "unix"; chroot = "n";  maxproc = 0; command = "bounce"; };
          defer = { type = "unix"; chroot = "n"; maxproc = 0; command = "bounce"; };
          trace = { type = "unix"; chroot = "n"; maxproc = 0; command = "bounce"; };
          verify = { type = "unix"; chroot = "n"; maxproc = 1; command = "verify"; };
          flush = { type = "unix"; chroot = "n"; wakeup = "1000?"; maxproc = "0";
                    command = "flush"; };
          proxymap = { type = "unix"; chroot = "n"; command = "proxymap"; };
          proxywrite = { type = "unix"; chroot = "n"; maxproc = "1";
                         command = "proxymap"; };
          smtp = [ { type = "unix"; chroot = "n"; command = "smtp"; }
                   { type = "inet"; private = "n"; chroot = "n"; command = "smtpd"; }
                 ];
          relay = { type = "unix"; chroot = "n"; command = ''
              smtp
                      -o syslog_name=postfix/$service_name
              #       -o smtp_helo_timeout=5 -o smtp_connect_timeout=5
            ''; };
          showq = { type = "unix"; private = "n"; chroot = "n"; command = "showq"; };
          error = { type = "unix"; chroot = "n"; command = "error"; };
          retry = { type = "unix"; chroot = "n"; command = "error"; };
          discard = { type = "unix"; chroot = "n"; command = "discard"; };
          local = { type = "unix";  unpriv = "n"; chroot = "n"; command = "local"; };
          virtual = { type = "unix"; unpriv = "n"; chroot = "n"; command = "virtual"; };
          lmtp = { type = "unix"; chroot = "n"; command = "lmtp"; };
          anvil = { type = "unix"; chroot = "n"; maxproc = 1; command = "anvil"; };
          scache = { type = "unix"; chroot = "n"; maxproc = 1; command = "scache"; };
          postlog =
            { type = "unix-dgram"; private = "n"; chroot = "n"; maxproc = "1";
              command = "postlogd"; };
        };
      };

      init.services.postfix =
        let
          mainCnf = pkgs.writeText "main.cf" (toMainCnf cfg.mainConfig);
          masterCnf = pkgs.writeText "master.cf" cfg.masterConfig;
          configDir = pkgs.runCommandNoCCLocal "postfix-config-dir" {}
            ''
              mkdir -p $out
              ln -s ${mainCnf} $out/main.cf
              ln -s ${masterCnf} $out/master.cf
            '';
        in
          {
            ensureSomething.create."data" = mkDefault {
              type = "directory";
              mode = "750";
              owner = "${cfg.user}:${cfg.group}";
              dst = cfg.mainConfig.data_directory;
              persistent = true;
            };

            ensureSomething.create."queue" = mkDefault {
              type = "directory";
              mode = "750";
              owner = "${cfg.user}:root";
              dst = cfg.mainConfig.queue_directory;
              persistent = false;
            };

            script = pkgs.writeShellScript "postfix-run"
              ''
                mkdir -p /etc/postfix/
                ${cfg.package}/bin/postfix -c ${configDir} set-permissions 
                ${cfg.package}/libexec/postfix/master -c ${configDir}
              '';      
            enabled = true;
          };
      assertions = [
        {
          assertion = createDefaultUsersGroups;
          message = ''
            Postfix relies on the `root` group being present,
            enable `users.createDefaultUsersGroups`.
          '';
        }
      ];
    };
}

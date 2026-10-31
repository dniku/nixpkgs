{
  options,
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib)
    escapeShellArgs
    mkEnableOption
    mkIf
    mkOption
    types
    ;

  cfg = config.services.loki;
  isDefaultDataDir = cfg.dataDir == options.services.loki.dataDir.default;

  prettyJSON =
    conf:
    pkgs.runCommand "loki-config.json" { } ''
      echo '${builtins.toJSON conf}' | ${pkgs.jq}/bin/jq 'del(._module)' > $out
    '';

in
{
  options.services.loki = {
    enable = mkEnableOption "Grafana Loki";

    user = mkOption {
      type = types.str;
      default = "loki";
      description = ''
        User under which the Loki service runs.
      '';
    };

    package = lib.mkPackageOption pkgs "grafana-loki" { };

    group = mkOption {
      type = types.str;
      default = "loki";
      description = ''
        Group under which the Loki service runs.
      '';
    };

    dataDir = mkOption {
      type = types.path;
      default = "/var/lib/loki";
      description = ''
        Specify the data directory for Loki.
        The default directory is managed by systemd's `StateDirectory`, using
        {option}`users.users.<name>.homeMode` of the configured user as its mode.
        Custom directories are created with tmpfiles, which preserves existing
        permissions and only changes ownership of the directory itself.
      '';
    };

    configuration = mkOption {
      type = (pkgs.formats.json { }).type;
      default = { };
      description = ''
        Specify the configuration for Loki in Nix.

        See [documentation of Grafana Loki](https://grafana.com/docs/loki/latest/configure/) for all available options.

        Cannot be specified together with {option}`services.loki.configFile`.
      '';
    };

    configFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        Specify a configuration file that Loki should use.

        Cannot be specified together with {option}`services.loki.configuration`.
      '';
    };

    extraFlags = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "--server.http-listen-port=3101" ];
      description = ''
        Specify a list of additional command line flags,
        which get escaped and are then passed to Loki.
      '';
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = (
          (cfg.configuration == { } -> cfg.configFile != null)
          && (cfg.configFile != null -> cfg.configuration == { })
        );
        message = ''
          Please specify either
          'services.loki.configuration' or
          'services.loki.configFile'.
        '';
      }
    ];

    environment.systemPackages = [ cfg.package ]; # logcli

    systemd.tmpfiles.settings.loki = mkIf (!isDefaultDataDir) {
      "${cfg.dataDir}".d = {
        # Only apply the mode on creation: https://www.freedesktop.org/software/systemd/man/262/tmpfiles.d.html#Mode
        mode = ":${config.users.users.${cfg.user}.homeMode}";
        inherit (cfg) user group;
      };
    };

    users.groups.${cfg.group} = { };
    users.users.${cfg.user} = {
      description = "Loki Service User";
      group = cfg.group;
      isSystemUser = true;
    };

    systemd.services.loki = {
      description = "Loki Service Daemon";
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      environment.HOME = cfg.dataDir;

      serviceConfig =
        let
          conf =
            if cfg.configFile == null then
              # Config validation may fail when using extraFlags = [ "-config.expand-env=true" ].
              # To work around this, we simply skip it when extraFlags is not empty.
              if cfg.extraFlags == [ ] then
                validateConfig (prettyJSON cfg.configuration)
              else
                prettyJSON cfg.configuration
            else
              cfg.configFile;
          validateConfig =
            file:
            pkgs.runCommand "validate-loki-conf"
              {
                nativeBuildInputs = [ cfg.package ];
              }
              ''
                loki -verify-config -config.file "${file}"
                ln -s "${file}" "$out"
              '';
        in
        {
          ExecStart = "${cfg.package}/bin/loki --config.file=${conf} ${escapeShellArgs cfg.extraFlags}";
          User = cfg.user;
          Group = cfg.group;
          StateDirectory = mkIf isDefaultDataDir "loki";
          StateDirectoryMode = mkIf isDefaultDataDir config.users.users.${cfg.user}.homeMode;
          Restart = "always";
          PrivateTmp = true;
          ProtectHome = true;
          ProtectSystem = "full";
          DevicePolicy = "closed";
          NoNewPrivileges = true;
          WorkingDirectory = cfg.dataDir;
        };
    };
  };
}

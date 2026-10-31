{ lib, pkgs, ... }:

{
  name = "loki";

  meta.maintainers = [ ];

  nodes = lib.genAttrs [ "machine" "custom" "missing" ] (
    name:
    { config, ... }:
    {
      services.loki = {
        enable = true;
        dataDir = lib.mkIf (name != "machine") "/srv/loki";
        user = lib.mkIf (name != "machine") "custom-loki";
        group = lib.mkIf (name != "machine") "custom-loki-group";
        configFile = pkgs.substitute {
          src = "${pkgs.grafana-loki.src}/cmd/loki/loki-local-config.yaml";
          substitutions = [
            "--replace-fail"
            "/tmp/loki"
            config.services.loki.dataDir
          ];
        };
      };

      # Exercise each user backend, including its home-directory handling.
      services.userborn.enable = name == "custom";
      systemd.sysusers.enable = name == "missing";
      users.users.${config.services.loki.user}.homeMode = lib.mkIf (name == "missing") "0750";

      virtualisation.fileSystems.${if name == "missing" then "/srv" else config.services.loki.dataDir} = {
        device = "none";
        fsType = "tmpfs";
        options = [ "mode=${if name == "custom" then "0750" else "0755"}" ];
      };
    }
  );

  testScript = ''
    import json
    import time

    payload = json.dumps({
        "streams": [{
            "stream": {"job": "test"},
            "values": [
                [str(time.time_ns()), "Loki Ingestion Test"],
            ],
        }],
    })
    for node, directory, owner, mode in [
        (machine, "/var/lib/loki", "loki:loki", "700"),
        (custom, "/srv/loki", "custom-loki:custom-loki-group", "750"),
        (missing, "/srv/loki", "custom-loki:custom-loki-group", "750"),
    ]:
        with subtest(f"{node.name}: mounted data directory"):
            node.start()
            node.wait_for_unit("loki.service")
            assert node.succeed(f"stat -c '%U:%G:%a' {directory}").strip() == f"{owner}:{mode}"
            node.wait_for_open_port(3100)
            node.succeed(f"curl --fail --json '{payload}' http://localhost:3100/loki/api/v1/push")
            node.wait_until_succeeds("logcli query --no-labels '{job=\"test\"}' | grep -q 'Loki Ingestion Test'")
            node.fail(f"journalctl -b -u systemd-tmpfiles-setup.service --grep 'Duplicate line for path.*{directory}'")

        with subtest(f"{node.name}: ownership repair"):
            node.succeed(
                "systemctl stop loki.service",
                f"install -m 0600 /dev/null {directory}/test-root-owned-file",
                f"chown root:root {directory}",
                f"chmod 0700 {directory}",
            )
            if node == machine:
                # StateDirectory repairs child ownership when the parent owner differs.
                node.succeed("systemctl start loki.service")
                child_owner = owner
            else:
                # The custom-path fallback only repairs the directory itself.
                node.succeed(f"systemd-tmpfiles --create --prefix={directory}")
                node.succeed("systemctl start loki.service")
                child_owner = "root:root"
            assert node.succeed(f"stat -c '%U:%G:%a' {directory}").strip() == f"{owner}:700"
            assert node.succeed(f"stat -c '%U:%G:%a' {directory}/test-root-owned-file").strip() == f"{child_owner}:600"
            node.wait_until_succeeds("logcli query --no-labels '{job=\"test\"}' | grep -q 'Loki Ingestion Test'")

        node.shutdown()
  '';
}

{ lib, ... }:

{
  name = "grafana-data-dir";

  nodes = lib.genAttrs [ "machine" "custom" "missing" ] (
    name:
    { config, ... }:
    {
      services.grafana = {
        enable = true;
        dataDir = lib.mkIf (name != "machine") "/srv/grafana";
        settings.security.secret_key = "grafana-data-dir-test-key";
      };

      # Exercise each user backend, including its home-directory handling.
      services.userborn.enable = name == "custom";
      systemd.sysusers.enable = name == "missing";
      users.users.grafana.homeMode = lib.mkIf (name == "missing") "0750";

      virtualisation.fileSystems.${
        if name == "missing" then "/srv" else config.services.grafana.dataDir
      } =
        {
          device = "none";
          fsType = "tmpfs";
          options = [ "mode=${if name == "custom" then "0750" else "0755"}" ];
        };
    }
  );

  testScript = ''
    import json

    for node, directory, mode in [
        (machine, "/var/lib/grafana", "700"),
        (custom, "/srv/grafana", "750"),
        (missing, "/srv/grafana", "750"),
    ]:
        with subtest(f"{node.name}: mounted data directory"):
            node.start()
            node.wait_for_unit("grafana.service")
            assert node.succeed(f"stat -c '%U:%G:%a' {directory}").strip() == f"grafana:grafana:{mode}"
            node.wait_for_open_port(3000)
            health = json.loads(node.succeed("curl --fail --silent http://localhost:3000/api/health"))
            assert health["database"] == "ok"
            node.fail(f"journalctl -b -u systemd-tmpfiles-setup.service --grep 'Duplicate line for path.*{directory}'")

        with subtest(f"{node.name}: ownership repair"):
            node.succeed(
                "systemctl stop grafana.service",
                f"install -m 0600 /dev/null {directory}/test-root-owned-file",
                f"chown root:root {directory}",
                f"chmod 0700 {directory}",
            )
            if node == machine:
                # StateDirectory repairs child ownership when the parent owner differs.
                node.succeed("systemctl start grafana.service")
                owner = "grafana:grafana"
            else:
                # The custom-path fallback only repairs the directory itself.
                node.succeed(f"systemd-tmpfiles --create --prefix={directory}")
                node.succeed("systemctl start grafana.service")
                owner = "root:root"
            assert node.succeed(f"stat -c '%U:%G:%a' {directory}").strip() == "grafana:grafana:700"
            assert node.succeed(f"stat -c '%U:%G:%a' {directory}/test-root-owned-file").strip() == f"{owner}:600"
            node.wait_for_open_port(3000)
            health = json.loads(node.succeed("curl --fail --silent http://localhost:3000/api/health"))
            assert health["database"] == "ok"

        node.shutdown()
  '';
}

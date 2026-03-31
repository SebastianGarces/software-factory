// install.ts — macOS launchd installer (replaces factory-install.sh)

import { join, resolve, dirname } from "node:path";
import { mkdir } from "node:fs/promises";

const LABEL = "com.software-factory.runner";

async function uninstall(): Promise<void> {
  console.log("Uninstalling factory service...");
  const uid = Bun.spawnSync(["id", "-u"]).stdout.toString().trim();
  Bun.spawnSync(["launchctl", "bootout", `gui/${uid}/${LABEL}`]);

  const plistPath = join(process.env.HOME || "~", `Library/LaunchAgents/${LABEL}.plist`);
  try {
    const { unlink } = await import("node:fs/promises");
    await unlink(plistPath);
  } catch {}

  console.log("Uninstalled.");
}

async function install(specInput: string, projectDir: string): Promise<void> {
  const uid = Bun.spawnSync(["id", "-u"]).stdout.toString().trim();
  const plistPath = join(process.env.HOME || "~", `Library/LaunchAgents/${LABEL}.plist`);

  // Resolve absolute paths
  const absSpec = resolve(specInput);
  const absProject = resolve(projectDir);

  // Resolve heartbeat script path
  const srcDir = dirname(new URL(import.meta.url).pathname);
  const heartbeatScript = resolve(join(srcDir, "heartbeat.ts"));

  // Find bun binary
  const bunPath = Bun.spawnSync(["which", "bun"]).stdout.toString().trim() || "/usr/local/bin/bun";

  console.log("Installing factory as launchd service...");
  console.log(`  Spec: ${absSpec}`);
  console.log(`  Project: ${absProject}`);
  console.log(`  Plist: ${plistPath}`);

  // Unload existing if present
  Bun.spawnSync(["launchctl", "bootout", `gui/${uid}/${LABEL}`]);

  // Get node version for PATH
  const nodeVersion = Bun.spawnSync(["node", "-v"]).stdout.toString().trim() || "v20.0.0";

  const plist = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LABEL}</string>

  <key>ProgramArguments</key>
  <array>
    <string>${bunPath}</string>
    <string>run</string>
    <string>${heartbeatScript}</string>
    <string>${absSpec}</string>
    <string>${absProject}</string>
  </array>

  <key>WorkingDirectory</key>
  <string>${absProject}</string>

  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>

  <key>ThrottleInterval</key>
  <integer>30</integer>

  <key>StandardOutPath</key>
  <string>${absProject}/.factory/logs/launchd-stdout.log</string>

  <key>StandardErrorPath</key>
  <string>${absProject}/.factory/logs/launchd-stderr.log</string>

  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin:${process.env.HOME}/.local/bin:${process.env.HOME}/.bun/bin:${process.env.HOME}/.nvm/versions/node/${nodeVersion}/bin</string>
    <key>HOME</key>
    <string>${process.env.HOME}</string>
  </dict>
</dict>
</plist>`;

  await Bun.write(plistPath, plist);

  // Ensure log directory exists
  await mkdir(join(absProject, ".factory/logs"), { recursive: true });

  // Load the service
  Bun.spawnSync(["launchctl", "bootstrap", `gui/${uid}`, plistPath]);

  console.log("");
  console.log("Factory service installed and started!");
  console.log("");
  console.log("Commands:");
  console.log(`  Status:    launchctl print gui/${uid}/${LABEL}`);
  console.log(`  Stop:      launchctl bootout gui/${uid}/${LABEL}`);
  console.log(`  Logs:      tail -f ${absProject}/.factory/logs/launchd-stdout.log`);
  console.log(`  Errors:    tail -f ${absProject}/.factory/logs/launchd-stderr.log`);
  console.log(`  Uninstall: bun run ts/src/install.ts --uninstall`);
  console.log("");
  console.log("Monitor progress:");
  console.log(`  bun run ts/src/monitor/status.ts ${absProject}`);
}

// CLI entry
const args = process.argv.slice(2);

if (args[0] === "--uninstall") {
  await uninstall();
} else if (args.length < 1) {
  console.error("Usage: bun run ts/src/install.ts <spec-file> [project-dir]");
  console.error("       bun run ts/src/install.ts --uninstall");
  process.exit(1);
} else {
  await install(args[0], args[1] || ".");
}

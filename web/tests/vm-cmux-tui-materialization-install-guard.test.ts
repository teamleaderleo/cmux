import { spawnSync } from "node:child_process";
import { describe, expect, test } from "bun:test";
import {
  CMUX_TUI_BINARY_PATH,
  cmuxTuiInstallCommand,
  cmuxTuiInstallMaterializationGuardCommand,
  type CmuxTuiSource,
} from "../services/vms/drivers/cmuxTuiDaemon";
import { CMUX_TUI_MATERIALIZATION_ID_ENV } from "../services/vms/drivers/cmuxTuiMaterialization";

const source: CmuxTuiSource = {
  url: "https://files.cmux.com/cmux-tui/test/cmux-tui-x86_64-unknown-linux-musl",
  sha256: "a".repeat(64),
  commit: "b".repeat(40),
  builtAt: null,
};

describe("cmux-tui install materialization guard", () => {
  test("guard is valid POSIX shell and resolves the reserved token through the one-shot rekey", () => {
    const guard = cmuxTuiInstallMaterializationGuardCommand();
    expect(guard).toContain(`\${${CMUX_TUI_MATERIALIZATION_ID_ENV}:-}`);
    expect(guard).toContain(`'${CMUX_TUI_BINARY_PATH}' __materialize-new-machine`);
    expect(guard).toContain("--workspace-state-root '/root/.local/state/cmux-tui/sessions'");
    expect(guard).toContain("--remote-state-dir '/root/.local/state/cmux/remote'");
    expect(guard).toContain(`--materialization-id \"$${CMUX_TUI_MATERIALIZATION_ID_ENV}\"`);
    expect(guard).toContain('"$cmux_materialize_attempt" -ge 5');

    const syntax = spawnSync("/bin/sh", ["-n"], { input: guard, encoding: "utf8" });
    expect(syntax.status).toBe(0);
    expect(syntax.stderr).toBe("");
  });

  test("install cannot succeed before the new-machine guard is evaluated", () => {
    const command = cmuxTuiInstallCommand(source);
    const versionIndex = command.indexOf(`'${CMUX_TUI_BINARY_PATH}' --version`);
    const guardIndex = command.indexOf("__materialize-new-machine");
    expect(versionIndex).toBeGreaterThanOrEqual(0);
    expect(guardIndex).toBeGreaterThan(versionIndex);
    expect(command).toContain(`\${${CMUX_TUI_MATERIALIZATION_ID_ENV}:-}`);
  });
});

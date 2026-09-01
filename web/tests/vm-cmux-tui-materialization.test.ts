import { describe, expect, test } from "bun:test";
import type { CmuxTuiInvoke } from "../services/vms/drivers/cmuxTuiDaemon";
import {
  CMUX_TUI_MATERIALIZE_BINARY_PATH,
  CMUX_TUI_REMOTE_STATE_DIR,
  CMUX_TUI_WORKSPACE_STATE_ROOT,
  cmuxTuiMaterializationPlan,
  materializeCmuxTuiNewMachine,
  materializeThenStartCmuxTui,
} from "../services/vms/drivers/cmuxTuiMaterialization";

function invokeWith(result: { exitCode: number; stdout?: string; stderr?: string }) {
  const calls: Array<{ command: string; timeoutMs?: number }> = [];
  const invoke: CmuxTuiInvoke = async (command, timeoutMs) => {
    calls.push({ command, timeoutMs });
    return {
      exitCode: result.exitCode,
      stdout: result.stdout ?? "",
      stderr: result.stderr ?? "",
    };
  };
  return { invoke, calls };
}

describe("cmux-tui Cloud materialization gate", () => {
  test("fresh enrollment is the default and uses the Cloud state roots", () => {
    const plan = cmuxTuiMaterializationPlan("sandbox-new-machine");
    expect(plan.enrollmentPolicy).toBe("fresh");
    expect(plan.materializerBinary).toBe(CMUX_TUI_MATERIALIZE_BINARY_PATH);
    expect(plan.workspaceStateRoot).toBe(CMUX_TUI_WORKSPACE_STATE_ROOT);
    expect(plan.remoteStateDir).toBe(CMUX_TUI_REMOTE_STATE_DIR);
    expect(plan.command).toContain(`'${CMUX_TUI_MATERIALIZE_BINARY_PATH}'`);
    expect(plan.command).toContain(`'${CMUX_TUI_WORKSPACE_STATE_ROOT}'`);
    expect(plan.command).toContain(`'${CMUX_TUI_REMOTE_STATE_DIR}'`);
    expect(plan.command).toContain("--materialization-id 'sandbox-new-machine'");
    expect(plan.command).not.toContain("--inherit-enrollments");
  });

  test("inherited enrollment must be requested explicitly", () => {
    const plan = cmuxTuiMaterializationPlan("sandbox-copy", { inheritEnrollments: true });
    expect(plan.enrollmentPolicy).toBe("inherit");
    expect(plan.command).toContain("--inherit-enrollments");
  });

  test("materialization failure prevents daemon start", async () => {
    const { invoke, calls } = invokeWith({
      exitCode: 1,
      stderr: "remote authorization state is busy",
    });
    let started = false;
    await expect(
      materializeThenStartCmuxTui(invoke, "e2b", "sandbox-b", async () => {
        started = true;
        return "started";
      }),
    ).rejects.toThrow("materialization in sandbox-b failed");
    expect(started).toBe(false);
    expect(calls).toHaveLength(1);
  });

  test("daemon start runs only after a valid materialization receipt", async () => {
    const receipt = {
      changed: true,
      materialization_id: "sandbox-b",
      machine_id: "machine_test",
      daemon_fingerprint: "daemon-test",
      enrollment_policy: "fresh",
    } as const;
    const { invoke, calls } = invokeWith({
      exitCode: 0,
      stdout: JSON.stringify(receipt),
    });
    const order: string[] = [];
    const result = await materializeThenStartCmuxTui(
      async (command, timeoutMs) => {
        order.push("materialize");
        return invoke(command, timeoutMs);
      },
      "e2b",
      "sandbox-b",
      async () => {
        order.push("start");
        return "daemon-started";
      },
    );
    expect(order).toEqual(["materialize", "start"]);
    expect(calls).toHaveLength(1);
    expect(result.materialization).toEqual(receipt);
    expect(result.started).toBe("daemon-started");
  });

  test("receipt must belong to the machine being materialized", async () => {
    const { invoke } = invokeWith({
      exitCode: 0,
      stdout: JSON.stringify({
        changed: false,
        materialization_id: "sandbox-a",
        machine_id: "machine_test",
        daemon_fingerprint: "daemon-test",
        enrollment_policy: "fresh",
      }),
    });
    await expect(materializeCmuxTuiNewMachine(invoke, "daytona", "sandbox-b"))
      .rejects.toThrow("returned an invalid receipt");
  });

  test("shell quoting keeps opaque provider ids in one argument", () => {
    const plan = cmuxTuiMaterializationPlan("machine-'quoted'");
    expect(plan.command).toContain("'machine-'\"'\"'quoted'\"'\"''");
  });
});

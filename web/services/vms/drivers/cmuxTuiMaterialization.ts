import {
  CMUX_TUI_BINARY_PATH,
  type CmuxTuiInvoke,
} from "./cmuxTuiDaemon";
import { ProviderError, type ProviderId } from "./types";

/**
 * Linux Cloud state roots used by `cmux-tui server start` when providers run it
 * as root with HOME=/root and do not pass an explicit --state override.
 */
export const CMUX_TUI_WORKSPACE_STATE_ROOT = "/root/.local/state/cmux-tui/sessions";
export const CMUX_TUI_REMOTE_STATE_DIR = "/root/.local/state/cmux/remote";
export const CMUX_TUI_MATERIALIZATION_TIMEOUT_MS = 30_000;

/**
 * Prototype A currently builds the transition as a sibling executable. The
 * production packaging decision is intentionally explicit here: today's Cloud
 * installer downloads only CMUX_TUI_BINARY_PATH, so this sidecar must either be
 * shipped alongside it or replaced by an equivalent main-binary subcommand.
 */
export const CMUX_TUI_MATERIALIZE_BINARY_PATH = `${CMUX_TUI_BINARY_PATH}-materialize`;

export interface CmuxTuiMaterializationReceipt {
  changed: boolean;
  materialization_id: string;
  machine_id: string;
  daemon_fingerprint: string;
  enrollment_policy: "fresh" | "inherit";
}

export interface CmuxTuiMaterializationPlan {
  command: string;
  materializationId: string;
  enrollmentPolicy: "fresh" | "inherit";
  workspaceStateRoot: string;
  remoteStateDir: string;
  materializerBinary: string;
}

export function cmuxTuiMaterializationPlan(
  materializationId: string,
  options: {
    inheritEnrollments?: boolean;
    materializerBinary?: string;
    workspaceStateRoot?: string;
    remoteStateDir?: string;
  } = {},
): CmuxTuiMaterializationPlan {
  if (!materializationId || materializationId.trim() !== materializationId || /[\u0000-\u001f\u007f]/.test(materializationId)) {
    throw new Error("materialization id must be non-empty, trimmed, and free of control characters");
  }
  const materializerBinary = options.materializerBinary ?? CMUX_TUI_MATERIALIZE_BINARY_PATH;
  const workspaceStateRoot = options.workspaceStateRoot ?? CMUX_TUI_WORKSPACE_STATE_ROOT;
  const remoteStateDir = options.remoteStateDir ?? CMUX_TUI_REMOTE_STATE_DIR;
  const enrollmentPolicy = options.inheritEnrollments ? "inherit" : "fresh";
  const args = [
    shellQuote(materializerBinary),
    "--workspace-state-root",
    shellQuote(workspaceStateRoot),
    "--remote-state-dir",
    shellQuote(remoteStateDir),
    "--materialization-id",
    shellQuote(materializationId),
  ];
  if (options.inheritEnrollments) args.push("--inherit-enrollments");
  return {
    command: args.join(" "),
    materializationId,
    enrollmentPolicy,
    workspaceStateRoot,
    remoteStateDir,
    materializerBinary,
  };
}

/**
 * Run the new-machine transition before the daemon is allowed to start.
 * A non-zero materializer result is fail-closed: the caller must not continue
 * into `cmux-tui server start` on copied identity state.
 */
export async function materializeCmuxTuiNewMachine(
  invoke: CmuxTuiInvoke,
  provider: ProviderId,
  vmId: string,
  options: Parameters<typeof cmuxTuiMaterializationPlan>[1] = {},
): Promise<CmuxTuiMaterializationReceipt> {
  const plan = cmuxTuiMaterializationPlan(vmId, options);
  const result = await invoke(plan.command, CMUX_TUI_MATERIALIZATION_TIMEOUT_MS);
  if (result.exitCode !== 0) {
    throw new ProviderError(
      provider,
      `cmux-tui new-machine materialization in ${vmId} failed: ${result.stderr || result.stdout}`,
    );
  }
  let receipt: unknown;
  try {
    receipt = JSON.parse(result.stdout.trim());
  } catch (error) {
    throw new ProviderError(provider, `cmux-tui materialization in ${vmId} returned invalid JSON`, error);
  }
  if (!isMaterializationReceipt(receipt) || receipt.materialization_id !== vmId) {
    throw new ProviderError(provider, `cmux-tui materialization in ${vmId} returned an invalid receipt`);
  }
  return receipt;
}

/**
 * Small orchestration owner used by provider bootstrap paths: materialization
 * must settle before any daemon-start side effect is attempted.
 */
export async function materializeThenStartCmuxTui<T>(
  invoke: CmuxTuiInvoke,
  provider: ProviderId,
  vmId: string,
  start: () => Promise<T>,
  options: Parameters<typeof cmuxTuiMaterializationPlan>[1] = {},
): Promise<{ materialization: CmuxTuiMaterializationReceipt; started: T }> {
  const materialization = await materializeCmuxTuiNewMachine(invoke, provider, vmId, options);
  const started = await start();
  return { materialization, started };
}

function isMaterializationReceipt(value: unknown): value is CmuxTuiMaterializationReceipt {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const record = value as Record<string, unknown>;
  return typeof record.changed === "boolean"
    && typeof record.materialization_id === "string"
    && typeof record.machine_id === "string"
    && typeof record.daemon_fingerprint === "string"
    && (record.enrollment_policy === "fresh" || record.enrollment_policy === "inherit");
}

function shellQuote(value: string): string {
  return `'${value.replaceAll("'", `'"'"'`)}'`;
}

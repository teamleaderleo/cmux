import { randomUUID } from "node:crypto";
import type { CreateOptions, ProviderId } from "./types";

/**
 * Private create-time contract between the Cloud control plane and cmux-tui.
 * The value is an idempotency identity for one newly materialized physical VM;
 * it is deliberately not an authentication secret.
 */
export const CMUX_TUI_MATERIALIZATION_ID_ENV = "CMUX_TUI_MATERIALIZATION_ID";

/** Providers whose new machines run the persistent cmux-tui remote daemon. */
export function providerNeedsCmuxTuiMaterialization(provider: ProviderId): boolean {
  return provider === "e2b" || provider === "daytona";
}

/**
 * Add one reserved new-machine token to provider create env without allowing a
 * caller-supplied value to bypass or replay another materialization.
 *
 * A failed E2B/Daytona create is rolled back by the provider/workflow. A retry
 * that creates another physical VM therefore receives another token, while all
 * daemon restarts inside one sandbox inherit the same token and replay the
 * committed transition as a no-op.
 */
export function withCmuxTuiMaterializationEnv(
  provider: ProviderId,
  options: CreateOptions,
  allocateId: () => string = randomUUID,
): CreateOptions {
  if (!providerNeedsCmuxTuiMaterialization(provider)) return options;
  const materializationId = allocateId();
  if (!materializationId || materializationId.trim() !== materializationId) {
    throw new Error("cmux-tui materialization id allocator returned an invalid id");
  }
  return {
    ...options,
    envs: {
      ...(options.envs ?? {}),
      [CMUX_TUI_MATERIALIZATION_ID_ENV]: materializationId,
    },
  };
}

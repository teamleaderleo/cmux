import { describe, expect, test } from "bun:test";
import {
  CMUX_TUI_MATERIALIZATION_ID_ENV,
  providerNeedsCmuxTuiMaterialization,
  withCmuxTuiMaterializationEnv,
} from "../services/vms/drivers/cmuxTuiMaterialization";
import type { CreateOptions, ProviderId } from "../services/vms/drivers/types";
import { VmProviderGatewayLive } from "../services/vms/providerGateway";

function options(envs: Readonly<Record<string, string>> = {}): CreateOptions {
  return { image: "snapshot-test", envs };
}

describe("cmux-tui new-machine materialization env", () => {
  test("live provider gateway compiles with the materialization create wrapper", () => {
    expect(VmProviderGatewayLive).toBeDefined();
  });

  test("E2B gets a reserved create token without losing caller env", () => {
    const result = withCmuxTuiMaterializationEnv(
      "e2b",
      options({ KEEP: "yes" }),
      () => "materialization-e2b",
    );
    expect(result.envs).toEqual({
      KEEP: "yes",
      [CMUX_TUI_MATERIALIZATION_ID_ENV]: "materialization-e2b",
    });
  });

  test("Daytona gets a create token and caller spoofing cannot override it", () => {
    const result = withCmuxTuiMaterializationEnv(
      "daytona",
      options({
        KEEP: "yes",
        [CMUX_TUI_MATERIALIZATION_ID_ENV]: "caller-controlled",
      }),
      () => "gateway-owned",
    );
    expect(result.envs?.KEEP).toBe("yes");
    expect(result.envs?.[CMUX_TUI_MATERIALIZATION_ID_ENV]).toBe("gateway-owned");
  });

  test("providers outside the modern snapshot-copy path are unchanged", () => {
    for (const provider of ["blaxel", "freestyle"] satisfies ProviderId[]) {
      const original = options({ KEEP: "yes" });
      const result = withCmuxTuiMaterializationEnv(provider, original, () => "unused");
      expect(result).toBe(original);
      expect(result.envs).toEqual({ KEEP: "yes" });
    }
  });

  test("provider predicate matches the intended current scope", () => {
    expect(providerNeedsCmuxTuiMaterialization("e2b")).toBe(true);
    expect(providerNeedsCmuxTuiMaterialization("daytona")).toBe(true);
    expect(providerNeedsCmuxTuiMaterialization("blaxel")).toBe(false);
    expect(providerNeedsCmuxTuiMaterialization("freestyle")).toBe(false);
  });

  test("invalid allocator output fails before provider create", () => {
    expect(() => withCmuxTuiMaterializationEnv("e2b", options(), () => " bad "))
      .toThrow("materialization id allocator returned an invalid id");
  });
});

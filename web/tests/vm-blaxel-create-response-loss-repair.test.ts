import { createHash } from "node:crypto";
import { afterAll, beforeAll, expect, test } from "bun:test";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import postgres, { type Sql } from "postgres";
import { closeCloudDbForTests } from "../db/client";
import {
  VmBillingGateway,
  noOpVmBillingGateway,
} from "../services/vms/billingGateway";
import { BlaxelProvider } from "../services/vms/drivers/blaxel";
import { VmProviderOperationError } from "../services/vms/errors";
import {
  VmProviderGateway,
  type VmProviderGatewayShape,
} from "../services/vms/providerGateway";
import { VmRepositoryLive } from "../services/vms/repository";
import { createVm, listUserVms } from "../services/vms/workflows";

const runDbTests = process.env.CMUX_DB_TEST === "1";
const serialTest = (test as typeof test & { serial: typeof test }).serial;
const dbTest = runDbTests ? serialTest : test.skip;

let sql: Sql | null = null;

function databaseURL() {
  const url = process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL;
  if (!url) throw new Error("DATABASE_URL is required when CMUX_DB_TEST=1");
  return url;
}

function providerLayer(provider: VmProviderGatewayShape) {
  return Layer.mergeAll(
    VmRepositoryLive,
    Layer.succeed(VmProviderGateway, provider),
    Layer.succeed(VmBillingGateway, noOpVmBillingGateway()),
  );
}

function unusedProviderMethods(): Pick<
  VmProviderGatewayShape,
  "exec" | "openAttach" | "openSSH" | "revokeSSHIdentity"
> {
  return {
    exec: () => Effect.fail(new Error("unused") as never),
    openAttach: () => Effect.fail(new Error("unused") as never),
    openSSH: () => Effect.fail(new Error("unused") as never),
    revokeSSHIdentity: () => Effect.void,
  };
}

beforeAll(() => {
  if (!runDbTests) return;
  sql = postgres(databaseURL(), { max: 1 });
});

afterAll(async () => {
  await closeCloudDbForTests();
  await sql?.end();
});

dbTest("same-key retry preserves one provider create identity across an ambiguous first create", async () => {
  if (!sql) throw new Error("test database not initialized");
  await sql`truncate cloud_vm_billing_grants, cloud_vm_usage_events, cloud_vm_leases, cloud_vms restart identity cascade`;

  const providerState = new Set<string>();
  const observedIdentities: string[] = [];
  let createCalls = 0;
  const provider: VmProviderGatewayShape = {
    ...unusedProviderMethods(),
    create: (_provider, options) => {
      createCalls += 1;
      const createIdentity = typeof options.providerMetadata?.createIdentity === "string"
        ? options.providerMetadata.createIdentity
        : "";
      observedIdentities.push(createIdentity);
      const providerVmId = createIdentity
        ? `blaxel-${createIdentity.slice(0, 12)}`
        : createCalls === 1
          ? "blaxel-orphan-a"
          : "blaxel-owned-b";

      if (createCalls === 1) {
        // The provider committed the resource keyed by the create identity, but
        // the VMHandle never crossed back to the workflow.
        providerState.add(providerVmId);
        return Effect.fail(new VmProviderOperationError({
          provider: "blaxel",
          operation: "create",
          cause: new Error("response lost after sandbox commit"),
        }));
      }

      // A provider that receives the same create identity can rediscover/adopt
      // the first effect instead of allocating a different machine.
      providerState.add(providerVmId);
      return Effect.succeed({
        provider: "blaxel" as const,
        providerVmId,
        status: "running" as const,
        image: "blaxel/test-image",
        createdAt: Date.now(),
        providerMetadata: createIdentity ? { createIdentity } : undefined,
      });
    },
    destroy: (_provider, providerVmId) => Effect.sync(() => {
      providerState.delete(providerVmId);
    }),
  };
  const layer = providerLayer(provider);
  const createInput = {
    userId: "fieldwork-blaxel-stable-create-identity",
    billingCustomerType: "team" as const,
    billingTeamId: "fieldwork-blaxel-stable-create-identity-team",
    billingPlanId: "pro",
    maxActiveVms: 10,
    provider: "blaxel" as const,
    image: "blaxel/test-image",
    idempotencyKey: "fieldwork-stable-create-key",
  };

  const firstError = await Effect.runPromise(
    createVm(createInput).pipe(Effect.flip, Effect.provide(layer)),
  );
  expect(firstError).toBeInstanceOf(VmProviderOperationError);
  expect(createCalls).toBe(1);

  const [firstRow] = await sql<{
    providerMetadata: Record<string, unknown> | null;
    providerVmId: string | null;
    failureCode: string | null;
    idempotencyKey: string | null;
  }[]>`
    select
      provider_metadata as "providerMetadata",
      provider_vm_id as "providerVmId",
      failure_code as "failureCode",
      idempotency_key as "idempotencyKey"
    from cloud_vms
    where user_id = ${createInput.userId}
    order by created_at, id
  `;
  expect(firstRow?.providerVmId).toBeNull();
  expect(firstRow?.failureCode).toBe("provider_create_unavailable");
  expect(firstRow?.idempotencyKey).toBe(createInput.idempotencyKey);
  expect(typeof firstRow?.providerMetadata?.createIdentity).toBe("string");
  expect(firstRow?.providerMetadata?.createIdentity).toBe(observedIdentities[0]);
  expect(observedIdentities[0]?.length).toBeGreaterThan(0);

  const retried = await Effect.runPromise(
    createVm(createInput).pipe(Effect.provide(layer)),
  );
  expect(createCalls).toBe(2);
  expect(observedIdentities[1]).toBe(observedIdentities[0]);
  expect(retried.providerVmId).toBe(`blaxel-${observedIdentities[0].slice(0, 12)}`);
  expect([...providerState]).toEqual([retried.providerVmId]);

  const settledVisible = await Effect.runPromise(
    listUserVms(createInput.userId, createInput.billingTeamId).pipe(Effect.provide(layer)),
  );
  expect(settledVisible.map((vm) => vm.providerVmId)).toEqual([retried.providerVmId]);
});

test("Blaxel re-reads the deterministic sandbox before cleaning up an ambiguous create", async () => {
  const previousKey = process.env.BL_API_KEY;
  const previousWorkspace = process.env.BL_WORKSPACE;
  const previousDomain = process.env.CMUX_VM_BLAXEL_CUSTOM_DOMAIN;
  process.env.BL_API_KEY = "test-key";
  process.env.BL_WORKSPACE = "cmux";
  delete process.env.CMUX_VM_BLAXEL_CUSTOM_DOMAIN;

  const originalFetch = globalThis.fetch;
  const calls: Array<{ method: string; url: string }> = [];
  const createIdentity = "fieldwork-response-loss-create-identity";
  const expectedSuffix = createHash("sha256").update(createIdentity).digest("hex").slice(0, 16);
  let machineName = "";

  globalThis.fetch = (async (input: string | URL | Request, init?: RequestInit) => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.toString() : input.url;
    const method = init?.method ?? "GET";
    calls.push({ method, url });
    const respond = (status: number, body?: unknown) =>
      new Response(body === undefined ? "" : JSON.stringify(body), {
        status,
        headers: { "content-type": "application/json" },
      });

    if (method === "POST" && url.endsWith("/volumes")) return respond(200, {});
    if (method === "POST" && url.endsWith("/sandboxes?createIfNotExist=true")) {
      const parsed = JSON.parse(String(init?.body)) as { metadata?: { name?: string } };
      machineName = parsed.metadata?.name ?? "";
      // Remote commit happened. The response path then disappeared.
      throw new TypeError("connection closed after sandbox commit");
    }
    if (method === "GET" && machineName && url.endsWith(`/sandboxes/${machineName}`)) {
      return respond(200, {
        status: "DEPLOYED",
        metadata: { name: machineName, url: "https://sandbox-api.test" },
      });
    }
    // Once the response-lost sandbox has been adopted, force a later bootstrap
    // failure. That keeps this test focused on create reconciliation and lets
    // the existing rollback path clean the test resource afterward.
    if (method === "PUT" && url.startsWith("https://sandbox-api.test/filesystem/")) {
      return respond(500, { error: "stop after adoption" });
    }
    if (method === "GET" && url.includes("/previews/")) return respond(404, {});
    if (method === "POST" && url.includes("/previews")) {
      return respond(200, { spec: { url: "https://preview.test", public: false } });
    }
    if (method === "DELETE" && url.includes("/sandboxes/")) return respond(200, {});
    if (method === "DELETE" && url.includes("/volumes/")) return respond(200, {});
    return respond(500, { error: `unexpected ${method} ${url}` });
  }) as typeof fetch;

  try {
    await expect(
      new BlaxelProvider().create({
        image: "blaxel/base-image:latest",
        providerMetadata: { createIdentity },
        homeVolume: "cmux-home-fieldwork-{machine}",
        memoryMb: 4096,
      }),
    ).rejects.toThrow("stop after adoption");

    expect(machineName).not.toBe("");
    expect(machineName.endsWith(`-${expectedSuffix}`)).toBe(true);
    const createPost = calls.findIndex((call) => call.method === "POST" && call.url.endsWith("/sandboxes?createIfNotExist=true"));
    const recoveryGet = calls.findIndex((call) => call.method === "GET" && call.url.endsWith(`/sandboxes/${machineName}`));
    const volumeDelete = calls.findIndex((call) => call.method === "DELETE" && call.url.endsWith(`/volumes/cmux-home-fieldwork-${machineName}`));
    expect(createPost).toBeGreaterThan(-1);
    expect(recoveryGet).toBeGreaterThan(createPost);
    expect(volumeDelete).toBeGreaterThan(recoveryGet);
  } finally {
    globalThis.fetch = originalFetch;
    if (previousKey === undefined) delete process.env.BL_API_KEY;
    else process.env.BL_API_KEY = previousKey;
    if (previousWorkspace === undefined) delete process.env.BL_WORKSPACE;
    else process.env.BL_WORKSPACE = previousWorkspace;
    if (previousDomain === undefined) delete process.env.CMUX_VM_BLAXEL_CUSTOM_DOMAIN;
    else process.env.CMUX_VM_BLAXEL_CUSTOM_DOMAIN = previousDomain;
  }
});
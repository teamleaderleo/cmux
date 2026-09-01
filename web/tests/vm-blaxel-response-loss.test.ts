import { afterAll, beforeAll, expect, test } from "bun:test";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import postgres, { type Sql } from "postgres";
import { closeCloudDbForTests } from "../db/client";
import {
  VmBillingGateway,
  noOpVmBillingGateway,
} from "../services/vms/billingGateway";
import {
  VmProviderGateway,
  type VmProviderGatewayShape,
} from "../services/vms/providerGateway";
import { VmRepositoryLive } from "../services/vms/repository";
import { VmProviderOperationError } from "../services/vms/errors";
import { createVm, listUserVms } from "../services/vms/workflows";

const runDbTests = process.env.CMUX_DB_TEST === "1";
const serialTest = (test as typeof test & { serial: typeof test }).serial;
const dbTest = runDbTests ? serialTest : test.skip;

let sql: Sql | null = null;

function databaseURL() {
  const url = process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL;
  if (!url) {
    throw new Error("DATABASE_URL is required when CMUX_DB_TEST=1");
  }
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

dbTest("same-key retry must not create B while response-lost Blaxel create A still exists", async () => {
  if (!sql) throw new Error("test database not initialized");
  await sql`truncate cloud_vm_billing_grants, cloud_vm_usage_events, cloud_vm_leases, cloud_vms restart identity cascade`;

  const providerState = new Set<string>();
  let createCalls = 0;
  let destroyCalls = 0;
  const provider: VmProviderGatewayShape = {
    ...unusedProviderMethods(),
    create: () => {
      createCalls += 1;
      if (createCalls === 1) {
        // Model the provider boundary precisely: sandbox A committed remotely,
        // but no VMHandle(A) crossed back to the workflow.
        providerState.add("blaxel-orphan-a");
        return Effect.fail(new VmProviderOperationError({
          provider: "blaxel",
          operation: "create",
          cause: new Error("response lost after sandbox commit"),
        }));
      }
      providerState.add("blaxel-owned-b");
      return Effect.succeed({
        provider: "blaxel" as const,
        providerVmId: "blaxel-owned-b",
        status: "running" as const,
        image: "blaxel/test-image",
        createdAt: Date.now(),
      });
    },
    destroy: (_provider, providerVmId) =>
      Effect.sync(() => {
        destroyCalls += 1;
        providerState.delete(providerVmId);
      }),
  };
  const layer = providerLayer(provider);
  const createInput = {
    userId: "fieldwork-blaxel-response-loss",
    billingCustomerType: "team" as const,
    billingTeamId: "fieldwork-blaxel-response-loss-team",
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
  expect(destroyCalls).toBe(0);
  expect([...providerState]).toEqual(["blaxel-orphan-a"]);

  const firstRows = await sql<{
    status: string;
    providerVmId: string | null;
    failureCode: string | null;
    idempotencyKey: string | null;
  }[]>`
    select
      status,
      provider_vm_id as "providerVmId",
      failure_code as "failureCode",
      idempotency_key as "idempotencyKey"
    from cloud_vms
    where user_id = ${createInput.userId}
    order by created_at, id
  `;
  expect(firstRows).toHaveLength(1);
  expect(firstRows[0]).toMatchObject({
    status: "failed",
    providerVmId: null,
    failureCode: "provider_create_unavailable",
    idempotencyKey: createInput.idempotencyKey,
  });

  const firstVisible = await Effect.runPromise(
    listUserVms(createInput.userId, createInput.billingTeamId).pipe(Effect.provide(layer)),
  );
  expect(firstVisible).toHaveLength(0);

  const retried = await Effect.runPromise(
    createVm(createInput).pipe(Effect.provide(layer)),
  );
  expect(retried.providerVmId).toBe("blaxel-owned-b");
  expect(createCalls).toBe(2);
  expect(destroyCalls).toBe(0);

  const settledRows = await sql<{
    status: string;
    providerVmId: string | null;
    failureCode: string | null;
    idempotencyKey: string | null;
  }[]>`
    select
      status,
      provider_vm_id as "providerVmId",
      failure_code as "failureCode",
      idempotency_key as "idempotencyKey"
    from cloud_vms
    where user_id = ${createInput.userId}
    order by created_at, id
  `;
  expect(settledRows).toHaveLength(2);
  expect(settledRows[0]).toMatchObject({
    status: "failed",
    providerVmId: null,
    failureCode: "provider_create_unavailable",
    idempotencyKey: null,
  });
  expect(settledRows[1]).toMatchObject({
    status: "running",
    providerVmId: "blaxel-owned-b",
    failureCode: null,
    idempotencyKey: createInput.idempotencyKey,
  });

  const settledVisible = await Effect.runPromise(
    listUserVms(createInput.userId, createInput.billingTeamId).pipe(Effect.provide(layer)),
  );
  expect(settledVisible.map((vm) => vm.providerVmId)).toEqual(["blaxel-owned-b"]);
  expect([...providerState].sort()).toEqual(["blaxel-orphan-a", "blaxel-owned-b"]);

  // RED invariant: retrying one durable logical create must not settle with a
  // provider resource that cmux cannot name, reconcile, list, or destroy.
  if (providerState.has("blaxel-orphan-a") && !settledVisible.some((vm) => vm.providerVmId === "blaxel-orphan-a")) {
    throw new Error(
      "same-key retry created B while response-lost provider effect A remained live and unowned",
    );
  }
});

dbTest("same-key retry after a definite pre-effect provider failure creates only one remote machine", async () => {
  if (!sql) throw new Error("test database not initialized");
  await sql`truncate cloud_vm_billing_grants, cloud_vm_usage_events, cloud_vm_leases, cloud_vms restart identity cascade`;

  const providerState = new Set<string>();
  let createCalls = 0;
  const provider: VmProviderGatewayShape = {
    ...unusedProviderMethods(),
    create: () => {
      createCalls += 1;
      if (createCalls === 1) {
        return Effect.fail(new VmProviderOperationError({
          provider: "blaxel",
          operation: "create",
          cause: new Error("provider rejected create before committing a sandbox"),
        }));
      }
      providerState.add("blaxel-owned-b");
      return Effect.succeed({
        provider: "blaxel" as const,
        providerVmId: "blaxel-owned-b",
        status: "running" as const,
        image: "blaxel/test-image",
        createdAt: Date.now(),
      });
    },
    destroy: (_provider, providerVmId) =>
      Effect.sync(() => {
        providerState.delete(providerVmId);
      }),
  };
  const layer = providerLayer(provider);
  const createInput = {
    userId: "fieldwork-blaxel-definite-failure",
    billingCustomerType: "team" as const,
    billingTeamId: "fieldwork-blaxel-definite-failure-team",
    billingPlanId: "pro",
    maxActiveVms: 10,
    provider: "blaxel" as const,
    image: "blaxel/test-image",
    idempotencyKey: "fieldwork-definite-failure-key",
  };

  const firstError = await Effect.runPromise(
    createVm(createInput).pipe(Effect.flip, Effect.provide(layer)),
  );
  expect(firstError).toBeInstanceOf(VmProviderOperationError);
  expect(providerState.size).toBe(0);

  const retried = await Effect.runPromise(
    createVm(createInput).pipe(Effect.provide(layer)),
  );
  expect(retried.providerVmId).toBe("blaxel-owned-b");
  expect(createCalls).toBe(2);
  expect([...providerState]).toEqual(["blaxel-owned-b"]);

  const visible = await Effect.runPromise(
    listUserVms(createInput.userId, createInput.billingTeamId).pipe(Effect.provide(layer)),
  );
  expect(visible.map((vm) => vm.providerVmId)).toEqual(["blaxel-owned-b"]);
});

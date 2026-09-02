import { afterAll, beforeAll, expect, test } from "bun:test";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import postgres, { type Sql } from "postgres";
import { closeCloudDbForTests } from "../db/client";
import {
  VmBillingGateway,
  noOpVmBillingGateway,
  type VmBillingGatewayShape,
} from "../services/vms/billingGateway";
import { VmProviderOperationError } from "../services/vms/errors";
import {
  VmProviderGateway,
  type VmProviderGatewayShape,
} from "../services/vms/providerGateway";
import {
  VmRepository,
  VmRepositoryLive,
} from "../services/vms/repository";
import { createVm } from "../services/vms/workflows";

const runDbTests = process.env.CMUX_DB_TEST === "1";
const serialTest = (test as typeof test & { serial: typeof test }).serial;
const dbTest = runDbTests ? serialTest : test.skip;

let sql: Sql | null = null;

function databaseURL() {
  const url = process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL;
  if (!url) throw new Error("DATABASE_URL is required when CMUX_DB_TEST=1");
  return url;
}

function createInput(idempotencyKey: string) {
  return {
    userId: "fieldwork-blaxel-billing-fence",
    billingCustomerType: "team" as const,
    billingTeamId: "fieldwork-blaxel-billing-fence-team",
    billingPlanId: "pro",
    maxActiveVms: 10,
    provider: "blaxel" as const,
    image: "blaxel/test-image",
    idempotencyKey,
  };
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

function testLayer(provider: VmProviderGatewayShape, billing: VmBillingGatewayShape) {
  return Layer.mergeAll(
    VmRepositoryLive,
    Layer.succeed(VmProviderGateway, provider),
    Layer.succeed(VmBillingGateway, billing),
  );
}

async function insertDurableIntent(input: ReturnType<typeof createInput>) {
  return Effect.runPromise(
    Effect.gen(function* () {
      const repo = yield* VmRepository;
      return yield* repo.beginCreate(input);
    }).pipe(Effect.provide(VmRepositoryLive)),
  );
}

async function ageIntent(id: string) {
  if (!sql) throw new Error("test database not initialized");
  await sql`update cloud_vms set updated_at = now() - interval '12 minutes' where id = ${id}`;
}

beforeAll(() => {
  if (!runDbTests) return;
  sql = postgres(databaseURL(), { max: 1 });
});

afterAll(async () => {
  await closeCloudDbForTests();
  await sql?.end();
});

dbTest("fresh Blaxel create durably fences provider start after billing succeeds", async () => {
  if (!sql) throw new Error("test database not initialized");
  await sql`truncate cloud_vm_billing_grants, cloud_vm_usage_events, cloud_vm_leases, cloud_vms restart identity cascade`;

  const order: string[] = [];
  const billing: VmBillingGatewayShape = {
    ...noOpVmBillingGateway(),
    reserveCreate: () => Effect.sync(() => {
      order.push("billing");
      return { kind: "none" as const };
    }),
  };
  let observedMetadata: Record<string, unknown> | undefined;
  const provider: VmProviderGatewayShape = {
    ...unusedProviderMethods(),
    create: (_provider, options) => Effect.sync(() => {
      order.push("provider");
      observedMetadata = options.providerMetadata;
      expect(options.providerMetadata?.providerCreateReady).toBe(true);
      const identity = options.providerMetadata?.createIdentity;
      expect(typeof identity).toBe("string");
      return {
        provider: "blaxel" as const,
        providerVmId: `blaxel-${String(identity).slice(0, 12)}`,
        status: "running" as const,
        image: "blaxel/test-image",
        createdAt: Date.now(),
        providerMetadata: options.providerMetadata,
      };
    }),
    destroy: () => Effect.void,
  };

  const created = await Effect.runPromise(
    createVm(createInput("fresh-billing-fence")).pipe(Effect.provide(testLayer(provider, billing))),
  );
  expect(created.providerVmId.startsWith("blaxel-")).toBe(true);
  expect(order).toEqual(["billing", "provider"]);
  expect(observedMetadata?.providerCreateReady).toBe(true);

  const rows = await sql<{ providerMetadata: Record<string, unknown> }[]>`
    select provider_metadata as "providerMetadata"
    from cloud_vms
    where provider_vm_id = ${created.providerVmId}
  `;
  expect(rows).toHaveLength(1);
  expect(rows[0]?.providerMetadata.providerCreateReady).toBe(true);
  expect(rows[0]?.providerMetadata.createIdentity).toBe(observedMetadata?.createIdentity);
});

dbTest("stale Blaxel row before durable billing fence never reaches provider", async () => {
  if (!sql) throw new Error("test database not initialized");
  await sql`truncate cloud_vm_billing_grants, cloud_vm_usage_events, cloud_vm_leases, cloud_vms restart identity cascade`;

  const input = createInput("stale-before-billing-fence");
  const intent = await insertDurableIntent(input);
  expect(intent.inserted).toBe(true);
  expect(typeof intent.vm.providerMetadata?.createIdentity).toBe("string");
  expect(intent.vm.providerMetadata?.providerCreateReady).toBeUndefined();
  await ageIntent(intent.vm.id);

  let providerCalls = 0;
  let billingCalls = 0;
  const provider: VmProviderGatewayShape = {
    ...unusedProviderMethods(),
    create: () => Effect.sync(() => {
      providerCalls += 1;
      return {
        provider: "blaxel" as const,
        providerVmId: "should-never-exist",
        status: "running" as const,
        image: input.image,
        createdAt: Date.now(),
      };
    }),
    destroy: () => Effect.void,
  };
  const billing: VmBillingGatewayShape = {
    ...noOpVmBillingGateway(),
    reserveCreate: () => Effect.sync(() => {
      billingCalls += 1;
      return { kind: "none" as const };
    }),
  };

  let failed = false;
  try {
    await Effect.runPromise(createVm(input).pipe(Effect.provide(testLayer(provider, billing))));
  } catch {
    failed = true;
  }
  expect(failed).toBe(true);
  expect(providerCalls).toBe(0);
  // The old request may have died before, during, or just after the external
  // credit decrement. Replaying that debit without a Stack operation identity
  // would be unsafe, so this retry also leaves billing untouched.
  expect(billingCalls).toBe(0);

  const rows = await sql<{ status: string; providerVmId: string | null }[]>`
    select status, provider_vm_id as "providerVmId"
    from cloud_vms
    where id = ${intent.vm.id}
  `;
  expect(rows).toEqual([{ status: "provisioning", providerVmId: null }]);
});

dbTest("indeterminate Blaxel create retains one billing reservation until exact attempt is adopted", async () => {
  if (!sql) throw new Error("test database not initialized");
  await sql`truncate cloud_vm_billing_grants, cloud_vm_usage_events, cloud_vm_leases, cloud_vms restart identity cascade`;

  const input = createInput("indeterminate-create-retains-billing");
  let reserveCalls = 0;
  let refundCalls = 0;
  let providerCalls = 0;
  const providerState = new Map<string, string>();

  const billing: VmBillingGatewayShape = {
    ...noOpVmBillingGateway(),
    reserveCreate: () => Effect.sync(() => {
      reserveCalls += 1;
      return {
        kind: "stack_item" as const,
        itemId: "fieldwork-credit",
        customerType: "team" as const,
        customerId: input.billingTeamId,
        amount: 1,
      };
    }),
    refundCreate: () => Effect.sync(() => {
      refundCalls += 1;
    }),
  };

  const provider: VmProviderGatewayShape = {
    ...unusedProviderMethods(),
    create: (_provider, options) => {
      providerCalls += 1;
      expect(options.providerMetadata?.providerCreateReady).toBe(true);
      const identity = options.providerMetadata?.createIdentity;
      expect(typeof identity).toBe("string");
      const createIdentity = String(identity);
      const existing = providerState.get(createIdentity);
      if (existing) {
        return Effect.succeed({
          provider: "blaxel" as const,
          providerVmId: existing,
          status: "running" as const,
          image: input.image,
          createdAt: Date.now(),
          providerMetadata: options.providerMetadata,
        });
      }

      providerState.set(createIdentity, "blaxel-indeterminate-A");
      const outcomeUnknown = Object.assign(new Error("sandbox POST response lost"), {
        code: "provider_create_indeterminate",
      });
      return Effect.fail(new VmProviderOperationError({
        provider: "blaxel",
        operation: "create",
        cause: outcomeUnknown,
      }));
    },
    destroy: () => Effect.void,
  };

  let firstFailed = false;
  try {
    await Effect.runPromise(createVm(input).pipe(Effect.provide(testLayer(provider, billing))));
  } catch {
    firstFailed = true;
  }
  expect(firstFailed).toBe(true);
  expect(reserveCalls).toBe(1);
  expect(refundCalls).toBe(0);
  expect(providerCalls).toBe(1);
  expect(providerState.size).toBe(1);

  const pendingRows = await sql<{
    id: string;
    status: string;
    providerVmId: string | null;
    providerMetadata: Record<string, unknown>;
  }[]>`
    select id, status, provider_vm_id as "providerVmId", provider_metadata as "providerMetadata"
    from cloud_vms
    where idempotency_key = ${input.idempotencyKey}
  `;
  expect(pendingRows).toHaveLength(1);
  const pending = pendingRows[0]!;
  expect(pending.status).toBe("provisioning");
  expect(pending.providerVmId).toBeNull();
  expect(pending.providerMetadata.providerCreateReady).toBe(true);
  const firstIdentity = pending.providerMetadata.createIdentity;
  expect(typeof firstIdentity).toBe("string");
  await ageIntent(pending.id);

  const recovered = await Effect.runPromise(
    createVm(input).pipe(Effect.provide(testLayer(provider, billing))),
  );
  expect(recovered.providerVmId).toBe("blaxel-indeterminate-A");
  expect(reserveCalls).toBe(1);
  expect(refundCalls).toBe(0);
  expect(providerCalls).toBe(2);
  expect(providerState.size).toBe(1);

  const runningRows = await sql<{
    status: string;
    providerVmId: string | null;
    providerMetadata: Record<string, unknown>;
  }[]>`
    select status, provider_vm_id as "providerVmId", provider_metadata as "providerMetadata"
    from cloud_vms
    where id = ${pending.id}
  `;
  expect(runningRows).toHaveLength(1);
  expect(runningRows[0]?.status).toBe("running");
  expect(runningRows[0]?.providerVmId).toBe("blaxel-indeterminate-A");
  expect(runningRows[0]?.providerMetadata.createIdentity).toBe(firstIdentity);
});

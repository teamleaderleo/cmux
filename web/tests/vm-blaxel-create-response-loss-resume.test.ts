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
import {
  VmRepository,
  VmRepositoryLive,
} from "../services/vms/repository";
import { createVm, destroyVm, listUserVms } from "../services/vms/workflows";

const runDbTests = process.env.CMUX_DB_TEST === "1";
const serialTest = (test as typeof test & { serial: typeof test }).serial;
const dbTest = runDbTests ? serialTest : test.skip;

let sql: Sql | null = null;

function databaseURL() {
  const url = process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL;
  if (!url) throw new Error("DATABASE_URL is required when CMUX_DB_TEST=1");
  return url;
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

function providerLayer(provider: VmProviderGatewayShape) {
  return Layer.mergeAll(
    VmRepositoryLive,
    Layer.succeed(VmProviderGateway, provider),
    Layer.succeed(VmBillingGateway, noOpVmBillingGateway()),
  );
}

function createInput(idempotencyKey: string) {
  return {
    userId: "fieldwork-blaxel-create-resume",
    billingCustomerType: "team" as const,
    billingTeamId: "fieldwork-blaxel-create-resume-team",
    billingPlanId: "pro",
    maxActiveVms: 10,
    provider: "blaxel" as const,
    image: "blaxel/test-image",
    idempotencyKey,
  };
}

async function insertDurableIntent(input: ReturnType<typeof createInput>) {
  return Effect.runPromise(
    Effect.gen(function* () {
      const repo = yield* VmRepository;
      return yield* repo.beginCreate(input);
    }).pipe(Effect.provide(VmRepositoryLive)),
  );
}

function createIdentity(row: { providerMetadata: Record<string, unknown> | null }) {
  const value = row.providerMetadata?.createIdentity;
  if (typeof value !== "string" || !value.trim()) throw new Error("missing durable create identity");
  return value.trim();
}

function externalId(identity: string) {
  return `blaxel-${identity.slice(0, 12)}`;
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

dbTest("restart resumes a stale durable Blaxel intent before any provider effect", async () => {
  if (!sql) throw new Error("test database not initialized");
  await sql`truncate cloud_vm_billing_grants, cloud_vm_usage_events, cloud_vm_leases, cloud_vms restart identity cascade`;

  const input = createInput("restart-before-provider");
  const intent = await insertDurableIntent(input);
  expect(intent.inserted).toBe(true);
  const identity = createIdentity(intent.vm);
  await ageIntent(intent.vm.id);

  const providerState = new Set<string>();
  let createCalls = 0;
  const provider: VmProviderGatewayShape = {
    ...unusedProviderMethods(),
    create: (_provider, options) => Effect.sync(() => {
      createCalls += 1;
      const observed = typeof options.providerMetadata?.createIdentity === "string"
        ? options.providerMetadata.createIdentity.trim()
        : "";
      expect(observed).toBe(identity);
      const providerVmId = externalId(observed);
      providerState.add(providerVmId);
      return {
        provider: "blaxel" as const,
        providerVmId,
        status: "running" as const,
        image: input.image,
        createdAt: Date.now(),
        providerMetadata: { createIdentity: observed },
      };
    }),
    destroy: (_provider, providerVmId) => Effect.sync(() => {
      providerState.delete(providerVmId);
    }),
  };
  const layer = providerLayer(provider);

  const recovered = await Effect.runPromise(createVm(input).pipe(Effect.provide(layer)));
  expect(recovered.providerVmId).toBe(externalId(identity));
  expect(createCalls).toBe(1);
  expect([...providerState]).toEqual([recovered.providerVmId]);

  const rows = await sql<{ id: string; status: string; providerVmId: string | null }[]>`
    select id, status, provider_vm_id as "providerVmId"
    from cloud_vms
    where user_id = ${input.userId}
  `;
  expect(rows).toEqual([{ id: intent.vm.id, status: "running", providerVmId: recovered.providerVmId }]);
});

dbTest("restart adopts the exact committed Blaxel attempt and same-key replay stays single", async () => {
  if (!sql) throw new Error("test database not initialized");
  await sql`truncate cloud_vm_billing_grants, cloud_vm_usage_events, cloud_vm_leases, cloud_vms restart identity cascade`;

  const input = createInput("restart-after-provider-commit");
  const intent = await insertDurableIntent(input);
  expect(intent.inserted).toBe(true);
  const identity = createIdentity(intent.vm);
  const committedA = externalId(identity);
  await ageIntent(intent.vm.id);

  // Independent provider oracle: A already exists even though CMUX still has
  // only the durable attempt identity and no committed provider_vm_id.
  const providerState = new Set<string>([committedA]);
  let createCalls = 0;
  const provider: VmProviderGatewayShape = {
    ...unusedProviderMethods(),
    create: (_provider, options) => Effect.sync(() => {
      createCalls += 1;
      const observed = typeof options.providerMetadata?.createIdentity === "string"
        ? options.providerMetadata.createIdentity.trim()
        : "";
      expect(observed).toBe(identity);
      const providerVmId = externalId(observed);
      // Model Blaxel createIfNotExist: replay returns the already-committed A.
      providerState.add(providerVmId);
      return {
        provider: "blaxel" as const,
        providerVmId,
        status: "running" as const,
        image: input.image,
        createdAt: Date.now(),
        providerMetadata: { createIdentity: observed },
      };
    }),
    destroy: (_provider, providerVmId) => Effect.sync(() => {
      providerState.delete(providerVmId);
    }),
  };
  const layer = providerLayer(provider);

  const recovered = await Effect.runPromise(createVm(input).pipe(Effect.provide(layer)));
  expect(recovered.providerVmId).toBe(committedA);
  expect(createCalls).toBe(1);
  expect([...providerState]).toEqual([committedA]);

  // Crash after provider identity commit but before user-visible success: the
  // next process observes the running row and never calls provider create.
  const repeated = await Effect.runPromise(createVm(input).pipe(Effect.provide(layer)));
  expect(repeated.providerVmId).toBe(committedA);
  expect(createCalls).toBe(1);
  expect([...providerState]).toEqual([committedA]);

  const visible = await Effect.runPromise(
    listUserVms(input.userId, input.billingTeamId).pipe(Effect.provide(layer)),
  );
  expect(visible.map((vm) => vm.providerVmId)).toEqual([committedA]);

  await Effect.runPromise(
    destroyVm({
      userId: input.userId,
      billingTeamId: input.billingTeamId,
      providerVmId: committedA,
    }).pipe(Effect.provide(layer)),
  );
  expect(providerState.size).toBe(0);

  // A genuinely new logical request receives a new durable external identity.
  const freshInput = createInput("genuinely-new-logical-request");
  const fresh = await Effect.runPromise(createVm(freshInput).pipe(Effect.provide(layer)));
  expect(fresh.providerVmId).not.toBe(committedA);
  expect(createCalls).toBe(2);
  expect([...providerState]).toEqual([fresh.providerVmId]);
});

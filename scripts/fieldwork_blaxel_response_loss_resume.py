from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected one match, found {count}")
    return text.replace(old, new, 1)


repo = Path("web/services/vms/repository.ts")
text = repo.read_text()
text = replace_once(
    text,
    '''  readonly beginBaseOpen: (input: {
''',
    '''  readonly claimStaleCreateAttempt?: (input: {
    readonly id: string;
    readonly before: Date;
  }) => Effect.Effect<CloudVmRow | null, VmDatabaseError>;
  readonly beginBaseOpen: (input: {
''',
    "repository resume claim shape",
)
text = replace_once(
    text,
    '''    }),

  beginBaseOpen: (input) =>
''',
    '''    }),

  claimStaleCreateAttempt: (input) =>
    dbEffect("claimStaleCreateAttempt", async () => {
      const db = cloudDb();
      const [vm] = await db
        .update(cloudVms)
        .set({ updatedAt: new Date() })
        .where(and(
          eq(cloudVms.id, input.id),
          eq(cloudVms.status, "provisioning"),
          isNull(cloudVms.providerVmId),
          lt(cloudVms.updatedAt, input.before),
        ))
        .returning();
      return vm ?? null;
    }),

  beginBaseOpen: (input) =>
''',
    "repository resume claim implementation",
)
repo.write_text(text)

workflows = Path("web/services/vms/workflows.ts")
text = workflows.read_text()
text = replace_once(
    text,
    '''const PREVIEW_ENDPOINT_LEASE_TTL_MS = 12 * 60 * 60 * 1000;
''',
    '''const PREVIEW_ENDPOINT_LEASE_TTL_MS = 12 * 60 * 60 * 1000;
// API VM create requests may run for ten minutes. A provisioning row older than
// this has outlived the request that owned it and can be claimed by one retry.
const BLAXEL_CREATE_RESUME_AFTER_MS = 11 * 60 * 1000;
''',
    "resume lease constant",
)
text = replace_once(
    text,
    '''      if (!existing.providerVmId) {
        return yield* Effect.fail(
          new VmCreateInProgressError({ idempotencyKey: input.idempotencyKey ?? "" }),
        );
      }
      return vmEntryFromRow(existing);
''',
    '''      if (!existing.providerVmId) {
        const createIdentity = existing.providerMetadata?.createIdentity;
        if (
          input.provider === "blaxel" &&
          existing.provider === "blaxel" &&
          typeof createIdentity === "string" &&
          createIdentity.trim() &&
          repo.claimStaleCreateAttempt
        ) {
          const claimed = yield* repo.claimStaleCreateAttempt({
            id: existing.id,
            before: new Date(Date.now() - BLAXEL_CREATE_RESUME_AFTER_MS),
          });
          if (claimed) {
            const handle = yield* measureVmEffect(
              input.timing,
              "provider_create_resume",
              providers.create(input.provider, {
                image: input.image,
                providerMetadata: claimed.providerMetadata,
                bakedFreestyleSignedAdmin: input.bakedFreestyleSignedAdmin,
                homeVolume: input.perMachineHome
                  ? homeVolumeTemplateForUser(input.userId)
                  : input.persistentHome
                    ? homeVolumeNameForUser(input.userId)
                    : undefined,
                memoryMb: input.memoryMb,
                envs: input.envs,
              }),
            ).pipe(
              Effect.tapError((err) =>
                repo.recordUsageEvent({
                  userId: input.userId,
                  billingTeamId: input.billingTeamId,
                  billingPlanId: input.billingPlanId,
                  vmId: claimed.id,
                  eventType: "vm.create.reconcile_failed",
                  provider: input.provider,
                  imageId: input.image,
                  metadata: { operation: err.operation, message: errorMessage(err.cause) },
                }).pipe(Effect.catchAll(() => Effect.void)),
              ),
            );

            const running = yield* measureVmEffect(
              input.timing,
              "mark_running_resume",
              repo.markCreateRunning({
                id: claimed.id,
                providerVmId: handle.providerVmId,
                image: handle.image,
                imageVersion: input.imageVersion ?? null,
                providerMetadata: handle.providerMetadata ?? claimed.providerMetadata,
              }),
            ).pipe(
              Effect.catchAll((err) =>
                Effect.gen(function* () {
                  yield* rollbackProviderCreate(providers, input.provider, handle);
                  yield* repo.markCreateFailed({
                    id: claimed.id,
                    code: "database_finalize_failed",
                    message: "Cloud VM state update failed after create recovery.",
                  }).pipe(Effect.catchAll(() => Effect.void));
                  yield* recordCreateFailureEvent(
                    repo,
                    input,
                    claimed,
                    "database_finalize_failed",
                    errorMessage(err.cause),
                  ).pipe(Effect.catchAll(() => Effect.void));
                  return yield* Effect.fail(err);
                }),
              ),
            );
            yield* recordCreateSuccessEvents(repo, input, running);
            return vmEntryFromRow(running);
          }
        }
        return yield* Effect.fail(
          new VmCreateInProgressError({ idempotencyKey: input.idempotencyKey ?? "" }),
        );
      }
      return vmEntryFromRow(existing);
''',
    "workflow stale create resume",
)
workflows.write_text(text)

blaxel = Path("web/services/vms/drivers/blaxel.ts")
text = blaxel.read_text()
text = replace_once(
    text,
    '''          let name = createIdentity ? vmNameForCreateIdentity(createIdentity) : friendlyVmName();
          let homeVolume = resolveHomeVolume(name);
''',
    '''          let name = createIdentity ? vmNameForCreateIdentity(createIdentity) : friendlyVmName();
          const sandboxCreateUrl = createIdentity
            ? `${CONTROL_PLANE_BASE}/sandboxes?createIfNotExist=true`
            : `${CONTROL_PLANE_BASE}/sandboxes`;
          let homeVolume = resolveHomeVolume(name);
''',
    "provider replay-safe create URL",
)
text = replace_once(
    text,
    '''              created = await timedStep("create_sandbox", () => blaxelFetch<BlaxelSandbox>("POST", `${CONTROL_PLANE_BASE}/sandboxes`, {
''',
    '''              created = await timedStep("create_sandbox", () => blaxelFetch<BlaxelSandbox>("POST", sandboxCreateUrl, {
''',
    "provider replay-safe create request",
)
blaxel.write_text(text)

test_file = Path("web/tests/vm-blaxel-create-response-loss-repair.test.ts")
text = test_file.read_text()
text = replace_once(
    text,
    '''    if (method === "POST" && url.endsWith("/sandboxes")) {
''',
    '''    if (method === "POST" && url.endsWith("/sandboxes?createIfNotExist=true")) {
''',
    "driver createIfNotExist fake",
)
text = replace_once(
    text,
    '''    const createPost = calls.findIndex((call) => call.method === "POST" && call.url.endsWith("/sandboxes"));
''',
    '''    const createPost = calls.findIndex((call) => call.method === "POST" && call.url.endsWith("/sandboxes?createIfNotExist=true"));
''',
    "driver createIfNotExist assertion",
)
test_file.write_text(text)

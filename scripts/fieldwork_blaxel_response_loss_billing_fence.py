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
    '''  readonly claimStaleCreateAttempt?: (input: {\n    readonly id: string;\n    readonly before: Date;\n  }) => Effect.Effect<CloudVmRow | null, VmDatabaseError>;\n''',
    '''  readonly markCreateAttemptReady: (id: string) => Effect.Effect<CloudVmRow, VmDatabaseError>;\n  readonly claimStaleCreateAttempt?: (input: {\n    readonly id: string;\n    readonly before: Date;\n  }) => Effect.Effect<CloudVmRow | null, VmDatabaseError>;\n''',
    "repository ready shape",
)
text = replace_once(
    text,
    '''  claimStaleCreateAttempt: (input) =>\n    dbEffect("claimStaleCreateAttempt", async () => {\n''',
    '''  markCreateAttemptReady: (id) =>\n    dbEffect("markCreateAttemptReady", async () => {\n      const db = cloudDb();\n      const [vm] = await db\n        .update(cloudVms)\n        .set({\n          providerMetadata: sql`${cloudVms.providerMetadata} || '{"providerCreateReady":true}'::jsonb`,\n          updatedAt: new Date(),\n        })\n        .where(and(\n          eq(cloudVms.id, id),\n          eq(cloudVms.status, "provisioning"),\n          isNull(cloudVms.providerVmId),\n        ))\n        .returning();\n      if (!vm) throw new Error(`create attempt ${id} is no longer provisioning`);\n      return vm;\n    }),\n\n  claimStaleCreateAttempt: (input) =>\n    dbEffect("claimStaleCreateAttempt", async () => {\n''',
    "repository ready implementation",
)
repo.write_text(text)

workflows = Path("web/services/vms/workflows.ts")
text = workflows.read_text()
text = replace_once(
    text,
    '''          typeof createIdentity === "string" &&\n          createIdentity.trim() &&\n          repo.claimStaleCreateAttempt\n''',
    '''          typeof createIdentity === "string" &&\n          createIdentity.trim() &&\n          existing.providerMetadata?.providerCreateReady === true &&\n          repo.claimStaleCreateAttempt\n''',
    "stale replay fence",
)
text = replace_once(
    text,
    '''    const creditReservation = yield* reserveCreateCredit(billing, repo, input, create.vm);\n    yield* recordCreateRequestedEvents(repo, input, create.vm, creditReservation);\n\n    const handle = yield* measureVmEffect(\n''',
    '''    const creditReservation = yield* reserveCreateCredit(billing, repo, input, create.vm);\n    yield* recordCreateRequestedEvents(repo, input, create.vm, creditReservation);\n\n    // The Stack item decrement has no externally replayable operation identity.\n    // Persist provider permission only after that billing call returned success.\n    // A process that dies before this commit leaves a provider-ineligible row,\n    // so a later retry cannot turn an ambiguous billing outcome into compute.\n    const providerCreateVm = input.provider === "blaxel"\n      ? yield* measureVmEffect(\n          input.timing,\n          "mark_provider_create_ready",\n          repo.markCreateAttemptReady(create.vm.id),\n        )\n      : create.vm;\n\n    const handle = yield* measureVmEffect(\n''',
    "fresh provider-start fence",
)
text = replace_once(
    text,
    '''        providerMetadata: create.vm.providerMetadata,\n''',
    '''        providerMetadata: providerCreateVm.providerMetadata,\n''',
    "fresh provider metadata source",
)
workflows.write_text(text)

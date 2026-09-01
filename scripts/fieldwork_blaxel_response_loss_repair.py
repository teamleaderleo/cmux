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
    'import { and, asc, count, desc, eq, gt, inArray, isNotNull, isNull, lt, ne, or, sql } from "drizzle-orm";\n',
    'import { randomUUID } from "node:crypto";\nimport { and, asc, count, desc, eq, gt, inArray, isNotNull, isNull, lt, ne, or, sql } from "drizzle-orm";\n',
    "repository crypto import",
)
text = replace_once(
    text,
    '''      try: async () => {
        const idempotencyKey = input.idempotencyKey?.trim() || undefined;
        const db = cloudDb();
        try {
''',
    '''      try: async () => {
        const idempotencyKey = input.idempotencyKey?.trim() || undefined;
        let createIdentity = input.provider === "blaxel" ? randomUUID() : undefined;
        const db = cloudDb();
        try {
''',
    "beginCreate identity initialization",
)
text = replace_once(
    text,
    '''              if (existing) {
                if (!isRetryableFailedCreate(existing, new Date())) {
                  return { inserted: false as const, vm: existing };
                }
                await tx
                  .update(cloudVms)
                  .set({ idempotencyKey: null, updatedAt: new Date() })
                  .where(eq(cloudVms.id, existing.id));
              }
''',
    '''              if (existing) {
                if (!isRetryableFailedCreate(existing, new Date())) {
                  return { inserted: false as const, vm: existing };
                }
                if (
                  input.provider === "blaxel" &&
                  existing.provider === "blaxel" &&
                  existing.failureCode === PROVIDER_CREATE_UNAVAILABLE_FAILURE_CODE
                ) {
                  const previousCreateIdentity = existing.providerMetadata?.createIdentity;
                  if (typeof previousCreateIdentity === "string" && previousCreateIdentity.trim()) {
                    createIdentity = previousCreateIdentity.trim();
                  }
                }
                await tx
                  .update(cloudVms)
                  .set({ idempotencyKey: null, updatedAt: new Date() })
                  .where(eq(cloudVms.id, existing.id));
              }
''',
    "retry generation identity transfer",
)
text = replace_once(
    text,
    '''                status: "provisioning",
                idempotencyKey,
              })
''',
    '''                status: "provisioning",
                idempotencyKey,
                ...(createIdentity ? { providerMetadata: { createIdentity } } : {}),
              })
''',
    "create identity persistence",
)
repo.write_text(text)

blaxel = Path("web/services/vms/drivers/blaxel.ts")
text = blaxel.read_text()
text = replace_once(
    text,
    'import { randomBytes } from "node:crypto";\n',
    'import { createHash, randomBytes } from "node:crypto";\n',
    "blaxel crypto import",
)
text = replace_once(
    text,
    '''export function friendlyVmName(withSuffix = false): string {
  const pick = (list: readonly string[]) => list[randomBytes(1)[0] % list.length];
  const base = `${pick(NAME_ADJECTIVES)}-${pick(NAME_ANIMALS)}`;
  if (!withSuffix) return base;
  const alphabet = "abcdefghijklmnopqrstuvwxyz0123456789";
  const suffix = Array.from(randomBytes(4), (byte) => alphabet[byte % alphabet.length]).join("");
  return `${base}-${suffix}`;
}
''',
    '''export function friendlyVmName(withSuffix = false): string {
  const pick = (list: readonly string[]) => list[randomBytes(1)[0] % list.length];
  const base = `${pick(NAME_ADJECTIVES)}-${pick(NAME_ANIMALS)}`;
  if (!withSuffix) return base;
  const alphabet = "abcdefghijklmnopqrstuvwxyz0123456789";
  const suffix = Array.from(randomBytes(4), (byte) => alphabet[byte % alphabet.length]).join("");
  return `${base}-${suffix}`;
}

function vmNameForCreateIdentity(createIdentity: string): string {
  const digest = createHash("sha256").update(createIdentity).digest();
  const adjective = NAME_ADJECTIVES[digest[0] % NAME_ADJECTIVES.length];
  const animal = NAME_ANIMALS[digest[1] % NAME_ANIMALS.length];
  const suffix = digest.toString("hex").slice(0, 16);
  return `${adjective}-${animal}-${suffix}`;
}

function ambiguousSandboxCreateFailure(error: unknown): boolean {
  if (!(error instanceof ProviderError)) return true;
  const statusMatch = /-> (\\d{3})/.exec(error.message);
  if (!statusMatch) return true;
  const status = Number(statusMatch[1]);
  return status === 408 || status === 409 || status === 425 || status === 429 || status >= 500;
}
''',
    "deterministic create identity helpers",
)
text = replace_once(
    text,
    '''          const resolveHomeVolume = (machineName: string): string | undefined =>
            homeVolumeSpec?.replace("{machine}", machineName);
          let name = friendlyVmName();
          let homeVolume = resolveHomeVolume(name);
''',
    '''          const resolveHomeVolume = (machineName: string): string | undefined =>
            homeVolumeSpec?.replace("{machine}", machineName);
          const createIdentity = typeof options.providerMetadata?.createIdentity === "string"
            ? options.providerMetadata.createIdentity.trim() || undefined
            : undefined;
          let name = createIdentity ? vmNameForCreateIdentity(createIdentity) : friendlyVmName();
          let homeVolume = resolveHomeVolume(name);
''',
    "deterministic create name selection",
)
text = replace_once(
    text,
    '''            } catch (err) {
              // A per-machine volume this call just created for a sandbox that never
              // came to exist is already orphaned — a retried create picks a fresh
              // name, so nothing ever reattaches it. Delete it before moving on. A
              // pre-existing volume (409 on ensure) is left alone: it may belong to
              // the live sandbox this name conflicted with.
              if (homeVolume && perMachineHomeVolume && volumeCreated) {
                const volume = homeVolume;
                await this.deleteHomeVolume(volume).catch((cleanupErr) => {
                  console.error(`[blaxel] create cleanup failed; volume ${volume} may be orphaned`, cleanupErr);
                });
              }
              const conflict = err instanceof ProviderError && /-> 409/.test(err.message);
              if (!conflict || attempt === 3) throw err;
              name = friendlyVmName(attempt >= 1);
              homeVolume = resolveHomeVolume(name);
            }
''',
    '''            } catch (err) {
              if (createIdentity && ambiguousSandboxCreateFailure(err)) {
                try {
                  const recovered = await timedStep("recover_ambiguous_create", () => this.getSandbox(name));
                  const recoveredName = recovered.metadata?.name?.trim();
                  if (recoveredName && recoveredName !== name) {
                    throw new ProviderError(
                      "blaxel",
                      `recovered sandbox identity mismatch: expected ${name}, got ${recoveredName}`,
                    );
                  }
                  const recoveredImage = recovered.spec?.runtime?.image?.trim();
                  if (recoveredImage && recoveredImage !== image) {
                    throw new ProviderError(
                      "blaxel",
                      `recovered sandbox ${name} uses unexpected image ${recoveredImage}`,
                    );
                  }
                  created = recovered;
                  break;
                } catch (recoveryErr) {
                  // A failed or stale read is not proof that the POST had no effect.
                  // Preserve any just-created per-machine volume; the same-key retry
                  // reuses this create identity, sandbox name, and volume name.
                  if (!(recoveryErr instanceof ProviderError && /-> 404/.test(recoveryErr.message))) {
                    console.warn(`[blaxel] ambiguous create recovery for ${name} failed`, recoveryErr);
                  }
                  throw err;
                }
              }

              // For a definite failed create, a per-machine volume made by this call
              // has no owner and can be removed. Ambiguous deterministic creates exit
              // above without cleanup so a committed-but-unobserved sandbox keeps its
              // durable home intact.
              if (homeVolume && perMachineHomeVolume && volumeCreated) {
                const volume = homeVolume;
                await this.deleteHomeVolume(volume).catch((cleanupErr) => {
                  console.error(`[blaxel] create cleanup failed; volume ${volume} may be orphaned`, cleanupErr);
                });
              }
              const conflict = err instanceof ProviderError && /-> 409/.test(err.message);
              if (createIdentity || !conflict || attempt === 3) throw err;
              name = friendlyVmName(attempt >= 1);
              homeVolume = resolveHomeVolume(name);
            }
''',
    "ambiguous create recovery",
)
text = replace_once(
    text,
    '''            providerMetadata: homeVolume
              ? {
                  sandboxUrl,
                  previewUrl,
                  homeVolume,
''',
    '''            providerMetadata: homeVolume
              ? {
                  ...(options.providerMetadata ?? {}),
                  sandboxUrl,
                  previewUrl,
                  homeVolume,
''',
    "preserve metadata with home volume",
)
text = replace_once(
    text,
    '''              : { sandboxUrl, previewUrl, image, memoryMb },
''',
    '''              : { ...(options.providerMetadata ?? {}), sandboxUrl, previewUrl, image, memoryMb },
''',
    "preserve metadata without home volume",
)
blaxel.write_text(text)

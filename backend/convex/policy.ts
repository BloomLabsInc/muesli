export function bloomEmail(value: unknown): string {
  if (
    typeof value !== "string" ||
    !/^[a-z0-9.!#$%&'*+/=?^_`{|}~-]+@bloom\.diy$/i.test(value.trim())
  )
    throw new Error("Use your @bloom.diy email address.");
  return value.trim().toLowerCase();
}
export function requireVerifiedBloom(
  user: { email?: string; emailVerificationTime?: number } | null,
) {
  if (!user || user.emailVerificationTime === undefined)
    throw new Error("Verified Bloom account required");
  return bloomEmail(user.email);
}

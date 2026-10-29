export function redactSecrets(text: string, secrets: readonly string[]): string {
  let output = text;
  const unique = [...new Set(secrets.filter((secret) => secret.length >= 4))].sort((a, b) => b.length - a.length);
  for (const secret of unique) {
    output = output.split(secret).join("••••");
  }
  return output;
}

# Security notes

Moved verbatim from `AGENTS.md` in the P3 trim.

## Security Notes

- Tokens stored as bcrypt digests or SHA256 hashes - never plaintext
- PKCE required for public OAuth clients
- Redirect URIs validated against whitelist
- All security events published for audit trail
- Session expiry enforced on every request
- Account locking/status changes revoke all sessions
- Social linking (0.44+): `(provider, sub)` first; email linking needs a provider-verified email. `Providers::Base.trusted_for_linking?` (0.45, default `false`) may only be `true` for an org-owned IdP, and still needs a verified provider email AND a verified existing identifier.
- `config.login_method_policy` (0.45) runs after the credential is proven and before any session/token, on every path listed in `StandardId::LoginMethodPolicy`, including `refresh_token` (re-checked with the original sign-in method from `StandardId::AuthLineage`). A new session-creating path must be added there and to `spec/requests/standard_id/login_method_policy_paths_spec.rb` (the spec fails on unclassified call sites and token grants).
- One-time codes are stored as `CodeChallenge#code_digest` (HMAC-SHA256 under `secret_key_base`, `CODE_DIGEST_PREFIX`); the raw code lives only on the in-memory record the issuing path publishes. `code` is a legacy plaintext column read only for rows without a digest. Never persist, log or serialise the raw code.
- Keyed digests (session `lookup_hash` / HMAC `token_digest`, code digests, authorization codes, registration access tokens) go through `StandardId::KeyedDigest`: write under the current secret, read under it plus `config.previous_secret_key_bases`. A new keyed digest should do the same, and look up every candidate in one indexed query. HMAC-signed JWTs follow the same rule: `JwtService.encode` signs under the current secret, `decode` verifies under `JwtService.symmetric_verification_keys` (current, then previous); asymmetric keys rotate via `oauth.previous_signing_keys` only.

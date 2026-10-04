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
- `config.login_method_policy` (0.45) runs after the credential is proven and before any session/token, on every path listed in `StandardId::LoginMethodPolicy`. A new session-creating path must be added there and to `spec/requests/standard_id/login_method_policy_paths_spec.rb` (the spec fails on unclassified call sites and token grants).

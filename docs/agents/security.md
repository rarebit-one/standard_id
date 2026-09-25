# Security notes

Moved verbatim from `AGENTS.md` in the P3 trim.

## Security Notes

- Tokens stored as bcrypt digests or SHA256 hashes - never plaintext
- PKCE required for public OAuth clients
- Redirect URIs validated against whitelist
- All security events published for audit trail
- Session expiry enforced on every request
- Account locking/status changes revoke all sessions

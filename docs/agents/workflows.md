# Common workflows

Moved verbatim from `AGENTS.md` in the P3 trim, with the two spec paths corrected to where the specs actually live.

## Common Workflows

### Adding an OAuth Flow

1. Create `lib/standard_id/oauth/my_flow.rb` inheriting from base flow
2. Define `expect_params` and `permit_params`
3. Implement authentication logic
4. Emit events via `StandardId::Events.publish`
5. Add tests in `spec/lib/standard_id/oauth/` (or `spec/lib/standard_id/<flow>_spec.rb`)

### Adding a Social Provider

1. Create `lib/standard_id/providers/my_provider.rb` inheriting from `Base`
2. Implement: `provider_name`, `authorization_url`, `get_user_info`, `config_schema`
3. Register: `StandardId::ProviderRegistry.register(:my_provider, MyProvider)`
4. Add tests in `spec/lib/standard_id/providers/`

### Adding Controller Actions

1. Add route in `config/routes/{web,api}.rb`
2. Create controller in `app/controllers/standard_id/{web,api}/`
3. Inherit from `StandardId::Web::BaseController` or `StandardId::Api::BaseController`
4. Emit events for audit trail

module StandardId
  module SocialAuthentication
    extend ActiveSupport::Concern

    included do
      prepend_before_action :prepare_provider
    end

    private

    attr_reader :provider

    def prepare_provider
      @provider = StandardId::ProviderRegistry.get(params[:provider])
    rescue StandardId::ProviderRegistry::ProviderNotFoundError => e
      raise StandardId::InvalidRequestError, e.message
    end

    def get_user_info_from_provider(redirect_uri: nil, flow: :web)
      provider_params = {
        code: params[:code],
        id_token: params[:id_token],
        access_token: params[:access_token],
        redirect_uri: redirect_uri
      }

      resolved_params = provider.resolve_params(provider_params, context: { flow: flow })
      provider.get_user_info(**resolved_params.compact)
    end

    def find_or_create_account_from_social(raw_social_info)
      social_info = raw_social_info.to_h.with_indifferent_access
      email = social_info[:email]
      raise StandardId::InvalidRequestError, "No email provided by #{provider.provider_name}" if email.blank?

      emit_social_user_info_fetched(provider, social_info, email)

      identifier = StandardId::EmailIdentifier.find_by(value: email)

      if identifier.present?
        emit_social_account_linked(identifier.account, provider, identifier)
        identifier.account
      else
        account = build_account_from_social(social_info)
        identifier = StandardId::EmailIdentifier.create!(
          account: account,
          value: email
        )
        identifier.verify! if identifier.respond_to?(:verify!)
        emit_social_account_created(account, provider, social_info)
        account
      end
    end

    def build_account_from_social(social_info)
      emit_account_creating_from_social(social_info)
      attrs = resolve_account_attributes(social_info)
      account = StandardId.account_class.create!(attrs)
      emit_account_created_from_social(account)
      account
    end

    def resolve_account_attributes(social_info)
      resolver = StandardId.config.social_account_attributes
      attrs = if resolver.respond_to?(:call)
                payload = {
                  social_info: social_info,
                  provider: provider.provider_name
                }

                filtered_payload = StandardId::Utils::CallableParameterFilter.filter(resolver, payload)
                resolver.call(**filtered_payload)
      else
                {
                  email: social_info[:email],
                  name: social_info[:name].presence || social_info[:given_name].presence || social_info[:email]
                }
      end

      unless attrs.is_a?(Hash)
        raise StandardId::InvalidRequestError, "Social account attribute resolver must return a hash"
      end

      attrs.symbolize_keys
    end

    def allow_other_host_redirect?(redirect_uri)
      return false if redirect_uri.blank?

      allowed = Array(StandardId.config.allowed_redirect_url_prefixes)
      return false if allowed.blank?

      allowed.any? do |entry|
        case entry
        when Regexp
          entry.match?(redirect_uri)
        else
          redirect_uri.start_with?(entry.to_s)
        end
      end
    end

    def run_social_callback(provider:, social_info:, provider_tokens:, account:)
      emit_social_auth_completed(provider, social_info, provider_tokens, account)
    end

    def emit_social_user_info_fetched(provider, social_info, email)
      StandardId::Events.publish(
        StandardId::Events::SOCIAL_USER_INFO_FETCHED,
        provider: provider,
        social_info: social_info,
        email: email
      )
    end

    def emit_social_account_created(account, provider, social_info)
      StandardId::Events.publish(
        StandardId::Events::SOCIAL_ACCOUNT_CREATED,
        account: account,
        provider: provider,
        social_info: social_info
      )
    end

    def emit_social_account_linked(account, provider, identifier)
      StandardId::Events.publish(
        StandardId::Events::SOCIAL_ACCOUNT_LINKED,
        account: account,
        provider: provider,
        identifier: identifier
      )
    end

    def emit_social_auth_completed(provider, social_info, provider_tokens, account)
      StandardId::Events.publish(
        StandardId::Events::SOCIAL_AUTH_COMPLETED,
        account: account,
        provider: provider,
        social_info: social_info,
        tokens: provider_tokens
      )
    end

    def emit_account_creating_from_social(social_info)
      StandardId::Events.publish(
        StandardId::Events::ACCOUNT_CREATING,
        account_params: resolve_account_attributes(social_info),
        auth_method: "social:#{provider.provider_name}"
      )
    end

    def emit_account_created_from_social(account)
      StandardId::Events.publish(
        StandardId::Events::ACCOUNT_CREATED,
        account: account,
        auth_method: "social:#{provider.provider_name}",
        source: "social"
      )
    end
  end
end

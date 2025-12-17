module StandardId
  module SocialAuthentication
    extend ActiveSupport::Concern

    private

    def get_user_info_from_provider(connection, redirect_uri: nil, flow: :web)
      case connection
      when "google"
        StandardId::SocialProviders::Google.get_user_info(
          code: params[:code],
          id_token: params[:id_token],
          access_token: params[:access_token],
          redirect_uri: redirect_uri
        )
      when "apple"
        StandardId::SocialProviders::Apple.get_user_info(
        code: params[:code],
          id_token: params[:id_token],
          redirect_uri: redirect_uri,
          client_id: apple_client_id_for_flow(flow)
        )
      else
        raise StandardId::InvalidRequestError, "Unsupported provider: #{connection}"
      end
    end

    def apple_client_id_for_flow(flow)
      flow == :web ? StandardId.config.apple_client_id : StandardId.config.apple_mobile_client_id
    end

    def find_or_create_account_from_social(raw_social_info, provider)
      social_info = raw_social_info.to_h.with_indifferent_access
      email = social_info[:email]
      raise StandardId::InvalidRequestError, "No email provided by #{provider}" if email.blank?

      emit_social_user_info_fetched(provider, social_info, email)

      identifier = StandardId::EmailIdentifier.find_by(value: email)

      if identifier.present?
        emit_social_account_linked(identifier.account, provider, identifier)
        identifier.account
      else
        account = build_account_from_social(social_info, provider)
        identifier = StandardId::EmailIdentifier.create!(
          account: account,
          value: email
        )
        identifier.verify! if identifier.respond_to?(:verify!)
        emit_social_account_created(account, provider, social_info)
        account
      end
    end

    def build_account_from_social(social_info, provider)
      emit_account_creating_from_social(social_info, provider)
      attrs = resolve_account_attributes(social_info, provider)
      account = StandardId.account_class.create!(attrs)
      emit_account_created_from_social(account, provider)
      account
    end

    def resolve_account_attributes(social_info, provider)
      resolver = StandardId.config.social_account_attributes
      attrs = if resolver.respond_to?(:call)
                payload = {
                  social_info: social_info,
                  provider: provider
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

    def emit_account_creating_from_social(social_info, provider)
      StandardId::Events.publish(
        StandardId::Events::ACCOUNT_CREATING,
        account_params: resolve_account_attributes(social_info, provider),
        auth_method: "social:#{provider}"
      )
    end

    def emit_account_created_from_social(account, provider)
      StandardId::Events.publish(
        StandardId::Events::ACCOUNT_CREATED,
        account: account,
        auth_method: "social:#{provider}",
        source: "social"
      )
    end
  end
end

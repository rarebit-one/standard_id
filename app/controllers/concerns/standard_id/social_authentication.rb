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

      identifier = StandardId::EmailIdentifier.find_by(value: email)

      if identifier.present?
        identifier.account
      else
        account = build_account_from_social(social_info, provider)
        identifier = StandardId::EmailIdentifier.create!(
          account: account,
          value: email
        )
        identifier.verify! if identifier.respond_to?(:verify!)
        account
      end
    end

    def build_account_from_social(social_info, provider)
      attrs = resolve_account_attributes(social_info, provider)
      StandardId.account_class.create!(attrs)
    end

    def resolve_account_attributes(social_info, provider)
      resolver = StandardId.config.social_account_attributes
      attrs = if resolver.respond_to?(:call)
                resolver.call(social_info: social_info, provider: provider)
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
      callback = StandardId.config.social_callback

      payload = {
        provider: provider,
        social_info: social_info,
        tokens: provider_tokens.presence,
        account: account
      }

      filtered_payload = StandardId::Utils::CallableParameterFilter.filter(callback, payload)
      callback.call(**filtered_payload.symbolize_keys)
    end
  end
end

module StandardId
  module Api
    class UserinfoController < BaseController
      authenticated_controller

      skip_before_action :validate_content_type!
      before_action :verify_access_token!
      endpoint_audiences :userinfo

      def show
        account = current_account
        raise StandardId::NotAuthenticatedError unless account

        render json: build_userinfo_response(account), status: :ok
      end

      private

      # OIDC userinfo claims other than `sub` are optional: a claim whose
      # attribute the host's account model doesn't define is omitted, not
      # sent as null and not a NoMethodError.
      def build_userinfo_response(account)
        email = optional_attribute(account, :email)

        {
          sub: account_sub(account),
          name: optional_attribute(account, :name),
          email: email,
          email_verified: email.present? ? email_verified?(email) : nil,
          updated_at: optional_attribute(account, :updated_at)&.to_i
        }.compact
      end

      def optional_attribute(account, attribute)
        account.public_send(attribute) if account.respond_to?(attribute)
      end

      def account_sub(account)
        account.id.to_s
      end

      def email_verified?(email)
        identifier = StandardId::EmailIdentifier.find_by(value: email)
        identifier&.verified_at.present?
      end
    end
  end
end

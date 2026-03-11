module StandardId
  module Api
    class UserinfoController < BaseController
      authenticated_controller

      skip_before_action :validate_content_type!

      def show
        verify_access_token!
        account = current_account
        raise StandardId::NotAuthenticatedError unless account

        render json: build_userinfo_response(account), status: :ok
      end

      private

      def build_userinfo_response(account)
        {
          sub: account_sub(account),
          name: account.name,
          email: account.email,
          email_verified: email_verified?(account),
          updated_at: account.respond_to?(:updated_at) ? account.updated_at&.to_i : nil
        }.compact
      end

      def account_sub(account)
        account.id.to_s
      end

      def email_verified?(account)
        identifier = StandardId::EmailIdentifier.find_by(value: account.email)
        identifier&.verified_at.present?
      end
    end
  end
end

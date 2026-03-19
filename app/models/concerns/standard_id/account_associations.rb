module StandardId
  module AccountAssociations
    extend ActiveSupport::Concern

    included do
      has_many :identifiers, class_name: "StandardId::Identifier", dependent: :restrict_with_exception
      has_many :credentials, class_name: "StandardId::Credential", through: :identifiers, source: :credentials, dependent: :restrict_with_exception
      has_many :sessions, class_name: "StandardId::Session", dependent: :restrict_with_exception
      has_many :client_applications, class_name: "StandardId::ClientApplication", as: :owner, dependent: :restrict_with_exception

      accepts_nested_attributes_for :identifiers
    end

    class_methods do
      def find_or_create_by_verified_email!(email, **account_attributes)
        normalized_email = email.to_s.strip.downcase

        identifier = StandardId::EmailIdentifier.includes(:account).find_by(value: normalized_email)
        return identifier.account if identifier.present?

        StandardId::Events.publish(
          StandardId::Events::ACCOUNT_CREATING,
          email: normalized_email,
          source: "find_or_create_by_verified_email"
        )

        account = create!(
          **account_attributes,
          identifiers_attributes: [
            { type: "StandardId::EmailIdentifier", value: normalized_email, verified_at: Time.current }
          ]
        )

        StandardId::Events.publish(
          StandardId::Events::ACCOUNT_CREATED,
          account: account,
          email: normalized_email,
          source: "find_or_create_by_verified_email"
        )

        account
      rescue ActiveRecord::RecordNotUnique
        identifier = StandardId::EmailIdentifier.includes(:account).find_by!(value: normalized_email)
        identifier.account
      end
    end
  end
end

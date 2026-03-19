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
        raise ArgumentError, "email is required" if email.blank?

        normalized_email = email.to_s.strip.downcase

        identifier = StandardId::EmailIdentifier.includes(:account).find_by(value: normalized_email)
        return identifier.account if identifier.present?

        # Best-effort intent signal: fires before create! so there will be no
        # matching ACCOUNT_CREATED event if create! raises (e.g. validation error).
        StandardId::Events.publish(
          StandardId::Events::ACCOUNT_CREATING,
          email: normalized_email,
          source: "find_or_create_by_verified_email"
        )

        merged_attributes = account_attributes.dup
        merged_attributes[:email] = normalized_email if column_names.include?("email") && !merged_attributes.key?(:email)

        account = create!(
          **merged_attributes,
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

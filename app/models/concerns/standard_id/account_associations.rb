module StandardId
  module AccountAssociations
    extend ActiveSupport::Concern

    included do
      has_many :identifiers, class_name: "StandardId::Identifier", dependent: :restrict_with_exception
      has_many :credentials, class_name: "StandardId::Credential", through: :identifiers, source: :credentials, dependent: :restrict_with_exception
      has_many :sessions, class_name: "StandardId::Session", dependent: :restrict_with_exception
      has_many :refresh_tokens, class_name: "StandardId::RefreshToken", dependent: :restrict_with_exception
      has_many :client_applications, class_name: "StandardId::ClientApplication", as: :owner, dependent: :restrict_with_exception

      accepts_nested_attributes_for :identifiers
    end

    # Returns the account's StandardId::EmailIdentifier, if any.
    #
    # Uses the in-memory collection when identifiers is already loaded to
    # avoid issuing an extra query (N+1 safety). Falls back to a scoped
    # query otherwise.
    #
    # @return [StandardId::EmailIdentifier, nil]
    def email_identifier
      typed_identifier(StandardId::EmailIdentifier)
    end

    # Returns the account's StandardId::PhoneNumberIdentifier, if any.
    #
    # @return [StandardId::PhoneNumberIdentifier, nil]
    def phone_number_identifier
      typed_identifier(StandardId::PhoneNumberIdentifier)
    end

    # Returns the account's StandardId::UsernameIdentifier, if any.
    #
    # @return [StandardId::UsernameIdentifier, nil]
    def username_identifier
      typed_identifier(StandardId::UsernameIdentifier)
    end

    class_methods do
      def find_or_create_by_verified_email!(email, **account_attributes)
        raise ArgumentError, "email is required" if email.blank?

        normalized_email = email.to_s.strip.downcase

        identifier = StandardId::EmailIdentifier.includes(:account).find_by(value: normalized_email)
        return identifier.account if identifier.present?

        # Best-effort intent signal — fires before create! so subscribers may see
        # ACCOUNT_CREATING without a matching ACCOUNT_CREATED if create! raises.
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
        identifier = StandardId::EmailIdentifier.includes(:account).find_by(value: normalized_email)
        raise unless identifier

        identifier.account
      end
    end

    private

    # Fetch the first identifier of the given STI subclass.
    #
    # When the identifiers association is already loaded, filters in memory
    # to avoid triggering an additional query. Otherwise issues a scoped
    # query that returns at most one row.
    #
    # @param klass [Class] subclass of StandardId::Identifier
    # @return [StandardId::Identifier, nil]
    def typed_identifier(klass)
      if association(:identifiers).loaded?
        identifiers.detect { |i| i.is_a?(klass) }
      else
        identifiers.where(type: klass.sti_name).first
      end
    end
  end
end

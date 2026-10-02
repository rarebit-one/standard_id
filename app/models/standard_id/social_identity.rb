module StandardId
  # A social provider's stable subject id (`sub`) linked to an account.
  #
  # Written by StandardId::SocialAuthentication when a social login creates an
  # account, or links to an existing email identifier on a provider-verified
  # email. Later logins with the same (provider, subject) resolve to the same
  # account, whatever email the provider then reports.
  #
  # `identifier` is the email identifier the link was made through. A different
  # subject from the same provider for that identifier is refused.
  class SocialIdentity < ApplicationRecord
    self.table_name = "standard_id_social_identities"

    belongs_to :account, class_name: StandardId.config.account_class_name
    belongs_to :identifier, class_name: "StandardId::Identifier"

    validates :provider, presence: true
    validates :subject, presence: true, uniqueness: { scope: :provider }
    validates :identifier_id, uniqueness: { scope: :provider }

    # Hosts that upgraded the gem but have not run
    # 20261002000000_create_standard_id_social_identities yet. Cached by the
    # schema cache, so this is one lookup per process.
    def self.available?
      table_exists?
    rescue ActiveRecord::ActiveRecordError
      false
    end
  end
end

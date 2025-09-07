module StandardId
  class EmailIdentifier < Identifier
    normalizes :value, with: ->(e) { e.strip.downcase }

    validates :value, format: { with: URI::MailTo::EMAIL_REGEXP }
  end
end

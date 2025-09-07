module StandardId
  class PhoneNumberIdentifier < Identifier
    normalizes :value, with: ->(p) { p.strip }

    validates :value, format: { with: /\A\+?[1-9]\d{1,14}\z/ }
  end
end

module StandardId
  class UsernameIdentifier < Identifier
    normalizes :value, with: ->(u) { u.strip }

    validates :value, format: { with: /\A[a-zA-Z0-9_]+\z/ }
  end
end

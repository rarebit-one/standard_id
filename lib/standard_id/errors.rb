module StandardId
  class NotAuthenticatedError < StandardError; end
  class InvalidsessionError < StandardError; end
  class ExpiredSessionError < InvalidsessionError; end
  class RevokedSessionError < InvalidsessionError; end
end

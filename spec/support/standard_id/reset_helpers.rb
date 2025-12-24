module StandardIdResetHelpers
  def reset_standard_id_cache_store!
    StandardId.singleton_class.send(:remove_const, :CACHE_STORE)
    StandardId.singleton_class.const_set(:CACHE_STORE, Concurrent::Delay.new { StandardId.config.cache_store || Rails.cache })
  end

  def reset_standard_id_logger!
    StandardId.singleton_class.send(:remove_const, :LOGGER)
    StandardId.singleton_class.const_set(:LOGGER, Concurrent::Delay.new { StandardId.config.logger || Rails.logger })
  end

  def reset_jwt_session_class!
    StandardId::JwtService.send(:remove_const, :SESSION_CLASS)
    StandardId::JwtService.const_set(:SESSION_CLASS, Concurrent::Delay.new do
      Struct.new(*(StandardId::JwtService::BASE_SESSION_FIELDS + StandardId::JwtService.send(:claim_resolver_keys)), keyword_init: true) do
        def active?
          true
        end
      end
    end)
  end
end

RSpec.configure do |config|
  config.include StandardIdResetHelpers
end

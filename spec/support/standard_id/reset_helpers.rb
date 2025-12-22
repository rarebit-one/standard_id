module StandardIdResetHelpers
  def reset_standard_id_cache_store!
    StandardId.instance_variable_set(:@cache_store_delay, nil)
  end

  def reset_standard_id_logger!
    StandardId.instance_variable_set(:@logger_delay, nil)
  end
end

RSpec.configure do |config|
  config.include StandardIdResetHelpers
end

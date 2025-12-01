module StandardId
  class DeviceSession < Session
    validates :device_id, presence: true
    validates :device_agent, presence: true

    def self.expiry
      StandardId.config.session.device_session_lifetime.seconds.from_now
    end

    def device_info
      return {} if device_agent.blank?

      # Simple device agent parsing
      case device_agent
      when /iOS/i
        { platform: "iOS", type: "mobile" }
      when /Android/i
        { platform: "Android", type: "mobile" }
      when /Windows/i
        { platform: "Windows", type: "desktop" }
      when /Mac/i
        { platform: "macOS", type: "desktop" }
      when /Linux/i
        { platform: "Linux", type: "desktop" }
      else
        { platform: "Unknown", type: "unknown" }
      end
    end

    def display_name
      "#{device_info[:platform]} Device Session"
    end

    def refresh!
      update!(last_refreshed_at: Time.current)
    end

    def stale?
      last_refreshed_at.nil? || last_refreshed_at < 1.hour.ago
    end
  end
end

module StandardId
  class BrowserSession < Session
    validates :user_agent, presence: true

    def self.expiry
      StandardId.config.session.browser_session_lifetime.seconds.from_now
    end

    def self.remember_me_expiry
      StandardId.config.session.browser_session_remember_me_lifetime.seconds.from_now
    end

    def browser_info
      return {} if user_agent.blank?

      # Simple user agent parsing - in production you might want to use a gem like browser
      case user_agent
      when /Edge/i
        { browser: "Edge", type: "browser" }
      when /Chrome/i
        { browser: "Chrome", type: "browser" }
      when /Firefox/i
        { browser: "Firefox", type: "browser" }
      when /Safari/i
        { browser: "Safari", type: "browser" }
      else
        { browser: "Unknown", type: "browser" }
      end
    end

    def display_name
      "#{browser_info[:browser]} Browser Session"
    end
  end
end

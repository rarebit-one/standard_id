namespace :standard_id do
  namespace :cleanup do
    desc "Delete expired sessions older than GRACE_DAYS (default 7)"
    task sessions: :environment do
      grace_seconds = ENV.fetch("GRACE_DAYS", "7").to_i.days.to_i
      StandardId::CleanupExpiredSessionsJob.perform_now(grace_period_seconds: grace_seconds)
    end

    desc "Delete expired/revoked refresh tokens older than GRACE_DAYS (default 7)"
    task refresh_tokens: :environment do
      grace_seconds = ENV.fetch("GRACE_DAYS", "7").to_i.days.to_i
      StandardId::CleanupExpiredRefreshTokensJob.perform_now(grace_period_seconds: grace_seconds)
    end

    desc "Delete expired/consumed authorization codes older than GRACE_DAYS (default 7). Consumed codes use a separate 1-day grace window (not env-configurable for now)."
    task authorization_codes: :environment do
      grace_seconds = ENV.fetch("GRACE_DAYS", "7").to_i.days.to_i
      StandardId::CleanupExpiredAuthorizationCodesJob.perform_now(grace_period_seconds: grace_seconds)
    end

    desc "Delete expired/used code challenges older than GRACE_DAYS (default 7). Used challenges use a separate 1-day grace window (not env-configurable for now)."
    task code_challenges: :environment do
      grace_seconds = ENV.fetch("GRACE_DAYS", "7").to_i.days.to_i
      StandardId::CleanupExpiredCodeChallengesJob.perform_now(grace_period_seconds: grace_seconds)
    end

    desc "Run all StandardId cleanup jobs with GRACE_DAYS (default 7)"
    task all: [:sessions, :refresh_tokens, :authorization_codes, :code_challenges]
  end
end

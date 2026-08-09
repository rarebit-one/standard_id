require "rails_helper"

# What a DROPPED refresh RESPONSE does to a healthy session.
#
# Rotation assumes the client receives the new token. When it does not — a
# timeout, a dead radio, the OS killing the app between the server's COMMIT and
# the client's write — the server has rotated and the client still holds the
# previous token. Its next refresh therefore presents an already-rotated token,
# which is indistinguishable from an attacker replaying a stolen one.
#
# These specs pin the resulting behaviour, because the second one is the reason a
# user gets bounced to a login screen rather than merely retrying: reuse
# detection revokes the whole FAMILY, so the perfectly good token the server
# issued (and the client never saw) dies too. The session is unrecoverable, and
# no amount of client-side retrying or failure-budgeting can bring it back.
RSpec.describe "refresh rotation after a lost response" do
  let(:request) { instance_double("ActionDispatch::Request") }
  let(:client_id) { "client_123" }
  let(:account) { Account.create!(name: "Lost Response", email: "lost-response@example.com") }
  let(:first_jti) { SecureRandom.uuid }
  let(:first_payload) { { sub: account.id, client_id: client_id, scope: "read", jti: first_jti } }

  # The token the client is holding when the response goes missing.
  let!(:first_token) do
    StandardId::RefreshToken.create!(
      account: account,
      token_digest: StandardId::RefreshToken.digest_for(first_jti),
      expires_at: 30.days.from_now
    )
  end

  def flow_presenting_first_token
    StandardId::Oauth::RefreshTokenFlow
      .new({ client_id: client_id, refresh_token: "rtok" }, request)
      .tap { allow(StandardId::JwtService).to receive(:decode).with("rtok").and_return(first_payload) }
  end

  # The server side of a refresh whose response never arrives: it rotates and
  # commits exactly as normal. Only the delivery fails, which the server cannot
  # see and therefore cannot compensate for.
  def server_rotates_but_client_never_receives_it
    flow_presenting_first_token.execute
    StandardId::RefreshToken.where(previous_token_id: first_token.id).sole
  end

  it "leaves the client holding a token the server has already revoked" do
    successor = server_rotates_but_client_never_receives_it

    expect(first_token.reload).to be_revoked
    expect(successor).to be_active
  end

  # THE PROPERTY THAT CAUSES THE LOGOUT.
  #
  # The client retries with the only token it has. That is reuse, so the family
  # is revoked — including the successor, which was never compromised and never
  # even left the server. A session that was one dropped packet away from
  # healthy is now dead, and the user is asked to sign in again.
  it "kills the successor too, so the session cannot be recovered" do
    successor = server_rotates_but_client_never_receives_it

    expect { flow_presenting_first_token.authenticate! }
      .to raise_error(StandardId::InvalidGrantError, /reuse detected/)

    expect(successor.reload).to be_revoked,
                                "the successor the client never received is revoked too — " \
                                "this is why a lost response becomes a forced re-login"
    expect(StandardId::RefreshToken.where(account: account).active).to be_empty
  end

  # Retrying cannot help, which is what makes a client-side failure budget the
  # wrong instrument for this failure: every attempt after the first re-presents
  # the same dead token against an already-revoked family.
  it "cannot be recovered by retrying" do
    server_rotates_but_client_never_receives_it
    suppress(StandardId::InvalidGrantError) { flow_presenting_first_token.authenticate! }

    3.times do
      expect { flow_presenting_first_token.authenticate! }
        .to raise_error(StandardId::InvalidGrantError)
    end
  end

  # ---------------------------------------------------------------------------
  # With the leeway enabled (opt-in; 0 by default), the honest client recovers.
  # ---------------------------------------------------------------------------
  context "with refresh_token_reuse_leeway enabled" do
    before { StandardId.config.oauth.refresh_token_reuse_leeway = 60 }

    it "lets the client recover by rotating from the untouched successor" do
      successor = server_rotates_but_client_never_receives_it

      response = nil
      expect { response = flow_presenting_first_token.execute }.not_to raise_error

      expect(response[:refresh_token]).to be_present
      # The successor is retired in favour of the token the client will actually
      # receive; it cannot be re-delivered, since only its digest is stored.
      expect(successor.reload).to be_revoked
      expect(StandardId::RefreshToken.where(account: account).active.count).to eq(1)
    end

    it "publishes a graced event so the leeway is observable when it fires" do
      server_rotates_but_client_never_receives_it

      expect(StandardId::Events).to receive(:publish).with(
        StandardId::Events::OAUTH_REFRESH_TOKEN_REUSE_GRACED,
        hash_including(account_id: account.id, client_id: client_id)
      ).at_least(:once)
      allow(StandardId::Events).to receive(:publish).and_call_original

      flow_presenting_first_token.execute
    end

    # The condition that keeps this from being a free pass for replay. A used
    # successor proves the legitimate client DID receive it, so a token presented
    # afterwards is a genuine replay — and dies exactly as before.
    it "still revokes the family once the successor has itself been rotated" do
      successor = server_rotates_but_client_never_receives_it
      grandchild = StandardId::RefreshToken.create!(
        account: account,
        token_digest: StandardId::RefreshToken.digest_for(SecureRandom.uuid),
        expires_at: 30.days.from_now,
        previous_token: successor
      )

      expect { flow_presenting_first_token.authenticate! }
        .to raise_error(StandardId::InvalidGrantError, /reuse detected/)

      expect(grandchild.reload).to be_revoked
    end

    it "still revokes the family once the leeway has elapsed" do
      successor = server_rotates_but_client_never_receives_it
      first_token.update!(revoked_at: 10.minutes.ago)

      expect { flow_presenting_first_token.authenticate! }
        .to raise_error(StandardId::InvalidGrantError, /reuse detected/)

      expect(successor.reload).to be_revoked
    end

    it "is clamped so a host cannot configure an unbounded replay window" do
      StandardId.config.oauth.refresh_token_reuse_leeway = 86_400
      successor = server_rotates_but_client_never_receives_it
      first_token.update!(revoked_at: (StandardId::Oauth::RefreshTokenFlow::MAX_REUSE_LEEWAY_SECONDS + 60).seconds.ago)

      expect { flow_presenting_first_token.authenticate! }
        .to raise_error(StandardId::InvalidGrantError, /reuse detected/)

      expect(successor.reload).to be_revoked
    end
  end
end

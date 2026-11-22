require "rails_helper"

RSpec.describe StandardId::PasswordPepper do
  let(:password) { "Sup3r-secret!" }
  let(:pepper) { "current-pepper-#{"x" * 32}" }
  let(:old_pepper) { "previous-pepper-#{"y" * 32}" }

  def digest_for(input)
    BCrypt::Password.create(input, cost: BCrypt::Engine::MIN_COST)
  end

  # Counts bcrypt hash computations: one per is_password? comparison. The
  # dummy digest is made first, so its creation is not counted.
  def bcrypt_comparisons
    described_class::DUMMY_DIGEST.value
    count = 0
    allow(BCrypt::Engine).to receive(:hash_secret).and_wrap_original do |original, *args|
      count += 1
      original.call(*args)
    end
    yield
    count
  end

  describe "with no pepper configured (the default)" do
    it "is disabled" do
      expect(described_class).not_to be_enabled
      expect(described_class.current).to eq("")
    end

    it "has the bare password as its only candidate" do
      expect(described_class.candidates).to eq([described_class::UNPEPPERED])
    end

    it "applies to the bare password" do
      expect(described_class.apply(password, described_class.current)).to eq(password)
    end

    it "matches a has_secure_password digest with one comparison" do
      digest = digest_for(password)
      expect(bcrypt_comparisons { expect(described_class.matching_pepper(digest, password)).to eq("") }).to eq(1)
    end

    it "makes one dummy comparison, as before" do
      expect(bcrypt_comparisons { described_class.dummy_authenticate(password) }).to eq(1)
    end
  end

  describe "with a pepper" do
    before do
      StandardId.config.password.pepper = pepper
      StandardId.config.password.previous_peppers = [old_pepper, "", old_pepper]
    end

    it "is enabled" do
      expect(described_class).to be_enabled
    end

    it "tries the current pepper, then the previous ones, then none, without blanks or repeats" do
      expect(described_class.candidates).to eq([pepper, old_pepper, ""])
    end

    it "drops the unpeppered candidate when accept_unpeppered_passwords is off" do
      StandardId.config.password.accept_unpeppered_passwords = false

      expect(described_class.candidates).to eq([pepper, old_pepper])
    end

    it "applies HMAC-SHA256 under the pepper, hex-encoded, so bcrypt sees 64 bytes whatever the password" do
      long = "p" * 200
      applied = described_class.apply(long, pepper)

      expect(applied).to eq(OpenSSL::HMAC.hexdigest("SHA256", pepper, long))
      expect(applied).to match(/\A\h{64}\z/)
      expect(described_class.apply("p" * 201, pepper)).not_to eq(applied)
    end

    it "names the pepper a digest was made under" do
      expect(described_class.matching_pepper(digest_for(described_class.apply(password, pepper)), password)).to eq(pepper)
      expect(described_class.matching_pepper(digest_for(described_class.apply(password, old_pepper)), password)).to eq(old_pepper)
      expect(described_class.matching_pepper(digest_for(password), password)).to eq("")
    end

    it "matches nothing for a wrong password" do
      expect(described_class.matching_pepper(digest_for(described_class.apply(password, pepper)), "Wr0ng-password!")).to be_nil
    end

    it "makes as many dummy comparisons as a wrong password costs against a real digest" do
      real = digest_for(described_class.apply(password, pepper))
      wrong = bcrypt_comparisons { described_class.matching_pepper(real, "Wr0ng-password!") }
      dummy = bcrypt_comparisons { described_class.dummy_authenticate("Wr0ng-password!") }

      expect(wrong).to eq(3)
      expect(dummy).to eq(wrong)
    end
  end

  describe "with only previous peppers (turning the pepper off)" do
    before { StandardId.config.password.previous_peppers = [old_pepper] }

    it "writes bare passwords and still reads the old pepper" do
      expect(described_class.current).to eq("")
      expect(described_class.candidates).to eq(["", old_pepper])
    end

    it "keeps the unpeppered candidate even when accept_unpeppered_passwords is off" do
      StandardId.config.password.accept_unpeppered_passwords = false

      expect(described_class.candidates).to eq(["", old_pepper])
    end
  end
end

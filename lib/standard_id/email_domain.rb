require "public_suffix"

module StandardId
  # Whether an e-mail address's domain ends in a TLD that is actually
  # delegated, judged against the ICANN section of the Public Suffix List.
  #
  # A format check cannot tell `rarebit.one` from `rarebit.ome`: both are a
  # well-formed domain, and every pattern in common use (Truemail's :regex,
  # `URI::MailTo::EMAIL_REGEXP`, EmailIdentifier::EMAIL_FORMAT) accepts any
  # run of letters as a TLD. On a sign-in code flow that typo fails silently:
  # the ESP accepts the message, bounces it hours later on the missing MX, and
  # the user is left waiting for a code that never comes. This catches the
  # whole class of mistyped TLDs (.ome, .con, .cmo) offline, before anything
  # is sent. It says nothing about whether the domain itself exists; that
  # needs DNS (Truemail's :mx), which this deliberately does not do.
  #
  # The gem's own rule is .allowed?: a registered TLD, or one of the
  # special-use TLDs in email.allowed_special_use_tlds (test, example, invalid,
  # localhost, local by default). Those can never be delegated, so accepting them
  # cannot hide a typo of a real TLD, and apps use them on purpose for
  # synthetic accounts and fixtures (agent+1@agents.example.invalid). Host
  # apps' own e-mail validators should call .allowed? too, so one address is
  # judged the same way on every path:
  #
  #   StandardId::EmailDomain.allowed?("jaryl@rarebit.ome")        # => false
  #   StandardId::EmailDomain.allowed?("bot@agents.app.invalid")   # => true
  #   StandardId::EmailDomain.registered_tld?("bot@agents.app.invalid") # => false
  module EmailDomain
    module_function

    # @param email_or_domain [String] an address ("a@b.com") or a bare domain ("b.com")
    # @return [Boolean] whether the domain ends in a registered TLD or an allowed special-use one
    def allowed?(email_or_domain)
      registered_tld?(email_or_domain) || special_use_tld?(email_or_domain)
    end

    # @param email_or_domain [String] an address ("a@b.com") or a bare domain ("b.com")
    # @return [Boolean]
    def registered_tld?(email_or_domain)
      domain = domain_of(email_or_domain)
      return false if domain.blank?

      unicode = domain.split(".").map { |label| to_unicode(label) }.join(".")
      # default_rule: nil — without it the PSL's implicit "*" rule matches any
      # unknown TLD, which is exactly what this exists to reject.
      # ignore_private: true — only ICANN suffixes count; a private entry such
      # as blogspot.com still resolves through its ICANN parent.
      PublicSuffix.valid?(unicode, default_rule: nil, ignore_private: true)
    rescue ArgumentError, RangeError
      # A malformed punycode label.
      false
    end

    # Whether the domain's last label is in email.allowed_special_use_tlds.
    def special_use_tld?(email_or_domain)
      tld = domain_of(email_or_domain)&.split(".")&.last
      return false if tld.blank?

      Array(StandardId.config.email.allowed_special_use_tlds).any? { |allowed| allowed.to_s.downcase.delete_prefix(".") == tld }
    end

    # The domain part of an address (or the input itself when it has no "@"),
    # stripped, downcased and without a trailing root dot. Nil when blank.
    def domain_of(email_or_domain)
      domain = email_or_domain.to_s.strip.split("@").last.to_s.downcase.delete_suffix(".")
      domain.presence
    end

    # The error shown when an address fails the check, or nil when it passes or
    # the check is turned off (email.require_registered_tld = false).
    def validation_error(email)
      return unless StandardId.config.email.require_registered_tld
      return if allowed?(email)

      "#{domain_of(email)} isn't a valid e-mail domain. Check the address."
    end

    # The PSL lists internationalised suffixes in Unicode (рф), but addresses
    # usually carry them as ASCII punycode (xn--p1ai), which PublicSuffix does
    # not convert. Ruby's standard library has no IDNA, so decode the A-label
    # here (RFC 3492) rather than take a dependency for one function.
    def to_unicode(label)
      return label unless label.start_with?("xn--")

      Punycode.decode(label.delete_prefix("xn--"))
    end

    # RFC 3492 decoding, section 6.2. Raises ArgumentError on malformed input.
    module Punycode
      BASE = 36
      TMIN = 1
      TMAX = 26
      SKEW = 38
      DAMP = 700
      INITIAL_BIAS = 72
      INITIAL_N = 128

      module_function

      def decode(input)
        delimiter = input.rindex("-")
        output = delimiter ? input[0...delimiter].chars : []
        raise ArgumentError, "non-basic code point" unless output.all?(&:ascii_only?)

        pos = delimiter ? delimiter + 1 : 0
        n = INITIAL_N
        bias = INITIAL_BIAS
        i = 0

        while pos < input.length
          old_i = i
          w = 1
          k = BASE
          loop do
            raise ArgumentError, "truncated punycode" if pos >= input.length

            digit = decode_digit(input[pos])
            pos += 1
            i += digit * w
            t = (k - bias).clamp(TMIN, TMAX)
            break if digit < t

            w *= BASE - t
            k += BASE
          end
          bias = adapt(i - old_i, output.length + 1, old_i.zero?)
          n += i / (output.length + 1)
          i %= output.length + 1
          output.insert(i, n.chr(Encoding::UTF_8))
          i += 1
        end

        output.join
      end

      def decode_digit(char)
        case char
        when "0".."9" then char.ord - 22
        when "a".."z" then char.ord - 97
        when "A".."Z" then char.ord - 65
        else raise ArgumentError, "invalid punycode digit"
        end
      end

      def adapt(delta, num_points, first_time)
        delta = first_time ? delta / DAMP : delta / 2
        delta += delta / num_points
        k = 0
        while delta > ((BASE - TMIN) * TMAX) / 2
          delta /= BASE - TMIN
          k += BASE
        end
        k + (((BASE - TMIN + 1) * delta) / (delta + SKEW))
      end
    end
  end
end

# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"

require_relative "hashing"

class Klenod::Build::Hashing::Test < Minitest::Test
  def test_hexdigest_returns_sha256_hex_digest
    assert_equal(Digest::SHA256.hexdigest("klenod"), Klenod::Build::Hashing.hexdigest("klenod"))
  end

  def test_short_returns_truncated_digest
    assert_equal(Digest::SHA256.hexdigest("klenod")[0, 16], Klenod::Build::Hashing.short("klenod"))
    assert_equal(Digest::SHA256.hexdigest("klenod")[0, 8], Klenod::Build::Hashing.short("klenod", length: 8))
  end

  def test_file_hexdigest_streams_file_digest
    Dir.mktmpdir do |dir|
      path = "#{dir}/asset.bin"
      File.binwrite(path, "klenod")

      assert_equal(Digest::SHA256.hexdigest("klenod"), Klenod::Build::Hashing.file_hexdigest(path))
    end
  end
end
